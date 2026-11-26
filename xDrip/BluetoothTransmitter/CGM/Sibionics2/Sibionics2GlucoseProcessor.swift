//
// Sibionics2GlucoseProcessor.swift
// Stock algorithm bridge and xDrip-facing delivery policy.
//

import Foundation
import Sibionics2Core

/// V115G is the Chinese S1 stock family; S2 and EU S1 use V116A.
enum Sibionics2StockFamily {
    case v115g
    case v116a
}

/// The glucose model applied to the sensor signal. Raw values are JugglucoNG's storage ids.
enum Sibionics2GlucoseModel: Int, CaseIterable {
    /// The manufacturer's algorithm (V116A or V115G).
    case stock = 0
    /// JugglucoNG's Adaptive V1 ("state model"): Kalman models on the vendor's chemical signal,
    /// gated by evidence and pulled back to the stock value; the stock value before minute 120.
    case adaptiveV1 = 2
    /// JugglucoNG's Balanced tracker: the stock value with small quantisation noise smoothed.
    case balanced = 4
    /// JugglucoNG's Responsive estimator: a glucose/velocity estimate with a small trend lead.
    case responsive = 6
    /// JugglucoNG's Adaptive V2: a probabilistic estimator fed by the stock core's
    /// sensor-state-calibrated signal instead of its filtered display value.
    case adaptiveV2 = 8

    var title: String {
        switch self {
        case .stock: return Texts_BluetoothPeripheralView.sibionicsGlucoseModelStock
        case .adaptiveV1: return Texts_BluetoothPeripheralView.sibionicsGlucoseModelAdaptiveV1
        case .balanced: return Texts_BluetoothPeripheralView.sibionicsGlucoseModelBalanced
        case .responsive: return Texts_BluetoothPeripheralView.sibionicsGlucoseModelResponsive
        case .adaptiveV2: return Texts_BluetoothPeripheralView.sibionicsGlucoseModelAdaptiveV2
        }
    }
}

/// Anything whose state crosses the Kotlin boundary as chunked hex.
private protocol SibionicsSnapshotCore: AnyObject {
    func reset()
    func snapshotByteCount() -> Int32
    func snapshotHexChunk(offsetBytes: Int32, lengthBytes: Int32) -> String
    func beginRestoreHex(characterCount: Int32) -> Bool
    func appendRestoreHexChunk(chunk: String) -> Bool
    func finishRestoreHex() -> Bool
}

private protocol SibionicsStockCore: SibionicsSnapshotCore {
    func process(rawMmol: Float, temperatureC: Float, index: Int32) -> Float
    func processAdaptiveV2(estimator: SibionicsAdaptiveV2Facade, temperatureC: Float,
                           impedance: Float, eventTimeMs: Int64) -> Float
    func processAdaptiveV1(model: SibionicsAdaptiveV1Facade, stockMmol: Float, rawMmol: Float, temperatureC: Float,
                           impedance: Float, index: Int32, eventTimeMs: Int64) -> Float
}

extension Sibionics2V116AFacade: SibionicsStockCore {}
extension Sibionics1V115GFacade: SibionicsStockCore {}
extension SibionicsAdaptiveV2Facade: SibionicsSnapshotCore {}
extension SibionicsAdaptiveV1Facade: SibionicsSnapshotCore {}

enum Sibionics2ProcessingMode {
    case live
    case replay
}

struct Sibionics2ProcessedGlucose {
    let glucoseMgDl: Double
    let index: Int
    let eventTime: Date
    let trend: Sibionics2Trend
    /// Adaptive V2's 90 % interval around this value (mg/dL), nil for the stock algorithm.
    var lowerMgDl: Double? = nil
    var upperMgDl: Double? = nil
}

/// Stateful xDrip wrapper for stock correction streams. V115G uses validated
/// rounded raw glucose before its first correction; V116A emits no result then.
struct Sibionics2GlucoseProcessor {
    private var snapshotMagic: [UInt8] {
        stockFamily == .v115g ? [0x53, 0x31, 0x47, 0x50] : [0x53, 0x32, 0x47, 0x50] // S1GP / S2GP
    }
    /// Version 2 is the stock layout; versions 3, 4 and 5 append the Adaptive V2, Balanced and
    /// Responsive state. A snapshot of another model is refused, which replays history with the
    /// selected one.
    private var snapshotVersion: UInt16 {
        switch model {
        case .stock: return 2
        case .adaptiveV2: return 3
        case .balanced: return 4
        case .responsive: return 5
        case .adaptiveV1: return 6
        }
    }
    private static let maximumTrackerSnapshotLength = 256
    private static let maximumCoreHexLength = 16_384
    private static let coreSnapshotChunkByteCount = 256
    private static let mmolToMgDlConversionFactor = 18.0

    private enum Validation {
        static let minimumCandidateMmol: Float = 1.0
        static let maximumCandidateMmol: Float = 50.0
        static let maximumCorrectionDeltaMmol: Float = 40.0
        static let minimumCorrectedMmol: Float = 0.0
    }

    private final class CoreBox {
        let value: SibionicsStockCore
        let adaptive: SibionicsAdaptiveV2Facade?
        let adaptiveV1: SibionicsAdaptiveV1Facade?

        /// Whichever model estimator keeps its own Kotlin state beside the stock core.
        var estimator: SibionicsSnapshotCore? {
            if let adaptive { return adaptive }
            return adaptiveV1
        }

