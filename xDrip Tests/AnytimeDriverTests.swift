//
//  AnytimeDriverTests.swift
//  xdripTests
//
//  Registration of the Anytime / Yuwell driver (enum cases, Core Data entity, troubleshooting source),
//  the per-address state and the link problem texts. The protocol maths, the session policies and the
//  glucose paths have their own test files with vectors from the unchanged JugglucoNG Kotlin run on the
//  JVM. Nothing here talks to a real transmitter, and the driver was never tried on a real sensor.
//

import XCTest
@testable import xdrip

final class AnytimeDriverTests: XCTestCase {

    // MARK: - registration

    func testAnytimeIsAvailableInTheDirectCGMAddFlow() {
        XCTAssertEqual(BluetoothPeripheralType.anytimeType.category(), .CGM)
        XCTAssertEqual(BluetoothPeripheralType.anytimeType.rawValue, "Anytime")
        XCTAssertTrue(BluetoothPeripheralType.addFlowPreferredOrder[.CGM]?.contains(.anytimeType) == true)
        XCTAssertEqual(BluetoothPeripheralType.anytimeType.onlineHelpTopic, .addDirectCGM)
        XCTAssertFalse(BluetoothPeripheralType.anytimeType.usesIntermittentConnection)
    }

    func testAnytimeTransmitterTypeProperties() {
        XCTAssertEqual(CGMTransmitterType.anytime.rawValue, "Anytime")
        XCTAssertEqual(CGMTransmitterType.anytime.sensorType(), .anytime)
        XCTAssertTrue(CGMTransmitterType.anytime.canDetectNewSensor())
        XCTAssertFalse(CGMTransmitterType.anytime.allowManualSensorStart())
    }

    func testAnytimeTroubleshootingSource() throws {
        XCTAssertEqual(TroubleshootingLogSource(directTransmitterType: .anytime), .anytime)
        let source = try XCTUnwrap(TroubleshootingLogSource(bluetoothPeripheralType: .anytimeType))
        XCTAssertEqual(source, .anytime)
        XCTAssertEqual(source.name, "Anytime")
        XCTAssertFalse(source.isFollowerSource)
    }

    func testAnytimeEntityRoundTripsThroughCoreData() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreDataManager.mainManagedObjectContext
        let anytime = Anytime(address: "test-anytime", name: "Anytime-test", alias: nil, nsManagedObjectContext: context)
        XCTAssertEqual(anytime.bluetoothPeripheralType(), .anytimeType)
        XCTAssertTrue(anytime.blePeripheral.shouldconnect)

        coreDataManager.saveChanges()
        let objectID = anytime.blePeripheral.objectID
        context.reset()

