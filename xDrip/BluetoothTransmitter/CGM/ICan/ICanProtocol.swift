//
//  ICanProtocol.swift
//  xdrip
//
//  Pure protocol layer of the iCan (Sinocare) CGM driver: key families, AES-CBC helpers, live and
//  history parsers, authentication helpers, profiles and the sequence timeline. Ported from the
//  JugglucoNG `drivers/icanhealth` package (GPL-3.0, see THIRD_PARTY_NOTICES.md). Nothing here
//  touches Bluetooth, so everything is covered by unit tests (`ICanProtocolTests`).
//
//  Never tried on a real sensor.
//

import CommonCrypto
import CoreBluetooth
import Foundation

// MARK: - GATT

enum ICanGATT {
    static let cgmService = CBUUID(string: "181F")
    static let deviceInfoService = CBUUID(string: "180A")

    /// CGM Measurement (notify): 19-byte live frames.
    static let measurement = CBUUID(string: "2AA7")
    /// CGM Status (read): u16 LE minutes since session start, byte 2 = launcher state.
    static let status = CBUUID(string: "2AA9")
    /// CGM Session Start Time (read).
    static let sessionStart = CBUUID(string: "2AAA")
    /// Record Access Control Point (write + indicate): history.
    static let racp = CBUUID(string: "2A52")
    /// CGM Specific Ops Control Point (write + indicate): vendor authentication.
    static let specificOps = CBUUID(string: "2AAC")

    static let modelNumber = CBUUID(string: "2A24")
    static let serialNumber = CBUUID(string: "2A25")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let softwareRevision = CBUUID(string: "2A28")
}

// MARK: - Constants

enum ICanConstants {
    static let mmolToMgdl: Float = 18.0182
    static let minValidMgdl: Float = 10
    static let maxValidMgdl: Float = 551
    static let liveFrameSize = 19
    static let aesBlockSize = 16
    static let advisoryLifetimeDays = 28

    static let launcherStateIdle = 0x00
    static let launcherStateWarmup = 0x01
    static let launcherStateEnded = 0x40
    static let launcherStateRunning = 0x80

    static let racpResultSuccess = 0x01
    static let racpResultNotSupported = 0x02
    static let racpResultNoData = 0x06
    static let racpResultFailed = 0x0A

    static let snSubtypeOriginal = 0x01
    static let snSubtypeGlucose = 0x02

    /// Calibration marker 0xFFFF in the sensor-info reply: nothing installed.
    static let calibrationMarkerMissing = 0xFFFF

    static func isActiveLauncherState(_ state: Int) -> Bool {
        return state == launcherStateRunning || state == launcherStateWarmup
    }

    static func isValidMgdl(_ value: Float) -> Bool {
        return value >= minValidMgdl && value <= maxValidMgdl
    }
}

// MARK: - Key family

/// The firmware generation selects one of two bundled key sets. The selector is the hexadecimal
/// pair at characters 10..<12 of the Device Information serial (else of the software revision);
/// 0x04...0x07 is the new family, everything else the old one.
enum ICanKeyFamily: String, Codable, Equatable {
    case old
    case new

    static func selector(from source: String?) -> Int? {
        guard let source = source else { return nil }
        let trimmed = Array(source.trimmingCharacters(in: .whitespacesAndNewlines))
        guard trimmed.count >= 12 else { return nil }
        return Int(String(trimmed[10..<12]), radix: 16)
    }

    static func resolve(launcherSerial: String?, softwareVersion: String?) -> ICanKeyFamily {
        let selector = self.selector(from: launcherSerial) ?? self.selector(from: softwareVersion)
        if let selector = selector, selector >= 0x04, selector <= 0x07 {
            return .new
        }
        return .old
    }

    var glucoseKey: [UInt8] {
        switch self {
        case .old: return Array("4&13E6G24w6ZL3rF".utf8)
        case .new: return Array("y67BbdK!3qN?75t8".utf8)
        }
    }

    var originalHistoryKey: [UInt8] {
        switch self {
        case .old: return Array("z3q9V419#7574XZI".utf8)
        case .new: return Array("X3c26#mb9~Sudyk9".utf8)
        }
    }

    var authKey: [UInt8] {
        switch self {
        case .old: return Array("92AFQU*u9c695826".utf8)
        case .new: return Array("px@9k5K*23cV%YDc".utf8)
        }
    }

    /// XOR table that hides the first readings of a session (warm-up).
    var warmupXorTable: [UInt8] {
        switch self {
        case .old: return ICanXorTables.old
        case .new: return ICanXorTables.new
        }
    }
}

