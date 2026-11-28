//
//  CGMAiDexTransmitter.swift
//  xdrip
//
//  Direct Bluetooth driver for the AiDex X / LinX CGM, ported from JugglucoNG `drivers/aidex`
//  (GPL-3.0, see THIRD_PARTY_NOTICES.md). The protocol maths and the decisions that can be tested
//  without a radio live in `AiDexProtocol.swift`; this file owns the connection: the vendor key
//  exchange on F001/F002, the encrypted live frames on F003, the encrypted commands on F002 (startup
//  control, device information, session start and activation, history download) and the delivery of
//  the readings to xDrip.
//
//  Differences from the Android driver that the platform forces:
//  - iOS has no bond-state API. Pairing happens when an encrypted characteristic is accessed, so the
//    driver does not know whether the sensor is bonded; "this phone holds the pairing" means that a
//    PAIR key is stored for the sensor.
//  - The PAIR key lives in the Keychain (this device only) and is stored only after a CRC-valid live
//    frame proved it, as in JugglucoNG.
//  - The post-bond configuration write to F001 is skipped; the same startup request goes out on F002.
//  - The history download reaches back one day at most.
//
//  Never compiled here and never tried on a real sensor.
//

import CoreBluetooth
import Foundation
import os
import Security

// MARK: - Link problems and persisted device state

/// What went wrong last, shown on the device screen and cleared by the next reading.
enum AiDexLinkProblem: String, Codable {
    case linkLost
    case keyExchangeFailed
    case savedKeyRejected
    case pairingRefused
    case unsupportedFSeries
    case serialUnknown
    case noReadings
    case historyFailed
    case sensorNotStarted
    case sensorEnded
    case notAnAiDex
}

/// Everything the driver learns about one sensor, kept per Bluetooth address in UserDefaults so the
/// device screen can show it without a connection. Not part of Core Data (the entity only links to its
/// BLEPeripheral). It holds no secret: the PAIR key is in the Keychain (`AiDexPairKeyStore`).
struct AiDexDeviceState: Codable, Equatable {
    var advertisedName: String?
    var serial: String?
    var model: String?
    var manufacturer: String?
    var firmware: String?
    var hardware: String?
    /// Reported by the sensor's startup device info; nil until it answered.
    var wearDays: Int?
    var sensorStartDate: Date?
    /// True when the start came from the sensor's own session start (2AAA or 0x21), not from an offset.
    var startIsAuthoritative: Bool = false
    var activationRequestedAt: Date?
    var batteryMillivolts: Int?
    var lastReadingDate: Date?
    var historyRawNextIndex: Int = 0
    var historyBriefNextIndex: Int = 0
    var historyFallbackIndex: Int = 0
    var historyFallbackGlucose: Int = 0
    var problem: AiDexLinkProblem?
    var problemDate: Date?
}

enum AiDexDeviceStore {
    private static let keyPrefix = "aidex.deviceState."
    private static let lock = NSLock()

    static func load(address: String) -> AiDexDeviceState {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(address: address)
    }

    @discardableResult
    static func update(address: String, _ change: (inout AiDexDeviceState) -> Void) -> AiDexDeviceState {
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
    }

    private static func loadUnlocked(address: String) -> AiDexDeviceState {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + address),
              let state = try? JSONDecoder().decode(AiDexDeviceState.self, from: data) else {
            return AiDexDeviceState()
        }
        return state
    }
}

// MARK: - PAIR key in the Keychain

/// The 16-byte PAIR key the sensor hands out over F001, one Keychain item per Bluetooth address. It is
/// device-only (never synchronised, never in a backup) and never written to a trace: only
/// `fingerprint` leaves this type.
enum AiDexPairKeyStore {
    static let keyLength = 16
    private static let service = (Bundle.main.bundleIdentifier ?? "xdrip") + ".aidex"
    private static let lock = NSLock()

    private static func query(address: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "pairKey." + address,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func load(address: String) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        var request = query(address: address)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == keyLength else { return nil }
        return [UInt8](data)
    }

    static func hasKey(address: String) -> Bool {
        return load(address: address) != nil
    }

    @discardableResult
    static func save(_ key: [UInt8], address: String) -> Bool {
        guard key.count == keyLength else { return false }
        lock.lock()
        defer { lock.unlock() }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key),
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

    /// First four bytes of the key's MD5: enough to tell two keys apart in a trace, useless as a key.
    static func fingerprint(_ key: [UInt8]?) -> String {
        guard let key = key, !key.isEmpty else { return "none" }
        return AiDexParser.compactHex(Array(AiDexCrypto.md5(key).prefix(4)))
    }
}

// MARK: - Transmitter

class CGMAiDexTransmitter: BluetoothTransmitter, CGMTransmitter {

    private enum Phase {
        case connecting
        case settingUp
        case keyExchange
        case streaming
    }

    private enum StartupControlStage {
        case idle
        case waitDynamicAdvAck
        case waitAutoUpdateAck
        case complete
        case failed
    }

    private struct NotifyStep {
        let uuid: CBUUID
        let enabled: Bool
    }

    private struct SampleToDeliver {
        let date: Date
        let mgdl: Float
    }

    // MARK: - timing

    /// From the start of the key exchange (after the notifications are on) to a usable session key.
    private static let keyExchangeTimeout: TimeInterval = 35
    /// iOS may show its pairing prompt while the F001 notification is switched on; give the user time.
    private static let pairingPromptTimeout: TimeInterval = 90
    private static let keyExchangeMaxFailures = 3
    private static let bondRereadDelay: TimeInterval = 0.4
    private static let bondMaxRereads = 1
    private static let postKeyNotificationDelay: TimeInterval = 0.25
    private static let notifyStepTimeout: TimeInterval = 6
    private static let commandTimeout: TimeInterval = 8
    private static let commandNoResponseSpacing: TimeInterval = 0.06
    private static let retryDelay: TimeInterval = 3
    /// After a saved key used up its retries and the replacement pairing failed too, or the sensor refuses.
    private static let savedKeyCooldown: TimeInterval = 15 * 60
    private static let freshPairCooldown: TimeInterval = 5 * 60
    private static let startupControlAckTimeout: TimeInterval = 3
    private static let initialHistoryDelay: TimeInterval = 65
    private static let historyPageTimeout: TimeInterval = 25
    private static let historyRequestDelay: TimeInterval = 0.08
    private static let expectedLiveInterval: TimeInterval = 60
    private static let expectedLiveGrace: TimeInterval = 20
    private static let noStreamWatchdogDelay: TimeInterval = expectedLiveInterval + expectedLiveGrace
    /// No frame of any kind for this long while streaming: recycle the link.
    private static let silenceTimeout: TimeInterval = 5 * 60
    /// The history download never reaches back further than this (the sensor holds the whole session).
    private static let historyWindowMinutes = 24 * 60
    /// A session start this far from the stored one means another sensor.
    private static let newSensorStartTolerance: TimeInterval = 60 * 60
    /// An offset-derived start closer than this to the current one is not worth a correction.
    private static let inferredStartTolerance: TimeInterval = 10 * 60
    /// A sensor that still shows no session after this long gets no second activation.
    private static let activationRetryInterval: TimeInterval = 10 * 60
    private static let fallbackWearDays = 15
    /// Opcodes whose replies always carry a CRC trailer; a reply that fails it is dropped.
    private static let crcCheckedOpcodes: Set<Int> = [0x21, 0x22, 0x23, 0x24, 0x26, 0x27]

