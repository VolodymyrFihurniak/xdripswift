//
//  OttaiSession.swift
//  xdrip
//
//  The session logic of the Ottai / Syai driver that can be tested without a radio, ported from
//  JugglucoNG `drivers/ottai/OttaiBleManager.kt` (GPL-3.0, see THIRD_PARTY_NOTICES.md): the timing
//  helpers, the stream clock that dates a record by its counter, the continuity gate, the whole
//  path a decoded frame takes before a reading may be published (`OttaiPipeline`), the history
//  request window and its chunk chain. The connection itself is `CGMOttaiTransmitter`.
//
//  The helpers and the pipeline were run against the unchanged Kotlin code on the JVM (a harness
//  holding verbatim copies of the Kotlin functions, with the Android calls replaced); the vectors in
//  `OttaiSessionTests` are its output.
//
//  Deliberately not ported (see docs/ottai.md): the Room backfill diff, the history hole ledger that
//  survives restarts, the provisional start taken from the cgm-info window, the activation
//  negotiation and the native mirror. A history window that the sensor does not deliver after its
//  retries is given up, not remembered.
//
//  Never compiled here and never tried on a real sensor.
//

import Foundation

// MARK: - Timing helpers

/// JugglucoNG `OttaiBleManager` companion helpers.
enum OttaiTiming {

    static let recordIntervalMs: Int64 = 60_000
    static let currentSampleFreshMs: Int64 = 120_000
    static let currentSampleFloorGraceMs: Int64 = recordIntervalMs
    static let maxReasonableDataNoAhead = 120
    static let maxLiveGapRecords = 240
    static let maxConsecutiveCeilingFullDrops = 3
    static let maxConsecutiveContinuityRejects = 3
    static let confirmedStartAgreementMs: Int64 = 2 * recordIntervalMs

    /// Only a decoded notification proves that notifications can replace the safety-net poll: at the
    /// wrong width the last record can be padding, whose zero current is not a sample.
    static func notifyHoldsPollDown(_ readings: [OttaiReading]) -> Bool {
        guard let last = readings.last else { return false }
        return last.valid && last.record.rawCurrent > 0
    }

    static func isFreshLiveSample(receivedAtMs: Int64, sampleMs: Int64) -> Bool {
        return receivedAtMs > 0 && sampleMs > 0 &&
            abs(receivedAtMs - sampleMs) <= currentSampleFreshMs + currentSampleFloorGraceMs
    }

    /// The latest stream start a live record allows: it cannot be measured after it arrived.
    static func arrivalBoundStartMs(dataNo: Int, receivedAtMs: Int64) -> Int64 {
        return receivedAtMs - Int64(dataNo) * recordIntervalMs
    }

    /// A live record's time from a confirmed stream start, capped at its arrival.
    static func anchoredLiveSampleMs(startMs: Int64, dataNo: Int, receivedAtMs: Int64) -> Int64 {
        return min(startMs + Int64(dataNo) * recordIntervalMs, receivedAtMs)
    }

    /// Whether a live record's monitor time (activation plus runtime) may anchor the stream.
    static func isUsableLiveMonitorTime(monitorMs: Int64, receivedAtMs: Int64) -> Bool {
        return monitorMs > 0 && monitorMs <= receivedAtMs && receivedAtMs - monitorMs <= currentSampleFreshMs
    }

    /// Whether the one-shot live read after a history payload is worth its round trip.
    static func shouldReadLiveAfterHistory(receivedAtMs: Int64, lastLiveFrameAtMs: Int64) -> Bool {
        if lastLiveFrameAtMs <= 0 { return true }
        let since = receivedAtMs - lastLiveFrameAtMs
        return since < 0 || since >= recordIntervalMs
    }

    /// Two records or 135 s behind the previous evaluated sample.
    static func isAdjacentSample(previousDataNo: Int, previousSampleMs: Int64, dataNo: Int, sampleMs: Int64) -> Bool {
        if previousDataNo < 0 { return false }
        let gap = dataNo - previousDataNo
        if gap >= 1 && gap <= 2 { return true }
        if previousSampleMs <= 0 || sampleMs <= previousSampleMs { return false }
        let delta = sampleMs - previousSampleMs
        return delta >= 1 && delta <= 2 * recordIntervalMs + 15_000
    }

    static func isPersistedDataNoAheadOfLive(previousDataNo: Int, liveDataNo: Int) -> Bool {
        return previousDataNo >= 0 && liveDataNo >= 0 && previousDataNo > liveDataNo + maxReasonableDataNoAhead
    }

    static func previousDataNoForHistory(previousDataNo: Int, liveDataNo: Int) -> Int {
        return isPersistedDataNoAheadOfLive(previousDataNo: previousDataNo, liveDataNo: liveDataNo) ? -1 : previousDataNo
    }

    /// The retry budget after a history frame for the in-flight chunk: refunded only when the frame
    /// goes further than every earlier frame of the chunk.
    static func historyRetriesAfterFrame(retries: Int, frameMaxDataNo: Int, chunkBestDataNo: Int) -> Int {
        return frameMaxDataNo > chunkBestDataNo ? 0 : retries
    }

