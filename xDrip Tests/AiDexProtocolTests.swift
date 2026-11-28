//
//  AiDexProtocolTests.swift
//  xdripTests
//
//  Expected values come from running the unchanged JugglucoNG Kotlin (`drivers/aidex/native`) on the JVM,
//  cross-checked for the crypto with an independent Python implementation. The three 0x23 history pages
//  and the documented live frame are JugglucoNG's captured vectors; the rest was encrypted with the
//  fixed keys below. Never compared with a real sensor.
//

import XCTest
@testable import xdrip

final class AiDexProtocolTests: XCTestCase {

    private func h(_ text: String) -> [UInt8] {
        return AiDexParser.bytes(fromHex: text)
    }

    private func hexOf(_ data: [UInt8]?) -> String {
        guard let data = data else { return "nil" }
        return AiDexParser.compactHex(data)
    }

    private let sensorSerial = "AiDEX X-2222267V4E"
    private let pairKey: [UInt8] = Array(1...16).map { UInt8($0) }
    private let sessionKey: [UInt8] = (0..<16).map { UInt8(0xA1 + $0) }
    private let bond = "C6D24EB0DC4A6803565125AA5F105EE23B"
    private let badBond = "C6D24EB0DC4A6803565125AA5F105EE23A"

    // MARK: real captured pages (JugglucoNG test vectors, opcode 0x23, CRC included)

    private let realPage0 = [
        "23 01 40 38 42 80 42 40 41 80 3F 80 3E 80 3D 40 3E 80 43 80 46 80 48 40 49 80 49 80 49 80 48 40",
        "46 80 44 80 43 80 42 40 41 80 40 80 3F 80 3D 40 3D 80 3C 80 3C 80 3D 40 3D 80 3E 80 3E 80 3E 40",
        "3E 80 3E 80 3E 80 3E 40 3D 80 3D 80 3C 80 3C 40 3C 80 3D 80 3E 80 3F 40 3F 80 3E 80 3D 80 3C 40",
        "3B 80 3B 80 3B 80 3B 40 3B 80 3B 80 3B 80 3C 40 3C 80 3C 80 3C 80 3C 40 3C 80 3C 80 3C 80 3B 40",
        "3B 80 3B 80 3C 80 3C 40 3D 80 3D 80 3D 80 3D 00 3D 80 3E 80 41 80 45 40 47 80 46 80 44 80 45 40",
        "45 80 45 80 44 80 43 40 43 80 41 80 3F 80 3E 40 3E 80 3E 80 3E 80 3E 40 3F 80 3F 80 3F 80 3F 40",
        "3F 80 3F 80 3F 80 3F 40 3F 80 3F 80 3E 80 3E 40 3E 80 3D 80 3C 80 3B 40 3B 80 3B 80 3B 80 3B 40",
        "3B 80 3B 80 3C 80 3C 40 3C 80 3C 80 3C 80 3D 40 3F 80 8B 7D"
    ].joined(separator: " ")

    private let realPage1 = [
        "23 01 B7 38 41 80 41 80 41 40 41 80 40 80 3E 80 3D 40 3D 80 3D 80 3E 80 3E 40 3F 80 3E 80 3F 80",
        "3F 00 3F 80 40 80 40 80 41 00 41 80 41 80 40 80 3F 00 3F 80 3E 80 3D 80 3D 00 3C 80 3C 80 3D 80",
        "3D 00 3C 80 3B 80 3B 80 3B 40 3D 80 3D 80 3F 80 3F 40 3E 80 3D 80 3C 80 3B 40 3B 80 3A 80 3A 80",
        "3A 40 39 80 3A 80 3A 80 3A 40 3A 80 3A 80 3A 80 39 40 39 80 39 80 39 80 39 40 3A 80 3C 80 3E 80",
        "43 40 45 80 45 80 44 80 43 40 42 80 41 80 41 80 41 40 43 80 44 80 44 80 44 40 44 80 44 80 43 80",
        "43 40 46 80 4A 80 4C 80 4D 40 4C 80 50 80 56 80 5C 40 60 80 61 80 62 80 62 40 61 80 60 80 5E 80",
        "5B 40 59 80 57 80 55 80 54 40 54 80 53 80 53 80 53 40 52 80 52 80 50 80 4E 40 4C 80 4B 80 4B 80",
        "4B 40 4C 80 4B 80 4A 80 49 40 48 80 47 80 46 80 45 40 F6 CE"
    ].joined(separator: " ")

    private let realPage2 = [
        "23 01 2E 39 42 80 40 80 40 80 41 40 42 80 43 80 42 80 41 40 40 80 40 80 40 80 41 40 42 80 42 80",
        "42 80 44 40 45 80 44 80 44 80 42 40 40 80 3E 80 3E 80 3E 40 3E 80 3F 80 3F 80 3F 40 3F 80 40 80",
        "40 80 40 40 41 80 41 80 41 80 41 40 42 80 44 80 46 80 47 40 47 80 46 80 45 80 45 40 44 80 43 80",
        "43 80 42 40 43 80 43 80 44 80 44 40 45 80 44 80 45 80 47 40 48 80 48 80 47 80 45 40 42 80 3F 80",
        "3D 80 3C 40 3C 80 3D 80 3E 80 3F 40 40 80 41 80 43 80 45 40 48 80 4D 80 52 80 54 40 58 80 5A 80",
        "59 80 57 40 55 80 56 80 5A 80 5E 40 60 80 60 80 5F 80 5F 40 5E 80 5D 80 57 80 4E 40 47 80 45 80",
        "44 80 45 40 45 80 46 80 47 80 49 40 4B 80 4E 80 4F 80 51 40 51 80 52 80 50 80 4E 40 4B 80 48 80",
        "44 80 42 40 3F 80 3E 80 3E 80 3E 40 3F 80 40 80 42 80 C0 95"
    ].joined(separator: " ")

    /// A key exchange that has finished with the fixed pair and session keys.
    private func completedKeyExchange() -> AiDexKeyExchange {
        let exchange = AiDexKeyExchange(serial: sensorSerial)
        exchange.onPairKeyReceived(pairKey)
        XCTAssertTrue(exchange.decryptBond(h(bond)))
        return exchange
    }

    // MARK: CRC

    func testCrc8Maxim() {
        XCTAssertEqual(AiDexCrc8Maxim.checksum(Array("123456789".utf8)), 161)
        XCTAssertEqual(AiDexCrc8Maxim.checksum((0..<16).map { UInt8($0) }), 60)
        XCTAssertEqual(AiDexCrc8Maxim.checksum(sessionKey), 138)
        XCTAssertEqual(AiDexCrc8Maxim.checksum([UInt8](repeating: 0xFF, count: 16)), 123)
        XCTAssertEqual(AiDexCrc8Maxim.checksum([]), 0)
        XCTAssertEqual(AiDexCrc8Maxim.checksum([0x00]), 0)
    }

    func testCrc16CcittFalse() {
        XCTAssertEqual(AiDexCrc16.checksum(Array("123456789".utf8)), 10673)
        XCTAssertEqual(AiDexCrc16.checksum([]), 65535)
        XCTAssertEqual(AiDexCrc16.checksum([0x00]), 57840)
        XCTAssertEqual(AiDexCrc16.checksum((0..<16).map { UInt8($0) }), 15159)
        // Vectors from the vendor's own traces.
        XCTAssertEqual(AiDexCrc16.checksum([0x10]), 0xF3C1)
        XCTAssertEqual(AiDexCrc16.checksum([0x11]), 0xE3E0)
        XCTAssertEqual(AiDexCrc16.checksum([0x21]), 0xD5B3)
        XCTAssertEqual(AiDexCrc16.checksum([0xF2]), 0x2EAD)
    }

    func testMakeCommand() {
        XCTAssertEqual(AiDexCrc16.makeCommand(opcode: 0x11), [0x11, 0xE0, 0xE3])
        XCTAssertEqual(AiDexCrc16.makeCommand(opcode: 0x10), [0x10, 0xC1, 0xF3])
        XCTAssertEqual(AiDexCrc16.makeCommand(opcode: 0xF2), [0xF2, 0xAD, 0x2E])
        XCTAssertEqual(AiDexCrc16.makeCommand(opcode: 0x23, params: [0x40, 0x38]), [0x23, 0x40, 0x38, 0x9D, 0xA9])
        XCTAssertEqual(AiDexCrc16.makeCommandWithU16(opcode: 0x23, param: 14400), [0x23, 0x40, 0x38, 0x9D, 0xA9])
        XCTAssertEqual(hexOf(AiDexCrc16.makeCommand(opcode: 0x35, params: [1])), "35014EF7")
        XCTAssertEqual(hexOf(AiDexCrc16.makeCommand(opcode: 0x34, params: [1])), "34017FC4")
        XCTAssertEqual(hexOf(AiDexCrc16.makeCommand(opcode: 0x22)), "22D0E5")
        XCTAssertEqual(hexOf(AiDexCrc16.makeCommand(opcode: 0x24, params: [0x2C, 0x01])), "242C0130C5")
        XCTAssertEqual(hexOf(AiDexCrc16.makeCommand(opcode: 0xF3)), "F38C3E")
        // A parameter is truncated to one byte.
        XCTAssertEqual(AiDexCrc16.makeCommand(opcode: 0x23, params: [0x138]), AiDexCrc16.makeCommand(opcode: 0x23, params: [0x38]))
    }

    func testValidateResponse() {
        let command = AiDexCrc16.makeCommand(opcode: 0x21)
        XCTAssertTrue(AiDexCrc16.validateResponse(command))
        var corrupt = command
        corrupt[0] ^= 0x01
        XCTAssertFalse(AiDexCrc16.validateResponse(corrupt))
        XCTAssertFalse(AiDexCrc16.validateResponse([0x11]))
        XCTAssertFalse(AiDexCrc16.validateResponse([]))
        // The commands the sensor was seen to receive.
        XCTAssertTrue(AiDexCrc16.validateResponse([0x23, 0xB7, 0x38, 0xCB, 0x23]))
        XCTAssertTrue(AiDexCrc16.validateResponse([0x23, 0x2E, 0x39, 0x99, 0x91]))
        XCTAssertTrue(AiDexCrc16.validateResponse([0x23, 0xF8, 0x3B, 0x5A, 0x0E]))
    }

    func testRealPagesCarryAValidCrc() {
        for page in [realPage0, realPage1, realPage2] {
            let data = h(page)
            XCTAssertEqual(data.count, 244)
            XCTAssertTrue(AiDexCrc16.validateResponse(data))
            var corrupt = data
            corrupt[10] ^= 0x01
            XCTAssertFalse(AiDexCrc16.validateResponse(corrupt))
        }
    }

    // MARK: serial identity

