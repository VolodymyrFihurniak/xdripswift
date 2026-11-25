import Foundation

/// Replays unique sensor history in ascending index order and returns only accepted values
/// in the newest-first order expected by CGMTransmitterDelegate.
struct Sibionics2ReadingBatchProcessor {
    private let allowsHistoricalBootstrap: Bool
    private let deviceIdentifier: String
    private let stateStore: Sibionics2ReadingStateStore
    private var processor: Sibionics2GlucoseProcessor
    private var readingState: Sibionics2ReadingState?

    private(set) var requiresHistoryReplay = false
    private var replayTargetIndex: Int?

    var state: Sibionics2ReadingState? { readingState }

    init(
        deviceIdentifier: String,
        stateStore: Sibionics2ReadingStateStore,
        processor: Sibionics2GlucoseProcessor,
        allowsHistoricalBootstrap: Bool = false
    ) {
        self.allowsHistoricalBootstrap = allowsHistoricalBootstrap
        self.deviceIdentifier = deviceIdentifier
        self.stateStore = stateStore
        let savedState = stateStore.load(for: deviceIdentifier)
        var restoredProcessor = processor
        var restoredState = savedState
        if let savedState {
            if let snapshot = savedState.processorSnapshot,
               restoredProcessor.restore(from: snapshot) {
                restoredState = savedState
            } else {
                stateStore.clear(for: deviceIdentifier)
                restoredProcessor.reset()
                restoredState = nil
            }
        }
        let savedCursor = Int(restoredState?.lastDeliveredIndex ?? 0)
        let restoredReplayTarget = restoredState?.replayTargetIndex
            .map { Int($0) }
            .flatMap { $0 > savedCursor ? $0 : nil }
        self.processor = restoredProcessor
        self.readingState = restoredState
        self.replayTargetIndex = restoredReplayTarget
        self.requiresHistoryReplay = restoredReplayTarget != nil
    }

    mutating func process(_ batch: [Sibionics2RawReading], receivedAt: Date) -> [GlucoseData] {
        guard receivedAt.timeIntervalSince1970.isFinite else { return [] }

        let validReadings = batch
            .filter(Self.isValid)
            .sorted {
                if $0.index == $1.index { return $0.eventTime < $1.eventTime }
                return $0.index < $1.index
            }

        guard !validReadings.isEmpty else { return [] }

        var uniqueByIndex: [Int: Sibionics2RawReading] = [:]
        for reading in validReadings where uniqueByIndex[reading.index] == nil {
            uniqueByIndex[reading.index] = reading
        }
        let uniqueReadings = uniqueByIndex.values.sorted { $0.index < $1.index }
        guard let firstReading = uniqueReadings.first else { return [] }

        let inferredStartDate = Self.sensorStartDate(for: firstReading)
        let didResetSession = shouldResetSession(
            inferredStartDate: inferredStartDate,
            firstReadingIndex: firstReading.index
        )
        if didResetSession {
            processor.reset()
            readingState = nil
            replayTargetIndex = nil
            requiresHistoryReplay = false
        }

        let firstConnectionWithoutHistory = readingState == nil
        let waitingForHistoryReplay = readingState?.lastDeliveredIndex == nil &&
            readingState?.processorSnapshot != nil &&
            readingState?.sensorStartDate != nil
        // Chinese history can begin after warmup (the V115G reference starts
        // at index 25). Only a historical response can establish this baseline;
        // an arbitrary current packet must still trigger a history request.
        let canBootstrapHistory = allowsHistoricalBootstrap && firstReading.reindex > 0 &&
            (firstConnectionWithoutHistory || waitingForHistoryReplay)
        if (firstConnectionWithoutHistory || waitingForHistoryReplay), firstReading.index > 1,
           !canBootstrapHistory {
            replayTargetIndex = max(replayTargetIndex ?? 0, uniqueReadings.last?.index ?? firstReading.index)
            requiresHistoryReplay = true
            if firstConnectionWithoutHistory {
                readingState = Sibionics2ReadingState(
                    lastDeliveredIndex: nil,
                    processorSnapshot: processor.snapshot(),
                    sensorStartDate: inferredStartDate
                )
            }
            persistReplayTarget()
            return []
        }

        let sensorStartDate = readingState?.sensorStartDate ?? inferredStartDate
        let lastIndex = readingState?.lastDeliveredIndex.map { Int($0) } ??
            (canBootstrapHistory ? firstReading.index - 1 : 0)
        let pendingReadings = uniqueReadings.filter { $0.index > lastIndex }
        guard !pendingReadings.isEmpty else { return [] }

        // The stock algorithm carries state across every minute. A gap must
        // keep the saved cursor intact so the missing page can be requested.
        var newReadings = [Sibionics2RawReading]()
        var expectedIndex = lastIndex + 1
        for reading in pendingReadings {
            guard reading.index == expectedIndex else {
                replayTargetIndex = max(replayTargetIndex ?? 0, uniqueReadings.last?.index ?? reading.index)
                requiresHistoryReplay = true
                persistReplayTarget()
                break
            }
            newReadings.append(reading)
            expectedIndex += 1
        }
        guard !newReadings.isEmpty else {
            return []
        }

        var processed: [Sibionics2ProcessedGlucose] = []
        for (position, reading) in newReadings.enumerated() {
            let mode: Sibionics2ProcessingMode = position == newReadings.count - 1 ? .live : .replay
            if let result = processor.process(reading, mode: mode),
               result.glucoseMgDl.isFinite,
               result.glucoseMgDl > 0,
               result.glucoseMgDl <= Sibionics2SensorProfile.maximumReportableGlucoseMgDl {
                processed.append(result)
            }
        }

        let latestProcessedIndex = newReadings.last?.index ?? lastIndex
        if let replayTargetIndex, latestProcessedIndex >= replayTargetIndex {
            self.replayTargetIndex = nil
            requiresHistoryReplay = false
        }
        let state = Sibionics2ReadingState(
            lastDeliveredIndex: UInt16(exactly: latestProcessedIndex),
            processorSnapshot: processor.snapshot(),
            sensorStartDate: sensorStartDate,
            replayTargetIndex: replayTargetIndex.flatMap { UInt16(exactly: $0) }
        )
        readingState = state
        stateStore.save(state, for: deviceIdentifier)

        GlucoseUncertaintyStore.record(processed.compactMap { result in
            guard let lower = result.lowerMgDl, let upper = result.upperMgDl else { return nil }
            return GlucoseUncertaintyStore.Entry(date: result.eventTime, mgDl: result.glucoseMgDl, lower: lower, upper: upper)
        })

        guard let newest = processed.max(by: {
            if $0.eventTime == $1.eventTime { return $0.index < $1.index }
            return $0.eventTime < $1.eventTime
        }) else { return [] }

        let corrected = processed
            .map { result in
                let data = GlucoseData(
                    timeStamp: result.eventTime,
                    glucoseLevelRaw: result.glucoseMgDl,
                    backfilledAt: result.index == newest.index ? nil : receivedAt
                )
                return data
            }
            .sorted {
                if $0.timeStamp == $1.timeStamp {
                    return $0.glucoseLevelRaw > $1.glucoseLevelRaw
                }
                return $0.timeStamp > $1.timeStamp
            }
        return corrected
    }