    /// The records a live sample says are missing, or nil.
    static func liveGapRange(
        previousDataNo: Int, liveDataNo: Int, ceiling: Int = Int.max, maxRecords: Int = OttaiTiming.maxLiveGapRecords
    ) -> (start: Int, endExclusive: Int)? {
        if previousDataNo < 0 || liveDataNo <= 0 || liveDataNo > ceiling { return nil }
        let missing = liveDataNo - previousDataNo - 1
        if missing <= 0 || missing > maxRecords { return nil }
        return (previousDataNo + 1, liveDataNo)
    }

    /// Physical upper bound for a record's counter, from the authoritative start only.
    static func dataNoCeilingFor(authoritativeStartMs: Int64, nowMs: Int64, lastDataNo: Int, live: Bool) -> Int {
        if authoritativeStartMs > 0 && authoritativeStartMs < nowMs {
            let elapsed = min((nowMs - authoritativeStartMs) / recordIntervalMs, Int64(Int32.max / 2))
            return Int(elapsed) + maxReasonableDataNoAhead
        }
        if live { return Int.max }
        return lastDataNo > 0 ? lastDataNo + maxReasonableDataNoAhead : Int.max
    }

    /// A bound that rejected whole payloads this often is likelier wrong than the sensor.
    static func shouldDistrustCeiling(consecutiveFullDrops: Int) -> Bool {
        return consecutiveFullDrops >= maxConsecutiveCeilingFullDrops
    }
}

// MARK: - Arrival start correction

/// JugglucoNG `OttaiArrivalStartCorrection`: lowers a stream start seeded by a delayed live read once
/// two accepted frames arrive earlier than it predicts. Bounded to one record, never trusts repeated
/// counters.
struct OttaiArrivalStartCorrection: Equatable {

    static let maxPendingAgeMs: Int64 = 3 * OttaiTiming.recordIntervalMs
    static let maxCorrectedLagMs: Int64 = 2 * OttaiTiming.recordIntervalMs

    private var lowestStartMs: Int64 = 0
    private var latestArrivalStartMs: Int64 = 0
    private var pendingStartMs: Int64 = 0
    private var pendingDataNo = -1
    private var pendingReceivedAtMs: Int64 = 0

    /// The anchor was (re)seeded at `startMs`; `seedArrivalStartMs` is arrival minus dataNo records of
    /// the live frame it came from, 0 for anything else.
    mutating func onAnchorSeeded(startMs: Int64, seedArrivalStartMs: Int64) {
        lowestStartMs = startMs - OttaiTiming.recordIntervalMs
        latestArrivalStartMs = max(seedArrivalStartMs, 0)
        clearPending()
    }

    /// Offers an accepted live frame dated from `anchorStartMs`. Returns the start the anchor should
    /// move to, or 0 to leave it.
    mutating func onAcceptedLive(anchorStartMs: Int64, dataNo: Int, receivedAtMs: Int64) -> Int64 {
        if anchorStartMs <= 0 || dataNo < 0 || receivedAtMs <= 0 {
            clearPending()
            return 0
        }
        if latestArrivalStartMs > 0 {
            latestArrivalStartMs = max(latestArrivalStartMs, receivedAtMs - Int64(dataNo) * OttaiTiming.recordIntervalMs)
        }
        let startMs = OttaiTiming.arrivalBoundStartMs(dataNo: dataNo, receivedAtMs: receivedAtMs)
        if startMs >= anchorStartMs {
            clearPending()
            return 0
        }
        let age = receivedAtMs - pendingReceivedAtMs
        let agrees = pendingDataNo >= 0 && pendingDataNo < dataNo &&
            age >= 1 && age <= Self.maxPendingAgeMs &&
            abs(pendingStartMs - startMs) <= OttaiTiming.recordIntervalMs
        if !agrees {
            pendingStartMs = startMs
            pendingDataNo = dataNo
            pendingReceivedAtMs = receivedAtMs
            return 0
        }
        let agreed = max(pendingStartMs, startMs)
        clearPending()
        let floor = floorMs()
        return (floor > 0 && agreed >= floor) ? agreed : 0
    }

    /// Lowest start a correction may still reach, or 0 when the anchor may not be corrected.
    func floorMs() -> Int64 {
        if lowestStartMs > 0 && latestArrivalStartMs > 0 {
            return max(lowestStartMs, latestArrivalStartMs - Self.maxCorrectedLagMs)
        }
        return 0
    }

    private mutating func clearPending() {
        pendingStartMs = 0
        pendingDataNo = -1
        pendingReceivedAtMs = 0
    }
}

// MARK: - Small least-recently-used map

/// A `LinkedHashMap(accessOrder = true)` of at most `capacity` entries: reading or writing a key makes
/// it the newest, and the oldest is dropped when the map outgrows its capacity.
struct OttaiLruMap<Value> {

