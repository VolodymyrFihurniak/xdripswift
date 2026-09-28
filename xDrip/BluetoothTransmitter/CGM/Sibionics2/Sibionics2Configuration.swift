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

/// Valid ranges for decoded V120 readings before they enter the correction algorithm.
enum Sibionics2ReadingValidationPolicy {
    static let minimumIndex = 1
    static let maximumIndex = Sibionics2V120ReadingFormat.maximumIndex
    static let maximumRawGlucoseMmol =
        Sibionics2V120ReadingFormat.maximumEncodedValue / Sibionics2V120ReadingFormat.measurementScale
    static let maximumTemperatureCelsius = 80.0
    static let minimumImpedance = 0
    static let maximumImpedance = Sibionics2V120ReadingFormat.maximumIndex
}

enum Sibionics2CalibrationMode: Int, CaseIterable {
    case xDripPlus = 0
    case jugglucoNG = 1

    static let defaultMode: Self = .xDripPlus
    private static let xDripPlusHistoryWindowInDays = 4

    var title: String {
        switch self {
        case .xDripPlus: return Texts_BluetoothPeripheralView.sibionics2CalibrationXDripPlus
        case .jugglucoNG: return Texts_BluetoothPeripheralView.sibionics2CalibrationJugglucoNG
        }
    }

    /// History used by both live glucose recalculation and new calibration creation.
    var calibrationHistoryDays: Int {
        switch self {
        case .xDripPlus: return Self.xDripPlusHistoryWindowInDays
        case .jugglucoNG: return Sibionics2SensorProfile.expectedLifeInDays
        }
    }
}

enum Sibionics2PollInterval: Int, CaseIterable {
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15

    static let defaultInterval: Self = .oneMinute
    var seconds: TimeInterval { TimeInterval(rawValue) * Sibionics2Time.secondsPerMinute }

    var title: String {
        switch self {
        case .oneMinute: return Texts_BluetoothPeripheralView.sibionics2PollOneMinute
        case .fiveMinutes: return Texts_BluetoothPeripheralView.sibionics2PollFiveMinutes
        case .tenMinutes: return Texts_BluetoothPeripheralView.sibionics2PollTenMinutes
        case .fifteenMinutes: return Texts_BluetoothPeripheralView.sibionics2PollFifteenMinutes
        }
    }
}

/// Retry, timeout, and cadence values for the Sibionics 2 BLE session lifecycle.
enum Sibionics2ConnectionPolicy {
    static let minimumScheduledDelay: TimeInterval = 1
    static let resetWriteRetryDelay: TimeInterval = 5
    static let resetRestartConfirmationDelay: TimeInterval = 15
    static let automaticResetRecheckInterval = Sibionics2PollInterval.fifteenMinutes.seconds

    static let streamingTimeout: TimeInterval = 75
    static let maximumHandshakeReconnectAttempts = 2

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
    static let maximumReadingIntervalMinutes: TimeInterval =
        TimeInterval(Sibionics2PollInterval.fifteenMinutes.rawValue)
}

struct Sibionics2CalibrationAnchor {
    let sensorMgDl: Double
    let fingerstickMgDl: Double
    let timeStamp: Date
}

/// Mirrors JugglucoNG's default single-point offset and fresh weighted-OLS
/// calibration profile for factory-corrected Sibionics glucose.
enum Sibionics2JugglucoCalibrationMath {
    private enum Profile {
        static let halfLifeRetention = 0.5
        static let recentAnchorHalfLifeHours: Double = 8.1
        static let latestAnchorWeightMultiplier = 1.25
        static let minimumStableWeight = 1e-9
        static let minimumRegressionDenominator = 1e-9
        static let regressionSlopeRange: ClosedRange<Double> = 0.65...1.35
        static let glucoseDistanceScale = 2.5
        static let timeDistanceScaleHours = 8.0
        static let maximumAnchorSnapContribution = 0.25
        static let calibratedValueRange: ClosedRange<Double> = 0...1000
    }

    private static let hour = Sibionics2Time.secondsPerHour

