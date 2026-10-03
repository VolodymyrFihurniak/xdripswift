import Foundation
import SwiftUI
import WidgetKit

/// One widget configuration, with an appearance derived from the patient's limits.
@available(iOSApplicationExtension 17.0, *)
struct AdaptiveStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "adaptiveStatusWidget", provider: AdaptiveStatusProvider()) { entry in
            AdaptiveStatusView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Adaptive Status")
        .description(Text("adaptive_description", tableName: "Common"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct AdaptiveStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> XDripWidget.Entry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (XDripWidget.Entry) -> Void) {
        completion(context.isPreview ? .placeholder : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<XDripWidget.Entry>) -> Void) {
        let entry = currentEntry()
        // Explicit entries age the reading even when the main app stops delivering data.
        var dates = (0...20).map { entry.date.addingTimeInterval(Double($0) * 60) }
        if let readingDate = entry.widgetState.bgReadingDate {
            for interval in [ConstantsWidgetExtension.bgReadingDateStaleInMinutes, ConstantsWidgetExtension.bgReadingDateVeryStaleInMinutes] {
                let deadline = readingDate.addingTimeInterval(interval)
                if deadline > entry.date { dates.append(deadline) }
            }
        }
        let entries = Set(dates).sorted().map { XDripWidget.Entry(date: $0, widgetState: entry.widgetState) }
        completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(20 * 60))))
    }

    private func currentEntry() -> XDripWidget.Entry {
        let empty = XDripWidget.Entry.WidgetState(followerPatientName: nil)
        guard let defaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName),
              let encodedData = defaults.data(forKey: WidgetSharedUserDefaultsModel.widgetDataKey(for: Bundle.main.mainAppBundleIdentifier)),
              let data = try? JSONDecoder().decode(WidgetSharedUserDefaultsModel.self, from: encodedData) else {
            // Never display sample data as a real glucose reading.
            return .init(date: .now, widgetState: empty)
        }
        let state = XDripWidget.Entry.WidgetState(
            bgReadingValues: data.bgReadingValues,
            bgReadingDates: data.bgReadingDatesAsDouble.map { Date(timeIntervalSince1970: $0) },
            isMgDl: data.isMgDl, slopeOrdinal: data.slopeOrdinal,
            deltaValueInUserUnit: data.deltaValueInUserUnit,
            urgentLowLimitInMgDl: data.urgentLowLimitInMgDl, lowLimitInMgDl: data.lowLimitInMgDl,
            highLimitInMgDl: data.highLimitInMgDl, urgentHighLimitInMgDl: data.urgentHighLimitInMgDl,
            followerPatientName: data.followerPatientName
        )
        return .init(date: .now, widgetState: state)
    }
}

private extension AdaptiveGlucoseStatus {

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .stale, .unavailable: return .gray
        }
    }

    var title: String {
        switch self {
        case .normal: return localized("adaptive_normal", "In range")
        case .warning: return localized("adaptive_warning", "Trend / out of range")
        case .critical: return localized("adaptive_critical", "Critical")
        case .stale: return localized("adaptive_stale", "Stale reading")
        case .unavailable: return localized("adaptive_unavailable", "No data")
        }
    }

    private func localized(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, tableName: "Common", bundle: .main, value: fallback, comment: "Adaptive Status widget")
    }

    var prominence: Double {
        switch self {
        case .normal: return 0.08
        case .warning: return 0.22
        case .critical: return 0.38
        case .stale, .unavailable: return 0.16
        }
    }

}

@available(iOSApplicationExtension 17.0, *)
private struct AdaptiveStatusView: View {
    var entry: XDripWidget.Entry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var compact: Bool { family == .accessoryRectangular }
    private var status: AdaptiveGlucoseStatus {
        let state = entry.widgetState
        return .resolve(values: state.bgReadingValues ?? [], dates: state.bgReadingDates ?? [], urgentLow: state.urgentLowLimitInMgDl, low: state.lowLimitInMgDl, high: state.highLimitInMgDl, urgentHigh: state.urgentHighLimitInMgDl, at: entry.date)
    }
    private var hasReading: Bool { status != .unavailable }
    private var readingText: String {
        guard hasReading, let value = entry.widgetState.bgValueInMgDl,
              let date = entry.widgetState.bgReadingDate,
              entry.date.timeIntervalSince(date) < ConstantsWidgetExtension.bgReadingDateVeryStaleInMinutes else { return "—" }
        if value >= 400 { return Texts_Common.HIGH }
        if value < 40 { return Texts_Common.LOW }
        return value.mgDlToMmolAndToString(mgDl: entry.widgetState.isMgDl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 8) {
            HStack(spacing: 6) {
                Image(systemName: status == .critical ? "exclamationmark.triangle.fill" : "drop.fill")
                    .foregroundStyle(status.color).widgetAccentable()
                Text(status.title).font(compact ? .system(size: 10, weight: .semibold) : .caption.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(readingText)
                    .font(.system(size: compact ? 25 : 42, weight: .semibold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6)
                Text(entry.widgetState.bgUnitString).font(.system(size: compact ? 9 : 12))
                Spacer(minLength: 0)
                Text(status == .stale || !hasReading ? "" : entry.widgetState.trendArrow())
                    .font(.system(size: compact ? 22 : 30, weight: .medium))
                    .foregroundStyle(status.color).widgetAccentable()
            }
            .lineLimit(1)
            if !compact {
                AdaptiveSparkline(values: chartValues).stroke(status.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(height: 20).accessibilityHidden(true)
            }
            if let date = entry.widgetState.bgReadingDate, hasReading {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(date, style: .relative)
                }
                .font(.system(size: compact ? 9 : 11)).monospacedDigit()
            }
        }
        .padding(compact ? 5 : 12)
        .background { glassSurface }
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 12 : 24)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), status.color.opacity(0.35), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: status == .critical ? 2 : 1)
        }
        .privacySensitive()
    }

    @ViewBuilder private var glassSurface: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 12 : 24)
        if renderingMode != .fullColor {
            // Lock Screen and tinted appearances are composited by WidgetKit.
            shape.fill(.white.opacity(status.prominence))
        } else if reduceTransparency {
            shape.fill(Color(white: 0.12)).overlay(shape.fill(status.color.opacity(status.prominence)))
        } else if #available(iOS 26.0, *) {
            shape.fill(.clear)
                .glassEffect(.clear.tint(status.color.opacity(status.prominence)), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(status.color.opacity(status.prominence)))
        }
    }

    private var chartValues: [Double] {
        guard let values = entry.widgetState.bgReadingValues, let dates = entry.widgetState.bgReadingDates else { return [] }
        return zip(values, dates).filter {
            $0.0.isFinite && $0.0 > 12 && $0.1 <= entry.date && $0.1 >= entry.date.addingTimeInterval(-60 * 60)
        }.sorted { $0.1 < $1.1 }.map { $0.0 }
    }
}

private struct AdaptiveSparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return Path() }
        let span = max(high - low, 20)
        let center = (high + low) / 2
        return Path { path in
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: rect.width * Double(index) / Double(values.count - 1), y: rect.height * (0.5 - (value - center) / span))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct AdaptiveStatusPreviews: PreviewProvider {
    static var previews: some View {
        ForEach([110.0, 185.0, 55.0], id: \.self) { value in
            AdaptiveStatusView(entry: .init(date: .now, widgetState: .init(
                bgReadingValues: [value, value, value],
                bgReadingDates: [.now, Date.now.addingTimeInterval(-300), Date.now.addingTimeInterval(-600)],
                isMgDl: false, slopeOrdinal: 4, followerPatientName: nil
            )))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
        }
    }
}
