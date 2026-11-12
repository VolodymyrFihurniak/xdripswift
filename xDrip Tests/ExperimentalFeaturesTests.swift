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

    // MARK: Predicted low evidence (JugglucoNG ForecastLowConfidencePolicy)

    private func evidence(_ policy: inout PredictedLowEvidence, current: Double, projected: Double = 65, rate: Double = -1,
                          at minutes: Double = 0, next30: Double? = nil, classic: Double? = nil, cob: Double = 0,
                          baseline: Double? = nil) -> PredictedLowEvidence.Decision {
        let date = start.addingTimeInterval(minutes * 60)
        return policy.evaluate(currentMgDl: current, thresholdMgDl: 70, projectedMgDl: projected, rate: rate, readingDate: date, now: date,
                               iobNext30: next30, classicIOB: classic, cobGrams: cob, carbRatio: 10, insulinSensitivityMgDl: 54,
                               recentRiseBaseline: baseline)
    }

    func testPredictedLowEvidenceUrgentCasesAlertAtOnce() {
        var policy = PredictedLowEvidence()
        XCTAssertEqual(evidence(&policy, current: 85), .nearThreshold)
        policy = PredictedLowEvidence()
        // 30 mg/dL above at 4 mg/dL a minute: 7.5 minutes away.
        XCTAssertEqual(evidence(&policy, current: 100, rate: -4), .imminent)
        policy = PredictedLowEvidence()
        // 1 U in the next 30 minutes at 54 mg/dL per unit explains more than half of 50 mg/dL.
        XCTAssertEqual(evidence(&policy, current: 120, next30: 1, classic: 2), .insulinSupported)
    }

    func testPredictedLowEvidenceNeedsASecondReadingOtherwise() {
        var policy = PredictedLowEvidence()
        XCTAssertEqual(evidence(&policy, current: 120), .confirming)
        // The same reading again (a second check) does not confirm.
        XCTAssertEqual(evidence(&policy, current: 120), .confirming)
        XCTAssertEqual(evidence(&policy, current: 115, at: 5), .confirmed)
        // A rise starts over.
        XCTAssertEqual(evidence(&policy, current: 118, at: 10), .confirming)
    }

    func testPredictedLowEvidenceRejectsFlatTrendAndCoveredByCarbs() {
        var policy = PredictedLowEvidence()
        XCTAssertEqual(evidence(&policy, current: 120, rate: -0.3), .noCandidate)
        // 5 g at 10 g/U and 54 mg/dL per unit is 27 mg/dL: more than the 5 mg/dL shortfall.
        XCTAssertEqual(evidence(&policy, current: 85, cob: 5), .coveredByCarbs)
        XCTAssertFalse(PredictedLowEvidence.cobCoversLow(projectedMgDl: 60, thresholdMgDl: 70, cobGrams: 1, carbRatio: 10, insulinSensitivityMgDl: 54))
        XCTAssertFalse(PredictedLowEvidence.Decision.coveredByCarbs.allowsAlert)
        XCTAssertTrue(PredictedLowEvidence.Decision.confirmed.allowsAlert)
    }

    func testPredictedLowEvidenceWaitsForAReturnToBaselineOnlyWithoutInsulin() {
        var policy = PredictedLowEvidence()
        XCTAssertEqual(evidence(&policy, current: 120, next30: 0, classic: 0, baseline: 118), .returningToBaseline)
        XCTAssertEqual(evidence(&policy, current: 110, at: 5, next30: 0, classic: 0, baseline: 118), .belowBaseline)
        policy = PredictedLowEvidence()
        // Unknown insulin does not qualify for the wait.
        XCTAssertEqual(evidence(&policy, current: 120, baseline: 118), .confirming)
    }

    func testRecentRiseBaselineFindsAQuietBaselineBeforeARise() {
        // Ten quiet minutes at 100, a rise to 120 in five minutes, then two minutes of falling.
        let values: [Double] = Array(repeating: 100, count: 10) + [104, 108, 112, 116, 120, 116, 112]
        let readings = values.enumerated().map { (date: start.addingTimeInterval(Double($0.offset) * 60), mgDl: $0.element) }
        let now = start.addingTimeInterval(16 * 60)
        XCTAssertEqual(PredictedLowEvidence.recentRiseBaseline(readings: readings, now: now), 100)
        // A steady fall has no rise to return from.
        let falling = (0..<17).map { (date: start.addingTimeInterval(Double($0) * 60), mgDl: 150 - Double($0) * 2) }
        XCTAssertNil(PredictedLowEvidence.recentRiseBaseline(readings: falling, now: now))
        XCTAssertEqual(try XCTUnwrap(PredictedLowEvidence.rate(readings: falling, now: now)), -2, accuracy: 1e-9)
    }

    func testInsulinAndCarbsOnBoardForTheEvidence() {
        let model = ExperimentalPredictionModel()
        let treatments = [ExperimentalTreatment(date: start, amount: 6, kind: .bolus, notes: nil),
                          ExperimentalTreatment(date: start, amount: 20, kind: .basalInjection, notes: nil),
                          ExperimentalTreatment(date: start, amount: 35, kind: .carbs, notes: nil)]
        let insulin = PredictedLowEvidence.insulin(treatments: treatments, model: model, at: start.addingTimeInterval(3600))
        // Aspart after an hour (Python port): 4.5093 U left; basal does not count.
        XCTAssertEqual(insulin.classic, 4.5093, accuracy: 0.001)
        XCTAssertGreaterThan(insulin.next30, 0)
        XCTAssertLessThan(insulin.next30, insulin.classic)
        // 35 g at 35 g/h is absorbed linearly over an hour.
        XCTAssertEqual(PredictedLowEvidence.carbsOnBoard(treatments: treatments, model: model, at: start.addingTimeInterval(1800)), 17.5, accuracy: 1e-9)
    }

    // MARK: Alarm additions

    func testHighAlarmIsQuietOnlyWhileFalling() {
        let earlier = start, later = start.addingTimeInterval(300)
        XCTAssertTrue(AlertKind.isFalling(newest: (later, 197), previous: (earlier, 200)))
        XCTAssertFalse(AlertKind.isFalling(newest: (later, 199), previous: (earlier, 200)))
        XCTAssertFalse(AlertKind.isFalling(newest: (later, 205), previous: (earlier, 200)))
        // Readings too far apart say nothing about the trend.
        XCTAssertFalse(AlertKind.isFalling(newest: (start.addingTimeInterval(900), 150), previous: (earlier, 200)))
    }

    func testSignalRestoredNeedsALossAndNotifiesOncePerReading() {
        let previous = start, newest = start.addingTimeInterval(40 * 60)
        XCTAssertTrue(AlertManager.signalWasRestored(newest: newest, previous: previous, lossMinutes: 30, lastNotified: nil))
        XCTAssertFalse(AlertManager.signalWasRestored(newest: newest, previous: previous, lossMinutes: 30, lastNotified: newest))
        XCTAssertFalse(AlertManager.signalWasRestored(newest: start.addingTimeInterval(300), previous: previous, lossMinutes: 30, lastNotified: nil))
        XCTAssertFalse(AlertManager.signalWasRestored(newest: newest, previous: nil, lossMinutes: 30, lastNotified: nil))
    }

    // MARK: eIOB, Nightscout IOB/COB, grouped markers

    func testEffectiveInsulinIsZeroAtTheDoseAndNeverAboveIOB() throws {
        let treatments = [ExperimentalTreatment(date: start, amount: 6, kind: .bolus, notes: nil)]
        let atDose = try XCTUnwrap(InsulinActivityStack.onBoard(treatments: treatments, at: start, bolusDefault: .aspart, basalDefault: .glargineU100).first)
        XCTAssertEqual(atDose.units, 6, accuracy: 1e-9)
        XCTAssertEqual(atDose.effectiveUnits, 0, accuracy: 1e-9)
        let later = try XCTUnwrap(InsulinActivityStack.onBoard(treatments: treatments, at: start.addingTimeInterval(3600), bolusDefault: .aspart, basalDefault: .glargineU100).first)
        XCTAssertGreaterThan(later.effectiveUnits, 0)
        XCTAssertLessThanOrEqual(later.effectiveUnits, later.units)
    }

    func testDeviceStatusCarriesIOBAndCOBWhenGiven() throws {
        let points = (0...2).map { GlucosePredictionPoint(date: start.addingTimeInterval(Double($0) * 300), value: 100, confidence: 1, unclampedValue: 100) }
        let status = try XCTUnwrap(ExperimentalNightscoutPrediction.deviceStatus(forecast: points, now: start, iob: 2.345, cob: 17.54))
        let openaps = try XCTUnwrap(status["openaps"] as? [String: Any])
        XCTAssertEqual((openaps["iob"] as? [String: Any])?["iob"] as? Double, 2.35)
        let suggested = try XCTUnwrap(openaps["suggested"] as? [String: Any])
        XCTAssertEqual(suggested["COB"] as? Double, 17.5)
        XCTAssertEqual(suggested["IOB"] as? Double, 2.35)
        let plain = try XCTUnwrap(ExperimentalNightscoutPrediction.deviceStatus(forecast: points, now: start)?["openaps"] as? [String: Any])
        XCTAssertNil(plain["iob"])
    }

    func testOverlappingMarkersBecomeOneWithTotalAndCount() {
        func point(_ seconds: TimeInterval, _ value: Double) -> GlucoseChartTreatmentPoint {
            GlucoseChartTreatmentPoint(date: start.addingTimeInterval(seconds), yValue: 100, treatmentValue: value, label: "\(Int(value))", notes: nil, idPrefix: "bolus")
        }
        let grouped = GlucoseChartExperimentalPlots.grouped([point(0, 2), point(60, 3), point(3600, 4)], minimumSeconds: 300, fractionDigits: 2, idPrefix: "group")
        XCTAssertEqual(grouped.map(\.treatmentValue), [5, 4])
        XCTAssertEqual(grouped.map(\.label), ["5 ×2", "4"])
        XCTAssertEqual(grouped.first?.date, start.addingTimeInterval(60))
    }

    // MARK: Dose hints (JugglucoNG StateDoseHintCalculator)

    private func line(from mgDl: Double, slope: Double, minutes: Int = 30) -> [(date: Date, mgDl: Double)] {
        (0...minutes / 5).map { (date: start.addingTimeInterval(Double($0) * 300), mgDl: mgDl + slope * Double($0) * 5) }
    }

    private func hint(_ readings: [(date: Date, mgDl: Double)], iob: Double, inRange: Bool = false) -> DoseHintCalculator.Hint? {
        DoseHintCalculator.hint(readings: readings, highMgDl: 180, targetMgDl: 90, iobUnits: iob, insulinSensitivityMgDl: 54,
                                carbRatio: 10, correctInRange: inRange, now: start.addingTimeInterval(30 * 60))
    }

    func testCarbHintForAFallWithInsulinOnBoard() throws {
        // 165 falling 1.5 mg/dL a minute to 120: 20 minutes from the target of 90; in 45 minutes at 52.5.
        let falling = line(from: 165, slope: -1.5)
        XCTAssertEqual(try XCTUnwrap(DoseHintCalculator.recencyWeightedSlope(falling)), -1.5, accuracy: 1e-9)
        let carbs = try XCTUnwrap(hint(falling, iob: 2))
        XCTAssertTrue(carbs.isCarbs)
        XCTAssertEqual(carbs.minutesAhead, 20)
        // 37.5 mg/dL to make up: 37.5 / 54 x 10 g = 6.9, rounded up.
        XCTAssertEqual(carbs.amount, 7)
        // A slower fall needs under 5 g: nothing worth showing.
        XCTAssertNil(hint(line(from: 150, slope: -1), iob: 2))
        // Nothing on board: the fall is not insulin's doing, no hint.
        XCTAssertNil(hint(falling, iob: 0))
    }

    func testInsulinHintOnlyWhenHighAndNotComingDown() throws {
        let high = line(from: 250, slope: 0)
        // (250 - 90) / 54 = 2.96 U, minus 1 U on board = 1.96, down to 1.5.
        let correction = try XCTUnwrap(hint(high, iob: 1))
        XCTAssertFalse(correction.isCarbs)
        XCTAssertEqual(correction.amount, 1.5)
        XCTAssertNil(correction.minutesAhead)
        // Enough on board already.
        XCTAssertNil(hint(high, iob: 3))
        // In range: only when asked, and only well above the target.
        let inRange = line(from: 160, slope: 0)
        XCTAssertNil(hint(inRange, iob: 0))
        XCTAssertEqual(hint(inRange, iob: 0, inRange: true)?.amount, 1)
        // Near the target nothing is hinted in either direction.
        XCTAssertNil(hint(line(from: 105, slope: 0), iob: 0, inRange: true))
    }

    func testRestrictedModePINIsFourToEightDigits() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RestrictedModeTests"))
        defaults.removePersistentDomain(forName: "RestrictedModeTests")
        XCTAssertNil(RestrictedMode.pin(defaults: defaults))
        XCTAssertFalse(RestrictedMode.setPIN("123", defaults: defaults))
        XCTAssertFalse(RestrictedMode.setPIN("12a4", defaults: defaults))
        XCTAssertTrue(RestrictedMode.setPIN("1234", defaults: defaults))
        XCTAssertEqual(RestrictedMode.pin(defaults: defaults), "1234")
        RestrictedMode.setPIN(nil, defaults: defaults)
        XCTAssertNil(RestrictedMode.pin(defaults: defaults))
    }

    // MARK: Power saving

    func testPowerSavingNeverAppliesWhileChargingAndAutomaticFollowsLowPowerOrBattery() {
        XCTAssertFalse(ExperimentalPowerSaving.isActive(mode: .off, lowPowerMode: true, batteryLevel: 0.05, charging: false))
        XCTAssertTrue(ExperimentalPowerSaving.isActive(mode: .on, lowPowerMode: false, batteryLevel: 0.9, charging: false))
        XCTAssertFalse(ExperimentalPowerSaving.isActive(mode: .on, lowPowerMode: false, batteryLevel: 0.9, charging: true))
        XCTAssertTrue(ExperimentalPowerSaving.isActive(mode: .automatic, lowPowerMode: true, batteryLevel: 0.9, charging: false))
        XCTAssertTrue(ExperimentalPowerSaving.isActive(mode: .automatic, lowPowerMode: false, batteryLevel: 0.25, charging: false))
        XCTAssertFalse(ExperimentalPowerSaving.isActive(mode: .automatic, lowPowerMode: false, batteryLevel: 0.26, charging: false))
        XCTAssertFalse(ExperimentalPowerSaving.isActive(mode: .automatic, lowPowerMode: false, batteryLevel: nil, charging: false))
        XCTAssertFalse(ExperimentalPowerSaving.isActive(mode: .automatic, lowPowerMode: true, batteryLevel: 0.05, charging: true))
    }

    func testPowerSavingOffAlwaysRefreshes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ExperimentalPowerSavingTests"))
        defaults.removePersistentDomain(forName: "ExperimentalPowerSavingTests")
        XCTAssertTrue(ExperimentalPowerSaving.allowsRefresh("widgets", urgent: false, now: start, defaults: defaults))
        XCTAssertTrue(ExperimentalPowerSaving.allowsRefresh("widgets", urgent: false, now: start.addingTimeInterval(60), defaults: defaults))
        defaults.set(70.0, forKey: UserDefaults.Key.lowMarkValue.rawValue)
        defaults.set(180.0, forKey: UserDefaults.Key.highMarkValue.rawValue)
        XCTAssertTrue(ExperimentalPowerSaving.isUrgent(mgDl: 65, defaults: defaults))
        XCTAssertTrue(ExperimentalPowerSaving.isUrgent(mgDl: 190, defaults: defaults))
        XCTAssertFalse(ExperimentalPowerSaving.isUrgent(mgDl: 120, defaults: defaults))
        XCTAssertFalse(ExperimentalPowerSaving.isUrgent(mgDl: nil, defaults: defaults))
    }

    // MARK: Sibionics device information

    func testSibionicsInformationStringsAreReadOnceAndAnUnansweredReadIsNotRepeated() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SibionicsDeviceStatusTests"))
        defaults.removePersistentDomain(forName: "SibionicsDeviceStatusTests")
        let id = "AAAA"
        let available: [Sibionics2DeviceStatus.Field] = [.modelNumber, .firmwareRevision, .manufacturerName]
        XCTAssertEqual(Sibionics2DeviceStatus.nextFieldToRead(for: id, available: available, userDefaults: defaults), .modelNumber)
        Sibionics2DeviceStatus.beginRead(.modelNumber, for: id, userDefaults: defaults)
        Sibionics2DeviceStatus.finishRead(.modelNumber, value: "GS1", for: id, userDefaults: defaults)
        XCTAssertEqual(Sibionics2DeviceStatus.text(.modelNumber, for: id, userDefaults: defaults), "GS1")
        // The firmware read is never answered: the session ends with it pending.
        XCTAssertEqual(Sibionics2DeviceStatus.nextFieldToRead(for: id, available: available, userDefaults: defaults), .firmwareRevision)
        Sibionics2DeviceStatus.beginRead(.firmwareRevision, for: id, userDefaults: defaults)
        // Next connection: firmware is given up on, the manufacturer is next.
        XCTAssertEqual(Sibionics2DeviceStatus.nextFieldToRead(for: id, available: available, userDefaults: defaults), .manufacturerName)
        // An answer without a value is not asked for again either.
        Sibionics2DeviceStatus.beginRead(.manufacturerName, for: id, userDefaults: defaults)
        Sibionics2DeviceStatus.finishRead(.manufacturerName, value: nil, for: id, userDefaults: defaults)
        XCTAssertNil(Sibionics2DeviceStatus.nextFieldToRead(for: id, available: available, userDefaults: defaults))
        // Deleting the sensor forgets all of it.
        Sibionics2DeviceStatus.clear(for: id, userDefaults: defaults)
        XCTAssertEqual(Sibionics2DeviceStatus.nextFieldToRead(for: id, available: available, userDefaults: defaults), .modelNumber)
    }

    func testSibionicsConnectionLogKeepsTheNewestEventsAndSkipsQuickRepeats() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SibionicsConnectionLogTests"))
        defaults.removePersistentDomain(forName: "SibionicsConnectionLogTests")
        Sibionics2ConnectionLog.add("connected", for: "id", at: start, userDefaults: defaults)
        Sibionics2ConnectionLog.add("connected", for: "id", at: start.addingTimeInterval(5), userDefaults: defaults)
        Sibionics2ConnectionLog.add("connected", for: "id", at: start.addingTimeInterval(20), userDefaults: defaults)
        XCTAssertEqual(Sibionics2ConnectionLog.entries(for: "ID", userDefaults: defaults).count, 2)
        for index in 0..<(Sibionics2ConnectionLog.maximumEntries + 5) {
            Sibionics2ConnectionLog.add("event \(index)", for: "id", at: start.addingTimeInterval(100 + Double(index)), userDefaults: defaults)
        }
        let entries = Sibionics2ConnectionLog.entries(for: "id", userDefaults: defaults)
        XCTAssertEqual(entries.count, Sibionics2ConnectionLog.maximumEntries)
        XCTAssertEqual(entries.last?.text, "event \(Sibionics2ConnectionLog.maximumEntries + 4)")
        XCTAssertTrue(Sibionics2ConnectionLog.text(for: "id", userDefaults: defaults).hasSuffix("event \(Sibionics2ConnectionLog.maximumEntries + 4)"))
        Sibionics2ConnectionLog.clear(for: "id", userDefaults: defaults)
        XCTAssertTrue(Sibionics2ConnectionLog.entries(for: "id", userDefaults: defaults).isEmpty)
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
    func testExperimentalSectionSitsBeforeAboutWithItsRows() throws {
        let sections = SettingsListFactory.makeRootSections(coreDataManager: nil, selectedFollowerActions: .none,
                                                            presenter: SettingsActionPresenter(router: SettingsRouter()))
        let experimentalID = SettingsRootSection.experimental.rawValue * 10
        let index = try XCTUnwrap(sections.firstIndex { $0.id == experimentalID })
        let aboutIndex = try XCTUnwrap(sections.firstIndex { $0.id == SettingsRootSection.about.rawValue * 10 })
        XCTAssertLessThan(index, aboutIndex)
        XCTAssertEqual(sections[index].section().rows.map(\.id),
                       ["experimental.chartStyle", "experimental.chartCursor", "experimental.prediction", "experimental.insulins",
                        "experimental.pens", "experimental.alerts", "experimental.restricted", "experimental.powerSaving"])
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

// MARK: - Food library

final class FoodLibraryTests: XCTestCase {
    private let table = "apple|11.4|0.3|0.2|piece:182,cup:109|Apple|Яблуко\nbanana|20.2|1.1|0.3|piece:118|Banana|Банан\nbroken|x|1|1||Broken|Зламаний"

    func testStaplesParseInBothLanguages() {
        let english = FoodLibrary.parseStaples(table, ukrainian: false)
        XCTAssertEqual(english.map(\.name), ["Apple", "Banana"])
        XCTAssertEqual(english[0].key, "staple:apple")
        XCTAssertEqual(english[0].portions, [FoodPortion(name: "piece", grams: 182), FoodPortion(name: "cup", grams: 109)])
        XCTAssertEqual(FoodLibrary.parseStaples(table, ukrainian: true).map(\.name), ["Яблуко", "Банан"])
    }

    func testBundledStaplesAreComplete() {
        XCTAssertEqual(FoodLibrary.staples.count, 232)
        XCTAssertEqual(Set(FoodLibrary.staples.map(\.key)).count, 232)
        XCTAssertTrue(FoodLibrary.staples.allSatisfy { $0.carbsPer100 >= 0 && $0.carbsPer100 <= 100 && !$0.name.isEmpty })
    }

    func testMealTotals() {
        let foods = FoodLibrary.parseStaples(table, ukrainian: false)
        let totals = MealTotals([MealIngredient(food: foods[0], grams: 182), MealIngredient(food: foods[1], grams: 59),
                                 MealIngredient(food: foods[1], grams: -5)])
        XCTAssertEqual(totals.carbs, 32.666, accuracy: 0.001)
        XCTAssertEqual(totals.protein, 1.195, accuracy: 0.001)
        XCTAssertEqual(totals.fat, 0.541, accuracy: 0.001)
    }

    func testSearchMatchesWordsAndPutsPrefixFirst() {
        let foods = [FoodItem(key: "a", name: "Green apple", carbsPer100: 11, proteinPer100: 0, fatPer100: 0),
                     FoodItem(key: "b", name: "Apple pie", carbsPer100: 34, proteinPer100: 2, fatPer100: 11),
                     FoodItem(key: "c", name: "Crème brûlée", carbsPer100: 16, proteinPer100: 4, fatPer100: 13)]
        XCTAssertEqual(FoodLibrary.search("APPLE", in: foods).map(\.key), ["b", "a"])
        XCTAssertEqual(FoodLibrary.search("pie app", in: foods).map(\.key), ["b"])
        XCTAssertEqual(FoodLibrary.search("creme", in: foods).map(\.key), ["c"])
        XCTAssertEqual(FoodLibrary.search(" ", in: foods, recent: [FoodLibrary.Recent(key: "c", grams: 80)]).map(\.key), ["c", "a", "b"])
        XCTAssertEqual(FoodLibrary.defaultGrams(for: foods[2], recent: [FoodLibrary.Recent(key: "c", grams: 80)]), 80)
        XCTAssertEqual(FoodLibrary.defaultGrams(for: foods[0], recent: []), 100)
    }

    func testOpenFoodFactsProductParsing() throws {
        let json = #"{"status":1,"product":{"code":"4820000000017","product_name":"Biscuits","product_name_uk":"Печиво","brands":"Roshen, Other","serving_quantity":"30","nutriments":{"carbohydrates_100g":"66,5","proteins_100g":7,"fat_100g":18.2}}}"#
        let food = try XCTUnwrap(OpenFoodFacts.parseProduct(Data(json.utf8), language: "uk"))
        XCTAssertEqual(food.key, "off:4820000000017")
        XCTAssertEqual(food.name, "Печиво (Roshen)")
        XCTAssertEqual(food.carbsPer100, 66.5, accuracy: 0.001)
        XCTAssertEqual(food.proteinPer100, 7, accuracy: 0.001)
        XCTAssertEqual(food.fatPer100, 18.2, accuracy: 0.001)
        XCTAssertEqual(food.portions, [FoodPortion(name: "serving", grams: 30)])
        XCTAssertEqual(OpenFoodFacts.parseProduct(Data(json.utf8), language: "en")?.name, "Biscuits (Roshen)")
    }

    func testOpenFoodFactsDropsWhatCannotBeCounted() {
        let noCarbs = #"{"status":1,"product":{"code":"12345678","product_name":"Water","nutriments":{"proteins_100g":0}}}"#
        XCTAssertNil(OpenFoodFacts.parseProduct(Data(noCarbs.utf8), language: "en"))
        let missing = #"{"status":0,"status_verbose":"product not found"}"#
        XCTAssertNil(OpenFoodFacts.parseProduct(Data(missing.utf8), language: "en"))
        let search = #"{"hits":[{"code":"11111111","product_name":"Oat bar","nutriments":{"carbohydrates_100g":58}},{"code":"11111111","product_name":"Oat bar","nutriments":{"carbohydrates_100g":58}},{"code":"22222222","product_name":"","nutriments":{"carbohydrates_100g":5}},{"code":"33333333","product_name":"Cola","nutriments":{}}]}"#
        XCTAssertEqual(OpenFoodFacts.parseSearch(Data(search.utf8), language: "en").map(\.key), ["off:11111111"])
    }

    func testBarcodesAndRequests() {
        XCTAssertEqual(OpenFoodFacts.normalizedBarcode(" 4820000000017 "), "4820000000017")
        XCTAssertNil(OpenFoodFacts.normalizedBarcode("1234567"))
        XCTAssertNil(OpenFoodFacts.normalizedBarcode("48200000abc17"))
        XCTAssertEqual(OpenFoodFacts.productURL(barcode: "12345678")?.host, "world.openfoodfacts.org")
        let url = OpenFoodFacts.searchURL(query: " гречка ", language: "uk")
        XCTAssertEqual(url?.host, "search.openfoodfacts.org")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "langs" }?.value, "uk,en")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "гречка")
    }

    func testCustomFoodsAndRecentsPersist() {
        let defaults = UserDefaults(suiteName: "FoodLibraryTests")!
        defaults.removePersistentDomain(forName: "FoodLibraryTests")
        let food = FoodItem(key: "custom:1", name: "Borscht", carbsPer100: 6, proteinPer100: 2, fatPer100: 3)
        FoodLibrary.save(food, defaults: defaults)
        FoodLibrary.save(FoodItem(key: "custom:1", name: "Borscht", carbsPer100: 7, proteinPer100: 2, fatPer100: 3), defaults: defaults)
        XCTAssertEqual(FoodLibrary.custom(defaults: defaults).map(\.carbsPer100), [7])
        FoodLibrary.remember([MealIngredient(food: food, grams: 350)], defaults: defaults)
        XCTAssertEqual(FoodLibrary.recentGrams(defaults: defaults), [FoodLibrary.Recent(key: "custom:1", grams: 350)])
        FoodLibrary.delete(key: "custom:1", defaults: defaults)
        XCTAssertTrue(FoodLibrary.custom(defaults: defaults).isEmpty)
        XCTAssertTrue(FoodLibrary.recentGrams(defaults: defaults).isEmpty)
        XCTAssertTrue(FoodEditorView.isValid(carbs: 60, protein: 10, fat: 30))
        XCTAssertFalse(FoodEditorView.isValid(carbs: 60, protein: 30, fat: 30))
        XCTAssertFalse(FoodEditorView.isValid(carbs: nil, protein: 1, fat: 1))
    }
}

