//
//  MQProtocol.swift
//  xdrip
//
//  Pure protocol layer of the MQ / Glutec CGM driver: the Nordic UART service layout, the frame
//  format (`5A A5 CMD LEN payload CRC_HI CRC_LO`), CRC16-Modbus and its Protocol02 variants, the
//  parser for the 6 byte glucose records, the frame builders, the reset command, the vendor serial
//  (`bleId`) rules and the small session policies (link activity, session start estimate, restore
//  and cloud history timing). Ported from the JugglucoNG `drivers/mq` package (GPL-3.0, see
//  THIRD_PARTY_NOTICES.md). Nothing here touches Bluetooth, so everything is covered by unit tests
//  (`MQProtocolTests`, `MQSessionTests`) whose expected values were computed by running the
//  unchanged Kotlin on the JVM.
//
//  Not ported: the vendor cloud (login, QR lookup, session, report and history endpoints), the
//  follower, the native mirror and the Android registry. See docs/mq.md.
//
//  Never tried on a real sensor.
//

import CoreBluetooth
import Foundation

// MARK: - Kotlin-compatible number helpers

/// Kotlin `Double.toInt()`: truncates toward zero and saturates; NaN is 0. Swift's `Int(_:)` would trap.
func mqKotlinInt(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 2147483647 { return Int(Int32.max) }
    if value <= -2147483648 { return Int(Int32.min) }
    return Int(value)
}

/// Kotlin `Double.roundToInt()`: ties go toward positive infinity (`Math.round`) and the result
/// saturates. Kotlin throws for NaN; the port returns 0 (no input of the driver can be NaN).
func mqKotlinRound(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 2147483647 { return Int(Int32.max) }
    if value <= -2147483648 { return Int(Int32.min) }
    let floored = value.rounded(.down)
    let rounded = (value - floored) >= 0.5 ? floored + 1 : floored
    return Int(rounded)
}

// MARK: - Constants

/// JugglucoNG `MQConstants` (the vendor endpoints, preference keys and native-id helpers are not ported).
enum MQConstants {

    // MARK: Nordic UART service

    /// Nordic UART Service.
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// TX characteristic (transmitter to phone, notify).
    static let txNotifyUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    /// RX characteristic (phone to transmitter, write).
    static let rxWriteUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: Framing

    static let header0: UInt8 = 0x5A
    static let header1: UInt8 = 0xA5
    /// 2 header bytes, command, length and 2 CRC bytes.
    static let frameOverhead = 6
    static let offsetCmd = 2
    static let offsetLen = 3
    static let offsetPayload = 4

    // MARK: Commands (byte 2 of every frame)

    /// Transmitter to phone heartbeat while it has no new data.
    static let cmdNotifyWorking: UInt8 = 0x01
    /// Phone to transmitter: acknowledgement of a BG data frame.
    static let cmdWriteBgDataConfirm: UInt8 = 0x02
    /// Phone to transmitter: continue without re-initialising the transmitter.
    static let cmdWriteConfirmWithoutInit: UInt8 = 0x03
    /// Transmitter to phone: glucose data, one or more 6 byte records.
    static let cmdNotifyBgData: UInt8 = 0x04
    /// Transmitter to phone: "BG data acknowledged, session continuing" marker (silent).
    static let cmdNotifyBgComplete: UInt8 = 0x05
    /// Transmitter to phone: the transmitter just started work (reset or fresh session).
    static let cmdNotifyBeginWork: UInt8 = 0x06
    /// Phone to transmitter: acknowledge the initialisation phase.
    static let cmdWriteConfirmWithInit: UInt8 = 0x08
    /// Phone to transmitter: reset the transmitter.
    static let cmdWriteConfirmReset: UInt8 = 0x11

    // MARK: BG record layout (payload of a 0x04 frame)

    static let bgRecordSize = 6
    static let bgRecordMarker = 0x40
    static let bgOffsetMarker = 0
    static let bgOffsetPacketLo = 1
    static let bgOffsetPacketHi = 2
    static let bgOffsetCurrentLo = 3
    static let bgOffsetCurrentHi = 4
    static let bgOffsetBattery = 5

    // MARK: Algorithm defaults and limits

