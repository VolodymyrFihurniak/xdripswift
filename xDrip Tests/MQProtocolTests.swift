//
//  MQProtocolTests.swift
//  xdripTests
//
//  Expected values come from running the unchanged JugglucoNG Kotlin (`drivers/mq`: MQCrc16, MQParser,
//  MQResetCommand, MQVendorIdentity, MQProfile) on the JVM: the same frames, serials and flags were fed
//  to the Kotlin and every line it printed is checked here. Some frames are real captures that
//  JugglucoNG's notes carry (packet 237 and 14 of a Protocol02 transmitter, whose CRC bytes are not
//  CRC16-Modbus, the session markers and the reset the official app sends). Never compared with a
//  real sensor.
//

import CoreBluetooth
import XCTest
@testable import xdrip

/// Shared by the MQ test files: parsing of the pipe separated vector lines and bit exact comparison.
enum MQVectorSupport {

    static func fields(_ line: String) -> [String] {
        return line.components(separatedBy: "|")
    }

    static func bytes(_ hex: String) -> [UInt8] {
        var result = [UInt8]()
        let characters = Array(hex)
        var index = 0
        while index + 1 < characters.count {
            result.append(UInt8(String(characters[index...index + 1]), radix: 16) ?? 0)
            index += 2
        }
        return result
    }

    static func hex(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func hex4(_ value: Int) -> String {
        return String(format: "%04lX", value)
    }

    /// The Kotlin printer wrote a Double as its 16 digit bit pattern.
    static func d(_ hexBits: String) -> Double {
        return Double(bitPattern: UInt64(hexBits, radix: 16) ?? 0)
    }

    /// The Kotlin printer wrote a Float as its 8 digit bit pattern.
    static func f(_ hexBits: String) -> Float {
        return Float(bitPattern: UInt32(hexBits, radix: 16) ?? 0)
    }

    static func bits(_ value: Double) -> String {
        return String(format: "%016llX", value.bitPattern)
    }

    static func bits(_ value: Float) -> String {
        return String(format: "%08X", value.bitPattern)
    }

    static func bits(_ value: Float?) -> String {
        return value.map { bits($0) } ?? "nil"
    }

    static func optionalInt(_ text: String) -> Int? {
        return text == "nil" ? nil : Int(text)
    }

    static func optionalInt64(_ text: String) -> Int64? {
        return text == "nil" ? nil : Int64(text)
    }

    static func optionalText(_ text: String) -> String? {
        return text == "nil" ? nil : text
    }

    static func flag(_ value: Bool) -> String {
        return value ? "true" : "false"
    }
}

final class MQProtocolTests: XCTestCase {

    private typealias V = MQVectorSupport

    // MARK: - CRC

    func testCrcVectors() {
        for line in MQProtocolVectors.crc {
            let f = V.fields(line)
            let data = V.bytes(f[1])
            XCTAssertEqual(V.hex4(MQCrc16.compute(data)), f[2], line)
            if data.count >= 2 {
                XCTAssertEqual(V.hex4(MQCrc16.compute(data, offset: 0, length: data.count - 2)), f[3], line)
                let observed = (Int(data[data.count - 2]) << 8) | Int(data[data.count - 1])
                XCTAssertEqual(V.hex4(observed), f[4], line)
            } else {
                XCTAssertEqual(f[3], "nil", line)
                XCTAssertEqual(f[4], "nil", line)
            }
            XCTAssertEqual(V.flag(MQCrc16.verify(data)), f[5], line)
        }
    }

    func testCrcOfTheStandardCheckString() {
        // the well known CRC16-Modbus check value of "123456789"
        XCTAssertEqual(MQCrc16.compute(Array("123456789".utf8)), 0x4B37)
    }

    func testCrcOffsetAndLength() {
        for line in MQProtocolVectors.crcOffset {
            let f = V.fields(line)
            let data = V.bytes(f[1])
            XCTAssertEqual(V.hex4(MQCrc16.compute(data, offset: Int(f[2]) ?? 0, length: Int(f[3]) ?? 0)), f[4], line)
        }
    }

