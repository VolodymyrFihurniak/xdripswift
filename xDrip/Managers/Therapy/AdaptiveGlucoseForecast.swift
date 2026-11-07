//
//  AdaptiveGlucoseForecast.swift
//  xdrip
//
//  The adaptive ("personal") glucose forecast, ported from JugglucoNG (GPL-3.0, see
//  THIRD_PARTY_NOTICES.md): `data/prediction/AdaptiveGlucoseForecast.kt` for the model and
//  `data/prediction/analysis/AdaptivePredictionStore.kt` for when it is trained and how its
//  answer becomes a forecast line.
//
//  What it learns, per horizon, is how much of the recent movement tends to carry on for this
//  person on their sensors, and how strongly glucose drifts back toward their own recent
//  average: one ridge regression per horizon over eight features from CGM history. It does not
//  read treatments, and it never decides anything clinical: the predicted low alert and the
//  Nightscout forecast keep using the standard model.
//

import Foundation
import CoreData

// MARK: - History

/// CGM history as the adaptive forecast reads it: ascending readings in mg/dL, each tagged with
/// the sensor segment it belongs to (JugglucoNG `AdaptiveHistory`).
///
/// A value is only ever read inside one segment: interpolating across a sensor change would make
/// the jump between two sensors look like a glucose movement.
struct AdaptiveHistory: Sendable {
    /// Seconds since 1970, ascending.
    let times: [TimeInterval]
    let mgDl: [Double]
    let segment: [Int]
    /// The longest gap a value is interpolated across: 2.5 readings, at least 6 minutes.
    let maximumGap: TimeInterval
    private let prefix: [Double]

    init(times: [TimeInterval], mgDl: [Double], segment: [Int]) {
        precondition(times.count == mgDl.count && times.count == segment.count)
        self.times = times
        self.mgDl = mgDl
        self.segment = segment
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        let cadence = gaps.isEmpty ? 5 * 60 : gaps[gaps.count / 2]
        maximumGap = max(6 * 60, cadence * 2.5)
        var sums = [Double](repeating: 0, count: mgDl.count + 1)
        for index in mgDl.indices { sums[index + 1] = sums[index] + mgDl[index] }
        prefix = sums
    }

    var count: Int { times.count }