    /// Lowest value (mmol/L) kept after the offset is subtracted.
    static let algoMmolFloor = 3.0
    /// Output clamp in mmol/L times ten: 1.7 to 40.0 mmol/L.
    static let algoMmolMinTimes10 = 17.0
    static let algoMmolMaxTimes10 = 400.0
    /// Conversion from the vendor's mmol/L to mg/dL.
    static let mmolToMgdl = 18.0182
    /// The warm-up guard applies from this packet index on.
    static let algoWarmupPacketThreshold = 19.0
    /// Default multiplier when no server value is known.
    static let algoDefaultMultiplier = 1.1
    /// Default packages per session when no server value is known.
    static let algoDefaultPackages = 720
    /// Default init-time guard when the session start is unknown (minutes).
    static let algoDefaultInitTimeMinutes = 24.0
    /// Default algorithm version when no server value is known.
    static let algoDefaultVersion = 0
    /// Sub-1 slopes are not plausible for the observed firmware and point at bogus state.
    static let algoMinValidK = 1.0

    /// Protocol type when the server did not say (1 = Protocol01, 2 = Protocol02).
    static let defaultProtocolType = 1

    // MARK: Lifetime and cadence

    static let ratedLifetimeDays = 16
    static let readingIntervalMinutes = 3
    /// JugglucoNG's profile warm-up. xDrip hides nothing for it: the vendor's own algorithm withholds
    /// values (see `MQAlgorithm`), and a longer xDrip warm-up would hide a new sensor's readings.
    static let warmupMinutes = 60

    static let defaultDisplayName = "Glutec CGM"

    // MARK: Device names

    /// Advertised names JugglucoNG treats as MQ / Glutec (case-insensitive prefixes).
    static let knownPrefixes = ["Glutec", "GLUTEC", "MQ", "RU-"]
}

// MARK: - Device name matching

enum MQDeviceName {

    /// JugglucoNG `MQConstants.KNOWN_PREFIXES` check. JugglucoNG also accepts names that look like a
    /// persisted sensor id (a MAC address or 12 to 16 hex digits); iOS has no MAC address and such a
    /// rule would match too many devices for an automatic first connection, so it is not ported.
    static func hasKnownPrefix(_ name: String?) -> Bool {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let lowered = trimmed.lowercased()
        return MQConstants.knownPrefixes.contains { lowered.hasPrefix($0.lowercased()) }
    }

    /// Whether an advertisement looks like an MQ / Glutec transmitter: a known name prefix, a name that
    /// is the printed vendor serial (`W25101399`; fork extension, JugglucoNG reaches such a device only
    /// through the service check) or the Nordic UART service in the advertisement (JugglucoNG's rule).
    static func looksLikeMQ(name: String?, advertisesNUS: Bool) -> Bool {
        if advertisesNUS { return true }
        if hasKnownPrefix(name) { return true }
        return MQVendorIdentity.bleId(name) != nil
    }
}

// MARK: - CRC16

/// CRC16-Modbus (polynomial 0xA001, initial value 0xFFFF), written high byte first on the wire.
///
/// Protocol01 firmware uses plain Modbus. Captures of Protocol02 firmware differ from it by a value
/// that depends on the packet (0x0100 in some, other values in others), so inbound CRC mismatches are
/// accepted and outbound acknowledgements that matter use captured bytes (see `MQAckFrames`).
enum MQCrc16 {

    /// CRC16-Modbus over `length` bytes of `data` starting at `offset` (the whole remainder when
    /// `length` is nil). Kotlin would throw for a range outside the array; the port clamps it.
    static func compute(_ data: [UInt8], offset: Int = 0, length: Int? = nil) -> Int {
        let start = max(0, min(offset, data.count))
        let requested = length ?? (data.count - start)
        let end = max(start, min(data.count, start + max(0, requested)))
        var crc = 0xFFFF
        var index = start
        while index < end {
            crc ^= Int(data[index])
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xA001) : (crc >> 1)
            }
            index += 1
        }
        return crc & 0xFFFF
    }

    /// Writes the CRC of all bytes but the last two into those two bytes (high byte first), XORed with
    /// `xorOut` (0 for Protocol01). A frame shorter than two bytes is returned unchanged.
    static func stamp(_ frame: [UInt8], xorOut: Int = 0) -> [UInt8] {
        guard frame.count >= 2 else { return frame }
        var result = frame
        let crc = compute(frame, offset: 0, length: frame.count - 2) ^ (xorOut & 0xFFFF)
        result[result.count - 2] = UInt8((crc >> 8) & 0xFF)
        result[result.count - 1] = UInt8(crc & 0xFF)
        return result
    }

    /// Whether the last two bytes are the big-endian CRC16-Modbus of the bytes before them.
    static func verify(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 2 else { return false }
        let expected = (Int(frame[frame.count - 2]) << 8) | Int(frame[frame.count - 1])
        return expected == compute(frame, offset: 0, length: frame.count - 2)
    }
}