        init(sensitivity: Float, stockFamily: Sibionics2StockFamily, model: Sibionics2GlucoseModel) {
            switch stockFamily {
            case .v115g: value = Sibionics1V115GFacade(sensitivity: sensitivity)
            case .v116a: value = Sibionics2V116AFacade(sensitivity: sensitivity)
            }
            adaptive = model == .adaptiveV2 ? SibionicsAdaptiveV2Facade(sensitivity: sensitivity) : nil
            adaptiveV1 = model == .adaptiveV1 ? SibionicsAdaptiveV1Facade(sensitivity: sensitivity) : nil
        }
    }

    private let stockFamily: Sibionics2StockFamily
    private let model: Sibionics2GlucoseModel
    private let sensitivity: Float
    private let validSensitivity: Bool
    private var coreBox: CoreBox
    private var liveDeltaMmol: Float?
    private var replayDeltaMmol: Float?
    private var lastIndex: Int?
    private var balanced: SibionicsBalancedTracker?
    private var responsive: SibionicsResponsiveEstimator?

    init(sensitivity: Double, stockFamily: Sibionics2StockFamily = .v116a, model: Sibionics2GlucoseModel = .stock) {
        let valid = Sibionics2FactorySensitivity.isSupported(sensitivity)
        self.stockFamily = stockFamily
        self.model = model
        self.validSensitivity = valid
        self.sensitivity = Float(sensitivity)
        self.coreBox = CoreBox(
            sensitivity: valid ? Float(sensitivity) : Float(Sibionics2FactorySensitivity.defaultSensitivity),
            stockFamily: stockFamily, model: model
        )
        self.balanced = model == .balanced ? SibionicsBalancedTracker(sensitivity: Float(sensitivity)) : nil
        self.responsive = model == .responsive ? SibionicsResponsiveEstimator(sensitivity: Float(sensitivity)) : nil
    }

    mutating func process(
        _ reading: Sibionics2RawReading,
        mode: Sibionics2ProcessingMode
    ) -> Sibionics2ProcessedGlucose? {
        guard validSensitivity, isValid(reading),
              lastIndex.map({ reading.index > $0 }) ?? true else { return nil }
        ensureUniqueCore()
        let core = coreBox.value

        let raw = Float(reading.rawMmol)
        let candidate = core.process(
            rawMmol: raw,
            temperatureC: Float(reading.temperatureC),
            index: Int32(reading.index)
        )
        lastIndex = reading.index

        // The estimator has to see every sample the stock core accepted, so it runs before
        // anything can return. Its estimate replaces the stock value whenever it is usable;
        // the stock value (and its deltas) stays the fallback and is never fed back into it.
        var adaptiveMmol: Float?
        var adaptiveBounds: (lower: Float, upper: Float)?
        if let adaptive = coreBox.adaptive {
            let estimate = core.processAdaptiveV2(
                estimator: adaptive,
                temperatureC: Float(reading.temperatureC),
                impedance: Float(reading.impedance),
                eventTimeMs: Int64((reading.eventTime.timeIntervalSince1970 * 1000).rounded())
            )
            if estimate.isFinite,
               estimate > Validation.minimumCandidateMmol,
               estimate <= Validation.maximumCandidateMmol {
                // Full precision, as JugglucoNG emits it since e64e3fd3e: rounding to 0.1 mmol/L left
                // about two minutes in three repeating the previous value. Display still rounds.
                adaptiveMmol = estimate
                let lower = adaptive.latestLower90Mmol(), upper = adaptive.latestUpper90Mmol()
                if lower.isFinite, upper.isFinite, lower > 0, upper >= lower { adaptiveBounds = (lower, upper) }
            }
        }
        let stockMmol = stockDisplayMmol(candidate: candidate, raw: raw, mode: mode)
        // JugglucoNG feeds Balanced and Responsive the stock value (no calibration anchors) and shows
        // their result in its place; they see every minute that has a stock value.
        var trackedMmol: Float?
        if let stockMmol {
            let eventTimeMs = Int64((reading.eventTime.timeIntervalSince1970 * 1000).rounded())
            var value = Float.nan
            if var tracker = balanced {
                value = tracker.process(stockMmol: stockMmol, rawMmol: raw, temperatureC: Float(reading.temperatureC),
                                        impedance: Float(reading.impedance), index: reading.index, eventTimeMs: eventTimeMs)
                balanced = tracker
            } else if var estimator = responsive {
                value = estimator.process(stockMmol: stockMmol, rawMmol: raw, temperatureC: Float(reading.temperatureC),
                                          impedance: Float(reading.impedance), index: reading.index, eventTimeMs: eventTimeMs)
                responsive = estimator
            }
            if let adaptiveV1 = coreBox.adaptiveV1 {
                value = core.processAdaptiveV1(model: adaptiveV1, stockMmol: stockMmol, rawMmol: raw,
                                               temperatureC: Float(reading.temperatureC), impedance: Float(reading.impedance),
                                               index: Int32(reading.index), eventTimeMs: eventTimeMs)
            }
            if value.isFinite, value > Validation.minimumCandidateMmol, value <= Validation.maximumCandidateMmol { trackedMmol = value }
        }
        guard let displayMmol = adaptiveMmol ?? trackedMmol ?? stockMmol else { return nil }

        let mgDl = Double(displayMmol) * Self.mmolToMgDlConversionFactor
        guard mgDl.isFinite,
              mgDl > 0,
              mgDl <= Sibionics2SensorProfile.maximumReportableGlucoseMgDl else { return nil }
        var result = Sibionics2ProcessedGlucose(
            glucoseMgDl: mgDl,
            index: reading.index,
            eventTime: reading.eventTime,
            trend: reading.trend
        )
        if adaptiveMmol != nil, let adaptiveBounds {
            result.lowerMgDl = Double(adaptiveBounds.lower) * Self.mmolToMgDlConversionFactor
            result.upperMgDl = Double(adaptiveBounds.upper) * Self.mmolToMgDlConversionFactor
        }
        return result
    }

