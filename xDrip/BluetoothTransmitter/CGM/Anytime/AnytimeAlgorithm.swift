//
//  AnytimeAlgorithm.swift
//  xdrip
//
//  Glucose computation of the Anytime / Yuwell driver, ported from JugglucoNG `AnytimeAlgorithm` and
//  `AnytimeCalibrator` (GPL-3.0, see THIRD_PARTY_NOTICES.md). Every path is plain arithmetic (JugglucoNG
//  does not ship the vendor library either):
//
//  - CT5 is computed by the transmitter itself (`fromComputedRecord`), the phone only reads it.
//  - CT2 uses the empirical CT-14 model (`computeCt14`).
//  - CT4 uses the MK4 chain (`AnytimeCalibrator`, a stateful temperature smoother plus a step limiter).
//  - CT3 and the families that share its frames have only the vendor kernel, which JugglucoNG ports as
//    `AnytimeNativeAlgorithm` and this fork does not (yet). Their K/R guess (`computeLinear`) is a display
//    fallback in JugglucoNG; the fork never presents it as glucose, see `AnytimeAlgorithm.valuePath`.
//
//  All arithmetic stays in `Float` exactly as in Kotlin, and the unit tests compare float bit patterns
//  with the unchanged Kotlin run on the JVM. Never tried on a real sensor.
//

import Foundation

/// Kotlin `Float.coerceAtLeast` (NaN stays NaN).
func anytimeCoerceAtLeast(_ value: Float, _ minimum: Float) -> Float {
    return value < minimum ? minimum : value
}

// MARK: - MK4 model (CT4)

/// Stateful, per-session glucose reconstructor of the MK4 chain (JugglucoNG `AnytimeCalibrator`): the base
/// value is `Iw / (1.2 * K0)`, scaled by a temperature multiplier from a smoothed sensor temperature, then
/// cut by a step limiter that follows the previous filtered value. Feed records in ascending glucose id
/// order; an id that goes backwards starts the limiter again.
final class AnytimeCalibrator {
    /// The three fields that carry continuity across records.
    struct State: Equatable, Codable {
        var tempSmoothPrev: Float
        var filteredPrev: Float
        var lastGlucoseId: Int

        init(tempSmoothPrev: Float, filteredPrev: Float, lastGlucoseId: Int) {
            self.tempSmoothPrev = tempSmoothPrev
            self.filteredPrev = filteredPrev
            self.lastGlucoseId = lastGlucoseId
        }

