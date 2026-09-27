import Foundation

/// Replays unique sensor history in ascending index order and returns only accepted values
/// in the newest-first order expected by CGMTransmitterDelegate.
struct Sibionics2ReadingBatchProcessor {
    private static let sessionStartTolerance: TimeInterval = 10 * 60

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
        processor: Sibionics2GlucoseProcessor
    ) {
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
        if (firstConnectionWithoutHistory || waitingForHistoryReplay), firstReading.index > 1 {
            replayTargetIndex = max(replayTargetIndex ?? 0, uniqueReadings.last?.index ?? firstReading.index)
            requiresHistoryReplay = true
            if firstConnectionWithoutHistory {
                let pendingState = Sibionics2ReadingState(
                    lastDeliveredIndex: nil,
                    processorSnapshot: processor.snapshot(),
                    sensorStartDate: inferredStartDate,
                    replayTargetIndex: replayTargetIndex.flatMap { UInt16(exactly: $0) }
                )
                readingState = pendingState
                stateStore.save(pendingState, for: deviceIdentifier)
            }
            return []
        }

        let sensorStartDate = readingState?.sensorStartDate ?? inferredStartDate
        let lastIndex = readingState?.lastDeliveredIndex.map { Int($0) } ?? 0
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
                break
            }
            newReadings.append(reading)
            expectedIndex += 1
        }
        guard !newReadings.isEmpty else { return [] }

        var processed: [Sibionics2ProcessedGlucose] = []
        for (position, reading) in newReadings.enumerated() {
            let mode: Sibionics2ProcessingMode = position == newReadings.count - 1 ? .live : .replay
            if let result = processor.process(reading, mode: mode),
               result.glucoseMgDl.isFinite, result.glucoseMgDl > 0, result.glucoseMgDl <= 900 {
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

        guard let newest = processed.max(by: {
            if $0.eventTime == $1.eventTime { return $0.index < $1.index }
            return $0.eventTime < $1.eventTime
        }) else { return [] }

        return processed
            .map { result in
                GlucoseData(
                    timeStamp: result.eventTime,
                    glucoseLevelRaw: result.glucoseMgDl,
                    backfilledAt: result.index == newest.index ? nil : receivedAt
                )
            }
            .sorted {
                if $0.timeStamp == $1.timeStamp {
                    return $0.glucoseLevelRaw > $1.glucoseLevelRaw
                }
                return $0.timeStamp > $1.timeStamp
            }
    }

    private func shouldResetSession(inferredStartDate: Date, firstReadingIndex: Int) -> Bool {
        guard let savedStartDate = readingState?.sensorStartDate else { return false }
        let difference = inferredStartDate.timeIntervalSince(savedStartDate)
        guard difference.isFinite else { return false }

        // The sensor's minute index can drift from wall time by tens of minutes
        // over a long session. A later index alone is not a new sensor.
        let lastIndex = Int(readingState?.lastDeliveredIndex ?? 0)
        let observedAge = Double(max(firstReadingIndex, lastIndex)) * 60
        let driftTolerance = min(6 * 60 * 60, max(Self.sessionStartTolerance, observedAge * 0.01))
        let tolerance = firstReadingIndex > lastIndex
            ? max(2 * 60 * 60, driftTolerance)
            : driftTolerance
        return abs(difference) > tolerance
    }

    private static func sensorStartDate(for reading: Sibionics2RawReading) -> Date {
        reading.eventTime.addingTimeInterval(-TimeInterval(reading.index) * 60)
    }

    private static func isValid(_ reading: Sibionics2RawReading) -> Bool {
        reading.index > 0 && reading.index <= Int(UInt16.max) &&
            reading.eventTime.timeIntervalSince1970.isFinite &&
            reading.temperatureC.isFinite && reading.temperatureC > 0 && reading.temperatureC <= 80 &&
            reading.impedance >= 0 && reading.impedance <= Int(UInt16.max) &&
            reading.rawMmol.isFinite && reading.rawMmol > 0 && reading.rawMmol <= 6553.5
    }
}
