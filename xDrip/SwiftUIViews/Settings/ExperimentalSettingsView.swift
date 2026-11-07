//
//  ExperimentalSettingsView.swift
//  xdrip
//
//  Settings > Experimental features: glucose prediction, insulins on the chart and the glucose
//  line style. The prediction and insulin models are ported from JugglucoNG.
//

import SwiftUI

extension SettingsViewGroupedSettingsViewModel {
    /// The Experimental features root section.
    static func experimental() -> SettingsViewGroupedSettingsViewModel {
        SettingsViewGroupedSettingsViewModel(
            title: ExperimentalTexts.text("sectionTitle", "Experimental features"),
            rows: [
                SettingsGroupedRow(
                    id: "experimental.prediction",
                    title: ExperimentalTexts.text("prediction", "Glucose prediction"),
                    detail: { UserDefaults.standard.experimentalPredictionEnabled ? Texts_Common.on : Texts_Common.off },
                    settingsScreen: { ExperimentalSettingsViewModel.predictionScreen }
                ),
                SettingsGroupedRow(
                    id: "experimental.insulins",
                    title: ExperimentalTexts.text("insulins", "Insulins"),
                    detail: { UserDefaults.standard.experimentalInsulinsEnabled ? Texts_Common.on : Texts_Common.off },
                    settingsScreen: { ExperimentalSettingsViewModel.insulinScreen }
                )
            ],
            leadingRows: { [ExperimentalSettingsViewModel.chartStyleRow(), ExperimentalSettingsViewModel.chartCursorRow()] }
        )
    }
}

struct ExperimentalSettingsViewModel: SettingsNativeSectionProvider {
    enum Group { case predictionMain, predictionAdaptive, predictionModel, predictionAlert, predictionAccuracy, predictionNightscout, insulins }
    let group: Group

    static var predictionScreen: SettingsScreen {
        SettingsScreen(title: ExperimentalTexts.text("prediction", "Glucose prediction"),
                       introduction: { ExperimentalTexts.text("predictionIntroduction", "Experimental. A forecast of the next hours, drawn as a dashed line to the right of the main chart. It continues the recent trend and adds the effect of the carbs, boluses and exercise you log. It is an estimate only: never dose insulin from it.") },
                       providers: { [ExperimentalSettingsViewModel(group: .predictionMain), ExperimentalSettingsViewModel(group: .predictionAdaptive),
                                     ExperimentalSettingsViewModel(group: .predictionModel),
                                     ExperimentalSettingsViewModel(group: .predictionAlert), ExperimentalSettingsViewModel(group: .predictionAccuracy),
                                     ExperimentalSettingsViewModel(group: .predictionNightscout)] })
    }

    static var insulinScreen: SettingsScreen {
        SettingsScreen(title: ExperimentalTexts.text("insulins", "Insulins"),
                       introduction: { ExperimentalTexts.text("insulinsIntroduction", "Experimental. Each insulin has its own action curve, from JugglucoNG's catalogue. A bolus or basal injection uses the insulin named in its notes; the treatment editor offers a choice. Otherwise the defaults below apply.") },
                       providers: { [ExperimentalSettingsViewModel(group: .insulins)] })
    }

    /// Glucose drawn as dots or as a line.
    static func chartStyleRow() -> SettingsRow {
        SettingsRow(id: "experimental.chartStyle", title: ExperimentalTexts.text("chartStyle", "Glucose on the chart"), accessory: .none,
                    control: .menu(options: {
                        let selected = UserDefaults.standard.experimentalGlucoseChartStyle
                        return ExperimentalGlucoseChartStyle.allCases.map { SettingsMenuOption(title: title(for: $0), isSelected: $0 == selected) }
                    }, selectOption: { index in
                        let styles = ExperimentalGlucoseChartStyle.allCases
                        guard styles.indices.contains(index) else { return }
                        UserDefaults.standard.experimentalGlucoseChartStyle = styles[index]
                    }))
    }

