//
//  AnytimeSession.swift
//  xdrip
//
//  The session policies of the Anytime / Yuwell driver, kept free of Bluetooth so they can be unit tested
//  (`AnytimeSessionTests`): reconnect back-off, the glucose-id gap arithmetic of the history backfill,
//  the caught-up cooldown, the CT5 live clock, the learned CT5 current-to-glucose scale, the calibration
//  acceptance rules and the trend estimator. Ported from the JugglucoNG `drivers/anytime` package
//  (GPL-3.0, see THIRD_PARTY_NOTICES.md); the expected values in the tests come from running the
//  unchanged Kotlin on the JVM.
//
//  All classes here are single-threaded: the transmitter calls them from the main queue only, so they
//  carry none of the Kotlin `@Synchronized` locking.
//
//  Left out on purpose: `AnytimeHistoryRoomImportBuffer` (it feeds JugglucoNG's Room database; the Swift
//  transmitter hands readings to xDrip directly).
//
//  Never tried on a real sensor.
//

import Foundation

// MARK: - Connect and session retry policy

/// When a reconnect should stop hammering a transmitter that is not answering.
///
/// On Android a direct connect gives up after 30 s with status 147 (133 before API 35) and the driver then
/// switches to a background connect. CoreBluetooth has no such timer, a `connect` stays pending until the
/// peripheral advertises, so on iOS only the delays are used: a failed connect attempt counts as a timeout
/// for the back-off and the auto-connect decision is ignored.
enum AnytimeConnectPolicy {
    /// `BluetoothGatt.GATT_CONNECTION_TIMEOUT` (API 35).
    static let connectionTimeoutStatus = 147
    /// `BluetoothGatt.GATT_ERROR`: the direct-connect timer surfaces as a plain 133 before API 35.
    static let genericErrorStatus = 133
    /// One timeout is already 30 seconds of silence, do not spend a second one to be sure.
    static let autoConnectAfterTimeouts = 1
    /// Overflow guard only: the reading interval cap is what actually bounds the wait.
    static let maxBackoffDoublings = 30
    /// Ceiling for the delay once whole sessions keep dying.
    static let sessionRetryMaxDelayMs: Int64 = 30_000

    static func isConnectTimeoutStatus(_ status: Int) -> Bool {
        return status == connectionTimeoutStatus || status == genericErrorStatus
    }

    static func shouldUseAutoConnect(userSetting: Bool, directConnectUnreachable: Bool) -> Bool {
        return userSetting || directConnectUnreachable
    }

    /// Reconnect delay after attempts that never reached the transmitter: doubles from `baseDelayMs` and
    /// stops at one reading interval, because the transmitter is connectable at least once per slot.
    static func connectRetryDelayMs(consecutiveConnectTimeouts: Int, baseDelayMs: Int64, readingIntervalMs: Int64) -> Int64 {
        if consecutiveConnectTimeouts <= 0 || baseDelayMs <= 0 { return baseDelayMs }
        let cap = max(readingIntervalMs, baseDelayMs)
        let scaled = baseDelayMs << Int64(min(consecutiveConnectTimeouts, maxBackoffDoublings))
        return min(max(scaled, baseDelayMs), cap)
    }

    /// Delay before reconnecting after sessions that connected, handshook and then died without delivering
    /// a single frame. Doubles from `baseDelayMs`, capped at `capMs`.
    static func sessionRetryDelayMs(consecutiveFailedSessions: Int, baseDelayMs: Int64, capMs: Int64) -> Int64 {
        if consecutiveFailedSessions <= 0 || baseDelayMs <= 0 { return baseDelayMs }
        let cap = max(capMs, baseDelayMs)
        let scaled = baseDelayMs << Int64(min(consecutiveFailedSessions, maxBackoffDoublings))
        return min(max(scaled, baseDelayMs), cap)
    }
}

/// What the driver has learned about reaching this transmitter. The back-off counts the failures right now
/// and any connection ends that run; whether a direct connect can reach the transmitter at all is a property
/// of the transmitter, and only a direct connect that succeeded is evidence that direct connects work.
final class AnytimeConnectModeState {
    private(set) var consecutiveConnectTimeouts = 0
    private(set) var directConnectUnreachable = false

    func onConnected(usedAutoConnect: Bool) {
        consecutiveConnectTimeouts = 0
        if !usedAutoConnect { directConnectUnreachable = false }
    }