    func testCrcRangeOutsideTheDataIsClampedInsteadOfTrapping() {
        let data: [UInt8] = [1, 2, 3]
        XCTAssertEqual(MQCrc16.compute(data, offset: 5, length: 2), 0xFFFF)
        XCTAssertEqual(MQCrc16.compute(data, offset: 1, length: 99), MQCrc16.compute(Array(data[1...])))
        XCTAssertEqual(MQCrc16.compute(data, offset: -4, length: 2), MQCrc16.compute(Array(data[0..<2])))
        XCTAssertEqual(MQCrc16.compute(data, offset: 0, length: -1), 0xFFFF)
    }

    func testStampVectors() {
        for line in MQProtocolVectors.stamp {
            let f = V.fields(line)
            let stamped = MQCrc16.stamp(V.bytes(f[1]), xorOut: Int(f[2]) ?? 0)
            XCTAssertEqual(V.hex(stamped), f[3], line)
            XCTAssertEqual(V.flag(MQCrc16.verify(stamped)), f[4], line)
        }
    }

    func testStampOfATooShortFrameLeavesItAlone() {
        XCTAssertEqual(MQCrc16.stamp([]), [])
        XCTAssertEqual(MQCrc16.stamp([0x12]), [0x12])
    }

    // MARK: - parser

    func testParseVectors() {
        for line in MQProtocolVectors.parse {
            let f = V.fields(line)
            let frame = MQParser.parse(V.bytes(f[1]))
            if f[2] == "nil" {
                XCTAssertNil(frame, line)
                continue
            }
            guard let parsed = frame else {
                XCTFail("expected a frame for \(line)")
                continue
            }
            XCTAssertEqual(String(format: "%02X", parsed.cmd), f[2], line)
            XCTAssertEqual(parsed.len, Int(f[3]), line)
            XCTAssertEqual(V.hex(parsed.payload), f[4], line)
            XCTAssertEqual(V.hex(parsed.raw), f[5], line)
            XCTAssertEqual(V.flag(parsed.crcValid), f[6], line)
        }
    }

    func testParseOfNothingIsNil() {
        XCTAssertNil(MQParser.parse(nil as [UInt8]?))
        XCTAssertNil(MQParser.parse(data: Data()))
    }

    func testParseAcceptsData() throws {
        let frame = try XCTUnwrap(MQParser.parse(data: Data(V.bytes("5AA5040640ED005700321161"))))
        XCTAssertEqual(frame.cmd, MQConstants.cmdNotifyBgData)
        XCTAssertEqual(frame.cmdUnsigned, 4)
    }

    func testTheLargestFrame() throws {
        // a frame with the longest payload the length byte allows
        var frame = [UInt8](repeating: 0, count: 6 + 255)
        frame[0] = 0x5A
        frame[1] = 0xA5
        frame[2] = 0x04
        frame[3] = 0xFF
        for index in 0..<255 {
            frame[4 + index] = UInt8(truncatingIfNeeded: index * 7)
        }
        frame = MQCrc16.stamp(frame)
        let parsed = try XCTUnwrap(MQParser.parse(frame))
        let records = MQParser.parseBgRecords(parsed)
        let last = try XCTUnwrap(records.last)
        let f = V.fields(try XCTUnwrap(MQProtocolVectors.parse255.first))
        XCTAssertEqual(parsed.len, Int(f[1]))
        XCTAssertEqual(parsed.raw.count, Int(f[2]))
        XCTAssertEqual(V.flag(parsed.crcValid), f[3])
        XCTAssertEqual(V.hex4(MQCrc16.compute(frame, offset: 0, length: frame.count - 2)), f[4])
        XCTAssertEqual(records.count, Int(f[5]))
        XCTAssertEqual(last.packetIndex, Int(f[6]))
        XCTAssertEqual(last.sampleCurrent, Int(f[7]))
        XCTAssertEqual(last.batteryRaw, Int(f[8]))
        XCTAssertEqual(V.hex(last.recordBytes), f[9])
    }