// MARK: - Alert episodes

final class AlertEpisodeTests: XCTestCase {
    func testALevelEpisodeEndsOnlyPastTheMargin() {
        XCTAssertEqual(AlertKind.episodeIsResolved(kind: .low, valueMgDl: 78, thresholdMgDl: 70), false)
        XCTAssertEqual(AlertKind.episodeIsResolved(kind: .low, valueMgDl: 79, thresholdMgDl: 70), true)
        XCTAssertEqual(AlertKind.episodeIsResolved(kind: .verylow, valueMgDl: 64, thresholdMgDl: 55), true)
        XCTAssertEqual(AlertKind.episodeIsResolved(kind: .high, valueMgDl: 172, thresholdMgDl: 180), false)
        XCTAssertEqual(AlertKind.episodeIsResolved(kind: .high, valueMgDl: 171, thresholdMgDl: 180), true)
        XCTAssertEqual(AlertKind.episodeIsResolved(kind: .veryhigh, valueMgDl: 260, thresholdMgDl: 250), false)
        // A missing value resolves nothing, and other alarms have no level to return from.
        XCTAssertNil(AlertKind.episodeIsResolved(kind: .low, valueMgDl: 0, thresholdMgDl: 70))
        XCTAssertNil(AlertKind.episodeIsResolved(kind: .fastdrop, valueMgDl: 120, thresholdMgDl: 3))
        XCTAssertNil(AlertKind.episodeIsResolved(kind: .missedreading, valueMgDl: 120, thresholdMgDl: 30))
    }

