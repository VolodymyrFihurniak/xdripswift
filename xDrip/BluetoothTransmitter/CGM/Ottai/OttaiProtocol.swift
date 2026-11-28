//
//  OttaiProtocol.swift
//  xdrip
//
//  Pure protocol layer of the Ottai (and Syai) CGM driver: the BLE service layout, the identity
//  rules (the 12 hex digit sensor id printed on the box), the "BLE Auth V2" handshake maths
//  (secp256r1 ECDH, SHA-256 signatures, session key pick), the AES-ECB payload decryption, the
//  record framing and parser (8 and 9 byte layouts), the stack machine that evaluates the
//  per-sensor glucose expression, the output gate and the portable sensor material format.
//  Ported from the JugglucoNG `drivers/ottai` package (GPL-3.0, see THIRD_PARTY_NOTICES.md).
//  Nothing here touches Bluetooth, so everything is covered by unit tests (`OttaiProtocolTests`,
//  `OttaiFormulaTests`) whose expected values were computed by running the unchanged Kotlin on
//  the JVM.
//
//  What this driver cannot do on its own: the six 16 byte authentication keys and the glucose
//  coefficients of a sensor are issued by the vendor cloud for the account that owns the sensor.
//  They cannot be derived on the phone. This fork does not talk to the vendor cloud: the keys and
//  coefficients have to be supplied by the user (`OttaiMaterials`), and without them the sensor
//  is shown as unsupported. See docs/ottai.md.
//
//  Not ported: the vendor cloud (login, validation, binding, region transport, request
//  signing), the cloud secret chain (decryption of the cloud fields with the account secret),
//  activation of a new sensor, firmware update, the registry and the native mirror.
//
//  Never tried on a real sensor.
//

import CommonCrypto
import CoreBluetooth
import CryptoKit
import Foundation

// MARK: - Kotlin-compatible number helpers

/// Kotlin `Double.toInt()`: truncates toward zero and saturates; NaN is 0. Swift's `Int32(_:)` would trap.
func ottaiKotlinInt(_ value: Double) -> Int32 {
    if value.isNaN { return 0 }
    if value >= 2147483647 { return Int32.max }
    if value <= -2147483648 { return Int32.min }
    return Int32(value)
}

/// Kotlin `String.toIntOrNull()` for radix 10: optional sign, ASCII digits, no overflow.
func ottaiParseKotlinInt(_ text: String) -> Int? {
    var scalars = Array(text.unicodeScalars)
    if scalars.isEmpty { return nil }
    var negative = false
    if scalars[0] == "-" {
        negative = true
        scalars.removeFirst()
    } else if scalars[0] == "+" {
        scalars.removeFirst()
    }
    if scalars.isEmpty { return nil }
    var result: Int64 = 0
    for scalar in scalars {
        guard scalar.value >= 48 && scalar.value <= 57 else { return nil }
        result = result * 10 + Int64(scalar.value - 48)
        if result > 2147483648 { return nil }
    }
    if negative { result = -result }
    if result > 2147483647 || result < -2147483648 { return nil }
    return Int(result)
}

/// Kotlin `String.toDoubleOrNull()` (Java `Double.parseDouble` grammar): optional surrounding
/// control characters and blanks, sign, `NaN`, `Infinity` or a decimal number with an optional
/// exponent and an optional `f`/`d` suffix. Hexadecimal floating point is not accepted.
func ottaiParseKotlinDouble(_ text: String) -> Double? {
    var scalars = Array(text.unicodeScalars)
    while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
    while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
    if scalars.isEmpty { return nil }
    var index = 0
    var negative = false
    if scalars[0] == "+" || scalars[0] == "-" {
        negative = scalars[0] == "-"
        index = 1
    }
    let rest = String(String.UnicodeScalarView(scalars[index...]))
    if rest == "NaN" { return Double.nan }
    if rest == "Infinity" { return negative ? -Double.infinity : Double.infinity }
    var body = Array(scalars[index...])
    if let last = body.last, last == "f" || last == "F" || last == "d" || last == "D" {
        body.removeLast()
    }
    var position = 0
    var mantissaDigits = 0
    var mantissaNonZero = false
    while position < body.count, body[position].value >= 48, body[position].value <= 57 {
        if body[position] != "0" { mantissaNonZero = true }
        mantissaDigits += 1
        position += 1
    }
    if position < body.count, body[position] == "." {
        position += 1
        while position < body.count, body[position].value >= 48, body[position].value <= 57 {
            if body[position] != "0" { mantissaNonZero = true }
            mantissaDigits += 1
            position += 1
        }
    }
    if mantissaDigits == 0 { return nil }
    var exponentPositive = true
    if position < body.count, body[position] == "e" || body[position] == "E" {
        position += 1
        if position < body.count, body[position] == "+" || body[position] == "-" {
            exponentPositive = body[position] == "+"
            position += 1
        }
        var exponentDigits = 0
        while position < body.count, body[position].value >= 48, body[position].value <= 57 {
            exponentDigits += 1
            position += 1
        }
        if exponentDigits == 0 { return nil }
    }
    if position != body.count { return nil }
    let literal = String(String.UnicodeScalarView(body))
    var value: Double
    if let parsed = Double(literal) {
        value = parsed
    } else if !mantissaNonZero {
        value = 0
    } else {
        value = exponentPositive ? Double.infinity : 0
    }
    if negative { value = -value }
    return value
}

// MARK: - Hex

enum OttaiHex {

    static func string(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }

    /// Nil for an odd length or a character that is not a hexadecimal digit.
    static func bytes(_ hex: String) -> [UInt8]? {
        let scalars = Array(hex.unicodeScalars)
        if scalars.count % 2 != 0 { return nil }
        var result = [UInt8]()
        result.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = digit(scalars[index]), let low = digit(scalars[index + 1]) else { return nil }
            result.append(UInt8(high << 4 | low))
            index += 2
        }
        return result
    }

    static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        return digit(scalar) != nil
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 48...57: return Int(scalar.value) - 48
        case 65...70: return Int(scalar.value) - 55
        case 97...102: return Int(scalar.value) - 87
        default: return nil
        }
    }
}

// MARK: - Constants and identity

/// JugglucoNG `OttaiConstants` (the cloud endpoints, preference keys and the activation and
/// firmware helpers are not ported).
enum OttaiConstants {

    static let displayName = "Ottai CGM"

    // MARK: BLE layout

    static let serviceDeviceInfo = CBUUID(string: "180A")
    static let charCurrentTime = CBUUID(string: "2A2B")
    static let charMaxActiveTime = CBUUID(string: "B8FD9848-0CCD-423F-BD34-2419AA7EA004")
    static let charCgmInfoNotify = CBUUID(string: "CB627922-4E79-42E3-B107-A10E816F6CAA")

