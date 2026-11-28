//
//  CGMMQTransmitter.swift
//  xdrip
//
//  Direct Bluetooth driver for the MQ / Glutec CGM, ported from JugglucoNG `drivers/mq`
//  (`MQBleManager`; GPL-3.0, see THIRD_PARTY_NOTICES.md). The frame format, the algorithm and the
//  session logic that can be tested without a radio live in `MQProtocol.swift`, `MQAlgorithm.swift`
//  and `MQSession.swift`; this file owns the connection: the Nordic UART service, the frames the
//  transmitter pushes (BEGIN_WORK, heartbeat, glucose records), the acknowledgements it expects, the
//  burst buffer, the watchdogs, the reset command and the delivery of the readings to xDrip.
//
//  What the fork does without the vendor cloud: nothing is sent to the vendor's servers, so there is
//  no factory sensitivity, algorithm version, packages or multiplier from the server. They are the
//  defaults or what the user enters on the device screen (`MQConfiguration`), and a reading needs
//  either a sensitivity the user typed or a fingerstick (xDrip's calibration button). Until one of
//  them exists the transmitter is followed (packets are counted, the session timed) but no value is
//  shown, because inventing one would be worse than none. See docs/mq.md.
//
//  Differences from the Android driver that the platform or the missing cloud force:
//  - iOS has no MAC address; the peripheral is known by its Core Bluetooth identifier.
//  - The vendor's session, history and report uploads are not ported, so a gap longer than what the
//    transmitter replays by itself is not filled.
//  - The learned CRC variant is not kept: JugglucoNG never uses it for anything it sends.
//  - Notifications are parsed one by one, as JugglucoNG does; a frame split over two notifications is
//    rejected.
//
//  Never compiled here and never tried on a real sensor.
//

import CoreBluetooth
import Foundation
import os

// MARK: - Link problems and persisted device state

/// What went wrong last, shown on the device screen and cleared by the next reading.
enum MQLinkProblem: String, Codable {
    case linkLost
    case notAnMQ
    case notificationsFailed
    case noFramesAfterConnect
    case linkSilent
    case noGlucose
    case beginWorkLoop
    case writeFailed
}

/// Everything the driver learns about one transmitter, kept per Bluetooth address in UserDefaults so
/// the device screen can show it without a connection. Not part of Core Data (the entity only links to
/// its BLEPeripheral). It holds no secret: the protocol is not encrypted.
struct MQDeviceState: Codable, Equatable {
    var advertisedName: String?
    /// K, B, the last processed current, the highest delivered packet and the session start.
    var tracker = MQSessionTracker()
    /// A Protocol02 session marker was seen: the captured reset command is used.
    var observedProtocol02 = false
    /// The session start xDrip was last told about (0 = none yet), so a new session is announced once.
    var announcedStartAtMs: Int64 = 0
    /// The `MQConfiguration.revision` the solved slope was computed under.
    var appliedConfigurationRevision = 0
    var lastFrameDate: Date?
    var lastReadingDate: Date?
    var lastReadingMgdlTimes10: Int?
    var lastResetDate: Date?
    var problem: MQLinkProblem?
    var problemDate: Date?
}

enum MQDeviceStore {
    private static let keyPrefix = "mq.deviceState."
    private static let lock = NSLock()

    static func load(address: String) -> MQDeviceState {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(address: address)
    }

    @discardableResult
    static func update(address: String, _ change: (inout MQDeviceState) -> Void) -> MQDeviceState {
        lock.lock()
        defer { lock.unlock() }
        var state = loadUnlocked(address: address)
        change(&state)
        save(state, address: address)
        return state
    }

    static func save(_ state: MQDeviceState, address: String) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: keyPrefix + address)
        }
    }

    static func clear(address: String) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: keyPrefix + address)
    }

    private static func loadUnlocked(address: String) -> MQDeviceState {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + address),
              let state = try? JSONDecoder().decode(MQDeviceState.self, from: data) else {
            return MQDeviceState()
        }
        return state
    }
}

/// What the user entered for one transmitter. Separate from the device state so the device screen can
/// change it without touching the session the driver is working on.
enum MQConfigurationStore {
    private static let keyPrefix = "mq.configuration."
    private static let lock = NSLock()