    /// Last index with time ≤ `t`.
    func indexAtOrBefore(_ t: TimeInterval) -> Int? {
        var low = 0, high = times.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if times[middle] <= t { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return found
    }

    /// First index with time ≥ `t`, or `count`.
    private func indexAtOrAfter(_ t: TimeInterval) -> Int {
        var low = 0, high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < t { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// mg/dL at `t` inside the segment, interpolated across at most `maximumGap`.
    func value(at t: TimeInterval, segment id: Int) -> Double? {
        guard let index = indexAtOrBefore(t), segment[index] == id else { return nil }
        if times[index] == t { return mgDl[index] }
        guard index + 1 < count, segment[index + 1] == id else { return nil }
        let t0 = times[index], t1 = times[index + 1]
        guard t1 - t0 <= maximumGap else { return nil }
        return mgDl[index] + (mgDl[index + 1] - mgDl[index]) * ((t - t0) / (t1 - t0))
    }

    /// Whether the segment has readings across all of `from...to` with no gap longer than
    /// `maximumGap`: five spot lookups can each find a value while a hole sits between them.
    func isContinuous(from: TimeInterval, to: TimeInterval, segment id: Int) -> Bool {
        guard let first = indexAtOrBefore(from), let last = indexAtOrBefore(to), last >= first else { return false }
        for index in first...last {
            if segment[index] != id { return false }
            if index > first && times[index] - times[index - 1] > maximumGap { return false }
        }
        return true
    }

    /// Mean of the readings in `from...to`, all sensors.
    func mean(from: TimeInterval, to: TimeInterval) -> Double? {
        guard let high = indexAtOrBefore(to) else { return nil }
        let low = indexAtOrAfter(from)
        guard low <= high else { return nil }
        return (prefix[high + 1] - prefix[low]) / Double(high + 1 - low)
    }

    /// Builds the history from parallel lists, starting a new segment wherever the sensor changes.
    /// Non-finite and implausible values are dropped; equal timestamps keep the first.
    static func of(times: [TimeInterval], mgDl: [Double], sensors: [String?]) -> AdaptiveHistory {
        let order = times.indices.sorted { times[$0] != times[$1] ? times[$0] < times[$1] : $0 < $1 }
        var keptTimes: [TimeInterval] = [], keptValues: [Double] = [], keptSegments: [Int] = []
        var segmentID = -1
        var lastSensor: String?
        for index in order {
            let value = mgDl[index]
            if !value.isFinite || value < 10 || value > 700 { continue }
            if let last = keptTimes.last, last == times[index] { continue }
            let sensor = index < sensors.count ? sensors[index] : nil
            if segmentID < 0 || sensor != lastSensor {
                segmentID += 1
                lastSensor = sensor
            }
            keptTimes.append(times[index])
            keptValues.append(value)
            keptSegments.append(segmentID)
        }
        return AdaptiveHistory(times: keptTimes, mgDl: keptValues, segment: keptSegments)
    }
}

// MARK: - Model

/// A fitted personal forecast: one ridge regression per horizon, predicting the change from the
/// current reading (JugglucoNG `AdaptiveForecastModel`).
struct AdaptiveForecastModel: Codable, Hashable, Sendable {
    let version: Int
    let trainedAt: Date
    /// Horizons in minutes, ascending; the forecast has one point per horizon.
    let horizons: [Int]
    let means: [Double]
    let scales: [Double]
    /// Intercept followed by one weight per feature, or nil when the horizon had too little data.
    let weights: [[Double]?]
    /// Training rows behind the 30-minute horizon: the size of the personal evidence.
    let trainingRows: Int
    /// Days of history the training window covered.
    let trainingDays: Double
    /// 30-minute holdout error of this model and of "no change" on the most recent days, mg/dL;
    /// nil when there was not enough history to hold any back.
    let holdoutRMSE: Double?
    let holdoutNoChangeRMSE: Double?

    /// Whether the model earned its place on held-back recent data. A model that could not be
    /// checked yet counts as reliable; one that lost to "no change" does not.
    var isReliable: Bool {
        guard let holdoutRMSE, let holdoutNoChangeRMSE else { return true }
        return holdoutRMSE <= holdoutNoChangeRMSE * AdaptiveGlucoseForecast.reliabilityMargin
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// A stored model, or nil when there is none or it was fitted by another model version.
    static func decode(_ data: Data?) -> AdaptiveForecastModel? {
        guard let data, let model = try? JSONDecoder().decode(AdaptiveForecastModel.self, from: data),
              model.version == AdaptiveGlucoseForecast.modelVersion, model.weights.count == model.horizons.count,
              model.means.count == AdaptiveGlucoseForecast.featureCount, model.scales.count == AdaptiveGlucoseForecast.featureCount,
              model.weights.allSatisfy({ $0 == nil || $0?.count == AdaptiveGlucoseForecast.featureCount + 1 }) else { return nil }
        return model
    }
}

// MARK: - Fitting and forecasting

/// JugglucoNG `AdaptiveGlucoseForecast`. Eight features, all from CGM history: the change over
/// the last 5, 15, 30 and 60 minutes, the distance from the trailing 24-hour mean, the level, and
/// the time of day. On JugglucoNG's benchmark it beat "no change" for every person on Dexcom G6
/// (median −12 % RMSE at 30 minutes) and on 15-minute Libre 2 (−16 %).
enum AdaptiveGlucoseForecast {
    static let modelVersion = 1
    static let featureCount = 8
    /// One point every 5 minutes out to two hours.
    static let horizons = (1...24).map { $0 * 5 }
    /// Two days of rows on the 5-minute grid.
    static let minimumTrainingRows = 576
    static let trainingWindowDays = 28
    static let holdoutDays = 2
    /// A holdout check needs this much history before the held-back days.
    static let minimumDaysForHoldout = 4
    /// A model may be this much worse than "no change" on holdout and still be used.
    static let reliabilityMargin = 1.02

    private static let lambda = 1.0
    private static let grid: TimeInterval = 5 * 60
    private static let day: TimeInterval = 24 * 60 * 60

    private static func floorMod(_ x: Double, _ y: Double) -> Double { x - (x / y).rounded(.down) * y }

    /// The feature vector at `t`, or nil when the hour behind `t` is not covered by one sensor or
    /// `t` itself has no reading.
    static func features(_ history: AdaptiveHistory, at t: TimeInterval, timeZone: TimeZone) -> [Double]? {
        guard let index = history.indexAtOrBefore(t) else { return nil }
        let segment = history.segment[index]
        guard let v0 = history.value(at: t, segment: segment),
              let v5 = history.value(at: t - 5 * 60, segment: segment),
              let v15 = history.value(at: t - 15 * 60, segment: segment),
              let v30 = history.value(at: t - 30 * 60, segment: segment),
              let v60 = history.value(at: t - 60 * 60, segment: segment),
              let mean = history.mean(from: t - day, to: t),
              history.isContinuous(from: t - 60 * 60, to: t, segment: segment) else { return nil }
        let offset = TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: t)))
        let timeOfDay = 2 * Double.pi * (floorMod(t + offset, day) / day)
        return [v0 - v5, v0 - v15, v0 - v30, v0 - v60, v0 - mean, v0, sin(timeOfDay), cos(timeOfDay)]
    }

    /// Fits a model on `history` as of `now`. Only outcomes at or before `now` are used, so a
    /// replay that hands this the past alone gets exactly what the phone would have learned.
    /// Nil with fewer than `minimumTrainingRows` usable rows.
    static func fit(_ history: AdaptiveHistory, now: Date, timeZone: TimeZone = .current) -> AdaptiveForecastModel? {
        let nowSeconds = now.timeIntervalSince1970
        let rows = trainingRows(history, now: nowSeconds, timeZone: timeZone)
        guard rows.count30 >= minimumTrainingRows, let firstRow = rows.times.first else { return nil }
        let spanDays = (nowSeconds - firstRow) / day

        // Hold the most recent days back once, to check the model against "no change".
        var holdoutRMSE: Double?
        var holdoutNoChangeRMSE: Double?
        if spanDays >= Double(minimumDaysForHoldout) {
            let cut = nowSeconds - Double(holdoutDays) * day
            // Training rows whose outcome lies past the cut would see the holdout.
            let longest = Double(horizons.last ?? 120) * 60
            if let early = solve(rows, mask: rows.times.map { $0 + longest <= cut }), let k30 = horizons.firstIndex(of: 30) {
                var squaredError = 0.0, squaredNoChange = 0.0, count = 0
                for row in rows.times.indices where rows.times[row] >= cut {
                    guard let target = rows.targets[row][k30], let predicted = early.predictDelta(rows.features[row], horizon: k30) else { continue }
                    squaredError += (predicted - target) * (predicted - target)
                    squaredNoChange += target * target
                    count += 1
                }
                if count >= 100 {
                    holdoutRMSE = sqrt(squaredError / Double(count))
                    holdoutNoChangeRMSE = sqrt(squaredNoChange / Double(count))
                }
            }
        }
        guard let full = solve(rows, mask: rows.times.map { _ in true }) else { return nil }
        return AdaptiveForecastModel(version: modelVersion, trainedAt: now, horizons: horizons, means: full.means, scales: full.scales,
                                     weights: full.weights, trainingRows: rows.count30, trainingDays: spanDays,
                                     holdoutRMSE: holdoutRMSE, holdoutNoChangeRMSE: holdoutNoChangeRMSE)
    }

    /// The forecast at `origin` as changes from the reading there, one per horizon (nil where the
    /// model has no weights), or nil when the features cannot be formed: a new sensor's first
    /// hour, a gap, no reading at `origin`.
    static func forecastDeltas(_ model: AdaptiveForecastModel, history: AdaptiveHistory, origin: Date,
                               timeZone: TimeZone = .current) -> [Double?]? {
        guard let features = features(history, at: origin.timeIntervalSince1970, timeZone: timeZone) else { return nil }
        let fitted = Fitted(means: model.means, scales: model.scales, weights: model.weights)
        return model.horizons.indices.map { fitted.predictDelta(features, horizon: $0) }
    }

    /// The forecast line from `baseline`: its reading plus each change, up to `horizonMinutes`
    /// (at most two hours), with the standard forecast's confidence ramp (`pointsFrom`).
    static func points(baseline: (date: Date, mgDl: Double), deltas: [Double?], horizons: [Int],
                       horizonMinutes: Int) -> [GlucosePredictionPoint]? {
        let limit = min(max(horizonMinutes, 30), horizons.last ?? 120)
        var points = [GlucosePredictionPoint(date: baseline.date, value: baseline.mgDl, confidence: 1, unclampedValue: baseline.mgDl)]
        for (index, minutes) in horizons.enumerated() {
            if minutes > limit { break }
            guard index < deltas.count, let delta = deltas[index], delta.isFinite else { continue }
            let projected = baseline.mgDl + delta
            let confidence = min(max(0.88 - 0.62 * sqrt(Double(minutes) / Double(limit)), 0.18), 0.88)
            points.append(GlucosePredictionPoint(date: baseline.date.addingTimeInterval(TimeInterval(minutes * 60)),
                                                 value: min(max(projected, 18), 540), confidence: confidence, unclampedValue: projected))
        }
        return points.count >= 2 ? points : nil
    }

    // MARK: Training rows

    private struct Rows {
        var times: [TimeInterval] = []
        var features: [[Double]] = []
        /// targets[row][k]: change at horizons[k], nil where unobserved.
        var targets: [[Double?]] = []

        var count30: Int {
            guard let k30 = AdaptiveGlucoseForecast.horizons.firstIndex(of: 30) else { return 0 }
            return targets.reduce(0) { $0 + ($1[k30] == nil ? 0 : 1) }
        }
    }

    private static func trainingRows(_ history: AdaptiveHistory, now: TimeInterval, timeZone: TimeZone) -> Rows {
        var rows = Rows()
        guard let firstReading = history.times.first else { return rows }
        let first = max(firstReading + 60 * 60, now - Double(trainingWindowDays) * day)
        var t = first - floorMod(first, grid) + grid
        let last = now - Double(horizons.first ?? 5) * 60
        while t <= last {
            if let features = features(history, at: t, timeZone: timeZone), let index = history.indexAtOrBefore(t) {
                let segment = history.segment[index]
                let level = features[5]
                rows.times.append(t)
                rows.features.append(features)
                rows.targets.append(horizons.map { minutes in
                    let target = t + Double(minutes) * 60
                    guard target <= now, let value = history.value(at: target, segment: segment) else { return nil }
                    return value - level
                })
            }
            t += grid
        }
        return rows
    }

    // MARK: Ridge regression

    private struct Fitted {
        let means: [Double]
        let scales: [Double]
        let weights: [[Double]?]

        func predictDelta(_ features: [Double], horizon k: Int) -> Double? {
            guard k < weights.count, let w = weights[k] else { return nil }
            var y = w[0]
            for c in 0..<AdaptiveGlucoseForecast.featureCount { y += w[c + 1] * (features[c] - means[c]) / scales[c] }
            return y
        }
    }

    private static func solve(_ rows: Rows, mask: [Bool]) -> Fitted? {
        let used = rows.times.indices.filter { mask[$0] }
        guard !used.isEmpty else { return nil }
        var means = [Double](repeating: 0, count: featureCount)
        var scales = [Double](repeating: 1, count: featureCount)
        for c in 0..<featureCount {
            let mean = used.reduce(0) { $0 + rows.features[$1][c] } / Double(used.count)
            let variance = used.reduce(0) { $0 + (rows.features[$1][c] - mean) * (rows.features[$1][c] - mean) } / Double(used.count)
            let sd = sqrt(variance)
            means[c] = mean
            scales[c] = sd > 1e-9 ? sd : 1
        }
        let weights: [[Double]?] = horizons.indices.map { k in
            let ok = used.filter { rows.targets[$0][k] != nil }
            guard ok.count >= minimumTrainingRows else { return nil }
            let yMean = ok.reduce(0) { $0 + (rows.targets[$1][k] ?? 0) } / Double(ok.count)
            var a = [[Double]](repeating: [Double](repeating: 0, count: featureCount), count: featureCount)
            var b = [Double](repeating: 0, count: featureCount)
            var x = [Double](repeating: 0, count: featureCount)
            for row in ok {
                for c in 0..<featureCount { x[c] = (rows.features[row][c] - means[c]) / scales[c] }
                let y = (rows.targets[row][k] ?? 0) - yMean
                for i in 0..<featureCount {
                    b[i] += x[i] * y
                    for j in 0..<featureCount { a[i][j] += x[i] * x[j] }
                }
            }
            for i in 0..<featureCount { a[i][i] += lambda }
            return [yMean] + gaussianSolve(a, b)
        }
        guard weights.contains(where: { $0 != nil }) else { return nil }
        return Fitted(means: means, scales: scales, weights: weights)
    }

    /// Gaussian elimination with partial pivoting for the small symmetric positive-definite systems above.
    static func gaussianSolve(_ a: [[Double]], _ b: [Double]) -> [Double] {
        let n = b.count
        var m = (0..<n).map { a[$0] + [b[$0]] }
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(m[row][column]) > abs(m[pivot][column]) { pivot = row }
            m.swapAt(column, pivot)
            let p = m[column][column]
            if abs(p) < 1e-12 { continue }
            for row in (column + 1)..<max(column + 1, n) {
                let factor = m[row][column] / p
                for c in column...n { m[row][c] -= factor * m[column][c] }
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = m[row][n]
            for c in (row + 1)..<max(row + 1, n) { s -= m[row][c] * x[c] }
            x[row] = abs(m[row][row]) < 1e-12 ? 0 : s / m[row][row]
        }
        return x
    }
}

// MARK: - Readings

/// Readings as loaded for the adaptive forecast, before they become an `AdaptiveHistory`.
struct AdaptiveReadings: Sendable {
    var times: [TimeInterval] = []
    var mgDl: [Double] = []
    var sensors: [String?] = []

