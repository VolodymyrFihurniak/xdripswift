//
//  OttaiProtocolTests.swift
//  xdripTests
//
//  Expected values come from running the unchanged JugglucoNG Kotlin (`drivers/ottai`: OttaiBleAuth,
//  OttaiCrypto, OttaiParser, OttaiConstants, OttaiMethodDefaults, OttaiOutputFilter) on the JVM: the
//  same keys, frames and labels were fed to the Kotlin and every line it printed is checked here. The
//  ECDH cases use fixed secp256r1 scalars whose public points and shared secrets were computed with
//  Python `cryptography` and cross-checked against the Kotlin session key (one case has a shared X
//  with a leading zero byte, the 1 in 256 handshake the vendor app derives wrongly). Two decrypted
//  frames are real captures that JugglucoNG's tests carry. Never compared with a real sensor.
//

import CryptoKit
import XCTest
@testable import xdrip

/// Shared by the Ottai test files: parsing of the pipe separated vector lines and bit exact comparison.
enum OttaiVectorSupport {

    static func fields(_ line: String) -> [String] {
        return line.components(separatedBy: "|")
    }

    static func bytes(_ hex: String) -> [UInt8] {
        return OttaiHex.bytes(hex) ?? []
    }

    static func hex(_ bytes: [UInt8]) -> String {
        return OttaiHex.string(bytes)
    }

    static func d(_ hexBits: String) -> Double {
        return Double(bitPattern: UInt64(hexBits, radix: 16) ?? 0)
    }

    static func f(_ hexBits: String) -> Float {
        return Float(bitPattern: UInt32(hexBits, radix: 16) ?? 0)
    }

    static func bits(_ value: Double) -> String {
        return String(format: "%016llx", value.bitPattern)
    }

    static func bits(_ value: Float) -> String {
        return String(format: "%08x", value.bitPattern)
    }

    static func opt(_ text: String) -> String? {
        return text == "NULL" ? nil : text
    }

    static func optInt(_ text: String) -> Int? {
        return text == "NULL" ? nil : Int(text)
    }

    static func flag(_ value: Bool) -> String {
        return value ? "true" : "false"
    }
}

final class OttaiProtocolTests: XCTestCase {

    private typealias V = OttaiVectorSupport

    // MARK: - BLE auth

