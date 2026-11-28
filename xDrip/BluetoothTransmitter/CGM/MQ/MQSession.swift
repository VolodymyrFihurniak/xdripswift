//
//  MQSession.swift
//  xdrip
//
//  The session logic of the MQ / Glutec CGM driver without Bluetooth: how a burst of packets becomes
//  readings, how the slope K and offset B are kept and recomputed, how a fingerstick reference or
//  the factory sensitivity seeds the slope, and the small policies around it (link activity, session
//  start estimate, restore and cloud history timing). Ported from the JugglucoNG `drivers/mq`
//  package (`MQBleManager` session handling, `MQLinkPolicy`, `MQSessionTiming`,
//  `MQSessionRestorePolicy`, `MQCloudHistoryTiming`; GPL-3.0, see THIRD_PARTY_NOTICES.md).
//  The expected values in `MQSessionTests` come from running that logic on the JVM.
//
//  Never tried on a real sensor.
//

import Foundation

// MARK: - Policies

/// JugglucoNG `MQLinkPolicy`.
enum MQLinkPolicy {

    /// Whether a connection still shows life: a frame since it was established is judged against
    /// `frameTimeoutMs`, no frame yet against `firstFrameTimeoutMs`.
    static func hasRecentActivity(
        nowMs: Int64,
        connectedAtMs: Int64,
        lastFrameAtMs: Int64,
        firstFrameTimeoutMs: Int64,
        frameTimeoutMs: Int64
    ) -> Bool {
        let hasFrame = lastFrameAtMs >= connectedAtMs && lastFrameAtMs > 0
        let since = hasFrame ? lastFrameAtMs : connectedAtMs
        let timeout = hasFrame ? frameTimeoutMs : firstFrameTimeoutMs
        return since > 0 && nowMs - since < timeout
    }
}

/// JugglucoNG `MQSessionTiming`.
enum MQSessionTiming {

    /// Estimate only: a running transmitter's packet counter survives app resets, so the session
    /// start is the time of a packet minus its number of intervals.
    static func estimateStartMs(receivedAtMs: Int64, newestPacket: Int, intervalMinutes: Int) -> Int64? {
        if receivedAtMs <= 0 || newestPacket < 1 || newestPacket >= 15000 || intervalMinutes <= 0 { return nil }
        let start = receivedAtMs - Int64(newestPacket) * Int64(intervalMinutes) * 60_000
        return start > 0 ? start : nil
    }

    /// Keeps a real start, repairs a connection-time fallback that contradicts the transmitter's
    /// age by more than two intervals.
    static func reconcileStartMs(existingStartMs: Int64, receivedAtMs: Int64, newestPacket: Int, intervalMinutes: Int) -> Int64 {
        guard let estimate = estimateStartMs(receivedAtMs: receivedAtMs, newestPacket: newestPacket, intervalMinutes: intervalMinutes) else {
            return existingStartMs
        }
        if existingStartMs <= 0 || existingStartMs > estimate + 2 * Int64(intervalMinutes) * 60_000 {
            return estimate
        }
        return existingStartMs
    }
}

/// JugglucoNG `MQSessionRestorePolicy.canRestore`: a vendor cloud snapshot may be restored only for
/// the same transmitter serial and while the session started inside the rated lifetime. The
/// fork has no cloud snapshot, so nothing calls this; it is kept (and tested) for parity.
enum MQSessionRestorePolicy {

    static func canRestore(requestedBleId: String?, snapshotBleId: String?, startAtMs: Int64?, nowMs: Int64) -> Bool {
        let requested = MQVendorIdentity.bleId(requestedBleId) ?? ""
        let actual = MQVendorIdentity.bleId(snapshotBleId) ?? ""
        if requested.trimmingCharacters(in: .whitespaces).isEmpty || requested != actual { return false }
        guard let start = startAtMs else { return false }
        let lifetimeMs = Int64(MQConstants.ratedLifetimeDays) * 24 * 60 * 60 * 1000
        return start > 0 && start <= nowMs && nowMs - start < lifetimeMs
    }
}

/// A glucose point of the vendor's cloud history.
struct MQBootstrapHistoryPoint: Equatable {
    var timestampMs: Int64
    var packetIndex: Int
    var glucoseMgdl: Float
}

