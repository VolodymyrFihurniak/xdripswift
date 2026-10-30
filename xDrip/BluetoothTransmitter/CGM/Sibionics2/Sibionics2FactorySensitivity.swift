//
// Sibionics2FactorySensitivity.swift
// Behavior adapted from ctqvva/JugglucoNG, commit 34ad7bbdcf3b53d1690347738a6a70f6a985b251 (GPL-3.0).
//

import Foundation

enum Sibionics2FactorySensitivity {
    private static let alphabet = Array("123456789ACDEFGHJKLMNPQRSTUVWXYZ")
    private static let supportedSensitivityRange = 0.8...2.5
    private static let identityBits = [1, 2, 3, 4, 18, 6, 7, 8, 9, 19, 11, 12, 13, 14, 16, 17, 0, 5, 10, 15]
    private static let sensitivityBits = [7, 8, 9, 0, 1, 2, 4, 5, 6, 3]
    /// Sibionics 2 variant token used by JugglucoNG when the sensor codes cannot be decoded.
    private static let variantFallbackShortCode = "0316015A"
    /// Final fallback when the variant token also fails to decode.
    static let defaultSensitivity: Double = 1.27

    static func isSupported(_ sensitivity: Double) -> Bool {
        sensitivity.isFinite && supportedSensitivityRange.contains(sensitivity)
    }

    /// Sibionics 2 decodes the QR probe code first. Sibionics 1 follows JugglucoNG's
    /// sensitivityFor: the probe decoder is Sibionics 2 only, so S1 uses its short code,
    /// then its own variant's fallback token, then 1.27.
    static func effectiveSensitivity(
        advertisedName: String?,
        probeCode: String? = nil,
        variant: SibionicsDeviceVariant = .sibionics2,
        sibionics1Family: Sibionics1Family = .eu,
        labelShortCode: String? = nil
    ) -> Double {
        guard variant == .sibionics1 else {
            // sensitivityFor(SIBIONICS2): probe code, then the label's short code, then the name.
            return decodeProbe(probeCode)
                ?? labelShortCode.flatMap { decodeShortCode($0) }
                ?? resolve(probeCode: nil, shortCode: advertisedName)
        }
        return sibionics1ShortCodeSensitivity(
            advertisedName: advertisedName, family: sibionics1Family, labelShortCode: labelShortCode
        )
            ?? decodeShortCode(sibionics1Family.fallbackShortCode)
            ?? defaultSensitivity
    }

    /// Sensitivity decoded from the S1 short code, or nil when only the variant fallback applies.
    /// A scanned label's short code wins over the one derived from the Bluetooth name, as
    /// JugglucoNG builds the sensor identity from the QR payload when one is given.
    static func sibionics1ShortCodeSensitivity(
        advertisedName: String?, family: Sibionics1Family, labelShortCode: String? = nil
    ) -> Double? {
        if let labelShortCode, let decoded = decodeShortCode(labelShortCode) { return decoded }
        let shortCode = deriveShortCode(advertisedName, fallback: family.fallbackShortCode)
        guard shortCode != family.fallbackShortCode else { return nil }
        return decodeShortCode(shortCode)
    }

    /// JugglucoNG's SibionicsSensitivity.deriveShortCode for a Bluetooth name.
    static func deriveShortCode(_ source: String?, fallback: String) -> String {
        let normalized = normalize(source)
        if normalized.count >= 8 {
            let prefix = String(normalized.prefix(8))
            if decodeShortCode(prefix) != nil { return prefix }
        }
        let shortName: String
        if normalized.count <= 11 && normalized.hasPrefix("LT") && normalized.count >= 8 {
            shortName = String((String(normalized.suffix(4)) + normalized).prefix(11))
        } else if (1...10).contains(normalized.count) {
            shortName = String(repeating: "0", count: 11 - normalized.count) + normalized
        } else if normalized.count >= 11 {
            shortName = String(normalized.prefix(11))
        } else {
            shortName = fallback
        }
        let candidate = String(shortName.prefix(8))
        return candidate.count == 8 ? candidate : fallback
    }