    func testSessionKeyDerivation() throws {
        for line in OttaiProtocolVectors.ecdh {
            let f = V.fields(line)
            let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(V.bytes(f[0])))
            let coordinates = OttaiBleAuth.publicCoords(key.publicKey)
            XCTAssertEqual(V.hex(coordinates.x), f[1], line)
            XCTAssertEqual(V.hex(coordinates.y), f[2], line)
            XCTAssertEqual(OttaiBleAuth.deriveSessionKey(devicePubXHex: f[3], devicePubYHex: f[4], ourPrivate: key), V.opt(f[5]), line)
            XCTAssertEqual(OttaiBleAuth.deriveSessionKey(devicePubX: V.bytes(f[3]), devicePubY: V.bytes(f[4]), ourPrivate: key), V.opt(f[5]), line)
        }
    }

    func testSessionKeyDerivationRefusesAPointThatIsNotOnTheCurve() throws {
        let key = OttaiBleAuth.generateKeyPair()
        let off = [UInt8](repeating: 0x11, count: 32)
        XCTAssertNil(OttaiBleAuth.deriveSessionKey(devicePubX: off, devicePubY: off, ourPrivate: key))
        XCTAssertNil(OttaiBleAuth.deriveSessionKey(devicePubX: [1, 2, 3], devicePubY: [], ourPrivate: key))
    }

    func testGeneratedKeyPairsAgreeOnTheSessionKey() {
        let app = OttaiBleAuth.generateKeyPair()
        let device = OttaiBleAuth.generateKeyPair()
        let deviceCoordinates = OttaiBleAuth.publicCoords(device.publicKey)
        let appCoordinates = OttaiBleAuth.publicCoords(app.publicKey)
        let appSide = OttaiBleAuth.deriveSessionKey(devicePubX: deviceCoordinates.x, devicePubY: deviceCoordinates.y, ourPrivate: app)
        let deviceSide = OttaiBleAuth.deriveSessionKey(devicePubX: appCoordinates.x, devicePubY: appCoordinates.y, ourPrivate: device)
        XCTAssertEqual(appSide, deviceSide)
        XCTAssertEqual(appSide?.count, 32)
    }

    func testSessionKeyPick() {
        for line in OttaiProtocolVectors.pick {
            let f = V.fields(line)
            XCTAssertEqual(OttaiBleAuth.sessionKeyPick(f[0]), V.opt(f[1]), line)
        }
    }

    func testCoordinateBytes() {
        for line in OttaiProtocolVectors.coord {
            let f = V.fields(line)
            XCTAssertEqual(V.hex(OttaiBleAuth.coordBytes(V.bytes(f[0]))), f[1], line)
        }
    }

    func testFixedFieldBytes() {
        for line in OttaiProtocolVectors.fixed {
            let f = V.fields(line)
            XCTAssertEqual(V.hex(OttaiBleAuth.fixedFieldBytes(V.bytes(f[0]), fieldLength: Int(f[1]) ?? 0)), f[2], line)
        }
    }

    func testLittleEndianHelpers() {
        for line in OttaiProtocolVectors.le32 {
            let f = V.fields(line)
            XCTAssertEqual(OttaiBleAuth.bytesToIntLE(V.bytes(f[0])).map { String($0) }, f[1], line)
        }
        XCTAssertNil(OttaiBleAuth.bytesToIntLE([1, 2, 3]))
        for line in OttaiProtocolVectors.leBytes {
            let f = V.fields(line)
            XCTAssertEqual(V.hex(OttaiBleAuth.intToBytesLE(Int32(f[0]) ?? 0)), f[1], line)
        }
    }

    func testAppTime3() {
        for line in OttaiProtocolVectors.time3 {
            let f = V.fields(line)
            XCTAssertEqual(V.hex(OttaiBleAuth.appTime3(deviceTimeBytes: V.bytes(f[0]))), f[1], line)
        }
    }

    func testAuthSignature() {
        for line in OttaiProtocolVectors.sign {
            let f = V.fields(line)
            let sign = OttaiBleAuth.authSign(authKeyHex: f[0], macHex: f[1], pubX: V.bytes(f[2]), pubY: V.bytes(f[3]), time3: V.bytes(f[4]))
            XCTAssertEqual(sign.map { V.hex($0) }, f[5], line)
        }
        XCTAssertNil(OttaiBleAuth.authSign(authKeyHex: "zz", macHex: "00", pubX: [], pubY: [], time3: []))
    }

    func testDeviceSignatureVerification() {
        for line in OttaiProtocolVectors.verify {
            let f = V.fields(line)
            let result = OttaiBleAuth.verifyDeviceSign(
                V.bytes(f[5]), authKeyHex: f[0], macHex: f[1],
                devicePubX: V.bytes(f[2]), devicePubY: V.bytes(f[3]), deviceTime: V.bytes(f[4])
            )
            XCTAssertEqual(V.flag(result), f[6], line)
        }
    }

    func testAppAuthParameter() {
        for line in OttaiProtocolVectors.appParam {
            let f = V.fields(line)
            let parameter = OttaiBleAuth.appAuthParameter(selectedIndex: Int(f[0]) ?? 0, time3: V.bytes(f[1]), pubX: V.bytes(f[2]), pubY: V.bytes(f[3]))
            XCTAssertEqual(V.hex(parameter), f[4], line)
        }
    }

    // MARK: - Keys and payload crypto

    func testAuthKeyParsing() {
        for line in OttaiProtocolVectors.keys {
            let f = V.fields(line)
            let input = f[0].replacingOccurrences(of: "<NL>", with: "\n")
            let keys = OttaiCrypto.parseAuthKeys(input)
            XCTAssertEqual(keys.map { $0.map { V.hex($0) }.joined(separator: ",") }, V.opt(f[1]), line)
        }
    }

    func testPayloadEncryptionAndDecryption() {
        for line in OttaiProtocolVectors.crypt {
            let f = V.fields(line)
            let cipher = OttaiCrypto.encryptPayload(V.bytes(f[1]), sessionKeyHex: f[0])
            XCTAssertEqual(cipher.map { V.hex($0) }, V.opt(f[2]), line)
            if let cipher = cipher {
                XCTAssertEqual(OttaiCrypto.decryptPayload(cipher, sessionKeyHex: f[0]).map { V.hex($0) }, V.opt(f[3]), line)
            }
        }
        for line in OttaiProtocolVectors.decrypt {
            let f = V.fields(line)
            XCTAssertEqual(OttaiCrypto.decryptPayload(V.bytes(f[1]), sessionKeyHex: f[0]).map { V.hex($0) }, V.opt(f[2]), line)
        }
    }

    // MARK: - Framing and records

    func testRecordSizeEvidence() {
        for line in OttaiProtocolVectors.evidence {
            let f = V.fields(line)
            let payload = V.bytes(f[0])
            let evidence = OttaiParser.recordSizeEvidence(payload)
            XCTAssertEqual("\(evidence.nine),\(evidence.eight)", f[1], line)
            XCTAssertEqual(OttaiParser.contentRecordSize(payload), V.optInt(f[2]), line)
            XCTAssertEqual(OttaiParser.frontDataNo(payload), Int(f[3]), line)
        }
    }

    func testFramingVectors() {
        for line in OttaiProtocolVectors.frames {
            let f = V.fields(line)
            let payload = V.bytes(f[0])
            let learned = V.optInt(f[2])
            XCTAssertEqual(OttaiParser.chooseRecordSize(payload, deviceVersion: f[1], learned: learned), Int(f[3]), line)
            XCTAssertEqual(OttaiParser.decisiveRecordSize(payload, deviceVersion: f[1]), V.optInt(f[4]), line)
            let records = OttaiParser.frameRecords(payload, deviceVersion: f[1], learned: learned)
            XCTAssertEqual(records.count, Int(f[5]), line)
            XCTAssertEqual(records.map { V.hex($0) }.joined(separator: ","), f[6], line)
        }
    }

    func testRecordParsing() throws {
        for line in OttaiProtocolVectors.records {
            let f = V.fields(line)
            let record = try XCTUnwrap(OttaiParser.parseRecord(V.bytes(f[0])), line)
            XCTAssertEqual(record.dataNo, Int(f[1]), line)
            XCTAssertEqual(record.voltage, Int(f[2]), line)
            XCTAssertEqual(record.runtimeSec, Int(f[3]), line)
            XCTAssertEqual(record.rawCurrent, Int(f[4]), line)
            XCTAssertEqual(V.bits(record.temperatureC), f[5], line)
            XCTAssertEqual(V.flag(OttaiParser.isRecordSane(record)), f[6], line)
            XCTAssertEqual(V.flag(OttaiParser.isAverageTick(record)), f[7], line)
            XCTAssertEqual(V.flag(OttaiParser.isAverageTick(record, warmupSec: 100)), f[8], line)
        }
        XCTAssertNil(OttaiParser.parseRecord([1, 2, 3]))
    }

    func testRealCapturedLiveFrameIsDecodedAsOneNineByteRecord() throws {
        // A real decrypted notify of an E1.1.4 sensor: header, one 9 byte record, seven padding bytes.
        let payload = V.bytes("000000002458ffff1f3c34e115ba47c50b" + String(repeating: "00", count: 7))
        let records = OttaiParser.frameRecords(payload, deviceVersion: "E1.1.4(V1.7.S2530.1)", learned: 9)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(OttaiParser.parseRecord(try XCTUnwrap(records.first)))
        XCTAssertEqual(record.dataNo, 0x5824)
        XCTAssertEqual(record.rawCurrent, 0x3C1F)
        XCTAssertEqual(record.voltage, 0x47)
        XCTAssertEqual(record.temperatureC, 30.13, accuracy: 1e-9)
    }

    // MARK: - Identity

    func testCanonicalSensorIds() {
        for line in OttaiProtocolVectors.canon {
            let f = V.fields(line)
            XCTAssertEqual(OttaiConstants.canonicalSensorId(f[0]), f[1], line)
            XCTAssertEqual(V.flag(OttaiConstants.looksLikeMac(f[0])), f[2], line)
            XCTAssertEqual(V.flag(OttaiConstants.isBoxSerial(f[0])), f[3], line)
        }
        XCTAssertEqual(OttaiConstants.canonicalSensorId(nil), "")
    }

    func testLabelAndQrExtraction() {
        for line in OttaiProtocolVectors.qr {
            let f = V.fields(line)
            let input = f[0].replacingOccurrences(of: "<GS>", with: "\u{1D}")
            XCTAssertEqual(OttaiConstants.extractMacFromQr(input), V.opt(f[1]), line)
            XCTAssertEqual(OttaiConstants.extractSetupCode(input), V.opt(f[2]), line)
        }
        XCTAssertNil(OttaiConstants.extractMacFromQr(nil))
    }

    func testAdvertisedNames() {
        for line in OttaiProtocolVectors.names {
            let f = V.fields(line)
            XCTAssertEqual(V.flag(OttaiConstants.isOttaiAdvertisedName(f[0])), f[1], line)
        }
        XCTAssertFalse(OttaiConstants.isOttaiAdvertisedName(nil))
    }

    // MARK: - Lifetime and timing

    func testActiveExpireSanitising() {
        for line in OttaiProtocolVectors.expire {
            let f = V.fields(line)
            XCTAssertEqual(OttaiConstants.sanitizeActiveExpireMs(Int64(f[0]) ?? 0), Int64(f[1]), line)
        }
    }

    func testExpectedLifetime() {
        for line in OttaiProtocolVectors.lifetime {
            let f = V.fields(line)
            XCTAssertEqual(OttaiConstants.expectedLifetimeMs(cloudActiveExpireMs: Int64(f[0]) ?? 0, acceptedMaxActiveMs: Int64(f[1]) ?? 0), Int64(f[2]), line)
        }
    }

    func testWarmupWindow() {
        for line in OttaiProtocolVectors.warmup {
            let f = V.fields(line)
            XCTAssertEqual(V.flag(OttaiConstants.isWithinWarmup(activationStartMs: Int64(f[0]) ?? 0, sampleMs: Int64(f[1]) ?? 0)), f[2], line)
        }
    }

    func testCommandStatus() {
        for line in OttaiProtocolVectors.commandStatus {
            let f = V.fields(line)
            XCTAssertEqual(V.flag(OttaiConstants.commandNeedsActivation(Int(f[0]) ?? -1)), f[1], line)
        }
    }

    // MARK: - Method defaults and the output gate

    func testDefaultMethodText() {
        XCTAssertEqual(OttaiMethodDefaults.standard14CoefficientMethod, OttaiProtocolVectors.defaultMethod)
    }

    func testCoefficientProfileDetection() {
        for line in OttaiProtocolVectors.matches {
            let f = V.fields(line)
            XCTAssertEqual(V.flag(OttaiMethodDefaults.matchesStandard14CoefficientProfile(f[0])), f[1], line)
        }
    }

    func testMethodResolution() {
        for line in OttaiProtocolVectors.resolve {
            let f = V.fields(line)
            let resolved = OttaiMethodDefaults.resolve(method: f[0], coefficient: f[1])
            if f[0].isEmpty {
                XCTAssertEqual(V.flag(resolved == OttaiMethodDefaults.standard14CoefficientMethod), f[2], line)
            } else if f[2] == "true" || f[2] == "false" {
                XCTAssertEqual(V.flag(resolved.isEmpty), f[2], line)
            } else {
                XCTAssertEqual(resolved.replacingOccurrences(of: " ", with: "_"), f[2], line)
            }
        }
    }

    func testHardRejectGate() {
        for line in OttaiProtocolVectors.hard {
            let f = V.fields(line)
            let record = OttaiRecord(
                dataNo: 100, voltage: 0, runtimeSec: 6000, rawCurrent: Int(f[0]) ?? 0,
                temperatureC: V.d(f[1]), recordBytes: [UInt8](repeating: 0, count: 12)
            )
            let reason = OttaiOutputFilter.hardRejectReason(record, mmol: V.f(f[2]))
            if f[3] == "NULL" {
                XCTAssertNil(reason, line)
            } else {
                let expectedPrefix = String(f[3].prefix(while: { $0 != "=" }))
                XCTAssertEqual(reason.map { String($0.prefix(while: { $0 != "=" })) }, expectedPrefix, line)
                if expectedPrefix == "raw" { XCTAssertEqual(reason, f[3], line) }
            }
        }
    }

    func testOneMinuteRawExcursion() {
        for line in OttaiProtocolVectors.excursion {
            let f = V.fields(line)
            let result = OttaiOutputFilter.isOneMinuteRawExcursion(
                candidateMmol: V.f(f[0]), candidateRaw: Int(f[1]) ?? 0, baselineMmol: V.f(f[2]), baselineRaw: Int(f[3]) ?? 0
            )
            XCTAssertEqual(V.flag(result), f[4], line)
        }
    }

    // MARK: - Sensor material

    private func materialJson(
        sensorId: String = "70:D0:7E:DC:B4:16", keyA: String? = nil, activeTime: Int64 = 1_700_000_000_000,
        expire: Int64 = 1_296_000_000, method: String = "", coefficient: String = "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,1.0"
    ) -> String {
        let key = keyA ?? (0..<96).map { String(format: "%02x", $0 & 0xFF) }.joined()
        return """
        {"v":1,"sensorId":"\(sensorId)","bleAddress":"","displayName":"","keyAHex":"\(key)","method":"\(method)",
        "coefficient":"\(coefficient)","activeTimeMs":\(activeTime),"activeExpireTimeMs":\(expire),
        "acceptedMaxActiveMs":0,"deviceVersion":"E1.2.3(V1.7.SH2542.1)"}
        """
    }

    func testMaterialsImport() throws {
        let result = OttaiMaterials.parse(json: materialJson())
        let materials = try XCTUnwrap(result.materials)
        XCTAssertNil(result.failure)
        XCTAssertEqual(materials.sensorId, "70D07EDCB416")
        XCTAssertEqual(materials.displayName, OttaiConstants.displayName)
        XCTAssertEqual(materials.macBytes, [0x70, 0xD0, 0x7E, 0xDC, 0xB4, 0x16])
        XCTAssertEqual(materials.authKeys?.count, 6)
        XCTAssertEqual(materials.coefficients.count, 14)
        XCTAssertEqual(materials.activeTimeMs, 1_700_000_000_000)
        XCTAssertEqual(materials.activeExpireTimeMs, 1_296_000_000)
        XCTAssertEqual(materials.expectedLifetimeMs, 1_296_000_000)
        XCTAssertEqual(materials.resolvedMethod, OttaiMethodDefaults.standard14CoefficientMethod)
        XCTAssertTrue(materials.canAuthenticateAndCompute)
    }

    func testMaterialsWithoutAnyExpressionCannotCompute() throws {
        let materials = try XCTUnwrap(OttaiMaterials.parse(json: materialJson(coefficient: "1,2,3")).materials)
        XCTAssertEqual(materials.resolvedMethod, "")
        XCTAssertFalse(materials.canAuthenticateAndCompute)
        let explicit = try XCTUnwrap(OttaiMaterials.parse(json: materialJson(method: "V0 C0 ML", coefficient: "1,2,3")).materials)
        XCTAssertEqual(explicit.resolvedMethod, "V0 C0 ML")
        XCTAssertTrue(explicit.canAuthenticateAndCompute)
    }

    func testMaterialsNormaliseSecondsAndRejectAnImplausibleLifetime() throws {
        let seconds = try XCTUnwrap(OttaiMaterials.parse(json: materialJson(activeTime: 1_700_000_000, expire: 100)).materials)
        XCTAssertEqual(seconds.activeTimeMs, 1_700_000_000_000)
        XCTAssertEqual(seconds.activeExpireTimeMs, 0)
        XCTAssertEqual(seconds.expectedLifetimeMs, OttaiConstants.defaultActiveExpireMs)
        let missing = try XCTUnwrap(OttaiMaterials.parse(json: materialJson(activeTime: 0)).materials)
        XCTAssertEqual(missing.activeTimeMs, 0)
    }

    func testMaterialsImportFailures() {
        XCTAssertEqual(OttaiMaterials.parse(json: "not json").failure, .notJson)
        XCTAssertEqual(OttaiMaterials.parse(json: "[]").failure, .notJson)
        XCTAssertEqual(OttaiMaterials.parse(json: materialJson(sensorId: "")).failure, .missingSensorId)
        XCTAssertEqual(OttaiMaterials.parse(json: materialJson(sensorId: "OTTAI-1234")).failure, .sensorIdNotTwelveHex)
        XCTAssertEqual(OttaiMaterials.parse(json: materialJson(keyA: "00ff")).failure, .invalidKeys)
        XCTAssertNil(OttaiMaterials.parse(json: materialJson(keyA: "00ff")).materials)
    }

    // MARK: - Kotlin number helpers

    func testKotlinIntParsing() {
        XCTAssertEqual(ottaiParseKotlinInt("12"), 12)
        XCTAssertEqual(ottaiParseKotlinInt("+1"), 1)
        XCTAssertEqual(ottaiParseKotlinInt("-0"), 0)
        XCTAssertEqual(ottaiParseKotlinInt("-2147483648"), -2147483648)
        XCTAssertNil(ottaiParseKotlinInt("2147483648"))
        XCTAssertNil(ottaiParseKotlinInt(""))
        XCTAssertNil(ottaiParseKotlinInt("-"))
        XCTAssertNil(ottaiParseKotlinInt("1x"))
        XCTAssertNil(ottaiParseKotlinInt("1 "))
    }

    func testKotlinIntConversionSaturates() {
        XCTAssertEqual(ottaiKotlinInt(Double.nan), 0)
        XCTAssertEqual(ottaiKotlinInt(3.0e10), Int32.max)
        XCTAssertEqual(ottaiKotlinInt(-3.0e10), Int32.min)
        XCTAssertEqual(ottaiKotlinInt(-2.9), -2)
        XCTAssertEqual(ottaiKotlinInt(2.9), 2)
    }

    func testHexHelpers() {
        XCTAssertEqual(OttaiHex.string([0x00, 0xAB, 0x7F]), "00ab7f")
        XCTAssertEqual(OttaiHex.bytes("00aB7f"), [0x00, 0xAB, 0x7F])
        XCTAssertNil(OttaiHex.bytes("abc"))
        XCTAssertNil(OttaiHex.bytes("zz"))
        XCTAssertEqual(OttaiHex.bytes(""), [])
    }
}