    func testBgRecordVectors() {
        for line in MQProtocolVectors.bgRecords {
            let f = V.fields(line)
            guard let frame = MQParser.parse(V.bytes(f[1])) else {
                XCTAssertEqual(f[2], "nil", line)
                continue
            }
            let records = MQParser.parseBgRecords(frame)
            XCTAssertEqual(records.count, Int(f[2]), line)
            let text = records.map {
                "\($0.indexInPacket):\($0.marker):\($0.packetIndex):\($0.sampleCurrent):\($0.batteryRaw):\(V.hex($0.recordBytes))"
            }.joined(separator: ";")
            XCTAssertEqual(text.isEmpty ? "none" : text, f[3], line)
        }
    }

    func testTheCapturedPacketDecodes() throws {
        // packet 237 of a Protocol02 transmitter: current 87, raw battery byte 0x32
        let frame = try XCTUnwrap(MQParser.parse(V.bytes("5AA5040640ED005700321161")))
        let record = try XCTUnwrap(MQParser.parseBgRecords(frame).first)
        XCTAssertEqual(record.marker, MQConstants.bgRecordMarker)
        XCTAssertEqual(record.packetIndex, 237)
        XCTAssertEqual(record.sampleCurrent, 87)
        XCTAssertEqual(record.batteryRaw, 0x32)
        XCTAssertFalse(frame.crcValid)
    }

    func testRecordsOfAnotherCommandAreIgnored() throws {
        let heartbeat = try XCTUnwrap(MQParser.parse(V.bytes("5AA5010640ED005700320000")))
        XCTAssertEqual(MQParser.parseBgRecords(heartbeat), [])
    }

    // MARK: - builders and captured acknowledgements

    func testBuilderVectors() {
        for line in MQProtocolVectors.build {
            let f = V.fields(line)
            let xor = Int(f[2]) ?? 0
            let built: [UInt8]
            switch f[1] {
            case "confirm01": built = MQParser.buildConfirm(cmd: MQConstants.cmdNotifyWorking, crcXorOut: xor)
            case "bgData": built = MQParser.buildConfirmBgData(crcXorOut: xor)
            case "withInit": built = MQParser.buildConfirmWithInit(crcXorOut: xor)
            case "withoutInit": built = MQParser.buildConfirmWithoutInit(crcXorOut: xor)
            case "reset": built = MQParser.buildConfirmReset(crcXorOut: xor)
            default:
                XCTFail("unknown builder \(f[1])")
                continue
            }
            XCTAssertEqual(V.hex(built), f[3], line)
        }
    }

    func testTheCapturedAcknowledgementsAreNotTheComputedOnes() {
        // JugglucoNG sends these captured bytes (the transmitter left a BEGIN_WORK loop only after
        // `withInit`); the computed Protocol01 frames differ, which is why the transmitter uses the
        // captured ones and why the builders are not used for acknowledgements.
        XCTAssertEqual(V.hex(MQAckFrames.withInit), "5AA50801004A6F")
        XCTAssertEqual(V.hex(MQAckFrames.bgData), "5AA5020100497F")
        XCTAssertEqual(V.hex(MQAckFrames.withoutInit), "5AA503010050AF")
        XCTAssertNotEqual(MQAckFrames.withInit, MQParser.buildConfirmWithInit())
        XCTAssertNotEqual(MQAckFrames.bgData, MQParser.buildConfirmBgData())
        XCTAssertNotEqual(MQAckFrames.withoutInit, MQParser.buildConfirmWithoutInit())
        // every acknowledgement is a well formed frame with a zero payload byte
        for ack in [MQAckFrames.withInit, MQAckFrames.bgData, MQAckFrames.withoutInit] {
            let frame = MQParser.parse(ack)
            XCTAssertEqual(frame?.len, 1)
            XCTAssertEqual(frame?.payload, [0])
        }
        XCTAssertEqual(MQParser.parse(MQAckFrames.withInit)?.cmd, MQConstants.cmdWriteConfirmWithInit)
        XCTAssertEqual(MQParser.parse(MQAckFrames.bgData)?.cmd, MQConstants.cmdWriteBgDataConfirm)
        XCTAssertEqual(MQParser.parse(MQAckFrames.withoutInit)?.cmd, MQConstants.cmdWriteConfirmWithoutInit)
    }