    /// `wasConnecting` separates an attempt that never reached the transmitter from a link that was up and
    /// dropped; only the former says anything about reachability.
    func onDisconnected(status: Int, wasConnecting: Bool) {
        if !wasConnecting || !AnytimeConnectPolicy.isConnectTimeoutStatus(status) {
            consecutiveConnectTimeouts = 0
            return
        }
        consecutiveConnectTimeouts += 1
        if consecutiveConnectTimeouts >= AnytimeConnectPolicy.autoConnectAfterTimeouts {
            directConnectUnreachable = true
        }
    }

    func useAutoConnect(userSetting: Bool) -> Bool {
        return AnytimeConnectPolicy.shouldUseAutoConnect(userSetting: userSetting, directConnectUnreachable: directConnectUnreachable)
    }

    func retryDelayMs(baseDelayMs: Int64, readingIntervalMs: Int64) -> Int64 {
        return AnytimeConnectPolicy.connectRetryDelayMs(consecutiveConnectTimeouts: consecutiveConnectTimeouts, baseDelayMs: baseDelayMs, readingIntervalMs: readingIntervalMs)
    }
}

/// How many link sessions in a row failed before delivering any sensor data. Kept apart from
/// `AnytimeConnectModeState` because it asks whether an established session stays usable, not whether the
/// phone can reach the transmitter at all. Any decoded frame ends the run.
final class AnytimeSessionChurnState {
    private(set) var consecutiveFailedSessions = 0

    func onSessionDeliveredData() {
        consecutiveFailedSessions = 0
    }

    /// Called once per session, after it is over.
    func onSessionEnded(deliveredData: Bool) {
        if deliveredData {
            consecutiveFailedSessions = 0
        } else {
            consecutiveFailedSessions += 1
        }
    }

    func retryDelayMs(baseDelayMs: Int64, capMs: Int64 = AnytimeConnectPolicy.sessionRetryMaxDelayMs) -> Int64 {
        return AnytimeConnectPolicy.sessionRetryDelayMs(consecutiveFailedSessions: consecutiveFailedSessions, baseDelayMs: baseDelayMs, capMs: capMs)
    }
}

// MARK: - History backfill arithmetic

/// Inclusive-start, exclusive-end glucose id range.
struct AnytimeIdRange: Equatable, Codable, CustomStringConvertible {
    let fromId: Int
    let stopBeforeId: Int

    var count: Int { return max(stopBeforeId - fromId, 0) }
    var isEmpty: Bool { return count <= 0 }

    var description: String {
        return isEmpty ? "<empty>" : "\(fromId)..\(stopBeforeId - 1)"
    }
}

enum AnytimeHistoryPolicy {
    /// The Kotlin `Int.MAX_VALUE`, kept 32-bit so the values match: "no upper bound" for a request.
    static let unbounded = Int(Int32.max)

    /// Missing ids between the newest record we hold and a newly arrived live id, nil when nothing is
    /// missing. Family-neutral: every Anytime generation advances one id per reading, so a hole shows only
    /// as a jump in the live id. `maxRecords` caps one repair and the newest part of the gap wins.
    static func reconnectGap(highestKnownId: Int, liveId: Int, maxRecords: Int) -> AnytimeIdRange? {
        if highestKnownId < 0 || liveId <= 0 { return nil }
        if liveId <= highestKnownId + 1 { return nil }
        let stopBeforeId = liveId
        let fromId = max(highestKnownId + 1, stopBeforeId - max(maxRecords, 1))
        let range = AnytimeIdRange(fromId: fromId, stopBeforeId: stopBeforeId)
        return range.isEmpty ? nil : range
    }

    /// Reconnect catch-up before a new live push has established the newest id. A clock estimate ahead of
    /// every observed record names an already-due id whose push may have been missed, so it is included;
    /// the boundary stays exclusive when the estimate is backed by an observed current frame.
    static func ct5ReconnectCatchupGap(highestKnownId: Int, lastObservedId: Int, expectedCurrentId: Int, maxRecords: Int) -> AnytimeIdRange? {
        if expectedCurrentId < 0 || expectedCurrentId == unbounded { return nil }
        let stopBeforeId = expectedCurrentId > lastObservedId ? expectedCurrentId + 1 : expectedCurrentId
        return reconnectGap(highestKnownId: highestKnownId, liveId: stopBeforeId, maxRecords: maxRecords)
    }

