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
    /// JugglucoNG's Adaptive V2: a probabilistic estimator fed by the stock core's
    /// sensor-state-calibrated signal instead of its filtered display value.
    case adaptiveV2 = 8

    var title: String {
        switch self {
        case .stock: return Texts_BluetoothPeripheralView.sibionicsGlucoseModelStock
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
}

extension Sibionics2V116AFacade: SibionicsStockCore {}
extension Sibionics1V115GFacade: SibionicsStockCore {}
extension SibionicsAdaptiveV2Facade: SibionicsSnapshotCore {}

enum Sibionics2ProcessingMode {
    case live
    case replay
}

struct Sibionics2ProcessedGlucose {
    let glucoseMgDl: Double
    let index: Int
    let eventTime: Date
    let trend: Sibionics2Trend
}

/// Stateful xDrip wrapper for stock correction streams. V115G uses validated
/// rounded raw glucose before its first correction; V116A emits no result then.
struct Sibionics2GlucoseProcessor {
    private var snapshotMagic: [UInt8] {
        stockFamily == .v115g ? [0x53, 0x31, 0x47, 0x50] : [0x53, 0x32, 0x47, 0x50] // S1GP / S2GP
    }
    /// Version 2 is the stock layout; version 3 appends the Adaptive V2 state. A snapshot of
    /// the other model is refused, which replays history with the selected one.
    private var snapshotVersion: UInt16 { model == .adaptiveV2 ? 3 : 2 }
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

        init(sensitivity: Float, stockFamily: Sibionics2StockFamily, model: Sibionics2GlucoseModel) {
            switch stockFamily {
            case .v115g: value = Sibionics1V115GFacade(sensitivity: sensitivity)
            case .v116a: value = Sibionics2V116AFacade(sensitivity: sensitivity)
            }
            adaptive = model == .adaptiveV2 ? SibionicsAdaptiveV2Facade(sensitivity: sensitivity) : nil
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
                adaptiveMmol = Self.nativeRound(estimate)
            }
        }
        let stockMmol = stockDisplayMmol(candidate: candidate, raw: raw, mode: mode)
        guard let displayMmol = adaptiveMmol ?? stockMmol else { return nil }

        let mgDl = Double(displayMmol) * Self.mmolToMgDlConversionFactor
        guard mgDl.isFinite,
              mgDl > 0,
              mgDl <= Sibionics2SensorProfile.maximumReportableGlucoseMgDl else { return nil }
        return Sibionics2ProcessedGlucose(
            glucoseMgDl: mgDl,
            index: reading.index,
            eventTime: reading.eventTime,
            trend: reading.trend
        )
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
        if let adaptive = coreBox.adaptive {
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
        if model == .adaptiveV2 {
            guard let adaptiveLength = data.uint32BE(at: coreEnd),
                  adaptiveLength > 0, adaptiveLength <= Self.maximumCoreHexLength,
                  adaptiveLength % 2 == 0,
                  data.count == coreEnd + 4 + Int(adaptiveLength) + checksumSize
            else { return false }
            let start = data.index(data.startIndex, offsetBy: coreEnd + 4)
            adaptiveHexBytes = Array(data[start..<data.index(start, offsetBy: Int(adaptiveLength))])
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
        if let adaptive = restored.adaptive {
            guard let adaptiveHexBytes,
                  Self.restoreCoreSnapshot(hexBytes: adaptiveHexBytes, into: adaptive) else { return false }
        }
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
