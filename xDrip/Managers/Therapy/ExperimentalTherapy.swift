//
//  ExperimentalTherapy.swift
//  xdrip
//
//  Experimental features ported from JugglucoNG (GPL-3.0, see THIRD_PARTY_NOTICES.md):
//  - glucose prediction: `data/prediction/GlucosePredictionKernel.kt` and the treatment model in
//    `data/prediction/GlucosePrediction.kt`;
//  - insulin action curves: `data/journal/JournalInsulinCurveCatalogue.kt` and the generated
//    curves in `data/journal/JournalModels.kt`;
//  - insulin activity on the chart: `ui/InsulinActivityStack.kt`.
//
//  Everything here is plain arithmetic over value types, so it can be tested without Core Data.
//

import Foundation
import CoreData
import SwiftUI

// MARK: - Settings

/// How the main chart draws glucose readings.
enum ExperimentalGlucoseChartStyle: Int, CaseIterable {
    /// One dot per reading (xDrip's own style).
    case points = 0
    /// A connected line, broken at gaps, as in JugglucoNG.
    case line = 1
}

/// Prediction horizons offered in Settings. JugglucoNG clamps the horizon to 30...360 minutes.
enum ExperimentalPredictionHorizon {
    static let choices = [60, 90, 120, 180, 240]
    static let defaultMinutes = 120
}

extension UserDefaults {
    private enum ExperimentalKey {
        static let chartStyle = "experimentalGlucoseChartStyle"
        static let predictionEnabled = "experimentalPredictionEnabled"
        static let predictionHorizon = "experimentalPredictionHorizonMinutes"
        static let predictionMomentum = "experimentalPredictionTrendMomentum"
        static let predictionCarbRatio = "experimentalPredictionCarbRatio"
        static let predictionSensitivity = "experimentalPredictionInsulinSensitivityMgDl"
        static let predictionAbsorption = "experimentalPredictionCarbAbsorption"
        static let insulinsEnabled = "experimentalInsulinsEnabled"
        static let bolusInsulin = "experimentalBolusInsulin"
        static let basalInsulin = "experimentalBasalInsulin"
    }

    var experimentalGlucoseChartStyle: ExperimentalGlucoseChartStyle {
        get { ExperimentalGlucoseChartStyle(rawValue: integer(forKey: ExperimentalKey.chartStyle)) ?? .points }
        set { set(newValue.rawValue, forKey: ExperimentalKey.chartStyle) }
    }

    /// Off by default here: JugglucoNG enables it, but in xDrip it is an experimental feature.
    var experimentalPredictionEnabled: Bool {
        get { bool(forKey: ExperimentalKey.predictionEnabled) }
        set { set(newValue, forKey: ExperimentalKey.predictionEnabled) }
    }

    var experimentalPredictionHorizonMinutes: Int {
        get {
            let stored = integer(forKey: ExperimentalKey.predictionHorizon)
            return ExperimentalPredictionHorizon.choices.contains(stored) ? stored : ExperimentalPredictionHorizon.defaultMinutes
        }
        set { set(newValue, forKey: ExperimentalKey.predictionHorizon) }
    }

    /// JugglucoNG `DEFAULT_PREDICTION_TREND_MOMENTUM = true`.
    var experimentalPredictionTrendMomentum: Bool {
        get { object(forKey: ExperimentalKey.predictionMomentum) == nil || bool(forKey: ExperimentalKey.predictionMomentum) }
        set { set(newValue, forKey: ExperimentalKey.predictionMomentum) }
    }

    /// Grams of carbohydrate covered by one unit. JugglucoNG default 10, range 3...30.
    var experimentalPredictionCarbRatio: Double {
        get { Self.experimentalValue(object(forKey: ExperimentalKey.predictionCarbRatio), fallback: ExperimentalPredictionModel.defaultCarbRatio, range: ExperimentalPredictionModel.carbRatioRange) }
        set { set(newValue, forKey: ExperimentalKey.predictionCarbRatio) }
    }

    /// Glucose drop per unit in mg/dL. JugglucoNG default 54, range 10...180.
    var experimentalPredictionInsulinSensitivityMgDl: Double {
        get { Self.experimentalValue(object(forKey: ExperimentalKey.predictionSensitivity), fallback: ExperimentalPredictionModel.defaultInsulinSensitivityMgDl, range: ExperimentalPredictionModel.insulinSensitivityRange) }
        set { set(newValue, forKey: ExperimentalKey.predictionSensitivity) }
    }

    /// Grams absorbed per hour. JugglucoNG default 35, range 10...90.
    var experimentalPredictionCarbAbsorption: Double {
        get { Self.experimentalValue(object(forKey: ExperimentalKey.predictionAbsorption), fallback: ExperimentalPredictionModel.defaultCarbAbsorption, range: ExperimentalPredictionModel.carbAbsorptionRange) }
        set { set(newValue, forKey: ExperimentalKey.predictionAbsorption) }
    }

    /// Body weight in kg for insulin curves measured per kilogram (Fiasp, Levemir, regular).
    /// JugglucoNG `JournalHumanProfile` accepts 10...400 kg; nil uses the study's reference dose.
    var experimentalBodyWeightKg: Double? {
        get {
            guard let value = (object(forKey: "experimentalBodyWeightKg") as? NSNumber)?.doubleValue, value.isFinite,
                  ExperimentalPredictionModel.bodyWeightRange.contains(value) else { return nil }
            return value
        }
        set {
            if let newValue, newValue.isFinite { set(min(max(newValue, ExperimentalPredictionModel.bodyWeightRange.lowerBound), ExperimentalPredictionModel.bodyWeightRange.upperBound), forKey: "experimentalBodyWeightKg") }
            else { removeObject(forKey: "experimentalBodyWeightKg") }
        }
    }

    /// Time-of-day periods after midnight, encoded as JugglucoNG's `PredictionModelProfile`
    /// ("start,carbRatio,sensitivity,absorption;..."). Midnight uses the single values above.
    var experimentalPredictionPeriods: [ExperimentalPredictionPeriod] {
        get { ExperimentalPredictionPeriod.decode(string(forKey: "experimentalPredictionPeriods")) }
        set { set(ExperimentalPredictionPeriod.encode(newValue), forKey: "experimentalPredictionPeriods") }
    }

    /// Adds the late rise of protein and fat to the forecast (JugglucoNG "food macros").
    var experimentalPredictionMacrosEnabled: Bool {
        get { bool(forKey: "experimentalPredictionMacrosEnabled") }
        set { set(newValue, forKey: "experimentalPredictionMacrosEnabled") }
    }

    /// Keep each forecast to score it against the readings that followed.
    var experimentalPredictionAccuracyEnabled: Bool {
        get { bool(forKey: "experimentalPredictionAccuracyEnabled") }
        set { set(newValue, forKey: "experimentalPredictionAccuracyEnabled") }
    }

    /// Uploads the forecast to Nightscout as an OpenAPS-style devicestatus.
    var experimentalNightscoutPredictionEnabled: Bool {
        get { bool(forKey: "experimentalNightscoutPredictionEnabled") }
        set { set(newValue, forKey: "experimentalNightscoutPredictionEnabled") }
    }

    /// How far ahead the predicted low alert looks, in minutes.
    var experimentalPredictedLowLeadMinutes: Int {
        get {
            let stored = integer(forKey: "experimentalPredictedLowLeadMinutes")
            return PredictedLowAlert.leadChoices.contains(stored) ? stored : PredictedLowAlert.defaultLeadMinutes
        }
        set { set(newValue, forKey: "experimentalPredictedLowLeadMinutes") }
    }

    /// Draws each insulin's activity along the bottom of the main chart.
    var experimentalInsulinsEnabled: Bool {
        get { bool(forKey: ExperimentalKey.insulinsEnabled) }
        set { set(newValue, forKey: ExperimentalKey.insulinsEnabled) }
    }

    /// Insulin used for a bolus whose notes do not name one. Until chosen, it follows the insulin
    /// type of the Treatments settings (NovoRapid, Fiasp or Lyumjev).
    var experimentalBolusInsulin: InsulinProfile {
        get {
            if let stored = string(forKey: ExperimentalKey.bolusInsulin).flatMap(InsulinProfile.init(rawValue:)) { return stored }
            switch TherapyInsulinPreset.nearest(to: object(forKey: "localInsulinPeak") as? Double ?? 75) {
            case .novoRapid: return .aspart
            case .fiasp: return .fiasp
            case .lyumjev: return .urli
            }
        }
        set { set(newValue.rawValue, forKey: ExperimentalKey.bolusInsulin) }
    }

    /// Insulin used for a basal injection whose description does not name one.
    var experimentalBasalInsulin: InsulinProfile {
        get { string(forKey: ExperimentalKey.basalInsulin).flatMap(InsulinProfile.init(rawValue:)) ?? .glargineU100 }
        set { set(newValue.rawValue, forKey: ExperimentalKey.basalInsulin) }
    }