// MARK: - Frames and records

struct MQFrame: Equatable {
    let cmd: UInt8
    let len: Int
    let payload: [UInt8]
    let raw: [UInt8]
    /// True if the trailing CRC matches CRC16-Modbus. Protocol02 firmware ships other values; such a
    /// frame is still accepted because the header and length checks already filter noise.
    let crcValid: Bool

    var cmdUnsigned: Int { return Int(cmd) }
}

struct MQBgRecord: Equatable {
    let indexInPacket: Int
    let marker: Int
    let packetIndex: Int
    let sampleCurrent: Int
    /// Raw vendor battery field, not a percentage.
    let batteryRaw: Int
    /// The 6 bytes of the record.
    let recordBytes: [UInt8]
}

// MARK: - Parser and frame builders

enum MQParser {

    /// Parses a notification buffer into a frame. A CRC mismatch does not reject it. Extra bytes after
    /// the frame are dropped; a buffer shorter than the frame, a wrong header or fewer than 6 bytes
    /// give nil.
    static func parse(_ buffer: [UInt8]?) -> MQFrame? {
        guard let buffer = buffer, buffer.count >= MQConstants.frameOverhead else { return nil }
        guard buffer[0] == MQConstants.header0, buffer[1] == MQConstants.header1 else { return nil }
        let len = Int(buffer[MQConstants.offsetLen])
        let expectedSize = MQConstants.frameOverhead + len
        guard buffer.count >= expectedSize else { return nil }
        let frame = buffer.count == expectedSize ? buffer : Array(buffer[0..<expectedSize])
        let payload = len == 0 ? [UInt8]() : Array(frame[MQConstants.offsetPayload..<(MQConstants.offsetPayload + len)])
        return MQFrame(
            cmd: frame[MQConstants.offsetCmd],
            len: len,
            payload: payload,
            raw: frame,
            crcValid: MQCrc16.verify(frame)
        )
    }

    static func parse(data: Data) -> MQFrame? {
        return parse([UInt8](data))
    }

    /// The fixed size glucose records of a 0x04 frame (`len / 6` of them).
    static func parseBgRecords(_ frame: MQFrame) -> [MQBgRecord] {
        guard frame.cmd == MQConstants.cmdNotifyBgData else { return [] }
        let count = frame.len / MQConstants.bgRecordSize
        guard count > 0 else { return [] }
        var records = [MQBgRecord]()
        records.reserveCapacity(count)
        for index in 0..<count {
            let base = index * MQConstants.bgRecordSize
            let marker = Int(frame.payload[base + MQConstants.bgOffsetMarker])
            let packetLo = Int(frame.payload[base + MQConstants.bgOffsetPacketLo])
            let packetHi = Int(frame.payload[base + MQConstants.bgOffsetPacketHi])
            let currentLo = Int(frame.payload[base + MQConstants.bgOffsetCurrentLo])
            let currentHi = Int(frame.payload[base + MQConstants.bgOffsetCurrentHi])
            let battery = Int(frame.payload[base + MQConstants.bgOffsetBattery])
            records.append(MQBgRecord(
                indexInPacket: index,
                marker: marker,
                packetIndex: (packetHi << 8) | packetLo,
                sampleCurrent: (currentHi << 8) | currentLo,
                batteryRaw: battery,
                recordBytes: Array(frame.payload[base..<(base + MQConstants.bgRecordSize)])
            ))
        }
        return records
    }

    /// A 7 byte frame with one zero payload byte and a stamped CRC. `crcXorOut` is 0 for Protocol01.
    static func buildConfirm(cmd: UInt8, crcXorOut: Int = 0) -> [UInt8] {
        let frame: [UInt8] = [MQConstants.header0, MQConstants.header1, cmd, 0x01, 0x00, 0x00, 0x00]
        return MQCrc16.stamp(frame, xorOut: crcXorOut)
    }

    static func buildConfirmBgData(crcXorOut: Int = 0) -> [UInt8] {
        return buildConfirm(cmd: MQConstants.cmdWriteBgDataConfirm, crcXorOut: crcXorOut)
    }

    static func buildConfirmWithInit(crcXorOut: Int = 0) -> [UInt8] {
        return buildConfirm(cmd: MQConstants.cmdWriteConfirmWithInit, crcXorOut: crcXorOut)
    }