    func testATrendAlarmFiresOncePerEpisode() {
        var running = false
        var fired: [Bool] = []
        for conditionMet in [true, true, true, false, true, false, false, true] {
            let decision = AlertKind.trendEpisode(conditionMet: conditionMet, episodeRunning: running)
            running = decision.episodeRunning
            fired.append(decision.fire)
        }
        XCTAssertEqual(fired, [true, false, false, false, true, false, false, true])
    }

    func testEpisodeSettingsAreOffByDefaultAndPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AlertEpisodeTests"))
        defaults.removePersistentDomain(forName: "AlertEpisodeTests")
        XCTAssertFalse(defaults.experimentalSnoozeEndsWhenResolved)
        XCTAssertFalse(defaults.experimentalTrendAlertOncePerEpisode)
        XCTAssertTrue(defaults.experimentalTrendAlertEpisodes.isEmpty)
        defaults.experimentalTrendAlertEpisodes = [AlertKind.fastdrop.rawValue, AlertKind.fastrise.rawValue]
        XCTAssertEqual(defaults.experimentalTrendAlertEpisodes, [7, 8])
    }
}

// MARK: - Insulin pens (NFC)

/// A simulated NovoPen: a Type 4 tag whose NDEF file carries the pen's side of the 11073
/// conversation. Verified against a Python port of the reader before these tests were written.
private final class SimulatedPen: PenTransport {
    private let doses: [[UInt8]]
    private let uptime: Int64
    private let serial: String
    private let maximumRead: Int
    private let maximumWrite: Int
    private let blockSize = 8
    private var selected = 0
    private var sequence = 0
    private var sent = 0
    private var transferPending = false
    private var file: [UInt8] = []
    /// Stops answering after this many commands, as a pen pulled away does.
    var commandsBeforeLoss = Int.max
    private(set) var received: [[UInt8]] = []