enum ICanXorTables {
    static let old: [UInt8] = [
        0x6D, 0x29, 0x8B, 0x2D, 0x24, 0xA7, 0x53, 0xF3, 0xC8, 0xB8, 0x7F, 0x2D, 0x85, 0x4D, 0x43, 0xF1,
        0x8A, 0xA2, 0x46, 0xAD, 0x8C, 0x77, 0xD4, 0x2D, 0xBE, 0x60, 0xFE, 0x07, 0xF2, 0xFE, 0x52, 0x77,
        0xAC, 0x8F, 0x7D, 0x1D, 0xED, 0x38, 0xBE, 0xEC, 0xDF, 0x78, 0x5D, 0x41, 0x9B, 0x68, 0x7F, 0x28,
        0xC4, 0xF2, 0x78, 0xF4, 0xF6, 0x47, 0x54, 0xD5, 0x0F, 0xAE, 0x5B, 0x27, 0xCB, 0x41, 0x21, 0x82
    ]
    static let new: [UInt8] = [
        0xBF, 0x2D, 0x98, 0x23, 0xD2, 0xA3, 0x75, 0x4F, 0xF8, 0xB8, 0x87, 0x21, 0xD8, 0x43, 0xD4, 0x5F,
        0x62, 0xAA, 0x24, 0xAD, 0xE8, 0x74, 0x7D, 0xC2, 0xEE, 0x6E, 0x5F, 0x27, 0x7F, 0xF2, 0xE5, 0x27,
        0xD8, 0x8C, 0xF7, 0x1C, 0xDE, 0x3E, 0x8B, 0xDE, 0xDF, 0x7F, 0x85, 0x48, 0x39, 0x6F, 0xC7, 0xB2,
        0x8E, 0xF4, 0x27, 0xF5, 0x4F, 0x44, 0x75, 0x6D, 0xB9, 0xAF, 0xE5, 0x22, 0x7C, 0x41, 0x12, 0xB8
    ]
}

// MARK: - Crypto

enum ICanCrypto {
    /// The CBC IV is 16 zero bytes with the four challenge bytes at positions 1, 6, 10 and 15.
    static func iv(challenge: [UInt8]) -> [UInt8]? {
        guard challenge.count == 4 else { return nil }
        var iv = [UInt8](repeating: 0, count: 16)
        iv[1] = challenge[0]
        iv[6] = challenge[1]
        iv[10] = challenge[2]
        iv[15] = challenge[3]
        return iv
    }

    static func encryptCBC(_ plain: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        return crypt(CCOperation(kCCEncrypt), input: plain, key: key, iv: iv)
    }

    /// Nil for a wrong length, a wrong key or invalid padding.
    static func decryptCBC(_ cipher: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard cipher.count % ICanConstants.aesBlockSize == 0 else { return nil }
        return crypt(CCOperation(kCCDecrypt), input: cipher, key: key, iv: iv)
    }

    private static func crypt(_ operation: CCOperation, input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty, key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }
}

// MARK: - Glucose field

/// One decoded 16-bit glucose field: a 4-bit nibble (purpose unknown, constant per sensor, not
/// part of the value) and a 12-bit mantissa in hundredths of mmol/L.
struct ICanGlucoseField: Equatable {
    let nibble: Int
    let mantissa: Int

    var mmolL: Float { return Float(mantissa) / 100.0 }
    var mgdl: Float { return mmolL * ICanConstants.mmolToMgdl }

    /// `direct` selects the variant that reads all 16 bits as the value. The iOS app has no
    /// onboarding box serial, so the transmitter always passes false.
    static func decode(low: UInt8, high: UInt8, direct: Bool) -> ICanGlucoseField {
        let lowValue = Int(low)
        let highValue = Int(high)
        if direct {
            return ICanGlucoseField(nibble: 0, mantissa: lowValue | (highValue << 8))
        }
        return ICanGlucoseField(nibble: (highValue >> 4) & 0x0F, mantissa: lowValue | ((highValue & 0x0F) << 8))
    }
}

// MARK: - Profile

/// Reading cadence, warm-up and rated lifetime of a sensor family, chosen from the Device
/// Information strings. Ported literally from JugglucoNG, including its hyphenated "h6-14" /
/// "h6-15" / "h6-7" checks that can never match because the text is normalised first (the hyphen
/// becomes a space); those branches are dead there and stay dead here.
struct ICanProfile: Equatable {
    let familyName: String
    let readingIntervalMinutes: Int
    let warmupMinutes: Int
    let ratedLifetimeDays: Int

    var advisoryLifetimeDays: Int { return ICanConstants.advisoryLifetimeDays }

    static let defaultProfile = ICanProfile(familyName: "iCan", readingIntervalMinutes: 3, warmupMinutes: 120, ratedLifetimeDays: 15)

