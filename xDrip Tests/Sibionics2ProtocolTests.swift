//
//  Sibionics2ProtocolTests.swift
//  xdripTests
//

import CoreBluetooth
import XCTest
@testable import xdrip

final class Sibionics2ProtocolTests: XCTestCase {
    private let testBluetoothAddress = "02:00:00:00:00:01"
    private let testBluetoothAddressBytes: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
    private let codec = Sibionics2ProtocolCodec()

    private func encryptedFrame(_ bytesWithoutChecksum: [UInt8]) -> Data {
        var bytes = bytesWithoutChecksum
        bytes.append(0 &- bytes.reduce(UInt8(0), { $0 &+ $1 }))
        return codec.encrypt(Data(bytes))
    }

    private func assertCommand(_ data: Data?, equals expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        guard let data else {
            XCTFail("Expected command", file: file, line: line)
            return
        }
        let plaintext = [UInt8](codec.decrypt(data))
        XCTAssertEqual(Array(plaintext.dropLast()), expected, file: file, line: line)
        XCTAssertEqual(plaintext.reduce(UInt8(0), { $0 &+ $1 }), 0, file: file, line: line)
    }

    func testRC4MatchesKnownVectorAndUsesFreshState() {
        let zeros = Data(repeating: 0, count: 12)
        let expected: [UInt8] = [0x27, 0xF7, 0x6F, 0xD9, 0x08, 0x73, 0x58, 0xDC, 0xBD, 0x81, 0x86, 0x03]
        XCTAssertEqual([UInt8](codec.encrypt(zeros)), expected)
        XCTAssertEqual(codec.encrypt(zeros), codec.encrypt(zeros))
        XCTAssertEqual(codec.decrypt(Data(expected)), zeros)
    }

    func testSibionics2IdentityDerivesEcoSessionKey() {
        XCTAssertEqual(codec.deriveSessionKey(), Data("GKSHGDU0TYA456G4".utf8))
        XCTAssertEqual(Sibionics2ProtocolCodec.serviceUUID.uuidString, "FF30")
        XCTAssertEqual(Sibionics2ProtocolCodec.notifyUUID.uuidString, "FF31")
        XCTAssertEqual(Sibionics2ProtocolCodec.writeUUID.uuidString, "FF32")
    }

    func testPacketDecoderRejectsCorruptedChecksumAndTruncation() {
        let valid = encryptedFrame([0x04, 0x01, 0x00, 0x00])
        guard case .handshake(.authenticationAccepted) = codec.parseV120(valid) else {
            return XCTFail("Expected authentication response")
        }
        var damaged = [UInt8](codec.decrypt(valid))
        damaged[2] ^= 0x01
        guard case .malformed = codec.parseV120(codec.encrypt(Data(damaged))) else {
            return XCTFail("Checksum corruption was accepted")
        }
        guard case .malformed = codec.parseV120(Data(valid.dropLast())) else {
            return XCTFail("Truncated handshake was accepted")
        }
        guard case .malformed = codec.parseV120(encryptedFrame([0x04, 0x10, 0, 0])) else {
            return XCTFail("Unknown response was accepted")
        }
        // A valid checksum must not hide a truncated second record.
        let truncated = encryptedFrame([0x11, 0x08, 0x02, 0x34, 0x12, 0, 0, 0, 0,
                                        0x68, 0x01, 0xF4, 0x01, 0x48, 0, 0x20, 0])
        guard case .malformed = codec.parseV120(truncated) else {
            return XCTFail("Truncated readings were accepted")
        }
        // The sensor may include trailing status bytes. The declared frame and
        // checksum still have to be valid before its data records are accepted.
        guard case .readings(let keepalive) = codec.parseV120(
            encryptedFrame([0x0A, 0x08, 0, 0, 0, 0, 0, 0, 0, 0])
        ) else { return XCTFail("Expected a keepalive with trailing status") }
        XCTAssertTrue(keepalive.isEmpty)
        guard case .handshake(.authenticationAccepted) = codec.parseV120(
            encryptedFrame([0x04, 0x01, 0x42, 0x99])
        ) else { return XCTFail("Valid handshake with status bytes was rejected") }
    }

