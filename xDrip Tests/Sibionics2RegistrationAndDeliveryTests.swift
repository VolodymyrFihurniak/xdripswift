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

        func newSensorDetected(sensorStartDate: Date?) {
            newSensorStartDates.append(sensorStartDate)
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
        let processed = batchProcessor.process([reading], receivedAt: receivedAt)
        let spy = CGMTransmitterDelegateSpy()

        XCTAssertEqual(processed.count, 1)
        Sibionics2DelegateDelivery.deliver(
            processed,
            detectedNewSensor: false,
            sensorStartDate: nil,
            sensorAge: receivedAt.timeIntervalSince(sensorStartDate),
            to: spy
        )

        XCTAssertEqual(spy.receivedGlucoseData.count, 1)
        XCTAssertEqual(spy.receivedGlucoseData[0].count, 1)
        XCTAssertEqual(spy.receivedGlucoseData[0][0].timeStamp, reading.eventTime)
        XCTAssertEqual(spy.receivedGlucoseData[0][0].glucoseLevelRaw, 64.8, accuracy: 0.0001)
        XCTAssertEqual(spy.receivedSensorAges.count, 1)
        XCTAssertEqual(spy.receivedSensorAges[0], 3_600)

        let invalidReading = rows[129].reading(
            index: 131,
            rawMmol: .nan,
            sensorStartDate: sensorStartDate
        )
        let invalidProcessed = batchProcessor.process([invalidReading], receivedAt: receivedAt)
        XCTAssertTrue(invalidProcessed.isEmpty)
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
        let newSessionStart = sensorStartDate.addingTimeInterval(30 * 24 * 60 * 60)
        Sibionics2DelegateDelivery.deliver(
            [],
            detectedNewSensor: true,
            sensorStartDate: newSessionStart,
            sensorAge: nil,
            to: spy
        )

        XCTAssertEqual(spy.receivedGlucoseData.count, 1)
        XCTAssertEqual(spy.receivedSensorAges.count, 1)
        XCTAssertEqual(spy.newSensorStartDates.count, 1)
        XCTAssertEqual(spy.newSensorStartDates[0], newSessionStart)
    }

}