    static func decodeProbe(_ code: String?) -> Double? {
        guard let code, code.count == 14 else { return nil }
        let characters = Array(code)
        let values = characters.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 14, (values[7] + values[11]) % 32 == 1 else { return nil }

        let batch: [Int] = (0..<4).map { index in
            let firstValue = values[index]
            let secondValue = values[index + 8]
            return (firstValue + secondValue) % 32
        }
        let sensitivity: [Int] = (0..<3).map { index in
            let firstValue = values[index]
            let secondValue = values[index + 4]
            let thirdValue = values[index + 8]
            let sum = firstValue + secondValue + thirdValue
            return sum % 32
        }
        var checksum = 0
        for value in batch {
            checksum += value
        }
        for value in values[8..<12] {
            checksum += value
        }
        for value in sensitivity {
            checksum += value
        }
        checksum %= 1024
        guard checksum == values[12] * 32 + values[13] else { return nil }

        let batchBits = permute(batch, order: identityBits)
        let year = batchBits >> 15
        let month = (batchBits >> 11) & 15
        let lot = (batchBits >> 4) & 127
        guard (1...12).contains(month), (year + month + lot) % 16 == (batchBits & 15) else {
            return nil
        }

        let serialBits = permute(Array(values[8..<12]), order: identityBits)
        let serial = serialBits >> 4
        let serialChecksum = serial / 2400 + (serial % 2400) / 100
            + (serial % 100) / 10 + serial % 10
        guard serialChecksum % 16 == (serialBits & 15) else { return nil }

        let packed = sensitivity[0] * 32 + sensitivity[1]
        let hundredths = permute(Array(sensitivity.prefix(2)), order: sensitivityBits)
        guard hundredths < 1000 else { return nil }
        let digitSum = packed / 100 + (packed / 10) % 10 + packed % 10
        guard sensitivity[2] == (hundredths % 4) * 8 + digitSum % 8 else { return nil }
        let decoded = Double(hundredths) / 100
        return isSupported(decoded) ? decoded : nil
    }

    static func decodeShortCode(_ source: String?) -> Double? {
        let token = normalize(source).suffix(4)
        guard token.count == 4 else { return nil }
        if token.allSatisfy({ $0.isNumber }),
           let number = Int(String(token)) {
            let decoded = Double(number) / 1000
            return isSupported(decoded) ? decoded : nil
        }
        let text = String(token)
        for base in [Character("A"), Character("P")] {
            if let digits = decodedDigits(text, base: base) {
                let decoded = Double(digits) / 100
                if isSupported(decoded) { return decoded }
            }
        }
        return nil
    }

    static func resolve(advertisedName: String?) -> Double {
        let normalizedName = normalize(advertisedName)
        let probeCode = normalizedName.count == 14 ? normalizedName : nil
        let shortCode = normalizedName.count >= 8 ? String(normalizedName.prefix(8)) : normalizedName
        return resolve(probeCode: probeCode, shortCode: shortCode)
    }

    static func resolve(probeCode: String?, shortCode: String?) -> Double {
        decodeProbe(probeCode)
            ?? decodeShortCode(shortCode)
            ?? decodeShortCode(variantFallbackShortCode)
            ?? defaultSensitivity
    }