    static let serviceCgm = CBUUID(string: "181F")
    static let charGlucoseLive = CBUUID(string: "2AA7")
    static let charHistoryRequest = CBUUID(string: "CCECB015-6750-41FD-BA78-3FB77D350574")
    static let charGlucoseHistory = CBUUID(string: "69E4F45F-A180-422C-83C0-324146402112")
    static let charCommand = CBUUID(string: "D78D0706-C775-448D-8A78-01215E7C2E11")

    static let serviceAuth = CBUUID(string: "E06E1D43-1319-4EBF-94B0-5B0E5313B1F4")
    static let charAuthDeviceParam = CBUUID(string: "86805092-92B5-4D8C-9D73-0785FF6F9147")
    static let charAuthAppParam = CBUUID(string: "1756EF6E-884B-4EB0-B646-F04AB18408F9")
    static let charAuthSign = CBUUID(string: "785022C6-08C0-48AF-AD17-684BB889AA83")

    // MARK: Lifetime and cadence

    /// Sensor rated lifetime reported by the cloud for the Chinese M8 JugglucoNG was tested with.
    static let defaultRatedLifetimeDays = 15
    static let defaultActiveExpireMs: Int64 = Int64(defaultRatedLifetimeDays) * 24 * 3600 * 1000
    static let extendedLifetimeDays = 30
    static let extendedLifetimeMs: Int64 = Int64(extendedLifetimeDays) * 24 * 3600 * 1000
    /// Reading cadence in minutes.
    static let readingIntervalMinutes = 1
    /// Record interval of the sensor's own counter.
    static let recordIntervalMs: Int64 = 60_000
    /// Post-activation window in which readings are decoded but never published.
    static let warmupSuppressMs: Int64 = 600_000
    /// Past the extended end, a sensor is only declared expired once samples stop this long.
    static let expiredStaleGraceMs: Int64 = 6 * 3600 * 1000

    private static let minActiveExpireMs: Int64 = 10 * 24 * 3600 * 1000
    private static let maxActiveExpireMs: Int64 = 45 * 24 * 3600 * 1000

    /// Cloud and sensor values are durations: reject epoch timestamps, unit mistakes and corrupt values.
    static func sanitizeActiveExpireMs(_ value: Int64) -> Int64 {
        return (minActiveExpireMs...maxActiveExpireMs).contains(value) ? value : 0
    }

    static func expectedLifetimeMs(cloudActiveExpireMs: Int64, acceptedMaxActiveMs: Int64) -> Int64 {
        let accepted = sanitizeActiveExpireMs(acceptedMaxActiveMs)
        if accepted > 0 { return accepted }
        let cloud = sanitizeActiveExpireMs(cloudActiveExpireMs)
        if cloud > 0 { return cloud }
        return defaultActiveExpireMs
    }

    /// Whether a sample falls inside the post-activation settling window. Pass 0 to disable the gate.
    static func isWithinWarmup(activationStartMs: Int64, sampleMs: Int64) -> Bool {
        return activationStartMs > 0 && sampleMs > 0 && sampleMs < activationStartMs + warmupSuppressMs
    }

    /// Sensor command state: 0 to 2 need activation, 3 is activated, 4 and above ended.
    static func commandNeedsActivation(_ status: Int) -> Bool {
        return (0...2).contains(status)
    }

    // MARK: Identity

    /// Whitespace as Kotlin `trim()` sees it (Java `Character.isWhitespace` plus space separators).
    static func kotlinTrim(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        func isBlank(_ scalar: Unicode.Scalar) -> Bool {
            if (0x1C...0x1F).contains(scalar.value) { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while let first = scalars.first, isBlank(first) { scalars.removeFirst() }
        while let last = scalars.last, isBlank(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isColonMac(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 17 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index % 3 == 2 {
                if scalar != ":" { return false }
            } else if !OttaiHex.isHexDigit(scalar) {
                return false
            }
        }
        return true
    }

    private static func isPlainMac(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 12 && scalars.allSatisfy { OttaiHex.isHexDigit($0) }
    }

    static func looksLikeMac(_ value: String?) -> Bool {
        guard let value = value else { return false }
        let trimmed = kotlinTrim(value)
        return isColonMac(trimmed) || isPlainMac(trimmed)
    }

    /// Canonical cloud device id: 12 uppercase hex digits, no separators. Anything else is returned trimmed.
    static func canonicalSensorId(_ sensorId: String?) -> String {
        let trimmed = kotlinTrim(sensorId ?? "")
        if trimmed.isEmpty { return "" }
        if isColonMac(trimmed) { return trimmed.uppercased().replacingOccurrences(of: ":", with: "") }
        if isPlainMac(trimmed) { return trimmed.uppercased() }
        return trimmed
    }

    /// The setup box serial is a lookup input only: 12 upper case letters or digits that is not a MAC.
    static func isBoxSerial(_ value: String?) -> Bool {
        let code = kotlinTrim(value ?? "").uppercased()
        let scalars = Array(code.unicodeScalars)
        guard scalars.count == 12 else { return false }
        let allowed = scalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) }
        return allowed && !looksLikeMac(code)
    }

    /// Extracts the 12 hex digit sensor id from a label or QR text. The box label is a GS1 data
    /// matrix `(01)GTIN (11)date (17)date (10)batch (21)serial`: the id is the (21) serial, not the
    /// leading GTIN, so candidates are ranked (after AI 21 +8, contains A-F +4, standalone +2).
    static func extractMacFromQr(_ qr: String?) -> String? {
        guard let qr = qr, !kotlinTrim(qr).isEmpty else { return nil }
        let raw = qr.uppercased()
        let units = Array(raw.utf16)
        func isHex(_ unit: UInt16) -> Bool {
            return (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 70)
        }
        // A literal colon separated MAC wins outright.
        if units.count >= 17 {
            for start in 0...(units.count - 17) {
                var matches = true
                for offset in 0..<17 {
                    let unit = units[start + offset]
                    if offset % 3 == 2 {
                        if unit != 58 { matches = false; break }
                    } else if !isHex(unit) {
                        matches = false
                        break
                    }
                }
                if matches {
                    let text = String(utf16CodeUnits: Array(units[start..<(start + 17)]), count: 17)
                    return canonicalSensorId(text)
                }
            }
        }
        var best: String?
        var bestScore = -1
        var index = 0
        while index + 12 <= units.count {
            if (index..<(index + 12)).allSatisfy({ isHex(units[$0]) }) {
                let window = Array(units[index..<(index + 12)])
                let sub = String(utf16CodeUnits: window, count: 12)
                let afterAi21 = index >= 2 && units[index - 1] == 49 && units[index - 2] == 50
                let standalone = (index == 0 || !isHex(units[index - 1])) && (index + 12 == units.count || !isHex(units[index + 12]))
                let hasLetter = window.contains { $0 >= 65 && $0 <= 70 }
                let score = (afterAi21 ? 8 : 0) + (hasLetter ? 4 : 0) + (standalone ? 2 : 0)
                if score > bestScore {
                    bestScore = score
                    best = sub
                }
            }
            index += 1
        }
        return best
    }

    /// A MAC, a box serial or the GS1 (21) serial of a label.
    static func extractSetupCode(_ value: String?) -> String? {
        let raw = kotlinTrim(value ?? "").uppercased()
        if looksLikeMac(raw) { return canonicalSensorId(raw) }
        if isBoxSerial(raw) { return raw }
        let pattern = "(?:\\(21\\)|\\u001D21|^21)([A-Z0-9]{12})(?=$|\\u001D|\\()"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(raw.startIndex..., in: raw)
            if let match = regex.firstMatch(in: raw, options: [], range: range),
               match.numberOfRanges > 1,
               let group = Range(match.range(at: 1), in: raw) {
                return String(raw[group])
            }
        }
        return extractMacFromQr(raw)
    }