/// Lines printed by the unchanged Kotlin on the JVM (see the header).
enum OttaiProtocolVectors {

    static let defaultMethod = "V1 C0 ad C1 ml C2 ad;V0 R0 2 pw dv;C3 0 ml C4 R1 2 pw ml ad C5 R1 ml ad C6 ad;C7 R2 2 pw ml C8 R2 ml ad C9 ad;C10 V2 86400 dv C11 ml sb V2 C12 1 le ml V2 C12 1 gt C13 ml ad;R3 R4 ml 1 rd"

    static let ecdh: [String] = [
        "6b8e290ea6c1166378c1e0b223455fdb2ac39edcceab38cc1a25288724ea6097|fdcdca6a9a0e50a9634158a88af0f95e08fc5c11526fb0c50bf108ebe4c33196|45e0a9b4266ad97207f16de30fe054514c27fa2e0e9f54086539a354cbb0d87c|46d6c4b3a9f5bdf9e83a4ee260b2e919d9b6ce753bcb5e4a3cfa11244577d493|7a0daea791ca00fe22598d22be1c30640603ccb5be289c8f58a0d8e32b4f7d86|a809e55f46bc65ee474d6c0aebda671a",
        "8833d8d87af3e79f1b42cf832d40b4efa4ed81770efb91c8be624b523f43b4aa|bc0d4af0bc4fa740b6e09594ef2a21f55721c306a0d3c37859026ae87dbf4e6d|6611670df331084811c474e20bae9761b700683b870778f38051b60e64d75f1f|4d0534d0ca2bf139d3695ec878364bceb5d46062c1b2fe1d6873bb3b67d537fd|082ac4acf201c1edf1771f5caf858e59db5221dd7c36e34561327ead1cc0e937|adcc67f5be4d4cf031df4e0787f4449b",
        "a8af00af8054261177387d3b3fc0ba2c4fa0edbea9dd4590cb663ae8b2c92ba8|773f8be2dba462e86e907155674b16fa26ba0b3efaa52b2743cd2e99580a6002|ea90b5b588d7bbbe7842ef555f3256d9d7a10d43f9ac6ffedc44f8567a0e3c6e|20fbbabd71f8355c5f2f7f8bbec5f672ac43d8ae00e59f127a863ba93dd79e7f|4373bdbc08887754176f08c8b2c591988f389517ef8b9c166b2e03c888cb8c16|37a7593d467cb7eda17df1fa4fb4d126",
    ]

