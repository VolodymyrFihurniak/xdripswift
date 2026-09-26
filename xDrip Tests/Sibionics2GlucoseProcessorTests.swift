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

    func testV116AStockPathMatchesSibionics2StartupFixture() throws {
        let rows = try startupRows()
        for mode in [Sibionics2ProcessingMode.live, .replay] {
            var processor = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            var final: Sibionics2ProcessedReading?
            for row in rows {
                let result = processor.process(row.reading(), mode: mode)
                // Zero in the upstream CSV means no exact core correction at this
                // minute. It does not mean a zero glucose reading. The wrapper's
                // supported between-stage behavior must be specified separately.
                if row.exactMmol > 0 {
                    let value = try XCTUnwrap(result, "Missing correction at \(row.index)")
                    XCTAssertEqual(value.glucoseMgDl, row.exactMmol * 18.0, accuracy: 0.0001)
                    XCTAssertEqual(value.index, row.index)
                    XCTAssertEqual(value.eventTime, row.reading().eventTime)
                    XCTAssertEqual(value.trend, .stable)
                }
                if row.index == 130 { final = result }
            }
            let value = try XCTUnwrap(final)
            XCTAssertEqual(value.glucoseMgDl, 64.8, accuracy: 0.0001)
            XCTAssertEqual(value.glucoseMgDl / 18.0, 3.6, accuracy: 0.0001)
            XCTAssertNotEqual(value.glucoseMgDl, 1.3 * 18.0)
        }
    }

    func testWarmupDoesNotPublishRawGlucose() throws {
        let rows = try startupRows()
        // The upstream exact core has no output in its initial four samples.
        // This checks initial core warm-up, not a guessed clinical warm-up time.
        for mode in [Sibionics2ProcessingMode.live, .replay] {
            var processor = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            for row in rows.prefix(4) {
                XCTAssertEqual(row.exactMmol, 0)
                XCTAssertNil(processor.process(row.reading(), mode: mode))
            }
        }
    }

    func testRejectsInvalidOrOutOfRangeRawValues() throws {
        let rows = try startupRows()
        for invalid in [Double.nan, Double.infinity, -Double.infinity,
                        0, -1, Double.greatestFiniteMagnitude] {
            var subject = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            var control = Sibionics2GlucoseProcessor(sensitivity: 1.44)
            for row in rows.prefix(129) {
                _ = subject.process(row.reading(), mode: .replay)
                _ = control.process(row.reading(), mode: .replay)
            }
            let last = try XCTUnwrap(rows.last)
            XCTAssertNil(subject.process(last.reading(rawOverride: invalid), mode: .live))
            // A rejected sample must not poison or advance the valid state.
            let afterRejected = try XCTUnwrap(subject.process(last.reading(), mode: .live))
            let expected = try XCTUnwrap(control.process(last.reading(), mode: .live))
            XCTAssertEqual(afterRejected.glucoseMgDl, expected.glucoseMgDl)
            XCTAssertEqual(afterRejected.index, expected.index)
        }
    }

    func testSnapshotRestoresTheSameNextReading() throws {
        let rows = try startupRows()
        var uninterrupted = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        for row in rows.prefix(129) {
            _ = uninterrupted.process(row.reading(), mode: .replay)
        }
        var restored = Sibionics2GlucoseProcessor(sensitivity: 1.44)
        XCTAssertTrue(restored.restore(from: uninterrupted.snapshot()))
        let next = try XCTUnwrap(rows.last)
        // Both paths must produce a real correction, not two nil results.
        let expected = try XCTUnwrap(uninterrupted.process(next.reading(), mode: .live))
        let actual = try XCTUnwrap(restored.process(next.reading(), mode: .live))
        XCTAssertEqual(actual.glucoseMgDl, expected.glucoseMgDl)
        XCTAssertEqual(actual.glucoseMgDl, 64.8, accuracy: 0.0001)
        XCTAssertEqual(actual.index, expected.index)
        XCTAssertEqual(actual.eventTime, expected.eventTime)
        XCTAssertEqual(actual.trend, expected.trend)
    }
}
