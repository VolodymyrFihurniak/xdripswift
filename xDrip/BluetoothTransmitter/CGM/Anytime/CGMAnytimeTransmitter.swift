//
//  CGMAnytimeTransmitter.swift
//  xdrip
//
//  Direct Bluetooth driver for the Anytime / Yuwell CGM transmitters, ported from the JugglucoNG
//  `drivers/anytime` package (GPL-3.0, see THIRD_PARTY_NOTICES.md). The frame layouts, the CT5 cipher, the
//  glucose paths and every decision that can be tested without a radio live in `AnytimeProtocol.swift`,
//  `AnytimeSession.swift` and `AnytimeAlgorithm.swift`; this file owns the connection: the handshake of each
//  family, the single write slot, the live pushes and the history pulls, and the delivery of the readings
//  to xDrip.
//
//  Three generations are driven: CT2 (SN04.., 16-bit service FFF0), CT4 (SN72..SN90) and CT5 (the
//  encrypted "Anytime" brand). CT2.5, the CT3 families and unknown names are refused with a link problem:
//  their glucose comes from a native kernel that is not ported (docs/anytime.md).
//
//  Differences from the Android driver that the platform forces:
//  - iOS has no bond-state API, no MTU request and no connect timeout. A failed connect counts as a
//    timeout for the back-off only, and the CT5 session material is "held here" when it is in the Keychain.
//  - Persistence is UserDefaults JSON per Bluetooth address (`AnytimeDeviceStore`); the CT5 cipher key and
//    its identity bytes live in the Keychain (`AnytimeCt5SecretStore`) and never reach a trace.
//  - Readings go straight to xDrip; JugglucoNG's Room import buffer, raw JNI window, fingerstick
//    calibration, reset / unbind / end-cycle commands and the older-history background pass are not ported.
//
//  Never compiled here and never tried on a real sensor.
//

import CoreBluetooth
import Foundation
import os
import Security

// MARK: - Link problems and persisted device state

/// What went wrong last, shown on the device screen and cleared by the next reading.
enum AnytimeLinkProblem: String, Codable {
    case linkLost
    case notAnAnytime
    case unsupportedFamily
    case handshakeStalled
    case protocolTimeout
    case checkMalformed
    case lowBattery
    case bindNeverStreamed
    case noData
    case historyFailed
    case sensorRestarted
}

/// Everything the driver learns about one sensor, kept per Bluetooth address in UserDefaults so the
/// device screen can show it without a connection. Not part of Core Data (the entity only links to its
/// BLEPeripheral). It holds no secret: the CT5 cipher key is in the Keychain (`AnytimeCt5SecretStore`).
struct AnytimeDeviceState: Codable, Equatable {
    var advertisedName: String?
    /// `AnytimeFamily.rawValue` of the name that classified this sensor.
    var family: String?
    var bound = false
    var transmitterVersion: String?
    /// The sensor code (or the code the CT5 transmitter reported), as typed or decoded.
    var qrRaw: String?
    var voltageFlag = 0
    var batteryVolts: Float?
    var batteryPercent: Int?
    var lastGlucoseId = -1
    var highestImportedId = -1
    var timelineStartMs: Int64 = 0
    var sensorStartMs: Int64 = 0
    var warmupStartedAtMs: Int64 = 0
    var lastReadingDate: Date?
    var lastMgdl: Float?
    /// True when the last stored value was estimated from the current of a CT5 that stopped computing glucose.
    var lastWasEstimate = false
    var iwNa: Float?
    var ibNa: Float?
    var temperatureC: Float?
    var ceVoltageMv: Int?
    var rawScale: Float?
    var rawScaleSamples = 0
    var calibrator: AnytimeCalibrator.State?
    var calibratorK0: Float?
    var pendingGapFromId = -1
    var pendingGapStopBeforeId = -1
    var gapFailure: AnytimeCt5GapFailureSnapshot?
    var resolvedIds: [Int] = []
    var skippedIds: [Int] = []
    var problem: AnytimeLinkProblem?
    var problemDate: Date?
}

enum AnytimeDeviceStore {
    private static let keyPrefix = "anytime.deviceState."
    private static let lock = NSLock()

    static func load(address: String) -> AnytimeDeviceState {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(address: address)
    }

    @discardableResult
    static func update(address: String, _ change: (inout AnytimeDeviceState) -> Void) -> AnytimeDeviceState {
        lock.lock()
        defer { lock.unlock() }
        var state = loadUnlocked(address: address)
        change(&state)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: keyPrefix + address)
        }
        return state
    }

    static func clear(address: String) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: keyPrefix + address)
        AnytimeConfiguration.clear(address: address)
    }

    private static func loadUnlocked(address: String) -> AnytimeDeviceState {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + address),
              let state = try? JSONDecoder().decode(AnytimeDeviceState.self, from: data) else {
            return AnytimeDeviceState()
        }
        return state
    }
}

// MARK: - Settings

/// The one choice the user makes for an Anytime sensor, kept per Bluetooth address.
enum AnytimeConfiguration {
    private static let estimateKeyPrefix = "anytime.ct5CurrentEstimate."

    /// A CT5 stops computing glucose when its rated life ends but keeps reporting current. JugglucoNG turns
    /// that current into an estimate with the scale it learned; here this is off until the user opts in, because
    /// the estimates look like any other reading everywhere outside the device screen.
    static func ct5EstimatesFromCurrent(for address: String, userDefaults: UserDefaults = .standard) -> Bool {
        return userDefaults.bool(forKey: estimateKeyPrefix + address)
    }

    static func setCt5EstimatesFromCurrent(_ isOn: Bool, for address: String, userDefaults: UserDefaults = .standard) {
        if isOn {
            userDefaults.set(true, forKey: estimateKeyPrefix + address)
        } else {
            userDefaults.removeObject(forKey: estimateKeyPrefix + address)
        }
    }

    static func clear(address: String, userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: estimateKeyPrefix + address)
    }
}

// MARK: - CT5 session material in the Keychain

/// What a CT5 transmitter has agreed with this phone: the session cipher key (0...255) from the setID answer,
/// the identity bytes of the reconnect check and the four-digit temporary id of the K/R setup.
struct AnytimeCt5Secrets: Codable, Equatable {
    var cipherKey: Int
    var randomB: [Int]?
    var tempId: String?
}

/// One Keychain item per Bluetooth address. Device-only (never synchronised, never in a backup) and never
/// written to a trace.
enum AnytimeCt5SecretStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "xdrip") + ".anytime"
    private static let lock = NSLock()

    private static func query(address: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ct5." + address,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func load(address: String) -> AnytimeCt5Secrets? {
        lock.lock()
        defer { lock.unlock() }
        var request = query(address: address)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secrets = try? JSONDecoder().decode(AnytimeCt5Secrets.self, from: data),
              (0...255).contains(secrets.cipherKey) else { return nil }
        return secrets
    }

    static func hasSecrets(address: String) -> Bool {
        return load(address: address) != nil
    }

    @discardableResult
    static func save(_ secrets: AnytimeCt5Secrets, address: String) -> Bool {
        guard (0...255).contains(secrets.cipherKey), let data = try? JSONEncoder().encode(secrets) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(address: address) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(address: address).merging(attributes) { _, new in new }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func clear(address: String) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query(address: address) as CFDictionary)
    }
}

// MARK: - Transmitter