    /// JugglucoNG's cursor on the main chart: time, glucose and the insulin on board at that moment.
    static func chartCursorRow() -> SettingsRow {
        SettingsRow(id: "experimental.chartCursor", title: ExperimentalTexts.text("chartCursor", "Chart cursor"),
                    control: .toggle(isOn: { UserDefaults.standard.experimentalChartCursorEnabled },
                                     setIsOn: { UserDefaults.standard.experimentalChartCursorEnabled = $0 }))
    }

    static func title(for style: ExperimentalGlucoseChartStyle) -> String {
        switch style {
        case .points: return ExperimentalTexts.text("chartStylePoints", "Points")
        case .line: return ExperimentalTexts.text("chartStyleLine", "Line")
        }
    }

    func settingsRows(sectionID: Int) -> [SettingsRow] {
        let defaults = UserDefaults.standard
        switch group {
        case .predictionMain:
            return [
                SettingsRow(id: "experimental.prediction.enabled", title: ExperimentalTexts.text("predictionShow", "Show prediction"),
                            control: .toggle(isOn: { UserDefaults.standard.experimentalPredictionEnabled },
                                             setIsOn: { UserDefaults.standard.experimentalPredictionEnabled = $0 }),
                            reloadScope: .all),
                SettingsRow(id: "experimental.prediction.horizon", title: ExperimentalTexts.text("predictionHorizon", "Forecast length"), accessory: .none,
                            control: .menu(options: {
                                let selected = UserDefaults.standard.experimentalPredictionHorizonMinutes
                                return ExperimentalPredictionHorizon.choices.map { SettingsMenuOption(title: Self.minutesText($0), isSelected: $0 == selected) }
                            }, selectOption: { index in
                                let choices = ExperimentalPredictionHorizon.choices
                                guard choices.indices.contains(index) else { return }
                                UserDefaults.standard.experimentalPredictionHorizonMinutes = choices[index]
                            }),
                            isEnabled: defaults.experimentalPredictionEnabled),
                SettingsRow(id: "experimental.prediction.momentum", title: ExperimentalTexts.text("predictionMomentum", "Follow the trend"),
                            control: .toggle(isOn: { UserDefaults.standard.experimentalPredictionTrendMomentum },
                                             setIsOn: { UserDefaults.standard.experimentalPredictionTrendMomentum = $0 }),
                            isEnabled: defaults.experimentalPredictionEnabled)
            ]
        case .predictionAdaptive:
            var rows = [
                SettingsRow(id: "experimental.prediction.adaptive", title: ExperimentalTexts.text("predictionAdaptive", "Adaptive prediction"),
                            control: .toggle(isOn: { UserDefaults.standard.experimentalPredictionAdaptive },
                                             setIsOn: { isOn in
                                                 UserDefaults.standard.experimentalPredictionAdaptive = isOn
                                                 if isOn, let coreDataManager = TherapyMetricsManager.shared.configuredCoreDataManager {
                                                     AdaptiveForecastStore.refreshIfDue(coreDataManager: coreDataManager)
                                                 }
                                             }),
                            isEnabled: defaults.experimentalPredictionEnabled, reloadScope: .all)
            ]
            if defaults.experimentalPredictionAdaptive || AdaptiveForecastStore.model() != nil {
                rows.append(SettingsRow(id: "experimental.prediction.adaptiveStatus",
                                        title: ExperimentalTexts.text("predictionAdaptiveModel", "Learned model"),
                                        detail: Self.adaptiveStatusText(AdaptiveForecastStore.status())))
                rows.append(SettingsRow(id: "experimental.prediction.adaptiveRelearn",
                                        title: ExperimentalTexts.text("predictionAdaptiveRelearn", "Relearn now"),
                                        control: .custom(content: {
                                            AnyView(Button(ExperimentalTexts.text("predictionAdaptiveRelearn", "Relearn now")) {
                                                AdaptiveForecastStore.reset()
                                                if let coreDataManager = TherapyMetricsManager.shared.configuredCoreDataManager {
                                                    AdaptiveForecastStore.refreshIfDue(coreDataManager: coreDataManager)
                                                }
                                            })
                                        })))
            }
            return rows
        case .predictionModel:
            let isMgDl = defaults.bloodGlucoseUnitIsMgDl
            let unit = isMgDl ? Texts_Common.mgdl : Texts_Common.mmol
            return [
                numberRow(id: "experimental.prediction.sensitivity", title: ExperimentalTexts.text("predictionSensitivity", "Insulin sensitivity (per unit)"),
                          value: defaults.experimentalPredictionInsulinSensitivityMgDl.mgDlToMmol(mgDl: isMgDl),
                          unit: unit, fractionDigits: isMgDl ? 0 : 1,
                          range: ExperimentalPredictionModel.insulinSensitivityRange.lowerBound.mgDlToMmol(mgDl: isMgDl)...ExperimentalPredictionModel.insulinSensitivityRange.upperBound.mgDlToMmol(mgDl: isMgDl),
                          isEnabled: defaults.experimentalPredictionEnabled) { value in
                    UserDefaults.standard.experimentalPredictionInsulinSensitivityMgDl = isMgDl ? value : value / ConstantsBloodGlucose.mgDlToMmoll
                },
                numberRow(id: "experimental.prediction.carbRatio", title: ExperimentalTexts.text("predictionCarbRatio", "Carb ratio (grams per unit)"),
                          value: defaults.experimentalPredictionCarbRatio, unit: "g", fractionDigits: 1,
                          range: ExperimentalPredictionModel.carbRatioRange, isEnabled: defaults.experimentalPredictionEnabled) { value in
                    UserDefaults.standard.experimentalPredictionCarbRatio = value
                },
                numberRow(id: "experimental.prediction.absorption", title: ExperimentalTexts.text("predictionAbsorption", "Carb absorption (grams per hour)"),
                          value: defaults.experimentalPredictionCarbAbsorption, unit: "g/h", fractionDigits: 0,
                          range: ExperimentalPredictionModel.carbAbsorptionRange, isEnabled: defaults.experimentalPredictionEnabled) { value in
                    UserDefaults.standard.experimentalPredictionCarbAbsorption = value
                },
                SettingsRow(id: "experimental.prediction.periods", title: ExperimentalTexts.text("predictionPeriods", "Time-of-day periods"),
                            control: .custom(content: {
                                AnyView(NavigationLink {
                                    ExperimentalPredictionPeriodsView()
                                } label: {
                                    LabeledContent(ExperimentalTexts.text("predictionPeriods", "Time-of-day periods"),
                                                   value: UserDefaults.standard.experimentalPredictionPeriods.isEmpty
                                                    ? ExperimentalTexts.text("predictionPeriodsNone", "All day the same")
                                                    : "\(UserDefaults.standard.experimentalPredictionPeriods.count + 1)")
                                })
                            })),
                bodyWeightRow(),
                SettingsRow(id: "experimental.prediction.macros", title: ExperimentalTexts.text("predictionMacros", "Protein and fat"),
                            control: .toggle(isOn: { UserDefaults.standard.experimentalPredictionMacrosEnabled },
                                             setIsOn: { UserDefaults.standard.experimentalPredictionMacrosEnabled = $0 }))
            ]
        case .predictionAlert:
            return [
                SettingsRow(id: "experimental.predictedLow.lead", title: ExperimentalTexts.text("predictedLowLead", "Warn ahead by"), accessory: .none,
                            control: .menu(options: {
                                let selected = UserDefaults.standard.experimentalPredictedLowLeadMinutes
                                return PredictedLowAlert.leadChoices.map { SettingsMenuOption(title: Self.minutesText($0), isSelected: $0 == selected) }
                            }, selectOption: { index in
                                let choices = PredictedLowAlert.leadChoices
                                guard choices.indices.contains(index) else { return }
                                UserDefaults.standard.experimentalPredictedLowLeadMinutes = choices[index]
                            }))
            ]
        case .predictionNightscout:
            return [
                SettingsRow(id: "experimental.prediction.nightscout", title: ExperimentalTexts.text("predictionNightscout", "Upload to Nightscout"),
                            control: .toggle(isOn: { UserDefaults.standard.experimentalNightscoutPredictionEnabled },
                                             setIsOn: { UserDefaults.standard.experimentalNightscoutPredictionEnabled = $0 }),
                            isEnabled: !defaults.dataFlowPolicy.importsStatusFromNightscout)
            ]
        case .predictionAccuracy:
            return [
                SettingsRow(id: "experimental.accuracy.enabled", title: ExperimentalTexts.text("accuracyRecord", "Record accuracy"),
                            control: .toggle(isOn: { UserDefaults.standard.experimentalPredictionAccuracyEnabled },
                                             setIsOn: { UserDefaults.standard.experimentalPredictionAccuracyEnabled = $0 })),
                SettingsRow(id: "experimental.accuracy.show", title: ExperimentalTexts.text("accuracyShow", "Prediction accuracy"),
                            control: .custom(content: {
                                AnyView(NavigationLink(ExperimentalTexts.text("accuracyShow", "Prediction accuracy")) { ExperimentalPredictionAccuracyView() })
                            }))
            ]
        case .insulins:
            return [
                SettingsRow(id: "experimental.insulins.enabled", title: ExperimentalTexts.text("insulinsShow", "Show insulin activity on the chart"),
                            control: .toggle(isOn: { UserDefaults.standard.experimentalInsulinsEnabled },
                                             setIsOn: { UserDefaults.standard.experimentalInsulinsEnabled = $0 }),
                            reloadScope: .all),
                insulinRow(id: "experimental.insulins.bolus", title: ExperimentalTexts.text("insulinBolus", "Bolus insulin"),
                           choices: InsulinProfile.bolusChoices, selected: { UserDefaults.standard.experimentalBolusInsulin },
                           select: { UserDefaults.standard.experimentalBolusInsulin = $0 }),
                insulinRow(id: "experimental.insulins.basal", title: ExperimentalTexts.text("insulinBasal", "Basal insulin"),
                           choices: InsulinProfile.basalChoices, selected: { UserDefaults.standard.experimentalBasalInsulin },
                           select: { UserDefaults.standard.experimentalBasalInsulin = $0 })
            ]
        }
    }

