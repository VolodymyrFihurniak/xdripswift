import CoreBluetooth
import Foundation

enum Sibionics2Time {
    static let secondsPerMinute: TimeInterval = 60
    static let minutesPerHour: TimeInterval = 60
    static let hoursPerDay: TimeInterval = 24
    static let secondsPerHour = secondsPerMinute * minutesPerHour
    static let secondsPerDay = secondsPerHour * hoursPerDay
}

enum Sibionics2SensorProfile {
    static let expectedLifeInDays: Int = 23
    static let sampleInterval: TimeInterval = Sibionics2Time.secondsPerMinute
    static let maximumReportableGlucoseMgDl: Double = 900
    static let expectedLife = TimeInterval(expectedLifeInDays) * Sibionics2Time.secondsPerDay
}

/// Sibionics 1 (GS1 EU, Hematonix, Chinese) lifetime, as in JugglucoNG `SibionicsConstants`.
/// The label says 14 days, but the sensor keeps streaming: JugglucoNG extends every GS1 session
/// automatically to `EXTENDED_CHINESE_LIFETIME_MS` (572 h − 19 min, ≈ 23 days 19 h 41 min) and
/// shows the official end only as information.
enum Sibionics1SensorProfile {
    static let officialLifeInDays: Double = 14
    static let extendedLife: TimeInterval = 572 * Sibionics2Time.secondsPerHour - 19 * Sibionics2Time.secondsPerMinute
    static let extendedLifeInDays: Double = extendedLife / Sibionics2Time.secondsPerDay
}

/// Valid ranges for decoded V120 readings before they enter the correction algorithm.
enum Sibionics2ReadingValidationPolicy {
    static let minimumIndex = 1
    static let maximumIndex = Sibionics2V120ReadingFormat.maximumIndex
    static let maximumRawGlucoseMmol =
        Sibionics2V120ReadingFormat.maximumEncodedValue / Sibionics2V120ReadingFormat.measurementScale
}

enum Sibionics2CalibrationMode: Int, CaseIterable {
    case xDripPlus = 0
    /// JugglucoNG's default algorithm. The raw value predates the other JugglucoNG modes.
    case jugglucoNG = 1
    case jugglucoMedianSlope = 2
    case jugglucoRobustRegression = 3
    case jugglucoElasticInterpolation = 4
    case jugglucoAdaptiveEnsemble = 5

    static let defaultMode: Self = .xDripPlus
    private static let xDripPlusHistoryWindowInDays = 4

    var title: String {
        switch self {
        case .xDripPlus: return Texts_BluetoothPeripheralView.sibionics2CalibrationXDripPlus
        case .jugglucoNG: return Texts_BluetoothPeripheralView.sibionics2CalibrationJugglucoNG
        case .jugglucoMedianSlope: return Texts_BluetoothPeripheralView.sibionics2CalibrationJugglucoMedianSlope
        case .jugglucoRobustRegression: return Texts_BluetoothPeripheralView.sibionics2CalibrationJugglucoRobust
        case .jugglucoElasticInterpolation: return Texts_BluetoothPeripheralView.sibionics2CalibrationJugglucoElastic
        case .jugglucoAdaptiveEnsemble: return Texts_BluetoothPeripheralView.sibionics2CalibrationJugglucoEnsemble
        }
    }

    /// The JugglucoNG CalibrationMath algorithm, or nil for xDrip's own calibration.
    var jugglucoAlgorithm: Sibionics2JugglucoCalibrationAlgorithm? {
        switch self {
        case .xDripPlus: return nil
        case .jugglucoNG: return .saneWeightedOLS
        case .jugglucoMedianSlope: return .xDripMedianSlope
        case .jugglucoRobustRegression: return .timeWeightedRobustRegression
        case .jugglucoElasticInterpolation: return .elasticTimeWeightedInterpolation
        case .jugglucoAdaptiveEnsemble: return .adaptiveEnsemble
        }
    }

    /// History used by both live glucose recalculation and new calibration creation.
    var calibrationHistoryDays: Int {
        jugglucoAlgorithm == nil ? Self.xDripPlusHistoryWindowInDays : Sibionics2SensorProfile.expectedLifeInDays
    }
}

/// Everything a Sibionics calibration needs: the selected method, JugglucoNG's
/// weight profile and the display unit its constants were tuned for.
struct Sibionics2CalibrationProfile {
    let mode: Sibionics2CalibrationMode
    let weighting: Sibionics2CalibrationWeighting
    let mgDlPerDisplayUnit: Double

    init(
        mode: Sibionics2CalibrationMode,
        weighting: Sibionics2CalibrationWeighting = .defaultWeighting,
        mgDlPerDisplayUnit: Double = 1
    ) {
        self.mode = mode
        self.weighting = weighting
        self.mgDlPerDisplayUnit = mgDlPerDisplayUnit
    }