    static func load(address: String) -> MQConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + address),
              let configuration = try? JSONDecoder().decode(MQConfiguration.self, from: data) else {
            return MQConfiguration()
        }
        return configuration
    }

    /// Applies `change`, counts it as a change that matters to the algorithm when the algorithm inputs
    /// differ afterwards, and stores the result.
    @discardableResult
    static func update(address: String, _ change: (inout MQConfiguration) -> Void) -> MQConfiguration {
        var configuration = load(address: address)
        let before = configuration
        change(&configuration)
        if configuration != before {
            configuration.noteChanged()
        }
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: keyPrefix + address)
        }
        return configuration
    }

    static func clear(address: String) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: keyPrefix + address)
    }
}

// MARK: - Transmitter

class CGMMQTransmitter: BluetoothTransmitter, CGMTransmitter {

    // MARK: - timing

    /// JugglucoNG `ACTIVE_SESSION_RECONNECT_DELAY_MS`.
    private static let reconnectDelay: TimeInterval = 2
    /// JugglucoNG `FIRST_FRAME_GRACE_MS`.
    private static let frameGrace: TimeInterval = 30
    /// JugglucoNG `NO_DATA_WATCHDOG_MULTIPLIER`.
    private static let noDataMultiplier = 4.0
    /// JugglucoNG `LINK_FRAME_TIMEOUT_MULTIPLIER`.
    private static let frameTimeoutMultiplier = 2.0
    /// JugglucoNG `BG_BURST_FLUSH_DELAY_MS`.
    private static let burstFlushDelay: TimeInterval = 0.75
    /// JugglucoNG `RESET_RECONNECT_DELAY_MS`.
    private static let resetReconnectDelay: TimeInterval = 0.7
    /// JugglucoNG `MAX_BEGIN_WORK_RETRIES_BEFORE_RECONNECT`.
    private static let maxBeginWorkRetries = 5
    private static let writeRetryDelay: TimeInterval = 0.25
    /// A new sensor session is announced to xDrip when its start moved by more than this.
    private static let newSessionTolerance: Int64 = 60 * 60 * 1000
    /// Notifications that are not frames before a first connection is given up as not being an MQ.
    private static let maxRejectedFramesBeforeFirstFrame = 3

    private static var intervalSeconds: TimeInterval {
        return TimeInterval(MQProfile.default.readingIntervalMinutes) * 60
    }

    private static var firstFrameTimeout: TimeInterval { return intervalSeconds + frameGrace }
    private static var protocolFrameTimeout: TimeInterval { return frameTimeoutMultiplier * intervalSeconds + frameGrace }
    private static var noDataTimeout: TimeInterval { return noDataMultiplier * intervalSeconds }