    struct Lost: Error {}

    init(doses: [[UInt8]], uptime: Int64, serial: String = "ABC123XY", maximumRead: Int = 255, maximumWrite: Int = 255) {
        self.doses = doses
        self.uptime = uptime
        self.serial = serial
        self.maximumRead = maximumRead
        self.maximumWrite = maximumWrite
        setMessage(associationRequest())
    }

    static func record(relative: Int64, tenths: Int, flags: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU32(relative)
        bytes.append(contentsOf: [0xFF, 0x00])
        bytes.appendU16(tenths)
        bytes.append(contentsOf: [0x08, 0x00, 0x00, flags])
        return bytes
    }

    private func setMessage(_ inner: [UInt8]) {
        let record = PenPHD(sequence: sequence, inner: inner).encode()
        file = []
        file.appendU16(record.count)
        file.append(contentsOf: record)
    }

    private func apdu(_ type: Int, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU16(type)
        bytes.appendIndexed(payload)
        return bytes
    }

    private func data(_ invokeID: Int, _ choice: Int, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU16(payload.count + 6)
        bytes.appendU16(invokeID)
        bytes.appendU16(choice)
        bytes.appendIndexed(payload)
        return apdu(0xE700, bytes)
    }

    private func attribute(_ type: Int, _ value: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU16(type)
        bytes.appendIndexed(value)
        return bytes
    }