    /// The stock value for a sample: the core's correction, or raw glucose carried by the
    /// last stock delta while the core has none for this minute.
    private mutating func stockDisplayMmol(candidate: Float, raw: Float, mode: Sibionics2ProcessingMode) -> Float? {
        if candidate.isFinite,
           candidate > Validation.minimumCandidateMmol,
           candidate <= Validation.maximumCandidateMmol {
            let delta = candidate - raw
            guard delta.isFinite, abs(delta) < Validation.maximumCorrectionDeltaMmol else { return nil }
            switch mode {
            case .live:
                liveDeltaMmol = delta
            case .replay:
                replayDeltaMmol = delta
                // Replay is the newer backfill immediately preceding live.
                liveDeltaMmol = delta
            }
            return candidate
        } else {
            let delta: Float?
            switch mode {
            case .live:
                delta = liveDeltaMmol ?? replayDeltaMmol
            case .replay:
                delta = replayDeltaMmol
            }
            // Only Chinese S1 has a raw startup fallback. Once either stream has
            // a correction, use that stock delta instead of returning to raw.
            let effectiveDelta: Float?
            if let delta {
                effectiveDelta = delta
            } else if stockFamily == .v115g {
                effectiveDelta = liveDeltaMmol ?? replayDeltaMmol ?? 0
            } else {
                effectiveDelta = nil
            }
            guard let effectiveDelta, effectiveDelta.isFinite,
                  abs(effectiveDelta) < Validation.maximumCorrectionDeltaMmol else { return nil }
            let corrected = raw + effectiveDelta
            guard corrected.isFinite,
                  corrected > Validation.minimumCorrectedMmol,
                  corrected <= Validation.maximumCandidateMmol else { return nil }
            return Self.nativeRound(corrected)
        }
    }

    mutating func reset() {
        ensureUniqueCore()
        coreBox.value.reset()
        coreBox.adaptive?.reset()
        coreBox.adaptiveV1?.reset()
        balanced?.reset()
        responsive?.reset()
        liveDeltaMmol = nil
        replayDeltaMmol = nil
        lastIndex = nil
    }

    func snapshot() -> Data {
        guard validSensitivity else { return Data() }
        guard let bytes = Self.snapshotCoreHexBytes(from: coreBox.value),
              !bytes.isEmpty, bytes.count <= Self.maximumCoreHexLength else { return Data() }
        var flags: UInt8 = 0
        if liveDeltaMmol != nil { flags |= 1 }
        if replayDeltaMmol != nil { flags |= 2 }
        if lastIndex != nil { flags |= 4 }
        var adaptiveBytes: [UInt8]?
        if let adaptive = coreBox.estimator {
            guard let hex = Self.snapshotCoreHexBytes(from: adaptive),
                  !hex.isEmpty, hex.count <= Self.maximumCoreHexLength else { return Data() }
            adaptiveBytes = hex
        }

        var data = Data(snapshotMagic)
        data.appendUInt16BE(snapshotVersion)
        data.append(flags)
        // The reserved field is one byte; an untyped literal selects Data.append<Int>.
        data.append(UInt8(0))
        data.appendUInt32BE(sensitivity.bitPattern)
        data.appendUInt32BE(UInt32(lastIndex ?? 0))
        data.appendUInt32BE((liveDeltaMmol ?? 0).bitPattern)
        data.appendUInt32BE((replayDeltaMmol ?? 0).bitPattern)
        data.appendUInt32BE(UInt32(bytes.count))
        data.append(contentsOf: bytes)
        if let adaptiveBytes {
            data.appendUInt32BE(UInt32(adaptiveBytes.count))
            data.append(contentsOf: adaptiveBytes)
        }
        if let trackerBytes = balanced?.snapshot() ?? responsive?.snapshot() {
            data.appendUInt32BE(UInt32(trackerBytes.count))
            data.append(trackerBytes)
        }
        let checksum = Self.checksum(data)
        data.appendUInt32BE(checksum)
        return data
    }