    static func current(for identifier: String?) -> Sibionics2CalibrationProfile {
        guard let identifier else { return Sibionics2CalibrationProfile(mode: .defaultMode) }
        return Sibionics2CalibrationProfile(
            mode: Sibionics2Configuration.calibrationMode(for: identifier),
            weighting: Sibionics2Configuration.calibrationWeighting(for: identifier),
            mgDlPerDisplayUnit: Sibionics2JugglucoCalibrationMath.currentMgDlPerDisplayUnit
        )
    }

    var calibrationHistoryDays: Int { mode.calibrationHistoryDays }

    /// JugglucoNG-calibrated value, or nil when xDrip's own calibration applies.
    func jugglucoValue(_ value: Double, at timeStamp: Date, anchors: [Sibionics2CalibrationAnchor]) -> Double? {
        guard let algorithm = mode.jugglucoAlgorithm else { return nil }
        return Sibionics2JugglucoCalibrationMath.calibratedValue(
            value, at: timeStamp, anchors: anchors,
            algorithm: algorithm, weighting: weighting, mgDlPerDisplayUnit: mgDlPerDisplayUnit
        )
    }
}

/// Standard BLE Battery Service, which Sibionics sensors expose next to FF30.
enum Sibionics2Battery {
    static let serviceUUID = CBUUID(string: "180F")
    static let levelCharacteristicUUID = CBUUID(string: "2A19")
    static let refreshInterval: TimeInterval = 6 * Sibionics2Time.secondsPerHour

    /// Battery Level is one unsigned byte holding a percentage.
    static func percentage(from value: Data) -> Int? {
        guard value.count == 1, let level = value.first, level <= 100 else { return nil }
        return Int(level)
    }
}

/// Confirmed wire protocol for a Sibionics 1 peripheral, keyed by iOS BLE UUID.
enum Sibionics1ProtocolMode: Int {
    case chinese = 1
    case v120 = 2
}

/// Retry, timeout, and cadence values for the Sibionics 2 BLE session lifecycle.
enum Sibionics2ConnectionPolicy {
    static let minimumScheduledDelay: TimeInterval = 1
    static let resetWriteRetryDelay: TimeInterval = 5
    static let resetRestartConfirmationDelay: TimeInterval = 15
    static let automaticResetRecheckInterval: TimeInterval = 15 * Sibionics2Time.secondsPerMinute
    static let chinesePollInterval: TimeInterval = Sibionics2Time.secondsPerMinute
    static let chineseDataRetryInterval: TimeInterval = 30
    /// JugglucoNG reconnects when streaming has produced no reading for three minutes.
    static let readingsStallTimeout: TimeInterval = 3 * Sibionics2Time.secondsPerMinute

    static let streamingTimeout: TimeInterval = 75
    static let maximumHandshakeReconnectAttempts = 2
    /// JugglucoNG moves to the next key group when authentication draws no response.
    static let authenticationResponseTimeout: TimeInterval = 5
    /// JugglucoNG restarts authentication when a later handshake step is not answered.
    static let handshakeStepTimeout: TimeInterval = 15
    static let maximumHandshakeRestartsPerConnection = 2
    /// Upper bound on waiting for the Device Information address before authenticating.
    static let deviceInformationTimeout: TimeInterval = 3

    static let historyResponseTimeout: TimeInterval = 90
    static let historyWriteRetryDelay: TimeInterval = 3
    static let maximumHistoryWriteFailures = 3
    static let maximumHistoryReconnectAttempts = 2

    static let sessionStartDateTolerance = 10 * Sibionics2Time.secondsPerMinute
    static let maximumSessionStartDrift = 6 * Sibionics2Time.secondsPerHour
    static let minimumForwardProgressDrift = 2 * Sibionics2Time.secondsPerHour
    static let indexAgeDriftRatio = 0.01
}

/// Stable-session thresholds used by automatic reset.
enum Sibionics2AutoResetReadingPolicy {
    static let minimumComfortableMgDl = 80.0
    static let maximumComfortableMgDl = 180.0
    static let maximumRateMgDlPerMinute = 2.0
    static let maximumReadingAge: TimeInterval = 10 * Sibionics2Time.secondsPerMinute
    static let maximumReadingIntervalMinutes: TimeInterval = 15
}

struct Sibionics2CalibrationAnchor {
    let sensorMgDl: Double
    let fingerstickMgDl: Double
    let timeStamp: Date
}