    let capacity: Int
    private var order: [Int] = []
    private var storage: [Int: Value] = [:]

    init(capacity: Int = 64) {
        self.capacity = capacity
    }

    var count: Int { return storage.count }

    mutating func get(_ key: Int) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func put(_ key: Int, _ value: Value) {
        storage[key] = value
        touch(key)
        if storage.count > capacity, let eldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: eldest)
        }
    }

    @discardableResult
    mutating func remove(_ key: Int) -> Value? {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        return storage.removeValue(forKey: key)
    }

    mutating func removeAll() {
        order.removeAll()
        storage.removeAll()
    }

    private mutating func touch(_ key: Int) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

// MARK: - Reading pipeline

/// One reading that passed every gate.
struct OttaiEmitted: Equatable {
    let sampleMs: Int64
    /// mmol/L as a `Float` times 18, the arithmetic JugglucoNG uses for its mg/dL.
    let mgdl: Float
    let dataNo: Int
    let rawCurrent: Int
    let temperatureC: Double
    /// A live record whose time is within the freshness window of its arrival.
    let fresh: Bool
}

/// What the pipeline needs to keep across connections and restarts.
struct OttaiPersistedPipeline: Codable, Equatable {
    var lastDataNo = -1
    var streamStartMs: Int64 = 0
    var streamStartReliable = false
    /// The activation start the driver confirmed itself from two live anchors (0 = none yet).
    var confirmedActiveTimeMs: Int64 = 0
    var lastAcceptedDataNo = -1
    var lastAcceptedSampleMs: Int64 = 0
    var lastAcceptedMmol: Float = 0
    var lastAcceptedRawCurrent = 0
}

/// What a decoded frame did.
struct OttaiFrameResult: Equatable {
    var emitted: [OttaiEmitted] = []
    /// A history frame decoded at the wrong record width: nothing of it may be used.
    var misframed = false
    /// Records dropped because their counter is past what the sensor can have reached.
    var dropped = 0
    /// The plausible records of the frame.
    var arrived: [Int] = []
    /// Of those, the ones that were stored or refused on their own merits.
    var settled: [Int] = []
    /// One line per record decision, for the trace and the tests: `A:` accepted, `R:` refused, `I:` invalid,
    /// `N:` no method, `S:` no time anchor.
    var trace: [String] = []
}

/// JugglucoNG's path from a decoded frame to a publishable reading: the ceiling filter, the sample
/// time, the warm-up, the continuity gate and the bookkeeping of what was accepted or refused.
struct OttaiPipeline {

    var persisted: OttaiPersistedPipeline
    /// The activation start from the sensor material, or the one confirmed from the stream; 0 = unknown.
    var activeTimeMs: Int64
    /// When set, the warm-up counts from this instant instead of `activeTimeMs`.
    var warmupAnchorOverrideMs: Int64?

    // transient
    private(set) var streamNotifyPhaseKnown = false
    private var acceptedLiveSampleTimes = OttaiLruMap<Int64>(capacity: 64)
    private var pendingConfirmedStartMs: Int64 = 0
    private var pendingConfirmedDataNo = -1
    private var arrivalStartCorrection = OttaiArrivalStartCorrection()
    private(set) var lastLiveFrameAtMs: Int64 = 0
    private var recentlyRejected = OttaiLruMap<RejectedSample>(capacity: 64)
    private(set) var consecutiveContinuityRejects = 0
    private(set) var lastEvaluatedDataNo = -1
    private(set) var lastEvaluatedSampleMs: Int64 = 0
    private(set) var consecutiveCeilingFullDrops = 0
    private(set) var ceilingDistrusted = false

    private struct RejectedSample {
        let rawCurrent: Int
        let mmol: Float
    }

    private struct NeighborSample {
        let dataNo: Int
        let mmol: Float
        let rawCurrent: Int
    }

    private static let mgdlPerMmol: Float = 18.0

    init(persisted: OttaiPersistedPipeline = OttaiPersistedPipeline(), activeTimeMs: Int64 = 0, warmupAnchorOverrideMs: Int64? = nil) {
        self.persisted = persisted
        self.activeTimeMs = activeTimeMs
        self.warmupAnchorOverrideMs = warmupAnchorOverrideMs
    }

    var lastDataNo: Int { return persisted.lastDataNo }
    var streamStartMs: Int64 { return persisted.streamStartMs }
    var streamStartReliable: Bool { return persisted.streamStartReliable }

    /// A new connection starts the transient state over (the anchors and the gate baseline stay).
    mutating func resetTransientState() {
        streamNotifyPhaseKnown = false
        acceptedLiveSampleTimes.removeAll()
        pendingConfirmedStartMs = 0
        pendingConfirmedDataNo = -1
        arrivalStartCorrection = OttaiArrivalStartCorrection()
        recentlyRejected.removeAll()
        consecutiveContinuityRejects = 0
        lastEvaluatedDataNo = -1
        lastEvaluatedSampleMs = 0
        consecutiveCeilingFullDrops = 0
        ceilingDistrusted = false
    }