    mutating func restore(from data: Data) -> Bool {
        let headerSize = 28
        let checksumSize = 4
        guard validSensitivity, data.count >= headerSize + checksumSize,
              Array(data.prefix(4)) == snapshotMagic,
              data.uint16BE(at: 4) == snapshotVersion,
              let flags = data.byte(at: 6), (flags & ~UInt8(7)) == 0,
              data.byte(at: 7) == 0,
              data.uint32BE(at: 8) == sensitivity.bitPattern,
              let savedIndex = data.uint32BE(at: 12),
              let liveBits = data.uint32BE(at: 16),
              let replayBits = data.uint32BE(at: 20),
              let coreLength = data.uint32BE(at: 24),
              coreLength > 0, coreLength <= Self.maximumCoreHexLength,
              coreLength % 2 == 0,
              data.count >= headerSize + Int(coreLength) + checksumSize
        else { return false }
        let coreEnd = headerSize + Int(coreLength)
        var adaptiveHexBytes: [UInt8]?
        var trackerBytes: Data?
        if model == .adaptiveV2 || model == .adaptiveV1 {
            guard let adaptiveLength = data.uint32BE(at: coreEnd),
                  adaptiveLength > 0, adaptiveLength <= Self.maximumCoreHexLength,
                  adaptiveLength % 2 == 0,
                  data.count == coreEnd + 4 + Int(adaptiveLength) + checksumSize
            else { return false }
            let start = data.index(data.startIndex, offsetBy: coreEnd + 4)
            adaptiveHexBytes = Array(data[start..<data.index(start, offsetBy: Int(adaptiveLength))])
        } else if model == .balanced || model == .responsive {
            guard let trackerLength = data.uint32BE(at: coreEnd),
                  trackerLength > 0, trackerLength <= Self.maximumTrackerSnapshotLength,
                  data.count == coreEnd + 4 + Int(trackerLength) + checksumSize
            else { return false }
            let start = data.index(data.startIndex, offsetBy: coreEnd + 4)
            trackerBytes = Data(data[start..<data.index(start, offsetBy: Int(trackerLength))])
        } else {
            guard data.count == coreEnd + checksumSize else { return false }
        }

        let checksumOffset = data.count - checksumSize
        guard let storedChecksum = data.uint32BE(at: checksumOffset),
              Self.checksum(Data(data.prefix(checksumOffset))) == storedChecksum
        else { return false }
        let coreHexBytes = Array(data[data.index(data.startIndex, offsetBy: headerSize)..<data.index(data.startIndex, offsetBy: coreEnd)])
        guard coreHexBytes.count == Int(coreLength),
              coreHexBytes.allSatisfy(Self.isHexByte)
        else { return false }

        let restoredIndex: Int?
        if (flags & 4) != 0 {
            guard let value = Int(exactly: savedIndex), value > 0 else { return false }
            restoredIndex = value
        } else {
            guard savedIndex == 0 else { return false }
            restoredIndex = nil
        }
        let liveDelta = Float(bitPattern: liveBits)
        let replayDelta = Float(bitPattern: replayBits)
        guard ((flags & 1) == 0 ? liveBits == 0 : Self.isUsableDelta(liveDelta)),
              ((flags & 2) == 0 ? replayBits == 0 : Self.isUsableDelta(replayDelta))
        else { return false }

        let restored = CoreBox(sensitivity: sensitivity, stockFamily: stockFamily, model: model)
        guard Self.restoreCoreSnapshot(hexBytes: coreHexBytes, into: restored.value) else { return false }
        if let adaptive = restored.estimator {
            guard let adaptiveHexBytes,
                  Self.restoreCoreSnapshot(hexBytes: adaptiveHexBytes, into: adaptive) else { return false }
        }
        var restoredBalanced: SibionicsBalancedTracker?
        var restoredResponsive: SibionicsResponsiveEstimator?
        switch model {
        case .balanced:
            guard let trackerBytes, let tracker = SibionicsBalancedTracker.restored(from: trackerBytes, sensitivity: sensitivity) else { return false }
            restoredBalanced = tracker
        case .responsive:
            guard let trackerBytes, let estimator = SibionicsResponsiveEstimator.restored(from: trackerBytes, sensitivity: sensitivity) else { return false }
            restoredResponsive = estimator
        case .stock, .adaptiveV2, .adaptiveV1:
            break
        }
        balanced = restoredBalanced
        responsive = restoredResponsive
        coreBox = restored
        self.lastIndex = restoredIndex
        self.liveDeltaMmol = (flags & 1) == 0 ? nil : liveDelta
        self.replayDeltaMmol = (flags & 2) == 0 ? nil : replayDelta
        return true
    }

    private static func snapshotCoreHexBytes(from core: SibionicsSnapshotCore) -> [UInt8]? {
        let byteCount = Int(core.snapshotByteCount())
        guard byteCount > 0, byteCount <= maximumCoreHexLength / 2,
              byteCount <= Int(Int32.max) else { return nil }

        var hexBytes: [UInt8] = []
        hexBytes.reserveCapacity(byteCount * 2)
        for offset in stride(from: 0, to: byteCount, by: coreSnapshotChunkByteCount) {
            let chunkByteCount = min(coreSnapshotChunkByteCount, byteCount - offset)
            let chunk = core.snapshotHexChunk(
                offsetBytes: Int32(offset),
                lengthBytes: Int32(chunkByteCount)
            )
            let chunkBytes = Array(chunk.utf8)
            guard chunkBytes.count == chunkByteCount * 2,
                  chunkBytes.allSatisfy(isHexByte) else { return nil }
            hexBytes.append(contentsOf: chunkBytes)
        }
        guard hexBytes.count == byteCount * 2 else { return nil }
        return hexBytes
    }

    private static func restoreCoreSnapshot(hexBytes: [UInt8], into core: SibionicsSnapshotCore) -> Bool {
        guard !hexBytes.isEmpty, hexBytes.count <= maximumCoreHexLength,
              hexBytes.count.isMultiple(of: 2),
              hexBytes.allSatisfy(isHexByte),
              core.beginRestoreHex(characterCount: Int32(hexBytes.count))
        else { return false }

        let chunkCharacterCount = coreSnapshotChunkByteCount * 2
        for offset in stride(from: 0, to: hexBytes.count, by: chunkCharacterCount) {
            let end = min(offset + chunkCharacterCount, hexBytes.count)
            let chunk = String(decoding: hexBytes[offset..<end], as: UTF8.self)
            guard core.appendRestoreHexChunk(chunk: chunk) else { return false }
        }
        return core.finishRestoreHex()
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }

    private func isValid(_ reading: Sibionics2RawReading) -> Bool {
        reading.index >= Sibionics2ReadingValidationPolicy.minimumIndex &&
            reading.index <= Sibionics2ReadingValidationPolicy.maximumIndex &&
            reading.rawMmol.isFinite && reading.rawMmol > 0 &&
            reading.rawMmol <= Sibionics2ReadingValidationPolicy.maximumRawGlucoseMmol &&
            // JugglucoNG passes every finite sensor temperature to the stock core.
            reading.temperatureC.isFinite
    }