        // JSON has no NaN, so an unset value is stored as an absent key.
        private enum CodingKeys: String, CodingKey { case tempSmoothPrev, filteredPrev, lastGlucoseId }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tempSmoothPrev = try container.decodeIfPresent(Float.self, forKey: .tempSmoothPrev) ?? Float.nan
            filteredPrev = try container.decodeIfPresent(Float.self, forKey: .filteredPrev) ?? Float.nan
            lastGlucoseId = try container.decode(Int.self, forKey: .lastGlucoseId)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if tempSmoothPrev.isFinite { try container.encode(tempSmoothPrev, forKey: .tempSmoothPrev) }
            if filteredPrev.isFinite { try container.encode(filteredPrev, forKey: .filteredPrev) }
            try container.encode(lastGlucoseId, forKey: .lastGlucoseId)
        }
    }

    static let kBaseFactor: Float = 1.2
    static let autoFloor: Float = 0.9
    static let autoRampDenom: Float = 4800
    static let warmupRecords = 480
    static let tempMulSlope: Float = -0.04593
    static let tempReferenceC: Float = 32
    static let tempSmoothKneeC: Float = 30
    static let tempSmoothAlpha: Float = 0.25
    static let filterSaturationUpper: Float = 60
    static let filterFloorLower: Float = 1
    static let filterHighHoldThreshold: Float = 50

    let k0: Float
    private let kBase: Float
    private var tempSmoothPrev = Float.nan
    private var filteredPrev = Float.nan
    private var lastGlucoseId = -1
    /// The next `computeNext` must seed a fresh limiter: a new session, or a restored one that never started.
    private var pendingReset = true

    init(k0: Float) {
        self.k0 = k0
        self.kBase = k0 * AnytimeCalibrator.kBaseFactor
    }

    /// Per-id auto sensitivity of the pack-in (warm-up) curve.
    func autoSensitivity(glucoseId: Int) -> Float {
        if glucoseId <= 0 { return kBase * AnytimeCalibrator.autoFloor }
        let unclamped = AnytimeCalibrator.autoFloor + Float(glucoseId) / AnytimeCalibrator.autoRampDenom
        let ramp: Float = unclamped > 1 ? 1 : unclamped
        return kBase * ramp
    }

    /// Temperature used for the multiplier: the raw value up to the knee, a smoothed one above it.
    func effectiveTemperature(_ rawT: Float) -> Float {
        if rawT <= AnytimeCalibrator.tempSmoothKneeC {
            tempSmoothPrev = rawT
            return rawT
        }
        let previous = tempSmoothPrev
        let effective: Float
        if previous.isNaN {
            effective = rawT
        } else {
            effective = AnytimeCalibrator.tempSmoothAlpha * rawT + (1 - AnytimeCalibrator.tempSmoothAlpha) * previous
        }
        tempSmoothPrev = effective
        return effective
    }

    func tempMultiplier(_ rawT: Float) -> Float {
        let effective = effectiveTemperature(rawT)
        return 1 + (effective - AnytimeCalibrator.tempReferenceC) * AnytimeCalibrator.tempMulSlope
    }

    /// Advance by one raw record and return the filtered glucose (mmol/L) for its id.
    func computeNext(_ record: AnytimeRawRecord) -> Float {
        let id = record.glucoseId
        if id < lastGlucoseId || pendingReset {
            pendingReset = false
            filteredPrev = Float.nan
        }
        lastGlucoseId = id

        let base = record.iwNa / kBase
        let multiplier = tempMultiplier(record.temperatureC)
        let raw = base * multiplier
        let auto = autoSensitivity(glucoseId: id)

        let filtered = applyStepLimiter(raw, auto)
        filteredPrev = filtered
        return filtered
    }

    private func applyStepLimiter(_ x: Float, _ r: Float) -> Float {
        let previous = filteredPrev
        // Start: no previous sample yet, seed the filter without a step cut.
        if previous.isNaN { return min(x, AnytimeCalibrator.filterSaturationUpper) }
        // Reset: over-range input only.
        if x > AnytimeCalibrator.filterSaturationUpper { return x }

        let delta = x - previous
        let candidate: Float
        if delta > r {
            // Uphill: blend toward the ceiling of one step.
            candidate = min((x + previous * delta) / (delta + 1), previous + r)
        } else if delta < -r {
            // Downhill: clamp to one step below.
            candidate = previous - r
        } else {
            candidate = x
        }

        if candidate < AnytimeCalibrator.filterFloorLower && x <= 0 { return x }
        if candidate >= AnytimeCalibrator.filterHighHoldThreshold && x >= AnytimeCalibrator.filterHighHoldThreshold { return previous }
        return candidate
    }

    /// New session or cleared calibration.
    func reset() {
        tempSmoothPrev = Float.nan
        filteredPrev = Float.nan
        lastGlucoseId = -1
        pendingReset = true
    }

    func snapshot() -> State {
        return State(tempSmoothPrev: tempSmoothPrev, filteredPrev: filteredPrev, lastGlucoseId: lastGlucoseId)
    }

    /// Resume a session from a snapshot (after an app restart); unlike `reset` this continues the
    /// limiter and the smoother where they stopped.
    func restoreState(_ state: State) {
        tempSmoothPrev = state.tempSmoothPrev
        filteredPrev = state.filteredPrev
        lastGlucoseId = state.lastGlucoseId
        pendingReset = false
    }
}

// MARK: - Algorithm dispatch

enum AnytimeAlgorithm {
    enum Source: String, Equatable {
        /// Computed by the transmitter (CT5).
        case native
        /// The vendor CT3 kernel ported to plain code. Declared for parity, never produced by this fork.
        case nativePort
        /// MK4 chain.
        case model
        /// Plain arithmetic: the CT-14 model, or the K/R guess.
        case linear
    }

    /// How a family gets its glucose value in this fork.
    enum ValuePath: Equatable {
        /// The transmitter sends the value (CT5).
        case transmitterComputed
        /// Empirical CT-14 model of the oldest family (CT2).
        case ct14Model
        /// MK4 chain (CT4).
        case mk4Model
        /// No validated value path: CT2.5, the CT3 families and unknown devices. The sensor is read, but
        /// no glucose is published, because JugglucoNG's only calibrated path for them is the vendor
        /// kernel port and its other path is a K/R guess.
        case unavailable
    }

    static func valuePath(for family: AnytimeFamily) -> ValuePath {
        switch family {
        case .ct5: return .transmitterComputed
        case .ct2: return .ct14Model
        case .ct4: return .mk4Model
        case .ct25, .ct3, .ct3Plus, .ct3Yuwell, .ct3Ultrasonic, .unknown: return .unavailable
        }
    }