    static let pick: [String] = [
        "b2a8b6093ee5cf5ffb46efbc166528ee7b47824dfb6c4d0a5febc3daf967e11a|a809e55f46bc65ee474d6c0aebda671a",
        "b2a8b6093ee5cf5ffb46efbc166528ee7b47824dfb6c4d0a5febc3daf967e11a|a809e55f46bc65ee474d6c0aebda671a",
        "16ad78ccf86779f5cabe094d8b4cb9f0433100df984e93072f8711f42a443b9b|adcc67f5be4d4cf031df4e0787f4449b",
        "16ad78ccf86779f5cabe094d8b4cb9f0433100df984e93072f8711f42a443b9b|adcc67f5be4d4cf031df4e0787f4449b",
        "00370da7db599f3d54469a7c88b783ed12a1207d9df1d6faaf4f32b4d9d19926|37a7593d467cb7eda17df1fa4fb4d126",
        "370da7db599f3d54469a7c88b783ed12a1207d9df1d6faaf4f32b4d9d19926|NULL",
        "|NULL",
        "00112233|NULL",
    ]

    static let coord: [String] = [
        "01|0000000000000000000000000000000000000000000000000000000000000001",
        "ff|00000000000000000000000000000000000000000000000000000000000000ff",
        "80|0000000000000000000000000000000000000000000000000000000000000080",
        "7f00|0000000000000000000000000000000000000000000000000000000000007f00",
        "00ff00|000000000000000000000000000000000000000000000000000000000000ff00",
        "8000000000000000000000000000000000000000000000000000000000000001|8000000000000000000000000000000000000000000000000000000000000001",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff|ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "00000000000000000000000000000000000000000000000000000000000000ff|00000000000000000000000000000000000000000000000000000000000000ff",
    ]

    static let fixed: [String] = [
        "0102|4|00000102",
        "01020304|4|01020304",
        "0001020304|4|01020304",
        "ff000102030405|4|02030405",
        "|4|00000000",
    ]

    static let le32: [String] = [
        "01000000|1",
        "ffffffff|-1",
        "78563412|305419896",
        "0100000000|1",
        "0000008001|-2147483648",
    ]

    static let leBytes: [String] = [
        "0|00000000",
        "1|01000000",
        "-1|ffffffff",
        "305419896|78563412",
        "-2147483648|00000080",
    ]

    static let time3: [String] = [
        "01020304|010203",
        "ffffffff|000000",
        "00ffffff|010000",
        "ffffff|010000",
        "00|000000",
        "0102030405060708090a|070809",
        "07e90b1c0a1e2d010000|2d0100",
        "aabbccddeeff00112233|001122",
        "000000ff|000001",
        "abcdef01ffffffff|000000",
    ]

    static let sign: [String] = [
        "000102030405060708090a0b0c0d0e0f|70d07edcb416|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|aabbcc|abe844b27f559c1b25adec138b02038ef3e80d35cac3dade37a5a870f2c0a035",
        "ffffffffffffffffffffffffffffffff|001122334455|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|000000|0a275ed45fba71665a94c550c716c00757abe5d2e92546d28e5ffb6f24ac4260",
    ]