    func testCanonicalAndBareSerial() {
        let cases: [(String, String?, String)] = [
            ("AiDEX X-2222267V4E", "X-2222267V4E", "2222267V4E"),
            ("X-2222267V4E", "X-2222267V4E", "2222267V4E"),
            ("2222267V4E", nil, "2222267V4E"),
            ("AiDEX x-2222293NWA", "X-2222293NWA", "2222293NWA"),
            ("AiDEX F-22222FZXKT", "X-22222FZXKT", "22222FZXKT"),
            ("F-22222FZXKT", "X-22222FZXKT", "22222FZXKT"),
            ("Smart-22222BZTJ3", "X-22222BZTJ3", "22222BZTJ3"),
            ("IndiaX-22222E7T6K", "X-22222E7T6K", "22222E7T6K"),
            ("VitaTok-22222DA48D", "X-22222DA48D", "22222DA48D"),
            ("Lumi-2222258CUW", "X-2222258CUW", "2222258CUW"),
            ("Linx X-2222293NWA", "X-2222293NWA", "2222293NWA"),
            ("Dexcom G7", nil, "Dexcom G7"),
            ("Smartwatch-22222BZTJ3", nil, "Smartwatch-22222BZTJ3"),
            ("Q-22222QZXKT", "X-22222QZXKT", "22222QZXKT"),
            ("AiDEX G-22222GZXKT", "X-22222GZXKT", "22222GZXKT"),
            ("12345678901", "X-12345678901", "12345678901"),
            ("Linx 12345678", "X-12345678", "12345678")
        ]
        for (name, canonical, bare) in cases {
            XCTAssertEqual(AiDexSerialIdentity.canonicalFromAdvertisement(name), canonical, name)
            XCTAssertEqual(AiDexSerialIdentity.bareSerial(name), bare, name)
        }
    }

    func testProductBrand() {
        XCTAssertEqual(AiDexSerialIdentity.productBrandFromAdvertisement("Lumi-2222258CUW"), "LUMI")
        XCTAssertNil(AiDexSerialIdentity.productBrandFromAdvertisement("AiDEX X-2222267V4E"))
        XCTAssertNil(AiDexSerialIdentity.productBrandFromAdvertisement("Linx X-2222293NWA"))
        XCTAssertNil(AiDexSerialIdentity.productBrandFromAdvertisement(nil))
        XCTAssertNil(AiDexSerialIdentity.productBrandFromAdvertisement("  "))
    }

    func testFSeriesAdvertisement() {
        XCTAssertTrue(AiDexSerialIdentity.isFSeriesAdvertisement("AiDEX F-22222FZXKT"))
        XCTAssertTrue(AiDexSerialIdentity.isFSeriesAdvertisement("F-22222FZXKT"))
        XCTAssertTrue(AiDexSerialIdentity.isFSeriesAdvertisement("aidex f-22222fzxkt"))
        XCTAssertFalse(AiDexSerialIdentity.isFSeriesAdvertisement("AiDEX X-2222267V4E"))
        XCTAssertFalse(AiDexSerialIdentity.isFSeriesAdvertisement("Smart-22222BZTJ3"))
        XCTAssertFalse(AiDexSerialIdentity.isFSeriesAdvertisement("IndiaX-22222E7T6K"))
        XCTAssertFalse(AiDexSerialIdentity.isFSeriesAdvertisement("AiDEX F-2222"))
        XCTAssertFalse(AiDexSerialIdentity.isFSeriesAdvertisement(""))
        XCTAssertTrue(AiDexKeyRequirement.requiresProvisionedKeys(advertisedName: "AiDEX F-22222FZXKT"))
        XCTAssertFalse(AiDexKeyRequirement.requiresProvisionedKeys(advertisedName: "AiDEX X-2222267V4E"))
        XCTAssertFalse(AiDexKeyRequirement.requiresProvisionedKeys(advertisedName: nil))
    }

    func testDeviceNameMatchesSerial() {
        XCTAssertTrue(AiDexSerialIdentity.deviceNameMatchesSerial(deviceName: "AiDEX x-2222293NWA", serial: "X-2222293NWA"))
        XCTAssertTrue(AiDexSerialIdentity.deviceNameMatchesSerial(deviceName: "aidex x-2222293nwa", serial: "X-2222293NWA"))
        XCTAssertTrue(AiDexSerialIdentity.deviceNameMatchesSerial(deviceName: "AiDEX X-2222293NWA", serial: "2222293NWA"))
        XCTAssertFalse(AiDexSerialIdentity.deviceNameMatchesSerial(deviceName: "AiDEX x-2222293NWA", serial: "X-222228AWH2"))
    }

    func testAdvertisementNamePrefixes() {
        for name in ["AiDEX X-2222267V4E", "AiDEX X-22222689WH", "Smart-22222BZTJ3", "IndiaX-22222E7T6K", "VitaTok-22222DA48D"] {
            XCTAssertTrue(AiDexOpcodes.isAiDexDevice(name: name), name)
        }
        for name in ["Dexcom G7", "Smartwatch-22222BZTJ3", ""] {
            XCTAssertFalse(AiDexOpcodes.isAiDexDevice(name: name), name)
        }
        XCTAssertFalse(AiDexOpcodes.isAiDexDevice(name: nil))
    }

    // MARK: serial-derived secret and IV

    func testCharToNumeric() {
        let expected: [(Character, Int)] = [
            ("0", 0), ("9", 9), ("A", 10), ("Z", 35), ("a", 10), ("z", 35),
            ("-", 0), (" ", 0), ("/", 0), (":", 0), ("@", 0), ("[", 0), ("`", 0), ("{", 0)
        ]
        for (character, value) in expected {
            let unit = String(character).utf16.first ?? 0
            XCTAssertEqual(AiDexSerialCrypto.charToNumeric(unit), value, String(character))
        }
    }

    func testSnToBytes() {
        XCTAssertEqual(hexOf(AiDexSerialCrypto.snToBytes("2222267V4E")), "020202020206071F040E")
        XCTAssertEqual(hexOf(AiDexSerialCrypto.snToBytes("22222abcXYZ")), "02020202020A0B0C212223")
    }

    func testSecretAndIvVectors() {
        let vectors: [(String, String, String)] = [
            ("2222267V4E", "4B76169576DA80E4EEACF886230873D2", "14CB6A3A39B96C448EBC39185F70F8AA"),
            ("22222FZXKT", "F0740DC2FA51F24A884F61FC4C14885B", "1D573ACE39CF1D9AB98178E6006AAFFD"),
            ("22222BZTJ3", "E8016728126EF9D4E1E4FAE30843CE6A", "99B9EC441298B062F3CF2694CC6694F5"),
            ("22222E7T6K", "A697A4333A1073F63F0766F3A9041216", "1B1EF3EB28F61DBBB6DFB6FBDDD6FF03"),
            ("22222DA48D", "3FF6677946B4ADA991BF3D4F273FFD20", "2C96BE74CCB770FFBAF2B6FED2046B33"),
            ("22222689WH", "91C5470280BB4C3D8FA8EDB1B06A0F06", "9813BF93DE83F013DD2DAD93507DCB89"),
            ("2222293NWA", "A5F5DD7C2131E005D05427EB23ED1341", "1AB5688310B9B1AA791BDA9A3256F908"),
            ("22222abcXYZ", "748017D9F646504337E734819329C34B", "BE9C6E1B4A7E5980585A7BA14FA690CC")
        ]
        for (serial, secret, iv) in vectors {
            XCTAssertEqual(hexOf(AiDexSerialCrypto.deriveSecret(serial)), secret, serial)
            XCTAssertEqual(hexOf(AiDexSerialCrypto.deriveIv(serial)), iv, serial)
        }
    }

    func testMd5() {
        // RFC 1321 test vector
        XCTAssertEqual(hexOf(AiDexCrypto.md5(Array("abc".utf8))), "900150983CD24FB0D6963F7D28E17F72")
        XCTAssertEqual(hexOf(AiDexCrypto.md5([])), "D41D8CD98F00B204E9800998ECF8427E")
    }

    // MARK: AES-128-CFB