    // MARK: - reset command

    func testProtocol02MarkerVectors() {
        for line in MQProtocolVectors.markers {
            let f = V.fields(line)
            guard let frame = MQParser.parse(V.bytes(f[1])) else {
                XCTAssertEqual(f[2], "nil", line)
                continue
            }
            XCTAssertEqual(V.flag(MQResetCommand.isProtocol02Marker(frame)), f[2], line)
        }
    }

    func testResetCommandVectors() {
        for line in MQProtocolVectors.resetCommands {
            let f = V.fields(line)
            let command = MQResetCommand.build(protocolType: Int(f[1]) ?? 0, observedProtocol02: f[2] == "true")
            XCTAssertEqual(V.hex(command), f[3], line)
        }
    }

    // MARK: - vendor identity

    func testBleIdVectors() {
        for line in MQProtocolVectors.bleIds {
            let f = V.fields(line)
            XCTAssertEqual(MQVendorIdentity.bleId(f[1]), V.optionalText(f[2]), line)
        }
        XCTAssertNil(MQVendorIdentity.bleId(nil))
    }

    // MARK: - profile

    func testProfileMatchesTheVendorLifecycle() throws {
        let f = V.fields(try XCTUnwrap(MQProtocolVectors.profile.first))
        let profile = MQProfile.resolve(modelName: "anything", rawSerial: "W25101399")
        XCTAssertEqual(profile.familyName, f[1])
        XCTAssertEqual(profile.readingIntervalMinutes, Int(f[2]))
        XCTAssertEqual(profile.warmupMinutes, Int(f[3]))
        XCTAssertEqual(profile.ratedLifetimeDays, Int(f[4]))
        XCTAssertEqual(profile.ratedLifetimeMs(), Int64(f[5]))
        XCTAssertEqual(profile.readingIntervalMs, 180_000)
        XCTAssertEqual(MQProfile.resolve(), MQProfile.default)
    }

    // MARK: - constants (typed from the Kotlin source; the vectors above exercise them in use)

