import Foundation
import CoreBluetooth
import os

class CGMSibionics2Transmitter: BluetoothTransmitter, CGMTransmitter {

    let variant: SibionicsDeviceVariant
    private let chineseCodec = Sibionics1ChineseProtocolCodec()
    private var sibionics1Connection: Sibionics1ConnectionState?
    private var probeGeneration = 0
    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?
    private let codec = Sibionics2ProtocolCodec()
    private let stateStore = Sibionics2ReadingStateStore()
    private var discoveredPeripherals = [String: CBPeripheral]()
    private var discoveredPeripheralNames = [String: String]()
    private var batchProcessor: Sibionics2ReadingBatchProcessor?
    private var probeReplaySessionStartDate: Date?
    private var handshake: Sibionics2Handshake?
    private var advertisedName: String?
    private var characteristicWriteType: CBCharacteristicWriteType?
    private var streamingReady = false
    private var receivedNonEmptyReadingsPacket = false
    private var notificationEnabled = false
    private var handshakeAttempt = 0
    private var handshakeReconnectCount = 0
    private var authenticationKeyGroupIndex = 0
    private var handshakeStepGeneration = 0
    private var handshakeRestartCount = 0
    /// Rotates through unverified authentication addresses, one per connection.
    private var addressCandidateIndex = 0
    private var authenticationAddressInUse: String?
    private var authenticationAddressAwaitingReadings = false
    private var authenticationAddressSelected = false
    /// Authentication waits for Device Information, which carries the BLE address.
    private var pendingDeviceInformationReads = 0
    private var sessionStartDeferred = false
    private var deviceInformationGeneration = 0
    private var historyRequest = Sibionics2HistoryRequestTracker()
    private var historyRecoveryToken = 0
    private var historyWriteFailures = 0
    private var historyRetryScheduled = false
    private var historyReconnectCount = 0
    /// Chinese Sibionics 1 firmware answers requests but does not push, so it is
    /// asked once a minute as JugglucoNG does. V120 sensors stream without polling.
    private var readingPollGeneration = 0
    private var streamingWatchdogGeneration = 0
    private var batteryLevelCharacteristic: CBCharacteristic?
    private var lastBatteryReadAt: Date?
    private var autoResetCheckGeneration = 0
    private var resetDisconnectGeneration = 0
    private let transmitterLog = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryBluetoothPeripheralManager)

    init(
        address: String?,
        name: String?,
        variant: SibionicsDeviceVariant = .sibionics2,
        bluetoothTransmitterDelegate: BluetoothTransmitterDelegate,
        cGMTransmitterDelegate: CGMTransmitterDelegate
    ) {
        let addressAndName: BluetoothTransmitter.DeviceAddressAndName
        if let address {
            addressAndName = .alreadyConnectedBefore(address: address, name: name)
        } else {
            addressAndName = .notYetConnected(expectedName: nil)
        }
        self.variant = variant
        self.cgmTransmitterDelegate = cGMTransmitterDelegate
        self.advertisedName = name
        super.init(
            addressAndName: addressAndName,
            // Use service UUID for advertisement filtering to enable background scanning
            // and auto-discovery like JugglucoNG (scan for devices with FF30 service)
            CBUUID_Advertisement: Sibionics2ProtocolCodec.serviceUUID.uuidString,
            // Device Information is read for a System ID or serial that carries the BLE address.
            servicesCBUUIDs: [
                Sibionics2ProtocolCodec.serviceUUID,
                Sibionics2AuthenticationAddress.deviceInformationServiceUUID,
                Sibionics2Battery.serviceUUID
            ],
            CBUUID_ReceiveCharacteristic: Sibionics2ProtocolCodec.notifyUUID.uuidString,
            CBUUID_WriteCharacteristic: Sibionics2ProtocolCodec.writeUUID.uuidString,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    static func canAdoptPeripheral(
        advertisedName: String?,
        storedAddress: String?,
        peripheralAddress: String,
        variant: SibionicsDeviceVariant = .sibionics2,
        advertisesSibionicsService: Bool = true,
        discoveredWithSibionicsServiceFilter: Bool = false
    ) -> Bool {
        if let storedAddress, !storedAddress.isEmpty {
            return storedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(peripheralAddress.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        if variant == .sibionics1 {
            return (advertisesSibionicsService || discoveredWithSibionicsServiceFilter) && !(advertisedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
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
            peripheralAddress: peripheral.identifier.uuidString,
            variant: variant,
            advertisesSibionicsService: ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []))
                .contains(Sibionics2ProtocolCodec.serviceUUID),
            // This transmitter always passes FF30 to scanForPeripherals.
            // Background discoveries may omit UUIDs in advertisementData.
            discoveredWithSibionicsServiceFilter: true
        ) else { return }

        recordAdvertisedAddressCandidates(advertisementData, for: peripheral.identifier.uuidString)

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

    /// Prefer acknowledged writes like JugglucoNG. The 26-byte V120 auth packet
    /// exceeds the default 20-byte ATT payload, and CoreBluetooth only splits
    /// acknowledged writes; an oversized write without response never reaches the sensor.
    static func writeType(for properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        if properties.contains(.write) { return .withResponse }
        if properties.contains(.writeWithoutResponse) { return .withoutResponse }
        return nil
    }

    private func recordAdvertisedAddressCandidates(_ advertisementData: [String: Any], for identifier: String) {
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let candidates = Sibionics2AuthenticationAddress.advertisementCandidates(manufacturerData: manufacturerData)
        guard Sibionics2AuthenticationAddress.addCandidates(candidates, for: identifier) else { return }
        if identifier.caseInsensitiveCompare(deviceAddress ?? "") == .orderedSame { addressCandidateIndex = 0 }
        trace("Sibionics 2 advertisement manufacturer data=%{public}@ addressCandidates=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info,
              manufacturerData?.hexEncodedString() ?? "none", candidates.joined(separator: ","))
    }

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        if error == nil, service.uuid == Sibionics2Battery.serviceUUID {
            batteryLevelCharacteristic = service.characteristics?.first { $0.uuid == Sibionics2Battery.levelCharacteristicUUID }
            if let batteryLevelCharacteristic {
                lastBatteryReadAt = Date()
                peripheral.readValue(for: batteryLevelCharacteristic)
            }
            return
        }
        if error == nil, service.uuid == Sibionics2AuthenticationAddress.deviceInformationServiceUUID {
            for characteristic in service.characteristics ?? [] where
                characteristic.uuid == Sibionics2AuthenticationAddress.systemIDCharacteristicUUID ||
                characteristic.uuid == Sibionics2AuthenticationAddress.serialNumberCharacteristicUUID {
                pendingDeviceInformationReads += 1
                peripheral.readValue(for: characteristic)
            }
            if pendingDeviceInformationReads == 0, sessionStartDeferred {
                sessionStartDeferred = false
                startSession()
            }
            return
        }
        guard error == nil, service.uuid == Sibionics2ProtocolCodec.serviceUUID else { return }
        characteristicWriteType = service.characteristics?.first(where: { $0.uuid == Sibionics2ProtocolCodec.writeUUID })
            .flatMap { Self.writeType(for: $0.properties) }
        trace("Sibionics 2 FF32 write type: %{public}@", log: transmitterLog,
              category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: characteristicWriteType == nil ? .error : .info,
              characteristicWriteType == .withoutResponse ? "withoutResponse"
                  : characteristicWriteType == .withResponse ? "withResponse" : "unsupported")
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        probeGeneration += 1
        sibionics1Connection = nil
        readingPollGeneration += 1
        resetDisconnectGeneration += 1
        handshakeAttempt += 1
        handshakeStepGeneration += 1
        authenticationKeyGroupIndex = 0
        handshakeRestartCount = 0
        pendingDeviceInformationReads = 0
        sessionStartDeferred = false
        deviceInformationGeneration += 1
        streamingWatchdogGeneration += 1
        batteryLevelCharacteristic = nil
        handshake = nil
        streamingReady = false
        receivedNonEmptyReadingsPacket = false
        notificationEnabled = false
        characteristicWriteType = nil
        historyRequest.reset()
        historyRecoveryToken += 1
        historyRetryScheduled = false
        if authenticationAddressAwaitingReadings {
            // The sensor accepts any address at authentication, so a session that
            // never streamed is the only sign the address was wrong.
            authenticationAddressAwaitingReadings = false
            addressCandidateIndex += 1
            trace("Sibionics 2 session ended without readings; next connection tries another authentication address",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
        }
        authenticationAddressSelected = false
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
        let deviceInformationUndiscovered = peripheral.services?.contains {
            $0.uuid == Sibionics2AuthenticationAddress.deviceInformationServiceUUID && $0.characteristics == nil
        } ?? false
        guard pendingDeviceInformationReads > 0 || deviceInformationUndiscovered else {
            startSession()
            return
        }
        sessionStartDeferred = true
        let generation = deviceInformationGeneration
        runOnCentralQueue(after: Sibionics2ConnectionPolicy.deviceInformationTimeout) { [weak self] in
            guard let self, self.deviceInformationGeneration == generation, self.sessionStartDeferred else { return }
            trace("Sibionics 2 device information not answered; authenticating without it",
                  log: self.transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            self.sessionStartDeferred = false
            self.pendingDeviceInformationReads = 0
            self.startSession()
        }
    }

    override func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
        if characteristic.uuid == Sibionics2Battery.levelCharacteristicUUID {
            receiveBatteryLevel(characteristic.value, error: error)
            return
        }
        if characteristic.uuid == Sibionics2AuthenticationAddress.systemIDCharacteristicUUID ||
            characteristic.uuid == Sibionics2AuthenticationAddress.serialNumberCharacteristicUUID {
            receiveDeviceInformation(characteristic, peripheral: peripheral, error: error)
            return
        }
        guard characteristic.uuid == Sibionics2ProtocolCodec.notifyUUID else { return }
        guard error == nil, let value = characteristic.value else {
            trace("Sibionics 2 FF31 notification failed: %{public}@", log: transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error,
                  error?.localizedDescription ?? "missing value")
            return
        }

        receiveNotification(value, at: Date())
    }

    private func receiveBatteryLevel(_ value: Data?, error: Error?) {
        guard error == nil, let percentage = value.flatMap(Sibionics2Battery.percentage(from:)) else { return }
        trace("Sibionics 2 battery level=%{public}@%%", log: transmitterLog,
              category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info, percentage.description)
        DispatchQueue.main.async { [weak self] in
            var noGlucose = [GlucoseData]()
            self?.cgmTransmitterDelegate?.cgmTransmitterInfoReceived(
                glucoseData: &noGlucose,
                transmitterBatteryInfo: .percentage(percentage: percentage),
                sensorAge: nil
            )
        }
    }

    /// JugglucoNG refreshes the standard battery level every six hours while streaming.
    private func refreshBatteryLevelIfDue(now: Date) {
        guard let batteryLevelCharacteristic, let peripheral = batteryLevelCharacteristic.service?.peripheral,
              now.timeIntervalSince(lastBatteryReadAt ?? .distantPast) >= Sibionics2Battery.refreshInterval else { return }
        lastBatteryReadAt = now
        peripheral.readValue(for: batteryLevelCharacteristic)
    }

    private func receiveDeviceInformation(_ characteristic: CBCharacteristic, peripheral: CBPeripheral, error: Error?) {
        defer {
            pendingDeviceInformationReads = max(0, pendingDeviceInformationReads - 1)
            if pendingDeviceInformationReads == 0, sessionStartDeferred {
                sessionStartDeferred = false
                startSession()
            }
        }
        guard error == nil, let value = characteristic.value else { return }
        let addresses = characteristic.uuid == Sibionics2AuthenticationAddress.systemIDCharacteristicUUID
            ? Sibionics2AuthenticationAddress.systemIDAddress(value).map { [$0] } ?? []
            : Sibionics2AuthenticationAddress.serialNumberAddresses(value)
        trace("Sibionics 2 device information %{public}@=%{public}@ addressCandidates=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info,
              characteristic.uuid.uuidString, value.hexEncodedString(),
              addresses.isEmpty ? "none" : addresses.joined(separator: ","))
        if Sibionics2AuthenticationAddress.addCandidates(addresses, for: peripheral.identifier.uuidString) {
            // A newly published address is tried before candidates that already failed.
            addressCandidateIndex = 0
        }
    }

    /// The address used in this connection produced readings, so keep it for later sessions.
    private func confirmAuthenticationAddress(for address: String) {
        guard authenticationAddressAwaitingReadings else { return }
        authenticationAddressAwaitingReadings = false
        addressCandidateIndex = 0
        guard let confirmed = authenticationAddressInUse,
              Sibionics2AuthenticationAddress.override(for: address) == nil,
              Sibionics2AuthenticationAddress.detected(for: address) != confirmed else { return }
        Sibionics2AuthenticationAddress.setDetected(confirmed, for: address)
        trace("Sibionics 2 authentication address confirmed by glucose readings",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
    }

    /// The address chosen for this connection; retries within it reuse the same one.
    private func authenticationMacAddress(for address: String) -> [UInt8] {
        authenticationAddressSelected
            ? Sibionics2AuthenticationAddress.macBytes(address: authenticationAddressInUse)
            : selectAuthenticationAddress(for: address)
    }

    /// Picks the address for this connection and remembers it until readings confirm it.
    private func selectAuthenticationAddress(for address: String) -> [UInt8] {
        let candidates = Sibionics2AuthenticationAddress.authenticationCandidates(for: address)
        let candidate = candidates[addressCandidateIndex % candidates.count]
        authenticationAddressInUse = candidate
        authenticationAddressSelected = true
        authenticationAddressAwaitingReadings = true
        let source: String
        if Sibionics2AuthenticationAddress.override(for: address) != nil {
            source = "manual override"
        } else if candidate == nil {
            source = "zero fallback"
        } else if candidate == Sibionics2AuthenticationAddress.detected(for: address) {
            source = "detected"
        } else {
            source = "unverified candidate"
        }
        trace("Sibionics 2 authentication address source=%{public}@ candidate=%{public}@/%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info,
              source, (addressCandidateIndex % candidates.count + 1).description, candidates.count.description)
        return Sibionics2AuthenticationAddress.macBytes(address: candidate)
    }

    private func receiveNotification(_ value: Data, at date: Date) {
        if variant == .sibionics1, sibionics1Connection?.mode == .chinese {
            switch chineseCodec.parse(value, at: date) {
            case .readings(let readings):
                sibionics1Connection?.confirm(.chinese)
                probeGeneration += 1
                if let address = deviceAddress {
                    Sibionics2Configuration.setProtocolMode(.chinese, for: address)
                    if !streamingReady { markStreamingReady(for: address) }
                }
                receivedNonEmptyReadingsPacket = !readings.isEmpty || receivedNonEmptyReadingsPacket
                if !readings.isEmpty, let address = deviceAddress { confirmAuthenticationAddress(for: address) }
                receiveReadings(readings, at: date)
            case .requestEcho:
                // JugglucoNG treats the AA55 echo as proof of the Chinese protocol and
                // keeps re-requesting data; falling back to V120 here broke these sensors.
                guard sibionics1Connection?.confirmed == false, let address = deviceAddress else { return }
                sibionics1Connection?.receiveEcho()
                sibionics1Connection?.confirm(.chinese)
                Sibionics2Configuration.setProtocolMode(.chinese, for: address)
                scheduleChineseDataRetry(for: address)
            case .v120AuthRequired:
                switchToV120()
            case .malformed:
                trace("Sibionics 1 rejected malformed probe/data notification", log: transmitterLog,
                      category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            }
            return
        }
        switch codec.parseV120(value) {
        case .malformed:
            trace("Sibionics 2 rejected V120 notification of %{public}@ bytes", log: transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error,
                  value.count.description)
        case .authenticationRequired:
            // An unanswered auth is handled by its own timeout; only restart a session that moved past it.
            guard handshake?.isAwaitingAuthentication != true, let address = deviceAddress else { return }
            trace("Sibionics 2 FF31 requested authentication; restarting handshake",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            streamingReady = false
            readingPollGeneration += 1
            sendAuthentication(for: address)
        case .handshake(let response):
            if variant == .sibionics1, let address = deviceAddress {
                sibionics1Connection?.confirm(.v120)
                Sibionics2Configuration.setProtocolMode(.v120, for: address)
            }
            receiveHandshake(response, at: date)
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
            if let address = deviceAddress { confirmAuthenticationAddress(for: address) }
            if !streamingReady {
                if let address = deviceAddress {
                    markStreamingReady(for: address)
                }
                trace("Sibionics 2 streaming started with first data packet (ready ACK optional)",
                      log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            }
            trace("Sibionics 2 FF31 readings=%{public}@ firstIndex=%{public}@ lastIndex=%{public}@",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info,
                  readings.count.description, first.index.description, last.index.description)
            receiveReadings(readings, at: date)
        }
    }

    override func prepareForRelease() {
        runOnCentralQueue {
            self.probeGeneration += 1
            self.sibionics1Connection = nil
            self.readingPollGeneration += 1
            self.streamingWatchdogGeneration += 1
            self.autoResetCheckGeneration += 1
            self.resetDisconnectGeneration += 1
            self.handshake = nil
            self.batchProcessor = nil
            self.probeReplaySessionStartDate = nil
            self.streamingReady = false
            self.notificationEnabled = false
            self.characteristicWriteType = nil
            self.historyRequest.reset()
            self.historyRecoveryToken += 1
            self.handshakeAttempt += 1
            self.handshakeStepGeneration += 1
        }
        super.prepareForRelease()
    }

    /// Rebuilds the stock correction after a probe code is changed. The
    /// processor snapshot contains the sensitivity, so replay from the sensor
    /// is required before corrected values are published again. Delivery also
    /// reconciles previously stored samples before the CGM cadence filter runs.
    func probeCodeDidChange(for address: String) {
        runOnCentralQueue { [weak self] in
            guard let self,
                  let currentAddress = self.deviceAddress,
                  currentAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else { return }

            self.probeReplaySessionStartDate = self.batchProcessor?.state?.sensorStartDate
                ?? self.stateStore.load(for: address)?.sensorStartDate
            self.stateStore.clear(for: address)
            self.batchProcessor = nil
            self.historyRequest.reset()
            self.historyRecoveryToken += 1
            self.historyRetryScheduled = false
            self.historyWriteFailures = 0
            trace("Sibionics 2 probe code changed; replaying history with decoded factory sensitivity",
                  log: self.transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            self.requestNewReading()
        }
    }

    var calibrationMode: Sibionics2CalibrationMode { calibrationProfile.mode }

    var calibrationProfile: Sibionics2CalibrationProfile { .current(for: deviceAddress) }

    func autoResetSettingDidChange(for address: String) {
        runOnCentralQueue { [weak self] in
            guard let self,
                  let currentAddress = self.deviceAddress,
                  currentAddress.caseInsensitiveCompare(address) == .orderedSame else { return }
            self.autoResetCheckGeneration += 1
            self.scheduleAutoResetCheck(for: currentAddress)
        }
    }

    func requestSensorReset(for requestedAddress: String? = nil) {
        guard variant.supportsReset else { return }
        guard let address = requestedAddress ?? deviceAddress else {
            trace("Sibionics 2 reset requested before a peripheral address was assigned",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            return
        }
        Sibionics2Configuration.requestReset(for: address)
        runOnCentralQueue { [weak self] in
            guard let self else { return }
            guard let currentAddress = self.deviceAddress else {
                self.connect()
                return
            }
            guard currentAddress.caseInsensitiveCompare(address) == .orderedSame else {
                trace("Sibionics 2 reset request ignored because the transmitter is assigned to a different peripheral",
                      log: self.transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
                return
            }
            if self.streamingReady {
                self.sendPendingResetIfReady(for: currentAddress)
            } else if self.getConnectionStatus() != .connecting {
                self.connect()
            }
        }
    }

    /// Apply a newly saved authentication address at the next connection.
    /// Keep the reading cursor and algorithm snapshot intact.
    func authenticationAddressDidChange(for address: String) {
        runOnCentralQueue { [weak self] in
            guard let self,
                  let currentAddress = self.deviceAddress,
                  currentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(address.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            else { return }

            trace("Sibionics 2 authentication address updated; reconnecting",
                  log: self.transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            if self.getConnectionStatus() == .connected || self.getConnectionStatus() == .connecting {
                self.disconnect()
            } else {
                self.connect()
            }
        }
    }

    func isNonFixedSlopeEnabled() -> Bool { false }
    func isWebOOPEnabled() -> Bool { true }
    func overruleIsWebOOPEnabled() -> Bool { true }
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
    func maxSensorAgeInDays() -> Double? {
        variant == .sibionics1 ? 14 : Double(Sibionics2SensorProfile.expectedLifeInDays)
    }

    /// Sibionics accepts no transmitter-side calibration write. Calibrations live
    /// in xDrip's CGM pipeline, so request fresh data to apply the saved profile.
    func calibrate(calibration: Calibration) {
        requestNewReading()
    }

    func needsSensorStartTime() -> Bool { false }
    func needsSensorStartCode() -> Bool { false }
    func shouldWarnOnLargeCalibrationStep() -> Bool { false }
    func getCBUUID_Service() -> String { Sibionics2ProtocolCodec.serviceUUID.uuidString }
    func getCBUUID_Receive() -> String { Sibionics2ProtocolCodec.notifyUUID.uuidString }

    private func markStreamingReady(for address: String) {
        streamingReady = true
        handshakeReconnectCount = 0
        scheduleChinesePoll(for: address)
        scheduleStreamingWatchdog()
        sendPendingResetIfReady(for: address)
    }

    private var usesChineseProtocol: Bool {
        variant == .sibionics1 && sibionics1Connection?.mode == .chinese
    }

    /// The Chinese protocol needs a request for every page; V120 streams on its own.
    private func scheduleChinesePoll(for address: String) {
        guard streamingReady, usesChineseProtocol else { return }
        readingPollGeneration += 1
        let generation = readingPollGeneration
        runOnCentralQueue(after: Sibionics2ConnectionPolicy.chinesePollInterval) { [weak self] in
            guard let self,
                  self.readingPollGeneration == generation,
                  self.streamingReady, self.usesChineseProtocol,
                  let currentAddress = self.deviceAddress,
                  currentAddress.caseInsensitiveCompare(address) == .orderedSame else { return }
            _ = self.sendDataRequest(for: currentAddress)
            self.scheduleChinesePoll(for: currentAddress)
        }
    }

    /// Reconnects a session that stays up but stops delivering readings, as
    /// JugglucoNG's streaming timeout does. Each readings packet re-arms it.
    private func scheduleStreamingWatchdog() {
        streamingWatchdogGeneration += 1
        let generation = streamingWatchdogGeneration
        runOnCentralQueue(after: Sibionics2ConnectionPolicy.readingsStallTimeout) { [weak self] in
            guard let self,
                  self.streamingWatchdogGeneration == generation,
                  self.streamingReady,
                  self.getConnectionStatus() == .connected else { return }
            trace("Sibionics 2 no readings for %{public}@ seconds while streaming; reconnecting",
                  log: self.transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error,
                  Sibionics2ConnectionPolicy.readingsStallTimeout.description)
            self.disconnect()
        }
    }

    private func sendPendingResetIfReady(for address: String) {
        guard variant.supportsReset, streamingReady,
              Sibionics2Configuration.resetRequested(for: address) else { return }
        guard writeCommand(codec.buildResetPacket(), label: "maintenance-reset") else {
            resetDisconnectGeneration += 1
            let generation = resetDisconnectGeneration
            runOnCentralQueue(after: Sibionics2ConnectionPolicy.resetWriteRetryDelay) { [weak self] in
                guard let self,
                      self.resetDisconnectGeneration == generation,
                      let currentAddress = self.deviceAddress,
                      currentAddress.caseInsensitiveCompare(address) == .orderedSame,
                      self.streamingReady,
                      Sibionics2Configuration.resetRequested(for: currentAddress) else { return }
                self.sendPendingResetIfReady(for: currentAddress)
            }
            return
        }

        Sibionics2Configuration.markResetSent(for: address)
        readingPollGeneration += 1
        resetDisconnectGeneration += 1
        let generation = resetDisconnectGeneration
        trace("Sibionics 2 reset command queued; keeping local session until restart is confirmed",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
        runOnCentralQueue(after: Sibionics2ConnectionPolicy.resetRestartConfirmationDelay) { [weak self] in
            guard let self,
                  self.resetDisconnectGeneration == generation,
                  Sibionics2Configuration.awaitingResetRestart(for: address) else { return }
            trace("Sibionics 2 reset did not disconnect; reconnecting to probe for a new session",
                  log: self.transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
            self.disconnect()
        }
    }

    private func scheduleAutoResetCheck(for address: String) {
        guard variant.supportsReset else { return }
        autoResetCheckGeneration += 1
        let generation = autoResetCheckGeneration
        guard !Sibionics2Configuration.awaitingResetRestart(for: address),
              let startDate = stateStore.load(for: address)?.sensorStartDate else { return }

        let age = Date().timeIntervalSince(startDate)
        let autoResetEnabled = Sibionics2Configuration.autoResetEnabled(for: address)
        let hardResetAge = Sibionics2AutoResetPolicy.expectedSensorLife
            - Sibionics2AutoResetPolicy.preExpiryGuard
        let delay: TimeInterval
        if !autoResetEnabled {
            delay = max(Sibionics2ConnectionPolicy.minimumScheduledDelay, hardResetAge - age)
        } else if age < Sibionics2AutoResetPolicy.normalResetAge {
            delay = max(
                Sibionics2ConnectionPolicy.minimumScheduledDelay,
                Sibionics2AutoResetPolicy.normalResetAge - age
            )
        } else {
            delay = Sibionics2ConnectionPolicy.automaticResetRecheckInterval
        }
        runOnCentralQueue(after: delay) { [weak self] in
            guard let self, self.autoResetCheckGeneration == generation else { return }
            self.evaluateAutoReset(for: address)
        }
    }

    private func evaluateAutoReset(for address: String) {
        guard variant.supportsReset else { return }
        guard !Sibionics2Configuration.awaitingResetRestart(for: address) else { return }
        let decision = Sibionics2AutoResetPolicy.evaluate(
            now: Date(),
            sensorStartDate: stateStore.load(for: address)?.sensorStartDate,
            enabled: Sibionics2Configuration.autoResetEnabled(for: address),
            previous: Sibionics2Configuration.previousReading(for: address),
            latest: Sibionics2Configuration.latestReading(for: address)
        )
        guard decision.resetNow else {
            scheduleAutoResetCheck(for: address)
            return
        }

        trace("Sibionics 2 automatic reset due; forced=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: .info, decision.forced.description)
        Sibionics2Configuration.requestReset(for: address)
        if streamingReady {
            sendPendingResetIfReady(for: address)
        } else if getConnectionStatus() != .connecting {
            connect()
        }
    }

    private func startSession() {
        probeGeneration += 1
        authenticationKeyGroupIndex = 0
        handshakeRestartCount = 0
        authenticationAddressInUse = nil
        authenticationAddressSelected = false
        authenticationAddressAwaitingReadings = false
        guard variant == .sibionics1, let address = deviceAddress else {
            startHandshake()
            return
        }
        sibionics1Connection = Sibionics1ConnectionState(savedMode: Sibionics2Configuration.protocolMode(for: address))
        if sibionics1Connection?.mode == .v120 {
            startHandshake()
        } else {
            batchProcessor = makeBatchProcessor(for: address)
            _ = sendChineseDataRequest(for: address)
            if Sibionics2Configuration.protocolMode(for: address) == .chinese {
                // A confirmed Chinese sensor is not re-probed; only its V120 marker switches it.
                sibionics1Connection?.confirm(.chinese)
                scheduleChineseDataRetry(for: address)
            } else {
                scheduleChineseProbeTimeout()
            }
        }
    }

    /// Re-sends the Chinese request until the first data page, as JugglucoNG's data timeout does.
    private func scheduleChineseDataRetry(for address: String) {
        probeGeneration += 1
        let generation = probeGeneration
        runOnCentralQueue(after: Sibionics2ConnectionPolicy.chineseDataRetryInterval) { [weak self] in
            guard let self, self.probeGeneration == generation,
                  self.notificationEnabled, !self.streamingReady, self.usesChineseProtocol else { return }
            _ = self.sendChineseDataRequest(for: address)
            self.scheduleChineseDataRetry(for: address)
        }
    }

    @discardableResult
    private func sendChineseDataRequest(for address: String) -> Bool {
        let cursor = stateStore.load(for: address)?.lastDeliveredIndex ?? 0
        return writeCommand(chineseCodec.buildDataRequestPacket(
            lastIndex: cursor, macAddress: authenticationMacAddress(for: address)
        ), label: "Chinese data-request index=\(cursor)")
    }

    private func scheduleChineseProbeTimeout() {
        guard let connection = sibionics1Connection, !connection.confirmed,
              connection.mode == .chinese else { return }
        probeGeneration += 1
        let generation = probeGeneration
        runOnCentralQueue(after: connection.probeDelay) { [weak self] in
            guard let self, self.probeGeneration == generation,
                  self.notificationEnabled else { return }
            // No Chinese answer at all: the firmware speaks V120.
            self.fallBackToV120()
        }
    }

    private func fallBackToV120() {
        guard sibionics1Connection?.fallBackToV120() == true else { return }
        beginV120AfterChineseProbe()
    }

    /// The V120 marker is authoritative even for a sensor saved as Chinese.
    private func switchToV120() {
        guard sibionics1Connection?.requireV120() == true else { return }
        beginV120AfterChineseProbe()
    }

    private func beginV120AfterChineseProbe() {
        probeGeneration += 1
        readingPollGeneration += 1
        // The factory algorithms have different serialized state and must not
        // reuse a Chinese processor when the sensor requests EU authentication.
        batchProcessor = nil
        startHandshake()
    }

    private func startHandshake() {
        guard let address = deviceAddress else {
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
        guard sendAuthentication(for: address) else { return }
        scheduleAutoResetCheck(for: address)
        runOnCentralQueue(after: Sibionics2ConnectionPolicy.streamingTimeout) { [weak self] in
            guard let self, self.handshakeAttempt == attempt else { return }
            if self.streamingReady {
                guard !self.receivedNonEmptyReadingsPacket else { return }
                trace("Sibionics 2 received streaming-ready but no glucose readings after %{public}@ seconds",
                      log: self.transmitterLog,
                      category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error,
                      Sibionics2ConnectionPolicy.streamingTimeout.description)
                return
            }
            trace("Sibionics 2 handshake stalled: FF31 has not begun streaming",
                  log: self.transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            self.reconnectAfterStalledHandshake()
        }
    }

    /// Builds a fresh handshake with the current key group and writes its auth
    /// packet. Used for the first attempt and for in-connection retries, which
    /// keep the connection-wide streaming timeout armed by `startHandshake`.
    @discardableResult
    private func sendAuthentication(for address: String) -> Bool {
        let keyGroups = Sibionics2KeyGroup.authenticationOrder(for: variant)
        guard keyGroups.indices.contains(authenticationKeyGroupIndex),
              let sessionKey = codec.deriveSessionKey(group: keyGroups[authenticationKeyGroupIndex]) else {
            trace("could not initialize Sibionics 2 authentication", log: transmitterLog,
                  category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            return false
        }
        trace("Sibionics 2 authentication keyGroup=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: .info, keyGroups[authenticationKeyGroupIndex].applicationIdentifier)
        let macAddress = authenticationMacAddress(for: address)
        let probeAfterReset = variant.supportsReset && Sibionics2Configuration.resetProbePending(for: address)
        var newHandshake = Sibionics2Handshake(
            macAddress: macAddress,
            sessionKey: sessionKey,
            lastDeliveredIndex: probeAfterReset ? nil : batchProcessor?.state?.lastDeliveredIndex
        )
        let command = newHandshake.start(at: Date())
        guard !command.isEmpty else { return false }
        handshake = newHandshake
        _ = writeCommand(command, label: "auth")
        scheduleHandshakeStepTimeout()
        return true
    }

    /// Mirrors JugglucoNG's auth and handshake-step timeouts: no auth response
    /// moves to the next key group, and a stalled later step restarts auth.
    private func scheduleHandshakeStepTimeout() {
        handshakeStepGeneration += 1
        let generation = handshakeStepGeneration
        let delay = handshake?.isAwaitingAuthentication == true
            ? Sibionics2ConnectionPolicy.authenticationResponseTimeout
            : Sibionics2ConnectionPolicy.handshakeStepTimeout
        runOnCentralQueue(after: delay) { [weak self] in
            guard let self,
                  self.handshakeStepGeneration == generation,
                  let handshake = self.handshake, !handshake.isStreaming,
                  self.getConnectionStatus() == .connected,
                  let address = self.deviceAddress else { return }
            if handshake.isAwaitingAuthentication {
                self.tryNextAuthenticationKeyGroup(for: address)
            } else if self.handshakeRestartCount < Sibionics2ConnectionPolicy.maximumHandshakeRestartsPerConnection {
                self.handshakeRestartCount += 1
                trace("Sibionics 2 handshake step timed out; restarting authentication",
                      log: self.transmitterLog,
                      category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
                self.sendAuthentication(for: address)
            }
        }
    }

    private func tryNextAuthenticationKeyGroup(for address: String) {
        authenticationKeyGroupIndex += 1
        guard authenticationKeyGroupIndex < Sibionics2KeyGroup.authenticationOrder(for: variant).count else {
            authenticationKeyGroupIndex = 0
            trace("Sibionics 2 authentication was not answered with any key group",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .error)
            reconnectAfterStalledHandshake()
            return
        }
        trace("Sibionics 2 authentication not answered; retrying with the next key group",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
        sendAuthentication(for: address)
    }

    private func reconnectAfterStalledHandshake() {
        guard notificationEnabled,
              handshakeReconnectCount < Sibionics2ConnectionPolicy.maximumHandshakeReconnectAttempts else { return }
        handshakeReconnectCount += 1
        disconnect()
    }

    private func makeBatchProcessor(for address: String) -> Sibionics2ReadingBatchProcessor {
        if let batchProcessor,
           batchProcessor.state != nil || stateStore.load(for: address) == nil {
            return batchProcessor
        }
        let probeCode = Sibionics2Configuration.probeCode(for: address)
        let sensitivity = Sibionics2FactorySensitivity.effectiveSensitivity(
            advertisedName: advertisedName,
            probeCode: probeCode, variant: variant
        )
        trace("Sibionics 2 sensitivity=%{public}@ source=%{public}@",
              log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager,
              type: .info, sensitivity.description,
              probeCode != nil ? "QR probe code" : "advertisement fallback")
        return Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: sensitivity,
                stockFamily: variant == .sibionics1 && sibionics1Connection?.mode == .chinese ? .v115g : .v116a),
            allowsHistoricalBootstrap: variant == .sibionics1 && sibionics1Connection?.mode == .chinese
        )
    }

    @discardableResult
    private func sendDataRequest(for address: String) -> Bool {
        guard streamingReady else { return false }
        let cursor = stateStore.load(for: address)?.lastDeliveredIndex ?? 0
        if variant == .sibionics1 && sibionics1Connection?.mode == .chinese {
            return sendChineseDataRequest(for: address)
        }
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
            scheduleHandshakeStepTimeout()
        } else if !wasStreaming && handshake.isStreaming {
            if let address = deviceAddress {
                markStreamingReady(for: address)
            }
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
            runOnCentralQueue(after: Sibionics2ConnectionPolicy.historyResponseTimeout) { [weak self] in
                guard let self, self.historyRecoveryToken == token,
                      !self.historyRequest.needsRequest(for: sessionStart, cursor: cursor),
                      self.batchProcessor?.requiresHistoryReplay == true else { return }
                self.reconnectForMissingHistory()
            }
        } else {
            historyWriteFailures += 1
            if historyWriteFailures >= Sibionics2ConnectionPolicy.maximumHistoryWriteFailures {
                reconnectForMissingHistory()
            } else if !historyRetryScheduled {
                historyRetryScheduled = true
                let token = historyRecoveryToken
                runOnCentralQueue(after: Sibionics2ConnectionPolicy.historyWriteRetryDelay) { [weak self] in
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
        guard historyReconnectCount < Sibionics2ConnectionPolicy.maximumHistoryReconnectAttempts,
              getConnectionStatus() == .connected else {
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
        if !readings.isEmpty {
            scheduleStreamingWatchdog()
            refreshBatteryLevelIfDue(now: receivedAt)
        }
        var currentProcessor = batchProcessor ?? makeBatchProcessor(for: address)
        let previousStartDate = currentProcessor.state?.sensorStartDate ?? probeReplaySessionStartDate
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
        guard !(requiresHistoryReplay && currentState?.lastDeliveredIndex == nil && glucoseData.isEmpty),
              let sensorStartDate = currentState?.sensorStartDate else { return }
        probeReplaySessionStartDate = nil
        let detectedNewSensor = previousStartDate.map {
            abs($0.timeIntervalSince(sensorStartDate)) > Sibionics2ConnectionPolicy.sessionStartDateTolerance
        } ?? true
        let sensorAge = max(0, receivedAt.timeIntervalSince(sensorStartDate))
        if variant.supportsReset, detectedNewSensor, Sibionics2Configuration.awaitingResetRestart(for: address) {
            Sibionics2Configuration.clearResetRestart(for: address)
            resetDisconnectGeneration += 1
            autoResetCheckGeneration += 1
            scheduleStreamingWatchdog()
            trace("Sibionics 2 confirmed a new sensor session after reset; local processor state has advanced",
                  log: transmitterLog, category: ConstantsLog.categoryBluetoothPeripheralManager, type: .info)
        }
        for item in glucoseData.reversed() {
            Sibionics2Configuration.recordReading(
                Sibionics2AutoResetReading(glucoseMgDl: item.glucoseLevelRaw, timeStamp: item.timeStamp),
                for: address
            )
        }
        if !glucoseData.isEmpty {
            evaluateAutoReset(for: address)
        } else {
            scheduleAutoResetCheck(for: address)
        }
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
                reading.glucoseLevelRaw > 0 &&
                reading.glucoseLevelRaw <= Sibionics2SensorProfile.maximumReportableGlucoseMgDl
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

/// Negotiation state is kept separate from CoreBluetooth so timeout and
/// reconnect behavior can be checked without an attached sensor.
struct Sibionics1ConnectionState {
    private(set) var mode: Sibionics1ProtocolMode
    private(set) var confirmed = false
    private(set) var receivedEcho = false
    var probeDelay: TimeInterval { receivedEcho ? 30 : 5 }

    init(savedMode: Sibionics1ProtocolMode?) {
        mode = savedMode ?? .chinese
    }

    mutating func receiveEcho() { receivedEcho = true }
    mutating func confirm(_ mode: Sibionics1ProtocolMode) {
        self.mode = mode
        confirmed = true
    }
    mutating func fallBackToV120() -> Bool {
        guard mode == .chinese, !confirmed else { return false }
        mode = .v120
        return true
    }

    /// The sensor's V120 authentication marker switches even a confirmed Chinese session.
    mutating func requireV120() -> Bool {
        guard mode == .chinese else { return false }
        mode = .v120
        confirmed = false
        return true
    }
}