    private let nistKey = AiDexParser.bytes(fromHex: "2b7e151628aed2a6abf7158809cf4f3c")
    private let nistIv = AiDexParser.bytes(fromHex: "000102030405060708090a0b0c0d0e0f")
    private let nistPlain = AiDexParser.bytes(fromHex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
    private let nistCipher = "3B3FD92EB72DAD20333449F8E83CFB4AC8A64537A0B3A93FCDE3CDAD9F1CE58B26751F67A3CBB140B1808CF187A4F4DFC04B05357C5D1C0EEAC4C66F9FF7F2E6"

    func testNistCfb128FourBlocks() {
        // NIST SP 800-38A F.3.13
        XCTAssertEqual(hexOf(AiDexCrypto.cfbEncrypt(nistPlain, key: nistKey, iv: nistIv)), nistCipher)
        XCTAssertEqual(AiDexCrypto.cfbDecrypt(h(nistCipher), key: nistKey, iv: nistIv), nistPlain)
    }

    func testPartialBlockPrefixes() {
        XCTAssertEqual(hexOf(AiDexCrypto.cfbEncrypt(Array(nistPlain.prefix(17)), key: nistKey, iv: nistIv)), "3B3FD92EB72DAD20333449F8E83CFB4AC8")
        XCTAssertEqual(hexOf(AiDexCrypto.cfbEncrypt(Array(nistPlain.prefix(5)), key: nistKey, iv: nistIv)), "3B3FD92EB7")
        XCTAssertEqual(hexOf(AiDexCrypto.cfbEncrypt(Array(nistPlain.prefix(33)), key: nistKey, iv: nistIv)),
                       "3B3FD92EB72DAD20333449F8E83CFB4AC8A64537A0B3A93FCDE3CDAD9F1CE58B26")
        for length in [1, 5, 15, 16, 17, 31, 32, 33, 47, 64] {
            let plain = Array(nistPlain.prefix(length))
            guard let encrypted = AiDexCrypto.cfbEncrypt(plain, key: nistKey, iv: nistIv) else { return XCTFail("encrypt \(length)") }
            XCTAssertEqual(encrypted.count, length)
            XCTAssertEqual(AiDexCrypto.cfbDecrypt(encrypted, key: nistKey, iv: nistIv), plain, "length \(length)")
        }
    }

    func testEcbBlockAndInvalidInput() {
        XCTAssertEqual(hexOf(AiDexCrypto.ecbEncrypt(block: nistIv, key: nistKey)), "50FE67CC996D32B6DA0937E99BAFEC60")
        XCTAssertNil(AiDexCrypto.ecbEncrypt(block: [1, 2, 3], key: nistKey))
        XCTAssertNil(AiDexCrypto.ecbEncrypt(block: nistIv, key: [1, 2, 3]))
        XCTAssertNil(AiDexCrypto.cfbEncrypt([], key: nistKey, iv: nistIv))
        XCTAssertNil(AiDexCrypto.cfbEncrypt(nistPlain, key: [UInt8](repeating: 0, count: 15), iv: nistIv))
        XCTAssertNil(AiDexCrypto.cfbDecrypt(nistPlain, key: nistKey, iv: [UInt8](repeating: 0, count: 17)))
        let wrongKey = [UInt8](repeating: 0xFF, count: 16)
        XCTAssertNotEqual(AiDexCrypto.cfbDecrypt(h(nistCipher), key: wrongKey, iv: nistIv), nistPlain)
    }

    // MARK: BOND and key exchange

    func testBondDecryption() {
        let iv = AiDexSerialCrypto.deriveIv("2222267V4E")
        XCTAssertEqual(AiDexCrypto.decryptBondData(h(bond), pairKey: pairKey, iv: iv), sessionKey)
        // Wrong CRC byte, wrong pair key, wrong length.
        XCTAssertNil(AiDexCrypto.decryptBondData(h(badBond), pairKey: pairKey, iv: iv))
        XCTAssertNil(AiDexCrypto.decryptBondData(h(bond), pairKey: [UInt8](repeating: 0x55, count: 16), iv: iv))
        XCTAssertNil(AiDexCrypto.decryptBondData(Array(h(bond).prefix(16)), pairKey: pairKey, iv: iv))
        XCTAssertNil(AiDexCrypto.decryptBondData([0x00], pairKey: pairKey, iv: iv))
    }

    func testKeyExchangeStateMachine() {
        let exchange = AiDexKeyExchange(serial: sensorSerial)
        XCTAssertEqual(exchange.bareSerial, "2222267V4E")
        XCTAssertEqual(hexOf(exchange.snSecret), "4B76169576DA80E4EEACF886230873D2")
        XCTAssertEqual(hexOf(exchange.snIv), "14CB6A3A39B96C448EBC39185F70F8AA")
        XCTAssertEqual(exchange.getChallenge(), exchange.snSecret)
        XCTAssertFalse(exchange.isComplete)
        XCTAssertNil(exchange.pairKey)
        XCTAssertNil(exchange.sessionKey)
        // Nothing can be encrypted, decrypted or built before a session key exists.
        XCTAssertNil(exchange.encrypt([0x10, 0xC1, 0xF3]))
        XCTAssertNil(exchange.decrypt([0x10, 0xC1, 0xF3]))
        XCTAssertNil(exchange.getPostBondConfig())
        // BOND before the PAIR key cannot be decrypted.
        XCTAssertFalse(exchange.decryptBond(h(bond)))

        exchange.onPairKeyReceived(pairKey)
        XCTAssertEqual(exchange.pairKey, pairKey)
        XCTAssertFalse(exchange.decryptBond(h(badBond)))
        XCTAssertFalse(exchange.isComplete)
        XCTAssertTrue(exchange.decryptBond(h(bond)))
        XCTAssertTrue(exchange.isComplete)
        XCTAssertEqual(exchange.sessionKey, sessionKey)
        XCTAssertEqual(hexOf(exchange.getPostBondConfig()), "222EFF")
        XCTAssertEqual(exchange.decrypt(exchange.encrypt([1, 2, 3, 4, 5]) ?? []), [1, 2, 3, 4, 5])

        exchange.reset()
        XCTAssertNil(exchange.pairKey)
        XCTAssertNil(exchange.sessionKey)
        XCTAssertFalse(exchange.isComplete)
    }

    func testEveryNameFormGivesTheSameSecretAndIv() {
        let bare = AiDexKeyExchange(serial: "2222267V4E")
        for name in ["X-2222267V4E", "AiDEX X-2222267V4E", "aidex x-2222267v4e"] {
            let other = AiDexKeyExchange(serial: name)
            XCTAssertEqual(other.bareSerial, "2222267V4E", name)
            XCTAssertEqual(other.snSecret, bare.snSecret, name)
            XCTAssertEqual(other.snIv, bare.snIv, name)
        }
        // Rebranded names derive from the bare serial, never from the label.
        let smart = AiDexKeyExchange(serial: "Smart-22222BZTJ3")
        XCTAssertEqual(smart.bareSerial, "22222BZTJ3")
        XCTAssertEqual(hexOf(smart.getChallenge()), "E8016728126EF9D4E1E4FAE30843CE6A")
        let fSeries = AiDexKeyExchange(serial: "AiDEX F-22222FZXKT")
        XCTAssertEqual(hexOf(fSeries.getChallenge()), "F0740DC2FA51F24A884F61FC4C14885B")
    }

    // MARK: command builder

    func testCommandBuilderNeedsASessionKey() {
        let builder = AiDexCommandBuilder(keyExchange: AiDexKeyExchange(serial: sensorSerial))
        XCTAssertNil(builder.getStartupDeviceInfo())
        XCTAssertNil(builder.getBroadcastData())
        XCTAssertNil(builder.getHistoryRange())
        XCTAssertNil(builder.getHistoriesRaw(offset: 14400))
        XCTAssertNil(builder.getHistories(offset: 14400))
        XCTAssertNil(builder.setAutoUpdateStatus(enabled: true))
        XCTAssertNil(builder.setDynamicAdvMode(1))
        XCTAssertNil(builder.deleteBond())
        XCTAssertNil(builder.reset())
    }

    func testEncryptedCommands() {
        let exchange = completedKeyExchange()
        let builder = AiDexCommandBuilder(keyExchange: exchange)
        let expected: [(String, [UInt8]?, String)] = [
            ("startupDeviceInfo", builder.getStartupDeviceInfo(), "222EFF"),
            ("legacyStartTime", builder.getLegacyStartTime(), "135CD9"),
            ("broadcast", builder.getBroadcastData(), "230FEF"),
            ("sensorCheck", builder.getSensorCheck(), "00EED50E"),
            ("sensorCheck(5)", builder.getSensorCheck(index: 5), "00EA514E"),
            ("autoUpdateStatus", builder.getAutoUpdateStatus(), "012FEB"),
            ("historyRange", builder.getHistoryRange(), "103FE9"),
            ("historiesRaw(14400)", builder.getHistoriesRaw(offset: 14400), "11AF34FD00"),
            ("histories(300)", builder.getHistories(offset: 300), "16C30D506C"),
            ("setNewSensor", builder.setNewSensor(year: 2026, month: 7, day: 1, hour: 12, minute: 0, second: 0, tzQuarters: 4, dstQuarters: 4), "12050B67A8E8CE3B7AE5ADE1"),
            ("setNewSensor negative zone", builder.setNewSensor(year: 2027, month: 1, day: 15, hour: 8, minute: 30, second: 5, tzQuarters: -20, dstQuarters: 0), "12040B61A6ECD03E92E19C29"),
            ("setCalibration", builder.setCalibration(offsetMinutes: 1234, glucoseMgDl: 110), "173D080EA98545"),
            ("calibrationRange", builder.getCalibrationRange(), "14BBA9"),
            ("calibration(3)", builder.getCalibration(index: 3), "15EC0CF933"),
            ("setAutoUpdate(true)", builder.setAutoUpdateStatus(enabled: true), "06EE73A4"),
            ("setAutoUpdate(false)", builder.setAutoUpdateStatus(enabled: false), "06EF52B4"),
            ("setDynamicAdv(1)", builder.setDynamicAdvMode(1), "07EE4297"),
            ("deleteBond", builder.deleteBond(), "C04222"),
            ("reset", builder.reset(), "C20002"),
            ("clearStorage", builder.clearStorage(), "C16332"),
            ("shelfMode", builder.shelfMode(), "C32112")
        ]
        for (name, bytes, hex) in expected {
            XCTAssertEqual(hexOf(bytes), hex, name)
        }
    }

    func testCommandPlaintextCarriesItsCrc() {
        let exchange = completedKeyExchange()
        let builder = AiDexCommandBuilder(keyExchange: exchange)
        guard let encrypted = builder.getHistoriesRaw(offset: 14400), let plain = exchange.decrypt(encrypted) else {
            return XCTFail("history command")
        }
        XCTAssertEqual(plain, [0x23, 0x40, 0x38, 0x9D, 0xA9])
        XCTAssertTrue(AiDexCrc16.validateResponse(plain))
        guard let setNew = builder.setNewSensor(year: 2026, month: 7, day: 1, hour: 12, minute: 0, second: 0, tzQuarters: 4, dstQuarters: 4),
              let setNewPlain = exchange.decrypt(setNew) else { return XCTFail("setNewSensor") }
        XCTAssertEqual(Array(setNewPlain.prefix(10)), [0x20, 0xEA, 0x07, 7, 1, 12, 0, 0, 4, 4])
        XCTAssertTrue(AiDexCrc16.validateResponse(setNewPlain))
    }

    // MARK: live frames

    func testDocumentedLiveFrame() {
        // 01 00 02 00 2B 00 3F 84 4F 03 86 0B 43 02 00 7D CE from a captured session.
        let bytes = h("01 00 02 00 2B 00 3F 84 4F 03 86 0B 43 02 00 7D CE")
        guard let frame = AiDexParser.parseDataFrame(bytes) else { return XCTFail("frame") }
        XCTAssertEqual(frame.opcode, 0x01)
        XCTAssertEqual(frame.timeOffsetMinutes, 43)
        XCTAssertEqual(frame.rawGlucosePacked, 0x843F)
        XCTAssertEqual(frame.glucoseMgDl, 63, accuracy: 0.01)
        XCTAssertEqual(frame.i1, 8.47, accuracy: 0.001)
        XCTAssertEqual(frame.i2, 29.5, accuracy: 0.001)
        XCTAssertEqual(frame.crc16, 0xCE7D)
        XCTAssertTrue(frame.isValid)
        XCTAssertEqual(frame.temperatureC, 29.5, accuracy: 0.001)
        XCTAssertTrue(AiDexParser.dataFrameCrcMatches(bytes, frame: frame))
        var tampered = bytes
        tampered[6] ^= 0x01
        if let changed = AiDexParser.parseDataFrame(tampered) {
            XCTAssertFalse(AiDexParser.dataFrameCrcMatches(tampered, frame: changed))
        }
    }

    func testEncryptedLiveFramesDecryptAndParse() {
        let exchange = completedKeyExchange()
        let cases: [(String, String, Int, Int, Float, Float, Bool)] = [
            // plaintext, ciphertext, opcode, offset, glucose, i2, valid
            ("A18403FF780069004F03350C112233D9B9", "936B0F9FD1E4A73B31E23401AFAB6B905F", 0xA1, 120, 105, 31.25, true),
            ("D2000000ED08BE800000540D000000B155", "E0EF0C6044EC70BB7EE15500BE8958F89B", 0xD2, 2285, 95, 34.12, true),
            ("A40000000700FF0305000600000000A0C5", "96EF0C60AEE431387BE1070DBE8958E968", 0xA4, 7, 1023, 0.06, false)
        ]
        for (plain, cipher, opcode, offset, glucose, temperature, valid) in cases {
            XCTAssertEqual(hexOf(exchange.encrypt(h(plain))), cipher)
            guard let decrypted = exchange.decrypt(h(cipher)) else { return XCTFail("decrypt") }
            XCTAssertEqual(decrypted, h(plain))
            guard let frame = AiDexParser.parseDataFrame(decrypted) else { return XCTFail("parse") }
            XCTAssertEqual(frame.opcode, opcode)
            XCTAssertEqual(frame.timeOffsetMinutes, offset)
            XCTAssertEqual(frame.glucoseMgDl, glucose, accuracy: 0.001)
            XCTAssertEqual(frame.i2, temperature, accuracy: 0.001)
            XCTAssertEqual(frame.isValid, valid)
            XCTAssertTrue(AiDexParser.dataFrameCrcMatches(decrypted, frame: frame))
        }
    }

    func testFrameClassification() {
        XCTAssertEqual(AiDexParser.classifyFrame([UInt8](repeating: 0, count: 17)), .data)
        XCTAssertEqual(AiDexParser.classifyFrame([UInt8](repeating: 0, count: 5)), .status)
        XCTAssertEqual(AiDexParser.classifyFrame([UInt8](repeating: 0, count: 10)), .unknown)
        XCTAssertEqual(AiDexParser.classifyFrame([]), .unknown)
        XCTAssertNil(AiDexParser.parseDataFrame([1, 2, 3]))
        XCTAssertNil(AiDexParser.parseDataFrame([UInt8](repeating: 0, count: 16)))
        XCTAssertNil(AiDexParser.parseDataFrame([UInt8](repeating: 0, count: 18)))
    }

    private func frame(opcode: UInt8, packed: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 17)
        bytes[0] = opcode
        bytes[6] = UInt8(packed & 0xFF)
        bytes[7] = UInt8((packed >> 8) & 0xFF)
        return bytes
    }