    // MARK: - properties

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMAiDex)

    /// Bumped on every connect and disconnect so delayed work of an older connection does nothing.
    private var connectionGeneration = 0
    private var phase: Phase = .connecting
    private var characteristics = [CBUUID: CBCharacteristic]()
    private var sessionBegun = false
    /// A specific problem recorded on this link is not overwritten by the generic "link lost".
    private var problemNotedOnThisLink = false
    private var released = false
    /// A reconnect after a refusal waits until this moment.
    private var reconnectNotBefore: Date?

    // identity and key exchange
    private var advertisedName: String?
    /// The local name of the advertisement that led to the first connection; the peripheral's own name
    /// may not be known yet when the services are discovered.
    private var discoveredAdvertisedName: String?
    private var serial: String?
    private var keyExchange: AiDexKeyExchange?
    private var usedSavedKey = false
    private var pairKeyAwaitingLiveValidation = false
    private var challengeWritten = false
    private var pairingRefusedOnThisLink = false
    private var bondReadPending = false
    private var bondDataRead = false
    private var shortBondReads = 0
    private var keyExchangeFailures = 0
    private var savedKeyExhausted = false
    private var keyExchangeFailureHandledOnThisLink = false
    private var keyExchangeToken = 0

    // notification switching, one characteristic at a time
    private var notifySteps = [NotifyStep]()
    private var notifyInFlight: NotifyStep?
    private var notifyCompletion: (() -> Void)?
    private var notifyToken = 0

    // F002 commands, one at a time
    private var commandQueue = [[UInt8]]()
    private var commandInFlight = false
    private var commandToken = 0

    // streaming
    private var streamingStartedAt: Date?
    private var lastF003At: Date?
    private var noStreamToken = 0
    private var silenceToken = 0
    private var noStreamRefreshAttempted = false
    private var startupControlStage: StartupControlStage = .idle
    private var startupControlToken = 0
    private var startupInfoAttempts = 0
    private var startupInfoLastRequestAt: Date?
    private var startupMetadataComplete = false
    private var pendingInitialHistoryRequest = false
    private var initialHistoryToken = 0
    private var autoActivationAttempted = false

    // session and time
    private var sensorStart: Date?
    private var hasAuthoritativeStart = false
    private var pendingNewSensorStart: Date?
    private var wearDays: Int?
    private var lastGlucoseTime: Date?
    private var lastOffsetMinutes = 0
    private var liveOffsetCutoff = 0

    // history
    private var historyDownloading = false
    private var historyNewestOffset = 0
    private var lastHistoryNewestOffset = 0
    private var historyRawNextIndex = 0
    private var historyBriefNextIndex = 0
    private var rawCursorLostItsCache = false
    private var calibratedGlucoseCache = [Int: Int]()
    private var lastCalibratedGlucoseFallback: Int?
    private var historyToken = 0

    // MARK: - initialization

    init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {
        var newAddressAndName: BluetoothTransmitter.DeviceAddressAndName = .notYetConnected(expectedName: nil)
        if let address = address {
            newAddressAndName = .alreadyConnectedBefore(address: address, name: name)
        }

        self.cgmTransmitterDelegate = cGMTransmitterDelegate

        // The sensor may not advertise the CGM service, so the first scan is unfiltered (foreground only);
        // later connections use the stored address. F003 carries the live frames, so the base class turns
        // its notifications on at discovery; F002 is the command characteristic.
        super.init(
            addressAndName: newAddressAndName,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [AiDexGATT.cgmService, AiDexGATT.deviceInfoService],
            CBUUID_ReceiveCharacteristic: AiDexGATT.f003.uuidString,
            CBUUID_WriteCharacteristic: AiDexGATT.f002.uuidString,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    // MARK: - persisted state helpers

    private func loadState() -> AiDexDeviceState? {
        guard let address = deviceAddress else { return nil }
        return AiDexDeviceStore.load(address: address)
    }

    private func updateState(_ change: (inout AiDexDeviceState) -> Void) {
        guard let address = deviceAddress else { return }
        AiDexDeviceStore.update(address: address, change)
    }

    private func loadSavedPairKey() -> [UInt8]? {
        guard let address = deviceAddress else { return nil }
        return AiDexPairKeyStore.load(address: address)
    }

    private func logLine(_ message: String, type: OSLogType = .info) {
        trace("%{public}@", log: log, category: ConstantsLog.categoryCGMAiDex, type: type, message)
    }

    private func noteProblem(_ problem: AiDexLinkProblem) {
        problemNotedOnThisLink = true
        logLine("AiDex link problem: \(problem.rawValue)")
        updateState {
            $0.problem = problem
            $0.problemDate = Date()
        }
    }

    // MARK: - connection lifecycle

    override func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // a stored address matches exactly
        if deviceAddress != nil {
            super.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
            return
        }

        // first connection: the first advertisement that looks like an AiDex sensor
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard Self.looksLikeAiDex(name) else { return }
        discoveredAdvertisedName = name
        logLine("in didDiscover, AiDex candidate found, rssi \(RSSI.intValue)")
        connectToDiscoveredPeripheral(peripheral)
    }

    /// An advertisement name that carries a serial behind a known family or brand prefix.
    private static func looksLikeAiDex(_ name: String?) -> Bool {
        guard let name = name, AiDexSerialIdentity.canonicalFromAdvertisement(name) != nil else { return false }
        return AiDexOpcodes.isAiDexDevice(name: name) || AiDexSerialIdentity.productBrandFromAdvertisement(name) != nil
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetConnectionState()
        super.centralManager(central, didConnect: peripheral)
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // a link that drops during the key exchange counts as a failed exchange: a pairing prompt the user
        // declines would otherwise come back on every reconnect
        if (phase == .settingUp || phase == .keyExchange) && !keyExchangeFailureHandledOnThisLink {
            handleKeyExchangeFailure("link-lost-during-key-exchange", linkAlreadyDown: true)
        }
        if !problemNotedOnThisLink, phase != .streaming || error != nil {
            noteProblem(.linkLost)
        }
        // the 0x23 values were only cached in memory: the next download starts them again
        if !calibratedGlucoseCache.isEmpty {
            rawCursorLostItsCache = true
        }
        invalidateConnection()
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func reconnectAfterDisconnect(_ central: CBCentralManager) {
        guard !released else { return }
        if let notBefore = reconnectNotBefore {
            let wait = notBefore.timeIntervalSinceNow
            if wait > 0 {
                logLine("in reconnectAfterDisconnect, waiting \(Int(wait)) s before the next connection attempt")
                runOnCentralQueue(after: wait) { [weak self] in
                    guard let self = self, !self.released else { return }
                    self.reconnectNotBefore = nil
                    self.performReconnect(central)
                }
                return
            }
            reconnectNotBefore = nil
        }
        super.reconnectAfterDisconnect(central)
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

    private func invalidateConnection() {
        connectionGeneration += 1
        keyExchangeToken += 1
        notifyToken += 1
        commandToken += 1
        noStreamToken += 1
        silenceToken += 1
        startupControlToken += 1
        initialHistoryToken += 1
        historyToken += 1
        notifySteps = []
        notifyInFlight = nil
        notifyCompletion = nil
        commandQueue = []
        commandInFlight = false
        historyDownloading = false
        phase = .connecting
    }

    private func resetConnectionState() {
        invalidateConnection()
        characteristics.removeAll()
        sessionBegun = false
        problemNotedOnThisLink = false

        keyExchange = nil
        usedSavedKey = false
        pairKeyAwaitingLiveValidation = false
        challengeWritten = false
        pairingRefusedOnThisLink = false
        bondReadPending = false
        bondDataRead = false
        shortBondReads = 0
        keyExchangeFailureHandledOnThisLink = false

        streamingStartedAt = nil
        lastF003At = nil
        noStreamRefreshAttempted = false
        startupControlStage = .idle
        startupInfoAttempts = 0
        startupInfoLastRequestAt = nil
        pendingInitialHistoryRequest = false
        autoActivationAttempted = false
        pendingNewSensorStart = nil
        lastOffsetMinutes = 0
        liveOffsetCutoff = 0
        historyNewestOffset = 0
        lastHistoryNewestOffset = 0
        calibratedGlucoseCache.removeAll()
        lastCalibratedGlucoseFallback = nil

        let state = loadState()
        advertisedName = state?.advertisedName
        serial = state?.serial
        sensorStart = state?.sensorStartDate
        hasAuthoritativeStart = state?.startIsAuthoritative ?? false
        wearDays = state?.wearDays
        lastGlucoseTime = state?.lastReadingDate
        historyRawNextIndex = state?.historyRawNextIndex ?? 0
        historyBriefNextIndex = state?.historyBriefNextIndex ?? 0
        // 0x24 rows are stored with the 0x23 glucose cached in memory; a raw cursor ahead of the brief
        // cursor means that cache was lost
        rawCursorLostItsCache = historyRawNextIndex > historyBriefNextIndex
        startupMetadataComplete = (state?.wearDays != nil) && !(state?.firmware ?? "").isEmpty && !(state?.model ?? "").isEmpty
        restoreHistoryFallback()
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

        guard characteristics[AiDexGATT.f001] != nil, characteristics[AiDexGATT.f002] != nil, characteristics[AiDexGATT.f003] != nil else {
            // a device that matched by name but has no vendor service: stop connecting to it
            noteProblem(.notAnAiDex)
            disconnectAndForget()
            return
        }
        sessionBegun = true

        for candidate in [deviceName, discoveredAdvertisedName] {
            if let name = candidate, let canonical = AiDexSerialIdentity.canonicalFromAdvertisement(name) {
                advertisedName = name
                serial = canonical
                updateState {
                    $0.advertisedName = name
                    $0.serial = canonical
                }
                break
            }
        }
        guard let sensorSerial = serial else {
            // the serial is the whole key derivation: without it nothing can be done
            noteProblem(.serialUnknown)
            reconnectNotBefore = Date().addingTimeInterval(Self.freshPairCooldown)
            disconnect()
            return
        }

        // F-generation sensors need pairing keys from the manufacturer's cloud, which this app does not
        // use; only a key that is already stored could still work
        let savedKey = loadSavedPairKey()
        if AiDexKeyRequirement.requiresProvisionedKeys(advertisedName: advertisedName ?? deviceName) && savedKey == nil {
            noteProblem(.unsupportedFSeries)
            disconnectAndForget()
            return
        }

        let hasSavedKey = savedKey != nil
        let startAction = AiDexKeyExchangePolicy.decidePairKeyStartAction(
            hasSavedPairKey: hasSavedKey,
            savedKeyExhausted: savedKeyExhausted,
            explicitPairRequested: false,
            pairedHere: hasSavedKey,
            pairKeyResetPending: false
        )

        let exchange = AiDexKeyExchange(serial: sensorSerial)
        var steps = [
            NotifyStep(uuid: AiDexGATT.f003, enabled: true),
            NotifyStep(uuid: AiDexGATT.f002, enabled: true)
        ]
        switch startAction {
        case .useSavedKey:
            if let savedKey = savedKey {
                exchange.onPairKeyReceived(savedKey)
            }
            usedSavedKey = true
        case .freshPair:
            usedSavedKey = false
            // switching F001 on needs an encrypted link: this is where iOS asks to pair
            steps.append(NotifyStep(uuid: AiDexGATT.f001, enabled: true))
        }
        keyExchange = exchange
        phase = .settingUp
        if usedSavedKey {
            logLine("in servicesDiscovered, key exchange with the saved key, fp \(AiDexPairKeyStore.fingerprint(savedKey))")
        } else {
            logLine("in servicesDiscovered, key exchange with a fresh pairing")
        }
        armKeyExchangeWatchdog(usedSavedKey ? Self.keyExchangeTimeout : Self.pairingPromptTimeout)
        runNotifyChain(steps) { [weak self] in
            self?.notificationsReady()
        }
    }

    // MARK: - notification switching

    private func runNotifyChain(_ steps: [NotifyStep], completion: @escaping () -> Void) {
        notifySteps = steps
        notifyInFlight = nil
        notifyCompletion = completion
        advanceNotifyChain()
    }

    private func advanceNotifyChain() {
        notifyInFlight = nil
        guard !notifySteps.isEmpty else {
            let completion = notifyCompletion
            notifyCompletion = nil
            completion?()
            return
        }
        let step = notifySteps.removeFirst()
        guard let characteristic = characteristics[step.uuid] else {
            advanceNotifyChain()
            return
        }
        // the base class already switched F003 on at discovery
        if characteristic.isNotifying == step.enabled {
            advanceNotifyChain()
            return
        }

        notifyInFlight = step
        notifyToken += 1
        let token = notifyToken
        let generation = connectionGeneration
        setNotifyValue(step.enabled, for: characteristic)

        let timeout = step.uuid == AiDexGATT.f001 ? Self.pairingPromptTimeout : Self.notifyStepTimeout
        runOnCentralQueue(after: timeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.notifyToken == token, self.notifyInFlight != nil else { return }
            let direction = step.enabled ? "on" : "off"
            self.logLine("in notification chain, no answer for \(step.uuid.uuidString) (\(direction))")
            if step.uuid == AiDexGATT.f001 && step.enabled {
                self.handleKeyExchangeFailure("f001-notification-timeout")
            } else {
                self.advanceNotifyChain()
            }
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)

        guard let step = notifyInFlight, step.uuid == characteristic.uuid else { return }
        if error != nil && step.enabled {
            // an encrypted characteristic that cannot be switched on: the pairing did not happen
            if step.uuid == AiDexGATT.f001 {
                pairingRefusedOnThisLink = true
            }
            handleKeyExchangeFailure("notification-\(step.uuid.uuidString)-error")
            return
        }
        advanceNotifyChain()
    }

    // MARK: - key exchange

    private func armKeyExchangeWatchdog(_ seconds: TimeInterval) {
        keyExchangeToken += 1
        let token = keyExchangeToken
        let generation = connectionGeneration
        runOnCentralQueue(after: seconds) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.keyExchangeToken == token else { return }
            guard self.phase == .settingUp || self.phase == .keyExchange else { return }
            self.handleKeyExchangeFailure("watchdog")
        }
    }

    private func notificationsReady() {
        guard phase == .settingUp else { return }
        phase = .keyExchange
        armKeyExchangeWatchdog(Self.keyExchangeTimeout)

        if usedSavedKey {
            readBondData()
            return
        }

        guard let exchange = keyExchange, let f001 = characteristics[AiDexGATT.f001] else {
            handleKeyExchangeFailure("f001-unavailable")
            return
        }
        // the challenge derives from the serial: keep it out of the trace
        challengeWritten = writeDataToPeripheral(data: Data(exchange.getChallenge()), characteristicToWriteTo: f001, type: .withResponse, logPayload: false)
        if !challengeWritten {
            handleKeyExchangeFailure("f001-write-rejected")
        }
    }

    private func readBondData() {
        guard let f002 = characteristics[AiDexGATT.f002] else {
            handleKeyExchangeFailure("f002-unavailable")
            return
        }
        bondReadPending = true
        readValueForCharacteristic(for: f002)
    }

    /// F001 answers with the PAIR key (16 bytes or more) or, when the sensor does not accept the
    /// challenge, with a single zero byte. Handled apart from the other values because the base class
    /// would write the PAIR key into the trace.
    private func handleF001Value(_ characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)

        if bytes.count < AiDexPairKeyStore.keyLength {
            logLine("in handleF001Value, answer of \(bytes.count) byte(s)")
            if bytes.count == 1 && bytes[0] == 0 {
                pairingRefusedOnThisLink = true
                noteProblem(.pairingRefused)
            }
            return
        }
        guard challengeWritten, let exchange = keyExchange, exchange.pairKey == nil else { return }

        let pairKey = Array(bytes[0..<AiDexPairKeyStore.keyLength])
        exchange.onPairKeyReceived(pairKey)
        logLine("in handleF001Value, PAIR key received (fp \(AiDexPairKeyStore.fingerprint(pairKey))), waiting for a live frame to prove it")
        readBondData()
    }

    /// The reply to the F002 read: 17 bytes of BOND data, or the sensor declining to give them.
    private func handleBondReadReply(_ bytes: [UInt8]) {
        switch AiDexKeyExchangePolicy.decideShortBondReadAction(replyLength: bytes.count, rereads: shortBondReads, maxRereads: Self.bondMaxRereads) {
        case .accept:
            handleBondData(bytes)
        case .reread:
            shortBondReads += 1
            logLine("in handleBondReadReply, \(bytes.count) byte(s) instead of 17, reading again")
            let generation = connectionGeneration
            runOnCentralQueue(after: Self.bondRereadDelay) { [weak self] in
                guard let self = self, self.connectionGeneration == generation, self.phase == .keyExchange, !self.bondDataRead else { return }
                self.readBondData()
            }
        case .failKeyExchange:
            logLine("in handleBondReadReply, the sensor refused the BOND data (\(bytes.count) byte(s))", type: .error)
            handleKeyExchangeFailure("bond-read-refused")
        }
    }

    private func handleBondData(_ bytes: [UInt8]) {
        guard !bondDataRead else { return }
        bondDataRead = true

        guard let exchange = keyExchange, exchange.decryptBond(bytes) else {
            logLine("in handleBondData, BOND decryption or CRC failed (saved key \(usedSavedKey))", type: .error)
            handleKeyExchangeFailure("bond-decrypt")
            return
        }
        // a key the sensor just handed out is stored only after a live frame decrypted with it
        pairKeyAwaitingLiveValidation = !usedSavedKey
        logLine("in handleBondData, session key established, waiting for a valid live frame")

        if usedSavedKey {
            enterStreamingPhase()
            return
        }
        // The sensor drops the notification registrations made before the pairing completed: switch F003
        // and F002 off and on again, then start.
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.postKeyNotificationDelay) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.phase == .keyExchange else { return }
            let steps = [
                NotifyStep(uuid: AiDexGATT.f003, enabled: false),
                NotifyStep(uuid: AiDexGATT.f002, enabled: false),
                NotifyStep(uuid: AiDexGATT.f003, enabled: true),
                NotifyStep(uuid: AiDexGATT.f002, enabled: true)
            ]
            self.runNotifyChain(steps) { [weak self] in
                guard let self = self, self.connectionGeneration == generation, self.phase == .keyExchange else { return }
                self.enterStreamingPhase()
            }
        }
    }

    /// One key exchange did not produce a working session. A saved key is retained through every failure;
    /// a fresh pair has nothing stored yet. Retry a bounded number of times, then replace a saved key by
    /// pairing again (the new key replaces it only after a CRC-valid live frame) or wait out a cooldown.
    private func handleKeyExchangeFailure(_ reason: String, linkAlreadyDown: Bool = false) {
        guard !keyExchangeFailureHandledOnThisLink else { return }
        keyExchangeFailureHandledOnThisLink = true

        let wasUsingSavedKey = usedSavedKey
        let refused = pairingRefusedOnThisLink
        let hasSavedKey = loadSavedPairKey() != nil
        keyExchangeFailures += 1
        logLine("in handleKeyExchangeFailure, \(reason) (\(keyExchangeFailures)/\(Self.keyExchangeMaxFailures), saved key \(wasUsingSavedKey))", type: .error)

        keyExchangeToken += 1
        notifyToken += 1
        notifySteps = []
        notifyInFlight = nil
        notifyCompletion = nil
        keyExchange = nil
        pairKeyAwaitingLiveValidation = false
        challengeWritten = false
        bondReadPending = false
        bondDataRead = false
        phase = .connecting

        let action = AiDexKeyExchangePolicy.decideFailureAction(
            consecutiveFailures: keyExchangeFailures,
            maxFailures: Self.keyExchangeMaxFailures,
            usedSavedKey: wasUsingSavedKey,
            pairedHere: hasSavedKey,
            freshPairAfterReset: false
        )
        switch action {
        case .retryCleanLink:
            noteProblem(refused ? .pairingRefused : .keyExchangeFailed)
            reconnectNotBefore = Date().addingTimeInterval(Self.retryDelay * Double(keyExchangeFailures))
        case .replaceSavedKey:
            // this phone holds the pairing: ask the sensor for a new key on the next connection
            savedKeyExhausted = true
            keyExchangeFailures = 0
            noteProblem(.savedKeyRejected)
            reconnectNotBefore = Date().addingTimeInterval(Self.retryDelay)
        case .restoreSavedKey, .giveUp:
            noteProblem(hasSavedKey ? .savedKeyRejected : (refused ? .pairingRefused : .keyExchangeFailed))
            keyExchangeFailures = 0
            // after the cooldown the saved key gets its turn again
            savedKeyExhausted = false
            reconnectNotBefore = Date().addingTimeInterval(hasSavedKey ? Self.savedKeyCooldown : Self.freshPairCooldown)
        }

        if !linkAlreadyDown {
            disconnect()
        }
    }

    // MARK: - streaming

    private func enterStreamingPhase() {
        keyExchangeToken += 1
        phase = .streaming
        let now = Date()
        streamingStartedAt = now
        noStreamRefreshAttempted = false
        startupControlStage = .idle
        logLine("in enterStreamingPhase, waiting for the first live frame")

        scheduleNoStreamWatchdog()
        scheduleSilenceWatchdog()

        beginStartupControl()
        readDeviceAndSessionCharacteristics()
        requestStartupDeviceInfoIfNeeded()

        // history starts with the first live frame; this is the fallback when none arrives
        pendingInitialHistoryRequest = true
        initialHistoryToken += 1
        let token = initialHistoryToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.initialHistoryDelay) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.initialHistoryToken == token else { return }
            guard self.phase == .streaming, self.pendingInitialHistoryRequest, !self.historyDownloading else { return }
            self.logLine("in initial history timer, no live frame yet, starting the history download")
            self.requestHistoryRange()
        }
    }

    private func hasLiveFrameSinceStreamingStart() -> Bool {
        guard let started = streamingStartedAt, let last = lastF003At else { return false }
        return last >= started
    }

    private func scheduleNoStreamWatchdog() {
        noStreamToken += 1
        guard phase == .streaming, !hasLiveFrameSinceStreamingStart() else { return }
        let token = noStreamToken
        let generation = connectionGeneration
        let delay = AiDexStreamingPolicy.resolveNoStreamWatchdogDelay(
            defaultDelay: Self.noStreamWatchdogDelay,
            now: Date(),
            latestKnownReading: lastGlucoseTime,
            expectedLiveInterval: Self.expectedLiveInterval,
            expectedLiveGrace: Self.expectedLiveGrace
        )
        runOnCentralQueue(after: delay) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.noStreamToken == token else { return }
            self.noStreamWatchdogFired()
        }
    }

    private func noStreamWatchdogFired() {
        guard phase == .streaming, !hasLiveFrameSinceStreamingStart() else { return }
        let action = AiDexStreamingPolicy.decideNoStreamRecovery(historyDownloading: historyDownloading, liveNotificationRefreshAttempted: noStreamRefreshAttempted)
        switch action {
        case .keepWaiting:
            logLine("in noStreamWatchdog, no live frame yet but the history download is running")
            scheduleNoStreamWatchdog()
        case .refreshLiveNotifications:
            noStreamRefreshAttempted = true
            logLine("in noStreamWatchdog, no live frame yet, switching the F003 and F002 notifications off and on")
            let generation = connectionGeneration
            let steps = [
                NotifyStep(uuid: AiDexGATT.f003, enabled: false),
                NotifyStep(uuid: AiDexGATT.f002, enabled: false),
                NotifyStep(uuid: AiDexGATT.f003, enabled: true),
                NotifyStep(uuid: AiDexGATT.f002, enabled: true)
            ]
            runNotifyChain(steps) { [weak self] in
                guard let self = self, self.connectionGeneration == generation else { return }
                self.scheduleNoStreamWatchdog()
            }
        case .reconnect:
            if usedSavedKey || pairKeyAwaitingLiveValidation {
                // a session key that never produced a frame: count it as a failed exchange
                handleKeyExchangeFailure("no-valid-live-frame")
            } else {
                logLine("in noStreamWatchdog, still no live frame, reconnecting")
                noteProblem(.noReadings)
                disconnect()
            }
        }
    }

    private func scheduleSilenceWatchdog() {
        silenceToken += 1
        let token = silenceToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.silenceTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.silenceToken == token else { return }
            guard self.phase == .streaming else { return }
            self.logLine("in silenceWatchdog, nothing received for \(Int(Self.silenceTimeout)) seconds, reconnecting")
            self.noteProblem(.noReadings)
            self.disconnect()
        }
    }

    // MARK: - startup control

    private var commandBuilder: AiDexCommandBuilder? {
        guard let exchange = keyExchange, exchange.isComplete else { return nil }
        return AiDexCommandBuilder(keyExchange: exchange)
    }

    /// Dynamic advertising mode, then automatic status updates, each acknowledged by the sensor. A stalled
    /// step is skipped after a few seconds: the live frames do not depend on it.
    private func beginStartupControl() {
        guard phase == .streaming, startupControlStage == .idle else { return }
        guard let command = commandBuilder?.setDynamicAdvMode(1) else {
            startupControlStage = .failed
            return
        }
        startupControlStage = .waitDynamicAdvAck
        armStartupControlTimeout()
        sendCommand(command)
    }

    private func armStartupControlTimeout() {
        startupControlToken += 1
        let token = startupControlToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.startupControlAckTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.startupControlToken == token else { return }
            if self.startupControlStage == .waitDynamicAdvAck || self.startupControlStage == .waitAutoUpdateAck {
                self.logLine("in startup control, no acknowledgement, going on without it")
                self.startupControlStage = .failed
            }
        }
    }

    private func handleDynamicAdvModeAck() {
        guard startupControlStage == .waitDynamicAdvAck else { return }
        guard let command = commandBuilder?.setAutoUpdateStatus(enabled: true) else {
            startupControlStage = .failed
            return
        }
        startupControlStage = .waitAutoUpdateAck
        armStartupControlTimeout()
        sendCommand(command)
    }

    private func handleAutoUpdateStatusAck() {
        guard startupControlStage == .waitAutoUpdateAck else { return }
        startupControlToken += 1
        startupControlStage = .complete
        logLine("in startup control, automatic status updates are on")
    }

    private func markStartupControlComplete() {
        guard startupControlStage == .waitDynamicAdvAck || startupControlStage == .waitAutoUpdateAck else { return }
        startupControlToken += 1
        startupControlStage = .complete
    }

    // MARK: - device information and session start

    private func readDeviceAndSessionCharacteristics() {
        let uuids = [AiDexGATT.modelNumber, AiDexGATT.softwareRevision, AiDexGATT.manufacturer, AiDexGATT.sessionStart, AiDexGATT.sessionRun]
        for uuid in uuids {
            if let characteristic = characteristics[uuid] {
                readValueForCharacteristic(for: characteristic)
            }
        }
    }

    private func readSessionStart() {
        if let characteristic = characteristics[AiDexGATT.sessionStart] {
            readValueForCharacteristic(for: characteristic)
        }
    }

    private func handleDeviceInformation(_ uuid: CBUUID, _ bytes: [UInt8]) {
        let text = (String(bytes: bytes, encoding: .utf8) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} ").union(.whitespacesAndNewlines))
        guard !text.isEmpty else { return }
        updateState {
            switch uuid {
            case AiDexGATT.modelNumber:
                // the startup device info (0x10) names the model too and wins when it came first
                if ($0.model ?? "").isEmpty { $0.model = text }
            case AiDexGATT.softwareRevision:
                $0.firmware = text
            case AiDexGATT.manufacturer:
                $0.manufacturer = text
            default:
                break
            }
        }
        if let state = loadState(), (state.model ?? "").isEmpty == false, (state.firmware ?? "").isEmpty == false, state.wearDays != nil {
            startupMetadataComplete = true
        }
    }

    private func handleSessionStartValue(_ bytes: [UInt8]) {
        guard let parsed = AiDexParser.parseLocalStartTimePayload(bytes) else {
            logLine("in handleSessionStartValue, payload of \(bytes.count) bytes is not a session start")
            return
        }
        applySessionStart(parsed, source: "2AAA", allowActivation: true)
    }

    private func applySessionStart(_ parsed: AiDexLocalStartTime, source: String, allowActivation: Bool) {
        if parsed.isAllZeros {
            logLine("in applySessionStart, \(source) reports no session")
            hasAuthoritativeStart = false
            updateState { $0.startIsAuthoritative = false }
            guard allowActivation else { return }
            if autoActivationAttempted {
                logLine("in applySessionStart, still no session after the activation, waiting for the first reading")
                return
            }
            if let last = loadState()?.activationRequestedAt, Date().timeIntervalSince(last) < Self.activationRetryInterval {
                noteProblem(.sensorNotStarted)
                return
            }
            startNewSensor()
            return
        }

        guard let start = parsed.date(now: Date()) else {
            logLine("in applySessionStart, \(source) start time is out of range")
            return
        }
        setSensorStart(start, authoritative: true)
        checkSensorEnded()
    }

    /// SET_NEW_SENSOR with the phone's local time: a sensor that reports no session is started.
    private func startNewSensor() {
        let now = Date()
        autoActivationAttempted = true
        hasAuthoritativeStart = false

        // a new session: its history starts from scratch
        historyRawNextIndex = 0
        historyBriefNextIndex = 0
        calibratedGlucoseCache.removeAll()
        lastCalibratedGlucoseFallback = nil
        liveOffsetCutoff = 0
        persistCursors()
        updateState {
            $0.activationRequestedAt = now
            $0.startIsAuthoritative = false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let zone = AiDexActivationTimeZone.make(date: now, timeZone: TimeZone.current)
        logLine("in startNewSensor, the sensor reports no session: starting it")
        sendCommand(commandBuilder?.setNewSensor(
            year: parts.year ?? 0,
            month: parts.month ?? 0,
            day: parts.day ?? 0,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: parts.second ?? 0,
            tzQuarters: zone.tzQuarters,
            dstQuarters: zone.dstQuarters
        ))
    }

    private func handleNewSensorAck(_ plaintext: [UInt8]) {
        guard plaintext.count >= 2 else { return }
        let status = Int(plaintext[1])
        logLine("in handleNewSensorAck, status \(status)")
        guard status == 0 else { return }
        let generation = connectionGeneration
        runOnCentralQueue(after: 1) { [weak self] in
            guard let self = self, self.connectionGeneration == generation else { return }
            self.readSessionStart()
        }
    }

    /// Moves the stored start. A start that is more than an hour from the stored one belongs to another
    /// sensor: xDrip is told, and the history cursors of the old session are dropped.
    private func setSensorStart(_ date: Date, authoritative: Bool) {
        var isNewSensor = false
        if let current = sensorStart {
            if abs(current.timeIntervalSince(date)) > Self.newSensorStartTolerance {
                isNewSensor = true
            }
        } else {
            isNewSensor = true
        }

        if isNewSensor && sensorStart != nil {
            historyRawNextIndex = 0
            historyBriefNextIndex = 0
            historyNewestOffset = 0
            lastHistoryNewestOffset = 0
            calibratedGlucoseCache.removeAll()
            lastCalibratedGlucoseFallback = nil
            liveOffsetCutoff = 0
            lastOffsetMinutes = 0
            persistCursors()
        }

        sensorStart = date
        if authoritative {
            hasAuthoritativeStart = true
        }
        if isNewSensor {
            pendingNewSensorStart = date
        }
        let authoritativeNow = hasAuthoritativeStart
        updateState {
            $0.sensorStartDate = date
            $0.startIsAuthoritative = authoritativeNow
        }
    }

    /// A start derived from an offset, used until the sensor's own session start arrives.
    private func ensureSensorStartTime(now: Date, trustedOffset: Int?) {
        if hasAuthoritativeStart && sensorStart != nil { return }
        let effective = trustedOffset ?? (lastOffsetMinutes > 0 ? lastOffsetMinutes : nil)
        guard let offset = effective, offset > 0 else { return }
        let inferred = now.addingTimeInterval(-Double(offset) * 60)
        if let current = sensorStart, abs(current.timeIntervalSince(inferred)) <= Self.inferredStartTolerance { return }
        setSensorStart(inferred, authoritative: false)
    }

    private func checkSensorEnded() {
        guard let start = sensorStart, let days = wearDays, days > 0 else { return }
        if Date() > start.addingTimeInterval(Double(days) * 24 * 3600) {
            noteProblem(.sensorEnded)
        }
    }

    // MARK: - values and writes

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        if uuid == AiDexGATT.f001 {
            // not passed to the base class: it traces every value and this one is the PAIR key
            handleF001Value(characteristic, error: error)
            return
        }

        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)

        if error != nil {
            // a failed BOND read counts like a short one; the other reads may simply stay unanswered
            if uuid == AiDexGATT.f002 && bondReadPending {
                bondReadPending = false
                handleBondReadReply([])
            }
            return
        }
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)

        switch uuid {
        case AiDexGATT.f002:
            if bondReadPending {
                bondReadPending = false
                handleBondReadReply(bytes)
            } else {
                handleF002Response(bytes)
            }
        case AiDexGATT.f003:
            handleF003(bytes)
        case AiDexGATT.modelNumber, AiDexGATT.softwareRevision, AiDexGATT.manufacturer:
            handleDeviceInformation(uuid, bytes)
        case AiDexGATT.sessionStart:
            handleSessionStartValue(bytes)
        case AiDexGATT.sessionRun:
            if bytes.count >= 2 {
                logLine("in didUpdateValueFor, session run time \(Int(bytes[0]) | (Int(bytes[1]) << 8)) minutes")
            }
        default:
            break
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didWriteValueFor: characteristic, error: error)

        if characteristic.uuid == AiDexGATT.f001 {
            if error != nil && phase == .keyExchange {
                handleKeyExchangeFailure("f001-write-error")
            }
            return
        }
        if characteristic.uuid == AiDexGATT.f002 {
            if error != nil {
                logLine("in didWriteValueFor, the F002 write failed", type: .error)
            }
            commandToken += 1
            commandInFlight = false
            drainCommandQueue()
        }
    }

    // MARK: - F002 command queue

    private func sendCommand(_ command: [UInt8]?) {
        guard let command = command else {
            logLine("in sendCommand, no session key yet", type: .error)
            return
        }
        commandQueue.append(command)
        drainCommandQueue()
    }

    private func drainCommandQueue() {
        guard !commandInFlight, !commandQueue.isEmpty else { return }
        guard let f002 = characteristics[AiDexGATT.f002] else {
            commandQueue.removeAll()
            return
        }
        let command = commandQueue.removeFirst()
        let withoutResponse = f002.properties.contains(.writeWithoutResponse)

        commandInFlight = true
        commandToken += 1
        let token = commandToken
        let generation = connectionGeneration
        let sent = writeDataToPeripheral(data: Data(command), characteristicToWriteTo: f002, type: withoutResponse ? .withoutResponse : .withResponse)
        guard sent else {
            commandInFlight = false
            commandQueue.removeAll()
            return
        }
        // a write without response has no confirmation to wait for; a write with response has one, and the
        // timer only guards against a confirmation that never comes
        let wait = withoutResponse ? Self.commandNoResponseSpacing : Self.commandTimeout
        runOnCentralQueue(after: wait) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.commandToken == token, self.commandInFlight else { return }
            self.commandInFlight = false
            self.drainCommandQueue()
        }
    }

    // MARK: - F003: live frames

    private func handleF003(_ bytes: [UInt8]) {
        let now = Date()
        guard let exchange = keyExchange, exchange.isComplete, phase == .streaming else { return }
        lastF003At = now
        noStreamToken += 1
        scheduleSilenceWatchdog()

        switch AiDexParser.classifyFrame(bytes) {
        case .status:
            handleStatusFrame(bytes, exchange: exchange)
            return
        case .unknown:
            // 13-byte frames follow calibration commands; this driver sends none
            logLine("in handleF003, frame of \(bytes.count) bytes ignored")
            return
        case .data:
            break
        }

        guard let decrypted = exchange.decrypt(bytes), let frame = AiDexParser.parseDataFrame(decrypted) else {
            logLine("in handleF003, the frame could not be decrypted or parsed", type: .error)
            return
        }
        guard AiDexParser.dataFrameCrcMatches(decrypted, frame: frame) else {
            logLine("in handleF003, CRC mismatch, frame dropped", type: .error)
            return
        }
        guard frame.isValid else {
            logLine("in handleF003, no valid reading yet (sentinel or out of range)")
            return
        }

        // a CRC-valid frame proves the session key and so the PAIR key behind it
        if pairKeyAwaitingLiveValidation, let candidate = exchange.pairKey, let address = deviceAddress {
            if AiDexPairKeyStore.save(candidate, address: address) {
                pairKeyAwaitingLiveValidation = false
                logLine("in handleF003, PAIR key stored after a valid live frame (fp \(AiDexPairKeyStore.fingerprint(candidate)))")
            } else {
                logLine("in handleF003, the PAIR key could not be stored, will try again with the next frame", type: .error)
            }
        }
        keyExchangeFailures = 0
        savedKeyExhausted = false
        pairingRefusedOnThisLink = false

        handleLiveFrame(frame, now: now)
    }

    private func offsetContext() -> AiDexOffsetContext {
        var context = AiDexOffsetContext()
        context.historyNewestOffset = historyNewestOffset
        context.lastOffsetMinutes = lastOffsetMinutes
        context.lastHistoryNewestOffset = lastHistoryNewestOffset
        context.sensorStart = sensorStart
        context.hasAuthoritativeSessionStart = hasAuthoritativeStart
        context.lastGlucoseTime = lastGlucoseTime
        return context
    }

    private func handleLiveFrame(_ frame: AiDexGlucoseFrame, now: Date) {
        let resolution = AiDexLiveOffset.resolveTrusted(wireOffset: frame.timeOffsetMinutes, now: now, context: offsetContext())
        if let note = resolution.note {
            logLine("in handleLiveFrame, timing: \(note)")
        }
        let trustedOffset = resolution.offset
        if let trusted = trustedOffset {
            lastOffsetMinutes = trusted
            if trusted > liveOffsetCutoff {
                liveOffsetCutoff = trusted
            }
            if !AiDexHistoryPolicy.isWithinWearDuration(offsetMinutes: trusted, wearDays: wearDays) {
                logLine("in handleLiveFrame, the frame is past the wear time, ignored")
                noteProblem(.sensorEnded)
                return
            }
        }

        markStartupControlComplete()

        // the history follows the first live frame
        if pendingInitialHistoryRequest && !historyDownloading {
            logLine("in handleLiveFrame, first live frame, starting the history download")
            requestHistoryRange()
        }

        ensureSensorStartTime(now: now, trustedOffset: trustedOffset)
        let sampleDate = AiDexHistoryPolicy.resolveOffsetBackedTimestamp(observedAt: now, sensorStart: sensorStart, offsetMinutes: trustedOffset)
        guard AiDexHistoryPolicy.shouldAcceptRealtimeTimestamp(candidate: sampleDate, latestAccepted: lastGlucoseTime) else {
            logLine("in handleLiveFrame, a sample older than the newest one, dropped")
            return
        }
        lastGlucoseTime = sampleDate
        deliver([SampleToDeliver(date: sampleDate, mgdl: frame.glucoseMgDl)], live: true)
    }

    /// 5-byte keepalive: bytes 1-2 are the battery voltage in millivolts, as the vendor driver reads them.
    private func handleStatusFrame(_ bytes: [UInt8], exchange: AiDexKeyExchange) {
        guard let decrypted = exchange.decrypt(bytes), decrypted.count >= 3 else { return }
        let millivolts = Int(decrypted[1]) | (Int(decrypted[2]) << 8)
        guard millivolts >= 500 && millivolts <= 3500 else { return }
        updateState { $0.batteryMillivolts = millivolts }
    }

    // MARK: - F002: command responses

    private func handleF002Response(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let exchange = keyExchange, exchange.isComplete, phase == .streaming,
              let plaintext = exchange.decrypt(bytes), !plaintext.isEmpty else { return }

        let crcValid = plaintext.count < 3 || AiDexCrc16.validateResponse(plaintext)
        let opcode = Int(plaintext[0])
        if !crcValid && Self.crcCheckedOpcodes.contains(opcode) {
            logLine("in handleF002Response, CRC failed for opcode \(opcode), reply dropped", type: .error)
            return
        }

        switch opcode {
        case AiDexOpcodes.getStartupDeviceInfo:
            handleStartupDeviceInfoResponse(plaintext)
        case AiDexOpcodes.getLocalStartTime:
            handleLegacyStartTimeResponse(plaintext)
        case AiDexOpcodes.getHistoryRange:
            handleHistoryRangeResponse(plaintext)
        case AiDexOpcodes.getHistoriesRaw:
            handleHistoryRawResponse(plaintext)
        case AiDexOpcodes.getHistories:
            handleHistoryBriefResponse(plaintext)
        case AiDexOpcodes.setNewSensor:
            handleNewSensorAck(plaintext)
        case AiDexOpcodes.setDynamicAdvMode:
            handleDynamicAdvModeAck()
        case AiDexOpcodes.setAutoUpdateStatus:
            handleAutoUpdateStatusAck()
        default:
            logLine("in handleF002Response, opcode \(opcode) of \(plaintext.count) bytes not used")
        }
    }

    // MARK: startup device info (0x10) and legacy start time (0x21)

    private func requestStartupDeviceInfoIfNeeded() {
        guard phase == .streaming else { return }
        let now = Date()
        guard AiDexStreamingPolicy.shouldRequestStartupDeviceInfo(
            startupMetadataComplete: startupMetadataComplete,
            attemptsThisConnection: startupInfoAttempts,
            lastRequestAt: startupInfoLastRequestAt,
            now: now
        ) else { return }

        startupInfoAttempts += 1
        startupInfoLastRequestAt = now
        sendCommand(commandBuilder?.getStartupDeviceInfo())

        // asked again later while the sensor stays silent about it
        let generation = connectionGeneration
        runOnCentralQueue(after: AiDexStreamingPolicy.startupDeviceInfoRetrySpacing) { [weak self] in
            guard let self = self, self.connectionGeneration == generation else { return }
            self.requestStartupDeviceInfoIfNeeded()
        }
    }

    private func handleStartupDeviceInfoResponse(_ plaintext: [UInt8]) {
        let end = (plaintext.count >= 4 && AiDexCrc16.validateResponse(plaintext)) ? plaintext.count - 2 : plaintext.count
        guard end > 1 else { return }
        guard let info = AiDexParser.parseStartupDeviceInfoFrame(plaintext, payloadEndExclusive: end) else {
            logLine("in handleStartupDeviceInfoResponse, unsupported payload of \(plaintext.count) bytes")
            return
        }
        if info.wearDays > 0 {
            wearDays = info.wearDays
        }
        updateState {
            if ($0.firmware ?? "").isEmpty { $0.firmware = info.firmwareVersion }
            $0.hardware = info.hardwareVersion
            $0.model = info.modelName
            if info.wearDays > 0 { $0.wearDays = info.wearDays }
        }
        startupMetadataComplete = true
        logLine("in handleStartupDeviceInfoResponse, model \(info.modelName), firmware \(info.firmwareVersion), hardware \(info.hardwareVersion), \(info.wearDays) days")
        checkSensorEnded()

        // the legacy request names the session start for a sensor whose 2AAA is empty or unread
        if !hasAuthoritativeStart {
            sendCommand(commandBuilder?.getLegacyStartTime())
        }
    }

    private func handleLegacyStartTimeResponse(_ plaintext: [UInt8]) {
        let end = (plaintext.count >= 4 && AiDexCrc16.validateResponse(plaintext)) ? plaintext.count - 2 : plaintext.count
        guard end > 2 else { return }
        let payload = Array(plaintext[2..<end])
        guard let parsed = AiDexParser.parseLocalStartTimePayload(payload) else {
            logLine("in handleLegacyStartTimeResponse, payload of \(payload.count) bytes is not a session start")
            return
        }
        applySessionStart(parsed, source: "0x21", allowActivation: false)
    }

    // MARK: - history

    private func u16(_ data: [UInt8], _ offset: Int) -> Int {
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private func persistCursors() {
        let raw = historyRawNextIndex
        let brief = historyBriefNextIndex
        updateState {
            $0.historyRawNextIndex = raw
            $0.historyBriefNextIndex = brief
        }
    }

    /// The fallback glucose belongs to the row before the brief cursor and is kept with it, so a download
    /// that resumes there merges the next rows as an uninterrupted one would.
    private func advanceBriefHistoryCursor(_ nextIndex: Int) {
        historyBriefNextIndex = nextIndex
        let raw = historyRawNextIndex
        let fallback = lastCalibratedGlucoseFallback ?? 0
        updateState {
            $0.historyRawNextIndex = raw
            $0.historyBriefNextIndex = nextIndex
            $0.historyFallbackIndex = nextIndex
            $0.historyFallbackGlucose = fallback
        }
    }

    private func restoreHistoryFallback() {
        if let state = loadState(), state.historyFallbackGlucose > 0, state.historyFallbackIndex == historyBriefNextIndex {
            lastCalibratedGlucoseFallback = state.historyFallbackGlucose
        } else {
            lastCalibratedGlucoseFallback = nil
        }
    }

    private func clearHistoryFallback() {
        lastCalibratedGlucoseFallback = nil
        updateState {
            $0.historyFallbackIndex = 0
            $0.historyFallbackGlucose = 0
        }
    }

    /// 0x24 rows are stored with the 0x23 glucose cached in memory; wherever that cache is lost before 0x24
    /// consumed it, 0x23 has to be fetched again from there too.
    private func rewindRawHistoryCursor() {
        historyRawNextIndex = min(historyRawNextIndex, historyBriefNextIndex)
        rawCursorLostItsCache = false
        persistCursors()
    }

    private func armHistoryWatchdog() {
        historyToken += 1
        let token = historyToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.historyPageTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.historyToken == token, self.historyDownloading else { return }
            self.logLine("in history watchdog, no answer for \(Int(Self.historyPageTimeout)) seconds", type: .error)
            self.abortHistoryDownload("page-timeout")
        }
    }

    private func requestHistoryRange() {
        guard let command = commandBuilder?.getHistoryRange() else { return }
        pendingInitialHistoryRequest = false
        initialHistoryToken += 1
        historyDownloading = true
        sendCommand(command)
        armHistoryWatchdog()
    }

    private func requestHistoryPage(opcode: Int, offset: Int) {
        guard historyDownloading else { return }
        let command: [UInt8]?
        if opcode == AiDexOpcodes.getHistoriesRaw {
            command = commandBuilder?.getHistoriesRaw(offset: offset)
        } else {
            command = commandBuilder?.getHistories(offset: offset)
        }
        guard command != nil else {
            abortHistoryDownload("no-session-key")
            return
        }
        sendCommand(command)
        armHistoryWatchdog()
    }

    private func scheduleHistoryPage(opcode: Int, offset: Int) {
        // keep the page watchdog running while the short pause passes
        armHistoryWatchdog()
        let generation = connectionGeneration
        let token = historyToken
        runOnCentralQueue(after: Self.historyRequestDelay) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.historyToken == token else { return }
            self.requestHistoryPage(opcode: opcode, offset: offset)
        }
    }

    private func handleHistoryRangeResponse(_ plaintext: [UInt8]) {
        guard plaintext.count >= 8 else { return }
        // [opcode, status, brief start (0x24), raw start (0x23), newest offset]
        let briefStart = u16(plaintext, 2)
        let rawStart = u16(plaintext, 4)
        let newest = u16(plaintext, 6)
        historyNewestOffset = newest
        historyDownloading = true
        logLine("in handleHistoryRangeResponse, brief start \(briefStart), raw start \(rawStart), newest \(newest)")

        let now = Date()
        if newest > 0 {
            lastOffsetMinutes = newest
            ensureSensorStartTime(now: now, trustedOffset: nil)
        }
        if rawCursorLostItsCache {
            rewindRawHistoryCursor()
        }

        // never further back than the window
        let windowStart = max(1, newest - Self.historyWindowMinutes)
        let plan = AiDexHistoryPolicy.planInitialDownload(
            briefStart: briefStart,
            rawStart: rawStart,
            newest: newest,
            persistedRawNextIndex: max(historyRawNextIndex, windowStart),
            persistedBriefNextIndex: max(historyBriefNextIndex, windowStart)
        )
        historyRawNextIndex = plan.rawNextIndex
        historyBriefNextIndex = plan.briefNextIndex
        persistCursors()
        restoreHistoryFallback()

        // only the exact minute the live frames already delivered is skipped; when a live frame arrived
        // before the range answer, everything up to the newest offset is theirs
        if liveOffsetCutoff == 0 && hasLiveFrameSinceStreamingStart() && newest > 0 {
            liveOffsetCutoff = newest
        }

        switch plan.action {
        case .completeEmpty:
            logLine("in handleHistoryRangeResponse, the sensor holds no history")
            completeHistory()
        case .completeAlreadyCaughtUp:
            logLine("in handleHistoryRangeResponse, nothing new to download")
            completeHistory()
        case .requestRaw:
            logLine("in handleHistoryRangeResponse, downloading from raw \(historyRawNextIndex), brief \(historyBriefNextIndex)")
            requestHistoryPage(opcode: AiDexOpcodes.getHistoriesRaw, offset: historyRawNextIndex)
        case .requestBrief:
            logLine("in handleHistoryRangeResponse, 0x23 is up to date, downloading 0x24 from \(historyBriefNextIndex)")
            requestHistoryPage(opcode: AiDexOpcodes.getHistories, offset: historyBriefNextIndex)
        }
    }

    /// `[opcode, status, rows..., crc_lo, crc_hi]`: the CRC was checked on arrival and is no row.
    private func historyPagePayload(_ plaintext: [UInt8]) -> [UInt8] {
        guard plaintext.count >= 4 else { return [] }
        return Array(plaintext[2..<(plaintext.count - 2)])
    }

    private func handleHistoryRawResponse(_ plaintext: [UInt8]) {
        guard plaintext.count >= 4, historyDownloading else { return }
        let entries = AiDexParser.parseHistoryResponse(historyPagePayload(plaintext))

        guard let last = entries.last else {
            // nothing more from 0x23: go on with 0x24
            if historyBriefNextIndex <= historyNewestOffset {
                scheduleHistoryPage(opcode: AiDexOpcodes.getHistories, offset: historyBriefNextIndex)
            } else {
                completeHistory()
            }
            return
        }

        // the glucose is cached by minute and stored together with the raw channels of 0x24
        let cached = AiDexHistoryMerge.cacheCalibratedEntries(entries, cache: &calibratedGlucoseCache)
        logLine("in handleHistoryRawResponse, \(entries.count) rows, \(cached.cached) cached")

        let next = AiDexHistoryPolicy.nextPageIndex(lastOffsetMinutes: last.timeOffsetMinutes, newest: historyNewestOffset)
        guard next > historyRawNextIndex else {
            abortHistoryDownload("raw-page-without-progress")
            return
        }
        historyRawNextIndex = next
        persistCursors()

        if historyRawNextIndex <= historyNewestOffset {
            scheduleHistoryPage(opcode: AiDexOpcodes.getHistoriesRaw, offset: historyRawNextIndex)
        } else if historyBriefNextIndex <= historyNewestOffset {
            scheduleHistoryPage(opcode: AiDexOpcodes.getHistories, offset: historyBriefNextIndex)
        } else {
            completeHistory()
        }
    }

    private func handleHistoryBriefResponse(_ plaintext: [UInt8]) {
        guard plaintext.count >= 7, historyDownloading else { return }
        let payload = historyPagePayload(plaintext)
        let entries = AiDexParser.parseBriefHistoryResponse(payload)

        guard let last = entries.last else {
            // a page of all-zero rows is not the end of the history
            if let pageEnd = AiDexParser.briefHistoryPageEnd(payload), pageEnd > historyBriefNextIndex, pageEnd <= historyNewestOffset {
                advanceBriefHistoryCursor(pageEnd)
                scheduleHistoryPage(opcode: AiDexOpcodes.getHistories, offset: historyBriefNextIndex)
                return
            }
            completeHistory()
            return
        }

        let merged = AiDexHistoryMerge.mergeHistoryEntries(entries, calibratedCache: &calibratedGlucoseCache, initialFallback: lastCalibratedGlucoseFallback)
        guard storeHistoryEntries(merged.entries) else {
            // keep this page pending; the merge consumed its factory cache, so 0x23 starts again there too
            rewindRawHistoryCursor()
            abortHistoryDownload("page-not-stored")
            return
        }
        if let known = merged.lastKnownGlucose {
            lastCalibratedGlucoseFallback = known
        }
        logLine("in handleHistoryBriefResponse, \(entries.count) rows: \(merged.mergedCount) matched, \(merged.fallbackCount) on the last known value, \(merged.noGlucoseCount) without glucose")

        let next = AiDexHistoryPolicy.nextPageIndex(lastOffsetMinutes: last.timeOffsetMinutes, newest: historyNewestOffset)
        guard next > historyBriefNextIndex else {
            abortHistoryDownload("brief-page-without-progress")
            return
        }
        advanceBriefHistoryCursor(next)

        if historyBriefNextIndex <= historyNewestOffset {
            scheduleHistoryPage(opcode: AiDexOpcodes.getHistories, offset: historyBriefNextIndex)
        } else {
            completeHistory()
        }
    }

    /// True when every row was either stored or deliberately discarded, so the cursor may pass the page.
    /// False when rows that belong in the history could not be stored (no session start known yet).
    private func storeHistoryEntries(_ entries: [AiDexHistoryStoreEntry]) -> Bool {
        let now = Date()
        if sensorStart == nil {
            ensureSensorStartTime(now: now, trustedOffset: nil)
        }
        // without a start only the offset rules can be checked: take the widest start that still lets
        // every offset up to the limit pass the future check
        let referenceStart = sensorStart ?? now.addingTimeInterval(-Double(AiDexHistoryMerge.maxOffsetDays) * 24 * 3600)
        let storable = AiDexHistoryMerge.filterForStorage(
            entries,
            sensorStart: referenceStart,
            now: now,
            historyNewestOffset: historyNewestOffset,
            liveOffsetCutoff: liveOffsetCutoff,
            wearDays: wearDays
        )
        if storable.isEmpty { return true }
        guard let start = sensorStart else {
            logLine("in storeHistoryEntries, no session start known yet, the page stays pending")
            return false
        }

        let samples = storable.map {
            SampleToDeliver(date: start.addingTimeInterval(Double($0.offsetMinutes) * 60), mgdl: $0.glucoseMgDl)
        }
        if let newestOffset = storable.map({ $0.offsetMinutes }).max(), newestOffset > lastHistoryNewestOffset {
            lastHistoryNewestOffset = newestOffset
        }
        if let newestDate = samples.map({ $0.date }).max() {
            lastGlucoseTime = max(lastGlucoseTime ?? Date.distantPast, newestDate)
        }
        deliver(samples, live: false)
        return true
    }

    private func completeHistory() {
        historyToken += 1
        historyDownloading = false
        if !calibratedGlucoseCache.isEmpty {
            logLine("in completeHistory, \(calibratedGlucoseCache.count) glucose values had no raw row")
            calibratedGlucoseCache.removeAll()
        }
        // 0x24 can run out of rows before the announced end: what is still ahead of its cursor needs the
        // factory glucose again
        if historyNewestOffset > 0 && historyBriefNextIndex <= historyNewestOffset {
            rewindRawHistoryCursor()
        } else {
            clearHistoryFallback()
        }
        logLine("in completeHistory, raw cursor \(historyRawNextIndex), brief cursor \(historyBriefNextIndex)")
    }

    private func abortHistoryDownload(_ reason: String) {
        historyToken += 1
        historyDownloading = false
        persistCursors()
        noteProblem(.historyFailed)
        logLine("in abortHistoryDownload, \(reason); resuming from raw \(historyRawNextIndex), brief \(historyBriefNextIndex) on the next connection", type: .error)
    }

    // MARK: - delivery to xDrip

    private func deliver(_ samples: [SampleToDeliver], live: Bool) {
        let valid = samples.filter {
            Int($0.mgdl) >= AiDexHistoryMerge.minValidGlucoseMgDl && Int($0.mgdl) <= AiDexHistoryMerge.maxValidGlucoseMgDl
        }
        guard !valid.isEmpty else { return }

        let now = Date()
        let newest = valid.max { $0.date < $1.date } ?? valid[0]
        let sensorAge: TimeInterval? = sensorStart.map { max(0, newest.date.timeIntervalSince($0)) }
        let newSensorStartDate = pendingNewSensorStart
        pendingNewSensorStart = nil

        updateState {
            $0.lastReadingDate = max($0.lastReadingDate ?? Date.distantPast, newest.date)
            if live || $0.lastReadingDate == newest.date {
                $0.problem = nil
            }
        }

        let sorted = valid.sorted { $0.date > $1.date }
        let glucoseData: [GlucoseData] = sorted.map {
            GlucoseData(
                timeStamp: $0.date,
                glucoseLevelRaw: (Double($0.mgdl) * 100).rounded() / 100,
                backfilledAt: live ? nil : now
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let delegate = self.cgmTransmitterDelegate else { return }
            if let newSensorStartDate = newSensorStartDate {
                delegate.newSensorDetected(sensorStartDate: newSensorStartDate)
            }
            var data = glucoseData
            delegate.cgmTransmitterInfoReceived(glucoseData: &data, transmitterBatteryInfo: nil, sensorAge: sensorAge)
        }
    }

    // MARK: - CGMTransmitter

    func cgmTransmitterType() -> CGMTransmitterType {
        return .aiDex
    }

    /// The wear time the sensor reported; the X and LinX run 15 days until it has.
    func maxSensorAgeInDays() -> Double? {
        let days = loadState()?.wearDays ?? Self.fallbackWearDays
        return Double(days)
    }

    /// AiDex has no warm-up that hides readings: valid values are kept from the first minute.
    func sensorWarmupDurationInMinutes() -> Double? { 0 }

    func needsSensorStartTime() -> Bool { false }

    /// Values are mg/dL from the sensor's own factory calibration, so xDrip uses no calibrator.
    func isWebOOPEnabled() -> Bool { true }

    func overruleIsWebOOPEnabled() -> Bool { true }

    func nonWebOOPAllowed() -> Bool { false }

    func getCBUUID_Service() -> String { return AiDexGATT.cgmService.uuidString }

    func getCBUUID_Receive() -> String { return AiDexGATT.f003.uuidString }
}
