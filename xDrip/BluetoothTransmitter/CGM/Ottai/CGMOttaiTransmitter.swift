//
//  CGMOttaiTransmitter.swift
//  xdrip
//
//  Direct Bluetooth driver for the Ottai (and Syai) CGM, ported from JugglucoNG `drivers/ottai`
//  (`OttaiBleManager`; GPL-3.0, see THIRD_PARTY_NOTICES.md). The protocol maths, the glucose
//  expression, the session logic and the history request chain that can be tested without a radio
//  live in `OttaiProtocol.swift` and `OttaiSession.swift`; this file owns the connection: the scan,
//  the three services, the "BLE Auth V2" handshake, the command status, the live read and its poll,
//  the history requests and the delivery of the readings to xDrip.
//
//  What the fork does without the vendor cloud: nothing is ever sent to the vendor's servers. The six
//  authentication keys and the glucose coefficients of a sensor are issued by that cloud to the
//  account that owns the sensor and cannot be computed on the phone, so the user has to supply them
//  (`OttaiMaterials`, the portable JSON JugglucoNG exports, kept in the Keychain). A sensor without
//  that material is shown as unsupported with a clear message; nothing is guessed. See docs/ottai.md.
//
//  Differences from the Android driver that the platform or the missing cloud force:
//  - iOS has no MAC address: the peripheral is known by its Core Bluetooth identifier. The 12 hex digit
//    sensor id that signs the handshake comes from the material.
//  - iOS has no bond state API and CoreBluetooth cannot tell a read result from a notification of the
//    same characteristic: a live value that arrives while a read is outstanding counts as that read.
//  - A sensor that needs activation (command status 0 to 2) is not activated: the activation
//    negotiation is not ported, the user activates it with the vendor's app.
//  - An ended sensor (status 4 or more) is not read and its last history is not fetched.
//  - Gaps are filled from the counter alone: there is no Room diff and no hole ledger that survives a
//    restart, and the first fill reaches back one day at most.
//
//  Never compiled here and never tried on a real sensor.
//

import CoreBluetooth
import CryptoKit
import Foundation
import os
import Security

// MARK: - Link problems and persisted device state

/// What went wrong last, shown on the device screen and cleared by the next reading.
enum OttaiLinkProblem: String, Codable {
    case linkLost
    case notAnOttai
    case noMaterial
    /// The first signature the sensor sent did not match the imported material: another sensor, or the
    /// material of another sensor.
    case sensorNotMatching
    /// A sensor that matched before sent a signature that does not match now; the handshake goes on.
    case signatureMismatch
    case notificationsFailed
    case setupTimeout
    case readFailed
    case authRejected
    case sessionKeyFailed
    case sensorNotActivated
    case sensorEnded
    case commandStatusUnreadable
    case linkSilent
    case noReadings
    case frameNotDecryptable
    case noExpression
}

/// Everything the driver learns about one sensor, kept per Bluetooth address in UserDefaults so the
/// device screen can show it without a connection. Not part of Core Data (the entity only links to its
/// BLEPeripheral). It holds no secret: the keys are in the Keychain (`OttaiMaterialsStore`).
struct OttaiDeviceState: Codable, Equatable {
    var advertisedName: String?
    /// The sensor id of the material this state belongs to; a different id starts the state over.
    var materialsSensorId: String?
    /// The counters, anchors and gate baseline that survive a reconnect.
    var pipeline = OttaiPersistedPipeline()
    /// The record width learned from the frames (0 = not yet).
    var learnedRecordSize = 0
    /// The last command status the sensor reported (-1 = none yet): 0 to 2 not activated, 3 running, 4+ ended.
    var commandStatus = -1
    /// The sensor's signature matched the material at least once.
    var verified = false
    /// The sensor did not match the material (or is no Ottai): it is not connected to again.
    var strangerRejected = false
    /// The lifetime the sensor itself reported (`b8fd9848`), 0 = unknown.
    var activatedMaxActiveMs: Int64 = 0
    var livePollIntervalMs: Int64 = OttaiCgmInfo.defaultLivePollIntervalMs
    /// The session start xDrip was last told about (0 = none yet), so a new session is announced once.
    var announcedStartAtMs: Int64 = 0
    var lastFrameDate: Date?
    var lastReadingDate: Date?
    var lastReadingMgdl: Double?
    var lastRawCurrent: Int?
    var lastTemperatureC: Double?
    var problem: OttaiLinkProblem?
    var problemDate: Date?
}

enum OttaiDeviceStore {
    private static let keyPrefix = "ottai.deviceState."
    private static let rejectedKey = "ottai.rejectedAddresses"
    private static let maxRejected = 20
    private static let lock = NSLock()

    static func load(address: String) -> OttaiDeviceState {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(address: address)
    }

    @discardableResult
    static func update(address: String, _ change: (inout OttaiDeviceState) -> Void) -> OttaiDeviceState {
        lock.lock()
        defer { lock.unlock() }
        var state = loadUnlocked(address: address)
        change(&state)
        saveUnlocked(state, address: address)
        return state
    }

    static func save(_ state: OttaiDeviceState, address: String) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(state, address: address)
    }

    static func clear(address: String) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: keyPrefix + address)
        removeRejectedUnlocked(address)
    }

    /// Peripherals that were not the sensor the material belongs to. A first scan skips them, so a
    /// neighbour's sensor is not picked again and again.
    static func rejectedAddresses() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []
    }

    static func reject(address: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []
        list.removeAll { $0 == address }
        list.append(address)
        if list.count > maxRejected { list.removeFirst(list.count - maxRejected) }
        UserDefaults.standard.set(list, forKey: rejectedKey)
    }

    static func forgetRejection(address: String) {
        lock.lock()
        defer { lock.unlock() }
        removeRejectedUnlocked(address)
    }

    private static func removeRejectedUnlocked(_ address: String) {
        var list = UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []
        let before = list.count
        list.removeAll { $0 == address }
        if list.count != before { UserDefaults.standard.set(list, forKey: rejectedKey) }
    }

    private static func loadUnlocked(address: String) -> OttaiDeviceState {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + address),
              let state = try? JSONDecoder().decode(OttaiDeviceState.self, from: data) else {
            return OttaiDeviceState()
        }
        return state
    }

    private static func saveUnlocked(_ state: OttaiDeviceState, address: String) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: keyPrefix + address)
        }
    }
}

// MARK: - Sensor material in the Keychain

/// The authentication keys and glucose coefficients of one sensor, one Keychain item per Bluetooth
/// address plus one "pending" item that the add screen fills before the sensor is found. Device-only
/// (never synchronised, never in a backup) and never written to a trace.
enum OttaiMaterialsStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "xdrip") + ".ottai"
    private static let pendingAccount = "materials.pending"
    private static let lock = NSLock()

    private static func query(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private static func account(address: String) -> String {
        return "materials." + address
    }

    private static func loadUnlocked(account: String) -> OttaiMaterials? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OttaiMaterials.self, from: data)
    }

    @discardableResult
    private static func saveUnlocked(_ materials: OttaiMaterials, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(materials) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(account: account).merging(attributes) { _, new in new }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func clearUnlocked(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    static func load(address: String) -> OttaiMaterials? {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(account: account(address: address))
    }

    static func has(address: String) -> Bool {
        return load(address: address) != nil
    }

    @discardableResult
    static func save(_ materials: OttaiMaterials, address: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveUnlocked(materials, account: account(address: address))
    }

    static func clear(address: String) {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked(account: account(address: address))
    }

    static func loadPending() -> OttaiMaterials? {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(account: pendingAccount)
    }

    @discardableResult
    static func savePending(_ materials: OttaiMaterials) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveUnlocked(materials, account: pendingAccount)
    }

    static func clearPending() {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked(account: pendingAccount)
    }

    /// Moves the pending material to `address` once the sensor proved it belongs to it.
    @discardableResult
    static func adoptPending(address: String) -> OttaiMaterials? {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = loadUnlocked(account: pendingAccount) else { return nil }
        guard saveUnlocked(pending, account: account(address: address)) else { return nil }
        clearUnlocked(account: pendingAccount)
        return pending
    }
}