    /// The advertised name of a sensor. JugglucoNG only admits advertisements whose name contains "ottai".
    static func isOttaiAdvertisedName(_ name: String?) -> Bool {
        guard let name = name else { return false }
        return kotlinTrim(name).range(of: "ottai", options: .caseInsensitive) != nil
    }
}

// MARK: - Payload crypto (AES-ECB with zero padding)

/// JugglucoNG `OttaiCrypto`, the BLE part only. The cloud secret chain (decryption of the cloud
/// fields with the account secret) is not ported.
enum OttaiCrypto {

    static let authKeyCount = 6
    static let authKeyBytes = 16
    static let authKeyHexLength = authKeyCount * authKeyBytes * 2

    /// Splits a keyA hex string into six 16 byte keys. Nil unless it is exactly 192 hex digits.
    static func parseAuthKeys(_ keyAHex: String) -> [[UInt8]]? {
        let hex = OttaiConstants.kotlinTrim(keyAHex)
        guard hex.unicodeScalars.count == authKeyHexLength, let bytes = OttaiHex.bytes(hex) else { return nil }
        return (0..<authKeyCount).map { Array(bytes[($0 * authKeyBytes)..<(($0 + 1) * authKeyBytes)]) }
    }

    /// Decrypts a live or history payload with the hex session key (AES/ECB, zero byte padding),
    /// then drops the trailing 8 bytes only when the length is even and those bytes are all zero
    /// (CgmMonitor). Nil for an empty input, a length that is not a multiple of 16 or a bad key.
    static func decryptPayload(_ cipher: [UInt8], sessionKeyHex: String) -> [UInt8]? {
        guard let key = OttaiHex.bytes(sessionKeyHex), !cipher.isEmpty, cipher.count % 16 == 0 else { return nil }
        guard let plain = ecb(cipher, key: key, encrypt: false) else { return nil }
        return trimTrailingZeroBlock(plain)
    }

    /// Encrypts with zero padding up to a 16 byte multiple. Used by the tests only.
    static func encryptPayload(_ plain: [UInt8], sessionKeyHex: String) -> [UInt8]? {
        guard let key = OttaiHex.bytes(sessionKeyHex) else { return nil }
        return ecb(zeroPad16(plain), key: key, encrypt: true)
    }

    private static func trimTrailingZeroBlock(_ data: [UInt8]) -> [UInt8] {
        if data.count >= 8 && data.count % 2 == 0 && data[(data.count - 8)...].allSatisfy({ $0 == 0 }) {
            return Array(data[0..<(data.count - 8)])
        }
        return data
    }

    private static func zeroPad16(_ data: [UInt8]) -> [UInt8] {
        if data.isEmpty { return [UInt8](repeating: 0, count: 16) }
        let remainder = data.count % 16
        if remainder == 0 { return data }
        return data + [UInt8](repeating: 0, count: 16 - remainder)
    }

    private static func ecb(_ input: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8]? {
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count), input.count % 16 == 0 else { return nil }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count,
                        nil,
                        inputBytes.baseAddress, input.count,
                        outputBytes.baseAddress, capacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else { return nil }
        return Array(output.prefix(moved))
    }
}

// MARK: - BLE auth V2

/// JugglucoNG `OttaiBleAuth`: secp256r1 ECDH, SHA-256 signatures and the session key pick.
enum OttaiBleAuth {

