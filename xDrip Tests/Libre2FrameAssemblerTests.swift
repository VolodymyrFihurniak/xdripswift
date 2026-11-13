//
//  Libre2FrameAssemblerTests.swift
//  xdripTests
//
//  Created by Paul Plant on 31/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class Libre2FrameAssemblerTests: XCTestCase {
    func testConsecutiveFramesCompleteWithoutWaitingForTimeout() {
        var assembler = Libre2FrameAssembler(expectedByteCount: 6)
        let start = ContinuousClock.now

        XCTAssertEqual(assembler.append(Data([0, 1]), arrival: start).frameResult, .incomplete)
        XCTAssertEqual(assembler.append(Data([2, 3]), arrival: start).frameResult, .incomplete)
        XCTAssertEqual(
            assembler.append(Data([4, 5]), arrival: start).frameResult,
            .complete(frame: Data([0, 1, 2, 3, 4, 5]), assemblyDuration: 0)
        )

        XCTAssertEqual(assembler.append(Data([6, 7, 8]), arrival: start).frameResult, .incomplete)
        XCTAssertEqual(
            assembler.append(Data([9, 10, 11]), arrival: start).frameResult,
            .complete(frame: Data([6, 7, 8, 9, 10, 11]), assemblyDuration: 0)
        )
    }

    func testPartialFrameIsDiscardedAfterAssemblyTimeout() {
        var assembler = Libre2FrameAssembler(expectedByteCount: 6, assemblyTimeout: .seconds(3))
        let start = ContinuousClock.now

        XCTAssertEqual(assembler.append(Data([0, 1, 2]), arrival: start).frameResult, .incomplete)

        let resultAfterTimeout = assembler.append(
            Data([3, 4, 5]),
            arrival: start.advanced(by: .seconds(4))
        )

        XCTAssertEqual(resultAfterTimeout.frameResult, .incomplete)
        XCTAssertEqual(
            resultAfterTimeout.timedOutPartialFrame,
            Libre2FrameAssembler.TimedOutPartialFrame(discardedByteCount: 3, assemblyDuration: 4)
        )

        // The fragment that exposed the timeout must remain as the start of the next frame.
        XCTAssertEqual(
            assembler.append(Data([6, 7, 8]), arrival: start.advanced(by: .seconds(5))).frameResult,
            .complete(frame: Data([3, 4, 5, 6, 7, 8]), assemblyDuration: 1)
        )
    }

    func testOversizedFrameIsDiscardedAndNextFrameCanComplete() {
        var assembler = Libre2FrameAssembler(expectedByteCount: 6)
        let start = ContinuousClock.now

        XCTAssertEqual(
            assembler.append(Data([0, 1, 2, 3, 4, 5, 6]), arrival: start).frameResult,
            .oversized(receivedByteCount: 7)
        )
        XCTAssertEqual(
            assembler.append(Data([7, 8, 9, 10, 11, 12]), arrival: start).frameResult,
            .complete(frame: Data([7, 8, 9, 10, 11, 12]), assemblyDuration: 0)
        )
    }
}

// MARK: - Libre sensor activation

/// Expected bytes were computed with a Python port of `PreLibre2.usefulFunction` and the Libre crc.
final class LibreSensorActivationTests: XCTestCase {
    private let sensorUID = Data([0x5E, 0x07, 0x1D, 0x00, 0x00, 0xA4, 0x07, 0xE0])
    private let libre2PatchInfo = Data([0x9D, 0x08, 0x30, 0x01, 0x00, 0x00])
    private let libre1PatchInfo = Data([0xDF, 0x00, 0x00, 0x01, 0x00, 0x00])