    /// What a finished gap pass still owes. A live id that jumps again during the pass widens the pending
    /// envelope past the range the pass was started with; nil when the pass covered everything owed.
    static func gapRemainder(runStopBeforeId: Int, reachedId: Int, pendingFromId: Int, pendingStopBeforeId: Int) -> AnytimeIdRange? {
        if pendingFromId < 0 || pendingStopBeforeId <= pendingFromId { return nil }
        let fromId = max(pendingFromId, runStopBeforeId, reachedId)
        if fromId >= pendingStopBeforeId { return nil }
        return AnytimeIdRange(fromId: fromId, stopBeforeId: pendingStopBeforeId)
    }

    /// True when a running pass already asks for every id in `[fromId, gapStopBeforeId)`.
    static func backfillCoversRange(nextRequestId: Int, stopBeforeId: Int, fromId: Int, gapStopBeforeId: Int) -> Bool {
        return nextRequestId <= fromId && stopBeforeId >= gapStopBeforeId
    }

    /// What is still owed from a persisted gap. Only ids inside the range count as progress: a newer live
    /// id says nothing about whether the hole was filled.
    static func ct5RemainingGap(pendingFromId: Int, pendingStopBeforeId: Int, highestImportedInRange: Int) -> AnytimeIdRange? {
        if pendingFromId < 0 || pendingStopBeforeId <= pendingFromId { return nil }
        let resumeFrom = (highestImportedInRange >= pendingFromId && highestImportedInRange < pendingStopBeforeId)
            ? highestImportedInRange + 1
            : pendingFromId
        if resumeFrom >= pendingStopBeforeId { return nil }
        return AnytimeIdRange(fromId: resumeFrom, stopBeforeId: pendingStopBeforeId)
    }

    /// Shrink an outstanding gap as batches land, so a second interruption resumes mid-range.
    static func ct5GapAfterBatch(pendingFromId: Int, pendingStopBeforeId: Int, maxImportedId: Int) -> AnytimeIdRange? {
        return ct5RemainingGap(pendingFromId: pendingFromId, pendingStopBeforeId: pendingStopBeforeId, highestImportedInRange: maxImportedId)
    }

    /// Merge a newly found gap into the outstanding one. Ranges are merged rather than queued, so a flaky
    /// stretch cannot grow an unbounded backlog; `maxRecords` keeps the result from becoming a session replay.
    static func ct5MergeGap(currentFromId: Int, currentStopBeforeId: Int, newFromId: Int, newStopBeforeId: Int, maxRecords: Int) -> AnytimeIdRange? {
        if newFromId < 0 || newStopBeforeId <= newFromId {
            if currentFromId < 0 || currentStopBeforeId <= currentFromId { return nil }
            return AnytimeIdRange(fromId: currentFromId, stopBeforeId: currentStopBeforeId)
        }
        let hasCurrent = currentFromId >= 0 && currentStopBeforeId > currentFromId
        let from = hasCurrent ? min(currentFromId, newFromId) : newFromId
        let stopBefore = hasCurrent ? max(currentStopBeforeId, newStopBeforeId) : newStopBeforeId
        let capped = max(from, stopBefore - max(maxRecords, 1))
        if capped >= stopBefore { return nil }
        return AnytimeIdRange(fromId: capped, stopBeforeId: stopBefore)
    }

    /// Smallest envelope that still contains every actually missing id.
    static func ct5MissingEnvelope(pendingFromId: Int, pendingStopBeforeId: Int, cachedIds: Set<Int>) -> AnytimeIdRange? {
        if pendingFromId < 0 || pendingStopBeforeId <= pendingFromId { return nil }
        var firstMissing = -1
        var lastMissing = -1
        for id in pendingFromId..<pendingStopBeforeId where !cachedIds.contains(id) {
            if firstMissing < 0 { firstMissing = id }
            lastMissing = id
        }
        if firstMissing < 0 { return nil }
        return AnytimeIdRange(fromId: firstMissing, stopBeforeId: lastMissing + 1)
    }

    /// Newest contiguous missing run inside a persisted gap envelope. Working backwards repairs the live
    /// edge first while the envelope keeps the older holes durable for later passes.
    static func ct5NewestMissingRange(pendingFromId: Int, pendingStopBeforeId: Int, cachedIds: Set<Int>, maxRecords: Int) -> AnytimeIdRange? {
        if pendingFromId < 0 || pendingStopBeforeId <= pendingFromId { return nil }
        var endInclusive = pendingStopBeforeId - 1
        while endInclusive >= pendingFromId && cachedIds.contains(endInclusive) { endInclusive -= 1 }
        if endInclusive < pendingFromId { return nil }

        let oldestAllowed = max(pendingFromId, endInclusive - max(maxRecords, 1) + 1)
        var start = endInclusive
        while start > oldestAllowed && !cachedIds.contains(start - 1) { start -= 1 }
        return AnytimeIdRange(fromId: start, stopBeforeId: endInclusive + 1)
    }

