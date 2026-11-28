//
//  MQSessionTests.swift
//  xdripTests
//
//  Expected values come from running the unchanged JugglucoNG Kotlin (`MQLinkPolicy`, `MQSessionTiming`,
//  `MQSessionRestorePolicy`, `MQCloudHistoryTiming`) on the JVM, and a harness that carries the
//  session logic of `MQBleManager` (`calculateVendorGlucose`, `synthesizeReferenceFromSensitivity`,
//  `processBgRecords`, `applyPendingCalibrationFromLatestSample`) without the Android parts through
//  five scenarios: a sensitivity seeded sensor with a clean and a noisy signal, a burst replay after a
//  lost link, a fingerstick calibrated sensor, the legacy algorithm version and a session start that
//  is unknown. The scenarios drive `MQBurstBuffer` and `MQSessionTracker`; every reading and every
//  state line is compared bit for bit. Never compared with a real sensor.
//

import XCTest
@testable import xdrip

final class MQSessionTests: XCTestCase {

    private typealias V = MQVectorSupport

    // MARK: - policies

    func testLinkPolicyVectors() {
        for line in MQSessionVectors.link {
            let f = V.fields(line)
            let alive = MQLinkPolicy.hasRecentActivity(
                nowMs: Int64(f[1]) ?? 0, connectedAtMs: Int64(f[2]) ?? 0, lastFrameAtMs: Int64(f[3]) ?? 0,
                firstFrameTimeoutMs: Int64(f[4]) ?? 0, frameTimeoutMs: Int64(f[5]) ?? 0
            )
            XCTAssertEqual(V.flag(alive), f[6], line)
        }
    }

    func testStartEstimateVectors() {
        for line in MQSessionVectors.estimate {
            let f = V.fields(line)
            let estimate = MQSessionTiming.estimateStartMs(
                receivedAtMs: Int64(f[1]) ?? 0, newestPacket: Int(f[2]) ?? 0, intervalMinutes: Int(f[3]) ?? 0
            )
            XCTAssertEqual(estimate, V.optionalInt64(f[4]), line)
        }
    }

    func testStartReconciliationVectors() {
        for line in MQSessionVectors.reconcile {
            let f = V.fields(line)
            let start = MQSessionTiming.reconcileStartMs(
                existingStartMs: Int64(f[1]) ?? 0, receivedAtMs: Int64(f[2]) ?? 0,
                newestPacket: Int(f[3]) ?? 0, intervalMinutes: Int(f[4]) ?? 0
            )
            XCTAssertEqual(start, Int64(f[5]), line)
        }
    }

    func testRestorePolicyVectors() {
        for line in MQSessionVectors.restore {
            let f = V.fields(line)
            let allowed = MQSessionRestorePolicy.canRestore(
                requestedBleId: V.optionalText(f[1]), snapshotBleId: V.optionalText(f[2]),
                startAtMs: V.optionalInt64(f[3]), nowMs: Int64(f[4]) ?? 0
            )
            XCTAssertEqual(V.flag(allowed), f[5], line)
        }
    }

    func testCloudHistoryTimingVectors() {
        let receivedAt: Int64 = 1_789_374_278_299
        let anchor = MQCloudHistoryTiming.Anchor(packetIndex: 443, receivedAtMs: receivedAt)
        let cloudOrigin: Int64 = 1_789_338_811_000
        let history = (249...438).filter { $0 != 250 }.map {
            MQBootstrapHistoryPoint(timestampMs: cloudOrigin + Int64($0) * 180_000, packetIndex: $0, glucoseMgdl: 64.8)
        }

        func show(_ label: String, _ points: [MQBootstrapHistoryPoint], _ anchor: MQCloudHistoryTiming.Anchor?, _ now: Int64, _ interval: Int) -> String {
            let prepared = MQCloudHistoryTiming.prepare(history: points, anchor: anchor, nowMs: now, intervalMinutes: interval)
            let first = prepared.history.first
            let last = prepared.history.last
            let fields: [String] = [
                "HIST", label, String(points.count), String(prepared.history.count), V.flag(prepared.deferred), V.flag(prepared.estimated),
                first.map { String($0.timestampMs) } ?? "nil", last.map { String($0.timestampMs) } ?? "nil",
                first.map { String($0.packetIndex) } ?? "nil", last.map { String($0.packetIndex) } ?? "nil",
                first.map { V.bits($0.glucoseMgdl) } ?? "nil"
            ]
            return fields.joined(separator: "|")
        }

        var skewed = history
        skewed[0].timestampMs += 120_000
        var newerCycle = history
        newerCycle.append(MQBootstrapHistoryPoint(timestampMs: history[history.count - 1].timestampMs, packetIndex: 444, glucoseMgdl: 64.8))
        var packetZero = history
        packetZero.append(MQBootstrapHistoryPoint(timestampMs: history[0].timestampMs, packetIndex: 0, glucoseMgdl: 64.8))
        let valid = history.map { MQBootstrapHistoryPoint(timestampMs: $0.timestampMs - 44_280_000, packetIndex: $0.packetIndex, glucoseMgdl: $0.glucoseMgdl) }
        let liveOrigin = receivedAt - 443 * 180_000
        let edge = history.prefix(5).map {
            MQBootstrapHistoryPoint(timestampMs: liveOrigin + 2 * 180_000 + Int64($0.packetIndex) * 180_000, packetIndex: $0.packetIndex, glucoseMgdl: $0.glucoseMgdl)
        }
        let edgePlusOne = edge.map { MQBootstrapHistoryPoint(timestampMs: $0.timestampMs + 1, packetIndex: $0.packetIndex, glucoseMgdl: $0.glucoseMgdl) }
        let sixty = edge.map { MQBootstrapHistoryPoint(timestampMs: receivedAt + 60_000, packetIndex: $0.packetIndex, glucoseMgdl: $0.glucoseMgdl) }

        let actual: [String] = [
            show("recovered", history, anchor, receivedAt, 3),
            show("deferred", history, nil, receivedAt, 3),
            show("valid", valid, nil, receivedAt, 3),
            show("skewed", skewed, anchor, receivedAt, 3),
            show("newerCycle", newerCycle, anchor, receivedAt, 3),
            show("packetZero", packetZero, anchor, receivedAt, 3),
            show("onePoint", Array(history.prefix(1)), anchor, receivedAt, 3),
            show("samePacketTwice", [history[0], history[0]], anchor, receivedAt, 3),
            show("anchorNoTime", history, MQCloudHistoryTiming.Anchor(packetIndex: 443, receivedAtMs: 0), receivedAt, 3),
            show("anchorTerminal", history, MQCloudHistoryTiming.Anchor(packetIndex: 15000, receivedAtMs: receivedAt), receivedAt, 3),
            show("noInterval", history, anchor, receivedAt, 0),
            show("anchorInFuture", history, MQCloudHistoryTiming.Anchor(packetIndex: 443, receivedAtMs: receivedAt + 61_000), receivedAt, 3),
            show("empty", [], anchor, receivedAt, 3),
            show("emptyNoAnchor", [], nil, receivedAt, 3),
            show("shiftExactlyTwo", edge, anchor, receivedAt, 3),
            show("shiftTwoPlus", edgePlusOne, anchor, receivedAt + 10_000_000, 3),
            show("futureOnlyBySixtySeconds", sixty, anchor, receivedAt, 3)
        ]
        XCTAssertEqual(actual.count, MQSessionVectors.history.count)
        for (index, line) in MQSessionVectors.history.enumerated() where index < actual.count {
            XCTAssertEqual(actual[index], line)
        }
    }

    // MARK: - burst buffer

    private func record(_ packet: Int, _ current: Int = 100, battery: Int = 0x32, marker: Int = 0x40) -> MQBgRecord {
        return MQBgRecord(
            indexInPacket: 0, marker: marker, packetIndex: packet, sampleCurrent: current, batteryRaw: battery,
            recordBytes: [UInt8(marker), UInt8(packet & 0xFF), UInt8((packet >> 8) & 0xFF), UInt8(current & 0xFF), UInt8((current >> 8) & 0xFF), UInt8(battery)]
        )
    }

