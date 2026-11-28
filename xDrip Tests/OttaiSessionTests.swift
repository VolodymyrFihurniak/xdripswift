//
//  OttaiSessionTests.swift
//  xdrip tests
//
//  Tests of `OttaiSession.swift`. The vectors in `OttaiSessionVectors` are the output of the unchanged
//  JugglucoNG Kotlin helpers and a harness holding verbatim copies of its session functions, run on the
//  JVM; the structural tests at the end (history chain, least recently used map, payload bytes) check
//  this fork's own code against values computed by hand and cross-checked in Python.
//

import XCTest
@testable import xdrip

final class OttaiSessionTests: XCTestCase {

    // MARK: vector helpers

    private func rows(_ tag: String) -> [[String]] {
        return OttaiSessionVectors.timing
            .map { $0.components(separatedBy: "|") }
            .filter { $0.first == tag }
            .map { Array($0.dropFirst()) }
    }

    private func bool(_ text: String) -> Bool { return text == "true" }

    // MARK: timing helpers

    func testFreshLiveSample() {
        for row in rows("FRESH") {
            XCTAssertEqual(OttaiTiming.isFreshLiveSample(receivedAtMs: Int64(row[0])!, sampleMs: Int64(row[1])!), bool(row[2]), row.joined(separator: "|"))
        }
    }

    func testArrivalBoundAndAnchoredTimes() {
        for row in rows("ARRIVALSTART") {
            XCTAssertEqual(OttaiTiming.arrivalBoundStartMs(dataNo: Int(row[0])!, receivedAtMs: Int64(row[1])!), Int64(row[2])!, row.joined(separator: "|"))
        }
        for row in rows("ANCHORED") {
            XCTAssertEqual(OttaiTiming.anchoredLiveSampleMs(startMs: Int64(row[0])!, dataNo: Int(row[1])!, receivedAtMs: Int64(row[2])!), Int64(row[3])!, row.joined(separator: "|"))
        }
    }

    func testUsableLiveMonitorTime() {
        for row in rows("MONITOR") {
            XCTAssertEqual(OttaiTiming.isUsableLiveMonitorTime(monitorMs: Int64(row[0])!, receivedAtMs: Int64(row[1])!), bool(row[2]), row.joined(separator: "|"))
        }
    }

    func testReadLiveAfterHistory() {
        for row in rows("READLIVE") {
            XCTAssertEqual(OttaiTiming.shouldReadLiveAfterHistory(receivedAtMs: Int64(row[0])!, lastLiveFrameAtMs: Int64(row[1])!), bool(row[2]), row.joined(separator: "|"))
        }
    }

    func testAdjacentSample() {
        for row in rows("ADJ") {
            XCTAssertEqual(
                OttaiTiming.isAdjacentSample(previousDataNo: Int(row[0])!, previousSampleMs: Int64(row[1])!, dataNo: Int(row[2])!, sampleMs: Int64(row[3])!),
                bool(row[4]), row.joined(separator: "|")
            )
        }
    }

    func testPersistedCounterAheadOfLive() {
        for row in rows("AHEAD") {
            XCTAssertEqual(OttaiTiming.isPersistedDataNoAheadOfLive(previousDataNo: Int(row[0])!, liveDataNo: Int(row[1])!), bool(row[2]), row.joined(separator: "|"))
            XCTAssertEqual(OttaiTiming.previousDataNoForHistory(previousDataNo: Int(row[0])!, liveDataNo: Int(row[1])!), Int(row[3])!, row.joined(separator: "|"))
        }
    }

    func testHistoryRetriesAfterFrame() {
        for row in rows("RETRIES") {
            XCTAssertEqual(OttaiTiming.historyRetriesAfterFrame(retries: Int(row[0])!, frameMaxDataNo: Int(row[1])!, chunkBestDataNo: Int(row[2])!), Int(row[3])!, row.joined(separator: "|"))
        }
    }

    func testLiveGapRange() {
        for row in rows("GAP") {
            let ceiling = Int(row[2])! == Int(Int32.max) ? Int.max : Int(row[2])!
            let range = OttaiTiming.liveGapRange(previousDataNo: Int(row[0])!, liveDataNo: Int(row[1])!, ceiling: ceiling)
            let text = range.map { "\($0.start)-\($0.endExclusive)" } ?? "NULL"
            XCTAssertEqual(text, row[3], row.joined(separator: "|"))
        }
    }

    func testDataNoCeiling() {
        for row in rows("CEIL") {
            let value = OttaiTiming.dataNoCeilingFor(authoritativeStartMs: Int64(row[0])!, nowMs: Int64(row[1])!, lastDataNo: Int(row[2])!, live: bool(row[3]))
            let expected = Int(row[4])! == Int(Int32.max) ? Int.max : Int(row[4])!
            XCTAssertEqual(value, expected, row.joined(separator: "|"))
        }
        for row in rows("DISTRUST") {
            XCTAssertEqual(OttaiTiming.shouldDistrustCeiling(consecutiveFullDrops: Int(row[0])!), bool(row[1]), row.joined(separator: "|"))
        }
    }

    func testBackfillPercent() {
        for row in rows("PERCENT") {
            XCTAssertEqual(OttaiHistoryChain.historyBackfillPercent(chainStart: Int(row[0])!, nextStart: Int(row[1])!, endExclusive: Int(row[2])!), Int(row[3])!, row.joined(separator: "|"))
        }
    }

    func testNotifyHoldsPollDown() {
        func reading(valid: Bool, raw: Int) -> OttaiReading {
            let record = OttaiRecord(dataNo: 1, voltage: 0, runtimeSec: 60, rawCurrent: raw, temperatureC: 30, recordBytes: [UInt8](repeating: 0, count: 12))
            return OttaiReading(record: record, adjustGlucose: 5, monitorTimeMs: 0, valid: valid, formulaFailed: false)
        }
        let expected = Dictionary(uniqueKeysWithValues: rows("POLLDOWN").map { ($0[0], bool($0[1])) })
        XCTAssertEqual(OttaiTiming.notifyHoldsPollDown([]), expected["empty"])
        XCTAssertEqual(OttaiTiming.notifyHoldsPollDown([reading(valid: true, raw: 10)]), expected["valid"])
        XCTAssertEqual(OttaiTiming.notifyHoldsPollDown([reading(valid: true, raw: 0)]), expected["zero"])
        XCTAssertEqual(OttaiTiming.notifyHoldsPollDown([reading(valid: false, raw: 10)]), expected["invalid"])
        XCTAssertEqual(OttaiTiming.notifyHoldsPollDown([reading(valid: false, raw: 10), reading(valid: true, raw: 10)]), expected["last"])
    }

    // MARK: arrival start correction

    func testArrivalStartCorrectionSequences() {
        var correctors: [String: OttaiArrivalStartCorrection] = [:]
        for row in rows("COR") {
            let name = row[0]
            var corrector = correctors[name] ?? OttaiArrivalStartCorrection()
            let label = row.joined(separator: "|")
            if row[2] == "seed" {
                corrector.onAnchorSeeded(startMs: Int64(row[3])!, seedArrivalStartMs: Int64(row[4])!)
                XCTAssertEqual(corrector.floorMs(), Int64(row[5])!, label)
            } else {
                let result = corrector.onAcceptedLive(anchorStartMs: Int64(row[3])!, dataNo: Int(row[4])!, receivedAtMs: Int64(row[5])!)
                XCTAssertEqual(result, Int64(row[6])!, label)
                XCTAssertEqual(corrector.floorMs(), Int64(row[7])!, label)
            }
            correctors[name] = corrector
        }
    }

    // MARK: pipeline scenarios

    private func parseReading(_ text: String) -> OttaiReading {
        let f = text.components(separatedBy: ":")
        let record = OttaiRecord(
            dataNo: Int(f[0])!, voltage: 0, runtimeSec: Int(f[4])!, rawCurrent: Int(f[2])!,
            temperatureC: Double(bitPattern: UInt64(f[3], radix: 16)!), recordBytes: [UInt8](repeating: 0, count: 12)
        )
        return OttaiReading(
            record: record, adjustGlucose: Double(bitPattern: UInt64(f[1], radix: 16)!),
            monitorTimeMs: Int64(f[5])!, valid: f[6] == "1", formulaFailed: false
        )
    }

    private func hex32(_ value: Float) -> String {
        return String(format: "%08x", value.bitPattern)
    }

    private func stateText(_ p: OttaiPipeline) -> String {
        let parts: [String] = [
            String(p.lastDataNo), String(p.streamStartMs), p.streamStartReliable ? "1" : "0", String(p.activeTimeMs),
            String(p.persisted.lastAcceptedDataNo), String(p.persisted.lastAcceptedSampleMs), hex32(p.persisted.lastAcceptedMmol),
            String(p.persisted.lastAcceptedRawCurrent), String(p.consecutiveContinuityRejects), String(p.lastEvaluatedDataNo),
            String(p.lastEvaluatedSampleMs), String(p.consecutiveCeilingFullDrops), p.ceilingDistrusted ? "1" : "0",
            p.streamNotifyPhaseKnown ? "1" : "0", String(p.lastLiveFrameAtMs),
        ]
        return parts.joined(separator: ",")
    }