    private static func experimentalValue(_ stored: Any?, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = (stored as? NSNumber)?.doubleValue, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Insulin catalogue

/// One point of an insulin action curve: glucose-lowering activity, peak normalised to 1.
struct InsulinCurvePoint: Hashable, Sendable {
    let minute: Int
    let activity: Double
}

/// What a JugglucoNG curve is based on (`JournalCurveEvidence`).
enum InsulinCurveEvidence: Sendable {
    case sourceSingleDose
    case sourceSteadyState
    case sourceReference
    case unverified
}

/// Built-in insulins, as JugglucoNG's `JournalBuiltInCurveProfile` and its default presets.
enum InsulinProfile: String, CaseIterable, Sendable {
    case rapidGeneric = "rapid_generic"
    case longBasalGeneric = "long_basal_generic"
    case humanRegular = "human_regular"
    case aspart
    case lispro
    case glulisine
    case fiasp
    case urli
    case afrezza
    case nph
    case ultraLongBasal = "ultra_long_basal"
    case glargineU100 = "glargine_u100"
    case glargineU300 = "glargine_u300"
    case detemir
    case degludec
    case icodec
    case humanRegularU500 = "human_regular_u500"
    case ryzodeg7030 = "ryzodeg_70_30"
    case aspartMix7030 = "aspart_mix_70_30"
    case lisproMix5050 = "lispro_mix_50_50"
    case lisproMix7525 = "lispro_mix_75_25"
    case humanMix7030 = "human_mix_70_30"

    /// Rapid and mealtime insulins first, then basal and premixed, as JugglucoNG lists its presets.
    static let bolusChoices: [InsulinProfile] = [.aspart, .lispro, .glulisine, .fiasp, .urli, .humanRegular, .afrezza, .rapidGeneric]
    static let basalChoices: [InsulinProfile] = [.glargineU100, .glargineU300, .detemir, .degludec, .icodec, .nph,
                                                 .longBasalGeneric, .ultraLongBasal, .humanRegularU500, .ryzodeg7030,
                                                 .aspartMix7030, .lisproMix5050, .lisproMix7525, .humanMix7030]

    /// Insulins a single dose can name in its notes. The generic curves have no brand to write down.
    static let perDoseBolusChoices: [InsulinProfile] = bolusChoices.filter { $0 != .rapidGeneric }
    static let perDoseBasalChoices: [InsulinProfile] = basalChoices.filter { $0 != .longBasalGeneric && $0 != .ultraLongBasal }

    /// JugglucoNG preset names (`journal_preset_*`).
    var displayName: String {
        switch self {
        case .rapidGeneric: return ExperimentalTexts.text("insulin.rapidGeneric", "Rapid acting (generic)")
        case .longBasalGeneric: return ExperimentalTexts.text("insulin.longGeneric", "Long acting (generic)")
        case .ultraLongBasal: return ExperimentalTexts.text("insulin.ultraLongGeneric", "Ultra-long basal (generic)")
        case .humanRegular: return "Humulin R / Novolin R"
        case .aspart: return "NovoRapid / NovoLog"
        case .lispro: return "Humalog"
        case .glulisine: return "Apidra"
        case .fiasp: return "Fiasp"
        case .urli: return "Lyumjev"
        case .afrezza: return "Afrezza"
        case .nph: return "Humulin N / Novolin N"
        case .glargineU100: return "Lantus / Basaglar / Semglee"
        case .glargineU300: return "Toujeo"
        case .detemir: return "Levemir"
        case .degludec: return "Tresiba"
        case .icodec: return "Awiqli"
        case .humanRegularU500: return "Humulin R U-500"
        case .ryzodeg7030: return "Ryzodeg"
        case .aspartMix7030: return "NovoLog Mix 70/30 / NovoMix 30"
        case .lisproMix5050: return "Humalog Mix 50/50"
        case .lisproMix7525: return "Humalog Mix 75/25"
        case .humanMix7030: return "Humulin 70/30 / Novolin 70/30"
        }
    }

    /// Short name for chart legends.
    var shortName: String {
        displayName.components(separatedBy: " / ").first ?? displayName
    }

    /// JugglucoNG default preset colours (ARGB without alpha).
    var colorHex: UInt32 {
        switch self {
        case .rapidGeneric: return 0x1565C0
        case .longBasalGeneric: return 0x6B7C3B
        case .humanRegular: return 0x6A1B9A
        case .aspart: return 0x1976D2
        case .lispro: return 0x00897B
        case .glulisine: return 0x00838F
        case .fiasp: return 0x2E7D32
        case .urli: return 0x00695C
        case .afrezza: return 0xEF6C00
        case .nph: return 0xE67E22
        case .ultraLongBasal: return 0x3949AB
        case .glargineU100: return 0x5E6C3B
        case .glargineU300: return 0x4E6041
        case .detemir: return 0x7B6A3C
        case .degludec: return 0x3949AB
        case .icodec: return 0x512DA8
        case .humanRegularU500: return 0x8E244D
        case .ryzodeg7030: return 0x6D4C41
        case .aspartMix7030: return 0x795548
        case .lisproMix5050: return 0x8D6E63
        case .lisproMix7525: return 0xA1887F
        case .humanMix7030: return 0x5D4037
        }
    }

    /// JugglucoNG presets: rapid, regular and NPH insulins count toward the forecast; basal and
    /// premixed ones do not, because basal insulin only covers the body's own needs.
    var countsTowardPrediction: Bool {
        switch self {
        case .rapidGeneric, .humanRegular, .aspart, .lispro, .glulisine, .fiasp, .urli, .afrezza, .nph:
            return true
        default:
            return false
        }
    }

    var evidence: InsulinCurveEvidence { InsulinCurveCatalogue.definition(self).evidence }

    /// Names and brands that identify an insulin in a treatment's notes. Specific names come
    /// before the generic ones they contain ("Humalog Mix 25" before "Humalog").
    static let notesAliases: [(alias: String, profile: InsulinProfile)] = [
        ("humalog mix 50", .lisproMix5050), ("humalog mix50", .lisproMix5050), ("mix 50", .lisproMix5050),
        ("humalog mix 25", .lisproMix7525), ("humalog mix25", .lisproMix7525), ("humalog mix 75", .lisproMix7525),
        ("novomix", .aspartMix7030), ("novolog mix", .aspartMix7030),
        ("humulin 70/30", .humanMix7030), ("novolin 70/30", .humanMix7030), ("mixtard", .humanMix7030), ("humulin m3", .humanMix7030),
        ("ryzodeg", .ryzodeg7030),
        ("u-500", .humanRegularU500), ("u500", .humanRegularU500),
        ("toujeo", .glargineU300), ("туджео", .glargineU300), ("тужео", .glargineU300),
        ("lantus", .glargineU100), ("basaglar", .glargineU100), ("abasaglar", .glargineU100), ("semglee", .glargineU100),
        ("glargine", .glargineU100), ("лантус", .glargineU100), ("гларгін", .glargineU100), ("гларгин", .glargineU100),
        ("levemir", .detemir), ("detemir", .detemir), ("левемір", .detemir), ("левемир", .detemir),
        ("tresiba", .degludec), ("degludec", .degludec), ("тресіба", .degludec), ("тресиба", .degludec),
        ("awiqli", .icodec), ("icodec", .icodec),
        ("fiasp", .fiasp), ("фіасп", .fiasp), ("фиасп", .fiasp),
        ("lyumjev", .urli), ("liumjev", .urli), ("люмджев", .urli), ("люмжев", .urli),
        ("novorapid", .aspart), ("novo rapid", .aspart), ("novolog", .aspart), ("aspart", .aspart),
        ("новорапід", .aspart), ("новорапид", .aspart),
        ("humalog", .lispro), ("lispro", .lispro), ("admelog", .lispro), ("хумалог", .lispro),
        ("apidra", .glulisine), ("glulisine", .glulisine), ("апідра", .glulisine), ("апидра", .glulisine),
        ("afrezza", .afrezza),
        ("protaphane", .nph), ("insulatard", .nph), ("humulin n", .nph), ("novolin n", .nph), ("nph", .nph), ("протафан", .nph),
        ("actrapid", .humanRegular), ("humulin r", .humanRegular), ("novolin r", .humanRegular), ("актрапід", .humanRegular), ("актрапид", .humanRegular)
    ]

    /// The insulin a treatment's notes name, if any.
    static func matching(notes: String?) -> InsulinProfile? {
        guard let notes = notes?.lowercased(), !notes.isEmpty else { return nil }
        return notesAliases.first { notes.contains($0.alias) }?.profile
    }
}

/// JugglucoNG `JournalInsulinCurveCatalogue` (model version 3): source-backed glucose-lowering
/// activity curves, each normalised so its peak is 1. xDrip has no body weight, so curves given
/// per kilogram use the source's reference dose, as JugglucoNG does without a weight.
enum InsulinCurveCatalogue {
    enum DoseAxis: Sendable { case fixed, units, unitsPerKg }

    struct Variant: Sendable {
        let dose: Double
        let points: [InsulinCurvePoint]
    }

    struct Definition: Sendable {
        let evidence: InsulinCurveEvidence
        let doseAxis: DoseAxis
        let variants: [Variant]
        let referenceDose: Double
    }

    private static let cache: [InsulinProfile: Definition] = Dictionary(uniqueKeysWithValues: InsulinProfile.allCases.map { ($0, makeDefinition($0)) })

    static func definition(_ profile: InsulinProfile) -> Definition { cache[profile] ?? makeDefinition(profile) }

    static func referenceCurve(_ profile: InsulinProfile) -> [InsulinCurvePoint] {
        let definition = definition(profile)
        return definition.variants.min { abs($0.dose - definition.referenceDose) < abs($1.dose - definition.referenceDose) }?.points ?? []
    }

    /// The curve for one dose: interpolated between the source's doses when the curve is given in
    /// units (Lyumjev, Afrezza), the reference curve otherwise.
    static func curve(for profile: InsulinProfile, units: Double, bodyWeightKg: Double? = nil) -> [InsulinCurvePoint] {
        let definition = definition(profile)
        switch definition.doseAxis {
        case .fixed: return interpolateVariants(definition.variants, requestedDose: definition.referenceDose)
        case .units: return interpolateVariants(definition.variants, requestedDose: units)
        case .unitsPerKg:
            // As JugglucoNG `resolve`: units per kilogram with a valid weight, else the reference curve.
            guard let weight = bodyWeightKg, weight.isFinite, ExperimentalPredictionModel.bodyWeightRange.contains(weight) else {
                return referenceCurve(profile)
            }
            return interpolateVariants(definition.variants, requestedDose: units / weight)
        }
    }

    private static func makeDefinition(_ profile: InsulinProfile) -> Definition {
        func fixed(_ evidence: InsulinCurveEvidence, _ dose: Double, _ points: [InsulinCurvePoint]) -> Definition {
            Definition(evidence: evidence, doseAxis: .fixed, variants: [Variant(dose: dose, points: points)], referenceDose: dose)
        }
        func single(_ axis: DoseAxis, _ dose: Double, _ points: [InsulinCurvePoint]) -> Definition {
            Definition(evidence: .sourceSingleDose, doseAxis: axis, variants: [Variant(dose: dose, points: points)], referenceDose: dose)
        }
        switch profile {
        case .fiasp:
            return Definition(evidence: .sourceSingleDose, doseAxis: .unitsPerKg, variants: fiaspVariants(), referenceDose: 0.1)
        case .urli:
            return Definition(evidence: .sourceSingleDose, doseAxis: .units, variants: lyumjevVariants(), referenceDose: 7)
        case .afrezza:
            return Definition(evidence: .sourceSingleDose, doseAxis: .units, variants: afrezzaVariants(), referenceDose: 12)
        case .humanRegular: return single(.unitsPerKg, 0.3, regularU100Curve())
        case .humanRegularU500: return single(.units, 100, regularU500Curve())
        case .aspartMix7030: return single(.unitsPerKg, 0.3, aspartMix7030Curve())
        case .glargineU100: return fixed(.sourceReference, 0.3, glargineU100Curve())
        case .glargineU300: return fixed(.sourceSteadyState, 0.4, glargineU300Curve())
        case .detemir:
            return Definition(evidence: .sourceReference, doseAxis: .unitsPerKg, variants: detemirVariants(), referenceDose: 0.4)
        case .degludec: return fixed(.sourceSteadyState, 0.4, degludecSteadyStateCurve())
        case .icodec: return fixed(.sourceSteadyState, 1, icodecSteadyStateCurve())
        case .ryzodeg7030: return fixed(.sourceReference, 0.8, ryzodegCurve())
        case .nph: return fixed(.sourceReference, 0.4, nphCurve())
        case .lisproMix5050: return fixed(.sourceReference, 0.3, lisproMix5050Reference())
        case .lisproMix7525: return fixed(.sourceReference, 0.3, lisproMix7525Reference())
        case .humanMix7030: return fixed(.sourceReference, 0.3, humanMix7030Reference())
        case .rapidGeneric, .aspart:
            return fixed(.unverified, 1, polynomialCurve(span: 360, peak: 40, [0.0, 34.05, -185.9, 439.8, -536.6, 327.1, -78.44]))
        case .lispro:
            return fixed(.unverified, 1, polynomialCurve(span: 330, peak: 60, [0.0, 31.6, -144.7, 259.5, -211.3, 64.93, 0.0]))
        case .glulisine:
            return fixed(.unverified, 1, polynomialCurve(span: 480, peak: 65, [0.0, 51.75, -325.2, 831.0, -1053.0, 655.7, -159.9]))
        case .longBasalGeneric:
            return fixed(.unverified, 1, timingCurve(duration: 1440, onset: 90, peak: 600, shoulder: 0.7, lateTail: 0.42))
        case .ultraLongBasal:
            return fixed(.unverified, 1, timingCurve(duration: 2160, onset: 180, peak: 960, shoulder: 0.66, lateTail: 0.3))
        }
    }

    // MARK: Curve helpers (JournalModels.kt)

    /// `normalizeJournalCurvePoints`: sorted, one point per minute, starting at minute 0, and with
    /// `forceZeroEndpoints` starting and ending at zero activity.
    static func normalize(_ points: [InsulinCurvePoint], fallbackDuration: Int? = nil, forceZeroEndpoints: Bool = true) -> [InsulinCurvePoint] {
        let fallback = fallbackDuration ?? points.map(\.minute).max() ?? 0
        var seen = Set<Int>()
        var cleaned = points
            .map { InsulinCurvePoint(minute: max(0, $0.minute), activity: min(max($0.activity, 0), 1)) }
            .enumerated().sorted { $0.element.minute == $1.element.minute ? $0.offset < $1.offset : $0.element.minute < $1.element.minute }
            .map { $0.element }
            .filter { seen.insert($0.minute).inserted }
        guard let first = cleaned.first else {
            let duration = max(fallback, 240)
            return [InsulinCurvePoint(minute: 0, activity: 0),
                    InsulinCurvePoint(minute: Int((Double(duration) * 0.2).rounded()), activity: 0.2),
                    InsulinCurvePoint(minute: Int((Double(duration) * 0.35).rounded()), activity: 1),
                    InsulinCurvePoint(minute: Int((Double(duration) * 0.7).rounded()), activity: 0.35),
                    InsulinCurvePoint(minute: duration, activity: 0)]
        }
        if first.minute != 0 {
            cleaned.insert(InsulinCurvePoint(minute: 0, activity: 0), at: 0)
        } else if forceZeroEndpoints {
            cleaned[0] = InsulinCurvePoint(minute: 0, activity: 0)
        }
        let last = cleaned[cleaned.count - 1]
        let lastMinute = max(last.minute, fallback)
        if forceZeroEndpoints && last.activity > 0 {
            cleaned.append(InsulinCurvePoint(minute: max(lastMinute, last.minute), activity: 0))
        } else if last.minute < lastMinute {
            cleaned.append(InsulinCurvePoint(minute: lastMinute, activity: 0))
        }
        return cleaned
    }

    /// JugglucoNG `curve(...)`: normalised, then scaled so the peak is exactly 1.
    private static func curve(_ points: [(Int, Double)], forceZeroEndpoints: Bool = true) -> [InsulinCurvePoint] {
        let normalized = normalize(points.map { InsulinCurvePoint(minute: $0.0, activity: $0.1) }, forceZeroEndpoints: forceZeroEndpoints)
        let peak = max(normalized.map(\.activity).max() ?? 1, 0.0001)
        return normalized.map { InsulinCurvePoint(minute: $0.minute, activity: min(max($0.activity / peak, 0), 1)) }
    }

    /// Linear interpolation of the activity at a minute, holding the end values outside the curve.
    static func interpolate(_ points: [InsulinCurvePoint], minute: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if minute <= Double(first.minute) { return first.activity }
        if minute >= Double(last.minute) { return last.activity }
        guard let upperIndex = points.firstIndex(where: { Double($0.minute) >= minute }) else { return 0 }
        let upper = points[upperIndex]
        guard upperIndex > 0 else { return upper.activity }
        let lower = points[upperIndex - 1]
        let span = max(Double(upper.minute - lower.minute), 1)
        let progress = min(max((minute - Double(lower.minute)) / span, 0), 1)
        return lower.activity + (upper.activity - lower.activity) * progress
    }

    private static func interpolateVariants(_ variants: [Variant], requestedDose: Double) -> [InsulinCurvePoint] {
        let sorted = variants.sorted { $0.dose < $1.dose }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        if requestedDose <= first.dose { return first.points }
        if requestedDose >= last.dose { return last.points }
        let upperIndex = max(sorted.firstIndex { $0.dose >= requestedDose } ?? 1, 1)
        let lower = sorted[upperIndex - 1], upper = sorted[upperIndex]
        let fraction = min(max((requestedDose - lower.dose) / (upper.dose - lower.dose), 0), 1)
        let minutes = Array(Set(lower.points.map(\.minute) + upper.points.map(\.minute))).sorted()
        let interpolated = minutes.map { minute -> InsulinCurvePoint in
            let low = interpolate(lower.points, minute: Double(minute))
            let high = interpolate(upper.points, minute: Double(minute))
            return InsulinCurvePoint(minute: minute, activity: low + (high - low) * fraction)
        }
        let peak = max(interpolated.map(\.activity).max() ?? 1, 0.0001)
        return normalize(interpolated.map { InsulinCurvePoint(minute: $0.minute, activity: min(max($0.activity / peak, 0), 1)) })
    }

    private static func polynomialCurve(span: Int, peak: Int, _ coefficients: [Double]) -> [InsulinCurvePoint] {
        func evaluate(_ t: Double) -> Double {
            let x = min(max(t, 0), 1)
            var total = 0.0
            for (power, coefficient) in coefficients.enumerated() { total += coefficient * pow(x, Double(power)) }
            return max(total, 0)
        }
        let tail = max(span - peak, 1)
        let anchors = Array(Set([0,
                                 Int((Double(peak) * 0.35).rounded()),
                                 Int((Double(peak) * 0.7).rounded()),
                                 peak,
                                 Int((Double(peak) + Double(tail) * 0.18).rounded()),
                                 Int((Double(peak) + Double(tail) * 0.42).rounded()),
                                 Int((Double(peak) + Double(tail) * 0.7).rounded()),
                                 span].map { min(max($0, 0), span) })).sorted()
        let sampledMax = max(stride(from: 0, through: span, by: 5).map { evaluate(Double($0) / Double(span)) }.max() ?? 1, 0.001)
        return normalize(anchors.map { minute in
            let activity = minute == 0 || minute == span ? 0 : min(max(evaluate(Double(minute) / Double(span)) / sampledMax, 0), 1)
            return InsulinCurvePoint(minute: minute, activity: activity)
        }, fallbackDuration: span)
    }

    private static func timingCurve(duration: Int, onset: Int, peak: Int, shoulder: Double, lateTail: Double) -> [InsulinCurvePoint] {
        let safeDuration = max(duration, max(peak + 30, 120))
        let rise = min(max(Int((Double(onset) + Double(peak - onset) * 0.45).rounded()), onset), peak)
        let shoulderMinute = min(max(Int((Double(peak) + Double(safeDuration - peak) * 0.28).rounded()), peak), safeDuration)
        let tailMinute = min(max(Int((Double(peak) + Double(safeDuration - peak) * 0.68).rounded()), shoulderMinute), safeDuration)
        return normalize([
            InsulinCurvePoint(minute: 0, activity: 0),
            InsulinCurvePoint(minute: max(onset, 0), activity: 0.16),
            InsulinCurvePoint(minute: rise, activity: 0.62),
            InsulinCurvePoint(minute: max(peak, onset + 1), activity: 1),
            InsulinCurvePoint(minute: shoulderMinute, activity: min(max(shoulder, 0.2), 0.95)),
            InsulinCurvePoint(minute: tailMinute, activity: min(max(lateTail, 0.05), 0.6)),
            InsulinCurvePoint(minute: safeDuration, activity: 0)
        ], fallbackDuration: safeDuration)
    }

    // MARK: Source curves (JournalInsulinCurveCatalogue.kt)

    private static func fiaspVariants() -> [Variant] {
        [Variant(dose: 0.1, points: curve([(0, 0), (5, 0.02), (10, 0.12), (15, 0.36), (20, 0.46), (30, 0.55), (40, 0.77), (45, 0.84), (60, 0.83), (90, 0.99),
                                           (91, 1), (120, 0.93), (150, 0.78), (180, 0.55), (210, 0.28), (240, 0.18), (270, 0.09), (300, 0.02), (360, 0)])),
         Variant(dose: 0.2, points: curve([(0, 0), (5, 0.02), (10, 0.08), (15, 0.25), (20, 0.45), (30, 0.59), (45, 0.65), (60, 0.83), (90, 0.94),
                                           (122, 1), (150, 0.93), (180, 0.74), (210, 0.54), (240, 0.36), (270, 0.22), (300, 0.14), (330, 0.08), (360, 0.04), (420, 0)])),
         Variant(dose: 0.4, points: curve([(0, 0), (5, 0.01), (10, 0.06), (15, 0.20), (20, 0.43), (30, 0.58), (45, 0.74), (60, 0.85), (90, 0.94),
                                           (133, 1), (180, 0.91), (210, 0.82), (240, 0.64), (270, 0.51), (300, 0.35), (330, 0.25), (360, 0.16), (390, 0.08), (420, 0)]))]
    }

    private static func lyumjevVariants() -> [Variant] {
        [Variant(dose: 7, points: curve([(0, 0), (17, 0), (30, 0.32), (60, 0.70), (90, 0.91), (120, 1), (150, 0.89), (180, 0.66), (210, 0.42), (240, 0.20), (276, 0)])),
         Variant(dose: 15, points: curve([(0, 0), (17, 0), (30, 0.30), (60, 0.64), (90, 0.84), (120, 0.97), (138, 1), (180, 0.88), (240, 0.59), (300, 0.31), (360, 0.08), (372, 0)])),
         Variant(dose: 30, points: curve([(0, 0), (15, 0), (30, 0.28), (60, 0.57), (90, 0.75), (120, 0.88), (150, 0.96), (174, 1), (240, 0.85), (300, 0.61), (360, 0.36), (420, 0.08), (438, 0)]))]
    }

    private static func afrezzaVariants() -> [Variant] {
        [Variant(dose: 4, points: curve([(0, 0), (12, 0), (20, 0.55), (35, 1), (55, 0.55), (75, 0.18), (90, 0)])),
         Variant(dose: 12, points: curve([(0, 0), (12, 0), (25, 0.55), (45, 1), (75, 0.62), (120, 0.27), (165, 0.06), (180, 0)])),
         Variant(dose: 48, points: curve([(0, 0), (12, 0), (30, 0.53), (55, 1), (90, 0.78), (150, 0.48), (210, 0.20), (255, 0.05), (270, 0)]))]
    }

    private static func regularU100Curve() -> [InsulinCurvePoint] {
        curve([(0, 0), (15, 0.02), (30, 0.14), (60, 0.49), (120, 0.86), (180, 1), (240, 0.94), (300, 0.76), (360, 0.50),
               (420, 0.31), (480, 0.18), (540, 0.09), (600, 0.04), (720, 0.02), (840, 0)])
    }

    private static func regularU500Curve() -> [InsulinCurvePoint] {
        curve([(0, 0), (30, 0.18), (60, 0.38), (120, 0.56), (240, 0.83), (360, 1), (480, 0.88), (600, 0.78), (720, 0.66),
               (840, 0.48), (960, 0.34), (1080, 0.24), (1200, 0.12), (1320, 0.04), (1440, 0)])
    }

    private static func nphCurve() -> [InsulinCurvePoint] {
        curve([(0, 0), (60, 0.05), (120, 0.28), (180, 0.64), (240, 0.75), (300, 0.95), (360, 0.98), (390, 1), (420, 0.92),
               (480, 0.96), (600, 0.94), (720, 0.82), (840, 0.68), (960, 0.55), (1080, 0.43), (1200, 0.35), (1320, 0.29)], forceZeroEndpoints: false)
    }

    private static func glargineU100Curve() -> [InsulinCurvePoint] {
        curve([(0, 0), (120, 0.27), (240, 0.55), (360, 0.82), (480, 1), (600, 0.78), (720, 0.74), (960, 0.79), (1200, 0.80), (1440, 0.72)], forceZeroEndpoints: false)
    }

    private static func glargineU300Curve() -> [InsulinCurvePoint] {
        curve([(0, 0.92), (240, 1), (480, 0.91), (720, 0.94), (960, 0.86), (1200, 0.72), (1440, 0.64), (1680, 0.49), (1920, 0.20), (2160, 0.10)], forceZeroEndpoints: false)
    }

    private static func detemirVariants() -> [Variant] {
        [Variant(dose: 0.2, points: curve([(0, 0), (60, 0.45), (180, 0.75), (360, 0.93), (540, 1), (720, 0.83), (900, 0.55), (1080, 0.25), (1260, 0.05), (1440, 0)])),
         Variant(dose: 0.4, points: curve([(0, 0), (60, 0.42), (180, 0.58), (360, 0.77), (540, 1), (720, 0.91), (900, 0.70), (1080, 0.44), (1260, 0.18), (1440, 0)]))]
    }

    private static func degludecSteadyStateCurve() -> [InsulinCurvePoint] {
        curve([(0, 0.70), (360, 0.96), (720, 1), (1080, 0.83), (1440, 0.67), (1800, 0.38), (2160, 0.14), (2520, 0.05)], forceZeroEndpoints: false)
    }

    private static func icodecSteadyStateCurve() -> [InsulinCurvePoint] {
        curve([(0, 0.80), (1440, 0.88), (2880, 0.96), (4320, 0.90), (5760, 1), (7200, 0.86), (8640, 0.90), (10080, 0.82)], forceZeroEndpoints: false)
    }

    private static func aspartMix7030Curve() -> [InsulinCurvePoint] {
        curve([(0, 0), (10, 0.10), (20, 0.42), (60, 0.86), (120, 0.98), (162, 1), (180, 0.96), (240, 0.82), (360, 0.58), (480, 0.43),
               (600, 0.27), (720, 0.21), (900, 0.13), (1080, 0.08), (1260, 0.10), (1380, 0.06), (1440, 0)])
    }

    private static func ryzodegCurve() -> [InsulinCurvePoint] {
        curve([(0, 0), (20, 0.12), (60, 0.62), (120, 0.94), (180, 1), (240, 0.87), (300, 0.62), (360, 0.42), (480, 0.25), (720, 0.18),
               (1080, 0.16), (1440, 0.14)], forceZeroEndpoints: false)
    }

    private static func lisproMix5050Reference() -> [InsulinCurvePoint] {
        curve([(0, 0), (60, 0.50), (120, 1), (180, 0.94), (240, 0.76), (300, 0.50), (360, 0.42), (480, 0.34), (600, 0.28), (720, 0.22),
               (900, 0.15), (1080, 0.10), (1320, 0.09)], forceZeroEndpoints: false)
    }

    private static func lisproMix7525Reference() -> [InsulinCurvePoint] {
        curve([(0, 0), (60, 0.45), (120, 1), (180, 0.94), (240, 0.70), (300, 0.52), (360, 0.48), (480, 0.43), (600, 0.38), (720, 0.31),
               (900, 0.23), (1080, 0.17), (1320, 0.13)], forceZeroEndpoints: false)
    }

    private static func humanMix7030Reference() -> [InsulinCurvePoint] {
        curve([(0, 0), (50, 0), (60, 0.18), (120, 0.72), (150, 0.90), (180, 0.98), (210, 1), (240, 0.96), (360, 0.65), (480, 0.47),
               (600, 0.28), (720, 0.23)], forceZeroEndpoints: false)
    }
}

// MARK: - Curve arithmetic (GlucoseTreatmentCurves / JournalIobMath)

enum InsulinCurveMath {
    /// Area under a piecewise-linear curve from its first point up to `minute`, in activity-minutes.
    static func integrate(_ points: [InsulinCurvePoint], upTo minute: Double) -> Double {
        guard points.count >= 2, minute > Double(points[0].minute) else { return 0 }
        var area = 0.0
        for index in 0..<(points.count - 1) {
            let start = points[index], end = points[index + 1]
            if minute <= Double(start.minute) { break }
            let segmentEnd = min(minute, Double(end.minute))
            let width = segmentEnd - Double(start.minute)
            if width <= 0 { continue }
            let fullWidth = Double(max(end.minute - start.minute, 1))
            let endFraction = min(max((segmentEnd - Double(start.minute)) / fullWidth, 0), 1)
            let endActivity = start.activity + (end.activity - start.activity) * endFraction
            area += (start.activity + endActivity) * 0.5 * width
            if minute <= Double(end.minute) { break }
        }
        return area
    }

    /// Fraction of a dose's total action delivered `elapsedMinutes` after it was given.
    static func cumulativeFraction(_ points: [InsulinCurvePoint], elapsedMinutes: Double) -> Double {
        guard points.count >= 2, elapsedMinutes > 0, let last = points.last else { return 0 }
        let total = integrate(points, upTo: Double(last.minute))
        guard total > 0.0001 else { return 0 }
        return min(max(integrate(points, upTo: elapsedMinutes) / total, 0), 1)
    }

    static func linearProgress(elapsedMinutes: Double, durationMinutes: Double) -> Double {
        guard elapsedMinutes > 0 else { return 0 }
        return min(max(elapsedMinutes / max(durationMinutes, 1), 0), 1)
    }

    /// Smoothstep over the absorption window: slow start, slow finish.
    static func mealProgress(elapsedMinutes: Double, durationMinutes: Double) -> Double {
        let x = linearProgress(elapsedMinutes: elapsedMinutes, durationMinutes: durationMinutes)
        return x * x * (3 - 2 * x)
    }
}

// MARK: - Treatments

/// A treatment detached from Core Data, as far as prediction and the insulin chart need it.
struct ExperimentalTreatment: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case bolus, basalInjection, carbs, exercise }

