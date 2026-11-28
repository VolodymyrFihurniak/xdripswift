//
//  CGMICanTransmitter.swift
//  xdrip
//
//  Direct Bluetooth driver for the iCan (Sinocare) i3/i6 CGM, ported from JugglucoNG
//  `drivers/icanhealth` (GPL-3.0, see THIRD_PARTY_NOTICES.md). The protocol maths lives in
//  `ICanProtocol.swift`; this file owns the connection: identity from Device Information, the
//  vendor authentication (F3, F4, F6) on the CGM Specific Ops characteristic, live frames on the
//  CGM Measurement characteristic and the history transfer through the Record Access Control Point.
//
//  Never compiled here and never tried on a real sensor.
//

import CoreBluetooth
import Foundation
import os

// MARK: - Link problems and persisted device state

/// What went wrong last, shown on the device screen and cleared by the next reading.
enum ICanLinkProblem: String, Codable {
    case linkLost
    case noAuthenticationAnswer
    case authenticationRejected
    case noReadings
    case historyRefused
    case notACGM
    case sensorNotStarted
    case sensorEnded
}

/// Everything the driver learns about one sensor, kept per Bluetooth address in UserDefaults so the
/// device screen can show it without a connection. Not part of Core Data (the entity only links to
/// its BLEPeripheral). It holds no secret: the user id the sensor is bound to is derived from the
/// Device Information serial.
struct ICanDeviceState: Codable, Equatable {
    var model: String?
    var rawSerial: String?
    var firmware: String?
    var software: String?
    var keyFamily: ICanKeyFamily?
    var profileFamily: String?
    var ratedLifetimeDays: Int?
    /// nil = not tried, true = accepted, false = rejected
    var authAccepted: Bool?
    var recoveredUserId: String?
    var calibrationMarker: Int?
    var sensorStartDate: Date?
    var highestSequence: Int = -1
    var counter: Int?
    var counterDate: Date?
    var launcherState: Int?
    var lastReadingDate: Date?
    var problem: ICanLinkProblem?
    var problemDate: Date?
}

enum ICanDeviceStore {
    private static let keyPrefix = "ican.deviceState."
    private static let lock = NSLock()

    static func load(address: String) -> ICanDeviceState {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(address: address)
    }

    @discardableResult
    static func update(address: String, _ change: (inout ICanDeviceState) -> Void) -> ICanDeviceState {
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

    private static func loadUnlocked(address: String) -> ICanDeviceState {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + address),
              let state = try? JSONDecoder().decode(ICanDeviceState.self, from: data) else {
            return ICanDeviceState()
        }
        return state
    }
}

// MARK: - Transmitter

class CGMICanTransmitter: BluetoothTransmitter, CGMTransmitter {

    private enum Phase {
        case connecting
        case readingIdentity
        case authenticating
        case settingUp
        case streaming
    }

    private struct Identity {
        var model: String?
        var rawSerial: String?
        var firmware: String?
        var software: String?
    }

    private struct SampleToDeliver {
        let sequence: Int
        let date: Date
        let mgdl: Float
    }

    // MARK: - timing

    private static let identityTimeout: TimeInterval = 4
    private static let authenticationTimeout: TimeInterval = 5
    private static let sensorInfoTimeout: TimeInterval = 1.5
    private static let setupTimeout: TimeInterval = 3
    private static let noDataTimeout: TimeInterval = 210
    private static let historyProgressTimeout: TimeInterval = 30
    private static let liveSequenceLagAllowance = 3
    private static let liveGapBackfillMinInterval: TimeInterval = 10 * 60
    /// The first history request reaches back one day; JugglucoNG asks for the whole session, but
    /// the sensors that refuse far requests are recorded to refuse exactly those.
    private static let historyWindowMinutes = 24 * 60
    /// A sequence this far below the highest delivered one means the sensor started a new session.
    private static let sessionRestartSequenceDrop = 30
    /// A derived session start this far from the stored one means another sensor.
    private static let newSensorStartTolerance: TimeInterval = 60 * 60