    /// Algorithm output. Mirrors the transmitter's own record where it provides one.
    struct Output: Equatable {
        var glucoseId: Int
        var mmol: Float
        var mgdlTimes10: Int
        var ibNa: Float
        var iwNa: Float
        var temperatureC: Float
        var trend: Int
        var errorCode: Int
        var warnCode: Int
        var source: Source
        /// Uncalibrated K/R (or model) glucose estimate for the raw history view.
        var rawMgdl: Float = Float.nan
        var beVoltageMv: Int = AnytimeComputedRecord.unset
        var weVoltageMv: Int = AnytimeComputedRecord.unset
        var reVoltageMv: Int = AnytimeComputedRecord.unset
        var ceVoltageMv: Int = AnytimeComputedRecord.unset
        var bVoltageMv: Int = AnytimeComputedRecord.unset
        var calibrationStatus: Int = AnytimeCalibrationPolicy.calibrationStatusUnknown

        var mgdl: Float { return Float(mgdlTimes10) / 10 }
    }

    /// Trend value of the paths that compute none (JugglucoNG `TREND_NONE`).
    static let trendNone = 6

    /// A fingerstick is attached to the CT3 kernel only for the record it was entered against or later.
    static func shouldAttachReferenceBg(recordGlucoseId: Int, referenceGlucoseId: Int, referenceMgdlTimes10: Int) -> Bool {
        return referenceGlucoseId >= 1 && referenceGlucoseId <= recordGlucoseId && referenceMgdlTimes10 > 0
    }

    private static func mgdlTimes10(forMmol mmol: Float) -> Int {
        let scaled = anytimeKotlinInt(mmol * 18.0 * 10 + 0.5)
        return anytimeClamp(scaled, AnytimeConstants.algoMgdlMinTimes10, AnytimeConstants.algoMgdlMaxTimes10)
    }

    private static func normalizedRawIw(_ iwNa: Float, family: AnytimeFamily?, voltageFlag: Int) -> Float {
        if iwNa <= 0 || !iwNa.isFinite { return iwNa }
        return (family == .ct4 && voltageFlag == 1) ? iwNa / 2 : iwNa
    }

    /// K/R guess. A display fallback only: the fork does not publish it as glucose.
    static func computeLinear(record: AnytimeRawRecord, k: Float, r: Float, family: AnytimeFamily? = nil, voltageFlag: Int = 0) -> Output {
        let kEff: Float = k > 0 ? k : 0.30
        let rEff: Float = r > 0 ? r : 50
        let rawIw = normalizedRawIw(record.iwNa, family: family, voltageFlag: voltageFlag)
        let rawMmol = kEff * rawIw + rEff / 100
        let mmol = anytimeCoerceAtLeast(rawMmol, AnytimeConstants.algoMmolFloor)
        return Output(
            glucoseId: record.glucoseId,
            mmol: mmol,
            mgdlTimes10: mgdlTimes10(forMmol: mmol),
            ibNa: record.ibNa,
            iwNa: record.iwNa,
            temperatureC: record.temperatureC,
            trend: trendNone,
            errorCode: 0,
            warnCode: 0,
            source: .linear,
            rawMgdl: rawMmol * 18.0
        )
    }

    /// CT2 aging compensated raw current in nA.
    static func ct14RawNa(iwNa: Float, sampleTimeMs: Int64, sensorStartTimeMs: Int64) -> Float {
        let elapsedDays: Float
        if sensorStartTimeMs > 0 && sampleTimeMs > sensorStartTimeMs {
            elapsedDays = Float(sampleTimeMs - sensorStartTimeMs) / 86_400_000
        } else {
            elapsedDays = 0
        }
        return iwNa + AnytimeConstants.ct14AgingNaPerDay * elapsedDays
    }

    /// CT2 / CT-14 empirical model: `raw = Iw + 0.4 * elapsedDays`, `mmol = (raw - intercept) / slope`.
    static func computeCt14(record: AnytimeRawRecord, sampleTimeMs: Int64, sensorStartTimeMs: Int64) -> Output {
        let rawNa = ct14RawNa(iwNa: record.iwNa, sampleTimeMs: sampleTimeMs, sensorStartTimeMs: sensorStartTimeMs)
        let stockMmol = (rawNa - AnytimeConstants.ct14DefaultIntercept) / AnytimeConstants.ct14DefaultSlope
        let mmol = anytimeCoerceAtLeast(stockMmol, AnytimeConstants.algoMmolFloor)
        return Output(
            glucoseId: record.glucoseId,
            mmol: mmol,
            mgdlTimes10: mgdlTimes10(forMmol: mmol),
            ibNa: record.ibNa,
            iwNa: record.iwNa,
            temperatureC: record.temperatureC,
            trend: trendNone,
            errorCode: 0,
            warnCode: 0,
            source: .linear,
            rawMgdl: stockMmol * 18.0
        )
    }