    private static func normalize(_ value: String?) -> String {
        guard let value = value else { return "" }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    static func resolve(model: String?, rawSerial: String? = nil, softwareVersion: String? = nil) -> ICanProfile {
        let parts = [normalize(model), normalize(rawSerial), normalize(softwareVersion)].filter { !$0.isEmpty }
        let combined = parts.joined(separator: " ")
        func has(_ needle: String) -> Bool { return combined.contains(needle) }

        if has("i7e") {
            return ICanProfile(familyName: "i7e", readingIntervalMinutes: 1, warmupMinutes: 30, ratedLifetimeDays: 9)
        }
        if has("i7pro") || has("h7pro") || has("i7s") || has(" i7") || combined.hasPrefix("i7") {
            return ICanProfile(familyName: "i7", readingIntervalMinutes: 1, warmupMinutes: 30, ratedLifetimeDays: 15)
        }
        if has("h6-14") {
            return ICanProfile(familyName: "H6-14", readingIntervalMinutes: 3, warmupMinutes: 120, ratedLifetimeDays: 14)
        }
        if has("h6-15s") || has("h6-15") || (has("h6") && (has(" yk") || has(" zz") || has(" zb"))) {
            return ICanProfile(familyName: "H6-15", readingIntervalMinutes: 3, warmupMinutes: 30, ratedLifetimeDays: 15)
        }
        if has("h6-7") || (has(" h6") && !has("h6-14") && !has("h6-15")) {
            return ICanProfile(familyName: "H6", readingIntervalMinutes: 3, warmupMinutes: has(" yk") ? 30 : 120, ratedLifetimeDays: 7)
        }
        if has("h3") {
            return ICanProfile(familyName: "H3", readingIntervalMinutes: 3, warmupMinutes: 120, ratedLifetimeDays: 8)
        }
        if has("i6pro") || has("i6s") || has(" i6") || combined.hasPrefix("i6") || has("t6") {
            return ICanProfile(familyName: "i6", readingIntervalMinutes: 3, warmupMinutes: 30, ratedLifetimeDays: 15)
        }
        if has("o3") {
            return ICanProfile(familyName: "o3", readingIntervalMinutes: 3, warmupMinutes: 120, ratedLifetimeDays: 15)
        }
        if has("t3") || has("i3a") || has(" i3") || combined.hasPrefix("i3") {
            return ICanProfile(familyName: "i3", readingIntervalMinutes: 3, warmupMinutes: 120, ratedLifetimeDays: 15)
        }
        return defaultProfile
    }
}

// MARK: - Advertised name

enum ICanDeviceName {
    static let knownPrefixes = ["iCGM-", "Sinocare CGM", "Sinocare ", "LT"]

    /// Prefixes plus the two serial-shaped names. JugglucoNG additionally accepts any 12 to 32
    /// character alphanumeric name; that would match many unrelated devices when the first match
    /// is connected without a picker, so it is left out here.
    static func looksLikeICan(_ name: String?) -> Bool {
        guard let name = name else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        for prefix in knownPrefixes where trimmed.hasPrefix(prefix) {
            return true
        }
        return matches(trimmed, pattern: "^P[0-9]{9}[A-Z]{3}$") || matches(trimmed, pattern: "^LT[0-9]{6,}[A-Z]{2,3}$")
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - Parsed values

struct ICanLiveReading: Equatable {
    let sequence: Int
    /// Launcher state carried in the frame (0x80 = running).
    let statusByte: Int
    let field: ICanGlucoseField

    var mgdl: Float { return field.mgdl }
}

struct ICanStatus: Equatable {
    let sequence: Int
    let launcherState: Int
}

struct ICanHistoryRecord: Equatable {
    let sequence: Int
    let subtype: Int
    let glucose: ICanGlucoseField?
    /// Vendor-formatted current of an original-history record (not a glucose value).
    let currentValue: Float?
    let temperatureC: Float?
}

struct ICanHistoryBatch: Equatable {
    let subtype: Int
    let baseSequence: Int
    let records: [ICanHistoryRecord]
}

struct ICanSessionStart: Equatable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    /// Time Zone in 15-minute steps; nil when unknown, out of range or the vendor constant.
    let timeZone15Min: Int?
    /// DST offset in 15-minute steps; nil when unknown.
    let dst15Min: Int?

    var utcOffset15Min: Int? {
        guard let zone = timeZone15Min else { return nil }
        return zone + (dst15Min ?? 0)
    }

    /// The sensor sends a local wall clock and usually no usable zone, so a missing or zero offset
    /// reads the wall clock in the device's zone; only a non-zero offset is taken at face value.
    func date(deviceTimeZone: TimeZone = TimeZone.current) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        if let offset = utcOffset15Min, offset != 0 {
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? deviceTimeZone
            guard let wallClock = calendar.date(from: components) else { return nil }
            return wallClock.addingTimeInterval(-Double(offset) * 900.0)
        }
        calendar.timeZone = deviceTimeZone
        return calendar.date(from: components)
    }
}

// MARK: - Parsers

enum ICanParser {
    private static let timeZoneUnknown = -128
    private static let timeZoneVendorConstant = 0x14
    private static let minTimeZone15Min = -48
    private static let maxTimeZone15Min = 56
    private static let dstUnknown = 255
    private static let maxDst15Min = 8