    private var effectiveActiveTimeMs: Int64 {
        if activeTimeMs > 0 { return activeTimeMs }
        if persisted.streamStartMs > 0 { return persisted.streamStartMs }
        return 0
    }

    private var warmupAnchorMs: Int64 {
        if let override = warmupAnchorOverrideMs { return override }
        return max(activeTimeMs, 0)
    }

    // MARK: frame

    /// The part of JugglucoNG's `handleGlucosePayload` after the frame was decrypted and framed.
    /// `methodBlank` is true when the sensor material holds no expression.
    mutating func processFrame(
        _ readings: [OttaiReading], live: Bool, notify: Bool, receivedAtMs: Int64, nowMs: Int64, methodBlank: Bool = false
    ) -> OttaiFrameResult {
        var result = OttaiFrameResult()
        if !live && OttaiOutputFilter.isMisframedFrame(readings) {
            result.misframed = true
            return result
        }
        let ceiling = dataNoCeiling(live: live, nowMs: nowMs)
        let plausible = ceiling == Int.max ? readings : readings.filter { $0.record.dataNo <= ceiling }
        result.dropped = readings.count - plausible.count
        noteCeilingOutcome(offered: readings.count, kept: plausible.count, ceiling: ceiling)
        if live && !plausible.isEmpty { lastLiveFrameAtMs = receivedAtMs }
        for (index, reading) in plausible.enumerated() {
            if !reading.valid {
                result.trace.append("I:\(reading.record.dataNo)")
                if !methodBlank { result.settled.append(reading.record.dataNo) }
                continue
            }
            if methodBlank {
                result.trace.append("N:\(reading.record.dataNo)")
                continue
            }
            var refused = false
            let emitted = emitReading(
                reading, live: live, receivedAtMs: receivedAtMs, nowMs: nowMs, batch: plausible, batchIndex: index,
                liveNotify: live && notify, trace: &result.trace, refused: &refused
            )
            if let emitted = emitted {
                result.emitted.append(emitted)
                result.trace.append("A:\(emitted.dataNo):\(emitted.sampleMs)")
            }
            if emitted != nil || refused { result.settled.append(reading.record.dataNo) }
        }
        result.arrived = plausible.map { $0.record.dataNo }
        return result
    }

    // MARK: ceiling

    private func dataNoCeiling(live: Bool, nowMs: Int64) -> Int {
        if ceilingDistrusted { return Int.max }
        return OttaiTiming.dataNoCeilingFor(
            authoritativeStartMs: activeTimeMs, nowMs: nowMs, lastDataNo: persisted.lastDataNo, live: live
        )
    }

    private mutating func noteCeilingOutcome(offered: Int, kept: Int, ceiling: Int) {
        if offered <= 0 || ceiling == Int.max { return }
        if kept > 0 {
            consecutiveCeilingFullDrops = 0
            return
        }
        consecutiveCeilingFullDrops += 1
        if !ceilingDistrusted && OttaiTiming.shouldDistrustCeiling(consecutiveFullDrops: consecutiveCeilingFullDrops) {
            ceilingDistrusted = true
        }
    }

    // MARK: one reading

    private mutating func emitReading(
        _ reading: OttaiReading, live: Bool, receivedAtMs: Int64, nowMs: Int64, batch: [OttaiReading], batchIndex: Int,
        liveNotify: Bool, trace: inout [String], refused: inout Bool
    ) -> OttaiEmitted? {
        let dataNo = reading.record.dataNo
        let mmol = Float(reading.adjustGlucose)
        let mgdl = mmol * Self.mgdlPerMmol

        func refuse(_ reason: String) -> OttaiEmitted? {
            refused = true
            recentlyRejected.put(dataNo, RejectedSample(rawCurrent: reading.record.rawCurrent, mmol: mmol))
            trace.append("R:\(dataNo):\(reason)")
            return nil
        }

        if let reason = OttaiOutputFilter.hardRejectReason(reading.record, mmol: mmol) {
            return refuse("hard-\(reason)")
        }
        if mgdl <= 1 { return refuse("mgdl=\(mgdl)") }
        if let rejected = recentlyRejected.get(dataNo) {
            let sameRaw = rejected.rawCurrent == reading.record.rawCurrent
            let sameValue = abs(rejected.mmol - mmol) < 0.05
            if sameRaw || sameValue { return refuse("recent-rejected") }
        }
        repairAheadLastDataNoIfNeeded(acceptedDataNo: dataNo, live: live)
        let advancesDataNo = dataNo > persisted.lastDataNo
        var sampleMs = resolveSampleTimeMs(reading, live: live, receivedAtMs: receivedAtMs, nowMs: nowMs)
        if sampleMs <= 0 {
            trace.append("S:\(dataNo):no-anchor")
            return nil
        }
        if OttaiConstants.isWithinWarmup(activationStartMs: warmupAnchorMs, sampleMs: sampleMs) {
            return refuse("warmup")
        }
        if let reason = continuityRejectReason(reading, mmol: mmol, sampleMs: sampleMs, live: live, batch: batch, batchIndex: batchIndex) {
            consecutiveContinuityRejects += 1
            noteContinuityEvaluated(dataNo: dataNo, sampleMs: sampleMs)
            return refuse(reason)
        }
        let notifyStartMs = OttaiTiming.arrivalBoundStartMs(dataNo: dataNo, receivedAtMs: receivedAtMs)
        if liveNotify && advancesDataNo && !streamNotifyPhaseKnown &&
            notifyStartMs / OttaiTiming.recordIntervalMs == persisted.streamStartMs / OttaiTiming.recordIntervalMs {
            sampleMs = seedStreamTimeAnchor(dataNo: dataNo, sampleHintMs: receivedAtMs, reliable: true, receivedAtMs: receivedAtMs, nowMs: nowMs)
            streamNotifyPhaseKnown = true
        }
        if live {
            if let pinned = acceptedLiveSampleTimes.get(dataNo) {
                sampleMs = pinned
            } else {
                acceptedLiveSampleTimes.put(dataNo, sampleMs)
            }
        }
        let fresh = live && OttaiTiming.isFreshLiveSample(receivedAtMs: receivedAtMs, sampleMs: sampleMs)
        rememberAcceptedReading(reading, mmol: mmol, sampleMs: sampleMs)
        if live { correctStreamStartFromArrival(dataNo: dataNo, receivedAtMs: receivedAtMs) }
        if advancesDataNo { noteSeenDataNo(dataNo) }
        return OttaiEmitted(
            sampleMs: sampleMs, mgdl: mgdl, dataNo: dataNo, rawCurrent: reading.record.rawCurrent,
            temperatureC: reading.record.temperatureC, fresh: fresh
        )
    }