/// The five calibration algorithms of JugglucoNG's CalibrationMath. JugglucoNG
/// applies the selected one to Sibionics through its integrated calibration lane.
enum Sibionics2JugglucoCalibrationAlgorithm: CaseIterable {
    case saneWeightedOLS
    case xDripMedianSlope
    case timeWeightedRobustRegression
    case elasticTimeWeightedInterpolation
    case adaptiveEnsemble
}

/// JugglucoNG's calibration weight profile: how quickly older fingersticks lose influence.
enum Sibionics2CalibrationWeighting: Int, CaseIterable {
    case fresh = 0
    case balanced = 1
    case stable = 2

    static let defaultWeighting: Self = .fresh

    var title: String {
        switch self {
        case .fresh: return Texts_BluetoothPeripheralView.sibionics2CalibrationWeightingFresh
        case .balanced: return Texts_BluetoothPeripheralView.sibionics2CalibrationWeightingBalanced
        case .stable: return Texts_BluetoothPeripheralView.sibionics2CalibrationWeightingStable
        }
    }

    /// Half-life multiplier for fingersticks before (past) or after (future) the reading.
    func halfLifeScale(isPastPoint: Bool) -> Double {
        switch self {
        case .fresh: return isPastPoint ? 0.45 : 0.65
        case .balanced: return 1
        case .stable: return isPastPoint ? 1.75 : 1.25
        }
    }
}

/// Port of JugglucoNG's CalibrationMath (tk.glucodata.data.calibration).
///
/// JugglucoNG stores calibrations and evaluates the fit in the user's display unit,
/// so its distance and robustness constants were tuned for that unit. Values here
/// arrive in mg/dL and are converted with `mgDlPerDisplayUnit` (1 for mg/dL,
/// 18.018 for mmol/L) before the original arithmetic runs. Only fingersticks at or
/// before the reading are used, matching JugglucoNG's default locked past history.
enum Sibionics2JugglucoCalibrationMath {
    private struct Point {
        let x: Double
        let y: Double
        let time: TimeInterval
    }

    private struct LinearModel {
        let slope: Double
        let intercept: Double
        func predict(_ x: Double) -> Double { slope * x + intercept }
    }

    private static let hour = Sibionics2Time.secondsPerHour
    private static let calibratedValueRange: ClosedRange<Double> = 0...1000

    /// The display-unit factor for the current xDrip setting.
    static var currentMgDlPerDisplayUnit: Double {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl ? 1 : ConstantsBloodGlucose.mmollToMgdl
    }

    static func calibratedValue(
        _ value: Double,
        at timeStamp: Date,
        anchors: [Sibionics2CalibrationAnchor],
        algorithm: Sibionics2JugglucoCalibrationAlgorithm = .saneWeightedOLS,
        weighting: Sibionics2CalibrationWeighting = .defaultWeighting,
        mgDlPerDisplayUnit: Double = 1
    ) -> Double {
        guard value.isFinite, value > 0, mgDlPerDisplayUnit.isFinite, mgDlPerDisplayUnit > 0 else { return value }
        let points = anchors
            .filter {
                $0.sensorMgDl.isFinite && $0.sensorMgDl > 0 &&
                    $0.fingerstickMgDl.isFinite && $0.fingerstickMgDl > 0 &&
                    $0.timeStamp <= timeStamp
            }
            .sorted { $0.timeStamp < $1.timeStamp }
            .map {
                Point(x: $0.sensorMgDl / mgDlPerDisplayUnit,
                      y: $0.fingerstickMgDl / mgDlPerDisplayUnit,
                      time: $0.timeStamp.timeIntervalSince1970)
            }
        guard !points.isEmpty else { return value }

        let target = value / mgDlPerDisplayUnit
        let targetTime = timeStamp.timeIntervalSince1970
        let prediction: Double
        if points.count == 1 {
            prediction = target + points[0].y - points[0].x
        } else {
            switch algorithm {
            case .saneWeightedOLS:
                prediction = saneWeightedOLS(target, targetTime, points, weighting)
            case .xDripMedianSlope:
                prediction = xDripMedianSlope(target, targetTime, points, weighting)
            case .timeWeightedRobustRegression:
                prediction = timeWeightedRobustRegression(target, targetTime, points, weighting)
            case .elasticTimeWeightedInterpolation:
                prediction = elasticTimeWeightedInterpolation(target, targetTime, points, weighting)
            case .adaptiveEnsemble:
                prediction = adaptiveEnsemble(target, targetTime, points, weighting)
            }
        }
        // sanitizeCalibratedValue keeps the input when the fit is not finite.
        guard prediction.isFinite else { return value }
        return prediction.clamped(to: calibratedValueRange) * mgDlPerDisplayUnit
    }