    private mutating func ensureUniqueCore() {
        guard !isKnownUniquelyReferenced(&coreBox) else { return }
        let copy = CoreBox(sensitivity: sensitivity, stockFamily: stockFamily, model: model)
        guard let hexBytes = Self.snapshotCoreHexBytes(from: coreBox.value),
              Self.restoreCoreSnapshot(hexBytes: hexBytes, into: copy.value) else { return }
        // A copy whose estimator state cannot be carried over starts the estimator afresh.
        if let adaptive = coreBox.adaptive, let adaptiveCopy = copy.adaptive,
           let adaptiveHex = Self.snapshotCoreHexBytes(from: adaptive) {
            _ = Self.restoreCoreSnapshot(hexBytes: adaptiveHex, into: adaptiveCopy)
        }
        coreBox = copy
    }

    /// FNV-1a detects accidental snapshot corruption; it is not authentication.
    private static func checksum(_ data: Data) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in data {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return hash
    }

    private static func isUsableDelta(_ value: Float) -> Bool {
        value.isFinite && abs(value) < 40
    }

    private static func nativeRound(_ value: Float) -> Float {
        let scaled = value * 10
        return Float(Int(scaled + (value >= 0 ? 0.5 : 0))) / 10
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }

    func uint16BE(at offset: Int) -> UInt16? {
        guard let high = byte(at: offset), let low = byte(at: offset + 1) else { return nil }
        return UInt16(high) << 8 | UInt16(low)
    }

    func uint32BE(at offset: Int) -> UInt32? {
        guard let a = byte(at: offset), let b = byte(at: offset + 1),
              let c = byte(at: offset + 2), let d = byte(at: offset + 3) else { return nil }
        return UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }
}

// MARK: - JugglucoNG Balanced and Responsive models

private extension Float {
    func clamped(_ lower: Float, _ upper: Float) -> Float { Swift.min(Swift.max(self, lower), upper) }
}

/// Shared helpers of JugglucoNG's one-minute trackers, in Float as the Kotlin originals.
private enum SibionicsTrackerMath {
    static func roundTenth(_ value: Float) -> Float {
        guard value.isFinite else { return .nan }
        return Float(Int(value * 10 + 0.5)) / 10
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func elapsedMinutes(eventTimeMs: Int64, lastTimestampMs: Int64, index: Int, lastIndex: Int) -> Float {
        if eventTimeMs > lastTimestampMs && lastTimestampMs > 0 {
            return (Float(eventTimeMs - lastTimestampMs) / 60_000).clamped(0.5, 3)
        }
        if index > lastIndex { return Float(index - lastIndex).clamped(1, 3) }
        return 1
    }
}

/// Fixed binary layout for the trackers' state; Float NaN survives as its bit pattern.
private struct SibionicsTrackerWriter {
    var data = Data()
    mutating func float(_ value: Float) { data.appendUInt32BE(value.bitPattern) }
    mutating func int(_ value: Int) { data.appendUInt32BE(UInt32(bitPattern: Int32(clamping: value))) }
    mutating func int64(_ value: Int64) {
        data.appendUInt32BE(UInt32(truncatingIfNeeded: UInt64(bitPattern: value) >> 32))
        data.appendUInt32BE(UInt32(truncatingIfNeeded: UInt64(bitPattern: value)))
    }
    // A typed byte: an untyped literal here selects Data.append<Int> and writes eight bytes.
    mutating func bool(_ value: Bool) { data.append(UInt8(value ? 1 : 0)) }
}

private struct SibionicsTrackerReader {
    let data: Data
    var offset = 0
    mutating func float() -> Float? {
        guard let bits = data.uint32BE(at: offset) else { return nil }
        offset += 4
        return Float(bitPattern: bits)
    }
    mutating func int() -> Int? {
        guard let bits = data.uint32BE(at: offset) else { return nil }
        offset += 4
        return Int(Int32(bitPattern: bits))
    }
    mutating func int64() -> Int64? {
        guard let high = data.uint32BE(at: offset), let low = data.uint32BE(at: offset + 4) else { return nil }
        offset += 8
        return Int64(bitPattern: UInt64(high) << 32 | UInt64(low))
    }
    mutating func bool() -> Bool? {
        guard let byte = data.byte(at: offset), byte <= 1 else { return nil }
        offset += 1
        return byte == 1
    }
    var isAtEnd: Bool { offset == data.count }
}

/// JugglucoNG `SibionicsBalancedAlgorithmContext`: a bounded one-minute tracker around the stock
/// value that only attenuates small quantisation noise and yields at once to real motion. Its
/// calibration anchors are always empty in JugglucoNG for this model, so they are not ported.
struct SibionicsBalancedTracker {
    private static let baseLevelGain: Float = 0.35
    private static let maxLevelGain: Float = 0.92
    private static let rapidInnovationMmol: Float = 0.8
    private static let trendGain: Float = 0.02
    private static let rawTrendWeight: Float = 0.05
    private static let maxTrendRate: Float = 0.35
    private static let maxTrendInnovation: Float = 1
    private static let minDirectionStep: Float = 0.05
    private static let minRawTrendRate: Float = 0.02
    private static let startupPassthroughSamples = 5
    private static let maxTrackingDistanceMmol: Float = 0.2
    private static let largeStepMmol: Float = 1
    private static let turnStepMmol: Float = 0.15
    private static let lowExactMmol: Float = 3.9
    private static let lowFallGuardMmol: Float = 4.5
    private static let temperatureJumpC: Float = 1.2
    private static let impedanceQualitySlope: Float = 5
    private static let impedanceAnomalyFraction: Float = 0.75
    private static let minSignalQuality: Float = 0.20
    private static let impedanceLearningRate: Float = 0.04
    private static let anomalousImpedanceLearningRate: Float = 0.004

    let sensitivity: Float
    private var initialized = false
    private var level: Float = .nan
    private var trend: Float = 0
    private var lastMeasurement: Float = .nan
    private var lastRaw: Float = .nan
    private var lastTemperature: Float = .nan
    private var impedanceBaseline: Float = .nan
    private var lastTimestampMs: Int64 = 0
    private var lastIndex = -1
    private var samplesSinceReset = 0