    func testBurstBufferSortsByPacketAndAnchorsAtTheNewest() throws {
        var buffer = MQBurstBuffer()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.flush())
        buffer.add([record(30), record(28)], receivedAtMs: 1_000)
        buffer.add([record(29)], receivedAtMs: 2_000)
        buffer.add([record(31)], receivedAtMs: 3_000)
        XCTAssertFalse(buffer.isEmpty)
        let flushed = try XCTUnwrap(buffer.flush())
        XCTAssertEqual(flushed.records.map { $0.packetIndex }, [28, 29, 30, 31])
        XCTAssertEqual(flushed.anchorPacketIndex, 31)
        // the anchor time is when the frame of the newest packet arrived
        XCTAssertEqual(flushed.anchorMs, 3_000)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.flush())
    }

    func testBurstBufferKeepsTheLaterRecordOfAPacket() throws {
        var buffer = MQBurstBuffer()
        buffer.add([record(33, 205)], receivedAtMs: 1_000)
        buffer.add([record(33, 207)], receivedAtMs: 1_500)
        let flushed = try XCTUnwrap(buffer.flush())
        XCTAssertEqual(flushed.records.count, 1)
        XCTAssertEqual(flushed.records.first?.sampleCurrent, 207)
        XCTAssertEqual(flushed.anchorMs, 1_500)
    }

    func testBurstBufferClear() {
        var buffer = MQBurstBuffer()
        buffer.add([record(1)], receivedAtMs: 1)
        buffer.clear()
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - scenarios

    private struct Scenario {
        var tracker: MQSessionTracker
        var parameters: MQAlgorithmParameters
    }

    private func records(from text: String) -> [MQBgRecord] {
        // packet:current:battery:marker;...
        return text.split(separator: ";").map { part in
            let values = part.split(separator: ":").map { Int($0) ?? 0 }
            return record(values[0], values[1], battery: values[2], marker: values[3])
        }
    }

    private func describe(_ reading: MQReading, tag: String, name: String) -> String {
        let r = reading.result
        let fields: [String] = [
            "OUT", name, tag, String(reading.record.packetIndex), String(reading.sampleMs), String(r.glucoseTimes10Mmol),
            String(r.mgdlTimes10), V.bits(r.mgdl), V.bits(r.kValue), V.bits(r.bValue), V.bits(r.reviseCurrent2),
            V.bits(r.referenceBgTimes10Mmol), V.bits(r.sampleCurrent), V.bits(r.previousReviseCurrent2)
        ]
        return fields.joined(separator: "|")
    }

    private func describeState(_ t: MQSessionTracker, name: String, label: String) -> String {
        let fields: [String] = [
            "STATE", name, label, String(t.lastPacketIndex), String(t.lastObservedPacketIndex), String(t.lastRecordReceivedAtMs),
            V.bits(t.lastRawCurrent), String(t.lastBatteryRaw), String(t.lastGlucoseAtMs), String(t.lastGlucoseMgdlTimes10),
            String(t.packetCount), V.bits(t.kValue), V.bits(t.bValue), V.bits(t.lastProcessed), V.bits(t.pendingReferenceTimes10Mmol)
        ]
        return fields.joined(separator: "|")
    }

    func testScenarios() {
        var scenarios = [String: Scenario]()
        // readings produced by the last action that the following OUT lines must match, in order
        var produced = [(reading: MQReading, tag: String)]()
        var calibrationText: String?
        var checkedStates = 0
        var checkedReadings = 0

        for line in MQSessionVectors.scenarios {
            let f = V.fields(line)
            let name = f[1]
            switch f[0] {
            case "CFG":
                var parameters = MQAlgorithmParameters()
                parameters.algorithmVersion = Int(f[2]) ?? 0
                parameters.packages = Int(f[3]) ?? 0
                parameters.multiplier = V.f(f[4])
                parameters.sensitivitySeed = V.f(f[5])
                var tracker = MQSessionTracker()
                tracker.sensorStartAtMs = Int64(f[6]) ?? 0
                scenarios[name] = Scenario(tracker: tracker, parameters: parameters)
                XCTAssertEqual(Int(f[7]), MQConstants.readingIntervalMinutes, line)

            case "BURST":
                guard var scenario = scenarios[name] else { XCTFail("no scenario for \(line)"); continue }
                let anchorMs = Int64(f[2]) ?? 0
                var buffer = MQBurstBuffer()
                buffer.add(records(from: f[3]), receivedAtMs: anchorMs)
                guard let burst = buffer.flush() else { XCTFail("empty burst for \(line)"); continue }
                XCTAssertTrue(produced.isEmpty, "unchecked readings before \(line)")
                let readings = scenario.tracker.processBurst(
                    burst.records, anchorPacketIndex: burst.anchorPacketIndex, anchorMs: burst.anchorMs,
                    intervalMs: MQProfile.default.readingIntervalMs, parameters: scenario.parameters
                )
                produced = readings.map { ($0, "burst") }
                scenarios[name] = scenario

            case "CALIBRATE":
                guard var scenario = scenarios[name] else { XCTFail("no scenario for \(line)"); continue }
                XCTAssertTrue(produced.isEmpty, "unchecked readings before \(line)")
                let outcome = scenario.tracker.calibrate(
                    glucoseMgDl: Int(f[2]) ?? 0, nowMs: Int64(f[3]) ?? 0, frameTimeoutMs: 390_000, parameters: scenario.parameters
                )
                let pending = V.bits(scenario.tracker.pendingReferenceTimes10Mmol)
                switch outcome {
                case .rejected: calibrationText = "CAL|\(name)|\(f[2])|rejected"
                case .queued: calibrationText = "CAL|\(name)|\(f[2])|queued|\(pending)"
                case .noResult: calibrationText = "CAL|\(name)|\(f[2])|no-result|\(pending)"
                case .applied(let reading):
                    calibrationText = "CAL|\(name)|\(f[2])|applied|\(pending)"
                    produced = [(reading, "calibration")]
                }
                scenarios[name] = scenario

            case "CAL":
                XCTAssertEqual(calibrationText, line)
                calibrationText = nil

            case "OUT":
                guard !produced.isEmpty else { XCTFail("no reading produced for \(line)"); continue }
                let next = produced.removeFirst()
                XCTAssertEqual(describe(next.reading, tag: next.tag, name: name), line)
                checkedReadings += 1

            case "STATE":
                guard let scenario = scenarios[name] else { XCTFail("no scenario for \(line)"); continue }
                XCTAssertTrue(produced.isEmpty, "readings without an OUT line before \(line)")
                XCTAssertEqual(describeState(scenario.tracker, name: name, label: f[2]), line)
                checkedStates += 1

            default:
                XCTFail("unknown vector line \(line)")
            }
        }
        XCTAssertTrue(produced.isEmpty)
        XCTAssertGreaterThan(checkedStates, 150)
        XCTAssertGreaterThan(checkedReadings, 100)
    }

    // MARK: - tracker behaviour

    func testBeginWorkOfAFreshSessionOnlyMarksTheStart() {
        var tracker = MQSessionTracker()
        XCTAssertFalse(tracker.noteBeginWork(nowMs: 5_000))
        XCTAssertEqual(tracker.sensorStartAtMs, 5_000)
        // a repeated BEGIN_WORK before any packet keeps the first start
        XCTAssertFalse(tracker.noteBeginWork(nowMs: 9_000))
        XCTAssertEqual(tracker.sensorStartAtMs, 5_000)
    }

    func testBeginWorkSupersedesARunningSession() {
        var tracker = MQSessionTracker()
        tracker.kValue = 29.41
        tracker.bValue = 2
        tracker.lastProcessed = 120
        tracker.lastPacketIndex = 90
        tracker.lastObservedPacketIndex = 91
        tracker.sensorStartAtMs = 1_000
        tracker.pendingReferenceTimes10Mmol = 60
        XCTAssertTrue(tracker.noteBeginWork(nowMs: 8_000_000))
        // everything of the old session is gone, and the new one starts now
        XCTAssertEqual(tracker.kValue, 0)
        XCTAssertEqual(tracker.bValue, 0)
        XCTAssertEqual(tracker.lastProcessed, 0)
        XCTAssertEqual(tracker.lastPacketIndex, -1)
        XCTAssertEqual(tracker.lastObservedPacketIndex, -1)
        XCTAssertEqual(tracker.pendingReferenceTimes10Mmol, 0)
        XCTAssertEqual(tracker.sensorStartAtMs, 8_000_000)
    }

    func testReconcileStartRepairsAConnectionTimeStart() {
        var tracker = MQSessionTracker()
        tracker.sensorStartAtMs = 1_789_337_213_000 // connection time
        XCTAssertTrue(tracker.reconcileStart(newestPacket: 237, nowMs: 1_789_337_213_000, intervalMinutes: 3))
        XCTAssertEqual(tracker.sensorStartAtMs, 1_789_294_553_000)
        // already consistent: unchanged
        XCTAssertFalse(tracker.reconcileStart(newestPacket: 237, nowMs: 1_789_337_213_000, intervalMinutes: 3))
        XCTAssertFalse(tracker.reconcileStart(newestPacket: nil, nowMs: 1_789_337_213_000, intervalMinutes: 3))
    }

    func testRestoreDiscardsAnImplausibleSlope() {
        var tracker = MQSessionTracker()
        tracker.kValue = 0.5
        tracker.bValue = 2
        tracker.lastProcessed = -4
        tracker.lastPacketIndex = 12
        tracker.pendingReferenceTimes10Mmol = 50
        tracker.prepareForNewRun()
        XCTAssertEqual(tracker.kValue, 0)
        XCTAssertEqual(tracker.bValue, 0)
        XCTAssertEqual(tracker.lastProcessed, 0)
        XCTAssertEqual(tracker.pendingReferenceTimes10Mmol, 0)
        XCTAssertEqual(tracker.lastObservedPacketIndex, 12)
        XCTAssertEqual(tracker.lastPacketIndex, 12)

        var good = MQSessionTracker()
        good.kValue = 29.41
        good.bValue = 2
        good.prepareForNewRun()
        XCTAssertEqual(good.kValue, 29.41)
        XCTAssertEqual(good.bValue, 2)
    }

    func testNoValueWithoutASeedOrAReference() {
        var tracker = MQSessionTracker()
        tracker.sensorStartAtMs = 1_000
        let parameters = MQAlgorithmParameters()
        let readings = tracker.processBurst(
            [record(40, 150), record(41, 152)], anchorPacketIndex: 41, anchorMs: 10_000_000,
            intervalMs: 180_000, parameters: parameters
        )
        XCTAssertEqual(readings, [])
        // the packets were seen, but none produced a reading, so the delivered counter did not move
        XCTAssertEqual(tracker.lastPacketIndex, -1)
        XCTAssertEqual(tracker.lastObservedPacketIndex, 41)
        XCTAssertEqual(tracker.packetCount, 2)
        XCTAssertEqual(tracker.lastRawCurrent, 152)
    }

    func testCalibrationRejectsNonPositiveValues() {
        var tracker = MQSessionTracker()
        XCTAssertEqual(tracker.calibrate(glucoseMgDl: 0, nowMs: 1, frameTimeoutMs: 390_000, parameters: MQAlgorithmParameters()), .rejected)
        XCTAssertEqual(tracker.calibrate(glucoseMgDl: -5, nowMs: 1, frameTimeoutMs: 390_000, parameters: MQAlgorithmParameters()), .rejected)
        XCTAssertEqual(tracker.pendingReferenceTimes10Mmol, 0)
    }

    func testCalibrationBeforeAnyPacketIsQueued() {
        var tracker = MQSessionTracker()
        XCTAssertEqual(tracker.calibrate(glucoseMgDl: 100, nowMs: 1, frameTimeoutMs: 390_000, parameters: MQAlgorithmParameters()), .queued)
        XCTAssertGreaterThan(tracker.pendingReferenceTimes10Mmol, 0)
    }

    func testPlausibleFingerstickRange() {
        XCTAssertFalse(MQCalibrationInput.isPlausible(mgdl: 39))
        XCTAssertTrue(MQCalibrationInput.isPlausible(mgdl: 40))
        XCTAssertTrue(MQCalibrationInput.isPlausible(mgdl: 108))
        XCTAssertTrue(MQCalibrationInput.isPlausible(mgdl: 400))
        XCTAssertFalse(MQCalibrationInput.isPlausible(mgdl: 401))
        XCTAssertFalse(MQCalibrationInput.isPlausible(mgdl: 0))
    }

    func testSessionLifetime() {
        var tracker = MQSessionTracker()
        XCTAssertEqual(tracker.officialEndMs(), 0)
        XCTAssertFalse(tracker.isExpired(nowMs: 10_000_000_000))
        tracker.sensorStartAtMs = 1_000_000
        XCTAssertEqual(tracker.officialEndMs(), 1_000_000 + 1_382_400_000)
        XCTAssertFalse(tracker.isExpired(nowMs: 1_000_000 + 1_382_399_999))
        XCTAssertTrue(tracker.isExpired(nowMs: 1_000_000 + 1_382_400_000))
    }

    func testTrackerSurvivesAJSONRoundTrip() throws {
        var tracker = MQSessionTracker()
        tracker.kValue = 29.41
        tracker.bValue = 2
        tracker.lastProcessed = 104.5
        tracker.lastPacketIndex = 345
        tracker.sensorStartAtMs = 1_789_294_553_000
        let data = try JSONEncoder().encode(tracker)
        let decoded = try JSONDecoder().decode(MQSessionTracker.self, from: data)
        XCTAssertEqual(decoded, tracker)
    }
}

