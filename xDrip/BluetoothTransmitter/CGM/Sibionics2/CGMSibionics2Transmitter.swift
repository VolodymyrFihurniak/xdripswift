import Foundation
import CoreBluetooth
import os

class CGMSibionics2Transmitter: BluetoothTransmitter, CGMTransmitter {

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?
    private let codec = Sibionics2ProtocolCodec()
    private let stateStore = Sibionics2ReadingStateStore()
    private var batchProcessor: Sibionics2ReadingBatchProcessor?
    private var handshake: Sibionics2Handshake?
    private var handshakeResponseCount = 0
    private var streamingReady = false
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
        super.init(
            addressAndName: addressAndName,
            CBUUID_Advertisement: nil,
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
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard Self.canAdoptPeripheral(
            advertisedName: advertisedName,
            storedAddress: deviceAddress,
            peripheralAddress: peripheral.identifier.uuidString
        ) else { return }
        super.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
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
        startHandshake()
    }

    override func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
        guard error == nil,
              characteristic.uuid == Sibionics2ProtocolCodec.notifyUUID,
              let value = characteristic.value else { return }

        switch codec.parseV120(value) {
        case .malformed:
            trace("ignored malformed Sibionics 2 V120 notification", log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
        case .handshake(let response):
            receiveHandshake(response, at: Date())
        case .readings(let readings):
            guard streamingReady else {
                trace("ignored readings before Sibionics 2 handshake completed", log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
                return
            }
            receiveReadings(readings, at: Date())
        }
    }

    override func prepareForRelease() {
        runOnCentralQueue {
            self.handshake = nil
            self.batchProcessor = nil
            self.streamingReady = false
            self.handshakeResponseCount = 0
        }
        super.prepareForRelease()
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
            let lastIndex = self.stateStore.load(for: address)?.lastDeliveredIndex ?? 0
            _ = self.writeDataToPeripheral(
                data: self.codec.buildDataRequestPacket(lastIndex: lastIndex),
                type: .withResponse
            )
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
        guard let address = deviceAddress, let sessionKey = codec.deriveSessionKey(),
              let batchProcessor = makeBatchProcessor(for: address) else {
            trace("could not initialize Sibionics 2 handshake or persisted state", log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            return
        }
        self.batchProcessor = batchProcessor
        streamingReady = false
        handshakeResponseCount = 0
        var newHandshake = Sibionics2Handshake(
            macAddress: [UInt8](repeating: 0, count: 6),
            sessionKey: sessionKey,
            lastDeliveredIndex: batchProcessor.state?.lastDeliveredIndex
        )
        let command = newHandshake.start(at: Date())
        guard !command.isEmpty else { return }
        handshake = newHandshake
        _ = writeDataToPeripheral(data: command, type: .withResponse)
    }

    private func makeBatchProcessor(for address: String) -> Sibionics2ReadingBatchProcessor? {
        if let batchProcessor,
           batchProcessor.state != nil || stateStore.load(for: address) == nil {
            return batchProcessor
        }
        return Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(
                sensitivity: Sibionics2FactorySensitivity.resolve(probeCode: nil, shortCode: nil)
            )
        )
    }

    private func receiveHandshake(_ response: Sibionics2HandshakeResponse, at date: Date) {
        let expectedResponseCount: Int
        switch response {
        case .authenticationAccepted: expectedResponseCount = 0
        case .timeSyncNeeded: expectedResponseCount = 1
        case .dataRequested: expectedResponseCount = 2
        case .streamingReady: expectedResponseCount = 3
        }
        guard handshakeResponseCount == expectedResponseCount,
              var handshake else { return }

        let nextCommand = handshake.receive(response, at: date)
        self.handshake = handshake
        if let nextCommand {
            handshakeResponseCount += 1
            _ = writeDataToPeripheral(data: nextCommand, type: .withResponse)
        } else if response == .streamingReady {
            handshakeResponseCount += 1
            streamingReady = true
        }
    }

    private func receiveReadings(_ readings: [Sibionics2RawReading], at receivedAt: Date) {
        guard let address = deviceAddress else { return }
        if batchProcessor == nil {
            batchProcessor = makeBatchProcessor(for: address)
        }
        guard var batchProcessor else { return }

        let previousStartDate = batchProcessor.state?.sensorStartDate
        let glucoseData = batchProcessor.process(readings, receivedAt: receivedAt)
        let requiresHistoryReplay = batchProcessor.requiresHistoryReplay
        let currentState = batchProcessor.state
        self.batchProcessor = batchProcessor

        if requiresHistoryReplay {
            requestNewReading()
        }

        guard let sensorStartDate = currentState?.sensorStartDate else { return }
        let detectedNewSensor = previousStartDate.map {
            abs($0.timeIntervalSince(sensorStartDate)) > 10 * 60
        } ?? true
        let sensorAge = max(0, receivedAt.timeIntervalSince(sensorStartDate))
        guard detectedNewSensor || !glucoseData.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.cgmTransmitterDelegate else { return }
            if detectedNewSensor {
                delegate.newSensorDetected(sensorStartDate: sensorStartDate)
            }
            guard !glucoseData.isEmpty else { return }
            var mutableGlucoseData = glucoseData
            delegate.cgmTransmitterInfoReceived(
                glucoseData: &mutableGlucoseData,
                transmitterBatteryInfo: nil,
                sensorAge: sensorAge
            )
        }
    }
}