    private static func leUnsigned(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset < bytes.count else { return 0 }
        let low = Int(bytes[offset])
        let high = offset + 1 < bytes.count ? Int(bytes[offset + 1]) : 0
        return low | (high << 8)
    }

    /// Vendor representation of the current: two bytes XOR 0x88, printed as five digits and
    /// prefixed with "25" before being read as a number. Only used by original-history records.
    static func decodeCurrentValue(low: UInt8, high: UInt8) -> Float {
        let decoded = Int(low ^ 0x88) | (Int(high ^ 0x88) << 8)
        var digits = String(decoded)
        while digits.count < 5 { digits = "0" + digits }
        return Float("25" + digits) ?? Float.nan
    }

    /// During warm-up (sequence below the profile's warm-up minutes) the two glucose bytes are
    /// XORed with a table slice whose offset comes from the first challenge byte. Without a
    /// 4-byte challenge the value cannot be recovered, so the record is rejected.
    static func decodeHistoryGlucoseBytes(
        low: UInt8,
        high: UInt8,
        sequence: Int,
        challenge: [UInt8]?,
        family: ICanKeyFamily,
        warmupMinutes: Int
    ) -> (UInt8, UInt8)? {
        if sequence >= warmupMinutes {
            return (low, high)
        }
        guard let challenge = challenge, challenge.count >= 4 else { return nil }
        let table = family.warmupXorTable
        let offset = Int(challenge[0]) % (table.count - 2)
        return (low ^ table[offset], high ^ table[offset + 1])
    }

    /// 19-byte live frame: `<seq u16 LE> 02 <16 bytes AES-CBC>`. The decrypted content is 13
    /// bytes: length 0x0D, launcher state, glucose u16, sequence u16 (must equal the header),
    /// 0x01 and six zero bytes.
    static func parseLive(
        _ data: [UInt8],
        family: ICanKeyFamily,
        challenge: [UInt8]?,
        direct: Bool,
        warmupMinutes: Int
    ) -> ICanLiveReading? {
        guard data.count == ICanConstants.liveFrameSize else { return nil }
        let headerSequence = Int(data[0]) | (Int(data[1]) << 8)
        guard let challenge = challenge, let iv = ICanCrypto.iv(challenge: challenge) else { return nil }
        guard let decrypted = ICanCrypto.decryptCBC(Array(data[3..<19]), key: family.glucoseKey, iv: iv) else { return nil }
        guard decrypted.count == 0x0D, decrypted[0] == 0x0D else { return nil }
        let status = Int(decrypted[1])
        guard let bytes = decodeHistoryGlucoseBytes(
            low: decrypted[2],
            high: decrypted[3],
            sequence: headerSequence,
            challenge: challenge,
            family: family,
            warmupMinutes: warmupMinutes
        ) else { return nil }
        let field = ICanGlucoseField.decode(low: bytes.0, high: bytes.1, direct: direct)
        guard leUnsigned(decrypted, 4) == headerSequence else { return nil }
        return ICanLiveReading(sequence: headerSequence, statusByte: status, field: field)
    }

    // MARK: Session metadata

    static func parseSessionStart(_ data: [UInt8]) -> ICanSessionStart? {
        guard data.count >= 7 else { return nil }
        let year = Int(data[0]) | (Int(data[1]) << 8)
        let month = Int(data[2])
        let day = Int(data[3])
        if year == 0 || year == 0xFFFF || month < 1 || month > 12 || day < 1 || day > 31 {
            return nil
        }
        var zone: Int?
        if data.count > 7 {
            let value = Int(Int8(bitPattern: data[7]))
            if value != timeZoneUnknown && value != timeZoneVendorConstant && value >= minTimeZone15Min && value <= maxTimeZone15Min {
                zone = value
            }
        }
        var dst: Int?
        if data.count > 8 {
            let value = Int(data[8])
            if value != dstUnknown && value <= maxDst15Min {
                dst = value
            }
        }
        return ICanSessionStart(
            year: year,
            month: month,
            day: day,
            hour: Int(data[4]),
            minute: Int(data[5]),
            second: Int(data[6]),
            timeZone15Min: zone,
            dst15Min: dst
        )
    }

    static func parseStatus(_ data: [UInt8]) -> ICanStatus? {
        guard data.count >= 2 else { return nil }
        return ICanStatus(
            sequence: Int(data[0]) | (Int(data[1]) << 8),
            launcherState: data.count > 2 ? Int(data[2]) : 0
        )
    }

    // MARK: History

    static func isSnNotification(_ data: [UInt8]) -> Bool {
        return data.count >= 2 && data[0] == 0x53 && data[1] == 0x4E
    }