    static func buildConfirmWithoutInit(crcXorOut: Int = 0) -> [UInt8] {
        return buildConfirm(cmd: MQConstants.cmdWriteConfirmWithoutInit, crcXorOut: crcXorOut)
    }

    static func buildConfirmReset(crcXorOut: Int = 0) -> [UInt8] {
        return buildConfirm(cmd: MQConstants.cmdWriteConfirmReset, crcXorOut: crcXorOut)
    }
}

// MARK: - Acknowledgement frames

/// The acknowledgements JugglucoNG always sends. They are byte sequences captured from the official
/// app's Bluetooth log on a Protocol02 transmitter, not computed CRCs: the transmitter left a
/// BEGIN_WORK loop only after one write of `withInit`, and a computed CRC (`MQParser.buildConfirm*`)
/// does not reproduce them.
enum MQAckFrames {
    /// `confirmWithInit` (0x08), the unlock acknowledgement for BEGIN_WORK.
    static let withInit: [UInt8] = [0x5A, 0xA5, 0x08, 0x01, 0x00, 0x4A, 0x6F]
    /// `bgDataConfirm` (0x02), sent after every 0x04 frame.
    static let bgData: [UInt8] = [0x5A, 0xA5, 0x02, 0x01, 0x00, 0x49, 0x7F]
    /// `confirmWithoutInit` (0x03), sent after every heartbeat.
    static let withoutInit: [UInt8] = [0x5A, 0xA5, 0x03, 0x01, 0x00, 0x50, 0xAF]
}

// MARK: - Reset command

/// JugglucoNG `MQResetCommand`: Protocol02's reset bytes come from the official app's capture.
enum MQResetCommand {

    private static let protocol02MarkerEnd: [UInt8] = [0x5A, 0xA5, 0x05, 0x01, 0x00, 0x51, 0x4F]
    private static let protocol02MarkerBegin: [UInt8] = [0x5A, 0xA5, 0x06, 0x01, 0x00, 0x91, 0x7E]
    private static let protocol02Reset: [UInt8] = [0x5A, 0xA5, 0x11, 0x01, 0x00, 0xAA, 0x07]

    /// The two session marker frames only Protocol02 firmware sends.
    static func isProtocol02Marker(_ frame: MQFrame) -> Bool {
        return frame.raw == protocol02MarkerEnd || frame.raw == protocol02MarkerBegin
    }

    static func build(protocolType: Int, observedProtocol02: Bool) -> [UInt8] {
        if protocolType == 2 || observedProtocol02 {
            return protocol02Reset
        }
        return MQParser.buildConfirmReset(crcXorOut: 0)
    }
}

// MARK: - Vendor identity

enum MQVendorIdentity {

    /// The printed transmitter serial (`W25101399`) is the vendor's `bleId`; a MAC address is not.
    /// Accepts the label prefix `S/N:` and any case; nil when the text is not a serial.
    static func bleId(_ name: String?) -> String? {
        guard let name = name else { return nil }
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("S/N:") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let characters = Array(text.unicodeScalars)
        guard characters.count >= 7, characters.count <= 16 else { return nil }
        guard let first = characters.first, first.value >= 0x41, first.value <= 0x5A else { return nil }
        let digits = characters.dropFirst()
        guard digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return nil }
        // 12 hexadecimal characters are a MAC address, whatever they look like
        if characters.count == 12, characters.allSatisfy({ isUpperHex($0) }) { return nil }
        return text
    }

    private static func isUpperHex(_ scalar: Unicode.Scalar) -> Bool {
        return (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x46)
    }
}

// MARK: - Profile

/// JugglucoNG `MQProfile`: the lifecycle and cadence of the one hardware generation.
struct MQProfile: Equatable {
    let familyName: String
    let readingIntervalMinutes: Int
    let warmupMinutes: Int
    let ratedLifetimeDays: Int

    func ratedLifetimeMs() -> Int64 {
        return Int64(ratedLifetimeDays) * 24 * 60 * 60 * 1000
    }

    var readingIntervalMs: Int64 {
        return Int64(readingIntervalMinutes) * 60 * 1000
    }

    static let `default` = MQProfile(
        familyName: "Glutec",
        readingIntervalMinutes: MQConstants.readingIntervalMinutes,
        warmupMinutes: MQConstants.warmupMinutes,
        ratedLifetimeDays: MQConstants.ratedLifetimeDays
    )

    /// There is one profile today, whatever the name or serial.
    static func resolve(modelName: String? = nil, rawSerial: String? = nil) -> MQProfile {
        return .default
    }
}
