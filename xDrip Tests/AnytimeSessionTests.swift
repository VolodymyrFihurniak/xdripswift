//
//  AnytimeSessionTests.swift
//  xdripTests
//
//  Expected values come from running the unchanged JugglucoNG Kotlin (`drivers/anytime`: the connect
//  retry policy, the history backfill state, the CT5 live clock and raw scale, the calibration policy and
//  the trend estimator) on the JVM with the same inputs. Float results are compared by their bit pattern
//  (`Float.floatToIntBits` there, `bitPattern` here). Never compared with a real sensor.
//

import XCTest
@testable import xdrip

final class AnytimeSessionTests: XCTestCase {

    private func d(_ range: AnytimeIdRange?) -> String {
        return range.map { $0.description } ?? "null"
    }

    private func fb(_ value: Float) -> String {
        return value.isNaN ? "NaN" : String(Int32(bitPattern: value.bitPattern))
    }

    private func family(_ name: String) -> AnytimeFamily {
        switch name {
        case "CT2": return .ct2
        case "CT2_5": return .ct25
        case "CT3": return .ct3
        case "CT3_PLUS": return .ct3Plus
        case "CT3_YUWELL": return .ct3Yuwell
        case "CT3_ULTRASONIC": return .ct3Ultrasonic
        case "CT4": return .ct4
        case "CT5": return .ct5
        default: return .unknown
        }
    }

    private let maxId = Int(Int32.max)

    // MARK: connect and session retry

    func testConnectRetryDelayDoublesUpToOneReadingInterval() {
        let cases: [(Int, Int64, Int64, String)] = [
            (-1, 2000, 180000, "2000"),
            (-1, 2000, 1000, "2000"),
            (-1, 0, 180000, "0"),
            (-1, 5000, 5000, "5000"),
            (-1, 1, 10000000000, "1"),
            (0, 2000, 180000, "2000"),
            (0, 2000, 1000, "2000"),
            (0, 0, 180000, "0"),
            (0, 5000, 5000, "5000"),
            (0, 1, 10000000000, "1"),
            (1, 2000, 180000, "4000"),
            (1, 2000, 1000, "2000"),
            (1, 0, 180000, "0"),
            (1, 5000, 5000, "5000"),
            (1, 1, 10000000000, "2"),
            (2, 2000, 180000, "8000"),
            (2, 2000, 1000, "2000"),
            (2, 0, 180000, "0"),
            (2, 5000, 5000, "5000"),
            (2, 1, 10000000000, "4"),
            (3, 2000, 180000, "16000"),
            (3, 2000, 1000, "2000"),
            (3, 0, 180000, "0"),
            (3, 5000, 5000, "5000"),
            (3, 1, 10000000000, "8"),
            (4, 2000, 180000, "32000"),
            (4, 2000, 1000, "2000"),
            (4, 0, 180000, "0"),
            (4, 5000, 5000, "5000"),
            (4, 1, 10000000000, "16"),
            (5, 2000, 180000, "64000"),
            (5, 2000, 1000, "2000"),
            (5, 0, 180000, "0"),
            (5, 5000, 5000, "5000"),
            (5, 1, 10000000000, "32"),
            (10, 2000, 180000, "180000"),
            (10, 2000, 1000, "2000"),
            (10, 0, 180000, "0"),
            (10, 5000, 5000, "5000"),
            (10, 1, 10000000000, "1024"),
            (30, 2000, 180000, "180000"),
            (30, 2000, 1000, "2000"),
            (30, 0, 180000, "0"),
            (30, 5000, 5000, "5000"),
            (30, 1, 10000000000, "1073741824"),
            (40, 2000, 180000, "180000"),
            (40, 2000, 1000, "2000"),
            (40, 0, 180000, "0"),
            (40, 5000, 5000, "5000"),
            (40, 1, 10000000000, "1073741824")
        ]
        for (count, base, interval, expected) in cases {
            XCTAssertEqual(String(AnytimeConnectPolicy.connectRetryDelayMs(consecutiveConnectTimeouts: count, baseDelayMs: base, readingIntervalMs: interval)), expected, "n=\(count) base=\(base) interval=\(interval)")
        }
    }

    func testSessionRetryDelayDoublesUpToTheCap() {
        let cases: [(Int, Int64, Int64, String)] = [
            (-1, 2000, 30000, "2000"),
            (-1, 2000, 1000, "2000"),
            (-1, 0, 30000, "0"),
            (-1, 500, 30000, "500"),
            (0, 2000, 30000, "2000"),
            (0, 2000, 1000, "2000"),
            (0, 0, 30000, "0"),
            (0, 500, 30000, "500"),
            (1, 2000, 30000, "4000"),
            (1, 2000, 1000, "2000"),
            (1, 0, 30000, "0"),
            (1, 500, 30000, "1000"),
            (2, 2000, 30000, "8000"),
            (2, 2000, 1000, "2000"),
            (2, 0, 30000, "0"),
            (2, 500, 30000, "2000"),
            (3, 2000, 30000, "16000"),
            (3, 2000, 1000, "2000"),
            (3, 0, 30000, "0"),
            (3, 500, 30000, "4000"),
            (4, 2000, 30000, "30000"),
            (4, 2000, 1000, "2000"),
            (4, 0, 30000, "0"),
            (4, 500, 30000, "8000"),
            (5, 2000, 30000, "30000"),
            (5, 2000, 1000, "2000"),
            (5, 0, 30000, "0"),
            (5, 500, 30000, "16000"),
            (10, 2000, 30000, "30000"),
            (10, 2000, 1000, "2000"),
            (10, 0, 30000, "0"),
            (10, 500, 30000, "30000"),
            (30, 2000, 30000, "30000"),
            (30, 2000, 1000, "2000"),
            (30, 0, 30000, "0"),
            (30, 500, 30000, "30000"),
            (40, 2000, 30000, "30000"),
            (40, 2000, 1000, "2000"),
            (40, 0, 30000, "0"),
            (40, 500, 30000, "30000")
        ]
        for (count, base, cap, expected) in cases {
            XCTAssertEqual(String(AnytimeConnectPolicy.sessionRetryDelayMs(consecutiveFailedSessions: count, baseDelayMs: base, capMs: cap)), expected, "n=\(count) base=\(base) cap=\(cap)")
        }
    }

    func testTimeoutStatusesAndAutoConnect() {
        XCTAssertEqual(AnytimeConnectPolicy.isConnectTimeoutStatus(147), true, "status 147")
        XCTAssertEqual(AnytimeConnectPolicy.isConnectTimeoutStatus(133), true, "status 133")
        XCTAssertEqual(AnytimeConnectPolicy.isConnectTimeoutStatus(0), false, "status 0")
        XCTAssertEqual(AnytimeConnectPolicy.isConnectTimeoutStatus(8), false, "status 8")
        XCTAssertEqual(AnytimeConnectPolicy.isConnectTimeoutStatus(19), false, "status 19")
        XCTAssertEqual(AnytimeConnectPolicy.isConnectTimeoutStatus(62), false, "status 62")
        XCTAssertEqual(AnytimeConnectPolicy.shouldUseAutoConnect(userSetting: false, directConnectUnreachable: false), false)
        XCTAssertEqual(AnytimeConnectPolicy.shouldUseAutoConnect(userSetting: false, directConnectUnreachable: true), true)
        XCTAssertEqual(AnytimeConnectPolicy.shouldUseAutoConnect(userSetting: true, directConnectUnreachable: false), true)
        XCTAssertEqual(AnytimeConnectPolicy.shouldUseAutoConnect(userSetting: true, directConnectUnreachable: true), true)
    }

