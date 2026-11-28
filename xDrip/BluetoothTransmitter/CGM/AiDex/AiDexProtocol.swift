//
//  AiDexProtocol.swift
//  xdrip
//
//  Pure protocol layer of the AiDex X / LinX CGM driver: serial-derived crypto, AES-128-CFB, CRCs,
//  the F001/F002/F003 key exchange, the F002 command builder, live and history parsers, history
//  merge and download policy, session start decoding and the decisions the transmitter takes.
//  Ported from the JugglucoNG `drivers/aidex/native` package (GPL-3.0, see THIRD_PARTY_NOTICES.md).
//  Nothing here touches Bluetooth, so everything is covered by unit tests (`AiDexProtocolTests`),
//  whose expected values were computed by running the unchanged Kotlin on the JVM.
//
//  Left out on purpose: the China-mainland cloud key endpoint (`AiDexCnCloudClient`, provisioned
//  pairing material), the default-parameter provisioning, the wear-profile catalogue, the broadcast
//  scan payload parser, blood-glucose calibration and the adaptive algorithm.
//
//  Never tried on a real sensor.
//

import CommonCrypto
import CoreBluetooth
import CryptoKit
import Foundation

// MARK: - GATT

enum AiDexGATT {
    /// CGM service. The sensor's vendor characteristics F001..F003 live in it, next to the standard
    /// CGM Session Start Time (2AAA) and Session Run Time (2AAB).
    static let cgmService = CBUUID(string: "181F")
    /// F001: write the serial-derived challenge, the PAIR key comes back as a notification. Needs an
    /// encrypted link, so touching it makes iOS pair with the sensor.
    static let f001 = CBUUID(string: "F001")
    /// F002: command write and response notification; a read returns the 17-byte BOND vector.
    static let f002 = CBUUID(string: "F002")
    /// F003: live glucose frames (17 bytes, AES-CFB) and 5-byte status frames.
    static let f003 = CBUUID(string: "F003")

    static let deviceInfoService = CBUUID(string: "180A")
    static let modelNumber = CBUUID(string: "2A24")
    static let softwareRevision = CBUUID(string: "2A28")
    static let manufacturer = CBUUID(string: "2A29")

    static let sessionStart = CBUUID(string: "2AAA")
    static let sessionRun = CBUUID(string: "2AAB")
}

// MARK: - Opcodes and constants

enum AiDexOpcodes {
    static let getStartupDeviceInfo = 0x10
    static let getBroadcastData = 0x11
    static let setNewSensor = 0x20
    static let getLocalStartTime = 0x21
    static let getHistoryRange = 0x22
    static let getHistoriesRaw = 0x23
    static let getHistories = 0x24
    static let setCalibration = 0x25
    static let getCalibrationRange = 0x26
    static let getCalibration = 0x27
    static let setDefaultParam = 0x30
    static let getDefaultParam = 0x31
    static let getSensorCheck = 0x32
    static let getAutoUpdateStatus = 0x33
    static let setAutoUpdateStatus = 0x34
    static let setDynamicAdvMode = 0x35
    static let deleteBond = 0xF2
    static let reset = 0xF0
    static let shelfMode = 0xF1
    static let clearStorage = 0xF3

    /// Length of a glucose data frame on F003.
    static let dataFrameLength = 17
    /// Length of a status / keepalive frame on F003.
    static let statusFrameLength = 5
    static let glucoseMask = 0x03FF
    static let maxValidGlucose = 500
    static let minValidGlucose = 20
    /// 10-bit "no reading".
    static let sentinelGlucose = 1023

    static let directOpcodes: Set<Int> = [0xA1, 0xA4, 0x5B, 0xD7]
    static let halfScaleOpcodes: Set<Int> = [0xD2]

    static let historyRawRowSize = 2
    static let historyBriefRowSize = 5
    static let calibrationRowSize = 8

    /// Scaling of the 10-bit value for a data-frame opcode; nil for an unknown opcode (the value is
    /// then used unscaled, as in JugglucoNG).
    static func scalingFactor(opcode: Int) -> Float? {
        if directOpcodes.contains(opcode) { return 1.0 }
        if halfScaleOpcodes.contains(opcode) { return 0.5 }
        return nil
    }

    static let knownNamePrefixes = ["AiDex", "AiDEX", "AIDEX", "Linx", "LINX", "CGM", "Smart-", "IndiaX-", "VitaTok-"]

    static func isAiDexDevice(name: String?) -> Bool {
        guard let name = name else { return false }
        return knownNamePrefixes.contains { name.hasPrefix($0) }
    }
}

// MARK: - CRC-8/MAXIM

enum AiDexCrc8Maxim {
    private static let table: [Int] = [
        0x00, 0x5e, 0xbc, 0xe2, 0x61, 0x3f, 0xdd, 0x83, 0xc2, 0x9c, 0x7e, 0x20, 0xa3, 0xfd, 0x1f, 0x41,
        0x9d, 0xc3, 0x21, 0x7f, 0xfc, 0xa2, 0x40, 0x1e, 0x5f, 0x01, 0xe3, 0xbd, 0x3e, 0x60, 0x82, 0xdc,
        0x23, 0x7d, 0x9f, 0xc1, 0x42, 0x1c, 0xfe, 0xa0, 0xe1, 0xbf, 0x5d, 0x03, 0x80, 0xde, 0x3c, 0x62,
        0xbe, 0xe0, 0x02, 0x5c, 0xdf, 0x81, 0x63, 0x3d, 0x7c, 0x22, 0xc0, 0x9e, 0x1d, 0x43, 0xa1, 0xff,
        0x46, 0x18, 0xfa, 0xa4, 0x27, 0x79, 0x9b, 0xc5, 0x84, 0xda, 0x38, 0x66, 0xe5, 0xbb, 0x59, 0x07,
        0xdb, 0x85, 0x67, 0x39, 0xba, 0xe4, 0x06, 0x58, 0x19, 0x47, 0xa5, 0xfb, 0x78, 0x26, 0xc4, 0x9a,
        0x65, 0x3b, 0xd9, 0x87, 0x04, 0x5a, 0xb8, 0xe6, 0xa7, 0xf9, 0x1b, 0x45, 0xc6, 0x98, 0x7a, 0x24,
        0xf8, 0xa6, 0x44, 0x1a, 0x99, 0xc7, 0x25, 0x7b, 0x3a, 0x64, 0x86, 0xd8, 0x5b, 0x05, 0xe7, 0xb9,
        0x8c, 0xd2, 0x30, 0x6e, 0xed, 0xb3, 0x51, 0x0f, 0x4e, 0x10, 0xf2, 0xac, 0x2f, 0x71, 0x93, 0xcd,
        0x11, 0x4f, 0xad, 0xf3, 0x70, 0x2e, 0xcc, 0x92, 0xd3, 0x8d, 0x6f, 0x31, 0xb2, 0xec, 0x0e, 0x50,
        0xaf, 0xf1, 0x13, 0x4d, 0xce, 0x90, 0x72, 0x2c, 0x6d, 0x33, 0xd1, 0x8f, 0x0c, 0x52, 0xb0, 0xee,
        0x32, 0x6c, 0x8e, 0xd0, 0x53, 0x0d, 0xef, 0xb1, 0xf0, 0xae, 0x4c, 0x12, 0x91, 0xcf, 0x2d, 0x73,
        0xca, 0x94, 0x76, 0x28, 0xab, 0xf5, 0x17, 0x49, 0x08, 0x56, 0xb4, 0xea, 0x69, 0x37, 0xd5, 0x8b,
        0x57, 0x09, 0xeb, 0xb5, 0x36, 0x68, 0x8a, 0xd4, 0x95, 0xcb, 0x29, 0x77, 0xf4, 0xaa, 0x48, 0x16,
        0xe9, 0xb7, 0x55, 0x0b, 0x88, 0xd6, 0x34, 0x6a, 0x2b, 0x75, 0x97, 0xc9, 0x4a, 0x14, 0xf6, 0xa8,
        0x74, 0x2a, 0xc8, 0x96, 0x15, 0x4b, 0xa9, 0xf7, 0xb6, 0xe8, 0x0a, 0x54, 0xd7, 0x89, 0x6b, 0x35
    ]