    // MARK: - properties

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMICan)

    /// Bumped on every connect and disconnect so delayed work of an older connection does nothing.
    private var connectionGeneration = 0
    private var phase: Phase = .connecting
    private var characteristics = [CBUUID: CBCharacteristic]()
    private var sessionBegun = false
    /// A specific problem recorded on this link is not overwritten by the generic "link lost".
    private var problemNotedOnThisLink = false

    private var identity = Identity()
    private var pendingIdentityReads = [CBUUID]()
    private var keyFamily: ICanKeyFamily = .old
    private var profile = ICanProfile.defaultProfile

    private var opsIndicating = false
    private var measurementNotifying = false
    private var racpIndicating = false
    private var waitingForOpsIndication = false

    private var challenge: [UInt8]?
    private var recoveredUserId: String?
    private var authenticationRetried = false
    private var authenticated = false
    private var setupStarted = false
    private var authenticationToken = 0
    private var identityToken = 0
    private var noDataToken = 0
    private var historyToken = 0

    private var clock = ICanClock()
    private var statusRead = false
    private var launcherState: Int?
    private var sessionStartRead = false
    private var lastHandledLiveSequence = -1
    private var pendingLiveGap: ICanSequenceGap?
    private var lastLiveGapBackfillAt: Date?

    private var historyAttempted = false
    private var historyActive = false
    private var historyModernPrefix = true
    private var historyTailRetried = false
    private var historyRequestedFrom = 0
    private var historyBuffer = [Int: SampleToDeliver]()

    // MARK: - initialization

    init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {
        var newAddressAndName: BluetoothTransmitter.DeviceAddressAndName = .notYetConnected(expectedName: nil)
        if let address = address {
            newAddressAndName = .alreadyConnectedBefore(address: address, name: name)
        }

        self.cgmTransmitterDelegate = cGMTransmitterDelegate

        // The sensors may not advertise the CGM service, so the first scan is unfiltered (foreground
        // only); later connections use the stored address. The vendor operations characteristic is
        // both "receive" and "write": the base class enables its indications and writes there.
        super.init(
            addressAndName: newAddressAndName,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [ICanGATT.cgmService, ICanGATT.deviceInfoService],
            CBUUID_ReceiveCharacteristic: ICanGATT.specificOps.uuidString,
            CBUUID_WriteCharacteristic: ICanGATT.specificOps.uuidString,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    // MARK: - persisted state helpers

    private func loadState() -> ICanDeviceState? {
        guard let address = deviceAddress else { return nil }
        return ICanDeviceStore.load(address: address)
    }

    private func updateState(_ change: (inout ICanDeviceState) -> Void) {
        guard let address = deviceAddress else { return }
        ICanDeviceStore.update(address: address, change)
    }

    private func noteProblem(_ problem: ICanLinkProblem) {
        problemNotedOnThisLink = true
        trace("iCan link problem: %{public}@", log: log, category: ConstantsLog.categoryCGMICan, type: .info, problem.rawValue)
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

        // first connection: the first advertisement that looks like an iCan sensor
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard ICanDeviceName.looksLikeICan(name) else { return }
        trace("in didDiscover, iCan candidate found: name=%{public}@, rssi=%{public}d", log: log, category: ConstantsLog.categoryCGMICan, type: .info, name ?? "unknown", RSSI.intValue)
        connectToDiscoveredPeripheral(peripheral)
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetConnectionState()
        super.centralManager(central, didConnect: peripheral)
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !problemNotedOnThisLink, phase != .streaming || error != nil {
            noteProblem(.linkLost)
        }
        invalidateConnection()
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func prepareForRelease() {
        runOnCentralQueue { [weak self] in
            self?.invalidateConnection()
        }
        super.prepareForRelease()
    }

    private func invalidateConnection() {
        connectionGeneration += 1
        authenticationToken += 1
        identityToken += 1
        noDataToken += 1
        historyToken += 1
        historyActive = false
        historyBuffer.removeAll()
        phase = .connecting
    }

    private func resetConnectionState() {
        invalidateConnection()
        characteristics.removeAll()
        sessionBegun = false
        problemNotedOnThisLink = false
        identity = Identity()
        pendingIdentityReads = []
        opsIndicating = false
        measurementNotifying = false
        racpIndicating = false
        waitingForOpsIndication = false
        challenge = nil
        authenticationRetried = false
        authenticated = false
        setupStarted = false
        clock = ICanClock()
        statusRead = false
        sessionStartRead = false
        pendingLiveGap = nil
        historyAttempted = false
        historyModernPrefix = true
        historyTailRetried = false

        let state = loadState()
        recoveredUserId = state?.recoveredUserId
        lastHandledLiveSequence = state?.highestSequence ?? -1
        if let family = state?.keyFamily {
            keyFamily = family
        }
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

        guard characteristics[ICanGATT.specificOps] != nil, characteristics[ICanGATT.measurement] != nil else {
            // a device that matched by name but has no CGM service: stop connecting to it
            noteProblem(.notACGM)
            disconnectAndForget()
            return
        }

        sessionBegun = true
        phase = .readingIdentity
        pendingIdentityReads = [ICanGATT.modelNumber, ICanGATT.serialNumber, ICanGATT.firmwareRevision, ICanGATT.softwareRevision]
            .filter { characteristics[$0] != nil }

        scheduleIdentityTimeout()
        readNextIdentity()
    }

    // MARK: - identity (Device Information)

    private func readNextIdentity() {
        guard let uuid = pendingIdentityReads.first, let characteristic = characteristics[uuid] else {
            identityComplete()
            return
        }
        readValueForCharacteristic(for: characteristic)
    }

    private func handleIdentityValue(_ uuid: CBUUID, _ bytes: [UInt8]) {
        let text = ICanParser.parseDeviceString(bytes)
        switch uuid {
        case ICanGATT.modelNumber: identity.model = text
        case ICanGATT.serialNumber: identity.rawSerial = text
        case ICanGATT.firmwareRevision: identity.firmware = text
        case ICanGATT.softwareRevision: identity.software = text
        default: break
        }
        pendingIdentityReads.removeAll { $0 == uuid }
        if phase == .readingIdentity {
            readNextIdentity()
        }
    }

    private func scheduleIdentityTimeout() {
        identityToken += 1
        let token = identityToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.identityTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.identityToken == token else { return }
            if self.phase == .readingIdentity {
                trace("in identity timeout, continuing with what was read", log: self.log, category: ConstantsLog.categoryCGMICan, type: .info)
                self.identityComplete()
            }
        }
    }

    private func identityComplete() {
        guard phase == .readingIdentity else { return }
        identityToken += 1

        keyFamily = ICanKeyFamily.resolve(launcherSerial: identity.rawSerial, softwareVersion: identity.software)
        profile = ICanProfile.resolve(model: identity.model ?? deviceName, rawSerial: identity.rawSerial, softwareVersion: identity.software)

        let snapshot = identity
        let family = keyFamily
        let resolvedProfile = profile
        updateState {
            $0.model = snapshot.model
            $0.rawSerial = snapshot.rawSerial
            $0.firmware = snapshot.firmware
            $0.software = snapshot.software
            $0.keyFamily = family
            $0.profileFamily = resolvedProfile.familyName
            $0.ratedLifetimeDays = resolvedProfile.ratedLifetimeDays
        }
        trace("in identityComplete, key family %{public}@, profile %{public}@ (interval %{public}d min, warm-up %{public}d min)", log: log, category: ConstantsLog.categoryCGMICan, type: .info, family.rawValue, resolvedProfile.familyName, resolvedProfile.readingIntervalMinutes, resolvedProfile.warmupMinutes)

        beginAuthentication()
    }

    // MARK: - authentication (F3, F4, F6 on the Specific Ops characteristic)

    private func beginAuthentication() {
        phase = .authenticating
        if !opsIndicating {
            // the base class enables the indications at discovery; wait for the confirmation
            waitingForOpsIndication = true
            scheduleAuthenticationTimeout()
            return
        }
        sendChallengeRequest()
    }

    private func sendChallengeRequest() {
        challenge = nil
        waitingForOpsIndication = false
        if writeOps(ICanParser.requestChallengeCommand) {
            scheduleAuthenticationTimeout()
        } else {
            noteProblem(.noAuthenticationAnswer)
        }
    }

    private func writeOps(_ bytes: [UInt8], logPayload: Bool = true) -> Bool {
        guard let characteristic = characteristics[ICanGATT.specificOps] else { return false }
        return writeDataToPeripheral(data: Data(bytes), characteristicToWriteTo: characteristic, type: .withResponse, logPayload: logPayload)
    }

    private func scheduleAuthenticationTimeout() {
        authenticationToken += 1
        let token = authenticationToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.authenticationTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.authenticationToken == token else { return }
            guard self.phase == .authenticating, !self.authenticated else { return }
            self.noteProblem(.noAuthenticationAnswer)
            // nothing more to do on this link; the silence watchdog recycles the connection
            self.scheduleNoDataWatchdog()
        }
    }

    private func handleOpsResponse(_ bytes: [UInt8]) {
        if ICanParser.isChallengeResponse(bytes), let received = ICanParser.extractChallenge(bytes) {
            handleChallenge(received)
        } else if bytes.count >= 3, bytes[1] == 0xF4 {
            handleAuthenticationResult(bytes)
        } else if ICanParser.isSensorInfoResponse(bytes) {
            handleSensorInfo(bytes)
        } else {
            trace("in handleOpsResponse, unhandled response of %{public}d bytes", log: log, category: ConstantsLog.categoryCGMICan, type: .debug, bytes.count)
        }
    }

    private func handleChallenge(_ received: [UInt8]) {
        guard phase == .authenticating, !authenticated else { return }
        challenge = received

        let userId = recoveredUserId ?? identity.rawSerial
        guard let token = ICanParser.deriveAuthToken(challenge: received, userId: userId ?? "", authKey: keyFamily.authKey),
              let packet = ICanParser.buildAuthTokenPacket(token) else {
            noteProblem(.authenticationRejected)
            return
        }
        // the token is derived from the sensor's serial: keep it out of the traces
        if writeOps(packet, logPayload: false) {
            scheduleAuthenticationTimeout()
        } else {
            noteProblem(.noAuthenticationAnswer)
        }
    }

    private func handleAuthenticationResult(_ bytes: [UInt8]) {
        authenticationToken += 1

        if ICanParser.isAuthSuccess(bytes) {
            authenticated = true
            updateState { $0.authAccepted = true }
            trace("in handleAuthenticationResult, sensor accepted the authentication", log: log, category: ConstantsLog.categoryCGMICan, type: .info)
            // ask for the sensor info (calibration marker); setup continues with or without the answer
            _ = writeOps(ICanParser.requestSensorInfoCommand)
            scheduleSensorInfoTimeout()
            return
        }

        // A rejected sensor answers with the user id it is bound to (encrypted); adopt it once.
        if ICanParser.parseAuthResult(bytes) == 0x02, !authenticationRetried,
           let recovered = ICanParser.recoverUserIdFromAuthReject(bytes, challenge: challenge, authKey: keyFamily.authKey),
           ICanParser.normalizeStandaloneUserId(recovered) != ICanParser.normalizeStandaloneUserId(recoveredUserId ?? identity.rawSerial) {
            authenticationRetried = true
            recoveredUserId = recovered
            updateState { $0.recoveredUserId = recovered }
            trace("in handleAuthenticationResult, sensor is bound to another user id; retrying once", log: log, category: ConstantsLog.categoryCGMICan, type: .info)
            sendChallengeRequest()
            return
        }

        updateState { $0.authAccepted = false }
        noteProblem(.authenticationRejected)
        scheduleNoDataWatchdog()
    }

    private func scheduleSensorInfoTimeout() {
        authenticationToken += 1
        let token = authenticationToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.sensorInfoTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.authenticationToken == token else { return }
            self.setupAfterAuthentication()
        }
    }

    private func handleSensorInfo(_ bytes: [UInt8]) {
        if let marker = ICanParser.parseSensorInfoMarker(bytes) {
            updateState { $0.calibrationMarker = marker }
        }
        authenticationToken += 1
        setupAfterAuthentication()
    }

    // MARK: - setup after authentication

    private func setupAfterAuthentication() {
        guard authenticated, !setupStarted else { return }
        setupStarted = true
        phase = .settingUp

        if let measurement = characteristics[ICanGATT.measurement] {
            setNotifyValue(true, for: measurement)
        }
        if let racp = characteristics[ICanGATT.racp] {
            setNotifyValue(true, for: racp)
        }
        if let status = characteristics[ICanGATT.status] {
            readValueForCharacteristic(for: status)
        } else {
            statusRead = true
        }
        if let sessionStart = characteristics[ICanGATT.sessionStart] {
            readValueForCharacteristic(for: sessionStart)
        } else {
            sessionStartRead = true
        }
        scheduleNoDataWatchdog()

        // start the history transfer even when one of the reads never answers
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.setupTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation else { return }
            self.statusRead = true
            self.sessionStartRead = true
            self.startHistoryIfPossible()
        }
    }

    private func handleStatusValue(_ bytes: [UInt8]) {
        statusRead = true
        if let status = ICanParser.parseStatus(bytes) {
            let now = Date()
            clock.counter = status.sequence
            clock.counterObservedAt = now
            launcherState = status.launcherState
            updateState {
                $0.counter = status.sequence
                $0.counterDate = now
                $0.launcherState = status.launcherState
            }
            switch status.launcherState {
            case ICanConstants.launcherStateIdle:
                noteProblem(.sensorNotStarted)
            case ICanConstants.launcherStateEnded:
                noteProblem(.sensorEnded)
            default:
                break
            }
        }
        startHistoryIfPossible()
    }

    private func handleSessionStartValue(_ bytes: [UInt8]) {
        sessionStartRead = true
        if let parsed = ICanParser.parseSessionStart(bytes) {
            clock.sessionStart = parsed.date()
        }
        startHistoryIfPossible()
    }

    // MARK: - notifications and values

    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)

        if error != nil {
            if characteristic.uuid == ICanGATT.specificOps {
                noteProblem(.noAuthenticationAnswer)
            }
            return
        }

        switch characteristic.uuid {
        case ICanGATT.specificOps:
            opsIndicating = characteristic.isNotifying
            if opsIndicating && waitingForOpsIndication && phase == .authenticating {
                sendChallengeRequest()
            }
        case ICanGATT.measurement:
            measurementNotifying = characteristic.isNotifying
            startHistoryIfPossible()
        case ICanGATT.racp:
            racpIndicating = characteristic.isNotifying
            startHistoryIfPossible()
        default:
            break
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)

        let uuid = characteristic.uuid
        if error != nil {
            // a failed Device Information, status or session read must not stall the setup
            switch uuid {
            case ICanGATT.modelNumber, ICanGATT.serialNumber, ICanGATT.firmwareRevision, ICanGATT.softwareRevision:
                handleIdentityValue(uuid, [])
            case ICanGATT.status:
                handleStatusValue([])
            case ICanGATT.sessionStart:
                handleSessionStartValue([])
            default:
                break
            }
            return
        }
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)

        switch uuid {
        case ICanGATT.modelNumber, ICanGATT.serialNumber, ICanGATT.firmwareRevision, ICanGATT.softwareRevision:
            handleIdentityValue(uuid, bytes)
        case ICanGATT.specificOps:
            handleOpsResponse(bytes)
        case ICanGATT.measurement:
            handleMeasurement(bytes)
        case ICanGATT.racp:
            handleRacp(bytes)
        case ICanGATT.status:
            handleStatusValue(bytes)
        case ICanGATT.sessionStart:
            handleSessionStartValue(bytes)
        default:
            break
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
        guard error != nil else { return }

        if characteristic.uuid == ICanGATT.racp, historyActive {
            noteProblem(.historyRefused)
            finishHistory()
        } else if characteristic.uuid == ICanGATT.specificOps, !authenticated {
            noteProblem(.noAuthenticationAnswer)
        }
    }

    // MARK: - live frames

    private func handleMeasurement(_ bytes: [UInt8]) {
        if ICanParser.isSnNotification(bytes) {
            handleSnBatch(bytes)
            return
        }
        guard authenticated, let challenge = challenge else { return }

        if bytes.count == ICanConstants.aesBlockSize {
            if historyActive {
                handleRawHistoryRecord(bytes, challenge: challenge)
            }
            return
        }

        guard let reading = ICanParser.parseLive(
            bytes,
            family: keyFamily,
            challenge: challenge,
            direct: false,
            warmupMinutes: profile.warmupMinutes
        ) else {
            // an encrypted history frame has the live shape but another subtype
            if historyActive && bytes.count >= ICanConstants.liveFrameSize {
                handleRawHistoryRecord(bytes, challenge: challenge)
            }
            return
        }

        guard ICanConstants.isValidMgdl(reading.mgdl) else {
            trace("in handleMeasurement, glucose out of range (seq %{public}d), ignored", log: log, category: ConstantsLog.categoryCGMICan, type: .info, reading.sequence)
            return
        }

        let now = Date()
        let counter = clock.counter ?? -1
        let isLive = counter < 0 || reading.sequence >= counter - Self.liveSequenceLagAllowance

        if historyActive && !isLive {
            addHistorySample(sequence: reading.sequence, mgdl: reading.mgdl, now: now)
            historyProgressed()
            return
        }

        handleLiveReading(reading, now: now)
    }

    private func handleLiveReading(_ reading: ICanLiveReading, now: Date) {
        phase = .streaming
        scheduleNoDataWatchdog()

        // a much lower sequence than anything delivered is a new session of the sensor
        if lastHandledLiveSequence >= 0, reading.sequence + Self.sessionRestartSequenceDrop < lastHandledLiveSequence {
            trace("in handleLiveReading, sequence went back from %{public}d to %{public}d: new session", log: log, category: ConstantsLog.categoryCGMICan, type: .info, lastHandledLiveSequence, reading.sequence)
            lastHandledLiveSequence = -1
            pendingLiveGap = nil
            updateState { $0.highestSequence = -1 }
        }

        let duplicate = reading.sequence <= lastHandledLiveSequence
        // the timestamp comes from the timeline as it was before this frame moved the counter
        let timestamp = ICanTimeline.liveTimestamp(sequence: reading.sequence, now: now, clock: clock)

        if reading.sequence >= (clock.counter ?? -1) {
            clock.counter = reading.sequence
            clock.counterObservedAt = now
        }
        if duplicate { return }

        let previous = lastHandledLiveSequence
        lastHandledLiveSequence = reading.sequence
        if previous >= 0, let gap = ICanHistoryPolicy.liveGapBetween(
            previousSequence: previous,
            currentSequence: reading.sequence,
            readingIntervalMinutes: profile.readingIntervalMinutes
        ) {
            pendingLiveGap = gap
            rearmHistoryForGap(now: now)
        }

        deliver([SampleToDeliver(sequence: reading.sequence, date: timestamp, mgdl: reading.mgdl)], live: true)
    }

    private func scheduleNoDataWatchdog() {
        noDataToken += 1
        let token = noDataToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.noDataTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.noDataToken == token else { return }
            trace("in noDataWatchdog, no live frame for %{public}d seconds, reconnecting", log: self.log, category: ConstantsLog.categoryCGMICan, type: .info, Int(Self.noDataTimeout))
            self.noteProblem(.noReadings)
            self.disconnect()
        }
    }

    // MARK: - history (RACP)

    private func startHistoryIfPossible() {
        guard authenticated, setupStarted, !historyActive, !historyAttempted else { return }
        guard racpIndicating, measurementNotifying, statusRead, sessionStartRead else { return }
        guard let counter = clock.counter, counter > 0 else { return }

        historyAttempted = true
        let interval = profile.readingIntervalMinutes
        guard var start = ICanHistoryPolicy.automaticGlucoseHistoryStartSequence(
            readingIntervalMinutes: interval,
            currentSequence: counter,
            latestKnownSequence: lastHandledLiveSequence,
            pendingLiveGap: pendingLiveGap
        ) else {
            trace("in startHistoryIfPossible, nothing missing", log: log, category: ConstantsLog.categoryCGMICan, type: .debug)
            return
        }
        // never reach back further than the window
        let earliest = max(interval, ((counter - Self.historyWindowMinutes) / interval) * interval)
        if start < earliest { start = earliest }
        requestHistory(from: start)
    }

    private func requestHistory(from sequence: Int) {
        guard let racp = characteristics[ICanGATT.racp] else { return }
        let command = ICanParser.racpReportFromGlucose(offset: sequence, modernPrefix: historyModernPrefix)
        historyRequestedFrom = sequence
        historyActive = true
        historyBuffer.removeAll()
        trace("in requestHistory, from sequence %{public}d, %{public}@ command", log: log, category: ConstantsLog.categoryCGMICan, type: .info, sequence, historyModernPrefix ? "modern" : "legacy")
        if writeDataToPeripheral(data: Data(command), characteristicToWriteTo: racp, type: .withResponse) {
            historyProgressed()
        } else {
            historyActive = false
        }
    }

    private func rearmHistoryForGap(now: Date) {
        guard authenticated, setupStarted, !historyActive else { return }
        if let last = lastLiveGapBackfillAt, now.timeIntervalSince(last) < Self.liveGapBackfillMinInterval { return }
        lastLiveGapBackfillAt = now
        historyAttempted = false
        startHistoryIfPossible()
    }

    /// Re-arms the progress timer; a transfer that goes quiet is finished with what it delivered.
    private func historyProgressed() {
        historyToken += 1
        let token = historyToken
        let generation = connectionGeneration
        scheduleNoDataWatchdog()
        runOnCentralQueue(after: Self.historyProgressTimeout) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, self.historyToken == token, self.historyActive else { return }
            trace("in history timeout, finishing with what arrived", log: self.log, category: ConstantsLog.categoryCGMICan, type: .info)
            self.finishHistory()
        }
    }

    private func handleRacp(_ bytes: [UInt8]) {
        guard let code = ICanParser.parseRacpResultCode(bytes) else { return }
        guard historyActive else { return }

        switch code {
        case ICanConstants.racpResultSuccess, ICanConstants.racpResultNoData:
            finishHistory()
        case ICanConstants.racpResultNotSupported:
            if historyModernPrefix {
                historyModernPrefix = false
                retryHistory(from: historyRequestedFrom)
            } else {
                noteProblem(.historyRefused)
                finishHistory()
            }
        case ICanConstants.racpResultFailed:
            if historyModernPrefix {
                historyModernPrefix = false
                retryHistory(from: historyRequestedFrom)
            } else if !historyTailRetried, let counter = clock.counter,
                      let tail = ICanHistoryPolicy.tailRetryStartSequence(
                        readingIntervalMinutes: profile.readingIntervalMinutes,
                        currentSequence: counter,
                        requestedSequence: historyRequestedFrom
                      ) {
                // both command families refused the range: one more try from the live edge
                historyTailRetried = true
                historyModernPrefix = true
                retryHistory(from: tail)
            } else {
                noteProblem(.historyRefused)
                finishHistory()
            }
        default:
            finishHistory()
        }
    }

    private func retryHistory(from sequence: Int) {
        historyActive = false
        requestHistory(from: sequence)
    }

    private func handleSnBatch(_ bytes: [UInt8]) {
        guard historyActive, let challenge = challenge else { return }
        guard let batch = ICanParser.parseSnHistoryBatch(
            bytes,
            challenge: challenge,
            direct: false,
            launcherSerial: identity.rawSerial,
            softwareVersion: identity.software,
            readingIntervalMinutes: profile.readingIntervalMinutes
        ) else {
            trace("in handleSnBatch, batch of %{public}d bytes could not be parsed", log: log, category: ConstantsLog.categoryCGMICan, type: .info, bytes.count)
            return
        }
        guard batch.subtype == ICanConstants.snSubtypeGlucose else { return }
        let now = Date()
        for record in batch.records {
            if let field = record.glucose {
                addHistorySample(sequence: record.sequence, mgdl: field.mgdl, now: now)
            }
        }
        historyProgressed()
    }

    private func handleRawHistoryRecord(_ bytes: [UInt8], challenge: [UInt8]) {
        guard let record = ICanParser.parseEncryptedHistoryRecord(
            bytes,
            challenge: challenge,
            readingOriginalHistory: false,
            direct: false,
            launcherSerial: identity.rawSerial,
            softwareVersion: identity.software,
            warmupMinutes: profile.warmupMinutes
        ), record.subtype == ICanConstants.snSubtypeGlucose, let field = record.glucose else { return }
        addHistorySample(sequence: record.sequence, mgdl: field.mgdl, now: Date())
        historyProgressed()
    }

    private func addHistorySample(sequence: Int, mgdl: Float, now: Date) {
        guard ICanConstants.isValidMgdl(mgdl) else { return }
        guard let date = ICanTimeline.resolve(sequence: sequence, now: now, clock: clock, requireRecent: false) else { return }
        if ICanHistoryPolicy.shouldSkipHistoryOverlap(
            sequence: sequence,
            sampleTime: date,
            coveredSequence: lastHandledLiveSequence,
            coveredTime: nil,
            pendingLiveGap: pendingLiveGap
        ) {
            return
        }
        historyBuffer[sequence] = SampleToDeliver(sequence: sequence, date: date, mgdl: mgdl)
    }

    private func finishHistory() {
        historyToken += 1
        let wasActive = historyActive
        historyActive = false
        let samples = Array(historyBuffer.values)
        historyBuffer.removeAll()
        guard wasActive else { return }

        trace("in finishHistory, %{public}d reading(s) to deliver", log: log, category: ConstantsLog.categoryCGMICan, type: .info, samples.count)
        if let newest = samples.map({ $0.sequence }).max() {
            lastHandledLiveSequence = max(lastHandledLiveSequence, newest)
            pendingLiveGap = nil
        }
        deliver(samples, live: false)
    }

    // MARK: - delivery to xDrip

    /// The session start the timeline implies: the sensor's own start while it agrees with the
    /// counter, else the moment the counter was read minus its minutes.
    private func estimatedSessionStart() -> Date? {
        if let start = clock.sessionStart,
           ICanTimeline.sessionMatchesCounter(sessionStart: start, counter: clock.counter, counterObservedAt: clock.counterObservedAt ?? Date()) {
            return start
        }
        if let counter = clock.counter, let observed = clock.counterObservedAt {
            return observed.addingTimeInterval(-Double(counter) * ICanTimeline.sequenceUnit)
        }
        return nil
    }

    private func deliver(_ samples: [SampleToDeliver], live: Bool) {
        let valid = samples.filter { ICanConstants.isValidMgdl($0.mgdl) }
        guard !valid.isEmpty else { return }

        let now = Date()
        let newest = valid.max { $0.date < $1.date } ?? valid[0]
        let newestSequence = valid.map { $0.sequence }.max() ?? newest.sequence

        // sensor session bookkeeping: a start date far from the stored one is another sensor
        let stored = loadState()?.sensorStartDate
        var startDate = stored
        var detectedNewSensor = false
        if let estimate = estimatedSessionStart() {
            if stored == nil || abs(stored?.timeIntervalSince(estimate) ?? 0) > Self.newSensorStartTolerance {
                startDate = estimate
                detectedNewSensor = true
            }
        }
        let sensorAge: TimeInterval? = startDate.map { max(0, newest.date.timeIntervalSince($0)) }

        updateState {
            if detectedNewSensor { $0.sensorStartDate = startDate }
            $0.highestSequence = max($0.highestSequence, newestSequence)
            $0.lastReadingDate = max($0.lastReadingDate ?? .distantPast, newest.date)
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
        let newSensorStartDate = startDate

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let delegate = self.cgmTransmitterDelegate else { return }
            if detectedNewSensor {
                delegate.newSensorDetected(sensorStartDate: newSensorStartDate)
            }
            var data = glucoseData
            delegate.cgmTransmitterInfoReceived(glucoseData: &data, transmitterBatteryInfo: nil, sensorAge: sensorAge)
        }
    }

    // MARK: - CGMTransmitter

    func cgmTransmitterType() -> CGMTransmitterType {
        return .iCan
    }

    func maxSensorAgeInDays() -> Double? {
        let days = loadState()?.ratedLifetimeDays ?? ICanProfile.defaultProfile.ratedLifetimeDays
        return Double(days)
    }

    /// iCan has no warm-up that hides readings: the first minutes are only encoded differently.
    func sensorWarmupDurationInMinutes() -> Double? { 0 }

    func needsSensorStartTime() -> Bool { false }

    /// Values are mg/dL from the sensor's own algorithm, so xDrip uses no calibrator.
    func isWebOOPEnabled() -> Bool { true }

    func overruleIsWebOOPEnabled() -> Bool { true }

    func nonWebOOPAllowed() -> Bool { false }

    func getCBUUID_Service() -> String { return ICanGATT.cgmService.uuidString }

    func getCBUUID_Receive() -> String { return ICanGATT.measurement.uuidString }
}