    let date: Date
    let amount: Double
    let kind: Kind
    let notes: String?

    /// Protein and fat grams of a carb entry, written by the treatment editor as "P:20 F:15".
    var macros: (protein: Double, fat: Double)? {
        guard kind == .carbs, let notes else { return nil }
        let protein = Self.number(after: "P:", in: notes) ?? 0
        let fat = Self.number(after: "F:", in: notes) ?? 0
        return protein > 0 || fat > 0 ? (protein, fat) : nil
    }

    /// Exercise intensity, written by the treatment editor as "intensity:light|moderate|intense".
    var intensity: ExperimentalExerciseIntensity? {
        guard kind == .exercise, let notes = notes?.lowercased() else { return nil }
        return ExperimentalExerciseIntensity.allCases.first { notes.contains("intensity:" + $0.rawValue) }
    }

    static func number(after token: String, in notes: String) -> Double? {
        guard let range = notes.range(of: token, options: .caseInsensitive) else { return nil }
        let digits = notes[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "," }
        return Double(digits.replacingOccurrences(of: ",", with: "."))
    }

    /// The notes token the editor writes for protein and fat, nil when both are empty.
    static func macrosNotes(protein: Double?, fat: Double?) -> String? {
        let parts = [protein.flatMap { $0 > 0 ? "P:\(ExperimentalPredictionModel.compact($0))" : nil },
                     fat.flatMap { $0 > 0 ? "F:\(ExperimentalPredictionModel.compact($0))" : nil }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The insulin of a bolus or basal injection: named in the notes, else the configured default.
    func insulin(bolusDefault: InsulinProfile, basalDefault: InsulinProfile) -> InsulinProfile? {
        switch kind {
        case .bolus: return InsulinProfile.matching(notes: notes) ?? bolusDefault
        case .basalInjection: return InsulinProfile.matching(notes: notes) ?? basalDefault
        case .carbs, .exercise: return nil
        }
    }
}

extension ExperimentalTreatment {
    /// Fetches the treatments in a window on `context`'s queue (the caller must be on it).
    static func fetch(from start: Date, to end: Date, in context: NSManagedObjectContext, policy: DataFlowPolicy) -> [ExperimentalTreatment]? {
        let request = TreatmentEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@ AND (treatmentdeleted == NO OR treatmentdeleted == nil) AND treatmentType IN %@",
            start as NSDate, end as NSDate,
            [TreatmentType.Insulin.rawValue, TreatmentType.BasalInjection.rawValue, TreatmentType.Carbs.rawValue, TreatmentType.Exercise.rawValue])
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return (try? context.fetch(request))?.filter { TherapyMetricsManager.includesTherapyTreatment($0, policy: policy) }.compactMap { entry -> ExperimentalTreatment? in
            let kind: ExperimentalTreatment.Kind
            switch entry.treatmentType {
            case .Insulin: kind = .bolus
            case .BasalInjection: kind = .basalInjection
            case .Carbs: kind = .carbs
            case .Exercise: kind = .exercise
            default: return nil
            }
            return ExperimentalTreatment(date: entry.date, amount: entry.value, kind: kind, notes: entry.notes)
        }
    }
}

extension TherapyMetricsManager {
    /// Boluses, basal injections, carbs and exercise in a window, from the sources the IOB/COB
    /// estimate also uses. Returns nil when Core Data is not available.
    func experimentalTreatments(from start: Date, to end: Date) async -> [ExperimentalTreatment]? {
        guard let coreDataManager = configuredCoreDataManager else { return nil }
        let policy = UserDefaults.standard.dataFlowPolicy
        let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator
        return await withCheckedContinuation { continuation in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.perform {
                continuation.resume(returning: ExperimentalTreatment.fetch(from: start, to: end, in: context, policy: policy))
            }
        }
    }
}

// MARK: - Predicted low alert

/// The experimental alert that warns before the forecast reaches the low value.
enum PredictedLowAlert {
    static let leadChoices = [15, 20, 25, 30, 45]
    static let defaultLeadMinutes = 20