    static let verify: [String] = [
        "000102030405060708090a0b0c0d0e0f|70d07edcb416|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|aabbcc|abe844b27f559c1b25adec138b02038ef3e80d35cac3dade37a5a870f2c0a035|true",
        "000102030405060708090a0b0c0d0e0f|70d07edcb416|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|aabbcc|abe844b27f549c1b25adec138b02038ef3e80d35cac3dade37a5a870f2c0a035|false",
        "ffffffffffffffffffffffffffffffff|70d07edcb416|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|aabbcc|abe844b27f559c1b25adec138b02038ef3e80d35cac3dade37a5a870f2c0a035|false",
        "000102030405060708090a0b0c0d0e0f|70d07edcb416|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|aabbcc|abe844b27f559c1b25adec138b02038ef3e80d35cac3dade37a5a870f2c0a0|false",
    ]

    static let appParam: [String] = [
        "3|aabbcc|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|03aabbcc11111111111111111111111111111111111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222",
        "511|aabbcc|1111111111111111111111111111111111111111111111111111111111111111|2222222222222222222222222222222222222222222222222222222222222222|ffaabbcc11111111111111111111111111111111111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222",
    ]

    static let keys: [String] = [
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f|000102030405060708090a0b0c0d0e0f,101112131415161718191a1b1c1d1e1f,202122232425262728292a2b2c2d2e2f,303132333435363738393a3b3c3d3e3f,404142434445464748494a4b4c4d4e4f,505152535455565758595a5b5c5d5e5f",
        "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F404142434445464748494A4B4C4D4E4F505152535455565758595A5B5C5D5E5F|000102030405060708090a0b0c0d0e0f,101112131415161718191a1b1c1d1e1f,202122232425262728292a2b2c2d2e2f,303132333435363738393a3b3c3d3e3f,404142434445464748494a4b4c4d4e4f,505152535455565758595a5b5c5d5e5f",
        " 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f<NL>|000102030405060708090a0b0c0d0e0f,101112131415161718191a1b1c1d1e1f,202122232425262728292a2b2c2d2e2f,303132333435363738393a3b3c3d3e3f,404142434445464748494a4b4c4d4e4f,505152535455565758595a5b5c5d5e5f",
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e|NULL",
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5g|NULL",
    ]

    static let crypt: [String] = [
        "0f0e0d0c0b0a09080706050403020100|000000002458ffff1f3c34e115ba47c50b00000000000000|1d3ea359ef52c83181ed85c998d00eb338deddfe2871d3d4acdb58b4daa97ea8|000000002458ffff1f3c34e115ba47c50b00000000000000",
        "0f0e0d0c0b0a09080706050403020100|00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000|8c54e5df609a9269059c79642701420c1051fbaf0dbd4bbea24782d049bf36e7c35d85607619b11a194381a68ec9e85419d42ab1c503f8d0244f9205c458d5fd3fe2f8c9c4d4a4ff1068fd5a4165ab4cf27ce17ed80f61f4f010c8b147c2e7d2912644b76f3adebb54613701507bd3efd6f5136ae90dcf044bbb4174bc49d3aa2cb8da39b3e707ef460a5517f5891372e424cfc0049773b5c1f92a01b63e434149196003c7fc4b07e41f2b154a414ae7|00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000",
        "0f0e0d0c0b0a09080706050403020100|00000000000000000000000000000000|e5311321918c386e63e98dff0afa770d|0000000000000000",
        "0f0e0d0c0b0a09080706050403020100|00000000000000000100000000000000|f5e3cc7fdc7ddcda401039e9ddf01eaf|00000000000000000100000000000000",
        "0f0e0d0c0b0a09080706050403020100|0102030405060708|6cd392eb2e0c47ae86ea029b8d5f7b2d|0102030405060708",
        "0f0e0d0c0b0a09080706050403020100|0101010101010101010101010101010101010101010101010000000000000000|c1ccda4b841986aeb6ce19e17ebf321f126f1c12797df7594314c2a7c73e68f7|010101010101010101010101010101010101010101010101",
        "0f0e0d0c0b0a09080706050403020100|0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a|4db03a12b8036b135749bb16ba178a3ad4095a67fc1221d46160dd6d1e7e18ff|0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a00000000000000",
        "0f0e0d0c0b0a09080706050403020100|0000000000000000000000000000000000000000000000000000000000000000|e5311321918c386e63e98dff0afa770de5311321918c386e63e98dff0afa770d|000000000000000000000000000000000000000000000000",
        "0f0e0d0c0b0a09080706050403020100||e5311321918c386e63e98dff0afa770d|0000000000000000",
        "0f0e0d0c0b0a09080706050403020100|7f|bdc82531dd17d72e5c2f4ad094349a43|7f00000000000000",
    ]

    static let decrypt: [String] = [
        "0f0e0d0c0b0a09080706050403020100|00112233|NULL",
        "0f0e0d0c0b0a09080706050403020100||NULL",
        "zz|00000000000000000000000000000000|NULL",
        "0011|00000000000000000000000000000000|NULL",
    ]

    static let evidence: [String] = [
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|1,0|NULL|19585",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|0,3|8|10",
        "000000007600ffff1f3c34e115ba47c50b00000000000000|1,0|NULL|118",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d|1,1|NULL|118",
        "00000000d067ffff1e18fd54722ef70b|0,1|NULL|26576",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000|0,4|NULL|5335",
        "000000002458ffff1f3c34e115ba47c50b00000000000000|1,0|NULL|22564",
        "0000000001|0,0|NULL|0",
        "0000000001000000|0,0|NULL|1",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000|18,6|9|0",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000|9,3|9|0",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|6,20|8|0",
    ]