private enum MQSessionVectors {

        static let link: [String] = [
            "LINK|1789297363000|1789296946000|1789297210000|210000|390000|true",
            "LINK|1209999|1000000|0|210000|390000|true",
            "LINK|1210000|1000000|0|210000|390000|false",
            "LINK|1569999|1000000|1180000|210000|390000|true",
            "LINK|1570000|1000000|1180000|210000|390000|false",
            "LINK|1210000|1000000|999999|210000|390000|false",
            "LINK|1000000|0|0|210000|390000|false",
            "LINK|500|1000|1000|210000|390000|true",
            "LINK|1000000|1000000|1000000|210000|390000|true",
            "LINK|60000|1|0|60000|60000|true",
            "LINK|60001|1|0|60000|60000|false"
        ]

        static let estimate: [String] = [
            "EST|1789337213000|237|3|1789294553000",
            "EST|1789337393000|238|3|1789294553000",
            "EST|1789337213000|-1|3|nil",
            "EST|1789337213000|0|3|nil",
            "EST|1789337213000|15000|3|nil",
            "EST|1789337213000|14999|3|1786637393000",
            "EST|1789337213000|65535|3|nil",
            "EST|1000|237|3|nil",
            "EST|1789337213000|237|0|nil",
            "EST|1789337213000|237|-3|nil",
            "EST|0|5|3|nil",
            "EST|-5|5|3|nil",
            "EST|1789337213000|1|3|1789337033000",
            "EST|1000000000000|5|1|999999700000",
            "EST|540000|3|3|nil",
            "EST|540001|3|3|1"
        ]

        static let reconcile: [String] = [
            "RECON|1789337213000|1789337213000|237|3|1789294553000",
            "RECON|1789294523000|1789337213000|237|3|1789294523000",
            "RECON|1789294583000|1789337213000|237|3|1789294583000",
            "RECON|1789294553000|1789337213000|237|3|1789294553000",
            "RECON|0|1789337213000|237|3|1789294553000",
            "RECON|-1|1789337213000|237|3|1789294553000",
            "RECON|1789294913000|1789337213000|237|3|1789294913000",
            "RECON|1789294913001|1789337213000|237|3|1789294553000",
            "RECON|1789294912999|1789337213000|237|3|1789294912999",
            "RECON|5000|1789337213000|0|3|5000",
            "RECON|0|1789337213000|15000|3|0"
        ]

        static let restore: [String] = [
            "RESTORE|W25101399|W25101399|1777312377000|1789295304000|false",
            "RESTORE|W25101399|w25101399|1789208904000|1789295304000|true",
            "RESTORE|W25101399|W25101398|1789208904000|1789295304000|false",
            "RESTORE|W25101399|nil|1789208904000|1789295304000|false",
            "RESTORE|nil|nil|1789208904000|1789295304000|false",
            "RESTORE|W25101399|W25101399|nil|1789295304000|false",
            "RESTORE|W25101399|W25101399|0|1789295304000|false",
            "RESTORE|W25101399|W25101399|-1|1789295304000|false",
            "RESTORE|W25101399|W25101399|1789295304001|1789295304000|false",
            "RESTORE|W25101399|W25101399|1787912904000|1789295304000|false",
            "RESTORE|W25101399|W25101399|1787912904001|1789295304000|true",
            "RESTORE|CFD8EBDDF969|CFD8EBDDF969|1000|2000|false",
            "RESTORE|W25101399|W25101398|1000|2000|false",
            "RESTORE|W25101399|w25101399|1000|2000|true",
            "RESTORE|S/N:W25101399|w25101399|1000|2000|true",
            "RESTORE|||1000|2000|false",
            "RESTORE|W25101399|W25101399|1789295304000|1789295304000|true"
        ]

        static let history: [String] = [
            "HIST|recovered|189|189|false|true|1789339358299|1789373378299|249|438|4281999A",
            "HIST|deferred|189|0|true|false|nil|nil|nil|nil|nil",
            "HIST|valid|189|189|false|false|1789339351000|1789373371000|249|438|4281999A",
            "HIST|skewed|189|0|false|false|nil|nil|nil|nil|nil",
            "HIST|newerCycle|190|0|false|false|nil|nil|nil|nil|nil",
            "HIST|packetZero|190|0|false|false|nil|nil|nil|nil|nil",
            "HIST|onePoint|1|0|false|false|nil|nil|nil|nil|nil",
            "HIST|samePacketTwice|2|0|false|false|nil|nil|nil|nil|nil",
            "HIST|anchorNoTime|189|0|false|false|nil|nil|nil|nil|nil",
            "HIST|anchorTerminal|189|0|false|false|nil|nil|nil|nil|nil",
            "HIST|noInterval|189|0|false|false|nil|nil|nil|nil|nil",
            "HIST|anchorInFuture|189|0|false|false|nil|nil|nil|nil|nil",
            "HIST|empty|0|0|false|false|nil|nil|nil|nil|nil",
            "HIST|emptyNoAnchor|0|0|false|false|nil|nil|nil|nil|nil",
            "HIST|shiftExactlyTwo|5|5|false|false|1789339718299|1789340618299|249|254|4281999A",
            "HIST|shiftTwoPlus|5|5|false|false|1789339718300|1789340618300|249|254|4281999A",
            "HIST|futureOnlyBySixtySeconds|5|5|false|false|1789374338299|1789374338299|249|254|4281999A"
        ]