    var history: AdaptiveHistory { AdaptiveHistory.of(times: times, mgDl: mgDl, sensors: sensors) }

    /// Adds the chart's readings that are newer than the last stored one (the store can lag the
    /// chart by a moment after a reading arrives), as readings of the newest sensor.
    mutating func appendNewer(dates: [Date], values: [Double], until now: Date) {
        let newest = times.last ?? -.infinity
        let sensor = sensors.last ?? nil
        for (date, value) in zip(dates, values).sorted(by: { $0.0 < $1.0 })
        where date.timeIntervalSince1970 > newest && date <= now {
            times.append(date.timeIntervalSince1970)
            mgDl.append(value)
            sensors.append(sensor)
        }
    }
}

// MARK: - Store

/// The phone's adaptive forecast: the fitted model and when to refresh it (JugglucoNG
/// `AdaptivePredictionStore`). Nothing runs on its own schedule: a fit starts on a background
/// queue when something asks for the model and it is missing or a day old (a new reading, or the
/// chart while the adaptive forecast is shown); a failed or empty fit is retried after six hours.
/// One model per person, not per sensor: it learns from every sensor of the last four weeks, and
/// its features never read across a sensor change, so a new sensor starts with what the old ones
/// taught.
enum AdaptiveForecastStore {
    static let modelKey = "experimentalAdaptiveForecastModel"
    static let lastAttemptKey = "experimentalAdaptiveForecastLastAttempt"
    static let refitAfter: TimeInterval = 24 * 60 * 60
    static let retryAfter: TimeInterval = 6 * 60 * 60
    /// Enough history for the 24-hour mean and the hour of features behind the newest reading.
    static let recentSpan: TimeInterval = 25 * 60 * 60