    /// accumulator = table[byte xor accumulator], starting at 0 (the vendor library's routine).
    static func checksum(_ data: [UInt8]) -> Int {
        var accumulator = 0
        for byte in data {
            accumulator = table[Int(byte) ^ accumulator]
        }
        return accumulator & 0xFF
    }
}

// MARK: - CRC-16/CCITT-FALSE

/// Polynomial 0x1021, initial 0xFFFF, no reflection, no final xor. The 2-byte little-endian
/// trailer of every F002 command and response.
enum AiDexCrc16 {
    static func checksum(_ data: [UInt8]) -> Int {
        var crc = 0xFFFF
        for byte in data {
            crc ^= Int(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
            crc &= 0xFFFF
        }
        return crc
    }

    /// `[opcode, params..., crc_lo, crc_hi]`; every parameter is truncated to one byte.
    static func makeCommand(opcode: Int, params: [Int] = []) -> [UInt8] {
        var payload: [UInt8] = [UInt8(truncatingIfNeeded: opcode)]
        for param in params {
            payload.append(UInt8(truncatingIfNeeded: param))
        }
        let crc = checksum(payload)
        payload.append(UInt8(crc & 0xFF))
        payload.append(UInt8((crc >> 8) & 0xFF))
        return payload
    }

    /// `[opcode, param_lo, param_hi, crc_lo, crc_hi]`.
    static func makeCommandWithU16(opcode: Int, param: Int) -> [UInt8] {
        return makeCommand(opcode: opcode, params: [param & 0xFF, (param >> 8) & 0xFF])
    }

    /// True when the last two bytes are the CRC-16 of everything before them.
    static func validateResponse(_ data: [UInt8]) -> Bool {
        guard data.count >= 3 else { return false }
        let payload = Array(data[0..<(data.count - 2)])
        let expected = checksum(payload)
        let actual = Int(data[data.count - 2]) | (Int(data[data.count - 1]) << 8)
        return expected == actual
    }
}

// MARK: - AES-128-CFB and MD5

/// AES-128-CFB (128-bit feedback) built on a single-block ECB primitive, exactly as the Kotlin
/// original: the feedback register is always the ciphertext block.
enum AiDexCrypto {
    static let blockSize = 16

    static func ecbEncrypt(block: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard block.count == blockSize, key.count == kCCKeySizeAES128 else { return nil }
        var output = [UInt8](repeating: 0, count: blockSize + kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            block.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count,
                        nil,
                        inputBytes.baseAddress, block.count,
                        outputBytes.baseAddress, outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == blockSize else { return nil }
        return Array(output.prefix(blockSize))
    }

    /// Nil for an empty input or a key or IV that is not 16 bytes.
    static func cfbDecrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        return cfb(ciphertext, key: key, iv: iv, decrypting: true)
    }

    static func cfbEncrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        return cfb(plaintext, key: key, iv: iv, decrypting: false)
    }

    private static func cfb(_ input: [UInt8], key: [UInt8], iv: [UInt8], decrypting: Bool) -> [UInt8]? {
        guard key.count == blockSize, iv.count == blockSize, !input.isEmpty else { return nil }
        var result = [UInt8](repeating: 0, count: input.count)
        var feedback = iv
        var offset = 0
        while offset < input.count {
            let chunk = min(blockSize, input.count - offset)
            guard let keystream = ecbEncrypt(block: feedback, key: key) else { return nil }
            for index in 0..<chunk {
                result[offset + index] = input[offset + index] ^ keystream[index]
            }
            if chunk == blockSize {
                if decrypting {
                    feedback = Array(input[offset..<(offset + blockSize)])
                } else {
                    feedback = Array(result[offset..<(offset + blockSize)])
                }
            }
            offset += chunk
        }
        return result
    }

    /// The 17-byte BOND vector read from F002, decrypted with the PAIR key and the serial IV:
    /// 16 bytes of session key and a CRC-8/MAXIM of them. Nil when the CRC does not match.
    static func decryptBondData(_ bondData: [UInt8], pairKey: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard bondData.count == 17, pairKey.count == blockSize, iv.count == blockSize else { return nil }
        guard let decrypted = cfbDecrypt(bondData, key: pairKey, iv: iv) else { return nil }
        let sessionKey = Array(decrypted[0..<blockSize])
        guard Int(decrypted[blockSize]) == AiDexCrc8Maxim.checksum(sessionKey) else { return nil }
        return sessionKey
    }

    static func md5(_ data: [UInt8]) -> [UInt8] {
        return Array(Insecure.MD5.hash(data: Data(data)))
    }
}

// MARK: - Serial identity

/// Advertisement names carry the serial behind a one-letter generation prefix ("AiDEX X-2222267V4E",
/// "Lumi-2222258CUW", "Smart-22222BZTJ3", "IndiaX-22222E7T6K", "VitaTok-22222DA48D"). The prefix is a
/// label, never a protocol capability; the bare serial is what the crypto uses.
enum AiDexSerialIdentity {
    private static let canonicalPrefix = "X-"
    private static let minSerialLength = 8
    private static let maxSerialLength = 14

    private static let generationPrefixed = try! NSRegularExpression(
        pattern: "(?:^|\\s)(?:AIDEX\\s+)?[A-Z]\\s*-\\s*([A-Z0-9]{8,14})(?=$|\\s)",
        options: [.caseInsensitive]
    )

    /// A family word may carry the generation letter glued to it ("IndiaX-22222E7T6K") or none ("VitaTok-22222DA48D").
    private static let familyPrefixed = try! NSRegularExpression(
        pattern: "(?:^|\\s)(?:AIDEX|LINX|LUMI|VISTA|SMART|INDIA|VITATOK)\\s*(?:[A-Z]\\s*-|[-_])?\\s*([A-Z0-9]{8,14})(?=$|\\s)",
        options: [.caseInsensitive]
    )

    /// F-generation sensors ("AiDEX F-22222FZXKT"): the manufacturer's app fetches sensor-specific
    /// pairing keys for them from a cloud service.
    private static let fSeriesName = try! NSRegularExpression(
        pattern: "(?:^|\\s)(?:AIDEX\\s+)?F\\s*-\\s*[A-Z0-9]{8,14}(?:$|\\s)",
        options: [.caseInsensitive]
    )