    private func u16(_ value: Int) -> [UInt8] { var bytes: [UInt8] = []; bytes.appendU16(value); return bytes }
    private func u32(_ value: Int64) -> [UInt8] { var bytes: [UInt8] = []; bytes.appendU32(value); return bytes }

    private func associationRequest() -> [UInt8] {
        var element = u32(0x8000_0000) + u16(0xA000) + u32(0x8000_0000) + u32(0) + u32(0x0080_0000)
        element.appendIndexed([1, 2, 3, 4, 5, 6, 7, 8])
        element += u16(0x4000) + u32(0) + u16(0) + u16(0)
        var body = u32(0x8000_0000) + u16(1) + u16(element.count + 4) + u16(20601)
        body.appendIndexed(element)
        return apdu(0xE200, body)
    }

    private func configuration() -> [UInt8] {
        let attributes = attribute(2385, u16(1)) + attribute(2372, u32(Int64(doses.count))) + attribute(2454, u16(5472)) + attribute(2369, u32(800))
        let object = u16(61) + u16(256) + u16(4) + u16(attributes.count) + attributes
        let config = u16(0x4000) + u16(1) + u16(object.count) + object
        return data(1, 0x0101, u16(0) + u32(uptime) + u16(3356) + u16(config.count) + config)
    }