        static let scenarios0: [String] = [
            "CFG|seed|1|720|3F800000|41EA6666|1790000000000|3",
            "BURST|seed|1790000181000|1:0:50:64",
            "STATE|seed|afterBurst|-1|1|1790000181000|0000000000000000|50|0|0|1|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790000362000|2:0:50:64",
            "STATE|seed|afterBurst|-1|2|1790000362000|0000000000000000|50|0|0|2|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790000543000|3:0:50:64",
            "STATE|seed|afterBurst|-1|3|1790000543000|0000000000000000|50|0|0|3|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790000724000|4:12:50:64",
            "STATE|seed|afterBurst|-1|4|1790000724000|4028000000000000|50|0|0|4|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790000900000|5:40:50:64",
            "STATE|seed|afterBurst|-1|5|1790000900000|4044000000000000|50|0|0|5|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790001081000|6:66:50:64",
            "STATE|seed|afterBurst|-1|6|1790001081000|4050800000000000|50|0|0|6|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790001262000|7:90:50:64",
            "STATE|seed|afterBurst|-1|7|1790001262000|4056800000000000|50|0|0|7|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790001443000|8:110:50:64",
            "STATE|seed|afterBurst|-1|8|1790001443000|405B800000000000|50|0|0|8|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790001624000|9:128:50:64",
            "STATE|seed|afterBurst|-1|9|1790001624000|4060000000000000|50|0|0|9|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790001800000|10:140:50:64",
            "STATE|seed|afterBurst|-1|10|1790001800000|4061800000000000|50|0|0|10|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790001981000|11:150:50:64",
            "STATE|seed|afterBurst|-1|11|1790001981000|4062C00000000000|50|0|0|11|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790002162000|12:158:50:64",
            "STATE|seed|afterBurst|-1|12|1790002162000|4063C00000000000|50|0|0|12|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790002343000|13:164:50:64",
            "STATE|seed|afterBurst|-1|13|1790002343000|4064800000000000|50|0|0|13|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790002524000|14:168:50:64",
            "STATE|seed|afterBurst|-1|14|1790002524000|4065000000000000|50|0|0|14|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790002700000|15:171:50:64",
            "STATE|seed|afterBurst|-1|15|1790002700000|4065600000000000|50|0|0|15|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790002881000|16:173:50:64",
            "STATE|seed|afterBurst|-1|16|1790002881000|4065A00000000000|50|0|0|16|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790003062000|17:174:50:64",
            "STATE|seed|afterBurst|-1|17|1790003062000|4065C00000000000|50|0|0|17|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790003243000|18:175:50:64",
            "STATE|seed|afterBurst|-1|18|1790003243000|4065E00000000000|50|0|0|18|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|seed|1790003424000|19:175:50:64",
            "OUT|seed|burst|19|1790003424000|59|1063|42D49D61|403D51EB851EB852|4000000000000000|4065A00000000000|404D800000000000|4065E00000000000|0000000000000000",
            "STATE|seed|afterBurst|19|19|1790003424000|4065E00000000000|50|1790003424000|1063|19|41EA8F5C|40000000|4065A00000000000|0000000000000000",
            "BURST|seed|1790003600000|20:176:50:64",
            "OUT|seed|burst|20|1790003600000|59|1063|42D49D61|403D51EB851EB852|4000000000000000|4065C00000000000|0000000000000000|4066000000000000|4065A00000000000",
            "STATE|seed|afterBurst|20|20|1790003600000|4066000000000000|50|1790003600000|1063|20|41EA8F5C|40000000|4065C00000000000|0000000000000000",
            "BURST|seed|1790003781000|21:176:50:64",
            "OUT|seed|burst|21|1790003781000|59|1063|42D49D61|403D51EB851EB852|4000000000000000|4065C00000000000|0000000000000000|4066000000000000|4065C00000000000",
            "STATE|seed|afterBurst|21|21|1790003781000|4066000000000000|50|1790003781000|1063|21|41EA8F5C|40000000|4065C00000000000|0000000000000000",
            "BURST|seed|1790003962000|22:178:50:64",
            "OUT|seed|burst|22|1790003962000|60|1081|42D837E9|403D51EB851EB852|4000000000000000|4066000000000000|0000000000000000|4066400000000000|4065C00000000000",
            "STATE|seed|afterBurst|22|22|1790003962000|4066400000000000|50|1790003962000|1081|22|41EA8F5C|40000000|4066000000000000|0000000000000000",
            "BURST|seed|1790004143000|23:177:50:64",
            "OUT|seed|burst|23|1790004143000|60|1081|42D837E9|403D51EB851EB852|4000000000000000|4065E00000000000|0000000000000000|4066200000000000|4066000000000000",
            "STATE|seed|afterBurst|23|23|1790004143000|4066200000000000|50|1790004143000|1081|23|41EA8F5C|40000000|4065E00000000000|0000000000000000",
            "BURST|seed|1790004324000|24:175:50:64",
            "OUT|seed|burst|24|1790004324000|59|1063|42D49D61|403D51EB851EB852|4000000000000000|4065A00000000000|0000000000000000|4065E00000000000|4065E00000000000",
            "STATE|seed|afterBurst|24|24|1790004324000|4065E00000000000|50|1790004324000|1063|24|41EA8F5C|40000000|4065A00000000000|0000000000000000",
            "BURST|seed|1790004500000|25:173:50:64",
            "OUT|seed|burst|25|1790004500000|58|1045|42D102D9|403D51EB851EB852|4000000000000000|4065600000000000|0000000000000000|4065A00000000000|4065A00000000000",
            "STATE|seed|afterBurst|25|25|1790004500000|4065A00000000000|50|1790004500000|1045|25|41EA8F5C|40000000|4065600000000000|0000000000000000",
            "BURST|seed|1790004681000|26:171:50:64",
            "OUT|seed|burst|26|1790004681000|58|1045|42D102D9|403D51EB851EB852|4000000000000000|4065200000000000|0000000000000000|4065600000000000|4065600000000000",
            "STATE|seed|afterBurst|26|26|1790004681000|4065600000000000|50|1790004681000|1045|26|41EA8F5C|40000000|4065200000000000|0000000000000000",
            "BURST|seed|1790004862000|27:170:50:64",
            "OUT|seed|burst|27|1790004862000|57|1027|42CD6851|403D51EB851EB852|4000000000000000|4065000000000000|0000000000000000|4065400000000000|4065200000000000",
            "STATE|seed|afterBurst|27|27|1790004862000|4065400000000000|50|1790004862000|1027|27|41EA8F5C|40000000|4065000000000000|0000000000000000",
            "BURST|seed|1790005043000|28:169:50:64",
            "OUT|seed|burst|28|1790005043000|57|1027|42CD6851|403D51EB851EB852|4000000000000000|4064E00000000000|0000000000000000|4065200000000000|4065000000000000",
            "STATE|seed|afterBurst|28|28|1790005043000|4065200000000000|50|1790005043000|1027|28|41EA8F5C|40000000|4064E00000000000|0000000000000000",
            "BURST|seed|1790005224000|29:168:50:64",
            "OUT|seed|burst|29|1790005224000|57|1027|42CD6851|403D51EB851EB852|4000000000000000|4064C00000000000|0000000000000000|4065000000000000|4064E00000000000",
            "STATE|seed|afterBurst|29|29|1790005224000|4065000000000000|50|1790005224000|1027|29|41EA8F5C|40000000|4064C00000000000|0000000000000000",
            "BURST|seed|1790005400000|30:167:50:64",
            "OUT|seed|burst|30|1790005400000|56|1009|42C9CDC8|403D51EB851EB852|4000000000000000|4064A00000000000|0000000000000000|4064E00000000000|4064C00000000000",
            "STATE|seed|afterBurst|30|30|1790005400000|4064E00000000000|50|1790005400000|1009|30|41EA8F5C|40000000|4064A00000000000|0000000000000000",
            "BURST|seed|1790005581000|31:166:50:64",
            "OUT|seed|burst|31|1790005581000|56|1009|42C9CDC8|403D51EB851EB852|4000000000000000|4064800000000000|0000000000000000|4064C00000000000|4064A00000000000",
            "STATE|seed|afterBurst|31|31|1790005581000|4064C00000000000|50|1790005581000|1009|31|41EA8F5C|40000000|4064800000000000|0000000000000000",
            "BURST|seed|1790005762000|32:330:50:64",
            "OUT|seed|burst|32|1790005762000|59|1063|42D49D61|403D51EB851EB852|4000000000000000|4065A00000000000|0000000000000000|4074A00000000000|4064800000000000",
            "STATE|seed|afterBurst|32|32|1790005762000|4074A00000000000|50|1790005762000|1063|32|41EA8F5C|40000000|4065A00000000000|0000000000000000",
            "BURST|seed|1790005943000|33:165:50:64",
            "OUT|seed|burst|33|1790005943000|56|1009|42C9CDC8|403D51EB851EB852|4000000000000000|4064800000000000|0000000000000000|4064A00000000000|4065A00000000000",
            "STATE|seed|afterBurst|33|33|1790005943000|4064A00000000000|50|1790005943000|1009|33|41EA8F5C|40000000|4064800000000000|0000000000000000",
            "BURST|seed|1790006124000|34:164:50:64",
            "OUT|seed|burst|34|1790006124000|55|991|42C63340|403D51EB851EB852|4000000000000000|4064400000000000|0000000000000000|4064800000000000|4064800000000000",
            "STATE|seed|afterBurst|34|34|1790006124000|4064800000000000|50|1790006124000|991|34|41EA8F5C|40000000|4064400000000000|0000000000000000",
            "BURST|seed|1790006300000|35:163:50:64",
            "OUT|seed|burst|35|1790006300000|55|991|42C63340|403D51EB851EB852|4000000000000000|4064200000000000|0000000000000000|4064600000000000|4064400000000000",
            "STATE|seed|afterBurst|35|35|1790006300000|4064600000000000|50|1790006300000|991|35|41EA8F5C|40000000|4064200000000000|0000000000000000",
            "BURST|seed|1790006481000|36:162:50:64",
            "OUT|seed|burst|36|1790006481000|55|991|42C63340|403D51EB851EB852|4000000000000000|4064000000000000|0000000000000000|4064400000000000|4064200000000000",
            "STATE|seed|afterBurst|36|36|1790006481000|4064400000000000|50|1790006481000|991|36|41EA8F5C|40000000|4064000000000000|0000000000000000",
            "BURST|seed|1790006662000|37:4:50:64",
            "OUT|seed|burst|37|1790006662000|55|991|42C63340|403D51EB851EB852|4000000000000000|4064000000000000|0000000000000000|4010000000000000|4064000000000000",
            "STATE|seed|afterBurst|37|37|1790006662000|4010000000000000|50|1790006662000|991|37|41EA8F5C|40000000|4064000000000000|0000000000000000",
            "BURST|seed|1790006843000|38:161:50:64",
            "OUT|seed|burst|38|1790006843000|54|973|42C298B8|403D51EB851EB852|4000000000000000|4063E00000000000|0000000000000000|4064200000000000|4064000000000000",
            "STATE|seed|afterBurst|38|38|1790006843000|4064200000000000|50|1790006843000|973|38|41EA8F5C|40000000|4063E00000000000|0000000000000000",
            "BURST|seed|1790007024000|39:160:50:64",
            "OUT|seed|burst|39|1790007024000|54|973|42C298B8|403D51EB851EB852|4000000000000000|4063C00000000000|0000000000000000|4064000000000000|4063E00000000000",
            "STATE|seed|afterBurst|39|39|1790007024000|4064000000000000|50|1790007024000|973|39|41EA8F5C|40000000|4063C00000000000|0000000000000000"
        ]