    /// The MK4 chain for one record through a stateful calibrator.
    static func computeModel(record: AnytimeRawRecord, calibrator: AnytimeCalibrator, rawMgdl: Float) -> Output {
        let filteredMmol = calibrator.computeNext(record)
        let mmol = anytimeCoerceAtLeast(filteredMmol, AnytimeConstants.algoMmolFloor)
        return Output(
            glucoseId: record.glucoseId,
            mmol: mmol,
            mgdlTimes10: mgdlTimes10(forMmol: mmol),
            ibNa: record.ibNa,
            iwNa: record.iwNa,
            temperatureC: record.temperatureC,
            trend: trendNone,
            errorCode: 0,
            warnCode: 0,
            source: .model,
            rawMgdl: rawMgdl
        )
    }

    /// Use the transmitter's own computed record directly.
    static func fromComputedRecord(_ record: AnytimeComputedRecord, qr: AnytimeQrCalibration? = nil, family: AnytimeFamily? = nil) -> Output {
        let rawRecord = AnytimeRawRecord(indexInPacket: 0, glucoseId: record.glucoseId, ibNa: record.ibNa, iwNa: record.iwNa, temperatureC: record.temperatureC, recordBytes: [])
        let rawLinear = computeLinear(record: rawRecord, k: qr?.k ?? 0, r: qr?.r ?? 0, family: family, voltageFlag: qr?.voltageFlag ?? 0)
        let mgdlTimes10 = anytimeClamp(record.gluMgdl * 10, AnytimeConstants.algoMgdlMinTimes10, AnytimeConstants.algoMgdlMaxTimes10)
        return Output(
            glucoseId: record.glucoseId,
            mmol: record.gluMmol,
            mgdlTimes10: mgdlTimes10,
            ibNa: record.ibNa,
            iwNa: record.iwNa,
            temperatureC: record.temperatureC,
            trend: record.trend,
            errorCode: record.errorCode,
            warnCode: record.warnCode,
            source: .native,
            rawMgdl: rawLinear.rawMgdl,
            beVoltageMv: record.beVoltageMv,
            weVoltageMv: record.weVoltageMv,
            reVoltageMv: record.reVoltageMv,
            ceVoltageMv: record.ceVoltageMv,
            bVoltageMv: record.batteryRaw
        )
    }
}

// MARK: - Per sensor state

/// The algorithm state of one sensor: the MK4 calibrator, created for the K0 in use.
final class AnytimeAlgorithmSession {
    private(set) var calibrator: AnytimeCalibrator?

    /// Seed from persisted state before the first record.
    func restoreCalibrator(k0: Float, state: AnytimeCalibrator.State) {
        if k0 <= 0 { return }
        let restored = AnytimeCalibrator(k0: k0)
        restored.restoreState(state)
        calibrator = restored
    }

    func snapshotCalibrator() -> AnytimeCalibrator.State? {
        return calibrator?.snapshot()
    }

    func clear() {
        calibrator = nil
    }

    private func calibratorMatching(k0: Float) -> AnytimeCalibrator {
        if let existing = calibrator, existing.k0 == k0 { return existing }
        let created = AnytimeCalibrator(k0: k0)
        calibrator = created
        return created
    }

    /// The value of one raw record, or nil when the family has no value path (or is transmitter computed).
    /// Call it in ascending glucose id order: the CT4 chain is stateful.
    func compute(record: AnytimeRawRecord, qr: AnytimeQrCalibration?, family: AnytimeFamily, sampleTimeMs: Int64, sensorStartTimeMs: Int64) -> AnytimeAlgorithm.Output? {
        switch AnytimeAlgorithm.valuePath(for: family) {
        case .ct14Model:
            return AnytimeAlgorithm.computeCt14(record: record, sampleTimeMs: sampleTimeMs, sensorStartTimeMs: sensorStartTimeMs)
        case .mk4Model:
            let k = qr?.k ?? 0
            let linear = AnytimeAlgorithm.computeLinear(record: record, k: k, r: qr?.r ?? 0, family: family, voltageFlag: qr?.voltageFlag ?? 0)
            // CT4 has no factory code, so K0 is usually 0 and the MK4 reference K0 stands in for it.
            let effectiveK0 = k > 0 ? k : AnytimeConstants.ct4DefaultK0
            return AnytimeAlgorithm.computeModel(record: record, calibrator: calibratorMatching(k0: effectiveK0), rawMgdl: linear.rawMgdl)
        case .transmitterComputed, .unavailable:
            return nil
        }
    }
}