    init(sensitivity: Float) {
        self.sensitivity = sensitivity.isFinite && (0.5...3.5).contains(sensitivity) ? sensitivity : 1.27
    }

    mutating func reset() { self = SibionicsBalancedTracker(sensitivity: sensitivity) }

    mutating func process(stockMmol: Float, rawMmol: Float, temperatureC: Float, impedance: Float,
                          index: Int, eventTimeMs: Int64) -> Float {
        guard stockMmol.isFinite, stockMmol > 0 else { return .nan }
        let measurement = stockMmol
        if !initialized || index <= 1 || index <= lastIndex {
            reset()
            initialized = true
            level = measurement
            samplesSinceReset = 1
            updateTelemetry(rawMmol: rawMmol, temperatureC: temperatureC, impedance: impedance, index: index,
                            eventTimeMs: eventTimeMs, measurement: measurement)
            return SibionicsTrackerMath.roundTenth(measurement)
        }

        let elapsed = SibionicsTrackerMath.elapsedMinutes(eventTimeMs: eventTimeMs, lastTimestampMs: lastTimestampMs,
                                                          index: index, lastIndex: lastIndex)
        let signal = signalQuality(temperatureC: temperatureC, impedance: impedance)
        let latestStep: Float = lastMeasurement.isFinite ? measurement - lastMeasurement : 0
        let predicted = level + trend * elapsed
        let innovation = measurement - predicted
        let rapidChange = (abs(innovation) / Self.rapidInnovationMmol).clamped(0, 1)
        let alpha = Self.baseLevelGain + (Self.maxLevelGain - Self.baseLevelGain) * rapidChange
        level = predicted + alpha * innovation

        let rawTrend: Float = rawMmol.isFinite && lastRaw.isFinite
            ? ((rawMmol - lastRaw) / sensitivity / elapsed).clamped(-Self.maxTrendRate, Self.maxTrendRate)
            : .nan
        let rawCoherent = rawTrend.isFinite && (abs(latestStep) < Self.minDirectionStep || abs(rawTrend) < Self.minRawTrendRate
                                                || latestStep * rawTrend > 0)
        let rawWeight: Float = rawCoherent ? Self.rawTrendWeight * signal.overall : 0
        let innovationTrend = Self.trendGain * innovation.clamped(-Self.maxTrendInnovation, Self.maxTrendInnovation) / elapsed
        let rawContribution: Float = rawTrend.isFinite ? rawTrend * rawWeight : 0
        trend = ((trend + innovationTrend) * (1 - rawWeight) + rawContribution).clamped(-Self.maxTrendRate, Self.maxTrendRate)
        samplesSinceReset += 1

        let turning = abs(latestStep) >= Self.turnStepMmol && latestStep * trend < 0
        let exactPassThrough = samplesSinceReset <= Self.startupPassthroughSamples || abs(latestStep) >= Self.largeStepMmol
            || measurement <= Self.lowExactMmol || turning || signal.telemetryAnomaly
        var output: Float
        if exactPassThrough {
            level = measurement
            if abs(latestStep) >= Self.largeStepMmol || signal.telemetryAnomaly { trend = 0 }
            output = measurement
        } else {
            output = level.clamped(measurement - Self.maxTrackingDistanceMmol, measurement + Self.maxTrackingDistanceMmol)
        }
        if measurement < Self.lowFallGuardMmol && latestStep < 0 { output = Swift.min(output, measurement) }

        updateTelemetry(rawMmol: rawMmol, temperatureC: temperatureC, impedance: impedance, index: index,
                        eventTimeMs: eventTimeMs, measurement: measurement)
        return SibionicsTrackerMath.roundTenth(Swift.max(output, 0))
    }

    private func signalQuality(temperatureC: Float, impedance: Float) -> (overall: Float, telemetryAnomaly: Bool) {
        let temperatureJump = lastTemperature.isFinite && temperatureC.isFinite && abs(temperatureC - lastTemperature) > Self.temperatureJumpC
        var temperatureQuality: Float
        if !temperatureC.isFinite {
            temperatureQuality = 0.45
        } else if (28...40).contains(temperatureC) {
            temperatureQuality = 1
        } else if (10...42).contains(temperatureC) {
            temperatureQuality = 0.65
        } else {
            temperatureQuality = 0.25
        }
        temperatureQuality *= temperatureJump ? 0.55 : 1
        let impedanceDelta: Float = impedance.isFinite && impedance > 0 && impedanceBaseline.isFinite
            ? abs(impedance - impedanceBaseline) / Swift.max(abs(impedanceBaseline), 1)
            : 0
        let impedanceQuality = (1 / (1 + impedanceDelta * Self.impedanceQualitySlope)).clamped(Self.minSignalQuality, 1)
        let anomaly = temperatureJump || (temperatureC.isFinite && !(10...42).contains(temperatureC))
            || impedanceDelta > Self.impedanceAnomalyFraction
        return ((temperatureQuality * 0.68 + impedanceQuality * 0.32).clamped(Self.minSignalQuality, 1), anomaly)
    }

    private mutating func updateTelemetry(rawMmol: Float, temperatureC: Float, impedance: Float, index: Int,
                                          eventTimeMs: Int64, measurement: Float) {
        if impedance.isFinite && impedance > 0 {
            if impedanceBaseline.isFinite {
                let relativeDelta = abs(impedance - impedanceBaseline) / Swift.max(abs(impedanceBaseline), 1)
                let rate = relativeDelta > Self.impedanceAnomalyFraction ? Self.anomalousImpedanceLearningRate : Self.impedanceLearningRate
                impedanceBaseline = impedanceBaseline * (1 - rate) + impedance * rate
            } else {
                impedanceBaseline = impedance
            }
        }
        if rawMmol.isFinite { lastRaw = rawMmol }
        if temperatureC.isFinite { lastTemperature = temperatureC }
        lastMeasurement = measurement
        lastTimestampMs = eventTimeMs
        lastIndex = index
    }