    static func parseSnType(_ data: [UInt8]) -> Int? {
        guard data.count >= 6, isSnNotification(data) else { return nil }
        guard data[3] == 0x2A, data[4] == 0x52 else { return nil }
        return Int(data[5])
    }

    /// `53 4E <len> 2A 52 <subtype> <AES-CBC payload> <trailer>`. The payload decrypts to
    /// `55 <base seq u16 LE> <records> AA`; records are 2 bytes (glucose) or 4 bytes (original),
    /// each one reading interval after the previous.
    static func parseSnHistoryBatch(
        _ data: [UInt8],
        challenge: [UInt8],
        direct: Bool,
        launcherSerial: String?,
        softwareVersion: String?,
        readingIntervalMinutes: Int
    ) -> ICanHistoryBatch? {
        guard let subtype = parseSnType(data), data.count >= 8 else { return nil }
        let payload = Array(data[6..<(data.count - 1)])
        if payload.isEmpty {
            return ICanHistoryBatch(subtype: subtype, baseSequence: -1, records: [])
        }
        let family = ICanKeyFamily.resolve(launcherSerial: launcherSerial, softwareVersion: softwareVersion)
        let key: [UInt8]
        let recordSize: Int
        switch subtype {
        case ICanConstants.snSubtypeGlucose:
            key = family.glucoseKey
            recordSize = 2
        case ICanConstants.snSubtypeOriginal:
            key = family.originalHistoryKey
            recordSize = 4
        default:
            return nil
        }
        guard let iv = ICanCrypto.iv(challenge: challenge),
              let decrypted = ICanCrypto.decryptCBC(payload, key: key, iv: iv) else { return nil }
        guard decrypted.count >= 4, decrypted[0] == 0x55, decrypted[decrypted.count - 1] == 0xAA else { return nil }
        let base = leUnsigned(decrypted, 1)
        var records: [ICanHistoryRecord] = []
        var sequence = base
        var offset = 3
        while offset + recordSize <= decrypted.count - 1 {
            if subtype == ICanConstants.snSubtypeGlucose {
                let field = ICanGlucoseField.decode(low: decrypted[offset], high: decrypted[offset + 1], direct: direct)
                records.append(ICanHistoryRecord(sequence: sequence, subtype: subtype, glucose: field, currentValue: nil, temperatureC: nil))
            } else {
                let current = decodeCurrentValue(low: decrypted[offset], high: decrypted[offset + 1])
                let temperature = Float(leUnsigned(decrypted, offset + 2)) / 10.0
                records.append(ICanHistoryRecord(sequence: sequence, subtype: subtype, glucose: nil, currentValue: current, temperatureC: temperature))
            }
            sequence += readingIntervalMinutes
            offset += recordSize
        }
        return ICanHistoryBatch(subtype: subtype, baseSequence: base, records: records)
    }

    /// A single encrypted history record: a bare 16-byte block, or a 19-byte frame whose third
    /// byte is the subtype (1 original, 2 glucose).
    static func parseEncryptedHistoryRecord(
        _ data: [UInt8],
        challenge: [UInt8],
        readingOriginalHistory: Bool,
        direct: Bool,
        launcherSerial: String?,
        softwareVersion: String?,
        warmupMinutes: Int
    ) -> ICanHistoryRecord? {
        let subtype: Int
        let payload: [UInt8]
        if data.count == ICanConstants.aesBlockSize {
            subtype = readingOriginalHistory ? ICanConstants.snSubtypeOriginal : ICanConstants.snSubtypeGlucose
            payload = data
        } else if data.count >= ICanConstants.liveFrameSize {
            let headerType = Int(data[2])
            guard headerType == ICanConstants.snSubtypeOriginal || headerType == ICanConstants.snSubtypeGlucose else { return nil }
            subtype = headerType
            payload = Array(data[3..<19])
        } else {
            return nil
        }
        let family = ICanKeyFamily.resolve(launcherSerial: launcherSerial, softwareVersion: softwareVersion)
        let key = subtype == ICanConstants.snSubtypeOriginal ? family.originalHistoryKey : family.glucoseKey
        guard let iv = ICanCrypto.iv(challenge: challenge),
              let decrypted = ICanCrypto.decryptCBC(payload, key: key, iv: iv),
              decrypted.count >= 13 else { return nil }
        let sequence = leUnsigned(decrypted, 4)
        let temperature = Float(leUnsigned(decrypted, 11)) / 10.0
        let current = decodeCurrentValue(low: decrypted[9], high: decrypted[10])
        if subtype == ICanConstants.snSubtypeOriginal {
            return ICanHistoryRecord(sequence: sequence, subtype: subtype, glucose: nil, currentValue: current, temperatureC: temperature)
        }
        guard let bytes = decodeHistoryGlucoseBytes(
            low: decrypted[2],
            high: decrypted[3],
            sequence: sequence,
            challenge: challenge,
            family: family,
            warmupMinutes: warmupMinutes
        ) else { return nil }
        let field = ICanGlucoseField.decode(low: bytes.0, high: bytes.1, direct: direct)
        return ICanHistoryRecord(sequence: sequence, subtype: subtype, glucose: field, currentValue: current, temperatureC: temperature)
    }