    // MARK: sample time

    private mutating func resolveSampleTimeMs(_ reading: OttaiReading, live: Bool, receivedAtMs: Int64, nowMs: Int64) -> Int64 {
        let dataNo = reading.record.dataNo
        if live, let pinned = acceptedLiveSampleTimes.get(dataNo) {
            return pinned
        }
        if persisted.streamStartMs > 0 && (!live || persisted.streamStartReliable) {
            if live && activeTimeMs <= 0 {
                offerConfirmedActiveTime(
                    startMs: OttaiTiming.arrivalBoundStartMs(dataNo: dataNo, receivedAtMs: receivedAtMs), dataNo: dataNo, nowMs: nowMs
                )
            }
            let anchored = persisted.streamStartMs + Int64(dataNo) * OttaiTiming.recordIntervalMs
            if live && receivedAtMs > 0 && anchored > receivedAtMs {
                return OttaiTiming.anchoredLiveSampleMs(startMs: persisted.streamStartMs, dataNo: dataNo, receivedAtMs: receivedAtMs)
            }
            return anchored
        }
        if live && receivedAtMs > 0 && dataNo >= 0 {
            let monitor = reading.monitorTimeMs
            if OttaiTiming.isUsableLiveMonitorTime(monitorMs: monitor, receivedAtMs: receivedAtMs) {
                return seedStreamTimeAnchor(dataNo: dataNo, sampleHintMs: monitor, reliable: true, receivedAtMs: receivedAtMs, nowMs: nowMs)
            }
            return seedStreamTimeAnchor(dataNo: dataNo, sampleHintMs: receivedAtMs, reliable: true, receivedAtMs: receivedAtMs, nowMs: nowMs)
        }
        if reading.monitorTimeMs > 0 {
            return seedStreamTimeAnchor(dataNo: dataNo, sampleHintMs: reading.monitorTimeMs, reliable: false, receivedAtMs: 0, nowMs: nowMs)
        }
        let active = effectiveActiveTimeMs
        if active > 0 {
            return seedStreamTimeAnchor(
                dataNo: dataNo, sampleHintMs: active + Int64(reading.record.runtimeSec) * 1000, reliable: false, receivedAtMs: 0, nowMs: nowMs
            )
        }
        return reading.monitorTimeMs
    }

    /// `reliable` means the hint is an independent wall-clock or monitor time (a live read), so the start it
    /// implies is the true activation and may be committed once a second one agrees.
    private mutating func seedStreamTimeAnchor(
        dataNo: Int, sampleHintMs: Int64, reliable: Bool, receivedAtMs: Int64, nowMs: Int64
    ) -> Int64 {
        if dataNo < 0 || sampleHintMs <= 0 { return sampleHintMs }
        let start = sampleHintMs - Int64(dataNo) * OttaiTiming.recordIntervalMs
        if start > 0 {
            let old = persisted.streamStartMs
            if old > 0 && persisted.streamStartReliable && !reliable {
                return old + Int64(dataNo) * OttaiTiming.recordIntervalMs
            }
            persisted.streamStartMs = start
            persisted.streamStartReliable = reliable
            arrivalStartCorrection.onAnchorSeeded(
                startMs: start,
                seedArrivalStartMs: receivedAtMs > 0 ? receivedAtMs - Int64(dataNo) * OttaiTiming.recordIntervalMs : 0
            )
            if reliable { offerConfirmedActiveTime(startMs: start, dataNo: dataNo, nowMs: nowMs) }
        }
        return sampleHintMs
    }