    static let frames: [String] = [
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000||NULL|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000||8|8|NULL|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000||9|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000||7|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.7.SH2542.1|NULL|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.7.SH2542.1|8|8|NULL|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.7.SH2542.1|9|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.7.SH2542.1|7|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E1.2.3(V1.7.SH2542.1)|NULL|9|9|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E1.2.3(V1.7.SH2542.1)|8|8|9|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E1.2.3(V1.7.SH2542.1)|9|9|9|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E1.2.3(V1.7.SH2542.1)|7|9|9|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|vE1.2.3(V1.7.SH2542.1)|NULL|9|9|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|vE1.2.3(V1.7.SH2542.1)|8|8|9|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|vE1.2.3(V1.7.SH2542.1)|9|9|9|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|vE1.2.3(V1.7.SH2542.1)|7|9|9|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.5.S2428.1|NULL|8|8|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.5.S2428.1|8|8|8|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.5.S2428.1|9|9|8|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|V1.5.S2428.1|7|8|8|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E9.9.9(V3.1.ZZ0000.0)|NULL|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E9.9.9(V3.1.ZZ0000.0)|8|8|NULL|3|0000814c1f3c34e115ba47c5,0000824c0b00000000000000,0000834c0000000000000000",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E9.9.9(V3.1.ZZ0000.0)|9|9|NULL|1|0000814c47113cee1f3cc50b",
        "00000000814cffff1f3c34e115ba47c50b000000000000000000000000000000|E9.9.9(V3.1.ZZ0000.0)|7|9|NULL|1|0000814c47113cee1f3cc50b",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d||NULL|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d||8|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d||9|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d||7|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E9.9.9(V9.9.UNK)|NULL|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E9.9.9(V9.9.UNK)|8|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E9.9.9(V9.9.UNK)|9|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E9.9.9(V9.9.UNK)|7|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|V1.5.S2428.1|NULL|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|V1.5.S2428.1|8|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|V1.5.S2428.1|9|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|V1.5.S2428.1|7|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E1.2.3(V1.7.SH2542.1)|NULL|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E1.2.3(V1.7.SH2542.1)|8|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E1.2.3(V1.7.SH2542.1)|9|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000000a00030005010203401fac0d05010203501fb00d05010203601fb40d|E1.2.3(V1.7.SH2542.1)|7|8|8|3|00000a0005010203401fac0d,00000b0005010203501fb00d,00000c0005010203601fb40d",
        "000000007600ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|NULL|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|8|8|NULL|2|000076001f3c34e115ba47c5,000077000b00000000000000",
        "000000007600ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|9|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|7|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b00000000000000||NULL|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b00000000000000||8|8|NULL|2|000076001f3c34e115ba47c5,000077000b00000000000000",
        "000000007600ffff1f3c34e115ba47c50b00000000000000||9|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b00000000000000||7|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d|E1.1.4(V1.7.S2530.1)|NULL|8|NULL|2|000076001f3c34e115ba47c5,000077000b000000401fac0d",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d|E1.1.4(V1.7.S2530.1)|8|8|NULL|2|000076001f3c34e115ba47c5,000077000b000000401fac0d",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d|E1.1.4(V1.7.S2530.1)|9|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d|E1.1.4(V1.7.S2530.1)|7|8|NULL|2|000076001f3c34e115ba47c5,000077000b000000401fac0d",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d||NULL|8|NULL|2|000076001f3c34e115ba47c5,000077000b000000401fac0d",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d||8|8|NULL|2|000076001f3c34e115ba47c5,000077000b000000401fac0d",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d||9|9|NULL|1|000076004700a81b1f3cc50b",
        "000000007600ffff1f3c34e115ba47c50b000000401fac0d||7|8|NULL|2|000076001f3c34e115ba47c5,000077000b000000401fac0d",
        "00000000d067ffff1e18fd54722ef70b|E1.2.3(V1.7.SH2542.1)|NULL|8|9|1|0000d0671e18fd54722ef70b",
        "00000000d067ffff1e18fd54722ef70b|E1.2.3(V1.7.SH2542.1)|8|8|9|1|0000d0671e18fd54722ef70b",
        "00000000d067ffff1e18fd54722ef70b|E1.2.3(V1.7.SH2542.1)|9|8|9|1|0000d0671e18fd54722ef70b",
        "00000000d067ffff1e18fd54722ef70b|E1.2.3(V1.7.SH2542.1)|7|8|9|1|0000d0671e18fd54722ef70b",
        "00000000d067ffff1e18fd54722ef70b||NULL|8|NULL|1|0000d0671e18fd54722ef70b",
        "00000000d067ffff1e18fd54722ef70b||8|8|NULL|1|0000d0671e18fd54722ef70b",
        "00000000d067ffff1e18fd54722ef70b||9|8|NULL|1|0000d0671e18fd54722ef70b",
        "00000000d067ffff1e18fd54722ef70b||7|8|NULL|1|0000d0671e18fd54722ef70b",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000||NULL|8|NULL|20|0000d714ce0344e0898a1366,0000d8140cc60344e0798b13,0000d914740cae0344e0698c,0000da14137e0c870344e059,0000db148d13890c870344e0,0000dc14498e13920c870344,0000dd14e0398f139b0c6f03,0000de1444e0299013a30c77,0000df140344e0199113ac0c,0000e0147f0344e0099213b5,0000e1140c770344e0f99213,0000e214bd0c770344e0e993,0000e31413c80c6f0344e0d9,0000e4149413cd0c7f0344e0,0000e514c99513d60c870344,0000e614e0b99613d50c9f03,0000e71444e0a99713c50cbe,0000e8140344e0999813bd0c,0000e914dd0344e0899913b5,0000ea140c00000000000000",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000||8|8|NULL|20|0000d714ce0344e0898a1366,0000d8140cc60344e0798b13,0000d914740cae0344e0698c,0000da14137e0c870344e059,0000db148d13890c870344e0,0000dc14498e13920c870344,0000dd14e0398f139b0c6f03,0000de1444e0299013a30c77,0000df140344e0199113ac0c,0000e0147f0344e0099213b5,0000e1140c770344e0f99213,0000e214bd0c770344e0e993,0000e31413c80c6f0344e0d9,0000e4149413cd0c7f0344e0,0000e514c99513d60c870344,0000e614e0b99613d50c9f03,0000e71444e0a99713c50cbe,0000e8140344e0999813bd0c,0000e914dd0344e0899913b5,0000ea140c00000000000000",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000||9|9|NULL|17|0000d714130464e2ce03660c,0000d8141304a0e2c603740c,0000d9141304dce2ae037e0c,0000da14130418e38703890c,0000db14130454e38703920c,0000dc14130490e387039b0c,0000dd141304cce36f03a30c,0000de14130408e47703ac0c,0000df14130444e47f03b50c,0000e014130480e47703bd0c,0000e1141304bce47703c80c,0000e2141304f8e46f03cd0c,0000e314130434e57f03d60c,0000e414130470e58703d50c,0000e5141304ace59f03c50c,0000e6141304e8e5be03bd0c,0000e714130424e6dd03b50c",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000||7|8|NULL|20|0000d714ce0344e0898a1366,0000d8140cc60344e0798b13,0000d914740cae0344e0698c,0000da14137e0c870344e059,0000db148d13890c870344e0,0000dc14498e13920c870344,0000dd14e0398f139b0c6f03,0000de1444e0299013a30c77,0000df140344e0199113ac0c,0000e0147f0344e0099213b5,0000e1140c770344e0f99213,0000e214bd0c770344e0e993,0000e31413c80c6f0344e0d9,0000e4149413cd0c7f0344e0,0000e514c99513d60c870344,0000e614e0b99613d50c9f03,0000e71444e0a99713c50cbe,0000e8140344e0999813bd0c,0000e914dd0344e0899913b5,0000ea140c00000000000000",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000|E1.1.4(V1.7.S2530.1)|NULL|8|NULL|20|0000d714ce0344e0898a1366,0000d8140cc60344e0798b13,0000d914740cae0344e0698c,0000da14137e0c870344e059,0000db148d13890c870344e0,0000dc14498e13920c870344,0000dd14e0398f139b0c6f03,0000de1444e0299013a30c77,0000df140344e0199113ac0c,0000e0147f0344e0099213b5,0000e1140c770344e0f99213,0000e214bd0c770344e0e993,0000e31413c80c6f0344e0d9,0000e4149413cd0c7f0344e0,0000e514c99513d60c870344,0000e614e0b99613d50c9f03,0000e71444e0a99713c50cbe,0000e8140344e0999813bd0c,0000e914dd0344e0899913b5,0000ea140c00000000000000",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000|E1.1.4(V1.7.S2530.1)|8|8|NULL|20|0000d714ce0344e0898a1366,0000d8140cc60344e0798b13,0000d914740cae0344e0698c,0000da14137e0c870344e059,0000db148d13890c870344e0,0000dc14498e13920c870344,0000dd14e0398f139b0c6f03,0000de1444e0299013a30c77,0000df140344e0199113ac0c,0000e0147f0344e0099213b5,0000e1140c770344e0f99213,0000e214bd0c770344e0e993,0000e31413c80c6f0344e0d9,0000e4149413cd0c7f0344e0,0000e514c99513d60c870344,0000e614e0b99613d50c9f03,0000e71444e0a99713c50cbe,0000e8140344e0999813bd0c,0000e914dd0344e0899913b5,0000ea140c00000000000000",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000|E1.1.4(V1.7.S2530.1)|9|9|NULL|17|0000d714130464e2ce03660c,0000d8141304a0e2c603740c,0000d9141304dce2ae037e0c,0000da14130418e38703890c,0000db14130454e38703920c,0000dc14130490e387039b0c,0000dd141304cce36f03a30c,0000de14130408e47703ac0c,0000df14130444e47f03b50c,0000e014130480e47703bd0c,0000e1141304bce47703c80c,0000e2141304f8e46f03cd0c,0000e314130434e57f03d60c,0000e414130470e58703d50c,0000e5141304ace59f03c50c,0000e6141304e8e5be03bd0c,0000e714130424e6dd03b50c",
        "00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000|E1.1.4(V1.7.S2530.1)|7|8|NULL|20|0000d714ce0344e0898a1366,0000d8140cc60344e0798b13,0000d914740cae0344e0698c,0000da14137e0c870344e059,0000db148d13890c870344e0,0000dc14498e13920c870344,0000dd14e0398f139b0c6f03,0000de1444e0299013a30c77,0000df140344e0199113ac0c,0000e0147f0344e0099213b5,0000e1140c770344e0f99213,0000e214bd0c770344e0e993,0000e31413c80c6f0344e0d9,0000e4149413cd0c7f0344e0,0000e514c99513d60c870344,0000e614e0b99613d50c9f03,0000e71444e0a99713c50cbe,0000e8140344e0999813bd0c,0000e914dd0344e0899913b5,0000ea140c00000000000000",
        "000000002458ffff1f3c34e115ba47c50b00000000000000||NULL|9|NULL|1|00002458471470a81f3cc50b",
        "000000002458ffff1f3c34e115ba47c50b00000000000000||8|8|NULL|2|000024581f3c34e115ba47c5,000025580b00000000000000",
        "000000002458ffff1f3c34e115ba47c50b00000000000000||9|9|NULL|1|00002458471470a81f3cc50b",
        "000000002458ffff1f3c34e115ba47c50b00000000000000||7|9|NULL|1|00002458471470a81f3cc50b",
        "000000002458ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|NULL|9|NULL|1|00002458471470a81f3cc50b",
        "000000002458ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|8|8|NULL|2|000024581f3c34e115ba47c5,000025580b00000000000000",
        "000000002458ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|9|9|NULL|1|00002458471470a81f3cc50b",
        "000000002458ffff1f3c34e115ba47c50b00000000000000|E1.1.4(V1.7.S2530.1)|7|9|NULL|1|00002458471470a81f3cc50b",
        "0000000001||NULL|8|NULL|0|",
        "0000000001||8|8|NULL|0|",
        "0000000001||9|8|NULL|0|",
        "0000000001||7|8|NULL|0|",
        "0000000001000000||NULL|8|NULL|0|",
        "0000000001000000||8|8|NULL|0|",
        "0000000001000000||9|8|NULL|0|",
        "0000000001000000||7|8|NULL|0|",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000|E1.1.4(V1.7.S2530.1)|NULL|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000|E1.1.4(V1.7.S2530.1)|8|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000|E1.1.4(V1.7.S2530.1)|9|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000|E1.1.4(V1.7.S2530.1)|7|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000||NULL|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000||8|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000||9|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d000000000000||7|9|9|18|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d,0000090047001c02201fac0d,00000a0047005802201fac0d,00000b0047009402201fac0d,00000c004700d002201fac0d,00000d0047000c03201fac0d,00000e0047004803201fac0d,00000f0047008403201fac0d,000010004700c003201fac0d,000011004700fc03201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000|E1.1.4(V1.7.S2530.1)|NULL|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000|E1.1.4(V1.7.S2530.1)|8|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000|E1.1.4(V1.7.S2530.1)|9|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000|E1.1.4(V1.7.S2530.1)|7|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000||NULL|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000||8|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000||9|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d201f0000000047ac0d00000000000000||7|9|9|9|0000000047000000201fac0d,0000010047003c00201fac0d,0000020047007800201fac0d,000003004700b400201fac0d,000004004700f000201fac0d,0000050047002c01201fac0d,0000060047006801201fac0d,000007004700a401201fac0d,000008004700e001201fac0d",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.1.4(V1.7.S2530.1)|NULL|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.1.4(V1.7.S2530.1)|8|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.1.4(V1.7.S2530.1)|9|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.1.4(V1.7.S2530.1)|7|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.2.3(V1.7.SH2542.1)|NULL|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.2.3(V1.7.SH2542.1)|8|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.2.3(V1.7.SH2542.1)|9|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c|E1.2.3(V1.7.SH2542.1)|7|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c||NULL|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c||8|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c||9|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
        "0000000000000000050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c050000000c1ea40c||7|8|8|20|00000000050000000c1ea40c,00000100050000000c1ea40c,00000200050000000c1ea40c,00000300050000000c1ea40c,00000400050000000c1ea40c,00000500050000000c1ea40c,00000600050000000c1ea40c,00000700050000000c1ea40c,00000800050000000c1ea40c,00000900050000000c1ea40c,00000a00050000000c1ea40c,00000b00050000000c1ea40c,00000c00050000000c1ea40c,00000d00050000000c1ea40c,00000e00050000000c1ea40c,00000f00050000000c1ea40c,00001000050000000c1ea40c,00001100050000000c1ea40c,00001200050000000c1ea40c,00001300050000000c1ea40c",
    ]

