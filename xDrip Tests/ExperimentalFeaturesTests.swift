//
//  ExperimentalFeaturesTests.swift
//  xdripTests
//
//  Glucose prediction, insulin catalogue and chart helpers ported from JugglucoNG. Numeric
//  expectations were computed with a Python port of the same arithmetic.
//

import XCTest
import SwiftUI
@testable import xdrip

final class ExperimentalFeaturesTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func flat(_ value: Double, count: Int = 12) -> [GlucosePredictionKernel.Sample] {
        (0..<count).map { GlucosePredictionKernel.Sample(date: start.addingTimeInterval(TimeInterval($0 * 60)), value: value) }
    }

    private func simulate(_ history: [GlucosePredictionKernel.Sample], momentum: Bool = false, horizon: Int = 120,
                          delta: @escaping (Date) -> Double = { _ in 0 }) -> [GlucosePredictionPoint] {
        GlucosePredictionKernel.simulate(history: history, isMmol: false, trendMomentum: momentum, horizonMinutes: horizon,
                                         stepMinutes: 5, targetLow: 70, targetHigh: 180, treatmentDeltaAt: delta)
    }

    // MARK: Kernel (JugglucoNG GlucosePredictionKernelTests)

    func testTooLittleHistoryPredictsNothing() {
        XCTAssertTrue(simulate([]).isEmpty)
        XCTAssertTrue(simulate(flat(120, count: 1)).isEmpty)
    }

    func testForecastStartsAtTheNewestReadingAndSpansTheHorizon() throws {
        let history = flat(120)
        let result = simulate(history, horizon: 60)
        let first = try XCTUnwrap(result.first), last = try XCTUnwrap(result.last)
        XCTAssertEqual(first.date, history.last?.date)
        XCTAssertEqual(first.value, 120, accuracy: 1e-9)
        XCTAssertEqual(first.confidence, 1)
        XCTAssertEqual(last.date.timeIntervalSince(first.date), 60 * 60)
        XCTAssertEqual(result.count, 1 + 12)
    }

    func testFlatHistorySettlesSlowlyTowardTheTargetCentre() throws {
        // 120 + (125 - 120) * (1 - e^(-120/240)) * 0.18
        let last = try XCTUnwrap(simulate(flat(120)).last)
        XCTAssertEqual(last.unclampedValue, 120.354_122_406, accuracy: 1e-6)
        XCTAssertEqual(last.confidence, 0.26, accuracy: 1e-9)
    }

    func testConfidenceDecaysAcrossTheHorizon() {
        let confidences = simulate(flat(120)).map(\.confidence)
        XCTAssertTrue(zip(confidences, confidences.dropFirst()).allSatisfy { $1 <= $0 })
        XCTAssertLessThan(confidences.last ?? 1, confidences.first ?? 0)
    }

    func testRisingSeriesWithMomentumForecastsHigher() throws {
        let rising = (0..<12).map { GlucosePredictionKernel.Sample(date: start.addingTimeInterval(TimeInterval($0 * 60)), value: 100 + Double($0) * 2) }
        let withMomentum = try XCTUnwrap(simulate(rising, momentum: true).last).unclampedValue
        let without = try XCTUnwrap(simulate(rising, momentum: false).last).unclampedValue
        XCTAssertEqual(withMomentum, 165.434_628_359, accuracy: 1e-6)
        XCTAssertEqual(without, 122.212_473_444, accuracy: 1e-6)
    }

    func testDrawnValueSaturatesButTheUnclampedValueDoesNot() throws {
        let huge = try XCTUnwrap(simulate(flat(120)) { _ in -400 }.last)
        XCTAssertEqual(huge.value, 18)
        XCTAssertEqual(huge.unclampedValue, -279.645_877_594, accuracy: 1e-6)
    }

    func testCurveFractionIsBoundedAndMonotonic() {
        let points = [InsulinCurvePoint(minute: 0, activity: 0), InsulinCurvePoint(minute: 30, activity: 1),
                      InsulinCurvePoint(minute: 60, activity: 1), InsulinCurvePoint(minute: 120, activity: 0.6),
                      InsulinCurvePoint(minute: 240, activity: 0)]
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction(points, elapsedMinutes: 0), 0)
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction(points, elapsedMinutes: 240), 1, accuracy: 1e-9)
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction(points, elapsedMinutes: 600), 1, accuracy: 1e-9)
        let fractions = stride(from: 0.0, through: 240, by: 20).map { InsulinCurveMath.cumulativeFraction(points, elapsedMinutes: $0) }
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $1 >= $0 - 1e-12 })
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction([InsulinCurvePoint(minute: 0, activity: 1)], elapsedMinutes: 1), 0)
    }

    // MARK: Treatment model

    private func model() -> ExperimentalPredictionModel {
        var model = ExperimentalPredictionModel()
        model.trendMomentum = false
        return model
    }

    private func readings(_ value: Double) -> [(date: Date, mgDl: Double)] {
        flat(value).map { (date: $0.date, mgDl: $0.value) }
    }

    func testCarbsRaiseTheForecastBySensitivityOverCarbRatio() throws {
        let baseline = start.addingTimeInterval(11 * 60)
        let carbs = ExperimentalTreatment(date: baseline, amount: 40, kind: .carbs, notes: nil)
        let result = model().forecast(readings: readings(120), treatments: [carbs], isMmol: false,
                                      targetLowMgDl: 70, targetHighMgDl: 180, now: baseline)
        // 40 g / 10 g/U * 54 mg/dL, fully absorbed within two hours, plus the settling term.
        XCTAssertEqual(try XCTUnwrap(result.last).unclampedValue, 336.354_122_406, accuracy: 1e-6)
    }

    func testBolusLowersTheForecastAlongItsInsulinCurve() throws {
        let baseline = start.addingTimeInterval(11 * 60)
        let bolus = ExperimentalTreatment(date: baseline, amount: 4, kind: .bolus, notes: nil)
        let result = model().forecast(readings: readings(200), treatments: [bolus], isMmol: false,
                                      targetLowMgDl: 70, targetHighMgDl: 180, now: baseline)
        // NovoRapid's curve has delivered 55.95 % of its action after two hours.
        XCTAssertEqual(try XCTUnwrap(result.last).unclampedValue, 73.831_515_943, accuracy: 1e-6)
    }

    func testBasalInsulinIsNotPartOfTheForecast() throws {
        let baseline = start.addingTimeInterval(11 * 60)
        let basal = ExperimentalTreatment(date: baseline, amount: 20, kind: .basalInjection, notes: "Tresiba")
        let plain = model().forecast(readings: readings(120), treatments: [], isMmol: false, targetLowMgDl: 70, targetHighMgDl: 180, now: baseline)
        let withBasal = model().forecast(readings: readings(120), treatments: [basal], isMmol: false, targetLowMgDl: 70, targetHighMgDl: 180, now: baseline)
        XCTAssertEqual(try XCTUnwrap(withBasal.last).unclampedValue, try XCTUnwrap(plain.last).unclampedValue, accuracy: 1e-9)
    }

    func testForecastNeedsARecentReading() {
        let tooLate = start.addingTimeInterval(11 * 60 + ExperimentalPredictionModel.maximumBaselineAge + 60)
        XCTAssertTrue(model().forecast(readings: readings(120), treatments: [], isMmol: false,
                                       targetLowMgDl: 70, targetHighMgDl: 180, now: tooLate).isEmpty)
    }

    func testMmolForecastIsReturnedInMgDl() throws {
        let baseline = start.addingTimeInterval(11 * 60)
        let result = model().forecast(readings: readings(120), treatments: [], isMmol: true, targetLowMgDl: 70, targetHighMgDl: 180, now: baseline)
        XCTAssertEqual(try XCTUnwrap(result.first).value, 120, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.last).unclampedValue, 120.354_122_406, accuracy: 1e-6)
    }

    // MARK: Insulin catalogue

    func testEveryCurveStartsAtMinuteZeroWithSortedMinutesAndBoundedActivity() {
        for insulin in InsulinProfile.allCases {
            let points = InsulinCurveCatalogue.referenceCurve(insulin)
            XCTAssertGreaterThanOrEqual(points.count, 2, insulin.rawValue)
            XCTAssertEqual(points.first?.minute, 0, insulin.rawValue)
            XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.minute < $1.minute }, insulin.rawValue)
            XCTAssertTrue(points.allSatisfy { (0...1).contains($0.activity) }, insulin.rawValue)
        }
    }

    func testGeneratedRapidCurveMatchesJugglucoNG() {
        let aspart = InsulinCurveCatalogue.referenceCurve(.aspart)
        XCTAssertEqual(aspart.map(\.minute), [0, 14, 28, 40, 98, 174, 264, 360])
        XCTAssertEqual(aspart[3].activity, 0.927_127_140, accuracy: 1e-6)
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction(aspart, elapsedMinutes: 60), 0.248_447_817, accuracy: 1e-6)
    }

    func testFiaspReferenceCurveDeliversAboutHalfInTwoHours() {
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction(InsulinCurveCatalogue.referenceCurve(.fiasp), elapsedMinutes: 120), 0.552_955_201, accuracy: 1e-6)
    }

    func testLyumjevCurveIsInterpolatedBetweenStudyDosesAndKeepsAPeakOfOne() {
        let curve = InsulinCurveCatalogue.curve(for: .urli, units: 11)
        XCTAssertEqual(curve.map(\.activity).max() ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(InsulinCurveCatalogue.curve(for: .urli, units: 3).last?.minute, 276)
        XCTAssertEqual(InsulinCurveCatalogue.curve(for: .urli, units: 40).last?.minute, 438)
    }

    func testNotesNameTheInsulinAndSpecificNamesWin() {
        XCTAssertEqual(InsulinProfile.matching(notes: "Tresiba 20"), .degludec)
        XCTAssertEqual(InsulinProfile.matching(notes: "humalog mix 25"), .lisproMix7525)
        XCTAssertEqual(InsulinProfile.matching(notes: "Humalog"), .lispro)
        XCTAssertEqual(InsulinProfile.matching(notes: "Новорапід"), .aspart)
        XCTAssertNil(InsulinProfile.matching(notes: "after lunch"))
        XCTAssertNil(InsulinProfile.matching(notes: nil))
    }

    func testEveryPerDoseChoiceIsRecognisedFromTheNameItWrites() {
        for insulin in InsulinProfile.perDoseBolusChoices + InsulinProfile.perDoseBasalChoices {
            XCTAssertEqual(InsulinProfile.matching(notes: insulin.shortName), insulin, insulin.shortName)
        }
    }

    func testTreatmentUsesItsNamedInsulinOrTheDefault() {
        let named = ExperimentalTreatment(date: start, amount: 4, kind: .bolus, notes: "Fiasp")
        let unnamed = ExperimentalTreatment(date: start, amount: 4, kind: .bolus, notes: nil)
        let basal = ExperimentalTreatment(date: start, amount: 20, kind: .basalInjection, notes: "evening")
        XCTAssertEqual(named.insulin(bolusDefault: .aspart, basalDefault: .degludec), .fiasp)
        XCTAssertEqual(unnamed.insulin(bolusDefault: .aspart, basalDefault: .degludec), .aspart)
        XCTAssertEqual(basal.insulin(bolusDefault: .aspart, basalDefault: .degludec), .degludec)
        XCTAssertNil(ExperimentalTreatment(date: start, amount: 30, kind: .carbs, notes: "Fiasp").insulin(bolusDefault: .aspart, basalDefault: .degludec))
    }

    // MARK: Insulin activity

    func testActivityOfADoseAddsUpToTheDose() {
        let shape = InsulinActivityStack.shape(for: .aspart, units: 6)
        let total = (0...360).reduce(0.0) { $0 + InsulinActivityStack.rate(units: 6, shape: shape, minutes: Double($1)) } / 60
        XCTAssertEqual(total, 6, accuracy: 0.05)
        XCTAssertEqual(InsulinActivityStack.rate(units: 6, shape: shape, minutes: 400), 0)
    }

    func testSteadyStateCurveIsReducedToOneDailyDose() {
        let shape = InsulinActivityStack.shape(for: .degludec, units: 20)
        XCTAssertEqual(shape.first?.activity, 0)
        XCTAssertTrue(shape.allSatisfy { $0.activity >= 0 })
        // One dose is what the regimen does less what it still does a day later.
        let full = InsulinCurveCatalogue.referenceCurve(.degludec)
        XCTAssertEqual(InsulinCurveCatalogue.interpolate(shape, minute: 720),
                       InsulinCurveCatalogue.interpolate(full, minute: 720) - InsulinCurveCatalogue.interpolate(full, minute: 2160), accuracy: 1e-9)
    }

    func testBandStacksBasalBelowBolus() throws {
        let treatments = [ExperimentalTreatment(date: start, amount: 20, kind: .basalInjection, notes: nil),
                          ExperimentalTreatment(date: start.addingTimeInterval(3600), amount: 5, kind: .bolus, notes: nil),
                          ExperimentalTreatment(date: start, amount: 50, kind: .carbs, notes: nil)]
        let dates = InsulinActivityStack.sampleDates(from: start, to: start.addingTimeInterval(6 * 3600), treatments: treatments)
        let band = InsulinActivityStack.band(treatments: treatments, dates: dates, bolusDefault: .aspart, basalDefault: .glargineU100)
        XCTAssertEqual(band.layers.map(\.insulin), [.glargineU100, .aspart])
        let basal = band.layers[0], bolus = band.layers[1]
        XCTAssertEqual(bolus.bottoms, basal.tops)
        XCTAssertTrue(zip(bolus.tops, basal.tops).allSatisfy { $0 >= $1 })
        XCTAssertTrue(dates.contains(start.addingTimeInterval(3600)))
    }

    // MARK: Insulin on board

    func testInsulinOnBoardFallsFromTheDoseToZero() {
        let shape = InsulinActivityStack.shape(for: .aspart, units: 6)
        XCTAssertEqual(InsulinActivityStack.remaining(units: 6, shape: shape, minutes: 0), 6, accuracy: 1e-9)
        // Python port of JugglucoNG JournalIobMath.remainingCurveFraction over the aspart curve.
        XCTAssertEqual(InsulinActivityStack.remaining(units: 6, shape: shape, minutes: 60), 4.5093, accuracy: 0.001)
        XCTAssertEqual(InsulinActivityStack.remaining(units: 6, shape: shape, minutes: 120), 2.6429, accuracy: 0.001)
        XCTAssertEqual(InsulinActivityStack.remaining(units: 6, shape: shape, minutes: -5), 0)
        XCTAssertEqual(InsulinActivityStack.remaining(units: 6, shape: shape, minutes: 360), 0)
    }

    func testOnBoardGroupsByInsulinAndEndsWithTheLastDose() throws {
        let treatments = [ExperimentalTreatment(date: start, amount: 6, kind: .bolus, notes: nil),
                          ExperimentalTreatment(date: start.addingTimeInterval(3600), amount: 6, kind: .bolus, notes: "NovoRapid"),
                          ExperimentalTreatment(date: start, amount: 20, kind: .basalInjection, notes: nil),
                          // Logged for later: not on board yet.
                          ExperimentalTreatment(date: start.addingTimeInterval(3 * 3600), amount: 4, kind: .bolus, notes: nil)]
        let onBoard = InsulinActivityStack.onBoard(treatments: treatments, at: start.addingTimeInterval(2 * 3600),
                                                   bolusDefault: .aspart, basalDefault: .glargineU100)
        XCTAssertEqual(Set(onBoard.map(\.insulin)), [.aspart, .glargineU100])
        let aspart = try XCTUnwrap(onBoard.first { $0.insulin == .aspart })
        XCTAssertEqual(aspart.units, 2.6429 + 4.5093, accuracy: 0.002)
        XCTAssertEqual(aspart.activeUntil, start.addingTimeInterval(3600 + 360 * 60))
        XCTAssertEqual(onBoard.map(\.units), onBoard.map(\.units).sorted(by: >))
    }

    func testBandCarriesTheInsulinOnBoard() throws {
        let treatments = [ExperimentalTreatment(date: start, amount: 6, kind: .bolus, notes: nil)]
        let dates = InsulinActivityStack.sampleDates(from: start, to: start.addingTimeInterval(3 * 3600), treatments: treatments)
        let band = InsulinActivityStack.band(treatments: treatments, dates: dates, bolusDefault: .aspart, basalDefault: .glargineU100)
        let index = try XCTUnwrap(dates.firstIndex(of: start.addingTimeInterval(3600)))
        XCTAssertEqual(band.layers[0].onBoard[index], 4.5093, accuracy: 0.001)
        XCTAssertEqual(band.layers[0].onBoard[0], 6, accuracy: 1e-9)
    }

    func testPlotsReadTheInsulinOnBoardNearestTheCursor() {
        var plots = GlucoseChartExperimentalPlots()
        plots.insulin = [GlucoseChartExperimentalPlots.InsulinLayer(
            id: "aspart", name: "NovoRapid", color: .blue,
            points: [GlucoseChartExperimentalPlots.InsulinPoint(date: start, bottom: 0, top: 1, onBoard: 3),
                     GlucoseChartExperimentalPlots.InsulinPoint(date: start.addingTimeInterval(300), bottom: 0, top: 1, onBoard: 2.8)],
            countsTowardIOB: true)]
        XCTAssertEqual(plots.onBoard(at: start.addingTimeInterval(200)).map(\.units), [2.8])
        XCTAssertTrue(plots.onBoard(at: start.addingTimeInterval(3600)).isEmpty)
    }

    func testUploadedBasalInjectionStillCountsButAnImportedNoteDoesNot() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreDataManager.mainManagedObjectContext
        // Uploaded to Nightscout: an id and the Note event type, as the treatment editor stores it.
        _ = TreatmentEntry(id: "uploaded", date: start, value: 20, treatmentType: .BasalInjection,
                           nightscoutEventType: ConstantsNightscout.noteEventType, enteredBy: "Test", notes: "Tresiba", nsManagedObjectContext: context)
        _ = TreatmentEntry(id: "imported", date: start, value: 4, treatmentType: .Insulin,
                           nightscoutEventType: "Correction Bolus", enteredBy: "Nightscout", nsManagedObjectContext: context)
        let policy = DataFlowPolicy(isMaster: true, followerDataSource: .nightscout, therapyDataSourceSelection: .none,
                                    nightscoutEnabled: false, masterUploadsGlucoseToNightscout: false,
                                    followerUploadsGlucoseToNightscout: false, nightscoutFollowType: .none)
        var treatments: [ExperimentalTreatment] = []
        context.performAndWait {
            treatments = ExperimentalTreatment.fetch(from: start.addingTimeInterval(-60), to: start.addingTimeInterval(60),
                                                     in: context, policy: policy) ?? []
        }
        XCTAssertEqual(treatments.map(\.kind), [.basalInjection])
        XCTAssertEqual(treatments.first?.insulin(bolusDefault: .aspart, basalDefault: .glargineU100), .degludec)
    }

    // MARK: Chart cursor

    func testCursorFindsTheNearestReading() {
        let dates = [0, 5, 10, 15].map { start.addingTimeInterval(TimeInterval($0 * 60)) }
        XCTAssertEqual(RootHomeMainChartView.nearestIndex(in: dates, to: start.addingTimeInterval(7 * 60)), 1)
        XCTAssertEqual(RootHomeMainChartView.nearestIndex(in: dates, to: start.addingTimeInterval(8 * 60)), 2)
        XCTAssertEqual(RootHomeMainChartView.nearestIndex(in: dates, to: start.addingTimeInterval(-60)), 0)
        XCTAssertEqual(RootHomeMainChartView.nearestIndex(in: dates, to: start.addingTimeInterval(99 * 60)), 3)
        XCTAssertNil(RootHomeMainChartView.nearestIndex(in: [], to: start))
    }

    func testCursorGeometryMapsTimeAndGlucose() {
        let geometry = GlucoseChartCursorGeometry()
        XCTAssertNil(geometry.date(atX: 10))
        geometry.update(plotRect: CGRect(x: 10, y: 0, width: 200, height: 100), xDomain: start...start.addingTimeInterval(3600), yDomain: 40...240)
        XCTAssertEqual(geometry.date(atX: 110), start.addingTimeInterval(1800))
        XCTAssertEqual(geometry.date(atX: -50), start)
        XCTAssertEqual(geometry.x(for: start.addingTimeInterval(900)), 60)
        XCTAssertEqual(geometry.y(forMgDl: 140), 50)
    }

    // MARK: Chart helpers

    func testGlucoseLineBreaksAtGapsAndChangesColourWithTheRange() {
        let dates = [0, 5, 10, 15, 40].map { start.addingTimeInterval(TimeInterval($0 * 60)) }
        let runs = GlucoseChartExperimentalPlots.lineRuns(values: [100, 110, 200, 210, 220], dates: dates) { $0 >= 180 ? .red : .green }
        XCTAssertEqual(runs.map { $0.points.map(\.mgDl) }, [[100, 110, 200], [200, 210], [220]])
        XCTAssertEqual(runs.map(\.color), [.green, .red, .red])
    }

    func testPredictionIsCutAtTheChartEdge() {
        var plots = GlucoseChartExperimentalPlots()
        plots.prediction = [0, 5, 10].map { GlucoseChartExperimentalPlots.PredictionPoint(date: start.addingTimeInterval(TimeInterval($0 * 60)), mgDl: 100 + Double($0)) }
        let points = plots.predictionPoints(until: start.addingTimeInterval(7.5 * 60))
        XCTAssertEqual(points.map(\.mgDl), [100, 105, 107.5])
    }

    // MARK: Body weight, periods, macros, intensity

    func testBodyWeightSelectsTheDosePerKilogramCurve() {
        // 14 U at 70 kg is Fiasp's 0.2 U/kg study dose; without a weight the 0.1 U/kg reference applies.
        let weighted = InsulinCurveCatalogue.curve(for: .fiasp, units: 14, bodyWeightKg: 70)
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction(weighted, elapsedMinutes: 120), 0.439_609_643, accuracy: 1e-6)
        let reference = InsulinCurveCatalogue.curve(for: .fiasp, units: 14)
        XCTAssertEqual(InsulinCurveMath.cumulativeFraction(reference, elapsedMinutes: 120), 0.552_955_201, accuracy: 1e-6)
        XCTAssertEqual(InsulinCurveCatalogue.curve(for: .fiasp, units: 14, bodyWeightKg: 5), reference)
    }

    func testPeriodsReplaceTheSingleValuesFromTheirStart() {
        var model = ExperimentalPredictionModel()
        model.timeZone = TimeZone(identifier: "UTC")!
        model.periods = [ExperimentalPredictionPeriod(startMinute: 360, carbRatio: 8, insulinSensitivityMgDl: 40, carbAbsorption: 30)]
        let midnight = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
        XCTAssertEqual(model.parameters(at: midnight.addingTimeInterval(5 * 3600)).carbRatio, ExperimentalPredictionModel.defaultCarbRatio)
        let morning = model.parameters(at: midnight.addingTimeInterval(7 * 3600))
        XCTAssertEqual(morning.carbRatio, 8)
        XCTAssertEqual(morning.insulinSensitivityMgDl, 40)
        XCTAssertEqual(morning.carbAbsorption, 30)
    }

    func testPeriodsEncodeSortedUniqueAndClamped() {
        let periods = [ExperimentalPredictionPeriod(startMinute: 720, carbRatio: 50, insulinSensitivityMgDl: 54, carbAbsorption: 35),
                       ExperimentalPredictionPeriod(startMinute: 360, carbRatio: 8, insulinSensitivityMgDl: 40, carbAbsorption: 30),
                       ExperimentalPredictionPeriod(startMinute: 360, carbRatio: 9, insulinSensitivityMgDl: 41, carbAbsorption: 31)]
        let decoded = ExperimentalPredictionPeriod.decode(ExperimentalPredictionPeriod.encode(periods))
        XCTAssertEqual(decoded.map(\.startMinute), [360, 720])
        XCTAssertEqual(decoded.first?.carbRatio, 8)
        XCTAssertEqual(decoded.last?.carbRatio, 30)
        XCTAssertEqual(ExperimentalPredictionPeriod.sanitized((1...10).map {
            ExperimentalPredictionPeriod(startMinute: $0 * 60, carbRatio: 10, insulinSensitivityMgDl: 54, carbAbsorption: 35) }).count, 7)
    }

    func testProteinAndFatAddJugglucoNGsDelayedTail() {
        var model = ExperimentalPredictionModel()
        model.macrosEnabled = true
        let meal = ExperimentalTreatment(date: start, amount: 40, kind: .carbs, notes: ExperimentalTreatment.macrosNotes(protein: 20, fat: 15))
        XCTAssertEqual(meal.notes, "P:20 F:15")
        XCTAssertEqual(meal.macros?.protein, 20)
        XCTAssertEqual(meal.macros?.fat, 15)
        // 216 mg/dL from the carbs plus 11.825 g equivalent from 2.15 fat-protein units.
        XCTAssertEqual(model.treatmentDelta(meal, at: start.addingTimeInterval(7 * 3600), baseline: start), 279.855, accuracy: 1e-6)
        model.macrosEnabled = false
        XCTAssertEqual(model.treatmentDelta(meal, at: start.addingTimeInterval(7 * 3600), baseline: start), 216, accuracy: 1e-9)
    }

    func testExerciseIntensityScalesTheDrop() {
        let model = ExperimentalPredictionModel()
        let intense = ExperimentalTreatment(date: start, amount: 60, kind: .exercise, notes: "intensity:intense")
        XCTAssertEqual(intense.intensity, .intense)
        XCTAssertEqual(model.treatmentDelta(intense, at: start.addingTimeInterval(3600), baseline: start), -11.88, accuracy: 1e-9)
        let unknown = ExperimentalTreatment(date: start, amount: 60, kind: .exercise, notes: nil)
        XCTAssertEqual(model.treatmentDelta(unknown, at: start.addingTimeInterval(3600), baseline: start), -5.94, accuracy: 1e-9)
    }

    // MARK: Prediction accuracy

    func testAccuracyScoresEachHorizonAgainstTheReadingsThatFollowed() throws {
        let readings = (0...12).map { (date: start.addingTimeInterval(TimeInterval($0 * 5 * 60)), mgDl: 100 + Double($0) * 2) }
        let forecast = RecordedForecast(origin: start, originMgDl: 100, predicted: [15: 110, 30: 120, 60: 90, 120: 100])
        let report = PredictionAccuracy.report(forecasts: [forecast], readings: readings, now: start.addingTimeInterval(60 * 60))
        let byHorizon = Dictionary(uniqueKeysWithValues: report.map { ($0.horizonMinutes, $0) })
        XCTAssertEqual(byHorizon[15]?.meanAbsoluteError, 4)
        XCTAssertEqual(byHorizon[30]?.bias, 8)
        XCTAssertEqual(byHorizon[60]?.bias, -34)
        XCTAssertEqual(byHorizon[60]?.noChangeMeanAbsoluteError, 24)
        XCTAssertEqual(byHorizon[120]?.count, 0)
        XCTAssertEqual(byHorizon[120]?.pending, 1)
        // Between readings five minutes apart the value is interpolated.
        XCTAssertEqual(try XCTUnwrap(PredictionAccuracy.actual(at: start.addingTimeInterval(150), readings: readings, maximumGap: 12.5 * 60)), 101, accuracy: 1e-9)
        XCTAssertEqual(PredictionAccuracy.maximumGap(readings: readings), 12.5 * 60)
    }

    func testRecordKeepsTheForecastAtEachScoredHorizon() throws {
        let points = (0...24).map { GlucosePredictionPoint(date: start.addingTimeInterval(TimeInterval($0 * 5 * 60)), value: 100 + Double($0), confidence: 1, unclampedValue: 100 + Double($0)) }
        let record = try XCTUnwrap(PredictionAccuracyRecorder.record(from: points))
        XCTAssertEqual(record.originMgDl, 100)
        XCTAssertEqual(record.predicted, [15: 103, 30: 106, 60: 112, 120: 124])
    }

    // MARK: Nightscout

    func testNightscoutForecastUsesTheOpenAPSPredBGsShape() throws {
        let points = (0...3).map { GlucosePredictionPoint(date: start.addingTimeInterval(TimeInterval($0 * 5 * 60)), value: 120.4 - Double($0), confidence: 1, unclampedValue: 0) }
        let status = try XCTUnwrap(ExperimentalNightscoutPrediction.deviceStatus(forecast: points, now: start))
        XCTAssertEqual(status["device"] as? String, "xDrip4iOS")
        let suggested = try XCTUnwrap((status["openaps"] as? [String: Any])?["suggested"] as? [String: Any])
        XCTAssertEqual(suggested["bg"] as? Int, 120)
        XCTAssertEqual((suggested["predBGs"] as? [String: [Int]])?["IOB"], [120, 119, 118, 117])
        XCTAssertNil(ExperimentalNightscoutPrediction.deviceStatus(forecast: Array(points.prefix(1)), now: start))
    }

    // MARK: Sibionics manual sensitivity

    func testManualSensitivityOverridesEveryCodeWhenSupported() {
        let automatic = Sibionics2FactorySensitivity.effectiveSensitivity(advertisedName: nil, variant: .sibionics1, sibionics1Family: .chinese)
        XCTAssertEqual(automatic, 1.27, accuracy: 1e-9)
        XCTAssertEqual(Sibionics2FactorySensitivity.effectiveSensitivity(advertisedName: nil, variant: .sibionics1, sibionics1Family: .chinese,
                                                                          manualSensitivity: 1.5), 1.5)
        XCTAssertEqual(Sibionics2FactorySensitivity.effectiveSensitivity(advertisedName: nil, variant: .sibionics1, sibionics1Family: .chinese,
                                                                          manualSensitivity: 3.0), automatic)
    }

    // MARK: Predicted low alert

    private func forecast(_ values: [Double]) -> [GlucosePredictionPoint] {
        values.enumerated().map { GlucosePredictionPoint(date: start.addingTimeInterval(TimeInterval($0.offset * 5 * 60)), value: $0.element, confidence: 1, unclampedValue: $0.element) }
    }

    func testPredictedLowFiresOnlyWithinTheLeadTimeAndWhileStillAbove() throws {
        let points = forecast([95, 90, 85, 78, 72, 68])
        XCTAssertNil(PredictedLowAlert.crossing(forecast: points, currentMgDl: 95, thresholdMgDl: 70, leadMinutes: 20))
        let crossing = try XCTUnwrap(PredictedLowAlert.crossing(forecast: points, currentMgDl: 95, thresholdMgDl: 70, leadMinutes: 25))
        XCTAssertEqual(crossing.minutes, 25)
        XCTAssertEqual(crossing.mgDl, 68)
        // Already below: the ordinary low alert covers it.
        XCTAssertNil(PredictedLowAlert.crossing(forecast: points, currentMgDl: 65, thresholdMgDl: 70, leadMinutes: 30))
        XCTAssertNil(PredictedLowAlert.crossing(forecast: [], currentMgDl: 95, thresholdMgDl: 70, leadMinutes: 30))
    }

    func testPredictedLowIsANewDisabledByDefaultGlucoseAlert() {
        XCTAssertEqual(AlertKind.predictedLow.rawValue, 16)
        XCTAssertTrue(AlertKind.predictedLow.defaultIsDisabled())
        XCTAssertTrue(AlertKind.predictedLow.valueIsABgValue())
        XCTAssertEqual(AlertKind.predictedLow.defaultAlertValue(), ConstantsDefaultAlertLevels.low)
        let kinds = AlertKind.visibleAlertKinds(for: .Libre2)
        XCTAssertEqual(kinds.firstIndex(of: .predictedLow), (kinds.firstIndex(of: .low) ?? -2) + 1)
    }

    // MARK: Settings

    func testSettingsDefaultsAndClamping() {
        let suite = "ExperimentalFeaturesTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.experimentalPredictionEnabled)
        XCTAssertTrue(defaults.experimentalPredictionTrendMomentum)
        XCTAssertEqual(defaults.experimentalPredictionHorizonMinutes, 120)
        XCTAssertEqual(defaults.experimentalPredictionInsulinSensitivityMgDl, 54)
        XCTAssertEqual(defaults.experimentalGlucoseChartStyle, .points)
        defaults.set(75, forKey: "experimentalPredictionHorizonMinutes")
        XCTAssertEqual(defaults.experimentalPredictionHorizonMinutes, 120)
        defaults.experimentalPredictionCarbRatio = 50
        XCTAssertEqual(defaults.experimentalPredictionCarbRatio, 30)
        defaults.set(55.0, forKey: "localInsulinPeak")
        XCTAssertEqual(defaults.experimentalBolusInsulin, .fiasp)
        defaults.experimentalBolusInsulin = .lispro
        XCTAssertEqual(defaults.experimentalBolusInsulin, .lispro)
    }

    @MainActor
    func testExperimentalSectionSitsBeforeAboutWithItsFourRows() throws {
        let sections = SettingsListFactory.makeRootSections(coreDataManager: nil, selectedFollowerActions: .none,
                                                            presenter: SettingsActionPresenter(router: SettingsRouter()))
        let experimentalID = SettingsRootSection.experimental.rawValue * 10
        let index = try XCTUnwrap(sections.firstIndex { $0.id == experimentalID })
        let aboutIndex = try XCTUnwrap(sections.firstIndex { $0.id == SettingsRootSection.about.rawValue * 10 })
        XCTAssertLessThan(index, aboutIndex)
        XCTAssertEqual(sections[index].section().rows.map(\.id),
                       ["experimental.chartStyle", "experimental.chartCursor", "experimental.prediction", "experimental.insulins"])
    }
}