    /// Whether a live id rolled back far enough to look like a sensor restart rather than a late frame.
    static func liveIdLooksRolledBack(liveId: Int, previousMaxId: Int, rollbackThreshold: Int) -> Bool {
        return liveId >= 0 && previousMaxId >= 0 && liveId + max(rollbackThreshold, 0) < previousMaxId
    }

    /// The last glucose id to trust after a restart: the persisted one, unless the cached raw maximum shows
    /// the ids were reset.
    static func sanitizeRestoredGlucoseId(persistedLastId: Int, cachedRawMaxId: Int, rollbackThreshold: Int) -> Int {
        if persistedLastId < 0 { return persistedLastId }
        if cachedRawMaxId < 0 { return persistedLastId }
        return liveIdLooksRolledBack(liveId: cachedRawMaxId, previousMaxId: persistedLastId, rollbackThreshold: rollbackThreshold)
            ? cachedRawMaxId
            : persistedLastId
    }

    /// Whether a live id should move the timeline anchor. The transmitter sends an id, never a time, so the
    /// app derives `start = arrival - id * interval`; a repeated id must not walk the stored start forward.
    static func shouldReanchorTimeline(liveId: Int, previousMaxId: Int, haveTimelineStart: Bool) -> Bool {
        return liveId >= 0 && (!haveTimelineStart || liveId > previousMaxId)
    }

    /// The timeline anchor to start a process with: the persisted one, or the sensor start for installs that
    /// predate it (only when an id has been seen before), else none.
    static func restoredTimelineStartMs(persistedTimelineStartMs: Int64, persistedSensorStartMs: Int64, persistedLastGlucoseId: Int) -> Int64 {
        if persistedTimelineStartMs > 0 { return persistedTimelineStartMs }
        if persistedSensorStartMs > 0 && persistedLastGlucoseId >= 0 { return persistedSensorStartMs }
        return 0
    }

    /// The legacy families use the profile record count as a hard history boundary; CT5 does not.
    static func shouldStopAtProfileHistoryEnd(family: AnytimeFamily, nextId: Int, profileEndNumber: Int) -> Bool {
        return family != .ct5 && profileEndNumber > 0 && nextId >= profileEndNumber
    }

    /// True when a CT5 history request may go out: the streaming session has held together long enough to be
    /// worth risking an optional write on, and the single write slot is free.
    static func isCt5HistoryLinkSettled(streamingSinceMs: Int64, nowMs: Int64, settleMs: Int64, writeInFlight: Bool) -> Bool {
        if writeInFlight { return false }
        if streamingSinceMs <= 0 { return false }
        return nowMs - streamingSinceMs >= settleMs
    }

    /// Whether a shared loss-of-signal alarm should be ignored because the streaming session is too young to
    /// have received its next scheduled push.
    static func shouldDeferLossOfSignalReconnect(streamingSinceMs: Int64, nowMs: Int64, graceMs: Int64) -> Bool {
        return isWithinWindow(sinceMs: streamingSinceMs, nowMs: nowMs, windowMs: graceMs)
    }

    /// True when the sensor has been heard from inside `withinMs`. A decoded push proves the link works
    /// whether or not it carried a reading.
    static func hasRecentSensorData(lastSensorDataAtMs: Int64, nowMs: Int64, withinMs: Int64) -> Bool {
        return isWithinWindow(sinceMs: lastSensorDataAtMs, nowMs: nowMs, windowMs: withinMs)
    }

    private static func isWithinWindow(sinceMs: Int64, nowMs: Int64, windowMs: Int64) -> Bool {
        if sinceMs <= 0 { return false }
        let elapsed = nowMs - sinceMs
        return elapsed >= 0 && elapsed < windowMs
    }

    // MARK: write tags, response matching, priorities

    /// Tag carried by history write frames. Built and matched through these helpers on purpose: the tag once
    /// gained a suffix while the guards still tested the old prefix, and a failed optional write then tore down
    /// a healthy link.
    static let backfillWriteTagPrefix = "pullGlucose(backfill"