    private mutating func correctStreamStartFromArrival(dataNo: Int, receivedAtMs: Int64) {
        let corrected = arrivalStartCorrection.onAcceptedLive(anchorStartMs: persisted.streamStartMs, dataNo: dataNo, receivedAtMs: receivedAtMs)
        if corrected <= 0 { return }
        persisted.streamStartMs = corrected
    }

    /// Two independent live anchors that agree commit an activation start; a replay of one counter is not
    /// corroboration and an impossible start is refused.
    private mutating func offerConfirmedActiveTime(startMs: Int64, dataNo: Int, nowMs: Int64) {
        if startMs <= 0 || activeTimeMs > 0 { return }
        if startMs > nowMs || nowMs - startMs > OttaiConstants.extendedLifetimeMs { return }
        if pendingConfirmedStartMs <= 0 {
            pendingConfirmedStartMs = startMs
            pendingConfirmedDataNo = dataNo
            return
        }
        if dataNo == pendingConfirmedDataNo { return }
        if abs(pendingConfirmedStartMs - startMs) <= OttaiTiming.confirmedStartAgreementMs {
            if dataNo < pendingConfirmedDataNo { return }
            activeTimeMs = startMs
            persisted.confirmedActiveTimeMs = startMs
            return
        }
        pendingConfirmedStartMs = startMs
        pendingConfirmedDataNo = dataNo
    }

    // MARK: counters

    private mutating func repairAheadLastDataNoIfNeeded(acceptedDataNo: Int, live: Bool) {
        if !live || !OttaiTiming.isPersistedDataNoAheadOfLive(previousDataNo: persisted.lastDataNo, liveDataNo: acceptedDataNo) { return }
        persisted.lastDataNo = acceptedDataNo - 1
    }

    private mutating func noteSeenDataNo(_ dataNo: Int) {
        if dataNo <= persisted.lastDataNo { return }
        persisted.lastDataNo = dataNo
    }

    // MARK: continuity gate

    private mutating func rememberAcceptedReading(_ reading: OttaiReading, mmol: Float, sampleMs: Int64) {
        recentlyRejected.remove(reading.record.dataNo)
        noteContinuityEvaluated(dataNo: reading.record.dataNo, sampleMs: sampleMs)
        // The excursion baseline only ever moves forward: a late history record must not replace it.
        if persisted.lastAcceptedDataNo >= 0 && reading.record.dataNo < persisted.lastAcceptedDataNo { return }
        persisted.lastAcceptedDataNo = reading.record.dataNo
        persisted.lastAcceptedSampleMs = sampleMs
        persisted.lastAcceptedMmol = mmol
        persisted.lastAcceptedRawCurrent = reading.record.rawCurrent
        consecutiveContinuityRejects = 0
    }

    private mutating func noteContinuityEvaluated(dataNo: Int, sampleMs: Int64) {
        if dataNo < lastEvaluatedDataNo { return }
        lastEvaluatedDataNo = dataNo
        lastEvaluatedSampleMs = sampleMs
    }

    private func continuityRejectReason(
        _ reading: OttaiReading, mmol: Float, sampleMs: Int64, live: Bool, batch: [OttaiReading], batchIndex: Int
    ) -> String? {
        // The baseline only advances on an accepted sample, so after a bounded run of refusals the gate
        // yields and re-baselines onto the next sample instead of refusing a genuine level change forever.
        if consecutiveContinuityRejects >= OttaiTiming.maxConsecutiveContinuityRejects { return nil }
        let dataNo = reading.record.dataNo
        let adjacent = OttaiTiming.isAdjacentSample(
            previousDataNo: lastEvaluatedDataNo, previousSampleMs: lastEvaluatedSampleMs, dataNo: dataNo, sampleMs: sampleMs
        )
        if adjacent && OttaiOutputFilter.isOneMinuteRawExcursion(
            candidateMmol: mmol, candidateRaw: reading.record.rawCurrent,
            baselineMmol: persisted.lastAcceptedMmol, baselineRaw: persisted.lastAcceptedRawCurrent
        ) {
            return "continuity-prev"
        }
        if !live && isImmediatelyBeforeLastAccepted(dataNo: dataNo, sampleMs: sampleMs) &&
            OttaiOutputFilter.isOneMinuteRawExcursion(
                candidateMmol: mmol, candidateRaw: reading.record.rawCurrent,
                baselineMmol: persisted.lastAcceptedMmol, baselineRaw: persisted.lastAcceptedRawCurrent
            ) {
            return "continuity-next"
        }
        if !live, let reason = historyIsolatedSpikeReason(batch: batch, batchIndex: batchIndex, candidate: reading, candidateMmol: mmol) {
            return reason
        }
        return nil
    }