    private static let lumiBrand = try! NSRegularExpression(
        pattern: "^\\s*lumi(?:flex)?(?=$|[\\s_0-9-])",
        options: [.caseInsensitive]
    )

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[groupRange])
    }

    private static func contains(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// "X-" plus the upper-cased serial, or nil when the name does not look like an AiDex advertisement.
    static func canonicalFromAdvertisement(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let serial = firstGroup(generationPrefixed, in: trimmed) {
            return canonicalPrefix + serial.uppercased()
        }
        if let serial = firstGroup(familyPrefixed, in: trimmed) {
            return canonicalPrefix + serial.uppercased()
        }
        // The narrow bare-name form: eleven letters or digits, not any alphanumeric device name.
        let cleaned = trimmed.replacingOccurrences(of: " ", with: "")
        if cleaned.count == 11 && cleaned.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return canonicalPrefix + cleaned.uppercased()
        }
        return nil
    }

    /// The serial without prefix, from an advertisement name, a canonical "X-..." identity or a bare serial.
    static func bareSerial(_ serialOrAdvertisementName: String) -> String {
        if let canonical = canonicalFromAdvertisement(serialOrAdvertisementName) {
            return String(canonical.dropFirst(canonicalPrefix.count))
        }
        let trimmed = serialOrAdvertisementName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= minSerialLength && trimmed.count <= maxSerialLength
            && trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return trimmed.uppercased()
        }
        return trimmed
    }

    /// "LUMI" for a rebrand that names its product line, else nil (the family's own badge).
    static func productBrandFromAdvertisement(_ rawName: String?) -> String? {
        guard let rawName = rawName, !rawName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return contains(lumiBrand, in: rawName) ? "LUMI" : nil
    }

    /// True for an F-generation advertisement name.
    static func isFSeriesAdvertisement(_ rawName: String) -> Bool {
        return contains(fSeriesName, in: rawName)
    }

    /// An advertised name matches a sensor when it contains the bare serial or the whole identity.
    static func deviceNameMatchesSerial(deviceName: String, serial: String) -> Bool {
        let bare = bareSerial(serial)
        return deviceName.range(of: bare, options: .caseInsensitive) != nil
            || deviceName.range(of: serial, options: .caseInsensitive) != nil
    }
}

// MARK: - Serial-derived secret and IV

enum AiDexSerialCrypto {

    /// '0'-'9' -> 0-9, 'A'-'Z' and 'a'-'z' -> 10-35, anything else -> 0 (the vendor's snToBytes).
    static func charToNumeric(_ unit: UInt16) -> Int {
        switch unit {
        case 0x30...0x39: return Int(unit) - 0x30
        case 0x41...0x5A: return Int(unit) - 0x41 + 10
        case 0x61...0x7A: return Int(unit) - 0x61 + 10
        default: return 0
        }
    }

    /// One numeric byte per serial character; the serial must not carry the "X-" prefix.
    static func snToBytes(_ serial: String) -> [UInt8] {
        return serial.utf16.map { UInt8(charToNumeric($0)) }
    }

    /// F001 challenge: MD5 of snToBytes(serial) mapped to (b * 13 + 61) and 0xFF.
    static func deriveSecret(_ serial: String) -> [UInt8] {
        let transformed = snToBytes(serial).map { UInt8(truncatingIfNeeded: Int($0) * 13 + 61) }
        return AiDexCrypto.md5(transformed)
    }

    /// IV for BOND, F003 and F002: MD5 of snToBytes(serial) mapped to (b * 17 + 19) and 0xFF.
    static func deriveIv(_ serial: String) -> [UInt8] {
        let transformed = snToBytes(serial).map { UInt8(truncatingIfNeeded: Int($0) * 17 + 19) }
        return AiDexCrypto.md5(transformed)
    }
}

// MARK: - Key exchange

/// The vendor key exchange for one sensor connection:
///   1. write the serial-derived secret to F001 (fresh pairing only)
///   2. the PAIR key arrives as an F001 notification (stable until the sensor forgets the pairing)
///   3. read F002: 17 bytes of BOND data
///   4. decrypt BOND with the PAIR key and the serial IV: the 16-byte session key (new each connection)
///   5. F003 frames and F002 responses are decrypted, F002 commands encrypted, with session key and serial IV
final class AiDexKeyExchange {
    let serial: String
    /// The serial without "X-" or "AiDEX X-" prefix; the derivation takes this form.
    let bareSerial: String
    let snSecret: [UInt8]
    let snIv: [UInt8]
    private(set) var pairKey: [UInt8]?
    private(set) var sessionKey: [UInt8]?

    init(serial: String) {
        self.serial = serial
        self.bareSerial = AiDexSerialIdentity.bareSerial(serial)
        self.snSecret = AiDexSerialCrypto.deriveSecret(bareSerial)
        self.snIv = AiDexSerialCrypto.deriveIv(bareSerial)
    }

    var isComplete: Bool { return sessionKey != nil }

    func getChallenge() -> [UInt8] { return snSecret }

    func onPairKeyReceived(_ data: [UInt8]) {
        pairKey = data
    }

    /// True when the BOND data decrypted and its CRC-8 matched; the session key is then set.
    func decryptBond(_ bondData: [UInt8]) -> Bool {
        guard let pairKey = pairKey,
              let key = AiDexCrypto.decryptBondData(bondData, pairKey: pairKey, iv: snIv) else { return false }
        sessionKey = key
        return true
    }

    /// The encrypted `[0x10, 0xC1, 0xF3]` (startup device info with its CRC).
    func getPostBondConfig() -> [UInt8]? {
        guard let sessionKey = sessionKey else { return nil }
        return AiDexCrypto.cfbEncrypt([0x10, 0xC1, 0xF3], key: sessionKey, iv: snIv)
    }

    func encrypt(_ plaintext: [UInt8]) -> [UInt8]? {
        guard let sessionKey = sessionKey else { return nil }
        return AiDexCrypto.cfbEncrypt(plaintext, key: sessionKey, iv: snIv)
    }

    func decrypt(_ ciphertext: [UInt8]) -> [UInt8]? {
        guard let sessionKey = sessionKey else { return nil }
        return AiDexCrypto.cfbDecrypt(ciphertext, key: sessionKey, iv: snIv)
    }

    /// Forget PAIR and session key for a new connection (the serial-derived values stay).
    func reset() {
        pairKey = nil
        sessionKey = nil
    }
}

// MARK: - Command builder

/// Builds encrypted F002 commands from the session key of a completed key exchange; every builder
/// returns nil until the key exchange has produced a session key.
struct AiDexCommandBuilder {
    let keyExchange: AiDexKeyExchange

    func buildEncrypted(opcode: Int, params: [Int] = []) -> [UInt8]? {
        return keyExchange.encrypt(AiDexCrc16.makeCommand(opcode: opcode, params: params))
    }