        static let scenarios1: [String] = [
            "BURST|seed|1790007200000|40:159:50:64",
            "OUT|seed|burst|40|1790007200000|54|973|42C298B8|403D51EB851EB852|4000000000000000|4063A00000000000|0000000000000000|4063E00000000000|4063C00000000000",
            "STATE|seed|afterBurst|40|40|1790007200000|4063E00000000000|50|1790007200000|973|40|41EA8F5C|40000000|4063A00000000000|0000000000000000",
            "BURST|seed|1790007381000|41:158:50:64",
            "OUT|seed|burst|41|1790007381000|53|955|42BEFE30|403D51EB851EB852|4000000000000000|4063800000000000|0000000000000000|4063C00000000000|4063A00000000000",
            "STATE|seed|afterBurst|41|41|1790007381000|4063C00000000000|50|1790007381000|955|41|41EA8F5C|40000000|4063800000000000|0000000000000000",
            "BURST|seed|1790007562000|42:157:50:64",
            "OUT|seed|burst|42|1790007562000|53|955|42BEFE30|403D51EB851EB852|4000000000000000|4063600000000000|0000000000000000|4063A00000000000|4063800000000000",
            "STATE|seed|afterBurst|42|42|1790007562000|4063A00000000000|50|1790007562000|955|42|41EA8F5C|40000000|4063600000000000|0000000000000000",
            "BURST|seed|1790007743000|43:156:50:64",
            "OUT|seed|burst|43|1790007743000|53|955|42BEFE30|403D51EB851EB852|4000000000000000|4063400000000000|0000000000000000|4063800000000000|4063600000000000",
            "STATE|seed|afterBurst|43|43|1790007743000|4063800000000000|50|1790007743000|955|43|41EA8F5C|40000000|4063400000000000|0000000000000000",
            "BURST|seed|1790007924000|44:155:50:64",
            "OUT|seed|burst|44|1790007924000|52|937|42BB63A8|403D51EB851EB852|4000000000000000|4063200000000000|0000000000000000|4063600000000000|4063400000000000",
            "STATE|seed|afterBurst|44|44|1790007924000|4063600000000000|50|1790007924000|937|44|41EA8F5C|40000000|4063200000000000|0000000000000000",
            "BURST|seed|1790008100000|45:154:50:64",
            "OUT|seed|burst|45|1790008100000|52|937|42BB63A8|403D51EB851EB852|4000000000000000|4063000000000000|0000000000000000|4063400000000000|4063200000000000",
            "STATE|seed|afterBurst|45|45|1790008100000|4063400000000000|50|1790008100000|937|45|41EA8F5C|40000000|4063000000000000|0000000000000000",
            "BURST|seed|1790008281000|46:153:50:64",
            "OUT|seed|burst|46|1790008281000|52|937|42BB63A8|403D51EB851EB852|4000000000000000|4062E00000000000|0000000000000000|4063200000000000|4063000000000000",
            "STATE|seed|afterBurst|46|46|1790008281000|4063200000000000|50|1790008281000|937|46|41EA8F5C|40000000|4062E00000000000|0000000000000000",
            "BURST|seed|1790008462000|47:152:50:64",
            "OUT|seed|burst|47|1790008462000|51|919|42B7C920|403D51EB851EB852|4000000000000000|4062C00000000000|0000000000000000|4063000000000000|4062E00000000000",
            "STATE|seed|afterBurst|47|47|1790008462000|4063000000000000|50|1790008462000|919|47|41EA8F5C|40000000|4062C00000000000|0000000000000000",
            "BURST|seed|1790008643000|48:150:50:64",
            "OUT|seed|burst|48|1790008643000|50|901|42B42E98|403D51EB851EB852|4000000000000000|4062800000000000|0000000000000000|4062C00000000000|4062C00000000000",
            "STATE|seed|afterBurst|48|48|1790008643000|4062C00000000000|50|1790008643000|901|48|41EA8F5C|40000000|4062800000000000|0000000000000000",
            "CFG|replay|1|720|3F800000|41EA6666|1790000000000|3",
            "BURST|replay|1790000180000|1:103:50:64",
            "STATE|replay|afterBurst|-1|1|1790000180000|4059C00000000000|50|0|0|1|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790000360000|2:106:50:64",
            "STATE|replay|afterBurst|-1|2|1790000360000|405A800000000000|50|0|0|2|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790000540000|3:109:50:64",
            "STATE|replay|afterBurst|-1|3|1790000540000|405B400000000000|50|0|0|3|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790000720000|4:112:50:64",
            "STATE|replay|afterBurst|-1|4|1790000720000|405C000000000000|50|0|0|4|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790000900000|5:115:50:64",
            "STATE|replay|afterBurst|-1|5|1790000900000|405CC00000000000|50|0|0|5|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790001080000|6:118:50:64",
            "STATE|replay|afterBurst|-1|6|1790001080000|405D800000000000|50|0|0|6|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790001260000|7:121:50:64",
            "STATE|replay|afterBurst|-1|7|1790001260000|405E400000000000|50|0|0|7|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790001440000|8:124:50:64",
            "STATE|replay|afterBurst|-1|8|1790001440000|405F000000000000|50|0|0|8|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790001620000|9:127:50:64",
            "STATE|replay|afterBurst|-1|9|1790001620000|405FC00000000000|50|0|0|9|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790001800000|10:130:50:64",
            "STATE|replay|afterBurst|-1|10|1790001800000|4060400000000000|50|0|0|10|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790001980000|11:133:50:64",
            "STATE|replay|afterBurst|-1|11|1790001980000|4060A00000000000|50|0|0|11|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790002160000|12:136:50:64",
            "STATE|replay|afterBurst|-1|12|1790002160000|4061000000000000|50|0|0|12|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790002340000|13:139:50:64",
            "STATE|replay|afterBurst|-1|13|1790002340000|4061600000000000|50|0|0|13|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790002520000|14:142:50:64",
            "STATE|replay|afterBurst|-1|14|1790002520000|4061C00000000000|50|0|0|14|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790002700000|15:145:50:64",
            "STATE|replay|afterBurst|-1|15|1790002700000|4062200000000000|50|0|0|15|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790002880000|16:148:50:64",
            "STATE|replay|afterBurst|-1|16|1790002880000|4062800000000000|50|0|0|16|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790003060000|17:151:50:64",
            "STATE|replay|afterBurst|-1|17|1790003060000|4062E00000000000|50|0|0|17|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790003240000|18:154:50:64",
            "STATE|replay|afterBurst|-1|18|1790003240000|4063400000000000|50|0|0|18|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|replay|1790003420000|19:157:50:64",
            "OUT|replay|burst|19|1790003420000|53|955|42BEFE30|403D3D70A3D70A3D|4000000000000000|4063600000000000|404A800000000000|4063A00000000000|0000000000000000",
            "STATE|replay|afterBurst|19|19|1790003420000|4063A00000000000|50|1790003420000|955|19|41E9EB85|40000000|4063600000000000|0000000000000000",
            "BURST|replay|1790003600000|20:160:50:64",
            "OUT|replay|burst|20|1790003600000|54|973|42C298B8|403D3D70A3D70A3D|4000000000000000|4063C00000000000|0000000000000000|4064000000000000|4063600000000000",
            "STATE|replay|afterBurst|20|20|1790003600000|4064000000000000|50|1790003600000|973|20|41E9EB85|40000000|4063C00000000000|0000000000000000",
            "BURST|replay|1790003780000|21:163:50:64",
            "OUT|replay|burst|21|1790003780000|55|991|42C63340|403D3D70A3D70A3D|4000000000000000|4064200000000000|0000000000000000|4064600000000000|4063C00000000000",
            "STATE|replay|afterBurst|21|21|1790003780000|4064600000000000|50|1790003780000|991|21|41E9EB85|40000000|4064200000000000|0000000000000000",
            "BURST|replay|1790003960000|22:166:50:64",
            "OUT|replay|burst|22|1790003960000|56|1009|42C9CDC8|403D3D70A3D70A3D|4000000000000000|4064800000000000|0000000000000000|4064C00000000000|4064200000000000",
            "STATE|replay|afterBurst|22|22|1790003960000|4064C00000000000|50|1790003960000|1009|22|41E9EB85|40000000|4064800000000000|0000000000000000",
            "BURST|replay|1790004140000|23:169:50:64",
            "OUT|replay|burst|23|1790004140000|57|1027|42CD6851|403D3D70A3D70A3D|4000000000000000|4064E00000000000|0000000000000000|4065200000000000|4064800000000000",
            "STATE|replay|afterBurst|23|23|1790004140000|4065200000000000|50|1790004140000|1027|23|41E9EB85|40000000|4064E00000000000|0000000000000000",
            "BURST|replay|1790004320000|24:172:50:64",
            "OUT|replay|burst|24|1790004320000|58|1045|42D102D9|403D3D70A3D70A3D|4000000000000000|4065400000000000|0000000000000000|4065800000000000|4064E00000000000",
            "STATE|replay|afterBurst|24|24|1790004320000|4065800000000000|50|1790004320000|1045|24|41E9EB85|40000000|4065400000000000|0000000000000000",
            "BURST|replay|1790005582000|23:169:50:64;24:175:50:64;25:178:50:64;26:181:50:64;27:184:50:64;28:187:50:64;29:190:50:64;30:193:50:64;31:196:50:64",
            "OUT|replay|burst|25|1790004502000|60|1081|42D837E9|403D3D70A3D70A3D|4000000000000000|4066000000000000|0000000000000000|4066400000000000|4065400000000000",
            "OUT|replay|burst|26|1790004682000|61|1099|42DBD271|403D3D70A3D70A3D|4000000000000000|4066600000000000|0000000000000000|4066A00000000000|4066000000000000",
            "OUT|replay|burst|27|1790004862000|62|1117|42DF6CF9|403D3D70A3D70A3D|4000000000000000|4066C00000000000|0000000000000000|4067000000000000|4066600000000000",
            "OUT|replay|burst|28|1790005042000|63|1135|42E30782|403D3D70A3D70A3D|4000000000000000|4067200000000000|0000000000000000|4067600000000000|4066C00000000000",
            "OUT|replay|burst|29|1790005222000|64|1153|42E6A20A|403D3D70A3D70A3D|4000000000000000|4067800000000000|0000000000000000|4067C00000000000|4067200000000000",
            "OUT|replay|burst|30|1790005402000|65|1171|42EA3C92|403D3D70A3D70A3D|4000000000000000|4067E00000000000|0000000000000000|4068200000000000|4067800000000000",
            "OUT|replay|burst|31|1790005582000|66|1189|42EDD71A|403D3D70A3D70A3D|4000000000000000|4068400000000000|0000000000000000|4068800000000000|4067E00000000000",
            "STATE|replay|afterBurst|31|31|1790005582000|4068800000000000|50|1790005582000|1189|31|41E9EB85|40000000|4068400000000000|0000000000000000",
            "BURST|replay|1790005760000|32:199:50:65",
            "STATE|replay|afterBurst|31|32|1790005760000|4068E00000000000|50|1790005582000|1189|32|41E9EB85|40000000|4068400000000000|0000000000000000",
            "BURST|replay|1790005940000|33:207:50:64",
            "OUT|replay|burst|33|1790005940000|70|1261|42FC413B|403D3D70A3D70A3D|4000000000000000|4069800000000000|0000000000000000|4069E00000000000|4068400000000000",
            "STATE|replay|afterBurst|33|33|1790005940000|4069E00000000000|50|1790005940000|1261|33|41E9EB85|40000000|4069800000000000|0000000000000000",
            "BURST|replay|1790005945000|33:205:50:64",
            "STATE|replay|afterBurst|33|33|1790005940000|4069E00000000000|50|1790005940000|1261|33|41E9EB85|40000000|4069800000000000|0000000000000000",
            "CFG|reference|0|720|3F8CCCCD|00000000|1790000000000|3",
            "BURST|reference|1790000180000|1:0:50:64"
        ]