    /// Optional body weight; an empty entry clears it.
    private func bodyWeightRow() -> SettingsRow {
        let range = ExperimentalPredictionModel.bodyWeightRange
        let current = UserDefaults.standard.experimentalBodyWeightKg
        let rangeText = String(format: ExperimentalTexts.text("numberRange", "From %@ to %@ %@."),
                               Self.numberText(range.lowerBound, fractionDigits: 0), Self.numberText(range.upperBound, fractionDigits: 0), "kg")
        return SettingsRow(id: "experimental.prediction.bodyWeight", title: ExperimentalTexts.text("bodyWeight", "Body weight"),
                           detail: current.map { "\(Self.numberText($0, fractionDigits: 1)) kg" } ?? ExperimentalTexts.text("notSet", "Not set"),
                           accessory: .disclosure, reloadScope: .all,
                           action: .textEntry {
                               SettingsTextEntryContent(
                                   title: ExperimentalTexts.text("bodyWeight", "Body weight"),
                                   message: rangeText + " " + ExperimentalTexts.text("bodyWeightMessage", "Leave empty to use the study's reference dose."),
                                   keyboardType: .decimalPad, text: current.map { Self.numberText($0, fractionDigits: 1) }, placeholder: nil,
                                   fieldTitle: nil, unitText: "kg", actionTitle: Texts_Common.Ok, cancelTitle: Texts_Common.Cancel,
                                   action: { entered in
                                       let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
                                       UserDefaults.standard.experimentalBodyWeightKg = trimmed.isEmpty ? nil : Self.parse(trimmed)
                                   },
                                   cancel: nil,
                                   validator: { entered in
                                       let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
                                       if trimmed.isEmpty { return nil }
                                       guard let value = Self.parse(trimmed), range.contains(value) else { return rangeText }
                                       return nil
                                   })
                           })
    }