/// JugglucoNG `MQCloudHistoryTiming`: recovers the timestamps of a cloud session that was created
/// after the transmitter's counter already started. The fork never receives cloud history, so
/// nothing calls this; it is kept (and tested) for parity.
enum MQCloudHistoryTiming {

    struct Anchor: Equatable {
        var packetIndex: Int
        var receivedAtMs: Int64
    }

    struct Prepared: Equatable {
        var history: [MQBootstrapHistoryPoint]
        var deferred = false
        var estimated = false
    }

    static func prepare(history: [MQBootstrapHistoryPoint], anchor: Anchor?, nowMs: Int64, intervalMinutes: Int) -> Prepared {
        if !history.contains(where: { $0.timestampMs > nowMs + 60_000 }) { return Prepared(history: history) }
        guard let anchor = anchor else { return Prepared(history: [], deferred: true) }
        let intervalMs = Int64(intervalMinutes) * 60_000
        // Never map a different or newer packet cycle into the live session, or infer a timeline from
        // one point.
        if intervalMs <= 0 || !(1..<15000).contains(anchor.packetIndex)
            || anchor.receivedAtMs <= 0 || anchor.receivedAtMs > nowMs + 60_000
            || Set(history.map { $0.packetIndex }).count < 2
            || history.contains(where: { !(1...anchor.packetIndex).contains($0.packetIndex) }) {
            return Prepared(history: [])
        }
        let origins = history.map { $0.timestampMs - Int64($0.packetIndex) * intervalMs }
        // The observed server bug assigns cloud start + packet * interval: do not reinterpret
        // arbitrary future dates or a batch that spans several cycles.
        guard let newestOrigin = origins.max(), let oldestOrigin = origins.min(), newestOrigin - oldestOrigin <= 60_000 else {
            return Prepared(history: [])
        }
        let liveOrigin = anchor.receivedAtMs - Int64(anchor.packetIndex) * intervalMs
        if liveOrigin <= 0 || oldestOrigin - liveOrigin <= 2 * intervalMs {
            return Prepared(history: [])
        }
        let shifted = history.map { point -> MQBootstrapHistoryPoint in
            var copy = point
            copy.timestampMs = liveOrigin + Int64(point.packetIndex) * intervalMs
            return copy
        }
        return Prepared(history: shifted, estimated: true)
    }
}

// MARK: - Parameters

/// What the vendor server hands the official app and JugglucoNG hands its algorithm: the algorithm
/// version, the packages per session, the multiplier and the normalised factory sensitivity (the
/// seed for the slope). The fork has no server, so these are the defaults or what the user entered.
struct MQAlgorithmParameters: Codable, Equatable {
    var algorithmVersion: Int = MQConstants.algoDefaultVersion
    var packages: Int = MQConstants.algoDefaultPackages
    /// Stored as Float like JugglucoNG's preferences; read through `MQAlgorithm.decimalParameter`.
    var multiplier: Float = Float(MQConstants.algoDefaultMultiplier)
    /// The normalised factory sensitivity; 0 when unknown.
    var sensitivitySeed: Float = 0
}

/// How the sensitivity the user typed relates to the one the algorithm needs. The vendor server tells
/// JugglucoNG with a flag per transmitter (`transmitter10`); the fork has no server, so the user says.
enum MQSensitivityScale: Int, Codable, CaseIterable {
    /// Not known: the typed sensitivity is not used (a wrong scale gives a slope ten times off).
    case unknown = 0
    /// The vendor flag is 0: the sensitivity is used as typed.
    case asEntered = 1
    /// The vendor flag is 1: the sensitivity is multiplied by ten and cut to one decimal.
    case timesTen = 2

    /// The vendor's `transmitter10` flag, nil while the scale is not known.
    var transmitter10: Int? {
        switch self {
        case .unknown: return nil
        case .asEntered: return 0
        case .timesTen: return 1
        }
    }
}