    func getStartupDeviceInfo() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.getStartupDeviceInfo) }
    func getLegacyStartTime() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.getLocalStartTime) }
    func getBroadcastData() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.getBroadcastData) }
    func getSensorCheck(index: Int = 0x01) -> [UInt8]? {
        return buildEncrypted(opcode: AiDexOpcodes.getSensorCheck, params: [index & 0xFF])
    }
    func getAutoUpdateStatus() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.getAutoUpdateStatus) }
    func getHistoryRange() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.getHistoryRange) }

    func getHistoriesRaw(offset: Int) -> [UInt8]? {
        return buildEncrypted(opcode: AiDexOpcodes.getHistoriesRaw, params: [offset & 0xFF, (offset >> 8) & 0xFF])
    }

    func getHistories(offset: Int) -> [UInt8]? {
        return buildEncrypted(opcode: AiDexOpcodes.getHistories, params: [offset & 0xFF, (offset >> 8) & 0xFF])
    }

    /// SET_NEW_SENSOR: `[year_lo, year_hi, month, day, hour, minute, second, tz_quarters, dst_quarters]`.
    func setNewSensor(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, tzQuarters: Int, dstQuarters: Int) -> [UInt8]? {
        return buildEncrypted(
            opcode: AiDexOpcodes.setNewSensor,
            params: [year & 0xFF, (year >> 8) & 0xFF, month, day, hour, minute, second, tzQuarters, dstQuarters]
        )
    }

    /// SET_CALIBRATION: the offset comes first, the glucose second (the vendor library's order).
    func setCalibration(offsetMinutes: Int, glucoseMgDl: Int) -> [UInt8]? {
        return buildEncrypted(
            opcode: AiDexOpcodes.setCalibration,
            params: [offsetMinutes & 0xFF, (offsetMinutes >> 8) & 0xFF, glucoseMgDl & 0xFF, (glucoseMgDl >> 8) & 0xFF]
        )
    }

    func getCalibrationRange() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.getCalibrationRange) }

    func getCalibration(index: Int) -> [UInt8]? {
        return buildEncrypted(opcode: AiDexOpcodes.getCalibration, params: [index & 0xFF, (index >> 8) & 0xFF])
    }

    func setAutoUpdateStatus(enabled: Bool = true) -> [UInt8]? {
        return buildEncrypted(opcode: AiDexOpcodes.setAutoUpdateStatus, params: [enabled ? 0x01 : 0x00])
    }

    func setDynamicAdvMode(_ mode: Int) -> [UInt8]? {
        return buildEncrypted(opcode: AiDexOpcodes.setDynamicAdvMode, params: [mode & 0xFF])
    }

    func deleteBond() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.deleteBond) }
    func reset() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.reset) }
    func clearStorage() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.clearStorage) }
    func shelfMode() -> [UInt8]? { return buildEncrypted(opcode: AiDexOpcodes.shelfMode) }
}

// MARK: - Parsed data

/// One decrypted 17-byte F003 data frame.
struct AiDexGlucoseFrame: Equatable {
    let opcode: Int
    /// Minutes since the sensor session started (u16 LE at bytes 4 and 5).
    let timeOffsetMinutes: Int
    /// Glucose in mg/dL after the opcode scaling.
    let glucoseMgDl: Float
    /// The 16-bit value that carries the 10-bit glucose.
    let rawGlucosePacked: Int
    let i1: Float
    let i2: Float
    let crc16: Int
    let isValid: Bool

    /// The `i2` channel tracks skin temperature in degrees Celsius.
    var temperatureC: Float { return i2 }
}

/// One 0x23 row: factory-calibrated glucose.
struct AiDexCalibratedHistoryEntry: Equatable {
    let timeOffsetMinutes: Int
    let glucoseMgDl: Int
    let statusBit: Bool
    let isSentinel: Bool
}

/// One 0x24 row: the raw channels.
struct AiDexAdcHistoryEntry: Equatable {
    let timeOffsetMinutes: Int
    let i1: Float
    let i2: Float
    let vc: Float
    /// i1 * 10
    let rawValue: Float
    /// i1 * 18.0182
    let sensorGlucose: Float

    var temperatureC: Float { return i2 }
}

struct AiDexCalibrationRecord: Equatable {
    let index: Int
    let timeOffsetMinutes: Int
    let referenceGlucoseMgDl: Int
    let calibrationFactor: Float
    let calibrationOffset: Float
}

struct AiDexStartupDeviceInfo: Equatable {
    let firmwareVersion: String
    let hardwareVersion: String
    let wearDays: Int
    let modelName: String
}

/// The date the sensor reports in 2AAA (and in the legacy 0x21 reply): local wall-clock time plus the
/// time zone the sensor was started in, in quarters of an hour.
struct AiDexLocalStartTime: Equatable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    let tzQuarters: Int
    let dstQuarters: Int

    var isAllZeros: Bool {
        return year == 0 && month == 0 && day == 0 && hour == 0 && minute == 0 && second == 0
    }

    /// Seconds to subtract from the wall-clock time to get UTC. The daylight-saving part counts only
    /// when it is exactly four quarters, as in JugglucoNG.
    var utcOffsetSeconds: Int {
        return tzQuarters * 15 * 60 + (dstQuarters == 4 ? 3600 : 0)
    }

    /// The moment the session started, nil for all zeros and for a date that is not after 1970 or
    /// more than a day in the future.
    func date(now: Date = Date()) -> Date? {
        guard !isAllZeros else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let wallClock = calendar.date(from: components) else { return nil }
        let start = wallClock.addingTimeInterval(-Double(utcOffsetSeconds))
        guard start.timeIntervalSince1970 > 0, start.timeIntervalSince1970 < now.timeIntervalSince1970 + 86_400 else { return nil }
        return start
    }
}

// MARK: - Parser

enum AiDexParser {

    enum FrameType: Equatable {
        case data
        case status
        case unknown
    }

    static func classifyFrame(_ data: [UInt8]) -> FrameType {
        switch data.count {
        case AiDexOpcodes.dataFrameLength: return .data
        case AiDexOpcodes.statusFrameLength: return .status
        default: return .unknown
        }
    }

    /// Layout of the 17-byte F003 frame: byte 0 opcode, bytes 4-5 minute offset (u16 LE), bytes 6-7 packed
    /// glucose (low 10 bits), bytes 8-9 and 10-11 the i1 and i2 channels (u16 LE, hundredths), bytes 15-16 CRC-16.
    static func parseDataFrame(_ data: [UInt8]) -> AiDexGlucoseFrame? {
        guard data.count == AiDexOpcodes.dataFrameLength else { return nil }

        let opcode = Int(data[0])
        let timeOffsetMinutes = u16LE(data, 4)
        let glucosePacked = u16LE(data, 6)
        let rawGlucose = glucosePacked & AiDexOpcodes.glucoseMask
        let i1Raw = u16LE(data, 8)
        let i2Raw = u16LE(data, 10)
        let crc16 = u16LE(data, 15)

        let i1 = Float(i1Raw) / 100
        let i2 = Float(i2Raw) / 100

        let glucoseMgDl: Float
        if let scaling = AiDexOpcodes.scalingFactor(opcode: opcode) {
            glucoseMgDl = Float(rawGlucose) * scaling
        } else {
            glucoseMgDl = Float(rawGlucose)
        }

        let isSentinel = rawGlucose == AiDexOpcodes.sentinelGlucose
        let isInRange = rawGlucose >= AiDexOpcodes.minValidGlucose && rawGlucose <= AiDexOpcodes.maxValidGlucose
        return AiDexGlucoseFrame(
            opcode: opcode,
            timeOffsetMinutes: timeOffsetMinutes,
            glucoseMgDl: glucoseMgDl,
            rawGlucosePacked: glucosePacked,
            i1: i1,
            i2: i2,
            crc16: crc16,
            isValid: !isSentinel && isInRange
        )
    }

    /// True when the CRC-16 carried in bytes 15-16 of a decrypted data frame matches bytes 0-14.
    static func dataFrameCrcMatches(_ decrypted: [UInt8], frame: AiDexGlucoseFrame) -> Bool {
        guard decrypted.count == AiDexOpcodes.dataFrameLength else { return false }
        return AiDexCrc16.checksum(Array(decrypted[0..<15])) == frame.crc16
    }