    /// The first forecast point within `leadMinutes` below the threshold, while the current
    /// reading is still at or above it (a current low is the low alert's job).
    static func crossing(forecast: [GlucosePredictionPoint], currentMgDl: Double, thresholdMgDl: Double,
                         leadMinutes: Int) -> (minutes: Int, mgDl: Double)? {
        guard currentMgDl >= thresholdMgDl, let baseline = forecast.first?.date else { return nil }
        let limit = baseline.addingTimeInterval(TimeInterval(leadMinutes * 60))
        guard let point = forecast.dropFirst().first(where: { $0.date <= limit && $0.value < thresholdMgDl }) else { return nil }
        return (Int((point.date.timeIntervalSince(baseline) / 60).rounded()), point.value)
    }

    /// Treatments the forecast needs, fetched on the main context for the alert check.
    static func treatments(in context: NSManagedObjectContext, now: Date = Date()) -> [ExperimentalTreatment] {
        var result: [ExperimentalTreatment] = []
        context.performAndWait {
            result = ExperimentalTreatment.fetch(from: now.addingTimeInterval(-ExperimentalPredictionModel.lookBack),
                                                 to: now.addingTimeInterval(6 * 60 * 60), in: context,
                                                 policy: UserDefaults.standard.dataFlowPolicy) ?? []
        }
        return result
    }
}

/// JugglucoNG `JournalIntensity`; nil (not logged) uses the 0.5 factor.
enum ExperimentalExerciseIntensity: String, CaseIterable, Sendable {
    case light, moderate, intense