    /// A fresh secp256r1 key pair for one handshake.
    static func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        return P256.KeyAgreement.PrivateKey()
    }

    /// P-256 coordinate: strip leading zero bytes (the BigInteger sign byte) and left-pad to 32 bytes.
    static func coordBytes(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = magnitude
        while let first = bytes.first, first == 0 { bytes.removeFirst() }
        if bytes.count >= 32 { return bytes }
        return [UInt8](repeating: 0, count: 32 - bytes.count) + bytes
    }

    static func publicCoords(_ publicKey: P256.KeyAgreement.PublicKey) -> (x: [UInt8], y: [UInt8]) {
        let raw = [UInt8](publicKey.rawRepresentation)
        return (coordBytes(Array(raw[0..<32])), coordBytes(Array(raw[32..<64])))
    }

    /// Little-endian int32 from the first four bytes. Nil when fewer than four bytes.
    static func bytesToIntLE(_ bytes: [UInt8]) -> Int32? {
        guard bytes.count >= 4 else { return nil }
        let value = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Int32(bitPattern: value)
    }

    static func intToBytesLE(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    }

    /// The 3 byte app auth time: the device time read big-endian, plus one, bits 24 to 8 most significant first.
    static func appTime3(deviceTimeBytes: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: max(0, 4 - deviceTimeBytes.count)) + deviceTimeBytes
        var index = bytes.count - 1
        var carry = 1
        while index >= 0 && carry > 0 {
            let sum = Int(bytes[index]) + carry
            bytes[index] = UInt8(sum & 0xFF)
            carry = sum >> 8
            index -= 1
        }
        let count = bytes.count
        return [bytes[count - 4], bytes[count - 3], bytes[count - 2]]
    }

    /// The parameter written to `1756ef6e`: `selectedIndex(1) || time3(3) || appPubX || appPubY`.
    static func appAuthParameter(selectedIndex: Int, time3: [UInt8], pubX: [UInt8], pubY: [UInt8]) -> [UInt8] {
        return [UInt8(truncatingIfNeeded: selectedIndex)] + time3 + pubX + pubY
    }

    /// `SHA256(authKey || mac || pubX || pubY || time3)`, written to `785022c6`.
    static func authSign(authKey: [UInt8], mac: [UInt8], pubX: [UInt8], pubY: [UInt8], time3: [UInt8]) -> [UInt8] {
        var data = Data()
        data.append(contentsOf: authKey)
        data.append(contentsOf: mac)
        data.append(contentsOf: pubX)
        data.append(contentsOf: pubY)
        data.append(contentsOf: time3)
        return Array(SHA256.hash(data: data))
    }

    /// The same with the hex strings the material stores. Nil for malformed hex.
    static func authSign(authKeyHex: String, macHex: String, pubX: [UInt8], pubY: [UInt8], time3: [UInt8]) -> [UInt8]? {
        guard let key = OttaiHex.bytes(authKeyHex), let mac = OttaiHex.bytes(macHex) else { return nil }
        return authSign(authKey: key, mac: mac, pubX: pubX, pubY: pubY, time3: time3)
    }

    /// Whether the sensor's signature read from `785022c6` equals
    /// `SHA256(authKeys[index] || mac || devPubX || devPubY || devTime)`.
    static func verifyDeviceSign(
        _ deviceSign: [UInt8], authKeyHex: String, macHex: String,
        devicePubX: [UInt8], devicePubY: [UInt8], deviceTime: [UInt8]
    ) -> Bool {
        guard let expected = authSign(authKeyHex: authKeyHex, macHex: macHex, pubX: devicePubX, pubY: devicePubY, time3: deviceTime) else {
            return false
        }
        return expected == deviceSign
    }

    /// ECDH session key. The shared X stays a fixed length big-endian field element (leading zeros
    /// kept): the vendor app's BigInteger round trip drops a leading zero byte in one handshake of
    /// 512 and ends with an empty key, JugglucoNG does not repeat that. Nil when the device point is
    /// not on the curve or the pick is too short.
    static func deriveSessionKey(devicePubX: [UInt8], devicePubY: [UInt8], ourPrivate: P256.KeyAgreement.PrivateKey) -> String? {
        let x = coordBytes(devicePubX)
        let y = coordBytes(devicePubY)
        guard x.count == 32, y.count == 32 else { return nil }
        guard let devicePublic = try? P256.KeyAgreement.PublicKey(x963Representation: Data([0x04] + x + y)),
              let secret = try? ourPrivate.sharedSecretFromKeyAgreement(with: devicePublic) else { return nil }
        let raw: [UInt8] = secret.withUnsafeBytes { Array($0) }
        return sessionKeyPick(OttaiHex.string(fixedFieldBytes(raw, fieldLength: 32)))
    }

    /// The same with the coordinates as hex strings.
    static func deriveSessionKey(devicePubXHex: String, devicePubYHex: String, ourPrivate: P256.KeyAgreement.PrivateKey) -> String? {
        guard let x = OttaiHex.bytes(devicePubXHex.count % 2 == 0 ? devicePubXHex : "0" + devicePubXHex),
              let y = OttaiHex.bytes(devicePubYHex.count % 2 == 0 ? devicePubYHex : "0" + devicePubYHex) else { return nil }
        return deriveSessionKey(devicePubX: x, devicePubY: y, ourPrivate: ourPrivate)
    }

    /// Big-endian field element of exactly `fieldLength` bytes: left-pad, never strip.
    static func fixedFieldBytes(_ value: [UInt8], fieldLength: Int) -> [UInt8] {
        if value.count == fieldLength { return value }
        if value.count < fieldLength { return [UInt8](repeating: 0, count: fieldLength - value.count) + value }
        return Array(value[(value.count - fieldLength)...])
    }

    /// Char pick from the shared secret hex: start at position 2, append the character, advance +1 and
    /// +3 alternately (2, 3, 6, 7, 10, 11, ...). Nil unless at least 32 characters come out.
    static func sessionKeyPick(_ sharedHex: String) -> String? {
        let characters = Array(sharedHex)
        if characters.isEmpty { return nil }
        var result = ""
        var position = 2
        var toggle = 1
        var index = 2
        while index < characters.count {
            if position < characters.count {
                result.append(characters[position])
                position += toggle != 0 ? 1 : 3
                toggle ^= 1
            }
            index += 1
        }
        return result.count >= 32 ? result : nil
    }
}

// MARK: - Records

struct OttaiRecord: Equatable {
    let dataNo: Int
    let voltage: Int
    let runtimeSec: Int
    let rawCurrent: Int
    let temperatureC: Double
    /// The 12 byte parser input (`00 00 || dataNo LE || 8 byte record`).
    let recordBytes: [UInt8]
}

struct OttaiReading: Equatable {
    let record: OttaiRecord
    /// Formula output in mmol/L; 0 means below the floor or invalid.
    let adjustGlucose: Double
    /// Activation time plus runtime, 0 when the activation time is unknown.
    let monitorTimeMs: Int64
    /// False when the record fails the vendor sanity gate, or when the expression could not be evaluated.
    let valid: Bool
    /// The expression could not be evaluated (malformed method or an operand the stack does not have).
    let formulaFailed: Bool
}

/// JugglucoNG `OttaiParser`: payload framing, the 8 and 9 byte record layouts and the record parser.
enum OttaiParser {

    static let headerSize = 8
    static let bleRecordSize = 8
    /// Some V1.7 devices pack 9 byte records with a different field layout.
    static let bleRecordSizeE12 = 9
    static let parserRecordSize = 12
    static let invalidDataNo = 65535

    private static let minDecisiveRecords = 3
    private static let decisiveMargin = 2

    /// Record size of a decrypted payload. Content that can prove a layout wins, then the layout the
    /// driver has already learned, then a confirmed firmware family, then the structure of the frame.
    static func chooseRecordSize(_ payload: [UInt8], deviceVersion: String, learned: Int? = nil) -> Int {
        if let size = contentRecordSize(payload) { return size }
        let bodyLength = payload.count - headerSize
        if let learned = learned, learned == bleRecordSize || learned == bleRecordSizeE12, bodyLength >= learned {
            return learned
        }
        if let confirmed = confirmedRecordSize(deviceVersion), bodyLength >= confirmed { return confirmed }
        let evidence = recordSizeEvidence(payload)
        return evidence.nine > evidence.eight ? bleRecordSizeE12 : bleRecordSize
    }

    /// Vendor-valid record counts for a payload read as 9 byte and as 8 byte records.
    static func recordSizeEvidence(_ payload: [UInt8]) -> (nine: Int, eight: Int) {
        return (
            vendorValidCount(payload, recordSize: bleRecordSizeE12, currentLow: 0, temperatureLow: 7),
            vendorValidCount(payload, recordSize: bleRecordSize, currentLow: 4, temperatureLow: 6)
        )
    }

    /// The layout this payload can prove, or nil: a confirmed version string proves it, otherwise
    /// the content must.
    static func decisiveRecordSize(_ payload: [UInt8], deviceVersion: String) -> Int? {
        return contentRecordSize(payload) ?? confirmedRecordSize(deviceVersion)
    }

    /// The layout the payload's own records prove: at least three vendor-valid records, a lead of two,
    /// and most non-padding records explained. Outranks the version string.
    static func contentRecordSize(_ payload: [UInt8]) -> Int? {
        let evidence = recordSizeEvidence(payload)
        if evidence.nine >= minDecisiveRecords && evidence.nine - evidence.eight >= decisiveMargin &&
            explainsMostRecords(payload, recordSize: bleRecordSizeE12, valid: evidence.nine) {
            return bleRecordSizeE12
        }
        if evidence.eight >= minDecisiveRecords && evidence.eight - evidence.nine >= decisiveMargin &&
            explainsMostRecords(payload, recordSize: bleRecordSize, valid: evidence.eight) {
            return bleRecordSize
        }
        return nil
    }