        let restored = try XCTUnwrap(context.existingObject(with: objectID) as? BLEPeripheral)
        XCTAssertNotNil(restored.anytime)
        XCTAssertNil(restored.aiDex)
        XCTAssertNil(restored.iCan)
        XCTAssertNil(restored.sibionics2)
        XCTAssertEqual(restored.anytime?.bluetoothPeripheralType(), .anytimeType)
    }

    // MARK: - per-address state

    func testDeviceStateDefaultsMeanNothingKnownYet() {
        let state = AnytimeDeviceState()
        XCTAssertFalse(state.bound)
        XCTAssertEqual(state.lastGlucoseId, -1)
        XCTAssertEqual(state.highestImportedId, -1)
        XCTAssertEqual(state.pendingGapFromId, -1)
        XCTAssertEqual(state.pendingGapStopBeforeId, -1)
        XCTAssertEqual(state.sensorStartMs, 0)
        XCTAssertNil(state.lastReadingDate)
        XCTAssertNil(state.problem)
        XCTAssertTrue(state.resolvedIds.isEmpty)
        XCTAssertTrue(state.skippedIds.isEmpty)
    }

    func testDeviceStateSurvivesJsonRoundTrip() throws {
        var state = AnytimeDeviceState()
        state.advertisedName = "Anytime-test"
        state.family = AnytimeFamily.ct5.rawValue
        state.bound = true
        state.lastGlucoseId = 1234
        state.highestImportedId = 1230
        state.lastWasEstimate = true
        state.rawScale = 13.5
        state.rawScaleSamples = 42
        state.resolvedIds = [1, 2, 3]
        state.problem = .noData
        state.problemDate = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AnytimeDeviceState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testDeviceStoreRoundTripAndClear() {
        let address = "anytime-test-address"
        AnytimeDeviceStore.clear(address: address)
        XCTAssertNil(AnytimeDeviceStore.load(address: address).advertisedName)
        XCTAssertEqual(AnytimeDeviceStore.load(address: address).lastGlucoseId, -1)

        AnytimeDeviceStore.update(address: address) {
            $0.advertisedName = "Anytime-test"
            $0.bound = true
            $0.lastGlucoseId = 77
            $0.problem = .linkLost
        }
        let stored = AnytimeDeviceStore.load(address: address)
        XCTAssertEqual(stored.advertisedName, "Anytime-test")
        XCTAssertTrue(stored.bound)
        XCTAssertEqual(stored.lastGlucoseId, 77)
        XCTAssertEqual(stored.problem, .linkLost)

        // another address is untouched
        XCTAssertNil(AnytimeDeviceStore.load(address: address + "-other").advertisedName)

        AnytimeDeviceStore.clear(address: address)
        XCTAssertNil(AnytimeDeviceStore.load(address: address).advertisedName)
        XCTAssertFalse(AnytimeDeviceStore.load(address: address).bound)
        XCTAssertEqual(AnytimeDeviceStore.load(address: address).lastGlucoseId, -1)
    }

    func testUnknownAddressHasNoCt5Secrets() {
        let address = "anytime-test-no-secrets"
        AnytimeCt5SecretStore.clear(address: address)
        XCTAssertFalse(AnytimeCt5SecretStore.hasSecrets(address: address))
        XCTAssertNil(AnytimeCt5SecretStore.load(address: address))
    }

    func testCt5SecretsWithAnImpossibleCipherKeyAreNotStored() {
        let address = "anytime-test-bad-key"
        AnytimeCt5SecretStore.clear(address: address)
        XCTAssertFalse(AnytimeCt5SecretStore.save(AnytimeCt5Secrets(cipherKey: 256, randomB: nil, tempId: nil), address: address))
        XCTAssertFalse(AnytimeCt5SecretStore.save(AnytimeCt5Secrets(cipherKey: -1, randomB: nil, tempId: nil), address: address))
        XCTAssertFalse(AnytimeCt5SecretStore.hasSecrets(address: address))
    }

    // MARK: - texts

    func testEveryLinkProblemHasAText() {
        let problems: [AnytimeLinkProblem] = [
            .linkLost, .notAnAnytime, .unsupportedFamily, .handshakeStalled, .protocolTimeout, .checkMalformed,
            .lowBattery, .bindNeverStreamed, .noData, .historyFailed, .sensorRestarted
        ]
        var texts = Set<String>()
        for problem in problems {
            let text = Texts_BluetoothPeripheralView.anytimeProblem(problem)
            XCTAssertFalse(text.isEmpty)
            texts.insert(text)
        }
        XCTAssertEqual(texts.count, problems.count)
    }

    func testLinkProblemRawValuesAreStable() {
        // persisted in UserDefaults: renaming a case would drop a stored problem
        XCTAssertEqual(AnytimeLinkProblem.linkLost.rawValue, "linkLost")
        XCTAssertEqual(AnytimeLinkProblem.unsupportedFamily.rawValue, "unsupportedFamily")
        XCTAssertEqual(AnytimeLinkProblem.sensorRestarted.rawValue, "sensorRestarted")
    }
}
