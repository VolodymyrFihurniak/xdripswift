//
//  ICanProtocolTests.swift
//  xdripTests
//
//  Expected values come from a Python port of the JugglucoNG icanhealth package (the live frames
//  are JugglucoNG's captured vectors, the rest was encrypted and computed with the same keys).
//

import XCTest
@testable import xdrip

final class ICanProtocolTests: XCTestCase {
    private func hex(_ text: String) -> [UInt8] {
        return text.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    private let challenge: [UInt8] = [0xF1, 0x18, 0x6B, 0xD2]
    private let serialNew = "0A1B2C3D4E05F6"
    private let serialOld = "0A1B2C3D4E00F6"

    // MARK: Key family and crypto

    func testKeyFamilySelector() {
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: serialNew, softwareVersion: nil), .new)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: serialOld, softwareVersion: nil), .old)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: "0A1B2C3D4E04F6", softwareVersion: nil), .new)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: "0A1B2C3D4E07F6", softwareVersion: nil), .new)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: "0A1B2C3D4E08F6", softwareVersion: nil), .old)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: "0A1B2C3D4E03F6", softwareVersion: nil), .old)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: nil, softwareVersion: nil), .old)
        // The serial wins; a serial that is too short falls back to the software revision.
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: serialOld, softwareVersion: "0123456789" + "06" + "xx"), .old)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: "short", softwareVersion: "0123456789" + "06" + "xx"), .new)
        XCTAssertEqual(ICanKeyFamily.resolve(launcherSerial: "  " + serialNew + "  ", softwareVersion: nil), .new)
    }

    func testBundledTablesAndKeys() {
        for family in [ICanKeyFamily.old, ICanKeyFamily.new] {
            XCTAssertEqual(family.glucoseKey.count, 16)
            XCTAssertEqual(family.originalHistoryKey.count, 16)
            XCTAssertEqual(family.authKey.count, 16)
            XCTAssertEqual(family.warmupXorTable.count, 64)
        }
        XCTAssertEqual(ICanKeyFamily.old.warmupXorTable.first, 0x6D)
        XCTAssertEqual(ICanKeyFamily.old.warmupXorTable.last, 0x82)
        XCTAssertEqual(ICanKeyFamily.new.warmupXorTable.first, 0xBF)
        XCTAssertEqual(ICanKeyFamily.new.warmupXorTable.last, 0xB8)
        XCTAssertEqual(String(decoding: ICanKeyFamily.new.glucoseKey, as: UTF8.self), "y67BbdK!3qN?75t8")
        XCTAssertEqual(String(decoding: ICanKeyFamily.old.authKey, as: UTF8.self), "92AFQU*u9c695826")
    }

    func testAuthIv() {
        XCTAssertEqual(ICanCrypto.iv(challenge: challenge), hex("00 F1 00 00 00 00 18 00 00 00 6B 00 00 00 00 D2"))
        XCTAssertNil(ICanCrypto.iv(challenge: [1, 2, 3]))
        XCTAssertNil(ICanCrypto.iv(challenge: [1, 2, 3, 4, 5]))
    }

    func testCbcRoundTripAndBadInput() {
        let key = ICanKeyFamily.new.glucoseKey
        guard let iv = ICanCrypto.iv(challenge: challenge) else { return XCTFail("iv") }
        let plain: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
        guard let cipher = ICanCrypto.encryptCBC(plain, key: key, iv: iv) else { return XCTFail("encrypt") }
        XCTAssertEqual(cipher.count, 16)
        XCTAssertEqual(ICanCrypto.decryptCBC(cipher, key: key, iv: iv), plain)
        XCTAssertNil(ICanCrypto.decryptCBC(Array(cipher.dropLast()), key: key, iv: iv))
        XCTAssertNil(ICanCrypto.decryptCBC(cipher, key: [1, 2, 3], iv: iv))
        XCTAssertNil(ICanCrypto.decryptCBC([], key: key, iv: iv))
    }

    // MARK: Glucose field

    func testGlucoseFieldDecode() {
        let field = ICanGlucoseField.decode(low: 0xAB, high: 0x31, direct: false)
        XCTAssertEqual(field.nibble, 3)
        XCTAssertEqual(field.mantissa, 427)
        let direct = ICanGlucoseField.decode(low: 0x55, high: 0x12, direct: true)
        XCTAssertEqual(direct.nibble, 0)
        XCTAssertEqual(direct.mantissa, 4693)
        XCTAssertEqual(ICanGlucoseField(nibble: 0, mantissa: 597).mgdl, 107.56864929199219, accuracy: 0.001)
        XCTAssertEqual(ICanGlucoseField(nibble: 0, mantissa: 100).mgdl, 18.0182, accuracy: 0.001)
        XCTAssertEqual(ICanGlucoseField(nibble: 0, mantissa: 4095).mgdl, 737.8452758789062, accuracy: 0.001)
    }

    func testValidRange() {
        XCTAssertTrue(ICanConstants.isValidMgdl(10))
        XCTAssertTrue(ICanConstants.isValidMgdl(551))
        XCTAssertFalse(ICanConstants.isValidMgdl(9.9))
        XCTAssertFalse(ICanConstants.isValidMgdl(551.1))
    }

    // MARK: Live frames

    func testLiveFramesFromCapturedVectors() {
        let newChallenge = hex("30 13 AA 84")
        let seq18 = hex("12 00 02 C1 CD 90 F4 FD AF 6C 42 AC D5 C9 87 B6 52 2B 7D")
        let warm = ICanParser.parseLive(seq18, family: .new, challenge: newChallenge, direct: false, warmupMinutes: 120)
        XCTAssertEqual(warm?.sequence, 18)
        XCTAssertEqual(warm?.field.mantissa, 597)
        XCTAssertEqual(warm?.field.nibble, 0)
        XCTAssertEqual(warm?.statusByte, 0x80)
        XCTAssertEqual(warm?.mgdl ?? 0, 107.56864929199219, accuracy: 0.001)
        // Without the warm-up transform the same frame reads as a different (wrong) value.
        let plain = ICanParser.parseLive(seq18, family: .new, challenge: newChallenge, direct: false, warmupMinutes: 0)
        XCTAssertEqual(plain?.field.mantissa, 1755)
        XCTAssertEqual(plain?.field.nibble, 15)

        let seq30 = hex("1E 00 02 E2 0C C3 32 50 31 C3 EE FD B3 49 7B 5A A3 05 2B")
        let reading30 = ICanParser.parseLive(seq30, family: .new, challenge: hex("C6 18 3B BD"), direct: false, warmupMinutes: 0)
        XCTAssertEqual(reading30?.field.mantissa, 573)
        XCTAssertEqual(reading30?.field.nibble, 4)
        XCTAssertEqual(reading30?.mgdl ?? 0, 103.2442855834961, accuracy: 0.001)

        let seq117 = hex("75 00 02 D4 22 8E 35 9E 64 5F 00 98 00 FF 86 4A CA 2F 4A")
        let challenge117 = hex("F8 93 7B 8C")
        XCTAssertEqual(ICanParser.parseLive(seq117, family: .new, challenge: challenge117, direct: false, warmupMinutes: 120)?.field.mantissa, 385)
        XCTAssertEqual(ICanParser.parseLive(seq117, family: .new, challenge: challenge117, direct: false, warmupMinutes: 0)?.field.mantissa, 3134)

        let seq99 = hex("63 00 02 DB 0C 40 27 65 C0 5F 94 2F B2 0A 39 AB 3D 0F 72")
        let issue = ICanParser.parseLive(seq99, family: .new, challenge: hex("06 D4 8E FA"), direct: false, warmupMinutes: 120)
        XCTAssertEqual(issue?.sequence, 99)
        XCTAssertEqual(issue?.field.mantissa, 822)
        XCTAssertEqual(issue?.mgdl ?? 0, 148.10960388183594, accuracy: 0.001)
    }

    func testLiveFrameOldFamily() {
        let frame = hex("48 03 02 3B AB 61 F4 F5 B4 2F 9F 48 79 A9 05 C0 A1 26 F9")
        let reading = ICanParser.parseLive(frame, family: .old, challenge: challenge, direct: false, warmupMinutes: 0)
        XCTAssertEqual(reading?.sequence, 840)
        XCTAssertEqual(reading?.field.mantissa, 525)
        XCTAssertEqual(reading?.statusByte, 0x80)
        XCTAssertEqual(reading?.mgdl ?? 0, 94.59555053710938, accuracy: 0.001)
        // The new key cannot decrypt an old-family frame.
        XCTAssertNil(ICanParser.parseLive(frame, family: .new, challenge: challenge, direct: false, warmupMinutes: 0))
    }

    func testLiveFrameRejections() {
        let frame = hex("48 03 02 3B AB 61 F4 F5 B4 2F 9F 48 79 A9 05 C0 A1 26 F9")
        // Header sequence differs from the one inside the encrypted content.
        var wrongSequence = frame
        wrongSequence[0] = 0x49
        XCTAssertNil(ICanParser.parseLive(wrongSequence, family: .old, challenge: challenge, direct: false, warmupMinutes: 0))
        // The IV depends on the challenge.
        XCTAssertNil(ICanParser.parseLive(frame, family: .old, challenge: hex("F1 18 6B D3"), direct: false, warmupMinutes: 0))
        XCTAssertNil(ICanParser.parseLive(frame, family: .old, challenge: nil, direct: false, warmupMinutes: 0))
        XCTAssertNil(ICanParser.parseLive(frame, family: .old, challenge: [1, 2, 3], direct: false, warmupMinutes: 0))
        XCTAssertNil(ICanParser.parseLive(Array(frame.dropLast()), family: .old, challenge: challenge, direct: false, warmupMinutes: 0))
    }

    // MARK: Authentication

    func testAuthTokens() {
        XCTAssertEqual(
            ICanParser.deriveAuthToken(challenge: challenge, userId: "ABCDEF123456", authKey: ICanKeyFamily.old.authKey),
            hex("15 53 00 0F 9F 7E 85 E7 F5 49 DF 8D 88 FA 0E 9A")
        )
        let token = ICanParser.deriveAuthToken(challenge: challenge, userId: "ABCDEF123456", authKey: ICanKeyFamily.new.authKey)
        XCTAssertEqual(token, hex("6A EF 85 6F D8 58 F7 50 A1 30 F5 15 DA 45 AE 28"))
        XCTAssertEqual(
            ICanParser.deriveAuthToken(challenge: challenge, userId: "xy", authKey: ICanKeyFamily.new.authKey),
            hex("D3 F9 97 35 8C 7B D1 B9 0A 60 D7 2C FE F2 FB B1")
        )
        XCTAssertNil(ICanParser.deriveAuthToken(challenge: [1, 2], userId: "x", authKey: ICanKeyFamily.new.authKey))
        let packet = token.flatMap { ICanParser.buildAuthTokenPacket($0) }
        XCTAssertEqual(packet, hex("F4 10 6A EF 85 6F D8 58 F7 50 A1 30 F5 15 DA 45 AE 28"))
        XCTAssertNil(ICanParser.buildAuthTokenPacket([1, 2, 3]))
    }

    func testUserIdNormalisation() {
        XCTAssertEqual(ICanParser.normalizeStandaloneUserId("  SN 12345678901234567 "), "678901234567")
        XCTAssertEqual(ICanParser.normalizeStandaloneUserId(nil), "000000000000")
        XCTAssertEqual(ICanParser.normalizeStandaloneUserId(""), "000000000000")
        XCTAssertEqual(ICanParser.normalizeStandaloneUserId("AB CD"), "ABCD00000000")
        XCTAssertEqual(ICanParser.normalizeStandaloneUserId("xy"), "xy0000000000")
        XCTAssertEqual(ICanParser.normalizeConfiguredUserId(" a b\tc "), "abc")
    }

    func testAuthResponses() {
        XCTAssertTrue(ICanParser.isChallengeResponse(hex("06 F3 01 F1 18 6B D2")))
        XCTAssertEqual(ICanParser.extractChallenge(hex("06 F3 01 F1 18 6B D2")), challenge)
        XCTAssertFalse(ICanParser.isChallengeResponse(hex("06 F3 01 F1 18 6B")))
        XCTAssertNil(ICanParser.extractChallenge(hex("06 F3 02 F1 18 6B D2")))
        XCTAssertTrue(ICanParser.isAuthSuccess(hex("1C F4 01")))
        XCTAssertFalse(ICanParser.isAuthSuccess(hex("1C F4 02")))
        XCTAssertEqual(ICanParser.parseAuthResult(hex("1C F4 02")), 2)
        XCTAssertNil(ICanParser.parseAuthResult(hex("1C F6 01")))
        XCTAssertEqual(ICanParser.parseSensorInfoMarker(hex("1C F6 01 FF FF")), 0xFFFF)
        XCTAssertEqual(ICanParser.parseSensorInfoMarker(hex("1C F6 01 4E 02")), 590)
        XCTAssertNil(ICanParser.parseSensorInfoMarker(hex("1C F6 01 4E")))
        XCTAssertTrue(ICanParser.isSensorInfoResponse(hex("1C F6 01")))
    }

    func testUserIdRecoveryFromReject() {
        let reject = hex("1C F4 02 C9 4E 01 89 87 62 7F 49 1C 00 8E 3A 47 D5 C0 37 05")
        XCTAssertEqual(ICanParser.recoverUserIdFromAuthReject(reject, challenge: challenge, authKey: ICanKeyFamily.new.authKey), "ABCDEF123456")
        // Junk characters are stripped.
        let junk = hex("1C F4 02 5C 95 32 58 9F 14 4A 1F 66 E0 B5 C5 3B 4D 22 24 01")
        XCTAssertEqual(ICanParser.recoverUserIdFromAuthReject(junk, challenge: challenge, authKey: ICanKeyFamily.old.authKey), "ab12 x")
        // A zero trailer, another status, a short frame and a missing challenge give nothing.
        var zeroTrailer = reject
        zeroTrailer[zeroTrailer.count - 1] = 0
        XCTAssertNil(ICanParser.recoverUserIdFromAuthReject(zeroTrailer, challenge: challenge, authKey: ICanKeyFamily.new.authKey))
        var accepted = reject
        accepted[2] = 0x01
        XCTAssertNil(ICanParser.recoverUserIdFromAuthReject(accepted, challenge: challenge, authKey: ICanKeyFamily.new.authKey))
        XCTAssertNil(ICanParser.recoverUserIdFromAuthReject(Array(reject.dropLast(2)), challenge: challenge, authKey: ICanKeyFamily.new.authKey))
        XCTAssertNil(ICanParser.recoverUserIdFromAuthReject(reject, challenge: nil, authKey: ICanKeyFamily.new.authKey))
    }

    // MARK: History batches

    func testSnGlucoseBatch() {
        let frame = hex("53 4E 14 2A 52 02 87 EE A9 CF 12 19 CC 1A 81 E5 46 19 11 05 34 3A 00")
        XCTAssertTrue(ICanParser.isSnNotification(frame))
        XCTAssertEqual(ICanParser.parseSnType(frame), 2)
        guard let batch = ICanParser.parseSnHistoryBatch(frame, challenge: challenge, direct: false, launcherSerial: serialNew, softwareVersion: nil, readingIntervalMinutes: 3) else {
            return XCTFail("batch")
        }
        XCTAssertEqual(batch.subtype, 2)
        XCTAssertEqual(batch.baseSequence, 33)
        XCTAssertEqual(batch.records.map { $0.sequence }, [33, 36, 39, 42])
        XCTAssertEqual(batch.records.map { $0.glucose?.mantissa }, [597, 600, 612, 4095])
        XCTAssertEqual(batch.records.map { $0.glucose?.nibble }, [1, 1, 1, 1])
        // Another reading interval changes only the sequence step.
        let minute = ICanParser.parseSnHistoryBatch(frame, challenge: challenge, direct: false, launcherSerial: serialNew, softwareVersion: nil, readingIntervalMinutes: 1)
        XCTAssertEqual(minute?.records.map { $0.sequence }, [33, 34, 35, 36])
        // The direct variant reads all 16 bits.
        let direct = ICanParser.parseSnHistoryBatch(frame, challenge: challenge, direct: true, launcherSerial: serialNew, softwareVersion: nil, readingIntervalMinutes: 3)
        XCTAssertEqual(direct?.records.map { $0.glucose?.mantissa }, [4693, 4696, 4708, 8191])
        // Wrong key family, corrupt payload, wrong challenge and a non-SN frame are all refused.
        XCTAssertNil(ICanParser.parseSnHistoryBatch(frame, challenge: challenge, direct: false, launcherSerial: serialOld, softwareVersion: nil, readingIntervalMinutes: 3))
        var corrupt = frame
        corrupt[10] ^= 0xFF
        XCTAssertNil(ICanParser.parseSnHistoryBatch(corrupt, challenge: challenge, direct: false, launcherSerial: serialNew, softwareVersion: nil, readingIntervalMinutes: 3))
        XCTAssertNil(ICanParser.parseSnHistoryBatch(frame, challenge: hex("00 00 00 00"), direct: false, launcherSerial: serialNew, softwareVersion: nil, readingIntervalMinutes: 3))
        XCTAssertNil(ICanParser.parseSnHistoryBatch(hex("06 00 F1 01"), challenge: challenge, direct: false, launcherSerial: serialNew, softwareVersion: nil, readingIntervalMinutes: 3))
        XCTAssertNil(ICanParser.parseSnType(hex("53 4E 10 00 52 01")))
        XCTAssertNil(ICanParser.parseSnType(hex("53 4E 10 2A 52")))
    }

    func testSnOriginalBatch() {
        let frame = hex("53 4E 14 2A 52 01 80 5D 32 44 DF 4F B5 EC 0B 59 B2 DE D9 1A E9 CF 00")
        guard let batch = ICanParser.parseSnHistoryBatch(frame, challenge: challenge, direct: false, launcherSerial: serialOld, softwareVersion: nil, readingIntervalMinutes: 3) else {
            return XCTFail("batch")
        }
        XCTAssertEqual(batch.subtype, 1)
        XCTAssertEqual(batch.baseSequence, 60)
        XCTAssertEqual(batch.records.map { $0.sequence }, [60, 63])
        XCTAssertNil(batch.records[0].glucose)
        XCTAssertEqual(batch.records[0].currentValue ?? 0, 2501234, accuracy: 0.5)
        XCTAssertEqual(batch.records[1].currentValue ?? 0, 2500020, accuracy: 0.5)
        XCTAssertEqual(batch.records[0].temperatureC ?? 0, 36.5, accuracy: 0.001)
        XCTAssertEqual(batch.records[1].temperatureC ?? 0, 37.1, accuracy: 0.001)
    }

    func testEncryptedHistoryRecords() {
        // 16-byte block and the same block inside a 19-byte frame (subtype 2 in the third byte).
        let block = hex("FE 73 D1 54 8E 3F 13 15 F3 BF 8C 95 A8 39 76 28")
        let record = ICanParser.parseEncryptedHistoryRecord(block, challenge: challenge, readingOriginalHistory: false, direct: false, launcherSerial: serialNew, softwareVersion: nil, warmupMinutes: 120)
        XCTAssertEqual(record?.sequence, 200)
        XCTAssertEqual(record?.subtype, 2)
        XCTAssertEqual(record?.glucose?.mantissa, 427)
        XCTAssertEqual(record?.glucose?.nibble, 3)
        XCTAssertEqual(record?.currentValue ?? 0, 2500016, accuracy: 0.5)
        XCTAssertEqual(record?.temperatureC ?? 0, 36.6, accuracy: 0.001)
        let framed = hex("C8 00 02") + block
        XCTAssertEqual(
            ICanParser.parseEncryptedHistoryRecord(framed, challenge: challenge, readingOriginalHistory: false, direct: false, launcherSerial: serialNew, softwareVersion: nil, warmupMinutes: 120)?.glucose?.mantissa,
            427
        )
        // Read as original history the glucose key does not fit.
        XCTAssertNil(ICanParser.parseEncryptedHistoryRecord(block, challenge: challenge, readingOriginalHistory: true, direct: false, launcherSerial: serialNew, softwareVersion: nil, warmupMinutes: 120))
        // A frame with an unknown subtype and a short block are refused.
        XCTAssertNil(ICanParser.parseEncryptedHistoryRecord(hex("C8 00 07") + block, challenge: challenge, readingOriginalHistory: false, direct: false, launcherSerial: serialNew, softwareVersion: nil, warmupMinutes: 120))
        XCTAssertNil(ICanParser.parseEncryptedHistoryRecord(Array(block.prefix(10)), challenge: challenge, readingOriginalHistory: false, direct: false, launcherSerial: serialNew, softwareVersion: nil, warmupMinutes: 120))
    }

    func testWarmupHistoryRecord() {
        let block = hex("18 20 5F 64 34 05 82 8B B8 68 8D C2 99 27 35 8E")
        let decoded = ICanParser.parseEncryptedHistoryRecord(block, challenge: challenge, readingOriginalHistory: false, direct: false, launcherSerial: serialNew, softwareVersion: nil, warmupMinutes: 120)
        XCTAssertEqual(decoded?.sequence, 30)
        XCTAssertEqual(decoded?.glucose?.mantissa, 573)
        XCTAssertEqual(decoded?.glucose?.nibble, 4)
        // Past the warm-up window the same bytes are taken as they are.
        let raw = ICanParser.parseEncryptedHistoryRecord(block, challenge: challenge, readingOriginalHistory: false, direct: false, launcherSerial: serialNew, softwareVersion: nil, warmupMinutes: 0)
        XCTAssertEqual(raw?.glucose?.mantissa, 2896)
        XCTAssertEqual(raw?.glucose?.nibble, 15)
    }

    func testOriginalHistoryRecord() {
        let block = hex("19 8D 11 AD F4 08 61 8F B7 B2 88 67 0E D0 8C A3")
        let record = ICanParser.parseEncryptedHistoryRecord(block, challenge: challenge, readingOriginalHistory: true, direct: false, launcherSerial: serialOld, softwareVersion: nil, warmupMinutes: 120)
        XCTAssertEqual(record?.sequence, 90)
        XCTAssertEqual(record?.subtype, 1)
        XCTAssertNil(record?.glucose)
        XCTAssertEqual(record?.currentValue ?? 0, 2504660, accuracy: 0.5)
        XCTAssertEqual(record?.temperatureC ?? 0, 37.2, accuracy: 0.001)
    }

    // MARK: RACP

    func testRacpRequestsAndResults() {
        XCTAssertEqual(ICanParser.racpReportAllGlucose(), hex("F1 01 02"))
        XCTAssertEqual(ICanParser.racpReportAllGlucose(modernPrefix: false), hex("01 01 02"))
        XCTAssertEqual(ICanParser.racpReportAllOriginal(), hex("F1 01 01"))
        XCTAssertEqual(ICanParser.racpReportFromGlucose(offset: 0x0123), hex("F1 03 02 01 23 01"))
        XCTAssertEqual(ICanParser.racpReportFromGlucose(offset: 300, modernPrefix: false), hex("01 03 02 01 2C 01"))
        XCTAssertEqual(ICanParser.racpReportFromOriginal(offset: 5), hex("F1 03 01 01 05 00"))
        XCTAssertEqual(ICanParser.racpReportFromGlucose(offset: 0), hex("F1 03 02 01 01 00"))
        XCTAssertEqual(ICanParser.racpReportFromGlucose(offset: 99999), hex("F1 03 02 01 FF FF"))
        XCTAssertEqual(ICanParser.parseRacpResultCode(hex("06 00 F1 01")), 1)
        XCTAssertEqual(ICanParser.parseRacpResultCode(hex("06 00 01 0A")), 0x0A)
        XCTAssertEqual(ICanParser.parseRacpResultCode(hex("06 00 F1 06")), 6)
        XCTAssertNil(ICanParser.parseRacpResultCode(hex("06 00 F2 01")))
        XCTAssertNil(ICanParser.parseRacpResultCode(hex("06 00 F1")))
    }

    // MARK: Profile and names

    func testProfiles() {
        func check(_ model: String?, _ family: String, _ interval: Int, _ warmup: Int, _ days: Int, line: UInt = #line) {
            let profile = ICanProfile.resolve(model: model)
            XCTAssertEqual(profile.familyName, family, line: line)
            XCTAssertEqual(profile.readingIntervalMinutes, interval, line: line)
            XCTAssertEqual(profile.warmupMinutes, warmup, line: line)
            XCTAssertEqual(profile.ratedLifetimeDays, days, line: line)
        }
        check("iCGM-t6", "i6", 3, 30, 15)
        check("iCan i3", "i3", 3, 120, 15)
        check("i7e", "i7e", 1, 30, 9)
        check("i7 pro", "i7", 1, 30, 15)
        check("H6 YK", "H6-15", 3, 30, 15)
        check("H6 ZZ", "H6-15", 3, 30, 15)
        check("H3", "H3", 3, 120, 8)
        check("i6 pro", "i6", 3, 30, 15)
        check("O3", "o3", 3, 120, 15)
        check("T3", "i3", 3, 120, 15)
        check("iCan i3a", "i3", 3, 120, 15)
        // JugglucoNG's hyphenated H6 checks never match after normalisation; so does this port.
        check("H6-14", "iCan", 3, 120, 15)
        check("H6-15", "iCan", 3, 120, 15)
        check("H6", "iCan", 3, 120, 15)
        check("", "iCan", 3, 120, 15)
        check(nil, "iCan", 3, 120, 15)
        check("Sinocare CGM", "iCan", 3, 120, 15)
        let combined = ICanProfile.resolve(model: "model x", rawSerial: "serial", softwareVersion: "i6s")
        XCTAssertEqual(combined.familyName, "i6")
        XCTAssertEqual(ICanProfile.defaultProfile.advisoryLifetimeDays, 28)
    }

    func testDeviceNames() {
        XCTAssertTrue(ICanDeviceName.looksLikeICan("iCGM-0123456789ABCDEF"))
        XCTAssertTrue(ICanDeviceName.looksLikeICan("Sinocare CGM"))
        XCTAssertTrue(ICanDeviceName.looksLikeICan("Sinocare i6"))
        XCTAssertTrue(ICanDeviceName.looksLikeICan("LT123456AB"))
        XCTAssertTrue(ICanDeviceName.looksLikeICan("P123456789ABC"))
        XCTAssertTrue(ICanDeviceName.looksLikeICan("p123456789abc"))
        XCTAssertTrue(ICanDeviceName.looksLikeICan("  iCGM-x  "))
        XCTAssertFalse(ICanDeviceName.looksLikeICan("P12345678ABC"))
        XCTAssertFalse(ICanDeviceName.looksLikeICan("ABCDEF123456"))
        XCTAssertFalse(ICanDeviceName.looksLikeICan("Sibionics"))
        XCTAssertFalse(ICanDeviceName.looksLikeICan(""))
        XCTAssertFalse(ICanDeviceName.looksLikeICan(nil))
    }

    func testDeviceStrings() {
        XCTAssertEqual(ICanParser.parseDeviceString(Array("iCGM-t6 ".utf8)), "iCGM-t6")
        XCTAssertEqual(ICanParser.parseDeviceString([0x32, 0x5B, 0xD1]), "325BD1")
        XCTAssertEqual(ICanParser.parseDeviceString([]), "")
    }

    // MARK: Session metadata

    func testSessionStartParsing() {
        let withOffset = ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 08 00"))
        XCTAssertEqual(withOffset?.year, 2024)
        XCTAssertEqual(withOffset?.month, 5)
        XCTAssertEqual(withOffset?.day, 6)
        XCTAssertEqual(withOffset?.hour, 7)
        XCTAssertEqual(withOffset?.minute, 8)
        XCTAssertEqual(withOffset?.second, 9)
        XCTAssertEqual(withOffset?.utcOffset15Min, 8)
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 80 FF"))?.timeZone15Min)
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 80 FF"))?.dst15Min)
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 14 00"))?.timeZone15Min)
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 39 00"))?.timeZone15Min)
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 08 09"))?.dst15Min)
        XCTAssertEqual(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 EC 00"))?.timeZone15Min, -20)
        XCTAssertEqual(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 08 04"))?.utcOffset15Min, 12)
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09"))?.utcOffset15Min)
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 06 07 08")))
        XCTAssertNil(ICanParser.parseSessionStart(hex("00 00 05 06 07 08 09")))
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 0D 06 07 08 09")))
        XCTAssertNil(ICanParser.parseSessionStart(hex("E8 07 05 00 07 08 09")))
    }

    func testSessionStartDates() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let newYork = TimeZone(identifier: "America/New_York")!
        // A non-zero offset is applied: wall clock 07:08:09 at UTC+2 is 05:08:09 UTC.
        let zoned = ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 08 00"))
        XCTAssertEqual(zoned?.date(deviceTimeZone: newYork)?.timeIntervalSince1970, 1714972089)
        // UTC-5 (-20 steps) moves the other way.
        let west = ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 EC 00"))
        XCTAssertEqual(west?.date(deviceTimeZone: utc)?.timeIntervalSince1970, 1714997289)
        // Unknown or zero offsets read the wall clock in the device zone.
        let unknown = ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 80 FF"))
        XCTAssertEqual(unknown?.date(deviceTimeZone: newYork)?.timeIntervalSince1970, 1714993689)
        let zero = ICanParser.parseSessionStart(hex("E8 07 05 06 07 08 09 00 00"))
        XCTAssertEqual(zero?.date(deviceTimeZone: newYork)?.timeIntervalSince1970, 1714993689)
    }

    func testStatusParsing() {
        let status = ICanParser.parseStatus(hex("10 27 80 00 00 00"))
        XCTAssertEqual(status?.sequence, 10000)
        XCTAssertEqual(status?.launcherState, 0x80)
        XCTAssertEqual(ICanParser.parseStatus(hex("05 00"))?.launcherState, 0)
        XCTAssertNil(ICanParser.parseStatus(hex("05")))
        XCTAssertTrue(ICanConstants.isActiveLauncherState(0x80))
        XCTAssertTrue(ICanConstants.isActiveLauncherState(0x01))
        XCTAssertFalse(ICanConstants.isActiveLauncherState(0x40))
        XCTAssertFalse(ICanConstants.isActiveLauncherState(0x00))
    }

    // MARK: Timeline

    private let now = Date(timeIntervalSince1970: 1772366400)

    func testTimelineWithConsistentSession() {
        let start = now.addingTimeInterval(-10000 * 60)
        let clock = ICanClock(sessionStart: start, counter: 10000, counterObservedAt: now)
        XCTAssertTrue(ICanTimeline.sessionMatchesCounter(sessionStart: start, counter: 10000, counterObservedAt: now))
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 10000, now: now, clock: clock), now)
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 9990, now: now, clock: clock), now.addingTimeInterval(-600))
        // History may reach far back, a live frame may not.
        XCTAssertEqual(ICanTimeline.resolve(sequence: 9000, now: now, clock: clock, requireRecent: false), now.addingTimeInterval(-60000))
        XCTAssertNil(ICanTimeline.resolve(sequence: 9000, now: now, clock: clock, requireRecent: true))
        XCTAssertNil(ICanTimeline.resolve(sequence: -1, now: now, clock: clock, requireRecent: false))
    }

    func testTimelineDistrustsSessionOffByTwoHours() {
        let start = now.addingTimeInterval(-10000 * 60 + 7200)
        let clock = ICanClock(sessionStart: start, counter: 10000, counterObservedAt: now)
        XCTAssertFalse(ICanTimeline.sessionMatchesCounter(sessionStart: start, counter: 10000, counterObservedAt: now))
        // Anchored on the counter instead of the wrong session start.
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 9990, now: now, clock: clock), now.addingTimeInterval(-600))
        XCTAssertEqual(ICanTimeline.resolve(sequence: 9000, now: now, clock: clock, requireRecent: false), now.addingTimeInterval(-60000))
        // Drift inside the tolerance is accepted.
        let nearStart = now.addingTimeInterval(-10000 * 60 + 1500)
        XCTAssertTrue(ICanTimeline.sessionMatchesCounter(sessionStart: nearStart, counter: 10000, counterObservedAt: now))
        XCTAssertFalse(ICanTimeline.sessionMatchesCounter(sessionStart: nil, counter: 10000, counterObservedAt: now))
        XCTAssertTrue(ICanTimeline.sessionMatchesCounter(sessionStart: nearStart, counter: nil, counterObservedAt: nil))
    }

    func testLiveTimestampGuards() {
        // The anchor is 20 minutes old: the newest frame is stamped now, an older one keeps its time.
        let stale = ICanClock(sessionStart: nil, counter: 10000, counterObservedAt: now.addingTimeInterval(-1200))
        XCTAssertEqual(ICanTimeline.resolve(sequence: 10000, now: now, clock: stale, requireRecent: true), now.addingTimeInterval(-1200))
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 10000, now: now, clock: stale), now)
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 9990, now: now, clock: stale), now.addingTimeInterval(-1800))
        // Anchors ahead of now are clamped or rejected, both end at now.
        let slightlyAhead = ICanClock(sessionStart: nil, counter: 10000, counterObservedAt: now.addingTimeInterval(3))
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 10000, now: now, clock: slightlyAhead), now)
        let further = ICanClock(sessionStart: nil, counter: 10000, counterObservedAt: now.addingTimeInterval(60))
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 10000, now: now, clock: further), now)
        // Nothing known: now.
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 5, now: now, clock: ICanClock()), now)
        XCTAssertNil(ICanTimeline.resolve(sequence: 5, now: now, clock: ICanClock(), requireRecent: true))
        // A session start without a counter still places a frame.
        let startOnly = ICanClock(sessionStart: now.addingTimeInterval(-600), counter: nil, counterObservedAt: nil)
        XCTAssertEqual(ICanTimeline.liveTimestamp(sequence: 10, now: now, clock: startOnly), now)
    }

    // MARK: History policy

    func testMissedReadingsAndGaps() {
        XCTAssertEqual(ICanHistoryPolicy.missedReadingsBetween(previousSequence: 30, currentSequence: 45, readingIntervalMinutes: 3), 4)
        XCTAssertEqual(ICanHistoryPolicy.missedReadingsBetween(previousSequence: 30, currentSequence: 33, readingIntervalMinutes: 3), 0)
        XCTAssertEqual(ICanHistoryPolicy.missedReadingsBetween(previousSequence: 30, currentSequence: 30, readingIntervalMinutes: 3), 0)
        XCTAssertEqual(ICanHistoryPolicy.missedReadingsBetween(previousSequence: -1, currentSequence: 30, readingIntervalMinutes: 3), 0)
        XCTAssertEqual(ICanHistoryPolicy.missedReadingsBetween(previousSequence: 30, currentSequence: 100, readingIntervalMinutes: 0), 0)
        XCTAssertEqual(ICanHistoryPolicy.missedReadingsBetween(previousSequence: 100, currentSequence: 160, readingIntervalMinutes: 1), 59)
        let gap = ICanHistoryPolicy.liveGapBetween(previousSequence: 30, currentSequence: 45, readingIntervalMinutes: 3)
        XCTAssertEqual(gap, ICanSequenceGap(startSequence: 33, endSequenceExclusive: 45, intervalMinutes: 3))
        XCTAssertEqual(gap?.readingCount, 4)
        XCTAssertTrue(gap?.contains(36) ?? false)
        XCTAssertFalse(gap?.contains(37) ?? true)
        XCTAssertFalse(gap?.contains(45) ?? true)
        XCTAssertNil(ICanHistoryPolicy.liveGapBetween(previousSequence: 30, currentSequence: 33, readingIntervalMinutes: 3))
    }

    func testHistoryStartSequence() {
        let gap = ICanSequenceGap(startSequence: 63, endSequenceExclusive: 78, intervalMinutes: 3)
        XCTAssertEqual(ICanHistoryPolicy.automaticGlucoseHistoryStartSequence(readingIntervalMinutes: 3, currentSequence: 100, latestKnownSequence: 90, pendingLiveGap: gap), 63)
        XCTAssertEqual(ICanHistoryPolicy.automaticGlucoseHistoryStartSequence(readingIntervalMinutes: 3, currentSequence: 100, latestKnownSequence: 90, pendingLiveGap: nil), 93)
        XCTAssertNil(ICanHistoryPolicy.automaticGlucoseHistoryStartSequence(readingIntervalMinutes: 3, currentSequence: 91, latestKnownSequence: 90, pendingLiveGap: nil))
        XCTAssertEqual(ICanHistoryPolicy.automaticGlucoseHistoryStartSequence(readingIntervalMinutes: 3, currentSequence: 100, latestKnownSequence: -1, pendingLiveGap: nil), 3)
    }

    func testTailRetry() {
        XCTAssertEqual(ICanHistoryPolicy.tailRetryStartSequence(readingIntervalMinutes: 3, currentSequence: 600, requestedSequence: 3), 597)
        XCTAssertEqual(ICanHistoryPolicy.tailRetryStartSequence(readingIntervalMinutes: 3, currentSequence: 600, requestedSequence: 591), 597)
        XCTAssertNil(ICanHistoryPolicy.tailRetryStartSequence(readingIntervalMinutes: 3, currentSequence: 600, requestedSequence: 594))
        XCTAssertNil(ICanHistoryPolicy.tailRetryStartSequence(readingIntervalMinutes: 3, currentSequence: 4, requestedSequence: 1))
        XCTAssertNil(ICanHistoryPolicy.tailRetryStartSequence(readingIntervalMinutes: 0, currentSequence: 600, requestedSequence: 1))
    }

    func testHistoryOverlap() {
        let gap = ICanSequenceGap(startSequence: 63, endSequenceExclusive: 78, intervalMinutes: 3)
        XCTAssertTrue(ICanHistoryPolicy.shouldSkipHistoryOverlap(sequence: 90, sampleTime: nil, coveredSequence: 100, coveredTime: nil, pendingLiveGap: nil))
        XCTAssertFalse(ICanHistoryPolicy.shouldSkipHistoryOverlap(sequence: 101, sampleTime: nil, coveredSequence: 100, coveredTime: nil, pendingLiveGap: nil))
        XCTAssertFalse(ICanHistoryPolicy.shouldSkipHistoryOverlap(sequence: 66, sampleTime: nil, coveredSequence: 100, coveredTime: nil, pendingLiveGap: gap))
        XCTAssertFalse(ICanHistoryPolicy.shouldSkipHistoryOverlap(sequence: 90, sampleTime: nil, coveredSequence: -1, coveredTime: nil, pendingLiveGap: nil))
        XCTAssertTrue(ICanHistoryPolicy.shouldSkipHistoryOverlap(sequence: 5, sampleTime: now, coveredSequence: -1, coveredTime: now, pendingLiveGap: nil))
        XCTAssertFalse(ICanHistoryPolicy.shouldSkipHistoryOverlap(sequence: 5, sampleTime: now.addingTimeInterval(1), coveredSequence: -1, coveredTime: now, pendingLiveGap: nil))
    }

    // MARK: - registration

    func testICanIsAvailableInTheDirectCGMAddFlow() {
        XCTAssertEqual(BluetoothPeripheralType.iCanType.category(), .CGM)
        XCTAssertTrue(BluetoothPeripheralType.addFlowPreferredOrder[.CGM]?.contains(.iCanType) == true)
        XCTAssertEqual(BluetoothPeripheralType.iCanType.onlineHelpTopic, .addDirectCGM)
        XCTAssertFalse(BluetoothPeripheralType.iCanType.usesIntermittentConnection)
    }

    func testICanTransmitterTypeProperties() {
        XCTAssertEqual(CGMTransmitterType.iCan.rawValue, "iCan")
        XCTAssertEqual(CGMTransmitterType.iCan.sensorType(), .iCan)
        XCTAssertTrue(CGMTransmitterType.iCan.canDetectNewSensor())
        XCTAssertFalse(CGMTransmitterType.iCan.allowManualSensorStart())
    }

    func testICanTroubleshootingSource() throws {
        XCTAssertEqual(TroubleshootingLogSource(directTransmitterType: .iCan), .iCan)
        let source = try XCTUnwrap(TroubleshootingLogSource(bluetoothPeripheralType: .iCanType))
        XCTAssertEqual(source, .iCan)
        XCTAssertEqual(source.name, "iCan")
        XCTAssertFalse(source.isFollowerSource)
    }

    func testICanEntityRoundTripsThroughCoreData() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreDataManager.mainManagedObjectContext
        let ican = ICan(address: "test-ican", name: "iCGM-0001", alias: nil, nsManagedObjectContext: context)
        XCTAssertEqual(ican.bluetoothPeripheralType(), .iCanType)
        XCTAssertTrue(ican.blePeripheral.shouldconnect)

        coreDataManager.saveChanges()
        let objectID = ican.blePeripheral.objectID
        context.reset()

        let restored = try XCTUnwrap(context.existingObject(with: objectID) as? BLEPeripheral)
        XCTAssertNotNil(restored.iCan)
        XCTAssertNil(restored.sibionics2)
        XCTAssertEqual(restored.iCan?.bluetoothPeripheralType(), .iCanType)
    }

    func testDeviceStoreRoundTripAndClear() {
        let address = "ican-test-address"
        ICanDeviceStore.clear(address: address)
        XCTAssertNil(ICanDeviceStore.load(address: address).authAccepted)
        XCTAssertEqual(ICanDeviceStore.load(address: address).highestSequence, -1)

        ICanDeviceStore.update(address: address) {
            $0.model = "iCan i3"
            $0.authAccepted = true
            $0.problem = .linkLost
        }
        let stored = ICanDeviceStore.load(address: address)
        XCTAssertEqual(stored.model, "iCan i3")
        XCTAssertEqual(stored.authAccepted, true)
        XCTAssertEqual(stored.problem, .linkLost)

        ICanDeviceStore.clear(address: address)
        XCTAssertNil(ICanDeviceStore.load(address: address).model)
    }
}