    private static func explainsMostRecords(_ payload: [UInt8], recordSize: Int, valid: Int) -> Bool {
        var framed = 0
        let count = (payload.count - headerSize) / recordSize
        for index in 0..<max(0, count) {
            let source = headerSize + index * recordSize
            if (0..<recordSize).contains(where: { payload[source + $0] != 0 }) { framed += 1 }
        }
        return valid * 2 > framed
    }

    /// E major.minor to record size, only for families still unambiguous on hardware.
    private static let confirmedEFamilies: [String: Int] = ["1.2": bleRecordSizeE12]

    /// Record size for firmware whose live format was confirmed; nil = unknown.
    private static func confirmedRecordSize(_ deviceVersion: String) -> Int? {
        if let regex = try? NSRegularExpression(pattern: "(?:^|[^0-9A-Za-z])v?e([0-9]+)\\.([0-9]+)", options: [.caseInsensitive]) {
            let range = NSRange(deviceVersion.startIndex..., in: deviceVersion)
            if let match = regex.firstMatch(in: deviceVersion, options: [], range: range),
               match.numberOfRanges > 2,
               let major = Range(match.range(at: 1), in: deviceVersion),
               let minor = Range(match.range(at: 2), in: deviceVersion),
               let size = confirmedEFamilies["\(deviceVersion[major]).\(deviceVersion[minor])"] {
                return size
            }
        }
        // Pre E-number strings: V1.5 is unambiguous (no 9 byte V1.5 exists), V1.7 is the ambiguous one.
        return deviceVersion.range(of: "V1.5", options: .caseInsensitive) != nil ? bleRecordSize : nil
    }

    private static func vendorValidCount(_ payload: [UInt8], recordSize: Int, currentLow: Int, temperatureLow: Int) -> Int {
        let count = (payload.count - headerSize) / recordSize
        var valid = 0
        for index in 0..<max(0, count) {
            let source = headerSize + index * recordSize
            if source + temperatureLow + 1 >= payload.count { break }
            let current = le16(payload[source + currentLow], payload[source + currentLow + 1])
            let temperature = Double(le16(payload[source + temperatureLow], payload[source + temperatureLow + 1])) / 100.0
            if current >= 1_000 && temperature <= 45.0 { valid += 1 }
        }
        return valid
    }

    private static func le16(_ low: UInt8, _ high: UInt8) -> Int {
        return Int(low) | Int(high) << 8
    }

    /// `frontDataNo` of a decrypted payload (LE16 at bytes 4 and 5).
    static func frontDataNo(_ payload: [UInt8]) -> Int {
        if payload.count < 6 { return 0 }
        return le16(payload[4], payload[5])
    }

    /// Splits a decrypted payload into 12 byte parser records (`00 00 || LE16(frontDataNo + index) || record`).
    /// Nine byte frames pad their tail with zero records: those are skipped.
    static func frameRecords(_ payload: [UInt8], deviceVersion: String = "", learned: Int? = nil) -> [[UInt8]] {
        if payload.count <= headerSize { return [] }
        let front = frontDataNo(payload)
        let size = chooseRecordSize(payload, deviceVersion: deviceVersion, learned: learned)
        let nineByte = size == bleRecordSizeE12
        let count = (payload.count - headerSize) / size
        if count <= 0 { return [] }
        var result = [[UInt8]]()
        for index in 0..<count {
            let source = headerSize + index * size
            if nineByte && (0..<size).allSatisfy({ payload[source + $0] == 0 }) { continue }
            let dataNo = (front + index) & 0xFFFF
            var record = [UInt8](repeating: 0, count: parserRecordSize)
            record[2] = UInt8(dataNo & 0xFF)
            record[3] = UInt8((dataNo >> 8) & 0xFF)
            if nineByte {
                // The 16-bit runtime counter wraps: derive the runtime from dataNo (minutes since activation).
                let runtime = dataNo * 60
                record[4] = payload[source + 6]
                record[5] = UInt8((runtime >> 16) & 0xFF)
                record[6] = UInt8(runtime & 0xFF)
                record[7] = UInt8((runtime >> 8) & 0xFF)
                record[8] = payload[source]
                record[9] = payload[source + 1]
                record[10] = payload[source + 7]
                record[11] = payload[source + 8]
            } else {
                for offset in 0..<bleRecordSize { record[4 + offset] = payload[source + offset] }
            }
            result.append(record)
        }
        return result
    }

    /// Parses a 12 byte parser record. Nil when shorter than 12 bytes.
    static func parseRecord(_ bytes: [UInt8]) -> OttaiRecord? {
        guard bytes.count >= parserRecordSize else { return nil }
        let dataNo = le16(bytes[2], bytes[3])
        let voltage = Int(bytes[4])
        // Mixed endian runtime: (b5 << 16) | (b7 << 8) | b6.
        let runtime = Int(bytes[5]) << 16 | Int(bytes[7]) << 8 | Int(bytes[6])
        let rawCurrent = le16(bytes[8], bytes[9])
        let temperature = Double(le16(bytes[10], bytes[11])) / 100.0
        return OttaiRecord(
            dataNo: dataNo, voltage: voltage, runtimeSec: runtime, rawCurrent: rawCurrent,
            temperatureC: temperature, recordBytes: Array(bytes[0..<bytes.count])
        )
    }

    /// Vendor sanity gate: dataNo 65535 is invalid, and from dataNo 60 on the record counter may not
    /// differ from runtime / 60 by more than 120.
    static func isRecordSane(_ record: OttaiRecord) -> Bool {
        if record.dataNo == invalidDataNo { return false }
        if record.dataNo >= 60 && abs(record.dataNo - record.runtimeSec / 60) > 120 { return false }
        return true
    }

    /// The AVERAGE record condition: runtime at least the warm-up, dataNo at least 5 and a multiple of 5.
    static func isAverageTick(_ record: OttaiRecord, warmupSec: Int = 3200) -> Bool {
        return record.runtimeSec >= warmupSec && record.dataNo >= 5 && record.dataNo % 5 == 0
    }