    /// A 0x23 payload (after opcode and status, before the CRC): u16 LE start offset, then two bytes
    /// per minute, the glucose in the low 10 bits.
    static func parseHistoryResponse(_ data: [UInt8]) -> [AiDexCalibratedHistoryEntry] {
        guard data.count >= 4 else { return [] }
        let startOffset = u16LE(data, 0)
        let bodyOffset = 2
        let rowCount = (data.count - bodyOffset) / AiDexOpcodes.historyRawRowSize

        var entries: [AiDexCalibratedHistoryEntry] = []
        for index in 0..<rowCount {
            let offset = bodyOffset + index * AiDexOpcodes.historyRawRowSize
            let b0 = Int(data[offset])
            let b1 = Int(data[offset + 1])
            let glucose = b0 | ((b1 & 0x03) << 8)
            entries.append(AiDexCalibratedHistoryEntry(
                timeOffsetMinutes: startOffset + index,
                glucoseMgDl: glucose,
                statusBit: (b1 & 0x04) != 0,
                isSentinel: glucose == AiDexOpcodes.sentinelGlucose
            ))
        }
        return entries
    }

    /// A 0x24 payload: u16 LE start offset, then five bytes per minute (i1, i2, vc). All-zero rows are dropped.
    static func parseBriefHistoryResponse(_ data: [UInt8]) -> [AiDexAdcHistoryEntry] {
        guard data.count >= 7 else { return [] }
        let startOffset = u16LE(data, 0)
        let bodyOffset = 2
        let rowCount = (data.count - bodyOffset) / AiDexOpcodes.historyBriefRowSize

        var entries: [AiDexAdcHistoryEntry] = []
        for index in 0..<rowCount {
            let offset = bodyOffset + index * AiDexOpcodes.historyBriefRowSize
            let i1Raw = u16LE(data, offset)
            let i2Raw = u16LE(data, offset + 2)
            let vcRaw = Int(data[offset + 4])
            if i1Raw == 0 && i2Raw == 0 && vcRaw == 0 { continue }

            let i1 = Float(i1Raw) / 100
            let i2 = Float(i2Raw) / 100
            entries.append(AiDexAdcHistoryEntry(
                timeOffsetMinutes: startOffset + index,
                i1: i1,
                i2: i2,
                vc: Float(vcRaw) / 100,
                rawValue: i1 * 10,
                sensorGlucose: i1 * 18.0182
            ))
        }
        return entries
    }

    /// The offset after the last row of a 0x24 page, counting the all-zero rows that
    /// `parseBriefHistoryResponse` drops; nil when the page has no rows at all.
    static func briefHistoryPageEnd(_ data: [UInt8]) -> Int? {
        let rowCount = (data.count - 2) / AiDexOpcodes.historyBriefRowSize
        return rowCount > 0 ? u16LE(data, 0) + rowCount : nil
    }

    /// A 0x27 payload: u16 LE start index, then eight bytes per record.
    static func parseCalibrationResponse(_ data: [UInt8]) -> [AiDexCalibrationRecord] {
        guard data.count >= 10 else { return [] }
        let startIndex = u16LE(data, 0)
        if startIndex > 10_000 { return [] }
        let bodyOffset = 2
        let bodySize = data.count - bodyOffset
        if bodySize % AiDexOpcodes.calibrationRowSize != 0 { return [] }
        let rowCount = bodySize / AiDexOpcodes.calibrationRowSize

        var records: [AiDexCalibrationRecord] = []
        for index in 0..<rowCount {
            let offset = bodyOffset + index * AiDexOpcodes.calibrationRowSize
            records.append(AiDexCalibrationRecord(
                index: startIndex + index,
                timeOffsetMinutes: u16LE(data, offset),
                referenceGlucoseMgDl: u16LE(data, offset + 2),
                calibrationFactor: Float(u16LE(data, offset + 4)) / 100,
                calibrationOffset: Float(s16LE(data, offset + 6)) / 100
            ))
        }
        return records
    }

    /// A reply echoes the opcode of the command it answers.
    static func isHandshakeEcho(sent: [UInt8], received: [UInt8]) -> Bool {
        guard let first = sent.first, let echoed = received.first else { return false }
        return first == echoed
    }

    // MARK: startup device info (0x10)

    /// The payload of a 0x10 reply after the opcode:
    /// `[status_lo, status_hi, fw_major, fw_minor, hw_major, hw_minor, wear_days, model_code, model_ascii...]`.
    static func parseStartupDeviceInfoPayload(_ payload: [UInt8]) -> AiDexStartupDeviceInfo? {
        guard payload.count >= 16 else { return nil }
        guard u16LE(payload, 0) == 0 else { return nil }
        return parseStartupDeviceInfoBody(payload)
    }

    private static func parseStartupDeviceInfoBody(_ payload: [UInt8]) -> AiDexStartupDeviceInfo? {
        guard payload.count >= 16 else { return nil }
        let modelBytes = Array(payload[8...])
        let modelEnd = modelBytes.firstIndex(of: 0) ?? modelBytes.count
        let modelName = asciiString(Array(modelBytes[0..<modelEnd])).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else { return nil }
        return AiDexStartupDeviceInfo(
            firmwareVersion: "\(Int(payload[2])).\(Int(payload[3]))",
            hardwareVersion: "\(Int(payload[4])).\(Int(payload[5]))",
            wearDays: Int(payload[6]),
            modelName: modelName
        )
    }

    /// A whole 0x10 reply frame (opcode first). Tries the payload after the opcode, then after the
    /// opcode and one more byte; a non-zero code after an ACK byte `0x01` is accepted only with a
    /// readable model name (a live Lumi sensor answers `[0x10, 0x01, 0x00, 0x80, ...]`).
    static func parseStartupDeviceInfoFrame(_ frame: [UInt8], payloadEndExclusive: Int? = nil) -> AiDexStartupDeviceInfo? {
        let end = payloadEndExclusive ?? frame.count
        guard end > 1, end <= frame.count else { return nil }
        if let info = parseStartupDeviceInfoPayload(Array(frame[1..<end])) { return info }
        guard end > 2 else { return nil }
        let body = Array(frame[2..<end])
        if let info = parseStartupDeviceInfoPayload(body) { return info }
        guard frame[1] == 0x01 else { return nil }
        guard let info = parseStartupDeviceInfoBody(body) else { return nil }
        let readable = info.modelName.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
        return readable ? info : nil
    }

    // MARK: session start (2AAA and 0x21)

    /// `[year_lo, year_hi, month, day, hour, minute, second, tz_quarters (signed), dst_quarters]` (the last two optional).
    /// All zeros means "no session"; anything else must be a plausible date.
    static func parseLocalStartTimePayload(_ payload: [UInt8]) -> AiDexLocalStartTime? {
        guard payload.count >= 7 else { return nil }
        let parsed = AiDexLocalStartTime(
            year: u16LE(payload, 0),
            month: Int(payload[2]),
            day: Int(payload[3]),
            hour: Int(payload[4]),
            minute: Int(payload[5]),
            second: Int(payload[6]),
            tzQuarters: payload.count >= 8 ? Int(Int8(bitPattern: payload[7])) : 0,
            dstQuarters: payload.count >= 9 ? Int(payload[8]) : 0
        )
        if parsed.isAllZeros { return parsed }

        let plausible = parsed.year >= 2020 && parsed.year <= 2040
            && parsed.month >= 1 && parsed.month <= 12
            && parsed.day >= 1 && parsed.day <= 31
            && parsed.hour >= 0 && parsed.hour <= 23
            && parsed.minute >= 0 && parsed.minute <= 59
            && parsed.second >= 0 && parsed.second <= 59
        return plausible ? parsed : nil
    }

    // MARK: hex helpers