    private func insulinRow(id: String, title: String, choices: [InsulinProfile], selected: @escaping () -> InsulinProfile,
                            select: @escaping (InsulinProfile) -> Void) -> SettingsRow {
        SettingsRow(id: id, title: title, accessory: .none,
                    control: .menuWithSelectionTitle(options: {
                        let current = selected()
                        return choices.map { SettingsMenuOption(title: $0.displayName, isSelected: $0 == current) }
                    }, selectionTitle: { selected().shortName }, selectOption: { index in
                        guard choices.indices.contains(index) else { return }
                        select(choices[index])
                    }))
    }

    private func numberRow(id: String, title: String, value: Double, unit: String, fractionDigits: Int, range: ClosedRange<Double>,
                           isEnabled: Bool, save: @escaping (Double) -> Void) -> SettingsRow {
        let text = Self.numberText(value, fractionDigits: fractionDigits)
        return SettingsRow(id: id, title: title, detail: "\(text) \(unit)", accessory: .disclosure, isEnabled: isEnabled, reloadScope: .all,
                           action: .textEntry {
                               SettingsTextEntryContent(
                                   title: title, message: String(format: ExperimentalTexts.text("numberRange", "From %@ to %@ %@."),
                                                                 Self.numberText(range.lowerBound, fractionDigits: fractionDigits),
                                                                 Self.numberText(range.upperBound, fractionDigits: fractionDigits), unit),
                                   keyboardType: .decimalPad, text: text, placeholder: nil, fieldTitle: nil, unitText: unit,
                                   actionTitle: Texts_Common.Ok, cancelTitle: Texts_Common.Cancel,
                                   action: { entered in
                                       guard let number = Self.parse(entered) else { return }
                                       save(min(max(number, range.lowerBound), range.upperBound))
                                   },
                                   cancel: nil,
                                   validator: { entered in
                                       guard let number = Self.parse(entered), range.contains(number) else {
                                           return String(format: ExperimentalTexts.text("numberRange", "From %@ to %@ %@."),
                                                         Self.numberText(range.lowerBound, fractionDigits: fractionDigits),
                                                         Self.numberText(range.upperBound, fractionDigits: fractionDigits), unit)
                                       }
                                       return nil
                                   })
                           })
    }

