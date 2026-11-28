//
//  MQDriverTests.swift
//  xdripTests
//
//  Registration of the MQ / Glutec driver (enum cases, Core Data entity, troubleshooting source), the
//  per-address state and configuration, what the user's inputs mean for the algorithm and the texts.
//  The protocol maths, the algorithm and the session logic have their own test files with vectors from
//  the unchanged JugglucoNG Kotlin run on the JVM; the expected seeds below were computed with the
//  Python mirror of that logic. Nothing here talks to a real transmitter, and the driver was never tried
//  on a real sensor.
//

import XCTest
@testable import xdrip

final class MQDriverTests: XCTestCase {

    // MARK: - registration

    func testMQIsAvailableInTheDirectCGMAddFlow() {
        XCTAssertEqual(BluetoothPeripheralType.mqType.category(), .CGM)
        XCTAssertEqual(BluetoothPeripheralType.mqType.rawValue, "MQ")
        XCTAssertTrue(BluetoothPeripheralType.addFlowPreferredOrder[.CGM]?.contains(.mqType) == true)
        XCTAssertEqual(BluetoothPeripheralType.mqType.onlineHelpTopic, .addDirectCGM)
        XCTAssertFalse(BluetoothPeripheralType.mqType.usesIntermittentConnection)
    }

    func testMQTransmitterTypeProperties() {
        XCTAssertEqual(CGMTransmitterType.mq.rawValue, "MQ")
        XCTAssertEqual(CGMTransmitterType.mq.sensorType(), .mq)
        XCTAssertEqual(CGMSensorType.mq.rawValue, "MQ")
        XCTAssertTrue(CGMTransmitterType.mq.canDetectNewSensor())
        XCTAssertFalse(CGMTransmitterType.mq.allowManualSensorStart())
        XCTAssertEqual(CGMTransmitterType.mq.detailedDescription(), "Glutec CGM")
    }

    func testMQTroubleshootingSource() throws {
        XCTAssertEqual(TroubleshootingLogSource(directTransmitterType: .mq), .mq)
        let source = try XCTUnwrap(TroubleshootingLogSource(bluetoothPeripheralType: .mqType))
        XCTAssertEqual(source, .mq)
        XCTAssertEqual(source.name, "MQ")
        XCTAssertFalse(source.isFollowerSource)
    }

    func testMQEntityRoundTripsThroughCoreData() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreDataManager.mainManagedObjectContext
        let mq = MQ(address: "test-mq", name: "MQ-test", alias: nil, nsManagedObjectContext: context)
        XCTAssertEqual(mq.bluetoothPeripheralType(), .mqType)
        XCTAssertTrue(mq.blePeripheral.shouldconnect)

        coreDataManager.saveChanges()
        let objectID = mq.blePeripheral.objectID
        context.reset()