    static func hexString(_ data: [UInt8]) -> String {
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func compactHex(_ data: [UInt8]) -> String {
        return data.map { String(format: "%02X", $0) }.joined()
    }

    /// "01 0A ff" or "010Aff"; characters that are not hex pairs are skipped.
    static func bytes(fromHex hex: String) -> [UInt8] {
        let clean = Array(hex.replacingOccurrences(of: " ", with: ""))
        var result: [UInt8] = []
        var index = 0
        while index + 1 < clean.count {
            if let value = UInt8(String(clean[index...index + 1]), radix: 16) {
                result.append(value)
            }
            index += 2
        }
        return result
    }

    // MARK: internal helpers

    private static func asciiString(_ bytes: [UInt8]) -> String {
        var text = ""
        for byte in bytes {
            if byte < 0x80, let scalar = UnicodeScalar(Int(byte)) {
                text.unicodeScalars.append(scalar)
            } else {
                text.unicodeScalars.append(UnicodeScalar(0xFFFD) ?? "?")
            }
        }
        return text
    }

    private static func u16LE(_ data: [UInt8], _ offset: Int) -> Int {
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func s16LE(_ data: [UInt8], _ offset: Int) -> Int {
        let unsigned = u16LE(data, offset)
        return unsigned >= 0x8000 ? unsigned - 0x10000 : unsigned
    }
}

// MARK: - History merge

/// A 0x24 row joined with the 0x23 glucose of the same minute, ready for storage.
struct AiDexHistoryStoreEntry: Equatable {
    let offsetMinutes: Int
    let glucoseMgDl: Float
    let rawMgDl: Float
    let isValid: Bool
    /// Skin temperature from the 0x24 `i2` channel; NaN when unknown.
    let temperatureC: Float

    static func == (lhs: AiDexHistoryStoreEntry, rhs: AiDexHistoryStoreEntry) -> Bool {
        let sameTemperature = lhs.temperatureC == rhs.temperatureC || (lhs.temperatureC.isNaN && rhs.temperatureC.isNaN)
        return lhs.offsetMinutes == rhs.offsetMinutes && lhs.glucoseMgDl == rhs.glucoseMgDl
            && lhs.rawMgDl == rhs.rawMgDl && lhs.isValid == rhs.isValid && sameTemperature
    }
}

struct AiDexMergeResult {
    let entries: [AiDexHistoryStoreEntry]
    /// Rows whose minute had a 0x23 value.
    let mergedCount: Int
    /// Rows that took the last known glucose instead.
    let fallbackCount: Int
    /// Rows with no glucose at all (the store filters them).
    let noGlucoseCount: Int
    /// Fallback to carry into the next page.
    let lastKnownGlucose: Int?
}

enum AiDexHistoryMerge {
    static let minValidGlucoseMgDl = 20
    static let maxValidGlucoseMgDl = 500
    static let maxPlausibleRawMmol: Float = 30
    static let mgdlPerMmol: Float = 18.0182
    static let maxPlausibleRawMgDl: Float = maxPlausibleRawMmol * mgdlPerMmol
    static let maxOffsetDays = 30
    private static let controlValueDeviationThresholdMgDl = 20

    /// A raw value can spike after the sensor is disturbed; an implausible one counts as absent.
    static func normalizeRawMgDl(_ rawMgDl: Float?) -> Float? {
        guard let value = rawMgDl else { return nil }
        if !value.isFinite { return nil }
        if value <= 0 { return nil }
        if value > maxPlausibleRawMgDl { return nil }
        return value
    }

    /// Cache the 0x23 glucose by minute, skipping sentinels and the control value the sensor may put
    /// at the end of a full page (120 rows or more) when it jumps by more than 20 mg/dL.
    static func cacheCalibratedEntries(_ entries: [AiDexCalibratedHistoryEntry], cache: inout [Int: Int]) -> (cached: Int, skipped: Int) {
        var cached = 0
        var skipped = 0
        let lastIndex = entries.count - 1

        for (index, entry) in entries.enumerated() {
            if entry.isSentinel {
                skipped += 1
                continue
            }
            if index == lastIndex && entries.count >= 120 {
                let previous = index > 0 ? entries[index - 1].glucoseMgDl : entry.glucoseMgDl
                if abs(entry.glucoseMgDl - previous) > controlValueDeviationThresholdMgDl {
                    skipped += 1
                    continue
                }
            }
            cache[entry.timeOffsetMinutes] = entry.glucoseMgDl
            cached += 1
        }
        return (cached, skipped)
    }

    /// Join 0x24 rows with the cached 0x23 glucose. A minute without a cached value takes the last
    /// matched one; before any match the glucose is 0 and the store filters the row.
    static func mergeHistoryEntries(_ adcEntries: [AiDexAdcHistoryEntry], calibratedCache: inout [Int: Int], initialFallback: Int?) -> AiDexMergeResult {
        var merged = 0
        var fallback = 0
        var noGlucose = 0
        var lastKnown = initialFallback
        var entries: [AiDexHistoryStoreEntry] = []

        for entry in adcEntries {
            let glucose: Float
            if let cached = calibratedCache.removeValue(forKey: entry.timeOffsetMinutes) {
                glucose = Float(cached)
                lastKnown = cached
                merged += 1
            } else if let known = lastKnown {
                glucose = Float(known)
                fallback += 1
            } else {
                glucose = 0
                noGlucose += 1
            }
            entries.append(AiDexHistoryStoreEntry(
                offsetMinutes: entry.timeOffsetMinutes,
                glucoseMgDl: glucose,
                rawMgDl: normalizeRawMgDl(entry.rawValue) ?? 0,
                isValid: !(entry.i1 == 0 && entry.i2 == 0 && entry.vc == 0),
                temperatureC: entry.temperatureC
            ))
        }

        return AiDexMergeResult(
            entries: entries,
            mergedCount: merged,
            fallbackCount: fallback,
            noGlucoseCount: noGlucose,
            lastKnownGlucose: lastKnown
        )
    }

    /// Rows that may be stored, as JugglucoNG's `AiDexBleManager.storeHistoryEntries` filters them: valid,
    /// at least one minute and at most 30 days into the session, inside the declared wear time, not past
    /// the sensor's newest offset, not the one minute the live pipeline already stored, glucose between
    /// 20 and 500 mg/dL, not in the future (two minutes of tolerance). There is no warm-up gate: valid
    /// readings are kept from the first minute. (The older `HistoryMerge.filterForStorage` in JugglucoNG
    /// also dropped the first seven minutes and every offset at or after the live cutoff; the driver
    /// stopped using those rules.)
    static func filterForStorage(
        _ entries: [AiDexHistoryStoreEntry],
        sensorStart: Date,
        now: Date,
        historyNewestOffset: Int,
        liveOffsetCutoff: Int,
        wearDays: Int?
    ) -> [AiDexHistoryStoreEntry] {
        var passed: [AiDexHistoryStoreEntry] = []
        for entry in entries {
            if !entry.isValid { continue }
            if entry.offsetMinutes <= 0 { continue }
            if entry.offsetMinutes > maxOffsetDays * 24 * 60 { continue }
            if !AiDexHistoryPolicy.isWithinWearDuration(offsetMinutes: entry.offsetMinutes, wearDays: wearDays) { continue }
            if historyNewestOffset > 0 && entry.offsetMinutes > historyNewestOffset { continue }
            if AiDexHistoryPolicy.shouldSkipHistoryEntryForLiveDedupe(entryOffsetMinutes: entry.offsetMinutes, liveOffsetCutoff: liveOffsetCutoff) { continue }

            let glucoseInt = Int(entry.glucoseMgDl)
            if glucoseInt >= 1023 && entry.glucoseMgDl > 0 { continue }
            if glucoseInt < minValidGlucoseMgDl || glucoseInt > maxValidGlucoseMgDl { continue }

            let time = sensorStart.addingTimeInterval(Double(entry.offsetMinutes) * 60)
            if time > now.addingTimeInterval(120) { continue }
            passed.append(entry)
        }
        return passed
    }
}

// MARK: - History download policy

enum AiDexHistoryPolicy {

    enum InitialAction: Equatable {
        case completeEmpty
        case requestRaw
        case requestBrief
        case completeAlreadyCaughtUp
    }

    struct DownloadPlan: Equatable {
        let rawNextIndex: Int
        let briefNextIndex: Int
        let downloadStartIndex: Int
        let action: InitialAction
        let requestOffset: Int?
    }

    private static let offsetTimestampFutureSlack: TimeInterval = 5 * 60

    /// Where a history download starts, from the sensor's announced range (0x22) and the cursors kept from
    /// earlier connections. 0x23 (factory glucose) is fetched first, 0x24 (raw channels) second.
    static func planInitialDownload(
        briefStart: Int,
        rawStart: Int,
        newest: Int,
        persistedRawNextIndex: Int,
        persistedBriefNextIndex: Int
    ) -> DownloadPlan {
        if briefStart == 0 && rawStart == 0 && newest == 0 {
            return DownloadPlan(rawNextIndex: 0, briefNextIndex: 0, downloadStartIndex: 0, action: .completeEmpty, requestOffset: nil)
        }

        let rawCursor = persistedRawNextIndex
        let briefCursor = persistedBriefNextIndex
        let effectiveRawNextIndex: Int
        if rawCursor <= newest && briefCursor > 0 && rawCursor > briefCursor {
            effectiveRawNextIndex = briefCursor
        } else {
            effectiveRawNextIndex = rawCursor
        }

        let rawNextIndex = normalizePersistedIndex(effectiveRawNextIndex, startIndex: rawStart, newest: newest)
        let briefNextIndex = normalizePersistedIndex(briefCursor, startIndex: briefStart, newest: newest)

        if rawNextIndex <= newest {
            return DownloadPlan(rawNextIndex: rawNextIndex, briefNextIndex: briefNextIndex, downloadStartIndex: rawNextIndex, action: .requestRaw, requestOffset: rawNextIndex)
        }
        if briefNextIndex <= newest {
            return DownloadPlan(rawNextIndex: rawNextIndex, briefNextIndex: briefNextIndex, downloadStartIndex: rawNextIndex, action: .requestBrief, requestOffset: briefNextIndex)
        }
        return DownloadPlan(rawNextIndex: rawNextIndex, briefNextIndex: briefNextIndex, downloadStartIndex: rawNextIndex, action: .completeAlreadyCaughtUp, requestOffset: nil)
    }

    private static func normalizePersistedIndex(_ persistedIndex: Int, startIndex: Int, newest: Int) -> Int {
        var normalized = max(persistedIndex, startIndex)
        if normalized > newest + 10 {
            normalized = startIndex
        }
        return normalized
    }

    /// The cursor after a page: rows past the newest offset the sensor announced stay ahead of it.
    static func nextPageIndex(lastOffsetMinutes: Int, newest: Int) -> Int {
        let next = lastOffsetMinutes + 1
        return newest > 0 ? min(next, newest + 1) : next
    }

    /// Only the exact minute the live pipeline already stored is skipped; newer offsets in a reconnect
    /// page are real backfill.
    static func shouldSkipHistoryEntryForLiveDedupe(entryOffsetMinutes: Int, liveOffsetCutoff: Int) -> Bool {
        if liveOffsetCutoff <= 0 { return false }
        return entryOffsetMinutes == liveOffsetCutoff
    }

    static func wearDurationMinutes(wearDays: Int?) -> Int? {
        guard let days = wearDays, days > 0 else { return nil }
        return days * 24 * 60
    }

    static func isWithinWearDuration(offsetMinutes: Int, wearDays: Int?) -> Bool {
        if offsetMinutes < 0 { return false }
        guard let wearMinutes = wearDurationMinutes(wearDays: wearDays) else { return true }
        return offsetMinutes < wearMinutes
    }

    /// The time an offset-backed sample belongs to: start plus offset, unless that lies more than five
    /// minutes after the moment it was observed.
    static func resolveOffsetBackedTimestamp(observedAt: Date, sensorStart: Date?, offsetMinutes: Int?) -> Date {
        guard let offset = offsetMinutes, offset > 0, let start = sensorStart, start.timeIntervalSince1970 > 0 else {
            return observedAt
        }
        let sample = start.addingTimeInterval(Double(offset) * 60)
        if sample.timeIntervalSince1970 > 0 && sample <= observedAt.addingTimeInterval(offsetTimestampFutureSlack) {
            return sample
        }
        return observedAt
    }

    /// A live sample older than the newest one already accepted is dropped.
    static func shouldAcceptRealtimeTimestamp(candidate: Date, latestAccepted: Date?) -> Bool {
        if candidate.timeIntervalSince1970 <= 0 { return false }
        guard let latest = latestAccepted, latest.timeIntervalSince1970 > 0 else { return true }
        return candidate >= latest
    }
}

// MARK: - Live offset

/// What the live-offset check needs to know about the session so far.
struct AiDexOffsetContext {
    var historyNewestOffset: Int = 0
    var lastOffsetMinutes: Int = 0
    var lastHistoryNewestOffset: Int = 0
    var sensorStart: Date?
    var hasAuthoritativeSessionStart = false
    var lastGlucoseTime: Date?
}

enum AiDexLiveOffset {
    static let maxOffsetMinutes = AiDexHistoryMerge.maxOffsetDays * 24 * 60

    /// The minute offset to trust for a live frame: the wire value when it fits the session, else an
    /// offset derived from the authoritative start or from the history cadence, else nil (the reading is
    /// then stamped with the moment it arrived). `note` says why the wire value was not used.
    static func resolveTrusted(wireOffset: Int, now: Date, context: AiDexOffsetContext) -> (offset: Int?, note: String?) {
        if wireOffset <= 0 {
            return (nil, "wire offset=\(wireOffset) is not positive")
        }
        if wireOffset > maxOffsetMinutes {
            if let derived = deriveFromAuthoritativeSession(now: now, context: context) {
                return (derived, "wire offset=\(wireOffset) invalid; derived live offset=\(derived) from authoritative session")
            }
            if let derived = deriveFromKnownHistory(now: now, context: context) {
                return (derived, "wire offset=\(wireOffset) invalid; derived live offset=\(derived) from history cadence")
            }
            return (nil, "wire offset=\(wireOffset) exceeds \(AiDexHistoryMerge.maxOffsetDays)d limit")
        }

        if context.historyNewestOffset > 0 && wireOffset > context.historyNewestOffset + 2 {
            if let derived = deriveFromAuthoritativeSession(now: now, context: context) {
                return (derived, "wire offset=\(wireOffset) ahead of history newest=\(context.historyNewestOffset); using session-derived offset=\(derived)")
            }
            if let derived = deriveFromKnownHistory(now: now, context: context) {
                return (derived, "wire offset=\(wireOffset) ahead of history newest=\(context.historyNewestOffset); using history-derived offset=\(derived)")
            }
            return (nil, "wire offset=\(wireOffset) ahead of known history newest=\(context.historyNewestOffset)")
        }

        if let start = context.sensorStart, start.timeIntervalSince1970 > 0 {
            let timestamp = start.addingTimeInterval(Double(wireOffset) * 60)
            if timestamp > now.addingTimeInterval(5 * 60) {
                if let derived = deriveFromAuthoritativeSession(now: now, context: context) {
                    return (derived, "wire offset=\(wireOffset) points into the future; using session-derived offset=\(derived)")
                }
                return (nil, "wire offset=\(wireOffset) points into the future")
            }
            let oldestAllowed = now.addingTimeInterval(-Double(AiDexHistoryMerge.maxOffsetDays) * 24 * 3600)
            if timestamp < oldestAllowed {
                return (nil, "wire offset=\(wireOffset) points older than \(AiDexHistoryMerge.maxOffsetDays)d")
            }
        }
        return (wireOffset, nil)
    }

    private static func deriveFromAuthoritativeSession(now: Date, context: AiDexOffsetContext) -> Int? {
        guard context.hasAuthoritativeSessionStart, let start = context.sensorStart,
              start.timeIntervalSince1970 > 0, now > start else { return nil }
        let derived = Int((now.timeIntervalSince(start) + 30) / 60)
        return derived > 0 && derived <= maxOffsetMinutes ? derived : nil
    }

    private static func deriveFromKnownHistory(now: Date, context: AiDexOffsetContext) -> Int? {
        let baseOffset = max(context.lastOffsetMinutes, context.historyNewestOffset, context.lastHistoryNewestOffset)
        if baseOffset <= 0 { return nil }
        guard let latest = context.lastGlucoseTime, latest.timeIntervalSince1970 > 0 else { return baseOffset }
        let advance = max(0, Int((now.timeIntervalSince(latest) + 30) / 60))
        let derived = baseOffset + advance
        return derived > 0 && derived <= maxOffsetMinutes ? derived : nil
    }
}

// MARK: - Connection decisions

enum AiDexKeyExchangePolicy {

    enum PairKeyStartAction: Equatable {
        case useSavedKey
        case freshPair
    }

    enum FailureAction: Equatable {
        case retryCleanLink
        /// The saved key is dead and this phone holds the sensor's pairing: replace it over F001.
        case replaceSavedKey
        /// A fresh pair that followed a confirmed reset kept failing: go back to the key that was kept.
        case restoreSavedKey
        /// Stop retrying until the user acts (JugglucoNG falls back to broadcast-only here).
        case giveUp
    }

    enum ShortBondReadAction: Equatable {
        case accept
        case reread
        case failKeyExchange
    }

    /// A saved key is used whenever one exists; only a key that has used up its retries is replaced over
    /// F001, and only for a phone that holds the pairing or when the user asked for it.
    static func decidePairKeyStartAction(
        hasSavedPairKey: Bool,
        savedKeyExhausted: Bool = false,
        explicitPairRequested: Bool = false,
        pairedHere: Bool = false,
        pairKeyResetPending: Bool = false
    ) -> PairKeyStartAction {
        if !hasSavedPairKey { return .freshPair }
        if pairKeyResetPending { return .freshPair }
        if savedKeyExhausted && (explicitPairRequested || pairedHere) { return .freshPair }
        return .useSavedKey
    }

    static func decideFailureAction(
        consecutiveFailures: Int,
        maxFailures: Int,
        usedSavedKey: Bool = false,
        pairedHere: Bool = false,
        freshPairAfterReset: Bool = false
    ) -> FailureAction {
        if consecutiveFailures < maxFailures { return .retryCleanLink }
        if freshPairAfterReset { return .restoreSavedKey }
        if usedSavedKey && pairedHere { return .replaceSavedKey }
        return .giveUp
    }

    static let bondVectorLength = 17

    /// The BOND read must return 17 bytes; a sensor that answers with one byte has refused. One re-read is allowed.
    static func decideShortBondReadAction(replyLength: Int, rereads: Int, maxRereads: Int) -> ShortBondReadAction {
        if replyLength == bondVectorLength { return .accept }
        if rereads < maxRereads { return .reread }
        return .failKeyExchange
    }
}

enum AiDexStreamingPolicy {

    enum NoStreamRecoveryAction: Equatable {
        case keepWaiting
        case refreshLiveNotifications
        case reconnect
    }

    /// No F003 frame since streaming started: keep waiting while history is downloading, refresh the F003 and
    /// F002 notifications once, then reconnect. (JugglucoNG also asks for a connected broadcast reading and a
    /// bounded history refresh first; this port has no broadcast fallback.)
    static func decideNoStreamRecovery(historyDownloading: Bool, liveNotificationRefreshAttempted: Bool) -> NoStreamRecoveryAction {
        if historyDownloading { return .keepWaiting }
        if !liveNotificationRefreshAttempted { return .refreshLiveNotifications }
        return .reconnect
    }

    /// The watchdog waits at least the default; with a known reading it waits until one interval plus the
    /// grace after that reading.
    static func resolveNoStreamWatchdogDelay(
        defaultDelay: TimeInterval,
        now: Date,
        latestKnownReading: Date?,
        expectedLiveInterval: TimeInterval,
        expectedLiveGrace: TimeInterval
    ) -> TimeInterval {
        guard let latest = latestKnownReading, latest.timeIntervalSince1970 > 0 else { return defaultDelay }
        let waitUntil = latest.addingTimeInterval(expectedLiveInterval + expectedLiveGrace)
        let historyAwareDelay = max(0, waitUntil.timeIntervalSince(now))
        return max(defaultDelay, historyAwareDelay)
    }

    /// Startup `0x10` is the only source of the sensor's wear byte: ask up to three times per connection, 30 s apart.
    static let startupDeviceInfoMaxAttempts = 3
    static let startupDeviceInfoRetrySpacing: TimeInterval = 30

    static func shouldRequestStartupDeviceInfo(startupMetadataComplete: Bool, attemptsThisConnection: Int, lastRequestAt: Date?, now: Date) -> Bool {
        if startupMetadataComplete { return false }
        if attemptsThisConnection >= startupDeviceInfoMaxAttempts { return false }
        guard attemptsThisConnection > 0, let last = lastRequestAt else { return true }
        return now.timeIntervalSince(last) >= startupDeviceInfoRetrySpacing
    }
}

// MARK: - Activation

/// The time zone fields of SET_NEW_SENSOR: the standard offset and the daylight-saving part, in quarters of an hour.
struct AiDexActivationTimeZone: Equatable {
    let tzQuarters: Int
    let dstQuarters: Int

    static func make(date: Date, timeZone: TimeZone) -> AiDexActivationTimeZone {
        let quarterHour = 15 * 60
        let dstSeconds = Int(timeZone.daylightSavingTimeOffset(for: date))
        let standardSeconds = timeZone.secondsFromGMT(for: date) - dstSeconds
        return AiDexActivationTimeZone(tzQuarters: standardSeconds / quarterHour, dstQuarters: dstSeconds / quarterHour)
    }
}

// MARK: - Provisioned keys

enum AiDexKeyRequirement {
    /// F-generation sensors get sensor-specific pairing keys from the manufacturer's cloud (China
    /// mainland endpoint) instead of the serial-derived challenge. This app does not use that endpoint,
    /// so such a sensor can only be followed when a PAIR key is already stored for it.
    static func requiresProvisionedKeys(advertisedName: String?) -> Bool {
        guard let name = advertisedName else { return false }
        return AiDexSerialIdentity.isFSeriesAdvertisement(name)
    }
}