// MARK: - Transmitter

class CGMOttaiTransmitter: BluetoothTransmitter, CGMTransmitter {

    private enum Phase {
        case connecting
        case settingUp
        case authenticating
        case streaming
    }

    private enum AuthStep {
        case idle
        case readDeviceTime
        case readDeviceParam
        case readDeviceSign
        case writeAppParam
        case writeAppSign
        case done
    }

    private struct NotifyStep {
        let uuid: CBUUID
        let enabled: Bool
    }

    // MARK: - timing

    /// JugglucoNG `RECONNECT_DELAY_MS`.
    private static let reconnectDelay: TimeInterval = 3
    private static let noMaterialRecheckDelay: TimeInterval = 60
    /// A sensor that waits for activation is left alone for a while, so the vendor's app can reach it.
    private static let notActivatedReconnectDelay: TimeInterval = 300
    private static let endedReconnectDelay: TimeInterval = 1800
    /// JugglucoNG `SETUP_ACTIVITY_STALE_MS`.
    private static let setupStaleThreshold: TimeInterval = 90
    private static let notifyStepTimeout: TimeInterval = 10
    /// The reads after the command status, JugglucoNG `startStreamingAfterCommandStatus`.
    private static let cgmInfoReadDelay: TimeInterval = 0.25
    private static let firstLiveReadDelay: TimeInterval = 0.7
    private static let maxActiveReadDelay: TimeInterval = 1.2
    /// JugglucoNG `INITIAL_HISTORY_DELAY_MS`, `INITIAL_HISTORY_RETRY_MS`, `INITIAL_HISTORY_MAX_ATTEMPTS`.
    private static let initialHistoryDelay: TimeInterval = 4
    private static let initialHistoryRetryDelay: TimeInterval = 5
    private static let initialHistoryMaxAttempts = 4
    /// JugglucoNG `INITIAL_HISTORY_MIN_SENSOR_AGE_MS`.
    private static let initialHistoryMinSensorAgeMs: Int64 = 3 * 60_000
    private static let emptyLiveHistoryDelay: TimeInterval = 1.8
    private static let postHistoryLiveDelay: TimeInterval = 1
    private static let noReadingsTimeout: TimeInterval = 300
    private static let maxDecryptFailuresBeforeProblem = 3
    private static let maxPendingGaps = 8
    /// A new sensor session is announced to xDrip when its start moved by more than this.
    private static let newSessionTolerance: Int64 = 60 * 60 * 1000