    /// A missing page can be followed by an app restart before any new minute
    /// is processed. Persist the target without advancing the saved cursor.
    private mutating func persistReplayTarget() {
        guard let state = readingState else { return }
        let updated = Sibionics2ReadingState(
            lastDeliveredIndex: state.lastDeliveredIndex,
            processorSnapshot: state.processorSnapshot,
            sensorStartDate: state.sensorStartDate,
            replayTargetIndex: replayTargetIndex.flatMap { UInt16(exactly: $0) }
        )
        readingState = updated
        stateStore.save(updated, for: deviceIdentifier)
    }

    private func shouldResetSession(inferredStartDate: Date, firstReadingIndex: Int) -> Bool {
        guard let savedStartDate = readingState?.sensorStartDate else { return false }
        let difference = inferredStartDate.timeIntervalSince(savedStartDate)
        guard difference.isFinite else { return false }

        // The sensor's minute index can drift from wall time by tens of minutes
        // over a long session. A later index alone is not a new sensor.
        let lastIndex = Int(readingState?.lastDeliveredIndex ?? 0)
        let observedAge = Double(max(firstReadingIndex, lastIndex)) * Sibionics2SensorProfile.sampleInterval
        let driftTolerance = min(
            Sibionics2ConnectionPolicy.maximumSessionStartDrift,
            max(Sibionics2ConnectionPolicy.sessionStartDateTolerance,
                observedAge * Sibionics2ConnectionPolicy.indexAgeDriftRatio)
        )
        let tolerance = firstReadingIndex > lastIndex
            ? max(Sibionics2ConnectionPolicy.minimumForwardProgressDrift, driftTolerance)
            : driftTolerance
        return abs(difference) > tolerance
    }

    private static func sensorStartDate(for reading: Sibionics2RawReading) -> Date {
        reading.eventTime.addingTimeInterval(
            -TimeInterval(reading.index) * Sibionics2SensorProfile.sampleInterval
        )
    }