    // MARK: - Shared helpers

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func temporalWeight(
        _ point: Point, _ targetTime: TimeInterval,
        pastHalfLifeHours: Double, futureHalfLifeHours: Double,
        _ weighting: Sibionics2CalibrationWeighting
    ) -> Double {
        let deltaHours = (targetTime - point.time) / hour
        let isPastPoint = deltaHours >= 0
        let halfLife = (isPastPoint ? pastHalfLifeHours : futureHalfLifeHours)
            * weighting.halfLifeScale(isPastPoint: isPastPoint)
        return pow(0.5, abs(deltaHours) / max(halfLife, 0.1))
    }

    private static func weightedOffset(_ points: [Point], _ weights: [Double]) -> Double {
        var sumWeight = 0.0
        var sumOffset = 0.0
        for (point, weight) in zip(points, weights) {
            let w = max(weight, 0)
            sumWeight += w
            sumOffset += (point.y - point.x) * w
        }
        guard sumWeight > 1e-9 else {
            return points.map { $0.y - $0.x }.reduce(0, +) / Double(points.count)
        }
        return sumOffset / sumWeight
    }

    private static func weightedLinearModel(
        _ points: [Point], _ weights: [Double], slopeRange: ClosedRange<Double>
    ) -> LinearModel? {
        guard points.count == weights.count, !points.isEmpty else { return nil }
        var sumW = 0.0, sumWX = 0.0, sumWY = 0.0, sumWXY = 0.0, sumWX2 = 0.0
        for (point, weight) in zip(points, weights) {
            let w = max(weight, 0)
            sumW += w
            sumWX += w * point.x
            sumWY += w * point.y
            sumWXY += w * point.x * point.y
            sumWX2 += w * point.x * point.x
        }
        guard sumW > 1e-9 else { return nil }
        let denominator = sumW * sumWX2 - sumWX * sumWX
        guard abs(denominator) > 1e-9 else { return nil }
        let slope = ((sumW * sumWXY - sumWX * sumWY) / denominator).clamped(to: slopeRange)
        let intercept = (sumWY - slope * sumWX) / sumW
        guard slope.isFinite, intercept.isFinite else { return nil }
        return LinearModel(slope: slope, intercept: intercept)
    }

    /// The point closest in value plus hours, used by the local anchor snap.
    private static func nearestByValueAndTime(_ points: [Point], _ target: Double, _ targetTime: TimeInterval) -> Point? {
        points.min {
            abs($0.x - target) + abs($0.time - targetTime) / hour < abs($1.x - target) + abs($1.time - targetTime) / hour
        }
    }

    private static func localProximityWeights(
        _ target: Double, _ targetTime: TimeInterval, _ points: [Point],
        pastHalfLifeHours: Double, futureHalfLifeHours: Double, _ weighting: Sibionics2CalibrationWeighting
    ) -> [Double] {
        let scale = max(median(points.map { abs($0.x - target) }), 0.5)
        return points.map { point in
            let timeWeight = temporalWeight(point, targetTime, pastHalfLifeHours: pastHalfLifeHours,
                                            futureHalfLifeHours: futureHalfLifeHours, weighting)
            let proximity = 1 / (1 + pow(abs(point.x - target) / scale, 2))
            return max(timeWeight * proximity, 1e-4)
        }
    }

    private static func dominance(_ weights: [Double]) -> Double {
        (weights.max() ?? 0) / max(weights.reduce(0, +), 1e-6)
    }

    // MARK: - Algorithms

    /// Recency-weighted OLS with local anchor snap (JugglucoNG default).
    private static func saneWeightedOLS(
        _ target: Double, _ targetTime: TimeInterval, _ points: [Point], _ weighting: Sibionics2CalibrationWeighting
    ) -> Double {
        let newestTime = points.map(\.time).max() ?? targetTime
        let weights = points.map { point -> Double in
            let weight = temporalWeight(point, targetTime, pastHalfLifeHours: 18, futureHalfLifeHours: 6, weighting)
            return point.time == newestTime ? weight * 1.25 : weight
        }
        let model = weightedLinearModel(points, weights, slopeRange: 0.65...1.35)
        let regression = model?.predict(target) ?? (target + weightedOffset(points, weights))
        guard let nearest = nearestByValueAndTime(points, target, targetTime) else { return regression }
        let dx = abs(nearest.x - target)
        let dtHours = abs(nearest.time - targetTime) / hour
        let snap = (1 / (1 + dx * 2.5)) * (1 / (1 + dtHours / 8)) * 0.25
        let anchor = target + (nearest.y - nearest.x)
        return regression * (1 - snap) + anchor * snap
    }