    static func backfillWriteTag(count: Int) -> String {
        return "pullGlucose(backfill,count=\(count))"
    }

    static func isBackfillWriteTag(_ tag: String) -> Bool {
        return tag.hasPrefix(backfillWriteTagPrefix)
    }

    /// A response releases only the request it actually answers; live pushes are unsolicited.
    static func responseMatchesRequest(requestOpcode: UInt8, responseOpcode: UInt8) -> Bool {
        if requestOpcode == AnytimeOpcode.txSetDate || requestOpcode == 0x04 {
            return responseOpcode == AnytimeOpcode.rxSetDateAckA || responseOpcode == AnytimeOpcode.rxSetDateAckB
        }
        // CT2 answers its 0x55 pull with 0x47, so the response slot would otherwise never clear.
        if requestOpcode == AnytimeOpcode.txCt2PullGlucose {
            return responseOpcode == AnytimeOpcode.rxCt2PullResponse
        }
        return requestOpcode == responseOpcode
    }

    enum WritePriority: Int, Comparable {
        case liveAck = 0
        case control = 1
        case gapHistory = 2
        case bulkHistory = 3

        static func < (lhs: WritePriority, rhs: WritePriority) -> Bool { return lhs.rawValue < rhs.rawValue }
    }

    static func writePriority(tag: String, historyReason: String) -> WritePriority {
        if tag == "ct5-pushAck" { return .liveAck }
        if !isBackfillWriteTag(tag) { return .control }
        if historyReason.hasPrefix("ct5-gap") || historyReason.hasPrefix("ct5-reconnect-catchup") { return .gapHistory }
        return .bulkHistory
    }
}

// MARK: - Stateful history helpers

/// Stops asking for history right after the transmitter said there is none: a reconnect that finds nothing
/// new must not repeat the same request for `cooldownMs`.
final class AnytimeHistoryCaughtUpCooldown {
    private let cooldownMs: Int64
    private let nowMs: () -> Int64
    private var caughtUpNextRequestId = -1
    private var caughtUpAtMs: Int64 = 0

    init(cooldownMs: Int64, nowMs: @escaping () -> Int64) {
        self.cooldownMs = cooldownMs
        self.nowMs = nowMs
    }

    func markCaughtUp(nextRequestId: Int) {
        caughtUpNextRequestId = max(nextRequestId, 0)
        caughtUpAtMs = nowMs()
    }

    func clearIfNewerData(glucoseId: Int) {
        if caughtUpNextRequestId >= 0 && glucoseId >= caughtUpNextRequestId { clear() }
    }

    func clear() {
        caughtUpNextRequestId = -1
        caughtUpAtMs = 0
    }

    func shouldSuppressBackfill(startId: Int, stopBeforeId: Int, reason: String, lastGlucoseId: Int) -> Bool {
        if reason.hasPrefix("user-requested") { return false }
        let caughtUpNext = caughtUpNextRequestId
        if caughtUpNext < 0 || stopBeforeId != AnytimeHistoryPolicy.unbounded { return false }
        if startId < caughtUpNext { return false }
        if lastGlucoseId >= caughtUpNext { return false }
        let elapsed = nowMs() - caughtUpAtMs
        return elapsed >= 0 && elapsed < cooldownMs
    }
}

/// Per-link health of the CT5 0x37 history pull. A timeout is transient (the link may be going away), so
/// timeouts get bounded retries inside one connection and everything resets on the next link; nothing is
/// ever disabled for the lifetime of the process.
final class AnytimeCt5HistoryHealth {
    private let maxTimeoutsPerConnection: Int
    private let retryBackoffMs: Int64
    private var timeoutsThisConnection = 0
    private var pausedThisConnection = false

    init(maxTimeoutsPerConnection: Int, retryBackoffMs: Int64) {
        self.maxTimeoutsPerConnection = maxTimeoutsPerConnection
        self.retryBackoffMs = retryBackoffMs
    }

    func onLinkSessionStarted() {
        timeoutsThisConnection = 0
        pausedThisConnection = false
    }

    /// Any successful series response proves the pull path still works.
    func onSeriesReceived() {
        timeoutsThisConnection = 0
    }

    func isPausedForThisConnection() -> Bool { return pausedThisConnection }

    func pauseForThisConnection() { pausedThisConnection = true }

    func timeoutCount() -> Int { return timeoutsThisConnection }

