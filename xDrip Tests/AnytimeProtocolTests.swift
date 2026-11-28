//
//  AnytimeProtocolTests.swift
//  xdripTests
//
//  Expected values come from running the unchanged JugglucoNG Kotlin (`drivers/anytime`) on the JVM:
//  the same frames, sensor codes and names were fed to `AnytimeFrames`, `AnytimeQr`,
//  `AnytimeConstants` and `AnytimeProfileResolver`, and every line they printed is checked here, so a
//  rounding, byte-order or table difference in the Swift port shows up. The CT5 frames were encrypted
//  with the fixed session key 0x5A, the way JugglucoNG's own `AnytimeCt5Tests` build theirs. A few
//  inputs are real captures that JugglucoNG's tests carry (CT2 SN08 live frames, the CT5 querySSN
//  answer, a used-sensor live push). Never compared with a real sensor.
//

import CoreBluetooth
import XCTest
@testable import xdrip

final class AnytimeProtocolTests: XCTestCase {

    // MARK: helpers

    private func bytes(_ text: String) -> [UInt8] {
        return AnytimeText.bytes(fromHex: text)
    }

    private func hx(_ data: [UInt8]?) -> String {
        guard let data = data else { return "nil" }
        return AnytimeText.compactHex(data)
    }

    /// The Kotlin vector printer's `f()`: a Float as thousandths.
    private func f(_ value: Float) -> String {
        return String(anytimeKotlinRound(value * 1000))
    }

    private func describeRaw(_ r: AnytimeRawRecord) -> String {
        return "id\(r.glucoseId)/ib\(f(r.ibNa))/iw\(f(r.iwNa))/t\(f(r.temperatureC))/\(hx(r.recordBytes))"
    }

    private func describeComputed(_ r: AnytimeComputedRecord) -> String {
        return "id\(r.glucoseId)/hypo\(r.hypoEarlyWarnMinutes)/hyper\(r.hyperEarlyWarnMinutes)/ib\(f(r.ibNa))/iw\(f(r.iwNa))/t\(f(r.temperatureC))"
            + "/mmol\(f(r.gluMmol))/ref\(f(r.referenceBgMmol))/err\(r.errorCode)/trend\(r.trend)/warn\(r.warnCode)/has\(r.hasGlucose)"
            + "/mgdl\(r.gluMgdl)/be\(r.beVoltageMv)/we\(r.weVoltageMv)/re\(r.reVoltageMv)/ce\(r.ceVoltageMv)/bat\(r.batteryRaw)"
    }

    private func describeQr(_ qr: AnytimeQrCalibration?) -> String {
        guard let q = qr else { return "null" }
        return "\(q.format.rawValue)|k\(f(q.k))|r\(f(q.r))|life\(q.lifeTime)|m\(q.productMonth)|y\(q.productYear)|el\(q.electrodeType)"
            + "|elt\(q.electrodeTecNo)|enz\(q.enzymeTecNo)|mem\(q.membraneTecNo)|mkt\(q.marketNo)|ser\(q.serialNo)|sn\(q.sensorNo)"
            + "|unit\(q.unitOrder)|vf\(q.voltageFlag)|cnt\(q.calibrationCount)|fac\(q.isFactoryCalibration)|trkr\(q.hasTransmitterKr)"
    }

    private func kotlinFamily(_ family: AnytimeFamily) -> String {
        switch family {
        case .ct2: return "CT2"
        case .ct25: return "CT2_5"
        case .ct3: return "CT3"
        case .ct3Plus: return "CT3_PLUS"
        case .ct3Yuwell: return "CT3_YUWELL"
        case .ct3Ultrasonic: return "CT3_ULTRASONIC"
        case .ct4: return "CT4"
        case .ct5: return "CT5"
        case .unknown: return "UNKNOWN"
        }
    }

    private func kotlinFailure(_ failure: AnytimeCheckFailure?) -> String {
        guard let failure = failure else { return "null" }
        switch failure {
        case .lowBattery: return "LOW_BATTERY"
        case .lowIw: return "LOW_IW"
        case .badTemperature: return "BAD_TEMPERATURE"
        case .malformed: return "MALFORMED"
        }
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return utc.date(from: components)!
    }

    private let key = 0x5A

    /// The 11-byte plaintext CT5 record chunk of JugglucoNG's `AnytimeCt5Tests`.
    private func chunk(ib: Float, iw: Float, temperature: Float, trend: Int, glucose: Int, error: Int = 0) -> [UInt8] {
        let ibRaw = anytimeKotlinRound(ib * 100)
        let iwRaw = anytimeKotlinRound(iw * 100)
        let tInt = anytimeKotlinInt(temperature)
        let tFrac = anytimeKotlinRound((temperature - Float(tInt)) * 100)
        return [
            UInt8((ibRaw >> 8) & 0xFF), UInt8(ibRaw & 0xFF),
            UInt8((iwRaw >> 8) & 0xFF), UInt8(iwRaw & 0xFF),
            UInt8(truncatingIfNeeded: tInt + AnytimeConstants.tempIntOffset), UInt8(truncatingIfNeeded: tFrac),
            UInt8(((trend & 0x0F) << 4) | ((glucose >> 8) & 0x0F)),
            UInt8(glucose & 0xFF), UInt8(truncatingIfNeeded: error), 0x00, 0x00
        ]
    }

    private func livePushFrame(_ id: Int, _ payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [AnytimeOpcode.rxCt5PushGlucose, UInt8(id & 0xFF), UInt8((id >> 8) & 0xFF)]
        frame.append(contentsOf: AnytimeFrames.ct5Decode(payload, cipherKey: key))
        frame.append(AnytimeFrames.sum(frame, from: 0, to: frame.count - 1))
        return frame
    }

    private func seriesFrame(_ startId: Int, _ chunks: [[UInt8]], trailing: [[UInt8]] = []) -> [UInt8] {
        let plain = chunks.flatMap { $0 }
        var frame: [UInt8] = [AnytimeOpcode.rxCt5Series, UInt8(startId & 0xFF), UInt8((startId >> 8) & 0xFF)]
        frame.append(contentsOf: AnytimeFrames.ct5Decode(plain, cipherKey: key))
        frame.append(contentsOf: trailing.flatMap { $0 })
        frame.append(AnytimeFrames.sum(frame, from: 0, to: frame.count - 1))
        return frame
    }

    private func marker(_ value: UInt8) -> [UInt8] {
        return [UInt8](repeating: value, count: AnytimeConstants.ct5RawChunkSize)
    }

    private func voltageChunk() -> [UInt8] {
        return Array(chunk(ib: 1, iw: 8.5, temperature: 34, trend: 3, glucose: 120).prefix(9)) + [0x10, 0x20, 0x30, 0x40, 0x0B, 0xB8]
    }

    private func withSum(_ values: [Int]) -> [UInt8] {
        var frame = values.map { UInt8(truncatingIfNeeded: $0) }
        frame.append(AnytimeFrames.sum(frame, from: 0, to: frame.count - 1))
        return frame
    }


    // MARK: frame builders

