//
//  MQAlgorithm.swift
//  xdrip
//
//  The Glutec glucose calculation and the first-reference bootstrap, ported from the JugglucoNG
//  `drivers/mq` package (`MQAlgorithm`, `MQBootstrapSeed`; GPL-3.0, see THIRD_PARTY_NOTICES.md).
//  The transmitter sends a raw current per packet; the vendor algorithm smooths it against the
//  previous processed current, subtracts an offset B, and divides by a slope K that is solved from a
//  reference glucose. All arithmetic stays in `Double` exactly as in Kotlin, K and B are persisted as
//  `Float` and recovered through their decimal text (`decimalParameter`), and K and B are truncated
//  down to two decimals the way the vendor's `BigDecimal` code does.
//
//  The accuracy of the values is unverified: JugglucoNG's own evidence notes record an excursion the
//  port cannot explain and history-dependent K/B adjustments of the vendor service that are not
//  ported. Never tried on a real sensor.
//

import Foundation

// MARK: - Decimal text (Kotlin BigDecimal.setScale(n, RoundingMode.DOWN))

/// A decimal number as digits and a decimal point position, read from the shortest text Swift (and
/// Kotlin's `toString`) prints for a `Double` or `Float`. Used to truncate toward zero at a number of
/// fraction digits without the error of binary arithmetic.
struct MQDecimalDigits: Equatable {
    var negative: Bool
    /// Significant digits 0 to 9 without leading or trailing zeros; empty for zero.
    var digits: [UInt8]
    /// Number of digits before the decimal point (negative or larger than `digits.count` is allowed).
    var pointPosition: Int

    /// Parses `[-]digits[.digits][e[+-]digits]`.
    init?(_ text: String) {
        var rest = Substring(text)
        var isNegative = false
        if rest.first == "-" {
            isNegative = true
            rest = rest.dropFirst()
        } else if rest.first == "+" {
            rest = rest.dropFirst()
        }
        var exponent = 0
        if let marker = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let exponentText = rest[rest.index(after: marker)...]
            guard let parsed = Int(exponentText.hasPrefix("+") ? String(exponentText.dropFirst()) : String(exponentText)) else { return nil }
            exponent = parsed
            rest = rest[..<marker]
        }
        var integerPart = rest
        var fractionPart = Substring("")
        if let dot = rest.firstIndex(of: ".") {
            integerPart = rest[..<dot]
            fractionPart = rest[rest.index(after: dot)...]
        }
        var all = [UInt8]()
        for character in String(integerPart) + String(fractionPart) {
            guard let digit = character.wholeNumberValue, character.isASCII else { return nil }
            all.append(UInt8(digit))
        }
        guard !all.isEmpty else { return nil }
        var position = integerPart.count + exponent
        var leading = 0
        while leading < all.count && all[leading] == 0 { leading += 1 }
        all.removeFirst(leading)
        position -= leading
        while let last = all.last, last == 0 { all.removeLast() }
        if all.isEmpty { position = 0 }
        negative = isNegative
        digits = all
        pointPosition = position
    }

    /// Truncates toward zero so that at most `scale` digits remain after the decimal point.
    func truncated(toFractionDigits scale: Int) -> MQDecimalDigits {
        let keep = pointPosition + scale
        if digits.isEmpty || keep >= digits.count { return self }
        var copy = self
        if keep <= 0 {
            copy.digits = []
            copy.pointPosition = 0
            return copy
        }
        copy.digits = Array(digits.prefix(keep))
        while let last = copy.digits.last, last == 0 { copy.digits.removeLast() }
        if copy.digits.isEmpty { copy.pointPosition = 0 }
        return copy
    }

    /// The same number times 10^places (the decimal point moves right by `places`).
    func timesPowerOfTen(_ places: Int) -> MQDecimalDigits {
        var copy = self
        if !digits.isEmpty { copy.pointPosition += places }
        return copy
    }

    /// Scientific text such as `2930e-2`, which `Double(_:)` and `Float(_:)` parse exactly.
    private var scientificText: String {
        if digits.isEmpty { return "0" }
        let body = digits.map { String($0) }.joined()
        return (negative ? "-" : "") + body + "e" + String(pointPosition - digits.count)
    }

    /// Nearest `Double` (Kotlin `BigDecimal.toDouble()`); zero is positive zero, as BigDecimal has no -0.
    func doubleValue() -> Double {
        if digits.isEmpty { return 0 }
        return Double(scientificText) ?? .nan
    }

    /// Nearest `Float` (Kotlin `BigDecimal.toFloat()`); out of range gives infinity.
    func floatValue() -> Float {
        if digits.isEmpty { return 0 }
        return Float(scientificText) ?? (negative ? -.infinity : .infinity)
    }
}

// MARK: - Algorithm

/// JugglucoNG `MQAlgorithm`.
enum MQAlgorithm {