    private static let queue = DispatchQueue(label: "prediction.adaptive", qos: .utility)
    private static let lock = NSLock()
    private static var isFitting = false
    private static var cache: (data: Data, model: AdaptiveForecastModel?)?

    /// The model's state, for the settings row.
    enum Status: Equatable {
        case learning
        case ready(trainingDays: Double, trainedAt: Date)
        /// It lost to "no change" on its own recent holdout, so the fallback is drawn instead.
        case notBetter(trainingDays: Double)
    }

    static func model(defaults: UserDefaults = .standard) -> AdaptiveForecastModel? {
        guard let data = defaults.data(forKey: modelKey) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache, cached.data == data { return cached.model }
        let model = AdaptiveForecastModel.decode(data)
        cache = (data, model)
        return model
    }

    static func status(defaults: UserDefaults = .standard) -> Status {
        guard let model = model(defaults: defaults) else { return .learning }
        return model.isReliable ? .ready(trainingDays: model.trainingDays, trainedAt: model.trainedAt) : .notBetter(trainingDays: model.trainingDays)
    }

    /// Forgets the model; the next request trains a new one.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: modelKey)
        defaults.removeObject(forKey: lastAttemptKey)
    }

    /// Whether anything needs the model: the adaptive forecast is drawn or forecasts are scored.
    static func isNeeded(defaults: UserDefaults = .standard) -> Bool {
        defaults.experimentalPredictionAdaptive || defaults.experimentalPredictionAccuracyEnabled
    }