    /// Theil-Sen style median slope over the twelve fingersticks nearest in time.
    private static func xDripMedianSlope(
        _ target: Double, _ targetTime: TimeInterval, _ points: [Point], _ weighting: Sibionics2CalibrationWeighting
    ) -> Double {
        let workingSet = Array(points.sorted { abs($0.time - targetTime) < abs($1.time - targetTime) }.prefix(12))
        var slopes = [Double]()
        for i in workingSet.indices {
            for j in workingSet.indices where j > i {
                let dx = workingSet[j].x - workingSet[i].x
                guard abs(dx) > 1e-9 else { continue }
                slopes.append((workingSet[j].y - workingSet[i].y) / dx)
            }
        }
        let offsetFallback: () -> Double = {
            let weights = workingSet.map {
                temporalWeight($0, targetTime, pastHalfLifeHours: 18, futureHalfLifeHours: 6, weighting)
            }
            return target + weightedOffset(workingSet, weights)
        }
        guard !slopes.isEmpty else { return offsetFallback() }
        let slope = median(slopes).clamped(to: 0.60...1.40)
        let intercept = median(workingSet.map { $0.y - slope * $0.x })
        let prediction = slope * target + intercept
        return prediction.isFinite ? prediction : offsetFallback()
    }

    /// Huber-style iteratively reweighted regression.
    private static func timeWeightedRobustRegression(
        _ target: Double, _ targetTime: TimeInterval, _ points: [Point], _ weighting: Sibionics2CalibrationWeighting
    ) -> Double {
        let baseWeights = points.map {
            temporalWeight($0, targetTime, pastHalfLifeHours: 24, futureHalfLifeHours: 8, weighting)
        }
        guard var model = weightedLinearModel(points, baseWeights, slopeRange: 0.60...1.40) else {
            return target + weightedOffset(points, baseWeights)
        }
        var weights = baseWeights
        for _ in 0..<4 {
            let residuals = points.map { $0.y - model.predict($0.x) }
            let mad = max(median(residuals.map { abs($0) }), 0.05)
            let scale = max(mad * 1.4826, 0.05)
            weights = baseWeights.indices.map { index in
                let u = residuals[index] / (1.5 * scale)
                let robustWeight = abs(u) <= 1 ? 1 : 1 / abs(u)
                return max(baseWeights[index] * robustWeight, 1e-4)
            }
            model = weightedLinearModel(points, weights, slopeRange: 0.60...1.40) ?? model
        }
        let regression = model.predict(target)
        let offsetFallback = target + weightedOffset(points, weights)
        return regression.isFinite ? regression * 0.85 + offsetFallback * 0.15 : offsetFallback
    }

    /// Local proximity-weighted fit blended with the robust global trend.
    private static func elasticTimeWeightedInterpolation(
        _ target: Double, _ targetTime: TimeInterval, _ points: [Point], _ weighting: Sibionics2CalibrationWeighting
    ) -> Double {
        let localWeights = localProximityWeights(target, targetTime, points,
                                                 pastHalfLifeHours: 14, futureHalfLifeHours: 5, weighting)
        let localPrediction = weightedLinearModel(points, localWeights, slopeRange: 0.55...1.45)?.predict(target)
            ?? (target + weightedOffset(points, localWeights))
        let globalPrediction = timeWeightedRobustRegression(target, targetTime, points, weighting)
        let alpha = (0.35 + 0.55 * dominance(localWeights)).clamped(to: 0.35...0.90)
        var blended = localPrediction * alpha + globalPrediction * (1 - alpha)
        if let nearest = points.min(by: { abs($0.x - target) < abs($1.x - target) }) {
            let snap = (1 / (1 + abs(nearest.x - target) * 3)) * 0.20
            blended = blended * (1 - snap) + (target + nearest.y - nearest.x) * snap
        }
        return blended
    }

    /// Weighted blend of the four models above, favouring robust and local fits when they disagree.
    private static func adaptiveEnsemble(
        _ target: Double, _ targetTime: TimeInterval, _ points: [Point], _ weighting: Sibionics2CalibrationWeighting
    ) -> Double {
        let sane = saneWeightedOLS(target, targetTime, points, weighting)
        let xDrip = xDripMedianSlope(target, targetTime, points, weighting)
        let robust = timeWeightedRobustRegression(target, targetTime, points, weighting)
        let elastic = elasticTimeWeightedInterpolation(target, targetTime, points, weighting)
        let predictions = [sane, xDrip, robust, elastic]
        let center = median(predictions)
        let dispersion = max(predictions.map { abs($0 - center) }.reduce(0, +) / Double(predictions.count), 0.01)
        let harmony = (1 / (1 + dispersion)).clamped(to: 0.20...1.00)
        let localDominance = dominance(localProximityWeights(target, targetTime, points,
                                                             pastHalfLifeHours: 12, futureHalfLifeHours: 4, weighting))
        var wSane = 0.20, wXDrip = 0.15, wRobust = 0.30
        var wElastic = 0.35 + 0.20 * localDominance
        if harmony < 0.50 {
            wSane *= 0.85
            wXDrip *= 0.70
            wRobust *= 1.10
            wElastic *= 1.10
        }
        var blended = (sane * wSane + xDrip * wXDrip + robust * wRobust + elastic * wElastic)
            / (wSane + wXDrip + wRobust + wElastic)
        if let nearest = nearestByValueAndTime(points, target, targetTime) {
            let dx = abs(nearest.x - target)
            let dtHours = abs(nearest.time - targetTime) / hour
            let snap = (1 / (1 + dx * 2)) * (1 / (1 + dtHours / 6)) * 0.35
            blended = blended * (1 - snap) + (target + nearest.y - nearest.x) * snap
        }
        return blended
    }
}