    static let records: [String] = [
        "0000640005013412e02ee40c|100|5|70196|12000|4040800000000000|false|true|true",
        "0000ffff050000006400e40c|65535|5|0|100|4040800000000000|false|false|false",
        "00003c000700e00e401fa40c|60|7|3808|8000|40402e147ae147ae|true|true|true",
        "00002c0107001027401fa40c|300|7|10000|8000|40402e147ae147ae|false|true|true",
        "00004600ffffffffffffffff|70|255|16777215|65535|40847acccccccccd|false|true|true",
        "0000050001002c01983ab70b|5|1|300|15000|403dfd70a3d70a3d|true|false|true",
        "00000a0001005802983ab70b|10|1|600|15000|403dfd70a3d70a3d|true|false|true",
    ]

    static let canon: [String] = [
        "70:D0:7E:DC:B4:16|70D07EDCB416|true|false",
        "70d07edcb416|70D07EDCB416|true|false",
        "70D07EDCB416|70D07EDCB416|true|false",
        " 70d07edcb416 |70D07EDCB416|true|false",
        "70D07EDCB41|70D07EDCB41|false|false",
        "70-D0-7E-DC-B4-16|70-D0-7E-DC-B4-16|false|false",
        "OTTAI-1234|OTTAI-1234|false|false",
        "||false|false",
        "ABCDEFGHIJKL|ABCDEFGHIJKL|false|true",
        "70:d0:7e:dc:b4:16:aa|70:d0:7e:dc:b4:16:aa|false|false",
    ]