    // MARK: - properties

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMOttai)

    /// Bumped on every connect and disconnect so delayed work of an older connection does nothing.
    private var connectionGeneration = 0
    private var activityToken = 0
    private var notifyToken = 0
    private var livePollToken = 0
    private var initialHistoryToken = 0
    private var historyWatchdogToken = 0
    private var historyChunkToken = 0
    private var postHistoryLiveToken = 0
    private var noReadingsToken = 0

    private var released = false
    private var phase: Phase = .connecting
    private var authStep: AuthStep = .idle
    private var characteristics = [CBUUID: CBCharacteristic]()
    private var sessionBegun = false
    private var streamingStarted = false
    private var problemNotedOnThisLink = false
    private var statusReadOnThisLink = false
    private var noMaterialLogged = false
    /// The Keychain is asked about the pending material at most every few seconds while scanning.
    private var pendingMaterialCache: (checkedAt: Date, available: Bool)?

    /// The local name of the advertisement that led to the first connection.
    private var discoveredAdvertisedName: String?

    private var state = OttaiDeviceState()
    private var stateLoadedForAddress: String?
    private var materials: OttaiMaterials?
    private var materialsFromPending = false

    private var pipeline = OttaiPipeline()
    private var liveDelivered = OttaiLruMap<Int64>(capacity: 64)

    // handshake
    private var deviceTimeBytes = [UInt8]()
    private var deviceParamIndex = -1
    private var deviceParamTime = [UInt8]()
    private var devicePubX = [UInt8]()
    private var devicePubY = [UInt8]()
    private var appPrivate: P256.KeyAgreement.PrivateKey?
    private var appPubX = [UInt8]()
    private var appPubY = [UInt8]()
    private var appTime3 = [UInt8]()
    private var appIndex = 0
    private var sessionKeyHex = ""

    // notification switching, one characteristic at a time
    private var notifySteps = [NotifyStep]()
    private var notifyInFlight: NotifyStep?

    // streaming
    private var liveReadsInFlight = 0
    private var lastLiveNotifyAtMs: Int64 = 0
    private var decryptFailuresInRow = 0
    private var decryptedAnyFrameOnThisLink = false
    private var streamingStartedAtMs: Int64 = 0

    // history
    private var historyChain = OttaiHistoryChain()
    private var lastHistoryRequestAtMs: Int64 = 0
    private var historyChecked = false
    private var initialHistoryAttempt = 0
    private var pendingGaps = [(start: Int, endExclusive: Int)]()

    // MARK: - initialization

    init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {
        var newAddressAndName: BluetoothTransmitter.DeviceAddressAndName = .notYetConnected(expectedName: nil)
        if let address = address {
            newAddressAndName = .alreadyConnectedBefore(address: address, name: name)
        }

        self.cgmTransmitterDelegate = cGMTransmitterDelegate

        // The advertisement is not known to carry a service, so the first scan is unfiltered (foreground
        // only); later connections use the stored address. 2AA7 carries the live frames, so the base
        // class turns its notifications on at discovery; the history characteristic gets its own step.
        super.init(
            addressAndName: newAddressAndName,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [OttaiConstants.serviceDeviceInfo, OttaiConstants.serviceCgm, OttaiConstants.serviceAuth],
            CBUUID_ReceiveCharacteristic: OttaiConstants.charGlucoseLive.uuidString,
            CBUUID_WriteCharacteristic: OttaiConstants.charHistoryRequest.uuidString,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    // MARK: - persisted state helpers

    private func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func loadStateIfNeeded() {
        guard let address = deviceAddress, stateLoadedForAddress != address else { return }
        state = OttaiDeviceStore.load(address: address)
        stateLoadedForAddress = address
    }

    private func persistState() {
        guard !released, let address = deviceAddress, stateLoadedForAddress == address else { return }
        OttaiDeviceStore.save(state, address: address)
    }

    private func logLine(_ message: String, type: OSLogType = .info) {
        trace("%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: type, message)
    }

    private func noteProblem(_ problem: OttaiLinkProblem) {
        problemNotedOnThisLink = true
        logLine("Ottai link problem: \(problem.rawValue)")
        loadStateIfNeeded()
        state.problem = problem
        state.problemDate = Date()
        persistState()
    }

    /// The material of this connection: the one stored for the address, else the pending one the add
    /// screen holds. A different sensor id than the state was built for starts the state over.
    private func loadMaterialsForConnection() {
        loadStateIfNeeded()
        guard let address = deviceAddress else {
            materials = nil
            materialsFromPending = false
            return
        }
        if let stored = OttaiMaterialsStore.load(address: address) {
            materials = stored
            materialsFromPending = false
        } else if let pending = OttaiMaterialsStore.loadPending() {
            materials = pending
            materialsFromPending = true
        } else {
            materials = nil
            materialsFromPending = false
        }
        guard let loaded = materials, state.materialsSensorId != loaded.sensorId else { return }
        logLine("in loadMaterialsForConnection, the material belongs to another sensor than the stored state, the state starts over")
        state.pipeline = OttaiPersistedPipeline()
        state.learnedRecordSize = 0
        state.commandStatus = -1
        state.verified = false
        state.strangerRejected = false
        state.activatedMaxActiveMs = 0
        state.announcedStartAtMs = 0
        state.lastReadingDate = nil
        state.lastReadingMgdl = nil
        state.lastRawCurrent = nil
        state.lastTemperatureC = nil
        state.problem = nil
        state.problemDate = nil
        state.materialsSensorId = loaded.sensorId
        persistState()
    }

    private func pendingMaterialAvailable() -> Bool {
        let now = Date()
        if let cache = pendingMaterialCache, now.timeIntervalSince(cache.checkedAt) < 5 {
            return cache.available
        }
        let available = OttaiMaterialsStore.loadPending() != nil
        pendingMaterialCache = (checkedAt: now, available: available)
        return available
    }

    /// The user imported or removed the material of this sensor on the device screen. The transmitter owns
    /// its copy of the persisted state, so the change is settled here on the central queue: a rejection is
    /// forgiven (the new material may be this sensor's) and a connected link is dropped so the reconnect
    /// reads the new keys. A connection that is still being made reads the material when it completes.
    func sensorMaterialsDidChange(removed: Bool) {
        runOnCentralQueue { [weak self] in
            guard let self = self, !self.released else { return }
            self.loadStateIfNeeded()
            self.pendingMaterialCache = nil
            self.noMaterialLogged = false
            if let address = self.deviceAddress {
                OttaiDeviceStore.forgetRejection(address: address)
            }
            self.state.strangerRejected = false
            self.state.problem = nil
            self.state.problemDate = nil
            self.persistState()
            self.logLine("in sensorMaterialsDidChange, the sensor material was \(removed ? "removed" : "replaced")")
            if removed {
                self.noteProblem(.noMaterial)
            }
            switch self.getConnectionStatus() {
            case .some(.connected):
                self.problemNotedOnThisLink = true
                self.disconnect()
            case .some(.connecting):
                break
            default:
                if !removed, self.deviceAddress != nil {
                    self.connect()
                }
            }
        }
    }

    // MARK: - connection lifecycle

    override func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // a stored address matches exactly
        if deviceAddress != nil {
            super.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
            return
        }

        // first connection: the first advertisement called Ottai, but only with material to try
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard OttaiConstants.isOttaiAdvertisedName(name) else { return }
        guard pendingMaterialAvailable() else {
            if !noMaterialLogged {
                noMaterialLogged = true
                logLine("in didDiscover, an Ottai advertisement was seen but no sensor material was imported, the sensor is not connected to", type: .error)
            }
            return
        }
        if OttaiDeviceStore.rejectedAddresses().contains(peripheral.identifier.uuidString) {
            return
        }
        discoveredAdvertisedName = name
        logLine("in didDiscover, Ottai candidate found, rssi \(RSSI.intValue)")
        connectToDiscoveredPeripheral(peripheral)
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetConnectionState()
        super.centralManager(central, didConnect: peripheral)
        loadStateIfNeeded()
        loadMaterialsForConnection()
        if state.advertisedName == nil {
            state.advertisedName = discoveredAdvertisedName ?? deviceName
            persistState()
        }
        noteActivity()

        if state.strangerRejected {
            logLine("in didConnect, this peripheral did not match the sensor material before, disconnecting")
            problemNotedOnThisLink = true
            disconnect()
            return
        }
        if materials == nil {
            noteProblem(.noMaterial)
            disconnect()
        }
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        loadStateIfNeeded()
        if !problemNotedOnThisLink {
            if authStep == .writeAppSign || (authStep == .done && !statusReadOnThisLink) {
                // the sensor hung up right after it got our signature
                noteProblem(.authRejected)
            } else if phase == .streaming {
                noteProblem(.linkLost)
            }
        }
        invalidateConnection()
        phase = .connecting
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func reconnectAfterDisconnect(_ central: CBCentralManager) {
        guard !released else { return }
        loadStateIfNeeded()
        if state.strangerRejected {
            logLine("in reconnectAfterDisconnect, this peripheral did not match the sensor material, not reconnecting")
            return
        }
        scheduleReconnect(central, delay: reconnectDelayForState())
    }

    /// Without material there is nothing to connect for: the Keychain is looked at again after a minute.
    private func reconnectDelayForState() -> TimeInterval {
        if !currentMaterialAvailable() { return Self.noMaterialRecheckDelay }
        if OttaiConstants.commandNeedsActivation(state.commandStatus) { return Self.notActivatedReconnectDelay }
        if state.commandStatus >= 4 { return Self.endedReconnectDelay }
        return Self.reconnectDelay
    }

    private func currentMaterialAvailable() -> Bool {
        guard let address = deviceAddress else { return false }
        return OttaiMaterialsStore.has(address: address) || OttaiMaterialsStore.loadPending() != nil
    }

    private func scheduleReconnect(_ central: CBCentralManager, delay: TimeInterval) {
        runOnCentralQueue(after: delay) { [weak self] in
            guard let self = self, !self.released else { return }
            if !self.currentMaterialAvailable() {
                // keep waiting for an import without touching the radio
                self.scheduleReconnect(central, delay: Self.noMaterialRecheckDelay)
                return
            }
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

    private func invalidateConnection() {
        connectionGeneration += 1
        activityToken += 1
        notifyToken += 1
        livePollToken += 1
        initialHistoryToken += 1
        historyWatchdogToken += 1
        historyChunkToken += 1
        postHistoryLiveToken += 1
        noReadingsToken += 1
        notifyInFlight = nil
        notifySteps.removeAll()
    }

    private func resetConnectionState() {
        invalidateConnection()
        phase = .connecting
        authStep = .idle
        characteristics.removeAll()
        sessionBegun = false
        streamingStarted = false
        problemNotedOnThisLink = false
        statusReadOnThisLink = false
        deviceTimeBytes = []
        deviceParamIndex = -1
        deviceParamTime = []
        devicePubX = []
        devicePubY = []
        appPrivate = nil
        appPubX = []
        appPubY = []
        appTime3 = []
        appIndex = 0
        sessionKeyHex = ""
        liveReadsInFlight = 0
        lastLiveNotifyAtMs = 0
        decryptFailuresInRow = 0
        decryptedAnyFrameOnThisLink = false
        streamingStartedAtMs = 0
        historyChain = OttaiHistoryChain()
        lastHistoryRequestAtMs = 0
        historyChecked = false
        initialHistoryAttempt = 0
    }

    /// JugglucoNG `noteGattActivity` and the connection watchdog: a link that shows no sign of life for
    /// the setup window (or, once streaming, three poll intervals) is dropped and tried again.
    private func noteActivity() {
        activityToken += 1
        let token = activityToken
        let generation = connectionGeneration
        let threshold: TimeInterval
        if phase == .streaming {
            threshold = TimeInterval(OttaiCgmInfo.streamingStaleThresholdMs(livePollIntervalMs: state.livePollIntervalMs)) / 1000
        } else {
            threshold = Self.setupStaleThreshold
        }
        runOnCentralQueue(after: threshold) { [weak self] in
            guard let self = self, !self.released,
                  self.connectionGeneration == generation, self.activityToken == token else { return }
            self.logLine("in activity watchdog, no sign of life for \(Int(threshold)) s in phase \(self.phase), reconnecting", type: .error)
            self.noteProblem(self.phase == .streaming ? .linkSilent : .setupTimeout)
            self.disconnect()
        }
    }

    /// A device that is not the sensor of this material: remembered, never connected to again.
    private func rejectPeripheral(_ problem: OttaiLinkProblem) {
        loadStateIfNeeded()
        if let address = deviceAddress {
            OttaiDeviceStore.reject(address: address)
        }
        state.strangerRejected = true
        noteProblem(problem)
        disconnect()
    }

    // MARK: - service and characteristic discovery

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        super.peripheral(peripheral, didDiscoverServices: error)
        guard error == nil, !state.strangerRejected else { return }
        let found = Set((peripheral.services ?? []).map { $0.uuid })
        let required: [CBUUID] = [OttaiConstants.serviceDeviceInfo, OttaiConstants.serviceCgm, OttaiConstants.serviceAuth]
        if !required.allSatisfy({ found.contains($0) }) {
            logLine("in didDiscoverServices, an Ottai service is missing", type: .error)
            wrongDevice()
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        guard error == nil, !state.strangerRejected else { return }

        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }

        // the session starts when every discovered service has reported its characteristics
        guard let services = peripheral.services, !services.isEmpty,
              services.allSatisfy({ $0.characteristics != nil }) else { return }
        servicesDiscovered()
    }

    /// A device that does not speak the protocol: when it never matched the material it is forgotten,
    /// otherwise the link is only dropped and tried again.
    private func wrongDevice() {
        loadStateIfNeeded()
        if state.verified {
            noteProblem(.notAnOttai)
            disconnect()
        } else {
            rejectPeripheral(.notAnOttai)
        }
    }

    private func servicesDiscovered() {
        guard !sessionBegun else { return }

        let required: [CBUUID] = [
            OttaiConstants.charCurrentTime, OttaiConstants.charAuthDeviceParam, OttaiConstants.charAuthAppParam,
            OttaiConstants.charAuthSign, OttaiConstants.charGlucoseLive, OttaiConstants.charGlucoseHistory,
            OttaiConstants.charHistoryRequest, OttaiConstants.charCommand
        ]
        guard required.allSatisfy({ characteristics[$0] != nil }) else {
            logLine("in servicesDiscovered, an Ottai characteristic is missing", type: .error)
            wrongDevice()
            return
        }
        guard let loaded = materials else {
            noteProblem(.noMaterial)
            disconnect()
            return
        }
        sessionBegun = true

        let activeTimeMs = loaded.activeTimeMs > 0 ? loaded.activeTimeMs : state.pipeline.confirmedActiveTimeMs
        pipeline = OttaiPipeline(persisted: state.pipeline, activeTimeMs: activeTimeMs)
        phase = .settingUp
        logLine("in servicesDiscovered, services ready, switching notifications on")

        runNotifyChain([
            NotifyStep(uuid: OttaiConstants.charGlucoseHistory, enabled: true),
            NotifyStep(uuid: OttaiConstants.charGlucoseLive, enabled: true),
            NotifyStep(uuid: OttaiConstants.charCgmInfoNotify, enabled: true)
        ]) { [weak self] in
            self?.startAuth()
        }
    }

    // MARK: - notification switching

    private var notifyCompletion: (() -> Void)?

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
        if characteristic.isNotifying == step.enabled {
            advanceNotifyChain()
            return
        }

        notifyInFlight = step
        notifyToken += 1
        let token = notifyToken
        let generation = connectionGeneration
        setNotifyValue(step.enabled, for: characteristic)

        runOnCentralQueue(after: Self.notifyStepTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.notifyToken == token, self.notifyInFlight != nil else { return }
            self.logLine("in notification chain, no answer for \(step.uuid.uuidString)", type: .error)
            self.noteProblem(.notificationsFailed)
            self.advanceNotifyChain()
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
        noteActivity()

        guard let step = notifyInFlight, step.uuid == characteristic.uuid else { return }
        if let error = error {
            // JugglucoNG goes on whatever the descriptor write says: the live read still works without it
            logLine("in didUpdateNotificationStateFor, \(characteristic.uuid.uuidString) could not be switched on: \(error.localizedDescription)", type: .error)
            noteProblem(.notificationsFailed)
        }
        advanceNotifyChain()
    }

    // MARK: - handshake (BLE Auth V2)

    private func readCharacteristic(_ uuid: CBUUID) -> Bool {
        guard let characteristic = characteristics[uuid] else {
            logLine("in readCharacteristic, \(uuid.uuidString) is missing", type: .error)
            return false
        }
        readValueForCharacteristic(for: characteristic)
        return true
    }

    @discardableResult
    private func writeCharacteristic(_ uuid: CBUUID, _ bytes: [UInt8], logPayload: Bool) -> Bool {
        guard let characteristic = characteristics[uuid] else {
            logLine("in writeCharacteristic, \(uuid.uuidString) is missing", type: .error)
            return false
        }
        // JugglucoNG: the acknowledged write when the characteristic offers it
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        return writeDataToPeripheral(data: Data(bytes), characteristicToWriteTo: characteristic, type: type, logPayload: logPayload)
    }

    private func startAuth() {
        guard !released, phase == .settingUp else { return }
        phase = .authenticating
        authStep = .readDeviceTime
        logLine("in startAuth, reading the device time")
        if !readCharacteristic(OttaiConstants.charCurrentTime) {
            noteProblem(.readFailed)
            disconnect()
        }
    }

    private func handleDeviceTime(_ bytes: [UInt8]) {
        deviceTimeBytes = bytes
        logLine("in handleDeviceTime, current time read, length \(bytes.count)")
        authStep = .readDeviceParam
        if !readCharacteristic(OttaiConstants.charAuthDeviceParam) {
            noteProblem(.readFailed)
            disconnect()
        }
    }

    /// `[0]` index, `[1...3]` time, `[4...35]` public X, `[36...67]` public Y.
    private func handleDeviceParam(_ bytes: [UInt8]) {
        logLine("in handleDeviceParam, device parameter read, length \(bytes.count)")
        if bytes.count >= 68 {
            deviceParamIndex = Int(bytes[0])
            deviceParamTime = Array(bytes[1..<4])
            devicePubX = Array(bytes[4..<36])
            devicePubY = Array(bytes[36..<68])
        } else {
            logLine("in handleDeviceParam, the device parameter is short", type: .error)
        }
        authStep = .readDeviceSign
        if !readCharacteristic(OttaiConstants.charAuthSign) {
            noteProblem(.readFailed)
            disconnect()
        }
    }

    /// JugglucoNG `verifyDeviceSign`: the sensor signs its public key with the key it names.
    private func deviceSignVerifies(_ deviceSign: [UInt8]) -> Bool {
        guard let keys = materials?.authKeys, let mac = materials?.macBytes,
              deviceParamIndex >= 0, deviceParamIndex < keys.count, !devicePubX.isEmpty else { return false }
        return OttaiBleAuth.verifyDeviceSign(
            deviceSign,
            authKeyHex: OttaiHex.string(keys[deviceParamIndex]),
            macHex: OttaiHex.string(mac),
            devicePubX: devicePubX, devicePubY: devicePubY, deviceTime: deviceParamTime
        )
    }

    private func handleDeviceSign(_ bytes: [UInt8]) {
        loadStateIfNeeded()
        let verified = deviceSignVerifies(bytes)
        logLine("in handleDeviceSign, sensor signature length \(bytes.count), matches the material: \(verified)")
        if verified {
            if !state.verified {
                state.verified = true
                persistState()
            }
            if let address = deviceAddress {
                OttaiDeviceStore.forgetRejection(address: address)
                if materialsFromPending, OttaiMaterialsStore.adoptPending(address: address) != nil {
                    materialsFromPending = false
                    logLine("in handleDeviceSign, the sensor matches the imported material, which now belongs to this sensor")
                }
            }
        } else if !state.verified {
            // a first signature that does not match: another sensor, or another sensor's material
            logLine("in handleDeviceSign, the sensor does not match the imported material", type: .error)
            rejectPeripheral(.sensorNotMatching)
            return
        } else {
            // JugglucoNG only logs: the sensor's own check decides
            noteProblem(.signatureMismatch)
        }
        writeAppParameter()
    }

    private func writeAppParameter() {
        guard let keys = materials?.authKeys, !keys.isEmpty else {
            noteProblem(.noMaterial)
            disconnect()
            return
        }
        let privateKey = OttaiBleAuth.generateKeyPair()
        appPrivate = privateKey
        let coordinates = OttaiBleAuth.publicCoords(privateKey.publicKey)
        appPubX = coordinates.x
        appPubY = coordinates.y
        appTime3 = OttaiBleAuth.appTime3(deviceTimeBytes: deviceTimeBytes)
        appIndex = Int.random(in: 0..<keys.count)
        let parameter = OttaiBleAuth.appAuthParameter(selectedIndex: appIndex, time3: appTime3, pubX: appPubX, pubY: appPubY)
        authStep = .writeAppParam
        logLine("in writeAppParameter, writing the app parameter, key index \(appIndex), length \(parameter.count)")
        if !writeCharacteristic(OttaiConstants.charAuthAppParam, parameter, logPayload: false) {
            noteProblem(.authRejected)
            disconnect()
        }
    }

    private func writeAppSign() {
        guard let keys = materials?.authKeys, let mac = materials?.macBytes, appIndex < keys.count else {
            noteProblem(.noMaterial)
            disconnect()
            return
        }
        let sign = OttaiBleAuth.authSign(authKey: keys[appIndex], mac: mac, pubX: appPubX, pubY: appPubY, time3: appTime3)
        authStep = .writeAppSign
        logLine("in writeAppSign, writing the app signature, length \(sign.count)")
        if !writeCharacteristic(OttaiConstants.charAuthSign, sign, logPayload: false) {
            noteProblem(.authRejected)
            disconnect()
        }
    }

    /// JugglucoNG `deriveSession` and the end of the handshake: the session key decrypts every frame.
    private func finishAuth() {
        authStep = .done
        guard let privateKey = appPrivate,
              let key = OttaiBleAuth.deriveSessionKey(devicePubX: devicePubX, devicePubY: devicePubY, ourPrivate: privateKey),
              !key.isEmpty else {
            // a failure of one handshake: the next one starts from scratch
            logLine("in finishAuth, no session key could be derived, reconnecting", type: .error)
            noteProblem(.sessionKeyFailed)
            disconnect()
            return
        }
        appPrivate = nil
        sessionKeyHex = key
        phase = .streaming
        logLine("in finishAuth, authentication complete, session key length \(key.count)")
        noteActivity()
        // the sensor's own state decides what happens next: 0 to 2 needs activation, 3 streams, 4+ ended
        if !readCharacteristic(OttaiConstants.charCommand) {
            noteProblem(.readFailed)
            disconnect()
        }
    }

    // MARK: - values

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
        loadStateIfNeeded()
        let uuid = characteristic.uuid

        if let error = error {
            handleValueError(uuid, error: error)
            return
        }
        guard let value = characteristic.value else { return }
        noteActivity()
        state.lastFrameDate = Date()
        let bytes = [UInt8](value)

        switch uuid {
        case OttaiConstants.charCurrentTime:
            if authStep == .readDeviceTime { handleDeviceTime(bytes) }
        case OttaiConstants.charAuthDeviceParam:
            if authStep == .readDeviceParam { handleDeviceParam(bytes) }
        case OttaiConstants.charAuthSign:
            if authStep == .readDeviceSign { handleDeviceSign(bytes) }
        case OttaiConstants.charCommand:
            handleCommandStatus(bytes)
        case OttaiConstants.charMaxActiveTime:
            handleMaxActiveRead(bytes)
        case OttaiConstants.charCgmInfoNotify:
            handleCgmInfo(bytes)
        case OttaiConstants.charGlucoseLive:
            // CoreBluetooth reports a read result and a notification the same way: a value that arrives
            // while a read is outstanding is taken for that read
            var notify = true
            if liveReadsInFlight > 0 {
                liveReadsInFlight -= 1
                notify = false
            }
            handleGlucosePayload(bytes, live: true, notify: notify)
        case OttaiConstants.charGlucoseHistory:
            handleGlucosePayload(bytes, live: false, notify: true)
        default:
            break
        }
    }

    private func handleValueError(_ uuid: CBUUID, error: Error) {
        logLine("in didUpdateValueFor, \(uuid.uuidString) failed: \(error.localizedDescription)", type: .error)
        // the lifetime read is an optional display probe: its failure never ends a healthy stream
        if uuid == OttaiConstants.charMaxActiveTime { return }
        if uuid == OttaiConstants.charGlucoseLive, liveReadsInFlight > 0 { liveReadsInFlight -= 1 }
        if phase == .authenticating || phase == .streaming {
            noteProblem(.readFailed)
            disconnect()
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
        noteActivity()

        switch characteristic.uuid {
        case OttaiConstants.charAuthAppParam:
            guard authStep == .writeAppParam else { return }
            if error != nil {
                noteProblem(.authRejected)
                disconnect()
            } else {
                writeAppSign()
            }
        case OttaiConstants.charAuthSign:
            guard authStep == .writeAppSign else { return }
            if error != nil {
                noteProblem(.authRejected)
                disconnect()
            } else {
                finishAuth()
            }
        case OttaiConstants.charHistoryRequest:
            if error != nil {
                // the watchdog asks again
                logLine("in didWriteValueFor, the history request was refused", type: .error)
            }
        default:
            break
        }
    }

    // MARK: - command status and streaming start

    /// JugglucoNG `handleCommandStatus` without the activation: 0 to 2 needs activation, 3 streams and
    /// 4 or more is an ended sensor.
    private func handleCommandStatus(_ bytes: [UInt8]) {
        statusReadOnThisLink = true
        let status = bytes.isEmpty ? -1 : Int(bytes[0])
        state.commandStatus = status
        persistState()
        logLine("in handleCommandStatus, command status \(status) (3 = activated, below 3 = needs activation)")

        if status < 0 {
            noteProblem(.commandStatusUnreadable)
            return
        }
        if OttaiConstants.commandNeedsActivation(status) {
            // the activation negotiation is not ported: the vendor's app activates the sensor
            noteProblem(.sensorNotActivated)
            disconnect()
            return
        }
        if status == 3 {
            if !streamingStarted { startStreaming() }
            return
        }
        // ended: nothing is published and the last history is not fetched
        noteProblem(.sensorEnded)
        disconnect()
    }

    /// JugglucoNG `startStreamingAfterCommandStatus`.
    private func startStreaming() {
        streamingStarted = true
        streamingStartedAtMs = nowMs()
        let generation = connectionGeneration

        runOnCentralQueue(after: Self.cgmInfoReadDelay) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation else { return }
            _ = self.readCharacteristic(OttaiConstants.charCgmInfoNotify)
        }
        runOnCentralQueue(after: Self.firstLiveReadDelay) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation else { return }
            self.readLive(reason: "command-status-3")
            self.scheduleLivePoll()
        }
        // the lifetime the sensor itself holds, once
        if state.activatedMaxActiveMs <= 0 {
            runOnCentralQueue(after: Self.maxActiveReadDelay) { [weak self] in
                guard let self = self, !self.released, self.connectionGeneration == generation else { return }
                _ = self.readCharacteristic(OttaiConstants.charMaxActiveTime)
            }
        }
        // history does not wait for the first accepted live sample
        initialHistoryAttempt = 0
        scheduleInitialHistory(after: Self.initialHistoryDelay)
        armNoReadingsWatchdog()
    }

    private func armNoReadingsWatchdog() {
        noReadingsToken += 1
        let token = noReadingsToken
        let generation = connectionGeneration
        let startedAtMs = streamingStartedAtMs
        runOnCentralQueue(after: Self.noReadingsTimeout) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation, self.noReadingsToken == token else { return }
            let last = self.state.lastReadingDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            if last < startedAtMs {
                self.logLine("in noReadingsWatchdog, no reading \(Int(Self.noReadingsTimeout)) s after streaming started", type: .error)
                self.noteProblem(self.pipelineHasMethod() ? .noReadings : .noExpression)
            }
        }
    }

    private func pipelineHasMethod() -> Bool {
        guard let method = materials?.resolvedMethod else { return false }
        return !OttaiFormula.isBlank(method)
    }

    // MARK: - cgm-info and lifetime

    /// JugglucoNG `maybeUpdateLivePollInterval`; the interval is also kept for the next connection.
    private func handleCgmInfo(_ bytes: [UInt8]) {
        logLine("in handleCgmInfo, cgm-info length \(bytes.count)", type: .debug)
        guard let interval = OttaiCgmInfo.livePollIntervalMs(bytes), interval != state.livePollIntervalMs else { return }
        state.livePollIntervalMs = interval
        persistState()
        logLine("in handleCgmInfo, live poll interval \(interval / 1000) s")
        if phase == .streaming, !sessionKeyHex.isEmpty { scheduleLivePoll() }
    }

    /// JugglucoNG `handleMaxActiveRead`.
    private func handleMaxActiveRead(_ bytes: [UInt8]) {
        guard !sessionKeyHex.isEmpty,
              let seconds = OttaiCgmInfo.decodeMaxActiveSeconds(bytes, sessionKeyHex: sessionKeyHex) else {
            logLine("in handleMaxActiveRead, the lifetime could not be decoded, length \(bytes.count)", type: .error)
            return
        }
        guard let ms = OttaiCgmInfo.plausibleMaxActiveMs(seconds: seconds) else {
            logLine("in handleMaxActiveRead, \(seconds) s is not a plausible lifetime, ignored", type: .error)
            return
        }
        if ms != state.activatedMaxActiveMs {
            state.activatedMaxActiveMs = ms
            persistState()
            logLine("in handleMaxActiveRead, the sensor's lifetime is \(ms / 86_400_000) days")
        }
    }

    // MARK: - live reads

    private func readLive(reason: String) {
        guard phase == .streaming, !sessionKeyHex.isEmpty, let characteristic = characteristics[OttaiConstants.charGlucoseLive] else { return }
        logLine("in readLive, reading the live value (\(reason))", type: .debug)
        liveReadsInFlight += 1
        readValueForCharacteristic(for: characteristic)
    }

    private func scheduleLivePoll(after interval: TimeInterval? = nil) {
        guard phase == .streaming, !released, !sessionKeyHex.isEmpty else { return }
        livePollToken += 1
        let token = livePollToken
        let generation = connectionGeneration
        let seconds = interval ?? TimeInterval(state.livePollIntervalMs) / 1000
        let delay = min(max(seconds, 5), 3600)
        runOnCentralQueue(after: delay) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation, self.livePollToken == token else { return }
            self.livePollFired()
        }
    }

    /// JugglucoNG `livePollRunnable`: stands down while notifications arrive on schedule.
    private func livePollFired() {
        guard phase == .streaming, !sessionKeyHex.isEmpty, state.commandStatus == 3 else { return }
        let sinceNotify = nowMs() - lastLiveNotifyAtMs
        if lastLiveNotifyAtMs > 0, sinceNotify < state.livePollIntervalMs {
            scheduleLivePoll()
            return
        }
        readLive(reason: "poll")
        scheduleLivePoll()
    }

    // MARK: - frames

    private var heldRecordSize: Int? {
        return state.learnedRecordSize > 0 ? state.learnedRecordSize : nil
    }

    /// JugglucoNG `learnRecordSize`: a payload that proves its layout fixes it, a short one proves nothing.
    private func learnRecordSize(_ payload: [UInt8], deviceVersion: String) {
        let decisive = OttaiParser.contentRecordSize(payload)
            ?? (state.learnedRecordSize == 0 ? OttaiParser.decisiveRecordSize(payload, deviceVersion: deviceVersion) : nil)
        guard let size = decisive, size != state.learnedRecordSize else { return }
        logLine("in learnRecordSize, record size \(size) (was \(state.learnedRecordSize))")
        state.learnedRecordSize = size
    }

    /// The activation start the formula's monitor time and the history estimate work from.
    private func effectiveStartMs() -> Int64 {
        if pipeline.activeTimeMs > 0 { return pipeline.activeTimeMs }
        return pipeline.streamStartMs
    }

    /// JugglucoNG `handleGlucosePayload`.
    private func handleGlucosePayload(_ cipher: [UInt8], live: Bool, notify: Bool) {
        guard phase == .streaming, !sessionKeyHex.isEmpty, let loaded = materials else { return }
        if live && state.commandStatus >= 4 { return }
        let receivedAtMs = nowMs()
        let kind = live ? "live" : "history"

        guard let payload = OttaiCrypto.decryptPayload(cipher, sessionKeyHex: sessionKeyHex) else {
            decryptFailuresInRow += 1
            logLine("in handleGlucosePayload, \(kind) frame could not be decrypted, length \(cipher.count), blockMod \(cipher.count % 16)", type: .error)
            if decryptFailuresInRow >= Self.maxDecryptFailuresBeforeProblem && !decryptedAnyFrameOnThisLink {
                noteProblem(.frameNotDecryptable)
            }
            return
        }
        decryptFailuresInRow = 0
        decryptedAnyFrameOnThisLink = true

        let widthBeforeFrame = state.learnedRecordSize
        learnRecordSize(payload, deviceVersion: loaded.deviceVersion)
        let records = OttaiParser.frameRecords(payload, deviceVersion: loaded.deviceVersion, learned: heldRecordSize)
        if records.isEmpty {
            logLine("in handleGlucosePayload, \(kind) frame holds no records, payload length \(payload.count)", type: .error)
            if live {
                let generation = connectionGeneration
                runOnCentralQueue(after: Self.emptyLiveHistoryDelay) { [weak self] in
                    guard let self = self, !self.released, self.connectionGeneration == generation else { return }
                    _ = self.requestRecentHistory(reason: "empty-live")
                }
            } else {
                abandonHistoryWindow()
            }
            return
        }

        let method = loaded.resolvedMethod
        let coefficients = loaded.coefficients
        let startMs = effectiveStartMs()
        var readings = [OttaiReading]()
        if live {
            if let last = records.last,
               let reading = OttaiParser.toReading(last, method: method, coefficients: coefficients, activeTimeMs: startMs) {
                readings = [reading]
            }
        } else {
            readings = records.compactMap {
                OttaiParser.toReading($0, method: method, coefficients: coefficients, activeTimeMs: startMs)
            }
        }
        if live && notify && OttaiTiming.notifyHoldsPollDown(readings) {
            lastLiveNotifyAtMs = receivedAtMs
        }

        let previousDataNo = pipeline.lastDataNo
        let result = pipeline.processFrame(
            readings, live: live, notify: notify, receivedAtMs: receivedAtMs, nowMs: receivedAtMs,
            methodBlank: OttaiFormula.isBlank(method)
        )
        if result.misframed {
            // a frame cut at the wrong width is judged whole and never trains the next one
            logLine("in handleGlucosePayload, history frame misframed (\(readings.count) records), discarded", type: .error)
            state.learnedRecordSize = widthBeforeFrame
            abandonHistoryWindow()
            return
        }
        if result.dropped > 0 {
            logLine("in handleGlucosePayload, \(kind) frame dropped \(result.dropped) records past the counter ceiling", type: .error)
        }
        if !result.trace.isEmpty {
            logLine("in handleGlucosePayload, \(kind) frame: \(result.trace.joined(separator: " "))", type: .debug)
        }
        if live && OttaiFormula.isBlank(method) && !problemNotedOnThisLink {
            noteProblem(.noExpression)
        }
        state.pipeline = pipeline.persisted
        persistState()

        deliver(result.emitted, live: live)

        if live {
            if !result.emitted.isEmpty {
                handleHistoryAfterLive(previousDataNo: previousDataNo)
            }
        } else {
            switch historyChain.frameArrived(arrived: result.arrived, settled: result.settled) {
            case .ignored:
                break
            case .partial:
                // the stall timer restarts so a later dropped frame is still caught
                armHistoryWatchdog()
            case .windowCompleteMoreChunks:
                cancelHistoryWatchdog()
                scheduleNextHistoryChunk()
                logLine("in handleGlucosePayload, history chunk complete, \(historyChain.percentAsked)% of the request asked")
            case .chainDone:
                cancelHistoryWatchdog()
                historyChainFinished(receivedAtMs: receivedAtMs)
            }
        }
    }

    // MARK: - history

    /// JugglucoNG `requestRoomBackfillAfterLive` and `ledgerLiveGap`, from the counter alone: the first
    /// live sample of a connection compares the counter with the last one stored, a later one with the
    /// previous sample.
    private func handleHistoryAfterLive(previousDataNo: Int) {
        let liveDataNo = pipeline.lastDataNo
        let previousForHistory = OttaiTiming.previousDataNoForHistory(previousDataNo: previousDataNo, liveDataNo: liveDataNo)
        // a live sample means the live path owns the backfill now: the independent backstop stands down
        initialHistoryToken += 1
        if !historyChecked {
            _ = requestBackfill(newest: liveDataNo, previous: previousForHistory, observedNewest: true)
            return
        }
        if let gap = OttaiTiming.liveGapRange(previousDataNo: previousForHistory, liveDataNo: liveDataNo) {
            noteGap(start: gap.start, endExclusive: gap.endExclusive)
            startNextGapIfIdle()
        }
    }

    private func scheduleInitialHistory(after delay: TimeInterval) {
        initialHistoryToken += 1
        let token = initialHistoryToken
        let generation = connectionGeneration
        runOnCentralQueue(after: delay) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation, self.initialHistoryToken == token else { return }
            self.runInitialHistoryBackfill()
        }
    }

    /// JugglucoNG `runInitialHistoryBackfill`: history is driven without waiting for a live sample.
    private func runInitialHistoryBackfill() {
        guard phase == .streaming, streamingStarted, !sessionKeyHex.isEmpty, state.commandStatus == 3, !historyChecked else { return }

        // a sensor this young has nothing behind its live frame
        let activationMs = pipeline.activeTimeMs
        if activationMs > 0 {
            let ageMs = nowMs() - activationMs
            if ageMs >= 0 && ageMs < Self.initialHistoryMinSensorAgeMs {
                scheduleInitialHistory(after: TimeInterval(Self.initialHistoryMinSensorAgeMs - ageMs) / 1000)
                return
            }
        }

        let estimate = estimatedNewestDataNo()
        let newest = max(pipeline.lastDataNo, estimate)
        if newest <= 0 {
            // no basis yet: a live read teaches the current counter, a few times
            if initialHistoryAttempt < Self.initialHistoryMaxAttempts {
                initialHistoryAttempt += 1
                readLive(reason: "initial-history-probe")
                scheduleInitialHistory(after: Self.initialHistoryRetryDelay)
            } else {
                logLine("in runInitialHistoryBackfill, gave up: no counter basis after \(initialHistoryAttempt) attempts", type: .error)
            }
            return
        }
        let previous = OttaiTiming.previousDataNoForHistory(previousDataNo: pipeline.lastDataNo, liveDataNo: newest)
        let issued = requestBackfill(newest: newest, previous: previous, observedNewest: estimate > 0 && pipeline.lastDataNo <= estimate)
        logLine("in runInitialHistoryBackfill, newest \(newest), previous \(previous), issued \(issued)")
    }

    /// JugglucoNG `estimatedNewestDataNo`: the counter is minutes since activation, two short of now.
    private func estimatedNewestDataNo() -> Int {
        let startMs = effectiveStartMs()
        if startMs <= 0 { return 0 }
        let minutes = Int((nowMs() - startMs) / OttaiTiming.recordIntervalMs)
        return max(minutes - 2, 0)
    }

    /// The one-shot gap check of a connection: everything after the last stored record, or the last day
    /// when nothing is stored. Returns whether a request went out.
    private func requestBackfill(newest: Int, previous: Int, observedNewest: Bool) -> Bool {
        if historyChecked || newest <= 0 { return false }
        if previous < 0 {
            let start = max(0, newest - OttaiHistoryChain.initialBackfillRecords)
            let issued = requestHistoryRange(reason: "initial-backfill", start: start, count: newest - start)
            if issued { historyChecked = true }
            return issued
        }
        let missing = newest - previous - 1
        if missing <= 0 {
            if observedNewest { historyChecked = true }
            return false
        }
        let issued = requestHistoryRange(reason: "gap-backfill", start: previous + 1, count: min(missing, OttaiHistoryChain.maxRequestRecords))
        if issued { historyChecked = true }
        return issued
    }

    private func requestRecentHistory(reason: String) -> Bool {
        let latest = pipeline.lastDataNo
        guard latest > 0 else { return false }
        let start = max(0, latest - OttaiHistoryChain.recentRecords)
        return requestHistoryRange(reason: reason, start: start, count: latest - start)
    }

    /// JugglucoNG `requestHistoryRange`: a new request replaces a running chain, and only the speculative
    /// ones wait for the cooldown.
    @discardableResult
    private func requestHistoryRange(reason: String, start: Int, count: Int) -> Bool {
        guard phase == .streaming, !sessionKeyHex.isEmpty, start >= 0, count > 0, count <= OttaiHistoryChain.maxRequestRecords else { return false }
        let bypassCooldown = reason == "initial-backfill" || reason == "gap-backfill" || reason == "manual"
        let now = nowMs()
        if !bypassCooldown && Double(now - lastHistoryRequestAtMs) < OttaiHistoryChain.requestCooldownSeconds * 1000 {
            return false
        }
        cancelHistoryWatchdog()
        historyChunkToken += 1
        guard let first = historyChain.begin(reason: reason, start: start, count: count) else { return false }
        guard issueHistoryWrite(start: first.start, count: first.count, reason: reason) else {
            historyChain.clear()
            return false
        }
        armHistoryWatchdog()
        return true
    }

    private func issueHistoryWrite(start: Int, count: Int, reason: String) -> Bool {
        let payload = OttaiHistoryChain.requestPayload(start: start, count: count)
        let written = writeCharacteristic(OttaiConstants.charHistoryRequest, payload, logPayload: true)
        if written {
            lastHistoryRequestAtMs = nowMs()
            logLine("in issueHistoryWrite, requested history (\(reason)) start \(start) count \(count)")
        } else {
            logLine("in issueHistoryWrite, the history request could not be written", type: .error)
        }
        return written
    }

    private func armHistoryWatchdog() {
        historyWatchdogToken += 1
        let token = historyWatchdogToken
        let generation = connectionGeneration
        runOnCentralQueue(after: OttaiHistoryChain.pageTimeoutSeconds) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation, self.historyWatchdogToken == token else { return }
            self.historyWatchdogFired()
        }
    }

    private func cancelHistoryWatchdog() {
        historyWatchdogToken += 1
    }

    /// JugglucoNG `checkHistoryWatchdog`: ask the same window again three times, then move on.
    private func historyWatchdogFired() {
        switch historyChain.watchdogFired() {
        case .nothingInFlight:
            break
        case .retry(let start, let count, let attempt):
            logLine("in historyWatchdog, no progress for chunk \(start)..<\(start + count), retry \(attempt)/\(OttaiHistoryChain.maxRetries)", type: .error)
            if issueHistoryWrite(start: start, count: count, reason: "watchdog-retry") {
                armHistoryWatchdog()
            } else {
                moveHistoryChainOn()
            }
        case .giveUp(let moreChunks):
            logLine("in historyWatchdog, the chunk was given up after \(OttaiHistoryChain.maxRetries) retries", type: .error)
            if moreChunks {
                scheduleNextHistoryChunk()
            } else {
                historyChainFinished(receivedAtMs: nowMs())
            }
        }
    }

    /// A history response that yielded nothing usable is still a response: the chain moves on.
    private func abandonHistoryWindow() {
        guard historyChain.window != nil else { return }
        cancelHistoryWatchdog()
        moveHistoryChainOn()
    }

    /// The window in flight is closed without a frame: the next chunk goes, or the chain is over.
    private func moveHistoryChainOn() {
        if historyChain.abandonWindow() {
            scheduleNextHistoryChunk()
        } else {
            historyChainFinished(receivedAtMs: nowMs())
        }
    }

    /// JugglucoNG `requestPendingHistoryChunk`, after its delay.
    private func scheduleNextHistoryChunk() {
        historyChunkToken += 1
        let token = historyChunkToken
        let generation = connectionGeneration
        runOnCentralQueue(after: OttaiHistoryChain.chunkDelaySeconds) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation, self.historyChunkToken == token else { return }
            guard self.historyChain.window == nil, let chunk = self.historyChain.nextChunk() else { return }
            if self.issueHistoryWrite(start: chunk.start, count: chunk.count, reason: "chunk") {
                self.armHistoryWatchdog()
            } else {
                // no half-dead chain: nothing armed, nothing pending
                self.historyChain.clear()
            }
        }
    }

    /// The chain has nothing left to ask: a window that was noted goes next, and live is read at once
    /// because a long burst can still end minutes behind wall time.
    private func historyChainFinished(receivedAtMs: Int64) {
        historyChain.clear()
        if !pendingGaps.isEmpty {
            startNextGapIfIdle()
            return
        }
        guard OttaiTiming.shouldReadLiveAfterHistory(receivedAtMs: receivedAtMs, lastLiveFrameAtMs: pipeline.lastLiveFrameAtMs) else { return }
        postHistoryLiveToken += 1
        let token = postHistoryLiveToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.postHistoryLiveDelay) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation, self.postHistoryLiveToken == token else { return }
            self.readLive(reason: "post-history")
            self.scheduleLivePoll()
        }
    }

    private func noteGap(start: Int, endExclusive: Int) {
        guard endExclusive > start, pendingGaps.count < Self.maxPendingGaps else { return }
        if pendingGaps.contains(where: { $0.start <= start && $0.endExclusive >= endExclusive }) { return }
        pendingGaps.append((start: start, endExclusive: endExclusive))
        logLine("in noteGap, gap \(start)..<\(endExclusive) noted, \(pendingGaps.count) waiting")
    }

    private func startNextGapIfIdle() {
        guard historyChain.isIdle, let next = pendingGaps.first else { return }
        pendingGaps.removeFirst()
        if !requestHistoryRange(reason: "gap-backfill", start: next.start, count: next.endExclusive - next.start) {
            logLine("in startNextGapIfIdle, the gap \(next.start)..<\(next.endExclusive) could not be requested", type: .error)
        }
    }

    // MARK: - delivery to xDrip

    /// Tells xDrip about the session (once per new session) and hands over the readings. Runs on the
    /// central queue; xDrip is called on main.
    private func deliver(_ emitted: [OttaiEmitted], live: Bool) {
        var fresh = [OttaiEmitted]()
        for sample in emitted {
            if live {
                // a read and its notification carry the same sample
                if liveDelivered.get(sample.dataNo) == sample.sampleMs { continue }
                liveDelivered.put(sample.dataNo, sample.sampleMs)
            }
            fresh.append(sample)
        }
        guard !fresh.isEmpty, let newest = fresh.max(by: { $0.sampleMs < $1.sampleMs }) else { return }

        let startMs = effectiveStartMs()
        var newSensorStart: Date?
        if startMs > 0 {
            let announced = state.announcedStartAtMs
            if announced == 0 || abs(startMs - announced) > Self.newSessionTolerance {
                newSensorStart = Date(timeIntervalSince1970: Double(startMs) / 1000)
                state.announcedStartAtMs = startMs
            }
        }

        let now = Date()
        var sensorAge: TimeInterval?
        if startMs > 0 {
            sensorAge = max(0, Double(newest.sampleMs - startMs) / 1000)
        }
        let newestDate = Date(timeIntervalSince1970: Double(newest.sampleMs) / 1000)
        if state.lastReadingDate.map({ newestDate >= $0 }) ?? true {
            state.lastReadingDate = newestDate
            state.lastReadingMgdl = Double(newest.mgdl)
            state.lastRawCurrent = newest.rawCurrent
            state.lastTemperatureC = newest.temperatureC
        }
        state.problem = nil
        state.problemDate = nil
        persistState()

        var glucoseData = [GlucoseData]()
        for sample in fresh.sorted(by: { $0.sampleMs > $1.sampleMs }) {
            glucoseData.append(GlucoseData(
                timeStamp: Date(timeIntervalSince1970: Double(sample.sampleMs) / 1000),
                glucoseLevelRaw: Double(sample.mgdl),
                backfilledAt: (live && sample.fresh) ? nil : now
            ))
        }

        let announcedStart = newSensorStart
        let deliveredData = glucoseData
        let deliveredAge = sensorAge
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let delegate = self.cgmTransmitterDelegate else { return }
            if let announcedStart = announcedStart {
                delegate.newSensorDetected(sensorStartDate: announcedStart)
            }
            var data = deliveredData
            delegate.cgmTransmitterInfoReceived(glucoseData: &data, transmitterBatteryInfo: nil, sensorAge: deliveredAge)
        }
    }

    // MARK: - CGMTransmitter

    func cgmTransmitterType() -> CGMTransmitterType {
        return .ottai
    }

    /// The lifetime the sensor reported, else the material's (cloud-rated) one, else 15 days.
    func maxSensorAgeInDays() -> Double? {
        var accepted: Int64 = 0
        var material: OttaiMaterials?
        if let address = deviceAddress {
            accepted = OttaiDeviceStore.load(address: address).activatedMaxActiveMs
            material = OttaiMaterialsStore.load(address: address)
        }
        if material == nil { material = OttaiMaterialsStore.loadPending() }
        let ms = OttaiConstants.expectedLifetimeMs(
            cloudActiveExpireMs: material?.activeExpireTimeMs ?? 0, acceptedMaxActiveMs: accepted
        )
        return Double(ms) / 86_400_000
    }

    /// The pipeline holds back the first ten minutes itself (`OttaiConstants.warmupSuppressMs`); an xDrip
    /// warm-up on top would only hide more of a new sensor's readings.
    func sensorWarmupDurationInMinutes() -> Double? { 0 }

    func needsSensorStartTime() -> Bool { false }

    /// Values are mg/dL from the sensor's own expression, so xDrip uses no calibrator.
    func isWebOOPEnabled() -> Bool { true }

    func overruleIsWebOOPEnabled() -> Bool { true }

    func nonWebOOPAllowed() -> Bool { false }

    func getCBUUID_Service() -> String { return OttaiConstants.serviceCgm.uuidString }

    func getCBUUID_Receive() -> String { return OttaiConstants.charGlucoseLive.uuidString }
}