    private func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map { offset -> UInt8 in
            let start = text.index(text.startIndex, offsetBy: offset)
            return UInt8(text[start ..< text.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    /// A plain 344-byte FRAM whose 24-byte header (valid crc) holds `state` at byte 4.
    private func plainFRAM(state: UInt8) -> Data {
        let headers: [UInt8: String] = [
            1: "a23600000111111111111111111111111111111111111111",
            2: "34e100000211111111111111111111111111111111111111",
            3: "cf8b00000311111111111111111111111111111111111111",
        ]
        return hex(headers[state]!) + Data(repeating: 0, count: 320)
    }

    /// Libre 2 FRAM as the sensor holds it: the decryption is an xor, so it also encrypts.
    private func libre2FRAM(state: UInt8, patchInfo: Data) -> Data {
        Data(PreLibre2.decryptFRAM(Array(sensorUID), Array(patchInfo), Array(plainFRAM(state: state))))
    }

    func testHeaderCrcCheck() {
        XCTAssertTrue(Crc.libreHeaderCrcIsValid(plainFRAM(state: 1)))
        var damaged = plainFRAM(state: 1)
        damaged[4] = 0x03
        XCTAssertFalse(Crc.libreHeaderCrcIsValid(damaged))
        XCTAssertFalse(Crc.libreHeaderCrcIsValid(Data(repeating: 0, count: 10)))
    }

    func testNewLibre2SensorGetsTheActivateSubcommand() {
        let fram = libre2FRAM(state: 1, patchInfo: libre2PatchInfo)
        XCTAssertNotEqual(fram.prefix(24), plainFRAM(state: 1).prefix(24))
        XCTAssertEqual(LibreSensorActivation.state(patchInfo: libre2PatchInfo, fram: fram, sensorUID: sensorUID), .notYetStarted)
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: libre2PatchInfo, fram: fram, sensorUID: sensorUID),
                       .activate(code: 0xA1, parameters: hex("1ba0ef6cd2")))
        // Libre 2 Plus EU (C6) and the 7F Libre 2 use the same command.
        for patchInfo in [Data([0xC6, 0x09, 0x31, 0x01, 0x00, 0x00]), Data([0x7F, 0x0E, 0x30, 0x01, 0x00, 0x00])] {
            let plan = LibreSensorActivation.plan(patchInfo: patchInfo, fram: libre2FRAM(state: 1, patchInfo: patchInfo), sensorUID: sensorUID)
            XCTAssertEqual(plan, .activate(code: 0xA1, parameters: hex("1ba0ef6cd2")))
        }
    }

    func testNewLibre1SensorGetsTheA0Command() {
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: libre1PatchInfo, fram: plainFRAM(state: 1), sensorUID: sensorUID),
                       .activate(code: 0xA0, parameters: Data([0xC2, 0xAD, 0x75, 0x21])))
    }

    func testRunningSensorsAreLeftAlone() {
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: libre1PatchInfo, fram: plainFRAM(state: 2), sensorUID: sensorUID),
                       .alreadyStarted(.starting))
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: libre2PatchInfo, fram: libre2FRAM(state: 3, patchInfo: libre2PatchInfo), sensorUID: sensorUID),
                       .alreadyStarted(.ready))
        XCTAssertTrue(LibreSensorActivation.isStarted(.starting))
        XCTAssertTrue(LibreSensorActivation.isStarted(.ready))
        XCTAssertFalse(LibreSensorActivation.isStarted(.notYetStarted))
        XCTAssertFalse(LibreSensorActivation.isStarted(.expired))
    }

    func testAMisreadStateSendsNothing() {
        // Plain FRAM read as a Libre 2 decrypts to garbage, so its header crc fails.
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: libre2PatchInfo, fram: plainFRAM(state: 1), sensorUID: sensorUID),
                       .unsupported(.unreadable))
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: libre1PatchInfo, fram: Data(repeating: 0, count: 100), sensorUID: sensorUID),
                       .unsupported(.unreadable))
    }

    func testSensorsThatNeedAbbottsCodeAreRefused() {
        let gen2 = Data([0x9D, 0x08, 0x39, 0x01, 0x00, 0x00])
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: gen2, fram: libre2FRAM(state: 1, patchInfo: gen2), sensorUID: sensorUID),
                       .unsupported(.libre2Gen2))
        let us14 = Data([0xE5, 0x00, 0x03, 0x02, 0x00, 0x00])
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: us14, fram: plainFRAM(state: 1), sensorUID: sensorUID), .unsupported(.libreUS14Day))
        let pro = Data([0x70, 0x00, 0x10, 0x00, 0x00, 0x00])
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: pro, fram: plainFRAM(state: 1), sensorUID: sensorUID), .unsupported(.librePro))
        let libre3 = Data(repeating: 0xA5, count: 24)
        XCTAssertTrue(LibreSensorActivation.isLibre3(patchInfo: libre3))
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: libre3, fram: plainFRAM(state: 1), sensorUID: sensorUID), .unsupported(.libre3))
        let unknown = Data([0x2C, 0x0A, 0x3A, 0x02, 0x00, 0x00])
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: unknown, fram: plainFRAM(state: 1), sensorUID: sensorUID), .unsupported(.unknownType))
        XCTAssertEqual(LibreSensorActivation.plan(patchInfo: Data(), fram: plainFRAM(state: 1), sensorUID: sensorUID), .unsupported(.unknownType))
    }

    func testActivationIsOfferedOnLibreReaderScreensOnly() {
        XCTAssertTrue(BluetoothPeripheralDetailState.supportsLibreSensorActivation(.Libre2Type))
        XCTAssertTrue(BluetoothPeripheralDetailState.supportsLibreSensorActivation(.MiaoMiaoType))
        XCTAssertTrue(BluetoothPeripheralDetailState.supportsLibreSensorActivation(.BubbleType))
        XCTAssertFalse(BluetoothPeripheralDetailState.supportsLibreSensorActivation(.Libre3Type))
        XCTAssertFalse(BluetoothPeripheralDetailState.supportsLibreSensorActivation(.DexcomType))
        XCTAssertFalse(BluetoothPeripheralDetailState.supportsLibreSensorActivation(.Sibionics2Type))
        for reason in [LibreSensorActivation.Unsupported.libre3, .libre2Gen2, .libreUS14Day, .librePro, .unknownType, .unreadable] {
            XCTAssertFalse(BluetoothPeripheralDetailState.libreActivationMessage(for: reason).isEmpty)
        }
    }
}