    func testConnectModeStateScenario() {
        let state = AnytimeConnectModeState()
        let operations = ["d147c", "d133c", "d8c", "d147l", "c0", "d147c", "c1", "c0", "d133c", "d133c", "d62c", "c1", "d147c", "c0"]
        let expected = [
            "1/true/true/true/4000",
            "2/true/true/true/8000",
            "0/true/true/true/2000",
            "0/true/true/true/2000",
            "0/false/false/true/2000",
            "1/true/true/true/4000",
            "0/true/true/true/2000",
            "0/false/false/true/2000",
            "1/true/true/true/4000",
            "2/true/true/true/8000",
            "0/true/true/true/2000",
            "0/true/true/true/2000",
            "1/true/true/true/4000",
            "0/false/false/true/2000"
        ]
        for (index, operation) in operations.enumerated() {
            if operation.hasPrefix("d") {
                let status = Int(operation.dropFirst().dropLast())!
                state.onDisconnected(status: status, wasConnecting: operation.hasSuffix("c"))
            } else {
                state.onConnected(usedAutoConnect: operation == "c1")
            }
            let text = "\(state.consecutiveConnectTimeouts)/\(state.directConnectUnreachable)/\(state.useAutoConnect(userSetting: false))/\(state.useAutoConnect(userSetting: true))/\(state.retryDelayMs(baseDelayMs: 2000, readingIntervalMs: 180000))"
            XCTAssertEqual(text, expected[index], "step \(index) \(operation)")
        }
    }

    func testSessionChurnScenario() {
        let state = AnytimeSessionChurnState()
        let operations = ["e0", "e0", "e0", "e0", "e0", "e0", "e1", "e0", "e0", "d", "e0", "e0", "e0", "e0", "e0", "e0", "e0"]
        let expected = [
            "1/4000/4000",
            "2/8000/5000",
            "3/16000/5000",
            "4/30000/5000",
            "5/30000/5000",
            "6/30000/5000",
            "0/2000/2000",
            "1/4000/4000",
            "2/8000/5000",
            "0/2000/2000",
            "1/4000/4000",
            "2/8000/5000",
            "3/16000/5000",
            "4/30000/5000",
            "5/30000/5000",
            "6/30000/5000",
            "7/30000/5000"
        ]
        for (index, operation) in operations.enumerated() {
            switch operation {
            case "e0": state.onSessionEnded(deliveredData: false)
            case "e1": state.onSessionEnded(deliveredData: true)
            default: state.onSessionDeliveredData()
            }
            let text = "\(state.consecutiveFailedSessions)/\(state.retryDelayMs(baseDelayMs: 2000))/\(state.retryDelayMs(baseDelayMs: 2000, capMs: 5000))"
            XCTAssertEqual(text, expected[index], "step \(index) \(operation)")
        }
    }

    // MARK: gap arithmetic

    func testReconnectGap() {
        let cases: [(Int, Int, Int, String)] = [
            (-1, 0, 0, "null"),
            (-1, 0, 1, "null"),
            (-1, 0, 5, "null"),
            (-1, 0, 480, "null"),
            (-1, 1, 0, "null"),
            (-1, 1, 1, "null"),
            (-1, 1, 5, "null"),
            (-1, 1, 480, "null"),
            (-1, 100, 0, "null"),
            (-1, 100, 1, "null"),
            (-1, 100, 5, "null"),
            (-1, 100, 480, "null"),
            (-1, 101, 0, "null"),
            (-1, 101, 1, "null"),
            (-1, 101, 5, "null"),
            (-1, 101, 480, "null"),
            (-1, 102, 0, "null"),
            (-1, 102, 1, "null"),
            (-1, 102, 5, "null"),
            (-1, 102, 480, "null"),
            (-1, 291, 0, "null"),
            (-1, 291, 1, "null"),
            (-1, 291, 5, "null"),
            (-1, 291, 480, "null"),
            (-1, 1000, 0, "null"),
            (-1, 1000, 1, "null"),
            (-1, 1000, 5, "null"),
            (-1, 1000, 480, "null"),
            (0, 0, 0, "null"),
            (0, 0, 1, "null"),
            (0, 0, 5, "null"),
            (0, 0, 480, "null"),
            (0, 1, 0, "null"),
            (0, 1, 1, "null"),
            (0, 1, 5, "null"),
            (0, 1, 480, "null"),
            (0, 100, 0, "99..99"),
            (0, 100, 1, "99..99"),
            (0, 100, 5, "95..99"),
            (0, 100, 480, "1..99"),
            (0, 101, 0, "100..100"),
            (0, 101, 1, "100..100"),
            (0, 101, 5, "96..100"),
            (0, 101, 480, "1..100"),
            (0, 102, 0, "101..101"),
            (0, 102, 1, "101..101"),
            (0, 102, 5, "97..101"),
            (0, 102, 480, "1..101"),
            (0, 291, 0, "290..290"),
            (0, 291, 1, "290..290"),
            (0, 291, 5, "286..290"),
            (0, 291, 480, "1..290"),
            (0, 1000, 0, "999..999"),
            (0, 1000, 1, "999..999"),
            (0, 1000, 5, "995..999"),
            (0, 1000, 480, "520..999"),
            (100, 0, 0, "null"),
            (100, 0, 1, "null"),
            (100, 0, 5, "null"),
            (100, 0, 480, "null"),
            (100, 1, 0, "null"),
            (100, 1, 1, "null"),
            (100, 1, 5, "null"),
            (100, 1, 480, "null"),
            (100, 100, 0, "null"),
            (100, 100, 1, "null"),
            (100, 100, 5, "null"),
            (100, 100, 480, "null"),
            (100, 101, 0, "null"),
            (100, 101, 1, "null"),
            (100, 101, 5, "null"),
            (100, 101, 480, "null"),
            (100, 102, 0, "101..101"),
            (100, 102, 1, "101..101"),
            (100, 102, 5, "101..101"),
            (100, 102, 480, "101..101"),
            (100, 291, 0, "290..290"),
            (100, 291, 1, "290..290"),
            (100, 291, 5, "286..290"),
            (100, 291, 480, "101..290"),
            (100, 1000, 0, "999..999"),
            (100, 1000, 1, "999..999"),
            (100, 1000, 5, "995..999"),
            (100, 1000, 480, "520..999"),
            (288, 0, 0, "null"),
            (288, 0, 1, "null"),
            (288, 0, 5, "null"),
            (288, 0, 480, "null"),
            (288, 1, 0, "null"),
            (288, 1, 1, "null"),
            (288, 1, 5, "null"),
            (288, 1, 480, "null"),
            (288, 100, 0, "null"),
            (288, 100, 1, "null"),
            (288, 100, 5, "null"),
            (288, 100, 480, "null"),
            (288, 101, 0, "null"),
            (288, 101, 1, "null"),
            (288, 101, 5, "null"),
            (288, 101, 480, "null"),
            (288, 102, 0, "null"),
            (288, 102, 1, "null"),
            (288, 102, 5, "null"),
            (288, 102, 480, "null"),
            (288, 291, 0, "290..290"),
            (288, 291, 1, "290..290"),
            (288, 291, 5, "289..290"),
            (288, 291, 480, "289..290"),
            (288, 1000, 0, "999..999"),
            (288, 1000, 1, "999..999"),
            (288, 1000, 5, "995..999"),
            (288, 1000, 480, "520..999")
        ]
        for (known, live, maxRecords, expected) in cases {
            XCTAssertEqual(d(AnytimeHistoryPolicy.reconnectGap(highestKnownId: known, liveId: live, maxRecords: maxRecords)), expected, "gap \(known) \(live) \(maxRecords)")
        }
    }