    /// Builds a reading from a 12 byte parser record (no decryption). `method` blank gives 0.
    static func toReading(_ record12: [UInt8], method: String, coefficients: [Double], activeTimeMs: Int64) -> OttaiReading? {
        guard let record = parseRecord(record12) else { return nil }
        var adjust = 0.0
        var failed = false
        if !OttaiFormula.isBlank(method) {
            let variables = OttaiFormula.buildVariables(
                rawCurrent: record.rawCurrent, temperature: record.temperatureC, runtimeSec: record.runtimeSec,
                dataNo: record.dataNo, voltage: record.voltage
            )
            if let value = OttaiFormula.evaluate(method: method, coefficients: coefficients, v: variables, recordBytes: record12) {
                adjust = value
            } else {
                failed = true
            }
        }
        let monitorMs: Int64 = activeTimeMs > 0 ? activeTimeMs + Int64(record.runtimeSec) * 1000 : 0
        return OttaiReading(
            record: record, adjustGlucose: adjust, monitorTimeMs: monitorMs,
            valid: isRecordSane(record) && !failed, formulaFailed: failed
        )
    }

    /// Live parse: decrypt, frame, take the last record, run the formula.
    static func parseLive(
        cipher: [UInt8], sessionKeyHex: String, method: String, coefficients: [Double], activeTimeMs: Int64
    ) -> OttaiReading? {
        guard let payload = OttaiCrypto.decryptPayload(cipher, sessionKeyHex: sessionKeyHex) else { return nil }
        guard let last = frameRecords(payload).last else { return nil }
        return toReading(last, method: method, coefficients: coefficients, activeTimeMs: activeTimeMs)
    }

    /// History parse: decrypt, frame, every record through the formula.
    static func parseHistory(
        cipher: [UInt8], sessionKeyHex: String, method: String, coefficients: [Double], activeTimeMs: Int64
    ) -> [OttaiReading] {
        guard let payload = OttaiCrypto.decryptPayload(cipher, sessionKeyHex: sessionKeyHex) else { return [] }
        return frameRecords(payload).compactMap { toReading($0, method: method, coefficients: coefficients, activeTimeMs: activeTimeMs) }
    }
}

// MARK: - Glucose expression

/// JugglucoNG `OttaiFormula`: the stack machine that evaluates the per-sensor expression.
///
/// The expression is `;` separated groups of space separated tokens: the 29 operators, numeric
/// literals and the references `C<i>` (coefficient), `V<i>` (current, temperature, runtime, dataNo,
/// runtime / 3600, voltage), `B<i>` (signed byte of the 12 byte record) and `R<i>` (result of an
/// earlier group). The last group's result is the glucose; values below 0.1 are forced to 0.
///
/// Where the Kotlin original throws (an operator without enough operands, a negative `RD` precision,
/// an integer remainder by zero) `evaluate` returns nil. Transcendental functions call the platform
/// libm, so they can differ from the JVM in the last digit.
enum OttaiFormula {

    private static let operators: Set<String> = [
        "AD", "SB", "ML", "DV", "NG", "AB", "SQ", "PW", "BW", "BE", "GT", "GE",
        "LT", "LE", "RD", "LN", "MX", "MI", "SN", "CS", "TN", "AS", "AC", "AT",
        "BA", "BO", "BN", "BX", "MD",
    ]

    private enum Token {
        case op(String)
        case number(Double)
    }

    private struct Failure: Error {}

    /// Kotlin `String.isBlank()`.
    static func isBlank(_ text: String) -> Bool {
        return text.unicodeScalars.allSatisfy { OttaiConstants.kotlinTrim(String($0)).isEmpty }
    }

    static func evaluate(method: String, coefficients: [Double], v: [Double], recordBytes: [UInt8]) -> Double? {
        if isBlank(method) { return 0.0 }
        var groupResults = [Double]()
        do {
            for group in method.split(separator: ";", omittingEmptySubsequences: false) {
                let rawTokens = group.split(separator: " ", omittingEmptySubsequences: true)
                if rawTokens.isEmpty { continue }
                let tokens = rawTokens.map { substitute(String($0), coefficients: coefficients, v: v, recordBytes: recordBytes, prior: groupResults) }
                groupResults.append(try evalGroup(tokens))
            }
        } catch {
            return nil
        }
        guard var adjust = groupResults.last else { return 0.0 }
        if adjust < 0.1 { adjust = 0.0 }
        return adjust
    }

    private static func substitute(_ token: String, coefficients: [Double], v: [Double], recordBytes: [UInt8], prior: [Double]) -> Token {
        let characters = Array(token)
        if characters.count >= 2, let index = ottaiParseKotlinInt(String(characters[1...])), index >= 0 {
            switch characters[0] {
            case "C": if index < coefficients.count { return .number(coefficients[index]) }
            case "V": if index < v.count { return .number(v[index]) }
            case "B": if index < recordBytes.count { return .number(Double(Int8(bitPattern: recordBytes[index]))) }
            case "R": if index < prior.count { return .number(prior[index]) }
            default: break
            }
        }
        let upper = token.uppercased()
        if operators.contains(upper) { return .op(upper) }
        return .number(ottaiParseKotlinDouble(token) ?? 0.0)
    }

    private static func evalGroup(_ tokens: [Token]) throws -> Double {
        var stack = [Double](repeating: 0, count: tokens.count)
        var sp = -1

        func at(_ index: Int) throws -> Double {
            guard index >= 0 && index < stack.count else { throw Failure() }
            return stack[index]
        }

        for token in tokens {
            switch token {
            case .op(let op):
                var r = 1.0
                switch op {
                case "AD": sp -= 1; r = try at(sp + 1) + at(sp)
                case "SB": sp -= 1; r = try at(sp) - at(sp + 1)
                case "ML": sp -= 1; r = try at(sp + 1) * at(sp)
                case "DV": sp -= 1; r = try at(sp) / at(sp + 1)
                case "NG": r = try -at(sp)
                case "AB": r = try abs(at(sp))
                case "SQ": r = try at(sp).squareRoot()
                case "PW": sp -= 1; r = try javaPow(at(sp), at(sp + 1))
                case "BW":
                    sp -= 3
                    let outside = try at(sp + 1) >= at(sp) || at(sp) >= at(sp + 2)
                    if outside {
                        r = 0.0
                    } else if try at(sp + 3) != 1.0 {
                        r = try at(sp)
                    } else {
                        r = 1.0
                    }
                case "BE":
                    sp -= 3
                    let inside = try at(sp + 1) <= at(sp) && at(sp) <= at(sp + 2) && at(sp + 3) != 1.0
                    if inside {
                        r = try at(sp)
                    } else {
                        r = 1.0
                    }
                case "GT": sp -= 2; r = try at(sp) > at(sp + 1) ? at(sp + 2) : 0.0
                case "GE": sp -= 2; r = try at(sp) >= at(sp + 1) ? at(sp + 2) : 0.0
                case "LT": sp -= 2; r = try at(sp) < at(sp + 1) ? at(sp + 2) : 0.0
                case "LE": sp -= 2; r = try at(sp) <= at(sp + 1) ? at(sp + 2) : 0.0
                case "RD":
                    sp -= 1
                    let decimals = Int(ottaiKotlinInt(try at(sp + 1)))
                    guard let rounded = ottaiRoundHalfUp(try at(sp), decimals: decimals) else { throw Failure() }
                    r = rounded
                case "LN": r = try log(at(sp))
                case "MX": sp -= 1; r = try javaMax(at(sp), at(sp + 1))
                case "MI": sp -= 1; r = try javaMin(at(sp), at(sp + 1))
                case "SN": r = try sin(at(sp))
                case "CS": r = try cos(at(sp))
                case "TN": r = try tan(at(sp))
                case "AS": r = try asin(at(sp))
                case "AC": r = try acos(at(sp))
                case "AT": r = try atan(at(sp))
                case "BA": sp -= 1; r = try Double(ottaiKotlinInt(at(sp)) & ottaiKotlinInt(at(sp + 1)))
                case "BO": sp -= 1; r = try Double(ottaiKotlinInt(at(sp)) | ottaiKotlinInt(at(sp + 1)))
                case "BN": r = try Double(~ottaiKotlinInt(at(sp)))
                case "BX": sp -= 1; r = try Double(ottaiKotlinInt(at(sp)) ^ ottaiKotlinInt(at(sp + 1)))
                case "MD":
                    sp -= 1
                    let dividend = try ottaiKotlinInt(at(sp))
                    let divisor = try ottaiKotlinInt(at(sp + 1))
                    if divisor == 0 { throw Failure() }
                    // The JVM answers 0 for Int.MIN % -1; Swift would trap.
                    r = Double(dividend.remainderReportingOverflow(dividingBy: divisor).partialValue)
                default: break
                }
                if sp < 0 { sp = 0 }
                guard sp < stack.count else { throw Failure() }
                stack[sp] = r
            case .number(let value):
                sp += 1
                if sp >= stack.count { return stack.isEmpty ? 0.0 : stack[0] }
                stack[sp] = value
            }
        }
        return stack.isEmpty ? 0.0 : stack[0]
    }