    /// Preferences store floats; recover the decimal value of a float (`Float.toString().toDouble()`)
    /// before the vendor's decimal truncation, so a stored 29.41 stays 29.41 and not 29.4099998.
    static func decimalParameter(_ value: Float) -> Double {
        if value.isNaN { return .nan }
        if value.isInfinite { return value < 0 ? -.infinity : .infinity }
        return Double(String(value)) ?? Double(value)
    }

    /// `BigDecimal(value.toString()).setScale(2, RoundingMode.DOWN).toDouble()`. Kotlin throws for NaN
    /// and infinity; the port returns the value unchanged (no reachable input produces one).
    static func roundDown2(_ value: Double) -> Double {
        guard value.isFinite, let parts = MQDecimalDigits(String(value)) else { return value }
        return parts.truncated(toFractionDigits: 2).doubleValue()
    }

    /// The ramp the vendor applies to the raw current: version 1 scales it from the multiplier down to
    /// 1 over `packages` packets after the warm-up threshold, version 0 uses a fixed ramp up to
    /// packet 250.
    static func adjustSampleCurrent(
        algorithmVersion: Int,
        packetIndex: Double,
        sampleCurrent: Double,
        packages: Double,
        multiplier: Double
    ) -> Double {
        if algorithmVersion >= 1 {
            if packetIndex < MQConstants.algoWarmupPacketThreshold {
                return sampleCurrent
            }
            let threshold = packages + MQConstants.algoWarmupPacketThreshold
            if packetIndex <= threshold {
                let factor = multiplier - (((multiplier - 1.0) / threshold) * (packetIndex - MQConstants.algoWarmupPacketThreshold))
                return factor * sampleCurrent
            }
            return sampleCurrent
        }
        if packetIndex > 8.0 && packetIndex < 250.0 {
            return ((100.0 - ((((250.0 - packetIndex) + 1.0) * 25.0) / 242.0)) * sampleCurrent) / 100.0
        }
        return sampleCurrent
    }

    /// The vendor `GlucoseCalculation`, returning its eight outputs:
    /// `[packet, sampleCurrent, reviseCurrent2, previousReviseCurrent2, K, referenceTimes10, B, glucoseMmolTimes10]`.
    static func calculate(
        algorithmVersion: Int,
        initTimeMinutes: Double,
        packetIndex: Double,
        sampleCurrent: Double,
        previousReviseCurrent2: Double,
        kValue: Double,
        referenceBgTimes10Mmol: Double,
        bValue: Double,
        packages: Double,
        multiplier: Double
    ) -> [Double] {
        var reviseCurrent = adjustSampleCurrent(
            algorithmVersion: algorithmVersion,
            packetIndex: packetIndex,
            sampleCurrent: sampleCurrent,
            packages: packages,
            multiplier: multiplier
        )

        var nextBValue = bValue != 0.0 ? bValue : 0.0
        var nextKValue = kValue != 0.0 ? kValue : 0.0

        if packetIndex > 8.0 && nextKValue != 0.0 && nextBValue != 0.0 && initTimeMinutes > 9.0 {
            if reviseCurrent < 5.0 {
                reviseCurrent = previousReviseCurrent2 + nextBValue
            } else {
                let target = previousReviseCurrent2 + nextBValue
                let tolerance = target * 0.05
                let upper = target + tolerance + 0.5
                let lower = target - tolerance - 0.5
                if reviseCurrent > upper {
                    reviseCurrent = upper
                } else if reviseCurrent < lower {
                    reviseCurrent = lower
                }
            }
        }

        var reviseCurrent2 = MQConstants.algoMmolFloor
        if referenceBgTimes10Mmol == 0.0 {
            if reviseCurrent > nextBValue { reviseCurrent -= nextBValue }
            if reviseCurrent >= MQConstants.algoMmolFloor || nextKValue == 0.0 {
                reviseCurrent2 = reviseCurrent
            }
        } else {
            nextBValue = 2.0
            if reviseCurrent > 2.0 { reviseCurrent -= 2.0 }
            reviseCurrent2 = reviseCurrent < MQConstants.algoMmolFloor ? MQConstants.algoMmolFloor : reviseCurrent
            let referenceBgMmol = referenceBgTimes10Mmol / 10.0
            nextKValue = referenceBgMmol > 0.0 ? reviseCurrent2 / referenceBgMmol : 0.0
        }

        var glucoseTimes10Mmol = 0.0
        if nextKValue > 0.0 {
            let raw = ((reviseCurrent2 / nextKValue) + 0.05) * 10.0
            if raw <= MQConstants.algoMmolMinTimes10 {
                glucoseTimes10Mmol = MQConstants.algoMmolMinTimes10
            } else if raw >= MQConstants.algoMmolMaxTimes10 {
                glucoseTimes10Mmol = MQConstants.algoMmolMaxTimes10
            } else {
                glucoseTimes10Mmol = raw
            }
        }

        return [
            Double(mqKotlinInt(packetIndex)),
            Double(mqKotlinInt(sampleCurrent)),
            Double(mqKotlinInt(reviseCurrent2 + 0.5)),
            Double(mqKotlinInt(previousReviseCurrent2)),
            roundDown2(nextKValue),
            Double(mqKotlinInt(referenceBgTimes10Mmol)),
            roundDown2(nextBValue),
            Double(mqKotlinInt(glucoseTimes10Mmol))
        ]
    }