private func anytimeNowMs() -> Int64 {
    return Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

class CGMAnytimeTransmitter: BluetoothTransmitter, CGMTransmitter {

    private enum Phase {
        case connecting
        case handshaking
        case streaming
    }

    /// Names of the delayed jobs. A job is dropped when its name was re-armed or cancelled, or when the
    /// connection it was armed on is gone.
    private enum TimerName: String {
        case notifyFallback
        case protocolTimeout
        case historyPullTimeout
        case historyStep
        case writeStale
        case writeSpacing
        case noData
        case pullFallback
        case telemetry
        case handshakeStall
        case ct5Unproven
        case ct5Settle
        case initGrace
        case postInit
        case freshBackfill
        case reconnectBackfill
        case gapResume
    }

    private struct PendingWrite {
        let bytes: [UInt8]
        let tag: String
        let expectResponse: Bool
        let priority: AnytimeHistoryPolicy.WritePriority
        let secret: Bool
    }

    /// One history pass: a contiguous range of glucose ids pulled in batches.
    private final class HistoryRun {
        let reason: String
        let stopBeforeId: Int
        var lastPulledId: Int
        var emptyInARow = 0
        let startedAfterGlucoseId: Int
        var pullInFlight = false
        var pullInFlightCount = 0
        var pullIsSeries = false
        var timeouts = 0

        init(reason: String, stopBeforeId: Int, lastPulledId: Int, startedAfterGlucoseId: Int) {
            self.reason = reason
            self.stopBeforeId = stopBeforeId
            self.lastPulledId = lastPulledId
            self.startedAfterGlucoseId = startedAfterGlucoseId
        }
    }

    /// A reading waiting for the end of the frame that carried it.
    private struct SampleToDeliver {
        let date: Date
        let mgdl: Float
        let live: Bool
    }

    // MARK: - timing and limits (JugglucoNG `AnytimeBleManager` constants)

    private static let activeSessionReconnectDelayMs: Int64 = 2_000
    /// iOS may suspend the app a few seconds after a disconnect, so a reconnect never waits longer.
    private static let maxReconnectDelay: TimeInterval = 8
    private static let protocolFrameTimeout: TimeInterval = 8
    private static let notifyFallbackDelay: TimeInterval = 6
    private static let writeStaleSeconds: TimeInterval = 5
    private static let writeNoResponseSpacing: TimeInterval = 0.06
    private static let noDataWatchdogMultiplier = 4.0
    private static let pullFallbackMultiplier = 3.0
    private static let historyPullTimeout: TimeInterval = 8
    private static let historyBatchDelay: TimeInterval = 0.01
    private static let ct5HistoryBatchDelay: TimeInterval = 0.4
    private static let historyPullSeriesCount = 15
    private static let historyEmptyResponsesToStop = 2
    private static let caughtUpCooldownMs: Int64 = 2 * 60 * 1000
    private static let ct5HistoryMaxTimeoutsPerConnection = 3
    private static let ct5HistoryRetryBackoffMs: Int64 = 3_000
    private static let ct5GapMaxFailedSessions = 3
    private static let ct5MaxGapRepairRecords = 480
    private static let ct4MaxGapRepairRecords = 480
    private static let ct2MaxGapRepairRecords = 60
    private static let ct5HistoryLinkSettleMs: Int64 = 45_000
    private static let ct5HistorySettleRetry: TimeInterval = 15
    private static let freshAutoBackfillRecords = 24
    private static let glucoseIdRollbackThreshold = 48
    private static let initNoAckStreamingGrace: TimeInterval = 0.65
    private static let telemetryCheckInterval: TimeInterval = 60 * 60
    private static let telemetryRetryDelay: TimeInterval = 60
    private static let telemetryQuiet: TimeInterval = 10
    /// Ids kept per set in the persisted CT5 gap bookkeeping.
    private static let maxStoredIds = 1500

    // MARK: - properties

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMAnytime)

    // link
    /// Bumped on every connect and disconnect so delayed work of an older connection does nothing.
    private var connectionGeneration = 0
    private var phase: Phase = .connecting
    private var characteristics = [CBUUID: CBCharacteristic]()
    private var notifyCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var legacyLayout = false
    private var sessionBegun = false
    /// A specific problem recorded on this link is not overwritten by the generic "link lost".
    private var problemNotedOnThisLink = false
    private var released = false
    private var stateRestored = false
    private var sessionDeliveredData = false
    private var sessionOutcomeRecorded = false
    /// The local name of the advertisement that led to the first connection.
    private var discoveredAdvertisedName: String?
    private let connectMode = AnytimeConnectModeState()
    private let sessionChurn = AnytimeSessionChurnState()
    private var timerTokens = [TimerName: Int]()

    // identity
    private var advertisedName: String?
    /// The name the handshake classified (the CT2 handshake sends it back to the transmitter).
    private var handshakeName = ""
    private var familyEntry = AnytimeFamilies.unknown
    private var profile = AnytimeProfileResolver.defaultProfile
    private var bound = false
    private var transmitterVersion: String?
    private var qr: AnytimeQrCalibration?
    private var voltageFlag = 0

    // CT5 session
    private var ct5CipherKey = -1
    private var ct5RandomA: [Int]?
    private var ct5RandomB: [Int]?
    private var ct5TempId = ""
    private var ct5ReconnectDateAfterIdentity = false
    private var ct5VoltagePayload = false
    private var ct5LastDataRxAtMs: Int64 = 0
    private var ct5HighestImportedId = -1
    private var ct5PendingGapFromId = -1
    private var ct5PendingGapStopBeforeId = -1
    private var ct5ResolvedIds = Set<Int>()
    private var ct5SkippedIds = Set<Int>()
    private let ct5LiveClock = AnytimeCt5LiveClock()
    private var ct5RawScale = AnytimeCt5RawScale()
    private let ct5HistoryHealth = AnytimeCt5HistoryHealth(
        maxTimeoutsPerConnection: CGMAnytimeTransmitter.ct5HistoryMaxTimeoutsPerConnection,
        retryBackoffMs: CGMAnytimeTransmitter.ct5HistoryRetryBackoffMs
    )
    private var ct5GapFailureTracker = AnytimeCt5GapFailureTracker(maxFailedSessions: CGMAnytimeTransmitter.ct5GapMaxFailedSessions)
    private var ct5SingleRecordHistoryOnly = false

    // CT2 and CT4 gap bookkeeping (memory only)
    private var pendingGapFromId = -1
    private var pendingGapStopBeforeId = -1

    // write slot
    private var writeQueue = [PendingWrite]()
    private var activeWrite: PendingWrite?
    private var writeInFlight = false
    private var protocolResponseInFlight = false
    private var protocolResponseRequestOpcode: UInt8 = 0
    private var lastProtocolFrameTag = ""
    private var lastProtocolFrameAtMs: Int64 = 0

    // streaming and timeline
    private var streamingSinceMs: Int64 = 0
    private var lastGlucoseId = -1
    private var lastGlucoseAtMs: Int64 = 0
    private var lastLiveFrameAtMs: Int64 = 0
    private var glucoseTimelineStartMs: Int64 = 0
    private var sensorStartMs: Int64 = 0
    private var warmupStartedAtMs: Int64 = 0
    private var restoredGlucoseState = false
    private var freshPostLiveBackfillStarted = false
    private var pendingNewSensorStart: Date?
    private var lastMgdl: Float?
    private var lastWasEstimate = false
    private var iwNa: Float?
    private var ibNa: Float?
    private var temperatureC: Float?
    private var ceVoltageMv: Int?
    private var batteryVolts: Float?
    private var batteryPercent: Int?
    private var telemetryLivePushesUntilCheck = -1
    private let algorithmSession = AnytimeAlgorithmSession()

    // history
    private var history: HistoryRun?
    private var legacySeriesHistorySupported = true
    private let caughtUpCooldown = AnytimeHistoryCaughtUpCooldown(
        cooldownMs: CGMAnytimeTransmitter.caughtUpCooldownMs,
        nowMs: { anytimeNowMs() }
    )
    /// Ids processed by this object (CT2 and CT4), so a repeated pull is not applied twice.
    private var processedIds = Set<Int>()

    // delivery
    private var deliveryBuffer = [SampleToDeliver]()

    // MARK: - initialization

    init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {
        var newAddressAndName: BluetoothTransmitter.DeviceAddressAndName = .notYetConnected(expectedName: nil)
        if let address = address {
            newAddressAndName = .alreadyConnectedBefore(address: address, name: name)
        }

        self.cgmTransmitterDelegate = cGMTransmitterDelegate

        // The first scan has no service filter (foreground only); later connections use the stored
        // address. The base class turns the notifications of the 128-bit layout on at discovery; the
        // 16-bit CT2 layout is switched on here.
        super.init(
            addressAndName: newAddressAndName,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [AnytimeGATT.primaryService, AnytimeGATT.legacyService],
            CBUUID_ReceiveCharacteristic: AnytimeGATT.primaryNotify.uuidString,
            CBUUID_WriteCharacteristic: AnytimeGATT.primaryWrite.uuidString,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    // MARK: - small helpers

    private func logLine(_ message: String, type: OSLogType = .info) {
        trace("%{public}@", log: log, category: ConstantsLog.categoryCGMAnytime, type: type, message)
    }

    private var isCt2: Bool { return familyEntry.family == .ct2 }
    private var isCt4: Bool { return familyEntry.family == .ct4 }
    private var isCt5: Bool { return familyEntry.family == .ct5 }

    private var intervalMs: Int64 { return Int64(profile.readingIntervalMinutes) * 60_000 }

    private var hasCt5Cipher: Bool { return (0...255).contains(ct5CipherKey) }

    private func loadState() -> AnytimeDeviceState? {
        guard let address = deviceAddress else { return nil }
        return AnytimeDeviceStore.load(address: address)
    }

    private func updateState(_ change: (inout AnytimeDeviceState) -> Void) {
        guard let address = deviceAddress else { return }
        AnytimeDeviceStore.update(address: address, change)
    }

    private func noteProblem(_ problem: AnytimeLinkProblem) {
        problemNotedOnThisLink = true
        logLine("Anytime link problem: \(problem.rawValue)")
        updateState {
            $0.problem = problem
            $0.problemDate = Date()
        }
    }

    private func finite(_ value: Float?) -> Float? {
        guard let value = value, value.isFinite else { return nil }
        return value
    }

    /// Writes the runtime values that must outlive the process (JugglucoNG `persistAlgorithmState`).
    private func persistState() {
        guard deviceAddress != nil else { return }
        let resolved = Array(ct5ResolvedIds.sorted().suffix(Self.maxStoredIds))
        let skipped = Array(ct5SkippedIds.sorted().suffix(Self.maxStoredIds))
        let calibrator = algorithmSession.calibrator
        updateState {
            $0.advertisedName = advertisedName ?? $0.advertisedName
            $0.family = familyEntry.family == .unknown ? $0.family : familyEntry.family.rawValue
            $0.bound = bound
            $0.transmitterVersion = transmitterVersion
            $0.qrRaw = qr?.rawQr
            $0.voltageFlag = voltageFlag
            $0.batteryVolts = finite(batteryVolts)
            $0.batteryPercent = batteryPercent
            $0.lastGlucoseId = lastGlucoseId
            $0.highestImportedId = ct5HighestImportedId
            $0.timelineStartMs = glucoseTimelineStartMs
            $0.sensorStartMs = sensorStartMs
            $0.warmupStartedAtMs = warmupStartedAtMs
            $0.lastReadingDate = lastGlucoseAtMs > 0 ? Date(timeIntervalSince1970: Double(lastGlucoseAtMs) / 1000) : nil
            $0.lastMgdl = finite(lastMgdl)
            $0.lastWasEstimate = lastWasEstimate
            $0.iwNa = finite(iwNa)
            $0.ibNa = finite(ibNa)
            $0.temperatureC = finite(temperatureC)
            $0.ceVoltageMv = ceVoltageMv
            $0.rawScale = finite(ct5RawScale.scale)
            $0.rawScaleSamples = ct5RawScale.samples
            $0.calibrator = calibrator?.snapshot()
            $0.calibratorK0 = calibrator?.k0
            $0.pendingGapFromId = ct5PendingGapFromId
            $0.pendingGapStopBeforeId = ct5PendingGapStopBeforeId
            $0.gapFailure = ct5GapFailureTracker.snapshot()
            $0.resolvedIds = resolved
            $0.skippedIds = skipped
        }
    }

    private func persistSecrets() {
        guard let address = deviceAddress else { return }
        if hasCt5Cipher {
            AnytimeCt5SecretStore.save(AnytimeCt5Secrets(cipherKey: ct5CipherKey, randomB: ct5RandomB, tempId: ct5TempId.isEmpty ? nil : ct5TempId), address: address)
        } else {
            AnytimeCt5SecretStore.clear(address: address)
        }
    }

    /// Reads the persisted state once per object, at the first connection (the address is known then).
    private func restoreStateIfNeeded() {
        guard !stateRestored, let address = deviceAddress else { return }
        stateRestored = true
        let state = AnytimeDeviceStore.load(address: address)
        advertisedName = state.advertisedName
        applyName(state.advertisedName)
        bound = state.bound
        transmitterVersion = state.transmitterVersion
        if let raw = state.qrRaw, !raw.isEmpty {
            qr = AnytimeQr.parse(raw)
        }
        voltageFlag = qr?.voltageFlag ?? state.voltageFlag
        batteryVolts = state.batteryVolts
        batteryPercent = state.batteryPercent
        lastGlucoseId = AnytimeHistoryPolicy.sanitizeRestoredGlucoseId(
            persistedLastId: state.lastGlucoseId,
            cachedRawMaxId: -1,
            rollbackThreshold: Self.glucoseIdRollbackThreshold
        )
        ct5HighestImportedId = state.highestImportedId
        if isCt5 && ct5HighestImportedId < 0 && lastGlucoseId >= 0 {
            // sessions stored before the import cursor existed: the old cursor only ever advanced on stored glucose
            ct5HighestImportedId = lastGlucoseId
        }
        sensorStartMs = state.sensorStartMs
        glucoseTimelineStartMs = AnytimeHistoryPolicy.restoredTimelineStartMs(
            persistedTimelineStartMs: state.timelineStartMs,
            persistedSensorStartMs: state.sensorStartMs,
            persistedLastGlucoseId: state.lastGlucoseId
        )
        warmupStartedAtMs = state.warmupStartedAtMs
        if let date = state.lastReadingDate {
            lastGlucoseAtMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        lastMgdl = state.lastMgdl
        lastWasEstimate = state.lastWasEstimate
        iwNa = state.iwNa
        ibNa = state.ibNa
        temperatureC = state.temperatureC
        ceVoltageMv = state.ceVoltageMv
        if let scale = state.rawScale {
            ct5RawScale.restore(scale: scale, samples: state.rawScaleSamples)
        }
        if let calibratorState = state.calibrator, let k0 = state.calibratorK0, k0 > 0 {
            algorithmSession.restoreCalibrator(k0: k0, state: calibratorState)
        }
        ct5PendingGapFromId = state.pendingGapFromId
        ct5PendingGapStopBeforeId = state.pendingGapStopBeforeId
        ct5ResolvedIds = Set(state.resolvedIds)
        ct5SkippedIds = Set(state.skippedIds)
        if let failure = state.gapFailure {
            ct5GapFailureTracker = AnytimeCt5GapFailureTracker(maxFailedSessions: Self.ct5GapMaxFailedSessions, restored: failure)
        }
        if let secrets = AnytimeCt5SecretStore.load(address: address) {
            ct5CipherKey = secrets.cipherKey
            ct5RandomB = secrets.randomB
            ct5TempId = secrets.tempId ?? ""
        }
        restoredGlucoseState = lastGlucoseId >= 0
    }

    private func applyName(_ name: String?) {
        familyEntry = AnytimeFamilies.resolve(name)
        profile = AnytimeProfileResolver.resolve(name)
    }

    private func nowMs() -> Int64 { return anytimeNowMs() }

    // MARK: - delayed jobs

    private func schedule(_ name: TimerName, after delay: TimeInterval, _ block: @escaping () -> Void) {
        let generation = connectionGeneration
        let token = (timerTokens[name] ?? 0) + 1
        timerTokens[name] = token
        runOnCentralQueue(after: delay) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation, self.timerTokens[name] == token else { return }
            block()
        }
    }

    private func cancel(_ name: TimerName) {
        timerTokens[name] = (timerTokens[name] ?? 0) + 1
    }

    // MARK: - connection lifecycle

    override func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // a stored address matches exactly
        if deviceAddress != nil {
            super.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
            return
        }

        // first connection: the first advertisement whose name belongs to a family this driver can run
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard Self.isSupportedName(name) else { return }
        discoveredAdvertisedName = name
        logLine("in didDiscover, Anytime candidate found, rssi \(RSSI.intValue)")
        connectToDiscoveredPeripheral(peripheral)
    }

    /// CT2, CT4 and CT5 names; the other generations are not driven (see the file header).
    private static func isSupportedName(_ name: String?) -> Bool {
        guard AnytimeFamilies.isAnytimeDevice(name) else { return false }
        return isSupportedFamily(AnytimeFamilies.resolve(name).family)
    }

    private static func isSupportedFamily(_ family: AnytimeFamily) -> Bool {
        return family == .ct2 || family == .ct4 || family == .ct5
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetConnectionState()
        restoreStateIfNeeded()
        connectMode.onConnected(usedAutoConnect: false)
        ct5HistoryHealth.onLinkSessionStarted()
        super.centralManager(central, didConnect: peripheral)
    }

    override func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // CoreBluetooth has no connect timeout; a failed attempt is the closest thing and counts as one
        connectMode.onDisconnected(status: AnytimeConnectPolicy.connectionTimeoutStatus, wasConnecting: true)
        super.centralManager(central, didFailToConnect: peripheral, error: error)
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !problemNotedOnThisLink, phase != .streaming || error != nil {
            noteProblem(.linkLost)
        }
        recordSessionOutcome()
        connectMode.onDisconnected(status: 0, wasConnecting: false)
        if history != nil, isCt5 {
            rememberInterruptedHistory()
        }
        invalidateConnection()
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func reconnectAfterDisconnect(_ central: CBCentralManager) {
        guard !released else { return }
        let connectDelay = connectMode.retryDelayMs(baseDelayMs: Self.activeSessionReconnectDelayMs, readingIntervalMs: intervalMs)
        let sessionDelay = sessionChurn.retryDelayMs(baseDelayMs: Self.activeSessionReconnectDelayMs)
        let wait = min(Double(max(connectDelay, sessionDelay)) / 1000, Self.maxReconnectDelay)
        logLine("in reconnectAfterDisconnect, reconnecting in \(wait) s (failed sessions \(sessionChurn.consecutiveFailedSessions), connect timeouts \(connectMode.consecutiveConnectTimeouts))")
        runOnCentralQueue(after: wait) { [weak self] in
            guard let self = self, !self.released else { return }
            self.performReconnect(central)
        }
    }

    private func performReconnect(_ central: CBCentralManager) {
        super.reconnectAfterDisconnect(central)
    }

    override func prepareForRelease() {
        runOnCentralQueue { [weak self] in
            self?.released = true
            self?.invalidateConnection()
        }
        super.prepareForRelease()
    }

    /// Any decoded frame from the sensor proves this session is usable.
    private func noteSessionSensorData() {
        sessionDeliveredData = true
        sessionChurn.onSessionDeliveredData()
    }

    /// Recorded once per session: a deliberate disconnect and the stack's own callback both lead here.
    private func recordSessionOutcome() {
        if sessionOutcomeRecorded { return }
        sessionOutcomeRecorded = true
        sessionChurn.onSessionEnded(deliveredData: sessionDeliveredData)
    }

    private func invalidateConnection() {
        connectionGeneration += 1
        writeQueue.removeAll()
        activeWrite = nil
        writeInFlight = false
        protocolResponseInFlight = false
        protocolResponseRequestOpcode = 0
        lastProtocolFrameTag = ""
        history = nil
        deliveryBuffer.removeAll()
        phase = .connecting
    }

    private func resetConnectionState() {
        invalidateConnection()
        characteristics.removeAll()
        notifyCharacteristic = nil
        commandCharacteristic = nil
        legacyLayout = false
        sessionBegun = false
        problemNotedOnThisLink = false
        sessionDeliveredData = false
        sessionOutcomeRecorded = false
        streamingSinceMs = 0
        ct5ReconnectDateAfterIdentity = false
        ct5RandomA = nil
        ct5SingleRecordHistoryOnly = false
        legacySeriesHistorySupported = true
        telemetryLivePushesUntilCheck = -1
        pendingGapFromId = -1
        pendingGapStopBeforeId = -1
        caughtUpCooldown.clear()
    }

    /// Ends the link and lets the base class reconnect after the back-off (JugglucoNG `recoverGattAndReconnect`).
    private func recoverAndReconnect(_ reason: String, problem: AnytimeLinkProblem?) {
        logLine("in recoverAndReconnect, \(reason)")
        if let problem = problem { noteProblem(problem) }
        disconnect()
    }

    // MARK: - service and characteristic discovery

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)

        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }

        // the session starts when every discovered service has reported its characteristics
        guard let services = peripheral.services, !services.isEmpty,
              services.allSatisfy({ $0.characteristics != nil }) else { return }
        servicesDiscovered()
    }

    private func servicesDiscovered() {
        guard !sessionBegun else { return }

        if let notify = characteristics[AnytimeGATT.primaryNotify], let write = characteristics[AnytimeGATT.primaryWrite] {
            notifyCharacteristic = notify
            commandCharacteristic = write
            legacyLayout = false
        } else if let notify = characteristics[AnytimeGATT.legacyNotify], let write = characteristics[AnytimeGATT.legacyWrite] {
            notifyCharacteristic = notify
            commandCharacteristic = write
            legacyLayout = true
        } else {
            // a device that matched by name but has no Anytime service: stop connecting to it
            noteProblem(.notAnAnytime)
            disconnectAndForget()
            return
        }
        sessionBegun = true

        // the connect-time name wins over the cached one, and a classifying name is kept for the next start
        let resolvedName = AnytimeFamilies.resolveHandshakeName(
            cachedName: advertisedName,
            connectedName: deviceName,
            activeName: discoveredAdvertisedName,
            serial: nil
        )
        let nameFamily = AnytimeFamilies.resolve(resolvedName)
        if nameFamily.family != .unknown {
            advertisedName = resolvedName
            familyEntry = nameFamily
        } else if legacyLayout, let ct2 = AnytimeFamilies.table.first(where: { $0.family == .ct2 }) {
            // the 16-bit service is CT2 only, so it beats a name that resolved to nothing
            familyEntry = ct2
        } else {
            familyEntry = nameFamily
        }
        profile = AnytimeProfileResolver.resolve(nameFamily.family != .unknown ? resolvedName : familyEntry.prefix)
        handshakeName = resolvedName
        logLine("in servicesDiscovered, family \(familyEntry.family.rawValue), layout \(legacyLayout ? "legacy" : "primary")")

        guard Self.isSupportedFamily(familyEntry.family) else {
            noteProblem(.unsupportedFamily)
            persistState()
            disconnectAndForget()
            return
        }
        persistState()

        guard let notify = notifyCharacteristic else { return }
        if notify.isNotifying {
            beginHandshake("notifications already on")
            return
        }
        if legacyLayout {
            // the base class only switches the primary layout's notification on
            setNotifyValue(true, for: notify)
        }
        schedule(.notifyFallback, after: Self.notifyFallbackDelay) { [weak self] in
            guard let self = self, self.phase == .connecting else { return }
            self.logLine("in notification wait, no confirmation; starting the handshake anyway")
            self.beginHandshake("notification confirmation missing")
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)

        guard let notify = notifyCharacteristic, characteristic.uuid == notify.uuid else { return }
        if error != nil {
            recoverAndReconnect("notification could not be switched on", problem: .handshakeStalled)
            return
        }
        if characteristic.isNotifying && phase == .connecting {
            beginHandshake("notifications on")
        }
    }

    // MARK: - frames of the three families

    private func checkFrame() -> [UInt8] {
        return isCt2 ? AnytimeFrames.Builders.ct2Check() : AnytimeFrames.Builders.checkSummed()
    }

    private func initFrame() -> [UInt8] {
        return isCt2 ? AnytimeFrames.Builders.ct2Init() : AnytimeFrames.Builders.initSummed()
    }

    private func lowPowerFrame() -> [UInt8] {
        return isCt2 ? AnytimeFrames.Builders.ct2LowPower() : AnytimeFrames.Builders.lowPowerSummed()
    }

    private func resetFrame() -> [UInt8] {
        return AnytimeFrames.Builders.resetSummed()
    }

    /// CT2 sets the date, CT5 asks for it (the same answer opcode), CT4 sets it with a summed frame.
    private func setDateFrame() -> [UInt8] {
        if isCt2 { return AnytimeFrames.Builders.ct2SetDate() }
        if isCt5 { return AnytimeFrames.Builders.ct5GetDate() }
        return AnytimeFrames.Builders.setDateSummed()
    }

    private func transmitterFormalFrame() -> [UInt8] {
        return AnytimeFrames.Builders.transmitterFormalSummed()
    }

    /// Only CT4 answers the batched 0x22 pull, and only until it once timed out on this link.
    private var supportsLegacySeriesHistory: Bool {
        return legacySeriesHistorySupported && isCt4
    }

    private func pullGlucoseFrame(_ nextId: Int, count: Int = 1) -> [UInt8] {
        if isCt2 { return AnytimeFrames.Builders.ct2PullGlucose(nextId) }
        if isCt5 { return AnytimeFrames.Builders.ct5PullGlucoseSeries(nextId, count: max(count, 1)) }
        if count > 1 && supportsLegacySeriesHistory {
            return AnytimeFrames.Builders.pullGlucoseSeriesSummed(nextId, count: count)
        }
        return AnytimeFrames.Builders.pullGlucoseSummed(nextId)
    }

    private func historyPullCount(_ nextId: Int) -> Int {
        // 0x37 carries an explicit count, so a two-record gap asks for two records
        if isCt5 && ct5SingleRecordHistoryOnly { return 1 }
        if !isCt5 && !supportsLegacySeriesHistory { return 1 }
        let stopRemaining = max((history?.stopBeforeId ?? AnytimeHistoryPolicy.unbounded) - nextId, 1)
        return min(Self.historyPullSeriesCount, stopRemaining)
    }

    // MARK: - the write slot

    @discardableResult
    private func writeFrame(_ bytes: [UInt8]?, tag: String, expectResponse: Bool = true, secret: Bool = false) -> Bool {
        guard let bytes = bytes, !bytes.isEmpty else {
            logLine("in writeFrame, \(tag) skipped: no frame", type: .error)
            return false
        }
        guard commandCharacteristic != nil else { return false }
        let pending = PendingWrite(
            bytes: bytes,
            tag: tag,
            expectResponse: expectResponse,
            priority: AnytimeHistoryPolicy.writePriority(tag: tag, historyReason: history?.reason ?? ""),
            secret: secret
        )
        // ordered by priority, first in first out inside one priority
        if let index = writeQueue.firstIndex(where: { $0.priority.rawValue > pending.priority.rawValue }) {
            writeQueue.insert(pending, at: index)
        } else {
            writeQueue.append(pending)
        }
        drainWriteQueue()
        return true
    }

    private func drainWriteQueue() {
        guard !released, commandCharacteristic != nil else { return }
        if writeInFlight || protocolResponseInFlight || writeQueue.isEmpty { return }
        let pending = writeQueue.removeFirst()
        guard let characteristic = commandCharacteristic else {
            handleDroppedWrite(pending, reason: "write characteristic unavailable", recoverControlWrite: false)
            return
        }
        let withResponse = characteristic.properties.contains(.write)
        activeWrite = pending
        writeInFlight = true
        let sent = writeDataToPeripheral(
            data: Data(pending.bytes),
            characteristicToWriteTo: characteristic,
            type: withResponse ? .withResponse : .withoutResponse,
            logPayload: !pending.secret
        )
        guard sent else {
            writeInFlight = false
            activeWrite = nil
            handleDroppedWrite(pending, reason: "write refused (\(pending.tag))", recoverControlWrite: phase == .handshaking)
            return
        }
        if withResponse {
            // the confirmation releases the slot; the timer only guards against one that never comes
            schedule(.writeStale, after: Self.writeStaleSeconds) { [weak self] in
                guard let self = self, self.writeInFlight else { return }
                self.logLine("in writeStale, no write confirmation for \(pending.tag)", type: .error)
                self.writeInFlight = false
                let stale = self.activeWrite
                self.activeWrite = nil
                if let stale = stale {
                    self.handleDroppedWrite(stale, reason: "write callback timed out", recoverControlWrite: !AnytimeHistoryPolicy.isBackfillWriteTag(stale.tag))
                }
                self.drainWriteQueue()
            }
        } else {
            schedule(.writeSpacing, after: Self.writeNoResponseSpacing) { [weak self] in
                guard let self = self else { return }
                self.writeInFlight = false
                self.activeWrite = nil
                self.drainWriteQueue()
            }
        }
        let historyWrite = AnytimeHistoryPolicy.isBackfillWriteTag(pending.tag)
        if historyWrite {
            armHistoryPullTimeout()
        }
        if pending.expectResponse {
            protocolResponseInFlight = true
            protocolResponseRequestOpcode = pending.bytes[0]
            if !historyWrite { armProtocolFrameTimeout(pending.tag) }
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didWriteValueFor: characteristic, error: error)

        guard let command = commandCharacteristic, characteristic.uuid == command.uuid else { return }
        let completed = activeWrite
        writeInFlight = false
        activeWrite = nil
        cancel(.writeStale)
        if error != nil, let completed = completed {
            handleDroppedWrite(completed, reason: "write failed (\(completed.tag))", recoverControlWrite: phase == .handshaking)
        }
        drainWriteQueue()
    }

    private func handleDroppedWrite(_ pending: PendingWrite, reason: String, recoverControlWrite: Bool) {
        logLine("in handleDroppedWrite, dropping \(pending.tag): \(reason)", type: .error)
        if pending.expectResponse, !pending.bytes.isEmpty, protocolResponseRequestOpcode == pending.bytes[0] {
            releaseProtocolResponseSlot(nil)
        }
        if AnytimeHistoryPolicy.isBackfillWriteTag(pending.tag) {
            cancel(.historyPullTimeout)
            history?.pullInFlight = false
            history?.pullInFlightCount = 0
            history?.pullIsSeries = false
            if history != nil && phase == .streaming {
                scheduleHistoryStep()
            }
        } else if recoverControlWrite && !released {
            recoverAndReconnect(reason, problem: .protocolTimeout)
        }
    }

    @discardableResult
    private func releaseProtocolResponseSlot(_ responseOpcode: UInt8?) -> Bool {
        if !protocolResponseInFlight { return false }
        if let responseOpcode = responseOpcode,
           !AnytimeHistoryPolicy.responseMatchesRequest(requestOpcode: protocolResponseRequestOpcode, responseOpcode: responseOpcode) {
            return false
        }
        protocolResponseInFlight = false
        protocolResponseRequestOpcode = 0
        clearProtocolFrameTimeout()
        drainWriteQueue()
        return true
    }

    private func armProtocolFrameTimeout(_ tag: String) {
        lastProtocolFrameTag = tag
        lastProtocolFrameAtMs = nowMs()
        schedule(.protocolTimeout, after: Self.protocolFrameTimeout) { [weak self] in
            self?.protocolFrameTimedOut()
        }
    }

    private func clearProtocolFrameTimeout() {
        cancel(.protocolTimeout)
        lastProtocolFrameTag = ""
    }

    private func protocolFrameTimedOut() {
        let tag = lastProtocolFrameTag
        releaseProtocolResponseSlot(nil)
        logLine("Protocol timeout after \(tag)", type: .error)
        if AnytimeHistoryPolicy.isBackfillWriteTag(tag) {
            history?.pullInFlight = false
            if history != nil && phase == .streaming {
                scheduleHistoryStep()
            }
            return
        }
        if tag.hasPrefix("setDate") || tag.hasPrefix("ct2-setDate") {
            logLine("setDate ACK timeout; keeping the link alive")
            clearProtocolFrameTimeout()
            return
        }
        if tag.hasPrefix("init(after-setDate") || tag.hasPrefix("ct2-init") {
            logLine("init ACK timeout after best-effort setDate; keeping the link alive and waiting for a raw push")
            clearProtocolFrameTimeout()
            return
        }
        guard phase == .handshaking else { return }
        if handleCt5ProtocolTimeout(tag) { return }
        recoverAndReconnect("protocol timeout after \(tag)", problem: .protocolTimeout)
    }

    /// A CT5 that already holds its cipher skips a handshake step that stays unanswered and waits for the
    /// encrypted live push instead.
    private func handleCt5ProtocolTimeout(_ tag: String) -> Bool {
        guard isCt5 else { return false }
        if tag.hasPrefix("ct5-getDate(fresh") && !hasCt5Cipher {
            logLine("CT5 fresh getDate timed out; keeping the link alive for an encrypted live push")
            clearProtocolFrameTimeout()
            return true
        }
        if tag.hasPrefix("ct5-getDate") && hasCt5Cipher {
            logLine("CT5 \(tag) timed out; using the cached cipher and waiting for an encrypted live push")
            enterStreaming("CT5 date timeout with cached cipher")
            return true
        }
        if (tag.hasPrefix("ct5-checkID") || tag.hasPrefix("ct5-init")) && hasCt5Cipher {
            logLine("CT5 \(tag) timed out; using the cached cipher and waiting for an encrypted live push")
            enterStreaming("CT5 identity or init timeout with cached cipher")
            return true
        }
        return false
    }

    // MARK: - handshake

    private func beginHandshake(_ reason: String) {
        guard phase == .connecting, !released else { return }
        cancel(.notifyFallback)
        phase = .handshaking
        logLine("Starting the Anytime handshake (\(reason)), family \(familyEntry.family.rawValue)")

        // One cadence plus a margin leaves room for the deliberate "wait for an encrypted live push"
        // recoveries; a step that rejects its answer would otherwise leave the link hanging.
        let stall = Double(profile.readingIntervalMinutes) * 60 + 60
        schedule(.handshakeStall, after: stall) { [weak self] in
            guard let self = self, self.phase == .handshaking else { return }
            self.recoverAndReconnect("handshake stalled for \(Int(stall)) s", problem: .handshakeStalled)
        }

        if isCt2 {
            sendCt2Handshake()
        } else if isCt5 {
            if bound {
                if let randomB = ct5RandomB, randomB.count == 4, hasCt5Cipher {
                    writeFrame(AnytimeFrames.Builders.ct5CheckId(randomB: randomB), tag: "ct5-checkID", secret: true)
                } else if hasCt5Cipher {
                    logLine("CT5 bound session has a cached cipher only; waiting for the encrypted live stream")
                    enterStreaming("CT5 cached cipher restored")
                } else {
                    logLine("CT5 bound session lacks identity material; asking for the date and keeping live-push recovery open")
                    writeFrame(setDateFrame(), tag: "ct5-getDate(fresh)")
                }
            } else if hasCt5Cipher {
                logLine("CT5 cached cipher found; waiting for the encrypted live stream")
                bound = true
                enterStreaming("CT5 cached cipher available")
            } else {
                logLine("CT5 getDate / check / setID / querySSN handshake")
                writeFrame(setDateFrame(), tag: "ct5-getDate(fresh)")
            }
        } else if bound {
            logLine("CT4 already bound; asking the transmitter to confirm the session")
            writeFrame(resetFrame(), tag: "reset")
        } else if isCt4VoltageOne() {
            logLine("CT4 voltage mode 1; skipping the formal voltage switch and sending check")
            writeFrame(checkFrame(), tag: "check(ct4-voltage1)")
        } else {
            writeFrame(transmitterFormalFrame(), tag: "transmitterFormal")
        }
    }

    private func isCt4VoltageOne() -> Bool {
        return isCt4 && ((qr?.voltageFlag ?? voltageFlag) == 1)
    }

    /// CT2 handshake: the transmitter's own advertised name.
    private func sendCt2Handshake() {
        let name = handshakeName.isEmpty ? (deviceName ?? "") : handshakeName
        if name.isEmpty {
            logLine("CT2 handshake has no device name to send", type: .error)
            writeFrame(checkFrame(), tag: "check(ct2-no-name)")
            return
        }
        writeFrame(AnytimeFrames.Builders.ct2Handshake(deviceName: name), tag: "ct2-handshake")
    }

    // MARK: - receive

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let notify = notifyCharacteristic, characteristic.uuid == notify.uuid,
              error == nil, let value = characteristic.value, !value.isEmpty else {
            super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
            return
        }
        let bytes = [UInt8](value)

        // the identity frames of the CT5 bind carry the session key material and the sensor code: the base
        // class traces every value, so these do not go through it
        let identityFrame = isCt5 && [
            AnytimeOpcode.txCt5SetId, AnytimeOpcode.rxCt5CheckId,
            AnytimeOpcode.rxCt5SetParameters, AnytimeOpcode.rxCt5QuerySsn
        ].contains(bytes[0])
        if identityFrame {
            requestSignalStrengthForTraceIfNeeded(from: peripheral)
        } else {
            super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
        }

        handleFrame(bytes)
    }

    private func handleFrame(_ bytes: [UInt8]) {
        let opcode = bytes[0]
        releaseProtocolResponseSlot(opcode)
        dispatch(opcode, bytes)
        drainWriteQueue()
    }

    private func dispatch(_ opcode: UInt8, _ data: [UInt8]) {
        if isCt5 && dispatchCt5(opcode, data) { return }
        // the CT-14 (CT2 family) has its own opcode namespace and never falls through to the generic table
        if isCt2 {
            if !dispatchCt14(opcode, data) {
                logLine("Unhandled CT-14 opcode \(String(format: "0x%02X", Int(opcode))), \(data.count) bytes", type: .debug)
            }
            return
        }
        switch opcode {
        case AnytimeOpcode.rxVersion:
            logLine("RX 0x01 version", type: .debug)
        case AnytimeOpcode.rxSetDateAckA, AnytimeOpcode.rxSetDateAckB:
            if phase == .handshaking {
                writeFrame(initFrame(), tag: "init")
            }
        case AnytimeOpcode.rxCheck:
            handleCheckResponse(data)
        case AnytimeOpcode.rxInit:
            enterStreaming("Init OK")
        case AnytimeOpcode.rxPushGlucose:
            handleGlucoseFrame(data, push: true)
        case AnytimeOpcode.rxPullGlucose, AnytimeOpcode.rxSeries:
            handleGlucoseFrame(data, push: false)
        case AnytimeOpcode.rxLegacyRawDump:
            handleGlucoseFrame(data, push: false)
        case AnytimeOpcode.rxReset:
            handleResetResponse(data)
        case AnytimeOpcode.rxModifyVoltage:
            handleVoltageAck(data)
        case AnytimeOpcode.rxTransmitterFormal:
            handleFormalVersion(data)
        case AnytimeOpcode.rxLowPowerAck:
            break
        default:
            logLine("Unhandled opcode \(String(format: "0x%02X", Int(opcode))), \(data.count) bytes", type: .debug)
        }
    }

    /// CT-14 (CT2 family) responses; false when the opcode is not ours.
    private func dispatchCt14(_ opcode: UInt8, _ data: [UInt8]) -> Bool {
        guard AnytimeConstants.isCt14Opcode(opcode) else { return false }
        switch opcode {
        case AnytimeOpcode.rxCt2HandshakeAck:
            guard phase == .handshaking else { return true }
            writeFrame(setDateFrame(), tag: "ct2-setDate")
        case AnytimeOpcode.rxCt2SetDateAck:
            guard phase == .handshaking else { return true }
            writeFrame(initFrame(), tag: "ct2-init")
        case AnytimeOpcode.rxCt2InitAck:
            guard phase == .handshaking else { return true }
            enterStreaming("CT2 init ack")
        case AnytimeOpcode.rxCt2PushGlucose:
            handleCt2GlucoseFrame(data, historical: false)
        case AnytimeOpcode.rxCt2PullResponse:
            handleCt2GlucoseFrame(data, historical: true)
        default:
            break
        }
        return true
    }

    /// CT5 responses; false when the opcode is not a CT5 one.
    private func dispatchCt5(_ opcode: UInt8, _ data: [UInt8]) -> Bool {
        if opcode == AnytimeOpcode.rxCt5PushGlucose || opcode == AnytimeOpcode.rxCt5Series {
            ct5LastDataRxAtMs = nowMs()
        }
        switch opcode {
        case AnytimeOpcode.rxSetDateAckA, AnytimeOpcode.rxSetDateAckB:
            handleCt5DateResponse(data)
        case AnytimeOpcode.rxCheck:
            handleCt5CheckResponse(data)
        case AnytimeOpcode.txCt5SetId:
            handleCt5SetIdResponse(data)
        case AnytimeOpcode.rxCt5CheckId:
            handleCt5CheckIdResponse(data)
        case AnytimeOpcode.rxCt5PushGlucose:
            handleCt5CurrentGlucose(data)
        case AnytimeOpcode.rxCt5Series:
            handleCt5Series(data)
        case AnytimeOpcode.rxCt5SetParameters:
            handleCt5SetParametersResponse(data)
        case AnytimeOpcode.rxCt5QuerySsn:
            handleCt5QuerySsnResponse(data)
        case AnytimeOpcode.rxInit:
            enterStreaming("Init OK")
        case AnytimeOpcode.rxLowPowerAck, AnytimeOpcode.rxInputBgAck, AnytimeOpcode.rxUnbindAck,
             AnytimeOpcode.rxReset, AnytimeOpcode.rxUnbindAckGeneric:
            // acknowledgements of commands this driver never sends, or a bind state nobody asked for
            logLine("CT5 acknowledgement \(String(format: "0x%02X", Int(opcode))) ignored", type: .debug)
        default:
            return false
        }
        return true
    }

    // MARK: - CT4 handshake handlers

    private func handleFormalVersion(_ data: [UInt8]) {
        let version = AnytimeFrames.parseFormalVersion(data)
        if !version.isEmpty {
            transmitterVersion = version
            logLine("Transmitter version: \(version)")
            persistState()
        }
        // vendor firmware branches V13xx / V14xx need the voltage mode of the sensor code
        let needsVoltageSwitch = version.range(of: "V1[34][0-9]{2}", options: [.regularExpression, .caseInsensitive]) != nil
        if isCt4VoltageOne() {
            logLine("CT4 voltage mode 1; skipping modifyVoltage after the formal version")
            writeFrame(checkFrame(), tag: "check(ct4-voltage1-post-formal)")
            return
        }
        if needsVoltageSwitch, let qr = qr {
            voltageFlag = qr.voltageFlag
            writeFrame(AnytimeFrames.Builders.modifyVoltage(voltageFlag), tag: "modifyVoltage(\(voltageFlag))")
        } else {
            writeFrame(checkFrame(), tag: "check")
        }
    }

    private func handleVoltageAck(_ data: [UInt8]) {
        guard phase == .handshaking else { return }
        writeFrame(checkFrame(), tag: "check(post-voltage)")
    }

    private func handleCheckResponse(_ data: [UInt8]) {
        let status = AnytimeFrames.parseCheckResponse(data, lowBatteryThresholdVolts: profile.lowBatteryVolts)
        if status.batteryVolts > 0 {
            batteryVolts = status.batteryVolts
            let percent = AnytimeFrames.batteryPercent(volts: status.batteryVolts, lowThresholdVolts: profile.lowBatteryVolts)
            if percent >= 0 { batteryPercent = percent }
        }
        if status.workingElectrodeCurrentNa > 0 { iwNa = status.workingElectrodeCurrentNa }
        if status.failure == .lowBattery { noteProblem(.lowBattery) }
        persistState()
        if phase != .handshaking {
            armTelemetryCheck(Self.telemetryCheckInterval)
            return
        }
        if !status.isHealthy {
            logLine("Check failed: \(String(describing: status.failure))", type: .error)
            noteProblem(.checkMalformed)
            return
        }
        logLine("Check OK (battery \(status.batteryVolts) V, working electrode \(status.workingElectrodeCurrentNa) nA)")
        // Some CT4 transmitters do not reliably ACK setDate. Send it as a best-effort clock update, then
        // carry on with init without arming an init timeout; otherwise the link is dropped just before the
        // next raw push arrives.
        writeFrame(setDateFrame(), tag: "setDate", expectResponse: false)
        schedule(.postInit, after: 0.25) { [weak self] in
            guard let self = self, self.phase == .handshaking, !self.lastProtocolFrameTag.hasPrefix("init") else { return }
            self.writeFrame(self.initFrame(), tag: "init(after-setDate-best-effort)", expectResponse: false)
            self.schedule(.initGrace, after: Self.initNoAckStreamingGrace) { [weak self] in
                guard let self = self, self.phase == .handshaking else { return }
                if self.hasUsableHistoryTimeline() || self.lastGlucoseId >= 0 {
                    self.enterStreaming("Init sent without ACK")
                } else {
                    self.logLine("Init ACK missing and no cached timeline; waiting for the first live push")
                }
            }
        }
    }

    private func handleResetResponse(_ data: [UInt8]) {
        guard let parsed = AnytimeFrames.parseResetResponse(data) else {
            recoverAndReconnect("reset response malformed", problem: .protocolTimeout)
            return
        }
        logLine("Reset response: bound=\(parsed.isBound)")
        bound = parsed.isBound
        persistState()
        if parsed.isBound {
            // the sensor confirms the session is alive: stream, and pull what was missed while away
            beginStreamingPhase()
            writeFrame(lowPowerFrame(), tag: "lowPower(post-reset)", expectResponse: false)
            armPullFallback()
            armNoDataWatchdog()
            requestTelemetryAfterReconnectLivePushes()
            schedule(.reconnectBackfill, after: 0.5) { [weak self] in
                guard let self = self, self.phase == .streaming else { return }
                self.startHistoryBackfill("post-reset(reconnect)", fromId: self.reconnectBackfillStartId(), stopBeforeId: self.cappedStop(from: self.reconnectBackfillStartId()))
            }
        } else {
            // the sensor lost the binding: fall through to a fresh handshake
            writeFrame(checkFrame(), tag: "check(post-reset)")
        }
    }

    // MARK: - CT5 handshake handlers

    private func generateCt5TempId() -> String {
        let generated = String(1000 + Int.random(in: 0..<9000))
        ct5TempId = generated
        return generated
    }

    private func randomBytes() -> [Int] {
        return (0..<4).map { _ in Int.random(in: 0..<256) }
    }

    private func handleCt5DateResponse(_ data: [UInt8]) {
        guard AnytimeFrames.verifySum(data) else {
            logLine("Bad CT5 date response", type: .error)
            return
        }
        guard phase == .handshaking else { return }
        if ct5ReconnectDateAfterIdentity && bound && hasCt5Cipher {
            ct5ReconnectDateAfterIdentity = false
            enterStreaming("CT5 reconnect date OK")
        } else {
            ct5ReconnectDateAfterIdentity = false
            writeFrame(checkFrame(), tag: "ct5-check")
        }
    }

    private func handleCt5CheckResponse(_ data: [UInt8]) {
        guard phase == .handshaking else { return }
        guard data.count == 20, AnytimeFrames.verifySum(data) else {
            logLine("Bad CT5 check response", type: .error)
            return
        }
        _ = generateCt5TempId()
        let randomA = randomBytes()
        let randomB = randomBytes()
        ct5RandomA = randomA
        ct5RandomB = randomB
        logLine("CT5 check OK; sending setID")
        writeFrame(AnytimeFrames.Builders.ct5SetId(randomA: randomA, randomB: randomB), tag: "ct5-setID", secret: true)
    }

    private func handleCt5SetIdResponse(_ data: [UInt8]) {
        guard let randomA = ct5RandomA, randomA.count == 4 else {
            logLine("CT5 setID response without randomA", type: .error)
            return
        }
        let key = AnytimeFrames.ct5SessionKey(fromSetIdResponse: data, randomA: randomA)
        guard (0...255).contains(key) else {
            logLine("CT5 setID failed", type: .error)
            return
        }
        ct5CipherKey = key
        persistSecrets()
        persistState()
        logLine("CT5 session cipher established")
        writeFrame(AnytimeFrames.Builders.ct5QuerySsn(), tag: "ct5-querySSN", secret: true)
    }

    private func handleCt5CheckIdResponse(_ data: [UInt8]) {
        let ok = data.count >= 6
            && data[0] == AnytimeOpcode.rxCt5CheckId
            && AnytimeFrames.verifySum(data)
            && data[5] == 1
        if ok {
            logLine("CT5 identity check OK")
            ct5ReconnectDateAfterIdentity = true
            writeFrame(setDateFrame(), tag: "ct5-getDate(reconnect)")
            return
        }
        ct5ReconnectDateAfterIdentity = false
        if hasCt5Cipher {
            logLine("CT5 identity check failed; keeping the cached cipher and waiting for the encrypted live stream", type: .error)
            bound = true
            persistState()
            enterStreaming("CT5 cached cipher after identity failure")
        } else {
            logLine("CT5 identity check failed without a cached cipher; restarting the fresh handshake", type: .error)
            bound = false
            ct5RandomB = nil
            persistState()
            writeFrame(setDateFrame(), tag: "ct5-getDate(fresh-after-checkID)")
        }
    }

    private func handleCt5QuerySsnResponse(_ data: [UInt8]) {
        guard hasCt5Cipher else {
            logLine("CT5 querySSN response before the cipher key", type: .error)
            return
        }
        let key = ct5CipherKey
        let decoded = AnytimeFrames.parseCt5QuerySsnResponse(data, cipherKey: key) ?? ""
        var candidates = [String]()
        func add(_ text: String) {
            if !text.isEmpty && !candidates.contains(text) { candidates.append(text) }
        }
        add(decoded)
        add(decoded.filter { $0.isLetter || $0.isNumber })
        if data.count > 2 {
            let noSumBytes = AnytimeFrames.trimNonPrintable(AnytimeFrames.ct5Encode(Array(data[1..<(data.count - 1)]), cipherKey: key))
            let noSum = String(decoding: noSumBytes, as: UTF8.self)
            add(noSum)
            add(noSum.filter { $0.isLetter || $0.isNumber })
        }
        let parsed = candidates.lazy.compactMap { AnytimeQr.parse($0) }.first
        if let parsed = parsed {
            qr = parsed
            voltageFlag = parsed.voltageFlag
            logLine("CT5 sensor code decoded from the transmitter: K=\(parsed.k) R=\(parsed.r) life=\(parsed.lifeTime) d")
            persistState()
        } else {
            logLine("CT5 querySSN did not decode with the local parser", type: .error)
        }
        let calibration = parsed ?? AnytimeQr.ct5SetupCalibration(stored: qr, voltageFlag: voltageFlag)
        if parsed == nil && calibration != qr {
            // without K/R the bind cannot finish: the CT5 default stands in until a code is known
            qr = calibration
            persistState()
            logLine("CT5 SSN gave no K/R; using the default K=\(calibration.k) R=\(calibration.r)", type: .error)
        }
        if ct5TempId.isEmpty { _ = generateCt5TempId() }
        persistSecrets()
        writeFrame(
            AnytimeFrames.Builders.ct5SetParameters(k: calibration.k, r: calibration.r, cipherKey: key, tempId: ct5TempId),
            tag: "ct5-setParameters",
            secret: true
        )
    }

    private func handleCt5SetParametersResponse(_ data: [UInt8]) {
        guard data.count == 14, AnytimeFrames.verifySum(data) else {
            logLine("Bad CT5 setParameters response", type: .error)
            return
        }
        guard phase == .handshaking else { return }
        logLine("CT5 K/R parameters accepted")
        writeFrame(initFrame(), tag: "ct5-init")
    }

    // MARK: - streaming

    /// The part of entering the streaming phase that every path shares.
    private func beginStreamingPhase() {
        phase = .streaming
        streamingSinceMs = nowMs()
        clearProtocolFrameTimeout()
        cancel(.handshakeStall)
        cancel(.postInit)
        cancel(.initGrace)
    }

    private func enterStreaming(_ reason: String) {
        guard phase != .streaming else { return }
        logLine("\(reason); entering streaming")
        bound = true
        beginStreamingPhase()
        cancel(.ct5Unproven)
        if isCt5 && lastGlucoseId < 0 {
            let wait = 2 * Double(profile.readingIntervalMinutes) * 60 + 60
            schedule(.ct5Unproven, after: wait) { [weak self] in
                self?.ct5UnprovenCipherFired(wait)
            }
        }
        persistState()
        writeFrame(lowPowerFrame(), tag: "lowPower", expectResponse: false)
        armPullFallback()
        armNoDataWatchdog()
        armTelemetryCheck(Self.telemetryCheckInterval)

        // Restored sessions resume any durable repair cursor. A fresh CT5 starts its bounded recent import
        // after the first real live anchor.
        if isCt5 {
            schedule(.gapResume, after: 0.75) { [weak self] in
                guard let self = self, self.phase == .streaming, self.history == nil else { return }
                if !self.maybeResumePendingCt5Gap() {
                    self.maybeStartCt5ReconnectCatchup()
                }
            }
        } else if hasUsableHistoryTimeline() && lastGlucoseId >= 0 {
            schedule(.postInit, after: 0.75) { [weak self] in
                guard let self = self, self.phase == .streaming else { return }
                let from = self.reconnectBackfillStartId()
                self.startHistoryBackfill("post-init", fromId: from, stopBeforeId: self.cappedStop(from: from))
            }
        } else {
            logLine("Fresh Anytime session has no live timeline yet; waiting for the first live push before history")
        }
    }

    /// A cached cipher is a bet that the transmitter is already bound. A CT5 that never sent a frame in two
    /// cadences of streaming was never bound: drop the cipher and bind it.
    private func ct5UnprovenCipherFired(_ waited: TimeInterval) {
        guard isCt5, phase == .streaming else { return }
        guard AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: lastGlucoseId, lastDataRxAtMs: ct5LastDataRxAtMs, streamingSinceMs: streamingSinceMs) else { return }
        logLine("CT5 sent no data frame in \(Int(waited / 60)) min of streaming and never delivered one; starting a fresh bind", type: .error)
        bound = false
        ct5CipherKey = -1
        ct5RandomB = nil
        persistSecrets()
        persistState()
        recoverAndReconnect("CT5 cached cipher never streamed", problem: .bindNeverStreamed)
    }

    private func hasUsableHistoryTimeline() -> Bool {
        return glucoseTimelineStartMs > 0 || sensorStartMs > 0
    }

    /// The first id to pull after a reconnect: the one after the newest id held.
    private func reconnectBackfillStartId() -> Int {
        return max(lastGlucoseId + 1, 0)
    }

    private var maxGapRepairRecords: Int {
        if isCt2 { return Self.ct2MaxGapRepairRecords }
        if isCt4 { return Self.ct4MaxGapRepairRecords }
        return Self.ct5MaxGapRepairRecords
    }

    /// A forward pull never reaches back further than a gap repair would, so a long absence stays bounded.
    private func cappedStop(from startId: Int) -> Int {
        return startId + maxGapRepairRecords
    }

    // MARK: - timeline

    private func warmupAnchorMs() -> Int64 {
        if warmupStartedAtMs > 0 { return warmupStartedAtMs }
        if glucoseTimelineStartMs > 0 { return glucoseTimelineStartMs }
        if sensorStartMs > 0 { return sensorStartMs }
        return 0
    }

    /// Age from the id timeline, which survives a restart unlike in-memory reading state.
    private func ct5SensorAgeMs() -> Int64 {
        let start = glucoseTimelineStartMs > 0 ? glucoseTimelineStartMs : sensorStartMs
        return start > 0 ? nowMs() - start : -1
    }

    /// True while a CT5 is alive and reporting telemetry but has no glucose yet.
    private func isCt5WarmingUp() -> Bool {
        guard isCt5, lastGlucoseAtMs <= 0 else { return false }
        let age = ct5SensorAgeMs()
        if age < 0 || age >= profile.warmupMs { return false }
        return lastLiveFrameAtMs > 0 || glucoseTimelineStartMs > 0
    }

    /// The transmitter sends an id, never a time, so the timeline start is `arrival - id * interval`. A
    /// repeated id must not walk the stored start forward.
    private func updateTimelineFromLiveGlucoseId(_ glucoseId: Int, sampleMs: Int64) {
        guard glucoseId >= 0, intervalMs > 0 else { return }
        guard AnytimeHistoryPolicy.shouldReanchorTimeline(liveId: glucoseId, previousMaxId: lastGlucoseId, haveTimelineStart: glucoseTimelineStartMs > 0) else { return }
        let anchored = max(sampleMs - Int64(glucoseId) * intervalMs, 1)
        let oldTimelineStart = glucoseTimelineStartMs
        glucoseTimelineStartMs = anchored
        var changed = oldTimelineStart != anchored
        let drift = abs(sensorStartMs - anchored)
        if sensorStartMs <= 0 || drift > intervalMs * 2 {
            let firstStart = sensorStartMs <= 0
            sensorStartMs = anchored
            if warmupStartedAtMs == 0 || abs(warmupStartedAtMs - anchored) > intervalMs * 2 {
                warmupStartedAtMs = anchored
            }
            if firstStart {
                pendingNewSensorStart = Date(timeIntervalSince1970: Double(anchored) / 1000)
            }
            changed = true
            logLine("Sensor start from live glucose id \(glucoseId)")
        }
        if changed { persistState() }
    }

    /// A projected time ahead of the sample means the timeline start is too late for this id.
    private func anchorSensorTimelineIfNeeded(_ glucoseId: Int, sampleMs: Int64) {
        guard glucoseId >= 0, intervalMs > 0 else { return }
        let projected = glucoseTimelineStartMs > 0 ? glucoseTimelineStartMs + Int64(glucoseId) * intervalMs : Int64.max
        let tolerance = max(intervalMs / 2, 30_000)
        if projected <= sampleMs + tolerance { return }
        glucoseTimelineStartMs = max(sampleMs - Int64(glucoseId) * intervalMs, 1)
        logLine("Anchoring the glucose timeline from glucose id \(glucoseId)")
    }

    /// Ids that went back by more than the threshold mean the sensor was started again: its session state goes.
    private func clearStaleRuntimeStateBeforeLiveRecord(_ liveId: Int) {
        guard AnytimeHistoryPolicy.liveIdLooksRolledBack(liveId: liveId, previousMaxId: lastGlucoseId, rollbackThreshold: Self.glucoseIdRollbackThreshold) else { return }
        logLine("Detected an Anytime glucose-id rollback (live \(liveId), previous \(lastGlucoseId)); clearing the session state", type: .error)
        stopHistoryBackfill(remember: false)
        ct5HighestImportedId = -1
        ct5PendingGapFromId = -1
        ct5PendingGapStopBeforeId = -1
        pendingGapFromId = -1
        pendingGapStopBeforeId = -1
        ct5ResolvedIds.removeAll()
        ct5SkippedIds.removeAll()
        ct5GapFailureTracker.clear()
        ct5RawScale = AnytimeCt5RawScale()
        processedIds.removeAll()
        caughtUpCooldown.clear()
        lastGlucoseId = -1
        lastGlucoseAtMs = 0
        lastMgdl = nil
        lastWasEstimate = false
        sensorStartMs = 0
        glucoseTimelineStartMs = 0
        warmupStartedAtMs = 0
        freshPostLiveBackfillStarted = false
        restoredGlucoseState = false
        algorithmSession.clear()
        ct5LiveClock.reset()
        noteProblem(.sensorRestarted)
        persistState()
    }

    // MARK: - glucose: CT2 and CT4 raw records

    private func handleGlucoseFrame(_ data: [UInt8], push: Bool) {
        if phase == .handshaking && push {
            let records = AnytimeFrames.parseRawRecords(data, wideRecords: true)
            if let firstLiveId = records.map({ $0.glucoseId }).max() {
                updateTimelineFromLiveGlucoseId(firstLiveId, sampleMs: nowMs())
            }
            enterStreaming("Raw glucose during handshake")
        }
        let records: [AnytimeRawRecord]
        if !push && (data[0] == AnytimeOpcode.rxSeries || data[0] == AnytimeOpcode.rxLegacyRawDump) {
            records = AnytimeFrames.parseWideRawSeriesRecords(data)
        } else {
            records = AnytimeFrames.parseRawRecords(data, wideRecords: true)
        }
        processRawRecords(records, push: push)
    }

    private func handleCt2GlucoseFrame(_ data: [UInt8], historical: Bool) {
        let push = !historical
        guard let frame = AnytimeFrames.parseCt2GlucoseRecord(data) else {
            logLine("CT2 glucose frame rejected (bad sum or size)", type: .error)
            processRawRecords([], push: push)
            return
        }
        if frame.isEndOfHistory {
            // the transmitter's own end-of-history sentinel: the same end as an empty pull answer
            processRawRecords([], push: push)
            return
        }
        if push && phase == .handshaking {
            updateTimelineFromLiveGlucoseId(frame.record.glucoseId, sampleMs: nowMs())
            enterStreaming("CT2 raw glucose during handshake")
        }
        if let percent = frame.batteryPercent, (0...100).contains(percent) {
            batteryPercent = percent
        }
        processRawRecords([frame.record], push: push)
    }

    private func processRawRecords(_ records: [AnytimeRawRecord], push: Bool) {
        if records.isEmpty {
            // an empty pull answer: the transmitter has nothing more to give
            if !push { clearPullInFlight() }
            if let run = history {
                run.emptyInARow += 1
                if run.emptyInARow >= Self.historyEmptyResponsesToStop {
                    logLine("Backfill caught up at id \(lastGlucoseId) after \(run.emptyInARow) empty responses")
                    caughtUpCooldown.markCaughtUp(nextRequestId: max(run.lastPulledId + 1, 0))
                    finishHistoryBackfill()
                } else {
                    scheduleHistoryStep()
                }
            }
            return
        }
        history?.emptyInARow = 0
        if !push {
            clearPullInFlight()
            if let maxId = records.map({ $0.glucoseId }).max(), let run = history, maxId > run.lastPulledId {
                run.lastPulledId = maxId
            }
        }
        let now = nowMs()
        let anchorId = records.map { $0.glucoseId }.max() ?? -1
        let anchorMs: Int64 = (push && anchorId >= 0) ? now : 0
        if push && anchorId >= 0 {
            clearStaleRuntimeStateBeforeLiveRecord(anchorId)
        }
        if anchorId >= 0 {
            caughtUpCooldown.clearIfNewerData(glucoseId: anchorId)
        }
        if push && anchorMs > 0 && anchorId >= 0 {
            noteSessionSensorData()
            lastLiveFrameAtMs = now
            maybeStartGapRepair(anchorId)
            updateTimelineFromLiveGlucoseId(anchorId, sampleMs: anchorMs)
            maybeStartFreshPostLiveBackfill(anchorId)
        }
        for record in records {
            if processedIds.contains(record.glucoseId) { continue }
            iwNa = record.iwNa
            ibNa = record.ibNa
            temperatureC = record.temperatureC
            let sampleMs: Int64
            if push && anchorMs > 0 && anchorId >= record.glucoseId {
                // live pushes are wall-clock anchored: a cadence that is wrong early in a session must not
                // make a fresh reading look old
                sampleMs = anchorMs - Int64(anchorId - record.glucoseId) * intervalMs
            } else if glucoseTimelineStartMs > 0 {
                sampleMs = glucoseTimelineStartMs + Int64(record.glucoseId) * intervalMs
            } else if sensorStartMs > 0 {
                sampleMs = sensorStartMs + Int64(record.glucoseId) * intervalMs
            } else {
                sampleMs = now - Int64(record.indexInPacket) * intervalMs
            }
            anchorSensorTimelineIfNeeded(record.glucoseId, sampleMs: sampleMs)
            let start = glucoseTimelineStartMs > 0 ? glucoseTimelineStartMs : sensorStartMs
            if let output = algorithmSession.compute(record: record, qr: qr, family: familyEntry.family, sampleTimeMs: sampleMs, sensorStartTimeMs: start) {
                commitReading(output, sampleMs: sampleMs, live: push)
            }
            noteProcessed(record.glucoseId)
            if record.glucoseId > lastGlucoseId { lastGlucoseId = record.glucoseId }
        }
        if push { maybeRunReconnectTelemetryAfterLivePush() }
        flushDeliveries()
        persistState()
        armNoDataWatchdog()
        armPullFallback()
        // a non-empty pull answer chains the next pull until the transmitter runs dry
        if history != nil { scheduleHistoryStep() }
    }

    private func noteProcessed(_ glucoseId: Int) {
        processedIds.insert(glucoseId)
        if processedIds.count > 4000, let newest = processedIds.max() {
            processedIds = processedIds.filter { $0 > newest - 2000 }
        }
    }

    // MARK: - glucose: CT5

    private func handleCt5CurrentGlucose(_ data: [UInt8]) {
        // every live push is acknowledged at once, ahead of any queued history write
        writeFrame(AnytimeFrames.Builders.ct5PushAck(), tag: "ct5-pushAck", expectResponse: false)
        let record: AnytimeComputedRecord
        if hasCt5Cipher {
            guard let parsed = AnytimeFrames.parseCt5CurrentRecord(data, cipherKey: ct5CipherKey) else {
                logLine("Malformed CT5 live frame", type: .error)
                return
            }
            record = parsed
        } else {
            let maxGlucoseId = familyEntry.endNumber > 0 ? familyEntry.endNumber : Int.max
            guard let recovered = AnytimeFrames.inferCt5CipherFromCurrentRecord(data, maxGlucoseId: maxGlucoseId) else {
                logLine("CT5 live push before the cipher key and no safe key inference", type: .error)
                return
            }
            ct5CipherKey = recovered.cipherKey
            bound = true
            persistSecrets()
            persistState()
            logLine("Recovered the CT5 cipher from a live push (id \(recovered.record.glucoseId), glucose \(recovered.record.gluMgdl))", type: .error)
            record = recovered.record
        }
        ct5VoltagePayload = data.count == 19
        if phase == .handshaking {
            enterStreaming("CT5 glucose during handshake")
        }
        let now = nowMs()

        // a protocol-valid frame proves the sensor is present, whether or not it has computed glucose yet
        lastLiveFrameAtMs = now
        noteSessionSensorData()
        iwNa = record.iwNa
        ibNa = record.ibNa
        temperatureC = record.temperatureC
        if record.ceVoltageMv != AnytimeComputedRecord.unset { ceVoltageMv = record.ceVoltageMv }

        clearStaleRuntimeStateBeforeLiveRecord(record.glucoseId)
        ct5LiveClock.observeLive(glucoseId: record.glucoseId, receivedAtMs: now, hasGlucose: record.hasGlucose, errorCode: record.errorCode)
        // anchor the timeline from every live id, warm-up included: waiting for the first glucose would
        // leave a fresh sensor without a start time for most of an hour
        updateTimelineFromLiveGlucoseId(record.glucoseId, sampleMs: now)
        caughtUpCooldown.clearIfNewerData(glucoseId: record.glucoseId)

        // learn the sensor's own current-to-glucose scale while the firmware still produces one
        if record.hasGlucose && record.errorCode == 0 {
            ct5RawScale.observe(iwNa: record.iwNa, vendorMgdl: Float(record.gluMgdl))
        }

        if !record.hasGlucose || record.errorCode != 0 {
            // read whether this id is new before the cursor moves: a transmitter still advancing its id is a
            // working sensor having a bad reading, and a working sensor's bad readings are dropped, not invented
            let idAdvanced = record.glucoseId > lastGlucoseId
            if idAdvanced { lastGlucoseId = record.glucoseId }
            persistState()
            if !idAdvanced && emitCt5RawEstimate(record, now: now) { return }
            logLine("CT5 \(isCt5WarmingUp() ? "warm-up" : "no reading") id \(record.glucoseId) (no glucose), error \(record.errorCode)")
            // the sensor is talking on schedule; only the reading is missing
            armNoDataWatchdog()
            armPullFallback()
            maybeRunReconnectTelemetryAfterLivePush()
            return
        }

        let wasWarmingUp = isCt5WarmingUp()
        // detect the gap before the cursor moves, so 288 -> 291 asks for 289..290
        maybeStartCt5GapRepair(record.glucoseId)
        maybeStartFreshPostLiveBackfill(record.glucoseId)
        let sampleMs = glucoseTimelineStartMs > 0 ? glucoseTimelineStartMs + Int64(record.glucoseId) * intervalMs : now
        let output = AnytimeAlgorithm.fromComputedRecord(record, qr: qr, family: familyEntry.family)
        let stored = commitReading(output, sampleMs: sampleMs, live: true)
        flushDeliveries()
        noteCt5Imported(record.glucoseId)
        if stored && wasWarmingUp {
            logLine("CT5 warm-up complete at id \(record.glucoseId); first glucose stored")
        }
        if record.glucoseId > lastGlucoseId { lastGlucoseId = record.glucoseId }
        persistState()
        armNoDataWatchdog()
        armPullFallback()
        maybeRunReconnectTelemetryAfterLivePush()
    }

    /// A CT5 that reached the end of its life keeps reporting live current and temperature but stops
    /// computing glucose. With a scale learned from its own earlier output the current can still be turned
    /// into an estimate (JugglucoNG measured 1.5-4 % MARD out of sample); the sensitivity this scale freezes
    /// decays about 0.9 % per day. Only reached for an id that is not advancing, never in warm-up, and only
    /// when the user turned the option on (`AnytimeConfiguration`, off by default).
    private func emitCt5RawEstimate(_ record: AnytimeComputedRecord, now: Int64) -> Bool {
        // opt-in: a value past the sensor's rated life must not appear without the user having asked for it
        guard let address = deviceAddress, AnytimeConfiguration.ct5EstimatesFromCurrent(for: address) else { return false }
        if isCt5WarmingUp() { return false }
        let estimate = ct5RawScale.estimateMgdl(iwNa: record.iwNa)
        guard estimate.isFinite else { return false }

        // never projected from the id: a terminated CT5 repeats one id forever. The frame arrived now.
        let rawRecord = AnytimeRawRecord(indexInPacket: 0, glucoseId: record.glucoseId, ibNa: record.ibNa, iwNa: record.iwNa, temperatureC: record.temperatureC, recordBytes: [])
        let rawLinear = AnytimeAlgorithm.computeLinear(
            record: rawRecord,
            k: qr?.k ?? 0,
            r: qr?.r ?? 0,
            family: familyEntry.family,
            voltageFlag: qr?.voltageFlag ?? 0
        ).rawMgdl
        let output = AnytimeAlgorithm.Output(
            glucoseId: record.glucoseId,
            mmol: estimate / 18,
            mgdlTimes10: anytimeKotlinInt(estimate * 10 + 0.5),
            ibNa: record.ibNa,
            iwNa: record.iwNa,
            temperatureC: record.temperatureC,
            trend: AnytimeAlgorithm.trendNone,
            errorCode: 0,
            warnCode: 0,
            source: .linear,
            rawMgdl: rawLinear.isFinite ? rawLinear : estimate,
            beVoltageMv: record.beVoltageMv,
            weVoltageMv: record.weVoltageMv,
            reVoltageMv: record.reVoltageMv,
            ceVoltageMv: record.ceVoltageMv,
            bVoltageMv: record.batteryRaw
        )
        let stored = commitReading(output, sampleMs: now, live: true, estimated: true)
        flushDeliveries()
        guard stored else { return false }
        noteCt5Imported(record.glucoseId)
        logLine("CT5 estimate id \(record.glucoseId): \(Int(estimate)) mg/dL from \(record.iwNa) nA (scale \(ct5RawScale.effectiveScale), \(ct5RawScale.isLearned ? "learned from \(ct5RawScale.samples) readings" : "family default"))")
        persistState()
        armNoDataWatchdog()
        armPullFallback()
        maybeRunReconnectTelemetryAfterLivePush()
        return true
    }

    private func handleCt5Series(_ data: [UInt8]) {
        guard hasCt5Cipher else {
            logLine("CT5 series before the cipher key", type: .error)
            clearPullInFlight()
            return
        }
        let payloadLength = max(data.count - 4, 0)
        let preferVoltage = ct5VoltagePayload
            || (payloadLength > 0
                && payloadLength % AnytimeConstants.ct5VoltageChunkSize == 0
                && payloadLength % AnytimeConstants.ct5RawChunkSize != 0)
        let preferred = AnytimeFrames.parseCt5SeriesRecords(data, cipherKey: ct5CipherKey, voltage: preferVoltage)
        let records: [AnytimeComputedRecord]
        if !preferred.isEmpty {
            ct5VoltagePayload = preferVoltage
            records = preferred
        } else {
            let fallbackVoltage = !preferVoltage
            let alternative = AnytimeFrames.parseCt5SeriesRecords(data, cipherKey: ct5CipherKey, voltage: fallbackVoltage)
            if !alternative.isEmpty { ct5VoltagePayload = fallbackVoltage }
            records = alternative
        }
        let requestedFromId = max((history?.lastPulledId ?? -1) + 1, 0)
        let requestedCount = max(history?.pullInFlightCount ?? 0, 1)
        let requestedStopBeforeId = min(requestedFromId + requestedCount, history?.stopBeforeId ?? AnytimeHistoryPolicy.unbounded)
        if history != nil {
            clearPullInFlight()
        }
        if records.isEmpty {
            if let run = history {
                run.emptyInARow += 1
                if run.emptyInARow >= Self.historyEmptyResponsesToStop {
                    logLine("CT5 backfill caught up at id \(lastGlucoseId)")
                    if isCt5AutomaticGapReason(run.reason) {
                        ct5HistoryHealth.pauseForThisConnection()
                        let abandoned = noteCt5GapFailedSession(requestedFromId, requestedStopBeforeId)
                        stopHistoryBackfill(remember: !abandoned)
                        if abandoned && refreshPendingCt5GapFromCache() != nil {
                            scheduleCt5Settle(after: Self.ct5HistoryBatchDelay)
                        }
                        return
                    }
                    caughtUpCooldown.markCaughtUp(nextRequestId: max(run.lastPulledId + 1, 0))
                    finishHistoryBackfill()
                } else {
                    scheduleHistoryStep()
                }
            }
            return
        }

        history?.emptyInARow = 0
        // an answer proves the pull path still works on this connection
        ct5HistoryHealth.onSeriesReceived()
        // a pull still works after the sensor stopped computing glucose, and teaches the scale
        for record in records where record.hasGlucose && record.errorCode == 0 {
            ct5RawScale.observe(iwNa: record.iwNa, vendorMgdl: Float(record.gluMgdl))
        }
        // every valid returned id resolves that part of a pending gap, even when xDrip already held the
        // reading; otherwise an "all existing" answer completed the range and the scanner asked for it again
        let known = Set(records.map { $0.glucoseId }.filter { ct5ResolvedIds.contains($0) })
        noteCt5GapProgress(records.map { $0.glucoseId })
        let maxId = records.map { $0.glucoseId }.max() ?? 0
        let minId = records.map { $0.glucoseId }.min() ?? 0
        if let run = history, maxId > run.lastPulledId { run.lastPulledId = maxId }
        caughtUpCooldown.clearIfNewerData(glucoseId: maxId)

        let now = nowMs()
        let tally = AnytimeCt5HistoryBatchTally()
        for record in records {
            iwNa = record.iwNa
            ibNa = record.ibNa
            temperatureC = record.temperatureC
            let sampleMs: Int64
            if glucoseTimelineStartMs > 0 {
                sampleMs = glucoseTimelineStartMs + Int64(record.glucoseId) * intervalMs
            } else if sensorStartMs > 0 {
                sampleMs = sensorStartMs + Int64(record.glucoseId) * intervalMs
            } else {
                sampleMs = now - Int64(maxId - record.glucoseId) * intervalMs
            }
            anchorSensorTimelineIfNeeded(record.glucoseId, sampleMs: sampleMs)
            if !record.hasGlucose {
                // a valid warm-up record anchors the timeline and nothing else
                tally.countWarmup()
                if record.glucoseId > lastGlucoseId { lastGlucoseId = record.glucoseId }
                continue
            }
            if known.contains(record.glucoseId) {
                tally.countExisting()
                continue
            }
            let output = AnytimeAlgorithm.fromComputedRecord(record, qr: qr, family: familyEntry.family)
            if commitReading(output, sampleMs: sampleMs, live: false) {
                tally.countInserted()
            }
            noteCt5Imported(record.glucoseId)
            if record.glucoseId > lastGlucoseId { lastGlucoseId = record.glucoseId }
        }
        logLine(tally.describe(firstId: minId, lastId: maxId))
        flushDeliveries()
        if ct5PendingGapFromId >= 0 { _ = refreshPendingCt5GapFromCache() }
        persistState()
        armNoDataWatchdog()
        armPullFallback()
        if history != nil { scheduleHistoryStep() }
    }

    private func noteCt5Imported(_ glucoseId: Int) {
        guard isCt5, glucoseId >= 0 else { return }
        if glucoseId > ct5HighestImportedId { ct5HighestImportedId = glucoseId }
        // a live import is as resolved as a pulled one: the gap scanner must not ask for it again
        ct5ResolvedIds.insert(glucoseId)
        trimResolvedIds()
    }

    private func trimResolvedIds() {
        if ct5ResolvedIds.count > Self.maxStoredIds * 2, let newest = ct5ResolvedIds.max() {
            ct5ResolvedIds = ct5ResolvedIds.filter { $0 > newest - Self.maxStoredIds }
        }
    }

    // MARK: - committing a reading

    /// Holds a reading until the end of the frame that carried it. False when it was held back.
    @discardableResult
    private func commitReading(_ output: AnytimeAlgorithm.Output, sampleMs: Int64, live: Bool, estimated: Bool = false) -> Bool {
        if live { noteSessionSensorData() }
        // Warm-up gate: readings the model has not settled for never reach xDrip. Sample based, so a later
        // pull of the same ids reaches the same verdict. CT5 computes nothing in its own warm-up.
        if AnytimeConstants.isWithinWarmup(anchorMs: warmupAnchorMs(), sampleMs: sampleMs, windowMs: profile.warmupMs) {
            if live {
                lastLiveFrameAtMs = nowMs()
                armNoDataWatchdog()
                logLine("Warm-up: holding live id \(output.glucoseId)")
            }
            return false
        }
        if output.errorCode != 0 || output.mgdlTimes10 < AnytimeConstants.algoMgdlMinTimes10 {
            if live {
                logLine("Dropping an invalid reading, id \(output.glucoseId), error \(output.errorCode), \(output.mgdl) mg/dL", type: .error)
            }
            return false
        }
        if sampleMs >= lastGlucoseAtMs {
            lastGlucoseAtMs = sampleMs
            lastMgdl = output.mgdl
            lastWasEstimate = estimated
            iwNa = output.iwNa
            ibNa = output.ibNa
            temperatureC = output.temperatureC
        }
        if live {
            logLine("Reading id \(output.glucoseId), \(output.mgdl) mg/dL, source \(output.source), \(String(format: "%.2f", output.iwNa)) nA")
        }
        deliveryBuffer.append(SampleToDeliver(date: Date(timeIntervalSince1970: Double(sampleMs) / 1000), mgdl: output.mgdl, live: live))
        return true
    }

    private func flushDeliveries() {
        guard !deliveryBuffer.isEmpty else { return }
        let samples = deliveryBuffer
        deliveryBuffer.removeAll()
        guard let newest = samples.max(by: { $0.date < $1.date }) else { return }

        let now = Date()
        let startDate: Date? = sensorStartMs > 0 ? Date(timeIntervalSince1970: Double(sensorStartMs) / 1000) : nil
        let sensorAge: TimeInterval? = startDate.map { max(0, newest.date.timeIntervalSince($0)) }
        let newSensorStartDate = pendingNewSensorStart
        pendingNewSensorStart = nil
        let battery: TransmitterBatteryInfo? = batteryPercent.map { TransmitterBatteryInfo.percentage(percentage: $0) }

        updateState {
            $0.problem = nil
            $0.problemDate = nil
        }

        let glucoseData: [GlucoseData] = samples.sorted { $0.date > $1.date }.map {
            GlucoseData(
                timeStamp: $0.date,
                glucoseLevelRaw: (Double($0.mgdl) * 100).rounded() / 100,
                backfilledAt: $0.live ? nil : now
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let delegate = self.cgmTransmitterDelegate else { return }
            if let newSensorStartDate = newSensorStartDate {
                delegate.newSensorDetected(sensorStartDate: newSensorStartDate)
            }
            var data = glucoseData
            delegate.cgmTransmitterInfoReceived(glucoseData: &data, transmitterBatteryInfo: battery, sensorAge: sensorAge)
        }
    }

    // MARK: - history

    private func scheduleHistoryStep() {
        let delay = isCt5 ? Self.ct5HistoryBatchDelay : Self.historyBatchDelay
        schedule(.historyStep, after: delay) { [weak self] in
            self?.historyStep()
        }
    }

    private func armHistoryPullTimeout() {
        schedule(.historyPullTimeout, after: Self.historyPullTimeout) { [weak self] in
            self?.historyPullTimedOut()
        }
    }

    private func clearPullInFlight() {
        cancel(.historyPullTimeout)
        history?.pullInFlight = false
        history?.pullInFlightCount = 0
        history?.pullIsSeries = false
        history?.timeouts = 0
    }

    private func isCt5AutomaticGapReason(_ reason: String) -> Bool {
        return reason.hasPrefix("ct5-gap") || reason.hasPrefix("ct5-reconnect-catchup")
    }

    /// Starts one pass over `[fromId, stopBeforeId)`. The pass pulls in batches until the range is done or the
    /// transmitter has nothing more to give.
    private func startHistoryBackfill(_ reason: String, fromId: Int, stopBeforeId: Int = AnytimeHistoryPolicy.unbounded) {
        guard phase == .streaming else { return }
        if isCt5 && !isCt5HistoryWindowOpen(reason: reason, fromId: fromId, stopBeforeId: stopBeforeId) { return }
        if isCt5 && ct5HistoryHealth.isPausedForThisConnection() {
            logLine("Deferring CT5 history (\(reason)); it is unhealthy on this link and resumes on the next one")
            rememberPendingCt5Gap(fromId, stopBeforeId)
            return
        }
        if history != nil { return }
        let startId = max(fromId, 0)
        let stopId = max(stopBeforeId, startId)
        if caughtUpCooldown.shouldSuppressBackfill(startId: startId, stopBeforeId: stopId, reason: reason, lastGlucoseId: lastGlucoseId) {
            logLine("Skipping history during the caught-up cooldown (\(reason), start \(startId))", type: .debug)
            return
        }
        if startId >= stopId {
            logLine("Skipping an empty history range (\(reason), start \(startId), stop before \(stopId))", type: .debug)
            return
        }
        logLine("Starting history (\(reason)) from id \(startId) stop before \(stopId == AnytimeHistoryPolicy.unbounded ? "no limit" : String(stopId))")
        history = HistoryRun(reason: reason, stopBeforeId: stopId, lastPulledId: startId - 1, startedAfterGlucoseId: lastGlucoseId)
        schedule(.historyStep, after: 0.25) { [weak self] in
            self?.historyStep()
        }
    }

    private func nextBackfillIdSkippingCached(_ fromId: Int) -> Int {
        var id = max(fromId, 0)
        let stop = history?.stopBeforeId ?? AnytimeHistoryPolicy.unbounded
        if isCt5 {
            while id < stop && (ct5ResolvedIds.contains(id) || ct5SkippedIds.contains(id)) { id += 1 }
        } else {
            while id < stop && processedIds.contains(id) { id += 1 }
        }
        return id
    }

    private func historyStep() {
        guard let run = history, phase == .streaming, !run.pullInFlight else { return }
        let nextId = nextBackfillIdSkippingCached(max(run.lastPulledId + 1, 0))
        if caughtUpCooldown.shouldSuppressBackfill(startId: nextId, stopBeforeId: run.stopBeforeId, reason: run.reason, lastGlucoseId: lastGlucoseId) {
            finishHistoryBackfill()
            return
        }
        if nextId >= run.stopBeforeId {
            logLine("History range complete (\(run.reason), next \(nextId))")
            finishHistoryBackfill()
            return
        }
        if AnytimeHistoryPolicy.shouldStopAtProfileHistoryEnd(family: familyEntry.family, nextId: nextId, profileEndNumber: familyEntry.endNumber) {
            logLine("History complete at the profile end (\(familyEntry.endNumber))")
            finishHistoryBackfill()
            return
        }
        if isCt5 && (writeInFlight || protocolResponseInFlight) {
            // never stack a history pull on top of a live-push acknowledgement
            scheduleHistoryStep()
            return
        }
        run.lastPulledId = nextId - 1
        run.pullInFlight = true
        let count = historyPullCount(nextId)
        run.pullInFlightCount = count
        run.pullIsSeries = count > 1 && !isCt5
        if !writeFrame(pullGlucoseFrame(nextId, count: count), tag: AnytimeHistoryPolicy.backfillWriteTag(count: count)) {
            clearPullInFlight()
            scheduleHistoryStep()
        }
    }

    private func historyPullTimedOut() {
        guard let run = history, run.pullInFlight else { return }
        releaseProtocolResponseSlot(nil)
        let retryId = max(run.lastPulledId + 1, 0)
        let failedCount = max(run.pullInFlightCount, 1)
        let retryStop = min(retryId + failedCount, run.stopBeforeId)
        logLine("History pull timeout at id \(retryId), count \(failedCount)", type: .error)
        run.pullInFlight = false
        run.pullInFlightCount = 0
        run.timeouts += 1
        if isCt5 {
            // transient by construction: keep the range, back off, and give up only for this link
            clearProtocolFrameTimeout()
            if failedCount > 1 {
                ct5SingleRecordHistoryOnly = true
                logLine("CT5 \(failedCount)-record pull timed out; falling back to single-record pulls")
                scheduleHistoryStep()
                return
            }
            if let backoffMs = ct5HistoryHealth.onTimeout() {
                logLine("CT5 history pull timed out at id \(retryId); retrying in \(backoffMs) ms")
                schedule(.historyStep, after: Double(backoffMs) / 1000) { [weak self] in
                    self?.historyStep()
                }
            } else {
                let abandoned = noteCt5GapFailedSession(retryId, retryStop)
                logLine("CT5 history pull timed out at id \(retryId) (\(ct5HistoryHealth.timeoutCount()) on this link); pausing history until the next one", type: .error)
                stopHistoryBackfill(remember: !abandoned)
                if abandoned && refreshPendingCt5GapFromCache() != nil {
                    scheduleCt5Settle(after: Self.ct5HistoryBatchDelay)
                }
            }
            return
        }
        if run.pullIsSeries && legacySeriesHistorySupported {
            legacySeriesHistorySupported = false
            logLine("Disabling the batched 0x22 history for this link; falling back to single-record pulls")
        }
        run.pullIsSeries = false
        if run.timeouts >= 5 {
            logLine("History stopped after \(run.timeouts) unanswered pulls", type: .error)
            noteProblem(.historyFailed)
            stopHistoryBackfill(remember: false)
            return
        }
        scheduleHistoryStep()
    }

    private func finishHistoryBackfill() {
        let reason = history?.reason ?? ""
        let stopBeforeId = history?.stopBeforeId ?? AnytimeHistoryPolicy.unbounded
        let reachedId = max((history?.lastPulledId ?? -1) + 1, 0)
        stopHistoryBackfill(remember: false)

        if reason.hasPrefix("ct2-gap") || reason.hasPrefix("ct4-gap") {
            finishGapRun(runStopBeforeId: stopBeforeId, reachedId: reachedId)
            return
        }
        if isCt5AutomaticGapReason(reason) {
            // a run is one contiguous slice of a possibly sparse envelope: recompute from the ids held and
            // repair the next newest hole before returning to live streaming
            _ = refreshPendingCt5GapFromCache()
            schedule(.gapResume, after: Self.ct5HistoryBatchDelay) { [weak self] in
                guard let self = self, self.phase == .streaming else { return }
                if !self.maybeResumePendingCt5Gap() {
                    self.maybeStartCt5ReconnectCatchup()
                }
            }
        }
    }

    private func stopHistoryBackfill(remember: Bool) {
        if remember { rememberInterruptedHistory() }
        history = nil
        cancel(.historyPullTimeout)
        cancel(.historyStep)
        writeQueue.removeAll { AnytimeHistoryPolicy.isBackfillWriteTag($0.tag) }
    }

    /// A CT5 pass cut short leaves the rest of its range as a pending gap, which survives a restart.
    private func rememberInterruptedHistory() {
        guard isCt5, let run = history else { return }
        let next = nextBackfillIdSkippingCached(max(run.lastPulledId + 1, 0))
        if next >= run.stopBeforeId { return }
        rememberPendingCt5Gap(next, run.stopBeforeId)
    }

    /// A fresh sensor pulls only a recent tail once the first live push has anchored its timeline.
    private func maybeStartFreshPostLiveBackfill(_ anchorId: Int) {
        if restoredGlucoseState || freshPostLiveBackfillStarted || history != nil { return }
        guard anchorId >= 0, hasUsableHistoryTimeline() else { return }
        freshPostLiveBackfillStarted = true
        let recentStartId = max(anchorId - Self.freshAutoBackfillRecords + 1, 0)
        let reason = isCt5 ? "ct5-initial" : "post-live-anchor(recent)"
        logLine("Fresh live anchor id \(anchorId); pulling the recent \(Self.freshAutoBackfillRecords) records (\(recentStartId)..\(anchorId))")
        schedule(.freshBackfill, after: 0.25) { [weak self] in
            self?.startHistoryBackfill(reason, fromId: recentStartId, stopBeforeId: anchorId + 1)
        }
    }

    // MARK: - CT5 gap repair

    /// CT5 glucose comes from the transmitter, so its history has one job: fill ids that are missing from
    /// the stored series.
    private func isCt5HistoryWindowOpen(reason: String, fromId: Int, stopBeforeId: Int) -> Bool {
        if reason.hasPrefix("user-requested") { return true }
        let busy = writeInFlight || protocolResponseInFlight
        if AnytimeHistoryPolicy.isCt5HistoryLinkSettled(streamingSinceMs: streamingSinceMs, nowMs: nowMs(), settleMs: Self.ct5HistoryLinkSettleMs, writeInFlight: busy) {
            return true
        }
        rememberPendingCt5Gap(fromId, stopBeforeId)
        logLine("Holding CT5 history (\(reason)); \(busy ? "the write slot is busy" : "the link has not settled yet")")
        scheduleCt5Settle(after: Self.ct5HistorySettleRetry)
        return false
    }

    private func scheduleCt5Settle(after delay: TimeInterval) {
        schedule(.ct5Settle, after: delay) { [weak self] in
            guard let self = self, self.isCt5, self.phase == .streaming, self.history == nil else { return }
            if !self.maybeResumePendingCt5Gap() {
                self.maybeStartCt5ReconnectCatchup()
            }
        }
    }

    private func rememberPendingCt5Gap(_ fromId: Int, _ stopBeforeId: Int) {
        guard isCt5 else { return }
        if fromId < 0 || stopBeforeId <= fromId || stopBeforeId == AnytimeHistoryPolicy.unbounded { return }
        guard let merged = AnytimeHistoryPolicy.ct5MergeGap(
            currentFromId: ct5PendingGapFromId,
            currentStopBeforeId: ct5PendingGapStopBeforeId,
            newFromId: fromId,
            newStopBeforeId: stopBeforeId,
            maxRecords: Self.ct5MaxGapRepairRecords
        ) else { return }
        if merged.fromId == ct5PendingGapFromId && merged.stopBeforeId == ct5PendingGapStopBeforeId { return }
        ct5PendingGapFromId = merged.fromId
        ct5PendingGapStopBeforeId = merged.stopBeforeId
        logLine("CT5 gap \(merged) outstanding")
        persistState()
    }

    /// One failed link for a range; after three the automatic repair skips those ids so an unavailable hole
    /// cannot reconnect and retry forever.
    private func noteCt5GapFailedSession(_ fromId: Int, _ stopBeforeId: Int) -> Bool {
        guard let run = history, isCt5AutomaticGapReason(run.reason), fromId >= 0, stopBeforeId > fromId else { return false }
        let range = AnytimeIdRange(fromId: fromId, stopBeforeId: stopBeforeId)
        let abandoned = ct5GapFailureTracker.onFailedSession(range)
        if let abandoned = abandoned {
            for id in abandoned.fromId..<abandoned.stopBeforeId { ct5SkippedIds.insert(id) }
            logLine("CT5 auto-repair abandons the unavailable range \(abandoned) after \(Self.ct5GapMaxFailedSessions) failed links", type: .error)
        } else {
            logLine("CT5 auto-repair range \(range) failed on this link; it retries after the reconnect")
        }
        persistState()
        return abandoned != nil
    }

    private func noteCt5GapProgress(_ receivedIds: [Int]) {
        guard !receivedIds.isEmpty else { return }
        ct5GapFailureTracker.onProgress(receivedIds: receivedIds)
        ct5ResolvedIds.formUnion(receivedIds)
        trimResolvedIds()
        ct5SkippedIds.subtract(receivedIds)
    }

    /// Rebuilds the durable envelope from the ids that are still absent.
    @discardableResult
    private func refreshPendingCt5GapFromCache() -> AnytimeIdRange? {
        guard ct5PendingGapFromId >= 0 else { return nil }
        guard let remaining = AnytimeHistoryPolicy.ct5MissingEnvelope(
            pendingFromId: ct5PendingGapFromId,
            pendingStopBeforeId: ct5PendingGapStopBeforeId,
            cachedIds: ct5ResolvedIds.union(ct5SkippedIds)
        ) else {
            ct5PendingGapFromId = -1
            ct5PendingGapStopBeforeId = -1
            persistState()
            return nil
        }
        if remaining.fromId != ct5PendingGapFromId || remaining.stopBeforeId != ct5PendingGapStopBeforeId {
            ct5PendingGapFromId = remaining.fromId
            ct5PendingGapStopBeforeId = remaining.stopBeforeId
            persistState()
        }
        return remaining
    }

    /// The ids missing between what is held and a freshly arrived live id: 288 -> 291 asks for 289..290.
    private func maybeStartCt5GapRepair(_ liveId: Int) {
        guard isCt5, phase == .streaming else { return }
        guard let gap = AnytimeHistoryPolicy.reconnectGap(highestKnownId: max(ct5HighestImportedId, -1), liveId: liveId, maxRecords: Self.ct5MaxGapRepairRecords) else { return }
        logLine("CT5 gap detected \(gap) (have \(ct5HighestImportedId), live \(liveId))")
        rememberPendingCt5Gap(gap.fromId, gap.stopBeforeId)
        if let run = history {
            if run.reason.hasPrefix("ct5-initial") {
                logLine("Pausing the initial recent history so the live gap \(gap) is repaired first")
                stopHistoryBackfill(remember: true)
            } else {
                return
            }
        }
        _ = maybeResumePendingCt5Gap()
    }

    /// Resumes a gap left by an interrupted repair or a restart: the newest missing slice first.
    @discardableResult
    private func maybeResumePendingCt5Gap() -> Bool {
        guard isCt5, phase == .streaming, ct5PendingGapFromId >= 0 else { return false }
        if protocolResponseInFlight {
            scheduleCt5Settle(after: Self.ct5HistoryBatchDelay)
            return false
        }
        // a newer live id proves nothing about the hole, so the stored range stands until ids inside it arrive
        guard let remaining = refreshPendingCt5GapFromCache() else { return false }
        guard let newestMissing = AnytimeHistoryPolicy.ct5NewestMissingRange(
            pendingFromId: remaining.fromId,
            pendingStopBeforeId: remaining.stopBeforeId,
            cachedIds: ct5ResolvedIds.union(ct5SkippedIds),
            maxRecords: Self.historyPullSeriesCount
        ) else { return false }
        logLine("Resuming the newest CT5 gap \(newestMissing) from \(remaining)")
        startHistoryBackfill("ct5-gap(resumed)", fromId: newestMissing.fromId, stopBeforeId: newestMissing.stopBeforeId)
        return history != nil
    }

    /// The id the transmitter should be at now, from the 3-minute timeline: after a longer outage the
    /// catch-up need not wait for the next live push to learn how far behind it is.
    private func ct5ExpectedCurrentId() -> Int {
        let start = glucoseTimelineStartMs > 0 ? glucoseTimelineStartMs : max(sensorStartMs, 0)
        return ct5LiveClock.expectedCurrentId(
            nowMs: nowMs(),
            intervalMs: intervalMs,
            streamingSinceMs: streamingSinceMs,
            lastObservedId: lastGlucoseId,
            timelineStartMs: start,
            profileEndNumber: profile.endNumber
        )
    }

    private func maybeStartCt5ReconnectCatchup() {
        guard isCt5, phase == .streaming else { return }
        let now = nowMs()
        // estimate only after the settle wait: a frame received meanwhile overrides the old clock guess
        if !AnytimeHistoryPolicy.isCt5HistoryLinkSettled(streamingSinceMs: streamingSinceMs, nowMs: now, settleMs: Self.ct5HistoryLinkSettleMs, writeInFlight: writeInFlight || protocolResponseInFlight) {
            let remaining = Double(Self.ct5HistoryLinkSettleMs - max(now - streamingSinceMs, 0)) / 1000
            scheduleCt5Settle(after: max(remaining, Self.ct5HistorySettleRetry))
            return
        }
        let expectedId = ct5ExpectedCurrentId()
        guard expectedId > 0 else { return }
        guard let gap = AnytimeHistoryPolicy.ct5ReconnectCatchupGap(
            highestKnownId: max(ct5HighestImportedId, -1),
            lastObservedId: lastGlucoseId,
            expectedCurrentId: expectedId,
            maxRecords: Self.ct5MaxGapRepairRecords
        ) else {
            logLine("CT5 reconnect: no missing ids (have \(ct5HighestImportedId), expected \(expectedId))")
            return
        }
        logLine("CT5 reconnect catch-up \(gap) (have \(ct5HighestImportedId), expected \(expectedId))")
        rememberPendingCt5Gap(gap.fromId, gap.stopBeforeId)
        _ = maybeResumePendingCt5Gap()
    }

    // MARK: - CT2 and CT4 gap repair

    // A CT2 or CT4 pushes one record per slot and names no ids a listener missed, so a hole only shows up
    // as a jump in the live id. The repair is kept in memory only: it is owed to this link.

    private var gapReason: String { return isCt2 ? "ct2-gap" : "ct4-gap" }

    private func maybeStartGapRepair(_ liveId: Int) {
        guard !isCt5, phase == .streaming else { return }
        if let gap = AnytimeHistoryPolicy.reconnectGap(highestKnownId: lastGlucoseId, liveId: liveId, maxRecords: maxGapRepairRecords) {
            logLine("\(isCt2 ? "CT2" : "CT4") gap detected \(gap) (have \(lastGlucoseId), live \(liveId))")
            rememberGap(gap)
        }
        _ = maybeResumeGap()
    }

    private func rememberGap(_ gap: AnytimeIdRange) {
        guard !isCt5, gap.fromId >= 0, gap.stopBeforeId > gap.fromId, gap.stopBeforeId != AnytimeHistoryPolicy.unbounded else { return }
        guard let merged = AnytimeHistoryPolicy.ct5MergeGap(
            currentFromId: pendingGapFromId,
            currentStopBeforeId: pendingGapStopBeforeId,
            newFromId: gap.fromId,
            newStopBeforeId: gap.stopBeforeId,
            maxRecords: maxGapRepairRecords
        ) else { return }
        pendingGapFromId = merged.fromId
        pendingGapStopBeforeId = merged.stopBeforeId
    }

    private func clearGap() {
        pendingGapFromId = -1
        pendingGapStopBeforeId = -1
    }

    /// Asks for the ids the live cursor has already moved past. A running pass that already covers the whole
    /// range is left alone; one that would end before the gap is displaced by it.
    @discardableResult
    private func maybeResumeGap() -> Bool {
        guard !isCt5, phase == .streaming else { return false }
        let from = pendingGapFromId
        let stopBefore = pendingGapStopBeforeId
        guard from >= 0, stopBefore > from else { return false }
        if let run = history {
            // an active gap pass owns the envelope; a wider live jump is picked up when it finishes
            if run.reason.hasPrefix(gapReason) { return true }
            let covers = AnytimeHistoryPolicy.backfillCoversRange(
                nextRequestId: nextBackfillIdSkippingCached(max(run.lastPulledId + 1, 0)),
                stopBeforeId: run.stopBeforeId,
                fromId: from,
                gapStopBeforeId: stopBefore
            )
            if covers { return true }
            guard run.reason.hasPrefix("post-init") || run.reason.hasPrefix("post-reset") || run.reason.hasPrefix("post-live-anchor") else { return false }
            logLine("Pausing \(run.reason) so the gap \(from)..\(stopBefore - 1) is repaired first")
            stopHistoryBackfill(remember: false)
        }
        startHistoryBackfill(gapReason, fromId: from, stopBeforeId: stopBefore)
        return history != nil
    }

    /// Closes a gap pass. Finishing short of the range means the transmitter has nothing more for it, so that
    /// hole is accepted; a live jump during the pass widens the envelope and the rest stays owed.
    private func finishGapRun(runStopBeforeId: Int, reachedId: Int) {
        if reachedId < runStopBeforeId {
            logLine("Gap repair stopped at id \(reachedId) before \(runStopBeforeId); the transmitter has no more history for it")
        } else {
            logLine("Gap repair complete through id \(reachedId)")
        }
        if let stillOwed = AnytimeHistoryPolicy.gapRemainder(
            runStopBeforeId: runStopBeforeId,
            reachedId: reachedId,
            pendingFromId: pendingGapFromId,
            pendingStopBeforeId: pendingGapStopBeforeId
        ) {
            pendingGapFromId = stillOwed.fromId
            logLine("Gap \(stillOwed) still outstanding")
            if maybeResumeGap() { return }
        }
        clearGap()
    }

    // MARK: - watchdogs

    private func lastSensorDataAtMs() -> Int64 {
        return max(lastGlucoseAtMs, lastLiveFrameAtMs)
    }

    private func noDataWatchdogDelay() -> TimeInterval {
        return Self.noDataWatchdogMultiplier * Double(profile.readingIntervalMinutes) * 60
    }

    private func armNoDataWatchdog() {
        cancel(.noData)
        guard phase == .streaming, lastSensorDataAtMs() > 0 else { return }
        schedule(.noData, after: noDataWatchdogDelay()) { [weak self] in
            self?.noDataWatchdogFired()
        }
    }

    private func noDataWatchdogFired() {
        guard phase == .streaming else { return }
        let last = lastSensorDataAtMs()
        guard last > 0 else { return }
        let elapsed = Double(nowMs() - last) / 1000
        if elapsed < noDataWatchdogDelay() {
            armNoDataWatchdog()
            return
        }
        recoverAndReconnect("no sensor data for \(Int(elapsed)) s", problem: .noData)
    }

    private func armPullFallback() {
        cancel(.pullFallback)
        guard phase == .streaming else { return }
        schedule(.pullFallback, after: Self.pullFallbackMultiplier * Double(profile.readingIntervalMinutes) * 60) { [weak self] in
            self?.pullFallbackFired()
        }
    }

    /// If the transmitter went quiet, ask for the next id explicitly.
    private func pullFallbackFired() {
        guard phase == .streaming else { return }
        if lastGlucoseId >= 0 {
            writeFrame(pullGlucoseFrame(lastGlucoseId + 1), tag: "pullGlucose(fallback)")
        }
        armPullFallback()
    }

    // Battery telemetry is a CT4 job: a CT2 carries its battery in every live push, and a CT5 has none.

    private func armTelemetryCheck(_ delay: TimeInterval) {
        cancel(.telemetry)
        guard isCt4, phase == .streaming else { return }
        schedule(.telemetry, after: delay) { [weak self] in
            self?.telemetryCheckFired()
        }
    }

    private func telemetryCheckFired() {
        guard phase == .streaming else { return }
        if history != nil {
            armTelemetryCheck(Self.telemetryRetryDelay)
            return
        }
        let quiet = Double(nowMs() - lastProtocolFrameAtMs) / 1000
        if lastProtocolFrameAtMs > 0 && quiet < Self.telemetryQuiet {
            armTelemetryCheck(Self.telemetryRetryDelay)
            return
        }
        if writeFrame(checkFrame(), tag: "check(periodic-telemetry)") {
            armTelemetryCheck(Self.telemetryCheckInterval)
        } else {
            armTelemetryCheck(Self.telemetryRetryDelay)
        }
    }

    private func requestTelemetryAfterReconnectLivePushes() {
        telemetryLivePushesUntilCheck = 2
        armTelemetryCheck(Self.telemetryCheckInterval)
    }

    private func maybeRunReconnectTelemetryAfterLivePush() {
        guard telemetryLivePushesUntilCheck > 0 else { return }
        telemetryLivePushesUntilCheck -= 1
        if telemetryLivePushesUntilCheck == 0 {
            telemetryLivePushesUntilCheck = -1
            armTelemetryCheck(1)
        }
    }

    // MARK: - CGMTransmitter

    func cgmTransmitterType() -> CGMTransmitterType {
        return .anytime
    }

    /// The rated life of the family the name classified (CT5 16 days, the others from their record count).
    func maxSensorAgeInDays() -> Double? {
        let name = loadState()?.advertisedName
        return Double(AnytimeProfileResolver.resolve(name).ratedLifetimeDays)
    }

    /// The driver holds a model's first readings back itself (`AnytimeConstants.isWithinWarmup`), and xDrip's
    /// own warm-up would hide the readings of a sensor that is already settled.
    func sensorWarmupDurationInMinutes() -> Double? { 0 }

    func needsSensorStartTime() -> Bool { false }

    /// Values are mg/dL from the transmitter's own algorithm or the driver's model, so xDrip uses no calibrator.
    func isWebOOPEnabled() -> Bool { true }

    func overruleIsWebOOPEnabled() -> Bool { true }

    func nonWebOOPAllowed() -> Bool { false }

    func getCBUUID_Service() -> String { return AnytimeGATT.primaryService.uuidString }

    func getCBUUID_Receive() -> String { return AnytimeGATT.primaryNotify.uuidString }
}