struct Sibionics2AutoResetReading {
    let glucoseMgDl: Double
    let timeStamp: Date
}

struct Sibionics2AutoResetDecision {
    let resetNow: Bool
    let forced: Bool
}

enum Sibionics2AutoResetPolicy {
    private static let scheduledResetWindowLeadHours: Double = 4
    private static let forcedResetDeadlineGuardHours: Double = 4

    /// The normal reset window opens one day before the sensor profile expires.
    static let scheduledResetAgeDays = Sibionics2SensorProfile.expectedLifeInDays - 1
    static let resetWindowLeadHours = scheduledResetWindowLeadHours
    static let scheduledResetAge = TimeInterval(scheduledResetAgeDays) * Sibionics2Time.secondsPerDay
    static let resetWindowLead = resetWindowLeadHours * Sibionics2Time.secondsPerHour
    static let normalResetAge = scheduledResetAge - resetWindowLead
    static let expectedSensorLifeDays = Sibionics2SensorProfile.expectedLifeInDays
    static let expectedSensorLife = Sibionics2SensorProfile.expectedLife
    static let preExpiryGuardHours = forcedResetDeadlineGuardHours
    static let preExpiryGuard = preExpiryGuardHours * Sibionics2Time.secondsPerHour
    static let defaultEnabled = true

    private static let minimumComfortableMgDl = Sibionics2AutoResetReadingPolicy.minimumComfortableMgDl
    private static let maximumComfortableMgDl = Sibionics2AutoResetReadingPolicy.maximumComfortableMgDl
    private static let maximumRateMgDlPerMinute = Sibionics2AutoResetReadingPolicy.maximumRateMgDlPerMinute
    private static let maximumReadingAge = Sibionics2AutoResetReadingPolicy.maximumReadingAge
    private static let maximumReadingIntervalMinutes = Sibionics2AutoResetReadingPolicy.maximumReadingIntervalMinutes

    static func evaluate(
        now: Date,
        sensorStartDate: Date?,
        enabled: Bool,
        previous: Sibionics2AutoResetReading?,
        latest: Sibionics2AutoResetReading?
    ) -> Sibionics2AutoResetDecision {
        guard let sensorStartDate,
              sensorStartDate.timeIntervalSince1970.isFinite,
              now >= sensorStartDate else {
            return Sibionics2AutoResetDecision(resetNow: false, forced: false)
        }

        let age = now.timeIntervalSince(sensorStartDate)
        if age >= expectedSensorLife - preExpiryGuard {
            return Sibionics2AutoResetDecision(resetNow: true, forced: true)
        }
        guard enabled,
              age >= normalResetAge,
              let latest,
              latest.timeStamp <= now,
              now.timeIntervalSince(latest.timeStamp) <= maximumReadingAge,
              latest.glucoseMgDl.isFinite,
              (minimumComfortableMgDl...maximumComfortableMgDl).contains(latest.glucoseMgDl),
              let previous,
              previous.timeStamp < latest.timeStamp else {
            return Sibionics2AutoResetDecision(resetNow: false, forced: false)
        }

        let elapsedMinutes = latest.timeStamp.timeIntervalSince(previous.timeStamp) /
            Sibionics2Time.secondsPerMinute
        guard elapsedMinutes > 0, elapsedMinutes <= maximumReadingIntervalMinutes else {
            return Sibionics2AutoResetDecision(resetNow: false, forced: false)
        }
        let rate = (latest.glucoseMgDl - previous.glucoseMgDl) / elapsedMinutes
        return Sibionics2AutoResetDecision(
            resetNow: rate.isFinite && abs(rate) <= maximumRateMgDlPerMinute,
            forced: false
        )
    }
}

/// Sensor-scoped Sibionics controls. CoreBluetooth's UUID is used as the key;
/// it is stable on this iPhone and does not require the sensor MAC address.
enum Sibionics2Configuration {
    private static let prefix = "sibionics2.configuration."
    private static let latestReadingPrefix = "sibionics2.latestReading."
    private static let previousReadingPrefix = "sibionics2.previousReading."