        let restored = try XCTUnwrap(context.existingObject(with: objectID) as? BLEPeripheral)
        XCTAssertNotNil(restored.mq)
        XCTAssertNil(restored.anytime)
        XCTAssertNil(restored.aiDex)
        XCTAssertNil(restored.iCan)
        XCTAssertNil(restored.sibionics2)
        XCTAssertEqual(restored.mq?.bluetoothPeripheralType(), .mqType)
    }

    // MARK: - per-address state

    func testDeviceStateDefaultsMeanNothingKnownYet() {
        let state = MQDeviceState()
        XCTAssertFalse(state.observedProtocol02)
        XCTAssertEqual(state.announcedStartAtMs, 0)
        XCTAssertEqual(state.appliedConfigurationRevision, 0)
        XCTAssertEqual(state.tracker.lastPacketIndex, -1)
        XCTAssertEqual(state.tracker.sensorStartAtMs, 0)
        XCTAssertNil(state.lastFrameDate)
        XCTAssertNil(state.lastReadingDate)
        XCTAssertNil(state.problem)
    }

    func testDeviceStateSurvivesJsonRoundTrip() throws {
        var state = MQDeviceState()
        state.advertisedName = "MQ-test"
        state.tracker.kValue = 29.32
        state.tracker.bValue = 2
        state.tracker.lastProcessed = 17.5
        state.tracker.lastPacketIndex = 252
        state.tracker.sensorStartAtMs = 1_789_294_553_000
        state.observedProtocol02 = true
        state.announcedStartAtMs = 1_789_294_553_000
        state.appliedConfigurationRevision = 3
        state.lastFrameDate = Date(timeIntervalSince1970: 1_790_000_000)
        state.lastReadingDate = Date(timeIntervalSince1970: 1_790_000_100)
        state.lastReadingMgdlTimes10 = 1052
        state.problem = .linkSilent
        state.problemDate = Date(timeIntervalSince1970: 1_790_000_200)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MQDeviceState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testDeviceStoreRoundTripAndClear() {
        let address = "mq-test-address"
        MQDeviceStore.clear(address: address)
        XCTAssertNil(MQDeviceStore.load(address: address).advertisedName)
        XCTAssertEqual(MQDeviceStore.load(address: address).tracker.lastPacketIndex, -1)

        MQDeviceStore.update(address: address) {
            $0.advertisedName = "MQ-test"
            $0.tracker.lastPacketIndex = 77
            $0.problem = .linkLost
        }
        let stored = MQDeviceStore.load(address: address)
        XCTAssertEqual(stored.advertisedName, "MQ-test")
        XCTAssertEqual(stored.tracker.lastPacketIndex, 77)
        XCTAssertEqual(stored.problem, .linkLost)

        // another address is untouched
        XCTAssertNil(MQDeviceStore.load(address: address + "-other").advertisedName)

        MQDeviceStore.clear(address: address)
        XCTAssertNil(MQDeviceStore.load(address: address).advertisedName)
        XCTAssertEqual(MQDeviceStore.load(address: address).tracker.lastPacketIndex, -1)
    }

    // MARK: - configuration

    func testConfigurationDefaultsAreJugglucoNGsBuiltInValues() {
        let configuration = MQConfiguration()
        XCTAssertNil(configuration.sensitivity)
        XCTAssertEqual(configuration.scale, .unknown)
        XCTAssertEqual(configuration.algorithmVersion, 0)
        XCTAssertEqual(configuration.packages, 720)
        XCTAssertEqual(configuration.multiplier, 1.1)
        XCTAssertEqual(configuration.revision, 0)

        let parameters = configuration.parameters
        XCTAssertEqual(parameters.algorithmVersion, 0)
        XCTAssertEqual(parameters.packages, 720)
        XCTAssertEqual(parameters.multiplier, 1.1)
        XCTAssertEqual(parameters.sensitivitySeed, 0)
        XCTAssertFalse(configuration.hasUsableSeed)
    }

    func testTheSensitivityNeedsAKnownScaleToBecomeASeed() {
        var configuration = MQConfiguration()
        configuration.sensitivity = 2.93

        // the scale is unknown: a wrong guess would put the slope ten times off
        XCTAssertEqual(configuration.parameters.sensitivitySeed, 0)
        XCTAssertFalse(configuration.hasUsableSeed)

        configuration.scale = .timesTen
        XCTAssertEqual(configuration.parameters.sensitivitySeed, 29.3)
        XCTAssertTrue(configuration.hasUsableSeed)

        configuration.scale = .asEntered
        XCTAssertEqual(configuration.parameters.sensitivitySeed, 2.93)
        XCTAssertTrue(configuration.hasUsableSeed)

        configuration.sensitivity = nil
        XCTAssertEqual(configuration.parameters.sensitivitySeed, 0)
        XCTAssertFalse(configuration.hasUsableSeed)
    }

    func testASeedAtOrBelowOneIsNotUsable() {
        var configuration = MQConfiguration()
        configuration.scale = .asEntered
        configuration.sensitivity = 0.9
        XCTAssertFalse(configuration.hasUsableSeed)
        configuration.sensitivity = 1.0
        XCTAssertFalse(configuration.hasUsableSeed)
        configuration.sensitivity = 1.01
        XCTAssertTrue(configuration.hasUsableSeed)

        // times ten and cut to one decimal: 0.09 gives 0.9, 0.1 gives 1.0
        configuration.scale = .timesTen
        configuration.sensitivity = 0.09
        XCTAssertFalse(configuration.hasUsableSeed)
        configuration.sensitivity = 0.1
        XCTAssertFalse(configuration.hasUsableSeed)
        configuration.sensitivity = 99.9
        XCTAssertEqual(configuration.parameters.sensitivitySeed, 999.0)
        XCTAssertTrue(configuration.hasUsableSeed)
    }

    func testScaleFlagsMatchTheVendorFlag() {
        XCTAssertNil(MQSensitivityScale.unknown.transmitter10)
        XCTAssertEqual(MQSensitivityScale.asEntered.transmitter10, 0)
        XCTAssertEqual(MQSensitivityScale.timesTen.transmitter10, 1)
        // persisted in UserDefaults: renumbering would change a stored choice
        XCTAssertEqual(MQSensitivityScale.unknown.rawValue, 0)
        XCTAssertEqual(MQSensitivityScale.asEntered.rawValue, 1)
        XCTAssertEqual(MQSensitivityScale.timesTen.rawValue, 2)
    }

    func testConfigurationStoreCountsOnlyRealChanges() {
        let address = "mq-test-configuration"
        MQConfigurationStore.clear(address: address)
        XCTAssertEqual(MQConfigurationStore.load(address: address), MQConfiguration())

        let first = MQConfigurationStore.update(address: address) { $0.sensitivity = 2.93 }
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.sensitivity, 2.93)

        // the same value again changes nothing, so the solved slope is kept
        let same = MQConfigurationStore.update(address: address) { $0.sensitivity = 2.93 }
        XCTAssertEqual(same.revision, 1)

        let scaled = MQConfigurationStore.update(address: address) { $0.scale = .timesTen }
        XCTAssertEqual(scaled.revision, 2)
        XCTAssertEqual(MQConfigurationStore.load(address: address).scale, .timesTen)
        XCTAssertEqual(MQConfigurationStore.load(address: address).parameters.sensitivitySeed, 29.3)

        // another address is untouched
        XCTAssertEqual(MQConfigurationStore.load(address: address + "-other"), MQConfiguration())

        MQConfigurationStore.clear(address: address)
        XCTAssertEqual(MQConfigurationStore.load(address: address), MQConfiguration())
    }

    func testChangedConfigurationDiscardsTheSolvedSlopeButNotTheSession() {
        var tracker = MQSessionTracker()
        tracker.kValue = 29.3
        tracker.bValue = 2
        tracker.lastProcessed = 12
        tracker.lastPacketIndex = 30
        tracker.sensorStartAtMs = 1_789_294_553_000
        XCTAssertTrue(tracker.hasSlope)

        tracker.resetAlgorithmState()

        XCTAssertFalse(tracker.hasSlope)
        XCTAssertEqual(tracker.kValue, 0)
        XCTAssertEqual(tracker.bValue, 0)
        XCTAssertEqual(tracker.lastProcessed, 0)
        XCTAssertEqual(tracker.lastPacketIndex, 30)
        XCTAssertEqual(tracker.sensorStartAtMs, 1_789_294_553_000)
    }

    func testASlopeAtOrBelowOneIsNotAHeldSlope() {
        var tracker = MQSessionTracker()
        XCTAssertFalse(tracker.hasSlope)
        tracker.kValue = 1.0
        XCTAssertFalse(tracker.hasSlope)
        tracker.kValue = 1.5
        XCTAssertTrue(tracker.hasSlope)
    }

    // MARK: - typed numbers

    func testDecimalInput() {
        XCTAssertEqual(MQInputText.decimal("2,93"), 2.93)
        XCTAssertEqual(MQInputText.decimal(" 29.3 "), 29.3)
        XCTAssertEqual(MQInputText.decimal("720"), 720)
        XCTAssertNil(MQInputText.decimal(""))
        XCTAssertNil(MQInputText.decimal("abc"))
        XCTAssertNil(MQInputText.decimal("-1"))
        XCTAssertNil(MQInputText.decimal("1e5"))
        XCTAssertNil(MQInputText.decimal("1.2.3"))
        XCTAssertNil(MQInputText.decimal("inf"))
        XCTAssertNil(MQInputText.decimal("0x10"))
    }

    func testIntegerInput() {
        XCTAssertEqual(MQInputText.integer("720"), 720)
        XCTAssertEqual(MQInputText.integer(" 07 "), 7)
        XCTAssertNil(MQInputText.integer(""))
        XCTAssertNil(MQInputText.integer("7.2"))
        XCTAssertNil(MQInputText.integer("-1"))
        XCTAssertNil(MQInputText.integer("1234567"))
    }

    func testStoredNumbersAreShownShort() {
        XCTAssertEqual(MQInputText.format(29.3), "29.3")
        XCTAssertEqual(MQInputText.format(2.93), "2.93")
        XCTAssertEqual(MQInputText.format(1.1), "1.1")
        XCTAssertEqual(MQInputText.format(2), "2")
        XCTAssertEqual(MQInputText.format(720), "720")
        XCTAssertEqual(MQInputText.format(0.5), "0.5")
    }

    func testInputRangesAreUsableDefaults() {
        XCTAssertTrue(MQConfiguration.packagesRange.contains(MQConstants.algoDefaultPackages))
        XCTAssertTrue(MQConfiguration.multiplierRange.contains(Float(MQConstants.algoDefaultMultiplier)))
        XCTAssertTrue(MQConfiguration.algorithmVersions.contains(MQConstants.algoDefaultVersion))
    }

    // MARK: - texts

    func testEveryLinkProblemHasAText() {
        let problems: [MQLinkProblem] = [
            .linkLost, .notAnMQ, .notificationsFailed, .noFramesAfterConnect, .linkSilent, .noGlucose,
            .beginWorkLoop, .writeFailed
        ]
        var texts = Set<String>()
        for problem in problems {
            let text = Texts_BluetoothPeripheralView.mqProblem(problem)
            XCTAssertFalse(text.isEmpty)
            texts.insert(text)
        }
        XCTAssertEqual(texts.count, problems.count)
    }

    func testEveryScaleHasADistinctText() {
        let titles = MQSensitivityScale.allCases.map { Texts_BluetoothPeripheralView.mqSensitivityScaleTitle($0) }
        XCTAssertEqual(Set(titles).count, MQSensitivityScale.allCases.count)
        XCTAssertFalse(titles.contains(""))
    }

    func testLinkProblemRawValuesAreStable() {
        // persisted in UserDefaults: renaming a case would drop a stored problem
        XCTAssertEqual(MQLinkProblem.linkLost.rawValue, "linkLost")
        XCTAssertEqual(MQLinkProblem.noFramesAfterConnect.rawValue, "noFramesAfterConnect")
        XCTAssertEqual(MQLinkProblem.beginWorkLoop.rawValue, "beginWorkLoop")
    }
}