        static let scenarios2: [String] = [
            "STATE|reference|afterBurst|-1|1|1790000180000|0000000000000000|50|0|0|1|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790000360000|2:3:50:64",
            "STATE|reference|afterBurst|-1|2|1790000360000|4008000000000000|50|0|0|2|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790000540000|3:9:50:64",
            "STATE|reference|afterBurst|-1|3|1790000540000|4022000000000000|50|0|0|3|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790000720000|4:25:50:64",
            "STATE|reference|afterBurst|-1|4|1790000720000|4039000000000000|50|0|0|4|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790000900000|5:48:50:64",
            "STATE|reference|afterBurst|-1|5|1790000900000|4048000000000000|50|0|0|5|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790001080000|6:70:50:64",
            "STATE|reference|afterBurst|-1|6|1790001080000|4051800000000000|50|0|0|6|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790001260000|7:88:50:64",
            "STATE|reference|afterBurst|-1|7|1790001260000|4056000000000000|50|0|0|7|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790001440000|8:103:50:64",
            "STATE|reference|afterBurst|-1|8|1790001440000|4059C00000000000|50|0|0|8|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790001620000|9:115:50:64",
            "STATE|reference|afterBurst|-1|9|1790001620000|405CC00000000000|50|0|0|9|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|reference|1790001800000|10:126:50:64",
            "STATE|reference|afterBurst|-1|10|1790001800000|405F800000000000|50|0|0|10|00000000|00000000|0000000000000000|0000000000000000",
            "CALIBRATE|reference|108|1790001820000",
            "CAL|reference|108|applied|0000000000000000",
            "OUT|reference|calibration|10|1790001800000|60|1081|42D837E9|402EE66666666666|4000000000000000|4057400000000000|404D800000000000|405F800000000000|0000000000000000",
            "STATE|reference|afterCalibration|10|10|1790001800000|405F800000000000|50|1790001800000|1081|10|41773333|40000000|4057400000000000|0000000000000000",
            "BURST|reference|1790001980000|11:134:50:64",
            "OUT|reference|burst|11|1790001980000|64|1153|42E6A20A|402EE66666666666|4000000000000000|4058800000000000|0000000000000000|4060C00000000000|4057400000000000",
            "STATE|reference|afterBurst|11|11|1790001980000|4060C00000000000|50|1790001980000|1153|11|41773333|40000000|4058800000000000|0000000000000000",
            "BURST|reference|1790002160000|12:140:50:64",
            "OUT|reference|burst|12|1790002160000|67|1207|42F171A2|402EE66666666666|4000000000000000|4059C00000000000|0000000000000000|4061800000000000|4058800000000000",
            "STATE|reference|afterBurst|12|12|1790002160000|4061800000000000|50|1790002160000|1207|12|41773333|40000000|4059C00000000000|0000000000000000",
            "BURST|reference|1790002340000|13:145:50:64",
            "OUT|reference|burst|13|1790002340000|69|1243|42F8A6B2|402EE66666666666|4000000000000000|405AC00000000000|0000000000000000|4062200000000000|4059C00000000000",
            "STATE|reference|afterBurst|13|13|1790002340000|4062200000000000|50|1790002340000|1243|13|41773333|40000000|405AC00000000000|0000000000000000",
            "BURST|reference|1790002520000|14:149:50:64",
            "OUT|reference|burst|14|1790002520000|72|1297|4301BB25|402EE66666666666|4000000000000000|405BC00000000000|0000000000000000|4062A00000000000|405AC00000000000",
            "STATE|reference|afterBurst|14|14|1790002520000|4062A00000000000|50|1790002520000|1297|14|41773333|40000000|405BC00000000000|0000000000000000",
            "BURST|reference|1790002700000|15:152:50:64",
            "OUT|reference|burst|15|1790002700000|73|1315|4303886A|402EE66666666666|4000000000000000|405C400000000000|0000000000000000|4063000000000000|405BC00000000000",
            "STATE|reference|afterBurst|15|15|1790002700000|4063000000000000|50|1790002700000|1315|15|41773333|40000000|405C400000000000|0000000000000000",
            "BURST|reference|1790002880000|16:154:50:64",
            "OUT|reference|burst|16|1790002880000|74|1333|430555AE|402EE66666666666|4000000000000000|405CC00000000000|0000000000000000|4063400000000000|405C400000000000",
            "STATE|reference|afterBurst|16|16|1790002880000|4063400000000000|50|1790002880000|1333|16|41773333|40000000|405CC00000000000|0000000000000000",
            "BURST|reference|1790003060000|17:156:50:64",
            "OUT|reference|burst|17|1790003060000|75|1351|430722F2|402EE66666666666|4000000000000000|405D000000000000|0000000000000000|4063800000000000|405CC00000000000",
            "STATE|reference|afterBurst|17|17|1790003060000|4063800000000000|50|1790003060000|1351|17|41773333|40000000|405D000000000000|0000000000000000",
            "BURST|reference|1790003240000|18:157:50:64",
            "OUT|reference|burst|18|1790003240000|76|1369|4308F036|402EE66666666666|4000000000000000|405D400000000000|0000000000000000|4063A00000000000|405D000000000000",
            "STATE|reference|afterBurst|18|18|1790003240000|4063A00000000000|50|1790003240000|1369|18|41773333|40000000|405D400000000000|0000000000000000",
            "BURST|reference|1790003420000|19:158:50:64",
            "OUT|reference|burst|19|1790003420000|76|1369|4308F036|402EE66666666666|4000000000000000|405D800000000000|0000000000000000|4063C00000000000|405D400000000000",
            "STATE|reference|afterBurst|19|19|1790003420000|4063C00000000000|50|1790003420000|1369|19|41773333|40000000|405D800000000000|0000000000000000",
            "BURST|reference|1790003600000|20:159:50:64",
            "OUT|reference|burst|20|1790003600000|77|1387|430ABD7A|402EE66666666666|4000000000000000|405DC00000000000|0000000000000000|4063E00000000000|405D800000000000",
            "STATE|reference|afterBurst|20|20|1790003600000|4063E00000000000|50|1790003600000|1387|20|41773333|40000000|405DC00000000000|0000000000000000",
            "BURST|reference|1790003780000|21:160:50:64",
            "OUT|reference|burst|21|1790003780000|78|1405|430C8ABE|402EE66666666666|4000000000000000|405E000000000000|0000000000000000|4064000000000000|405DC00000000000",
            "STATE|reference|afterBurst|21|21|1790003780000|4064000000000000|50|1790003780000|1405|21|41773333|40000000|405E000000000000|0000000000000000",
            "BURST|reference|1790003960000|22:161:50:64",
            "OUT|reference|burst|22|1790003960000|78|1405|430C8ABE|402EE66666666666|4000000000000000|405E400000000000|0000000000000000|4064200000000000|405E000000000000",
            "STATE|reference|afterBurst|22|22|1790003960000|4064200000000000|50|1790003960000|1405|22|41773333|40000000|405E400000000000|0000000000000000",
            "BURST|reference|1790004140000|23:161:50:64",
            "OUT|reference|burst|23|1790004140000|78|1405|430C8ABE|402EE66666666666|4000000000000000|405E400000000000|0000000000000000|4064200000000000|405E400000000000",
            "STATE|reference|afterBurst|23|23|1790004140000|4064200000000000|50|1790004140000|1405|23|41773333|40000000|405E400000000000|0000000000000000",
            "BURST|reference|1790004320000|24:162:50:64",
            "OUT|reference|burst|24|1790004320000|79|1423|430E5802|402EE66666666666|4000000000000000|405E800000000000|0000000000000000|4064400000000000|405E400000000000",
            "STATE|reference|afterBurst|24|24|1790004320000|4064400000000000|50|1790004320000|1423|24|41773333|40000000|405E800000000000|0000000000000000",
            "BURST|reference|1790004500000|25:162:50:64",
            "OUT|reference|burst|25|1790004500000|79|1423|430E5802|402EE66666666666|4000000000000000|405E800000000000|0000000000000000|4064400000000000|405E800000000000",
            "STATE|reference|afterBurst|25|25|1790004500000|4064400000000000|50|1790004500000|1423|25|41773333|40000000|405E800000000000|0000000000000000",
            "BURST|reference|1790004680000|26:163:50:64",
            "OUT|reference|burst|26|1790004680000|80|1441|43102546|402EE66666666666|4000000000000000|405EC00000000000|0000000000000000|4064600000000000|405E800000000000",
            "STATE|reference|afterBurst|26|26|1790004680000|4064600000000000|50|1790004680000|1441|26|41773333|40000000|405EC00000000000|0000000000000000",
            "BURST|reference|1790004860000|27:163:50:64",
            "OUT|reference|burst|27|1790004860000|80|1441|43102546|402EE66666666666|4000000000000000|405EC00000000000|0000000000000000|4064600000000000|405EC00000000000",
            "STATE|reference|afterBurst|27|27|1790004860000|4064600000000000|50|1790004860000|1441|27|41773333|40000000|405EC00000000000|0000000000000000",
            "BURST|reference|1790005040000|28:164:50:64",
            "OUT|reference|burst|28|1790005040000|80|1441|43102546|402EE66666666666|4000000000000000|405F000000000000|0000000000000000|4064800000000000|405EC00000000000",
            "STATE|reference|afterBurst|28|28|1790005040000|4064800000000000|50|1790005040000|1441|28|41773333|40000000|405F000000000000|0000000000000000",
            "BURST|reference|1790005220000|29:164:50:64",
            "OUT|reference|burst|29|1790005220000|81|1459|4311F28A|402EE66666666666|4000000000000000|405F000000000000|0000000000000000|4064800000000000|405F000000000000",
            "STATE|reference|afterBurst|29|29|1790005220000|4064800000000000|50|1790005220000|1459|29|41773333|40000000|405F000000000000|0000000000000000",
            "BURST|reference|1790005400000|30:165:50:64",
            "OUT|reference|burst|30|1790005400000|81|1459|4311F28A|402EE66666666666|4000000000000000|405F400000000000|0000000000000000|4064A00000000000|405F000000000000",
            "STATE|reference|afterBurst|30|30|1790005400000|4064A00000000000|50|1790005400000|1459|30|41773333|40000000|405F400000000000|0000000000000000",
            "CALIBRATE|reference|130|1790005420000",
            "CAL|reference|130|applied|0000000000000000",
            "OUT|reference|calibration|30|1790005400000|72|1297|4301BB25|40315EB851EB851F|4000000000000000|405F400000000000|4052000000000000|4064A00000000000|405F400000000000",
            "STATE|reference|afterCalibration|30|30|1790005400000|4064A00000000000|50|1790005400000|1297|30|418AF5C3|40000000|405F400000000000|0000000000000000",
            "BURST|reference|1790005580000|31:150:50:64",
            "OUT|reference|burst|31|1790005580000|68|1225|42F50C2A|40315EB851EB851F|4000000000000000|405D800000000000|0000000000000000|4062C00000000000|405F400000000000",
            "STATE|reference|afterBurst|31|31|1790005580000|4062C00000000000|50|1790005580000|1225|31|418AF5C3|40000000|405D800000000000|0000000000000000",
            "BURST|reference|1790005760000|32:148:50:64",
            "OUT|reference|burst|32|1790005760000|65|1171|42EA3C92|40315EB851EB851F|4000000000000000|405C400000000000|0000000000000000|4062800000000000|405D800000000000",
            "STATE|reference|afterBurst|32|32|1790005760000|4062800000000000|50|1790005760000|1171|32|418AF5C3|40000000|405C400000000000|0000000000000000",
            "BURST|reference|1790005940000|33:152:50:64",
            "OUT|reference|burst|33|1790005940000|67|1207|42F171A2|40315EB851EB851F|4000000000000000|405D000000000000|0000000000000000|4063000000000000|405C400000000000",
            "STATE|reference|afterBurst|33|33|1790005940000|4063000000000000|50|1790005940000|1207|33|418AF5C3|40000000|405D000000000000|0000000000000000",
            "BURST|reference|1790006120000|34:156:50:64",
            "OUT|reference|burst|34|1790006120000|69|1243|42F8A6B2|40315EB851EB851F|4000000000000000|405DC00000000000|0000000000000000|4063800000000000|405D000000000000",
            "STATE|reference|afterBurst|34|34|1790006120000|4063800000000000|50|1790006120000|1243|34|418AF5C3|40000000|405DC00000000000|0000000000000000",
            "BURST|reference|1790006300000|35:160:50:64"
        ]