    /// Starts a fit on the background queue when one is due. Never blocks the caller.
    static func refreshIfDue(coreDataManager: CoreDataManager, defaults: UserDefaults = .standard, now: Date = Date()) {
        guard isNeeded(defaults: defaults) else { return }
        let due: Bool
        if let current = model(defaults: defaults) {
            due = now.timeIntervalSince(current.trainedAt) >= refitAfter
        } else if let attempt = defaults.object(forKey: lastAttemptKey) as? Date {
            due = now.timeIntervalSince(attempt) >= retryAfter
        } else {
            due = true
        }
        guard due else { return }
        lock.lock()
        guard !isFitting else { lock.unlock(); return }
        isFitting = true
        lock.unlock()
        defaults.set(now, forKey: lastAttemptKey)
        let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator
        queue.async {
            defer { lock.lock(); isFitting = false; lock.unlock() }
            let span = TimeInterval(AdaptiveGlucoseForecast.trainingWindowDays + 1) * 24 * 60 * 60
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            var readings: AdaptiveReadings?
            context.performAndWait { readings = fetchReadings(in: context, from: now.addingTimeInterval(-span), to: now) }
            guard let readings, let model = AdaptiveGlucoseForecast.fit(readings.history, now: now), let data = model.encoded() else { return }
            defaults.set(data, forKey: modelKey)
        }
    }