    static func calibratedValue(
        _ value: Double,
        at timeStamp: Date,
        anchors: [Sibionics2CalibrationAnchor]
    ) -> Double {
        guard value.isFinite, value > 0 else { return value }
        let usable = anchors
            .filter {
                $0.sensorMgDl.isFinite && $0.sensorMgDl > 0 &&
                    $0.fingerstickMgDl.isFinite && $0.fingerstickMgDl > 0 &&
                    $0.timeStamp <= timeStamp
            }
            .sorted { $0.timeStamp < $1.timeStamp }
        guard let latest = usable.last else { return value }
        if usable.count == 1 {
            return value + latest.fingerstickMgDl - latest.sensorMgDl
        }

        let newestTime = latest.timeStamp
        let weights = usable.map { anchor -> Double in
            let ageHours = max(0, timeStamp.timeIntervalSince(anchor.timeStamp) / hour)
            let temporal = pow(Profile.halfLifeRetention, ageHours / Profile.recentAnchorHalfLifeHours)
            let anchorWeight = anchor.timeStamp == newestTime
                ? Profile.latestAnchorWeightMultiplier
                : 1
            return temporal * anchorWeight
        }

        let sumWeight = weights.reduce(0, +)
        guard sumWeight.isFinite, sumWeight > Profile.minimumStableWeight else { return value }
        let sumWX = zip(usable, weights).reduce(0) { $0 + $1.0.sensorMgDl * $1.1 }
        let sumWY = zip(usable, weights).reduce(0) { $0 + $1.0.fingerstickMgDl * $1.1 }
        let sumWXY = zip(usable, weights).reduce(0) {
            $0 + $1.0.sensorMgDl * $1.0.fingerstickMgDl * $1.1
        }
        let sumWX2 = zip(usable, weights).reduce(0) {
            $0 + $1.0.sensorMgDl * $1.0.sensorMgDl * $1.1
        }
        let denominator = sumWeight * sumWX2 - sumWX * sumWX
        let regression: Double
        if abs(denominator) > Profile.minimumRegressionDenominator {
            let slope = ((sumWeight * sumWXY - sumWX * sumWY) / denominator)
                .clamped(to: Profile.regressionSlopeRange)
            let intercept = (sumWY - slope * sumWX) / sumWeight
            regression = slope * value + intercept
        } else {
            let offset = zip(usable, weights).reduce(0) {
                $0 + ($1.0.fingerstickMgDl - $1.0.sensorMgDl) * $1.1
            } / sumWeight
            regression = value + offset
        }

        guard let nearest = usable.min(by: {
            anchorDistance($0, value: value, timeStamp: timeStamp)
                < anchorDistance($1, value: value, timeStamp: timeStamp)
        }) else { return regression }
        let glucoseDistance = abs(nearest.sensorMgDl - value)
        let timeDistanceHours = abs(nearest.timeStamp.timeIntervalSince(timeStamp)) / hour
        let glucoseProximity = 1 / (1 + glucoseDistance * Profile.glucoseDistanceScale)
        let timeProximity = 1 / (1 + timeDistanceHours / Profile.timeDistanceScaleHours)
        let snap = glucoseProximity * timeProximity * Profile.maximumAnchorSnapContribution
        let anchorValue = value + nearest.fingerstickMgDl - nearest.sensorMgDl
        let calibrated = regression * (1 - snap) + anchorValue * snap
        return calibrated.isFinite ? calibrated.clamped(to: Profile.calibratedValueRange) : value
    }

    private static func anchorDistance(
        _ anchor: Sibionics2CalibrationAnchor,
        value: Double,
        timeStamp: Date
    ) -> Double {
        abs(anchor.sensorMgDl - value) + abs(anchor.timeStamp.timeIntervalSince(timeStamp)) / hour
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
    // Both reset boundaries currently use the same four-hour safety margin,
    // while remaining separate policies for scheduled and forced reset.
    private static let resetDeadlineMarginHours: Double = 4

    /// The normal reset window opens one day before the sensor profile expires.
    static let scheduledResetAgeDays = Sibionics2SensorProfile.expectedLifeInDays - 1
    static let resetWindowLeadHours = resetDeadlineMarginHours
    static let scheduledResetAge = TimeInterval(scheduledResetAgeDays) * Sibionics2Time.secondsPerDay
    static let resetWindowLead = resetWindowLeadHours * Sibionics2Time.secondsPerHour
    static let normalResetAge = scheduledResetAge - resetWindowLead
    static let expectedSensorLifeDays = Sibionics2SensorProfile.expectedLifeInDays
    static let expectedSensorLife = Sibionics2SensorProfile.expectedLife
    static let preExpiryGuardHours = resetDeadlineMarginHours
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

    static func pollInterval(for identifier: String, userDefaults: UserDefaults = .standard) -> Sibionics2PollInterval {
        guard let key = key("pollInterval", identifier: identifier),
              userDefaults.object(forKey: key) != nil,
              let interval = Sibionics2PollInterval(rawValue: userDefaults.integer(forKey: key)) else {
            return Sibionics2PollInterval.defaultInterval
        }
        return interval
    }

    @discardableResult
    static func setPollInterval(
        _ interval: Sibionics2PollInterval,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key("pollInterval", identifier: identifier) else { return false }
        userDefaults.set(interval.rawValue, forKey: key)
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