    /// The variable vector V0..V5: current, temperature, runtime, dataNo, runtime / 3600 (integer division), voltage.
    static func buildVariables(rawCurrent: Int, temperature: Double, runtimeSec: Int, dataNo: Int, voltage: Int) -> [Double] {
        return [Double(rawCurrent), temperature, Double(runtimeSec), Double(dataNo), Double(runtimeSec / 3600), Double(voltage)]
    }

    // MARK: Java Math semantics

    /// `Math.pow`: the JVM differs from C for a NaN exponent and for +-1 with an infinite exponent,
    /// and squares exactly.
    private static func javaPow(_ x: Double, _ y: Double) -> Double {
        if y == 0 { return 1.0 }
        if y.isNaN || x.isNaN { return Double.nan }
        if y == 2 { return x * x }
        if y.isInfinite && abs(x) == 1 { return Double.nan }
        return pow(x, y)
    }

    private static func javaMax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return Double.nan }
        if a == 0 && b == 0 { return (a.sign == .minus && b.sign == .minus) ? -0.0 : 0.0 }
        return a >= b ? a : b
    }

    private static func javaMin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return Double.nan }
        if a == 0 && b == 0 { return (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0 }
        return a <= b ? a : b
    }
}

/// `String.format(Locale.ROOT, "%.<decimals>f", value).toDouble()`: Java rounds HALF_UP on the shortest
/// decimal digits of the double (`7.25` with one decimal is `7.3`, `1.005` with two is `1.01`), not on
/// its binary value. Nil for a negative precision (Java throws). NaN and infinities are returned as is.
func ottaiRoundHalfUp(_ value: Double, decimals: Int) -> Double? {
    if decimals < 0 { return nil }
    if !value.isFinite { return value }
    let negative = value.sign == .minus
    let magnitude = abs(value)
    func signed(_ result: Double) -> Double { return negative ? -result : result }
    if magnitude == 0 { return signed(0) }
    if decimals > 400 { return value }

    // Shortest round-trip digits and the position of the decimal point relative to the first digit.
    var text = "\(magnitude)"
    var exponent = 0
    if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exponent = Int(text[text.index(after: marker)...]) ?? 0
        text = String(text[..<marker])
    }
    var integerPart = text
    var fractionPart = ""
    if let dot = text.firstIndex(of: ".") {
        integerPart = String(text[..<dot])
        fractionPart = String(text[text.index(after: dot)...])
    }
    var digits = (integerPart + fractionPart).compactMap { $0.wholeNumberValue }
    var pointPosition = integerPart.count + exponent
    while digits.count > 1, digits.first == 0 {
        digits.removeFirst()
        pointPosition -= 1
    }
    while digits.count > 1, digits.last == 0 { digits.removeLast() }

    let keep = pointPosition + decimals
    var kept = digits
    var newPoint = pointPosition
    if keep < 0 {
        return signed(0)
    } else if keep < digits.count {
        let roundUp = digits[keep] >= 5
        kept = Array(digits[0..<keep])
        if roundUp {
            if keep == 0 {
                kept = [1]
                newPoint = pointPosition + 1
            } else {
                var index = keep - 1
                while index >= 0 {
                    if kept[index] == 9 {
                        kept[index] = 0
                        index -= 1
                    } else {
                        kept[index] += 1
                        break
                    }
                }
                if index < 0 {
                    kept.insert(1, at: 0)
                    newPoint += 1
                }
            }
        }
    }
    if kept.isEmpty { return signed(0) }
    let literal = "0." + kept.map { String($0) }.joined() + "e" + String(newPoint)
    guard let result = Double(literal) else { return nil }
    return signed(result)
}

// MARK: - Method defaults

/// JugglucoNG `OttaiMethodDefaults`: the official app's fallback for the common 14 coefficient formula,
/// used when a response carries the per-sensor coefficients but no method.
enum OttaiMethodDefaults {

    static let standard14CoefficientMethod =
        "V1 C0 ad C1 ml C2 ad;" +
        "V0 R0 2 pw dv;" +
        "C3 0 ml C4 R1 2 pw ml ad C5 R1 ml ad C6 ad;" +
        "C7 R2 2 pw ml C8 R2 ml ad C9 ad;" +
        "C10 V2 86400 dv C11 ml sb V2 C12 1 le ml V2 C12 1 gt C13 ml ad;" +
        "R3 R4 ml 1 rd"

    static func resolve(method: String, coefficient: String) -> String {
        let explicit = OttaiConstants.kotlinTrim(method)
        if !explicit.isEmpty { return explicit }
        return matchesStandard14CoefficientProfile(coefficient) ? standard14CoefficientMethod : ""
    }

    static func matchesStandard14CoefficientProfile(_ coefficient: String) -> Bool {
        var values = [Double]()
        for part in coefficient.split(separator: ",", omittingEmptySubsequences: false) {
            guard let value = ottaiParseKotlinDouble(OttaiConstants.kotlinTrim(String(part))) else { return false }
            values.append(value)
        }
        if values.count != 14 { return false }
        if values.contains(where: { !$0.isFinite }) { return false }
        return values[12] >= 86_400.0 && values[12] <= 604_800.0 && values[13] >= 0.0 && values[13] <= 2.0
    }
}

