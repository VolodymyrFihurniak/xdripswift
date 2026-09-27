//
//  Sibionics2ProtocolTests.swift
//  xdripTests
//

import CoreBluetooth
import XCTest
@testable import xdrip

final class Sibionics2ProtocolTests: XCTestCase {
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

    func testSensorCaptureCommandVectors() {
        let sessionKey = Data("GKSHGDU0TYA456G4".utf8)
        XCTAssertEqual(
            [UInt8](codec.buildAuthPacket(
                macAddress: [0xC7, 0x71, 0xB0, 0xD1, 0x5B, 0x32],
                sessionKey: sessionKey
            )),
            [0x3E, 0xF6, 0x6F, 0xEB, 0x53, 0xA2, 0xE8, 0xAD, 0x7A, 0xC6, 0xCD, 0x50,
             0x47, 0xF0, 0x42, 0xD9, 0xB2, 0xE7, 0xBD, 0x0D, 0x16, 0xB1, 0x57, 0xF1,
             0x4A, 0x51]
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
        for name in [nil, "", "P12ABCD", "P123", "P1234567890123456", "P123_#ABCD",
                     "GS3-12345", "GKS2-ABCDE", "SiBionics CGM", "SiBionics 2",
                     "Sijoy CGM", "GS1ECO", "Dexcom G7"] as [String?] {
            XCTAssertFalse(Sibionics2DeviceIdentity.isSibionics2(name: name), "Unexpected match: \(name ?? "nil")")
        }
    }
}