    /// The readings of `from...to` as the model reads them: the displayed value (`finalValue`),
    /// tagged with their sensor. Call on `context`'s queue.
    static func fetchReadings(in context: NSManagedObjectContext, from: Date, to: Date) -> AdaptiveReadings? {
        let request = NSFetchRequest<NSDictionary>(entityName: "BgReading")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["timeStamp", "calculatedValue", "adjustedValue", "smoothedValue", "sensor"]
        request.predicate = NSPredicate(format: "timeStamp > %@ AND timeStamp <= %@ AND isSuppressedByFiveMinuteCadence == NO",
                                        from as NSDate, to as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timeStamp", ascending: true)]
        guard let rows = try? context.fetch(request) else { return nil }
        var readings = AdaptiveReadings()
        for row in rows {
            guard let date = row["timeStamp"] as? Date, let calculated = row["calculatedValue"] as? Double, calculated != 0 else { continue }
            // BgReading.finalValue: smoothed, else adjusted, else calculated.
            let value = (row["smoothedValue"] as? NSNumber)?.doubleValue ?? (row["adjustedValue"] as? NSNumber)?.doubleValue ?? calculated
            readings.times.append(date.timeIntervalSince1970)
            readings.mgDl.append(value)
            readings.sensors.append((row["sensor"] as? NSManagedObjectID)?.uriRepresentation().absoluteString)
        }
        return readings
    }

    /// The last day of readings, for a forecast, on a background context.
    static func recentReadings(coreDataManager: CoreDataManager, now: Date) async -> AdaptiveReadings? {
        let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator
        return await withCheckedContinuation { continuation in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.perform {
                continuation.resume(returning: fetchReadings(in: context, from: now.addingTimeInterval(-recentSpan), to: now))
            }
        }
    }

    /// The last day of readings on the main context, for callers already on the main queue.
    static func recentReadingsOnMainContext(coreDataManager: CoreDataManager, now: Date) -> AdaptiveReadings? {
        var readings: AdaptiveReadings?
        let context = coreDataManager.mainManagedObjectContext
        context.performAndWait { readings = fetchReadings(in: context, from: now.addingTimeInterval(-recentSpan), to: now) }
        return readings
    }

    /// Draws the adaptive forecast when it can answer, else the standard forecast without the
    /// trend momentum: on JugglucoNG's benchmark that fallback never did worse than "no change".
    /// Returns the forecast and whether it is the adaptive one.
    static func shownForecast(readings: AdaptiveReadings?, standard: (_ trendMomentum: Bool) -> [GlucosePredictionPoint],
                              horizonMinutes: Int, defaults: UserDefaults = .standard, now: Date = Date()) -> (points: [GlucosePredictionPoint], isAdaptive: Bool) {
        if let readings, let adaptive = forecast(history: readings.history, horizonMinutes: horizonMinutes, defaults: defaults, now: now) {
            return (adaptive, true)
        }
        return (standard(false), false)
    }

    /// The adaptive forecast from the newest reading of `history`, or nil when it cannot answer:
    /// no reliable model yet, or the last hour does not support the features. The caller then
    /// draws the fallback.
    static func forecast(history: AdaptiveHistory, horizonMinutes: Int, defaults: UserDefaults = .standard, now: Date = Date(),
                         timeZone: TimeZone = .current) -> [GlucosePredictionPoint]? {
        guard let model = model(defaults: defaults), model.isReliable, let last = history.times.last,
              now.timeIntervalSince1970 - last <= ExperimentalPredictionModel.maximumBaselineAge,
              let baselineValue = history.mgDl.last else { return nil }
        let origin = Date(timeIntervalSince1970: last)
        guard let deltas = AdaptiveGlucoseForecast.forecastDeltas(model, history: history, origin: origin, timeZone: timeZone) else { return nil }
        return AdaptiveGlucoseForecast.points(baseline: (origin, baselineValue), deltas: deltas, horizons: model.horizons, horizonMinutes: horizonMinutes)
    }
}