    /// Accepts both decimal separators.
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
            .flatMap { $0.isFinite ? $0 : nil }
    }

    static func numberText(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...fractionDigits)))
    }

    /// JugglucoNG's adaptive prediction summary: learning, learned from N days, or not better yet.
    static func adaptiveStatusText(_ status: AdaptiveForecastStore.Status) -> String {
        switch status {
        case .learning:
            return ExperimentalTexts.text("predictionAdaptiveLearning", "Learning, needs 2 days of readings")
        case .ready(let trainingDays, _):
            return String(format: ExperimentalTexts.text("predictionAdaptiveReady", "Learned from %@ days of readings"),
                          numberText(trainingDays, fractionDigits: 0))
        case .notBetter:
            return ExperimentalTexts.text("predictionAdaptiveNotBetter", "Not better than no change yet, standard shown")
        }
    }

    static func minutesText(_ minutes: Int) -> String {
        DateComponentsFormatter.localizedString(from: DateComponents(minute: minutes), unitsStyle: .short) ?? "\(minutes)"
    }

    func sectionTitle() -> String? {
        switch group {
        case .predictionMain, .insulins: return nil
        case .predictionAdaptive: return ExperimentalTexts.text("predictionAdaptive", "Adaptive prediction")
        case .predictionModel: return ExperimentalTexts.text("predictionModel", "Model")
        case .predictionAlert: return Texts_Alerts.predictedLowAlertTitle
        case .predictionAccuracy: return ExperimentalTexts.text("accuracyShow", "Prediction accuracy")
        case .predictionNightscout: return "Nightscout"
        }
    }

    func sectionFooter() -> String? {
        switch group {
        case .predictionMain:
            return ExperimentalTexts.text("predictionMainFooter", "Follow the trend continues the recent rise or fall that your treatments do not explain, fading over about an hour. The forecast starts only from a reading at most 15 minutes old.")
        case .predictionAdaptive:
            return ExperimentalTexts.text("predictionAdaptiveFooter", "Draws a forecast learned from your own readings instead of the standard one, dotted, up to two hours. It learns from the last four weeks, relearns once a day and needs two days of readings; it ignores logged insulin and carbs. Until it is ready, after a gap or a new sensor's first hour, or while it is not better than no change, the standard forecast without the trend is drawn. The predicted low alert and Nightscout keep using the standard forecast.")
        case .predictionModel:
            return ExperimentalTexts.text("predictionModelFooter", "Insulin sensitivity: how far one unit lowers glucose. Carb ratio: grams covered by one unit. Absorption sets how long carbs take to act. Periods change these by time of day; each treatment uses the values in force when it was logged. Body weight sharpens curves measured per kilogram (Fiasp, Levemir, regular insulin). Protein and fat add a late rise for carb entries that list them. Basal and premixed insulins are not part of the forecast, as in JugglucoNG.")
        case .predictionAlert:
            return ExperimentalTexts.text("predictedLowFooter", "Warns when the forecast falls below the alarm value within this time while glucose is still above it. Turn it on and set the value, sound and snooze in Settings > Alerts > Predicted Low. It uses the model above even when the prediction is not drawn.")
        case .predictionNightscout:
            return ExperimentalTexts.text("predictionNightscoutFooter", "Every five minutes the forecast is uploaded as an OpenAPS-style devicestatus, as AAPS does, so Nightscout's forecast lines show it (enable the openaps plugin). Not available while xDrip follows an AID's status from Nightscout. Boluses also upload their chosen insulin as notes, carb entries their protein and fat.")
        case .predictionAccuracy:
            return ExperimentalTexts.text("accuracyFooter", "Keeps the forecast every five minutes for 14 days and compares it with the glucose that followed. If the forecast is often worse than assuming no change, or runs high or low, adjust sensitivity, carb ratio or absorption.")
        case .insulins:
            return ExperimentalTexts.text("insulinsFooter", "The chart shows how fast each insulin is working, in units per hour, stacked in its own colour along the bottom. A curve ends where its source stopped measuring; nothing is extrapolated.")
        }
    }

    private func row(at index: Int) -> SettingsRow? {
        let rows = settingsRows(sectionID: 0)
        return rows.indices.contains(index) ? rows[index] : nil
    }
    func settingsRowText(index: Int) -> String { row(at: index)?.title ?? "" }
    func accessoryType(index: Int) -> SettingsAccessory { .none }
    func detailedText(index: Int) -> String? { row(at: index)?.detail }
    func numberOfRows() -> Int { settingsRows(sectionID: 0).count }
    func onRowSelect(index: Int) -> SettingsSelectedRowAction { .nothing }
    func isEnabled(index: Int) -> Bool { row(at: index)?.isEnabled ?? false }
    func completeSettingsViewRefreshNeeded(index: Int) -> Bool { false }
    func storeMessageHandler(messageHandler: @escaping ((String, String) -> Void)) {}
    func storeRowReloadClosure(rowReloadClosure: @escaping ((Int) -> Void)) {}
}

