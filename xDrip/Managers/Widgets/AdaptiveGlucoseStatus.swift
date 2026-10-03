import Foundation

/// Visual status only; the projection never enters the CGM pipeline.
enum AdaptiveGlucoseStatus: Equatable {
    case normal, warning, critical, stale, unavailable

    static func resolve(values: [Double], dates: [Date], urgentLow: Double, low: Double, high: Double, urgentHigh: Double, at date: Date, staleAfter: TimeInterval = 7 * 60) -> Self {
        guard urgentLow.isFinite, low.isFinite, high.isFinite, urgentHigh.isFinite,
              urgentLow <= low, low < high, high <= urgentHigh else { return .unavailable }
        guard let value = values.first, value.isFinite, value > 12,
              let readingDate = dates.first, readingDate <= date.addingTimeInterval(60) else { return .unavailable }
        guard date.timeIntervalSince(readingDate) < staleAfter else { return .stale }
        if value <= urgentLow || value >= urgentHigh { return .critical }
        if value <= low || value >= high { return .warning }
        // A short linear look-ahead is only a visual trend hint, never a delivered CGM value.
        let predictionHorizon: TimeInterval = 15 * 60
        if values.count > 1, dates.count > 1, values[1].isFinite, values[1] > 12 {
            let interval = readingDate.timeIntervalSince(dates[1])
            if interval >= 60, interval <= 10 * 60 {
                let projected = value + (value - values[1]) * predictionHorizon / interval
                if projected <= low || projected >= high { return .warning }
            }
        }
        return .normal
    }
}