    func testGlucoseScalingAndValidity() {
        XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0xA1, packed: 77))?.glucoseMgDl, 77)
        XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0x5B, packed: 77))?.glucoseMgDl, 77)
        XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0xD7, packed: 77))?.glucoseMgDl, 77)
        XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0xD2, packed: 77))?.glucoseMgDl, 38.5)
        XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0xD2, packed: 100))?.glucoseMgDl, 50)
        // An unknown opcode is used unscaled.
        XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0x01, packed: 77))?.glucoseMgDl, 77)
        XCTAssertEqual(AiDexOpcodes.scalingFactor(opcode: 0xA4), 1.0)
        XCTAssertEqual(AiDexOpcodes.scalingFactor(opcode: 0xD2), 0.5)
        XCTAssertNil(AiDexOpcodes.scalingFactor(opcode: 0x00))
        XCTAssertNil(AiDexOpcodes.scalingFactor(opcode: 0xFF))

        let validity: [(Int, Bool)] = [(19, false), (20, true), (500, true), (501, false), (1022, false), (1023, false)]
        for (glucose, valid) in validity {
            XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0xA1, packed: glucose))?.isValid, valid, "\(glucose)")
        }
        // Only the low ten bits are glucose; the rest is flags.
        XCTAssertEqual(AiDexParser.parseDataFrame(frame(opcode: 0xA1, packed: 0xFC00 | 90))?.glucoseMgDl, 90)
    }

    func testOffsetUsesBothBytes() {
        var bytes = frame(opcode: 0xA1, packed: 80)
        bytes[1] = 0x84
        bytes[2] = 0x03
        bytes[3] = 0xFF
        bytes[4] = 0xED
        bytes[5] = 0x08
        XCTAssertEqual(AiDexParser.parseDataFrame(bytes)?.timeOffsetMinutes, 2285)
    }

    // MARK: history pages

    func testRealHistoryPages() {
        // (page, rows, first offset, first glucose, last offset, last glucose, sum, max, min)
        let expected: [(String, Int, Int, Int, Int, Int, Int, Int, Int)] = [
            (realPage0, 119, 14400, 66, 14518, 63, 7461, 73, 59),
            (realPage1, 119, 14519, 65, 14637, 69, 8197, 98, 57),
            (realPage2, 119, 14638, 66, 14756, 66, 8422, 96, 60)
        ]
        for (index, page) in expected.enumerated() {
            let full = h(page.0)
            // The payload is everything between the opcode/status pair and the CRC.
            let payload = Array(full[2..<(full.count - 2)])
            let rows = AiDexParser.parseHistoryResponse(payload)
            XCTAssertEqual(rows.count, page.1, "page \(index)")
            XCTAssertEqual(rows.first?.timeOffsetMinutes, page.2)
            XCTAssertEqual(rows.first?.glucoseMgDl, page.3)
            XCTAssertEqual(rows.last?.timeOffsetMinutes, page.4)
            XCTAssertEqual(rows.last?.glucoseMgDl, page.5)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.glucoseMgDl }, page.6)
            XCTAssertEqual(rows.map { $0.glucoseMgDl }.max(), page.7)
            XCTAssertEqual(rows.map { $0.glucoseMgDl }.min(), page.8)
            XCTAssertEqual(rows.filter { $0.statusBit }.count, 0)
            XCTAssertEqual(rows.filter { $0.isSentinel }.count, 0)
            var cache: [Int: Int] = [:]
            let counts = AiDexHistoryMerge.cacheCalibratedEntries(rows, cache: &cache)
            XCTAssertEqual(counts.cached, 119)
            XCTAssertEqual(counts.skipped, 0)
            XCTAssertEqual(cache.count, 119)
        }
    }

    func testHistoryRowDecoding() {
        let rows = AiDexParser.parseHistoryResponse(h("40 38 42 80 42 40 41 80 3F 80"))
        XCTAssertEqual(rows.map { $0.timeOffsetMinutes }, [14400, 14401, 14402, 14403])
        XCTAssertEqual(rows.map { $0.glucoseMgDl }, [66, 66, 65, 63])
        // 0x84 carries the status bit (0x04); 0x80 does not.
        let flagged = AiDexParser.parseHistoryResponse(h("00 00 42 84 42 80"))
        XCTAssertEqual(flagged.map { $0.statusBit }, [true, false])
        // 1023 is the "no reading" sentinel.
        let sentinel = AiDexParser.parseHistoryResponse(h("00 00 FF 03"))
        XCTAssertEqual(sentinel.count, 1)
        XCTAssertTrue(sentinel[0].isSentinel)
        XCTAssertEqual(sentinel[0].glucoseMgDl, 1023)
        // Too short, and an odd trailing byte is dropped.
        XCTAssertEqual(AiDexParser.parseHistoryResponse([]).count, 0)
        XCTAssertEqual(AiDexParser.parseHistoryResponse([0x00]).count, 0)
        XCTAssertEqual(AiDexParser.parseHistoryResponse([0x00, 0x00, 0x00]).count, 0)
        XCTAssertEqual(AiDexParser.parseHistoryResponse(h("00 00 42 80 FF")).count, 1)
    }

    func testBriefHistory() {
        // Rows: (8.47, 29.50, 0.50), an all-zero row that is dropped, (10.00, 100.00, 0.05).
        let page = h("2C01 4F03860B32 0000000000 E8031027 05")
        XCTAssertEqual(page.count, 17)
        let rows = AiDexParser.parseBriefHistoryResponse(page)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].timeOffsetMinutes, 300)
        XCTAssertEqual(rows[0].i1, 8.47, accuracy: 0.001)
        XCTAssertEqual(rows[0].i2, 29.5, accuracy: 0.001)
        XCTAssertEqual(rows[0].vc, 0.5, accuracy: 0.001)
        XCTAssertEqual(rows[0].rawValue, 84.7, accuracy: 0.01)
        XCTAssertEqual(rows[0].sensorGlucose, 152.61415, accuracy: 0.01)
        XCTAssertEqual(rows[0].temperatureC, 29.5, accuracy: 0.001)
        XCTAssertEqual(rows[1].timeOffsetMinutes, 302)
        XCTAssertEqual(rows[1].i1, 10, accuracy: 0.001)
        XCTAssertEqual(rows[1].i2, 100, accuracy: 0.001)
        XCTAssertEqual(rows[1].vc, 0.05, accuracy: 0.001)
        XCTAssertEqual(rows[1].rawValue, 100, accuracy: 0.001)
        XCTAssertEqual(rows[1].sensorGlucose, 180.182, accuracy: 0.01)
        // The page end counts the dropped row.
        XCTAssertEqual(AiDexParser.briefHistoryPageEnd(page), 303)
        XCTAssertNil(AiDexParser.briefHistoryPageEnd([UInt8](repeating: 0, count: 6)))
        XCTAssertNil(AiDexParser.briefHistoryPageEnd([UInt8](repeating: 0, count: 2)))
        // Too short
        XCTAssertEqual(AiDexParser.parseBriefHistoryResponse([]).count, 0)
        XCTAssertEqual(AiDexParser.parseBriefHistoryResponse([0x00]).count, 0)
        XCTAssertEqual(AiDexParser.parseBriefHistoryResponse([UInt8](repeating: 0, count: 6)).count, 0)
        XCTAssertEqual(AiDexParser.parseBriefHistoryResponse([UInt8](repeating: 0, count: 7)).count, 0)
    }

    func testCalibrationRecords() {
        let records = AiDexParser.parseCalibrationResponse(h("0100 6400 7800 9600 3200 6500 6E00 C800 F6FF"))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].index, 1)
        XCTAssertEqual(records[0].timeOffsetMinutes, 100)
        XCTAssertEqual(records[0].referenceGlucoseMgDl, 120)
        XCTAssertEqual(records[0].calibrationFactor, 1.5, accuracy: 0.001)
        XCTAssertEqual(records[0].calibrationOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(records[1].index, 2)
        XCTAssertEqual(records[1].referenceGlucoseMgDl, 110)
        XCTAssertEqual(records[1].calibrationFactor, 2.0, accuracy: 0.001)
        XCTAssertEqual(records[1].calibrationOffset, -0.1, accuracy: 0.001)
        XCTAssertEqual(AiDexParser.parseCalibrationResponse([]).count, 0)
        XCTAssertEqual(AiDexParser.parseCalibrationResponse([UInt8](repeating: 0, count: 9)).count, 0)
        XCTAssertEqual(AiDexParser.parseCalibrationResponse([0x12, 0x27] + [UInt8](repeating: 0, count: 8)).count, 0)
        XCTAssertEqual(AiDexParser.parseCalibrationResponse([UInt8](repeating: 0, count: 11)).count, 0)
    }

    // MARK: startup info and session start

    func testStartupDeviceInfo() {
        let vendor = AiDexParser.parseStartupDeviceInfoPayload(h("0000010701030F0047582D3031530000"))
        XCTAssertEqual(vendor, AiDexStartupDeviceInfo(firmwareVersion: "1.7", hardwareVersion: "1.3", wearDays: 15, modelName: "GX-01S"))
        let sixteenDay = AiDexParser.parseStartupDeviceInfoPayload(h("000001080201100047582D3031530000"))
        XCTAssertEqual(sixteenDay, AiDexStartupDeviceInfo(firmwareVersion: "1.8", hardwareVersion: "2.1", wearDays: 16, modelName: "GX-01S"))

        // A whole frame: opcode first.
        let framed = AiDexParser.parseStartupDeviceInfoFrame(h("100000010701030F0047582D3031530000"))
        XCTAssertEqual(framed, vendor)
        // A live Lumi sensor: ACK byte 0x01, then a non-zero model code.
        let lumi = AiDexParser.parseStartupDeviceInfoFrame(h("1001008001070103100047582D3031530000"))
        XCTAssertEqual(lumi, AiDexStartupDeviceInfo(firmwareVersion: "1.7", hardwareVersion: "1.3", wearDays: 16, modelName: "GX-01S"))
        // The same reply without the ACK byte, a model that is not text, and a frame too short.
        XCTAssertNil(AiDexParser.parseStartupDeviceInfoFrame(h("1002008001070103100047582D3031530000")))
        XCTAssertNil(AiDexParser.parseStartupDeviceInfoFrame(h("100100800107010310000102030405060000")))
        XCTAssertNil(AiDexParser.parseStartupDeviceInfoFrame(h("10")))
        XCTAssertNil(AiDexParser.parseStartupDeviceInfoPayload([0x00, 0x00]))
    }

    func testSessionStartParsing() {
        let parsed = AiDexParser.parseLocalStartTimePayload([0xEA, 0x07, 0x02, 0x1C, 0x13, 0x25, 0x05, 0x14, 0x00])
        XCTAssertEqual(parsed, AiDexLocalStartTime(year: 2026, month: 2, day: 28, hour: 19, minute: 37, second: 5, tzQuarters: 20, dstQuarters: 0))
        XCTAssertEqual(parsed?.isAllZeros, false)
        // The zone is signed, the daylight part is not.
        let negative = AiDexParser.parseLocalStartTimePayload([0xEA, 0x07, 0x07, 0x01, 0x0C, 0x00, 0x00, 0xE4, 0x04])
        XCTAssertEqual(negative?.tzQuarters, -28)
        XCTAssertEqual(negative?.dstQuarters, 4)
        // Zone fields are optional.
        let short = AiDexParser.parseLocalStartTimePayload([0xEA, 0x07, 0x02, 0x1C, 0x13, 0x25, 0x05])
        XCTAssertEqual(short?.tzQuarters, 0)
        XCTAssertEqual(short?.dstQuarters, 0)
        // All zeros is a sensor that was never started.
        XCTAssertEqual(AiDexParser.parseLocalStartTimePayload([UInt8](repeating: 0, count: 9))?.isAllZeros, true)
        // The startup info reply is not a date.
        XCTAssertNil(AiDexParser.parseLocalStartTimePayload(h("0000010701030F0047582D3031530000")))
        XCTAssertNil(AiDexParser.parseLocalStartTimePayload([0xEA, 0x07, 0x0D, 0x1C, 0x13, 0x25, 0x05, 0, 0]))
        XCTAssertNil(AiDexParser.parseLocalStartTimePayload([0xEA, 0x07, 0x02]))
    }

    func testSessionStartInstant() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(AiDexLocalStartTime, TimeInterval)] = [
            (AiDexLocalStartTime(year: 2026, month: 2, day: 28, hour: 19, minute: 37, second: 5, tzQuarters: 20, dstQuarters: 0), 1_772_289_425),
            (AiDexLocalStartTime(year: 2026, month: 7, day: 1, hour: 12, minute: 0, second: 0, tzQuarters: 4, dstQuarters: 4), 1_782_900_000),
            (AiDexLocalStartTime(year: 2027, month: 1, day: 15, hour: 8, minute: 30, second: 5, tzQuarters: -20, dstQuarters: 0), 1_800_019_805),
            // Only a daylight part of exactly four quarters counts.
            (AiDexLocalStartTime(year: 2026, month: 7, day: 1, hour: 12, minute: 0, second: 0, tzQuarters: 4, dstQuarters: 2), 1_782_903_600),
            (AiDexLocalStartTime(year: 2026, month: 7, day: 1, hour: 12, minute: 0, second: 0, tzQuarters: 0, dstQuarters: 0), 1_782_907_200)
        ]
        for (start, epoch) in cases {
            XCTAssertEqual(start.date(now: now)?.timeIntervalSince1970, epoch)
        }
        XCTAssertEqual(AiDexLocalStartTime(year: 2026, month: 7, day: 1, hour: 12, minute: 0, second: 0, tzQuarters: 4, dstQuarters: 4).utcOffsetSeconds, 7200)
        // All zeros and a start more than a day ahead have no instant.
        XCTAssertNil(AiDexLocalStartTime(year: 0, month: 0, day: 0, hour: 0, minute: 0, second: 0, tzQuarters: 0, dstQuarters: 0).date(now: now))
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(cases[0].0.date(now: early))
    }

    func testActivationTimeZone() {
        let summer = Date(timeIntervalSince1970: 1_782_907_200)
        let winter = Date(timeIntervalSince1970: 1_768_478_400)
        let cases: [(String, Date, Int, Int)] = [
            ("Europe/Berlin", summer, 4, 4),
            ("Europe/Berlin", winter, 4, 0),
            ("America/New_York", summer, -20, 4),
            ("Asia/Kolkata", summer, 22, 0),
            ("UTC", summer, 0, 0),
            ("Australia/Lord_Howe", winter, 42, 2)
        ]
        for (identifier, date, tz, dst) in cases {
            guard let zone = TimeZone(identifier: identifier) else { return XCTFail(identifier) }
            XCTAssertEqual(AiDexActivationTimeZone.make(date: date, timeZone: zone), AiDexActivationTimeZone(tzQuarters: tz, dstQuarters: dst), identifier)
        }
    }

    func testHexHelpers() {
        XCTAssertEqual(AiDexParser.hexString([0x01, 0xAB, 0xFF, 0x00]), "01 AB FF 00")
        XCTAssertEqual(AiDexParser.compactHex([0x01, 0xAB, 0xFF, 0x00]), "01ABFF00")
        XCTAssertEqual(AiDexParser.bytes(fromHex: "01 AB FF 00"), [0x01, 0xAB, 0xFF, 0x00])
        XCTAssertEqual(AiDexParser.bytes(fromHex: "01abff00"), [0x01, 0xAB, 0xFF, 0x00])
        XCTAssertTrue(AiDexParser.isHandshakeEcho(sent: [0x6F, 0x01], received: [0x6F, 0xAA]))
        XCTAssertFalse(AiDexParser.isHandshakeEcho(sent: [0x6F, 0x01], received: [0x70, 0xAA]))
        XCTAssertFalse(AiDexParser.isHandshakeEcho(sent: [], received: []))
    }

    // MARK: history merge

    private func adc(_ offset: Int, i1: Float = 5.0, i2: Float = 10.0, vc: Float = 0.5) -> AiDexAdcHistoryEntry {
        return AiDexAdcHistoryEntry(timeOffsetMinutes: offset, i1: i1, i2: i2, vc: vc, rawValue: i1 * 10, sensorGlucose: i1 * 18.0182)
    }

    private func calibrated(_ offset: Int, _ glucose: Int, sentinel: Bool = false) -> AiDexCalibratedHistoryEntry {
        return AiDexCalibratedHistoryEntry(timeOffsetMinutes: offset, glucoseMgDl: glucose, statusBit: false, isSentinel: sentinel)
    }

    func testMergeTakesLastKnownGlucoseForGaps() {
        var cache: [Int: Int] = [100: 80, 103: 95]
        let result = AiDexHistoryMerge.mergeHistoryEntries((100...105).map { adc($0) }, calibratedCache: &cache, initialFallback: nil)
        XCTAssertEqual(result.mergedCount, 2)
        XCTAssertEqual(result.fallbackCount, 4)
        XCTAssertEqual(result.noGlucoseCount, 0)
        XCTAssertEqual(result.lastKnownGlucose, 95)
        XCTAssertEqual(result.entries.map { $0.glucoseMgDl }, [80, 80, 80, 95, 95, 95])
        XCTAssertEqual(result.entries.map { $0.rawMgDl }, [50, 50, 50, 50, 50, 50])
        // Matched rows leave the cache.
        XCTAssertTrue(cache.isEmpty)
    }

    func testMergeRawValueValidityAndTemperature() {
        var cache: [Int: Int] = [100: 80]
        let rows = [adc(100, i1: 135), adc(101, i1: 0, i2: 0, vc: 0), adc(102, i1: 8.47, i2: 33.5)]
        let result = AiDexHistoryMerge.mergeHistoryEntries(rows, calibratedCache: &cache, initialFallback: nil)
        XCTAssertEqual(result.mergedCount, 1)
        XCTAssertEqual(result.fallbackCount, 2)
        XCTAssertEqual(result.entries.map { $0.glucoseMgDl }, [80, 80, 80])
        // 1350 mg/dL is not plausible and counts as no raw value.
        XCTAssertEqual(result.entries[0].rawMgDl, 0)
        XCTAssertEqual(result.entries[1].rawMgDl, 0)
        XCTAssertEqual(result.entries[2].rawMgDl, 84.7, accuracy: 0.01)
        XCTAssertEqual(result.entries.map { $0.isValid }, [true, false, true])
        XCTAssertEqual(result.entries[0].temperatureC, 10, accuracy: 0.001)
        XCTAssertEqual(result.entries[2].temperatureC, 33.5, accuracy: 0.001)
    }

    func testMergeFallbackAcrossPages() {
        var cache: [Int: Int] = [:]
        let carried = AiDexHistoryMerge.mergeHistoryEntries([adc(100), adc(101)], calibratedCache: &cache, initialFallback: 75)
        XCTAssertEqual(carried.mergedCount, 0)
        XCTAssertEqual(carried.fallbackCount, 2)
        XCTAssertEqual(carried.noGlucoseCount, 0)
        XCTAssertEqual(carried.lastKnownGlucose, 75)
        XCTAssertEqual(carried.entries.map { $0.glucoseMgDl }, [75, 75])

        let none = AiDexHistoryMerge.mergeHistoryEntries([adc(100), adc(101)], calibratedCache: &cache, initialFallback: nil)
        XCTAssertEqual(none.noGlucoseCount, 2)
        XCTAssertNil(none.lastKnownGlucose)
        XCTAssertEqual(none.entries.map { $0.glucoseMgDl }, [0, 0])
    }

    func testMergeLeavesUnmatchedCacheRows() {
        var cache: [Int: Int] = [200: 80, 201: 85, 202: 90]
        let result = AiDexHistoryMerge.mergeHistoryEntries((100...102).map { adc($0) }, calibratedCache: &cache, initialFallback: nil)
        XCTAssertEqual(result.noGlucoseCount, 3)
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache[200], 80)
        var untouched: [Int: Int] = [100: 80]
        let empty = AiDexHistoryMerge.mergeHistoryEntries([], calibratedCache: &untouched, initialFallback: nil)
        XCTAssertEqual(empty.entries.count, 0)
        XCTAssertEqual(untouched.count, 1)
    }

    func testNormalizeRaw() {
        XCTAssertNil(AiDexHistoryMerge.normalizeRawMgDl(nil))
        XCTAssertNil(AiDexHistoryMerge.normalizeRawMgDl(Float.nan))
        XCTAssertNil(AiDexHistoryMerge.normalizeRawMgDl(Float.infinity))
        XCTAssertNil(AiDexHistoryMerge.normalizeRawMgDl(0))
        XCTAssertNil(AiDexHistoryMerge.normalizeRawMgDl(-1))
        XCTAssertEqual(AiDexHistoryMerge.normalizeRawMgDl(540.5), 540.5)
        XCTAssertNil(AiDexHistoryMerge.normalizeRawMgDl(540.6))
        XCTAssertEqual(AiDexHistoryMerge.normalizeRawMgDl(84.7), 84.7)
        XCTAssertEqual(AiDexHistoryMerge.maxPlausibleRawMgDl, 540.546, accuracy: 0.001)
    }

    func testCacheSkipsSentinelsAndPageTailControlValue() {
        var cache: [Int: Int] = [:]
        // The last row of a full page that jumps by more than 20 is a control value.
        let spike = (0..<120).map { calibrated(1000 + $0, $0 < 119 ? 80 : 366) }
        var counts = AiDexHistoryMerge.cacheCalibratedEntries(spike, cache: &cache)
        XCTAssertEqual(counts.cached, 119)
        XCTAssertEqual(counts.skipped, 1)
        XCTAssertNil(cache[1119])

        // Exactly 20 is kept, 21 is not.
        cache = [:]
        counts = AiDexHistoryMerge.cacheCalibratedEntries((0..<120).map { calibrated(1000 + $0, $0 < 119 ? 80 : 100) }, cache: &cache)
        XCTAssertEqual(counts.cached, 120)
        XCTAssertEqual(counts.skipped, 0)
        cache = [:]
        counts = AiDexHistoryMerge.cacheCalibratedEntries((0..<120).map { calibrated(1000 + $0, $0 < 119 ? 80 : 101) }, cache: &cache)
        XCTAssertEqual(counts.cached, 119)
        XCTAssertEqual(counts.skipped, 1)

        // A partial page has no control value.
        cache = [:]
        counts = AiDexHistoryMerge.cacheCalibratedEntries((0..<50).map { calibrated(1000 + $0, $0 < 49 ? 80 : 366) }, cache: &cache)
        XCTAssertEqual(counts.cached, 50)
        XCTAssertEqual(counts.skipped, 0)

        cache = [:]
        counts = AiDexHistoryMerge.cacheCalibratedEntries(
            [calibrated(100, 1023, sentinel: true), calibrated(101, 1023, sentinel: true), calibrated(102, 80)], cache: &cache)
        XCTAssertEqual(counts.cached, 1)
        XCTAssertEqual(counts.skipped, 2)
        XCTAssertEqual(cache[102], 80)
    }

    // MARK: storage filter

    private let filterStart = Date(timeIntervalSince1970: 1_700_000_000)
    private var filterNow: Date { return filterStart.addingTimeInterval(15 * 24 * 3600) }

    private func stored(_ offset: Int = 1000, glucose: Float = 100, valid: Bool = true) -> AiDexHistoryStoreEntry {
        return AiDexHistoryStoreEntry(offsetMinutes: offset, glucoseMgDl: glucose, rawMgDl: 50, isValid: valid, temperatureC: 30)
    }

    private func passes(_ entry: AiDexHistoryStoreEntry, newest: Int = 0, cutoff: Int = 0, wear: Int? = nil, now: Date? = nil) -> Bool {
        let result = AiDexHistoryMerge.filterForStorage(
            [entry], sensorStart: filterStart, now: now ?? filterNow, historyNewestOffset: newest, liveOffsetCutoff: cutoff, wearDays: wear
        )
        return result.count == 1
    }

    func testStorageFilterOffsets() {
        let month = filterStart.addingTimeInterval(31 * 24 * 3600)
        XCTAssertTrue(passes(stored()))
        XCTAssertFalse(passes(stored(valid: false)))
        XCTAssertFalse(passes(stored(0)))
        XCTAssertFalse(passes(stored(-1)))
        XCTAssertTrue(passes(stored(1)))
        // No warm-up gate: the first minutes are kept.
        XCTAssertTrue(passes(stored(3)))
        XCTAssertTrue(passes(stored(43200), now: month))
        XCTAssertFalse(passes(stored(43201), now: month))
    }

    func testStorageFilterAgainstSensorAndLiveCursors() {
        XCTAssertFalse(passes(stored(1001), newest: 1000))
        XCTAssertTrue(passes(stored(1000), newest: 1000))
        XCTAssertTrue(passes(stored(5000), newest: 0))
        // Only the exact minute the live pipeline stored is skipped.
        XCTAssertFalse(passes(stored(1000), cutoff: 1000))
        XCTAssertTrue(passes(stored(1001), cutoff: 1000))
        XCTAssertTrue(passes(stored(999), cutoff: 1000))
        XCTAssertTrue(passes(stored(1000), cutoff: 0))
    }

    func testStorageFilterGlucoseRange() {
        XCTAssertFalse(passes(stored(glucose: 0)))
        XCTAssertFalse(passes(stored(glucose: 19)))
        XCTAssertFalse(passes(stored(glucose: 19.9)))
        XCTAssertTrue(passes(stored(glucose: 20)))
        XCTAssertTrue(passes(stored(glucose: 500)))
        XCTAssertTrue(passes(stored(glucose: 500.9)))
        XCTAssertFalse(passes(stored(glucose: 501)))
        XCTAssertFalse(passes(stored(glucose: 1023)))
    }

    func testStorageFilterWearTimeAndFuture() {
        let sixteenDays = filterStart.addingTimeInterval(16 * 24 * 3600)
        XCTAssertTrue(passes(stored(21599), wear: 15, now: sixteenDays))
        XCTAssertFalse(passes(stored(21600), wear: 15, now: sixteenDays))
        XCTAssertTrue(passes(stored(21600), wear: nil, now: sixteenDays))
        XCTAssertTrue(passes(stored(21600), wear: 0, now: sixteenDays))
        // Two minutes into the future are tolerated.
        let atNow = 15 * 24 * 60
        XCTAssertTrue(passes(stored(atNow + 1)))
        XCTAssertTrue(passes(stored(atNow + 2)))
        XCTAssertFalse(passes(stored(atNow + 3)))
    }

    func testStorageFilterMixedPage() {
        let rows = [
            stored(10, glucose: 90), stored(11, glucose: 10), stored(12, glucose: 120, valid: false),
            stored(13, glucose: 130), stored(14, glucose: 600), stored(15, glucose: 150)
        ]
        let result = AiDexHistoryMerge.filterForStorage(
            rows, sensorStart: filterStart, now: filterNow, historyNewestOffset: 14, liveOffsetCutoff: 13, wearDays: nil
        )
        XCTAssertEqual(result.map { $0.offsetMinutes }, [10])
    }

    // MARK: download policy

    private func plan(_ briefStart: Int, _ rawStart: Int, _ newest: Int, _ persistedRaw: Int, _ persistedBrief: Int) -> AiDexHistoryPolicy.DownloadPlan {
        return AiDexHistoryPolicy.planInitialDownload(
            briefStart: briefStart, rawStart: rawStart, newest: newest,
            persistedRawNextIndex: persistedRaw, persistedBriefNextIndex: persistedBrief
        )
    }

    func testInitialDownloadPlans() {
        // (plan, raw, brief, start, action, request)
        XCTAssertEqual(plan(0, 0, 0, 5, 5), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 0, briefNextIndex: 0, downloadStartIndex: 0, action: .completeEmpty, requestOffset: nil))
        XCTAssertEqual(plan(1, 1, 500, 0, 0), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 1, briefNextIndex: 1, downloadStartIndex: 1, action: .requestRaw, requestOffset: 1))
        XCTAssertEqual(plan(5, 3, 500, 0, 0), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 3, briefNextIndex: 5, downloadStartIndex: 3, action: .requestRaw, requestOffset: 3))
        XCTAssertEqual(plan(1, 1, 500, 300, 280), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 280, briefNextIndex: 280, downloadStartIndex: 280, action: .requestRaw, requestOffset: 280))
        // The raw cursor never runs ahead of the brief one while both are in range.
        XCTAssertEqual(plan(1, 1, 500, 400, 100), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 100, briefNextIndex: 100, downloadStartIndex: 100, action: .requestRaw, requestOffset: 100))
        XCTAssertEqual(plan(1, 1, 500, 501, 100), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 501, briefNextIndex: 100, downloadStartIndex: 501, action: .requestBrief, requestOffset: 100))
        XCTAssertEqual(plan(1, 1, 500, 501, 501), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 501, briefNextIndex: 501, downloadStartIndex: 501, action: .completeAlreadyCaughtUp, requestOffset: nil))
        // A cursor more than ten past the newest offset is stale (the sensor was reset), so it restarts.
        XCTAssertEqual(plan(10, 20, 500, 900, 900), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 20, briefNextIndex: 10, downloadStartIndex: 20, action: .requestRaw, requestOffset: 20))
        XCTAssertEqual(plan(10, 20, 500, 510, 510), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 510, briefNextIndex: 510, downloadStartIndex: 510, action: .completeAlreadyCaughtUp, requestOffset: nil))
        XCTAssertEqual(plan(10, 20, 500, 511, 511), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 20, briefNextIndex: 10, downloadStartIndex: 20, action: .requestRaw, requestOffset: 20))
        // A cursor below the sensor's first stored minute starts at that minute.
        XCTAssertEqual(plan(50, 60, 500, 5, 5), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 60, briefNextIndex: 50, downloadStartIndex: 60, action: .requestRaw, requestOffset: 60))
        XCTAssertEqual(plan(1, 1, 500, 505, 300), AiDexHistoryPolicy.DownloadPlan(rawNextIndex: 505, briefNextIndex: 300, downloadStartIndex: 505, action: .requestBrief, requestOffset: 300))
    }

    func testNextPageIndex() {
        XCTAssertEqual(AiDexHistoryPolicy.nextPageIndex(lastOffsetMinutes: 100, newest: 500), 101)
        XCTAssertEqual(AiDexHistoryPolicy.nextPageIndex(lastOffsetMinutes: 499, newest: 500), 500)
        XCTAssertEqual(AiDexHistoryPolicy.nextPageIndex(lastOffsetMinutes: 500, newest: 500), 501)
        XCTAssertEqual(AiDexHistoryPolicy.nextPageIndex(lastOffsetMinutes: 520, newest: 500), 501)
        XCTAssertEqual(AiDexHistoryPolicy.nextPageIndex(lastOffsetMinutes: 100, newest: 0), 101)
    }

    func testLiveDedupeAndWearDuration() {
        XCTAssertTrue(AiDexHistoryPolicy.shouldSkipHistoryEntryForLiveDedupe(entryOffsetMinutes: 10, liveOffsetCutoff: 10))
        XCTAssertFalse(AiDexHistoryPolicy.shouldSkipHistoryEntryForLiveDedupe(entryOffsetMinutes: 11, liveOffsetCutoff: 10))
        XCTAssertFalse(AiDexHistoryPolicy.shouldSkipHistoryEntryForLiveDedupe(entryOffsetMinutes: 9, liveOffsetCutoff: 10))
        XCTAssertFalse(AiDexHistoryPolicy.shouldSkipHistoryEntryForLiveDedupe(entryOffsetMinutes: 10, liveOffsetCutoff: 0))
        XCTAssertEqual(AiDexHistoryPolicy.wearDurationMinutes(wearDays: 15), 21600)
        XCTAssertNil(AiDexHistoryPolicy.wearDurationMinutes(wearDays: 0))
        XCTAssertNil(AiDexHistoryPolicy.wearDurationMinutes(wearDays: nil))
        XCTAssertTrue(AiDexHistoryPolicy.isWithinWearDuration(offsetMinutes: 21599, wearDays: 15))
        XCTAssertFalse(AiDexHistoryPolicy.isWithinWearDuration(offsetMinutes: 21600, wearDays: 15))
        XCTAssertFalse(AiDexHistoryPolicy.isWithinWearDuration(offsetMinutes: -1, wearDays: 15))
        XCTAssertTrue(AiDexHistoryPolicy.isWithinWearDuration(offsetMinutes: 99999, wearDays: nil))
    }

    func testOffsetBackedTimestamp() {
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let start = observed.addingTimeInterval(-1_000_000)
        XCTAssertEqual(AiDexHistoryPolicy.resolveOffsetBackedTimestamp(observedAt: observed, sensorStart: start, offsetMinutes: 100).timeIntervalSince1970, 1_799_006_000)
        XCTAssertEqual(AiDexHistoryPolicy.resolveOffsetBackedTimestamp(observedAt: observed, sensorStart: start, offsetMinutes: nil), observed)
        XCTAssertEqual(AiDexHistoryPolicy.resolveOffsetBackedTimestamp(observedAt: observed, sensorStart: start, offsetMinutes: 0), observed)
        XCTAssertEqual(AiDexHistoryPolicy.resolveOffsetBackedTimestamp(observedAt: observed, sensorStart: nil, offsetMinutes: 100), observed)
        // Up to five minutes after the moment it was seen is kept, more is not.
        let recent = observed.addingTimeInterval(-4 * 60)
        XCTAssertEqual(AiDexHistoryPolicy.resolveOffsetBackedTimestamp(observedAt: observed, sensorStart: recent, offsetMinutes: 8).timeIntervalSince1970, 1_800_000_240)
        XCTAssertEqual(AiDexHistoryPolicy.resolveOffsetBackedTimestamp(observedAt: observed, sensorStart: recent, offsetMinutes: 10), observed)
    }

    func testRealtimeTimestampOrder() {
        let latest = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AiDexHistoryPolicy.shouldAcceptRealtimeTimestamp(candidate: latest, latestAccepted: latest))
        XCTAssertFalse(AiDexHistoryPolicy.shouldAcceptRealtimeTimestamp(candidate: latest.addingTimeInterval(-1), latestAccepted: latest))
        XCTAssertTrue(AiDexHistoryPolicy.shouldAcceptRealtimeTimestamp(candidate: latest.addingTimeInterval(1), latestAccepted: latest))
        XCTAssertTrue(AiDexHistoryPolicy.shouldAcceptRealtimeTimestamp(candidate: latest, latestAccepted: nil))
        XCTAssertFalse(AiDexHistoryPolicy.shouldAcceptRealtimeTimestamp(candidate: Date(timeIntervalSince1970: 0), latestAccepted: nil))
    }

    // MARK: live offset

    private let offsetNow = Date(timeIntervalSince1970: 1_800_000_000)
    /// The session began 3000 minutes and 25 seconds before `offsetNow`.
    private var offsetStart: Date { return offsetNow.addingTimeInterval(-3000 * 60 + 25) }

    private func resolve(_ wire: Int, _ context: AiDexOffsetContext = AiDexOffsetContext()) -> (offset: Int?, note: String?) {
        return AiDexLiveOffset.resolveTrusted(wireOffset: wire, now: offsetNow, context: context)
    }

    func testLiveOffsetPlainAndInvalid() {
        XCTAssertNil(resolve(0).offset)
        XCTAssertEqual(resolve(0).note, "wire offset=0 is not positive")
        XCTAssertEqual(resolve(-5).note, "wire offset=-5 is not positive")
        XCTAssertEqual(resolve(120).offset, 120)
        XCTAssertNil(resolve(120).note)

        var good = AiDexOffsetContext()
        good.sensorStart = offsetStart
        good.hasAuthoritativeSessionStart = true
        XCTAssertEqual(resolve(2999, good).offset, 2999)
        XCTAssertEqual(resolve(3004, good).offset, 3004)
    }

    func testLiveOffsetBeyondThirtyDays() {
        XCTAssertNil(resolve(50000).offset)
        XCTAssertEqual(resolve(50000).note, "wire offset=50000 exceeds 30d limit")

        var session = AiDexOffsetContext()
        session.sensorStart = offsetStart
        session.hasAuthoritativeSessionStart = true
        XCTAssertEqual(resolve(50000, session).offset, 3000)
        XCTAssertEqual(resolve(50000, session).note, "wire offset=50000 invalid; derived live offset=3000 from authoritative session")

        var history = AiDexOffsetContext()
        history.historyNewestOffset = 2990
        history.lastOffsetMinutes = 2995
        history.lastGlucoseTime = offsetNow.addingTimeInterval(-5 * 60)
        XCTAssertEqual(resolve(50000, history).offset, 3000)
        XCTAssertEqual(resolve(50000, history).note, "wire offset=50000 invalid; derived live offset=3000 from history cadence")

        var historyOnly = AiDexOffsetContext()
        historyOnly.historyNewestOffset = 2990
        XCTAssertEqual(resolve(50000, historyOnly).offset, 2990)

        // A session start that is not authoritative is not used to derive an offset.
        var unconfirmed = AiDexOffsetContext()
        unconfirmed.sensorStart = offsetStart
        XCTAssertNil(resolve(50000, unconfirmed).offset)
    }

    func testLiveOffsetAheadOfHistory() {
        var session = AiDexOffsetContext()
        session.historyNewestOffset = 2900
        session.sensorStart = offsetStart
        session.hasAuthoritativeSessionStart = true
        XCTAssertEqual(resolve(3000, session).offset, 3000)
        XCTAssertEqual(resolve(3000, session).note, "wire offset=3000 ahead of history newest=2900; using session-derived offset=3000")

        var history = AiDexOffsetContext()
        history.historyNewestOffset = 2900
        history.lastOffsetMinutes = 2950
        history.lastGlucoseTime = offsetNow.addingTimeInterval(-2 * 60)
        XCTAssertEqual(resolve(3000, history).offset, 2952)
        XCTAssertEqual(resolve(3000, history).note, "wire offset=3000 ahead of history newest=2900; using history-derived offset=2952")

        var bare = AiDexOffsetContext()
        bare.historyNewestOffset = 2900
        XCTAssertEqual(resolve(3000, bare).offset, 2900)
        // Two minutes ahead of the history is still believed, three is not.
        XCTAssertEqual(resolve(2902, bare).offset, 2902)
        XCTAssertNil(resolve(2902, bare).note)
        XCTAssertEqual(resolve(2903, bare).offset, 2900)
    }

    func testLiveOffsetFutureAndOld() {
        var future = AiDexOffsetContext()
        future.sensorStart = offsetStart
        future.hasAuthoritativeSessionStart = true
        XCTAssertEqual(resolve(3100, future).offset, 3000)
        XCTAssertEqual(resolve(3100, future).note, "wire offset=3100 points into the future; using session-derived offset=3000")
        future.hasAuthoritativeSessionStart = false
        XCTAssertNil(resolve(3100, future).offset)
        XCTAssertEqual(resolve(3100, future).note, "wire offset=3100 points into the future")

        var old = AiDexOffsetContext()
        old.sensorStart = offsetNow.addingTimeInterval(-40 * 24 * 3600)
        XCTAssertNil(resolve(100, old).offset)
        XCTAssertEqual(resolve(100, old).note, "wire offset=100 points older than 30d")

        var notStarted = AiDexOffsetContext()
        notStarted.sensorStart = offsetNow.addingTimeInterval(1)
        notStarted.hasAuthoritativeSessionStart = true
        XCTAssertNil(resolve(50000, notStarted).offset)
    }

    // MARK: key exchange and streaming decisions

    func testPairKeyStartAction() {
        typealias Policy = AiDexKeyExchangePolicy
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: false), .freshPair)
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: false, savedKeyExhausted: true), .freshPair)
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: true), .useSavedKey)
        // A key that still works is not replaced on request.
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: true, explicitPairRequested: true), .useSavedKey)
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: true, pairedHere: true), .useSavedKey)
        // A phone that does not hold the pairing never replaces a key on its own.
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: true, savedKeyExhausted: true), .useSavedKey)
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: true, savedKeyExhausted: true, explicitPairRequested: true), .freshPair)
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: true, savedKeyExhausted: true, pairedHere: true), .freshPair)
        // A confirmed reset wiped the sensor's own key.
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: true, pairKeyResetPending: true), .freshPair)
        XCTAssertEqual(Policy.decidePairKeyStartAction(hasSavedPairKey: false, pairKeyResetPending: true), .freshPair)
    }

    func testKeyExchangeFailureAction() {
        typealias Policy = AiDexKeyExchangePolicy
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 2, maxFailures: 3), .retryCleanLink)
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 3, maxFailures: 3), .giveUp)
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 3, maxFailures: 3, usedSavedKey: false, pairedHere: true), .giveUp)
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 2, maxFailures: 3, usedSavedKey: true, pairedHere: true), .retryCleanLink)
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 3, maxFailures: 3, usedSavedKey: true, pairedHere: true), .replaceSavedKey)
        // A counter that outlived the app past its limit must not fall back into retrying.
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 5, maxFailures: 3, usedSavedKey: true, pairedHere: true), .replaceSavedKey)
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 3, maxFailures: 3, usedSavedKey: true, pairedHere: false), .giveUp)
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 2, maxFailures: 3, freshPairAfterReset: true), .retryCleanLink)
        XCTAssertEqual(Policy.decideFailureAction(consecutiveFailures: 3, maxFailures: 3, freshPairAfterReset: true), .restoreSavedKey)
    }

    func testShortBondRead() {
        typealias Policy = AiDexKeyExchangePolicy
        XCTAssertEqual(Policy.decideShortBondReadAction(replyLength: 17, rereads: 0, maxRereads: 1), .accept)
        XCTAssertEqual(Policy.decideShortBondReadAction(replyLength: 1, rereads: 0, maxRereads: 1), .reread)
        XCTAssertEqual(Policy.decideShortBondReadAction(replyLength: 1, rereads: 1, maxRereads: 1), .failKeyExchange)
        XCTAssertEqual(Policy.decideShortBondReadAction(replyLength: 17, rereads: 1, maxRereads: 1), .accept)
    }

    func testNoStreamRecovery() {
        typealias Policy = AiDexStreamingPolicy
        XCTAssertEqual(Policy.decideNoStreamRecovery(historyDownloading: true, liveNotificationRefreshAttempted: false), .keepWaiting)
        XCTAssertEqual(Policy.decideNoStreamRecovery(historyDownloading: true, liveNotificationRefreshAttempted: true), .keepWaiting)
        XCTAssertEqual(Policy.decideNoStreamRecovery(historyDownloading: false, liveNotificationRefreshAttempted: false), .refreshLiveNotifications)
        XCTAssertEqual(Policy.decideNoStreamRecovery(historyDownloading: false, liveNotificationRefreshAttempted: true), .reconnect)
    }

    func testNoStreamWatchdogDelay() {
        typealias Policy = AiDexStreamingPolicy
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Policy.resolveNoStreamWatchdogDelay(defaultDelay: 80, now: now, latestKnownReading: nil, expectedLiveInterval: 60, expectedLiveGrace: 20), 80)
        // A reading 10 s ago: the next one is due in 70 s, still inside the default.
        XCTAssertEqual(Policy.resolveNoStreamWatchdogDelay(defaultDelay: 80, now: now, latestKnownReading: now.addingTimeInterval(-10), expectedLiveInterval: 60, expectedLiveGrace: 20), 80)
        // A reading right now: 60 + 120 s grace is longer than the default.
        XCTAssertEqual(Policy.resolveNoStreamWatchdogDelay(defaultDelay: 80, now: now, latestKnownReading: now, expectedLiveInterval: 60, expectedLiveGrace: 120), 180)
        // An old reading never shortens the wait.
        XCTAssertEqual(Policy.resolveNoStreamWatchdogDelay(defaultDelay: 80, now: now, latestKnownReading: now.addingTimeInterval(-3600), expectedLiveInterval: 60, expectedLiveGrace: 20), 80)
    }

    func testStartupDeviceInfoRetries() {
        typealias Policy = AiDexStreamingPolicy
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let spacing = Policy.startupDeviceInfoRetrySpacing
        XCTAssertEqual(spacing, 30)
        XCTAssertEqual(Policy.startupDeviceInfoMaxAttempts, 3)
        XCTAssertTrue(Policy.shouldRequestStartupDeviceInfo(startupMetadataComplete: false, attemptsThisConnection: 0, lastRequestAt: nil, now: start))
        XCTAssertFalse(Policy.shouldRequestStartupDeviceInfo(startupMetadataComplete: false, attemptsThisConnection: 1, lastRequestAt: start, now: start.addingTimeInterval(spacing - 1)))
        XCTAssertTrue(Policy.shouldRequestStartupDeviceInfo(startupMetadataComplete: false, attemptsThisConnection: 1, lastRequestAt: start, now: start.addingTimeInterval(spacing)))
        XCTAssertTrue(Policy.shouldRequestStartupDeviceInfo(startupMetadataComplete: false, attemptsThisConnection: 2, lastRequestAt: start, now: start.addingTimeInterval(spacing)))
        XCTAssertFalse(Policy.shouldRequestStartupDeviceInfo(startupMetadataComplete: false, attemptsThisConnection: 3, lastRequestAt: start, now: start.addingTimeInterval(600)))
        XCTAssertFalse(Policy.shouldRequestStartupDeviceInfo(startupMetadataComplete: true, attemptsThisConnection: 0, lastRequestAt: nil, now: start))
    }

    func testGattIdentifiers() {
        XCTAssertEqual(AiDexGATT.cgmService.uuidString, "181F")
        XCTAssertEqual(AiDexGATT.f001.uuidString, "F001")
        XCTAssertEqual(AiDexGATT.f002.uuidString, "F002")
        XCTAssertEqual(AiDexGATT.f003.uuidString, "F003")
        XCTAssertEqual(AiDexOpcodes.dataFrameLength, 17)
        XCTAssertEqual(AiDexOpcodes.statusFrameLength, 5)
    }

    // MARK: - registration

    func testAiDexIsAvailableInTheDirectCGMAddFlow() {
        XCTAssertEqual(BluetoothPeripheralType.aiDexType.category(), .CGM)
        XCTAssertTrue(BluetoothPeripheralType.addFlowPreferredOrder[.CGM]?.contains(.aiDexType) == true)
        XCTAssertEqual(BluetoothPeripheralType.aiDexType.onlineHelpTopic, .addDirectCGM)
        XCTAssertFalse(BluetoothPeripheralType.aiDexType.usesIntermittentConnection)
    }

    func testAiDexTransmitterTypeProperties() {
        XCTAssertEqual(CGMTransmitterType.aiDex.rawValue, "AiDex")
        XCTAssertEqual(CGMTransmitterType.aiDex.sensorType(), .aiDex)
        XCTAssertTrue(CGMTransmitterType.aiDex.canDetectNewSensor())
        XCTAssertFalse(CGMTransmitterType.aiDex.allowManualSensorStart())
    }

    func testAiDexTroubleshootingSource() throws {
        XCTAssertEqual(TroubleshootingLogSource(directTransmitterType: .aiDex), .aiDex)
        let source = try XCTUnwrap(TroubleshootingLogSource(bluetoothPeripheralType: .aiDexType))
        XCTAssertEqual(source, .aiDex)
        XCTAssertEqual(source.name, "AiDex")
        XCTAssertFalse(source.isFollowerSource)
    }

    func testAiDexEntityRoundTripsThroughCoreData() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = coreDataManager.mainManagedObjectContext
        let aiDex = AiDex(address: "test-aidex", name: "AiDEX X-2222267V4E", alias: nil, nsManagedObjectContext: context)
        XCTAssertEqual(aiDex.bluetoothPeripheralType(), .aiDexType)
        XCTAssertTrue(aiDex.blePeripheral.shouldconnect)

        coreDataManager.saveChanges()
        let objectID = aiDex.blePeripheral.objectID
        context.reset()

        let restored = try XCTUnwrap(context.existingObject(with: objectID) as? BLEPeripheral)
        XCTAssertNotNil(restored.aiDex)
        XCTAssertNil(restored.iCan)
        XCTAssertNil(restored.sibionics2)
        XCTAssertEqual(restored.aiDex?.bluetoothPeripheralType(), .aiDexType)
    }

    func testDeviceStoreRoundTripAndClear() {
        let address = "aidex-test-address"
        AiDexDeviceStore.clear(address: address)
        XCTAssertNil(AiDexDeviceStore.load(address: address).model)
        XCTAssertEqual(AiDexDeviceStore.load(address: address).historyRawNextIndex, 0)

        AiDexDeviceStore.update(address: address) {
            $0.model = "AiDEX X"
            $0.wearDays = 15
            $0.historyBriefNextIndex = 321
            $0.problem = .linkLost
        }
        let stored = AiDexDeviceStore.load(address: address)
        XCTAssertEqual(stored.model, "AiDEX X")
        XCTAssertEqual(stored.wearDays, 15)
        XCTAssertEqual(stored.historyBriefNextIndex, 321)
        XCTAssertEqual(stored.problem, .linkLost)

        AiDexDeviceStore.clear(address: address)
        XCTAssertNil(AiDexDeviceStore.load(address: address).model)
        XCTAssertEqual(AiDexDeviceStore.load(address: address).historyBriefNextIndex, 0)
    }

    func testPairKeyFingerprintDoesNotRevealTheKey() {
        let key = (1...16).map { UInt8($0) }
        let fingerprint = AiDexPairKeyStore.fingerprint(key)
        XCTAssertEqual(fingerprint.count, 8)
        XCTAssertEqual(fingerprint, AiDexParser.compactHex(Array(AiDexCrypto.md5(key).prefix(4))))
        XCTAssertFalse(fingerprint.uppercased().contains(AiDexParser.compactHex(key).uppercased()))
        XCTAssertEqual(AiDexPairKeyStore.fingerprint(nil), "none")
        XCTAssertEqual(AiDexPairKeyStore.fingerprint([]), "none")
    }

    func testEveryLinkProblemHasAText() {
        let problems: [AiDexLinkProblem] = [
            .linkLost, .keyExchangeFailed, .savedKeyRejected, .pairingRefused, .unsupportedFSeries,
            .serialUnknown, .noReadings, .historyFailed, .sensorNotStarted, .sensorEnded, .notAnAiDex
        ]
        var texts = Set<String>()
        for problem in problems {
            let text = Texts_BluetoothPeripheralView.aiDexProblem(problem)
            XCTAssertFalse(text.isEmpty)
            texts.insert(text)
        }
        XCTAssertEqual(texts.count, problems.count)
    }

    func testFSeriesAdvertisementIsRefusedWithoutAStoredKey() {
        XCTAssertTrue(AiDexKeyRequirement.requiresProvisionedKeys(advertisedName: "AiDEX F-22222FZXKT"))
        XCTAssertFalse(AiDexKeyRequirement.requiresProvisionedKeys(advertisedName: "AiDEX X-2222267V4E"))
        XCTAssertFalse(AiDexKeyRequirement.requiresProvisionedKeys(advertisedName: nil))
    }
}