    private static func normalize(_ source: String?) -> String {
        String((source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func permute(_ values: [Int], order: [Int]) -> Int {
        let packed = values.reduce(0) { ($0 << 5) | $1 }
        return order.reduce(0) { result, bit in
            (result << 1) | ((packed >> (order.count - 1 - bit)) & 1)
        }
    }

    private static func decodedDigits(_ token: String, base: Character) -> Int? {
        let mapped = token.uppercased().map { character -> Character in
            switch character {
            case "K": return "I"
            case "I": return "!"
            default: return character
            }
        }
        guard mapped.count == 4 else { return nil }
        let chars = mapped.compactMap { $0.asciiValue }.map(Int.init)
        guard chars.count == 4, let baseValue = base.asciiValue.map(Int.init) else { return nil }
        let t0 = chars[0], t1 = chars[1], t2 = chars[2], t3 = chars[3]

        let out3 = (baseValue - t3) + 57
        var w9 = (t3 - baseValue) + 48
        let w10: Int
        let out2: Int
        if t2 >= baseValue {
            let w11 = t2 - baseValue
            w10 = w11 + 48
            w9 = (9 - w11) + w9
            out2 = w9
        } else {
            let w11 = t2 <= (w9 & 0xff) ? 48 : 57
            w9 = (w11 - t2) + w9
            w10 = t2
            out2 = w9
        }

        let out1: Int
        let w11: Int
        var w10b = w10
        if t1 >= baseValue {
            let w12 = t1 - baseValue
            w11 = w12 + 48
            w10b = (9 - w12) + w10b
            out1 = w10b
        } else {
            let w12 = (t1 <= (w10b & 0xff) ? 48 : 57) - t1
            w11 = t1
            w10b += w12
            out1 = w10b
        }

        let out0: Int
        if t0 >= baseValue {
            out0 = (baseValue - t0) + 9 + w11
        } else {
            let w12 = (t0 <= (w11 & 0xff) ? 48 : 57) - t0
            out0 = w12 + w11
        }

        let remainder = (out0 + out1 + out2 - 0x90) % 10
        let checksum = remainder < 0 ? remainder + 10 : remainder
        guard out3 - 48 == checksum,
              let c0 = UnicodeScalar(out0), let c1 = UnicodeScalar(out1), let c2 = UnicodeScalar(out2)
        else { return nil }
        return Int(String(String.UnicodeScalarView([c0, c1, c2])))
    }
}

/// Sibionics 1 product lines, which differ in key group, fallback sensitivity token
/// and stock algorithm (JugglucoNG SibionicsConstants.Variant EU, HEMATONIX, CHINESE).
enum Sibionics1Family {
    case eu
    case hematonix
    case chinese

    var fallbackShortCode: String {
        switch self {
        case .eu: return "YMWD016F"
        case .hematonix: return "YEZ1450H"
        case .chinese: return "GEPD802J"
        }
    }

    /// The family follows the confirmed protocol and the key group that produced readings.
    static func resolve(protocolMode: Sibionics1ProtocolMode?, keyGroup: Sibionics2KeyGroup?) -> Sibionics1Family {
        if protocolMode == .chinese { return .chinese }
        return keyGroup == .hematonix ? .hematonix : .eu
    }
}

/// The Sibionics sensor label: a GS1 code carrying GTIN (01), dates (11, 17),
/// batch (10) and serial (21). Ported from JugglucoNG SibionicsRegistry
/// (supportedQrMatch, acceptsIdentityForm, deriveNativeQrName, buildIdentity).
enum SibionicsSensorLabel {
    /// What a label contributes to factory sensitivity.
    enum Code: Equatable {
        /// A Sibionics 2 14-character factory probe code.
        case probeCode(String)
        /// An 8-character short code whose last four characters encode sensitivity.
        case shortCode(String)
    }

    enum ParseError: Error, Equatable {
        /// Not a Sibionics GS1 sensor label.
        case notSibionicsLabel
        /// The label belongs to the other sensor type (V120 "P"/"XPT" serial is Sibionics 2).
        case otherSensorType
        /// A Sibionics 2 label that carries no decodable factory code.
        case noFactoryCode
    }

    private static let groupSeparator: Character = "\u{1D}"
    private static let gtinPrefix = "0697283164"
    private static let labelPattern = try! NSRegularExpression(
        pattern: "^\u{1D}?01(\\d{14})11\\d{6}17\\d{6}10[A-Z0-9]{8,20}\u{1D}?21([A-Z0-9]{10,20})\u{1D}?$"
    )

    static func code(fromLabel payload: String, variant: SibionicsDeviceVariant) -> Result<Code, ParseError> {
        variant == .sibionics1
            ? sibionics1ShortCode(fromLabel: payload).map(Code.shortCode)
            : sibionics2Code(fromLabel: payload)
    }

    /// The 8-character short code JugglucoNG stores for a Sibionics 1 sensor; its last
    /// four characters encode the factory sensitivity.
    static func sibionics1ShortCode(fromLabel payload: String) -> Result<String, ParseError> {
        switch validatedSerial(payload) {
        case .failure(let error):
            return .failure(error)
        case .success(let (cleaned, serial)):
            guard !isV120Serial(serial) else { return .failure(.otherSensorType) }
            // buildIdentity: the QR short view is the last 11 characters; its first 8 are the short code.
            guard let nativeName = nativeName(cleaned) else { return .failure(.notSibionicsLabel) }
            let shortView = String(nativeName.suffix(11))
            guard shortView.count == 11 else { return .failure(.notSibionicsLabel) }
            return .success(String(shortView.prefix(8)))
        }
    }

    /// A Sibionics 2 label: JugglucoNG keeps the AI (21) value as the probe code when it
    /// decodes (the XPT form). A P-form serial instead yields the short code of its
    /// structured identity: "1" plus the first 15 serial characters, last 11, first 8.
    static func sibionics2Code(fromLabel payload: String) -> Result<Code, ParseError> {
        switch validatedSerial(payload) {
        case .failure(let error):
            return .failure(error)
        case .success(let (_, serial)):
            guard isV120Serial(serial) else { return .failure(.otherSensorType) }
            if Sibionics2FactorySensitivity.decodeProbe(serial) != nil { return .success(.probeCode(serial)) }
            guard serial.hasPrefix("P"), serial.count >= 16 else { return .failure(.noFactoryCode) }
            let identity = "1" + serial.prefix(15)
            let shortCode = String(identity.suffix(11).prefix(8))
            guard Sibionics2FactorySensitivity.decodeShortCode(shortCode) != nil else { return .failure(.noFactoryCode) }
            return .success(.shortCode(shortCode))
        }
    }

    /// Scanners may prefix the GS1 Data Matrix identifier and render FNC1 as "^]".
    static func cleanPayload(_ source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("]D2") { text.removeFirst(3) }
        text = text.replacingOccurrences(of: "^]", with: String(groupSeparator))
        return String(text.filter {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == groupSeparator
        })
    }

    /// supportedQrMatch: GS1 layout, Sibionics GTIN with a valid check digit and a native identity.
    private static func validatedSerial(_ payload: String) -> Result<(String, String), ParseError> {
        let cleaned = cleanPayload(payload)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = labelPattern.firstMatch(in: cleaned, range: range),
              let gtinRange = Range(match.range(at: 1), in: cleaned),
              let serialRange = Range(match.range(at: 2), in: cleaned) else {
            return .failure(.notSibionicsLabel)
        }
        let gtin = String(cleaned[gtinRange])
        guard gtin.hasPrefix(gtinPrefix), hasValidCheckDigit(gtin), nativeName(cleaned) != nil else {
            return .failure(.notSibionicsLabel)
        }
        return .success((cleaned, String(cleaned[serialRange])))
    }

    private static func isV120Serial(_ serial: String) -> Bool {
        serial.hasPrefix("P") || serial.hasPrefix("XPT")
    }

    /// JugglucoNG's legacy 16-character identity window, which the stock app also uses.
    private static func nativeName(_ payload: String) -> String? {
        let characters = Array(payload)
        guard payload.contains(gtinPrefix), characters.count >= 50 else { return nil }
        let window: [Character]
        if characters.count < 65 {
            let endLength = characters.count - 49
            let startLength = 16 - endLength
            guard endLength > 0, startLength >= 0,
                  characters.count >= 49 + endLength, characters.count >= 22 + startLength else { return nil }
            window = Array(characters[22..<(22 + startLength)]) + Array(characters[49..<(49 + endLength)])
        } else {
            let start = characters.count - 17
            window = Array(characters[start..<(start + 16)])
        }
        guard window.count == 16 else { return nil }
        return String(window.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    private static func hasValidCheckDigit(_ gtin: String) -> Bool {
        let digits = gtin.compactMap(\.wholeNumberValue)
        guard digits.count == gtin.count, let check = digits.last else { return false }
        let body = digits.dropLast()
        let sum = body.enumerated().reduce(0) { total, item in
            total + ((body.count - item.offset) % 2 == 1 ? item.element * 3 : item.element)
        }
        return (10 - sum % 10) % 10 == check
    }
}