    static let qr: [String] = [
        "(01)06971234567890(11)260101(17)280101(10)AB12(21)70D07EDCB416|70D07EDCB416|70D07EDCB416",
        "01069712345678902170D07EDCB416|70D07EDCB416|70D07EDCB416",
        "70:D0:7E:DC:B4:16|70D07EDCB416|70D07EDCB416",
        "70d07edcb416|70D07EDCB416|70D07EDCB416",
        "ABCDEFGHIJKL|NULL|ABCDEFGHIJKL",
        "A1B2C3D4E5F6|A1B2C3D4E5F6|A1B2C3D4E5F6",
        "0123456789AB 99|0123456789AB|0123456789AB",
        "01234567890123456789|012345678901|012345678901",
        "xyz|NULL|NULL",
        "|NULL|NULL",
        "(21)70D07EDCB416<GS>(10)B1|70D07EDCB416|70D07EDCB416",
        "21ABCDEF123456|ABCDEF123456|ABCDEF123456",
        "https://example.com/x?id=70D07EDCB416&z=1|70D07EDCB416|70D07EDCB416",
        "(01)06971234567890(21)0123456789AB|0123456789AB|0123456789AB",
        "AAAAAAAAAAAAAAAA|AAAAAAAAAAAA|AAAAAAAAAAAA",
        "  70D07EDCB416  |70D07EDCB416|70D07EDCB416",
        "ZZ70D07EDCB416ZZ|70D07EDCB416|70D07EDCB416",
    ]

    static let expire: [String] = [
        "0|0",
        "1|0",
        "9999999999|0",
        "10000000000|0",
        "864000000|864000000",
        "863999999|0",
        "3888000000|3888000000",
        "3888000001|0",
        "1296000000|1296000000",
        "-5|0",
    ]

    static let lifetime: [String] = [
        "0|0|1296000000",
        "1296000000|0|1296000000",
        "0|2592000000|2592000000",
        "1000|1296000000|1296000000",
        "2000000000|2600000000|2600000000",
        "5|1|1296000000",
    ]

    static let warmup: [String] = [
        "0|5|false",
        "1000|0|false",
        "1000|1000|true",
        "1000|600999|true",
        "1000|601000|false",
        "1000|601001|false",
        "1700000000000|1700000300000|true",
        "1700000000000|1700000600000|false",
        "-1|5|false",
    ]

    static let commandStatus: [String] = [
        "-1|false",
        "0|true",
        "1|true",
        "2|true",
        "3|false",
        "4|false",
        "5|false",
    ]

    static let names: [String] = [
        "Ottai CGM|true",
        "OTTAI|true",
        "ottai-1|true",
        "Syai|false",
        "xOttaix|true",
        "|false",
        "Libre|false",
    ]

    static let matches: [String] = [
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,1.0|true",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,86399.0,1.0|false",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,86400.0,1.0|true",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,604800.0,1.0|true",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,604800.5,1.0|false",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,2.0|true",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,2.5|false",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,-0.1|false",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,1.0,1.0|false",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0|false",
        "|false",
        "a,b|false",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,NaN,172800.0,1.0|false",
        "-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,Infinity,172800.0,1.0|false",
        " -25.0 , 0.1 , 1.0 , 0.0 , 0.0 , 0.00054 , 0.0 , 2.0 , 1.0 , 1.2 , 1.3 , 0.2 , 172800.0 , 1.0|true",
    ]

    static let resolve: [String] = [
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,1.0|true",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,86399.0,1.0|false",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,86400.0,1.0|true",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,604800.0,1.0|true",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,604800.5,1.0|false",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,2.0|true",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,2.5|false",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,-0.1|false",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,1.0,1.0|false",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0|false",
        "||false",
        "|a,b|false",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,NaN,172800.0,1.0|false",
        "|-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,Infinity,172800.0,1.0|false",
        "| -25.0 , 0.1 , 1.0 , 0.0 , 0.0 , 0.00054 , 0.0 , 2.0 , 1.0 , 1.2 , 1.3 , 0.2 , 172800.0 , 1.0|true",
        "  V0 C0 ML |-25.0,0.1,1.0,0.0,0.0,0.00054,0.0,2.0,1.0,1.2,1.3,0.2,172800.0,1.0|V0_C0_ML",
        "   |a|true",
    ]

    static let hard: [String] = [
        "12000|4040000000000000|40eccccd|NULL",
        "999|4040000000000000|40eccccd|raw=999",
        "1000|4040000000000000|40eccccd|NULL",
        "12000|4046800000000000|40eccccd|NULL",
        "12000|40468ccccccccccd|40eccccd|temp=45.1",
        "12000|402dcccccccccccd|40eccccd|temp=14.9",
        "12000|402e000000000000|40eccccd|NULL",
        "12000|c044000000000000|40eccccd|temp=-40.0",
        "12000|7ff8000000000000|40eccccd|temp=NaN",
        "12000|4040000000000000|42200000|NULL",
        "12000|4040000000000000|42206666|glucose=40.1",
        "12000|4040000000000000|00000000|glucose=0.0",
        "12000|4040000000000000|7fc00000|glucose=NaN",
        "12000|4040000000000000|7f800000|glucose=Infinity",
        "12000|4040000000000000|bf800000|glucose=-1.0",
        "0|4058c00000000000|00000000|glucose=0.0",
        "-5|4040000000000000|40eccccd|raw=-5",
    ]

    static let excursion: [String] = [
        "4161999a|26856|40f9999a|14534|true",
        "411e6666|18053|41066666|15032|true",
        "4114cccd|17026|40f00000|13707|true",
        "4114cccd|17026|40f00000|14000|true",
        "41000000|17026|40f00000|13707|false",
        "41100000|15000|40f00000|12712|false",
        "41100000|15000|40f00000|12711|true",
        "7fc00000|5|3f800000|5|false",
        "00000000|5|3f800000|5|false",
        "40a00000|0|3f800000|5|false",
        "40a00000|5|3f800000|-3|false",
        "40f00000|10000|40c00000|8000|true",
        "40c00000|8000|40f00000|10000|true",
        "40eccccd|12000|40bccccd|10170|false",
    ]
}
