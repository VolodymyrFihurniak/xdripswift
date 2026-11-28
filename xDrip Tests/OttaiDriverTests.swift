//
//  OttaiDriverTests.swift
//  xdripTests
//
//  Registration of the Ottai / Syai driver (enum cases, Core Data entity, troubleshooting source), the
//  per-address state, the small values the connection reads besides glucose (`OttaiCgmInfo`) and the
//  texts. The protocol maths, the glucose expression and the session logic have their own test files
//  with vectors from the unchanged JugglucoNG Kotlin run on the JVM; the expectations for `OttaiCgmInfo`
//  were computed with a Python mirror of the Kotlin functions. Nothing here talks to a real sensor, the
//  Keychain is not written to, and the driver was never tried on a real sensor.
//

import XCTest
@testable import xdrip

final class OttaiDriverTests: XCTestCase {

    private let sessionKey = "000102030405060708090a0b0c0d0e0f"

    private func materials(sensorId: String = "A1B2C3D4E5F6") -> OttaiMaterials {
        return OttaiMaterials(
            sensorId: sensorId,
            displayName: "Ottai CGM",
            keyAHex: String(repeating: "00112233445566778899AABBCCDDEEFF", count: 6),
            method: "V0 C0 ML",
            coefficient: "1,2,3",
            activeTimeMs: 1_790_000_000_000,
            activeExpireTimeMs: 1_296_000_000,
            acceptedMaxActiveMs: 0,
            deviceVersion: "V1.7"
        )
    }

    // MARK: - registration

    func testOttaiIsAvailableInTheDirectCGMAddFlow() {
        XCTAssertEqual(BluetoothPeripheralType.ottaiType.category(), .CGM)
        XCTAssertEqual(BluetoothPeripheralType.ottaiType.rawValue, "Ottai")
        XCTAssertTrue(BluetoothPeripheralType.addFlowPreferredOrder[.CGM]?.contains(.ottaiType) == true)
        XCTAssertEqual(BluetoothPeripheralType.ottaiType.onlineHelpTopic, .addDirectCGM)
        XCTAssertFalse(BluetoothPeripheralType.ottaiType.usesIntermittentConnection)
    }

    func testOttaiTransmitterTypeProperties() {
        XCTAssertEqual(CGMTransmitterType.ottai.rawValue, "Ottai")
        XCTAssertEqual(CGMTransmitterType.ottai.sensorType(), .ottai)
        XCTAssertEqual(CGMSensorType.ottai.rawValue, "Ottai")
        XCTAssertTrue(CGMTransmitterType.ottai.canDetectNewSensor())
        XCTAssertFalse(CGMTransmitterType.ottai.allowManualSensorStart())
        XCTAssertEqual(CGMTransmitterType.ottai.detailedDescription(), "Ottai CGM")
    }

    func testOttaiTroubleshootingSource() throws {
        XCTAssertEqual(TroubleshootingLogSource(directTransmitterType: .ottai), .ottai)
        let source = try XCTUnwrap(TroubleshootingLogSource(bluetoothPeripheralType: .ottaiType))
        XCTAssertEqual(source, .ottai)
        XCTAssertEqual(source.name, "Ottai")
        XCTAssertFalse(source.isFollowerSource)
    }

    func testOttaiEntityRoundTripsThroughCoreData() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreDataManager.mainManagedObjectContext
        let ottai = Ottai(address: "test-ottai", name: "Ottai-test", alias: nil, nsManagedObjectContext: context)
        XCTAssertEqual(ottai.bluetoothPeripheralType(), .ottaiType)
        XCTAssertTrue(ottai.blePeripheral.shouldconnect)

        coreDataManager.saveChanges()
        let objectID = ottai.blePeripheral.objectID
        context.reset()