    func testReconnectCatchupGap() {
        let cases: [(Int, Int, Int, String)] = [
            (-1, -1, -1, "null"),
            (-1, -1, 288, "null"),
            (-1, -1, 289, "null"),
            (-1, -1, 290, "null"),
            (-1, -1, 291, "null"),
            (-1, -1, 292, "null"),
            (-1, -1, 2147483647, "null"),
            (-1, 288, -1, "null"),
            (-1, 288, 288, "null"),
            (-1, 288, 289, "null"),
            (-1, 288, 290, "null"),
            (-1, 288, 291, "null"),
            (-1, 288, 292, "null"),
            (-1, 288, 2147483647, "null"),
            (-1, 289, -1, "null"),
            (-1, 289, 288, "null"),
            (-1, 289, 289, "null"),
            (-1, 289, 290, "null"),
            (-1, 289, 291, "null"),
            (-1, 289, 292, "null"),
            (-1, 289, 2147483647, "null"),
            (-1, 291, -1, "null"),
            (-1, 291, 288, "null"),
            (-1, 291, 289, "null"),
            (-1, 291, 290, "null"),
            (-1, 291, 291, "null"),
            (-1, 291, 292, "null"),
            (-1, 291, 2147483647, "null"),
            (100, -1, -1, "null"),
            (100, -1, 288, "101..288"),
            (100, -1, 289, "101..289"),
            (100, -1, 290, "101..290"),
            (100, -1, 291, "101..291"),
            (100, -1, 292, "101..292"),
            (100, -1, 2147483647, "null"),
            (100, 288, -1, "null"),
            (100, 288, 288, "101..287"),
            (100, 288, 289, "101..289"),
            (100, 288, 290, "101..290"),
            (100, 288, 291, "101..291"),
            (100, 288, 292, "101..292"),
            (100, 288, 2147483647, "null"),
            (100, 289, -1, "null"),
            (100, 289, 288, "101..287"),
            (100, 289, 289, "101..288"),
            (100, 289, 290, "101..290"),
            (100, 289, 291, "101..291"),
            (100, 289, 292, "101..292"),
            (100, 289, 2147483647, "null"),
            (100, 291, -1, "null"),
            (100, 291, 288, "101..287"),
            (100, 291, 289, "101..288"),
            (100, 291, 290, "101..289"),
            (100, 291, 291, "101..290"),
            (100, 291, 292, "101..292"),
            (100, 291, 2147483647, "null"),
            (288, -1, -1, "null"),
            (288, -1, 288, "null"),
            (288, -1, 289, "289..289"),
            (288, -1, 290, "289..290"),
            (288, -1, 291, "289..291"),
            (288, -1, 292, "289..292"),
            (288, -1, 2147483647, "null"),
            (288, 288, -1, "null"),
            (288, 288, 288, "null"),
            (288, 288, 289, "289..289"),
            (288, 288, 290, "289..290"),
            (288, 288, 291, "289..291"),
            (288, 288, 292, "289..292"),
            (288, 288, 2147483647, "null"),
            (288, 289, -1, "null"),
            (288, 289, 288, "null"),
            (288, 289, 289, "null"),
            (288, 289, 290, "289..290"),
            (288, 289, 291, "289..291"),
            (288, 289, 292, "289..292"),
            (288, 289, 2147483647, "null"),
            (288, 291, -1, "null"),
            (288, 291, 288, "null"),
            (288, 291, 289, "null"),
            (288, 291, 290, "289..289"),
            (288, 291, 291, "289..290"),
            (288, 291, 292, "289..292"),
            (288, 291, 2147483647, "null")
        ]
        for (known, observed, expected, result) in cases {
            XCTAssertEqual(d(AnytimeHistoryPolicy.ct5ReconnectCatchupGap(highestKnownId: known, lastObservedId: observed, expectedCurrentId: expected, maxRecords: 480)), result, "catchup \(known) \(observed) \(expected)")
        }
        XCTAssertEqual(d(AnytimeHistoryPolicy.ct5ReconnectCatchupGap(highestKnownId: 100, lastObservedId: 100, expectedCurrentId: 1000, maxRecords: 10)), "991..1000")
    }

    func testGapRemainder() {
        let cases: [(Int, Int, Int, Int, String)] = [
            (103, 100, 100, 105, "103..104"),
            (103, 100, 100, 103, "null"),
            (103, 100, -1, 5, "null"),
            (103, 100, 104, 104, "null"),
            (103, 100, 90, 120, "103..119"),
            (103, 104, 100, 105, "104..104"),
            (103, 104, 100, 103, "null"),
            (103, 104, -1, 5, "null"),
            (103, 104, 104, 104, "null"),
            (103, 104, 90, 120, "104..119"),
            (103, 109, 100, 105, "null"),
            (103, 109, 100, 103, "null"),
            (103, 109, -1, 5, "null"),
            (103, 109, 104, 104, "null"),
            (103, 109, 90, 120, "109..119"),
            (105, 100, 100, 105, "null"),
            (105, 100, 100, 103, "null"),
            (105, 100, -1, 5, "null"),
            (105, 100, 104, 104, "null"),
            (105, 100, 90, 120, "105..119"),
            (105, 104, 100, 105, "null"),
            (105, 104, 100, 103, "null"),
            (105, 104, -1, 5, "null"),
            (105, 104, 104, 104, "null"),
            (105, 104, 90, 120, "105..119"),
            (105, 109, 100, 105, "null"),
            (105, 109, 100, 103, "null"),
            (105, 109, -1, 5, "null"),
            (105, 109, 104, 104, "null"),
            (105, 109, 90, 120, "109..119"),
            (110, 100, 100, 105, "null"),
            (110, 100, 100, 103, "null"),
            (110, 100, -1, 5, "null"),
            (110, 100, 104, 104, "null"),
            (110, 100, 90, 120, "110..119"),
            (110, 104, 100, 105, "null"),
            (110, 104, 100, 103, "null"),
            (110, 104, -1, 5, "null"),
            (110, 104, 104, 104, "null"),
            (110, 104, 90, 120, "110..119"),
            (110, 109, 100, 105, "null"),
            (110, 109, 100, 103, "null"),
            (110, 109, -1, 5, "null"),
            (110, 109, 104, 104, "null"),
            (110, 109, 90, 120, "110..119")
        ]
        for (run, reached, from, stop, expected) in cases {
            XCTAssertEqual(d(AnytimeHistoryPolicy.gapRemainder(runStopBeforeId: run, reachedId: reached, pendingFromId: from, pendingStopBeforeId: stop)), expected, "remainder \(run) \(reached) \(from) \(stop)")
        }
    }

    func testBackfillCoversRange() {
        let cases: [(Int, Int, Int, Int, Bool)] = [
            (95, 103, 100, 103, true),
            (95, 103, 100, 105, false),
            (95, 103, 101, 103, true),
            (95, 105, 100, 103, true),
            (95, 105, 100, 105, true),
            (95, 105, 101, 103, true),
            (95, 2147483647, 100, 103, true),
            (95, 2147483647, 100, 105, true),
            (95, 2147483647, 101, 103, true),
            (100, 103, 100, 103, true),
            (100, 103, 100, 105, false),
            (100, 103, 101, 103, true),
            (100, 105, 100, 103, true),
            (100, 105, 100, 105, true),
            (100, 105, 101, 103, true),
            (100, 2147483647, 100, 103, true),
            (100, 2147483647, 100, 105, true),
            (100, 2147483647, 101, 103, true),
            (101, 103, 100, 103, false),
            (101, 103, 100, 105, false),
            (101, 103, 101, 103, true),
            (101, 105, 100, 103, false),
            (101, 105, 100, 105, false),
            (101, 105, 101, 103, true),
            (101, 2147483647, 100, 103, false),
            (101, 2147483647, 100, 105, false),
            (101, 2147483647, 101, 103, true)
        ]
        for (next, stop, from, gapStop, expected) in cases {
            XCTAssertEqual(AnytimeHistoryPolicy.backfillCoversRange(nextRequestId: next, stopBeforeId: stop, fromId: from, gapStopBeforeId: gapStop), expected, "covers \(next) \(stop) \(from) \(gapStop)")
        }
    }