        static let scenarios3: [String] = [
            "OUT|reference|burst|35|1790006300000|70|1261|42FC413B|40315EB851EB851F|4000000000000000|405E800000000000|0000000000000000|4064000000000000|405DC00000000000",
            "STATE|reference|afterBurst|35|35|1790006300000|4064000000000000|50|1790006300000|1261|35|418AF5C3|40000000|405E800000000000|0000000000000000",
            "BURST|reference|1790006480000|36:170:50:64",
            "OUT|reference|burst|36|1790006480000|74|1333|430555AE|40315EB851EB851F|4000000000000000|4060200000000000|0000000000000000|4065400000000000|405E800000000000",
            "STATE|reference|afterBurst|36|36|1790006480000|4065400000000000|50|1790006480000|1333|36|418AF5C3|40000000|4060200000000000|0000000000000000",
            "BURST|reference|1790006660000|37:180:50:64",
            "OUT|reference|burst|37|1790006660000|78|1405|430C8ABE|40315EB851EB851F|4000000000000000|4061000000000000|0000000000000000|4066800000000000|4060200000000000",
            "STATE|reference|afterBurst|37|37|1790006660000|4066800000000000|50|1790006660000|1405|37|418AF5C3|40000000|4061000000000000|0000000000000000",
            "BURST|reference|1790006840000|38:190:50:64",
            "OUT|reference|burst|38|1790006840000|83|1496|43158D12|40315EB851EB851F|4000000000000000|4061E00000000000|0000000000000000|4067C00000000000|4061000000000000",
            "STATE|reference|afterBurst|38|38|1790006840000|4067C00000000000|50|1790006840000|1496|38|418AF5C3|40000000|4061E00000000000|0000000000000000",
            "BURST|reference|1790007020000|39:200:50:64",
            "OUT|reference|burst|39|1790007020000|87|1568|431CC223|40315EB851EB851F|4000000000000000|4062E00000000000|0000000000000000|4069000000000000|4061E00000000000",
            "STATE|reference|afterBurst|39|39|1790007020000|4069000000000000|50|1790007020000|1568|39|418AF5C3|40000000|4062E00000000000|0000000000000000",
            "BURST|reference|1790007200000|40:210:50:64",
            "OUT|reference|burst|40|1790007200000|92|1658|4325C477|40315EB851EB851F|4000000000000000|4063E00000000000|0000000000000000|406A400000000000|4062E00000000000",
            "STATE|reference|afterBurst|40|40|1790007200000|406A400000000000|50|1790007200000|1658|40|418AF5C3|40000000|4063E00000000000|0000000000000000",
            "CALIBRATE|reference|0|1790007201000",
            "CAL|reference|0|rejected",
            "CALIBRATE|reference|99|1790011200000",
            "CAL|reference|99|queued|404B78E393652838",
            "STATE|reference|afterStale|40|40|1790007200000|406A400000000000|50|1790007200000|1658|40|418AF5C3|40000000|4063E00000000000|404B78E393652838",
            "CFG|legacy|0|720|3F8CCCCD|41EA6666|1790000000000|3",
            "BURST|legacy|1790000180000|1:2:50:64",
            "STATE|legacy|afterBurst|-1|1|1790000180000|4000000000000000|50|0|0|1|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790000360000|2:4:50:64",
            "STATE|legacy|afterBurst|-1|2|1790000360000|4010000000000000|50|0|0|2|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790000540000|3:6:50:64",
            "STATE|legacy|afterBurst|-1|3|1790000540000|4018000000000000|50|0|0|3|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790000720000|4:8:50:64",
            "STATE|legacy|afterBurst|-1|4|1790000720000|4020000000000000|50|0|0|4|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790000900000|5:10:50:64",
            "STATE|legacy|afterBurst|-1|5|1790000900000|4024000000000000|50|0|0|5|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790001080000|6:12:50:64",
            "STATE|legacy|afterBurst|-1|6|1790001080000|4028000000000000|50|0|0|6|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790001260000|7:14:50:64",
            "STATE|legacy|afterBurst|-1|7|1790001260000|402C000000000000|50|0|0|7|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790001440000|8:152:50:64",
            "STATE|legacy|afterBurst|-1|8|1790001440000|4063000000000000|50|0|0|8|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790001620000|9:154:50:64",
            "STATE|legacy|afterBurst|-1|9|1790001620000|4063400000000000|50|0|0|9|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790001800000|10:156:50:64",
            "STATE|legacy|afterBurst|-1|10|1790001800000|4063800000000000|50|0|0|10|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790001980000|11:158:50:64",
            "STATE|legacy|afterBurst|-1|11|1790001980000|4063C00000000000|50|0|0|11|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790002160000|12:160:50:64",
            "STATE|legacy|afterBurst|-1|12|1790002160000|4064000000000000|50|0|0|12|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790002340000|13:162:50:64",
            "STATE|legacy|afterBurst|-1|13|1790002340000|4064400000000000|50|0|0|13|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790002520000|14:150:50:64",
            "STATE|legacy|afterBurst|-1|14|1790002520000|4062C00000000000|50|0|0|14|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790002700000|15:152:50:64",
            "STATE|legacy|afterBurst|-1|15|1790002700000|4063000000000000|50|0|0|15|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790002880000|16:154:50:64",
            "STATE|legacy|afterBurst|-1|16|1790002880000|4063400000000000|50|0|0|16|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790003060000|17:156:50:64",
            "STATE|legacy|afterBurst|-1|17|1790003060000|4063800000000000|50|0|0|17|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790003240000|18:158:50:64",
            "STATE|legacy|afterBurst|-1|18|1790003240000|4063C00000000000|50|0|0|18|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|legacy|1790003420000|19:160:50:64",
            "OUT|legacy|burst|19|1790003420000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405E000000000000|4044800000000000|4064000000000000|0000000000000000",
            "STATE|legacy|afterBurst|19|19|1790003420000|4064000000000000|50|1790003420000|739|19|41E970A4|40000000|405E000000000000|0000000000000000",
            "BURST|legacy|1790003600000|20:162:50:64",
            "OUT|legacy|burst|20|1790003600000|42|757|42975A56|403D2E147AE147AE|4000000000000000|405E400000000000|0000000000000000|4064400000000000|405E000000000000",
            "STATE|legacy|afterBurst|20|20|1790003600000|4064400000000000|50|1790003600000|757|20|41E970A4|40000000|405E400000000000|0000000000000000",
            "BURST|legacy|1790003780000|21:150:50:64",
            "OUT|legacy|burst|21|1790003780000|39|703|428C8ABE|403D2E147AE147AE|4000000000000000|405C800000000000|0000000000000000|4062C00000000000|405E400000000000",
            "STATE|legacy|afterBurst|21|21|1790003780000|4062C00000000000|50|1790003780000|703|21|41E970A4|40000000|405C800000000000|0000000000000000",
            "BURST|legacy|1790003960000|22:152:50:64",
            "OUT|legacy|burst|22|1790003960000|39|703|428C8ABE|403D2E147AE147AE|4000000000000000|405C800000000000|0000000000000000|4063000000000000|405C800000000000",
            "STATE|legacy|afterBurst|22|22|1790003960000|4063000000000000|50|1790003960000|703|22|41E970A4|40000000|405C800000000000|0000000000000000",
            "BURST|legacy|1790004140000|23:154:50:64",
            "OUT|legacy|burst|23|1790004140000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D000000000000|0000000000000000|4063400000000000|405C800000000000",
            "STATE|legacy|afterBurst|23|23|1790004140000|4063400000000000|50|1790004140000|721|23|41E970A4|40000000|405D000000000000|0000000000000000",
            "BURST|legacy|1790004320000|24:156:50:64",
            "OUT|legacy|burst|24|1790004320000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D400000000000|0000000000000000|4063800000000000|405D000000000000",
            "STATE|legacy|afterBurst|24|24|1790004320000|4063800000000000|50|1790004320000|721|24|41E970A4|40000000|405D400000000000|0000000000000000",
            "BURST|legacy|1790004500000|25:158:50:64",
            "OUT|legacy|burst|25|1790004500000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405DC00000000000|0000000000000000|4063C00000000000|405D400000000000",
            "STATE|legacy|afterBurst|25|25|1790004500000|4063C00000000000|50|1790004500000|739|25|41E970A4|40000000|405DC00000000000|0000000000000000",
            "BURST|legacy|1790004680000|26:160:50:64",
            "OUT|legacy|burst|26|1790004680000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405E400000000000|0000000000000000|4064000000000000|405DC00000000000",
            "STATE|legacy|afterBurst|26|26|1790004680000|4064000000000000|50|1790004680000|739|26|41E970A4|40000000|405E400000000000|0000000000000000",
            "BURST|legacy|1790004860000|27:162:50:64",
            "OUT|legacy|burst|27|1790004860000|42|757|42975A56|403D2E147AE147AE|4000000000000000|405EC00000000000|0000000000000000|4064400000000000|405E400000000000",
            "STATE|legacy|afterBurst|27|27|1790004860000|4064400000000000|50|1790004860000|757|27|41E970A4|40000000|405EC00000000000|0000000000000000",
            "BURST|legacy|1790005040000|28:150:50:64",
            "OUT|legacy|burst|28|1790005040000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D000000000000|0000000000000000|4062C00000000000|405EC00000000000",
            "STATE|legacy|afterBurst|28|28|1790005040000|4062C00000000000|50|1790005040000|721|28|41E970A4|40000000|405D000000000000|0000000000000000",
            "BURST|legacy|1790005220000|29:152:50:64",
            "OUT|legacy|burst|29|1790005220000|39|703|428C8ABE|403D2E147AE147AE|4000000000000000|405CC00000000000|0000000000000000|4063000000000000|405D000000000000",
            "STATE|legacy|afterBurst|29|29|1790005220000|4063000000000000|50|1790005220000|703|29|41E970A4|40000000|405CC00000000000|0000000000000000",
            "BURST|legacy|1790005400000|30:154:50:64",
            "OUT|legacy|burst|30|1790005400000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D400000000000|0000000000000000|4063400000000000|405CC00000000000",
            "STATE|legacy|afterBurst|30|30|1790005400000|4063400000000000|50|1790005400000|721|30|41E970A4|40000000|405D400000000000|0000000000000000",
            "BURST|legacy|1790005580000|31:156:50:64",
            "OUT|legacy|burst|31|1790005580000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405DC00000000000|0000000000000000|4063800000000000|405D400000000000",
            "STATE|legacy|afterBurst|31|31|1790005580000|4063800000000000|50|1790005580000|739|31|41E970A4|40000000|405DC00000000000|0000000000000000",
            "BURST|legacy|1790005760000|32:158:50:64",
            "OUT|legacy|burst|32|1790005760000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405E000000000000|0000000000000000|4063C00000000000|405DC00000000000"
        ]