// MARK: - Output gate

/// JugglucoNG `OttaiOutputFilter`: the final gate before a reading may be published or stored.
enum OttaiOutputFilter {

    static let minRawCurrent = 1_000
    static let maxTemperatureC = 45.0
    static let minTemperatureC = 15.0
    static let maxGlucoseMmol: Float = 40.0
    /// A one minute point moving this far while the electrode current jumps this much is noise.
    static let singleSampleDeltaMmol: Float = 1.5
    static let rawExcursionRatio: Float = 0.18
    static let misframedMinRecords = 8
    static let impossibleTemperatureLowC = 0.0
    static let impossibleTemperatureHighC = 60.0

    /// True when a history frame is almost certainly decoded at the wrong record width: nearly all of
    /// it fails the hard gate and most temperatures are physically impossible.
    static func isMisframedFrame(_ readings: [OttaiReading]) -> Bool {
        if readings.count < misframedMinRecords { return false }
        let accepted = readings.filter { hardRejectReason($0.record, mmol: Float($0.adjustGlucose)) == nil }.count
        if accepted * 4 >= readings.count { return false }
        let impossible = readings.filter { isImpossibleTemperature($0.record.temperatureC) }.count
        return impossible * 2 > readings.count
    }

    private static func isImpossibleTemperature(_ celsius: Double) -> Bool {
        return !celsius.isFinite || celsius < impossibleTemperatureLowC || celsius > impossibleTemperatureHighC
    }

    /// Why a record may not be published, or nil. The text is `glucose=`, `raw=` or `temp=` and the value.
    static func hardRejectReason(_ record: OttaiRecord, mmol: Float) -> String? {
        if !mmol.isFinite || mmol <= 0 { return "glucose=\(mmol)" }
        if mmol > maxGlucoseMmol { return "glucose=\(mmol)" }
        if record.rawCurrent < minRawCurrent { return "raw=\(record.rawCurrent)" }
        if !record.temperatureC.isFinite || record.temperatureC > maxTemperatureC || record.temperatureC < minTemperatureC {
            return "temp=\(record.temperatureC)"
        }
        return nil
    }

    static func isOneMinuteRawExcursion(candidateMmol: Float, candidateRaw: Int, baselineMmol: Float, baselineRaw: Int) -> Bool {
        if !candidateMmol.isFinite || !baselineMmol.isFinite { return false }
        if candidateMmol <= 0 || baselineMmol <= 0 { return false }
        if candidateRaw <= 0 || baselineRaw <= 0 { return false }
        let glucoseDelta = abs(candidateMmol - baselineMmol)
        let rawDeltaRatio = Float(abs(candidateRaw - baselineRaw)) / Float(baselineRaw)
        return glucoseDelta >= singleSampleDeltaMmol && rawDeltaRatio >= rawExcursionRatio
    }
}

// MARK: - Sensor material

/// The per-sensor material the vendor cloud issues for the account that owns a sensor, in the portable
/// JSON format JugglucoNG exports (version 1): the six authentication keys (`keyAHex`, 192 hex digits),
/// the glucose expression and its coefficients, the activation time and the lifetime. This fork never
/// contacts the vendor cloud: without this material a sensor cannot authenticate and no value can be
/// computed, so the driver reports the sensor as unsupported.
struct OttaiMaterials: Equatable, Codable {
    /// Canonical 12 hex digit sensor id: it is the "mac" of the authentication signature.
    var sensorId: String
    var displayName: String
    var keyAHex: String
    var method: String
    var coefficient: String
    var activeTimeMs: Int64
    var activeExpireTimeMs: Int64
    var acceptedMaxActiveMs: Int64
    var deviceVersion: String

    var authKeys: [[UInt8]]? { return OttaiCrypto.parseAuthKeys(keyAHex) }

    /// The sensor id as the 6 bytes of the signature.
    var macBytes: [UInt8]? { return OttaiHex.bytes(OttaiConstants.canonicalSensorId(sensorId)) }

    var coefficients: [Double] {
        return coefficient.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { ottaiParseKotlinDouble(OttaiConstants.kotlinTrim(String($0))) }
    }

    /// The expression to evaluate: the explicit one, else the standard 14 coefficient method.
    var resolvedMethod: String { return OttaiMethodDefaults.resolve(method: method, coefficient: coefficient) }

    /// Keys and an expression are present (the activation time is learned from the stream when missing).
    var canAuthenticateAndCompute: Bool { return authKeys != nil && macBytes?.count == 6 && !resolvedMethod.isEmpty }

    var expectedLifetimeMs: Int64 {
        return OttaiConstants.expectedLifetimeMs(cloudActiveExpireMs: activeExpireTimeMs, acceptedMaxActiveMs: acceptedMaxActiveMs)
    }

    enum ImportFailure: Equatable {
        case notJson
        case missingSensorId
        case sensorIdNotTwelveHex
        case invalidKeys
    }

    /// Ottai's cloud answers in epoch seconds in one case and milliseconds in the others.
    static func normalizeActiveTimeMs(_ value: Int64) -> Int64 {
        return (1...9_999_999_999).contains(value) ? value * 1000 : value
    }

    /// JugglucoNG `OttaiRegistry.importJson`, stricter in one place: the sensor id must be 12 hex digits
    /// because the handshake signs with it.
    static func parse(json: String) -> (materials: OttaiMaterials?, failure: ImportFailure?) {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, .notJson)
        }
        func string(_ key: String) -> String {
            if let value = object[key] as? String { return value }
            return ""
        }
        func integer(_ key: String) -> Int64 {
            if let value = object[key] as? NSNumber { return value.int64Value }
            if let value = object[key] as? String, let parsed = Int64(OttaiConstants.kotlinTrim(value)) { return parsed }
            return 0
        }
        let id = OttaiConstants.canonicalSensorId(string("sensorId"))
        if id.isEmpty { return (nil, .missingSensorId) }
        guard OttaiConstants.looksLikeMac(id) else { return (nil, .sensorIdNotTwelveHex) }
        let keyA = OttaiConstants.kotlinTrim(string("keyAHex"))
        guard OttaiCrypto.parseAuthKeys(keyA) != nil else { return (nil, .invalidKeys) }
        let name = string("displayName")
        let materials = OttaiMaterials(
            sensorId: id,
            displayName: name.isEmpty ? OttaiConstants.displayName : name,
            keyAHex: keyA,
            method: string("method"),
            coefficient: string("coefficient"),
            activeTimeMs: normalizeActiveTimeMs(integer("activeTimeMs")),
            activeExpireTimeMs: OttaiConstants.sanitizeActiveExpireMs(integer("activeExpireTimeMs")),
            acceptedMaxActiveMs: integer("acceptedMaxActiveMs"),
            deviceVersion: string("deviceVersion")
        )
        return (materials, nil)
    }
}