    func testRemainingGapAndGapAfterBatch() {
        let remaining: [(Int, Int, Int, String)] = [
            (100, 110, -1, "100..109"),
            (100, 110, 99, "100..109"),
            (100, 110, 100, "101..109"),
            (100, 110, 104, "105..109"),
            (100, 110, 109, "null"),
            (100, 110, 110, "100..109"),
            (100, 110, 150, "100..109"),
            (-1, 5, -1, "null"),
            (-1, 5, 99, "null"),
            (-1, 5, 100, "null"),
            (-1, 5, 104, "null"),
            (-1, 5, 109, "null"),
            (-1, 5, 110, "null"),
            (-1, 5, 150, "null"),
            (105, 105, -1, "null"),
            (105, 105, 99, "null"),
            (105, 105, 100, "null"),
            (105, 105, 104, "null"),
            (105, 105, 109, "null"),
            (105, 105, 110, "null"),
            (105, 105, 150, "null"),
            (0, 1, -1, "0..0"),
            (0, 1, 99, "0..0"),
            (0, 1, 100, "0..0"),
            (0, 1, 104, "0..0"),
            (0, 1, 109, "0..0"),
            (0, 1, 110, "0..0"),
            (0, 1, 150, "0..0")
        ]
        let afterBatch: [(Int, Int, Int, String)] = [
            (100, 110, -1, "100..109"),
            (100, 110, 99, "100..109"),
            (100, 110, 100, "101..109"),
            (100, 110, 104, "105..109"),
            (100, 110, 109, "null"),
            (100, 110, 110, "100..109"),
            (100, 110, 150, "100..109"),
            (-1, 5, -1, "null"),
            (-1, 5, 99, "null"),
            (-1, 5, 100, "null"),
            (-1, 5, 104, "null"),
            (-1, 5, 109, "null"),
            (-1, 5, 110, "null"),
            (-1, 5, 150, "null"),
            (105, 105, -1, "null"),
            (105, 105, 99, "null"),
            (105, 105, 100, "null"),
            (105, 105, 104, "null"),
            (105, 105, 109, "null"),
            (105, 105, 110, "null"),
            (105, 105, 150, "null"),
            (0, 1, -1, "0..0"),
            (0, 1, 99, "0..0"),
            (0, 1, 100, "0..0"),
            (0, 1, 104, "0..0"),
            (0, 1, 109, "0..0"),
            (0, 1, 110, "0..0"),
            (0, 1, 150, "0..0")
        ]
        for (from, stop, imported, expected) in remaining {
            XCTAssertEqual(d(AnytimeHistoryPolicy.ct5RemainingGap(pendingFromId: from, pendingStopBeforeId: stop, highestImportedInRange: imported)), expected, "remaining \(from) \(stop) \(imported)")
        }
        for (from, stop, imported, expected) in afterBatch {
            XCTAssertEqual(d(AnytimeHistoryPolicy.ct5GapAfterBatch(pendingFromId: from, pendingStopBeforeId: stop, maxImportedId: imported)), expected, "afterBatch \(from) \(stop) \(imported)")
        }
    }

    func testMergeGap() {
        let cases: [(Int, Int, Int, Int, Int, String)] = [
            (-1, -1, 100, 105, 1, "104..104"),
            (-1, -1, 100, 105, 10, "100..104"),
            (-1, -1, 100, 105, 480, "100..104"),
            (100, 105, -1, -1, 1, "100..104"),
            (100, 105, -1, -1, 10, "100..104"),
            (100, 105, -1, -1, 480, "100..104"),
            (100, 105, 103, 110, 1, "109..109"),
            (100, 105, 103, 110, 10, "100..109"),
            (100, 105, 103, 110, 480, "100..109"),
            (100, 105, 90, 95, 1, "104..104"),
            (100, 105, 90, 95, 10, "95..104"),
            (100, 105, 90, 95, 480, "90..104"),
            (100, 105, 102, 104, 1, "104..104"),
            (100, 105, 102, 104, 10, "100..104"),
            (100, 105, 102, 104, 480, "100..104"),
            (0, 0, 0, 0, 1, "null"),
            (0, 0, 0, 0, 10, "null"),
            (0, 0, 0, 0, 480, "null"),
            (10, 20, 2000, 2500, 1, "2499..2499"),
            (10, 20, 2000, 2500, 10, "2490..2499"),
            (10, 20, 2000, 2500, 480, "2020..2499"),
            (100, 105, 105, 105, 1, "100..104"),
            (100, 105, 105, 105, 10, "100..104"),
            (100, 105, 105, 105, 480, "100..104"),
            (100, 105, 200, 100, 1, "100..104"),
            (100, 105, 200, 100, 10, "100..104"),
            (100, 105, 200, 100, 480, "100..104")
        ]
        for (currentFrom, currentStop, newFrom, newStop, maxRecords, expected) in cases {
            XCTAssertEqual(d(AnytimeHistoryPolicy.ct5MergeGap(currentFromId: currentFrom, currentStopBeforeId: currentStop, newFromId: newFrom, newStopBeforeId: newStop, maxRecords: maxRecords)), expected, "merge \(currentFrom) \(currentStop) \(newFrom) \(newStop) \(maxRecords)")
        }
    }

    func testMissingEnvelopeAndNewestMissingRange() {
        let cacheSets: [Set<Int>] = [[], [100, 101, 102], [100, 101, 103, 104, 105], [101, 102, 103, 104], [98, 99, 100, 107, 108, 109], [100, 101, 102, 103, 104, 105, 106, 107, 108, 109]]
        let envelopes: [(Int, Int, Int, String)] = [
            (0, 100, 110, "100..109"),
            (0, 100, 100, "null"),
            (0, -1, 5, "null"),
            (0, 98, 110, "98..109"),
            (1, 100, 110, "103..109"),
            (1, 100, 100, "null"),
            (1, -1, 5, "null"),
            (1, 98, 110, "98..109"),
            (2, 100, 110, "102..109"),
            (2, 100, 100, "null"),
            (2, -1, 5, "null"),
            (2, 98, 110, "98..109"),
            (3, 100, 110, "100..109"),
            (3, 100, 100, "null"),
            (3, -1, 5, "null"),
            (3, 98, 110, "98..109"),
            (4, 100, 110, "101..106"),
            (4, 100, 100, "null"),
            (4, -1, 5, "null"),
            (4, 98, 110, "101..106"),
            (5, 100, 110, "null"),
            (5, 100, 100, "null"),
            (5, -1, 5, "null"),
            (5, 98, 110, "98..99")
        ]
        let newest: [(Int, Int, Int, Int, String)] = [
            (0, 100, 110, 1, "109..109"),
            (0, 100, 110, 2, "108..109"),
            (0, 100, 110, 3, "107..109"),
            (0, 100, 110, 480, "100..109"),
            (0, 100, 100, 1, "null"),
            (0, 100, 100, 2, "null"),
            (0, 100, 100, 3, "null"),
            (0, 100, 100, 480, "null"),
            (0, -1, 5, 1, "null"),
            (0, -1, 5, 2, "null"),
            (0, -1, 5, 3, "null"),
            (0, -1, 5, 480, "null"),
            (0, 98, 110, 1, "109..109"),
            (0, 98, 110, 2, "108..109"),
            (0, 98, 110, 3, "107..109"),
            (0, 98, 110, 480, "98..109"),
            (1, 100, 110, 1, "109..109"),
            (1, 100, 110, 2, "108..109"),
            (1, 100, 110, 3, "107..109"),
            (1, 100, 110, 480, "103..109"),
            (1, 100, 100, 1, "null"),
            (1, 100, 100, 2, "null"),
            (1, 100, 100, 3, "null"),
            (1, 100, 100, 480, "null"),
            (1, -1, 5, 1, "null"),
            (1, -1, 5, 2, "null"),
            (1, -1, 5, 3, "null"),
            (1, -1, 5, 480, "null"),
            (1, 98, 110, 1, "109..109"),
            (1, 98, 110, 2, "108..109"),
            (1, 98, 110, 3, "107..109"),
            (1, 98, 110, 480, "103..109"),
            (2, 100, 110, 1, "109..109"),
            (2, 100, 110, 2, "108..109"),
            (2, 100, 110, 3, "107..109"),
            (2, 100, 110, 480, "106..109"),
            (2, 100, 100, 1, "null"),
            (2, 100, 100, 2, "null"),
            (2, 100, 100, 3, "null"),
            (2, 100, 100, 480, "null"),
            (2, -1, 5, 1, "null"),
            (2, -1, 5, 2, "null"),
            (2, -1, 5, 3, "null"),
            (2, -1, 5, 480, "null"),
            (2, 98, 110, 1, "109..109"),
            (2, 98, 110, 2, "108..109"),
            (2, 98, 110, 3, "107..109"),
            (2, 98, 110, 480, "106..109"),
            (3, 100, 110, 1, "109..109"),
            (3, 100, 110, 2, "108..109"),
            (3, 100, 110, 3, "107..109"),
            (3, 100, 110, 480, "105..109"),
            (3, 100, 100, 1, "null"),
            (3, 100, 100, 2, "null"),
            (3, 100, 100, 3, "null"),
            (3, 100, 100, 480, "null"),
            (3, -1, 5, 1, "null"),
            (3, -1, 5, 2, "null"),
            (3, -1, 5, 3, "null"),
            (3, -1, 5, 480, "null"),
            (3, 98, 110, 1, "109..109"),
            (3, 98, 110, 2, "108..109"),
            (3, 98, 110, 3, "107..109"),
            (3, 98, 110, 480, "105..109"),
            (4, 100, 110, 1, "106..106"),
            (4, 100, 110, 2, "105..106"),
            (4, 100, 110, 3, "104..106"),
            (4, 100, 110, 480, "101..106"),
            (4, 100, 100, 1, "null"),
            (4, 100, 100, 2, "null"),
            (4, 100, 100, 3, "null"),
            (4, 100, 100, 480, "null"),
            (4, -1, 5, 1, "null"),
            (4, -1, 5, 2, "null"),
            (4, -1, 5, 3, "null"),
            (4, -1, 5, 480, "null"),
            (4, 98, 110, 1, "106..106"),
            (4, 98, 110, 2, "105..106"),
            (4, 98, 110, 3, "104..106"),
            (4, 98, 110, 480, "101..106"),
            (5, 100, 110, 1, "null"),
            (5, 100, 110, 2, "null"),
            (5, 100, 110, 3, "null"),
            (5, 100, 110, 480, "null"),
            (5, 100, 100, 1, "null"),
            (5, 100, 100, 2, "null"),
            (5, 100, 100, 3, "null"),
            (5, 100, 100, 480, "null"),
            (5, -1, 5, 1, "null"),
            (5, -1, 5, 2, "null"),
            (5, -1, 5, 3, "null"),
            (5, -1, 5, 480, "null"),
            (5, 98, 110, 1, "99..99"),
            (5, 98, 110, 2, "98..99"),
            (5, 98, 110, 3, "98..99"),
            (5, 98, 110, 480, "98..99")
        ]
        for (index, from, stop, expected) in envelopes {
            XCTAssertEqual(d(AnytimeHistoryPolicy.ct5MissingEnvelope(pendingFromId: from, pendingStopBeforeId: stop, cachedIds: cacheSets[index])), expected, "envelope \(index) \(from) \(stop)")
        }
        for (index, from, stop, maxRecords, expected) in newest {
            XCTAssertEqual(d(AnytimeHistoryPolicy.ct5NewestMissingRange(pendingFromId: from, pendingStopBeforeId: stop, cachedIds: cacheSets[index], maxRecords: maxRecords)), expected, "newest \(index) \(from) \(stop) \(maxRecords)")
        }
    }