    /// The back-off before the next attempt, or nil when this link has used up its retries.
    func onTimeout() -> Int64? {
        timeoutsThisConnection += 1
        if timeoutsThisConnection >= maxTimeoutsPerConnection {
            pausedThisConnection = true
            return nil
        }
        return retryBackoffMs * Int64(timeoutsThisConnection)
    }
}

/// One-line accounting for a CT5 history batch.
final class AnytimeCt5HistoryBatchTally {
    private(set) var inserted = 0
    private(set) var existing = 0
    private(set) var warmup = 0
    private(set) var liveRace = 0

    func countInserted() { inserted += 1 }
    func countExisting() { existing += 1 }
    func countWarmup() { warmup += 1 }
    func countLiveRace() { liveRace += 1 }

    var total: Int { return inserted + existing + warmup + liveRace }

    func describe(firstId: Int, lastId: Int) -> String {
        var text = "CT5 history \(firstId)..\(lastId) received: \(existing) existing, \(inserted) inserted, \(warmup) warm-up/no-glucose"
        if liveRace > 0 { text += ", \(liveRace) superseded by live" }
        return text
    }
}

struct AnytimeCt5GapFailureSnapshot: Equatable, Codable {
    let fromId: Int
    let stopBeforeId: Int
    let failures: Int
}

/// Bounds automatic repair of a range the transmitter repeatedly cannot serve. One failure is recorded only
/// after a link session exhausts its own retries.
final class AnytimeCt5GapFailureTracker {
    private let maxFailedSessions: Int
    private var current: AnytimeCt5GapFailureSnapshot?

    init(maxFailedSessions: Int, restored: AnytimeCt5GapFailureSnapshot? = nil) {
        self.maxFailedSessions = maxFailedSessions
        self.current = restored
    }

    /// Returns the range once it has failed often enough to be given up on, nil while it may be retried.
    func onFailedSession(_ range: AnytimeIdRange) -> AnytimeIdRange? {
        let failures: Int
        if let previous = current, previous.fromId == range.fromId, previous.stopBeforeId == range.stopBeforeId {
            failures = previous.failures + 1
        } else {
            failures = 1
        }
        current = AnytimeCt5GapFailureSnapshot(fromId: range.fromId, stopBeforeId: range.stopBeforeId, failures: failures)
        if failures < max(maxFailedSessions, 1) { return nil }
        current = nil
        return range
    }

    func onProgress(receivedIds: [Int]) {
        guard let snapshot = current else { return }
        if receivedIds.contains(where: { $0 >= snapshot.fromId && $0 < snapshot.stopBeforeId }) { current = nil }
    }

    func clear() { current = nil }

    func snapshot() -> AnytimeCt5GapFailureSnapshot? { return current }
}

/// Live-only evidence for the clock based CT5 reconnect recovery; history must not feed this.
final class AnytimeCt5LiveClock {
    private var lastLiveId = -1
    private var lastLiveAtMs: Int64 = 0
    private var lastLiveAdvancedWithGlucose = false

    func observeLive(glucoseId: Int, receivedAtMs: Int64, hasGlucose: Bool, errorCode: Int) {
        lastLiveAdvancedWithGlucose = lastLiveId >= 0 && glucoseId > lastLiveId && hasGlucose && errorCode == 0
        lastLiveId = glucoseId
        lastLiveAtMs = receivedAtMs
    }

    func reset() {
        lastLiveId = -1
        lastLiveAtMs = 0
        lastLiveAdvancedWithGlucose = false
    }

    /// The id the transmitter should be at now, or -1 when there is no basis for an estimate.
    func expectedCurrentId(nowMs: Int64, intervalMs: Int64, streamingSinceMs: Int64, lastObservedId: Int, timelineStartMs: Int64, profileEndNumber: Int) -> Int {
        if intervalMs <= 0 { return -1 }
        let liveAgeMs = lastLiveAtMs > 0 ? nowMs - lastLiveAtMs : Int64.max
        // The last frame is authoritative while the same session is alive, or when ids repeat or carry no
        // glucose. But a healthy advancing frame from an earlier link says nothing about the push missed
        // while that connection was down.
        let recoveringAdvancingSession = lastLiveAdvancedWithGlucose && streamingSinceMs > lastLiveAtMs && streamingSinceMs <= nowMs
        if liveAgeMs >= 0 && liveAgeMs <= intervalMs * 2 && !recoveringAdvancingSession { return lastObservedId }
        if timelineStartMs <= 0 || nowMs < timelineStartMs { return -1 }
        let horizon = profileEndNumber > 0 ? profileEndNumber : AnytimeHistoryPolicy.unbounded
        let elapsedIds = (nowMs - timelineStartMs) / intervalMs
        return Int(min(elapsedIds, Int64(max(horizon, lastObservedId))))
    }
}