    func testFrameBuildersMatchTheKotlinOriginal() {
        XCTAssertEqual(hx(AnytimeFrames.Builders.version()), "01", "b.version")
        XCTAssertEqual(hx(AnytimeFrames.Builders.check()), "05", "b.check")
        XCTAssertEqual(hx(AnytimeFrames.Builders.checkSummed()), "0555AA04", "b.checkSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.initFrame()), "06", "b.init")
        XCTAssertEqual(hx(AnytimeFrames.Builders.initSummed()), "0655AA05", "b.initSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.lowPower()), "0F", "b.lowPower")
        XCTAssertEqual(hx(AnytimeFrames.Builders.lowPowerSummed()), "0F55AA0E", "b.lowPowerSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.reset()), "11", "b.reset")
        XCTAssertEqual(hx(AnytimeFrames.Builders.resetSummed()), "1155AA10", "b.resetSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.unbind()), "0A", "b.unbind")
        XCTAssertEqual(hx(AnytimeFrames.Builders.unbindSummed()), "0A55AA09", "b.unbindSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.unbindGeneric()), "5855AA57", "b.unbindGeneric")
        XCTAssertEqual(hx(AnytimeFrames.Builders.setDate(utcDate(2026, 9, 7, 20, 7, 24), calendar: utc)), "037E0907140718", "b.setDate")
        XCTAssertEqual(hx(AnytimeFrames.Builders.setDateSummed(utcDate(2026, 9, 7, 20, 7, 24), calendar: utc)), "037E0907140718C4", "b.setDateSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.pullGlucose(0x1234)), "083412", "b.pullGlucose")
        XCTAssertEqual(hx(AnytimeFrames.Builders.pullGlucose(0x12345)), "084523", "b.pullGlucoseWrap")
        XCTAssertEqual(hx(AnytimeFrames.Builders.pullGlucoseSummed(0x1234)), "0834124E", "b.pullGlucoseSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.pullGlucoseSeriesSummed(147, count: 15)), "2293000FC4", "b.series147x15")
        XCTAssertEqual(hx(AnytimeFrames.Builders.pullGlucoseSeriesSummed(300, count: 0)), "222C010150", "b.series300x0")
        XCTAssertEqual(hx(AnytimeFrames.Builders.pullGlucoseSeriesSummed(300, count: 99)), "222C010F5E", "b.series300x99")
        XCTAssertEqual(hx(AnytimeFrames.Builders.fetchComputedGlucose(0x0102)), "0C0201", "b.fetchComputed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMg(100)), "090506", "b.inputBg100")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMgSummed(100)), "09050614", "b.inputBgSummed100")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMg(137)), "090706", "b.inputBg137")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMgSummed(137)), "09070616", "b.inputBgSummed137")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMg(54)), "090300", "b.inputBg54")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMgSummed(54)), "0903000C", "b.inputBgSummed54")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMg(400)), "091602", "b.inputBg400")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMgSummed(400)), "09160221", "b.inputBgSummed400")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMg(181)), "090A01", "b.inputBg181")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputBgMgSummed(181)), "090A0114", "b.inputBgSummed181")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKR(1.13, 1.0)), "0B01010100", "b.inputKR_1130_1000")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKRSummed(1.13, 1.0)), "0B010D01001A", "b.inputKRSummed_1130_1000")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKR(1.09, 1.0)), "0B01000100", "b.inputKR_1090_1000")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKRSummed(1.09, 1.0)), "0B0109010016", "b.inputKRSummed_1090_1000")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKR(0.97, 2.5)), "0B00090205", "b.inputKR_970_2500")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKRSummed(0.97, 2.5)), "0B00610232A0", "b.inputKRSummed_970_2500")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKR(3.45, 6.0)), "0B03040600", "b.inputKR_3450_6000")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKRSummed(3.45, 6.0)), "0B032D060041", "b.inputKRSummed_3450_6000")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKR(1.2, 45.6)), "0B01022D05", "b.inputKR_1200_45600")
        XCTAssertEqual(hx(AnytimeFrames.Builders.inputKRSummed(1.2, 45.6)), "0B01142D3B88", "b.inputKRSummed_1200_45600")
        XCTAssertEqual(hx(AnytimeFrames.Builders.modifyVoltage(0)), "150000000000000000000015", "b.modifyVoltage0")
        XCTAssertEqual(hx(AnytimeFrames.Builders.modifyVoltage(1)), "150100000000000000000016", "b.modifyVoltage1")
        XCTAssertEqual(hx(AnytimeFrames.Builders.transmitterFormal()), "20", "b.formal")
        XCTAssertEqual(hx(AnytimeFrames.Builders.transmitterFormalSummed()), "2055AA1F", "b.formalSummed")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5GetDate()), "0455AA03", "b.ct5GetDate")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5CheckId(randomB: [1, 2, 3, 4])), "31010203043B", "b.ct5CheckId")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5CheckId(randomB: [200, 201, 202, 203])), "31C8C9CACB57", "b.ct5CheckIdHigh")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5SetId(randomA: [1, 2, 3, 4], randomB: [5, 6, 7, 8])), "30050607080510223CBD", "b.ct5SetId")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5SetId(randomA: [250, 3, 99, 17], randomB: [200, 201, 7, 255])), "30C8C907FF50A2891E60", "b.ct5SetIdHigh")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5QuerySsn()), "3F55AA3E", "b.ct5QuerySsn")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5PushAck()), "3555AA34", "b.ct5PushAck")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5BindStateQuery()), "1155AA10", "b.ct5BindState")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5PullGlucoseSeries(300, count: 15)), "372C010F73", "b.ct5Series300")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5PullGlucoseSeries(5, count: 1)), "370500013D", "b.ct5Series5x1")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5InputBgMg(100)), "0900646D", "b.ct5InputBg100")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5InputBgMg(256)), "0901000A", "b.ct5InputBg256")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5EndCycle(tempId: "1234")), "0A31323334D4", "b.ct5EndCycle")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5SetParameters(k: 1.15, r: 1.0, cipherKey: 0x5A, tempId: "1234")), "380FF5F00F0E3E3C0F1FE11E1C0C", "b.ct5SetParams_115_10_5A_1234")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5SetParameters(k: 1.09, r: 1.0, cipherKey: 237, tempId: "12")), "3847BFB84746767447575757A962", "b.ct5SetParams_109_10_237_12")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5SetParameters(k: 1.10, r: 1.0, cipherKey: 0, tempId: "0000")), "38AA5355AAAB9B99AABABABABAA5", "b.ct5SetParams_110_10_0_0000")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct5SetParameters(k: 3.45, r: 6.5, cipherKey: 255, tempId: "98765")), "38ABB1A8BB546466554242B847ED", "b.ct5SetParams_345_65_255_9876")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2Version()), "03", "b.ct2Version")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2Handshake(deviceName: "SN08402458")), "48534E303834303234353888", "b.ct2Handshake")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2SetDate(utcDate(2026, 9, 7, 20, 7, 24), calendar: utc)), "5407EA090714071888", "b.ct2SetDate")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2Init()), "5355AA52", "b.ct2Init")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2Check()), "4355AA42", "b.ct2Check")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2LowPower()), "5755AA56", "b.ct2LowPower")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2Unbind()), "5855AA57", "b.ct2Unbind")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2PullGlucose(14)), "55000E63", "b.ct2Pull14")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2PullGlucose(65535)), "55FFFF53", "b.ct2Pull65535")
        XCTAssertEqual(hx(AnytimeFrames.Builders.ct2InputBgMg(100)), "0800646C", "b.ct2InputBg100")
    }

    func testBuildersRejectBadCt5Arguments() {
        XCTAssertNil(AnytimeFrames.Builders.ct5CheckId(randomB: [1, 2, 3]))
        XCTAssertNil(AnytimeFrames.Builders.ct5SetId(randomA: [1, 2, 3], randomB: [1, 2, 3, 4]))
        XCTAssertNil(AnytimeFrames.Builders.ct5SetId(randomA: [1, 2, 3, 4], randomB: [1, 2, 3, 4, 5]))
        XCTAssertNil(AnytimeFrames.Builders.ct5EndCycle(tempId: "123"))
        XCTAssertNil(AnytimeFrames.Builders.ct5SetParameters(k: 1.1, r: 1.0, cipherKey: 256, tempId: "1234"))
        XCTAssertNil(AnytimeFrames.Builders.ct5SetParameters(k: 1.1, r: 1.0, cipherKey: -1, tempId: "1234"))
    }

    // MARK: sums

    func testSumsMatchTheKotlinOriginal() {
        XCTAssertEqual(Int(AnytimeFrames.sum(bytes("0102030405"), from: 0, to: 3)), 10)
        XCTAssertEqual(Int(AnytimeFrames.sum(bytes("FFFFFF01"), from: 0, to: 3)), 254)
        XCTAssertEqual(AnytimeFrames.verifySum(bytes("0A55AA09")), true)
        XCTAssertEqual(AnytimeFrames.verifySum(bytes("0A55AA10")), false)
        XCTAssertEqual(AnytimeFrames.verifySum(bytes("0A")), false)
    }

    // MARK: CT5 crypto and identity

    func testConvolutionMatchesTheKotlinOriginal() {
        XCTAssertEqual(AnytimeFrames.ct5Convolve([5, 6, 7, 8], [1, 2, 3, 4]).map(String.init).joined(separator: ","), "5,16,34,60")
        XCTAssertEqual(AnytimeFrames.ct5Convolve([250, 251, 252, 253], [255, 254, 253, 252]).map(String.init).joined(separator: ","), "63750,127505,191264,255026")
    }

    func testCipherMatchesTheKotlinOriginal() {
        let plain = bytes("010901000353550031323334")
        XCTAssertEqual(hx(AnytimeFrames.ct5Decode(plain, cipherKey: 0x5A)), "0FF7F00F0E3E3C0F1FE11E1C")
        XCTAssertEqual(hx(AnytimeFrames.ct5Decode(plain, cipherKey: 237)), "B84047B8B9898BB8A856A9AB")
        XCTAssertEqual(hx(AnytimeFrames.ct5Decode(plain, cipherKey: 0)), "55ADAA555464665545BB4446")
        XCTAssertEqual(hx(AnytimeFrames.ct5Encode(plain, cipherKey: 0x5A)), "120A121114E4EE114247444C")
        XCTAssertEqual(hx(AnytimeFrames.ct5Encode(plain, cipherKey: 237)), "CAD2CAC9CC3C36C99A9F9C95")
        XCTAssertEqual(hx(AnytimeFrames.ct5Encode(AnytimeFrames.ct5Decode(plain, cipherKey: 0x5A), cipherKey: 0x5A)), "010901000353550031323334")
        XCTAssertEqual(hx(AnytimeFrames.ct5Decode([], cipherKey: 7)), "")
        XCTAssertEqual(hx(AnytimeFrames.ct5Decode(bytes("A5"), cipherKey: 7)), "CE")
        XCTAssertEqual(hx(AnytimeFrames.ct5Encode(bytes("A5"), cipherKey: 7)), "18")
    }

    func testSessionKeyFromTheSetIdAnswer() {
        let response = withSum([0x30, 0x11, 0x22, 0x33, 0x44, 0xA1, 0xB2, 0xC3, 0xD4])
        XCTAssertEqual(hx(response), "3011223344A1B2C3D4C4")
        XCTAssertEqual(AnytimeFrames.ct5SessionKey(fromSetIdResponse: response, randomA: [1, 2, 3, 4]), 171)
        XCTAssertEqual(AnytimeFrames.ct5SessionKey(fromSetIdResponse: response, randomA: [9, 8, 7, 6]), 1)
        XCTAssertEqual(AnytimeFrames.ct5SessionKey(fromSetIdResponse: bytes("3011223344A1B2C3D400"), randomA: [1, 2, 3, 4]), -1)
        XCTAssertEqual(AnytimeFrames.ct5SessionKey(fromSetIdResponse: withSum([0x30, 1, 2, 3, 4]), randomA: [1, 2, 3, 4]), -1)
        XCTAssertEqual(AnytimeFrames.ct5SessionKey(fromSetIdResponse: withSum([0x31, 0x11, 0x22, 0x33, 0x44, 0xA1]), randomA: [1, 2, 3, 4]), -1)
        XCTAssertEqual(AnytimeFrames.ct5SessionKey(fromSetIdResponse: response, randomA: [1, 2, 3]), -1)
    }

    func testQuerySsnAnswerFromAReal237KeySession() {
        // RX 0x3F captured by JugglucoNG on 2026-09-26; the session cipher key was 237.
        let frame = bytes("3F 57 57 54 55 57 A9 A8 57 54 A8 54 55 AA A8 57 AB A8 57 57 7A A8")
        XCTAssertEqual(AnytimeFrames.parseCt5QuerySsnResponse(frame, cipherKey: 237), "0056131041576115100F1")
        XCTAssertEqual(AnytimeFrames.parseCt5QuerySsnResponse(frame, cipherKey: 236), "3365202372645226233E2")
        XCTAssertNil(AnytimeFrames.parseCt5QuerySsnResponse(frame, cipherKey: 300))
        XCTAssertNil(AnytimeFrames.parseCt5QuerySsnResponse(bytes("3E5757"), cipherKey: 237))
        XCTAssertNil(AnytimeFrames.parseCt5QuerySsnResponse(bytes("3F"), cipherKey: 237))
        XCTAssertEqual(AnytimeQr.parse(AnytimeFrames.parseCt5QuerySsnResponse(frame, cipherKey: 237))?.k, 1.15)
    }

    // MARK: CT5 live and series frames

    func testLiveFramesAreBuiltAndParsedLikeKotlin() {
        let warm = livePushFrame(7, chunk(ib: 0, iw: 3.20, temperature: 32.5, trend: 0, glucose: 0))
        XCTAssertEqual(hx(warm), "3507000F0F0FCF371EF0F0F0F0F03D")
        XCTAssertEqual(AnytimeFrames.parseCt5CurrentRecord(warm, cipherKey: key).map(describeComputed), "id7/hypo0/hyper0/ib0/iw3200/t32500/mmol0/ref0/err0/trend0/warn0/hasfalse/mgdl0/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")

        let first = livePushFrame(14, chunk(ib: 0, iw: 6.72, temperature: 33.5, trend: 4, glucose: 96))
        XCTAssertEqual(hx(first), "350E00F0F0F16F37E130D0F0F0F06B")
        XCTAssertEqual(AnytimeFrames.parseCt5CurrentRecord(first, cipherKey: key).map(describeComputed), "id14/hypo0/hyper0/ib0/iw6720/t33500/mmol5333/ref0/err0/trend4/warn0/hastrue/mgdl96/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")

        let big = livePushFrame(0x1234, chunk(ib: 5.5, iw: 14.25, temperature: 36.75, trend: 6, glucose: 301, error: 3))
        XCTAssertEqual(hx(big), "3534120EED0C7FCB362FEBF1F0F0ED")
        XCTAssertEqual(AnytimeFrames.parseCt5CurrentRecord(big, cipherKey: key).map(describeComputed), "id4660/hypo0/hyper0/ib5500/iw14250/t36750/mmol16722/ref0/err3/trend6/warn0/hastrue/mgdl301/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")

        var badSum = warm
        badSum[badSum.count - 1] = badSum[badSum.count - 1] &+ 1
        XCTAssertNil(AnytimeFrames.parseCt5CurrentRecord(badSum, cipherKey: key))
        XCTAssertEqual(AnytimeFrames.parseCt5CurrentRecord(first, cipherKey: 0x5B).map(describeComputed), "id14/hypo0/hyper0/ib7710/iw4190/t34490/mmol48167/ref0/err3/trend4/warn0/hastrue/mgdl867/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")
        XCTAssertNil(AnytimeFrames.parseCt5CurrentRecord(first, cipherKey: 256))
        XCTAssertNil(AnytimeFrames.parseCt5CurrentRecord(first, cipherKey: -1))
    }

    func testWarmupRecordIsValidTelemetryWithoutGlucose() {
        let frame = livePushFrame(7, chunk(ib: 0, iw: 3.20, temperature: 32.5, trend: 0, glucose: 0))
        let record = AnytimeFrames.parseCt5CurrentRecord(frame, cipherKey: key)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.hasGlucose, false)
        XCTAssertEqual(record?.gluMgdl, 0)
    }

    func testTheDocumentedLayoutDecodes() {
        // The plaintext layout JugglucoNG's tests document: Ib 4.39, Iw 13.74, 33.10 C, trend 5, 123 mg/dL.
        var frame = [UInt8](repeating: 0, count: 15)
        frame[0] = 0x35
        frame[1] = 0x93
        let encrypted = AnytimeFrames.ct5Decode(bytes("01B7055E490A507B000000"), cipherKey: key)
        for index in 0..<encrypted.count { frame[3 + index] = encrypted[index] }
        frame[14] = AnytimeFrames.sum(frame, from: 0, to: 13)
        XCTAssertEqual(hx(frame), "3593000F9DF3C537F6C0D9F0F0F0C2")
        XCTAssertEqual(AnytimeFrames.parseCt5CurrentRecord(frame, cipherKey: key).map(describeComputed), "id147/hypo0/hyper0/ib4390/iw13740/t33100/mmol6833/ref0/err0/trend5/warn0/hastrue/mgdl123/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")
    }

    func testCipherInferenceFromAUsedSensorPush() {
        let used = bytes("35E700D8D8D9D61EC8E7142725" + "31D9")
        let candidate = AnytimeFrames.inferCt5CipherFromCurrentRecord(used)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate.map { (0...255).contains($0.cipherKey) }, true)
        XCTAssertEqual(candidate.map { describeComputed($0.record) }, "id231/hypo0/hyper0/ib0/iw7870/t34480/mmol4722/ref0/err0/trend4/warn0/hastrue/mgdl85/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")
        XCTAssertEqual(AnytimeFrames.inferCt5CipherFromCurrentRecord(used, maxGlucoseId: 100).map { describeComputed($0.record) }, nil)

        var corrupted = used
        corrupted[14] = 0
        XCTAssertNil(AnytimeFrames.inferCt5CipherFromCurrentRecord(corrupted))
    }

    func testCipherInferenceOnAmbiguousFramesBehavesLikeKotlin() {
        let warm = livePushFrame(7, chunk(ib: 0, iw: 3.20, temperature: 32.5, trend: 0, glucose: 0))
        XCTAssertEqual(AnytimeFrames.inferCt5CipherFromCurrentRecord(warm).map { describeComputed($0.record) }, "id7/hypo0/hyper0/ib0/iw3200/t32500/mmol0/ref0/err0/trend0/warn0/hasfalse/mgdl0/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")
        let first = livePushFrame(14, chunk(ib: 0, iw: 6.72, temperature: 33.5, trend: 4, glucose: 96))
        let inferred = AnytimeFrames.inferCt5CipherFromCurrentRecord(first)
        XCTAssertEqual(inferred.map { "key=\($0.cipherKey) \(describeComputed($0.record))" }, "key=90 id14/hypo0/hyper0/ib0/iw6720/t33500/mmol5333/ref0/err0/trend4/warn0/hastrue/mgdl96/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")
    }

    func testVoltageFramesCarryTheElectrodePotentials() {
        XCTAssertEqual(hx(voltageChunk()), "006403524A00307800102030400BB8")
        let frame = livePushFrame(21, voltageChunk())
        XCTAssertEqual(hx(frame), "3515000F2CF1C136F0E0D8F0FF10E0CF099864")
        XCTAssertEqual(frame.count, 19)
        XCTAssertEqual(AnytimeFrames.parseCt5CurrentRecord(frame, cipherKey: key).map(describeComputed), "id21/hypo0/hyper0/ib1000/iw8500/t34000/mmol6667/ref0/err0/trend3/warn0/hastrue/mgdl120/be96/we192/re288/ce384/bat3000")
    }

    func testSeriesFramesAreBuiltAndParsedLikeKotlin() {
        let three = seriesFrame(100, [
            chunk(ib: 0, iw: 7.0, temperature: 34.0, trend: 4, glucose: 100),
            chunk(ib: 0.1, iw: 7.2, temperature: 34.1, trend: 5, glucose: 104),
            chunk(ib: 0.2, iw: 7.4, temperature: 34.2, trend: 6, glucose: 110, error: 1)
        ])
        XCTAssertEqual(hx(three), "3764000F0F0E9B36F0CF2CF0F0F0F0F6F140C9093F28F0F0F0F0FCF15336FCD0D50FF0F069")
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(three, cipherKey: key).map(describeComputed), ["id100/hypo0/hyper0/ib0/iw7000/t34000/mmol5556/ref0/err0/trend4/warn0/hastrue/mgdl100/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648", "id101/hypo0/hyper0/ib100/iw7200/t34100/mmol5778/ref0/err0/trend5/warn0/hastrue/mgdl104/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648", "id102/hypo0/hyper0/ib200/iw7400/t34200/mmol6111/ref0/err1/trend6/warn0/hastrue/mgdl110/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648"])

        // A partial batch is padded with all-0xFF chunks, which must be skipped.
        let padded = seriesFrame(200, [
            chunk(ib: 0, iw: 7.0, temperature: 34.0, trend: 4, glucose: 100),
            chunk(ib: 0, iw: 7.1, temperature: 34.0, trend: 4, glucose: 102)
        ], trailing: [marker(0xFF), marker(0xFF)])
        XCTAssertEqual(hx(padded), "37C800F0F0F164C90F30D30F0F0F0F0F0EB2C90F30D2F0F0F0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFAE")
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(padded, cipherKey: key).map(describeComputed), ["id200/hypo0/hyper0/ib0/iw7000/t34000/mmol5556/ref0/err0/trend4/warn0/hastrue/mgdl100/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648", "id201/hypo0/hyper0/ib0/iw7100/t34000/mmol5667/ref0/err0/trend4/warn0/hastrue/mgdl102/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648"])

        // An all-0xFC chunk ends the batch; whatever follows it is ignored.
        let stopped = seriesFrame(300, [chunk(ib: 0, iw: 7.0, temperature: 34.0, trend: 4, glucose: 100)],
                                  trailing: [marker(0xFC), marker(0xAB)])
        XCTAssertEqual(hx(stopped), "372C010F0F0E9B36F0CF2CF0F0F0FCFCFCFCFCFCFCFCFCFCFCABABABABABABABABABABAB49")
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(stopped, cipherKey: key).map(describeComputed), ["id300/hypo0/hyper0/ib0/iw7000/t34000/mmol5556/ref0/err0/trend4/warn0/hastrue/mgdl100/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648"])
    }

    func testEmptyAndInvalidSeriesFrames() {
        let empty = withSum([0x37, 0x2C, 0x01])
        XCTAssertEqual(hx(empty), "372C0164")
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(empty, cipherKey: key).count, 0)

        let allFill = seriesFrame(400, [], trailing: [marker(0xFF)])
        XCTAssertEqual(hx(allFill), "379001FFFFFFFFFFFFFFFFFFFFFFBD")
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(allFill, cipherKey: key).count, 0)

        var badSum = seriesFrame(100, [chunk(ib: 0, iw: 7.0, temperature: 34.0, trend: 4, glucose: 100)])
        badSum[badSum.count - 1] = badSum[badSum.count - 1] &+ 1
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(badSum, cipherKey: key).count, 0)

        var wrongOpcode = seriesFrame(100, [chunk(ib: 0, iw: 7.0, temperature: 34.0, trend: 4, glucose: 100)])
        wrongOpcode[0] = 0x36
        wrongOpcode[wrongOpcode.count - 1] = AnytimeFrames.sum(wrongOpcode, from: 0, to: wrongOpcode.count - 2)
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(wrongOpcode, cipherKey: key).count, 0)

        // Frames too short to hold a record never trap.
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords([], cipherKey: key).count, 0)
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(withSum([0x37]), cipherKey: key).count, 0)
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(withSum([0x37, 0x01]), cipherKey: key).count, 0)
    }

    func testVoltageSeriesFrames() {
        let frame = seriesFrame(50, [voltageChunk(), voltageChunk()])
        XCTAssertEqual(hx(frame), "373200F0D30E3EC90F1F270F00EF1F30F6670F2CF1C136F0E0D8F0FF10E0CF09985A")
        XCTAssertEqual(AnytimeFrames.parseCt5SeriesRecords(frame, cipherKey: key, voltage: true).map(describeComputed), ["id50/hypo0/hyper0/ib1000/iw8500/t34000/mmol6667/ref0/err0/trend3/warn0/hastrue/mgdl120/be96/we192/re288/ce384/bat3000", "id51/hypo0/hyper0/ib1000/iw8500/t34000/mmol6667/ref0/err0/trend3/warn0/hastrue/mgdl120/be96/we192/re288/ce384/bat3000"])
    }

    // MARK: bind state and reset

    func testCt5BindStateMatchesKotlin() {
        let bind14bound = AnytimeFrames.parseCt5BindState(bytes("1155010000000000000000000067"))
        XCTAssertEqual(bind14bound?.isBound, true, "r.bind14bound.parse")
        XCTAssertEqual(bind14bound?.unbindReason, -1, "r.bind14bound.parse")
        let bind14unbound = AnytimeFrames.parseCt5BindState(bytes("1155000000000000010000002289"))
        XCTAssertEqual(bind14unbound?.isBound, false, "r.bind14unbound.parse")
        XCTAssertEqual(bind14unbound?.unbindReason, 1, "r.bind14unbound.parse")
        XCTAssertEqual(AnytimeFrames.parseCt5BindState(withSum([0x11, 0x55, 0x00, 0, 0, 0, 0, 0, 0x05, 0, 0, 0, 0x22]))?.unbindReason, -1)
        XCTAssertEqual(AnytimeFrames.parseCt5BindState(withSum([0x11, 0x55, 0x00, 0, 0, 0, 0, 0, 0x01, 0, 0, 0, 0x00]))?.unbindReason, -1)
        XCTAssertNil(AnytimeFrames.parseCt5BindState(bytes("11550100")))
        var badSum = bytes("1155010000000000000000000067")
        badSum[13] = 0
        XCTAssertNil(AnytimeFrames.parseCt5BindState(badSum))
    }

    func testResetResponseMatchesKotlin() {
        XCTAssertEqual(AnytimeFrames.parseResetResponse(bytes("110001"))?.isBound, true)
        XCTAssertEqual(AnytimeFrames.parseResetResponse(bytes("110000"))?.isBound, false)
        XCTAssertNil(AnytimeFrames.parseResetResponse(bytes("1100")))
        XCTAssertNil(AnytimeFrames.parseResetResponse(bytes("120001")))
    }

    // MARK: raw current records (CT2.5, CT3, CT4)

    func testPlainRawRecords() {
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("07 0A 00 04 27 0D 4A 4A 0A")).map(describeRaw), ["id10/ib4390/iw13740/t34100/0A0004270D4A4A0A"])
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("08 0A 00 04 27 0D 4A 4A 0A 0B 00 04 28 0D 4B 4A 14")).map(describeRaw), ["id10/ib4390/iw13740/t34100/0A0004270D4A4A0A", "id11/ib4400/iw13750/t34200/0B0004280D4B4A14"])
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("07 0A 00")).count, 0)
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("09 0A 00 04 27 0D 4A 4A 0A")).count, 0)
    }

    func testWideRawRecords() {
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("07 93 00 01 B7 05 5E 49 0A 04 1B 27"), wideRecords: true).map(describeRaw), ["id147/ib4390/iw13740/t33100/930001B7055E490A041B"])
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("07 93 00 01 B7 05 5E 49 0A 04 1B 07 94 00 01 C2 05 64 49 19 04 1C 07 95 00 01 C8 05 6A 49 1E 04 1D"), wideRecords: true).map(describeRaw), ["id147/ib4390/iw13740/t33100/930001B7055E490A041B", "id148/ib4500/iw13800/t33250/940001C205644919041C", "id149/ib4560/iw13860/t33300/950001C8056A491E041D"])
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("07 93 00 01 B7 05 5E 49 0A 04 1B 27 07 94 00 FF FF FF FF FF FF FF FF 28"), wideRecords: true).map(describeRaw), ["id147/ib4390/iw13740/t33100/930001B7055E490A041B"])
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("07 93 00 01 B7 05 5E 7D 0A 04 1B 27"), wideRecords: true).count, 0)
        XCTAssertEqual(AnytimeFrames.parseRawRecords(bytes("07 93 00 01 B7 05 5E 49 0A 04 1B 27 22 94 00 01 C2 05 64 49 19 04 1B 28"), wideRecords: true).count, 1)
    }

    func testWideRawSeriesRecords() {
        let two = bytes("22930001B7055E490A01C205644919B1")
        XCTAssertEqual(AnytimeFrames.parseWideRawSeriesRecords(two).map(describeRaw), ["id147/ib4390/iw13740/t33100/930001B7055E490A", "id148/ib4500/iw13800/t33250/940001C205644919"])
        // The request frame of the same batch: id 147, 15 records.
        XCTAssertEqual(hx(AnytimeFrames.Builders.pullGlucoseSeriesSummed(147, count: 15)), "2293000FC4")

        var legacy = two
        legacy[0] = 0x0D
        legacy[legacy.count - 1] = AnytimeFrames.sum(legacy, from: 0, to: legacy.count - 2)
        XCTAssertEqual(AnytimeFrames.parseWideRawSeriesRecords(legacy).count, 2)

        let empty = bytes("229300B5")
        XCTAssertEqual(AnytimeFrames.parseWideRawSeriesRecords(empty).count, 0)

        var badSum = two
        badSum[badSum.count - 1] = badSum[badSum.count - 1] &+ 1
        XCTAssertEqual(AnytimeFrames.parseWideRawSeriesRecords(badSum).count, 0)

        let filler = withSum([0x22, 0x93, 0x00, 0x01, 0xB7, 0x05, 0x5E, 0x49, 0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0xC2, 0x05, 0x64, 0x49, 0x19])
        XCTAssertEqual(AnytimeFrames.parseWideRawSeriesRecords(filler).count, 1)

        let wrong = withSum([0x23, 0x93, 0x00, 0x01, 0xB7, 0x05, 0x5E, 0x49, 0x0A])
        XCTAssertEqual(AnytimeFrames.parseWideRawSeriesRecords(wrong).count, 0)
        XCTAssertEqual(AnytimeFrames.parseWideRawSeriesRecords(bytes("2293")).count, 0)
    }

    // MARK: computed record, check, version

    func testComputedRecord() {
        let record = bytes("0C3412050904270D4A490A0546050500030000")
        XCTAssertEqual(AnytimeFrames.parseComputedRecord(record).map(describeComputed), "id4660/hypo5/hyper9/ib4390/iw13740/t33100/mmol5700/ref5500/err0/trend3/warn0/hastrue/mgdl103/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")
        var noGlucose = record
        noGlucose[11] = 0
        noGlucose[12] = 0
        XCTAssertEqual(AnytimeFrames.parseComputedRecord(noGlucose).map(describeComputed), "id4660/hypo5/hyper9/ib4390/iw13740/t33100/mmol0/ref5500/err0/trend3/warn0/hasfalse/mgdl0/be-2147483648/we-2147483648/re-2147483648/ce-2147483648/bat-2147483648")
        XCTAssertNil(AnytimeFrames.parseComputedRecord(Array(record.prefix(18))))
        var wrong = record
        wrong[0] = 0x0D
        XCTAssertNil(AnytimeFrames.parseComputedRecord(wrong))
    }

    func testCheckResponses() {
        func describe(_ s: AnytimeCheckStatus) -> String {
            return "age\(s.sensorAgeReadings)/iw\(f(s.workingElectrodeCurrentNa))/v\(f(s.batteryVolts))/healthy\(s.isHealthy)/fail\(kotlinFailure(s.failure))"
        }
        let first = bytes("05 12 05 64 00 01 C0 48 62 04 1B 06 D1 06 D2 05 18 00 00 D6")
        XCTAssertEqual(describe(AnytimeFrames.parseCheckResponse(first, lowBatteryThresholdVolts: AnytimeConstants.batteryLowVoltsCT3A)), "age1380/iw13800/v4270/healthytrue/failnull")
        XCTAssertEqual(describe(AnytimeFrames.parseCheckResponse(first, lowBatteryThresholdVolts: AnytimeConstants.batteryLowVoltsCT3)), "age1380/iw13800/v4270/healthytrue/failnull")
        XCTAssertEqual(describe(AnytimeFrames.parseCheckResponse(first, lowBatteryThresholdVolts: AnytimeConstants.batteryLowVoltsCT4)), "age1380/iw13800/v4270/healthytrue/failnull")

        let second = bytes("05 12 02 78 00 01 42 49 0B 03 62 06 D1 06 D1 05 18 00 00 58")
        XCTAssertEqual(describe(AnytimeFrames.parseCheckResponse(second, lowBatteryThresholdVolts: AnytimeConstants.batteryLowVoltsCT3)), "age632/iw66730/v3980/healthytrue/failLOW_BATTERY")
        XCTAssertEqual(describe(AnytimeFrames.parseCheckResponse(second, lowBatteryThresholdVolts: AnytimeConstants.batteryLowVoltsCT4)), "age632/iw66730/v3980/healthytrue/failnull")

        let short = AnytimeFrames.parseCheckResponse(bytes("0512"), lowBatteryThresholdVolts: 3)
        XCTAssertEqual("healthy\(short.isHealthy)/fail\(kotlinFailure(short.failure))", "healthyfalse/failMALFORMED")
        let wrong = AnytimeFrames.parseCheckResponse(bytes("06 12 02 78 00 01 42 49 0B 03 62 06"), lowBatteryThresholdVolts: 3)
        XCTAssertEqual("healthy\(wrong.isHealthy)/fail\(kotlinFailure(wrong.failure))", "healthyfalse/failMALFORMED")
        let none = AnytimeFrames.parseCheckResponse(bytes("05 12 00 01 00 01 00 00 00 04 1B 06"), lowBatteryThresholdVolts: 3)
        XCTAssertEqual("iw\(f(none.workingElectrodeCurrentNa))/v\(f(none.batteryVolts))", "iw0/v4270")
        let bigEndian = AnytimeFrames.parseCheckResponse(bytes("05 12 05 64 00 01 00 00 00 04 1B 06"), lowBatteryThresholdVolts: 3)
        XCTAssertEqual("iw\(f(bigEndian.workingElectrodeCurrentNa))", "iw13800")
    }

    func testFormalVersionAndBatteryPercent() {
        XCTAssertEqual(AnytimeFrames.parseFormalVersion(bytes("20 56 31 33 30 32 00")), "V1302")
        XCTAssertEqual(AnytimeFrames.parseFormalVersion(bytes("20 56 31 2E 34 20 21")), "V1.4")
        XCTAssertEqual(AnytimeFrames.parseFormalVersion(bytes("20 00 56")), "V")
        XCTAssertEqual(AnytimeFrames.parseFormalVersion(bytes("21 56 31")), "")
        XCTAssertEqual(AnytimeFrames.parseFormalVersion(bytes("20")), "")

        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 3.98, lowThresholdVolts: 2.97), 82, "bat.3980.2970")
        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 4.27, lowThresholdVolts: 3.9), 100, "bat.4270.3900")
        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 4.2, lowThresholdVolts: 4.05), 100, "bat.4200.4050")
        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 4.0, lowThresholdVolts: 4.05), 0, "bat.4000.4050")
        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 3.5, lowThresholdVolts: 2.97), 43, "bat.3500.2970")
        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 0.0, lowThresholdVolts: 2.97), -1, "bat.0.2970")
        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 4.3, lowThresholdVolts: 4.2), -1, "bat.4300.4200")
        XCTAssertEqual(AnytimeFrames.batteryPercent(volts: 5.0, lowThresholdVolts: 2.97), 100, "bat.5000.2970")
    }

    // MARK: CT2 frames (captures of SN08402458, 2026-09-07)

    func testCt2GlucoseFrames() {
        func describe(_ frame: AnytimeCt2GlucoseFrame?) -> String? {
            guard let frame = frame else { return nil }
            let battery = frame.batteryPercent.map(String.init) ?? "null"
            return "\(describeRaw(frame.record))/hist\(frame.isHistorical)/bat\(battery)/end\(frame.isEndOfHistory)"
        }
        XCTAssertEqual(describe(AnytimeFrames.parseCt2GlucoseRecord(bytes("4400001a0907143b008400151d64d7"))), "id0/ib2100/iw13200/t29000/4400001A0907143B008400151D64D7/histfalse/bat100/endfalse", "push")
        XCTAssertEqual(describe(AnytimeFrames.parseCt2GlucoseRecord(bytes("47000e1a0907152a008100169efff2"))), "id14/ib2200/iw12900/t30500/47000E1A0907152A008100169EFFF2/histtrue/batnull/endfalse", "pull")
        XCTAssertEqual(describe(AnytimeFrames.parseCt2GlucoseRecord(bytes("4400001a0907143b008400151d64d8"))), nil, "badSum")
        XCTAssertEqual(describe(AnytimeFrames.parseCt2GlucoseRecord(bytes("4400001a0907143b008400151d64"))), nil, "short")
        XCTAssertEqual(describe(AnytimeFrames.parseCt2GlucoseRecord(bytes("4400001a0907143b008400151d64d700"))), nil, "long")
        XCTAssertEqual(describe(AnytimeFrames.parseCt2GlucoseRecord(bytes("47ffff1a0907143b008400151d64d8"))), "id65535/ib2100/iw13200/t29000/47FFFF1A0907143B008400151D64D8/histtrue/batnull/endtrue", "sentinel")
        XCTAssertEqual(describe(AnytimeFrames.parseCt2GlucoseRecord(bytes("44ffff1a0907143b008400151d64d5"))), "id65535/ib2100/iw13200/t29000/44FFFF1A0907143B008400151D64D5/histfalse/bat100/endfalse", "pushMax")
        var wrongOpcode = bytes("4400001a0907143b008400151d64d7")
        wrongOpcode[0] = 0x45
        wrongOpcode[wrongOpcode.count - 1] = AnytimeFrames.sum(wrongOpcode, from: 0, to: wrongOpcode.count - 2)
        XCTAssertNil(AnytimeFrames.parseCt2GlucoseRecord(wrongOpcode))
    }

    func testCt2CheckResponse() {
        func describe(_ r: AnytimeCt2CheckResult?) -> String? {
            guard let r = r else { return nil }
            return "iw\(f(r.iwNa))/ib\(f(r.ibNa))/t\(f(r.temperatureC))/p\(r.powerByte)/pass\(r.passed)"
        }
        XCTAssertEqual(describe(AnytimeFrames.parseCt2CheckResponse(bytes("43008200171c645c"))), "iw13000/ib2300/t28000/p100/passtrue")
        var low = bytes("43008200171c645c")
        low[6] = 0x10
        low[low.count - 1] = AnytimeFrames.sum(low, from: 0, to: low.count - 2)
        XCTAssertEqual(AnytimeFrames.parseCt2CheckResponse(low).map { "pass\($0.passed)/p\($0.powerByte)" }, "passfalse/p16")
        var hot = bytes("43008200179c645c")
        hot[5] = 0xB2
        hot[hot.count - 1] = AnytimeFrames.sum(hot, from: 0, to: hot.count - 2)
        XCTAssertEqual(AnytimeFrames.parseCt2CheckResponse(hot).map { "t\(f($0.temperatureC))/pass\($0.passed)" }, "t50500/passfalse")
        XCTAssertNil(AnytimeFrames.parseCt2CheckResponse(bytes("43008200171c645d")))
        XCTAssertNil(AnytimeFrames.parseCt2CheckResponse(bytes("43008200171c64")))
    }

    func testCt2TemperatureByte() {
        XCTAssertEqual(f(AnytimeFrames.decodeCt2Temperature(0x9C)), "28500")
        XCTAssertEqual(f(AnytimeFrames.decodeCt2Temperature(0x1C)), "28000")
        XCTAssertEqual(f(AnytimeFrames.decodeCt2Temperature(0x80)), "500")
        XCTAssertEqual(f(AnytimeFrames.decodeCt2Temperature(0xFF)), "127500")
    }

    // MARK: sensor codes (QR)

    func testSensorCodesMatchTheKotlinParser() {
        XCTAssertEqual(describeQr(AnytimeQr.parse("0116975124206236112602191728021910CQ6212")), "UDI|k300|r50000|life16|m2|y2026|el|elt|enz|mem|mktCQ6212|ser16975124206236|sn206236|unit0|vf0|cnt0|facfalse|trkrfalse", "udi")
        XCTAssertEqual(describeQr(AnytimeQr.parse("(01)16975124206236(11)260219(17)280219(10)CQ6212")), "UDI|k300|r50000|life16|m2|y2026|el|elt|enz|mem|mktCQ6212|ser16975124206236|sn206236|unit0|vf0|cnt0|facfalse|trkrfalse", "udiParen")
        XCTAssertEqual(describeQr(AnytimeQr.parse("0116975124206236112613191728021910CQ6212")), "null", "udiBadDate")
        XCTAssertEqual(describeQr(AnytimeQr.parse("0116975124206236112602321728021910CQ6212")), "null", "udiBadDay")
        XCTAssertEqual(describeQr(AnytimeQr.parse("0116975124206236112602191728021910")), "null", "udiNoLot")
        XCTAssertEqual(describeQr(AnytimeQr.parse("AB34567")), "MANUAL|k3450|r6000|life16|m0|y0|el|elt|enz|mem|mkt|ser|snAB|unit0|vf1|cnt0|factrue|trkrtrue", "manual")
        XCTAssertEqual(describeQr(AnytimeQr.parse("a61061B")), "MANUAL|k1060|r1000|life16|m0|y0|el|elt|enz|mem|mkt|ser|snA6|unit0|vf1|cnt0|factrue|trkrtrue", "manualLower")
        XCTAssertEqual(describeQr(AnytimeQr.parse("111061B")), "MANUAL|k1060|r1000|life16|m0|y0|el|elt|enz|mem|mkt|ser|sn11|unit0|vf0|cnt0|factrue|trkrtrue", "manualDigit")
        XCTAssertEqual(describeQr(AnytimeQr.parse("AB00567")), "MANUAL|k50|r6000|life16|m0|y0|el|elt|enz|mem|mkt|ser|snAB|unit0|vf1|cnt0|factrue|trkrtrue", "manualZeroK")
        XCTAssertEqual(describeQr(AnytimeQr.parse("a645210531368109100A4")), "C|k1090|r1000|life16|m21|y2016|el4|elt21|enz109|mem10|mkt0A4|ser531368|snA6|unit0|vf1|cnt5|factrue|trkrtrue", "trailing")
        XCTAssertEqual(describeQr(AnytimeQr.parse("0056131041576115100F1")), "C|k1150|r1000|life16|m13|y2010|el5|elt13|enz115|mem10|mkt0F1|ser041576|sn00|unit0|vf0|cnt6|factrue|trkrtrue", "ssn00")
        XCTAssertEqual(describeQr(AnytimeQr.parse("0056001041576115100F1")), "null", "ssn00BadMonth")
        XCTAssertEqual(describeQr(AnytimeQr.parse("2142121234561234561AB")), "B|k1230|r45600|life16|m12|y2011|el4|elt12|enz123|mem456|mkt1AB|ser123456|sn21|unit2|vf0|cnt2|factrue|trkrtrue", "formatB21")
        XCTAssertEqual(describeQr(AnytimeQr.parse("Q1B2031234561234567ZZ")), "D|k1230|r45600|life16|m3|y2011|elB|elt03|enz123|mem456|mkt7ZZ|ser123456|snQ1|unit0|vf1|cnt2|factrue|trkrtrue", "formatD")
        XCTAssertEqual(describeQr(AnytimeQr.parse("B30712304500012" + "44A")), "A|k1230|r4500|life16|m7|y2013|elB|elt07|enz123|mem44A|mkt44A|ser00012|snB3|unit0|vf1|cnt0|factrue|trkrtrue", "formatA")
        XCTAssertEqual(describeQr(AnytimeQr.parse("B3A1" + "123045" + "00012" + "55B")), "A|k1230|r4500|life15|m10|y2013|elB|eltA1|enz123|mem55B|mkt55B|ser00012|snB3|unit0|vf1|cnt0|factrue|trkrtrue", "formatAmonthLetter")
        XCTAssertEqual(describeQr(AnytimeQr.parse("B30712304500012" + "33C")), "A|k1230|r4500|life14|m7|y2013|elB|elt07|enz123|mem33C|mkt33C|ser00012|snB3|unit0|vf1|cnt0|factrue|trkrtrue", "formatA33")
        XCTAssertEqual(describeQr(AnytimeQr.parse("A1B20712304500012" + "G" + "44A")), "C|k1230|r4500|life16|m7|y2011|elB|elt07|enz2|mem07|mkt44A|ser00012G|snA1|unit0|vf1|cnt2|factrue|trkrtrue", "formatC")
        XCTAssertEqual(describeQr(AnytimeQr.parse("A5B1122334455135200A4")), "C|k1350|r2000|life16|m12|y2015|elB|elt12|enz135|mem20|mkt0A4|ser334455|snA5|unit0|vf1|cnt1|factrue|trkrtrue", "formatCtrailingKr")
        XCTAssertEqual(describeQr(AnytimeQr.parse("")), "null", "empty")
        XCTAssertEqual(describeQr(AnytimeQr.parse(nil)), "null", "null")
        XCTAssertEqual(describeQr(AnytimeQr.parse("hello world")), "null", "garbage")
        XCTAssertEqual(describeQr(AnytimeQr.parse("  ab34567  ")), "MANUAL|k3450|r6000|life16|m0|y0|el|elt|enz|mem|mkt|ser|snAB|unit0|vf1|cnt0|factrue|trkrtrue", "spaces")
        XCTAssertEqual(describeQr(AnytimeQr.parse("01169751242062361126021917280219" + "10cq6212")), "UDI|k300|r50000|life16|m2|y2026|el|elt|enz|mem|mktCQ6212|ser16975124206236|sn206236|unit0|vf0|cnt0|facfalse|trkrfalse", "lowerUdi")
    }

    func testVoltageFlagFromTheFirstCharacter() {
        XCTAssertEqual(AnytimeQr.inferVoltageFlag("1AB"), 0)
        XCTAssertEqual(AnytimeQr.inferVoltageFlag("AB1"), 1)
        XCTAssertEqual(AnytimeQr.inferVoltageFlag(""), 0)
        XCTAssertEqual(AnytimeQr.inferVoltageFlag(nil), 0)
        XCTAssertEqual(AnytimeQr.inferVoltageFlag(" 5A"), 0)
    }

    func testCt5SetupCalibrationNeverSendsALabelPlaceholder() {
        let none = AnytimeQr.ct5SetupCalibration(stored: nil, voltageFlag: 0)
        XCTAssertEqual("\(none.format.rawValue)|k\(f(none.k))|r\(f(none.r))|life\(none.lifeTime)|vf\(none.voltageFlag)|fac\(none.isFactoryCalibration)|trkr\(none.hasTransmitterKr)", "DEFAULT|k1100|r1000|life16|vf0|facfalse|trkrtrue")
        let one = AnytimeQr.ct5Default(voltageFlag: 1)
        XCTAssertEqual("\(one.format.rawValue)|vf\(one.voltageFlag)", "DEFAULT|vf1")
        let udi = AnytimeQr.parse("0116975124206236112602191728021910CQ6212")!
        XCTAssertEqual(AnytimeQr.ct5SetupCalibration(stored: udi, voltageFlag: 0).format.rawValue, "DEFAULT")
        let scanned = AnytimeQr.parse("a645210531368109100A4")!
        XCTAssertEqual(AnytimeQr.ct5SetupCalibration(stored: scanned, voltageFlag: 1), scanned)
        XCTAssertEqual(AnytimeQr.ct5SetupCalibration(stored: scanned, voltageFlag: 1).format.rawValue, "C")
    }

    // MARK: families and profiles

    func testFamilyTableMatchesTheKotlinTableEntryForEntry() {
        XCTAssertEqual(AnytimeFamilies.table.count, 45)
        let expected = [
            "SN04|CT2|8|6740|14",
            "SN06|CT2|6|3420|7",
            "SN08|CT2|1|6720|14",
            "SN12|CT2|1|4800|10",
            "SN18|CT2|7|3380|7",
            "SN20|CT2|7|6740|14",
            "SN22|CT2|1|4800|10",
            "SN48|CT2|7|6740|14",
            "SN50|CT2|7|6740|14",
            "SN52|CT2|7|6740|14",
            "SN30|CT2_5|7|6740|14",
            "SN32|CT2_5|7|3380|7",
            "SN36|CT2_5|7|6740|14",
            "SN38|CT2_5|7|6740|14",
            "SN40|CT2_5|7|6740|14",
            "SN16|CT3|3|6740|14",
            "SN26|CT3_YUWELL|3|6740|14",
            "SN28|CT3_YUWELL|3|3380|7",
            "SN42|CT3_YUWELL|3|6740|14",
            "SN46|CT3_YUWELL|3|6740|14",
            "SN56|CT3_PLUS|3|6740|14",
            "SN58|CT3_PLUS|3|3380|7",
            "SN60|CT3_PLUS|3|6740|14",
            "SN62|CT3_PLUS|3|6740|14",
            "SN66|CT3_PLUS|3|6740|14",
            "SN68|CT3_PLUS|3|6740|14",
            "SN70|CT3_PLUS|12|6740|14",
            "SN17|CT3_ULTRASONIC|9|6740|14",
            "SN27|CT3_ULTRASONIC|12|6740|14",
            "SN29|CT3_ULTRASONIC|12|3380|7",
            "SN43|CT3_ULTRASONIC|9|6740|14",
            "SN47|CT3_ULTRASONIC|9|6740|14",
            "SN91|CT3_ULTRASONIC|10|6740|14",
            "SN96|CT3_ULTRASONIC|12|6740|14",
            "SN98|CT3_ULTRASONIC|12|6740|14",
            "SN72|CT4|10|7220|15",
            "SN76|CT4|10|7220|15",
            "SN78|CT4|10|7220|15",
            "SN80|CT4|10|7220|15",
            "SN82|CT4|10|3860|8",
            "SN86|CT4|10|3860|8",
            "SN87|CT4|10|7220|15",
            "SN88|CT4|10|7220|15",
            "SN90|CT4|10|4820|10",
            "Anytime|CT5|11|7695|16"
        ]
        let actual = AnytimeFamilies.table.map { "\($0.prefix)|\(kotlinFamily($0.family))|\($0.algorithm)|\($0.endNumber)|\($0.ratedLifetimeDays)" }
        XCTAssertEqual(actual, expected)
    }


    func testProfilesMatchTheKotlinResolver() {
        func describe(_ name: String) -> String {
            let e = AnytimeFamilies.resolve(name)
            let pr = AnytimeProfileResolver.resolve(name)
            return "\(kotlinFamily(e.family))|\(e.prefix)|\(kotlinFamily(pr.family))|int\(pr.readingIntervalMinutes)|wu\(pr.warmupMinutes)|life\(pr.ratedLifetimeDays)"
                + "|algo\(pr.algorithmId)|end\(pr.endNumber)|low\(f(pr.lowBatteryVolts))|wuRec\(pr.warmupRecords)|lifeMs\(pr.ratedLifetimeMs)|wuMs\(pr.warmupMs)"
                + "|legacy\(e.family.needsLegacyUuids)|name\(e.family.displayName)|selftest\(AnytimeFamilies.supportsSelfTest(e.family))|isAny\(AnytimeFamilies.isAnytimeDevice(name))"
        }
        XCTAssertEqual(describe("SN08402458"), "CT2|SN08|CT2|int3|wu60|life14|algo1|end6720|low4050|wuRec20|lifeMs1209600000|wuMs3600000|legacytrue|nameCT2|selftesttrue|isAnytrue", "SN08402458")
        XCTAssertEqual(describe("SN06-test"), "CT2|SN06|CT2|int3|wu180|life7|algo6|end3420|low4050|wuRec60|lifeMs604800000|wuMs10800000|legacytrue|nameCT2|selftesttrue|isAnytrue", "SN06-test")
        XCTAssertEqual(describe("SN12-test"), "CT2|SN12|CT2|int3|wu180|life10|algo1|end4800|low4050|wuRec60|lifeMs864000000|wuMs10800000|legacytrue|nameCT2|selftesttrue|isAnytrue", "SN12-test")
        XCTAssertEqual(describe("SN04"), "CT2|SN04|CT2|int3|wu60|life14|algo8|end6740|low4050|wuRec20|lifeMs1209600000|wuMs3600000|legacytrue|nameCT2|selftesttrue|isAnytrue", "SN04")
        XCTAssertEqual(describe("SN52x"), "CT2|SN52|CT2|int3|wu60|life14|algo7|end6740|low4050|wuRec20|lifeMs1209600000|wuMs3600000|legacytrue|nameCT2|selftesttrue|isAnytrue", "SN52x")
        XCTAssertEqual(describe("SN16-test"), "CT3|SN16|CT3|int3|wu60|life14|algo3|end6740|low4050|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT3|selftestfalse|isAnytrue", "SN16-test")
        XCTAssertEqual(describe("SN16"), "CT3|SN16|CT3|int3|wu60|life14|algo3|end6740|low4050|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT3|selftestfalse|isAnytrue", "SN16")
        XCTAssertEqual(describe("SN26-test"), "CT3_YUWELL|SN26|CT3_YUWELL|int3|wu60|life14|algo3|end6740|low3900|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT3-Yuwell|selftestfalse|isAnytrue", "SN26-test")
        XCTAssertEqual(describe("SN28-test"), "CT3_YUWELL|SN28|CT3_YUWELL|int3|wu60|life7|algo3|end3380|low3900|wuRec20|lifeMs604800000|wuMs3600000|legacyfalse|nameCT3-Yuwell|selftestfalse|isAnytrue", "SN28-test")
        XCTAssertEqual(describe("SN30-a"), "CT2_5|SN30|CT2_5|int3|wu60|life14|algo7|end6740|low2970|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT2.5|selftestfalse|isAnytrue", "SN30-a")
        XCTAssertEqual(describe("SN40-a"), "CT2_5|SN40|CT2_5|int3|wu60|life14|algo7|end6740|low2970|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT2.5|selftestfalse|isAnytrue", "SN40-a")
        XCTAssertEqual(describe("SN72-test"), "CT4|SN72|CT4|int3|wu60|life15|algo10|end7220|low2970|wuRec20|lifeMs1296000000|wuMs3600000|legacyfalse|nameCT4|selftestfalse|isAnytrue", "SN72-test")
        XCTAssertEqual(describe("SN90-a"), "CT4|SN90|CT4|int3|wu60|life10|algo10|end4820|low2970|wuRec20|lifeMs864000000|wuMs3600000|legacyfalse|nameCT4|selftestfalse|isAnytrue", "SN90-a")
        XCTAssertEqual(describe("SN9150002398"), "CT3_ULTRASONIC|SN91|CT3_ULTRASONIC|int3|wu60|life14|algo10|end6740|low3900|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT3-Ultrasonic|selftestfalse|isAnytrue", "SN9150002398")
        XCTAssertEqual(describe("SN91"), "CT3_ULTRASONIC|SN91|CT3_ULTRASONIC|int3|wu60|life14|algo10|end6740|low3900|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT3-Ultrasonic|selftestfalse|isAnytrue", "SN91")
        XCTAssertEqual(describe("Anytime"), "CT5|Anytime|CT5|int3|wu40|life16|algo11|end7695|low4050|wuRec13|lifeMs1382400000|wuMs2400000|legacyfalse|nameCT5|selftestfalse|isAnytrue", "Anytime")
        XCTAssertEqual(describe("Anytime  4pro"), "CT5|Anytime|CT5|int3|wu40|life16|algo11|end7695|low4050|wuRec13|lifeMs1382400000|wuMs2400000|legacyfalse|nameCT5|selftestfalse|isAnytrue", "Anytime  4pro")
        XCTAssertEqual(describe("anytime5252037585"), "CT5|Anytime|CT5|int3|wu40|life16|algo11|end7695|low4050|wuRec13|lifeMs1382400000|wuMs2400000|legacyfalse|nameCT5|selftestfalse|isAnytrue", "anytime5252037585")
        XCTAssertEqual(describe("Anytime5252037585"), "CT5|Anytime|CT5|int3|wu40|life16|algo11|end7695|low4050|wuRec13|lifeMs1382400000|wuMs2400000|legacyfalse|nameCT5|selftestfalse|isAnytrue", "Anytime5252037585")
        XCTAssertEqual(describe("foo"), "UNKNOWN|UNKNOWN|UNKNOWN|int3|wu60|life16|algo3|end6740|low4050|wuRec20|lifeMs1382400000|wuMs3600000|legacyfalse|nameUnknown|selftestfalse|isAnyfalse", "foo")
        XCTAssertEqual(describe("SN1"), "UNKNOWN|UNKNOWN|UNKNOWN|int3|wu60|life16|algo3|end6740|low4050|wuRec20|lifeMs1382400000|wuMs3600000|legacyfalse|nameUnknown|selftestfalse|isAnyfalse", "SN1")
        XCTAssertEqual(describe(""), "UNKNOWN|UNKNOWN|UNKNOWN|int3|wu60|life16|algo3|end6740|low4050|wuRec20|lifeMs1382400000|wuMs3600000|legacyfalse|nameUnknown|selftestfalse|isAnyfalse", "")
        XCTAssertEqual(describe("  "), "UNKNOWN|UNKNOWN|UNKNOWN|int3|wu60|life16|algo3|end6740|low4050|wuRec20|lifeMs1382400000|wuMs3600000|legacyfalse|nameUnknown|selftestfalse|isAnyfalse", "  ")
        XCTAssertEqual(describe("SN99999"), "UNKNOWN|UNKNOWN|UNKNOWN|int3|wu60|life16|algo3|end6740|low4050|wuRec20|lifeMs1382400000|wuMs3600000|legacyfalse|nameUnknown|selftestfalse|isAnyfalse", "SN99999")
        XCTAssertEqual(describe("sn26-lower"), "CT3_YUWELL|SN26|CT3_YUWELL|int3|wu60|life14|algo3|end6740|low3900|wuRec20|lifeMs1209600000|wuMs3600000|legacyfalse|nameCT3-Yuwell|selftestfalse|isAnytrue", "sn26-lower")
        let unknown = AnytimeProfileResolver.resolve(nil)
        XCTAssertEqual("\(kotlinFamily(unknown.family))|int\(unknown.readingIntervalMinutes)|wu\(unknown.warmupMinutes)|life\(unknown.ratedLifetimeDays)|algo\(unknown.algorithmId)|end\(unknown.endNumber)|low\(f(unknown.lowBatteryVolts))", "UNKNOWN|int3|wu60|life16|algo3|end6740|low4050")
    }

    func testSn91IsItsOwnFamilyNotTheCt5Fallback() {
        XCTAssertEqual(AnytimeProfileResolver.resolve("SN9150002398").family, .ct3Ultrasonic)
        XCTAssertEqual(AnytimeFamilies.resolve("Anytime  4pro").family, .ct5)
        XCTAssertEqual(AnytimeFamilies.resolve("SN08402458").family, .ct2)
    }

    func testGattLayoutFollowsTheFamily() {
        XCTAssertTrue(AnytimeFamily.ct2.needsLegacyUuids)
        for family in AnytimeFamily.allCases where family != .ct2 {
            XCTAssertFalse(family.needsLegacyUuids, family.displayName)
        }
        XCTAssertEqual(AnytimeGATT.legacyService.uuidString, "FFF0")
        XCTAssertEqual(AnytimeGATT.primaryService.uuidString.uppercased(), "00001000-1212-EFDE-1523-785FEABCD123")
        XCTAssertEqual(AnytimeGATT.primaryNotify.uuidString.uppercased(), "00001001-1212-EFDE-1523-785FEABCD123")
        XCTAssertEqual(AnytimeGATT.primaryWrite.uuidString.uppercased(), "00001002-1212-EFDE-1523-785FEABCD123")
        XCTAssertEqual(AnytimeGATT.legacyNotify.uuidString, "FFF2")
        XCTAssertEqual(AnytimeGATT.legacyWrite.uuidString, "FFF1")
    }

    func testHandshakeNameKeepsASpecificSerialOverTheSharedBrand() {
        let sn91 = "SN9150002398"
        let sensorId = "D4FE28EB506B"
        for cached in ["Anytime", "Anytime  4pro", AnytimeConstants.defaultDisplayName] {
            XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: cached, connectedName: sn91, activeName: "CGM Sensor", serial: sensorId), "SN9150002398")
        }
        XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: "Anytime", connectedName: nil, activeName: sn91, serial: sensorId), "SN9150002398")
        XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: "Anytime", connectedName: "Anytime  4pro", activeName: nil, serial: sn91), "SN9150002398")
        XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: "", connectedName: "Anytime", activeName: nil, serial: sensorId), "Anytime")
        XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: "Anytime", connectedName: "  " + sn91 + "  ", activeName: nil, serial: sensorId), "SN9150002398")
        XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: "unknown", connectedName: " CGM Sensor ", activeName: nil, serial: sensorId), "CGM Sensor")
        XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: nil, connectedName: " ", activeName: nil, serial: nil), "")
        XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: "SN08402458", connectedName: nil, activeName: "CGM Sensor", serial: sensorId), "SN08402458")
    }

    func testEverySpecificPrefixBeatsTheBrand() {
        for entry in AnytimeFamilies.table where entry.family != .ct5 {
            let name = entry.prefix + "-test"
            XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: name, connectedName: "Anytime", activeName: nil, serial: "D4FE28EB506B"), name)
            XCTAssertEqual(AnytimeFamilies.resolveHandshakeName(cachedName: "Anytime", connectedName: name, activeName: nil, serial: "D4FE28EB506B"), name)
        }
    }

    // MARK: sensor identity

    func testSensorIdHelpersMatchTheKotlinOnes() {
        func describe(_ s: String?) -> String {
            return "canon=\(AnytimeFamilies.canonicalSensorId(s))|mac=\(AnytimeFamilies.macAddress(fromSensorId: s) ?? "null")"
                + "|persisted=\(AnytimeFamilies.isLikelyPersistedSensorName(s))|prov=\(AnytimeFamilies.isProvisionalSensorId(s))"
        }
        XCTAssertEqual(describe("F0:FD:45:09:C7:C2"), "canon=F0FD4509C7C2|mac=F0:FD:45:09:C7:C2|persisted=true|prov=false", "F0:FD:45:09:C7:C2")
        XCTAssertEqual(describe("f0fd4509c7c2"), "canon=F0FD4509C7C2|mac=F0:FD:45:09:C7:C2|persisted=true|prov=false", "f0fd4509c7c2")
        XCTAssertEqual(describe("F0FD4509C7C2"), "canon=F0FD4509C7C2|mac=F0:FD:45:09:C7:C2|persisted=true|prov=false", "F0FD4509C7C2")
        XCTAssertEqual(describe("509C7C2"), "canon=509C7C2|mac=null|persisted=false|prov=false", "509C7C2")
        XCTAssertEqual(describe("SN08402458"), "canon=SN08402458|mac=null|persisted=false|prov=false", "SN08402458")
        XCTAssertEqual(describe("ANY-SN08402458"), "canon=ANY-SN08402458|mac=null|persisted=true|prov=true", "ANY-SN08402458")
        XCTAssertEqual(describe(""), "canon=|mac=null|persisted=false|prov=false", "")
        XCTAssertEqual(describe("  "), "canon=|mac=null|persisted=false|prov=false", "  ")
        XCTAssertEqual(describe("0123456789ABCDEF"), "canon=0123456789ABCDEF|mac=null|persisted=true|prov=false", "0123456789ABCDEF")
        XCTAssertEqual(describe("0123456789abcdef0"), "canon=0123456789abcdef0|mac=null|persisted=false|prov=false", "0123456789abcdef0")
        XCTAssertEqual(describe("D4FE28EB506B"), "canon=D4FE28EB506B|mac=D4:FE:28:EB:50:6B|persisted=true|prov=false", "D4FE28EB506B")
        let none = "canon=\(AnytimeFamilies.canonicalSensorId(nil))|mac=\(AnytimeFamilies.macAddress(fromSensorId: nil) ?? "null")|persisted=\(AnytimeFamilies.isLikelyPersistedSensorName(nil))"
        XCTAssertEqual(none, "canon=|mac=null|persisted=false")
    }

    func testNativeAliasMatching() {
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("F0FD4509C7C2", "509C7C2"), true, "F0FD4509C7C2/509C7C2")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("509C7C2", "F0:FD:45:09:C7:C2"), true, "509C7C2/F0:FD:45:09:C7:C2")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("F0FD4509C7C2", "09C7C2"), false, "F0FD4509C7C2/09C7C2")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("F0FD4509C7C2", "09C7D0"), false, "F0FD4509C7C2/09C7D0")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("F0FD4509C7C2", "F0FD4509C7C2"), true, "F0FD4509C7C2/F0FD4509C7C2")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("", "509C7C2"), false, "/509C7C2")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("SN08402458", "SN08402458"), true, "SN08402458/SN08402458")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("SN0840", "SN08402458"), false, "SN0840/SN08402458")
        XCTAssertEqual(AnytimeFamilies.matchesCanonicalOrKnownNativeAlias("ZZZZZZZZ", "ZZZZZZZZ"), true, "ZZZZZZZZ/ZZZZZZZZ")
    }

    func testInitialSensorIdFromTheAddressOrTheName() {
        XCTAssertEqual(AnytimeFamilies.deriveInitialSensorId(deviceName: "SN08402458", address: "F0:FD:45:09:C7:C2"), "F0FD4509C7C2", "init.[SN08402458][F0:FD:45:09:C7:C2]")
        XCTAssertEqual(AnytimeFamilies.deriveInitialSensorId(deviceName: "SN08402458", address: nil), "ANY-SN08402458", "init.[SN08402458][null]")
        XCTAssertEqual(AnytimeFamilies.deriveInitialSensorId(deviceName: "SN08402458", address: ""), "ANY-SN08402458", "init.[SN08402458][]")
        XCTAssertEqual(AnytimeFamilies.deriveInitialSensorId(deviceName: "Anytime  4pro", address: "bad"), "ANY-ANYTIME4PRO", "init.[Anytime  4pro][bad]")
        XCTAssertEqual(AnytimeFamilies.deriveInitialSensorId(deviceName: "", address: nil), "ANY-PENDING", "init.[][null]")
        XCTAssertEqual(AnytimeFamilies.deriveInitialSensorId(deviceName: "a-very-long-device-name-here", address: nil), "ANY-AVERYLONGDEV", "init.[a-very-long-device-name-here][null]")
        XCTAssertEqual(AnytimeFamilies.deriveInitialSensorId(deviceName: "SN16!!", address: "0123456789abcdef"), "0123456789ABCDEF", "init.[SN16!!][0123456789abcdef]")
    }

    // MARK: constants and Kotlin number semantics

    func testWarmupWindowIsAPropertyOfTheSample() {
        XCTAssertEqual(AnytimeConstants.isWithinWarmup(anchorMs: 1000, sampleMs: 1500, windowMs: 1000), true)
        XCTAssertEqual(AnytimeConstants.isWithinWarmup(anchorMs: 1000, sampleMs: 2000, windowMs: 1000), false)
        XCTAssertEqual(AnytimeConstants.isWithinWarmup(anchorMs: 1000, sampleMs: 900, windowMs: 1000), true)
        XCTAssertFalse(AnytimeConstants.isWithinWarmup(anchorMs: 0, sampleMs: 1500, windowMs: 1000))
        XCTAssertFalse(AnytimeConstants.isWithinWarmup(anchorMs: 1000, sampleMs: 0, windowMs: 1000))
        XCTAssertFalse(AnytimeConstants.isWithinWarmup(anchorMs: 1000, sampleMs: 1500, windowMs: 0))
    }

    func testCachedCipherLooksUnbound() {
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: 0, lastDataRxAtMs: 0, streamingSinceMs: 5000), false)
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: 10, lastDataRxAtMs: 0, streamingSinceMs: 5000), false)
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: 0, lastDataRxAtMs: 6000, streamingSinceMs: 5000), false)
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: 0, lastDataRxAtMs: 5000, streamingSinceMs: 5000), false)
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: -1, lastDataRxAtMs: 0, streamingSinceMs: 0), false)
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: -1, lastDataRxAtMs: 0, streamingSinceMs: 5000), true)
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: -1, lastDataRxAtMs: 6000, streamingSinceMs: 5000), false)
        XCTAssertEqual(AnytimeConstants.ct5CachedCipherLooksUnbound(lastGlucoseId: -1, lastDataRxAtMs: 4999, streamingSinceMs: 5000), true)
    }

    func testCt14OpcodeOwnership() {
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x48), true, "0x48")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x54), true, "0x54")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x53), true, "0x53")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x43), true, "0x43")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x44), true, "0x44")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x47), true, "0x47")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x58), true, "0x58")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x07), false, "0x07")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x08), false, "0x08")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x09), false, "0x09")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x05), false, "0x05")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x06), false, "0x06")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x0A), false, "0x0A")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x11), false, "0x11")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x35), false, "0x35")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x37), false, "0x37")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x38), false, "0x38")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0x00), false, "0x00")
        XCTAssertEqual(AnytimeConstants.isCt14Opcode(0xFF), false, "0xFF")
    }

    func testKotlinNumberHelpers() {
        let inputs: [(String, Float)] = [
            ("2.5", 2.5), ("-2.5", -2.5), ("0.49999997", Float(0.49999997)), ("0.5", 0.5), ("1.4999999", Float(1.4999999)), ("-0.5", -0.5),
            ("-0.51", Float(-0.51)), ("3.0E9", 3.0e9), ("-3.0E9", -3.0e9), ("100.5", 100.5), ("267.5", Float(2.675) * 100), ("123.4", Float(12.34) * 10)
        ]
        let rounded: [String: Int] = [
            "2.5": 3,
            "-2.5": -2,
            "0.49999997": 0,
            "0.5": 1,
            "1.4999999": 1,
            "-0.5": 0,
            "-0.51": -1,
            "3.0E9": 2147483647,
            "-3.0E9": -2147483648,
            "100.5": 101,
            "267.5": 268,
            "123.4": 123
        ]
        let truncated: [String: Int] = [
            "2.5": 2,
            "-2.5": -2,
            "0.49999997": 0,
            "0.5": 0,
            "1.4999999": 1,
            "-0.5": 0,
            "-0.51": 0,
            "3.0E9": 2147483647,
            "-3.0E9": -2147483648,
            "100.5": 100,
            "267.5": 267,
            "123.4": 123
        ]
        for (label, value) in inputs {
            XCTAssertEqual(anytimeKotlinRound(value), rounded[label], "round \(label)")
            XCTAssertEqual(anytimeKotlinInt(value), truncated[label], "toInt \(label)")
        }
        XCTAssertEqual(anytimeKotlinInt(Float.nan), 0)
        XCTAssertEqual(anytimeKotlinInt(Float.infinity), 2147483647)
        XCTAssertEqual(anytimeClamp(5, 0, 3), 3)
        XCTAssertEqual(anytimeClamp(-5, 0, 3), 0)
        XCTAssertEqual(anytimeClamp(2, 0, 3), 2)
    }
}