    private var isStateValid: Bool {
        guard initialized else { return true }
        return level.isFinite && (0...50).contains(level) && trend.isFinite && abs(trend) <= Self.maxTrendRate
            && lastMeasurement.isFinite && (0...50).contains(lastMeasurement) && lastIndex >= 0 && samplesSinceReset > 0
    }

    func snapshot() -> Data {
        var writer = SibionicsTrackerWriter()
        writer.float(sensitivity)
        writer.bool(initialized)
        writer.float(level)
        writer.float(trend)
        writer.float(lastMeasurement)
        writer.float(lastRaw)
        writer.float(lastTemperature)
        writer.float(impedanceBaseline)
        writer.int64(lastTimestampMs)
        writer.int(lastIndex)
        writer.int(samplesSinceReset)
        return writer.data
    }

    /// Restores a snapshot of a tracker with the same sensitivity; nil otherwise.
    static func restored(from data: Data, sensitivity: Float) -> SibionicsBalancedTracker? {
        var tracker = SibionicsBalancedTracker(sensitivity: sensitivity)
        var reader = SibionicsTrackerReader(data: data)
        guard let saved = reader.float(), saved.isFinite, abs(saved - tracker.sensitivity) <= 0.0001,
              let initialized = reader.bool(), let level = reader.float(), let trend = reader.float(),
              let lastMeasurement = reader.float(), let lastRaw = reader.float(), let lastTemperature = reader.float(),
              let impedanceBaseline = reader.float(), let lastTimestampMs = reader.int64(), let lastIndex = reader.int(),
              let samplesSinceReset = reader.int(), reader.isAtEnd else { return nil }
        tracker.initialized = initialized
        tracker.level = level
        tracker.trend = trend
        tracker.lastMeasurement = lastMeasurement
        tracker.lastRaw = lastRaw
        tracker.lastTemperature = lastTemperature
        tracker.impedanceBaseline = impedanceBaseline
        tracker.lastTimestampMs = lastTimestampMs
        tracker.lastIndex = lastIndex
        tracker.samplesSinceReset = samplesSinceReset
        return tracker.isStateValid ? tracker : nil
    }
}

/// JugglucoNG `SibionicsResponsiveAlgorithmContext`: a glucose/velocity estimator around the stock
/// value with a robust innovation clamp and a small trend lead, kept within a safety distance of
/// the stock value. Calibration anchors are always empty for it in JugglucoNG.
struct SibionicsResponsiveEstimator {
    private static let innovationWindow = 7
    private static let minInnovationScale: Float = 0.12
    private static let minInnovationLimit: Float = 0.55
    private static let maxInnovation: Float = 2.5
    private static let maxVelocity: Float = 0.30
    private static let maxTrendLead: Float = 0.35
    private static let minOutputDistance: Float = 0.65
    private static let maxOutputDistanceFraction: Float = 0.16
    private static let lowQualitySafetyExpansion: Float = 2

    let sensitivity: Float
    private var initialized = false
    private var glucose: Float = .nan
    private var velocity: Float = 0
    private var lastMeasurement: Float = .nan
    private var lastRaw: Float = .nan
    private var lastTemperature: Float = .nan
    private var impedanceBaseline: Float = .nan
    private var lastTimestampMs: Int64 = 0
    private var lastIndex = -1
    private var innovations: [Float] = []

    init(sensitivity: Float) {
        self.sensitivity = sensitivity.isFinite && (0.5...3.5).contains(sensitivity) ? sensitivity : 1.27
    }

    mutating func reset() { self = SibionicsResponsiveEstimator(sensitivity: sensitivity) }