    static func protocolMode(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics1ProtocolMode? {
        guard let key = key("protocolMode", identifier: identifier),
              userDefaults.object(forKey: key) != nil else { return nil }
        return Sibionics1ProtocolMode(rawValue: userDefaults.integer(forKey: key))
    }

    @discardableResult
    static func setProtocolMode(
        _ mode: Sibionics1ProtocolMode?,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key("protocolMode", identifier: identifier) else { return false }
        if let mode {
            userDefaults.set(mode.rawValue, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
        return true
    }

    static func calibrationMode(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics2CalibrationMode {
        guard let key = key("calibrationMode", identifier: identifier),
              let mode = Sibionics2CalibrationMode(rawValue: userDefaults.integer(forKey: key)) else {
            return Sibionics2CalibrationMode.defaultMode
        }
        return mode
    }

    @discardableResult
    static func setCalibrationMode(
        _ mode: Sibionics2CalibrationMode,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key("calibrationMode", identifier: identifier) else { return false }
        userDefaults.set(mode.rawValue, forKey: key)
        return true
    }

    /// Short code read from a scanned Sibionics sensor label.
    static func labelShortCode(for identifier: String, userDefaults: UserDefaults = .standard) -> String? {
        guard let key = key("labelShortCode", identifier: identifier),
              let code = userDefaults.string(forKey: key), code.count == 8 else { return nil }
        return code
    }

    static func setLabelShortCode(_ code: String?, for identifier: String, userDefaults: UserDefaults = .standard) {
        guard let key = key("labelShortCode", identifier: identifier) else { return }
        if let code, code.count == 8 {
            userDefaults.set(code, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// The V120 key group whose session produced readings for this sensor.
    static func confirmedKeyGroup(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics2KeyGroup? {
        guard let key = key("confirmedKeyGroup", identifier: identifier),
              userDefaults.object(forKey: key) != nil else { return nil }
        return Sibionics2KeyGroup(rawValue: userDefaults.integer(forKey: key))
    }

    static func setConfirmedKeyGroup(_ group: Sibionics2KeyGroup?, for identifier: String, userDefaults: UserDefaults = .standard) {
        guard let key = key("confirmedKeyGroup", identifier: identifier) else { return }
        if let group {
            userDefaults.set(group.rawValue, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    static func sibionics1Family(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics1Family {
        Sibionics1Family.resolve(
            protocolMode: protocolMode(for: identifier, userDefaults: userDefaults),
            keyGroup: confirmedKeyGroup(for: identifier, userDefaults: userDefaults)
        )
    }

    static func calibrationWeighting(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics2CalibrationWeighting {
        guard let key = key("calibrationWeighting", identifier: identifier),
              userDefaults.object(forKey: key) != nil,
              let weighting = Sibionics2CalibrationWeighting(rawValue: userDefaults.integer(forKey: key)) else {
            return .defaultWeighting
        }
        return weighting
    }

    @discardableResult
    static func setCalibrationWeighting(
        _ weighting: Sibionics2CalibrationWeighting,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key("calibrationWeighting", identifier: identifier) else { return false }
        userDefaults.set(weighting.rawValue, forKey: key)
        return true
    }

    static func autoResetEnabled(for identifier: String, userDefaults: UserDefaults = .standard) -> Bool {
        guard let key = key("autoReset", identifier: identifier) else { return false }
        guard userDefaults.object(forKey: key) != nil else {
            return Sibionics2AutoResetPolicy.defaultEnabled
        }
        return userDefaults.bool(forKey: key)
    }

    @discardableResult
    static func setAutoResetEnabled(
        _ enabled: Bool,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key("autoReset", identifier: identifier) else { return false }
        userDefaults.set(enabled, forKey: key)
        return true
    }

    static func probeCode(for identifier: String, userDefaults: UserDefaults = .standard) -> String? {
        guard let key = key("probeCode", identifier: identifier),
              let code = userDefaults.string(forKey: key) else { return nil }
        let normalized = normalizeProbeCode(code)
        return Sibionics2FactorySensitivity.decodeProbe(normalized) == nil ? nil : normalized
    }

    @discardableResult
    static func setProbeCode(
        _ code: String?,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key("probeCode", identifier: identifier) else { return false }
        let normalized = normalizeProbeCode(code ?? "")
        if normalized.isEmpty {
            userDefaults.removeObject(forKey: key)
            return true
        }
        guard Sibionics2FactorySensitivity.decodeProbe(normalized) != nil else { return false }
        userDefaults.set(normalized, forKey: key)
        return true
    }

    static func latestReading(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics2AutoResetReading? {
        reading(for: identifier, prefix: latestReadingPrefix, userDefaults: userDefaults)
    }

    static func previousReading(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics2AutoResetReading? {
        reading(for: identifier, prefix: previousReadingPrefix, userDefaults: userDefaults)
    }

    static func recordReading(_ reading: Sibionics2AutoResetReading, for identifier: String, userDefaults: UserDefaults = .standard) {
        guard let latestKey = compoundKey(latestReadingPrefix, identifier: identifier),
              let previousKey = compoundKey(previousReadingPrefix, identifier: identifier),
              reading.glucoseMgDl.isFinite, reading.glucoseMgDl > 0 else { return }
        if let latest = self.reading(for: identifier, prefix: latestReadingPrefix, userDefaults: userDefaults) {
            guard reading.timeStamp > latest.timeStamp else { return }
            userDefaults.set(latest.glucoseMgDl, forKey: previousKey + ".value")
            userDefaults.set(latest.timeStamp.timeIntervalSince1970, forKey: previousKey + ".time")
        }
        userDefaults.set(reading.glucoseMgDl, forKey: latestKey + ".value")
        userDefaults.set(reading.timeStamp.timeIntervalSince1970, forKey: latestKey + ".time")
    }

    static func resetRequested(for identifier: String, userDefaults: UserDefaults = .standard) -> Bool {
        bool("resetRequested", identifier: identifier, defaultValue: false, userDefaults: userDefaults)
    }

    static func requestReset(for identifier: String, userDefaults: UserDefaults = .standard) {
        setBool(true, name: "resetRequested", identifier: identifier, userDefaults: userDefaults)
    }

    static func clearResetRequest(for identifier: String, userDefaults: UserDefaults = .standard) {
        setBool(false, name: "resetRequested", identifier: identifier, userDefaults: userDefaults)
    }

    static func awaitingResetRestart(for identifier: String, userDefaults: UserDefaults = .standard) -> Bool {
        bool("awaitingResetRestart", identifier: identifier, defaultValue: false, userDefaults: userDefaults)
    }

    static func markResetSent(for identifier: String, userDefaults: UserDefaults = .standard) {
        clearResetRequest(for: identifier, userDefaults: userDefaults)
        setBool(true, name: "awaitingResetRestart", identifier: identifier, userDefaults: userDefaults)
        setBool(true, name: "probeAfterReset", identifier: identifier, userDefaults: userDefaults)
    }

    static func resetProbePending(for identifier: String, userDefaults: UserDefaults = .standard) -> Bool {
        bool("probeAfterReset", identifier: identifier, defaultValue: false, userDefaults: userDefaults)
    }

    static func clearResetRestart(for identifier: String, userDefaults: UserDefaults = .standard) {
        setBool(false, name: "awaitingResetRestart", identifier: identifier, userDefaults: userDefaults)
        setBool(false, name: "probeAfterReset", identifier: identifier, userDefaults: userDefaults)
        clearResetRequest(for: identifier, userDefaults: userDefaults)
    }

    private static func reading(for identifier: String, prefix: String, userDefaults: UserDefaults) -> Sibionics2AutoResetReading? {
        guard let key = compoundKey(prefix, identifier: identifier),
              let value = userDefaults.object(forKey: key + ".value") as? Double,
              let timestamp = userDefaults.object(forKey: key + ".time") as? Double,
              value.isFinite, value > 0, timestamp.isFinite else { return nil }
        return Sibionics2AutoResetReading(glucoseMgDl: value, timeStamp: Date(timeIntervalSince1970: timestamp))
    }

    private static func bool(_ name: String, identifier: String, defaultValue: Bool, userDefaults: UserDefaults) -> Bool {
        guard let key = key(name, identifier: identifier) else { return defaultValue }
        return userDefaults.object(forKey: key) == nil ? defaultValue : userDefaults.bool(forKey: key)
    }

    private static func setBool(_ value: Bool, name: String, identifier: String, userDefaults: UserDefaults) {
        guard let key = key(name, identifier: identifier) else { return }
        userDefaults.set(value, forKey: key)
    }

    private static func key(_ name: String, identifier: String) -> String? {
        guard let normalized = normalizedIdentifier(identifier) else { return nil }
        return prefix + name + "." + normalized
    }

    private static func compoundKey(_ keyPrefix: String, identifier: String) -> String? {
        guard let normalized = normalizedIdentifier(identifier) else { return nil }
        return keyPrefix + normalized
    }

    private static func normalizedIdentifier(_ identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeProbeCode(_ code: String) -> String {
        String(code.uppercased().filter { $0.isLetter || $0.isNumber })
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
