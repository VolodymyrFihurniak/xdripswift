import Foundation

enum Sibionics2CalibrationMode: Int, CaseIterable {
    case xDripPlus = 0
    case jugglucoNG = 1

    var title: String {
        switch self {
        case .xDripPlus: return Texts_BluetoothPeripheralView.sibionics2CalibrationXDripPlus
        case .jugglucoNG: return Texts_BluetoothPeripheralView.sibionics2CalibrationJugglucoNG
        }
    }
}

enum Sibionics2PollInterval: Int, CaseIterable {
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15

    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    var title: String {
        switch self {
        case .oneMinute: return Texts_BluetoothPeripheralView.sibionics2PollOneMinute
        case .fiveMinutes: return Texts_BluetoothPeripheralView.sibionics2PollFiveMinutes
        case .tenMinutes: return Texts_BluetoothPeripheralView.sibionics2PollTenMinutes
        case .fifteenMinutes: return Texts_BluetoothPeripheralView.sibionics2PollFifteenMinutes
        }
    }
}

struct Sibionics2CalibrationAnchor {
    let sensorMgDl: Double
    let fingerstickMgDl: Double
    let timeStamp: Date
}

/// Mirrors JugglucoNG's default single-point offset and fresh weighted-OLS
/// calibration profile for factory-corrected Sibionics glucose.
enum Sibionics2JugglucoCalibrationMath {
    private static let hour: TimeInterval = 60 * 60
    private static let pastHalfLifeHours = 18.0 * 0.45

    static func calibratedValue(_ value: Double, at timeStamp: Date, anchors: [Sibionics2CalibrationAnchor]) -> Double {
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
            let temporal = pow(0.5, ageHours / pastHalfLifeHours)
            return temporal * (anchor.timeStamp == newestTime ? 1.25 : 1)
        }

        let sumWeight = weights.reduce(0, +)
        guard sumWeight.isFinite, sumWeight > 1e-9 else { return value }
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
        if abs(denominator) > 1e-9 {
            let slope = ((sumWeight * sumWXY - sumWX * sumWY) / denominator).clamped(to: 0.65...1.35)
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
        let snap = (1 / (1 + glucoseDistance * 2.5)) * (1 / (1 + timeDistanceHours / 8)) * 0.25
        let anchorValue = value + nearest.fingerstickMgDl - nearest.sensorMgDl
        let calibrated = regression * (1 - snap) + anchorValue * snap
        return calibrated.isFinite ? calibrated.clamped(to: 0...1000) : value
    }

    private static func anchorDistance(_ anchor: Sibionics2CalibrationAnchor, value: Double, timeStamp: Date) -> Double {
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
    static let scheduledResetAge: TimeInterval = 22 * 24 * 60 * 60
    static let resetWindowLead: TimeInterval = 4 * 60 * 60
    static let normalResetAge: TimeInterval = scheduledResetAge - resetWindowLead
    static let expectedSensorLife: TimeInterval = 23 * 24 * 60 * 60
    static let preExpiryGuard: TimeInterval = 4 * 60 * 60
    private static let maximumReadingAge: TimeInterval = 10 * 60
    private static let minimumComfortableMgDl = 80.0
    private static let maximumComfortableMgDl = 180.0
    private static let maximumRateMgDlPerMinute = 2.0

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

        let elapsedMinutes = latest.timeStamp.timeIntervalSince(previous.timeStamp) / 60
        guard elapsedMinutes > 0, elapsedMinutes <= 15 else {
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
            return .xDripPlus
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
            return .oneMinute
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
        return userDefaults.object(forKey: key) == nil ? true : userDefaults.bool(forKey: key)
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