        let restored = try XCTUnwrap(context.existingObject(with: objectID) as? BLEPeripheral)
        XCTAssertNotNil(restored.ottai)
        XCTAssertNil(restored.mq)
        XCTAssertNil(restored.anytime)
        XCTAssertNil(restored.aiDex)
        XCTAssertNil(restored.iCan)
        XCTAssertNil(restored.sibionics2)
        XCTAssertEqual(restored.ottai?.bluetoothPeripheralType(), .ottaiType)
    }

    // MARK: - per-address state

    func testDeviceStateDefaultsMeanNothingKnownYet() {
        let state = OttaiDeviceState()
        XCTAssertEqual(state.commandStatus, -1)
        XCTAssertFalse(state.verified)
        XCTAssertFalse(state.strangerRejected)
        XCTAssertEqual(state.learnedRecordSize, 0)
        XCTAssertEqual(state.activatedMaxActiveMs, 0)
        XCTAssertEqual(state.announcedStartAtMs, 0)
        XCTAssertEqual(state.livePollIntervalMs, 60_000)
        XCTAssertEqual(state.pipeline, OttaiPersistedPipeline())
        XCTAssertEqual(state.pipeline.lastDataNo, -1)
        XCTAssertNil(state.materialsSensorId)
        XCTAssertNil(state.lastReadingDate)
        XCTAssertNil(state.problem)
    }

    func testDeviceStateSurvivesJsonRoundTrip() throws {
        var state = OttaiDeviceState()
        state.advertisedName = "Ottai-test"
        state.materialsSensorId = "A1B2C3D4E5F6"
        state.pipeline.lastDataNo = 1234
        state.pipeline.streamStartMs = 1_790_000_000_000
        state.pipeline.streamStartReliable = true
        state.pipeline.confirmedActiveTimeMs = 1_790_000_000_000
        state.pipeline.lastAcceptedMmol = 5.5
        state.learnedRecordSize = 9
        state.commandStatus = 3
        state.verified = true
        state.activatedMaxActiveMs = 1_296_000_000
        state.livePollIntervalMs = 30_000
        state.announcedStartAtMs = 1_790_000_000_000
        state.lastFrameDate = Date(timeIntervalSince1970: 1_790_000_000)
        state.lastReadingDate = Date(timeIntervalSince1970: 1_790_000_100)
        state.lastReadingMgdl = 99
        state.lastRawCurrent = 4200
        state.lastTemperatureC = 33.5
        state.problem = .linkSilent
        state.problemDate = Date(timeIntervalSince1970: 1_790_000_200)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(OttaiDeviceState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testDeviceStoreRoundTripAndClear() {
        let address = "ottai-test-address"
        OttaiDeviceStore.clear(address: address)
        XCTAssertNil(OttaiDeviceStore.load(address: address).advertisedName)
        XCTAssertEqual(OttaiDeviceStore.load(address: address).commandStatus, -1)

        OttaiDeviceStore.update(address: address) {
            $0.advertisedName = "Ottai-test"
            $0.commandStatus = 3
            $0.problem = .linkLost
        }
        let stored = OttaiDeviceStore.load(address: address)
        XCTAssertEqual(stored.advertisedName, "Ottai-test")
        XCTAssertEqual(stored.commandStatus, 3)
        XCTAssertEqual(stored.problem, .linkLost)

        // another address is untouched
        XCTAssertNil(OttaiDeviceStore.load(address: address + "-other").advertisedName)

        OttaiDeviceStore.clear(address: address)
        XCTAssertNil(OttaiDeviceStore.load(address: address).advertisedName)
        XCTAssertEqual(OttaiDeviceStore.load(address: address).commandStatus, -1)
    }

    func testPeripheralsThatWereNotTheSensorAreRememberedAndForgotten() {
        let first = "ottai-test-rejected-1"
        let second = "ottai-test-rejected-2"
        OttaiDeviceStore.clear(address: first)
        OttaiDeviceStore.clear(address: second)

        OttaiDeviceStore.reject(address: first)
        OttaiDeviceStore.reject(address: second)
        OttaiDeviceStore.reject(address: first)
        let rejected = OttaiDeviceStore.rejectedAddresses()
        XCTAssertTrue(rejected.contains(first))
        XCTAssertTrue(rejected.contains(second))
        // a repeated rejection moves to the end, it is not listed twice
        XCTAssertEqual(rejected.filter { $0 == first }.count, 1)

        OttaiDeviceStore.forgetRejection(address: first)
        XCTAssertFalse(OttaiDeviceStore.rejectedAddresses().contains(first))
        XCTAssertTrue(OttaiDeviceStore.rejectedAddresses().contains(second))

        // deleting the peripheral forgets the rejection with the rest of its state
        OttaiDeviceStore.clear(address: second)
        XCTAssertFalse(OttaiDeviceStore.rejectedAddresses().contains(second))
    }

    func testTheRememberedRejectionsAreBounded() {
        let prefix = "ottai-test-bound-"
        for index in 0..<30 {
            OttaiDeviceStore.reject(address: prefix + String(index))
        }
        let rejected = OttaiDeviceStore.rejectedAddresses()
        XCTAssertLessThanOrEqual(rejected.count, 20)
        // the newest stay, the oldest go
        XCTAssertTrue(rejected.contains(prefix + "29"))
        XCTAssertFalse(rejected.contains(prefix + "0"))
        for index in 0..<30 {
            OttaiDeviceStore.clear(address: prefix + String(index))
        }
    }

    func testMaterialsSurviveJsonRoundTrip() throws {
        let original = materials()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OttaiMaterials.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.canAuthenticateAndCompute)
    }

    func testUnknownAddressHasNoMaterials() {
        let address = "ottai-test-no-materials"
        OttaiMaterialsStore.clear(address: address)
        XCTAssertFalse(OttaiMaterialsStore.has(address: address))
        XCTAssertNil(OttaiMaterialsStore.load(address: address))
    }

    // MARK: - cgm-info and lifetime values

    func testLivePollIntervalComesFromTheCgmInfoPacket() {
        XCTAssertEqual(OttaiCgmInfo.livePollIntervalMs([0x07, 0x77, 0x3C, 0x00]), 60_000)
        XCTAssertEqual(OttaiCgmInfo.livePollIntervalMs([0x07, 0x77, 0x1E, 0x00]), 30_000)
        XCTAssertEqual(OttaiCgmInfo.livePollIntervalMs([0x07, 0x77, 0x05, 0x00]), 5_000)
        // a longer interval never makes the poll wait more than a minute
        XCTAssertEqual(OttaiCgmInfo.livePollIntervalMs([0x07, 0x77, 0x10, 0x0E]), 60_000)
    }

    func testLivePollIntervalRejectsWhatIsNotAnInterval() {
        // 4 seconds and 3601 seconds are outside 5...3600
        XCTAssertNil(OttaiCgmInfo.livePollIntervalMs([0x07, 0x77, 0x04, 0x00]))
        XCTAssertNil(OttaiCgmInfo.livePollIntervalMs([0x07, 0x77, 0x11, 0x0E]))
        // another packet type, and a packet that is too short
        XCTAssertNil(OttaiCgmInfo.livePollIntervalMs([0x04, 0x77, 0x3C, 0x00]))
        XCTAssertNil(OttaiCgmInfo.livePollIntervalMs([0x07, 0x77, 0x3C]))
        XCTAssertNil(OttaiCgmInfo.livePollIntervalMs([]))
    }

    func testSecondsAreReadLittleEndianFourOrEightBytes() {
        XCTAssertEqual(OttaiCgmInfo.secondsLittleEndian([0x80, 0x51, 0x01, 0x00]), 86_400)
        XCTAssertEqual(OttaiCgmInfo.secondsLittleEndian([0x80, 0xC6, 0x13, 0, 0, 0, 0, 0]), 1_296_000)
        // eight bytes are read whole, bytes past the eighth are not
        XCTAssertEqual(OttaiCgmInfo.secondsLittleEndian([0x80, 0xC6, 0x13, 0, 0, 0, 0, 0, 0xFF]), 1_296_000)
        XCTAssertNil(OttaiCgmInfo.secondsLittleEndian([0, 0, 0, 0]))
        XCTAssertNil(OttaiCgmInfo.secondsLittleEndian([1, 2, 3]))
    }

    func testTheLifetimeIsDecryptedWithTheSessionKey() throws {
        let plain: [UInt8] = [0x80, 0xC6, 0x13, 0, 0, 0, 0, 0]
        let cipher = try XCTUnwrap(OttaiCrypto.encryptPayload(plain, sessionKeyHex: sessionKey))
        XCTAssertEqual(cipher.count, 16)
        XCTAssertEqual(OttaiCgmInfo.decodeMaxActiveSeconds(cipher, sessionKeyHex: sessionKey), 1_296_000)
    }

    func testTheLifetimeFallsBackToAPlaintextRead() {
        // eight bytes are no AES block: firmware that answers in the clear
        XCTAssertEqual(OttaiCgmInfo.decodeMaxActiveSeconds([0x80, 0xC6, 0x13, 0, 0, 0, 0, 0], sessionKeyHex: sessionKey), 1_296_000)
        XCTAssertNil(OttaiCgmInfo.decodeMaxActiveSeconds([], sessionKeyHex: sessionKey))
        XCTAssertNil(OttaiCgmInfo.decodeMaxActiveSeconds([1, 2], sessionKeyHex: sessionKey))
    }

    func testOnlyAPlausibleLifetimeIsKept() {
        XCTAssertNil(OttaiCgmInfo.plausibleMaxActiveMs(seconds: 9 * 86_400))
        XCTAssertEqual(OttaiCgmInfo.plausibleMaxActiveMs(seconds: 10 * 86_400), 864_000_000)
        XCTAssertEqual(OttaiCgmInfo.plausibleMaxActiveMs(seconds: 15 * 86_400), 1_296_000_000)
        XCTAssertEqual(OttaiCgmInfo.plausibleMaxActiveMs(seconds: 45 * 86_400), 3_888_000_000)
        XCTAssertNil(OttaiCgmInfo.plausibleMaxActiveMs(seconds: 46 * 86_400))
    }

    func testAStreamingLinkMayStaySilentForThreePollIntervals() {
        XCTAssertEqual(OttaiCgmInfo.streamingStaleThresholdMs(livePollIntervalMs: 60_000), 195_000)
        XCTAssertEqual(OttaiCgmInfo.streamingStaleThresholdMs(livePollIntervalMs: 5_000), 180_000)
    }
}