    func testV120ReadingsDecodeLittleEndianIndexTimeAndTrend() {
        let packet = encryptedFrame([0x19, 0x08, 0x02, 0x34, 0x12,
                                     0x00, 0xF1, 0x53, 0x65,
                                     0x68, 0x01, 0xF4, 0x01, 0x48, 0x00, 0x20, 0x00,
                                     0x72, 0x01, 0xF5, 0x01, 0x4B, 0x00, 0x30, 0x00])
        guard case .readings(let readings) = codec.parseV120(packet) else {
            return XCTFail("Expected two readings")
        }
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].index, 0x1234)
        XCTAssertEqual(readings[1].index, 0x1235)
        XCTAssertEqual(readings[0].eventTime.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(readings[1].eventTime.timeIntervalSince1970, 1_700_000_060)
        XCTAssertEqual(readings[0].temperatureC, 36.0)
        XCTAssertEqual(readings[0].impedance, 500)
        XCTAssertEqual(readings[0].rawMmol, 7.2)
        XCTAssertEqual(readings[0].trend, .stable)
        XCTAssertEqual(readings[1].trend, .falling)
        XCTAssertEqual(readings[0].reindex, 1)
        XCTAssertEqual(readings[1].reindex, 0)
    }

    func testHandshakeEmitsAuthActivationTimeSyncAndDataRequestInOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var handshake = Sibionics2Handshake(macAddress: [1, 2, 3, 4, 5, 6],
                                             sessionKey: Data("GKSHGDU0TYA456G4".utf8),
                                             lastDeliveredIndex: 0x1234)
        XCTAssertNil(handshake.receive(.authenticationAccepted, at: now))
        assertCommand(handshake.start(at: now), equals: [0x19, 0x01, 0, 6, 5, 4, 3, 2, 1] + Array("GKSHGDU0TYA456G4".utf8))
        XCTAssertNil(handshake.receive(.dataRequested, at: now))
        assertCommand(handshake.receive(.authenticationAccepted, at: now), equals: [0x0A, 0x07, 0, 0xF1, 0x53, 0x65, 0xD2, 0x04, 0, 0])
        XCTAssertNil(handshake.receive(.authenticationAccepted, at: now))
        assertCommand(handshake.receive(.timeSyncNeeded, at: now), equals: [0x06, 0x03, 0, 0xF1, 0x53, 0x65])
        assertCommand(handshake.receive(.dataRequested, at: now), equals: [0x06, 0x08, 0x34, 0x12, 0, 0])
        XCTAssertNil(handshake.receive(.streamingReady, at: now))
        XCTAssertNil(handshake.receive(.authenticationAccepted, at: now))
    }

    func testBluetoothAddressOverrideUsesConfiguredAddressToBuildAuthPacket() throws {
        let suiteName = "Sibionics2AuthAddress.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = "DE1815CA-590A-1AAF-9C98-34082E80A191"
        let otherIdentifier = "another-peripheral"

        XCTAssertEqual(Sibionics2AuthenticationAddress.macBytes(for: identifier, userDefaults: defaults),
                       [UInt8](repeating: 0, count: 6))
        XCTAssertTrue(Sibionics2AuthenticationAddress.setOverride(
             " \(testBluetoothAddress.lowercased()) ", for: identifier, userDefaults: defaults
        ))
        XCTAssertEqual(Sibionics2AuthenticationAddress.override(for: identifier, userDefaults: defaults),
                       testBluetoothAddress)
        let mac = Sibionics2AuthenticationAddress.macBytes(for: identifier, userDefaults: defaults)
        XCTAssertEqual(mac, testBluetoothAddressBytes)
        XCTAssertEqual(Sibionics2AuthenticationAddress.macBytes(for: otherIdentifier, userDefaults: defaults),
                       [UInt8](repeating: 0, count: 6))
        XCTAssertEqual(
            [UInt8](codec.buildAuthPacket(macAddress: mac, sessionKey: Data("GKSHGDU0TYA456G4".utf8))),
            [0x3E, 0xF6, 0x6F, 0xD8, 0x08, 0x73, 0x58, 0xDC, 0xBF, 0xC6, 0xCD, 0x50,
             0x47, 0xF0, 0x42, 0xD9, 0xB2, 0xE7, 0xBD, 0x0D, 0x16, 0xB1, 0x57, 0xF1,
             0x4A, 0x94]
        )
    }

    func testInvalidBluetoothAddressCannotReplaceStoredAuthenticationAddress() throws {
        let suiteName = "Sibionics2AuthAddress.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = "saved-device"

        XCTAssertTrue(Sibionics2AuthenticationAddress.setOverride(
            testBluetoothAddress, for: identifier, userDefaults: defaults
        ))
        for input in [
            "02:00:00:00:00",
            "02:00:00:00:GG:01",
            "00:00:00:00:00:00",
            "02-00-00-00-00-01",
            "02::00:00:00:00:01",
            "02.00.00.00.00.01"
        ] {
            XCTAssertNil(Sibionics2AuthenticationAddress.normalize(input))
            XCTAssertFalse(Sibionics2AuthenticationAddress.setOverride(input, for: identifier, userDefaults: defaults))
            XCTAssertEqual(Sibionics2AuthenticationAddress.override(for: identifier, userDefaults: defaults),
                           testBluetoothAddress)
        }
        XCTAssertTrue(Sibionics2AuthenticationAddress.setOverride(nil, for: identifier, userDefaults: defaults))
        XCTAssertNil(Sibionics2AuthenticationAddress.override(for: identifier, userDefaults: defaults))
    }

    func testSensorCaptureCommandVectors() {
        let sessionKey = Data("GKSHGDU0TYA456G4".utf8)
        XCTAssertEqual(
            [UInt8](codec.buildAuthPacket(
                macAddress: testBluetoothAddressBytes,
                sessionKey: sessionKey
            )),
            [0x3E, 0xF6, 0x6F, 0xD8, 0x08, 0x73, 0x58, 0xDC, 0xBF, 0xC6, 0xCD, 0x50,
             0x47, 0xF0, 0x42, 0xD9, 0xB2, 0xE7, 0xBD, 0x0D, 0x16, 0xB1, 0x57, 0xF1,
             0x4A, 0x94]
        )
        XCTAssertEqual(
            [UInt8](codec.buildDataRequestPacket(lastIndex: 25_296)),
            [0x21, 0xFF, 0xBF, 0xBB, 0x08, 0x73, 0x98]
        )
    }

    func testFirstDataFrameStartsStreamingWithoutOptionalReadyAcknowledgement() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var handshake = Sibionics2Handshake(macAddress: [UInt8](repeating: 0, count: 6),
                                             sessionKey: Data("GKSHGDU0TYA456G4".utf8),
                                             lastDeliveredIndex: 0)
        XCTAssertFalse(handshake.receiveReadings())
        _ = handshake.start(at: now)
        XCTAssertFalse(handshake.receiveReadings(), "No readings before auth")
        _ = handshake.receive(.authenticationAccepted, at: now)
        _ = handshake.receive(.timeSyncNeeded, at: now)
        assertCommand(handshake.receive(.dataRequested, at: now),
                      equals: [0x06, 0x08, 0, 0, 0, 0])
        XCTAssertTrue(handshake.receiveReadings())
        XCTAssertTrue(handshake.receiveReadings())
        XCTAssertNil(handshake.receive(.streamingReady, at: now))

        var earlyData = Sibionics2Handshake(macAddress: [UInt8](repeating: 0, count: 6),
                                            sessionKey: Data("GKSHGDU0TYA456G4".utf8),
                                            lastDeliveredIndex: nil)
        _ = earlyData.start(at: now)
        _ = earlyData.receive(.authenticationAccepted, at: now)
        XCTAssertTrue(earlyData.receiveReadings(), "Some sensors stream immediately after authentication")

        var skippedTimeSync = Sibionics2Handshake(macAddress: [UInt8](repeating: 0, count: 6),
                                                  sessionKey: Data("GKSHGDU0TYA456G4".utf8),
                                                  lastDeliveredIndex: 0x1234)
        _ = skippedTimeSync.start(at: now)
        _ = skippedTimeSync.receive(.authenticationAccepted, at: now)
        assertCommand(skippedTimeSync.receive(.dataRequested, at: now),
                      equals: [0x06, 0x08, 0x34, 0x12, 0, 0])
        XCTAssertTrue(skippedTimeSync.receiveReadings())
    }

    func testFailedHistoryWriteRemainsEligibleForRetryAndProgressRequestsNextPage() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var tracker = Sibionics2HistoryRequestTracker()
        XCTAssertTrue(tracker.needsRequest(for: start, cursor: 0))
        tracker.record(for: start, cursor: 0, queued: false)
        XCTAssertTrue(tracker.needsRequest(for: start, cursor: 0))
        tracker.record(for: start, cursor: 0, queued: true)
        XCTAssertFalse(tracker.needsRequest(for: start, cursor: 0))
        XCTAssertTrue(tracker.needsRequest(for: start, cursor: 1_000))
        tracker.reset()
        XCTAssertTrue(tracker.needsRequest(for: start, cursor: 0))
    }

    func testSibionicsWriteTypeMatchesFF32Properties() {
        XCTAssertEqual(CGMSibionics2Transmitter.writeType(
            for: [.writeWithoutResponse]), .withoutResponse)
        XCTAssertEqual(CGMSibionics2Transmitter.writeType(
            for: [.write]), .withResponse)
        XCTAssertEqual(CGMSibionics2Transmitter.writeType(
            for: [.write, .writeWithoutResponse]), .withoutResponse)
        XCTAssertNil(CGMSibionics2Transmitter.writeType(for: [.read]))
    }

    func testOnlySibionics2AdvertisementNamesMatch() {
        XCTAssertTrue(Sibionics2DeviceIdentity.isSibionics2(name: "P123ABCD"))
        XCTAssertTrue(Sibionics2DeviceIdentity.isSibionics2(name: "p123-ABCD_56"))
        XCTAssertTrue(Sibionics2DeviceIdentity.isSibionics2(name: "P1234567890123456"))
        for name in [nil, "", "P12ABCD", "P123", "P12345678901234567", "P123_#ABCD",
                     "GS3-12345", "GKS2-ABCDE", "SiBionics CGM", "SiBionics 2",
                     "Sijoy CGM", "GS1ECO", "Dexcom G7"] as [String?] {
            XCTAssertFalse(Sibionics2DeviceIdentity.isSibionics2(name: name), "Unexpected match: \(name ?? "nil")")
        }
    }

    func testAuthenticationAddressAcceptsCompactAndPrivateSelectorValueFormats() {
        XCTAssertEqual(
            Sibionics2AuthenticationAddress.normalize(testBluetoothAddress.lowercased()),
            testBluetoothAddress
        )
        XCTAssertEqual(
            Sibionics2AuthenticationAddress.normalize(
                testBluetoothAddress.replacingOccurrences(of: ":", with: "")
            ),
            testBluetoothAddress
        )
        XCTAssertEqual(
            Sibionics2AuthenticationAddress.address(from: Data(testBluetoothAddressBytes)),
            testBluetoothAddress
        )
        XCTAssertEqual(
            Sibionics2AuthenticationAddress.address(from: testBluetoothAddress),
            testBluetoothAddress
        )
        XCTAssertNil(Sibionics2AuthenticationAddress.normalize("000000000000"))
        XCTAssertNil(Sibionics2AuthenticationAddress.address(from: Data(repeating: 0, count: 6)))
    }

    func testFactorySensitivityUsesJugglucoVariantFallbackWhenFactoryCodeIsMissing() {
        // JugglucoNG retries the Sibionics 2 variant token after invalid QR and BLE codes.
        XCTAssertEqual(
            Sibionics2FactorySensitivity.effectiveSensitivity(advertisedName: nil),
            1.44,
            accuracy: 0.00001
        )
        XCTAssertEqual(
            Sibionics2FactorySensitivity.effectiveSensitivity(
                advertisedName: "P225XXXX", probeCode: "invalid"
            ),
            1.44,
            accuracy: 0.00001
        )
        XCTAssertEqual(
            Sibionics2FactorySensitivity.effectiveSensitivity(advertisedName: "P2251500"),
            1.5,
            accuracy: 0.00001
        )
    }

    func testResetPacketMatchesJugglucoV120MaintenancePacket() {
        let packet = codec.buildResetPacket()
        let plaintext = [UInt8](codec.decrypt(packet))

        XCTAssertEqual(plaintext, [0x03, 0x10, 0x00, 0xED])
        XCTAssertEqual(plaintext.reduce(UInt8(0), { $0 &+ $1 }), 0)
    }

    func testSibionics2PollIntervalAndCalibrationModePersistPerPeripheral() throws {
        let suiteName = "Sibionics2ConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(Sibionics2Configuration.pollInterval(for: "sensor-A", userDefaults: defaults), .oneMinute)
        XCTAssertEqual(Sibionics2PollInterval.allCases.map(\.rawValue), [1, 5, 10, 15])
        for interval in Sibionics2PollInterval.allCases {
            XCTAssertTrue(Sibionics2Configuration.setPollInterval(interval, for: "sensor-A", userDefaults: defaults))
            XCTAssertEqual(Sibionics2Configuration.pollInterval(for: "sensor-A", userDefaults: defaults), interval)
        }
        XCTAssertTrue(Sibionics2Configuration.setCalibrationMode(.jugglucoNG, for: "sensor-A", userDefaults: defaults))
        XCTAssertEqual(Sibionics2Configuration.pollInterval(for: "sensor-A", userDefaults: defaults), .fifteenMinutes)
        XCTAssertEqual(Sibionics2Configuration.calibrationMode(for: "sensor-A", userDefaults: defaults), .jugglucoNG)
        XCTAssertEqual(Sibionics2Configuration.pollInterval(for: "sensor-B", userDefaults: defaults), .oneMinute)
        XCTAssertEqual(Sibionics2Configuration.calibrationMode(for: "sensor-B", userDefaults: defaults), .xDripPlus)
        XCTAssertEqual(Sibionics2CalibrationMode.xDripPlus.calibrationHistoryDays, 4)
        XCTAssertEqual(Sibionics2CalibrationMode.jugglucoNG.calibrationHistoryDays, 23)
        Sibionics2Configuration.requestReset(for: "sensor-A", userDefaults: defaults)
        XCTAssertTrue(Sibionics2Configuration.resetRequested(for: "sensor-A", userDefaults: defaults))
        XCTAssertFalse(Sibionics2Configuration.resetRequested(for: "sensor-B", userDefaults: defaults))
        XCTAssertTrue(Sibionics2Configuration.autoResetEnabled(for: "sensor-A", userDefaults: defaults))
        XCTAssertTrue(Sibionics2Configuration.setAutoResetEnabled(false, for: "sensor-A", userDefaults: defaults))
        XCTAssertFalse(Sibionics2Configuration.autoResetEnabled(for: "sensor-A", userDefaults: defaults))
        XCTAssertTrue(Sibionics2Configuration.autoResetEnabled(for: "sensor-B", userDefaults: defaults))

        let readingTime = Date(timeIntervalSince1970: 1_800_000_000)
        Sibionics2Configuration.recordReading(
            Sibionics2AutoResetReading(glucoseMgDl: 110, timeStamp: readingTime),
            for: "sensor-A", userDefaults: defaults
        )
        Sibionics2Configuration.recordReading(
            Sibionics2AutoResetReading(glucoseMgDl: 112, timeStamp: readingTime.addingTimeInterval(60)),
            for: "sensor-A", userDefaults: defaults
        )
        XCTAssertEqual(Sibionics2Configuration.previousReading(for: "sensor-A", userDefaults: defaults)?.glucoseMgDl, 110)
        XCTAssertEqual(Sibionics2Configuration.latestReading(for: "sensor-A", userDefaults: defaults)?.glucoseMgDl, 112)
    }

    func testJugglucoCalibrationUsesOffsetThenBoundedWeightedRegression() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let single = [Sibionics2CalibrationAnchor(sensorMgDl: 150, fingerstickMgDl: 165, timeStamp: time)]
        XCTAssertEqual(
            Sibionics2JugglucoCalibrationMath.calibratedValue(180, at: time.addingTimeInterval(60), anchors: single),
            195,
            accuracy: 0.00001
        )

        let anchors = [
            Sibionics2CalibrationAnchor(sensorMgDl: 100, fingerstickMgDl: 110, timeStamp: time),
            Sibionics2CalibrationAnchor(sensorMgDl: 200, fingerstickMgDl: 220, timeStamp: time.addingTimeInterval(3600)),
        ]
        XCTAssertEqual(
            Sibionics2JugglucoCalibrationMath.calibratedValue(200, at: time.addingTimeInterval(7200), anchors: anchors),
            220,
            accuracy: 0.00001
        )
    }

    func testAutomaticSensorResetWaitsForStableReadingAndHonorsDisableSetting() {
        XCTAssertEqual(Sibionics2SensorProfile.expectedLifeInDays, 23)
        XCTAssertEqual(Sibionics2AutoResetPolicy.expectedSensorLifeDays, 23)
        XCTAssertEqual(Sibionics2CalibrationMode.jugglucoNG.calibrationHistoryDays, 23)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // 22 days minus four hours after activation.
        let resetWindowStartsAt = start.addingTimeInterval(1_886_400)
        let prior = Sibionics2AutoResetReading(glucoseMgDl: 119, timeStamp: resetWindowStartsAt.addingTimeInterval(-60))
        let current = Sibionics2AutoResetReading(glucoseMgDl: 120, timeStamp: resetWindowStartsAt)
        let earlier = Sibionics2AutoResetReading(glucoseMgDl: 118, timeStamp: resetWindowStartsAt.addingTimeInterval(-120))

        XCTAssertFalse(Sibionics2AutoResetPolicy.evaluate(
            now: prior.timeStamp, sensorStartDate: start, enabled: true, previous: earlier, latest: prior
        ).resetNow)
        XCTAssertTrue(Sibionics2AutoResetPolicy.evaluate(
            now: resetWindowStartsAt, sensorStartDate: start, enabled: true, previous: prior, latest: current
        ).resetNow)
        XCTAssertFalse(Sibionics2AutoResetPolicy.evaluate(
            now: resetWindowStartsAt, sensorStartDate: start, enabled: false, previous: prior, latest: current
        ).resetNow)
        XCTAssertFalse(Sibionics2AutoResetPolicy.evaluate(
            now: resetWindowStartsAt, sensorStartDate: start, enabled: true,
            previous: Sibionics2AutoResetReading(glucoseMgDl: 200, timeStamp: resetWindowStartsAt.addingTimeInterval(-60)),
            latest: Sibionics2AutoResetReading(glucoseMgDl: 205, timeStamp: resetWindowStartsAt)
        ).resetNow)
        let forcedResetTime = start.addingTimeInterval(
            Sibionics2AutoResetPolicy.expectedSensorLife - Sibionics2AutoResetPolicy.preExpiryGuard
        )
        let forced = Sibionics2AutoResetPolicy.evaluate(
            now: forcedResetTime,
            sensorStartDate: start, enabled: true, previous: nil, latest: nil
        )
        XCTAssertTrue(forced.resetNow)
        XCTAssertTrue(forced.forced)
        let forcedWhenDisabled = Sibionics2AutoResetPolicy.evaluate(
            now: forcedResetTime,
            sensorStartDate: start, enabled: false, previous: nil, latest: nil
        )
        XCTAssertTrue(forcedWhenDisabled.resetNow)
        XCTAssertTrue(forcedWhenDisabled.forced)
    }
}