    var factor: Double {
        switch self {
        case .light: return 0.35
        case .moderate: return 0.65
        case .intense: return 1
        }
    }

    var title: String {
        switch self {
        case .light: return ExperimentalTexts.text("intensityLight", "Light")
        case .moderate: return ExperimentalTexts.text("intensityModerate", "Moderate")
        case .intense: return ExperimentalTexts.text("intensityIntense", "Intense")
        }
    }
}

/// One time-of-day period of the prediction model (JugglucoNG `PredictionModelBlock`).
struct ExperimentalPredictionPeriod: Hashable, Sendable {
    /// Minutes after midnight, 1...1439 (midnight itself uses the single settings).
    var startMinute: Int
    var carbRatio: Double
    var insulinSensitivityMgDl: Double
    var carbAbsorption: Double

    /// JugglucoNG `MAX_BLOCKS` is 8 including midnight.
    static let maximumCount = 7

    func normalized() -> ExperimentalPredictionPeriod {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return ExperimentalPredictionPeriod(
            startMinute: min(max(startMinute, 1), 1439),
            carbRatio: clamp(carbRatio, ExperimentalPredictionModel.carbRatioRange, ExperimentalPredictionModel.defaultCarbRatio),
            insulinSensitivityMgDl: clamp(insulinSensitivityMgDl, ExperimentalPredictionModel.insulinSensitivityRange, ExperimentalPredictionModel.defaultInsulinSensitivityMgDl),
            carbAbsorption: clamp(carbAbsorption, ExperimentalPredictionModel.carbAbsorptionRange, ExperimentalPredictionModel.defaultCarbAbsorption))
    }

    static func encode(_ periods: [ExperimentalPredictionPeriod]) -> String {
        sanitized(periods).map { "\($0.startMinute),\($0.carbRatio),\($0.insulinSensitivityMgDl),\($0.carbAbsorption)" }.joined(separator: ";")
    }

    static func decode(_ encoded: String?) -> [ExperimentalPredictionPeriod] {
        guard let encoded, !encoded.isEmpty else { return [] }
        return sanitized(encoded.split(separator: ";").compactMap { block in
            let fields = block.split(separator: ",").map { Double($0) }
            guard fields.count == 4, let start = fields[0], let ratio = fields[1], let sensitivity = fields[2], let absorption = fields[3] else { return nil }
            return ExperimentalPredictionPeriod(startMinute: Int(start), carbRatio: ratio, insulinSensitivityMgDl: sensitivity, carbAbsorption: absorption)
        })
    }

    /// Sorted, one per start minute, at most `maximumCount`, each value within its range.
    static func sanitized(_ periods: [ExperimentalPredictionPeriod]) -> [ExperimentalPredictionPeriod] {
        // Keep the first period for a start minute, then sort (Swift's sort is not guaranteed stable).
        var seen = Set<Int>()
        return periods.map { $0.normalized() }
            .filter { seen.insert($0.startMinute).inserted }
            .sorted { $0.startMinute < $1.startMinute }
            .prefix(maximumCount).map { $0 }
    }
}

/// JugglucoNG `JournalFoodMath`: protein and fat as a delayed, carb-equivalent rise.
enum ExperimentalFoodMath {
    static func fatProteinUnits(protein: Double, fat: Double) -> Double {
        (max(protein, 0) * 4 + max(fat, 0) * 9) / 100
    }

    static func tailEquivalentCarbs(protein: Double, fat: Double) -> Double {
        let units = fatProteinUnits(protein: protein, fat: fat)
        guard units > 0 else { return 0 }
        let delayedFraction = units < 1 ? 0.30 : units < 2 ? 0.42 : units < 4 ? 0.55 : 0.65
        return min(max(units * 10 * delayedFraction, 0), 80)
    }

    static func tailDelayMinutes(protein: Double, fat: Double) -> Double {
        let units = fatProteinUnits(protein: protein, fat: fat)
        if fat >= 30 || units >= 4 { return 110 }
        if fat >= 15 || protein >= 25 || units >= 2 { return 80 }
        return 50
    }

    static func tailDurationMinutes(protein: Double, fat: Double) -> Double {
        min(max(110 + fatProteinUnits(protein: protein, fat: fat) * 55 + max(fat, 0) * 3.5, 90), 480)
    }
}

// MARK: - Glucose prediction (GlucosePredictionKernel.kt)

struct GlucosePredictionPoint: Sendable, Hashable {
    let date: Date
    /// Value in the simulation's unit, clamped to the chart range.
    let value: Double
    let confidence: Double
    /// The same value before the clamp.
    let unclampedValue: Double
}

/// The forward simulation, as JugglucoNG's `GlucosePredictionKernel.simulate`: the newest reading,
/// plus the recent trend the treatments do not explain (fading over about an hour), plus a slow
/// pull toward the middle of the target range, plus the modelled effect of logged treatments.
enum GlucosePredictionKernel {
    struct Sample: Sendable, Hashable {
        let date: Date
        let value: Double
    }

    /// Below this a value is a hole rather than a reading.
    static let minimumValidValue = 0.1
    /// How far back the momentum regression looks.
    static let slopeWindow: TimeInterval = 45 * 60
    static let slopeMaximumSamples = 10

