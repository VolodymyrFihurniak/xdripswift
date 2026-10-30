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

    func testExplicitDeviceVariantsUseTheirOwnV120SessionKeys() {
        XCTAssertEqual(SibionicsDeviceVariant.sibionics1.rawValue, 1)
        XCTAssertEqual(SibionicsDeviceVariant.sibionics2.rawValue, 2)
        XCTAssertEqual(codec.deriveSessionKey(variant: .sibionics1), Data("THE544U0TYITE461".utf8))
        XCTAssertEqual(codec.deriveSessionKey(variant: .sibionics2), codec.deriveSessionKey())
    }

    func testAuthenticationKeyGroupsLeadWithTheConfiguredVariant() {
        XCTAssertEqual(codec.deriveSessionKey(group: .eco), Data("GKSHGDU0TYA456G4".utf8))
        XCTAssertEqual(codec.deriveSessionKey(group: .sijoy), Data("THE544U0TYITE461".utf8))
        XCTAssertEqual(codec.deriveSessionKey(group: .hematonix), Data("LQSS54U0RURUA99J".utf8))
        XCTAssertEqual(Sibionics2KeyGroup.authenticationOrder(for: .sibionics2), [.eco, .sijoy, .hematonix])
        XCTAssertEqual(Sibionics2KeyGroup.authenticationOrder(for: .sibionics1), [.sijoy, .hematonix, .eco])
        for variant in [SibionicsDeviceVariant.sibionics1, .sibionics2] {
            XCTAssertEqual(Set(Sibionics2KeyGroup.authenticationOrder(for: variant)), Set(Sibionics2KeyGroup.allCases))
        }
    }

    func testV120ParserRecognizesPlainAuthenticationRequiredMarker() {
        guard case .authenticationRequired = codec.parseV120(Data([0x23, 0xF7, 0x6F, 0xD9, 0xF4])) else {
            return XCTFail("Expected the plain V120 authentication marker")
        }
    }

    func testHandshakeAnswersRepeatedDataRequestAndEarlyStreamingReady() {
        let now = Date(timeIntervalSince1970: 0x6553F100)
        var repeated = Sibionics2Handshake(macAddress: [UInt8](repeating: 0, count: 6),
                                           sessionKey: Data("GKSHGDU0TYA456G4".utf8),
                                           lastDeliveredIndex: 0x1234)
        _ = repeated.start(at: now)
        XCTAssertTrue(repeated.isAwaitingAuthentication)
        _ = repeated.receive(.authenticationAccepted, at: now)
        XCTAssertFalse(repeated.isAwaitingAuthentication)
        assertCommand(repeated.receive(.dataRequested, at: now), equals: [0x06, 0x08, 0x34, 0x12, 0, 0])
        assertCommand(repeated.receive(.dataRequested, at: now), equals: [0x06, 0x08, 0x34, 0x12, 0, 0])
        XCTAssertNil(repeated.receive(.streamingReady, at: now))
        XCTAssertTrue(repeated.isStreaming)
        XCTAssertNil(repeated.receive(.dataRequested, at: now))

        var earlyReady = Sibionics2Handshake(macAddress: [UInt8](repeating: 0, count: 6),
                                             sessionKey: Data("GKSHGDU0TYA456G4".utf8),
                                             lastDeliveredIndex: nil)
        _ = earlyReady.start(at: now)
        XCTAssertNil(earlyReady.receive(.streamingReady, at: now), "Ready before auth must be ignored")
        XCTAssertFalse(earlyReady.isStreaming)
        _ = earlyReady.receive(.authenticationAccepted, at: now)
        XCTAssertNil(earlyReady.receive(.streamingReady, at: now))
        XCTAssertTrue(earlyReady.isStreaming)
    }

    func testChineseRequestIsPlaintextWithLittleEndianCursorAndReversedMAC() {
        let chinese = Sibionics1ChineseProtocolCodec()
        let request = chinese.buildDataRequestPacket(lastIndex: 0x1234, macAddress: testBluetoothAddressBytes)
        XCTAssertEqual([UInt8](request), [
            0xAA, 0x55, 0x07, 0x34, 0x12, 0x01, 0, 0, 0, 0, 0x02,
            0, 0, 0, 0, 0, 0, 0, 0, 0xB1
        ])
        XCTAssertEqual(request.reduce(UInt8(0), { $0 &+ $1 }), 0)
        let initial = [UInt8](chinese.buildDataRequestPacket(lastIndex: 0, macAddress: []))
        XCTAssertEqual(initial[3], 1, "Chinese cursors start at one")
        XCTAssertEqual(initial[4], 0)
        XCTAssertEqual(Array(initial[5..<11]), [UInt8](repeating: 0, count: 6))
        XCTAssertEqual(initial.reduce(UInt8(0), { $0 &+ $1 }), 0)
    }

    func testChineseResponseDecodesBigEndianMeasurementsAndRelativeHistoryTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Seven big-endian words per entry; status is not a V120 trend byte.
        let frame = chineseFrame([
            0xAA, 0x55, 0x09, 0x02,
            0x12, 0x34, 0x01, 0x25, 0x01, 0xF4, 0x00, 0x53, 0x00, 0x20, 0x00, 0x02, 0x00, 0x0A,
            0x12, 0x36, 0x01, 0x26, 0x01, 0xF5, 0x00, 0x54, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x05
        ])
        guard case .readings(let readings) = Sibionics1ChineseProtocolCodec().parse(frame, at: now) else {
            return XCTFail("Expected two Chinese readings")
        }
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].index, 0x1234)
        XCTAssertEqual(readings[0].temperatureC, 29.3)
        XCTAssertEqual(readings[0].impedance, 500)
        XCTAssertEqual(readings[0].rawMmol, 8.3)
        XCTAssertEqual(readings[0].trend, .notDetermined)
        XCTAssertEqual(readings[0].reindex, 2)
        XCTAssertEqual(readings[0].eventTime, now.addingTimeInterval(-110))
        XCTAssertEqual(readings[1].index, 0x1236)
        XCTAssertEqual(readings[1].reindex, 0)
        XCTAssertEqual(readings[1].eventTime, now, "Positive firmware offsets cannot move readings into the future")
    }

    func testChineseParserDistinguishesChecksummedEchoAndExactV120Marker() {
        let chinese = Sibionics1ChineseProtocolCodec()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = chinese.buildDataRequestPacket(lastIndex: 1, macAddress: testBluetoothAddressBytes)
        guard case .requestEcho = chinese.parse(request, at: now) else {
            return XCTFail("A request echo must not confirm Chinese data")
        }
        let marker = Data([0x23, 0xF7, 0x6F, 0xD9, 0xF4])
        XCTAssertEqual(codec.decrypt(marker), Data([0x04, 0, 0, 0, 0xFC]))
        guard case .v120AuthRequired = chinese.parse(marker, at: now) else {
            return XCTFail("Expected encrypted V120 marker")
        }
        guard case .readings(let readings) = chinese.parse(chineseFrame([0xAA, 0x55, 0x09, 0]), at: now) else {
            return XCTFail("A valid zero-entry response is a Chinese response")
        }
        XCTAssertTrue(readings.isEmpty)
    }

    func testChineseParserRejectsCorruptTruncatedAndExtraPayloads() {
        let chinese = Sibionics1ChineseProtocolCodec()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = chineseFrame([0xAA, 0x55, 0x09, 1] + [UInt8](repeating: 0, count: 14))
        var corrupt = response
        corrupt[5] ^= 1
        let echo = chinese.buildDataRequestPacket(lastIndex: 1, macAddress: [])
        var corruptEcho = echo
        corruptEcho[5] ^= 1
        let malformed = [
            Data(), Data([0xAA, 0x55, 0x09]), corrupt, Data(response.dropLast()),
            chineseFrame([0xAA, 0x55, 0x09, 2] + [UInt8](repeating: 0, count: 14)),
            chineseFrame([0xAA, 0x55, 0x09, 0, 0]),
            chineseFrame([0xAA, 0x55, 0x08, 0]),
            corruptEcho, Data(echo.dropLast()), Data([0xAA, 0x55, 0x07]),
            Data([0x23, 0xF7, 0x6F, 0xD9, 0xF4, 0]), Data([0x23, 0xF7, 0x6F, 0xD9, 0xF5])
        ]
        for frame in malformed {
            guard case .malformed = chinese.parse(frame, at: now) else {
                XCTFail("Accepted malformed frame: \(frame as NSData)")
                continue
            }
        }
    }

    func testConfirmedProtocolModePersistsPerPeripheralUUIDAndCanBeCleared() throws {
        let suiteName = "Sibionics1ProtocolMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = UUID().uuidString
        let other = UUID().uuidString
        XCTAssertNil(Sibionics2Configuration.protocolMode(for: identifier, userDefaults: defaults))
        XCTAssertTrue(Sibionics2Configuration.setProtocolMode(.chinese, for: identifier, userDefaults: defaults))
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(Sibionics2Configuration.protocolMode(for: identifier.lowercased(), userDefaults: reloaded), .chinese)
        XCTAssertNil(Sibionics2Configuration.protocolMode(for: other, userDefaults: reloaded))
        XCTAssertTrue(Sibionics2Configuration.setProtocolMode(.v120, for: identifier, userDefaults: reloaded))
        XCTAssertEqual(Sibionics2Configuration.protocolMode(for: identifier, userDefaults: defaults), .v120)
        XCTAssertFalse(Sibionics2Configuration.setProtocolMode(.chinese, for: "  ", userDefaults: defaults))
        XCTAssertTrue(Sibionics2Configuration.setProtocolMode(nil, for: identifier, userDefaults: defaults))
        XCTAssertNil(Sibionics2Configuration.protocolMode(for: identifier, userDefaults: defaults))
        defaults.set(99, forKey: "sibionics2.configuration.protocolMode." + identifier.lowercased())
        XCTAssertNil(Sibionics2Configuration.protocolMode(for: identifier, userDefaults: defaults))
    }

    private func chineseFrame(_ payload: [UInt8]) -> Data {
        Data(payload + [0 &- payload.reduce(UInt8(0), { $0 &+ $1 })])
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
        // The 26-byte auth packet needs an acknowledged (long) write on a 20-byte ATT payload.
        XCTAssertEqual(CGMSibionics2Transmitter.writeType(
            for: [.write, .writeWithoutResponse]), .withResponse)
        XCTAssertNil(CGMSibionics2Transmitter.writeType(for: [.read]))
    }

    func testOnlySibionics2AdvertisementNamesMatch() {
        XCTAssertTrue(Sibionics2DeviceIdentity.isSibionics2(name: "P123ABCD"))
        XCTAssertTrue(Sibionics2DeviceIdentity.isSibionics2(name: "p123-ABCD_56"))
        XCTAssertTrue(Sibionics2DeviceIdentity.isSibionics2(name: "P123456789012345"))
        for name in [nil, "", "P12ABCD", "P123", "P1234567890123456", "P12345678901234567", "P123_#ABCD",
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

    func testAuthenticationAddressCandidatesComeFromAdvertisementAndDeviceInformation() {
        // Company identifier followed by the address in either byte order.
        let manufacturerData = Data([0x4C, 0x05, 0xC7, 0x71, 0xB0, 0xD1, 0x5B, 0x32])
        XCTAssertEqual(Sibionics2AuthenticationAddress.advertisementCandidates(manufacturerData: manufacturerData),
                       ["C7:71:B0:D1:5B:32", "32:5B:D1:B0:71:C7"])
        XCTAssertEqual(Sibionics2AuthenticationAddress.advertisementCandidates(
            manufacturerData: Data([0x4C, 0x05, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xAA])
        ), ["01:02:03:04:05:06", "06:05:04:03:02:01", "02:03:04:05:06:AA", "AA:06:05:04:03:02"])
        XCTAssertTrue(Sibionics2AuthenticationAddress.advertisementCandidates(manufacturerData: nil).isEmpty)
        XCTAssertTrue(Sibionics2AuthenticationAddress.advertisementCandidates(
            manufacturerData: Data([0x4C, 0x05, 0x01])
        ).isEmpty)
        XCTAssertTrue(Sibionics2AuthenticationAddress.advertisementCandidates(
            manufacturerData: Data([0x4C, 0x05] + [UInt8](repeating: 0xFF, count: 6))
        ).isEmpty, "An all-FF field is padding, not an address")

        // System ID: device bytes, FFFE, then OUI, all least significant byte first.
        XCTAssertEqual(Sibionics2AuthenticationAddress.systemIDAddress(
            Data([0x32, 0x5B, 0xD1, 0xFE, 0xFF, 0xB0, 0x71, 0xC7])
        ), "C7:71:B0:D1:5B:32")
        XCTAssertNil(Sibionics2AuthenticationAddress.systemIDAddress(Data([1, 2, 3, 4, 5, 6, 7, 8])))
        // Captured from P225044UHA: 2A25 = 32 5B D1 B0 71 C7 for address C7:71:B0:D1:5B:32.
        XCTAssertEqual(Sibionics2AuthenticationAddress.serialNumberAddresses(
            Data([0x32, 0x5B, 0xD1, 0xB0, 0x71, 0xC7])
        ), ["C7:71:B0:D1:5B:32", "32:5B:D1:B0:71:C7"])
        XCTAssertEqual(Sibionics2AuthenticationAddress.serialNumberAddresses(Data("C771B0D15B32".utf8)),
                       ["C7:71:B0:D1:5B:32"])
        XCTAssertTrue(Sibionics2AuthenticationAddress.serialNumberAddresses(Data("P123ABCD".utf8)).isEmpty)
    }

    func testAuthenticationCandidatesTryDetectedThenUnverifiedThenZero() throws {
        let suiteName = "Sibionics2AuthAddress.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = "DE1815CA-590A-1AAF-9C98-34082E80A191"

        XCTAssertEqual(Sibionics2AuthenticationAddress.authenticationCandidates(for: identifier, userDefaults: defaults),
                       [nil])
        XCTAssertTrue(Sibionics2AuthenticationAddress.addCandidates(
            ["C7:71:B0:D1:5B:32", "invalid", "32:5B:D1:B0:71:C7"], for: identifier, userDefaults: defaults))
        XCTAssertFalse(Sibionics2AuthenticationAddress.addCandidates(
            ["c771b0d15b32"], for: identifier, userDefaults: defaults), "Duplicates are not stored twice")
        XCTAssertTrue(Sibionics2AuthenticationAddress.setDetected("32:5B:D1:B0:71:C7", for: identifier, userDefaults: defaults))
        XCTAssertEqual(Sibionics2AuthenticationAddress.authenticationCandidates(for: identifier, userDefaults: defaults),
                       ["32:5B:D1:B0:71:C7", "C7:71:B0:D1:5B:32", nil])
        XCTAssertEqual(Sibionics2AuthenticationAddress.macBytes(address: "C7:71:B0:D1:5B:32"),
                       [0xC7, 0x71, 0xB0, 0xD1, 0x5B, 0x32])
        XCTAssertEqual(Sibionics2AuthenticationAddress.macBytes(address: nil), [UInt8](repeating: 0, count: 6))

        XCTAssertTrue(Sibionics2AuthenticationAddress.setOverride(testBluetoothAddress, for: identifier, userDefaults: defaults))
        XCTAssertEqual(Sibionics2AuthenticationAddress.authenticationCandidates(for: identifier, userDefaults: defaults),
                       [testBluetoothAddress], "A manual address is never rotated away")

        Sibionics2AuthenticationAddress.clearAutomatic(for: identifier, userDefaults: defaults)
        XCTAssertNil(Sibionics2AuthenticationAddress.detected(for: identifier, userDefaults: defaults))
        XCTAssertTrue(Sibionics2AuthenticationAddress.candidates(for: identifier, userDefaults: defaults).isEmpty)
        XCTAssertEqual(Sibionics2AuthenticationAddress.override(for: identifier, userDefaults: defaults), testBluetoothAddress)
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