    // MARK: RACP

    /// Modern firmware uses F1 as the opcode, older firmware 01.
    private static func racpPrefix(modern: Bool) -> UInt8 {
        return modern ? 0xF1 : 0x01
    }

    static func racpReportAllGlucose(modernPrefix: Bool = true) -> [UInt8] {
        return [racpPrefix(modern: modernPrefix), 0x01, 0x02]
    }

    static func racpReportAllOriginal(modernPrefix: Bool = true) -> [UInt8] {
        return [racpPrefix(modern: modernPrefix), 0x01, 0x01]
    }

    static func racpReportFromGlucose(offset: Int, modernPrefix: Bool = true) -> [UInt8] {
        return racpReportFrom(subtype: UInt8(ICanConstants.snSubtypeGlucose), offset: offset, modernPrefix: modernPrefix)
    }

    static func racpReportFromOriginal(offset: Int, modernPrefix: Bool = true) -> [UInt8] {
        return racpReportFrom(subtype: UInt8(ICanConstants.snSubtypeOriginal), offset: offset, modernPrefix: modernPrefix)
    }

    private static func racpReportFrom(subtype: UInt8, offset: Int, modernPrefix: Bool) -> [UInt8] {
        let safe = min(max(offset, 1), 0xFFFF)
        return [racpPrefix(modern: modernPrefix), 0x03, subtype, 0x01, UInt8(safe & 0xFF), UInt8((safe >> 8) & 0xFF)]
    }

    /// `06 00 F1|01 <code>`.
    static func parseRacpResultCode(_ data: [UInt8]) -> Int? {
        guard data.count >= 4, data[0] == 0x06, data[1] == 0x00, data[2] == 0xF1 || data[2] == 0x01 else { return nil }
        return Int(data[3])
    }

    // MARK: Authentication

    static let requestChallengeCommand: [UInt8] = [0xF3]
    static let requestSensorInfoCommand: [UInt8] = [0xF6]

    /// `06 F3 01 <challenge 4>`.
    static func isChallengeResponse(_ data: [UInt8]) -> Bool {
        return data.count >= 7 && data[0] == 0x06 && data[1] == 0xF3 && data[2] == 0x01
    }

    static func extractChallenge(_ data: [UInt8]) -> [UInt8]? {
        guard isChallengeResponse(data) else { return nil }
        return Array(data[3..<7])
    }

    /// `1C F4 01`.
    static func isAuthSuccess(_ data: [UInt8]) -> Bool {
        return data.count >= 3 && data[0] == 0x1C && data[1] == 0xF4 && data[2] == 0x01
    }

    /// Status byte of an F4 reply, 0x01 accepted and 0x02 rejected.
    static func parseAuthResult(_ data: [UInt8]) -> Int? {
        guard data.count >= 3, data[1] == 0xF4 else { return nil }
        return Int(data[2])
    }

