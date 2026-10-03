//
// Sibionics2RegistrationAndDeliveryTests.swift
//

import CoreData
import Foundation
import XCTest
@testable import xdrip

final class Sibionics2RegistrationAndDeliveryTests: XCTestCase {
    private let sensorStartDate = Date(timeIntervalSince1970: 1_700_000_000)

    private struct FixtureRow {
        let index: Int
        let rawMmol: Double
        let temperatureC: Double

        func reading(
            index overrideIndex: Int? = nil,
            rawMmol overrideRawMmol: Double? = nil,
            temperatureC overrideTemperatureC: Double? = nil,
            eventTime overrideEventTime: Date? = nil,
            sensorStartDate: Date
        ) -> Sibionics2RawReading {
            let readingIndex = overrideIndex ?? index
            return Sibionics2RawReading(
                index: readingIndex,
                eventTime: overrideEventTime ?? sensorStartDate.addingTimeInterval(TimeInterval(readingIndex * 60)),
                temperatureC: overrideTemperatureC ?? temperatureC,
                impedance: 0,
                rawMmol: overrideRawMmol ?? rawMmol,
                trend: .stable,
                reindex: 0
            )
        }
    }


    private final class CGMTransmitterDelegateSpy: CGMTransmitterDelegate {
        private(set) var receivedGlucoseData = [[GlucoseData]]()
        private(set) var receivedSensorAges = [TimeInterval?]()
        private(set) var newSensorStartDates = [Date?]()
        var glucoseExpectation: XCTestExpectation?
        var newSensorExpectation: XCTestExpectation?

        func newSensorDetected(sensorStartDate: Date?) {
            newSensorStartDates.append(sensorStartDate)
            newSensorExpectation?.fulfill()
        }

        func sensorStopDetected() {}
        func sensorNotDetected() {}

        func cgmTransmitterInfoReceived(
            glucoseData: inout [GlucoseData],
            transmitterBatteryInfo: TransmitterBatteryInfo?,
            sensorAge: TimeInterval?
        ) {
            receivedGlucoseData.append(glucoseData)
            receivedSensorAges.append(sensorAge)
            glucoseExpectation?.fulfill()
        }

        func errorOccurred(xDripError: XdripError) {}
    }