    private func isImmediatelyBeforeLastAccepted(dataNo: Int, sampleMs: Int64) -> Bool {
        let nextDataNo = persisted.lastAcceptedDataNo
        if nextDataNo < 0 { return false }
        let gap = nextDataNo - dataNo
        if gap >= 1 && gap <= 2 { return true }
        let nextMs = persisted.lastAcceptedSampleMs
        if nextMs <= 0 || sampleMs >= nextMs { return false }
        let delta = nextMs - sampleMs
        return delta >= 1 && delta <= 2 * OttaiTiming.recordIntervalMs + 15_000
    }

    private func historyIsolatedSpikeReason(batch: [OttaiReading], batchIndex: Int, candidate: OttaiReading, candidateMmol: Float) -> String? {
        let previous = neighborSample(batch, start: batchIndex - 1, step: -1)
        let next = neighborSample(batch, start: batchIndex + 1, step: 1)
        let dataNo = candidate.record.dataNo
        var previousAdjacent = false
        if let previous = previous { previousAdjacent = dataNo - previous.dataNo >= 1 && dataNo - previous.dataNo <= 2 }
        var nextAdjacent = false
        if let next = next { nextAdjacent = next.dataNo - dataNo >= 1 && next.dataNo - dataNo <= 2 }

        if previousAdjacent && nextAdjacent, let previous = previous, let next = next {
            let neighborsAgree = abs(previous.mmol - next.mmol) < OttaiOutputFilter.singleSampleDeltaMmol
            if neighborsAgree &&
                OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: candidateMmol, candidateRaw: candidate.record.rawCurrent, baselineMmol: previous.mmol, baselineRaw: previous.rawCurrent) &&
                OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: candidateMmol, candidateRaw: candidate.record.rawCurrent, baselineMmol: next.mmol, baselineRaw: next.rawCurrent) {
                return "history-isolated"
            }
        }
        if !previousAdjacent && nextAdjacent && dataNo <= 5, let next = next,
           OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: candidateMmol, candidateRaw: candidate.record.rawCurrent, baselineMmol: next.mmol, baselineRaw: next.rawCurrent) {
            return "history-start"
        }
        return nil
    }

    private func neighborSample(_ batch: [OttaiReading], start: Int, step: Int) -> NeighborSample? {
        var index = start
        while index >= 0 && index < batch.count {
            let reading = batch[index]
            if reading.valid {
                let mmol = Float(reading.adjustGlucose)
                if OttaiOutputFilter.hardRejectReason(reading.record, mmol: mmol) == nil {
                    return NeighborSample(dataNo: reading.record.dataNo, mmol: mmol, rawCurrent: reading.record.rawCurrent)
                }
            }
            index += step
        }
        return nil
    }
}

// MARK: - History requests

/// One requested history window: its bounds, the state of each record and the watchdog budget.
struct OttaiHistoryWindow: Equatable {

    /// Never arrived: a lost or undecryptable frame inside the window.
    static let missing: UInt8 = 0
    /// Arrived but could not be judged yet.
    static let deferred: UInt8 = 1
    /// Stored, or refused on its own merits.
    static let settled: UInt8 = 2

    let start: Int
    let endExclusive: Int
    var retries = 0
    var bestDataNo = -1
    private(set) var states: [UInt8]

    init?(start: Int, endExclusive: Int) {
        guard endExclusive > start && start >= 0 else { return nil }
        self.start = start
        self.endExclusive = endExclusive
        self.states = [UInt8](repeating: Self.missing, count: endExclusive - start)
    }

    func covers(start: Int, endExclusive: Int) -> Bool {
        return start == self.start && endExclusive == self.endExclusive
    }

    func contains(_ dataNo: Int) -> Bool {
        return dataNo >= start && dataNo < endExclusive
    }

    mutating func mark(_ dataNos: [Int], state: UInt8) {
        for dataNo in dataNos {
            let index = dataNo - start
            if index >= 0 && index < states.count && states[index] < state { states[index] = state }
        }
    }
}

/// JugglucoNG's history request: the window the sensor is asked for, cut into chunks of 270 records,
/// one chunk in flight at a time, a watchdog that asks again three times and then moves on.
struct OttaiHistoryChain: Equatable {

    static let maxRequestRecords = 0xFFFF
    static let chunkRecords = 270
    static let chunkDelaySeconds: TimeInterval = 0.75
    static let requestCooldownSeconds: TimeInterval = 60
    static let pageTimeoutSeconds: TimeInterval = 12
    static let maxRetries = 3
    /// The newest records asked for when a link has nothing before them (JugglucoNG `RECENT_HISTORY_RECORDS`).
    static let recentRecords = 60
    /// How far back a first run reaches: a day, a limit of this fork (JugglucoNG pulls everything it lacks).
    static let initialBackfillRecords = 1440