    /// Only the minute index and time decide history continuity. A minute with an
    /// unusable measurement still advances the cursor (the processor skips it), as in
    /// JugglucoNG; filtering it here left a permanent gap that stalled delivery.
    private static func isValid(_ reading: Sibionics2RawReading) -> Bool {
        reading.index >= Sibionics2ReadingValidationPolicy.minimumIndex &&
            reading.index <= Sibionics2ReadingValidationPolicy.maximumIndex &&
            reading.eventTime.timeIntervalSince1970.isFinite
    }
}

// MARK: - Source journal

/// JugglucoNG `SibionicsSampleJournal` + `SibionicsSourceJournalBackup`: the sensor's raw minutes
/// (index, time, raw current, temperature, impedance) in an append-only file per sensor, so a new
/// sensitivity, glucose model or GS3 setting is recalculated locally instead of downloading the
/// sensor's whole life over Bluetooth again, and so a backup can carry them. Records use
/// JugglucoNG's layout: 36 big-endian bytes (`SJR1`, version 1, index, time ms, raw, temperature,
/// impedance, variant) and a CRC-32. A new sensor session starts a new journal.
enum SibionicsSourceJournal {
    struct Sample: Equatable {
        let index: Int
        let timestampMs: Int64
        let rawMmol: Float
        let temperatureC: Float
        let impedance: Float
        let variantId: Int

        var isValid: Bool {
            index >= 0 && timestampMs > 0 && rawMmol.isFinite && temperatureC.isFinite && impedance.isFinite && variantId >= 0
        }
    }

    static let magic: UInt32 = 0x534A_5231
    static let version: UInt32 = 1
    static let payloadSize = 36
    static let recordSize = payloadSize + 4
    static let directoryName = "sibionics-source"
    private static let queue = DispatchQueue(label: "sibionics.source.journal", qos: .utility)
    private static let sessionTolerance: TimeInterval = 5 * 60

    // MARK: Encoding

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static func encode(_ sample: Sample) -> Data {
        var payload = [UInt8]()
        payload.reserveCapacity(recordSize)
        func put32(_ value: UInt32) { payload += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        put32(magic)
        put32(version)
        put32(UInt32(bitPattern: Int32(truncatingIfNeeded: sample.index)))
        put32(UInt32(truncatingIfNeeded: UInt64(bitPattern: sample.timestampMs) >> 32))
        put32(UInt32(truncatingIfNeeded: UInt64(bitPattern: sample.timestampMs)))
        put32(sample.rawMmol.bitPattern)
        put32(sample.temperatureC.bitPattern)
        put32(sample.impedance.bitPattern)
        put32(UInt32(bitPattern: Int32(truncatingIfNeeded: sample.variantId)))
        put32(crc32(payload))
        return Data(payload)
    }

    /// Every valid record, later records of an index replacing earlier ones; reading stops at the
    /// first damaged record, as JugglucoNG truncates there.
    static func decode(_ data: Data) -> [Sample] {
        let bytes = [UInt8](data)
        var byIndex: [Int: Sample] = [:]
        var offset = 0
        func get32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }
        while offset + recordSize <= bytes.count {
            let payload = Array(bytes[offset..<(offset + payloadSize)])
            guard get32(offset + payloadSize) == crc32(payload), get32(offset) == magic, get32(offset + 4) == version else { break }
            let sample = Sample(index: Int(Int32(bitPattern: get32(offset + 8))),
                                timestampMs: Int64(bitPattern: UInt64(get32(offset + 12)) << 32 | UInt64(get32(offset + 16))),
                                rawMmol: Float(bitPattern: get32(offset + 20)),
                                temperatureC: Float(bitPattern: get32(offset + 24)),
                                impedance: Float(bitPattern: get32(offset + 28)),
                                variantId: Int(Int32(bitPattern: get32(offset + 32))))
            if sample.isValid { byIndex[sample.index] = sample }
            offset += recordSize
        }
        return byIndex.values.sorted { $0.index < $1.index }
    }

    /// JugglucoNG `appendAll`: what changes the journal (a new index, or another value for one;
    /// a known index keeps its first time).
    static func changes(_ incoming: [Sample], existing: [Int: Sample]) -> [Sample] {
        var held = existing
        var result: [Sample] = []
        for sample in incoming where sample.isValid {
            let previous = held[sample.index]
            let normalized = previous.map {
                Sample(index: sample.index, timestampMs: $0.timestampMs, rawMmol: sample.rawMmol, temperatureC: sample.temperatureC,
                       impedance: sample.impedance, variantId: sample.variantId)
            } ?? sample
            guard normalized != previous else { continue }
            held[sample.index] = normalized
            result.append(normalized)
        }
        return result
    }