    func testRestoredIdsAndTimelineAnchor() {
        let rolled: [(Int, Int, Int, Bool)] = [
            (10, 100, 0, true),
            (10, 100, 50, true),
            (60, 100, 50, false),
            (-1, 100, 0, false),
            (10, -1, 0, false),
            (98, 100, 5, false),
            (94, 100, 5, true),
            (0, 5000, -3, true)
        ]
        let sanitize: [(Int, Int, Int, Int)] = [
            (500, 20, 50, 20),
            (500, 480, 50, 500),
            (-1, 20, 50, -1),
            (500, -1, 50, 500),
            (500, 500, 0, 500),
            (500, 449, 50, 449),
            (500, 450, 50, 500)
        ]
        let reanchor: [(Int, Int, Bool, Bool)] = [
            (-1, -1, false, false),
            (-1, -1, true, false),
            (-1, 5, false, false),
            (-1, 5, true, false),
            (0, -1, false, true),
            (0, -1, true, true),
            (0, 5, false, true),
            (0, 5, true, false),
            (5, -1, false, true),
            (5, -1, true, true),
            (5, 5, false, true),
            (5, 5, true, false),
            (6, -1, false, true),
            (6, -1, true, true),
            (6, 5, false, true),
            (6, 5, true, true)
        ]
        let restored: [(Int64, Int64, Int, Int64)] = [
            (5, 6, 7, 5),
            (0, 6, 7, 6),
            (0, 6, -1, 0),
            (0, 0, 7, 0),
            (-3, 6, 0, 6)
        ]
        for (live, previous, threshold, expected) in rolled {
            XCTAssertEqual(AnytimeHistoryPolicy.liveIdLooksRolledBack(liveId: live, previousMaxId: previous, rollbackThreshold: threshold), expected, "rolledBack \(live) \(previous) \(threshold)")
        }
        for (persisted, cached, threshold, expected) in sanitize {
            XCTAssertEqual(AnytimeHistoryPolicy.sanitizeRestoredGlucoseId(persistedLastId: persisted, cachedRawMaxId: cached, rollbackThreshold: threshold), expected, "sanitize \(persisted) \(cached) \(threshold)")
        }
        for (live, previous, have, expected) in reanchor {
            XCTAssertEqual(AnytimeHistoryPolicy.shouldReanchorTimeline(liveId: live, previousMaxId: previous, haveTimelineStart: have), expected, "reanchor \(live) \(previous) \(have)")
        }
        for (timeline, sensor, lastId, expected) in restored {
            XCTAssertEqual(AnytimeHistoryPolicy.restoredTimelineStartMs(persistedTimelineStartMs: timeline, persistedSensorStartMs: sensor, persistedLastGlucoseId: lastId), expected, "restored \(timeline) \(sensor) \(lastId)")
        }
    }

    func testProfileHistoryEndAppliesToEveryFamilyButCt5() {
        let cases: [(AnytimeFamily, Int, Int, Bool)] = [
            (.ct2, 100, 7695, false),
            (.ct2, 7695, 7695, true),
            (.ct2, 8000, 7695, true),
            (.ct2, 5, 0, false),
            (.ct2, 5, -1, false),
            (.ct25, 100, 7695, false),
            (.ct25, 7695, 7695, true),
            (.ct25, 8000, 7695, true),
            (.ct25, 5, 0, false),
            (.ct25, 5, -1, false),
            (.ct3, 100, 7695, false),
            (.ct3, 7695, 7695, true),
            (.ct3, 8000, 7695, true),
            (.ct3, 5, 0, false),
            (.ct3, 5, -1, false),
            (.ct3Plus, 100, 7695, false),
            (.ct3Plus, 7695, 7695, true),
            (.ct3Plus, 8000, 7695, true),
            (.ct3Plus, 5, 0, false),
            (.ct3Plus, 5, -1, false),
            (.ct3Yuwell, 100, 7695, false),
            (.ct3Yuwell, 7695, 7695, true),
            (.ct3Yuwell, 8000, 7695, true),
            (.ct3Yuwell, 5, 0, false),
            (.ct3Yuwell, 5, -1, false),
            (.ct3Ultrasonic, 100, 7695, false),
            (.ct3Ultrasonic, 7695, 7695, true),
            (.ct3Ultrasonic, 8000, 7695, true),
            (.ct3Ultrasonic, 5, 0, false),
            (.ct3Ultrasonic, 5, -1, false),
            (.ct4, 100, 7695, false),
            (.ct4, 7695, 7695, true),
            (.ct4, 8000, 7695, true),
            (.ct4, 5, 0, false),
            (.ct4, 5, -1, false),
            (.ct5, 100, 7695, false),
            (.ct5, 7695, 7695, false),
            (.ct5, 8000, 7695, false),
            (.ct5, 5, 0, false),
            (.ct5, 5, -1, false),
            (.unknown, 100, 7695, false),
            (.unknown, 7695, 7695, true),
            (.unknown, 8000, 7695, true),
            (.unknown, 5, 0, false),
            (.unknown, 5, -1, false)
        ]
        for (family, next, end, expected) in cases {
            XCTAssertEqual(AnytimeHistoryPolicy.shouldStopAtProfileHistoryEnd(family: family, nextId: next, profileEndNumber: end), expected, "\(family) \(next) \(end)")
        }
    }

    func testLinkSettledAndWindows() {
        let settled: [(Int64, Int64, Int64, Bool, Bool)] = [
            (0, 100, 10, false, false),
            (100, 109, 10, false, false),
            (100, 110, 10, false, true),
            (100, 200, 10, true, false),
            (-5, 200, 10, false, false)
        ]
        let windows: [(Int64, Int64, Int64, Bool, Bool)] = [
            (0, 100, 10, false, false),
            (100, 109, 10, true, true),
            (100, 110, 10, false, false),
            (100, 99, 10, false, false),
            (100, 100, 10, true, true),
            (100, 100, 0, false, false)
        ]
        for (since, now, settle, inFlight, expected) in settled {
            XCTAssertEqual(AnytimeHistoryPolicy.isCt5HistoryLinkSettled(streamingSinceMs: since, nowMs: now, settleMs: settle, writeInFlight: inFlight), expected, "settled \(since) \(now) \(settle) \(inFlight)")
        }
        for (since, now, window, deferred, recent) in windows {
            XCTAssertEqual(AnytimeHistoryPolicy.shouldDeferLossOfSignalReconnect(streamingSinceMs: since, nowMs: now, graceMs: window), deferred, "defer \(since) \(now) \(window)")
            XCTAssertEqual(AnytimeHistoryPolicy.hasRecentSensorData(lastSensorDataAtMs: since, nowMs: now, withinMs: window), recent, "recent \(since) \(now) \(window)")
        }
    }