/// What the user can tell the driver about the sensor without the vendor server. `revision` counts
/// the changes that matter to the algorithm: a changed configuration discards the solved slope and
/// offset so the next packets start from the new values (JugglucoNG does the same for a refreshed
/// vendor bootstrap).
struct MQConfiguration: Codable, Equatable {
    /// The sensitivity of the sensor code as typed, nil when none was entered.
    var sensitivity: Float?
    var scale: MQSensitivityScale = .unknown
    var algorithmVersion: Int = MQConstants.algoDefaultVersion
    var packages: Int = MQConstants.algoDefaultPackages
    var multiplier: Float = Float(MQConstants.algoDefaultMultiplier)
    var revision: Int = 0

    /// Typing guards only; the vendor documents no limits.
    static let algorithmVersions = [0, 1]
    static let packagesRange = 1...2000
    static let multiplierRange: ClosedRange<Float> = 0.5...3.0
    static let sensitivityRange: ClosedRange<Float> = 0.1...99.9

    /// The algorithm inputs; the seed is 0 until a sensitivity and its scale are both known.
    var parameters: MQAlgorithmParameters {
        let seed = MQBootstrapSeed.normalizeSensitivity(raw: sensitivity, transmitter10: scale.transmitter10) ?? 0
        return MQAlgorithmParameters(
            algorithmVersion: algorithmVersion,
            packages: packages,
            multiplier: multiplier,
            sensitivitySeed: seed
        )
    }

    /// Whether the sensitivity can seed a slope (a seed below the plausible slope range cannot).
    var hasUsableSeed: Bool {
        return MQSessionTracker.hasValidSlopeSeed(MQAlgorithm.decimalParameter(parameters.sensitivitySeed))
    }

    mutating func noteChanged() {
        revision += 1
    }
}

// MARK: - Burst buffer

/// JugglucoNG's pending burst: records keyed by packet index (a later record of the same packet
/// replaces the earlier one), flushed together so a replay of several frames is processed once and
/// in packet order.
struct MQBurstBuffer: Equatable {

    private(set) var records = [Int: MQBgRecord]()
    private(set) var receivedAtMs = [Int: Int64]()

    var isEmpty: Bool { return records.isEmpty }

    mutating func add(_ newRecords: [MQBgRecord], receivedAtMs time: Int64) {
        for record in newRecords {
            records[record.packetIndex] = record
            receivedAtMs[record.packetIndex] = time
        }
    }

    mutating func clear() {
        records.removeAll()
        receivedAtMs.removeAll()
    }

    /// The buffered records in packet order, anchored at the newest packet and the time its frame
    /// arrived. Empties the buffer; nil when it was empty.
    mutating func flush() -> (records: [MQBgRecord], anchorPacketIndex: Int, anchorMs: Int64)? {
        guard let newest = records.keys.max() else { return nil }
        let sorted = records.values.sorted { $0.packetIndex < $1.packetIndex }
        let anchorMs = receivedAtMs[newest] ?? 0
        clear()
        return (sorted, newest, anchorMs)
    }
}

// MARK: - Session tracker

/// One reading produced by the algorithm.
struct MQReading: Equatable {
    let record: MQBgRecord
    let sampleMs: Int64
    let result: MQAlgorithm.Result
}

/// The outcome of a fingerstick reference.
enum MQCalibrationOutcome: Equatable {
    /// The value was not positive.
    case rejected
    /// Kept for the next live packet (no recent packet, or none above packet 8 yet).
    case queued
    /// The latest packet was recomputed but gave no usable value.
    case noResult
    /// The latest packet was recomputed with the reference; K and B are updated.
    case applied(MQReading)
}

/// The persisted algorithm state of a session (K, B, the last processed current, the highest packet
/// delivered, the session start) and the runtime bookkeeping around it. JugglucoNG keeps the same
/// values in `MQBleManager` and `MQRegistry`.
struct MQSessionTracker: Codable, Equatable {

    // persisted by JugglucoNG as well
    var kValue: Float = 0
    var bValue: Float = 0
    var lastProcessed: Double = 0
    var lastPacketIndex: Int = -1
    var sensorStartAtMs: Int64 = 0