// MARK: - CT5 learned current scale

/// Per-sensor conversion from working-electrode current to glucose, learned from the transmitter's own
/// output while it still produces one. A CT5 stops computing glucose at the end of its nominal life but keeps
/// reporting current, and its output is a proportional scaling of Iw, so the whole of what the firmware adds
/// is one scalar that a trailing window of readings can learn. The scale is not constant over a sensor life
/// (it climbs early and decays slowly), which is why only a trailing window is used.
final class AnytimeCt5RawScale {
    /// mg/dL per nA for a CT5 with nothing learned yet (the mean over a measured 17-day life).
    static let defaultScale: Float = 13.3
    /// About 4 days at the 3-minute cadence.
    static let defaultWindow = 2000
    /// Half a day. Fewer than this and a single excursion dominates the mean.
    static let minSamples = 240

    private static let minUsableIw: Float = 0.3
    private static let minUsableMgdl: Float = 20
    private static let minPlausibleRatio: Float = 4
    private static let maxPlausibleRatio: Float = 40
    private static let minEstimateMgdl: Float = 20
    private static let maxEstimateMgdl: Float = 600

    private let windowSize: Int
    private var ratios = [Float]()
    /// Held apart from the live window so a restart cannot dilute it below the threshold.
    private var restoredScale = Float.nan
    private var restoredSamples = 0

    /// mg/dL per nA, NaN until enough of a window has been seen to trust it.
    private(set) var scale = Float.nan

    init(windowSize: Int = AnytimeCt5RawScale.defaultWindow) {
        self.windowSize = windowSize
    }

    /// Evidence behind the current scale. Must not fall back to the live window's size alone: persisting a
    /// restored scale as "1 sample" made the next restart reject it.
    var samples: Int { return max(ratios.count, restoredSamples) }

    /// Feed a reading the transmitter computed itself. Only clean ones: an errored or warm-up record carries
    /// no usable relation between current and glucose.
    func observe(iwNa: Float, vendorMgdl: Float) {
        if !iwNa.isFinite || iwNa < AnytimeCt5RawScale.minUsableIw { return }
        if !vendorMgdl.isFinite || vendorMgdl < AnytimeCt5RawScale.minUsableMgdl { return }
        let ratio = vendorMgdl / iwNa
        if ratio < AnytimeCt5RawScale.minPlausibleRatio || ratio > AnytimeCt5RawScale.maxPlausibleRatio { return }
        if ratios.count >= windowSize { ratios.removeFirst() }
        ratios.append(ratio)
        recompute()
    }

    /// Restore a scale learned before a restart, so a frozen sensor is usable immediately. Deliberately kept
    /// out of the live window: seeding it with the restored mean made the scale evaporate on the first frame.
    func restore(scale restoredValue: Float, samples restoredCount: Int) {
        if !restoredValue.isFinite || restoredValue < AnytimeCt5RawScale.minPlausibleRatio || restoredValue > AnytimeCt5RawScale.maxPlausibleRatio { return }
        if restoredCount < AnytimeCt5RawScale.minSamples { return }
        ratios.removeAll()
        restoredScale = restoredValue
        restoredSamples = restoredCount
        recompute()
    }

    private func recompute() {
        if ratios.count >= AnytimeCt5RawScale.minSamples {
            var total: Float = 0
            for ratio in ratios { total += ratio }
            scale = total / Float(ratios.count)
        } else {
            scale = restoredScale
        }
    }

    /// True once this sensor has taught us its own scale, rather than the family default.
    var isLearned: Bool { return scale.isFinite }

    /// The scale in use: this sensor's if known, otherwise the CT5 family figure.
    var effectiveScale: Float { return scale.isFinite ? scale : AnytimeCt5RawScale.defaultScale }

    /// mg/dL for a current the transmitter did not compute for. Never withheld for want of a learned scale:
    /// the family default is a measured figure, not a placeholder.
    func estimateMgdl(iwNa: Float) -> Float {
        if !iwNa.isFinite || iwNa < AnytimeCt5RawScale.minUsableIw { return Float.nan }
        let mgdl = effectiveScale * iwNa
        return (mgdl >= AnytimeCt5RawScale.minEstimateMgdl && mgdl <= AnytimeCt5RawScale.maxEstimateMgdl) ? mgdl : Float.nan
    }
}