    /// A decoded reading of the vendor algorithm.
    struct Result: Equatable {
        let packetIndex: Int
        let sampleCurrent: Double
        let reviseCurrent2: Double
        let previousReviseCurrent2: Double
        let kValue: Double
        let referenceBgTimes10Mmol: Double
        let bValue: Double
        let glucoseTimes10Mmol: Int
        let glucoseMmol: Double

        /// mg/dL times ten, converted from the vendor's mmol/L.
        var mgdlTimes10: Int {
            return mqKotlinRound(glucoseMmol * MQConstants.mmolToMgdl * 10.0)
        }

        /// mg/dL.
        var mgdl: Float {
            return Float(glucoseMmol * MQConstants.mmolToMgdl)
        }

        /// mmol/L.
        var mmol: Float {
            return Float(glucoseMmol)
        }
    }

    static func calculateResult(
        algorithmVersion: Int,
        initTimeMinutes: Double,
        packetIndex: Double,
        sampleCurrent: Double,
        previousReviseCurrent2: Double,
        kValue: Double,
        referenceBgTimes10Mmol: Double,
        bValue: Double,
        packages: Double,
        multiplier: Double
    ) -> Result {
        let values = calculate(
            algorithmVersion: algorithmVersion,
            initTimeMinutes: initTimeMinutes,
            packetIndex: packetIndex,
            sampleCurrent: sampleCurrent,
            previousReviseCurrent2: previousReviseCurrent2,
            kValue: kValue,
            referenceBgTimes10Mmol: referenceBgTimes10Mmol,
            bValue: bValue,
            packages: packages,
            multiplier: multiplier
        )
        let glucoseTimes10Mmol = mqKotlinInt(values[7])
        return Result(
            packetIndex: mqKotlinInt(values[0]),
            sampleCurrent: values[1],
            reviseCurrent2: values[2],
            previousReviseCurrent2: values[3],
            kValue: values[4],
            referenceBgTimes10Mmol: values[5],
            bValue: values[6],
            glucoseTimes10Mmol: glucoseTimes10Mmol,
            glucoseMmol: Double(glucoseTimes10Mmol) / 10.0
        )
    }
}

// MARK: - First reference from the factory sensitivity

/// JugglucoNG `MQBootstrapSeed`: how the vendor turns the factory sensitivity of the sensor code into
/// a first reference glucose at packet 19 and later, so a slope can be solved without a fingerstick.
enum MQBootstrapSeed {

    /// The sensitivity of the sensor code is raw; the vendor normalises it with the transmitter scale
    /// flag from the server: 0 keeps it, 1 multiplies by ten and truncates to one decimal, anything
    /// else (including an unknown flag) is not a usable seed.
    static func normalizeSensitivity(raw: Float?, transmitter10: Int?) -> Float? {
        guard let raw = raw, raw.isFinite, raw > 0 else { return nil }
        guard let scale = transmitter10 else { return nil }
        switch scale {
        case 0:
            return raw
        case 1:
            guard let parts = MQDecimalDigits(String(raw)) else { return nil }
            let value = parts.timesPowerOfTen(1).truncated(toFractionDigits: 1).floatValue()
            return (value.isFinite && value > 0) ? value : nil
        default:
            return nil
        }
    }

    /// The vendor's first-reference call: init time 1 (not the elapsed minutes, which would smooth
    /// against an empty history), no reference, B = 2, K = the sensitivity. The caller uses
    /// `glucoseTimes10Mmol` of the result as the reference for the real calculation.
    static func initialReference(
        algorithmVersion: Int,
        packetIndex: Int,
        sampleCurrent: Int,
        previousProcessed: Double,
        sensitivity: Double,
        packages: Int,
        multiplier: Double
    ) -> MQAlgorithm.Result? {
        if !sensitivity.isFinite || sensitivity <= 0.0
            || Double(packetIndex) < MQConstants.algoWarmupPacketThreshold || sampleCurrent <= 0 {
            return nil
        }
        return MQAlgorithm.calculateResult(
            algorithmVersion: algorithmVersion,
            initTimeMinutes: 1.0,
            packetIndex: Double(packetIndex),
            sampleCurrent: Double(sampleCurrent),
            previousReviseCurrent2: previousProcessed,
            kValue: sensitivity,
            referenceBgTimes10Mmol: 0.0,
            bValue: 2.0,
            packages: Double(packages),
            multiplier: multiplier
        )
    }
}