    mutating func process(stockMmol: Float, rawMmol: Float, temperatureC: Float, impedance: Float,
                          index: Int, eventTimeMs: Int64) -> Float {
        guard stockMmol.isFinite, stockMmol > 0 else { return .nan }
        let measurement = stockMmol
        if !initialized || index <= 1 || index <= lastIndex || !glucose.isFinite {
            // As in JugglucoNG, this restart keeps the recent innovations.
            initialized = true
            glucose = measurement
            velocity = 0
            updateTelemetry(rawMmol: rawMmol, temperatureC: temperatureC, impedance: impedance, index: index,
                            eventTimeMs: eventTimeMs, measurement: measurement)
            return SibionicsTrackerMath.roundTenth(measurement)
        }

        let elapsed = SibionicsTrackerMath.elapsedMinutes(eventTimeMs: eventTimeMs, lastTimestampMs: lastTimestampMs,
                                                          index: index, lastIndex: lastIndex)
        let quality = signalQuality(temperatureC: temperatureC, impedance: impedance)
        let predicted = glucose + velocity * elapsed
        var innovation = measurement - predicted

        if innovations.count >= 5 {
            let median = SibionicsTrackerMath.median(innovations)
            let scale = Swift.max(Self.minInnovationScale, SibionicsTrackerMath.median(innovations.map { abs($0 - median) }))
            let robustLimit = Swift.max(Self.minInnovationLimit, scale * 3)
            if quality < 0.75 && abs(innovation - median) > robustLimit {
                innovation = median + (innovation - median).clamped(-robustLimit, robustLimit)
            }
        }
        innovation = innovation.clamped(-Self.maxInnovation, Self.maxInnovation)

        let rapidChange = (abs(innovation) / 1.2).clamped(0, 1)
        let rawVelocity: Float = rawMmol.isFinite && lastRaw.isFinite
            ? ((rawMmol - lastRaw) / sensitivity / elapsed).clamped(-Self.maxVelocity, Self.maxVelocity)
            : 0
        let directionAgreement: Float
        if abs(rawVelocity) < 0.015 || abs(innovation) < 0.08 {
            directionAgreement = 0
        } else if rawVelocity * innovation > 0 {
            directionAgreement = 1
        } else {
            directionAgreement = -1
        }
        let alpha = (0.34 + quality * 0.30 + rapidChange * 0.18 + directionAgreement * 0.06).clamped(0.18, 0.84)
        let beta = (0.055 + quality * 0.12 + rapidChange * 0.07).clamped(0.04, 0.24)

        glucose = predicted + alpha * innovation
        let innovationVelocity = beta * innovation / elapsed
        velocity = (velocity * 0.72 + innovationVelocity + rawVelocity * quality * 0.20).clamped(-Self.maxVelocity, Self.maxVelocity)

        let lead = (velocity * (0.25 + quality * 0.25)).clamped(-Self.maxTrendLead, Self.maxTrendLead)
        let safetyDistance = Swift.max(Self.minOutputDistance, measurement * Self.maxOutputDistanceFraction)
            * (1 + (1 - quality) * Self.lowQualitySafetyExpansion)
        let output = (glucose + lead).clamped(measurement - safetyDistance, measurement + safetyDistance)

        innovations.append(innovation)
        while innovations.count > Self.innovationWindow { innovations.removeFirst() }
        updateTelemetry(rawMmol: rawMmol, temperatureC: temperatureC, impedance: impedance, index: index,
                        eventTimeMs: eventTimeMs, measurement: measurement)
        return SibionicsTrackerMath.roundTenth(Swift.max(output, 0))
    }

    private func signalQuality(temperatureC: Float, impedance: Float) -> Float {
        var temperatureQuality: Float
        if !temperatureC.isFinite {
            temperatureQuality = 0.35
        } else if (28...40).contains(temperatureC) {
            temperatureQuality = 1
        } else if (10...42).contains(temperatureC) {
            temperatureQuality = 0.65
        } else {
            temperatureQuality = 0.25
        }
        temperatureQuality *= lastTemperature.isFinite && abs(temperatureC - lastTemperature) > 1.2 ? 0.65 : 1
        var impedanceQuality: Float = 1
        if impedance.isFinite && impedance > 0 && impedanceBaseline.isFinite {
            let relativeDelta = abs(impedance - impedanceBaseline) / Swift.max(abs(impedanceBaseline), 1)
            impedanceQuality = (1 / (1 + relativeDelta * 5)).clamped(0.2, 1)
        }
        return (temperatureQuality * 0.7 + impedanceQuality * 0.3).clamped(0.2, 1)
    }

    private mutating func updateTelemetry(rawMmol: Float, temperatureC: Float, impedance: Float, index: Int,
                                          eventTimeMs: Int64, measurement: Float) {
        if impedance.isFinite && impedance > 0 {
            impedanceBaseline = impedanceBaseline.isFinite ? impedanceBaseline * 0.96 + impedance * 0.04 : impedance
        }
        if rawMmol.isFinite { lastRaw = rawMmol }
        if temperatureC.isFinite { lastTemperature = temperatureC }
        lastMeasurement = measurement
        lastTimestampMs = eventTimeMs
        lastIndex = index
    }

    private var isStateValid: Bool {
        guard initialized else { return true }
        return glucose.isFinite && (0...50).contains(glucose) && velocity.isFinite && abs(velocity) <= Self.maxVelocity && lastIndex >= 0
    }

    func snapshot() -> Data {
        var writer = SibionicsTrackerWriter()
        writer.float(sensitivity)
        writer.bool(initialized)
        writer.float(glucose)
        writer.float(velocity)
        writer.float(lastMeasurement)
        writer.float(lastRaw)
        writer.float(lastTemperature)
        writer.float(impedanceBaseline)
        writer.int64(lastTimestampMs)
        writer.int(lastIndex)
        writer.int(innovations.count)
        innovations.forEach { writer.float($0) }
        return writer.data
    }

    static func restored(from data: Data, sensitivity: Float) -> SibionicsResponsiveEstimator? {
        var estimator = SibionicsResponsiveEstimator(sensitivity: sensitivity)
        var reader = SibionicsTrackerReader(data: data)
        guard let saved = reader.float(), saved.isFinite, abs(saved - estimator.sensitivity) <= 0.0001,
              let initialized = reader.bool(), let glucose = reader.float(), let velocity = reader.float(),
              let lastMeasurement = reader.float(), let lastRaw = reader.float(), let lastTemperature = reader.float(),
              let impedanceBaseline = reader.float(), let lastTimestampMs = reader.int64(), let lastIndex = reader.int(),
              let count = reader.int(), (0...innovationWindow).contains(count) else { return nil }
        var innovations: [Float] = []
        for _ in 0..<count {
            guard let value = reader.float(), value.isFinite else { return nil }
            innovations.append(value)
        }
        guard reader.isAtEnd else { return nil }
        estimator.initialized = initialized
        estimator.glucose = glucose
        estimator.velocity = velocity
        estimator.lastMeasurement = lastMeasurement
        estimator.lastRaw = lastRaw
        estimator.lastTemperature = lastTemperature
        estimator.impedanceBaseline = impedanceBaseline
        estimator.lastTimestampMs = lastTimestampMs
        estimator.lastIndex = lastIndex
        estimator.innovations = innovations
        return estimator.isStateValid ? estimator : nil
    }
}