    private func specification(_ invokeID: Int) -> [UInt8] {
        var items = u16(1) + u16(0)
        items.appendIndexed(Array(serial.utf8) + [0])
        items += u16(2) + u16(0)
        items.appendIndexed(Array("PART".utf8))
        let spec = u16(2) + u16(items.count) + items
        let attributes = attribute(2349, spec) + attribute(2447, u32(uptime))
        return data(invokeID, 0x0203, u16(0) + u16(2) + u16(attributes.count) + attributes)
    }

    private func segmentInfo(_ invokeID: Int) -> [UInt8] {
        func entry(_ object: Int, _ value: Int) -> [UInt8] { u16(6) + u16(130) + u16(object) + u16(1) + u16(1) + u16(4) + u16(value) + u16(4) }
        let map = u16(0x8000) + u16(3) + u16(0) + entry(13313, 2646) + entry(13314, 2662) + entry(61440, 2662)
        let attributes = attribute(2638, map) + attribute(2427, u32(Int64(doses.count)))
        let segment = u16(16) + u16(2) + u16(attributes.count) + attributes
        let body = u16(1) + u16(segment.count) + segment
        return data(invokeID, 0x0207, u16(256) + u16(3085) + u16(body.count) + body)
    }

    private func nextBlock() -> [UInt8] {
        let chunk = Array(doses[sent..<min(sent + blockSize, doses.count)])
        let raw = chunk.flatMap { $0 }
        let body = u16(16) + u32(Int64(sent)) + u32(Int64(chunk.count)) + u16(0) + u16(raw.count) + raw
        let message = data(7 + sent, 0x0101, u16(256) + u32(uptime) + u16(3361) + u16(body.count) + body)
        sent += chunk.count
        return message
    }

    private func answer(_ inner: [UInt8]) -> [UInt8] {
        received.append(inner)
        guard inner.count >= 4 else {
            if transferPending { transferPending = false; return nextBlock() }
            return []
        }
        var reader = PenByteReader(inner)
        guard let type = try? reader.u16(), (try? reader.u16()) != nil else { return [] }
        if type == 0xE300 { return configuration() }
        if type == 0xE400 { return [0xE5, 0, 0, 2, 0, 0] }
        guard type == 0xE700, (try? reader.u16()) != nil, let invokeID = try? reader.u16(),
              let choice = try? reader.u16(), (try? reader.u16()) != nil else { return [0xE6, 0, 0, 2, 0, 0] }
        switch choice {
        case 0x0201:
            _ = try? reader.u16()
            _ = try? reader.u32()
            return (try? reader.u16()) == 3356 ? [] : nextBlock()
        case 0x0103:
            return specification(invokeID)
        case 0x0107:
            _ = try? reader.u16()
            let action = try? reader.u16()
            _ = try? reader.u16()
            if action == 3085 { return segmentInfo(invokeID) }
            transferPending = true
            let segment = (try? reader.u16()) ?? 0
            return data(invokeID, 0x0207, u16(256) + u16(3100) + u16(4) + u16(segment) + u16(0))
        default:
            return [0xE6, 0, 0, 2, 0, 0]
        }
    }