    func testNordicUartLayout() {
        XCTAssertEqual(MQConstants.serviceUUID, CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e"))
        XCTAssertEqual(MQConstants.txNotifyUUID, CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e"))
        XCTAssertEqual(MQConstants.rxWriteUUID, CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e"))
    }

    func testCommandBytes() {
        XCTAssertEqual(MQConstants.cmdNotifyWorking, 0x01)
        XCTAssertEqual(MQConstants.cmdWriteBgDataConfirm, 0x02)
        XCTAssertEqual(MQConstants.cmdWriteConfirmWithoutInit, 0x03)
        XCTAssertEqual(MQConstants.cmdNotifyBgData, 0x04)
        XCTAssertEqual(MQConstants.cmdNotifyBgComplete, 0x05)
        XCTAssertEqual(MQConstants.cmdNotifyBeginWork, 0x06)
        XCTAssertEqual(MQConstants.cmdWriteConfirmWithInit, 0x08)
        XCTAssertEqual(MQConstants.cmdWriteConfirmReset, 0x11)
    }

    // MARK: - device names

    func testKnownPrefixesAreCaseInsensitive() {
        XCTAssertTrue(MQDeviceName.hasKnownPrefix("Glutec CGM"))
        XCTAssertTrue(MQDeviceName.hasKnownPrefix("GLUTEC-1234"))
        XCTAssertTrue(MQDeviceName.hasKnownPrefix("glutec"))
        XCTAssertTrue(MQDeviceName.hasKnownPrefix("MQ-7"))
        XCTAssertTrue(MQDeviceName.hasKnownPrefix("ru-12"))
        XCTAssertTrue(MQDeviceName.hasKnownPrefix("  Glutec  "))
        XCTAssertFalse(MQDeviceName.hasKnownPrefix("Dexcom"))
        XCTAssertFalse(MQDeviceName.hasKnownPrefix("My Glutec"))
        XCTAssertFalse(MQDeviceName.hasKnownPrefix(""))
        XCTAssertFalse(MQDeviceName.hasKnownPrefix(nil))
    }

    func testAdvertisementMatching() {
        // the Nordic UART service alone is enough (JugglucoNG), so is a name with a known prefix,
        // and so is the printed vendor serial
        XCTAssertTrue(MQDeviceName.looksLikeMQ(name: nil, advertisesNUS: true))
        XCTAssertTrue(MQDeviceName.looksLikeMQ(name: "Glutec", advertisesNUS: false))
        XCTAssertTrue(MQDeviceName.looksLikeMQ(name: "W25101399", advertisesNUS: false))
        XCTAssertFalse(MQDeviceName.looksLikeMQ(name: "Libre", advertisesNUS: false))
        XCTAssertFalse(MQDeviceName.looksLikeMQ(name: nil, advertisesNUS: false))
        // a MAC like name is not a vendor serial
        XCTAssertFalse(MQDeviceName.looksLikeMQ(name: "CFD8EBDDF969", advertisesNUS: false))
    }
}

private enum MQProtocolVectors {

        static let crc: [String] = [
            "CRC|313233343536373839|4B37|9D73|3839|false",
            "CRC|5AA5040640ED005700321161|E4E5|1061|1161|false",
            "CRC|5AA50406400E00AC003238D5|19CD|37D5|38D5|false",
            "CRC|5AA5050100514F|6848|504F|514F|false",
            "CRC|5AA5060100917E|BC9D|50BF|917E|false",
            "CRC|5AA50801004A6F|816E|93DE|4A6F|false",
            "CRC|5AA5020100497F|BCF7|91FE|497F|false",
            "CRC|5AA503010050AF|70C0|51AF|50AF|false",
            "CRC|5AA500000000|F840|DF02|0000|false",
            "CRC|5AA5110100AA07|6D3B|540F|AA07|false",
            "CRC|00|40BF|nil|nil|false",
            "CRC||FFFF|nil|nil|false",
            "CRC|FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF|9431|7040|FFFF|false",
            "CRC|5AA5110100540F|CB7A|540F|540F|true",
            "CRC|5AA50601000000|0C70|50BF|0000|false"
        ]

        static let crcOffset: [String] = [
            "CRCOFF|00313233343536373839|1|9|4B37"
        ]

        static let stamp: [String] = [
            "STAMP|5AA506000000|0|5AA506007F01|true",
            "STAMP|5AA506000000|256|5AA506007E01|false",
            "STAMP|5AA504031020300000|0|5AA504031020306510|true",
            "STAMP|5AA504031020300000|3840|5AA504031020306A10|false",
            "STAMP|5AA504031020300000|65535|5AA504031020309AEF|false",
            "STAMP|5AA504031020300000|65792|5AA504031020306410|false",
            "STAMP|5AA51101000000|0|5AA5110100540F|true"
        ]

        static let parse: [String] = [
            "PARSE|5AA5040640ED005700321161|04|6|40ED00570032|5AA5040640ED005700321161|false",
            "PARSE|5AA50406400E00AC003238D5|04|6|400E00AC0032|5AA50406400E00AC003238D5|false",
            "PARSE|5AA5050100514F|05|1|00|5AA5050100514F|false",
            "PARSE|5AA5060100917E|06|1|00|5AA5060100917E|false",
            "PARSE|5AA50101000000|01|1|00|5AA50101000000|false",
            "PARSE|5AA5040640ED0057003211617F|04|6|40ED00570032|5AA5040640ED005700321161|false",
            "PARSE|5AA5040640ED005700321162|04|6|40ED00570032|5AA5040640ED005700321162|false",
            "PARSE|5AA5040640ED00570032|nil",
            "PARSE|5AA504|nil",
            "PARSE|5AA504|nil",
            "PARSE||nil",
            "PARSE|5BA5040640ED005700321161|nil",
            "PARSE|5A00040640ED005700321161|nil",
            "PARSE|5AA504000000|04|0||5AA504000000|false",
            "PARSE|5AA5040640ED005700321161|04|6|40ED00570032|5AA5040640ED005700321161|false"
        ]

        static let parse255: [String] = [
            "PARSE255|255|261|true|B64D|42|51393|54991|221|BAC1C8CFD6DD"
        ]

        static let bgRecords: [String] = [
            "BGREC|5AA5040640ED005700321161|1|0:64:237:87:50:40ED00570032",
            "BGREC|5AA5040C4001020304504005060708640000|2|0:64:513:1027:80:400102030450;1:64:1541:2055:100:400506070864",
            "BGREC|5AA5040D400102030450410506070864990000|2|0:64:513:1027:80:400102030450;1:65:1541:2055:100:410506070864",
            "BGREC|5AA5040C4001020304504005060708640000|2|0:64:513:1027:80:400102030450;1:64:1541:2055:100:400506070864",
            "BGREC|5AA5010640ED005700320000|0|none",
            "BGREC|5AA504000000|0|none",
            "BGREC|5AA5040540ED0057000000|0|none",
            "BGREC|5AA5040640FFFFFFFFFF0000|1|0:64:65535:65535:255:40FFFFFFFFFF"
        ]

        static let build: [String] = [
            "BUILD|confirm01|0|5AA5010100910E",
            "BUILD|bgData|0|5AA502010091FE",
            "BUILD|withInit|0|5AA508010093DE",
            "BUILD|withoutInit|0|5AA503010051AF",
            "BUILD|reset|0|5AA5110100540F",
            "BUILD|confirm01|256|5AA5010100900E",
            "BUILD|bgData|256|5AA502010090FE",
            "BUILD|withInit|256|5AA508010092DE",
            "BUILD|withoutInit|256|5AA503010050AF",
            "BUILD|reset|256|5AA5110100550F",
            "BUILD|confirm01|3840|5AA50101009E0E",
            "BUILD|bgData|3840|5AA50201009EFE",
            "BUILD|withInit|3840|5AA50801009CDE",
            "BUILD|withoutInit|3840|5AA50301005EAF",
            "BUILD|reset|3840|5AA51101005B0F"
        ]

        static let markers: [String] = [
            "MARKER|5AA5050100514F|true",
            "MARKER|5AA5060100917E|true",
            "MARKER|5AA50406400E00AC003238D5|false",
            "MARKER|5AA5050100524F|false",
            "MARKER|5AA50801004A6F|false",
            "MARKER|5AA50501000000|false",
            "MARKER|5AA5050100514E|false",
            "MARKER|5AA5050200514F00|false",
            "MARKER|5AA5050100504F|false"
        ]

        static let resetCommands: [String] = [
            "RESETCMD|0|false|5AA5110100540F",
            "RESETCMD|0|true|5AA5110100AA07",
            "RESETCMD|1|false|5AA5110100540F",
            "RESETCMD|1|true|5AA5110100AA07",
            "RESETCMD|2|false|5AA5110100AA07",
            "RESETCMD|2|true|5AA5110100AA07",
            "RESETCMD|3|false|5AA5110100540F",
            "RESETCMD|3|true|5AA5110100AA07"
        ]

        static let bleIds: [String] = [
            "BLEID|w25101399|W25101399",
            "BLEID|W25101399|W25101399",
            "BLEID|S/N:W25101399|W25101399",
            "BLEID| s/n:w25101399 |W25101399",
            "BLEID|W2510139|W2510139",
            "BLEID|W251013|W251013",
            "BLEID|W2510139912345678|nil",
            "BLEID|W25101399123456|W25101399123456",
            "BLEID|CF:D8:EB:DD:F9:69|nil",
            "BLEID|CFD8EBDDF969|nil",
            "BLEID|C12345678901|nil",
            "BLEID|FD8EBDDF969|nil",
            "BLEID|Glutec CGM|nil",
            "BLEID||nil",
            "BLEID|  |nil",
            "BLEID|X1234567|X1234567",
            "BLEID|AB1234567|nil",
            "BLEID|a123456|A123456",
            "BLEID|Z123456789012345|Z123456789012345",
            "BLEID|Z1234567890123456|nil"
        ]

        static let profile: [String] = [
            "PROFILE|Glutec|3|60|16|1382400000"
        ]
}