    // MARK: - properties

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMMQ)

    /// Bumped on every connect and disconnect so delayed work of an older connection does nothing.
    private var connectionGeneration = 0
    private var burstFlushToken = 0
    private var firstFrameToken = 0
    private var protocolFrameToken = 0
    private var noDataToken = 0

    private var released = false
    private var streaming = false
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    /// The local name of the advertisement that led to the first connection.
    private var discoveredAdvertisedName: String?

    private var state = MQDeviceState()
    private var stateLoadedForAddress: String?
    private var burst = MQBurstBuffer()

    private var beginWorkRetryCount = 0
    private var rejectedFramesWithoutValidFrame = 0
    private var validFrameOnThisLink = false
    private var problemNotedOnThisLink = false

    // MARK: - initialization

    init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {
        var newAddressAndName: BluetoothTransmitter.DeviceAddressAndName = .notYetConnected(expectedName: nil)
        if let address = address {
            newAddressAndName = .alreadyConnectedBefore(address: address, name: name)
        }

        self.cgmTransmitterDelegate = cGMTransmitterDelegate

        // The advertisement is not known to carry the Nordic UART service, so the first scan is
        // unfiltered (foreground only); later connections use the stored address.
        super.init(
            addressAndName: newAddressAndName,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [MQConstants.serviceUUID],
            CBUUID_ReceiveCharacteristic: MQConstants.txNotifyUUID.uuidString,
            CBUUID_WriteCharacteristic: MQConstants.rxWriteUUID.uuidString,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    // MARK: - persisted state helpers

    private func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Loads the stored state for the address once per address; a fresh process takes over the stored
    /// session the way JugglucoNG's `restoreFromPersistence` does.
    private func loadStateIfNeeded() {
        guard let address = deviceAddress, stateLoadedForAddress != address else { return }
        var loaded = MQDeviceStore.load(address: address)
        loaded.tracker.prepareForNewRun()
        state = loaded
        stateLoadedForAddress = address
    }

    private func persistState() {
        guard !released, let address = deviceAddress, stateLoadedForAddress == address else { return }
        MQDeviceStore.save(state, address: address)
    }

    private func currentConfiguration() -> MQConfiguration {
        guard let address = deviceAddress else { return MQConfiguration() }
        return MQConfigurationStore.load(address: address)
    }

    /// The algorithm inputs, after dropping the solved slope when the user changed them since.
    private func currentParameters() -> MQAlgorithmParameters {
        let configuration = currentConfiguration()
        if configuration.revision != state.appliedConfigurationRevision {
            logLine("in currentParameters, configuration changed (revision \(state.appliedConfigurationRevision) to \(configuration.revision)), the solved slope starts over")
            state.tracker.resetAlgorithmState()
            state.appliedConfigurationRevision = configuration.revision
            persistState()
        }
        return configuration.parameters
    }

    private func logLine(_ message: String, type: OSLogType = .info) {
        trace("%{public}@", log: log, category: ConstantsLog.categoryCGMMQ, type: type, message)
    }

    private func noteProblem(_ problem: MQLinkProblem) {
        problemNotedOnThisLink = true
        logLine("MQ link problem: \(problem.rawValue)")
        loadStateIfNeeded()
        state.problem = problem
        state.problemDate = Date()
        persistState()
    }

    // MARK: - connection lifecycle

    override func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // a stored address matches exactly
        if deviceAddress != nil {
            super.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
            return
        }

        // first connection: the first advertisement that looks like an MQ transmitter
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard MQDeviceName.looksLikeMQ(name: name, advertisesNUS: services.contains(MQConstants.serviceUUID)) else { return }
        discoveredAdvertisedName = name
        logLine("in didDiscover, MQ candidate found, rssi \(RSSI.intValue)")
        connectToDiscoveredPeripheral(peripheral)
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetConnectionState()
        super.centralManager(central, didConnect: peripheral)
        loadStateIfNeeded()
        if state.advertisedName == nil {
            state.advertisedName = discoveredAdvertisedName ?? deviceName
            persistState()
        }
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        loadStateIfNeeded()
        // JugglucoNG `flushPendingBgBurst("disconnect")`: records already acknowledged are not lost
        flushBurst(reason: "disconnect")
        if !problemNotedOnThisLink, streaming {
            noteProblem(.linkLost)
        }
        invalidateConnection()
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func reconnectAfterDisconnect(_ central: CBCentralManager) {
        guard !released else { return }
        // JugglucoNG waits two seconds before it connects again
        runOnCentralQueue(after: Self.reconnectDelay) { [weak self] in
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

    private func invalidateConnection() {
        connectionGeneration += 1
        burstFlushToken += 1
        firstFrameToken += 1
        protocolFrameToken += 1
        noDataToken += 1
        streaming = false
    }

    private func resetConnectionState() {
        invalidateConnection()
        txCharacteristic = nil
        rxCharacteristic = nil
        burst.clear()
        beginWorkRetryCount = 0
        rejectedFramesWithoutValidFrame = 0
        validFrameOnThisLink = false
        problemNotedOnThisLink = false
    }

    // MARK: - service and characteristic discovery

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        super.peripheral(peripheral, didDiscoverServices: error)
        guard error == nil else { return }
        if !(peripheral.services ?? []).contains(where: { $0.uuid == MQConstants.serviceUUID }) {
            logLine("in didDiscoverServices, the Nordic UART service is not present", type: .error)
            giveUpOrReconnectAfterWrongDevice()
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        guard service.uuid == MQConstants.serviceUUID else { return }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == MQConstants.txNotifyUUID { txCharacteristic = characteristic }
            if characteristic.uuid == MQConstants.rxWriteUUID { rxCharacteristic = characteristic }
        }
        guard !streaming else { return }

        guard txCharacteristic != nil, rxCharacteristic != nil else {
            logLine("in didDiscoverCharacteristicsFor, the transmit or receive characteristic is missing", type: .error)
            giveUpOrReconnectAfterWrongDevice()
            return
        }

        // the base class switches the notifications on; JugglucoNG goes to its streaming phase here
        streaming = true
        loadStateIfNeeded()
        logLine("in didDiscoverCharacteristicsFor, Nordic UART service ready, waiting for frames")
        armFirstFrameWatchdog()
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
        guard characteristic.uuid == MQConstants.txNotifyUUID else { return }
        if let error = error {
            logLine("in didUpdateNotificationStateFor, the notifications could not be switched on: \(error.localizedDescription)", type: .error)
            noteProblem(.notificationsFailed)
        } else {
            logLine("in didUpdateNotificationStateFor, notifications \(characteristic.isNotifying ? "on" : "off")")
        }
    }

    /// A device that does not speak the protocol: when it never sent a frame it is forgotten (it was
    /// probably a different Nordic UART device), otherwise the link is only dropped and tried again.
    private func giveUpOrReconnectAfterWrongDevice() {
        loadStateIfNeeded()
        if state.lastFrameDate == nil {
            logLine("in giveUpOrReconnectAfterWrongDevice, the device never sent an MQ frame and is forgotten", type: .error)
            if let address = deviceAddress {
                MQDeviceStore.clear(address: address)
            }
            stateLoadedForAddress = nil
            disconnectAndForget()
        } else {
            noteProblem(.notAnMQ)
            disconnect()
        }
    }

    // MARK: - values

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
        guard error == nil, characteristic.uuid == MQConstants.txNotifyUUID, let value = characteristic.value else { return }
        handleNotification(value)
    }

    private func handleNotification(_ value: Data) {
        loadStateIfNeeded()

        guard let frame = MQParser.parse(data: value) else {
            logLine("in handleNotification, rejected a notification of \(value.count) bytes that is not a frame: \(value.hexEncodedString())", type: .error)
            if !validFrameOnThisLink && state.lastFrameDate == nil {
                rejectedFramesWithoutValidFrame += 1
                if rejectedFramesWithoutValidFrame >= Self.maxRejectedFramesBeforeFirstFrame {
                    giveUpOrReconnectAfterWrongDevice()
                }
            }
            return
        }

        validFrameOnThisLink = true
        let now = Date()
        state.lastFrameDate = now
        if state.observedProtocol02 == false && MQResetCommand.isProtocol02Marker(frame) {
            state.observedProtocol02 = true
            logLine("in handleNotification, Protocol02 confirmed by the session marker, the captured reset command will be used")
        }
        persistState()

        // the link shows life: the first-frame watchdog is done and the silence watchdog restarts
        firstFrameToken += 1
        armProtocolFrameWatchdog()

        let commandText = String(format: "0x%02X", UInt32(frame.cmd))
        logLine("in handleNotification, frame cmd=\(commandText) len=\(frame.len) crcValid=\(frame.crcValid)", type: .debug)

        switch frame.cmd {
        case MQConstants.cmdNotifyBeginWork:
            onBeginWork()
        case MQConstants.cmdNotifyWorking:
            onHeartbeat()
        case MQConstants.cmdNotifyBgData:
            onBgData(frame)
        case MQConstants.cmdNotifyBgComplete:
            flushBurst(reason: "bg-complete")
        default:
            logLine("in handleNotification, unhandled command \(commandText)", type: .debug)
        }
    }

    // MARK: - frame handlers

    /// JugglucoNG `onBeginWork`: the transmitter says it just started work (a reset, a new sensor, or a
    /// fresh link in a loop). The acknowledgement is the captured `withInit` frame; a transmitter that
    /// keeps repeating BEGIN_WORK is reconnected.
    private func onBeginWork() {
        let superseded = state.tracker.noteBeginWork(nowMs: nowMs())
        if superseded {
            logLine("in onBeginWork, BEGIN_WORK supersedes the running session")
            burst.clear()
            burstFlushToken += 1
            // the next data announces the new session to xDrip
            state.announcedStartAtMs = 0
        }
        persistState()

        beginWorkRetryCount += 1
        if beginWorkRetryCount > Self.maxBeginWorkRetries {
            logLine("in onBeginWork, BEGIN_WORK looped \(beginWorkRetryCount) times, reconnecting", type: .error)
            beginWorkRetryCount = 0
            noteProblem(.beginWorkLoop)
            disconnect()
            return
        }

        logLine("in onBeginWork, acknowledgement #\(beginWorkRetryCount)")
        writeFrame(MQAckFrames.withInit, tag: "beginWorkAck")
    }

    /// JugglucoNG `onHeartbeat`.
    private func onHeartbeat() {
        beginWorkRetryCount = 0
        flushBurst(reason: "heartbeat")
        armNoDataWatchdog()
        writeFrame(MQAckFrames.withoutInit, tag: "confirmWithoutInit")
    }

    /// JugglucoNG `onBgData`: records are acknowledged at once and processed together shortly after, so
    /// a replay of several frames becomes one burst in packet order.
    private func onBgData(_ frame: MQFrame) {
        beginWorkRetryCount = 0
        let records = MQParser.parseBgRecords(frame)
        if records.isEmpty {
            writeFrame(MQAckFrames.bgData, tag: "confirmBgData(empty)")
            return
        }

        let now = nowMs()
        let newestPacket = records.filter { $0.marker == MQConstants.bgRecordMarker }.map { $0.packetIndex }.max()
        if state.tracker.reconcileStart(newestPacket: newestPacket, nowMs: now, intervalMinutes: MQProfile.default.readingIntervalMinutes) {
            logLine("in onBgData, the session start was estimated from the running packet counter (packet \(newestPacket ?? -1)), not from the connection time")
            persistState()
        }

        burst.add(records, receivedAtMs: now)
        scheduleBurstFlush()
        writeFrame(MQAckFrames.bgData, tag: "confirmBgData")
    }

    // MARK: - burst processing

    private func scheduleBurstFlush() {
        burstFlushToken += 1
        let token = burstFlushToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.burstFlushDelay) { [weak self] in
            guard let self = self, !self.released,
                  self.connectionGeneration == generation, self.burstFlushToken == token else { return }
            self.flushBurst(reason: "timeout")
        }
    }

    /// JugglucoNG `flushPendingBgBurst` and `processBgRecords`.
    private func flushBurst(reason: String) {
        burstFlushToken += 1
        guard let flushed = burst.flush() else { return }
        loadStateIfNeeded()

        let parameters = currentParameters()
        logLine("in flushBurst (\(reason)), records \(flushed.records.count), packet \(flushed.records.first?.packetIndex ?? -1)...\(flushed.anchorPacketIndex)")

        let previousLast = state.tracker.lastPacketIndex
        if let firstNew = flushed.records.first(where: { $0.packetIndex > previousLast })?.packetIndex,
           previousLast >= 0, firstNew > previousLast + 1 {
            logLine("in flushBurst, replay gap: last \(previousLast), first received \(firstNew); the missing records were not in this burst", type: .error)
        }

        let readings = state.tracker.processBurst(
            flushed.records,
            anchorPacketIndex: flushed.anchorPacketIndex,
            anchorMs: flushed.anchorMs,
            intervalMs: MQProfile.default.readingIntervalMs,
            parameters: parameters
        )
        if readings.isEmpty && !flushed.records.isEmpty {
            logLine("in flushBurst, no value: slope \(state.tracker.hasSlope ? "held" : "not held"), sensitivity seed \(parameters.sensitivitySeed > 0 ? "set" : "not set"); a fingerstick or a sensitivity is needed")
        }
        deliver(readings)
        armNoDataWatchdog()
    }

    // MARK: - delivery to xDrip

    /// Tells xDrip about the session (once per new session, even before the first value, so the
    /// calibration button has a sensor to work on) and hands over the readings. Runs on the central
    /// queue; xDrip is called on main.
    private func deliver(_ readings: [MQReading]) {
        let startMs = state.tracker.sensorStartAtMs
        var newSensorStart: Date?
        if startMs > 0 {
            let announced = state.announcedStartAtMs
            if announced == 0 || abs(startMs - announced) > Self.newSessionTolerance {
                newSensorStart = Date(timeIntervalSince1970: Double(startMs) / 1000)
                state.announcedStartAtMs = startMs
            }
        }

        let now = Date()
        var glucoseData = [GlucoseData]()
        var sensorAge: TimeInterval?
        if let newest = readings.max(by: { $0.sampleMs < $1.sampleMs }) {
            let newestDate = Date(timeIntervalSince1970: Double(newest.sampleMs) / 1000)
            if startMs > 0 {
                sensorAge = max(0, Double(newest.sampleMs - startMs) / 1000)
            }
            state.lastReadingDate = newestDate
            state.lastReadingMgdlTimes10 = newest.result.mgdlTimes10
            state.problem = nil
            state.problemDate = nil

            for reading in readings.sorted(by: { $0.sampleMs > $1.sampleMs }) {
                let isNewest = reading.sampleMs == newest.sampleMs
                glucoseData.append(GlucoseData(
                    timeStamp: Date(timeIntervalSince1970: Double(reading.sampleMs) / 1000),
                    glucoseLevelRaw: Double(reading.result.mgdlTimes10) / 10.0,
                    backfilledAt: isNewest ? nil : now
                ))
            }
        }
        persistState()

        guard newSensorStart != nil || !glucoseData.isEmpty else { return }

        let announcedStart = newSensorStart
        let deliveredData = glucoseData
        let deliveredAge = sensorAge
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let delegate = self.cgmTransmitterDelegate else { return }
            if let announcedStart = announcedStart {
                delegate.newSensorDetected(sensorStartDate: announcedStart)
            }
            if !deliveredData.isEmpty {
                var data = deliveredData
                delegate.cgmTransmitterInfoReceived(glucoseData: &data, transmitterBatteryInfo: nil, sensorAge: deliveredAge)
            }
        }
    }

    // MARK: - writes

    /// JugglucoNG `writeFrame`: the best write type the characteristic offers, one retry when the
    /// first write is refused.
    @discardableResult
    private func writeFrame(_ bytes: [UInt8], tag: String) -> Bool {
        guard let rx = rxCharacteristic else {
            logLine("in writeFrame, \(tag) not sent: no receive characteristic", type: .error)
            return false
        }
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let data = Data(bytes)
        if writeDataToPeripheral(data: data, characteristicToWriteTo: rx, type: type) {
            return true
        }
        logLine("in writeFrame, \(tag) was refused, trying once more", type: .error)
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.writeRetryDelay) { [weak self] in
            guard let self = self, self.connectionGeneration == generation, let rx = self.rxCharacteristic else { return }
            if !self.writeDataToPeripheral(data: data, characteristicToWriteTo: rx, type: type) {
                self.noteProblem(.writeFailed)
            }
        }
        return false
    }

    // MARK: - watchdogs

    private func armFirstFrameWatchdog() {
        firstFrameToken += 1
        let token = firstFrameToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.firstFrameTimeout) { [weak self] in
            guard let self = self, !self.released, self.streaming,
                  self.connectionGeneration == generation, self.firstFrameToken == token else { return }
            self.logLine("in firstFrameWatchdog, connected but no frame arrived, reconnecting", type: .error)
            self.noteProblem(.noFramesAfterConnect)
            self.disconnect()
        }
    }

    private func armProtocolFrameWatchdog() {
        protocolFrameToken += 1
        let token = protocolFrameToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.protocolFrameTimeout) { [weak self] in
            guard let self = self, !self.released, self.streaming,
                  self.connectionGeneration == generation, self.protocolFrameToken == token else { return }
            self.logLine("in protocolFrameWatchdog, the link has been silent for \(Int(Self.protocolFrameTimeout)) s, reconnecting", type: .error)
            self.noteProblem(.linkSilent)
            self.disconnect()
        }
    }

    /// Armed only once a value exists: a transmitter that is waiting for a fingerstick sends frames but
    /// produces no glucose, and reconnecting would not help.
    private func armNoDataWatchdog() {
        noDataToken += 1
        guard state.tracker.lastGlucoseAtMs > 0 else { return }
        let token = noDataToken
        let generation = connectionGeneration
        runOnCentralQueue(after: Self.noDataTimeout) { [weak self] in
            guard let self = self, !self.released, self.streaming,
                  self.connectionGeneration == generation, self.noDataToken == token else { return }
            self.logLine("in noDataWatchdog, no glucose for \(Int(Self.noDataTimeout)) s, reconnecting", type: .error)
            self.noteProblem(.noGlucose)
            self.disconnect()
        }
    }

    // MARK: - fingerstick

    /// xDrip's calibration button ends here (the calibrator creates the calibration, `bg` is mg/dL).
    /// The value becomes the reference for the latest packet and solves the slope at once, as
    /// JugglucoNG's `calibrateSensor` does.
    func calibrate(calibration: Calibration) {
        let mgdl = calibration.bg
        runOnCentralQueue { [weak self] in
            self?.applyFingerstick(mgdl: mgdl)
        }
    }

    private func applyFingerstick(mgdl: Double) {
        loadStateIfNeeded()
        let value = mqKotlinRound(mgdl)
        guard MQCalibrationInput.isPlausible(mgdl: value) else {
            logLine("in applyFingerstick, \(value) mg/dL is outside \(MQCalibrationInput.minimumMgDl) to \(MQCalibrationInput.maximumMgDl) and is ignored", type: .error)
            return
        }
        let parameters = currentParameters()
        let outcome = state.tracker.calibrate(
            glucoseMgDl: value,
            nowMs: nowMs(),
            frameTimeoutMs: Int64(Self.protocolFrameTimeout * 1000),
            parameters: parameters
        )
        persistState()
        switch outcome {
        case .rejected:
            logLine("in applyFingerstick, the value was rejected", type: .error)
        case .queued:
            logLine("in applyFingerstick, \(value) mg/dL kept for the next packet (no recent packet above packet 8)")
        case .noResult:
            logLine("in applyFingerstick, the latest packet gave no value with \(value) mg/dL", type: .error)
        case .applied(let reading):
            logLine("in applyFingerstick, \(value) mg/dL applied to packet \(reading.record.packetIndex), slope solved")
            deliver([reading])
            armNoDataWatchdog()
        }
    }

    // MARK: - reset

    /// JugglucoNG `resetSensor`: the transmitter is told to reset, the local session is forgotten and
    /// the link is dropped a moment later so the transmitter starts clean. `completion` runs on main
    /// with whether the command was written.
    func resetSensor(completion: @escaping (Bool) -> Void) {
        runOnCentralQueue { [weak self] in
            let sent = self?.performReset() ?? false
            DispatchQueue.main.async { completion(sent) }
        }
    }

    private func performReset() -> Bool {
        loadStateIfNeeded()
        guard streaming else {
            logLine("in performReset, not connected to the transmitter", type: .error)
            return false
        }
        let frame = MQResetCommand.build(protocolType: MQConstants.defaultProtocolType, observedProtocol02: state.observedProtocol02)
        guard writeFrame(frame, tag: "confirmReset") else { return false }

        burst.clear()
        burstFlushToken += 1
        noDataToken += 1
        state.tracker.clearSession()
        state.announcedStartAtMs = 0
        state.lastReadingDate = nil
        state.lastReadingMgdlTimes10 = nil
        state.lastResetDate = Date()
        persistState()
        logLine("in performReset, reset sent, the session was cleared")

        let generation = connectionGeneration
        runOnCentralQueue(after: Self.resetReconnectDelay) { [weak self] in
            guard let self = self, !self.released, self.connectionGeneration == generation else { return }
            self.disconnect()
        }
        return true
    }

    // MARK: - CGMTransmitter

    func cgmTransmitterType() -> CGMTransmitterType {
        return .mq
    }

    /// The vendor's rated life, which JugglucoNG also uses for the expected end.
    func maxSensorAgeInDays() -> Double? {
        return Double(MQProfile.default.ratedLifetimeDays)
    }

    /// JugglucoNG's profile has a warm-up, but the vendor algorithm already withholds values by itself
    /// (see `MQAlgorithm`); an xDrip warm-up on top would only hide a new sensor's first readings.
    func sensorWarmupDurationInMinutes() -> Double? { 0 }

    func needsSensorStartTime() -> Bool { false }

    /// Values are mg/dL from the driver's port of the transmitter algorithm, so xDrip uses no calibrator.
    func isWebOOPEnabled() -> Bool { true }

    /// A fingerstick is still accepted: it is the reference of the algorithm (`calibrate(calibration:)`).
    func overruleIsWebOOPEnabled() -> Bool { true }

    func nonWebOOPAllowed() -> Bool { false }

    func getCBUUID_Service() -> String { return MQConstants.serviceUUID.uuidString }

    func getCBUUID_Receive() -> String { return MQConstants.txNotifyUUID.uuidString }
}