    func transceive(_ command: [UInt8]) async throws -> [UInt8] {
        commandsBeforeLoss -= 1
        if commandsBeforeLoss < 0 { throw Lost() }
        switch command[1] {
        case 0xA4:
            if command[2] == 4 { return Array(command[5..<12]) == [0xD2, 0x76, 0, 0, 0x85, 1, 1] ? [0x90, 0] : [0x6A, 0x82] }
            selected = Int(command[5]) << 8 | Int(command[6])
            return [0x90, 0]
        case 0xB0:
            let offset = Int(command[2]) << 8 | Int(command[3])
            let length = Int(command[4])
            let source = selected == 0xE103
                ? u16(15) + [0x20] + u16(maximumRead) + u16(maximumWrite) + [4, 6] + u16(0xE104) + u16(1024) + [0, 0]
                : file
            guard selected == 0xE103 || length <= maximumRead else { return [0x67, 0] }
            return Array(source[min(offset, source.count)..<min(offset + length, source.count)]) + [0x90, 0]
        case 0xD6:
            let offset = Int(command[2]) << 8 | Int(command[3])
            let length = Int(command[4])
            guard length <= maximumWrite else { return [0x67, 0] }
            if file.count < offset + length { file += [UInt8](repeating: 0, count: offset + length - file.count) }
            file.replaceSubrange(offset..<(offset + length), with: command[5..<(5 + length)])
            let contentLength = Int(file[0]) << 8 | Int(file[1])
            if contentLength > 0, offset == 0 {
                let content = Array(file[2..<(2 + contentLength)])
                if content == PenPHD.emptyNDEF { return [0x90, 0] }
                guard let record = PenPHD.parse(content), record.sequence == (sequence + 1) & 15 else { return [0x6F, 0] }
                sequence = (sequence + 2) & 15
                setMessage(answer(record.inner))
            }
            return [0x90, 0]
        default:
            return [0x6D, 0]
        }
    }
}