    /// Keeps letters, digits and whitespace of the (lossy UTF-8) plaintext, then trims.
    private static func cleanRecoveredUserId(_ plain: [UInt8]) -> String? {
        let text = String(decoding: plain, as: UTF8.self)
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isLetter = (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
            let isDigit = value >= 0x30 && value <= 0x39
            let isSpace = value == 0x20 || (value >= 0x09 && value <= 0x0D)
            if isLetter || isDigit || isSpace {
                kept.append(scalar)
            }
        }
        let cleaned = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// A rejected F4 (`<xx> F4 02 <16 bytes> <non-zero trailer>`) carries the user id the sensor
    /// is bound to, encrypted with the auth key and the same IV.
    static func recoverUserIdFromAuthReject(_ data: [UInt8], challenge: [UInt8]?, authKey: [UInt8]) -> String? {
        guard data.count >= 20, data[1] == 0xF4, data[2] == 0x02, data[data.count - 1] != 0 else { return nil }
        guard let challenge = challenge, let iv = ICanCrypto.iv(challenge: challenge) else { return nil }
        guard let plain = ICanCrypto.decryptCBC(Array(data[3..<19]), key: authKey, iv: iv) else { return nil }
        return cleanRecoveredUserId(plain)
    }

    /// Printable characters only (0x21...0x7E), no whitespace.
    static func normalizeConfiguredUserId(_ source: String?) -> String {
        guard let source = source else { return "" }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars where scalar.value >= 0x21 && scalar.value <= 0x7E {
            kept.append(scalar)
        }
        return String(kept)
    }

    /// The last 12 characters, right-padded with "0", or twelve zeros.
    static func normalizeStandaloneUserId(_ source: String?) -> String {
        let normalized = normalizeConfiguredUserId(source)
        if normalized.count >= 12 {
            return String(normalized.suffix(12))
        }
        if !normalized.isEmpty {
            return normalized + String(repeating: "0", count: 12 - normalized.count)
        }
        return String(repeating: "0", count: 12)
    }

    /// `F4 0C <12 user id bytes>` encrypted with the auth key (14 bytes plaintext, 16 bytes token).
    static func deriveAuthToken(challenge: [UInt8], userId: String, authKey: [UInt8]) -> [UInt8]? {
        guard let iv = ICanCrypto.iv(challenge: challenge) else { return nil }
        let id = Array(normalizeStandaloneUserId(userId).utf8)
        var plain = [UInt8](repeating: 0, count: 14)
        plain[0] = 0xF4
        plain[1] = UInt8(id.count)
        for (index, byte) in id.enumerated() where 2 + index < plain.count {
            plain[2 + index] = byte
        }
        guard let token = ICanCrypto.encryptCBC(plain, key: authKey, iv: iv), token.count == ICanConstants.aesBlockSize else { return nil }
        return token
    }

    /// `F4 10 <token 16>`.
    static func buildAuthTokenPacket(_ token: [UInt8]) -> [UInt8]? {
        guard token.count == ICanConstants.aesBlockSize else { return nil }
        return [0xF4, 0x10] + token
    }

    /// `1C F6 01 <marker u16 LE>`.
    static func isSensorInfoResponse(_ data: [UInt8]) -> Bool {
        return data.count >= 3 && data[0] == 0x1C && data[1] == 0xF6 && data[2] == 0x01
    }

    static func parseSensorInfoMarker(_ data: [UInt8]) -> Int? {
        guard isSensorInfoResponse(data), data.count >= 5 else { return nil }
        return (Int(data[4]) << 8) | Int(data[3])
    }

    /// Device Information strings: printable ASCII as text, anything else as hex.
    static func parseDeviceString(_ data: [UInt8]) -> String {
        if data.isEmpty { return "" }
        let printable = data.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        if printable {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return data.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - History policy

struct ICanSequenceGap: Equatable {
    let startSequence: Int
    let endSequenceExclusive: Int
    let intervalMinutes: Int

    var readingCount: Int { return (endSequenceExclusive - startSequence) / intervalMinutes }

    func contains(_ sequence: Int) -> Bool {
        return sequence >= startSequence && sequence < endSequenceExclusive && (sequence - startSequence) % intervalMinutes == 0
    }
}

enum ICanHistoryPolicy {
    /// Readings the sensor produced between two live sequences that were never delivered. The
    /// counter advances one unit per minute, so a three-minute sensor steps by three.
    static func missedReadingsBetween(previousSequence: Int, currentSequence: Int, readingIntervalMinutes: Int) -> Int {
        if previousSequence < 0 || currentSequence <= previousSequence || readingIntervalMinutes <= 0 {
            return 0
        }
        return max(0, (currentSequence - previousSequence) / readingIntervalMinutes - 1)
    }

    static func liveGapBetween(previousSequence: Int, currentSequence: Int, readingIntervalMinutes: Int) -> ICanSequenceGap? {
        let missed = missedReadingsBetween(
            previousSequence: previousSequence,
            currentSequence: currentSequence,
            readingIntervalMinutes: readingIntervalMinutes
        )
        if missed < 1 { return nil }
        return ICanSequenceGap(
            startSequence: previousSequence + readingIntervalMinutes,
            endSequenceExclusive: currentSequence,
            intervalMinutes: readingIntervalMinutes
        )
    }

    /// Where a history request starts: the pending live gap, else the reading after the newest
    /// known one (when the live edge is past it), else the first reading.
    static func automaticGlucoseHistoryStartSequence(
        readingIntervalMinutes: Int,
        currentSequence: Int,
        latestKnownSequence: Int,
        pendingLiveGap: ICanSequenceGap?
    ) -> Int? {
        if let gap = pendingLiveGap, gap.startSequence >= readingIntervalMinutes, gap.startSequence < currentSequence {
            return gap.startSequence
        }
        if latestKnownSequence >= readingIntervalMinutes {
            let next = latestKnownSequence + readingIntervalMinutes
            return currentSequence >= next ? next : nil
        }
        return readingIntervalMinutes
    }

    /// One live-edge retry after a refused request: only when the refused request was well behind
    /// the tail (more than one interval) and the live edge is known.
    static func tailRetryStartSequence(readingIntervalMinutes: Int, currentSequence: Int, requestedSequence: Int) -> Int? {
        if readingIntervalMinutes <= 0 { return nil }
        let liveEdge = currentSequence - readingIntervalMinutes
        if liveEdge < readingIntervalMinutes { return nil }
        return requestedSequence < liveEdge - readingIntervalMinutes ? liveEdge : nil
    }

    static func shouldSkipHistoryOverlap(
        sequence: Int,
        sampleTime: Date?,
        coveredSequence: Int,
        coveredTime: Date?,
        pendingLiveGap: ICanSequenceGap?
    ) -> Bool {
        if let gap = pendingLiveGap, gap.contains(sequence) { return false }
        if coveredSequence >= 0, sequence >= 0, sequence <= coveredSequence { return true }
        if let covered = coveredTime, let sample = sampleTime { return sample <= covered }
        return false
    }
}

// MARK: - Timeline

/// What the driver knows about how sequence numbers map to wall-clock time. The sequence counts
/// minutes since session start; the counter read from 2AA9 (or the newest live frame) together
/// with the moment it was observed is the anchor.
struct ICanClock: Equatable {
    var sessionStart: Date?
    var counter: Int?
    var counterObservedAt: Date?
}

enum ICanTimeline {
    static let sequenceUnit: TimeInterval = 60
    static let sessionCounterTolerance: TimeInterval = 30 * 60
    static let maxPastDrift: TimeInterval = 6 * 60 * 60
    static let maxFutureDrift: TimeInterval = 2 * 60
    static let maxLiveLag: TimeInterval = 10 * 60

    private static let epochFloor = Date(timeIntervalSince1970: 1)

    /// The session start explains the counter while `start + counter * 60` lands within 30
    /// minutes of the moment the counter was read (symmetric: a negative UTC offset drags the
    /// start into the past, a positive one into the future).
    static func sessionMatchesCounter(sessionStart: Date?, counter: Int?, counterObservedAt: Date?) -> Bool {
        guard let start = sessionStart, start.timeIntervalSince1970 > 0 else { return false }
        guard let counter = counter, counter >= 0 else { return true }
        guard let observed = counterObservedAt, observed.timeIntervalSince1970 > 0 else { return false }
        let implied = start.addingTimeInterval(Double(counter) * sequenceUnit)
        return abs(implied.timeIntervalSince(observed)) <= sessionCounterTolerance
    }

    private static func canUseSessionTimeline(_ clock: ICanClock, anchor: Date) -> Bool {
        guard let start = clock.sessionStart, start.timeIntervalSince1970 > 0 else { return false }
        guard let counter = clock.counter, counter >= 0 else { return true }
        let candidate = start.addingTimeInterval(Double(counter) * sequenceUnit)
        return candidate >= anchor.addingTimeInterval(-maxPastDrift) && candidate <= anchor.addingTimeInterval(maxFutureDrift)
    }

    /// The time of a sequence number, or nil when nothing plausible fits. `requireRecent` is the
    /// live path (candidate within 6 h of now); history may reach back to the session start.
    static func resolve(sequence: Int, now: Date, clock: ICanClock, requireRecent: Bool) -> Date? {
        if sequence < 0 { return nil }
        let anchor = clock.counterObservedAt ?? now
        let latest = now.addingTimeInterval(maxFutureDrift)
        let matches = sessionMatchesCounter(
            sessionStart: clock.sessionStart,
            counter: clock.counter,
            counterObservedAt: clock.counterObservedAt ?? now
        )
        let useSession = matches && (requireRecent ? canUseSessionTimeline(clock, anchor: anchor) : clock.sessionStart != nil)
        if useSession, let start = clock.sessionStart {
            let candidate = start.addingTimeInterval(Double(sequence) * sequenceUnit)
            let lower = requireRecent ? now.addingTimeInterval(-maxPastDrift) : epochFloor
            if candidate >= lower && candidate <= latest {
                return candidate
            }
        }
        if let counter = clock.counter, counter >= 0 {
            let candidate = anchor.addingTimeInterval(-Double(counter - sequence) * sequenceUnit)
            let lower: Date
            if requireRecent {
                lower = now.addingTimeInterval(-maxPastDrift)
            } else if let start = clock.sessionStart, start.timeIntervalSince1970 > 0 {
                lower = start.addingTimeInterval(-maxPastDrift)
            } else {
                lower = epochFloor
            }
            if candidate >= lower && candidate <= latest {
                return candidate
            }
        }
        return nil
    }

    /// Timestamp for a frame that has just arrived. A candidate at most five seconds ahead is
    /// clamped to now and one further ahead is rejected (now); the newest sequence that lags the
    /// wall clock by more than ten minutes means a skewed anchor, so it is stamped now as well.
    static func liveTimestamp(sequence: Int, now: Date, clock: ICanClock) -> Date {
        if sequence < 0 { return now }
        guard let resolved = resolve(sequence: sequence, now: now, clock: clock, requireRecent: true) else { return now }
        if resolved > now { return now }
        let counter = clock.counter ?? -1
        let isNewest = counter < 0 || sequence >= counter
        if isNewest && now.timeIntervalSince(resolved) > maxLiveLag {
            return now
        }
        return resolved
    }
}