    /// - Parameters:
    ///   - history: readings in ascending time order, in the display unit.
    ///   - treatmentDeltaAt: modelled glucose change, in the display unit, from the newest
    ///     reading to the given date (zero at the reading itself).
    static func simulate(history: [Sample], isMmol: Bool, trendMomentum: Bool, horizonMinutes: Int, stepMinutes: Int,
                         targetLow: Double, targetHigh: Double, treatmentDeltaAt: (Date) -> Double) -> [GlucosePredictionPoint] {
        guard history.count >= 2,
              let baseline = history.reversed().first(where: { $0.value.isFinite && $0.value > minimumValidValue }) else { return [] }
        let baselineDate = baseline.date
        let step = min(max(stepMinutes, 3), 15)
        let horizon = min(max(horizonMinutes, 30), 360)
        let center = (targetLow + targetHigh) * 0.5
        let targetCenter = center.isFinite && center > 0 ? center : baseline.value

        let slope: Double
        if trendMomentum {
            // Regress over treatment-residualised samples so momentum carries only the slope the
            // treatment model does not already explain; that part is re-added below.
            let maxSlope = isMmol ? 0.16 : 3
            slope = min(max(residualSlopePerMinute(history, baselineDate: baselineDate, treatmentDeltaAt: treatmentDeltaAt), -maxSlope), maxSlope)
        } else {
            slope = 0
        }

        func projectedDelta(at date: Date) -> Double {
            let minutes = max(date.timeIntervalSince(baselineDate) / 60, 0)
            let trend = slope * minutes * exp(-minutes / 70)
            let settling = (targetCenter - baseline.value) * (1 - exp(-minutes / 240)) * 0.18
            return trend + settling + treatmentDeltaAt(date)
        }

        let lowClamp = isMmol ? 1.0 : 18
        let highClamp = isMmol ? 30.0 : 540
        var points = [GlucosePredictionPoint(date: baselineDate, value: baseline.value, confidence: 1, unclampedValue: baseline.value)]
        var minute = step
        while minute <= horizon {
            let date = baselineDate.addingTimeInterval(TimeInterval(minute * 60))
            let progress = Double(minute) / Double(horizon)
            let confidence = min(max(0.88 - 0.62 * sqrt(progress), 0.18), 0.88)
            let projected = baseline.value + projectedDelta(at: date)
            points.append(GlucosePredictionPoint(date: date, value: min(max(projected, lowClamp), highClamp),
                                                 confidence: confidence, unclampedValue: projected))
            minute += step
        }
        return points
    }

    static func residualSlopePerMinute(_ history: [Sample], baselineDate: Date, treatmentDeltaAt: (Date) -> Double) -> Double {
        let recent = Array(history.reversed()
            .filter { $0.date <= baselineDate && baselineDate.timeIntervalSince($0.date) <= slopeWindow }
            .filter { $0.value.isFinite && $0.value > minimumValidValue }
            .prefix(slopeMaximumSamples)
            .reversed())
        guard recent.count >= 2, let firstDate = recent.first?.date else { return 0 }
        let xs = recent.map { $0.date.timeIntervalSince(firstDate) / 60 }
        let ys = recent.map { $0.value - treatmentDeltaAt($0.date) }
        let xMean = xs.reduce(0, +) / Double(xs.count)
        let yMean = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0, denominator = 0.0
        for index in recent.indices {
            let dx = xs[index] - xMean
            numerator += dx * (ys[index] - yMean)
            denominator += dx * dx
        }
        return denominator > 0.001 ? numerator / denominator : 0
    }
}

/// JugglucoNG's prediction settings and treatment model (`PredictiveSimulationSettings`,
/// `JournalEntry.projectedDisplayDelta`).
struct ExperimentalPredictionModel: Sendable {
    static let defaultCarbRatio = 10.0
    static let defaultInsulinSensitivityMgDl = 54.0
    static let defaultCarbAbsorption = 35.0
    static let carbRatioRange = 3.0...30.0
    static let insulinSensitivityRange = 10.0...180.0
    static let carbAbsorptionRange = 10.0...90.0
    static let bodyWeightRange = 10.0...400.0
    /// Treatments older than this cannot move the forecast.
    static let lookBack: TimeInterval = 36 * 60 * 60
    static let stepMinutes = 5
    /// A forecast starts only from a reading this recent.
    static let maximumBaselineAge: TimeInterval = 15 * 60

    var horizonMinutes = ExperimentalPredictionHorizon.defaultMinutes
    var trendMomentum = true
    var carbRatio = defaultCarbRatio
    var insulinSensitivityMgDl = defaultInsulinSensitivityMgDl
    var carbAbsorption = defaultCarbAbsorption
    var bolusInsulin: InsulinProfile = .aspart
    var basalInsulin: InsulinProfile = .glargineU100
    var bodyWeightKg: Double?
    /// Periods after midnight; before the first one the single values apply.
    var periods: [ExperimentalPredictionPeriod] = []
    var macrosEnabled = false
    var timeZone = TimeZone.current

    init() {}

    init(defaults: UserDefaults) {
        horizonMinutes = defaults.experimentalPredictionHorizonMinutes
        trendMomentum = defaults.experimentalPredictionTrendMomentum
        carbRatio = defaults.experimentalPredictionCarbRatio
        insulinSensitivityMgDl = defaults.experimentalPredictionInsulinSensitivityMgDl
        carbAbsorption = defaults.experimentalPredictionCarbAbsorption
        bolusInsulin = defaults.experimentalBolusInsulin
        basalInsulin = defaults.experimentalBasalInsulin
        bodyWeightKg = defaults.experimentalBodyWeightKg
        periods = defaults.experimentalPredictionPeriods
        macrosEnabled = defaults.experimentalPredictionMacrosEnabled
    }

    static func compact(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Carb ratio, sensitivity (mg/dL) and absorption in force at `date`, as JugglucoNG
    /// `PredictionModelProfile.parametersAt`: the last period starting at or before that minute.
    func parameters(at date: Date) -> (carbRatio: Double, insulinSensitivityMgDl: Double, carbAbsorption: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if let period = ExperimentalPredictionPeriod.sanitized(periods).last(where: { $0.startMinute <= minute }) {
            return (period.carbRatio, period.insulinSensitivityMgDl, period.carbAbsorption)
        }
        return (carbRatio, insulinSensitivityMgDl, carbAbsorption)
    }

    /// Modelled change from `baseline` to `date`. The model parameters are those in force when the
    /// treatment was logged, as in JugglucoNG; `toDisplay` converts mg/dL to the simulation unit.
    func treatmentDelta(_ treatment: ExperimentalTreatment, at date: Date, baseline: Date, toDisplay: (Double) -> Double = { $0 }) -> Double {
        let elapsed = date.timeIntervalSince(treatment.date) / 60
        let elapsedAtBaseline = baseline.timeIntervalSince(treatment.date) / 60
        let parameters = parameters(at: treatment.date)
        let sensitivity = toDisplay(parameters.insulinSensitivityMgDl)
        switch treatment.kind {
        case .carbs:
            let grams = treatment.amount
            guard grams.isFinite, grams > 0 else { return 0 }
            let absorptionRate = min(max(parameters.carbAbsorption, Self.carbAbsorptionRange.lowerBound), Self.carbAbsorptionRange.upperBound)
            let absorption = min(max(grams / absorptionRate * 60, 30), 360)
            let ratio = max(parameters.carbRatio, 1)
            let carbRise = grams / ratio * sensitivity * (InsulinCurveMath.mealProgress(elapsedMinutes: elapsed, durationMinutes: absorption)
                - InsulinCurveMath.mealProgress(elapsedMinutes: elapsedAtBaseline, durationMinutes: absorption))
            guard macrosEnabled, let macros = treatment.macros else { return carbRise }
            let tailGrams = ExperimentalFoodMath.tailEquivalentCarbs(protein: macros.protein, fat: macros.fat)
            guard tailGrams > 0 else { return carbRise }
            let delay = ExperimentalFoodMath.tailDelayMinutes(protein: macros.protein, fat: macros.fat)
            let duration = ExperimentalFoodMath.tailDurationMinutes(protein: macros.protein, fat: macros.fat)
            return carbRise + tailGrams / ratio * sensitivity * (InsulinCurveMath.mealProgress(elapsedMinutes: elapsed - delay, durationMinutes: duration)
                - InsulinCurveMath.mealProgress(elapsedMinutes: elapsedAtBaseline - delay, durationMinutes: duration))
        case .bolus, .basalInjection:
            let units = treatment.amount
            guard units.isFinite, units > 0,
                  let insulin = treatment.insulin(bolusDefault: bolusInsulin, basalDefault: basalInsulin),
                  insulin.countsTowardPrediction else { return 0 }
            let points = InsulinCurveCatalogue.curve(for: insulin, units: units, bodyWeightKg: bodyWeightKg)
            return -(units * sensitivity * (InsulinCurveMath.cumulativeFraction(points, elapsedMinutes: elapsed)
                - InsulinCurveMath.cumulativeFraction(points, elapsedMinutes: elapsedAtBaseline)))
        case .exercise:
            // Intensity from the editor's notes token; without one JugglucoNG's 0.5 applies.
            let duration = min(max(treatment.amount.isFinite ? treatment.amount : 30, 5), 240)
            let oneHourDrop = sensitivity * 0.22 * (treatment.intensity?.factor ?? 0.5)
            return -oneHourDrop * (duration / 60) * (InsulinCurveMath.linearProgress(elapsedMinutes: elapsed, durationMinutes: duration)
                - InsulinCurveMath.linearProgress(elapsedMinutes: elapsedAtBaseline, durationMinutes: duration))
        }
    }

    /// The forecast in mg/dL, simulated in the user's unit as JugglucoNG does.
    /// - Parameter readings: date and mg/dL value of recent readings, any order.
    func forecast(readings: [(date: Date, mgDl: Double)], treatments: [ExperimentalTreatment], isMmol: Bool,
                  targetLowMgDl: Double, targetHighMgDl: Double, now: Date = Date()) -> [GlucosePredictionPoint] {
        let toDisplay: (Double) -> Double = { isMmol ? $0 * ConstantsBloodGlucose.mgDlToMmoll : $0 }
        let history = readings.sorted { $0.date < $1.date }
            .map { GlucosePredictionKernel.Sample(date: $0.date, value: toDisplay($0.mgDl)) }
        guard let newest = history.last(where: { $0.value.isFinite && $0.value > GlucosePredictionKernel.minimumValidValue }),
              now.timeIntervalSince(newest.date) <= Self.maximumBaselineAge else { return [] }
        let baseline = newest.date
        let horizon = TimeInterval(min(max(horizonMinutes, 30), 360) * 60)
        let relevant = treatments.filter { $0.date >= baseline.addingTimeInterval(-Self.lookBack) && $0.date <= baseline.addingTimeInterval(horizon) }
        let points = GlucosePredictionKernel.simulate(
            history: history, isMmol: isMmol, trendMomentum: trendMomentum, horizonMinutes: horizonMinutes, stepMinutes: Self.stepMinutes,
            targetLow: toDisplay(targetLowMgDl), targetHigh: toDisplay(targetHighMgDl),
            treatmentDeltaAt: { date in relevant.reduce(0) { $0 + treatmentDelta($1, at: date, baseline: baseline, toDisplay: toDisplay) } })
        guard isMmol else { return points }
        return points.map { GlucosePredictionPoint(date: $0.date, value: $0.value / ConstantsBloodGlucose.mgDlToMmoll,
                                                   confidence: $0.confidence, unclampedValue: $0.unclampedValue / ConstantsBloodGlucose.mgDlToMmoll) }
    }
}

// MARK: - Prediction accuracy (JugglucoNG data/prediction/analysis)

/// One recorded forecast: where it started and what it predicted at each scored horizon (mg/dL).
struct RecordedForecast: Codable, Hashable, Sendable {
    let origin: Date
    let originMgDl: Double
    /// Horizon in minutes → predicted mg/dL.
    let predicted: [Int: Double]
}

/// How the forecast fared at one horizon (JugglucoNG `HorizonAccuracy`).
struct HorizonAccuracy: Hashable, Sendable {
    let horizonMinutes: Int
    let count: Int
    /// Mean absolute error, mg/dL.
    let meanAbsoluteError: Double
    /// Mean of forecast − actual, mg/dL: positive means the forecast ran high.
    let bias: Double
    let rootMeanSquareError: Double
    /// The same for assuming glucose stays where it was.
    let noChangeMeanAbsoluteError: Double
    let pending: Int
    let missing: Int
}

/// Scores recorded forecasts against the readings that followed (JugglucoNG `PredictionAccuracy`).
enum PredictionAccuracy {
    static let horizons = [15, 30, 60, 120]
    /// Below this many scored forecasts a horizon says nothing yet.
    static let minimumReliableCount = 36
    /// How long after its time a reading may still arrive before the outcome counts as missing.
    static let arrivalAllowance: TimeInterval = 30 * 60