        static let scenarios4: [String] = [
            "STATE|legacy|afterBurst|32|32|1790005760000|4063C00000000000|50|1790005760000|739|32|41E970A4|40000000|405E000000000000|0000000000000000",
            "BURST|legacy|1790005940000|33:160:50:64",
            "OUT|legacy|burst|33|1790005940000|42|757|42975A56|403D2E147AE147AE|4000000000000000|405E800000000000|0000000000000000|4064000000000000|405E000000000000",
            "STATE|legacy|afterBurst|33|33|1790005940000|4064000000000000|50|1790005940000|757|33|41E970A4|40000000|405E800000000000|0000000000000000",
            "BURST|legacy|1790006120000|34:162:50:64",
            "OUT|legacy|burst|34|1790006120000|42|757|42975A56|403D2E147AE147AE|4000000000000000|405F000000000000|0000000000000000|4064400000000000|405E800000000000",
            "STATE|legacy|afterBurst|34|34|1790006120000|4064400000000000|50|1790006120000|757|34|41E970A4|40000000|405F000000000000|0000000000000000",
            "BURST|legacy|1790006300000|35:150:50:64",
            "OUT|legacy|burst|35|1790006300000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D400000000000|0000000000000000|4062C00000000000|405F000000000000",
            "STATE|legacy|afterBurst|35|35|1790006300000|4062C00000000000|50|1790006300000|721|35|41E970A4|40000000|405D400000000000|0000000000000000",
            "BURST|legacy|1790006480000|36:152:50:64",
            "OUT|legacy|burst|36|1790006480000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D000000000000|0000000000000000|4063000000000000|405D400000000000",
            "STATE|legacy|afterBurst|36|36|1790006480000|4063000000000000|50|1790006480000|721|36|41E970A4|40000000|405D000000000000|0000000000000000",
            "BURST|legacy|1790006660000|37:154:50:64",
            "OUT|legacy|burst|37|1790006660000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D800000000000|0000000000000000|4063400000000000|405D000000000000",
            "STATE|legacy|afterBurst|37|37|1790006660000|4063400000000000|50|1790006660000|721|37|41E970A4|40000000|405D800000000000|0000000000000000",
            "BURST|legacy|1790006840000|38:156:50:64",
            "OUT|legacy|burst|38|1790006840000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405E000000000000|0000000000000000|4063800000000000|405D800000000000",
            "STATE|legacy|afterBurst|38|38|1790006840000|4063800000000000|50|1790006840000|739|38|41E970A4|40000000|405E000000000000|0000000000000000",
            "BURST|legacy|1790007020000|39:158:50:64",
            "OUT|legacy|burst|39|1790007020000|42|757|42975A56|403D2E147AE147AE|4000000000000000|405E400000000000|0000000000000000|4063C00000000000|405E000000000000",
            "STATE|legacy|afterBurst|39|39|1790007020000|4063C00000000000|50|1790007020000|757|39|41E970A4|40000000|405E400000000000|0000000000000000",
            "BURST|legacy|1790007200000|40:160:50:64",
            "OUT|legacy|burst|40|1790007200000|42|757|42975A56|403D2E147AE147AE|4000000000000000|405EC00000000000|0000000000000000|4064000000000000|405E400000000000",
            "STATE|legacy|afterBurst|40|40|1790007200000|4064000000000000|50|1790007200000|757|40|41E970A4|40000000|405EC00000000000|0000000000000000",
            "BURST|legacy|1790007380000|41:162:50:64",
            "OUT|legacy|burst|41|1790007380000|43|775|429AF4DE|403D2E147AE147AE|4000000000000000|405F400000000000|0000000000000000|4064400000000000|405EC00000000000",
            "STATE|legacy|afterBurst|41|41|1790007380000|4064400000000000|50|1790007380000|775|41|41E970A4|40000000|405F400000000000|0000000000000000",
            "BURST|legacy|1790007560000|42:150:50:64",
            "OUT|legacy|burst|42|1790007560000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D800000000000|0000000000000000|4062C00000000000|405F400000000000",
            "STATE|legacy|afterBurst|42|42|1790007560000|4062C00000000000|50|1790007560000|721|42|41E970A4|40000000|405D800000000000|0000000000000000",
            "BURST|legacy|1790007740000|43:152:50:64",
            "OUT|legacy|burst|43|1790007740000|40|721|42902546|403D2E147AE147AE|4000000000000000|405D400000000000|0000000000000000|4063000000000000|405D800000000000",
            "STATE|legacy|afterBurst|43|43|1790007740000|4063000000000000|50|1790007740000|721|43|41E970A4|40000000|405D400000000000|0000000000000000",
            "BURST|legacy|1790007920000|44:154:50:64",
            "OUT|legacy|burst|44|1790007920000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405DC00000000000|0000000000000000|4063400000000000|405D400000000000",
            "STATE|legacy|afterBurst|44|44|1790007920000|4063400000000000|50|1790007920000|739|44|41E970A4|40000000|405DC00000000000|0000000000000000",
            "BURST|legacy|1790008100000|45:156:50:64",
            "OUT|legacy|burst|45|1790008100000|41|739|4293BFCE|403D2E147AE147AE|4000000000000000|405E400000000000|0000000000000000|4063800000000000|405DC00000000000",
            "STATE|legacy|afterBurst|45|45|1790008100000|4063800000000000|50|1790008100000|739|45|41E970A4|40000000|405E400000000000|0000000000000000",
            "CFG|nostart|1|720|3F800000|41EA6666|0|3",
            "BURST|nostart|1790003060000|17:120:50:64",
            "STATE|nostart|afterBurst|-1|17|1790003060000|405E000000000000|50|0|0|1|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|nostart|1790003240000|18:124:50:64",
            "STATE|nostart|afterBurst|-1|18|1790003240000|405F000000000000|50|0|0|2|00000000|00000000|0000000000000000|0000000000000000",
            "BURST|nostart|1790003420000|19:128:50:64",
            "OUT|nostart|burst|19|1790003420000|43|775|429AF4DE|403D4CCCCCCCCCCD|4000000000000000|405F800000000000|4045800000000000|4060000000000000|0000000000000000",
            "STATE|nostart|afterBurst|19|19|1790003420000|4060000000000000|50|1790003420000|775|3|41EA6666|40000000|405F800000000000|0000000000000000",
            "BURST|nostart|1790003600000|20:132:50:64",
            "OUT|nostart|burst|20|1790003600000|44|793|429E8F67|403D4CCCCCCCCCCD|4000000000000000|4060400000000000|0000000000000000|4060800000000000|405F800000000000",
            "STATE|nostart|afterBurst|20|20|1790003600000|4060800000000000|50|1790003600000|793|4|41EA6666|40000000|4060400000000000|0000000000000000",
            "BURST|nostart|1790003780000|21:136:50:64",
            "OUT|nostart|burst|21|1790003780000|46|829|42A5C477|403D4CCCCCCCCCCD|4000000000000000|4060C00000000000|0000000000000000|4061000000000000|4060400000000000",
            "STATE|nostart|afterBurst|21|21|1790003780000|4061000000000000|50|1790003780000|829|5|41EA6666|40000000|4060C00000000000|0000000000000000",
            "BURST|nostart|1790003960000|22:140:50:64",
            "OUT|nostart|burst|22|1790003960000|47|847|42A95EFF|403D4CCCCCCCCCCD|4000000000000000|4061400000000000|0000000000000000|4061800000000000|4060C00000000000",
            "STATE|nostart|afterBurst|22|22|1790003960000|4061800000000000|50|1790003960000|847|6|41EA6666|40000000|4061400000000000|0000000000000000",
            "BURST|nostart|1790004140000|23:144:50:64",
            "OUT|nostart|burst|23|1790004140000|48|865|42ACF987|403D4CCCCCCCCCCD|4000000000000000|4061C00000000000|0000000000000000|4062000000000000|4061400000000000",
            "STATE|nostart|afterBurst|23|23|1790004140000|4062000000000000|50|1790004140000|865|7|41EA6666|40000000|4061C00000000000|0000000000000000",
            "BURST|nostart|1790004320000|24:148:50:64",
            "OUT|nostart|burst|24|1790004320000|50|901|42B42E98|403D4CCCCCCCCCCD|4000000000000000|4062400000000000|0000000000000000|4062800000000000|4061C00000000000",
            "STATE|nostart|afterBurst|24|24|1790004320000|4062800000000000|50|1790004320000|901|8|41EA6666|40000000|4062400000000000|0000000000000000",
            "BURST|nostart|1790004500000|25:152:50:64",
            "OUT|nostart|burst|25|1790004500000|51|919|42B7C920|403D4CCCCCCCCCCD|4000000000000000|4062C00000000000|0000000000000000|4063000000000000|4062400000000000",
            "STATE|nostart|afterBurst|25|25|1790004500000|4063000000000000|50|1790004500000|919|9|41EA6666|40000000|4062C00000000000|0000000000000000",
            "BURST|nostart|1790004680000|26:156:50:64",
            "OUT|nostart|burst|26|1790004680000|53|955|42BEFE30|403D4CCCCCCCCCCD|4000000000000000|4063400000000000|0000000000000000|4063800000000000|4062C00000000000",
            "STATE|nostart|afterBurst|26|26|1790004680000|4063800000000000|50|1790004680000|955|10|41EA6666|40000000|4063400000000000|0000000000000000",
            "BURST|nostart|1790004860000|27:160:50:64",
            "OUT|nostart|burst|27|1790004860000|54|973|42C298B8|403D4CCCCCCCCCCD|4000000000000000|4063C00000000000|0000000000000000|4064000000000000|4063400000000000",
            "STATE|nostart|afterBurst|27|27|1790004860000|4064000000000000|50|1790004860000|973|11|41EA6666|40000000|4063C00000000000|0000000000000000",
            "BURST|nostart|1790005040000|28:164:50:64",
            "OUT|nostart|burst|28|1790005040000|55|991|42C63340|403D4CCCCCCCCCCD|4000000000000000|4064400000000000|0000000000000000|4064800000000000|4063C00000000000",
            "STATE|nostart|afterBurst|28|28|1790005040000|4064800000000000|50|1790005040000|991|12|41EA6666|40000000|4064400000000000|0000000000000000",
            "BURST|nostart|1790005220000|29:168:50:64",
            "OUT|nostart|burst|29|1790005220000|57|1027|42CD6851|403D4CCCCCCCCCCD|4000000000000000|4064C00000000000|0000000000000000|4065000000000000|4064400000000000",
            "STATE|nostart|afterBurst|29|29|1790005220000|4065000000000000|50|1790005220000|1027|13|41EA6666|40000000|4064C00000000000|0000000000000000",
            "BURST|nostart|1790005400000|30:172:50:64",
            "OUT|nostart|burst|30|1790005400000|58|1045|42D102D9|403D4CCCCCCCCCCD|4000000000000000|4065400000000000|0000000000000000|4065800000000000|4064C00000000000",
            "STATE|nostart|afterBurst|30|30|1790005400000|4065800000000000|50|1790005400000|1045|14|41EA6666|40000000|4065400000000000|0000000000000000"
        ]

        static var scenarios: [String] {
            return scenarios0 + scenarios1 + scenarios2 + scenarios3 + scenarios4
        }
}