    // runtime
    var pendingReferenceTimes10Mmol: Double = 0
    var packetCount: Int = 0
    var lastObservedPacketIndex: Int = -1
    var lastRecordReceivedAtMs: Int64 = 0
    var lastRawCurrent: Double = 0
    var lastBatteryRaw: Int = -1
    var lastGlucoseAtMs: Int64 = 0
    var lastGlucoseMgdlTimes10: Int = 0

    // MARK: restore and reset

    /// JugglucoNG `restoreFromPersistence`: what a fresh process takes over from the stored state.
    /// An invalid persisted K (not above 1) is discarded with its B, the last processed current is
    /// never negative, and everything that only describes the previous run starts empty.
    mutating func prepareForNewRun() {
        if kValue != 0 && !Self.hasValidSlopeSeed(MQAlgorithm.decimalParameter(kValue)) {
            kValue = 0
            bValue = 0
        }
        lastProcessed = max(0, lastProcessed)
        pendingReferenceTimes10Mmol = 0
        packetCount = 0
        lastObservedPacketIndex = max(-1, lastPacketIndex)
        lastRecordReceivedAtMs = 0
        lastRawCurrent = 0
        lastBatteryRaw = -1
        lastGlucoseAtMs = 0
        lastGlucoseMgdlTimes10 = 0
    }

    /// JugglucoNG `clearVolatileSessionState`: a new session starts from nothing (the factory
    /// sensitivity and the algorithm parameters live outside the tracker and stay).
    mutating func clearSession() {
        sensorStartAtMs = 0
        packetCount = 0
        pendingReferenceTimes10Mmol = 0
        lastPacketIndex = -1
        lastObservedPacketIndex = -1
        lastRecordReceivedAtMs = 0
        lastRawCurrent = 0
        lastProcessed = 0
        lastGlucoseAtMs = 0
        lastGlucoseMgdlTimes10 = 0
        kValue = 0
        bValue = 0
    }

    /// The configuration changed: the solved slope, offset and smoothing start over, the session
    /// itself (start, delivered packets) stays.
    mutating func resetAlgorithmState() {
        kValue = 0
        bValue = 0
        lastProcessed = 0
    }

    /// Whether a slope is held (solved from a fingerstick or seeded from the sensitivity).
    var hasSlope: Bool {
        return Self.hasValidSlopeSeed(MQAlgorithm.decimalParameter(kValue))
    }

    /// The transmitter says it just started work. When a session was running (packets were
    /// processed) it is superseded and cleared; a start time is set when none is known. Returns
    /// whether a session was superseded.
    @discardableResult
    mutating func noteBeginWork(nowMs: Int64) -> Bool {
        var superseded = false
        if lastPacketIndex >= 0 {
            clearSession()
            superseded = true
        }
        if sensorStartAtMs == 0 {
            sensorStartAtMs = nowMs
            packetCount = 0
        }
        return superseded
    }

    /// Repairs a connection-time session start with the packet counter (`MQSessionTiming`). Returns
    /// whether the start changed.
    @discardableResult
    mutating func reconcileStart(newestPacket: Int?, nowMs: Int64, intervalMinutes: Int) -> Bool {
        guard let newestPacket = newestPacket else { return false }
        let reconciled = MQSessionTiming.reconcileStartMs(
            existingStartMs: sensorStartAtMs, receivedAtMs: nowMs, newestPacket: newestPacket, intervalMinutes: intervalMinutes
        )
        if reconciled == sensorStartAtMs { return false }
        sensorStartAtMs = reconciled
        return true
    }

    // MARK: glucose

    /// A slope below or at 1 is not plausible for this firmware (and is how a bogus legacy value
    /// looks); a non-finite one cannot be real either (Kotlin would have thrown while truncating it).
    static func hasValidSlopeSeed(_ value: Double) -> Bool {
        return value.isFinite && value > MQConstants.algoMinValidK
    }

    /// Minutes since the session start at the time of the sample, or the vendor default when the
    /// start is unknown or in the future.
    func initTimeMinutes(sampleMs: Int64) -> Double {
        guard sensorStartAtMs > 0 else { return MQConstants.algoDefaultInitTimeMinutes }
        let elapsedMs = sampleMs - sensorStartAtMs
        return elapsedMs > 0 ? Double(elapsedMs) / 60_000.0 : MQConstants.algoDefaultInitTimeMinutes
    }