final class InsulinPenReaderTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private let uptime: Int64 = 5_000_000

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Newest first, as the pen sends them: 4.5 U ten minutes ago, a 2 U air shot 30 s before it,
    /// then one dose every six hours.
    private func doses() -> [[UInt8]] {
        [SimulatedPen.record(relative: uptime - 600, tenths: 45), SimulatedPen.record(relative: uptime - 630, tenths: 20)]
            + (1...18).map { SimulatedPen.record(relative: uptime - 600 - Int64($0) * 21600, tenths: 30 + $0) }
    }

    private func machine() -> PenMachine {
        var machine = PenMachine()
        let now = now
        machine.now = { Date(timeIntervalSince1970: TimeInterval(now)) }
        return machine
    }

    func testType4CommandsMatchTheReference() {
        XCTAssertEqual(PenT4.reads(offset: 2, length: 300, mtu: 255).map(hex), ["00b00002ff", "00b001012d"])
        XCTAssertEqual(PenT4.updates(for: [1, 2, 3], mtu: 255).map(hex), ["00d60000050003010203"])
        XCTAssertEqual(PenT4.updates(for: Array(1...10), mtu: 12).map(hex),
                       ["00d600000700000102030405", "00d6000705060708090a", "00d6000002000a"])
        XCTAssertEqual(PenT4.updates(for: [], mtu: 255).map(hex), ["00d60000020000"])
        XCTAssertEqual(PenT4.data(of: [1, 2, 0x90, 0x00]), [1, 2])
        XCTAssertNil(PenT4.data(of: [1, 2, 0x6A, 0x82]))
    }

    func testPHDRecordRoundTrips() {
        let record = PenPHD(sequence: 3, inner: [0xAA, 0xBB])
        XCTAssertEqual(hex(record.encode()), "d1030350484483aabb")
        XCTAssertEqual(PenPHD.parse(record.encode()), record)
        XCTAssertNil(PenPHD.parse([0xD1, 0x03, 0x03, 0x41, 0x42, 0x43, 0x83, 0xAA, 0xBB]))
        XCTAssertNil(PenPHD.parse(PenPHD.emptyNDEF))
    }

    func testMessagesMatchTheReference() {
        var context = PenContext()
        let request: [UInt8] = [0xe2, 0x00, 0x00, 0x32, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x2a, 0x50, 0x79, 0x00, 0x26, 0x80, 0x00, 0x00, 0x00,
                                0xa0, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x08, 0x01, 0x02, 0x03, 0x04,
                                0x05, 0x06, 0x07, 0x08, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertNotNil(PenMessage.parse(request, into: &context))
        let association = try? XCTUnwrap(context.association)
        XCTAssertEqual(association?.systemID, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(association.map { hex(PenMessage.associationResponse(to: $0)) },
                       "e300002c00035079002680000000a0008000000000000000800000000008010203040506070800000000000000000000")

        context.invokeID = 1
        context.configuration = PenContext.Configuration(id: 0x4000, handle: 256, numberOfSegments: 1, totalStoredEntries: 20, unitCode: 5472)
        context.eventReport = PenContext.EventReport(handle: 0)
        XCTAssertEqual(PenMessage.acceptConfiguration(context).map(hex), "e7000016001400010201000e0000000000000d1c000440000000")
        XCTAssertEqual(PenMessage.askInformation(context).map(hex), "e700000e000c000101030006000000000000")
        XCTAssertEqual(PenMessage.askSegments(context).map(hex), "e7000014001200010107000c01000c0d0006000100020000")
        XCTAssertEqual(PenMessage.startTransfer(context, segment: 16).map(hex), "e7000010000e00010107000801000c1c00020010")
        XCTAssertEqual(PenMessage.confirmTransfer(context, invokeID: 9, instance: 16, index: 8, count: 8).map(hex),
                       "e700001e001c0009020100160100ffffffff0d21000c001000000008000000080080")
        XCTAssertNil(PenMessage.parse([0x12, 0x34, 0x00, 0x00], into: &context))
    }

    func testWholeLogIsReadFromASimulatedPen() async {
        for (maximumRead, maximumWrite) in [(255, 255), (40, 32)] {
            let pen = SimulatedPen(doses: doses(), uptime: uptime, maximumRead: maximumRead, maximumWrite: maximumWrite)
            var machine = machine()
            var session = PenSession(transport: pen)
            await session.run(machine: &machine)

            XCTAssertTrue(session.spokeProtocol)
            XCTAssertTrue(machine.finishedNormally)
            XCTAssertEqual(machine.context.serial, "ABC123XY")
            XCTAssertEqual(machine.context.doseBlocks.map { $0.raw.count / 12 }, [8, 8, 4, 0])
            XCTAssertEqual(machine.context.doseBlocks.first?.referenceTime, now - uptime)
            XCTAssertEqual(pen.received.count, 10)

            let parsed = PenDoseParser.merge(machine.context.doseBlocks, nowSeconds: now)
            XCTAssertEqual(parsed.count, 20)
            XCTAssertEqual(parsed.last?.tenths, 45)
            XCTAssertEqual(parsed.last?.timestampSeconds, now - 600)
            XCTAssertEqual(parsed.filter(\.priming).map(\.tenths), [20])
        }
    }

    func testReadStopsOnceABlockIsAlreadyImported() async {
        let pen = SimulatedPen(doses: doses(), uptime: uptime)
        var machine = machine()
        let cursor = uptime - 600 - 7 * 21600
        machine.isFullyImported = { _, block in InsulinPenImport.isFullyImported(block, cursor: cursor) }
        var session = PenSession(transport: pen)
        await session.run(machine: &machine)
        // The second block is entirely at or below the cursor, so the third is never asked for.
        XCTAssertEqual(machine.context.doseBlocks.map { $0.raw.count / 12 }, [8, 8])
        XCTAssertTrue(machine.finishedNormally)
    }

    func testALostPenKeepsWhatArrivedAndAForeignTagIsNotAPen() async {
        let pen = SimulatedPen(doses: doses(), uptime: uptime)
        pen.commandsBeforeLoss = 37
        var machine = machine()
        var session = PenSession(transport: pen)
        await session.run(machine: &machine)
        XCTAssertTrue(session.spokeProtocol)
        XCTAssertFalse(machine.finishedNormally)
        XCTAssertEqual(machine.context.serial, "ABC123XY")
        XCTAssertFalse(machine.context.doseBlocks.isEmpty)

        struct BankCard: PenTransport {
            func transceive(_ command: [UInt8]) async throws -> [UInt8] { [0x6A, 0x82] }
        }
        var foreignMachine = PenMachine()
        var foreign = PenSession(transport: BankCard())
        await foreign.run(machine: &foreignMachine)
        XCTAssertFalse(foreign.spokeProtocol)
        XCTAssertNil(foreignMachine.context.serial)
    }

    func testDoseRecordsAreValidatedNotGuessed() {
        var raw = SimulatedPen.record(relative: 1000, tenths: 120, flags: 4)
        raw += SimulatedPen.record(relative: 2000, tenths: 0)            // no amount
        raw += SimulatedPen.record(relative: 3000, tenths: 601)          // more than a pen delivers
        var badMarker = SimulatedPen.record(relative: 4000, tenths: 50)
        badMarker[4] = 0x00
        raw += badMarker
        raw += SimulatedPen.record(relative: 9_000_000, tenths: 50)      // after now
        raw += [1, 2, 3]                                                 // a torn record
        let block = PenContext.DoseBlock(referenceTime: now - 5000, raw: raw)
        let parsed = PenDoseParser.parse(block, nowSeconds: now)
        XCTAssertEqual(parsed, [PenDose(relativeSeconds: 1000, timestampSeconds: now - 4000, tenths: 120, flags: 4)])
        XCTAssertEqual(parsed.first?.units, 12)

        let old = PenContext.DoseBlock(referenceTime: now - PenDoseParser.maximumAgeSeconds - 5000,
                                       raw: SimulatedPen.record(relative: 1000, tenths: 50))
        XCTAssertTrue(PenDoseParser.parse(old, nowSeconds: now).isEmpty)
    }

    func testReviewOffersOnlyDosesPastTheCursorAndMarksWhatIsLogged() {
        let dose = { (relative: Int64, tenths: Int, priming: Bool) in
            PenDose(relativeSeconds: relative, timestampSeconds: self.now - 5000 + relative, tenths: tenths, flags: 0, priming: priming)
        }
        let all = [dose(100, 40, false), dose(200, 20, true), dose(230, 60, false), dose(900, 80, false)]
        let logged = [(date: Date(timeIntervalSince1970: TimeInterval(now - 5000 + 900 + 120)), units: 8.0),
                      (date: Date(timeIntervalSince1970: TimeInterval(now - 5000 + 230 + 120)), units: 5.0)]

        let candidates = InsulinPenImport.candidates(doses: all, cursor: 100, fullRead: false, logged: logged)
        XCTAssertEqual(candidates.map(\.dose.relativeSeconds), [900, 230, 200])
        XCTAssertEqual(candidates.map(\.alreadyLogged), [true, false, false])
        XCTAssertEqual(candidates.map(\.preselected), [false, true, false])
        XCTAssertEqual(InsulinPenImport.candidates(doses: all, cursor: 100, fullRead: true, logged: []).count, 4)

        let block = PenContext.DoseBlock(referenceTime: 0, raw: SimulatedPen.record(relative: 100, tenths: 40) + SimulatedPen.record(relative: 200, tenths: 20))
        XCTAssertTrue(InsulinPenImport.isFullyImported(block, cursor: 200))
        XCTAssertFalse(InsulinPenImport.isFullyImported(block, cursor: 199))
        XCTAssertFalse(InsulinPenImport.isFullyImported(block, cursor: 0))
    }

    func testPensPersistAndABasalPenLogsBasalInjections() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "InsulinPenReaderTests"))
        defaults.removePersistentDomain(forName: "InsulinPenReaderTests")
        var pen = InsulinPen(serial: "ABC123XY", insulin: nil, addedAt: Date(timeIntervalSince1970: 10))
        XCTAssertFalse(pen.isBasal)
        XCTAssertNil(InsulinPenImport.notes(for: pen))
        InsulinPenStore.save(pen, defaults: defaults)
        pen.insulin = InsulinProfile.degludec.rawValue
        pen.cursor = 4242
        InsulinPenStore.save(pen, defaults: defaults)
        InsulinPenStore.save(InsulinPen(serial: "ZZZ", insulin: InsulinProfile.fiasp.rawValue, addedAt: Date(timeIntervalSince1970: 20)), defaults: defaults)

        let stored = InsulinPenStore.pens(defaults: defaults)
        XCTAssertEqual(stored.map(\.serial), ["ABC123XY", "ZZZ"])
        XCTAssertEqual(stored.first?.cursor, 4242)
        XCTAssertEqual(stored.map(\.isBasal), [true, false])
        XCTAssertEqual(stored.first.flatMap(InsulinPenImport.notes(for:)), "Tresiba")
        // The name written to the notes is one the insulin lookup recognises again.
        XCTAssertEqual(InsulinProfile.matching(notes: "Tresiba"), .degludec)
        InsulinPenStore.remove(serial: "ABC123XY", defaults: defaults)
        XCTAssertEqual(InsulinPenStore.pens(defaults: defaults).map(\.serial), ["ZZZ"])
    }
}