/// JugglucoNG `AdaptiveGlucoseForecastTests`: the adaptive forecast learns only from the past,
/// needs two days before it answers, never reads across a sensor change or a gap, survives a save
/// and load, and on data with a learnable pattern beats assuming no change. The expectations were
/// checked with a Python port of the Swift code on the same generated data.
final class AdaptiveGlucoseForecastTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let start: TimeInterval = 1_800_000_000
    private let minute: TimeInterval = 60
    private let day: TimeInterval = 24 * 60 * 60

    /// SplitMix64, so the generated history is the same on every run and in the Python check.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func between(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * (Double(next() >> 11) * 0x1p-53)
        }
    }

    /// Five-minute readings of a mean-reverting process with momentum: glucose drifts toward 130
    /// and a move tends to continue for a while.
    private func history(days: Double, seed: UInt64 = 1, sensorChangeAt: TimeInterval? = nil) -> AdaptiveHistory {
        var rng = SplitMix64(state: seed)
        let count = Int(days * 24 * 12)
        var glucose = 130.0, velocity = 0.0
        var times: [TimeInterval] = [], values: [Double] = []
        for index in 0..<count {
            velocity = 0.85 * velocity + 0.02 * (130.0 - glucose) + rng.between(-2.5, 2.5) + 1.5 * sin(2 * Double.pi * Double(index) / 288.0)
            glucose += velocity
            times.append(start + Double(index) * 5 * minute)
            values.append(min(max(glucose, 40), 400))
        }
        let sensors: [String?] = times.map { time in sensorChangeAt.map { time >= $0 } == true ? "B" : "A" }
        return AdaptiveHistory.of(times: times, mgDl: values, sensors: sensors)
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func keeping(_ history: AdaptiveHistory, _ keep: (TimeInterval) -> Bool) -> AdaptiveHistory {
        let indices = history.times.indices.filter { keep(history.times[$0]) }
        return AdaptiveHistory(times: indices.map { history.times[$0] }, mgDl: indices.map { history.mgDl[$0] },
                               segment: indices.map { history.segment[$0] })
    }

    func testNoModelBeforeTwoDaysOfHistory() throws {
        let short = history(days: 1.5)
        XCTAssertNil(AdaptiveGlucoseForecast.fit(short, now: date(try XCTUnwrap(short.times.last)), timeZone: utc))
        let model = try XCTUnwrap(AdaptiveGlucoseForecast.fit(history(days: 2.5), now: date(start + 2.5 * day), timeZone: utc))
        XCTAssertEqual(model.trainingRows, 701)
        XCTAssertNil(model.holdoutRMSE, "fewer than four days: nothing held back")
    }

    func testItLearnsOnlyFromOutcomesBeforeNow() throws {
        let now = start + 5 * day
        let past = history(days: 6)
        // Same past, a different future after `now`: the fitted model must be identical.
        let altered = AdaptiveHistory(times: past.times, mgDl: zip(past.times, past.mgDl).map { $0.0 <= now ? $0.1 : $0.1 * 0.5 + 60 },
                                      segment: past.segment)
        let a = try XCTUnwrap(AdaptiveGlucoseForecast.fit(past, now: date(now), timeZone: utc))
        let b = try XCTUnwrap(AdaptiveGlucoseForecast.fit(altered, now: date(now), timeZone: utc))
        XCTAssertEqual(a, b)
    }

    func testItBeatsNoChangeOnALearnablePattern() throws {
        let train = history(days: 10, seed: 3)
        let model = try XCTUnwrap(AdaptiveGlucoseForecast.fit(train, now: date(try XCTUnwrap(train.times.last)), timeZone: utc))
        XCTAssertNotNil(model.holdoutRMSE, "holdout checked on 10 days")
        XCTAssertTrue(model.isReliable)

        // Fresh data from the same process, never seen in training.
        let test = history(days: 3, seed: 9)
        let k30 = try XCTUnwrap(model.horizons.firstIndex(of: 30))
        var squaredModel = 0.0, squaredNoChange = 0.0, count = 0
        for index in 24..<(test.count - 6) {
            guard let deltas = AdaptiveGlucoseForecast.forecastDeltas(model, history: test, origin: date(test.times[index]), timeZone: utc),
                  let delta = deltas[k30] else { continue }
            let actual = test.mgDl[index + 6] - test.mgDl[index]
            squaredModel += (delta - actual) * (delta - actual)
            squaredNoChange += actual * actual
            count += 1
        }
        XCTAssertGreaterThan(count, 500)
        // The Python port measures 0.43 here.
        XCTAssertLessThan(squaredModel, squaredNoChange * 0.9)
    }

    func testFeaturesNeverReachAcrossASensorChange() throws {
        let change = start + 3 * day
        let changed = history(days: 4, sensorChangeAt: change)
        let model = try XCTUnwrap(AdaptiveGlucoseForecast.fit(changed, now: date(start + 4 * day - 10 * minute), timeZone: utc))
        // Within the new sensor's first hour the past hour belongs to the old sensor: no answer.
        XCTAssertNil(AdaptiveGlucoseForecast.forecastDeltas(model, history: changed, origin: date(change + 30 * minute), timeZone: utc))
        XCTAssertNotNil(AdaptiveGlucoseForecast.forecastDeltas(model, history: changed, origin: date(change + 65 * minute), timeZone: utc))
    }

    func testAGapLeavesNoFeaturesUntilAnHourOfReadingsIsBack() throws {
        let gapStart = start + 2 * day
        let gapped = keeping(history(days: 3)) { !(gapStart...(gapStart + 3 * 60 * minute)).contains($0) }
        let model = try XCTUnwrap(AdaptiveGlucoseForecast.fit(history(days: 3), now: date(start + 3 * day - 10 * minute), timeZone: utc))
        let firstAfter = gapStart + 3 * 60 * minute + 5 * minute
        XCTAssertNil(AdaptiveGlucoseForecast.forecastDeltas(model, history: gapped, origin: date(firstAfter), timeZone: utc))
        XCTAssertNotNil(AdaptiveGlucoseForecast.forecastDeltas(model, history: gapped, origin: date(firstAfter + 60 * minute), timeZone: utc))
    }

    func testAHoleInsideTheHourIsCaughtEvenWhenEverySpotLookupLands() throws {
        // Readings at t−60 and from t−35 on: the 5/15/30/60-minute lookups all find values, but
        // 25 minutes of the hour are missing, so the features must not be formed.
        let full = history(days: 3)
        let t = full.times[full.count - 40]
        let holed = keeping(full) { $0 <= t - 60 * minute || $0 >= t - 35 * minute }
        let model = try XCTUnwrap(AdaptiveGlucoseForecast.fit(full, now: date(try XCTUnwrap(full.times.last)), timeZone: utc))
        XCTAssertNotNil(AdaptiveGlucoseForecast.forecastDeltas(model, history: full, origin: date(t), timeZone: utc))
        XCTAssertNil(AdaptiveGlucoseForecast.forecastDeltas(model, history: holed, origin: date(t), timeZone: utc))
    }

    func testASavedModelLoadsBackTheSame() throws {
        let model = try XCTUnwrap(AdaptiveGlucoseForecast.fit(history(days: 5), now: date(start + 5 * day - 10 * minute), timeZone: utc))
        let loaded = try XCTUnwrap(AdaptiveForecastModel.decode(model.encoded()))
        XCTAssertEqual(loaded, model)
        let other = AdaptiveForecastModel(version: 99, trainedAt: model.trainedAt, horizons: model.horizons, means: model.means,
                                          scales: model.scales, weights: model.weights, trainingRows: model.trainingRows,
                                          trainingDays: model.trainingDays, holdoutRMSE: model.holdoutRMSE,
                                          holdoutNoChangeRMSE: model.holdoutNoChangeRMSE)
        XCTAssertNil(AdaptiveForecastModel.decode(other.encoded()), "another version is not loaded")
        XCTAssertNil(AdaptiveForecastModel.decode(Data("garbage".utf8)))
    }

    func testReliabilityAllowsTwoPercentOverNoChange() {
        func model(_ holdout: Double?, _ noChange: Double?) -> AdaptiveForecastModel {
            AdaptiveForecastModel(version: 1, trainedAt: Date(), horizons: [30], means: [], scales: [], weights: [nil], trainingRows: 0,
                                  trainingDays: 0, holdoutRMSE: holdout, holdoutNoChangeRMSE: noChange)
        }
        XCTAssertTrue(model(nil, nil).isReliable)
        XCTAssertTrue(model(10, 9.9).isReliable)
        XCTAssertFalse(model(10.2, 9.9).isReliable)
    }

    func testPointsFollowTheHorizonWithTheStandardConfidenceRamp() throws {
        let origin = date(start)
        let points = try XCTUnwrap(AdaptiveGlucoseForecast.points(baseline: (origin, 100), deltas: Array(repeating: 10, count: 24),
                                                                   horizons: AdaptiveGlucoseForecast.horizons, horizonMinutes: 30))
        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points.last?.date, origin.addingTimeInterval(30 * minute))
        XCTAssertEqual(points.last?.value, 110)
        XCTAssertEqual(points[3].confidence, 0.88 - 0.62 * sqrt(0.5), accuracy: 1e-12)
        XCTAssertEqual(points[6].confidence, 0.26, accuracy: 1e-12)
        // At most two hours, whatever the forecast length; values clamped like the chart's.
        let low = try XCTUnwrap(AdaptiveGlucoseForecast.points(baseline: (origin, 100), deltas: Array(repeating: -100, count: 24),
                                                                horizons: AdaptiveGlucoseForecast.horizons, horizonMinutes: 240))
        XCTAssertEqual(low.count, 25)
        XCTAssertEqual(low.last?.value, 18)
        XCTAssertEqual(low.last?.unclampedValue, 0)
    }

    func testGaussianSolve() {
        let x = AdaptiveGlucoseForecast.gaussianSolve([[2, 1], [1, 3]], [3, 5])
        XCTAssertEqual(x[0], 0.8, accuracy: 1e-12)
        XCTAssertEqual(x[1], 1.4, accuracy: 1e-12)
    }

    func testChartReadingsNewerThanTheStoreJoinTheNewestSensor() {
        var readings = AdaptiveReadings(times: [start, start + 300], mgDl: [100, 110], sensors: ["s1", "s1"])
        readings.appendNewer(dates: [date(start + 300), date(start + 600), date(start + 900)], values: [110, 120, 130],
                             until: date(start + 600))
        XCTAssertEqual(readings.times, [start, start + 300, start + 600])
        XCTAssertEqual(readings.mgDl, [100, 110, 120])
        XCTAssertEqual(readings.sensors, ["s1", "s1", "s1"])
    }

    func testWithoutAModelTheStandardForecastWithoutTrendIsShown() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AdaptiveGlucoseForecastTests"))
        defaults.removePersistentDomain(forName: "AdaptiveGlucoseForecastTests")
        let standard = [GlucosePredictionPoint(date: date(start), value: 100, confidence: 1, unclampedValue: 100),
                        GlucosePredictionPoint(date: date(start + 300), value: 101, confidence: 0.8, unclampedValue: 101)]
        var askedMomentum: Bool?
        let shown = AdaptiveForecastStore.shownForecast(readings: AdaptiveReadings(), standard: { askedMomentum = $0; return standard },
                                                        horizonMinutes: 120, defaults: defaults, now: date(start + 300))
        XCTAssertFalse(shown.isAdaptive)
        XCTAssertEqual(shown.points, standard)
        XCTAssertEqual(askedMomentum, false)
        XCTAssertEqual(AdaptiveForecastStore.status(defaults: defaults), .learning)
    }
}
