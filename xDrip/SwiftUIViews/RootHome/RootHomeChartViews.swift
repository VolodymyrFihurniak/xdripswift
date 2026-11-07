//
//  RootHomeChartViews.swift
//  xdrip
//
//  Created by Paul Plant on 22/7/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI
import Charts

/// Main interactive chart with loading state and the reading shown at the panned end date.
struct RootHomeMainChartView: View {
    @AppStorage(UserDefaults.Key.targetMarkValue.rawValue) private var targetValueInMgDl = 0.0
    @Binding var selectedRange: RootHomeChartRange
    let showsTreatments: Bool
    var allowsTherapyCharts = true
    let chartState: GlucoseChartState
    let isLoading: Bool
    let scrollCoordinator: GlucoseChartScrollCoordinator
    let yAxisResetRevision: Int
    let updateChartStateIfNeeded: () -> Void
    let finishChartScroll: (_ forceReset: Bool, _ showsLoading: Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var rangeOverlay = ChartDelayedState(false)
    @State private var hasUpdatedRangeDuringPinch = false
    @AppStorage("showIOBCOB") private var showIOBCOB = UserDefaults.standard.showIOBCOB
    @AppStorage(UserDefaults.Key.renderBasalDownwards.rawValue) private var renderBasalDownwards = true
    @State private var therapySeries = TherapyChartSeries()
    @State private var therapyRevision = 0
    @State private var experimentalPlots = GlucoseChartExperimentalPlots()
    @State private var experimentalRevision = 0
    @State private var experimentalSettingsSignature = ExperimentalChartInputs.settingsSignature()
    // JugglucoNG's chart cursor and active insulin card (Settings > Experimental).
    @AppStorage("experimentalChartCursorEnabled") private var cursorEnabled = true
    @State private var cursor: GlucoseChartCursor?
    @State private var cursorGeometry = GlucoseChartCursorGeometry()
    @State private var touchMode: ChartTouchMode?
    @State private var cursorHold: DispatchWorkItem?
    @State private var isActiveInsulinExpanded = false

    /// What the current touch on the main chart does, decided when it starts or after a hold.
    private enum ChartTouchMode { case undecided, pan, cursor }
    // Hide curves immediately and cancel pending chart work when Treatments is off.
    private var hasIOB: Bool { showsTreatments && allowsTherapyCharts && showIOBCOB && !therapySeries.iob.isEmpty }
    private var hasCOB: Bool { showsTreatments && allowsTherapyCharts && showIOBCOB && !therapySeries.cob.isEmpty }
    // Reuse the glucose cache's buffered coverage, rounded outward so tiny pans do
    // not dispatch another fetch and rebuild for each visible-range change.
    private var therapyStart: Date { Date(timeIntervalSince1970: floor(chartState.dataStartDate.timeIntervalSince1970 / 3600) * 3600) }
    private var therapyEnd: Date { Date(timeIntervalSince1970: ceil(chartState.dataEndDate.timeIntervalSince1970 / 3600) * 3600) }
    private var seriesKey: String { scenePhase != .active ? "inactive" : "\(therapyStart)-\(therapyEnd)-\(showIOBCOB)-\(showsTreatments)-\(allowsTherapyCharts)-\(therapyRevision)-\(floor(Date().timeIntervalSince1970 / 60))" }
    private var experimentalKey: String {
        scenePhase != .active ? "inactive" : "\(therapyStart)-\(therapyEnd)-\(showsTreatments)-\(allowsTherapyCharts)-\(experimentalRevision)-\(experimentalSettingsSignature)-\(chartState.endDate.timeIntervalSinceNow > -ConstantsGlucoseChartSwiftUI.experimentalPredictionPresentTolerance)-\(chartState.bgReadingDates.last?.timeIntervalSince1970 ?? 0)-\(floor(Date().timeIntervalSince1970 / 60))"
    }

    private enum Layout {
        static let rangeOverlayTopInset: CGFloat = 8
        static let rangeOverlayHorizontalPadding: CGFloat = 10
        static let rangeOverlayVerticalPadding: CGFloat = 5
        static let rangeOverlayFontSize: CGFloat = 16
        static let rangeOverlayMinimumWidth: CGFloat = 70
        /// JugglucoNG starts the cursor when a touch lands this close to the glucose line (32 dp there).
        static let cursorLineTouchDistance: CGFloat = 26
        /// Holding a finger still this long anywhere on the chart also starts the cursor.
        static let cursorHoldDelay: TimeInterval = 0.4
        static let cursorHoldSlop: CGFloat = 8
        /// JugglucoNG picks the nearest reading only within 15 minutes of the touch.
        static let cursorMaximumReadingDistance: TimeInterval = 15 * 60
        static let overlayInset: CGFloat = 6
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                GlucoseChartView(
                    glucoseChartType: .widgetSystemLarge,
                    bgReadingValues: nil,
                    bgReadingDates: nil,
                    isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl,
                    urgentLowLimitInMgDl: UserDefaults.standard.urgentLowMarkValue,
                    lowLimitInMgDl: UserDefaults.standard.lowMarkValue,
                    highLimitInMgDl: UserDefaults.standard.highMarkValue,
                    urgentHighLimitInMgDl: UserDefaults.standard.urgentHighMarkValue,
                    targetValueInMgDl: targetValueInMgDl,
                    liveActivityType: nil,
                    hoursToShowScalingHours: selectedRange.rawValue,
                    glucoseCircleDiameterScalingHours: selectedRange.glucoseCircleDiameterScalingHours,
                    showsTreatments: showsTreatments,
                    overrideChartHeight: geometry.size.height,
                    overrideChartWidth: geometry.size.width,
                    highContrast: nil,
                    chartState: chartState
                )
                .mainChartYAxisContext(
                    resetRevision: yAxisResetRevision, renderBasalDownwards: renderBasalDownwards
                )
                .therapyPlots(TherapyChartSeries(iob: hasIOB ? therapySeries.iob : [], cob: hasCOB ? therapySeries.cob : []))
                .experimentalPlots(experimentalPlots)
                .cursor(cursorEnabled ? cursor : nil, geometry: cursorGeometry)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(GlucoseChartCursorGeometry.coordinateSpace))
                        .onChanged { value in
                            if touchMode == nil { beginTouch(at: value.location) }
                            if touchMode == .cursor {
                                moveCursor(toX: value.location.x)
                                return
                            }
                            if touchMode == .undecided,
                               max(abs(value.translation.width), abs(value.translation.height)) > Layout.cursorHoldSlop {
                                touchMode = .pan
                                cancelCursorHold()
                            }
                            scrollCoordinator.updateVisibleRange(value: value, chartWidth: geometry.size.width)
                            updateChartStateIfNeeded()
                        }
                        .onEnded { value in
                            cancelCursorHold()
                            let mode = touchMode
                            touchMode = nil
                            // The cursor stays where the finger left it until the next touch.
                            guard mode != .cursor else { return }
                            scrollCoordinator.finishUpdatingVisibleRange(value: value, chartWidth: geometry.size.width)
                            finishChartScroll(false, false)
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    cursor = nil
                    scrollCoordinator.resetToNow()
                    finishChartScroll(true, true)
                })
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged(updateRange)
                        .onEnded { _ in
                            hasUpdatedRangeDuringPinch = false
                        }
                )
                .clipped()

                // Experimental: the insulin still on board now (JugglucoNG's active insulin card) and
                // which colour is which insulin, for the layers in this window. Hidden under the cursor.
                let legendLayers = experimentalPlots.insulinLayers(from: chartState.startDate, to: chartState.endDate)
                let onBoardNow = experimentalPlots.onBoardNow
                if showsTreatments && allowsTherapyCharts && cursor == nil && (!legendLayers.isEmpty || !onBoardNow.isEmpty) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !onBoardNow.isEmpty {
                            ActiveInsulinCard(onBoard: onBoardNow, isExpanded: $isActiveInsulinExpanded)
                        }
                        if !legendLayers.isEmpty {
                            InsulinActivityLegend(layers: legendLayers)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.leading, Layout.overlayInset)
                    .padding(.top, 4)
                }

                // JugglucoNG's cursor card: the moment, its glucose and the insulin acting then.
                if cursorEnabled, let cursor, let cursorX = cursorGeometry.x(for: cursor.date) {
                    ChartCursorCardLayout(centerX: cursorX, inset: Layout.overlayInset) {
                        ChartCursorCard(cursor: cursor, details: cursorDetails(for: cursor))
                    }
                    .padding(.top, 4)
                    .allowsHitTesting(false)
                }

                if rangeOverlay.value {
                    HStack(spacing: 4) {
                        Text("\(Int(selectedRange.rawValue))")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        Text(Texts_Common.hours)
                    }
                    .font(.system(size: Layout.rangeOverlayFontSize))
                    .foregroundStyle(ConstantsAppColors.secondaryText)
                    .frame(minWidth: Layout.rangeOverlayMinimumWidth)
                    .padding(.horizontal, Layout.rangeOverlayHorizontalPadding)
                    .padding(.vertical, Layout.rangeOverlayVerticalPadding)
                    .background(
                        ConstantsAppColors.homePanelBackground,
                        in: RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius, style: .continuous)
                    )
                    .padding(.top, Layout.rangeOverlayTopInset)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }

                if isLoading {
                    ProgressView()
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: GlucoseChartCursorGeometry.coordinateSpace)
        }
        .onChange(of: cursorEnabled) { isEnabled in
            if !isEnabled { cursor = nil }
        }
        .task(id: seriesKey) {
            guard scenePhase == .active else { return }
            guard showsTreatments && allowsTherapyCharts && showIOBCOB else {
                therapySeries = TherapyChartSeries()
                return
            }
            let result = await TherapyMetricsManager.shared.chart(from: therapyStart, to: therapyEnd)
            guard !Task.isCancelled else { return }
            therapySeries = result
        }
        .onReceive(NotificationCenter.default.publisher(for: TherapyMetricsManager.changed)) { _ in
            if scenePhase == .active { therapyRevision &+= 1; experimentalRevision &+= 1 }
        }
        .task(id: experimentalKey) {
            guard scenePhase == .active else { return }
            let plots = await ExperimentalChartInputs.plots(
                chartState: chartState, dataStart: therapyStart, dataEnd: therapyEnd,
                showsInsulin: showsTreatments && allowsTherapyCharts)
            guard !Task.isCancelled else { return }
            experimentalPlots = plots
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Defaults can change on any thread; compare on the main queue.
            DispatchQueue.main.async {
                let signature = ExperimentalChartInputs.settingsSignature()
                if signature != experimentalSettingsSignature { experimentalSettingsSignature = signature }
            }
        }
        .onDisappear {
            rangeOverlay.cancel()
        }
    }

    private func updateRange(magnification: CGFloat) {
        guard !hasUpdatedRangeDuringPinch else { return }

        let threshold = ConstantsHomeView.mainChartZoomMagnificationThreshold
        let newRange: RootHomeChartRange?

        // One pinch changes one range step as soon as it crosses the deliberate threshold.
        if magnification >= 1 + threshold {
            newRange = selectedRange.nextShorterRange
        } else if magnification <= 1 - threshold {
            newRange = selectedRange.nextLongerRange
        } else {
            newRange = nil
        }

        guard let newRange else { return }

        hasUpdatedRangeDuringPinch = true
        cursor = nil
        selectedRange = newRange
        showRangeOverlay()
    }

    // MARK: - Cursor

    /// A new touch clears the cursor. It starts a new one at once when it lands on the glucose line,
    /// as in JugglucoNG, or once the finger has been held still; otherwise it pans the chart.
    private func beginTouch(at location: CGPoint) {
        touchMode = .undecided
        cursor = nil
        guard cursorEnabled else { return }
        if let target = cursorTarget(atX: location.x), let mgDl = target.mgDl, let lineY = cursorGeometry.y(forMgDl: mgDl),
           abs(location.y - lineY) <= Layout.cursorLineTouchDistance {
            startCursor(atX: location.x)
            return
        }
        let hold = DispatchWorkItem {
            guard touchMode == .undecided else { return }
            // Undo the few points the chart moved before the hold was recognised.
            scrollCoordinator.cancelDrag()
            updateChartStateIfNeeded()
            startCursor(atX: location.x)
        }
        cursorHold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.cursorHoldDelay, execute: hold)
    }

    private func startCursor(atX x: CGFloat) {
        touchMode = .cursor
        scrollCoordinator.stopDeceleration()
        moveCursor(toX: x)
    }

    private func moveCursor(toX x: CGFloat) {
        guard let target = cursorTarget(atX: x) else { return }
        // A light tick for each new reading under the finger, as JugglucoNG's scrub haptic.
        if target.date != cursor?.date { UISelectionFeedbackGenerator().selectionChanged() }
        cursor = target
    }

    private func cancelCursorHold() {
        cursorHold?.cancel()
        cursorHold = nil
    }

    /// The reading nearest the touch, within 15 minutes; past the newest reading, the forecast
    /// point while one is drawn; otherwise just the time, without a glucose value.
    private func cursorTarget(atX x: CGFloat) -> GlucoseChartCursor? {
        guard let date = cursorGeometry.date(atX: x) else { return nil }
        let dates = chartState.bgReadingDates
        let values = chartState.bgReadingValues
        if let newest = dates.last, date > newest.addingTimeInterval(ExperimentalCompanionForecast.stepSeconds / 2),
           let point = experimentalPlots.prediction.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
           point.date > newest, abs(point.date.timeIntervalSince(date)) <= ExperimentalCompanionForecast.stepSeconds {
            return GlucoseChartCursor(date: point.date, mgDl: point.mgDl, isForecast: true)
        }
        if let index = Self.nearestIndex(in: dates, to: date), index < values.count,
           abs(dates[index].timeIntervalSince(date)) <= Layout.cursorMaximumReadingDistance {
            return GlucoseChartCursor(date: dates[index], mgDl: values[index])
        }
        return GlucoseChartCursor(date: date, mgDl: nil)
    }

    /// Binary search in ascending dates for the one closest to `date`.
    static func nearestIndex(in dates: [Date], to date: Date) -> Int? {
        guard !dates.isEmpty else { return nil }
        var low = 0
        var high = dates.count - 1
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] < date { low = middle + 1 } else { high = middle }
        }
        if low > 0, abs(dates[low - 1].timeIntervalSince(date)) <= abs(dates[low].timeIntervalSince(date)) { return low - 1 }
        return low
    }

    /// The insulin on board, xDrip's own IOB/COB where the experimental insulins are off, and the
    /// doses logged at the cursor's moment.
    private func cursorDetails(for cursor: GlucoseChartCursor) -> ChartCursorCard.Details {
        var details = ChartCursorCard.Details()
        details.onBoard = experimentalPlots.onBoard(at: cursor.date)
        if details.onBoard.isEmpty {
            details.therapyIOB = Self.nearestAmount(in: hasIOB ? therapySeries.iob : [], to: cursor.date)
            details.therapyCOB = Self.nearestAmount(in: hasCOB ? therapySeries.cob : [], to: cursor.date)
        }
        guard showsTreatments, !cursor.isForecast else { return details }
        let window = ExperimentalCompanionForecast.stepSeconds / 2
        let points = chartState.treatmentPoints
        var doses: [ChartCursorCard.Dose] = []
        for point in points.boluses where abs(point.date.timeIntervalSince(cursor.date)) <= window {
            doses.append(ChartCursorCard.Dose(id: "bolus-\(point.date.timeIntervalSince1970)", title: TreatmentType.Insulin.asString(),
                                              insulin: InsulinProfile.matching(notes: point.notes)?.shortName,
                                              amount: ChartCursorCard.units(point.treatmentValue)))
        }
        for point in points.basalInjections where abs(point.date.timeIntervalSince(cursor.date)) <= window {
            doses.append(ChartCursorCard.Dose(id: "basal-\(point.date.timeIntervalSince1970)", title: TreatmentType.BasalInjection.asString(),
                                              insulin: InsulinProfile.matching(notes: point.notes)?.shortName,
                                              amount: ChartCursorCard.units(point.treatmentValue)))
        }
        for point in points.carbs where abs(point.date.timeIntervalSince(cursor.date)) <= window {
            doses.append(ChartCursorCard.Dose(id: "carbs-\(point.date.timeIntervalSince1970)", title: TreatmentType.Carbs.asString(),
                                              insulin: nil, amount: ChartCursorCard.grams(point.treatmentValue)))
        }
        details.doses = doses
        return details
    }

    private static func nearestAmount(in points: [TherapyChartPoint], to date: Date) -> Double? {
        guard let nearest = points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(nearest.date.timeIntervalSince(date)) <= 5 * 60 else { return nil }
        return nearest.amount
    }

    private func showRangeOverlay() {
        rangeOverlay.cancel()

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            rangeOverlay.value = true
        }

        // The owner schedules a value change without retaining this view and its old work item.
        rangeOverlay.schedule(
            false,
            after: ConstantsHomeView.mainChartZoomOverlayVisibleDuration,
            animation: .easeOut(duration: ConstantsHomeView.mainChartZoomOverlayFadeDuration)
        )
    }
}