    func testPipelineScenariosMatchTheKotlinHarness() {
        var pipelines: [String: OttaiPipeline] = [:]
        for scenario in OttaiSessionVectors.scenarios {
            let f = scenario.components(separatedBy: "|")
            let override: Int64? = Int64(f[3])! >= 0 ? Int64(f[3])! : nil
            pipelines[f[0]] = OttaiPipeline(activeTimeMs: Int64(f[1])!, warmupAnchorOverrideMs: override)
        }
        XCTAssertEqual(pipelines.count, 9)
        var checked = 0
        for step in OttaiSessionVectors.steps {
            let f = step.components(separatedBy: "|")
            // name|step|live|notify|recv|now|blank|readings|emitted|mis|drop|arrived|settled|state|trace
            let name = f[0]
            let label = "\(name) step \(f[1])"
            guard var pipeline = pipelines[name] else { return XCTFail("unknown scenario \(name)") }
            let readings = f[7].isEmpty ? [] : f[7].components(separatedBy: ";").map(parseReading)
            let result = pipeline.processFrame(
                readings, live: f[2] == "1", notify: f[3] == "1", receivedAtMs: Int64(f[4])!, nowMs: Int64(f[5])!, methodBlank: f[6] == "1"
            )
            let emitted = result.emitted.map { "\($0.sampleMs):\(hex32($0.mgdl)):\($0.dataNo):\($0.rawCurrent):\($0.fresh ? 1 : 0)" }.joined(separator: ",")
            XCTAssertEqual(emitted, f[8], label + " emitted")
            XCTAssertEqual(result.misframed ? "1" : "0", f[9], label + " misframed")
            XCTAssertEqual(String(result.dropped), f[10], label + " dropped")
            XCTAssertEqual(result.arrived.map(String.init).joined(separator: ","), f[11], label + " arrived")
            XCTAssertEqual(result.settled.map(String.init).joined(separator: ","), f[12], label + " settled")
            XCTAssertEqual(stateText(pipeline), f[13], label + " state")
            XCTAssertEqual(result.trace.joined(separator: ","), f[14], label + " trace")
            pipelines[name] = pipeline
            checked += 1
        }
        XCTAssertEqual(checked, OttaiSessionVectors.steps.count)
    }

    // MARK: least recently used map

    func testLruMapEvictsTheLeastRecentlyUsedEntry() {
        var map = OttaiLruMap<Int>(capacity: 3)
        map.put(1, 10)
        map.put(2, 20)
        map.put(3, 30)
        XCTAssertEqual(map.get(1), 10)      // 1 is now the newest, 2 the oldest
        map.put(4, 40)                       // evicts 2
        XCTAssertNil(map.get(2))
        XCTAssertEqual(map.get(1), 10)
        XCTAssertEqual(map.get(3), 30)
        XCTAssertEqual(map.get(4), 40)
        map.put(3, 31)                       // rewriting a key keeps the size and makes it the newest
        XCTAssertEqual(map.count, 3)
        map.put(5, 50)                       // evicts the oldest, which is now 1
        XCTAssertNil(map.get(1))
        XCTAssertEqual(map.remove(3), 31)
        XCTAssertNil(map.get(3))
        map.removeAll()
        XCTAssertEqual(map.count, 0)
    }

    // MARK: persistence

    func testPersistedPipelineRoundTrips() throws {
        var persisted = OttaiPersistedPipeline()
        persisted.lastDataNo = 4321
        persisted.streamStartMs = 1_759_740_800_000
        persisted.streamStartReliable = true
        persisted.confirmedActiveTimeMs = 1_759_740_000_000
        persisted.lastAcceptedDataNo = 4320
        persisted.lastAcceptedSampleMs = 1_760_000_000_000
        persisted.lastAcceptedMmol = 6.1
        persisted.lastAcceptedRawCurrent = 13000
        let data = try JSONEncoder().encode(persisted)
        XCTAssertEqual(try JSONDecoder().decode(OttaiPersistedPipeline.self, from: data), persisted)
    }

    func testResetTransientStateKeepsAnchorsAndBaseline() {
        var pipeline = OttaiPipeline(activeTimeMs: 0)
        let record = OttaiRecord(dataNo: 300, voltage: 0, runtimeSec: 18000, rawCurrent: 10000, temperatureC: 32, recordBytes: [UInt8](repeating: 0, count: 12))
        let reading = OttaiReading(record: record, adjustGlucose: 5.0, monitorTimeMs: 0, valid: true, formulaFailed: false)
        let now: Int64 = 1_760_000_000_000
        _ = pipeline.processFrame([reading], live: true, notify: true, receivedAtMs: now, nowMs: now)
        XCTAssertEqual(pipeline.lastDataNo, 300)
        let start = pipeline.streamStartMs
        XCTAssertGreaterThan(start, 0)
        pipeline.resetTransientState()
        XCTAssertEqual(pipeline.streamStartMs, start)
        XCTAssertEqual(pipeline.lastDataNo, 300)
        XCTAssertEqual(pipeline.persisted.lastAcceptedDataNo, 300)
        XCTAssertEqual(pipeline.consecutiveContinuityRejects, 0)
        XCTAssertFalse(pipeline.streamNotifyPhaseKnown)
    }

    // MARK: history chain

    func testHistoryRequestPayloadIsStartAndCountLittleEndian() {
        XCTAssertEqual(OttaiHistoryChain.requestPayload(start: 300, count: 270), [44, 1, 14, 1])
        XCTAssertEqual(OttaiHistoryChain.requestPayload(start: 0, count: 1), [0, 0, 1, 0])
        XCTAssertEqual(OttaiHistoryChain.requestPayload(start: 65535, count: 65535), [255, 255, 255, 255])
        XCTAssertEqual(OttaiHistoryChain.requestPayload(start: 1000, count: 5), [232, 3, 5, 0])
    }

    func testHistoryChainCutsARequestIntoChunks() {
        var chain = OttaiHistoryChain()
        XCTAssertTrue(chain.isIdle)
        let first = chain.begin(reason: "post-live", start: 100, count: 600)
        XCTAssertEqual(first?.start, 100)
        XCTAssertEqual(first?.count, 270)
        XCTAssertEqual(chain.pendingNextStart, 370)
        XCTAssertEqual(chain.pendingEndExclusive, 700)
        XCTAssertEqual(chain.chainStart, 100)
        XCTAssertEqual(chain.percentAsked, 45)
        // a chunk is only asked for after the window before it closed
        XCTAssertNil(chain.nextChunk())
        // a frame that reaches the end of the window completes it; one more chunk waits
        let done = chain.frameArrived(arrived: Array(100..<370), settled: Array(100..<370))
        XCTAssertEqual(done, .windowCompleteMoreChunks)
        let second = chain.nextChunk()
        XCTAssertEqual(second?.start, 370)
        XCTAssertEqual(second?.count, 270)
        XCTAssertEqual(chain.pendingNextStart, 640)
        XCTAssertEqual(chain.frameArrived(arrived: Array(370..<640), settled: Array(370..<640)), .windowCompleteMoreChunks)
        let third = chain.nextChunk()
        XCTAssertEqual(third?.start, 640)
        XCTAssertEqual(third?.count, 60)
        XCTAssertNil(chain.pendingReason)
        XCTAssertEqual(chain.chainStart, -1)
        XCTAssertEqual(chain.frameArrived(arrived: Array(640..<700), settled: Array(640..<700)), .chainDone)
        XCTAssertTrue(chain.isIdle)
    }

    func testHistoryChainRejectsInvalidRequests() {
        var chain = OttaiHistoryChain()
        XCTAssertNil(chain.begin(reason: "x", start: -1, count: 10))
        XCTAssertNil(chain.begin(reason: "x", start: 0, count: 0))
        XCTAssertNil(chain.begin(reason: "x", start: 0, count: 0x10000))
        XCTAssertTrue(chain.isIdle)
        let single = chain.begin(reason: "x", start: 7, count: 3)
        XCTAssertEqual(single?.count, 3)
        XCTAssertNil(chain.pendingReason)
        XCTAssertEqual(chain.chainStart, -1)
    }

    func testHistoryChainPartialFramesAndWatchdog() {
        var chain = OttaiHistoryChain()
        _ = chain.begin(reason: "post-live", start: 10, count: 20)
        XCTAssertEqual(chain.frameArrived(arrived: [], settled: []), .ignored)
        XCTAssertEqual(chain.frameArrived(arrived: [10, 11, 12], settled: [10, 11]), .partial)
        XCTAssertEqual(chain.window?.bestDataNo, 12)
        XCTAssertEqual(chain.window?.states[0], OttaiHistoryWindow.settled)
        XCTAssertEqual(chain.window?.states[2], OttaiHistoryWindow.deferred)
        XCTAssertEqual(chain.window?.states[5], OttaiHistoryWindow.missing)
        // the watchdog asks again three times for the same window, then gives it up
        XCTAssertEqual(chain.watchdogFired(), .retry(start: 10, count: 20, attempt: 1))
        XCTAssertEqual(chain.watchdogFired(), .retry(start: 10, count: 20, attempt: 2))
        XCTAssertEqual(chain.watchdogFired(), .retry(start: 10, count: 20, attempt: 3))
        // a frame that goes further than any before refunds the budget
        XCTAssertEqual(chain.frameArrived(arrived: [13, 14], settled: [13, 14]), .partial)
        XCTAssertEqual(chain.window?.retries, 0)
        // a frame that only repeats what was delivered does not
        XCTAssertEqual(chain.watchdogFired(), .retry(start: 10, count: 20, attempt: 1))
        XCTAssertEqual(chain.frameArrived(arrived: [13, 14], settled: [13, 14]), .partial)
        XCTAssertEqual(chain.window?.retries, 1)
        XCTAssertEqual(chain.watchdogFired(), .retry(start: 10, count: 20, attempt: 2))
        XCTAssertEqual(chain.watchdogFired(), .retry(start: 10, count: 20, attempt: 3))
        XCTAssertEqual(chain.watchdogFired(), .giveUp(moreChunks: false))
        XCTAssertTrue(chain.isIdle)
        XCTAssertEqual(chain.watchdogFired(), .nothingInFlight)
    }