    /// The 4 byte write: first record and record count, both 16 bit little endian.
    static func requestPayload(start: Int, count: Int) -> [UInt8] {
        return [UInt8(start & 0xFF), UInt8((start >> 8) & 0xFF), UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF)]
    }

    private(set) var window: OttaiHistoryWindow?
    private(set) var pendingReason: String?
    private(set) var pendingNextStart = 0
    private(set) var pendingEndExclusive = 0
    /// First record of the chunked request that is running, -1 when none.
    private(set) var chainStart = -1

    var isIdle: Bool { return window == nil && pendingReason == nil }

    /// Plans a request for `count` records from `start`: returns the first chunk to write and keeps the rest
    /// pending. Nil when the request is not valid.
    mutating func begin(reason: String, start: Int, count: Int) -> (start: Int, count: Int)? {
        guard start >= 0, count > 0, count <= Self.maxRequestRecords else { return nil }
        clear()
        let first = min(count, Self.chunkRecords)
        guard let window = OttaiHistoryWindow(start: start, endExclusive: start + first) else { return nil }
        self.window = window
        if first < count {
            pendingReason = reason
            pendingNextStart = start + first
            pendingEndExclusive = start + count
            chainStart = start
        }
        return (start, first)
    }

    /// The next chunk once the window before it closed.
    mutating func nextChunk() -> (start: Int, count: Int)? {
        guard window == nil, pendingReason != nil else { return nil }
        let remaining = pendingEndExclusive - pendingNextStart
        if remaining <= 0 {
            clear()
            return nil
        }
        let count = min(remaining, Self.chunkRecords)
        let start = pendingNextStart
        guard let window = OttaiHistoryWindow(start: start, endExclusive: start + count) else {
            clear()
            return nil
        }
        self.window = window
        pendingNextStart = start + count
        if pendingNextStart >= pendingEndExclusive {
            pendingReason = nil
            pendingNextStart = 0
            pendingEndExclusive = 0
            chainStart = -1
        }
        return (start, count)
    }

    enum FrameOutcome: Equatable {
        /// No window is in flight, or the frame holds nothing of it.
        case ignored
        /// A part of the window: the watchdog restarts.
        case partial
        /// The sensor reached the end of the window and another chunk is waiting.
        case windowCompleteMoreChunks
        /// The sensor reached the end of the window and nothing is left to ask.
        case chainDone
    }

    /// JugglucoNG `continueHistoryAfterPayload`: `arrived` are the plausible records of one history frame and
    /// `settled` those of them that were stored or refused on their own merits.
    mutating func frameArrived(arrived: [Int], settled: [Int]) -> FrameOutcome {
        guard var window = window else { return pendingReason != nil ? .windowCompleteMoreChunks : .ignored }
        if arrived.isEmpty { return .ignored }
        let inWindow = arrived.filter { window.contains($0) }
        window.mark(inWindow, state: OttaiHistoryWindow.deferred)
        window.mark(settled, state: OttaiHistoryWindow.settled)
        guard let maxDataNo = inWindow.max() else {
            self.window = window
            return .partial
        }
        window.retries = OttaiTiming.historyRetriesAfterFrame(retries: window.retries, frameMaxDataNo: maxDataNo, chunkBestDataNo: window.bestDataNo)
        if maxDataNo > window.bestDataNo { window.bestDataNo = maxDataNo }
        if maxDataNo + 1 < window.endExclusive {
            self.window = window
            return .partial
        }
        self.window = nil
        if pendingReason == nil {
            clear()
            return .chainDone
        }
        return .windowCompleteMoreChunks
    }

    enum WatchdogAction: Equatable {
        case nothingInFlight
        /// Ask for the same window again.
        case retry(start: Int, count: Int, attempt: Int)
        /// The retries are spent: the window is given up and the chain moves on (`moreChunks`).
        case giveUp(moreChunks: Bool)
    }

    mutating func watchdogFired() -> WatchdogAction {
        guard var window = window else { return .nothingInFlight }
        if window.retries < Self.maxRetries {
            window.retries += 1
            self.window = window
            return .retry(start: window.start, count: window.endExclusive - window.start, attempt: window.retries)
        }
        self.window = nil
        let more = pendingReason != nil
        if !more { clear() }
        return .giveUp(moreChunks: more)
    }

    /// The window was closed without a frame (an empty answer, a misframed frame): the chain moves on.
    mutating func abandonWindow() -> Bool {
        window = nil
        if pendingReason == nil {
            clear()
            return false
        }
        return true
    }

    mutating func clear() {
        window = nil
        pendingReason = nil
        pendingNextStart = 0
        pendingEndExclusive = 0
        chainStart = -1
    }

    /// Percent of a running chunk chain that has been requested, or -1 (JugglucoNG `historyBackfillPercent`).
    static func historyBackfillPercent(chainStart: Int, nextStart: Int, endExclusive: Int) -> Int {
        if chainStart < 0 || endExclusive <= chainStart { return -1 }
        let total = endExclusive - chainStart
        let done = min(max(nextStart - chainStart, 0), total)
        return min(max(done * 100 / total, 0), 99)
    }

    var percentAsked: Int {
        return Self.historyBackfillPercent(chainStart: chainStart, nextStart: pendingNextStart, endExclusive: pendingEndExclusive)
    }
}