    /// Glucose at `date` from readings sorted ascending: exact, or interpolated across a gap of at
    /// most 2.5 typical intervals (6–20 minutes), as JugglucoNG `ActualGlucose.valueAt`.
    static func actual(at date: Date, readings: [(date: Date, mgDl: Double)], maximumGap: TimeInterval) -> Double? {
        guard let upperIndex = readings.firstIndex(where: { $0.date >= date }) else { return nil }
        let upper = readings[upperIndex]
        if upper.date == date { return upper.mgDl > 0 ? upper.mgDl : nil }
        guard upperIndex > 0 else { return nil }
        let lower = readings[upperIndex - 1]
        let span = upper.date.timeIntervalSince(lower.date)
        guard span <= maximumGap, lower.mgDl > 0, upper.mgDl > 0 else { return nil }
        return lower.mgDl + (upper.mgDl - lower.mgDl) * date.timeIntervalSince(lower.date) / span
    }

    static func maximumGap(readings: [(date: Date, mgDl: Double)]) -> TimeInterval {
        let gaps = zip(readings, readings.dropFirst()).map { $1.date.timeIntervalSince($0.date) }.filter { $0 > 0 }.sorted()
        let cadence = gaps.isEmpty ? 5 * 60 : gaps[gaps.count / 2]
        return min(max(cadence * 2.5, 6 * 60), 20 * 60)
    }

    static func report(forecasts: [RecordedForecast], readings: [(date: Date, mgDl: Double)], now: Date = Date()) -> [HorizonAccuracy] {
        let sorted = readings.filter { $0.mgDl > 0 }.sorted { $0.date < $1.date }
        let gap = maximumGap(readings: sorted)
        let latest = sorted.last?.date ?? .distantPast
        return horizons.map { horizon in
            var errors: [Double] = [], noChange: [Double] = []
            var pending = 0, missing = 0
            for forecast in forecasts {
                guard let predicted = forecast.predicted[horizon] else { continue }
                let target = forecast.origin.addingTimeInterval(TimeInterval(horizon * 60))
                if let actual = actual(at: target, readings: sorted, maximumGap: gap) {
                    errors.append(predicted - actual)
                    noChange.append(abs(forecast.originMgDl - actual))
                } else if target > latest && target > now.addingTimeInterval(-arrivalAllowance) {
                    pending += 1
                } else {
                    missing += 1
                }
            }
            let count = errors.count
            func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
            return HorizonAccuracy(horizonMinutes: horizon, count: count,
                                   meanAbsoluteError: mean(errors.map(abs)), bias: mean(errors),
                                   rootMeanSquareError: sqrt(mean(errors.map { $0 * $0 })),
                                   noChangeMeanAbsoluteError: mean(noChange), pending: pending, missing: missing)
        }
    }
}

/// Records one forecast every five minutes while "Record accuracy" is on, keeping 14 days in a
/// file in Application Support.
enum PredictionAccuracyRecorder {
    static let interval: TimeInterval = 5 * 60
    static let retention: TimeInterval = 14 * 24 * 60 * 60
    private static let queue = DispatchQueue(label: "prediction.accuracy", qos: .utility)

    static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("experimental-prediction-accuracy.json")
    }