    /// The samples from the first one on while indices run without a gap.
    static func contiguousRun(_ samples: [Sample]) -> [Sample] {
        var run: [Sample] = []
        for sample in samples.sorted(by: { $0.index < $1.index }) {
            if let last = run.last, sample.index != last.index + 1 { break }
            run.append(sample)
        }
        return run
    }

    static func sample(from reading: Sibionics2RawReading, variant: SibionicsDeviceVariant) -> Sample {
        Sample(index: reading.index, timestampMs: Int64((reading.eventTime.timeIntervalSince1970 * 1000).rounded()),
               rawMmol: Float(reading.rawMmol), temperatureC: Float(reading.temperatureC), impedance: Float(reading.impedance),
               variantId: variant == .sibionics1 ? 1 : 2)
    }

    static func reading(from sample: Sample) -> Sibionics2RawReading {
        Sibionics2RawReading(index: sample.index, eventTime: Date(timeIntervalSince1970: TimeInterval(sample.timestampMs) / 1000),
                             temperatureC: Double(sample.temperatureC), impedance: Int(sample.impedance.rounded()),
                             rawMmol: Double(sample.rawMmol), trend: .notDetermined,
                             // Marked historical, so a Chinese journal that begins after warm-up can seed the cursor.
                             reindex: 1)
    }

    // MARK: Files

    static var directoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileName(for address: String) -> String {
        let safe = address.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        return String(String.UnicodeScalarView(safe)) + ".bin"
    }

    private static func fileURL(for address: String) -> URL? { directoryURL?.appendingPathComponent(fileName(for: address)) }
    private static func sessionKey(_ address: String) -> String { "sibionics2.sourceJournalSession." + address.lowercased() }

    /// Adds the minutes of one batch; a different sensor session starts the journal over.
    static func append(_ readings: [Sibionics2RawReading], sessionStart: Date, address: String, variant: SibionicsDeviceVariant,
                       defaults: UserDefaults = .standard) {
        let samples = readings.map { sample(from: $0, variant: variant) }.filter(\.isValid)
        guard !samples.isEmpty, let url = fileURL(for: address) else { return }
        let key = sessionKey(address)
        let savedStart = defaults.object(forKey: key) as? Date
        let newSession = savedStart.map { abs($0.timeIntervalSince(sessionStart)) > sessionTolerance } ?? true
        if newSession { defaults.set(sessionStart, forKey: key) }
        queue.async {
            if newSession { try? FileManager.default.removeItem(at: url) }
            let existing = Dictionary(uniqueKeysWithValues: load(url: url).map { ($0.index, $0) })
            let changed = changes(samples, existing: existing)
            guard !changed.isEmpty else { return }
            var data = Data()
            changed.forEach { data.append(encode($0)) }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
            // Compact once rewritten indices make the file twice as long as needed (JugglucoNG slack 64).
            let all = load(url: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > (all.count * 2 + 64) * recordSize {
                var compacted = Data()
                all.forEach { compacted.append(encode($0)) }
                try? compacted.write(to: url, options: .atomic)
            }
        }
    }

    private static func load(url: URL) -> [Sample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    /// The journal of `address` when it belongs to the session that began at `sessionStart`.
    static func samples(for address: String, sessionStart: Date?, defaults: UserDefaults = .standard) -> [Sample] {
        guard let url = fileURL(for: address) else { return [] }
        if let sessionStart, let saved = defaults.object(forKey: sessionKey(address)) as? Date,
           abs(saved.timeIntervalSince(sessionStart)) > sessionTolerance { return [] }
        return queue.sync { load(url: url) }
    }

    // MARK: Backup

    /// Every journal file by name, with its session start, for a backup.
    static func exportAll(defaults: UserDefaults = .standard) -> [String: Data] {
        guard let directory = directoryURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        return queue.sync {
            var result: [String: Data] = [:]
            for name in names where name.hasSuffix(".bin") {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name)), !data.isEmpty { result[name] = data }
            }
            return result
        }
    }

    /// JugglucoNG `restore`: merges a backed-up journal; samples the phone already holds win, so
    /// an older backup never loses what the sensor delivered since. Returns the samples added.
    @discardableResult
    static func restore(name: String, data: Data) -> Int {
        guard name.hasSuffix(".bin"), !name.contains("/"), let directory = directoryURL else { return 0 }
        let url = directory.appendingPathComponent(name)
        return queue.sync {
            let imported = decode(data)
            guard !imported.isEmpty else { return 0 }
            let held = Set(load(url: url).map(\.index))
            let added = imported.filter { !held.contains($0.index) }
            guard !added.isEmpty else { return 0 }
            var bytes = (try? Data(contentsOf: url)) ?? Data()
            added.forEach { bytes.append(encode($0)) }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? bytes.write(to: url, options: .atomic)
            return added.count
        }
    }
}
