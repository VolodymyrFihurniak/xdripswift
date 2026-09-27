//
// Sibionics2GlucoseProcessorTests.swift
// Fixture facts adapted from ctqvva/JugglucoNG, GPL-3.0.
// See THIRD_PARTY_NOTICES.md for pinned provenance.
//

import Foundation
import XCTest
@testable import xdrip

final class Sibionics2GlucoseProcessorTests: XCTestCase {
    private struct Row {
        let index: Int
        let rawMmol: Double
        let temperatureC: Double
        let exactMmol: Double

        func reading(rawOverride: Double? = nil) -> Sibionics2RawReading {
            Sibionics2RawReading(
                index: index,
                eventTime: Date(timeIntervalSince1970: TimeInterval(index * 60)),
                temperatureC: temperatureC,
                impedance: 0,
                rawMmol: rawOverride ?? rawMmol,
                trend: .stable,
                reindex: 0
            )
        }
    }

    private func startupRows() throws -> [Row] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "sibionics2_v116a_startup", withExtension: "csv"
        ))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.hasPrefix("#") }
        XCTAssertEqual(String(lines.first ?? ""), "index,raw_mmol,temperature_c,exact_mmol")
        let rows: [Row] = try lines.dropFirst().map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            XCTAssertEqual(fields.count, 4)
            guard fields.count == 4 else {
                throw NSError(domain: "Sibionics2Fixture", code: 1)
            }
            return Row(
                index: try XCTUnwrap(Int(fields[0])),
                rawMmol: try XCTUnwrap(Double(fields[1])),
                temperatureC: try XCTUnwrap(Double(fields[2])),
                exactMmol: try XCTUnwrap(Double(fields[3]))
            )
        }
        XCTAssertEqual(rows.map(\.index), Array(1...130))
        return rows
    }

    // Expected values come from the licensed fixture's exact corrections plus
    // the reference wrapper rule. They are never taken from the processor.
    private func expectedDisplayMmol(_ rows: [Row]) -> [Double?] {
        var stockDelta: Float?
        return rows.map { row in
            if row.exactMmol > 0 {
                stockDelta = Float(row.exactMmol) - Float(row.rawMmol)
                return row.exactMmol
            }
            guard let delta = stockDelta else { return nil }
            let scaled = (Float(row.rawMmol) + delta) * 10
            return Double(Int(scaled + 0.5)) / 10
        }
    }

    func testV116AStockPathMatchesSibionics2StartupFixture() throws {
        let rows = try startupRows()
        let expected = expectedDisplayMmol(rows)
        XCTAssertEqual(expected.compactMap { $0 }.count, 126)
        XCTAssertEqual(try XCTUnwrap(expected[5]), 10.5)
        XCTAssertEqual(try XCTUnwrap(expected[80]), 3.9)
        for mode in [Sibionics2ProcessingMode.live, .replay] {
            var processor = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            for (row, mmol) in zip(rows, expected) {
                let result = processor.process(row.reading(), mode: mode)
                guard let mmol else {
                    XCTAssertNil(result, "No stock correction at \(row.index)")
                    continue
                }
                let value = try XCTUnwrap(result, "Missing display at \(row.index)")
                XCTAssertEqual(value.glucoseMgDl, mmol * 18.0, accuracy: 0.0001,
                               "Stock display at \(row.index)")
                XCTAssertEqual(value.index, row.index)
                XCTAssertEqual(value.eventTime, row.reading().eventTime)
                XCTAssertEqual(value.trend, .stable)
                // All corrected rows in this fixture differ from raw values.
                XCTAssertNotEqual(value.glucoseMgDl, row.rawMmol * 18.0)
                if row.index == 130 {
                    XCTAssertEqual(value.glucoseMgDl, 64.8, accuracy: 0.0001)
                }
            }
        }
    }

    func testFactoryShortCodeResolvesKnownV116AFallbackVector() throws {
        let sensitivity = try XCTUnwrap(
            Sibionics2FactorySensitivity.decodeShortCode("0316015A")
        )
        XCTAssertEqual(sensitivity, 1.44, accuracy: 0.0001)
    }

    func testWarmupDoesNotPublishRawGlucose() throws {
        let rows = try startupRows()
        for mode in [Sibionics2ProcessingMode.live, .replay] {
            var processor = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            // Initial exact-core state, not an assumed clinical warm-up period.
            for row in rows.prefix(4) {
                XCTAssertNil(processor.process(row.reading(), mode: mode))
            }
        }
    }

    func testRejectsInvalidOrOutOfRangeRawValues() throws {
        let rows = try startupRows()
        let expected = expectedDisplayMmol(rows)
        for nextIndex in [6, 81, 130] {
            for invalid in [Double.nan, Double.infinity, -Double.infinity,
                            0, -1, 6553.6, Double.greatestFiniteMagnitude] {
                var subject = Sibionics2GlucoseProcessor(sensitivity: 1.44)
                var control = Sibionics2GlucoseProcessor(sensitivity: 1.44)
                for row in rows.prefix(nextIndex - 1) {
                    _ = subject.process(row.reading(), mode: .replay)
                    _ = control.process(row.reading(), mode: .replay)
                }
                let next = rows[nextIndex - 1]
                // 6553.6 is outside the protocol's UInt16 / 10 raw domain.
                XCTAssertNil(subject.process(next.reading(rawOverride: invalid), mode: .live))
                // Rejection must not poison state, consume this index, lose the
                // held stock offset, or force a raw-value fallback.
                let recovered = try XCTUnwrap(subject.process(next.reading(), mode: .live))
                let uninterrupted = try XCTUnwrap(control.process(next.reading(), mode: .live))
                XCTAssertEqual(recovered.glucoseMgDl, uninterrupted.glucoseMgDl)
                XCTAssertEqual(recovered.glucoseMgDl,
                               try XCTUnwrap(expected[nextIndex - 1]) * 18, accuracy: 0.0001)
            }
        }
    }

    func testSnapshotRestoresTheSameNextReading() throws {
        let rows = try startupRows()
        let expected = expectedDisplayMmol(rows)
        // Both intermediate-minute continuation and exact correction state.
        for checkpoint in [5, 70, 129] {
            var uninterrupted = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            for row in rows.prefix(checkpoint) {
                _ = uninterrupted.process(row.reading(), mode: .replay)
            }
            let snapshot = uninterrupted.snapshot()
            XCTAssertEqual(snapshot.count, 5_040,
                           "Checkpoint \(checkpoint) must contain the 28-byte Swift envelope, 5008-byte core hex, and checksum")
            var restored = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            XCTAssertTrue(restored.restore(from: snapshot),
                          "Failed to restore Sibionics processor checkpoint \(checkpoint)")
            for row in rows.dropFirst(checkpoint) {
                let control = try XCTUnwrap(uninterrupted.process(row.reading(), mode: .live))
                let actual = try XCTUnwrap(restored.process(row.reading(), mode: .live))
                XCTAssertEqual(actual.glucoseMgDl, control.glucoseMgDl)
                XCTAssertEqual(actual.glucoseMgDl,
                               try XCTUnwrap(expected[row.index - 1]) * 18, accuracy: 0.0001)
                XCTAssertEqual(actual.index, control.index)
                XCTAssertEqual(actual.eventTime, control.eventTime)
                XCTAssertEqual(actual.trend, control.trend)
            }
        }
    }

    func testSnapshotChecksumRejectsHeaderAndPayloadCorruptionWithoutChangingState() throws {
        let rows = try startupRows()
        var checkpoint = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        for row in rows.prefix(70) {
            _ = checkpoint.process(row.reading(), mode: .replay)
        }
        let snapshot = checkpoint.snapshot()

        // Keep the core snapshot's own magic/version/sensitivity intact while
        // changing a context nibble. It remains well-formed hex and is rejected
        // by the wrapper integrity checksum.
        var payloadMutation = snapshot
        let contextHexOffset = 28 + (12 * 2)
        payloadMutation[contextHexOffset] = payloadMutation[contextHexOffset] == 0x30 ? 0x31 : 0x30

        // Flip one low bit of the serialized live correction delta.
        var headerMutation = snapshot
        headerMutation[16] ^= 0x01

        for corrupted in [payloadMutation, headerMutation] {
            var subject = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            var control = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            for row in rows.prefix(70) {
                _ = subject.process(row.reading(), mode: .replay)
                _ = control.process(row.reading(), mode: .replay)
            }
            let stateBeforeRestore = subject.snapshot()
            XCTAssertFalse(subject.restore(from: corrupted))
            XCTAssertEqual(subject.snapshot(), stateBeforeRestore,
                           "A rejected snapshot must leave the processor unchanged")
            let next = rows[70].reading()
            let actual = try XCTUnwrap(subject.process(next, mode: .live))
            let expected = try XCTUnwrap(control.process(next, mode: .live))
            XCTAssertEqual(actual.glucoseMgDl, expected.glucoseMgDl)
            XCTAssertEqual(actual.index, expected.index)
        }
    }

    func testSnapshotRejectsCorruptionVersionAndDifferentSensitivity() throws {
        let rows = try startupRows()
        var source = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        for row in rows.prefix(70) {
            _ = source.process(row.reading(), mode: .replay)
        }
        let snapshot = source.snapshot()

        var wrongSensitivity = Sibionics2GlucoseProcessor(sensitivity: 1.43)
        XCTAssertFalse(wrongSensitivity.restore(from: snapshot))

        var badVersion = snapshot
        badVersion[5] = 3
        var versionTarget = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        XCTAssertFalse(versionTarget.restore(from: badVersion))

        var truncated = snapshot
        truncated.removeLast()
        var truncatedTarget = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        XCTAssertFalse(truncatedTarget.restore(from: truncated))

        var trailing = snapshot
        trailing.append(UInt8(0))
        var trailingTarget = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        XCTAssertFalse(trailingTarget.restore(from: trailing))
    }

    func testRejectsUnsupportedExplicitSensitivityWithoutFallback() throws {
        let rows = try startupRows()
        // Validate the caller's Double before narrowing to Float or adjusting
        // factory sensitivity. Resolving absent factory codes is a separate API.
        for sensitivity in [Double.nan, Double.infinity, -Double.infinity, 0, -1,
                            Double(0.8).nextDown, Double(2.5).nextUp] {
            var processor = Sibionics2GlucoseProcessor(sensitivity: sensitivity)
            for row in rows {
                XCTAssertNil(processor.process(row.reading(), mode: .replay))
            }
        }
        XCTAssertTrue(Sibionics2FactorySensitivity.isSupported(0.8))
        XCTAssertTrue(Sibionics2FactorySensitivity.isSupported(2.5))
        XCTAssertFalse(Sibionics2FactorySensitivity.isSupported(Double(0.8).nextDown))
        XCTAssertFalse(Sibionics2FactorySensitivity.isSupported(Double(2.5).nextUp))
    }

    func testFactoryProbeSensitivityMatchesLicensedNativeVectors() throws {
        // JugglucoNG probe-sensitivity-native.tsv and ProbeSensitivityTest.
        for (code, expected) in [
            ("EU2VCZUQPSHD5Q", 1.73), ("145TUMXYK4S46V", 1.75),
            ("XPT1EEX2NRU16U", 1.26), ("EU2VMGLQPSHD57", 0.8),
            ("EU2VWR4QPSHD6A", 2.5)
        ] {
            XCTAssertEqual(try XCTUnwrap(Sibionics2FactorySensitivity.decodeProbe(code)),
                           expected, accuracy: 0.00001)
        }
    }

    func testFactoryProbeRejectsMalformedAndSingleCharacterCorruptions() {
        for code: String? in [
            nil, "", "EU2VCZUQPSHD5", "EU2VCZUQPSHD5QQ", "eu2vczuqpshd5q",
            "EU2VCZUQPSHD50", "EU2VCZUQPSHD5I", "J45TUMXYK4S46V",
            "EU2VYYTQPSHD69", "145TGCFYK4S46Q"
        ] {
            XCTAssertNil(Sibionics2FactorySensitivity.decodeProbe(code))
        }
        let alphabet = Array("123456789ACDEFGHJKLMNPQRSTUVWXYZ")
        for code in ["EU2VCZUQPSHD5Q", "145TUMXYK4S46V"] {
            let characters = Array(code)
            for index in characters.indices {
                for replacement in alphabet where replacement != characters[index] {
                    var corrupted = characters
                    corrupted[index] = replacement
                    XCTAssertNil(Sibionics2FactorySensitivity.decodeProbe(String(corrupted)))
                }
            }
        }
    }

    func testSensitivityUsesAdvertisedNameWithoutManualCodeEntry() {
        XCTAssertEqual(
            Sibionics2FactorySensitivity.resolve(advertisedName: "0401671KCJ2"),
            1.37,
            accuracy: 0.00001
        )
        XCTAssertEqual(Sibionics2FactorySensitivity.resolve(advertisedName: nil),
                       1.44, accuracy: 0.00001)
        XCTAssertEqual(Sibionics2FactorySensitivity.resolve(advertisedName: "P225044UHA"),
                       1.44, accuracy: 0.00001)
    }

    func testFactorySensitivityUsesProbeThenShortCodeThenDocumentedFallback() throws {
        XCTAssertEqual(Sibionics2FactorySensitivity.resolve(
            probeCode: "EU2VCZUQPSHD5Q", shortCode: "0316015A"), 1.73, accuracy: 0.00001)
        XCTAssertEqual(Sibionics2FactorySensitivity.resolve(
            probeCode: "invalid", shortCode: "1440"), 1.44, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(Sibionics2FactorySensitivity.decodeShortCode("0316015A")),
                       1.44, accuracy: 0.00001)
        XCTAssertEqual(Sibionics2FactorySensitivity.resolve(
            probeCode: nil, shortCode: nil), 1.44, accuracy: 0.00001)
        XCTAssertEqual(Sibionics2FactorySensitivity.resolve(
            probeCode: "invalid", shortCode: "9999"), 1.44, accuracy: 0.00001)
    }
}