// MARK: - Calibration acceptance and trend

enum AnytimeCalibrationPolicy {
    /// The manual BG calibration is unavailable in the first 24 hours.
    static let manualCalibrationMinAgeHours = 24
    /// Stable/moderate slope boundary, mmol/L per minute.
    static let trendStableThresholdMmolPerMin: Float = 0.06
    /// Moderate/rapid slope boundary, mmol/L per minute.
    static let trendRapidThresholdMmolPerMin: Float = 0.11
    /// Maximum noise (mmol/L) accepted for a manual calibration.
    static let maxCalibrationNoiseMmol: Float = 0.2

    static let calibrationStatusUnknown = -1
    static let calibrationStatusNot = 0
    static let calibrationStatusCan = 1
    static let calibrationStatusHope = 2
    static let calibrationStatusInit = 3
    static let calibrationStatusMust = 4

    enum Trend: String {
        case rapidRise, moderateRise, stable, moderateFall, rapidFall
    }

    static func canAcceptManualCalibration(sensorAgeHours: Int) -> Bool {
        return sensorAgeHours >= manualCalibrationMinAgeHours
    }

    static func canAcceptAlgorithmCalibrationStatus(_ status: Int) -> Bool {
        return status == calibrationStatusUnknown || status != calibrationStatusNot
    }

    static func classifyTrend(slopeMmolPerMin: Float) -> Trend {
        if slopeMmolPerMin >= trendRapidThresholdMmolPerMin { return .rapidRise }
        if slopeMmolPerMin >= trendStableThresholdMmolPerMin { return .moderateRise }
        if slopeMmolPerMin <= -trendRapidThresholdMmolPerMin { return .rapidFall }
        if slopeMmolPerMin <= -trendStableThresholdMmolPerMin { return .moderateFall }
        return .stable
    }

    /// A calibration point is only accepted on a stable ("→") trend.
    static func canAcceptTrendForCalibration(slopeMmolPerMin: Float) -> Bool {
        return classifyTrend(slopeMmolPerMin: slopeMmolPerMin) == .stable
    }

    static func canAcceptNoiseForCalibration(noiseMmol: Float) -> Bool {
        return noiseMmol < maxCalibrationNoiseMmol
    }

    static func calibrationStatusName(_ status: Int) -> String {
        switch status {
        case calibrationStatusUnknown: return "UNKNOWN"
        case calibrationStatusNot: return "NOT"
        case calibrationStatusCan: return "CAN"
        case calibrationStatusHope: return "HOPE"
        case calibrationStatusInit: return "INIT"
        case calibrationStatusMust: return "MUST"
        default: return "UNKNOWN(\(status))"
        }
    }
}

/// Trend slope and noise for the calibration gate and the trend classifier: an ordinary least-squares line
/// over a short window of readings.
enum AnytimeTrendEstimator {
    struct Point: Equatable {
        let timestampMs: Int64
        let mmol: Float
    }

    struct Estimate: Equatable {
        let slopeMmolPerMin: Float
        let noiseMmol: Float
    }

    /// Slope (mmol/L per minute) and RMS residual (mmol/L) over `points`; nil with fewer than 3 points,
    /// which cannot tell a real trend from sensor jitter.
    static func estimate(_ points: [Point]) -> Estimate? {
        if points.count < 3 { return nil }
        let t0 = points[0].timestampMs
        let xs = points.map { Double($0.timestampMs - t0) / 60_000.0 }
        let ys = points.map { Double($0.mmol) }
        var sumX = 0.0
        for x in xs { sumX += x }
        var sumY = 0.0
        for y in ys { sumY += y }
        let meanX = sumX / Double(xs.count)
        let meanY = sumY / Double(ys.count)
        var sxx = 0.0
        var sxy = 0.0
        for index in 0..<points.count {
            let dx = xs[index] - meanX
            sxx += dx * dx
            sxy += dx * (ys[index] - meanY)
        }
        if sxx <= 1e-9 { return Estimate(slopeMmolPerMin: 0, noiseMmol: 0) }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        var sse = 0.0
        for index in 0..<points.count {
            let residual = ys[index] - (intercept + slope * xs[index])
            sse += residual * residual
        }
        let noise = (sse / Double(points.count)).squareRoot()
        return Estimate(slopeMmolPerMin: Float(slope), noiseMmol: Float(noise))
    }
}
