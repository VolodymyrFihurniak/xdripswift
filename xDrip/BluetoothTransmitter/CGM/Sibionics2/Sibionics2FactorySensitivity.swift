//
// Sibionics2FactorySensitivity.swift
// Behavior adapted from ctqvva/JugglucoNG, commit 34ad7bbdcf3b53d1690347738a6a70f6a985b251 (GPL-3.0).
//

import Foundation

enum Sibionics2FactorySensitivity {
    private static let alphabet = Array("123456789ACDEFGHJKLMNPQRSTUVWXYZ")
    private static let identityBits = [1, 2, 3, 4, 18, 6, 7, 8, 9, 19, 11, 12, 13, 14, 16, 17, 0, 5, 10, 15]
    private static let sensitivityBits = [7, 8, 9, 0, 1, 2, 4, 5, 6, 3]
    private static let sibionics2FallbackShortCode = "0316015A"

    static func isSupported(_ sensitivity: Double) -> Bool {
        sensitivity.isFinite && (0.8...2.5).contains(sensitivity)
    }

    static func decodeProbe(_ code: String?) -> Double? {
        guard let code, code.count == 14 else { return nil }
        let characters = Array(code)
        let values = characters.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 14, (values[7] + values[11]) % 32 == 1 else { return nil }

        let batch = (0..<4).map { (values[$0] + values[$0 + 8]) % 32 }
        let sensitivity = (0..<3).map {
            (values[$0] + values[$0 + 4] + values[$0 + 8]) % 32
        }
        let checksum = (batch.reduce(0, +) + values[8..<12].reduce(0, +)
            + sensitivity.reduce(0, +)) % 1024
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

    static func resolve(probeCode: String?, shortCode: String?) -> Double {
        decodeProbe(probeCode)
            ?? decodeShortCode(shortCode)
            ?? decodeShortCode(sibionics2FallbackShortCode)
            ?? 1.27
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