/// Historical overview chart and the active main-chart window.
struct RootHomeMiniChartView: View {
    @AppStorage(UserDefaults.Key.targetMarkValue.rawValue) private var targetValueInMgDl = 0.0
    let miniChartHoursToShow: Double
    let chartState: GlucoseChartState
    let scrollCoordinator: GlucoseChartScrollCoordinator
    let updateChartStateIfNeeded: () -> Void
    let finishChartScroll: () -> Void
    let cycleMiniChartHoursToShow: () -> Void

    /// `nil` until a new drag is classified. The result is then held for the whole gesture because
    /// the active window moves away from its original touch point during a valid drag.
    @State private var activeWindowDragIsEnabled: Bool?

    private enum Layout {
        static let chartHeight: CGFloat = 60
    }

    var body: some View {
        GeometryReader { geometry in
            let overviewStartDate = chartState.startDate
            let edgeInsetTimeInterval = overviewEdgeInsetTimeInterval(chartWidth: geometry.size.width)
            let renderedOverviewEndDate = chartState.endDate.addingTimeInterval(edgeInsetTimeInterval)

            ZStack(alignment: .leading) {
                GlucoseChartView(
                    glucoseChartType: .miniChart,
                    bgReadingValues: nil,
                    bgReadingDates: nil,
                    isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl,
                    urgentLowLimitInMgDl: UserDefaults.standard.urgentLowMarkValue,
                    lowLimitInMgDl: UserDefaults.standard.lowMarkValue,
                    highLimitInMgDl: UserDefaults.standard.highMarkValue,
                    urgentHighLimitInMgDl: UserDefaults.standard.urgentHighMarkValue,
                    targetValueInMgDl: targetValueInMgDl,
                    liveActivityType: nil,
                    hoursToShowScalingHours: miniChartHoursToShow,
                    glucoseCircleDiameterScalingHours: miniChartHoursToShow,
                    overrideChartHeight: geometry.size.height,
                    overrideChartWidth: geometry.size.width,
                    highContrast: nil,
                    chartState: chartState
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
                .contentShape(Rectangle())
                // Treat the fixed mini-chart as a scrubber: moving its active window updates the shared
                // coordinator and therefore the main chart, while the overview data stays stationary.
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            if activeWindowDragIsEnabled == nil {
                                activeWindowDragIsEnabled = activeWindowContains(
                                    xPosition: value.startLocation.x,
                                    chartWidth: geometry.size.width,
                                    overviewStartDate: overviewStartDate,
                                    overviewEndDate: renderedOverviewEndDate
                                )
                            }

                            guard activeWindowDragIsEnabled == true else { return }

                            scrollCoordinator.updateVisibleRangeFromOverview(
                                value: value,
                                overviewStartDate: overviewStartDate,
                                overviewEndDate: renderedOverviewEndDate,
                                leadingEdgeInsetTimeInterval: edgeInsetTimeInterval,
                                chartWidth: geometry.size.width
                            )
                            updateChartStateIfNeeded()
                        }
                        .onEnded { value in
                            let shouldFinishDrag = activeWindowDragIsEnabled ?? activeWindowContains(
                                xPosition: value.startLocation.x,
                                chartWidth: geometry.size.width,
                                overviewStartDate: overviewStartDate,
                                overviewEndDate: renderedOverviewEndDate
                            )
                            activeWindowDragIsEnabled = nil

                            guard shouldFinishDrag else { return }

                            scrollCoordinator.finishUpdatingVisibleRangeFromOverview(
                                value: value,
                                overviewStartDate: overviewStartDate,
                                overviewEndDate: renderedOverviewEndDate,
                                leadingEdgeInsetTimeInterval: edgeInsetTimeInterval,
                                chartWidth: geometry.size.width
                            )
                            finishChartScroll()
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded(cycleMiniChartHoursToShow))
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: Layout.chartHeight)
    }

    /// Converts the active window's dates into the same extended coordinate space used to render
    /// the mini-chart, so only touches that begin within the visible window can move it.
    private func activeWindowContains(
        xPosition: CGFloat,
        chartWidth: CGFloat,
        overviewStartDate: Date,
        overviewEndDate: Date
    ) -> Bool {
        guard chartWidth > 0,
              let activeWindowStartDate = chartState.overlayWindowStartDate,
              let activeWindowEndDate = chartState.overlayWindowEndDate,
              activeWindowStartDate < activeWindowEndDate else {
            return false
        }

        let overviewTimeInterval = overviewEndDate.timeIntervalSince(overviewStartDate)
        let visibleActiveStartDate = max(activeWindowStartDate, overviewStartDate)
        let visibleActiveEndDate = min(activeWindowEndDate, overviewEndDate)

        guard overviewTimeInterval > 0, visibleActiveStartDate < visibleActiveEndDate else { return false }

        let activeStartX = CGFloat(visibleActiveStartDate.timeIntervalSince(overviewStartDate) / overviewTimeInterval) * chartWidth
        let activeEndX = CGFloat(visibleActiveEndDate.timeIntervalSince(overviewStartDate) / overviewTimeInterval) * chartWidth

        return xPosition >= activeStartX && xPosition <= activeEndX
    }

    /// Uses one time-equivalent inset for both rounded corners without changing chart data. The
    /// trailing span protects the `now` edge. The overview-only clamp protects the leading edge.
    private func overviewEdgeInsetTimeInterval(chartWidth: CGFloat) -> TimeInterval {
        let visibleTimeInterval = chartState.endDate.timeIntervalSince(chartState.startDate)
        return ConstantsGlucoseChartSwiftUI.miniChartEdgeInsetTimeInterval(
            visibleTimeInterval: visibleTimeInterval,
            chartWidth: chartWidth
        )
    }
}

/// Compact legend for the experimental insulin activity layers: a dot and a short name each.
struct InsulinActivityLegend: View {
    let layers: [GlucoseChartExperimentalPlots.InsulinLayer]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(layers) { layer in
                HStack(spacing: 3) {
                    Circle().fill(layer.color).frame(width: 7, height: 7)
                    Text(layer.name).font(.caption2).foregroundStyle(ConstantsAppColors.secondaryText).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(ConstantsAppColors.homePanelBackground.opacity(0.75), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// JugglucoNG's active insulin card: IOB of the rapid insulins and the basal insulin still on
/// board now. A tap lists every insulin with its units and when its last dose stops acting.
struct ActiveInsulinCard: View {
    let onBoard: [GlucoseChartExperimentalPlots.OnBoard]
    @Binding var isExpanded: Bool

    private var iob: Double { onBoard.filter(\.countsTowardIOB).reduce(0) { $0 + $1.units } }
    private var basal: Double { onBoard.filter { !$0.countsTowardIOB }.reduce(0) { $0 + $1.units } }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if iob > ChartCursorCard.minimumUnits {
                        Text(String(format: ChartCursorCard.iobFormat, ChartCursorCard.units(iob)))
                            .fontWeight(.semibold)
                    }
                    if basal > ChartCursorCard.minimumUnits {
                        Text(String(format: ChartCursorCard.basalFormat, ChartCursorCard.units(basal)))
                            .foregroundStyle(ConstantsAppColors.secondaryText)
                    }
                }
                if isExpanded {
                    ForEach(onBoard) { item in
                        HStack(spacing: 4) {
                            Circle().fill(item.color).frame(width: 7, height: 7)
                            Text(item.name)
                            Text(ChartCursorCard.units(item.units))
                                .fontWeight(.semibold)
                            if let activeUntil = item.activeUntil {
                                Text(String(format: ChartCursorCard.untilFormat, ChartCursorCard.time(activeUntil)))
                                    .foregroundStyle(ConstantsAppColors.secondaryText)
                            }
                        }
                    }
                }
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(ConstantsAppColors.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ConstantsAppColors.homePanelBackground.opacity(0.85),
                        in: RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// JugglucoNG's cursor card: when, the glucose then, the insulin still acting at that moment and
/// the doses logged at it.
struct ChartCursorCard: View {
    struct Dose: Identifiable {
        let id: String
        let title: String
        let insulin: String?
        let amount: String
    }

    struct Details {
        var onBoard: [GlucoseChartExperimentalPlots.OnBoard] = []
        /// xDrip's own IOB and COB, shown when the experimental insulins are off.
        var therapyIOB: Double?
        var therapyCOB: Double?
        var doses: [Dose] = []
    }

    let cursor: GlucoseChartCursor
    let details: Details

    static let minimumUnits = 0.005
    static var iobFormat: String { ExperimentalTexts.text("iobValue", "IOB %@") }
    static var cobFormat: String { ExperimentalTexts.text("cobValue", "COB %@") }
    static var basalFormat: String { ExperimentalTexts.text("basalOnBoardValue", "Basal %@") }
    static var untilFormat: String { ExperimentalTexts.text("activeUntil", "until %@") }

    /// Insulin units: one decimal below ten units, as JugglucoNG's card.
    static func units(_ value: Double) -> String {
        String(format: ExperimentalTexts.text("unitsValue", "%@ U"),
               value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))))
    }

    static func grams(_ value: Double) -> String {
        String(format: ExperimentalTexts.text("gramsValue", "%@ g"), value.formatted(.number.precision(.fractionLength(0))))
    }

    /// The time, with the weekday when it is not today.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private static func glucose(_ mgDl: Double) -> String {
        let isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        return "\(mgDl.mgDlToMmolAndToString(mgDl: isMgDl)) \(isMgDl ? Texts_Common.mgdl : Texts_Common.mmol)"
    }

    private var iob: Double { details.onBoard.filter(\.countsTowardIOB).reduce(0) { $0 + $1.units } }

    private var therapyLine: String? {
        let parts = [details.therapyIOB.map { String(format: Self.iobFormat, Self.units($0)) },
                     details.therapyCOB.map { String(format: Self.cobFormat, Self.grams($0)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.time(cursor.date))
                if cursor.isForecast {
                    Text(ExperimentalTexts.text("cursorForecast", "forecast"))
                        .foregroundStyle(ConstantsGlucoseChartSwiftUI.experimentalPredictionColor)
                }
            }
            .font(.caption2)
            .foregroundStyle(ConstantsAppColors.secondaryText)

            if let mgDl = cursor.mgDl {
                Text(Self.glucose(mgDl))
                    .font(.subheadline.weight(.semibold))
            }

            if iob > Self.minimumUnits {
                Text(String(format: Self.iobFormat, Self.units(iob)))
                    .fontWeight(.semibold)
            }
            ForEach(details.onBoard) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    Text(item.name)
                        .foregroundStyle(ConstantsAppColors.secondaryText)
                    Text(Self.units(item.units))
                }
            }
            if let therapyLine {
                Text(therapyLine)
            }
            ForEach(details.doses) { dose in
                Text([dose.title, dose.insulin, dose.amount].compactMap { $0 }.joined(separator: " "))
                    .foregroundStyle(ConstantsAppColors.secondaryText)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(ConstantsAppColors.primaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(ConstantsAppColors.homePanelBackground.opacity(0.95),
                    in: RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Places the cursor card centred over the cursor, kept inside the chart's edges.
struct ChartCursorCardLayout: Layout {
    /// The cursor's x, from the chart's leading edge.
    let centerX: CGFloat
    let inset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let card = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? card.width, height: card.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let size = card.sizeThatFits(.unspecified)
        let leading = bounds.minX + inset
        let trailing = max(bounds.maxX - size.width - inset, leading)
        let x = min(max(bounds.minX + centerX - size.width / 2, leading), trailing)
        card.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}