    func testHistoryChainGivesUpAWindowAndMovesOn() {
        var chain = OttaiHistoryChain()
        _ = chain.begin(reason: "post-live", start: 0, count: 300)
        XCTAssertTrue(chain.abandonWindow())
        let next = chain.nextChunk()
        XCTAssertEqual(next?.start, 270)
        XCTAssertEqual(next?.count, 30)
        for _ in 0..<OttaiHistoryChain.maxRetries { _ = chain.watchdogFired() }
        XCTAssertEqual(chain.watchdogFired(), .giveUp(moreChunks: false))
        XCTAssertFalse(chain.abandonWindow())
    }

    func testHistoryWindowRejectsEmptyBounds() {
        XCTAssertNil(OttaiHistoryWindow(start: 5, endExclusive: 5))
        XCTAssertNil(OttaiHistoryWindow(start: -1, endExclusive: 5))
        XCTAssertNotNil(OttaiHistoryWindow(start: 0, endExclusive: 1))
        var window = OttaiHistoryWindow(start: 10, endExclusive: 13)!
        window.mark([9, 10, 12, 13], state: OttaiHistoryWindow.settled)
        XCTAssertEqual(window.states, [OttaiHistoryWindow.settled, OttaiHistoryWindow.missing, OttaiHistoryWindow.settled])
        window.mark([10], state: OttaiHistoryWindow.deferred)
        XCTAssertEqual(window.states[0], OttaiHistoryWindow.settled)
        XCTAssertTrue(window.covers(start: 10, endExclusive: 13))
        XCTAssertFalse(window.covers(start: 10, endExclusive: 12))
    }
}

// MARK: - Vectors

enum OttaiSessionVectors {

    static let timing: [String] = [
        "FRESH|1760000000000|1760000000000|true",
        "FRESH|1760000000000|1759999820000|true",
        "FRESH|1760000000000|1759999819999|false",
        "FRESH|1760000000000|1760000180000|true",
        "FRESH|1760000000000|1760000180001|false",
        "FRESH|0|1760000000000|false",
        "FRESH|1760000000000|0|false",
        "FRESH|1760000000000|-5|false",
        "ARRIVALSTART|0|1760000000000|1760000000000",
        "ANCHORED|1759940000000|0|1760000000000|1759940000000",
        "ANCHORED|1760000000000|0|1760000000000|1760000000000",
        "ANCHORED|1760000180000|0|1760000000000|1760000000000",
        "ARRIVALSTART|1|1760000000000|1759999940000",
        "ANCHORED|1759940000000|1|1760000000000|1759940060000",
        "ANCHORED|1760000000000|1|1760000000000|1760000000000",
        "ANCHORED|1760000180000|1|1760000000000|1760000000000",
        "ARRIVALSTART|500|1760000000000|1759970000000",
        "ANCHORED|1759940000000|500|1760000000000|1759970000000",
        "ANCHORED|1760000000000|500|1760000000000|1760000000000",
        "ANCHORED|1760000180000|500|1760000000000|1760000000000",
        "ARRIVALSTART|65535|1760000000000|1756067900000",
        "ANCHORED|1759940000000|65535|1760000000000|1760000000000",
        "ANCHORED|1760000000000|65535|1760000000000|1760000000000",
        "ANCHORED|1760000180000|65535|1760000000000|1760000000000",
        "ARRIVALSTART|12|0|-720000",
        "ANCHORED|1759940000000|12|0|0",
        "ANCHORED|1760000000000|12|0|0",
        "ANCHORED|1760000180000|12|0|0",
        "MONITOR|1760000000000|1760000000000|true",
        "MONITOR|1759999880000|1760000000000|true",
        "MONITOR|1759999879999|1760000000000|false",
        "MONITOR|1760000000001|1760000000000|false",
        "MONITOR|0|1760000000000|false",
        "MONITOR|-3|1760000000000|false",
        "READLIVE|1760000000000|0|true",
        "READLIVE|1760000000000|1759999940001|false",
        "READLIVE|1760000000000|1759999940000|true",
        "READLIVE|1760000000000|1760000005000|true",
        "READLIVE|1760000000000|1759999400000|true",
        "ADJ|-1|0|5|100|false",
        "ADJ|10|0|11|0|true",
        "ADJ|10|0|12|0|true",
        "ADJ|10|0|13|0|false",
        "ADJ|10|0|10|0|false",
        "ADJ|10|0|9|0|false",
        "ADJ|10|1760000000000|15|1760000135000|true",
        "ADJ|10|1760000000000|15|1760000135001|false",
        "ADJ|10|1760000000000|15|1760000000001|true",
        "ADJ|10|1760000000000|15|1760000000000|false",
        "ADJ|10|1760000000000|3|1759999999999|false",
        "ADJ|10|0|15|1760000000000|false",
        "AHEAD|-1|5|false|-1",
        "AHEAD|100|5|false|100",
        "AHEAD|126|5|true|-1",
        "AHEAD|125|5|false|125",
        "AHEAD|130|-1|false|130",
        "AHEAD|5000|5000|false|5000",
        "AHEAD|0|0|false|0",
        "RETRIES|2|10|-1|0",
        "RETRIES|2|10|10|2",
        "RETRIES|2|9|10|2",
        "RETRIES|0|11|10|0",
        "RETRIES|3|1|0|0",
        "GAP|10|20|2147483647|11-20",
        "GAP|-1|20|2147483647|NULL",
        "GAP|10|11|2147483647|NULL",
        "GAP|10|10|2147483647|NULL",
        "GAP|10|0|2147483647|NULL",
        "GAP|10|251|2147483647|11-251",
        "GAP|10|250|2147483647|11-250",
        "GAP|10|12|11|NULL",
        "GAP|10|12|12|11-12",
        "GAP|0|3|100|1-3",
        "CEIL|0|1760000000000|0|true|2147483647",
        "CEIL|0|1760000000000|0|false|2147483647",
        "CEIL|0|1760000000000|500|false|620",
        "CEIL|0|1760000000000|500|true|2147483647",
        "CEIL|1759999400000|1760000000000|0|true|130",
        "CEIL|1759999400000|1760000000000|500|false|130",
        "CEIL|1760000000000|1760000000000|500|true|2147483647",
        "CEIL|1760000000001|1760000000000|500|false|620",
        "CEIL|1|4611686018427387903|0|true|1073741943",
        "CEIL|1759820000000|1760000000000|9|false|3120",
        "DISTRUST|0|false",
        "DISTRUST|1|false",
        "DISTRUST|2|false",
        "DISTRUST|3|true",
        "DISTRUST|4|true",
        "DISTRUST|5|true",
        "COR|agree|0|seed|1759982000000|1759982090000|1759981970000",
        "COR|agree|1|live|1759982000000|301|1760000030000|0|1759981970000",
        "COR|agree|2|live|1759982000000|302|1760000085000|1759981970000|1759981970000",
        "COR|agree|3|live|1759982000000|303|1760000135000|0|1759981970000",
        "COR|late-seed|0|seed|1759988000000|1759988050000|1759987940000",
        "COR|late-seed|1|live|1759988000000|10|1759988580000|0|1759987940000",
        "COR|late-seed|2|live|1759988000000|11|1759988640000|1759987980000|1759987940000",
        "COR|late-seed|3|live|1759988000000|12|1759988700000|0|1759987940000",
        "COR|disagree|0|seed|1759994000000|1760000000000|1759999880000",
        "COR|disagree|1|live|1759994000000|50|1759996870000|0|1759999880000",
        "COR|disagree|2|live|1759994000000|51|1759997050000|0|1759999880000",
        "COR|disagree|3|live|1759994000000|52|1759997320000|0|1759999880000",
        "COR|replay|0|seed|1759994000000|1759994080000|1759993960000",
        "COR|replay|1|live|1759994000000|60|1759997580000|0|1759993960000",
        "COR|replay|2|live|1759994000000|60|1759997590000|0|1759993960000",
        "COR|replay|3|live|1759994000000|59|1759997595000|0|1759993960000",
        "COR|bad|0|live|0|5|1760000000000|0|0",
        "COR|bad|1|live|1760000000000|-1|1760000000000|0|0",
        "COR|bad|2|live|1760000000000|5|0|0|0",
        "COR|bad|3|seed|0|-5|0",
        "COR|stale-pending|0|seed|1759994000000|1759994090000|1759993970000",
        "COR|stale-pending|1|live|1759994000000|70|1759998170000|0|1759993970000",
        "COR|stale-pending|2|live|1759994000000|71|1759998470000|0|1759994090000",
        "COR|stale-pending|3|live|1759994000000|72|1759998540000|0|1759994100000",
        "PERCENT|0|270|1000|27",
        "PERCENT|-1|10|100|-1",
        "PERCENT|5|5|5|-1",
        "PERCENT|0|1000|1000|99",
        "PERCENT|0|-5|100|0",
        "PERCENT|100|370|1000|30",
        "PERCENT|0|999|1000|99",
        "PERCENT|10|3|50|0",
        "PERCENT|0|1|3|33",
        "POLLDOWN|empty|false",
        "POLLDOWN|valid|true",
        "POLLDOWN|zero|false",
        "POLLDOWN|invalid|false",
        "POLLDOWN|last|true"
    ]