    static func load() -> [RecordedForecast] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RecordedForecast].self, from: data)) ?? []
    }

    static func clear() {
        queue.sync { if let url = fileURL { try? FileManager.default.removeItem(at: url) } }
    }

    /// The forecast's value at each scored horizon.
    static func record(from forecast: [GlucosePredictionPoint]) -> RecordedForecast? {
        guard let first = forecast.first else { return nil }
        var predicted: [Int: Double] = [:]
        for horizon in PredictionAccuracy.horizons {
            let target = first.date.addingTimeInterval(TimeInterval(horizon * 60))
            if let point = forecast.first(where: { abs($0.date.timeIntervalSince(target)) < 1 }) { predicted[horizon] = point.unclampedValue }
        }
        return predicted.isEmpty ? nil : RecordedForecast(origin: first.date, originMgDl: first.value, predicted: predicted)
    }

    /// Called after each new reading on the main queue; at most one record per five minutes.
    static func recordIfDue(coreDataManager: CoreDataManager, defaults: UserDefaults = .standard, now: Date = Date()) {
        guard defaults.experimentalPredictionAccuracyEnabled else { return }
        if let last = defaults.object(forKey: "experimentalPredictionAccuracyLastRecord") as? Date,
           now.timeIntervalSince(last) < interval - 30 { return }
        let readings = BgReadingsAccessor(coreDataManager: coreDataManager)
            .getLatestBgReadings(limit: nil, fromDate: now.addingTimeInterval(-2 * 60 * 60), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
            .map { (date: $0.timeStamp, mgDl: $0.finalValue) }
        let forecast = ExperimentalPredictionModel(defaults: defaults).forecast(
            readings: readings, treatments: PredictedLowAlert.treatments(in: coreDataManager.mainManagedObjectContext, now: now),
            isMmol: false, targetLowMgDl: defaults.lowMarkValue, targetHighMgDl: defaults.highMarkValue, now: now)
        guard let record = record(from: forecast) else { return }
        defaults.set(now, forKey: "experimentalPredictionAccuracyLastRecord")
        queue.async {
            var records = load().filter { now.timeIntervalSince($0.origin) < retention }
            records.append(record)
            guard let url = fileURL, let data = try? JSONEncoder().encode(records) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Nightscout

/// The forecast in the shape AAPS uploads, which Nightscout's OpenAPS plugin draws as forecast lines.
enum ExperimentalNightscoutPrediction {
    static let device = "xDrip4iOS"

    static func deviceStatus(forecast: [GlucosePredictionPoint], now: Date) -> [String: Any]? {
        guard let first = forecast.first, forecast.count > 1 else { return nil }
        return [
            "device": device,
            "created_at": now.ISOStringFromDate(),
            "openaps": [
                "suggested": [
                    "timestamp": first.date.ISOStringFromDate(),
                    "bg": Int(first.value.rounded()),
                    // Five-minute steps from the newest reading, as OpenAPS predBGs.
                    "predBGs": ["IOB": forecast.map { Int($0.value.rounded()) }],
                    "reason": "xDrip4iOS experimental forecast, not a dosing recommendation"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }
}

// MARK: - Insulin activity (InsulinActivityStack.kt)

/// How fast logged insulin is acting, in units per hour, stacked by insulin.
///
/// Each dose's curve is a shape with its peak at 1; scaled by the dose and divided by the shape's
/// area it becomes the rate the dose works at, so a basal injection reads as a low, wide band and a
/// bolus as a taller, short one. A steady-state curve (Toujeo, Tresiba) was measured after days of
/// daily doses, so one dose's own action is taken as `S(t) − S(t + 24 h)`. Nothing is extrapolated:
/// a curve ends where its source stopped observing.
enum InsulinActivityStack {
    struct Layer: Sendable {
        let insulin: InsulinProfile
        /// Running total up to and including this layer, in units per hour.
        let tops: [Double]
        /// Total of the layers below, in units per hour.
        let bottoms: [Double]
    }

    struct Band: Sendable {
        let dates: [Date]
        let layers: [Layer]
        var maximumRate: Double { layers.last?.tops.max() ?? 0 }
    }

    private static let dayMinutes = 24 * 60
    /// A steady-state curve longer than this was measured on once-weekly doses.
    private static let weeklyCurveMinutes = 3 * dayMinutes

    /// One dose's shape: steady-state curves are reduced to a single daily dose's action.
    static func shape(for insulin: InsulinProfile, units: Double, bodyWeightKg: Double? = nil) -> [InsulinCurvePoint] {
        let points = InsulinCurveCatalogue.curve(for: insulin, units: units, bodyWeightKg: bodyWeightKg)
        guard insulin.evidence == .sourceSteadyState, let end = points.last?.minute, end <= weeklyCurveMinutes else { return points }
        let minutes = Array(Set(points.map(\.minute) + points.map { $0.minute - dayMinutes } + [0]))
            .filter { $0 >= 0 && $0 <= end }.sorted()
        return minutes.map { minute in
            let activity = minute == 0 ? 0 : max(InsulinCurveCatalogue.interpolate(points, minute: Double(minute))
                - activityWithinCurve(points, minute: Double(minute + dayMinutes)), 0)
            return InsulinCurvePoint(minute: minute, activity: activity)
        }
    }

    /// Activity inside the observed curve, zero past its end.
    private static func activityWithinCurve(_ points: [InsulinCurvePoint], minute: Double) -> Double {
        guard let end = points.last?.minute, minute <= Double(end) else { return 0 }
        return InsulinCurveCatalogue.interpolate(points, minute: minute)
    }

    /// Rate in units per hour that `units` of insulin with this shape act at, `minutes` after the dose.
    static func rate(units: Double, shape: [InsulinCurvePoint], minutes: Double) -> Double {
        guard units.isFinite, units > 0, minutes >= 0, let end = shape.last?.minute, minutes <= Double(end) else { return 0 }
        let areaHours = InsulinCurveMath.integrate(shape, upTo: Double(end)) / 60
        guard areaHours > 0.0001 else { return 0 }
        return units * InsulinCurveCatalogue.interpolate(shape, minute: minutes) / areaHours
    }

    /// The stacked band over `dates`. Basal insulins sit at the bottom, then rapid ones.
    static func band(treatments: [ExperimentalTreatment], dates: [Date], bolusDefault: InsulinProfile, basalDefault: InsulinProfile,
                     bodyWeightKg: Double? = nil) -> Band {
        struct Dose { let date: Date; let units: Double; let shape: [InsulinCurvePoint] }
        var doses: [InsulinProfile: [Dose]] = [:]
        var shapes: [String: [InsulinCurvePoint]] = [:]
        for treatment in treatments where treatment.kind == .bolus || treatment.kind == .basalInjection {
            guard treatment.amount.isFinite, treatment.amount > 0,
                  let insulin = treatment.insulin(bolusDefault: bolusDefault, basalDefault: basalDefault) else { continue }
            let key = "\(insulin.rawValue)-\(InsulinCurveCatalogue.definition(insulin).doseAxis == .fixed ? 0 : treatment.amount)"
            let doseShape = shapes[key] ?? shape(for: insulin, units: treatment.amount, bodyWeightKg: bodyWeightKg)
            shapes[key] = doseShape
            doses[insulin, default: []].append(Dose(date: treatment.date, units: treatment.amount, shape: doseShape))
        }
        let order = InsulinProfile.basalChoices + InsulinProfile.bolusChoices
        var running = [Double](repeating: 0, count: dates.count)
        var layers: [Layer] = []
        for insulin in order {
            guard let insulinDoses = doses[insulin] else { continue }
            let bottoms = running
            for (index, date) in dates.enumerated() {
                running[index] += insulinDoses.reduce(0) { total, dose in
                    total + rate(units: dose.units, shape: dose.shape, minutes: date.timeIntervalSince(dose.date) / 60)
                }
            }
            layers.append(Layer(insulin: insulin, tops: running, bottoms: bottoms))
        }
        return Band(dates: dates, layers: layers)
    }

    /// Sample dates every five minutes, plus each dose's moment so the rise starts where it should.
    static func sampleDates(from start: Date, to end: Date, treatments: [ExperimentalTreatment]) -> [Date] {
        guard start < end else { return [] }
        var dates = Set<Date>([start, end])
        var time = ceil(start.timeIntervalSince1970 / 300) * 300
        while time < end.timeIntervalSince1970 {
            dates.insert(Date(timeIntervalSince1970: time))
            time += 300
        }
        for treatment in treatments where (treatment.kind == .bolus || treatment.kind == .basalInjection) && treatment.date > start && treatment.date < end {
            dates.insert(treatment.date)
        }
        return dates.sorted()
    }
}

/// Localised texts for the experimental features (SettingsViews table, `experimental.` keys).
enum ExperimentalTexts {
    static func text(_ key: String, _ english: String) -> String {
        NSLocalizedString("experimental." + key, tableName: "SettingsViews", bundle: .main, value: english, comment: "")
    }
}

// MARK: - Main chart inputs

/// Prepares the experimental overlays of the main chart from its state and the logged treatments.
enum ExperimentalChartInputs {
    /// Changes whenever a setting that alters the overlays changes.
    static func settingsSignature(defaults: UserDefaults = .standard) -> String {
        let model = ExperimentalPredictionModel(defaults: defaults)
        return [defaults.experimentalGlucoseChartStyle.rawValue.description, defaults.experimentalPredictionEnabled.description,
                defaults.experimentalInsulinsEnabled.description, model.horizonMinutes.description, model.trendMomentum.description,
                model.carbRatio.description, model.insulinSensitivityMgDl.description, model.carbAbsorption.description,
                model.bolusInsulin.rawValue, model.basalInsulin.rawValue, defaults.bloodGlucoseUnitIsMgDl.description,
                model.bodyWeightKg?.description ?? "-", ExperimentalPredictionPeriod.encode(model.periods), model.macrosEnabled.description,
                defaults.lowMarkValue.description, defaults.highMarkValue.description].joined(separator: "|")
    }

    /// How far back insulin can still be acting: two days, or eight for a once-weekly basal.
    static func insulinLookBack(basal: InsulinProfile) -> TimeInterval {
        (basal == .icodec ? 8 : 2) * 24 * 60 * 60
    }

    /// The forecast for widgets, Live Activity and the watch, while "Show prediction" is on.
    static func companionForecast(defaults: UserDefaults = .standard, now: Date = Date()) -> ExperimentalCompanionForecast? {
        guard defaults.experimentalPredictionEnabled, let coreDataManager = TherapyMetricsManager.shared.configuredCoreDataManager else { return nil }
        let readings = BgReadingsAccessor(coreDataManager: coreDataManager)
            .getLatestBgReadings(limit: nil, fromDate: now.addingTimeInterval(-2 * 60 * 60), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
            .map { (date: $0.timeStamp, mgDl: $0.finalValue) }
        let forecast = ExperimentalPredictionModel(defaults: defaults).forecast(
            readings: readings, treatments: PredictedLowAlert.treatments(in: coreDataManager.mainManagedObjectContext, now: now),
            isMmol: !defaults.bloodGlucoseUnitIsMgDl, targetLowMgDl: defaults.lowMarkValue, targetHighMgDl: defaults.highMarkValue, now: now)
        guard let first = forecast.first, forecast.count > 1 else { return nil }
        return ExperimentalCompanionForecast(startAsDouble: first.date.timeIntervalSince1970,
                                             valuesMgDl: forecast.map { ($0.value * 10).rounded() / 10 })
    }

    static func color(_ insulin: InsulinProfile) -> Color {
        Color(red: Double((insulin.colorHex >> 16) & 0xFF) / 255,
              green: Double((insulin.colorHex >> 8) & 0xFF) / 255,
              blue: Double(insulin.colorHex & 0xFF) / 255)
    }

    static func plots(chartState: GlucoseChartState, dataStart: Date, dataEnd: Date, showsInsulin: Bool,
                      defaults: UserDefaults = .standard, now: Date = Date()) async -> GlucoseChartExperimentalPlots {
        var plots = GlucoseChartExperimentalPlots()
        plots.drawsGlucoseAsLine = defaults.experimentalGlucoseChartStyle == .line
        let model = ExperimentalPredictionModel(defaults: defaults)
        let atPresent = chartState.endDate.timeIntervalSince(now) > -ConstantsGlucoseChartSwiftUI.experimentalPredictionPresentTolerance
        let wantsPrediction = defaults.experimentalPredictionEnabled && atPresent
        let wantsInsulin = defaults.experimentalInsulinsEnabled && showsInsulin
        guard wantsPrediction || wantsInsulin else { return plots }

        let futureEnd = now.addingTimeInterval(TimeInterval(model.horizonMinutes * 60))
        let lookBack = max(ExperimentalPredictionModel.lookBack, wantsInsulin ? insulinLookBack(basal: model.basalInsulin) : 0)
        let fetchStart = min(dataStart, now).addingTimeInterval(-lookBack)
        guard let treatments = await TherapyMetricsManager.shared.experimentalTreatments(from: fetchStart, to: max(dataEnd, futureEnd)) else { return plots }

        if wantsPrediction {
            let readings = zip(chartState.bgReadingDates, chartState.bgReadingValues)
                .filter { $0.0 >= now.addingTimeInterval(-2 * 60 * 60) && $0.0 <= now }
                .map { (date: $0.0, mgDl: $0.1) }
            plots.prediction = model.forecast(readings: readings, treatments: treatments, isMmol: !defaults.bloodGlucoseUnitIsMgDl,
                                              targetLowMgDl: defaults.lowMarkValue, targetHighMgDl: defaults.highMarkValue, now: now)
                .map { GlucoseChartExperimentalPlots.PredictionPoint(date: $0.date, mgDl: $0.value) }
        }

        if wantsInsulin {
            let bandEnd = wantsPrediction ? max(dataEnd, futureEnd) : dataEnd
            let dates = InsulinActivityStack.sampleDates(from: dataStart, to: bandEnd, treatments: treatments)
            let band = InsulinActivityStack.band(treatments: treatments, dates: dates,
                                                 bolusDefault: model.bolusInsulin, basalDefault: model.basalInsulin,
                                                 bodyWeightKg: model.bodyWeightKg)
            plots.insulin = band.layers.map { layer in
                GlucoseChartExperimentalPlots.InsulinLayer(
                    id: layer.insulin.rawValue, name: layer.insulin.shortName, color: color(layer.insulin),
                    points: band.dates.indices.map {
                        GlucoseChartExperimentalPlots.InsulinPoint(date: band.dates[$0], bottom: layer.bottoms[$0], top: layer.tops[$0])
                    })
            }
        }
        return plots
    }
}
