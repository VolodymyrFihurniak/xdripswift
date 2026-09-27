import Foundation
import CoreBluetooth
import os

class CGMSibionics2Transmitter: BluetoothTransmitter, CGMTransmitter {

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?
    private let codec = Sibionics2ProtocolCodec()
    private let stateStore = Sibionics2ReadingStateStore()
    private var discoveredPeripherals = [String: CBPeripheral]()
    private var discoveredPeripheralNames = [String: String]()
    private var batchProcessor: Sibionics2ReadingBatchProcessor?
    private var handshake: Sibionics2Handshake?
    private var advertisedName: String?
    private var characteristicWriteType: CBCharacteristicWriteType?
    private var streamingReady = false
    private var receivedNonEmptyReadingsPacket = false
    private var notificationEnabled = false
    private var handshakeAttempt = 0
    private var handshakeReconnectCount = 0
    private var historyRequest = Sibionics2HistoryRequestTracker()
    private var historyRecoveryToken = 0
    private var historyWriteFailures = 0
    private var historyRetryScheduled = false
    private var historyReconnectCount = 0
    private let transmitterLog = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryBluetoothPeripheralManager)

    init(
        address: String?,
        name: String?,
        bluetoothTransmitterDelegate: BluetoothTransmitterDelegate,
        cGMTransmitterDelegate: CGMTransmitterDelegate
    ) {
        let addressAndName: BluetoothTransmitter.DeviceAddressAndName
        if let address {
            addressAndName = .alreadyConnectedBefore(address: address, name: name)
        } else {
            addressAndName = .notYetConnected(expectedName: nil)
        }
        self.cgmTransmitterDelegate = cGMTransmitterDelegate
        self.advertisedName = name
        super.init(
            addressAndName: addressAndName,
            // Use service UUID for advertisement filtering to enable background scanning
            // and auto-discovery like JugglucoNG (scan for devices with FF30 service)
            CBUUID_Advertisement: Sibionics2ProtocolCodec.serviceUUID.uuidString,
            servicesCBUUIDs: [Sibionics2ProtocolCodec.serviceUUID],
            CBUUID_ReceiveCharacteristic: Sibionics2ProtocolCodec.notifyUUID.uuidString,
            CBUUID_WriteCharacteristic: Sibionics2ProtocolCodec.writeUUID.uuidString,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    static func canAdoptPeripheral(
        advertisedName: String?,
        storedAddress: String?,
        peripheralAddress: String
    ) -> Bool {
        if let storedAddress, !storedAddress.isEmpty {
            return storedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(peripheralAddress.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        return Sibionics2DeviceIdentity.isSibionics2(name: advertisedName)
    }

    override func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard Self.canAdoptPeripheral(
            advertisedName: name,
            storedAddress: deviceAddress,
            peripheralAddress: peripheral.identifier.uuidString
        ) else { return }

        guard deviceAddress == nil else {
            super.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
            return
        }

        guard let name else { return }
        let identifier = peripheral.identifier.uuidString
        discoveredPeripherals[identifier] = peripheral
        discoveredPeripheralNames[identifier] = name
        trace("Sibionics 2 candidate found: name=%{public}@ rssi=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: .info, name, RSSI.intValue.description)
        bluetoothTransmitterDelegate?.didDiscoverBluetoothPeripheral(
            BluetoothPeripheralScanResult(identifier: identifier, name: name, rssi: RSSI.intValue),
            bluetoothTransmitter: self
        )
    }

    func selectDiscoveredPeripheral(identifier: String) {
        runOnCentralQueue { [weak self] in
            guard let self,
                  self.deviceAddress == nil,
                  let peripheral = self.discoveredPeripherals[identifier] else { return }
            self.advertisedName = self.discoveredPeripheralNames[identifier]
            self.discoveredPeripherals.removeAll()
            self.discoveredPeripheralNames.removeAll()
            self.connectToDiscoveredPeripheral(peripheral)
        }
    }

    static func writeType(for properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        if properties.contains(.writeWithoutResponse) { return .withoutResponse }
        if properties.contains(.write) { return .withResponse }
        return nil
    }

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        guard error == nil, service.uuid == Sibionics2ProtocolCodec.serviceUUID else { return }
        characteristicWriteType = service.characteristics?
            .first(where: { $0.uuid == Sibionics2ProtocolCodec.writeUUID })
            .flatMap { Self.writeType(for: $0.properties) }
        trace("Sibionics 2 FF32 write type: %{public}@", log: transmitterLog,
              category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: characteristicWriteType == nil ? .error : .info,
              characteristicWriteType == .withoutResponse ? "withoutResponse"
                  : characteristicWriteType == .withResponse ? "withResponse" : "unsupported")
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handshakeAttempt += 1
        handshake = nil
        streamingReady = false
        receivedNonEmptyReadingsPacket = false
        notificationEnabled = false
        characteristicWriteType = nil
        historyRequest.reset()
        historyRecoveryToken += 1
        historyRetryScheduled = false
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
        guard error == nil,
              characteristic.uuid == Sibionics2ProtocolCodec.notifyUUID,
              characteristic.isNotifying else { return }
        notificationEnabled = true
        startHandshake()
    }

    override func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
        guard characteristic.uuid == Sibionics2ProtocolCodec.notifyUUID else { return }
        guard error == nil, let value = characteristic.value else {
            trace("Sibionics 2 FF31 notification failed: %{public}@", log: transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error,
                  error?.localizedDescription ?? "missing value")
            return
        }

        switch codec.parseV120(value) {
        case .malformed:
            trace("Sibionics 2 rejected V120 notification of %{public}@ bytes", log: transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error,
                  value.count.description)
        case .handshake(let response):
            receiveHandshake(response, at: Date())
        case .readings(let readings):
            guard let first = readings.first, let last = readings.last else {
                trace("Sibionics 2 FF31 data packet contained no glucose readings", log: transmitterLog,
                      category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
                return
            }
            receivedNonEmptyReadingsPacket = true
            guard var handshake, handshake.receiveReadings() else {
                trace("Sibionics 2 readings before authentication", log: transmitterLog,
                      category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
                return
            }
            self.handshake = handshake
            if !streamingReady {
                streamingReady = true
                handshakeReconnectCount = 0
                trace("Sibionics 2 streaming started with first data packet (ready ACK optional)",
                      log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            }
            trace("Sibionics 2 FF31 readings=%{public}@ firstIndex=%{public}@ lastIndex=%{public}@",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info,
                  readings.count.description, first.index.description, last.index.description)
            receiveReadings(readings, at: Date())
        }
    }

    override func prepareForRelease() {
        runOnCentralQueue {
            self.handshake = nil
            self.batchProcessor = nil
            self.streamingReady = false
            self.notificationEnabled = false
            self.characteristicWriteType = nil
            self.historyRequest.reset()
            self.historyRecoveryToken += 1
            self.handshakeAttempt += 1
        }
        super.prepareForRelease()
    }

    /// Rebuilds state after the per-device factory sensitivity changes. The
    /// snapshot contains its sensitivity, so the batch processor will reject the
    /// old snapshot and request history from the sensor before publishing again.
    func factorySensitivityDidChange(for address: String) {
        runOnCentralQueue { [weak self] in
            guard let self,
                  let currentAddress = self.deviceAddress,
                  currentAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else { return }

            self.stateStore.clear(for: address)
            self.batchProcessor = nil
            self.historyRequest.reset()
            self.historyRecoveryToken += 1
            self.historyRetryScheduled = false
            self.historyWriteFailures = 0
            trace("Sibionics 2 factory sensitivity changed; restarting processor from saved sensor history",
                  log: self.transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            self.requestNewReading()
        }
    }

    func setNonFixedSlopeEnabled(enabled: Bool) {}
    func isNonFixedSlopeEnabled() -> Bool { false }
    func setWebOOPEnabled(enabled: Bool) {}
    func isWebOOPEnabled() -> Bool { true }
    func overruleIsWebOOPEnabled() -> Bool { false }
    func nonWebOOPAllowed() -> Bool { false }
    func isAnubisG6() -> Bool { false }
    func cgmTransmitterType() -> CGMTransmitterType { .sibionics2 }
    func requestNewReading() {
        runOnCentralQueue { [weak self] in
            guard let self,
                  self.streamingReady,
                  let address = self.deviceAddress else { return }
            _ = self.sendDataRequest(for: address)
        }
    }
    func maxSensorAgeInDays() -> Double? { nil }
    func startSensor(sensorCode: String?, startDate: Date) {}
    func stopSensor(stopDate: Date) {}
    func calibrate(calibration: Calibration) {}
    func transmitterCalibrationStatus() -> CGMTransmitterCalibrationStatus? { nil }
    func needsSensorStartTime() -> Bool { false }
    func needsSensorStartCode() -> Bool { false }
    func shouldWarnOnLargeCalibrationStep() -> Bool { false }
    func getCBUUID_Service() -> String { Sibionics2ProtocolCodec.serviceUUID.uuidString }
    func getCBUUID_Receive() -> String { Sibionics2ProtocolCodec.notifyUUID.uuidString }

    private func startHandshake() {
        guard let address = deviceAddress, let sessionKey = codec.deriveSessionKey() else {
            trace("could not initialize Sibionics 2 authentication", log: transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            return
        }
        batchProcessor = makeBatchProcessor(for: address)

        streamingReady = false
        receivedNonEmptyReadingsPacket = false
        historyRequest.reset()
        historyRecoveryToken += 1
        historyRetryScheduled = false
        historyWriteFailures = 0
        handshakeAttempt += 1
        let attempt = handshakeAttempt
        var newHandshake = Sibionics2Handshake(
            macAddress: [UInt8](repeating: 0, count: 6),
            sessionKey: sessionKey,
            lastDeliveredIndex: batchProcessor?.state?.lastDeliveredIndex
        )
        let command = newHandshake.start(at: Date())
        guard !command.isEmpty else { return }
        handshake = newHandshake
        _ = writeCommand(command, label: "auth")
        runOnCentralQueue(after: 75) { [weak self] in
            guard let self, self.handshakeAttempt == attempt else { return }
            if self.streamingReady {
                guard !self.receivedNonEmptyReadingsPacket else { return }
                trace("Sibionics 2 received streaming-ready but no glucose readings after 75 seconds",
                      log: self.transmitterLog,
                      category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
                return
            }
            trace("Sibionics 2 handshake stalled: FF31 has not begun streaming",
                  log: self.transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            if self.notificationEnabled && self.handshakeReconnectCount < 2 {
                self.handshakeReconnectCount += 1
                self.disconnect()
            }
        }
    }

    private func makeBatchProcessor(for address: String) -> Sibionics2ReadingBatchProcessor {
        if let batchProcessor,
           batchProcessor.state != nil || stateStore.load(for: address) == nil {
            return batchProcessor
        }
        let override = Sibionics2FactorySensitivity.override(for: address)
        let sensitivity = Sibionics2FactorySensitivity.effectiveSensitivity(
            for: address,
            advertisedName: advertisedName
        )
        trace("Sibionics 2 sensitivity=%{public}@ source=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: .info, sensitivity.description, override == nil ? "automatic" : "peripheral override")
        return Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: sensitivity)
        )
    }

    @discardableResult
    private func sendDataRequest(for address: String) -> Bool {
        guard streamingReady else { return false }
        let cursor = stateStore.load(for: address)?.lastDeliveredIndex ?? 0
        return writeCommand(codec.buildDataRequestPacket(lastIndex: cursor),
                            label: "data-request index=\(cursor)")
    }

    @discardableResult
    private func writeCommand(_ command: Data, label: String) -> Bool {
        guard let type = characteristicWriteType else {
            trace("Sibionics 2 FF32 cannot send %{public}@: missing supported write property",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
                  type: .error, label)
            return false
        }
        let sent = writeDataToPeripheral(data: command, type: type)
        trace("Sibionics 2 FF32 %{public}@ queued=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: sent ? .info : .error, label, sent.description)
        return sent
    }

    private func receiveHandshake(_ response: Sibionics2HandshakeResponse, at date: Date) {
        guard var handshake else {
            trace("Sibionics 2 FF31 unexpected handshake response=%{public}@",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
                  type: .error, response.rawValue.description)
            return
        }
        let wasStreaming = handshake.isStreaming
        let nextCommand = handshake.receive(response, at: date)
        self.handshake = handshake
        trace("Sibionics 2 FF31 response=%{public}@ nextCommand=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: .info, response.rawValue.description, (nextCommand != nil).description)
        if let nextCommand {
            let label: String
            switch response {
            case .authenticationAccepted: label = "activation"
            case .timeSyncNeeded: label = "time-sync"
            case .dataRequested: label = "data-request"
            case .streamingReady: label = "unexpected"
            }
            _ = writeCommand(nextCommand, label: label)
        } else if !wasStreaming && handshake.isStreaming {
            streamingReady = true
            handshakeReconnectCount = 0
            trace("Sibionics 2 received streaming-ready ACK; waiting for glucose readings",
                  log: transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
        }
    }

    /// A requested page may require another BLE session. Retry a failed write
    /// briefly, then perform at most two connection resets if no missing page
    /// arrives. The saved cursor always remains on the last contiguous minute.
    private func requestMissingHistory(for sessionStart: Date, address: String) {
        let cursor = stateStore.load(for: address)?.lastDeliveredIndex ?? 0
        guard historyRequest.needsRequest(for: sessionStart, cursor: cursor) else { return }

        if sendDataRequest(for: address) {
            historyRequest.record(for: sessionStart, cursor: cursor, queued: true)
            historyWriteFailures = 0
            historyRetryScheduled = false
            historyRecoveryToken += 1
            let token = historyRecoveryToken
            runOnCentralQueue(after: 90) { [weak self] in
                guard let self, self.historyRecoveryToken == token,
                      !self.historyRequest.needsRequest(for: sessionStart, cursor: cursor),
                      self.batchProcessor?.requiresHistoryReplay == true else { return }
                self.reconnectForMissingHistory()
            }
        } else {
            historyWriteFailures += 1
            if historyWriteFailures >= 3 {
                reconnectForMissingHistory()
            } else if !historyRetryScheduled {
                historyRetryScheduled = true
                let token = historyRecoveryToken
                runOnCentralQueue(after: 3) { [weak self] in
                    guard let self, self.historyRecoveryToken == token else { return }
                    self.historyRetryScheduled = false
                    guard self.batchProcessor?.requiresHistoryReplay == true,
                          self.batchProcessor?.state?.sensorStartDate == sessionStart else { return }
                    self.requestMissingHistory(for: sessionStart, address: address)
                }
            }
        }
    }

    private func reconnectForMissingHistory() {
        guard historyReconnectCount < 2, getConnectionStatus() == .connected else {
            trace("Sibionics 2 history page still missing; saved cursor retained",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
                  type: .error)
            return
        }
        historyReconnectCount += 1
        historyRecoveryToken += 1
        trace("Sibionics 2 reconnecting for missing history page",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: .info)
        disconnect()
    }

    private func receiveReadings(_ readings: [Sibionics2RawReading], at receivedAt: Date) {
        guard let address = deviceAddress else { return }
        var currentProcessor = batchProcessor ?? makeBatchProcessor(for: address)
        let previousStartDate = currentProcessor.state?.sensorStartDate
        let glucoseData = currentProcessor.process(readings, receivedAt: receivedAt)
        let requiresHistoryReplay = currentProcessor.requiresHistoryReplay
        let currentState = currentProcessor.state
        batchProcessor = currentProcessor

        if requiresHistoryReplay, let sessionStart = currentState?.sensorStartDate {
            trace("Sibionics 2 waiting for missing history from saved cursor",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
                  type: .info)
            requestMissingHistory(for: sessionStart, address: address)
        } else if !requiresHistoryReplay {
            historyRequest.reset()
            historyRecoveryToken += 1
            historyRetryScheduled = false
            historyReconnectCount = 0
        }

        trace("Sibionics 2 processor input=%{public}@ delivered=%{public}@ cursor=%{public}@ replay=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info,
              readings.count.description, glucoseData.count.description,
              currentState?.lastDeliveredIndex.map { String($0) } ?? "waiting",
              requiresHistoryReplay.description)
        guard !(requiresHistoryReplay && currentState?.lastDeliveredIndex == nil),
              let sensorStartDate = currentState?.sensorStartDate else { return }
        let detectedNewSensor = previousStartDate.map {
            abs($0.timeIntervalSince(sensorStartDate)) > 10 * 60
        } ?? true
        let sensorAge = max(0, receivedAt.timeIntervalSince(sensorStartDate))
        guard detectedNewSensor || !glucoseData.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.cgmTransmitterDelegate else { return }
            Sibionics2DelegateDelivery.deliver(
                glucoseData,
                detectedNewSensor: detectedNewSensor,
                sensorStartDate: sensorStartDate,
                sensorAge: sensorAge,
                to: delegate
            )
        }
    }
}


enum Sibionics2DelegateDelivery {
    static func deliver(
        _ glucoseData: [GlucoseData],
        detectedNewSensor: Bool,
        sensorStartDate: Date?,
        sensorAge: TimeInterval?,
        to delegate: CGMTransmitterDelegate
    ) {
        if detectedNewSensor {
            delegate.newSensorDetected(sensorStartDate: sensorStartDate)
        }

        let validGlucoseData = glucoseData.filter { reading in
            reading.timeStamp.timeIntervalSince1970.isFinite &&
                reading.glucoseLevelRaw.isFinite &&
                reading.glucoseLevelRaw > 0 && reading.glucoseLevelRaw <= 900
        }
        guard !validGlucoseData.isEmpty else { return }

        var mutableGlucoseData = validGlucoseData
        delegate.cgmTransmitterInfoReceived(
            glucoseData: &mutableGlucoseData,
            transmitterBatteryInfo: nil,
            sensorAge: sensorAge
        )
    }
}