    private func synthesizeReference(_ record: MQBgRecord, previousProcessed: Double, parameters: MQAlgorithmParameters) -> Double? {
        let seed = MQAlgorithm.decimalParameter(parameters.sensitivitySeed)
        guard Self.hasValidSlopeSeed(seed), record.packetIndex >= Int(MQConstants.algoWarmupPacketThreshold) else { return nil }
        guard let seeded = MQBootstrapSeed.initialReference(
            algorithmVersion: parameters.algorithmVersion,
            packetIndex: record.packetIndex,
            sampleCurrent: record.sampleCurrent,
            previousProcessed: previousProcessed,
            sensitivity: seed,
            packages: parameters.packages,
            multiplier: MQAlgorithm.decimalParameter(parameters.multiplier)
        ) else { return nil }
        let synthetic = Double(seeded.glucoseTimes10Mmol)
        return synthetic > 0 ? synthetic : nil
    }

    /// JugglucoNG `calculateVendorGlucose`: one record through the algorithm. Without a valid slope
    /// the reference comes from a queued fingerstick (after packet 8) or, from packet 19, from the
    /// factory sensitivity; with neither there is no value. Updates K, B and the last processed
    /// current; a fingerstick reference is consumed.
    mutating func calculate(record: MQBgRecord, sampleMs: Int64, parameters: MQAlgorithmParameters) -> MQAlgorithm.Result? {
        let initTimeMinutes = self.initTimeMinutes(sampleMs: sampleMs)
        let previousProcessed = lastProcessed
        let manualReference = (pendingReferenceTimes10Mmol > 0.0 && record.packetIndex > 8) ? pendingReferenceTimes10Mmol : 0.0
        var reference = manualReference
        var seedK = MQAlgorithm.decimalParameter(kValue)
        var seedB = MQAlgorithm.decimalParameter(bValue)

        if !Self.hasValidSlopeSeed(seedK) && reference <= 0.0 {
            guard let synthesized = synthesizeReference(record, previousProcessed: previousProcessed, parameters: parameters) else {
                return nil
            }
            reference = synthesized
            seedK = 0.0
            seedB = 0.0
        } else if !Self.hasValidSlopeSeed(seedK) && reference > 0.0 {
            seedK = 0.0
            seedB = 0.0
        }

        let result = MQAlgorithm.calculateResult(
            algorithmVersion: parameters.algorithmVersion,
            initTimeMinutes: initTimeMinutes,
            packetIndex: Double(record.packetIndex),
            sampleCurrent: Double(record.sampleCurrent),
            previousReviseCurrent2: previousProcessed,
            kValue: seedK,
            referenceBgTimes10Mmol: reference,
            bValue: seedB,
            packages: Double(parameters.packages),
            multiplier: MQAlgorithm.decimalParameter(parameters.multiplier)
        )
        lastProcessed = result.reviseCurrent2
        if Self.hasValidSlopeSeed(result.kValue) {
            kValue = Float(result.kValue)
        }
        bValue = Float(result.bValue)
        if manualReference > 0.0 {
            pendingReferenceTimes10Mmol = 0.0
        }
        return result.glucoseTimes10Mmol > 0 ? result : nil
    }