    // MARK: write tags, response matching, priorities

    func testBackfillWriteTags() {
        XCTAssertEqual(AnytimeHistoryPolicy.backfillWriteTag(count: 15), "pullGlucose(backfill,count=15)")
        XCTAssertEqual(AnytimeHistoryPolicy.backfillWriteTagPrefix, "pullGlucose(backfill")
        XCTAssertEqual(AnytimeHistoryPolicy.isBackfillWriteTag("pullGlucose(backfill,count=3)"), true, "pullGlucose(backfill,count=3)")
        XCTAssertEqual(AnytimeHistoryPolicy.isBackfillWriteTag("pullGlucose(backfill"), true, "pullGlucose(backfill")
        XCTAssertEqual(AnytimeHistoryPolicy.isBackfillWriteTag("pullGlucose(live)"), false, "pullGlucose(live)")
        XCTAssertEqual(AnytimeHistoryPolicy.isBackfillWriteTag("ct5-pushAck"), false, "ct5-pushAck")
        XCTAssertEqual(AnytimeHistoryPolicy.isBackfillWriteTag(""), false, "")
    }

    func testResponseMatching() {
        let opcodes: [UInt8] = [0x03, 0x04, 0x05, 0x08, 0x07, 0x22, 0x37, 0x47, 0x55, 0x54, 0x58, 0x0A]
        let expected: [String] = [
            "110000000000",
            "110000000000",
            "001000000000",
            "000100000000",
            "000010000000",
            "000001000000",
            "000000100000",
            "000000010000",
            "000000010000",
            "000000000100",
            "000000000010",
            "000000000001"
        ]
        for (requestIndex, request) in opcodes.enumerated() {
            let row = opcodes.map { AnytimeHistoryPolicy.responseMatchesRequest(requestOpcode: request, responseOpcode: $0) ? "1" : "0" }.joined()
            XCTAssertEqual(row, expected[requestIndex], String(format: "request 0x%02X", request))
        }
    }