/// Edits the time-of-day periods of the prediction model (JugglucoNG `PredictionModelProfileScreen`).
/// Midnight always uses the single values on the previous screen; up to seven more periods follow.
struct ExperimentalPredictionPeriodsView: View {
    @State private var periods = UserDefaults.standard.experimentalPredictionPeriods
    private let isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl

    var body: some View {
        List {
            Section(footer: Text(ExperimentalTexts.text("predictionPeriodsFooter", "From each start time until the next one these values replace the single ones. Before the first period, and when there are none, the single values apply."))) {
                LabeledContent("00:00", value: summary(carbRatio: UserDefaults.standard.experimentalPredictionCarbRatio,
                                                       sensitivityMgDl: UserDefaults.standard.experimentalPredictionInsulinSensitivityMgDl,
                                                       absorption: UserDefaults.standard.experimentalPredictionCarbAbsorption))
                // Index identity keeps a row stable while its start time is being edited.
                ForEach(periods.indices, id: \.self) { index in
                    let period = $periods[index]
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker(ExperimentalTexts.text("periodStart", "Starts at"), selection: Binding(
                            get: { Self.date(minute: period.wrappedValue.startMinute) },
                            set: { period.wrappedValue.startMinute = Self.minute(of: $0) }), displayedComponents: .hourAndMinute)
                        numberField(ExperimentalTexts.text("predictionSensitivity", "Insulin sensitivity (per unit)"),
                                    value: Binding(get: { isMgDl ? period.wrappedValue.insulinSensitivityMgDl : period.wrappedValue.insulinSensitivityMgDl * ConstantsBloodGlucose.mgDlToMmoll },
                                                   set: { period.wrappedValue.insulinSensitivityMgDl = isMgDl ? $0 : $0 / ConstantsBloodGlucose.mgDlToMmoll }),
                                    unit: isMgDl ? Texts_Common.mgdl : Texts_Common.mmol)
                        numberField(ExperimentalTexts.text("predictionCarbRatio", "Carb ratio (grams per unit)"), value: period.carbRatio, unit: "g")
                        numberField(ExperimentalTexts.text("predictionAbsorption", "Carb absorption (grams per hour)"), value: period.carbAbsorption, unit: "g/h")
                    }
                }
                .onDelete { periods.remove(atOffsets: $0); save() }
            }
            if periods.count < ExperimentalPredictionPeriod.maximumCount {
                Button(ExperimentalTexts.text("periodAdd", "Add period")) { addPeriod() }
            }
        }
        .navigationTitle(ExperimentalTexts.text("predictionPeriods", "Time-of-day periods"))
        .onDisappear { save() }
    }

    private func numberField(_ title: String, value: Binding<Double>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(carbRatio: Double, sensitivityMgDl: Double, absorption: Double) -> String {
        let sensitivity = isMgDl ? sensitivityMgDl : sensitivityMgDl * ConstantsBloodGlucose.mgDlToMmoll
        return "\(ExperimentalSettingsViewModel.numberText(sensitivity, fractionDigits: isMgDl ? 0 : 1)) · 1:\(ExperimentalSettingsViewModel.numberText(carbRatio, fractionDigits: 1)) · \(ExperimentalSettingsViewModel.numberText(absorption, fractionDigits: 0)) g/h"
    }

    /// Splits the longest gap in the day, as JugglucoNG `suggestedSplitMinute`, inheriting its values.
    private func addPeriod() {
        let starts = [0] + periods.map(\.startMinute) + [1440]
        let gaps = zip(starts, starts.dropFirst()).map { ($0, $1 - $0) }
        guard let largest = gaps.max(by: { $0.1 < $1.1 }) else { return }
        let start = min(max(((largest.0 + largest.1 / 2 + 15) / 30) * 30, 1), 1439)
        let inherited = ExperimentalPredictionModel(defaults: .standard).parameters(at: Self.date(minute: start))
        periods.append(ExperimentalPredictionPeriod(startMinute: start, carbRatio: inherited.carbRatio,
                                                    insulinSensitivityMgDl: inherited.insulinSensitivityMgDl, carbAbsorption: inherited.carbAbsorption))
        save()
    }

    private func save() {
        periods = ExperimentalPredictionPeriod.sanitized(periods)
        UserDefaults.standard.experimentalPredictionPeriods = periods
    }

    private static func date(minute: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minute * 60))
    }

    private static func minute(of date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

/// Forecast error by horizon (JugglucoNG `PredictionAnalysisScreen`, simplified).
struct ExperimentalPredictionAccuracyView: View {
    @State private var report: [HorizonAccuracy] = []
    @State private var adaptiveReport: [HorizonAccuracy] = []
    @State private var forecastCount = 0
    @State private var isLoading = true
    private let isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl

    var body: some View {
        List {
            if isLoading {
                ProgressView()
            } else if forecastCount == 0 {
                Text(ExperimentalTexts.text("accuracyEmpty", "No forecasts recorded yet. Turn on Record accuracy and come back after a few hours."))
            } else {
                Section(header: adaptiveReport.isEmpty ? nil : Text(ExperimentalTexts.text("accuracyStandard", "Standard forecast")),
                        footer: Text(String(format: ExperimentalTexts.text("accuracyCount", "%ld forecasts recorded. A horizon needs at least %ld compared forecasts to say much."),
                                            forecastCount, PredictionAccuracy.minimumReliableCount))) {
                    horizonRows(report)
                }
                // JugglucoNG records the adaptive forecast from the same reading, so the two compare.
                if !adaptiveReport.isEmpty {
                    Section(header: Text(ExperimentalTexts.text("accuracyAdaptive", "Adaptive forecast")),
                            footer: Text(ExperimentalTexts.text("accuracyAdaptiveFooter", "Recorded from the same readings whenever the adaptive model could answer, whether or not it is drawn."))) {
                        horizonRows(adaptiveReport)
                    }
                }
                Section {
                    Button(ExperimentalTexts.text("accuracyClear", "Delete recorded forecasts"), role: .destructive) {
                        PredictionAccuracyRecorder.clear()
                        report = []
                        adaptiveReport = []
                        forecastCount = 0
                    }
                }
            }
        }
        .navigationTitle(ExperimentalTexts.text("accuracyShow", "Prediction accuracy"))
        .task { await load() }
    }

    @ViewBuilder
    private func horizonRows(_ horizons: [HorizonAccuracy]) -> some View {
        ForEach(horizons, id: \.horizonMinutes) { horizon in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ExperimentalSettingsViewModel.minutesText(horizon.horizonMinutes)).font(.headline)
                    Spacer()
                    Text("n = \(horizon.count)").foregroundStyle(horizon.count < PredictionAccuracy.minimumReliableCount ? Color.orange : Color.secondary)
                }
                if horizon.count > 0 {
                    Text(String(format: ExperimentalTexts.text("accuracyLine", "Error %@ · no change %@ · bias %@"),
                                glucose(horizon.meanAbsoluteError), glucose(horizon.noChangeMeanAbsoluteError), glucose(horizon.bias, signed: true)))
                        .font(.subheadline)
                        .foregroundStyle(horizon.meanAbsoluteError <= horizon.noChangeMeanAbsoluteError ? Color.primary : Color.orange)
                }
            }
        }
    }

    private func glucose(_ mgDl: Double, signed: Bool = false) -> String {
        let value = isMgDl ? mgDl : mgDl * ConstantsBloodGlucose.mgDlToMmoll
        let text = ExperimentalSettingsViewModel.numberText(abs(value), fractionDigits: isMgDl ? 0 : 1)
        let sign = signed ? (value > 0 ? "+" : value < 0 ? "−" : "") : ""
        return sign + text + " " + (isMgDl ? Texts_Common.mgdl : Texts_Common.mmol)
    }

    @MainActor
    private func load() async {
        let forecasts = PredictionAccuracyRecorder.load()
        forecastCount = forecasts.filter { !$0.isAdaptive }.count
        guard let earliest = forecasts.map(\.origin).min(), let coreDataManager = TherapyMetricsManager.shared.configuredCoreDataManager else {
            isLoading = false
            return
        }
        let readings = BgReadingsAccessor(coreDataManager: coreDataManager)
            .getLatestBgReadings(limit: nil, fromDate: earliest.addingTimeInterval(-60), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
            .map { (date: $0.timeStamp, mgDl: $0.finalValue) }
        report = PredictionAccuracy.report(forecasts: forecasts.filter { !$0.isAdaptive }, readings: readings)
        let adaptive = forecasts.filter(\.isAdaptive)
        adaptiveReport = adaptive.isEmpty ? [] : PredictionAccuracy.report(forecasts: adaptive, readings: readings)
        isLoading = false
    }
}