    private func fixtureRows() throws -> [FixtureRow] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sibionics2_v116a_startup",
            withExtension: "csv"
        ))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.hasPrefix("#") }
        XCTAssertEqual(String(lines.first ?? ""), "index,raw_mmol,temperature_c,exact_mmol")

        let rows = try lines.dropFirst().map { line -> FixtureRow in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            XCTAssertEqual(fields.count, 4)
            guard fields.count == 4 else {
                throw NSError(domain: "Sibionics2Fixture", code: 1)
            }
            return FixtureRow(
                index: try XCTUnwrap(Int(fields[0])),
                rawMmol: try XCTUnwrap(Double(fields[1])),
                temperatureC: try XCTUnwrap(Double(fields[2]))
            )
        }
        XCTAssertEqual(rows.map(\.index), Array(1...130))
        return rows
    }

    private func processor(
        through index: Int,
        rows: [FixtureRow]
    ) -> Sibionics2GlucoseProcessor {
        var result = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        for row in rows.prefix(index) {
            _ = result.process(row.reading(sensorStartDate: sensorStartDate), mode: .replay)
        }
        return result
    }

    private func isolatedStateStore() throws -> (String, UserDefaults, Sibionics2ReadingStateStore) {
        let suiteName = "Sibionics2RegistrationAndDeliveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults, Sibionics2ReadingStateStore(userDefaults: defaults))
    }

    private func assertIncompleteSnapshotCanReplayEarlyHistory(
        snapshot: Data?,
        address: String
    ) throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 127,
                processorSnapshot: snapshot,
                sensorStartDate: sensorStartDate
            ),
            for: address
        )

        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )

        XCTAssertNil(batchProcessor.state)
        XCTAssertNil(stateStore.load(for: address))

        _ = batchProcessor.process(
            rows.prefix(3).map { $0.reading(sensorStartDate: sensorStartDate) },
            receivedAt: sensorStartDate.addingTimeInterval(20_000)
        )

        XCTAssertEqual(batchProcessor.state?.lastDeliveredIndex, 3)
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 3)
        XCTAssertEqual(batchProcessor.state?.sensorStartDate, sensorStartDate)
    }

    private func managedObjectModel() throws -> NSManagedObjectModel {
        let bundle = Bundle(for: BLEPeripheral.self)
        let modelURL = try XCTUnwrap(
            bundle.url(forResource: "xdrip", withExtension: "momd")
                ?? Bundle.main.url(forResource: "xdrip", withExtension: "momd")
        )
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
    }

    private func inMemoryContext(model: NSManagedObjectModel) throws -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(
            ofType: NSInMemoryStoreType,
            configurationName: nil,
            at: nil,
            options: nil
        )
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    func testJugglucoReadingPreservesFactoryValueForManualCalibration() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        var readings: [BgReading] = []
        var calibrations: [Calibration] = []
        let reading = Sibionics2JugglucoCalibrator().createNewBgReading(
            rawData: 150, timeStamp: sensorStartDate.addingTimeInterval(3600), sensor: sensor,
            last3Readings: &readings, lastCalibrationsForActiveSensorInLastXDays: &calibrations,
            firstCalibration: nil, lastCalibration: nil, deviceName: nil,
            nsManagedObjectContext: context
        )
        XCTAssertEqual(reading.rawData, 150)
        XCTAssertEqual(reading.ageAdjustedRawValue, 150)
        XCTAssertEqual(reading.calculatedValue, 150)
    }

    func testXDripReadingWithoutFingerstickKeepsFactoryValue() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        var readings: [BgReading] = []
        var calibrations: [Calibration] = []
        let reading = Sibionics2XDripCalibrator().createNewBgReading(
            rawData: 150, timeStamp: sensorStartDate.addingTimeInterval(3600), sensor: sensor,
            last3Readings: &readings, lastCalibrationsForActiveSensorInLastXDays: &calibrations,
            firstCalibration: nil, lastCalibration: nil, deviceName: nil,
            nsManagedObjectContext: context
        )
        XCTAssertEqual(reading.rawData, 150)
        XCTAssertEqual(reading.ageAdjustedRawValue, 150)
        XCTAssertEqual(reading.calculatedValue, 150)
    }

    func testXDripReadingWithCalibrationButNoPriorReadingsUsesCorrectedValue() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        let at = sensorStartDate.addingTimeInterval(3600)
        let calibration = Calibration(timeStamp: at, sensor: sensor, bg: 150,
            rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: at,
            slope: 1.2, intercept: 30, distanceFromEstimate: 0,
            estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1,
            deviceName: nil, nsManagedObjectContext: context)
        var readings: [BgReading] = []
        var calibrations = [calibration]
        let reading = Sibionics2XDripCalibrator().createNewBgReading(
            rawData: 125, timeStamp: at.addingTimeInterval(60), sensor: sensor,
            last3Readings: &readings, lastCalibrationsForActiveSensorInLastXDays: &calibrations,
            firstCalibration: calibration, lastCalibration: calibration, deviceName: nil,
            nsManagedObjectContext: context
        )
        XCTAssertEqual(reading.rawData, 125)
        XCTAssertEqual(reading.ageAdjustedRawValue, 125)
        XCTAssertEqual(reading.calculatedValue, 180, accuracy: 0.00001)
        XCTAssertEqual(reading.c, 180, accuracy: 0.00001)
    }

    func testXDripNonzeroCalibratedPathKeepsSharedClamp() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        let at = sensorStartDate.addingTimeInterval(3600)
        let calibration = Calibration(timeStamp: at, sensor: sensor, bg: 150,
            rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: at,
            slope: 1.2, intercept: 30, distanceFromEstimate: 0,
            estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1,
            deviceName: nil, nsManagedObjectContext: context)
        let previous = BgReading(timeStamp: at, sensor: sensor, calibration: calibration,
            rawData: 100, deviceName: nil, nsManagedObjectContext: context)
        previous.calculatedValue = 150
        previous.ageAdjustedRawValue = 100
        var readings = [previous]
        var calibrations = [calibration]
        let reading = Sibionics2XDripCalibrator().createNewBgReading(
            rawData: 400, timeStamp: at.addingTimeInterval(300), sensor: sensor,
            last3Readings: &readings, lastCalibrationsForActiveSensorInLastXDays: &calibrations,
            firstCalibration: calibration, lastCalibration: calibration, deviceName: nil,
            nsManagedObjectContext: context
        )
        XCTAssertEqual(reading.calculatedValue, ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValue)
    }

    func testJugglucoNewCalibrationMatchesReloadedUniqueAnchors() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let now = Date()
        let sensor = Sensor(startDate: now.addingTimeInterval(-172_800), nsManagedObjectContext: context)
        func anchor(raw: Double, glucose: Double, age: TimeInterval) -> Calibration {
            let timestamp = now.addingTimeInterval(-age)
            return Calibration(
                timeStamp: timestamp, sensor: sensor, bg: glucose, rawValue: raw,
                adjustedRawValue: raw, sensorConfidence: 1, rawTimeStamp: timestamp,
                slope: 1, intercept: glucose - raw, distanceFromEstimate: 0,
                estimateRawAtTimeOfCalibration: raw, slopeConfidence: 1, deviceName: nil,
                nsManagedObjectContext: context
            )
        }
        let first = anchor(raw: 100, glucose: 110, age: 7200)
        let second = anchor(raw: 150, glucose: 155, age: 3600)
        var calibrations = [second, first]
        let reading = BgReading(
            timeStamp: now, sensor: sensor, calibration: second, rawData: 200,
            deviceName: nil, nsManagedObjectContext: context
        )
        // Existing readings from the former NoCalibrator path have a zero here.
        XCTAssertEqual(reading.ageAdjustedRawValue, 0)
        reading.calculatedValue = 200
        let calibrator = Sibionics2JugglucoCalibrator()
        let added = try XCTUnwrap(calibrator.createNewCalibration(
            bgValue: 260, lastBgReading: reading, sensor: sensor,
            lastCalibrationsForActiveSensorInLastXDays: &calibrations,
            firstCalibration: first, deviceName: nil, nsManagedObjectContext: context
        ))
        let immediateValue = reading.calculatedValue
        XCTAssertEqual(reading.ageAdjustedRawValue, 200)
        XCTAssertEqual(added.estimateRawAtTimeOfCalibration, 200)

        let request = NSFetchRequest<Calibration>(entityName: "Calibration")
        request.sortDescriptors = [NSSortDescriptor(key: "timeStamp", ascending: false)]
        var reloadedCalibrations = try context.fetch(request)
        XCTAssertEqual(reloadedCalibrations.count, 3)
        var priorReadings: [BgReading] = []
        let reloadedReading = calibrator.createNewBgReading(
            rawData: 200, timeStamp: added.timeStamp, sensor: sensor,
            last3Readings: &priorReadings,
            lastCalibrationsForActiveSensorInLastXDays: &reloadedCalibrations,
            firstCalibration: first, lastCalibration: added, deviceName: nil,
            nsManagedObjectContext: context
        )
        XCTAssertEqual(immediateValue, reloadedReading.calculatedValue, accuracy: 0.00001)
    }

    func testReadingRepairUsesOnlyPastAnchorsAndPreservesUnrelatedValues() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        let otherSensor = Sensor(startDate: sensorStartDate.addingTimeInterval(10), nsManagedObjectContext: context)
        let base = sensorStartDate.addingTimeInterval(3600)
        func reading(_ raw: Double, at offset: TimeInterval, sensor owner: Sensor? = nil) -> BgReading {
            BgReading(timeStamp: base.addingTimeInterval(offset), sensor: owner ?? sensor,
                      calibration: nil, rawData: raw, deviceName: nil,
                      nsManagedObjectContext: context)
        }
        func anchor(_ raw: Double, _ bg: Double, at offset: TimeInterval) -> Calibration {
            let date = base.addingTimeInterval(offset)
            return Calibration(timeStamp: date, sensor: sensor, bg: bg, rawValue: raw,
                               adjustedRawValue: raw, sensorConfidence: 1, rawTimeStamp: date,
                               slope: 1, intercept: bg - raw, distanceFromEstimate: 0,
                               estimateRawAtTimeOfCalibration: raw, slopeConfidence: 1,
                               deviceName: nil, nsManagedObjectContext: context)
        }

        let before = reading(120, at: 0)
        let after = reading(120, at: 120)
        let future = anchor(120, 145, at: 60)
        let later = anchor(120, 160, at: 180)
        let manual = reading(130, at: 240)
        manual.calibrationFlag = true
        let alreadyCalculated = reading(140, at: 300)
        alreadyCalculated.calculatedValue = 170
        let invalidRaw = reading(0, at: 360)
        let other = reading(150, at: 420, sensor: otherSensor)
        try context.save()

        XCTAssertEqual(Sibionics2ReadingRepair.repair(in: context, sensor: sensor, mode: .jugglucoNG), 2)
        XCTAssertEqual(before.calculatedValue, 120)
        XCTAssertEqual(after.calculatedValue, 145)
        XCTAssertEqual(manual.calculatedValue, 0)
        XCTAssertEqual(alreadyCalculated.calculatedValue, 170)
        XCTAssertEqual(invalidRaw.calculatedValue, 0)
        XCTAssertEqual(other.calculatedValue, 0)
        XCTAssertEqual(future.bg, 145)
        XCTAssertEqual(later.bg, 160)
        XCTAssertEqual(Sibionics2ReadingRepair.repair(in: context, sensor: sensor, mode: .jugglucoNG), 0)
        try context.save()
        context.reset()
        let stored = try context.fetch(NSFetchRequest<BgReading>(entityName: "BgReading"))
        XCTAssertEqual(stored.filter { $0.calculatedValue > 0 }.count, 3)
    }

    func testReadingRepairUsesXDripCalibrationAtReadingTime() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        let at = sensorStartDate.addingTimeInterval(3600)
        let calibration = Calibration(timeStamp: at, sensor: sensor, bg: 150,
            rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: at,
            slope: 1.2, intercept: 30, distanceFromEstimate: 0,
            estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1,
            deviceName: nil, nsManagedObjectContext: context)
        let before = BgReading(timeStamp: at.addingTimeInterval(-60), sensor: sensor,
            calibration: nil, rawData: 125, deviceName: nil, nsManagedObjectContext: context)
        let reading = BgReading(timeStamp: at.addingTimeInterval(60), sensor: sensor,
            calibration: nil, rawData: 125, deviceName: nil, nsManagedObjectContext: context)
        try context.save()

        XCTAssertEqual(Sibionics2ReadingRepair.repair(in: context, sensor: sensor, mode: .xDripPlus), 2)
        XCTAssertEqual(before.calculatedValue, 125)
        XCTAssertEqual(reading.calculatedValue, 180, accuracy: 0.00001)
        XCTAssertEqual(reading.ageAdjustedRawValue, 125)
        XCTAssertEqual(calibration.bg, 150)
    }

    func testReadingRepairKeepsZeroConfidenceCalibrationAnchorsInBothModes() throws {
        for mode in Sibionics2CalibrationMode.allCases {
            let context = try inMemoryContext(model: managedObjectModel())
            let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
            let at = sensorStartDate.addingTimeInterval(3600)
            _ = Calibration(timeStamp: at, sensor: sensor, bg: 155,
                rawValue: 100, adjustedRawValue: 100, sensorConfidence: 0, rawTimeStamp: at,
                slope: 1.2, intercept: 30, distanceFromEstimate: 0,
                estimateRawAtTimeOfCalibration: 100, slopeConfidence: 0,
                deviceName: nil, nsManagedObjectContext: context)
            let reading = BgReading(timeStamp: at.addingTimeInterval(60), sensor: sensor,
                calibration: nil, rawData: 125, deviceName: nil, nsManagedObjectContext: context)
            try context.save()

            XCTAssertEqual(Sibionics2ReadingRepair.repair(in: context, sensor: sensor, mode: mode), 1)
            XCTAssertEqual(reading.calculatedValue, 180, accuracy: 0.00001, "Mode: \(mode)")
        }
    }

    func testProbeReplayUpdatesStoredRowsWithoutAddingCadenceDuplicates() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        let other = Sensor(startDate: sensorStartDate.addingTimeInterval(-3600), nsManagedObjectContext: context)
        let at = sensorStartDate.addingTimeInterval(3600)
        let row = BgReading(timeStamp: at, sensor: sensor, calibration: nil, rawData: 100,
                            deviceName: nil, nsManagedObjectContext: context)
        row.calculatedValue = 100
        row.adjustedValue = 105
        row.smoothedValue = 108
        let neighbor = BgReading(timeStamp: at.addingTimeInterval(60), sensor: sensor, calibration: nil,
                                 rawData: 120, deviceName: nil, nsManagedObjectContext: context)
        neighbor.calculatedValue = 120
        let unrelated = BgReading(timeStamp: at, sensor: other, calibration: nil, rawData: 90,
                                  deviceName: nil, nsManagedObjectContext: context)
        unrelated.calculatedValue = 90
        try context.save()
        let id = row.objectID
        let stableID = row.id
        let data = [GlucoseData(timeStamp: at.addingTimeInterval(5), glucoseLevelRaw: 150)]
        XCTAssertFalse(Sibionics2PersistedReadingReplay.reconcile(in: context, sensor: sensor,
                         glucoseData: data, mode: .xDripPlus).isEmpty)
        XCTAssertEqual(row.rawData, 150)
        XCTAssertEqual(row.ageAdjustedRawValue, 150)
        XCTAssertEqual(row.calculatedValue, 150)
        XCTAssertEqual(row.objectID, id)
        XCTAssertEqual(row.id, stableID)
        XCTAssertEqual(row.timeStamp, at)
        XCTAssertNil(row.adjustedValue)
        XCTAssertNil(row.smoothedValue)
        XCTAssertEqual(neighbor.rawData, 120, "A neighboring minute is not the same sample")
        XCTAssertEqual(unrelated.calculatedValue, 90)
        XCTAssertTrue(Sibionics2PersistedReadingReplay.reconcile(in: context, sensor: sensor,
                         glucoseData: data, mode: .xDripPlus).isEmpty)
        try context.save()
        context.reset()
        let stored = try context.fetch(NSFetchRequest<BgReading>(entityName: "BgReading"))
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(try XCTUnwrap(stored.first { $0.id == stableID }).calculatedValue, 150)
    }

    func testProbeReplayRebasesBothCalibrationModesAndPreservesFingerstick() throws {
        for mode in Sibionics2CalibrationMode.allCases {
            let context = try inMemoryContext(model: managedObjectModel())
            let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
            let at = sensorStartDate.addingTimeInterval(3600)
            let anchor = Calibration(timeStamp: at, sensor: sensor, bg: 150,
                rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: at,
                slope: 1, intercept: 50, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100,
                slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: context)
            let manual = BgReading(timeStamp: at, sensor: sensor, calibration: anchor, rawData: 100,
                                   deviceName: nil, nsManagedObjectContext: context)
            manual.calibrationFlag = true
            manual.calculatedValue = 150
            let after = BgReading(timeStamp: at.addingTimeInterval(300), sensor: sensor, calibration: anchor,
                                  rawData: 120, deviceName: nil, nsManagedObjectContext: context)
            after.calculatedValue = 170
            let anchorID = anchor.id
            let corrected = [GlucoseData(timeStamp: at, glucoseLevelRaw: 120),
                             GlucoseData(timeStamp: after.timeStamp, glucoseLevelRaw: 144)]
            XCTAssertFalse(Sibionics2PersistedReadingReplay.reconcile(in: context, sensor: sensor,
                              glucoseData: corrected, mode: mode).isEmpty)
            XCTAssertEqual(anchor.rawValue, 120, accuracy: 0.00001)
            XCTAssertEqual(anchor.estimateRawAtTimeOfCalibration, 120, accuracy: 0.00001)
            XCTAssertEqual(anchor.bg, 150)
            XCTAssertEqual(anchor.id, anchorID)
            XCTAssertTrue(manual.calibrationFlag)
            XCTAssertEqual(manual.calculatedValue, 150)
            XCTAssertEqual(after.calculatedValue, 174, accuracy: 0.00001)
            // Clearing/restoring the code follows the same path, with no persistent replay flag.
            let restored = [GlucoseData(timeStamp: at, glucoseLevelRaw: 100),
                            GlucoseData(timeStamp: after.timeStamp, glucoseLevelRaw: 120)]
            _ = Sibionics2PersistedReadingReplay.reconcile(in: context, sensor: sensor,
                    glucoseData: restored, mode: mode)
            XCTAssertEqual(anchor.rawValue, 100, accuracy: 0.00001)
            XCTAssertEqual(after.calculatedValue, 170, accuracy: 0.00001)
            XCTAssertEqual(manual.calculatedValue, 150)
        }
    }

    func testProbeReplayRejectsCadenceNeighborsAndInvalidSamples() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        let at = sensorStartDate.addingTimeInterval(3600)
        let row = BgReading(timeStamp: at, sensor: sensor, calibration: nil, rawData: 100,
                            deviceName: nil, nsManagedObjectContext: context)
        row.calculatedValue = 100
        for data in [[GlucoseData(timeStamp: at.addingTimeInterval(60), glucoseLevelRaw: 180)],
                     [GlucoseData(timeStamp: at.addingTimeInterval(30), glucoseLevelRaw: 180)],
                     [GlucoseData(timeStamp: at, glucoseLevelRaw: .nan)],
                     [GlucoseData(timeStamp: at, glucoseLevelRaw: 0)]] {
            XCTAssertTrue(Sibionics2PersistedReadingReplay.reconcile(in: context, sensor: sensor,
                              glucoseData: data, mode: .jugglucoNG).isEmpty)
        }
        XCTAssertEqual(row.calculatedValue, 100)
    }

    func testProbeReplayDoesNotApplyFutureFingerstickToOlderReading() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let sensor = Sensor(startDate: sensorStartDate, nsManagedObjectContext: context)
        let at = sensorStartDate.addingTimeInterval(3600)
        _ = Calibration(timeStamp: at.addingTimeInterval(600), sensor: sensor, bg: 180,
            rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: at.addingTimeInterval(600),
            slope: 1, intercept: 80, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100,
            slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: context)
        let row = BgReading(timeStamp: at, sensor: sensor, calibration: nil, rawData: 100,
                            deviceName: nil, nsManagedObjectContext: context)
        row.calculatedValue = 100
        for mode in Sibionics2CalibrationMode.allCases {
            let value = mode == .xDripPlus ? 110.0 : 120.0
            _ = Sibionics2PersistedReadingReplay.reconcile(in: context, sensor: sensor,
                    glucoseData: [GlucoseData(timeStamp: at, glucoseLevelRaw: value)], mode: mode)
            XCTAssertEqual(row.calculatedValue, value)
        }
    }

    func testProbeReplayPreservesSessionButAllowsPhysicalSensorRestart() {
        XCTAssertTrue(Sibionics2PersistedReadingReplay.matchesSession(sensorStartDate,
                       sensorStartDate.addingTimeInterval(30)))
        XCTAssertFalse(Sibionics2PersistedReadingReplay.matchesSession(sensorStartDate,
                       sensorStartDate.addingTimeInterval(3600)))
    }

    func testReadingAgeOnlyMatchesSelectedSibionicsPeripheral() {
        XCTAssertTrue(SibionicsReadingAge.matchesActivePeripheral(
            viewedAddress: "AA:BB:CC:DD:EE:FF", activeAddress: "aa:bb:cc:dd:ee:ff"
        ))
        XCTAssertFalse(SibionicsReadingAge.matchesActivePeripheral(
            viewedAddress: "AA:BB:CC:DD:EE:FF", activeAddress: "11:22:33:44:55:66"
        ))
        XCTAssertFalse(SibionicsReadingAge.matchesActivePeripheral(
            viewedAddress: "AA:BB:CC:DD:EE:FF", activeAddress: nil
        ))
    }

    func testReadingAgeChangesFromSecondsToMinutesAtBoundaries() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SibionicsReadingAge.detail(since: now.addingTimeInterval(-42), now: now),
                       String(format: Texts_BluetoothPeripheralView.sibionicsReadingAgeSecondsFormat, 42))
        XCTAssertEqual(SibionicsReadingAge.detail(since: now.addingTimeInterval(-60), now: now),
                       String(format: Texts_BluetoothPeripheralView.sibionicsReadingAgeMinutesFormat, 1))
        XCTAssertEqual(SibionicsReadingAge.detail(since: now.addingTimeInterval(-119), now: now),
                       String(format: Texts_BluetoothPeripheralView.sibionicsReadingAgeMinutesFormat, 1))
        XCTAssertEqual(SibionicsReadingAge.nextRefreshInterval(since: now.addingTimeInterval(-42.25), now: now), 0.75, accuracy: 0.001)
        XCTAssertEqual(SibionicsReadingAge.nextRefreshInterval(since: now.addingTimeInterval(-119.25), now: now), 0.75, accuracy: 0.001)
    }

    func testSibionics1SensitivityUsesOnlyOwnCodeOrNeutralScaling() {
        XCTAssertNil(Sibionics2FactorySensitivity.decodedSibionics1Sensitivity(
            advertisedName: nil, probeCode: nil))
        XCTAssertEqual(Sibionics2FactorySensitivity.effectiveSensitivity(
            advertisedName: nil, variant: .sibionics1), 1.0)
        XCTAssertEqual(Sibionics2FactorySensitivity.effectiveSensitivity(
            advertisedName: "ABCD1270SERIAL", variant: .sibionics1), 1.27)
    }

    func testSibionics1PeripheralFactoryPersistsExplicitVariant() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let peripheral = BluetoothPeripheralType.Sibionics1Type.createNewBluetoothPeripheral(
            withAddress: "s1-device", withName: "GS1", nsManagedObjectContext: context
        )
        let sensor = try XCTUnwrap(peripheral as? Sibionics2)
        try context.save()
        context.refresh(sensor, mergeChanges: false)
        XCTAssertEqual(sensor.variant, .sibionics1)
        XCTAssertEqual(sensor.bluetoothPeripheralType(), .Sibionics1Type)
        XCTAssertEqual(BluetoothPeripheralType.Sibionics1Type.category(), .CGM)
        XCTAssertFalse(sensor.variant.supportsReset)
        XCTAssertTrue(SibionicsDeviceVariant.sibionics2.supportsReset)
    }

    func testSibionics1DiscoveryRequiresServiceAndName() {
        XCTAssertTrue(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "GS1ECO", storedAddress: nil, peripheralAddress: "s1",
            variant: .sibionics1, advertisesSibionicsService: true))
        XCTAssertFalse(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "GS1ECO", storedAddress: nil, peripheralAddress: "s1",
            variant: .sibionics1, advertisesSibionicsService: false))
        XCTAssertTrue(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "GS1ECO", storedAddress: nil, peripheralAddress: "s1",
            variant: .sibionics1, advertisesSibionicsService: false,
            discoveredWithSibionicsServiceFilter: true))
        XCTAssertFalse(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "  ", storedAddress: nil, peripheralAddress: "s1",
            variant: .sibionics1, advertisesSibionicsService: true))
    }

    func testSibionics1ConfirmedProtocolPersistsAcrossSessions() throws {
        let (suite, defaults, _) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for mode in [Sibionics1ProtocolMode.chinese, .v120] {
            var first = Sibionics1ConnectionState(savedMode: nil)
            first.confirm(mode)
            Sibionics2Configuration.setProtocolMode(first.mode, for: "sensor-uuid", userDefaults: defaults)
            let reconnect = Sibionics1ConnectionState(savedMode:
                Sibionics2Configuration.protocolMode(for: "SENSOR-UUID", userDefaults: defaults))
            XCTAssertEqual(reconnect.mode, mode)
        }
    }

    func testSibionics1ProbeFallbackAndEchoWait() {
        var session = Sibionics1ConnectionState(savedMode: nil)
        XCTAssertEqual(session.mode, .chinese)
        XCTAssertEqual(session.probeDelay, 5)
        session.receiveEcho()
        XCTAssertEqual(session.probeDelay, 30)
        XCTAssertFalse(session.confirmed)
        XCTAssertTrue(session.fallBackToV120())
        XCTAssertEqual(session.mode, .v120)
        XCTAssertFalse(session.fallBackToV120())
        var chinese = Sibionics1ConnectionState(savedMode: .chinese)
        XCTAssertFalse(chinese.confirmed)
        chinese.confirm(.chinese)
        XCTAssertFalse(chinese.fallBackToV120())
        XCTAssertEqual(Sibionics1ConnectionState(savedMode: .v120).mode, .v120)
    }

    func testSibionics1ChineseReadingsUseExistingDeliveryPipeline() throws {
        let (suite, defaults, store) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var processor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: "s1", stateStore: store,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.0, stockFamily: .v115g)
        )
        let reading = Sibionics2RawReading(index: 1, eventTime: sensorStartDate.addingTimeInterval(60),
            temperatureC: 33, impedance: 0, rawMmol: 6, trend: .notDetermined, reindex: 0)
        let data = processor.process([reading], receivedAt: reading.eventTime)
        let delegate = CGMTransmitterDelegateSpy()
        Sibionics2DelegateDelivery.deliver(data, detectedNewSensor: true,
            sensorStartDate: processor.state?.sensorStartDate, sensorAge: 60, to: delegate)
        XCTAssertEqual(delegate.receivedGlucoseData.first?.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(delegate.receivedGlucoseData.first?.first?.glucoseLevelRaw), 0)
        XCTAssertEqual(processor.process([reading], receivedAt: reading.eventTime).count, 0)
    }

    func testChineseGapWaitsForExactReplayBeforeCGMDelivery() throws {
        let (suite, defaults, store) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        func makeProcessor() -> Sibionics2ReadingBatchProcessor {
            Sibionics2ReadingBatchProcessor(deviceIdentifier: "s1", stateStore: store,
                processor: Sibionics2GlucoseProcessor(sensitivity: 1, stockFamily: .v115g),
                allowsHistoricalBootstrap: true)
        }
        func reading(_ index: Int, age: Int = 0) -> Sibionics2RawReading {
            Sibionics2RawReading(index: index,
                eventTime: sensorStartDate.addingTimeInterval(Double(index * 60)),
                temperatureC: 33, impedance: 0, rawMmol: 6, trend: .notDetermined, reindex: age)
        }
        var firstConnection = makeProcessor()
        let live = reading(10)
        // Raw current samples must not reach the normal CGM/AID pipeline
        // while exact algorithm history is incomplete.
        XCTAssertTrue(firstConnection.process([live], receivedAt: live.eventTime).isEmpty)
        XCTAssertNil(firstConnection.state?.lastDeliveredIndex)
        XCTAssertTrue(firstConnection.requiresHistoryReplay)

        var reconnected = makeProcessor()
        XCTAssertTrue(reconnected.process([live], receivedAt: live.eventTime).isEmpty)
        let history = (1...10).map { reading($0, age: 10 - $0) }
        let corrected = reconnected.process(history, receivedAt: live.eventTime)
        var uninterrupted = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: "s1-reference", stateStore: store,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1, stockFamily: .v115g))
        let expected = uninterrupted.process(history, receivedAt: live.eventTime)
        XCTAssertEqual(corrected.map { $0.timeStamp }, expected.map { $0.timeStamp })
        XCTAssertEqual(corrected.map { $0.glucoseLevelRaw }, expected.map { $0.glucoseLevelRaw })
        XCTAssertFalse(corrected.isEmpty)
        XCTAssertTrue(corrected.allSatisfy { $0.glucoseLevelRaw > 0 })
        XCTAssertEqual(reconnected.state?.lastDeliveredIndex, 10)
        XCTAssertFalse(reconnected.requiresHistoryReplay)
        XCTAssertTrue(reconnected.process([live], receivedAt: live.eventTime).isEmpty)

        // A later gap also keeps uncorrected raw values out of CGM/AID.
        let later = reading(100)
        let laterData = reconnected.process([later], receivedAt: later.eventTime)
        XCTAssertTrue(laterData.isEmpty)
        XCTAssertTrue(reconnected.requiresHistoryReplay)
        XCTAssertEqual(reconnected.state?.lastDeliveredIndex, 10)
    }

    func testChineseHistoryCanBootstrapAtFirstAvailableHistoricalIndex() throws {
        let (suite, defaults, store) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sibionics1_v115g_replay", withExtension: "csv"))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: { $0.isNewline }).dropFirst()
        let rows = try lines.map { line -> (reading: Sibionics2RawReading, expected: Double) in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            let index = try XCTUnwrap(Int(fields[0]))
            return (Sibionics2RawReading(index: index,
                eventTime: sensorStartDate.addingTimeInterval(Double(index * 60)),
                temperatureC: try XCTUnwrap(Double(fields[2])), impedance: 0,
                rawMmol: try XCTUnwrap(Double(fields[1])), trend: .notDetermined, reindex: 1),
                try XCTUnwrap(Double(fields[3])))
        }
        XCTAssertEqual(rows.first?.reading.index, 25)
        var processor = Sibionics2ReadingBatchProcessor(deviceIdentifier: "s1-fixture", stateStore: store,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.4, stockFamily: .v115g),
            allowsHistoricalBootstrap: true)
        let receivedAt = try XCTUnwrap(rows.last?.reading.eventTime).addingTimeInterval(60)
        let current = try XCTUnwrap(rows.last?.reading)
        let live = Sibionics2RawReading(index: current.index, eventTime: current.eventTime,
            temperatureC: current.temperatureC, impedance: current.impedance,
            rawMmol: current.rawMmol, trend: .notDetermined, reindex: 0)
        XCTAssertTrue(processor.process([live], receivedAt: receivedAt).isEmpty)
        XCTAssertTrue(processor.requiresHistoryReplay)
        let data = processor.process(rows.map { $0.reading }, receivedAt: receivedAt)
        let byTimestamp = Dictionary(uniqueKeysWithValues: data.map { ($0.timeStamp, $0) })
        XCTAssertEqual(data.count, rows.count)
        for row in rows where row.expected > 1 && row.reading.index % 5 == 0 {
            let result = try XCTUnwrap(byTimestamp[row.reading.eventTime])
            XCTAssertEqual(result.glucoseLevelRaw, row.expected * 18, accuracy: 0.0002)
        }
        XCTAssertFalse(processor.requiresHistoryReplay)
        XCTAssertEqual(Int(try XCTUnwrap(processor.state?.lastDeliveredIndex)), rows.last?.reading.index)
        XCTAssertTrue(processor.process(rows.map { $0.reading }, receivedAt: receivedAt).isEmpty)
    }

    func testSibionics2PeripheralFactoryAndCGMTypeMapping() throws {
        let context = try inMemoryContext(model: managedObjectModel())
        let peripheral = BluetoothPeripheralType.Sibionics2Type.createNewBluetoothPeripheral(
            withAddress: "A1-B2-C3-D4-E5-F6",
            withName: "P123ABCD",
            nsManagedObjectContext: context
        )

        let sibionics2 = try XCTUnwrap(peripheral as? Sibionics2)
        XCTAssertEqual(sibionics2.bluetoothPeripheralType(), .Sibionics2Type)
        XCTAssertEqual(sibionics2.blePeripheral.address, "A1-B2-C3-D4-E5-F6")
        XCTAssertEqual(sibionics2.blePeripheral.name, "P123ABCD")
        XCTAssertTrue(sibionics2.blePeripheral.sibionics2 === sibionics2)
        XCTAssertEqual(BluetoothPeripheralType.Sibionics2Type.category(), .CGM)
        XCTAssertEqual(CGMTransmitterType.sibionics2.sensorType(), .Sibionics2)
        XCTAssertEqual(CGMTransmitterType.sibionics2.rawValue, "Sibionics 2")
    }

    func testV32PersistentStoreLightweightMigratesAndKeepsExistingRecords() throws {
        let bundle = Bundle(for: BLEPeripheral.self)
        let momdURL = try XCTUnwrap(
            bundle.url(forResource: "xdrip", withExtension: "momd")
                ?? Bundle.main.url(forResource: "xdrip", withExtension: "momd")
        )
        let v32URL = momdURL.appendingPathComponent("xdrip v32.mom")
        let v32Model = try XCTUnwrap(NSManagedObjectModel(contentsOf: v32URL))
        let currentModel = try managedObjectModel()
        XCTAssertNil(v32Model.entitiesByName["Sibionics2"])
        XCTAssertNotNil(currentModel.entitiesByName["Sibionics2"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sibionics2Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("v32.sqlite")

        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: v32Model)
        let oldStore = try oldCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: nil
        )
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let oldPeripheral = NSEntityDescription.insertNewObject(
            forEntityName: "BLEPeripheral",
            into: oldContext
        )
        oldPeripheral.setValue("legacy-v32-address", forKey: "address")
        oldPeripheral.setValue("Legacy peripheral", forKey: "name")
        oldPeripheral.setValue(true, forKey: "shouldconnect")
        oldPeripheral.setValue(true, forKey: "webOOPEnabled")
        oldPeripheral.setValue(false, forKey: "parameterUpdateNeededAtNextConnect")
        try oldContext.save()
        oldContext.reset()
        try oldCoordinator.remove(oldStore)

        let migratedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
        try migratedCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let migratedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        migratedContext.persistentStoreCoordinator = migratedCoordinator
        let request = NSFetchRequest<NSManagedObject>(entityName: "BLEPeripheral")
        let records = try migratedContext.fetch(request)
        let migrated = try XCTUnwrap(records.first)
        XCTAssertEqual(migrated.value(forKey: "address") as? String, "legacy-v32-address")
        XCTAssertEqual(migrated.value(forKey: "name") as? String, "Legacy peripheral")
        XCTAssertEqual(migrated.value(forKey: "shouldconnect") as? Bool, true)
        XCTAssertNil(migrated.value(forKey: "sibionics2"))
    }

    func testV33PersistentStoreDefaultsExistingSibionicsToVariantTwo() throws {
        let bundle = Bundle(for: BLEPeripheral.self)
        let momdURL = try XCTUnwrap(
            bundle.url(forResource: "xdrip", withExtension: "momd")
                ?? Bundle.main.url(forResource: "xdrip", withExtension: "momd")
        )
        let v33URL = momdURL.appendingPathComponent("xdrip v33.mom")
        let v33Model = try XCTUnwrap(NSManagedObjectModel(contentsOf: v33URL))
        let currentModel = try managedObjectModel()
        XCTAssertNil(v33Model.entitiesByName["Sibionics2"]?.attributesByName["sensorVariant"])
        XCTAssertNotNil(currentModel.entitiesByName["Sibionics2"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sibionics2Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("v33.sqlite")

        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: v33Model)
        let oldStore = try oldCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: nil
        )
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let oldPeripheral = NSEntityDescription.insertNewObject(
            forEntityName: "BLEPeripheral",
            into: oldContext
        )
        oldPeripheral.setValue("legacy-v33-address", forKey: "address")
        oldPeripheral.setValue("Legacy peripheral", forKey: "name")
        oldPeripheral.setValue(true, forKey: "shouldconnect")
        oldPeripheral.setValue(true, forKey: "webOOPEnabled")
        oldPeripheral.setValue(false, forKey: "parameterUpdateNeededAtNextConnect")
        let oldSensor = NSEntityDescription.insertNewObject(forEntityName: "Sibionics2", into: oldContext)
        oldSensor.setValue(oldPeripheral, forKey: "blePeripheral")
        try oldContext.save()
        oldContext.reset()
        try oldCoordinator.remove(oldStore)

        let migratedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
        try migratedCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let migratedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        migratedContext.persistentStoreCoordinator = migratedCoordinator
        let request = NSFetchRequest<NSManagedObject>(entityName: "BLEPeripheral")
        let records = try migratedContext.fetch(request)
        let migrated = try XCTUnwrap(records.first)
        XCTAssertEqual(migrated.value(forKey: "address") as? String, "legacy-v33-address")
        XCTAssertEqual(migrated.value(forKey: "name") as? String, "Legacy peripheral")
        XCTAssertEqual(migrated.value(forKey: "shouldconnect") as? Bool, true)
        let migratedSensor = try XCTUnwrap(migrated.value(forKey: "sibionics2") as? Sibionics2)
        XCTAssertEqual(migratedSensor.sensorVariant, 2)
        XCTAssertEqual(migratedSensor.variant, .sibionics2)
        XCTAssertEqual(migratedSensor.bluetoothPeripheralType(), .Sibionics2Type)
    }

    func testFirstConnectUsesOnlySibionics2AdvertisedName() {
        XCTAssertTrue(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "P123ABCD",
            storedAddress: nil,
            peripheralAddress: "first-device"
        ))
        XCTAssertTrue(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "p123-ABCD_56",
            storedAddress: nil,
            peripheralAddress: "first-device"
        ))
        for name in ["GS3-12345", "GKS2-ABCDE", "GS1ECO", "SiBionics 2", "Dexcom G7"] {
            XCTAssertFalse(CGMSibionics2Transmitter.canAdoptPeripheral(
                advertisedName: name,
                storedAddress: nil,
                peripheralAddress: "first-device"
            ), "Unexpected first connection to \(name)")
        }

        XCTAssertTrue(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "Renamed sensor",
            storedAddress: "saved-address",
            peripheralAddress: "saved-address"
        ))
        XCTAssertFalse(CGMSibionics2Transmitter.canAdoptPeripheral(
            advertisedName: "P123ABCD",
            storedAddress: "saved-address",
            peripheralAddress: "different-device"
        ))
    }

    func testReconnectSuppressesStoredIndexesAndBackfillsMissingReadings() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "sensor-A"
        let preparedProcessor = processor(through: 127, rows: rows)
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 127,
                processorSnapshot: preparedProcessor.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: address
        )

        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let receivedAt = sensorStartDate.addingTimeInterval(20_000)
        let readings = [
            rows[129].reading(sensorStartDate: sensorStartDate),
            rows[127].reading(sensorStartDate: sensorStartDate),
            rows[128].reading(sensorStartDate: sensorStartDate),
            rows[128].reading(sensorStartDate: sensorStartDate),
            rows[129].reading(sensorStartDate: sensorStartDate)
        ]
        let delivered = batchProcessor.process(readings, receivedAt: receivedAt)

        XCTAssertEqual(delivered.count, 3)
        guard delivered.count == 3 else { return }
        XCTAssertEqual(delivered.map(\.timeStamp), [
            rows[129].reading(sensorStartDate: sensorStartDate).eventTime,
            rows[128].reading(sensorStartDate: sensorStartDate).eventTime,
            rows[127].reading(sensorStartDate: sensorStartDate).eventTime
        ])
        XCTAssertEqual(delivered[0].glucoseLevelRaw, 64.8, accuracy: 0.0001)
        XCTAssertNil(delivered[0].backfilledAt)
        XCTAssertEqual(delivered[1].backfilledAt, receivedAt)
        XCTAssertEqual(delivered[2].backfilledAt, receivedAt)
        XCTAssertTrue(delivered.allSatisfy { $0.glucoseLevelRaw.isFinite && $0.glucoseLevelRaw > 0 })
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 130)

        var reconnected = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let afterReconnect = reconnected.process([
            rows[129].reading(sensorStartDate: sensorStartDate),
            rows[129].reading(index: 131, sensorStartDate: sensorStartDate)
        ], receivedAt: receivedAt.addingTimeInterval(60))
        XCTAssertEqual(afterReconnect.map(\.timeStamp), [
            rows[129].reading(index: 131, sensorStartDate: sensorStartDate).eventTime
        ])
        XCTAssertNil(afterReconnect.first?.backfilledAt)
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 131)
    }

    func testMissingProcessorSnapshotClearsProgressAndReplaysEarlyHistory() throws {
        try assertIncompleteSnapshotCanReplayEarlyHistory(snapshot: nil, address: "sensor-missing-snapshot")
    }

    func testRejectedProcessorSnapshotClearsProgressAndReplaysEarlyHistory() throws {
        try assertIncompleteSnapshotCanReplayEarlyHistory(snapshot: Data([0xFF, 0x00]), address: "sensor-rejected-snapshot")
    }

    func testHigherIndexFromNewSessionRequestsHistoryReplayFromZero() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "sensor-reset-above-saved-index"
        let savedProcessor = processor(through: 5, rows: rows)
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 5,
                processorSnapshot: savedProcessor.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: address
        )

        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let newSessionStart = sensorStartDate.addingTimeInterval(30 * 24 * 60 * 60)
        let laterReading = rows[19].reading(
            eventTime: newSessionStart.addingTimeInterval(20 * 60),
            sensorStartDate: newSessionStart
        )

        XCTAssertTrue(batchProcessor.process([laterReading], receivedAt: newSessionStart).isEmpty)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay)
        let pendingState = try XCTUnwrap(batchProcessor.state)
        XCTAssertNil(pendingState.lastDeliveredIndex)
        XCTAssertEqual(pendingState.sensorStartDate, newSessionStart)
        XCTAssertEqual(
            pendingState.processorSnapshot,
            Sibionics2GlucoseProcessor(sensitivity: 1.44).snapshot()
        )
        XCTAssertNil(stateStore.load(for: address)?.lastDeliveredIndex)

        let earlyHistory = rows.prefix(20).map { $0.reading(sensorStartDate: newSessionStart) }
        _ = batchProcessor.process(earlyHistory, receivedAt: newSessionStart.addingTimeInterval(30 * 60))
        XCTAssertFalse(batchProcessor.requiresHistoryReplay)
        XCTAssertEqual(batchProcessor.state?.lastDeliveredIndex, 20)
        XCTAssertEqual(batchProcessor.state?.sensorStartDate, newSessionStart)
    }

    func testFirstConnectionToAgedSensorRequestsEarlyHistoryBeforeAdvancingCursor() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "cold-attach-aged-sensor"
        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )

        let lateReading = rows[49].reading(index: 25_298, sensorStartDate: sensorStartDate)
        XCTAssertTrue(batchProcessor.process([lateReading], receivedAt: lateReading.eventTime).isEmpty)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay)
        XCTAssertNil(batchProcessor.state?.lastDeliveredIndex)
        XCTAssertNil(stateStore.load(for: address)?.lastDeliveredIndex)

        let firstPage = rows.prefix(50).map { $0.reading(sensorStartDate: sensorStartDate) }
        let delivered = batchProcessor.process(firstPage, receivedAt: lateReading.eventTime)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay,
                      "A partial history page must request the next page until index 25,298")
        XCTAssertEqual(batchProcessor.state?.lastDeliveredIndex, 50)
        XCTAssertEqual(delivered.first?.timeStamp,
                       rows[49].reading(sensorStartDate: sensorStartDate).eventTime)

        XCTAssertTrue(batchProcessor.process([firstPage[49]], receivedAt: lateReading.eventTime).isEmpty)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay,
                      "A duplicate history page must not cancel replay")
        XCTAssertEqual(batchProcessor.state?.lastDeliveredIndex, 50)

        // A new transmitter is created after an app restart while the sensor's history
        // is still being replayed. It must retain the original live index as its target.
        var resumedProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        XCTAssertTrue(resumedProcessor.requiresHistoryReplay)
        let secondPage = rows.dropFirst(50).prefix(50).map { $0.reading(sensorStartDate: sensorStartDate) }
        _ = resumedProcessor.process(secondPage, receivedAt: lateReading.eventTime)
        XCTAssertTrue(resumedProcessor.requiresHistoryReplay)
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 100)
        XCTAssertEqual(stateStore.load(for: address)?.replayTargetIndex, 25_298)
    }

    func testPendingReplayTargetSurvivesRestartBeforeFirstHistoryPage() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "pending-replay-target"
        var subject = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address, stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        for index in [25_298, 25_300] {
            let reading = rows[49].reading(index: index, sensorStartDate: sensorStartDate)
            XCTAssertTrue(subject.process([reading], receivedAt: reading.eventTime).isEmpty)
        }
        XCTAssertNil(stateStore.load(for: address)?.lastDeliveredIndex)
        XCTAssertEqual(stateStore.load(for: address)?.replayTargetIndex, 25_300)
        let resumed = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address, stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        XCTAssertTrue(resumed.requiresHistoryReplay)
        XCTAssertEqual(resumed.state?.replayTargetIndex, 25_300)
    }

    func testSibionics2DiscoverySearchMatchesSensorName() {
        XCTAssertTrue(Sibionics2DeviceIdentity.matchesSearch(name: "P225044UHA", query: "225044"))
        XCTAssertTrue(Sibionics2DeviceIdentity.matchesSearch(name: "P225044UHA", query: "  p225 "))
        XCTAssertTrue(Sibionics2DeviceIdentity.matchesSearch(name: "P225044UHA", query: ""))
        XCTAssertFalse(Sibionics2DeviceIdentity.matchesSearch(name: "P225044UHA", query: "0401671K"))
    }

    func testMissingHistoryMinuteCannotAdvanceExactAlgorithmCursor() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "missing-minute"
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 5,
                processorSnapshot: processor(through: 5, rows: rows).snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: address
        )
        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let afterGap = rows[7].reading(sensorStartDate: sensorStartDate)
        XCTAssertTrue(batchProcessor.process([afterGap], receivedAt: afterGap.eventTime).isEmpty)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay)
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 5)

        XCTAssertEqual(stateStore.load(for: address)?.replayTargetIndex, 8)
        batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        XCTAssertTrue(batchProcessor.requiresHistoryReplay,
                      "Restarting before the missing page arrives must preserve the replay target")

        let duplicate = rows[4].reading(sensorStartDate: sensorStartDate)
        XCTAssertTrue(batchProcessor.process([duplicate], receivedAt: afterGap.eventTime).isEmpty)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay,
                      "A duplicate before the gap must not cancel history recovery")
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 5)

        // An in-page gap publishes only its contiguous prefix, leaving the
        // missing index available for the next history request.
        let partial = batchProcessor.process(
            [rows[5].reading(sensorStartDate: sensorStartDate), afterGap],
            receivedAt: afterGap.eventTime
        )
        XCTAssertEqual(partial.count, 1)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay)
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 6)

        let nextPage = batchProcessor.process(
            [rows[6].reading(sensorStartDate: sensorStartDate)],
            receivedAt: afterGap.eventTime
        )
        XCTAssertEqual(nextPage.count, 1)
        XCTAssertTrue(batchProcessor.requiresHistoryReplay,
                      "A short contiguous page must request the remaining minute")
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 7)

        let recovered = batchProcessor.process([afterGap], receivedAt: afterGap.eventTime)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertFalse(batchProcessor.requiresHistoryReplay)
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 8)
    }

    func testGrowingIndexWithClockDriftDoesNotEraseAValidAlgorithmSnapshot() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "clock-drift"
        let preparedProcessor = processor(through: 127, rows: rows)
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 127,
                processorSnapshot: preparedProcessor.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: address
        )

        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let current = rows[127].reading(
            eventTime: sensorStartDate.addingTimeInterval(128 * 60 + 45 * 60),
            sensorStartDate: sensorStartDate
        )
        let delivered = batchProcessor.process([current], receivedAt: current.eventTime)
        XCTAssertFalse(delivered.isEmpty)
        XCTAssertFalse(batchProcessor.requiresHistoryReplay)
        XCTAssertEqual(batchProcessor.state?.lastDeliveredIndex, 128)
        XCTAssertEqual(batchProcessor.state?.sensorStartDate, sensorStartDate)
    }

    func testIndexResetStartsANewSensorSessionAndClearsProcessorState() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "sensor-reset"
        let preparedProcessor = processor(through: 127, rows: rows)
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 127,
                processorSnapshot: preparedProcessor.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: address
        )

        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let newSessionStart = sensorStartDate.addingTimeInterval(30 * 24 * 60 * 60)
        let firstReading = rows[0].reading(
            eventTime: newSessionStart.addingTimeInterval(60),
            sensorStartDate: newSessionStart
        )
        XCTAssertTrue(batchProcessor.process([firstReading], receivedAt: newSessionStart).isEmpty)

        let resetState = try XCTUnwrap(stateStore.load(for: address))
        XCTAssertEqual(resetState.lastDeliveredIndex, 1)
        XCTAssertEqual(resetState.sensorStartDate, newSessionStart)

        var freshProcessor = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        _ = freshProcessor.process(firstReading, mode: .replay)
        XCTAssertEqual(resetState.processorSnapshot, freshProcessor.snapshot())
    }

    func testStateStoreRestoresIndexAndProcessorSnapshotPerPeripheralAddress() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let addressA = "saved-sensor-A"
        let addressB = "saved-sensor-B"
        var continuedProcessor = processor(through: 129, rows: rows)
        let processorForB = processor(through: 5, rows: rows)
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 129,
                processorSnapshot: continuedProcessor.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: addressA
        )
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 5,
                processorSnapshot: processorForB.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: addressB
        )

        var restored = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: addressA,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let reading = rows[129].reading(sensorStartDate: sensorStartDate)
        let receivedAt = sensorStartDate.addingTimeInterval(20_000)
        let delivered = restored.process([reading], receivedAt: receivedAt)
        let uninterrupted = try XCTUnwrap(
            continuedProcessor.process(reading, mode: .live)
        )

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].timeStamp, reading.eventTime)
        XCTAssertEqual(delivered[0].glucoseLevelRaw, uninterrupted.glucoseMgDl, accuracy: 0.0001)
        XCTAssertEqual(delivered[0].glucoseLevelRaw, 64.8, accuracy: 0.0001)
        XCTAssertEqual(stateStore.load(for: addressA)?.lastDeliveredIndex, 130)
        XCTAssertEqual(stateStore.load(for: addressB)?.lastDeliveredIndex, 5)

        stateStore.clear(for: addressA)
        XCTAssertNil(stateStore.load(for: addressA))
        XCTAssertEqual(stateStore.load(for: addressB)?.lastDeliveredIndex, 5)
    }

    func testMalformedOrInvalidEntriesNeverReachGlucoseData() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "sensor-invalid-input"
        let preparedProcessor = processor(through: 129, rows: rows)
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 129,
                processorSnapshot: preparedProcessor.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: address
        )
        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )

        let invalidRaw = rows[129].reading(index: 131, rawMmol: .nan, sensorStartDate: sensorStartDate)
        let invalidTemperature = rows[129].reading(
            index: 132,
            temperatureC: 99,
            sensorStartDate: sensorStartDate
        )
        let delivered = batchProcessor.process([
            invalidRaw,
            invalidTemperature,
            rows[129].reading(sensorStartDate: sensorStartDate)
        ], receivedAt: sensorStartDate.addingTimeInterval(20_000))

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.timeStamp, rows[129].reading(sensorStartDate: sensorStartDate).eventTime)
        XCTAssertTrue(delivered.allSatisfy {
            $0.glucoseLevelRaw.isFinite && $0.glucoseLevelRaw > 0 && $0.glucoseLevelRaw <= 900
        })
        XCTAssertEqual(stateStore.load(for: address)?.lastDeliveredIndex, 130)
    }
    func testDelegateDeliverySeamForwardsOnlyProcessedGlucoseAndSensorAge() throws {
        let rows = try fixtureRows()
        let (suiteName, defaults, stateStore) = try isolatedStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let address = "sensor-delegate-delivery"
        let preparedProcessor = processor(through: 129, rows: rows)
        stateStore.save(
            Sibionics2ReadingState(
                lastDeliveredIndex: 129,
                processorSnapshot: preparedProcessor.snapshot(),
                sensorStartDate: sensorStartDate
            ),
            for: address
        )

        var batchProcessor = Sibionics2ReadingBatchProcessor(
            deviceIdentifier: address,
            stateStore: stateStore,
            processor: Sibionics2GlucoseProcessor(sensitivity: 1.44)
        )
        let reading = rows[129].reading(sensorStartDate: sensorStartDate)
        let receivedAt = sensorStartDate.addingTimeInterval(3_600)
        let sensorAge = receivedAt.timeIntervalSince(sensorStartDate)
        let processed = batchProcessor.process([reading], receivedAt: receivedAt)
        let spy = CGMTransmitterDelegateSpy()
        let glucoseReceived = expectation(description: "delegate receives processed glucose")
        let newSensorDetected = expectation(description: "delegate receives new sensor start")
        spy.glucoseExpectation = glucoseReceived
        spy.newSensorExpectation = newSensorDetected

        XCTAssertEqual(processed.count, 1)
        let newSessionStart = sensorStartDate.addingTimeInterval(30 * 24 * 60 * 60)
        DispatchQueue.main.async {
            Sibionics2DelegateDelivery.deliver(
                processed,
                detectedNewSensor: false,
                sensorStartDate: nil,
                sensorAge: sensorAge,
                to: spy
            )
            Sibionics2DelegateDelivery.deliver(
                [],
                detectedNewSensor: true,
                sensorStartDate: newSessionStart,
                sensorAge: nil,
                to: spy
            )
        }
        wait(for: [glucoseReceived, newSensorDetected], timeout: 2)

        XCTAssertEqual(spy.receivedGlucoseData.count, 1)
        XCTAssertEqual(spy.receivedGlucoseData[0].count, 1)
        XCTAssertEqual(spy.receivedGlucoseData[0][0].timeStamp, reading.eventTime)
        XCTAssertEqual(spy.receivedGlucoseData[0][0].glucoseLevelRaw, 64.8, accuracy: 0.0001)
        XCTAssertEqual(spy.receivedSensorAges.count, 1)
        XCTAssertEqual(spy.receivedSensorAges[0], 3_600)
        XCTAssertEqual(spy.newSensorStartDates.count, 1)
        XCTAssertEqual(spy.newSensorStartDates[0], newSessionStart)

        let invalidReading = rows[129].reading(
            index: 131,
            rawMmol: .nan,
            sensorStartDate: sensorStartDate
        )
        let invalidProcessed = batchProcessor.process([invalidReading], receivedAt: receivedAt)
        XCTAssertTrue(invalidProcessed.isEmpty)
        let invalidAndEmptyDeliveriesCompleted = expectation(description: "invalid and empty outputs are ignored")
        DispatchQueue.main.async {
            Sibionics2DelegateDelivery.deliver(
                invalidProcessed,
                detectedNewSensor: false,
                sensorStartDate: nil,
                sensorAge: nil,
                to: spy
            )
            Sibionics2DelegateDelivery.deliver(
                [GlucoseData(timeStamp: reading.eventTime, glucoseLevelRaw: .nan)],
                detectedNewSensor: false,
                sensorStartDate: nil,
                sensorAge: nil,
                to: spy
            )
            Sibionics2DelegateDelivery.deliver(
                [],
                detectedNewSensor: false,
                sensorStartDate: nil,
                sensorAge: nil,
                to: spy
            )
            invalidAndEmptyDeliveriesCompleted.fulfill()
        }
        wait(for: [invalidAndEmptyDeliveriesCompleted], timeout: 2)

        XCTAssertEqual(spy.receivedGlucoseData.count, 1)
        XCTAssertEqual(spy.receivedSensorAges.count, 1)
        XCTAssertEqual(spy.newSensorStartDates.count, 1)
    }

}