    func testWritePriorities() {
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "ct5-pushAck", historyReason: ""), .liveAck)
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "ct5-pushAck", historyReason: "ct5-gap"), .liveAck)
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "check", historyReason: "ct5-gap"), .control)
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "pullGlucose(backfill,count=3)", historyReason: "ct5-gap(289..290)"), .gapHistory)
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "pullGlucose(backfill,count=3)", historyReason: "ct5-reconnect-catchup"), .gapHistory)
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "pullGlucose(backfill,count=15)", historyReason: "reconnect"), .bulkHistory)
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "pullGlucose(backfill,count=15)", historyReason: "user-requested"), .bulkHistory)
        XCTAssertEqual(AnytimeHistoryPolicy.writePriority(tag: "pullGlucose(backfill", historyReason: ""), .bulkHistory)
        XCTAssertTrue(AnytimeHistoryPolicy.WritePriority.liveAck < .control)
        XCTAssertTrue(AnytimeHistoryPolicy.WritePriority.control < .gapHistory)
        XCTAssertTrue(AnytimeHistoryPolicy.WritePriority.gapHistory < .bulkHistory)
    }

    // MARK: caught-up cooldown

    func testCaughtUpCooldownScenario() {
        var clock: Int64 = 1_000_000
        let cooldown = AnytimeHistoryCaughtUpCooldown(cooldownMs: 60_000, nowMs: { clock })
        func check(_ tag: String, startId: Int = 120, stop: Int? = nil, reason: String = "reconnect", last: Int = 119) -> Bool {
            return cooldown.shouldSuppressBackfill(startId: startId, stopBeforeId: stop ?? maxId, reason: reason, lastGlucoseId: last)
        }
        XCTAssertEqual(check("fresh"), false)
        cooldown.markCaughtUp(nextRequestId: 120)
        XCTAssertEqual(check("justMarked"), true)
        XCTAssertEqual(check("userRequested", reason: "user-requested"), false)
        XCTAssertEqual(check("userRequestedFull", reason: "user-requested(full)"), false)
        XCTAssertEqual(check("boundedStop", stop: 130), false)
        XCTAssertEqual(check("startBelow", startId: 119), false)
        XCTAssertEqual(check("lastReached", last: 120), false)
        clock += 59_999
        XCTAssertEqual(check("beforeExpiry"), true)
        clock += 1
        XCTAssertEqual(check("atExpiry"), false)
        clock = 1_000_100
        XCTAssertEqual(check("clockBack"), true)
        clock = 1_000_000 - 5
        XCTAssertEqual(check("clockBeforeMark"), false)
        clock = 1_030_000
        cooldown.clearIfNewerData(glucoseId: 119)
        XCTAssertEqual(check("stillSuppressedAfterOlder"), true)
        cooldown.clearIfNewerData(glucoseId: 120)
        XCTAssertEqual(check("clearedByNewer"), false)
        cooldown.markCaughtUp(nextRequestId: -7)
        XCTAssertEqual(check("negativeNextClamped", startId: 0, last: -1), true)
        cooldown.clear()
        XCTAssertEqual(check("clearedExplicit", startId: 0, last: -1), false)
    }

    // MARK: history health, tally, failure tracker

    func testHistoryHealthScenario() {
        let health = AnytimeCt5HistoryHealth(maxTimeoutsPerConnection: 3, retryBackoffMs: 4000)
        func state() -> String { return "\(health.timeoutCount())/\(health.isPausedForThisConnection())" }
        func backoff(_ value: Int64?) -> String { return value.map { String($0) } ?? "null" }
        XCTAssertEqual(state(), "0/false")
        XCTAssertEqual(backoff(health.onTimeout()), "4000")
        XCTAssertEqual(state(), "1/false")
        XCTAssertEqual(backoff(health.onTimeout()), "8000")
        XCTAssertEqual(state(), "2/false")
        health.onSeriesReceived()
        XCTAssertEqual(state(), "0/false")
        XCTAssertEqual(backoff(health.onTimeout()), "4000")
        XCTAssertEqual(state(), "1/false")
        XCTAssertEqual(backoff(health.onTimeout()), "8000")
        XCTAssertEqual(state(), "2/false")
        XCTAssertEqual(backoff(health.onTimeout()), "null")
        XCTAssertEqual(state(), "3/true")
        health.onLinkSessionStarted()
        XCTAssertEqual(state(), "0/false")
        health.pauseForThisConnection()
        XCTAssertEqual(state(), "0/true")
        health.onLinkSessionStarted()
        XCTAssertEqual(state(), "0/false")
    }

    func testBatchTallyDescribesAHistoryPass() {
        let tally = AnytimeCt5HistoryBatchTally()
        XCTAssertEqual(tally.describe(firstId: 289, lastId: 290) + "|\(tally.total)", "CT5 history 289..290 received: 0 existing, 0 inserted, 0 warm-up/no-glucose|0")
        tally.countInserted()
        tally.countInserted()
        tally.countExisting()
        tally.countWarmup()
        XCTAssertEqual(tally.describe(firstId: 289, lastId: 290) + "|\(tally.total)", "CT5 history 289..290 received: 1 existing, 2 inserted, 1 warm-up/no-glucose|4")
        tally.countLiveRace()
        XCTAssertEqual(tally.describe(firstId: 1, lastId: 5) + "|\(tally.total)", "CT5 history 1..5 received: 1 existing, 2 inserted, 1 warm-up/no-glucose, 1 superseded by live|5")
    }

    func testGapFailureTrackerScenario() {
        let tracker = AnytimeCt5GapFailureTracker(maxFailedSessions: 3)
        func state(_ value: AnytimeIdRange?) -> String {
            let snapshot = tracker.snapshot().map { "AnytimeCt5GapFailureSnapshot(fromId=\($0.fromId), stopBeforeId=\($0.stopBeforeId), failures=\($0.failures))" } ?? "null"
            return "\(d(value))/\(snapshot)"
        }
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 100, stopBeforeId: 110))), "null/AnytimeCt5GapFailureSnapshot(fromId=100, stopBeforeId=110, failures=1)")
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 100, stopBeforeId: 110))), "null/AnytimeCt5GapFailureSnapshot(fromId=100, stopBeforeId=110, failures=2)")
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 100, stopBeforeId: 112))), "null/AnytimeCt5GapFailureSnapshot(fromId=100, stopBeforeId=112, failures=1)")
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 100, stopBeforeId: 112))), "null/AnytimeCt5GapFailureSnapshot(fromId=100, stopBeforeId=112, failures=2)")
        tracker.onProgress(receivedIds: [5, 200])
        XCTAssertEqual(state(nil), "null/AnytimeCt5GapFailureSnapshot(fromId=100, stopBeforeId=112, failures=2)")
        tracker.onProgress(receivedIds: [5, 111])
        XCTAssertEqual(state(nil), "null/null")
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 100, stopBeforeId: 112))), "null/AnytimeCt5GapFailureSnapshot(fromId=100, stopBeforeId=112, failures=1)")
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 100, stopBeforeId: 112))), "null/AnytimeCt5GapFailureSnapshot(fromId=100, stopBeforeId=112, failures=2)")
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 100, stopBeforeId: 112))), "100..111/null")
        XCTAssertEqual(state(tracker.onFailedSession(AnytimeIdRange(fromId: 1, stopBeforeId: 2))), "null/AnytimeCt5GapFailureSnapshot(fromId=1, stopBeforeId=2, failures=1)")
        tracker.clear()
        XCTAssertEqual(state(nil), "null/null")

        let restored = AnytimeCt5GapFailureTracker(maxFailedSessions: 2, restored: AnytimeCt5GapFailureSnapshot(fromId: 10, stopBeforeId: 20, failures: 1))
        let given = restored.onFailedSession(AnytimeIdRange(fromId: 10, stopBeforeId: 20))
        XCTAssertEqual("\(d(given))/\(restored.snapshot() == nil ? "null" : "set")", "10..19/null")
        let zero = AnytimeCt5GapFailureTracker(maxFailedSessions: 0)
        let immediate = zero.onFailedSession(AnytimeIdRange(fromId: 10, stopBeforeId: 20))
        XCTAssertEqual("\(d(immediate))/\(zero.snapshot() == nil ? "null" : "set")", "10..19/null")
    }


    // MARK: CT5 live clock

    func testLiveClockScenario() {
        let interval: Int64 = 180_000
        let timeline: Int64 = 1_700_000_000_000
        let live = AnytimeCt5LiveClock()
        func expectedId(_ now: Int64, _ streamingSince: Int64, _ lastObserved: Int, start: Int64 = 1_700_000_000_000, end: Int = 7695) -> String {
            return String(live.expectedCurrentId(nowMs: now, intervalMs: interval, streamingSinceMs: streamingSince, lastObservedId: lastObserved, timelineStartMs: start, profileEndNumber: end))
        }
        XCTAssertEqual(expectedId(timeline + 10 * interval, 0, 8), "10", "noLive")
        XCTAssertEqual(expectedId(timeline + 10 * interval, 0, 8, start: 0), "-1", "noLiveNoTimeline")
        XCTAssertEqual(expectedId(timeline - 5, 0, 8), "-1", "beforeTimeline")
        XCTAssertEqual(String(AnytimeCt5LiveClock().expectedCurrentId(nowMs: timeline, intervalMs: 0, streamingSinceMs: 0, lastObservedId: 8, timelineStartMs: timeline, profileEndNumber: 100)), "-1", "zeroInterval")
        live.observeLive(glucoseId: 5, receivedAtMs: timeline + 5 * interval, hasGlucose: true, errorCode: 0)
        XCTAssertEqual(expectedId(timeline + 5 * interval + 1000, timeline, 5), "5", "freshLive")
        XCTAssertEqual(expectedId(timeline + 5 * interval + 2 * interval, timeline, 5), "5", "liveAge2x")
        XCTAssertEqual(expectedId(timeline + 5 * interval + 2 * interval + 1, timeline, 5), "7", "liveAgeOver2x")
        live.observeLive(glucoseId: 6, receivedAtMs: timeline + 6 * interval, hasGlucose: true, errorCode: 0)
        XCTAssertEqual(expectedId(timeline + 6 * interval + 1000, timeline, 6), "6", "advancing")
        XCTAssertEqual(expectedId(timeline + 6 * interval + 200_000, timeline + 6 * interval + 150_000, 6), "7", "recoveringNewLink")
        XCTAssertEqual(expectedId(timeline + 6 * interval + 200_000, timeline + 6 * interval - 30_000, 6), "6", "recoveringBeforeLink")
        XCTAssertEqual(expectedId(timeline + 6 * interval + 200_000, timeline + 6 * interval + 290_000, 6), "6", "recoveringFutureLink")
        live.observeLive(glucoseId: 6, receivedAtMs: timeline + 6 * interval + 100, hasGlucose: true, errorCode: 0)
        XCTAssertEqual(expectedId(timeline + 6 * interval + 200_000, timeline + 6 * interval + 150_000, 6), "6", "repeatedId")
        live.observeLive(glucoseId: 7, receivedAtMs: timeline + 7 * interval, hasGlucose: false, errorCode: 0)
        XCTAssertEqual(expectedId(timeline + 7 * interval + 200_000, timeline + 7 * interval + 150_000, 7), "7", "noGlucose")
        live.observeLive(glucoseId: 8, receivedAtMs: timeline + 8 * interval, hasGlucose: true, errorCode: 2)
        XCTAssertEqual(expectedId(timeline + 8 * interval + 200_000, timeline + 8 * interval + 150_000, 8), "8", "withError")
        XCTAssertEqual(expectedId(timeline + 100 * interval + 5, 0, 8), "100", "longGap")
        XCTAssertEqual(expectedId(timeline + 9000 * interval, 0, 8), "7695", "longGapHorizon")
        XCTAssertEqual(expectedId(timeline + 9000 * interval, 0, 9000), "9000", "longGapHorizonLastAbove")
        XCTAssertEqual(expectedId(timeline + 9000 * interval, 0, 8, end: 0), "9000", "longGapNoHorizon")
        live.reset()
        XCTAssertEqual(expectedId(timeline + 100 * interval + 5, 0, 8), "100", "afterReset")
    }


    // MARK: CT5 learned scale

    func testRawScaleLearnsFromTheTransmittersOwnReadings() {
        let scale = AnytimeCt5RawScale(windowSize: 300)
        func state() -> String {
            return "\(fb(scale.scale))/\(scale.samples)/\(scale.isLearned)/\(fb(scale.effectiveScale))/\(fb(scale.estimateMgdl(iwNa: 8.5)))"
        }
        XCTAssertEqual(state(), "NaN/0/false/1096076493/1122113946", "empty")
        for i in 0..<500 {
            let iw: Float = 5 + Float(i % 13) * 0.25
            let vendor: Float = iw * (12 + Float(i % 7) * 0.5)
            scale.observe(iwNa: iw, vendorMgdl: vendor)
            switch i {
            case 0: XCTAssertEqual(state(), "NaN/1/false/1096076493/1122113946", "i0")
            case 99: XCTAssertEqual(state(), "NaN/100/false/1096076493/1122113946", "i99")
            case 238: XCTAssertEqual(state(), "NaN/239/false/1096076493/1122113946", "i238")
            case 239: XCTAssertEqual(state(), "1096275285/240/true/1096275285/1122325162", "i239")
            case 240: XCTAssertEqual(state(), "1096273155/241/true/1096273155/1122322899", "i240")
            case 299: XCTAssertEqual(state(), "1096280965/300/true/1096280965/1122331197", "i299")
            case 300: XCTAssertEqual(state(), "1096291451/300/true/1096291451/1122342339", "i300")
            case 499: XCTAssertEqual(state(), "1096286208/300/true/1096286208/1122336768", "i499")
            default: break
            }
        }
        // None of these may enter the window.
        scale.observe(iwNa: Float.nan, vendorMgdl: 100)
        scale.observe(iwNa: 5, vendorMgdl: Float.nan)
        scale.observe(iwNa: 0.29, vendorMgdl: 100)
        scale.observe(iwNa: 5, vendorMgdl: 19.9)
        scale.observe(iwNa: 5, vendorMgdl: 19.99)
        scale.observe(iwNa: 5, vendorMgdl: 3.9 * 5)
        scale.observe(iwNa: 1, vendorMgdl: 41)
        scale.observe(iwNa: 1, vendorMgdl: 40)
        scale.observe(iwNa: 1, vendorMgdl: 4)
        XCTAssertEqual(state(), "1096377085/300/true/1096377085/1122433325", "afterFilters")
        let estimates: [(Float, String)] = [
            (Float.nan, "NaN"),
            (0.2, "NaN"),
            (0.3, "NaN"),
            (1, "NaN"),
            (1.4, "NaN"),
            (2, "1104765693"),
            (8.5, "1122433325"),
            (40, "1141366238"),
            (50, "NaN")
        ]
        for (iw, expected) in estimates {
            XCTAssertEqual(fb(scale.estimateMgdl(iwNa: iw)), expected, "estimate \(iw)")
        }
    }

    func testRawScaleRestoreSurvivesTheFirstFrames() {
        let fresh = AnytimeCt5RawScale()
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)/\(fresh.isLearned)/\(fb(fresh.effectiveScale))/\(fb(fresh.estimateMgdl(iwNa: 8.5)))", "NaN/0/false/1096076493/1122113946")
        fresh.restore(scale: 13.7, samples: 100)
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)", "NaN/0", "restoreFew")
        fresh.restore(scale: 3.9, samples: 1000)
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)", "NaN/0", "restoreLow")
        fresh.restore(scale: 40.1, samples: 1000)
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)", "NaN/0", "restoreHigh")
        fresh.restore(scale: Float.nan, samples: 1000)
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)", "NaN/0", "restoreNaN")
        fresh.restore(scale: 13.7, samples: 1000)
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)/\(fresh.isLearned)/\(fb(fresh.estimateMgdl(iwNa: 8.5)))", "1096495923/1000/true/1122559590", "restoreOk")
        fresh.observe(iwNa: 8, vendorMgdl: 8 * 14)
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)", "1096495923/1000", "restoreThenOne")
        for _ in 0..<239 { fresh.observe(iwNa: 8, vendorMgdl: 8 * 15) }
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)", "1097854703/1000", "restoreThen239")
        fresh.observe(iwNa: 8, vendorMgdl: 8 * 15)
        XCTAssertEqual("\(fb(fresh.scale))/\(fresh.samples)", "1097854721/1000", "restoreThen240")
        XCTAssertEqual("\(AnytimeCt5RawScale.defaultScale)/\(AnytimeCt5RawScale.defaultWindow)/\(AnytimeCt5RawScale.minSamples)", "13.3/2000/240")
    }


    // MARK: calibration policy and trend estimator

    func testTrendClassification() {
        let cases: [(Float, String)] = [
            (-0.2, "RAPID_FALL/false"),
            (-0.11, "RAPID_FALL/false"),
            (-0.1099, "MODERATE_FALL/false"),
            (-0.06, "MODERATE_FALL/false"),
            (-0.0599, "STABLE/true"),
            (0, "STABLE/true"),
            (0.0599, "STABLE/true"),
            (0.06, "MODERATE_RISE/false"),
            (0.1099, "MODERATE_RISE/false"),
            (0.11, "RAPID_RISE/false"),
            (0.2, "RAPID_RISE/false")
        ]
        for (slope, expected) in cases {
            let trend = AnytimeCalibrationPolicy.classifyTrend(slopeMmolPerMin: slope)
            let name: String
            switch trend {
            case .rapidRise: name = "RAPID_RISE"
            case .moderateRise: name = "MODERATE_RISE"
            case .stable: name = "STABLE"
            case .moderateFall: name = "MODERATE_FALL"
            case .rapidFall: name = "RAPID_FALL"
            }
            XCTAssertEqual("\(name)/\(AnytimeCalibrationPolicy.canAcceptTrendForCalibration(slopeMmolPerMin: slope))", expected, "slope \(slope)")
        }
    }

    func testCalibrationGates() {
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptNoiseForCalibration(noiseMmol: 0), true, "noise 0")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptNoiseForCalibration(noiseMmol: 0.1), true, "noise 0.1")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptNoiseForCalibration(noiseMmol: 0.19999), true, "noise 0.19999")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptNoiseForCalibration(noiseMmol: 0.2), false, "noise 0.2")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptNoiseForCalibration(noiseMmol: 0.5), false, "noise 0.5")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptManualCalibration(sensorAgeHours: 0), false, "age 0")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptManualCalibration(sensorAgeHours: 23), false, "age 23")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptManualCalibration(sensorAgeHours: 24), true, "age 24")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptManualCalibration(sensorAgeHours: 100), true, "age 100")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(-1), true, "status -1")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(-1), "UNKNOWN", "status -1")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(0), false, "status 0")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(0), "NOT", "status 0")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(1), true, "status 1")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(1), "CAN", "status 1")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(2), true, "status 2")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(2), "HOPE", "status 2")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(3), true, "status 3")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(3), "INIT", "status 3")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(4), true, "status 4")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(4), "MUST", "status 4")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(5), true, "status 5")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(5), "UNKNOWN(5)", "status 5")
        XCTAssertEqual(AnytimeCalibrationPolicy.canAcceptAlgorithmCalibrationStatus(9), true, "status 9")
        XCTAssertEqual(AnytimeCalibrationPolicy.calibrationStatusName(9), "UNKNOWN(9)", "status 9")
        XCTAssertEqual(AnytimeCalibrationPolicy.manualCalibrationMinAgeHours, 24)
        XCTAssertEqual(fb(AnytimeCalibrationPolicy.trendStableThresholdMmolPerMin), "1031127695")
        XCTAssertEqual(fb(AnytimeCalibrationPolicy.trendRapidThresholdMmolPerMin), "1038174126")
        XCTAssertEqual(fb(AnytimeCalibrationPolicy.maxCalibrationNoiseMmol), "1045220557")
    }

    func testTrendEstimatorMatchesTheKotlinRegression() {
        let t0: Int64 = 1_700_000_000_000
        func estimate(_ points: [AnytimeTrendEstimator.Point]) -> String? {
            return AnytimeTrendEstimator.estimate(points).map { "\(fb($0.slopeMmolPerMin))/\(fb($0.noiseMmol))" }
        }
        func point(_ offsetMs: Int64, _ mmol: Float) -> AnytimeTrendEstimator.Point {
            return AnytimeTrendEstimator.Point(timestampMs: t0 + offsetMs, mmol: mmol)
        }
        XCTAssertEqual(estimate([point(0, 5), point(180_000, 5.2)]), nil, "two")
        XCTAssertEqual(estimate([]), nil, "empty")
        XCTAssertEqual(estimate([point(0, 5), point(180_000, 5), point(360_000, 5)]), "0/0", "flat")
        XCTAssertEqual(estimate((0..<10).map { point(Int64($0) * 180_000, 5 + Float($0) * 0.3) }), "1036831949/876110738", "rising")
        XCTAssertEqual(estimate((0..<10).map { point(Int64($0) * 180_000, 9 - Float($0) * 0.45) }), "-1105618535/875767043", "falling")
        XCTAssertEqual(estimate((0..<12).map { point(Int64($0) * 60_000, 6 + Float($0 % 3) * 0.2 - Float($0 % 4) * 0.1 + Float($0) * 0.02) }), "1017745801/1045079027", "noisy")
        XCTAssertEqual(estimate([point(0, 5), point(0, 5.5), point(0, 6)]), "0/0", "sameTime")
        XCTAssertEqual(estimate([point(0, 5), point(360_000, 5.6), point(180_000, 5.3), point(540_000, 5.9)]), "1036831949/870644014", "unsorted")
        XCTAssertEqual(estimate((0..<5).map { point(Int64($0) * 60_000, 7 + Float($0) * 0.07) }), "1032805421/872076263", "oneMinute")
    }
}