    /// JugglucoNG `processBgRecords`: the records of one flushed burst, in packet order. Packets at or
    /// below the highest delivered one are skipped; a record is timed from the newest packet of the
    /// burst (`anchor`) minus its number of intervals. `lastPacketIndex` advances only for packets
    /// that produced a reading.
    mutating func processBurst(
        _ records: [MQBgRecord],
        anchorPacketIndex: Int,
        anchorMs: Int64,
        intervalMs: Int64,
        parameters: MQAlgorithmParameters
    ) -> [MQReading] {
        guard !records.isEmpty else { return [] }
        let previousLastPacketIndex = lastPacketIndex
        var highestProcessedPacketIndex = lastPacketIndex
        var readings = [MQReading]()
        for record in records {
            if previousLastPacketIndex >= 0 && record.packetIndex <= previousLastPacketIndex { continue }
            packetCount += 1
            lastObservedPacketIndex = max(lastObservedPacketIndex, record.packetIndex)
            lastRawCurrent = Double(record.sampleCurrent)
            lastBatteryRaw = record.batteryRaw
            let packetDelta = max(0, anchorPacketIndex - record.packetIndex)
            let sampleMs = anchorMs - Int64(packetDelta) * intervalMs
            lastRecordReceivedAtMs = max(lastRecordReceivedAtMs, sampleMs)
            if record.marker != MQConstants.bgRecordMarker { continue }
            guard let result = calculate(record: record, sampleMs: sampleMs, parameters: parameters) else { continue }
            if sampleMs >= lastGlucoseAtMs {
                lastGlucoseAtMs = sampleMs
                lastGlucoseMgdlTimes10 = result.mgdlTimes10
            }
            highestProcessedPacketIndex = max(highestProcessedPacketIndex, record.packetIndex)
            readings.append(MQReading(record: record, sampleMs: sampleMs, result: result))
        }
        if highestProcessedPacketIndex != lastPacketIndex {
            lastPacketIndex = highestProcessedPacketIndex
        }
        return readings
    }

    /// JugglucoNG `calibrateSensor` and `applyPendingCalibrationFromLatestSample`: queues a
    /// fingerstick (mg/dL) and, when the latest packet is recent, recomputes it at once with the
    /// reference so K is solved right away.
    mutating func calibrate(glucoseMgDl: Int, nowMs: Int64, frameTimeoutMs: Int64, parameters: MQAlgorithmParameters) -> MQCalibrationOutcome {
        guard glucoseMgDl > 0 else { return .rejected }
        pendingReferenceTimes10Mmol = (Double(glucoseMgDl) / MQConstants.mmolToMgdl) * 10.0
        let sampleMs = lastRecordReceivedAtMs
        let packetIndex = lastObservedPacketIndex
        let sampleCurrent = mqKotlinInt(lastRawCurrent)
        if sampleMs <= 0 || packetIndex < 0 || sampleCurrent <= 0 || nowMs - sampleMs > frameTimeoutMs {
            return .queued
        }
        let battery = max(0, lastBatteryRaw)
        let record = MQBgRecord(
            indexInPacket: 0,
            marker: MQConstants.bgRecordMarker,
            packetIndex: packetIndex,
            sampleCurrent: sampleCurrent,
            batteryRaw: battery,
            recordBytes: [
                UInt8(MQConstants.bgRecordMarker),
                UInt8(packetIndex & 0xFF),
                UInt8((packetIndex >> 8) & 0xFF),
                UInt8(sampleCurrent & 0xFF),
                UInt8((sampleCurrent >> 8) & 0xFF),
                UInt8(battery & 0xFF)
            ]
        )
        guard let result = calculate(record: record, sampleMs: sampleMs, parameters: parameters) else { return .noResult }
        lastPacketIndex = max(lastPacketIndex, record.packetIndex)
        if sampleMs >= lastGlucoseAtMs {
            lastGlucoseAtMs = sampleMs
            lastGlucoseMgdlTimes10 = result.mgdlTimes10
        }
        return .applied(MQReading(record: record, sampleMs: sampleMs, result: result))
    }

    // MARK: session age

    /// Session start plus the rated lifetime, 0 while the start is unknown.
    func officialEndMs(profile: MQProfile = .default) -> Int64 {
        return sensorStartAtMs > 0 ? sensorStartAtMs + profile.ratedLifetimeMs() : 0
    }

    func isExpired(nowMs: Int64, profile: MQProfile = .default) -> Bool {
        let end = officialEndMs(profile: profile)
        return end > 0 && nowMs >= end
    }
}

// MARK: - Calibration input

/// A fingerstick outside this range is almost certainly a typing mistake, and the algorithm turns
/// such a reference into an absurd slope (a reference of 1 mg/dL solves K about 40 times too small).
/// JugglucoNG accepts any positive value; the fork asks for a plausible one.
enum MQCalibrationInput {
    static let minimumMgDl = 40
    static let maximumMgDl = 400

    static func isPlausible(mgdl: Int) -> Bool {
        return mgdl >= minimumMgDl && mgdl <= maximumMgDl
    }
}