    /// `name|activeTimeMs|nowMs|warmupAnchorOverrideMs (-1 = none)`
    static let scenarios: [String] = [
        "anchor|0|1760000000000|-1",
        "known|1759740800000|1760000000000|-1",
        "continuity|0|1760000000000|-1",
        "history|1759992800000|1760000000000|-1",
        "misframed|1759996400000|1760000000000|-1",
        "ahead|0|1760000000000|-1",
        "noanchor|0|1760000000000|-1",
        "evict|0|1760000000000|-1",
        "warmup|0|1760000000000|1759998200000"
    ]

    /// `name|step|live|notify|receivedAtMs|nowMs|methodBlank|readings|emitted|misframed|dropped|arrived|settled|state|trace`;
    /// a reading is `dataNo:glucoseDoubleBits:rawCurrent:temperatureDoubleBits:runtimeSec:monitorMs:valid`.
    static let steps: [String] = [
        "anchor|0|1|1|1760000060000|1760000060000|0|500:4016000000000000:12000:4040000000000000:30000:0:1|1760000060000:42c60000:500:12000:1|0|0|500|500|500,1759970060000,1,0,500,1760000060000,40b00000,12000,0,500,1760000060000,0,0,1,1760000060000|A:500:1760000060000",
        "anchor|1|1|0|1760000122000|1760000122000|0|501:4016666666666666:12030:4040000000000000:30060:0:1|1760000120000:42c99999:501:12030:1|0|0|501|501|501,1759970060000,1,1759970062000,501,1760000120000,40b33333,12030,0,501,1760000120000,0,0,1,1760000122000|A:501:1760000120000",
        "anchor|2|1|1|1760000186000|1760000186000|0|502:4016cccccccccccd:12060:4040000000000000:30120:0:1|1760000180000:42cd3333:502:12060:1|0|0|502|502|502,1759970060000,1,1759970062000,502,1760000180000,40b66666,12060,0,502,1760000180000,0,0,1,1760000186000|A:502:1760000180000",
        "anchor|3|1|0|1760000246000|1760000246000|0|503:4017333333333333:12090:4040000000000000:30180:0:1|1760000240000:42d0cccd:503:12090:1|0|0|503|503|503,1759970060000,1,1759970062000,503,1760000240000,40b9999a,12090,0,503,1760000240000,0,0,1,1760000246000|A:503:1760000240000",
        "anchor|4|1|1|1760000308000|1760000308000|0|504:401799999999999a:12120:4040000000000000:30240:0:1|1760000300000:42d46667:504:12120:1|0|0|504|504|504,1759970060000,1,1759970062000,504,1760000300000,40bccccd,12120,0,504,1760000300000,0,0,1,1760000308000|A:504:1760000300000",
        "anchor|5|1|0|1760000372000|1760000372000|0|505:4018000000000000:12150:4040000000000000:30300:0:1|1760000360000:42d80000:505:12150:1|0|0|505|505|505,1759970060000,1,1759970062000,505,1760000360000,40c00000,12150,0,505,1760000360000,0,0,1,1760000372000|A:505:1760000360000",
        "anchor|6|1|0|1760000402000|1760000402000|0|505:4018000000000000:12150:4040000000000000:30300:0:1|1760000360000:42d80000:505:12150:1|0|0|505|505|505,1759970060000,1,1759970062000,505,1760000360000,40c00000,12150,0,505,1760000360000,0,0,1,1760000402000|A:505:1760000360000",
        "anchor|7|1|0|1760000492000|1760000492000|0|508:4018cccccccccccd:12400:4040000000000000:30480:0:1|1760000492000:42df3333:508:12400:1|0|0|508|508|508,1759970060000,1,1759970062000,508,1760000492000,40c66666,12400,0,508,1760000492000,0,0,1,1760000492000|A:508:1760000492000",
        "anchor|8|1|0|1760000552000|1760000552000|0|509:4019333333333333:12420:4040000000000000:30540:0:1|1760000552000:42e2cccd:509:12420:1|0|0|509|509|509,1759970012000,1,1759970062000,509,1760000552000,40c9999a,12420,0,509,1760000552000,0,0,1,1760000552000|A:509:1760000552000",
        "known|0|0|0|1759741700000|1759741700000|0|0:4014000000000000:11000:4040000000000000:0:1759740800000:1;1:4014333333333333:11010:4040000000000000:60:1759740860000:1;2:4014666666666666:11020:4040000000000000:120:1759740920000:1;3:401499999999999a:11030:4040000000000000:180:1759740980000:1;4:4014cccccccccccd:11040:4040000000000000:240:1759741040000:1;5:4015000000000000:11050:4040000000000000:300:1759741100000:1;6:4015333333333333:11060:4040000000000000:360:1759741160000:1;7:4015666666666666:11070:4040000000000000:420:1759741220000:1;8:401599999999999a:11080:4040000000000000:480:1759741280000:1;9:4015cccccccccccd:11090:4040000000000000:540:1759741340000:1;10:4016000000000000:11100:4040000000000000:600:1759741400000:1;11:4016333333333333:11110:4040000000000000:660:1759741460000:1;12:4016666666666666:11120:4040000000000000:720:1759741520000:1;13:401699999999999a:11130:4040000000000000:780:1759741580000:1;14:4016cccccccccccd:11140:4040000000000000:840:1759741640000:1|1759741400000:42c60000:10:11100:0,1759741460000:42c7cccd:11:11110:0,1759741520000:42c99999:12:11120:0,1759741580000:42cb6667:13:11130:0,1759741640000:42cd3333:14:11140:0|0|0|0,1,2,3,4,5,6,7,8,9,10,11,12,13,14|0,1,2,3,4,5,6,7,8,9,10,11,12,13,14|14,1759740800000,0,1759740800000,14,1759741640000,40b66666,11140,0,14,1759741640000,0,0,0,0|R:0:warmup,R:1:warmup,R:2:warmup,R:3:warmup,R:4:warmup,R:5:warmup,R:6:warmup,R:7:warmup,R:8:warmup,R:9:warmup,A:10:1759741400000,A:11:1759741460000,A:12:1759741520000,A:13:1759741580000,A:14:1759741640000",
        "known|1|1|1|1760000000000|1760000000000|0|4320:4018666666666666:13000:4040000000000000:259200:1760000000000:1|1760000000000:42db9999:4320:13000:1|0|0|4320|4320|4320,1759740800000,1,1759740800000,4320,1760000000000,40c33333,13000,0,4320,1760000000000,0,0,1,1760000000000|A:4320:1760000000000",
        "known|2|1|1|1760000060000|1760000060000|0|4321:4018cccccccccccd:13100:4040000000000000:259260:1760000060000:1|1760000060000:42df3333:4321:13100:1|0|0|4321|4321|4321,1759740800000,1,1759740800000,4321,1760000060000,40c66666,13100,0,4321,1760000060000,0,0,1,1760000060000|A:4321:1760000060000",
        "known|3|1|0|1760000320000|1760000320000|0|4322:4019333333333333:13200:4040000000000000:259320:1760000120000:1|1760000120000:42e2cccd:4322:13200:0|0|0|4322|4322|4322,1759740800000,1,1759740800000,4322,1760000120000,40c9999a,13200,0,4322,1760000120000,0,0,1,1760000320000|A:4322:1760000120000",
        "continuity|0|1|1|1760000000000|1760000000000|0|300:4014000000000000:10000:4040000000000000:18000:0:1|1760000000000:42b40000:300:10000:1|0|0|300|300|300,1759982000000,1,0,300,1760000000000,40a00000,10000,0,300,1760000000000,0,0,1,1760000000000|A:300:1760000000000",
        "continuity|1|1|1|1760000060000|1760000060000|0|301:4014666666666666:10050:4040000000000000:18060:0:1|1760000060000:42b79999:301:10050:1|0|0|301|301|301,1759982000000,1,1759982000000,301,1760000060000,40a33333,10050,0,301,1760000060000,0,0,1,1760000060000|A:301:1760000060000",
        "continuity|2|1|1|1760000120000|1760000120000|0|302:4020000000000000:13000:4040000000000000:18120:0:1||0|0|302|302|301,1759982000000,1,1759982000000,301,1760000060000,40a33333,10050,1,302,1760000120000,0,0,1,1760000120000|R:302:continuity-prev",
        "continuity|3|1|1|1760000180000|1760000180000|0|303:4020333333333333:13050:4040000000000000:18180:0:1||0|0|303|303|301,1759982000000,1,1759982000000,301,1760000060000,40a33333,10050,2,303,1760000180000,0,0,1,1760000180000|R:303:continuity-prev",
        "continuity|4|1|1|1760000240000|1760000240000|0|304:4020666666666666:13100:4040000000000000:18240:0:1||0|0|304|304|301,1759982000000,1,1759982000000,301,1760000060000,40a33333,10050,3,304,1760000240000,0,0,1,1760000240000|R:304:continuity-prev",
        "continuity|5|1|1|1760000300000|1760000300000|0|305:402099999999999a:13120:4040000000000000:18300:0:1|1760000300000:43156667:305:13120:1|0|0|305|305|305,1759982000000,1,1759982000000,305,1760000300000,4104cccd,13120,0,305,1760000300000,0,0,1,1760000300000|A:305:1760000300000",
        "continuity|6|1|1|1760000360000|1760000360000|0|306:4020cccccccccccd:13140:4040000000000000:18360:0:1|1760000360000:43173333:306:13140:1|0|0|306|306|306,1759982000000,1,1759982000000,306,1760000360000,41066666,13140,0,306,1760000360000,0,0,1,1760000360000|A:306:1760000360000",
        "continuity|7|1|0|1760000370000|1760000370000|0|306:4020cccccccccccd:13140:4040000000000000:18360:0:1|1760000360000:43173333:306:13140:1|0|0|306|306|306,1759982000000,1,1759982000000,306,1760000360000,41066666,13140,0,306,1760000360000,0,0,1,1760000370000|A:306:1760000360000",
        "history|0|0|0|1760000000000|1760000000000|0|20:4014000000000000:10000:4040000000000000:1200:1759994000000:1;21:4014666666666666:10040:4040000000000000:1260:1759994060000:1;22:4022000000000000:14000:4040000000000000:1320:1759994120000:1;23:4014cccccccccccd:10080:4040000000000000:1380:1759994180000:1;24:4014cccccccccccd:10090:4040000000000000:1440:1759994240000:1;25:4015333333333333:800:4040000000000000:1500:1759994300000:1;26:4015333333333333:10100:4049000000000000:1560:1759994360000:1;27:0000000000000000:10100:4040000000000000:1620:1759994420000:1;28:401599999999999a:10110:4040000000000000:1680:1759994480000:1;65535:401599999999999a:10110:4040000000000000:3932100:1763924900000:0;620:4016000000000000:10120:4040000000000000:37200:1760030000000:1|1759994000000:42b40000:20:10000:0,1759994060000:42b79999:21:10040:0,1759994180000:42bb3333:23:10080:0,1759994240000:42bb3333:24:10090:0,1759994480000:42c26667:28:10110:0|0|2|20,21,22,23,24,25,26,27,28|20,21,22,23,24,25,26,27,28|28,1759992800000,0,1759992800000,28,1759994480000,40accccd,10110,0,28,1759994480000,0,0,0,0|A:20:1759994000000,A:21:1759994060000,R:22:continuity-prev,A:23:1759994180000,A:24:1759994240000,R:25:hard-raw=800,R:26:hard-temp=50.0,R:27:hard-glucose=0.0,A:28:1759994480000",
        "history|1|0|0|1760000001000|1760000001000|0|2:4022000000000000:14000:4040000000000000:120:1759992920000:1;3:4014000000000000:10000:4040000000000000:180:1759992980000:1;4:4014000000000000:10010:4040000000000000:240:1759993040000:1||0|0|2,3,4|2,3,4|28,1759992800000,0,1759992800000,28,1759994480000,40accccd,10110,0,28,1759994480000,0,0,0,0|R:2:warmup,R:3:warmup,R:4:warmup",
        "misframed|0|0|0|1760000000000|1760000000000|0|100:0000000000000000:200:4058c00000000000:6000:1760002400000:1;101:0000000000000000:201:4058c00000000000:6060:1760002460000:1;102:0000000000000000:202:4058c00000000000:6120:1760002520000:1;103:0000000000000000:203:4058c00000000000:6180:1760002580000:1;104:0000000000000000:204:4058c00000000000:6240:1760002640000:1;105:0000000000000000:205:4058c00000000000:6300:1760002700000:1;106:0000000000000000:206:4058c00000000000:6360:1760002760000:1;107:0000000000000000:207:4058c00000000000:6420:1760002820000:1;108:0000000000000000:208:4058c00000000000:6480:1760002880000:1;109:0000000000000000:209:4058c00000000000:6540:1760002940000:1||1|0|||-1,0,0,1759996400000,-1,0,00000000,0,0,-1,0,0,0,0,0|",
        "misframed|1|1|1|1760000000000|1760000000000|0|5000:4014000000000000:10000:4040000000000000:300000:1760296400000:1||0|1|||-1,0,0,1759996400000,-1,0,00000000,0,0,-1,0,1,0,0,0|",
        "misframed|2|1|1|1760000060000|1760000060000|0|5001:4014000000000000:10000:4040000000000000:300060:1760296460000:1||0|1|||-1,0,0,1759996400000,-1,0,00000000,0,0,-1,0,2,0,0,0|",
        "misframed|3|1|1|1760000120000|1760000120000|0|5002:4014000000000000:10000:4040000000000000:300120:1760296520000:1||0|1|||-1,0,0,1759996400000,-1,0,00000000,0,0,-1,0,3,1,0,0|",
        "misframed|4|1|1|1760000180000|1760000180000|0|5003:4014000000000000:10000:4040000000000000:300180:1760296580000:1|1760000180000:42b40000:5003:10000:1|0|0|5003|5003|5003,1759700000000,1,1759996400000,5003,1760000180000,40a00000,10000,0,5003,1760000180000,3,1,1,1760000180000|A:5003:1760000180000",
        "misframed|5|1|1|1760000300000|1760000300000|0|5004:4014000000000000:10000:4040000000000000:300240:1760296640000:1|1760000240000:42b40000:5004:10000:1|0|0|5004|5004|5004,1759700000000,1,1759996400000,5004,1760000240000,40a00000,10000,0,5004,1760000240000,3,1,1,1760000300000|A:5004:1760000240000",
        "ahead|0|1|1|1760000000000|1760000000000|0|2000:4014000000000000:10000:4040000000000000:120000:0:1|1760000000000:42b40000:2000:10000:1|0|0|2000|2000|2000,1759880000000,1,0,2000,1760000000000,40a00000,10000,0,2000,1760000000000,0,0,1,1760000000000|A:2000:1760000000000",
        "ahead|1|1|1|1760000060000|1760000060000|0|40:4014000000000000:10000:4040000000000000:2400:0:1|1759882400000:42b40000:40:10000:0|0|0|40|40|40,1759880000000,1,0,2000,1760000000000,40a00000,10000,0,2000,1760000000000,0,0,1,1760000060000|A:40:1759882400000",
        "ahead|2|0|0|1760000120000|1760000120000|0|30:4014000000000000:10000:4040000000000000:1800:0:1;31:4014000000000000:10001:4040000000000000:1860:0:1|1759881800000:42b40000:30:10000:0,1759881860000:42b40000:31:10001:0|0|0|30,31|30,31|40,1759880000000,1,0,2000,1760000000000,40a00000,10000,0,2000,1760000000000,0,0,1,1760000060000|A:30:1759881800000,A:31:1759881860000",
        "ahead|3|1|1|1760000180000|1760000180000|1|41:4014000000000000:10020:4040000000000000:2460:0:1||0|0|41||40,1759880000000,1,0,2000,1760000000000,40a00000,10000,0,2000,1760000000000,0,0,1,1760000180000|N:41",
        "noanchor|0|0|0|1760000000000|1760000000000|0|10:4014000000000000:10000:4040000000000000:600:0:1;11:4014000000000000:10010:4040000000000000:660:0:1||0|0|10,11||-1,0,0,0,-1,0,00000000,0,0,-1,0,0,0,0,0|S:10:no-anchor,S:11:no-anchor",
        "noanchor|1|1|1|1760000060000|1760000060000|0|12:4014000000000000:10020:4040000000000000:720:0:1|1760000060000:42b40000:12:10020:1|0|0|12|12|12,1759999340000,1,0,12,1760000060000,40a00000,10020,0,12,1760000060000,0,0,1,1760000060000|A:12:1760000060000",
        "noanchor|2|0|0|1760000120000|1760000120000|0|10:4014000000000000:10000:4040000000000000:600:0:1;11:4014000000000000:10010:4040000000000000:660:0:1;13:4014cccccccccccd:10030:4040000000000000:780:0:1|1759999940000:42b40000:10:10000:0,1760000000000:42b40000:11:10010:0,1760000120000:42bb3333:13:10030:0|0|0|10,11,13|10,11,13|13,1759999340000,1,0,13,1760000120000,40a66666,10030,0,13,1760000120000,0,0,1,1760000060000|A:10:1759999940000,A:11:1760000000000,A:13:1760000120000",
        "evict|0|1|0|1760000000000|1760000000000|0|1000:4014000000000000:10000:4040000000000000:60000:0:1|1760000000000:42b40000:1000:10000:1|0|0|1000|1000|1000,1759940000000,1,0,1000,1760000000000,40a00000,10000,0,1000,1760000000000,0,0,0,1760000000000|A:1000:1760000000000",
        "evict|1|1|0|1760000060000|1760000060000|0|1001:40140a3d70a3d70a:10001:4040000000000000:60060:0:1|1760000060000:42b45c2a:1001:10001:1|0|0|1001|1001|1001,1759940000000,1,1759940000000,1001,1760000060000,40a051ec,10001,0,1001,1760000060000,0,0,0,1760000060000|A:1001:1760000060000",
        "evict|2|1|0|1760000120000|1760000120000|0|1002:4014147ae147ae14:10002:4040000000000000:60120:0:1|1760000120000:42b4b852:1002:10002:1|0|0|1002|1002|1002,1759940000000,1,1759940000000,1002,1760000120000,40a0a3d7,10002,0,1002,1760000120000,0,0,0,1760000120000|A:1002:1760000120000",
        "evict|3|1|0|1760000180000|1760000180000|0|1003:40141eb851eb851f:10003:4040000000000000:60180:0:1|1760000180000:42b5147b:1003:10003:1|0|0|1003|1003|1003,1759940000000,1,1759940000000,1003,1760000180000,40a0f5c3,10003,0,1003,1760000180000,0,0,0,1760000180000|A:1003:1760000180000",
        "evict|4|1|0|1760000240000|1760000240000|0|1004:401428f5c28f5c29:10004:4040000000000000:60240:0:1|1760000240000:42b570a4:1004:10004:1|0|0|1004|1004|1004,1759940000000,1,1759940000000,1004,1760000240000,40a147ae,10004,0,1004,1760000240000,0,0,0,1760000240000|A:1004:1760000240000",
        "evict|5|1|0|1760000300000|1760000300000|0|1005:4014333333333333:10005:4040000000000000:60300:0:1|1760000300000:42b5cccd:1005:10005:1|0|0|1005|1005|1005,1759940000000,1,1759940000000,1005,1760000300000,40a1999a,10005,0,1005,1760000300000,0,0,0,1760000300000|A:1005:1760000300000",
        "evict|6|1|0|1760000360000|1760000360000|0|1006:40143d70a3d70a3d:10006:4040000000000000:60360:0:1|1760000360000:42b628f6:1006:10006:1|0|0|1006|1006|1006,1759940000000,1,1759940000000,1006,1760000360000,40a1eb85,10006,0,1006,1760000360000,0,0,0,1760000360000|A:1006:1760000360000",
        "evict|7|1|0|1760000420000|1760000420000|0|1007:401447ae147ae148:10007:4040000000000000:60420:0:1|1760000420000:42b6851f:1007:10007:1|0|0|1007|1007|1007,1759940000000,1,1759940000000,1007,1760000420000,40a23d71,10007,0,1007,1760000420000,0,0,0,1760000420000|A:1007:1760000420000",
        "evict|8|1|0|1760000480000|1760000480000|0|1008:401451eb851eb852:10008:4040000000000000:60480:0:1|1760000480000:42b6e148:1008:10008:1|0|0|1008|1008|1008,1759940000000,1,1759940000000,1008,1760000480000,40a28f5c,10008,0,1008,1760000480000,0,0,0,1760000480000|A:1008:1760000480000",
        "evict|9|1|0|1760000540000|1760000540000|0|1009:40145c28f5c28f5c:10009:4040000000000000:60540:0:1|1760000540000:42b73d71:1009:10009:1|0|0|1009|1009|1009,1759940000000,1,1759940000000,1009,1760000540000,40a2e148,10009,0,1009,1760000540000,0,0,0,1760000540000|A:1009:1760000540000",
        "evict|10|1|0|1760000600000|1760000600000|0|1010:4014666666666666:10010:4040000000000000:60600:0:1|1760000600000:42b79999:1010:10010:1|0|0|1010|1010|1010,1759940000000,1,1759940000000,1010,1760000600000,40a33333,10010,0,1010,1760000600000,0,0,0,1760000600000|A:1010:1760000600000",
        "evict|11|1|0|1760000660000|1760000660000|0|1011:401470a3d70a3d71:10011:4040000000000000:60660:0:1|1760000660000:42b7f5c3:1011:10011:1|0|0|1011|1011|1011,1759940000000,1,1759940000000,1011,1760000660000,40a3851f,10011,0,1011,1760000660000,0,0,0,1760000660000|A:1011:1760000660000",
        "evict|12|1|0|1760000720000|1760000720000|0|1012:40147ae147ae147b:10012:4040000000000000:60720:0:1|1760000720000:42b851eb:1012:10012:1|0|0|1012|1012|1012,1759940000000,1,1759940000000,1012,1760000720000,40a3d70a,10012,0,1012,1760000720000,0,0,0,1760000720000|A:1012:1760000720000",
        "evict|13|1|0|1760000780000|1760000780000|0|1013:4014851eb851eb85:10013:4040000000000000:60780:0:1|1760000780000:42b8ae15:1013:10013:1|0|0|1013|1013|1013,1759940000000,1,1759940000000,1013,1760000780000,40a428f6,10013,0,1013,1760000780000,0,0,0,1760000780000|A:1013:1760000780000",
        "evict|14|1|0|1760000840000|1760000840000|0|1014:40148f5c28f5c28f:10014:4040000000000000:60840:0:1|1760000840000:42b90a3d:1014:10014:1|0|0|1014|1014|1014,1759940000000,1,1759940000000,1014,1760000840000,40a47ae1,10014,0,1014,1760000840000,0,0,0,1760000840000|A:1014:1760000840000",
        "evict|15|1|0|1760000900000|1760000900000|0|1015:401499999999999a:10015:4040000000000000:60900:0:1|1760000900000:42b96667:1015:10015:1|0|0|1015|1015|1015,1759940000000,1,1759940000000,1015,1760000900000,40a4cccd,10015,0,1015,1760000900000,0,0,0,1760000900000|A:1015:1760000900000",
        "evict|16|1|0|1760000960000|1760000960000|0|1016:4014a3d70a3d70a4:10016:4040000000000000:60960:0:1|1760000960000:42b9c28f:1016:10016:1|0|0|1016|1016|1016,1759940000000,1,1759940000000,1016,1760000960000,40a51eb8,10016,0,1016,1760000960000,0,0,0,1760000960000|A:1016:1760000960000",
        "evict|17|1|0|1760001020000|1760001020000|0|1017:4014ae147ae147ae:10017:4040000000000000:61020:0:1|1760001020000:42ba1eb8:1017:10017:1|0|0|1017|1017|1017,1759940000000,1,1759940000000,1017,1760001020000,40a570a4,10017,0,1017,1760001020000,0,0,0,1760001020000|A:1017:1760001020000",
        "evict|18|1|0|1760001080000|1760001080000|0|1018:4014b851eb851eb8:10018:4040000000000000:61080:0:1|1760001080000:42ba7ae1:1018:10018:1|0|0|1018|1018|1018,1759940000000,1,1759940000000,1018,1760001080000,40a5c28f,10018,0,1018,1760001080000,0,0,0,1760001080000|A:1018:1760001080000",
        "evict|19|1|0|1760001140000|1760001140000|0|1019:4014c28f5c28f5c3:10019:4040000000000000:61140:0:1|1760001140000:42bad70a:1019:10019:1|0|0|1019|1019|1019,1759940000000,1,1759940000000,1019,1760001140000,40a6147b,10019,0,1019,1760001140000,0,0,0,1760001140000|A:1019:1760001140000",
        "evict|20|1|0|1760001200000|1760001200000|0|1020:4014cccccccccccd:10020:4040000000000000:61200:0:1|1760001200000:42bb3333:1020:10020:1|0|0|1020|1020|1020,1759940000000,1,1759940000000,1020,1760001200000,40a66666,10020,0,1020,1760001200000,0,0,0,1760001200000|A:1020:1760001200000",
        "evict|21|1|0|1760001260000|1760001260000|0|1021:4014d70a3d70a3d7:10021:4040000000000000:61260:0:1|1760001260000:42bb8f5c:1021:10021:1|0|0|1021|1021|1021,1759940000000,1,1759940000000,1021,1760001260000,40a6b852,10021,0,1021,1760001260000,0,0,0,1760001260000|A:1021:1760001260000",
        "evict|22|1|0|1760001320000|1760001320000|0|1022:4014e147ae147ae1:10022:4040000000000000:61320:0:1|1760001320000:42bbeb85:1022:10022:1|0|0|1022|1022|1022,1759940000000,1,1759940000000,1022,1760001320000,40a70a3d,10022,0,1022,1760001320000,0,0,0,1760001320000|A:1022:1760001320000",
        "evict|23|1|0|1760001380000|1760001380000|0|1023:4014eb851eb851ec:10023:4040000000000000:61380:0:1|1760001380000:42bc47ae:1023:10023:1|0|0|1023|1023|1023,1759940000000,1,1759940000000,1023,1760001380000,40a75c29,10023,0,1023,1760001380000,0,0,0,1760001380000|A:1023:1760001380000",
        "evict|24|1|0|1760001440000|1760001440000|0|1024:4014f5c28f5c28f6:10024:4040000000000000:61440:0:1|1760001440000:42bca3d6:1024:10024:1|0|0|1024|1024|1024,1759940000000,1,1759940000000,1024,1760001440000,40a7ae14,10024,0,1024,1760001440000,0,0,0,1760001440000|A:1024:1760001440000",
        "evict|25|1|0|1760001500000|1760001500000|0|1025:4015000000000000:10025:4040000000000000:61500:0:1|1760001500000:42bd0000:1025:10025:1|0|0|1025|1025|1025,1759940000000,1,1759940000000,1025,1760001500000,40a80000,10025,0,1025,1760001500000,0,0,0,1760001500000|A:1025:1760001500000",
        "evict|26|1|0|1760001560000|1760001560000|0|1026:40150a3d70a3d70a:10026:4040000000000000:61560:0:1|1760001560000:42bd5c2a:1026:10026:1|0|0|1026|1026|1026,1759940000000,1,1759940000000,1026,1760001560000,40a851ec,10026,0,1026,1760001560000,0,0,0,1760001560000|A:1026:1760001560000",
        "evict|27|1|0|1760001620000|1760001620000|0|1027:4015147ae147ae14:10027:4040000000000000:61620:0:1|1760001620000:42bdb852:1027:10027:1|0|0|1027|1027|1027,1759940000000,1,1759940000000,1027,1760001620000,40a8a3d7,10027,0,1027,1760001620000,0,0,0,1760001620000|A:1027:1760001620000",
        "evict|28|1|0|1760001680000|1760001680000|0|1028:40151eb851eb851f:10028:4040000000000000:61680:0:1|1760001680000:42be147b:1028:10028:1|0|0|1028|1028|1028,1759940000000,1,1759940000000,1028,1760001680000,40a8f5c3,10028,0,1028,1760001680000,0,0,0,1760001680000|A:1028:1760001680000",
        "evict|29|1|0|1760001740000|1760001740000|0|1029:401528f5c28f5c29:10029:4040000000000000:61740:0:1|1760001740000:42be70a4:1029:10029:1|0|0|1029|1029|1029,1759940000000,1,1759940000000,1029,1760001740000,40a947ae,10029,0,1029,1760001740000,0,0,0,1760001740000|A:1029:1760001740000",
        "evict|30|1|0|1760001800000|1760001800000|0|1030:4015333333333333:10030:4040000000000000:61800:0:1|1760001800000:42becccd:1030:10030:1|0|0|1030|1030|1030,1759940000000,1,1759940000000,1030,1760001800000,40a9999a,10030,0,1030,1760001800000,0,0,0,1760001800000|A:1030:1760001800000",
        "evict|31|1|0|1760001860000|1760001860000|0|1031:40153d70a3d70a3d:10031:4040000000000000:61860:0:1|1760001860000:42bf28f6:1031:10031:1|0|0|1031|1031|1031,1759940000000,1,1759940000000,1031,1760001860000,40a9eb85,10031,0,1031,1760001860000,0,0,0,1760001860000|A:1031:1760001860000",
        "evict|32|1|0|1760001920000|1760001920000|0|1032:401547ae147ae148:10032:4040000000000000:61920:0:1|1760001920000:42bf851f:1032:10032:1|0|0|1032|1032|1032,1759940000000,1,1759940000000,1032,1760001920000,40aa3d71,10032,0,1032,1760001920000,0,0,0,1760001920000|A:1032:1760001920000",
        "evict|33|1|0|1760001980000|1760001980000|0|1033:401551eb851eb852:10033:4040000000000000:61980:0:1|1760001980000:42bfe148:1033:10033:1|0|0|1033|1033|1033,1759940000000,1,1759940000000,1033,1760001980000,40aa8f5c,10033,0,1033,1760001980000,0,0,0,1760001980000|A:1033:1760001980000",
        "evict|34|1|0|1760002040000|1760002040000|0|1034:40155c28f5c28f5c:10034:4040000000000000:62040:0:1|1760002040000:42c03d71:1034:10034:1|0|0|1034|1034|1034,1759940000000,1,1759940000000,1034,1760002040000,40aae148,10034,0,1034,1760002040000,0,0,0,1760002040000|A:1034:1760002040000",
        "evict|35|1|0|1760002100000|1760002100000|0|1035:4015666666666666:10035:4040000000000000:62100:0:1|1760002100000:42c09999:1035:10035:1|0|0|1035|1035|1035,1759940000000,1,1759940000000,1035,1760002100000,40ab3333,10035,0,1035,1760002100000,0,0,0,1760002100000|A:1035:1760002100000",
        "evict|36|1|0|1760002160000|1760002160000|0|1036:401570a3d70a3d71:10036:4040000000000000:62160:0:1|1760002160000:42c0f5c3:1036:10036:1|0|0|1036|1036|1036,1759940000000,1,1759940000000,1036,1760002160000,40ab851f,10036,0,1036,1760002160000,0,0,0,1760002160000|A:1036:1760002160000",
        "evict|37|1|0|1760002220000|1760002220000|0|1037:40157ae147ae147b:10037:4040000000000000:62220:0:1|1760002220000:42c151eb:1037:10037:1|0|0|1037|1037|1037,1759940000000,1,1759940000000,1037,1760002220000,40abd70a,10037,0,1037,1760002220000,0,0,0,1760002220000|A:1037:1760002220000",
        "evict|38|1|0|1760002280000|1760002280000|0|1038:4015851eb851eb85:10038:4040000000000000:62280:0:1|1760002280000:42c1ae15:1038:10038:1|0|0|1038|1038|1038,1759940000000,1,1759940000000,1038,1760002280000,40ac28f6,10038,0,1038,1760002280000,0,0,0,1760002280000|A:1038:1760002280000",
        "evict|39|1|0|1760002340000|1760002340000|0|1039:40158f5c28f5c28f:10039:4040000000000000:62340:0:1|1760002340000:42c20a3d:1039:10039:1|0|0|1039|1039|1039,1759940000000,1,1759940000000,1039,1760002340000,40ac7ae1,10039,0,1039,1760002340000,0,0,0,1760002340000|A:1039:1760002340000",
        "evict|40|1|0|1760002400000|1760002400000|0|1040:401599999999999a:10040:4040000000000000:62400:0:1|1760002400000:42c26667:1040:10040:1|0|0|1040|1040|1040,1759940000000,1,1759940000000,1040,1760002400000,40accccd,10040,0,1040,1760002400000,0,0,0,1760002400000|A:1040:1760002400000",
        "evict|41|1|0|1760002460000|1760002460000|0|1041:4015a3d70a3d70a4:10041:4040000000000000:62460:0:1|1760002460000:42c2c28f:1041:10041:1|0|0|1041|1041|1041,1759940000000,1,1759940000000,1041,1760002460000,40ad1eb8,10041,0,1041,1760002460000,0,0,0,1760002460000|A:1041:1760002460000",
        "evict|42|1|0|1760002520000|1760002520000|0|1042:4015ae147ae147ae:10042:4040000000000000:62520:0:1|1760002520000:42c31eb8:1042:10042:1|0|0|1042|1042|1042,1759940000000,1,1759940000000,1042,1760002520000,40ad70a4,10042,0,1042,1760002520000,0,0,0,1760002520000|A:1042:1760002520000",
        "evict|43|1|0|1760002580000|1760002580000|0|1043:4015b851eb851eb8:10043:4040000000000000:62580:0:1|1760002580000:42c37ae1:1043:10043:1|0|0|1043|1043|1043,1759940000000,1,1759940000000,1043,1760002580000,40adc28f,10043,0,1043,1760002580000,0,0,0,1760002580000|A:1043:1760002580000",
        "evict|44|1|0|1760002640000|1760002640000|0|1044:4015c28f5c28f5c3:10044:4040000000000000:62640:0:1|1760002640000:42c3d70a:1044:10044:1|0|0|1044|1044|1044,1759940000000,1,1759940000000,1044,1760002640000,40ae147b,10044,0,1044,1760002640000,0,0,0,1760002640000|A:1044:1760002640000",
        "evict|45|1|0|1760002700000|1760002700000|0|1045:4015cccccccccccd:10045:4040000000000000:62700:0:1|1760002700000:42c43333:1045:10045:1|0|0|1045|1045|1045,1759940000000,1,1759940000000,1045,1760002700000,40ae6666,10045,0,1045,1760002700000,0,0,0,1760002700000|A:1045:1760002700000",
        "evict|46|1|0|1760002760000|1760002760000|0|1046:4015d70a3d70a3d7:10046:4040000000000000:62760:0:1|1760002760000:42c48f5c:1046:10046:1|0|0|1046|1046|1046,1759940000000,1,1759940000000,1046,1760002760000,40aeb852,10046,0,1046,1760002760000,0,0,0,1760002760000|A:1046:1760002760000",
        "evict|47|1|0|1760002820000|1760002820000|0|1047:4015e147ae147ae1:10047:4040000000000000:62820:0:1|1760002820000:42c4eb85:1047:10047:1|0|0|1047|1047|1047,1759940000000,1,1759940000000,1047,1760002820000,40af0a3d,10047,0,1047,1760002820000,0,0,0,1760002820000|A:1047:1760002820000",
        "evict|48|1|0|1760002880000|1760002880000|0|1048:4015eb851eb851ec:10048:4040000000000000:62880:0:1|1760002880000:42c547ae:1048:10048:1|0|0|1048|1048|1048,1759940000000,1,1759940000000,1048,1760002880000,40af5c29,10048,0,1048,1760002880000,0,0,0,1760002880000|A:1048:1760002880000",
        "evict|49|1|0|1760002940000|1760002940000|0|1049:4015f5c28f5c28f6:10049:4040000000000000:62940:0:1|1760002940000:42c5a3d6:1049:10049:1|0|0|1049|1049|1049,1759940000000,1,1759940000000,1049,1760002940000,40afae14,10049,0,1049,1760002940000,0,0,0,1760002940000|A:1049:1760002940000",
        "evict|50|1|0|1760003000000|1760003000000|0|1050:4016000000000000:10050:4040000000000000:63000:0:1|1760003000000:42c60000:1050:10050:1|0|0|1050|1050|1050,1759940000000,1,1759940000000,1050,1760003000000,40b00000,10050,0,1050,1760003000000,0,0,0,1760003000000|A:1050:1760003000000",
        "evict|51|1|0|1760003060000|1760003060000|0|1051:40160a3d70a3d70a:10051:4040000000000000:63060:0:1|1760003060000:42c65c2a:1051:10051:1|0|0|1051|1051|1051,1759940000000,1,1759940000000,1051,1760003060000,40b051ec,10051,0,1051,1760003060000,0,0,0,1760003060000|A:1051:1760003060000",
        "evict|52|1|0|1760003120000|1760003120000|0|1052:4016147ae147ae14:10052:4040000000000000:63120:0:1|1760003120000:42c6b852:1052:10052:1|0|0|1052|1052|1052,1759940000000,1,1759940000000,1052,1760003120000,40b0a3d7,10052,0,1052,1760003120000,0,0,0,1760003120000|A:1052:1760003120000",
        "evict|53|1|0|1760003180000|1760003180000|0|1053:40161eb851eb851f:10053:4040000000000000:63180:0:1|1760003180000:42c7147b:1053:10053:1|0|0|1053|1053|1053,1759940000000,1,1759940000000,1053,1760003180000,40b0f5c3,10053,0,1053,1760003180000,0,0,0,1760003180000|A:1053:1760003180000",
        "evict|54|1|0|1760003240000|1760003240000|0|1054:401628f5c28f5c29:10054:4040000000000000:63240:0:1|1760003240000:42c770a4:1054:10054:1|0|0|1054|1054|1054,1759940000000,1,1759940000000,1054,1760003240000,40b147ae,10054,0,1054,1760003240000,0,0,0,1760003240000|A:1054:1760003240000",
        "evict|55|1|0|1760003300000|1760003300000|0|1055:4016333333333333:10055:4040000000000000:63300:0:1|1760003300000:42c7cccd:1055:10055:1|0|0|1055|1055|1055,1759940000000,1,1759940000000,1055,1760003300000,40b1999a,10055,0,1055,1760003300000,0,0,0,1760003300000|A:1055:1760003300000",
        "evict|56|1|0|1760003360000|1760003360000|0|1056:40163d70a3d70a3e:10056:4040000000000000:63360:0:1|1760003360000:42c828f6:1056:10056:1|0|0|1056|1056|1056,1759940000000,1,1759940000000,1056,1760003360000,40b1eb85,10056,0,1056,1760003360000,0,0,0,1760003360000|A:1056:1760003360000",
        "evict|57|1|0|1760003420000|1760003420000|0|1057:401647ae147ae148:10057:4040000000000000:63420:0:1|1760003420000:42c8851f:1057:10057:1|0|0|1057|1057|1057,1759940000000,1,1759940000000,1057,1760003420000,40b23d71,10057,0,1057,1760003420000,0,0,0,1760003420000|A:1057:1760003420000",
        "evict|58|1|0|1760003480000|1760003480000|0|1058:401651eb851eb852:10058:4040000000000000:63480:0:1|1760003480000:42c8e148:1058:10058:1|0|0|1058|1058|1058,1759940000000,1,1759940000000,1058,1760003480000,40b28f5c,10058,0,1058,1760003480000,0,0,0,1760003480000|A:1058:1760003480000",
        "evict|59|1|0|1760003540000|1760003540000|0|1059:40165c28f5c28f5c:10059:4040000000000000:63540:0:1|1760003540000:42c93d71:1059:10059:1|0|0|1059|1059|1059,1759940000000,1,1759940000000,1059,1760003540000,40b2e148,10059,0,1059,1760003540000,0,0,0,1760003540000|A:1059:1760003540000",
        "evict|60|1|0|1760003600000|1760003600000|0|1060:4016666666666666:10060:4040000000000000:63600:0:1|1760003600000:42c99999:1060:10060:1|0|0|1060|1060|1060,1759940000000,1,1759940000000,1060,1760003600000,40b33333,10060,0,1060,1760003600000,0,0,0,1760003600000|A:1060:1760003600000",
        "evict|61|1|0|1760003660000|1760003660000|0|1061:401670a3d70a3d71:10061:4040000000000000:63660:0:1|1760003660000:42c9f5c3:1061:10061:1|0|0|1061|1061|1061,1759940000000,1,1759940000000,1061,1760003660000,40b3851f,10061,0,1061,1760003660000,0,0,0,1760003660000|A:1061:1760003660000",
        "evict|62|1|0|1760003720000|1760003720000|0|1062:40167ae147ae147b:10062:4040000000000000:63720:0:1|1760003720000:42ca51eb:1062:10062:1|0|0|1062|1062|1062,1759940000000,1,1759940000000,1062,1760003720000,40b3d70a,10062,0,1062,1760003720000,0,0,0,1760003720000|A:1062:1760003720000",
        "evict|63|1|0|1760003780000|1760003780000|0|1063:4016851eb851eb85:10063:4040000000000000:63780:0:1|1760003780000:42caae15:1063:10063:1|0|0|1063|1063|1063,1759940000000,1,1759940000000,1063,1760003780000,40b428f6,10063,0,1063,1760003780000,0,0,0,1760003780000|A:1063:1760003780000",
        "evict|64|1|0|1760003840000|1760003840000|0|1064:40168f5c28f5c28f:10064:4040000000000000:63840:0:1|1760003840000:42cb0a3d:1064:10064:1|0|0|1064|1064|1064,1759940000000,1,1759940000000,1064,1760003840000,40b47ae1,10064,0,1064,1760003840000,0,0,0,1760003840000|A:1064:1760003840000",
        "evict|65|1|0|1760003900000|1760003900000|0|1065:401699999999999a:10065:4040000000000000:63900:0:1|1760003900000:42cb6667:1065:10065:1|0|0|1065|1065|1065,1759940000000,1,1759940000000,1065,1760003900000,40b4cccd,10065,0,1065,1760003900000,0,0,0,1760003900000|A:1065:1760003900000",
        "evict|66|1|0|1760003960000|1760003960000|0|1066:4016a3d70a3d70a4:10066:4040000000000000:63960:0:1|1760003960000:42cbc28f:1066:10066:1|0|0|1066|1066|1066,1759940000000,1,1759940000000,1066,1760003960000,40b51eb8,10066,0,1066,1760003960000,0,0,0,1760003960000|A:1066:1760003960000",
        "evict|67|1|0|1760004020000|1760004020000|0|1067:4016ae147ae147ae:10067:4040000000000000:64020:0:1|1760004020000:42cc1eb8:1067:10067:1|0|0|1067|1067|1067,1759940000000,1,1759940000000,1067,1760004020000,40b570a4,10067,0,1067,1760004020000,0,0,0,1760004020000|A:1067:1760004020000",
        "evict|68|1|0|1760004080000|1760004080000|0|1068:4016b851eb851eb8:10068:4040000000000000:64080:0:1|1760004080000:42cc7ae1:1068:10068:1|0|0|1068|1068|1068,1759940000000,1,1759940000000,1068,1760004080000,40b5c28f,10068,0,1068,1760004080000,0,0,0,1760004080000|A:1068:1760004080000",
        "evict|69|1|0|1760004140000|1760004140000|0|1069:4016c28f5c28f5c3:10069:4040000000000000:64140:0:1|1760004140000:42ccd70a:1069:10069:1|0|0|1069|1069|1069,1759940000000,1,1759940000000,1069,1760004140000,40b6147b,10069,0,1069,1760004140000,0,0,0,1760004140000|A:1069:1760004140000",
        "evict|70|1|0|1760004260000|1760004260000|0|1069:4016c28f5c28f5c3:10069:4040000000000000:64140:0:1|1760004140000:42ccd70a:1069:10069:1|0|0|1069|1069|1069,1759940000000,1,1759940000000,1069,1760004140000,40b6147b,10069,0,1069,1760004140000,0,0,0,1760004260000|A:1069:1760004140000",
        "evict|71|1|0|1760004265000|1760004265000|0|1000:4014000000000000:10000:4040000000000000:60000:0:1|1760000000000:42b40000:1000:10000:0|0|0|1000|1000|1069,1759940000000,1,1759940000000,1069,1760004140000,40b6147b,10069,0,1069,1760004140000,0,0,0,1760004265000|A:1000:1760000000000",
        "warmup|0|1|1|1759998500000|1759998500000|0|5:4014000000000000:10000:4040000000000000:300:0:1||0|0|5|5|-1,1759998200000,1,0,-1,0,00000000,0,0,-1,0,0,0,0,1759998500000|R:5:warmup",
        "warmup|1|1|1|1759999700000|1759999700000|0|25:4014000000000000:10020:4040000000000000:1500:0:1|1759999700000:42b40000:25:10020:1|0|0|25|25|25,1759998200000,1,1759998200000,25,1759999700000,40a00000,10020,0,25,1759999700000,0,0,1,1759999700000|A:25:1759999700000"
    ]
}
