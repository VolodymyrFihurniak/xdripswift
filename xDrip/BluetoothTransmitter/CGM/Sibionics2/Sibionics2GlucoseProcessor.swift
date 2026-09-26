//
// Sibionics2GlucoseProcessor.swift
// Stock algorithm bridge and xDrip-facing delivery policy.
//

import Foundation
import Sibionics2Core

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

/// Stateful xDrip wrapper for the stock V116A correction stream. Before its
/// first exact correction there is deliberately no glucose result.
struct Sibionics2GlucoseProcessor {
    private static let snapshotMagic: [UInt8] = [0x53, 0x32, 0x47, 0x50] // S2GP
    private static let snapshotVersion: UInt16 = 1
    private static let maximumCoreHexLength = 16_384

    private final class CoreBox {
        let value: Sibionics2V116AFacade
        init(_ value: Sibionics2V116AFacade) { self.value = value }
    }

    private let sensitivity: Float
    private let validSensitivity: Bool
    private var coreBox: CoreBox
    private var liveDeltaMmol: Float?
    private var replayDeltaMmol: Float?
    private var lastIndex: Int?

    init(sensitivity: Double) {
        let valid = Sibionics2FactorySensitivity.isSupported(sensitivity)
        self.validSensitivity = valid
        self.sensitivity = Float(sensitivity)
        self.coreBox = CoreBox(Sibionics2V116AFacade(sensitivity: valid ? Float(sensitivity) : 1.27))
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

        let displayMmol: Float
        if candidate.isFinite, candidate > 1, candidate <= 50 {
            let delta = candidate - raw
            guard delta.isFinite, abs(delta) < 40 else { return nil }
            switch mode {
            case .live:
                liveDeltaMmol = delta
            case .replay:
                replayDeltaMmol = delta
                // Replay is the newer backfill immediately preceding live.
                liveDeltaMmol = delta
            }
            displayMmol = candidate
        } else {
            let delta: Float?
            switch mode {
            case .live:
                delta = liveDeltaMmol ?? replayDeltaMmol
            case .replay:
                delta = replayDeltaMmol
            }
            guard let delta, delta.isFinite, abs(delta) < 40 else { return nil }
            let corrected = raw + delta
            guard corrected.isFinite, corrected > 0, corrected <= 50 else { return nil }
            displayMmol = Self.nativeRound(corrected)
        }

        let mgDl = Double(displayMmol) * 18.0
        guard mgDl.isFinite, mgDl > 0, mgDl <= 900 else { return nil }
        return Sibionics2ProcessedGlucose(
            glucoseMgDl: mgDl,
            index: reading.index,
            eventTime: reading.eventTime,
            trend: reading.trend
        )
    }

    mutating func reset() {
        ensureUniqueCore()
        coreBox.value.reset()
        liveDeltaMmol = nil
        replayDeltaMmol = nil
        lastIndex = nil
    }

    func snapshot() -> Data {
        guard validSensitivity else { return Data() }
        let coreHex = coreBox.value.snapshotHex()
        let bytes = Array(coreHex.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumCoreHexLength else { return Data() }
        var flags: UInt8 = 0
        if liveDeltaMmol != nil { flags |= 1 }
        if replayDeltaMmol != nil { flags |= 2 }
        if lastIndex != nil { flags |= 4 }

        var data = Data(Self.snapshotMagic)
        data.appendUInt16BE(Self.snapshotVersion)
        data.append(flags)
        data.append(0)
        data.appendUInt32BE(sensitivity.bitPattern)
        data.appendUInt32BE(UInt32(lastIndex ?? 0))
        data.appendUInt32BE((liveDeltaMmol ?? 0).bitPattern)
        data.appendUInt32BE((replayDeltaMmol ?? 0).bitPattern)
        data.appendUInt32BE(UInt32(bytes.count))
        data.append(contentsOf: bytes)
        return data
    }

    mutating func restore(from data: Data) -> Bool {
        let headerSize = 28
        guard validSensitivity, data.count >= headerSize,
              Array(data.prefix(4)) == Self.snapshotMagic,
              data.uint16BE(at: 4) == Self.snapshotVersion,
              let flags = data.byte(at: 6), (flags & ~UInt8(7)) == 0,
              data.byte(at: 7) == 0,
              data.uint32BE(at: 8) == sensitivity.bitPattern,
              let savedIndex = data.uint32BE(at: 12),
              let liveBits = data.uint32BE(at: 16),
              let replayBits = data.uint32BE(at: 20),
              let coreLength = data.uint32BE(at: 24),
              coreLength > 0, coreLength <= Self.maximumCoreHexLength,
              data.count == headerSize + Int(coreLength),
              let hex = String(data: data[headerSize...], encoding: .utf8)
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

        let restored = Sibionics2V116AFacade(sensitivity: sensitivity)
        guard restored.restoreHex(hex) else { return false }
        coreBox = CoreBox(restored)
        self.lastIndex = restoredIndex
        self.liveDeltaMmol = (flags & 1) == 0 ? nil : liveDelta
        self.replayDeltaMmol = (flags & 2) == 0 ? nil : replayDelta
        return true
    }

    private func isValid(_ reading: Sibionics2RawReading) -> Bool {
        reading.index > 0 && reading.index <= Int(UInt16.max) &&
            reading.rawMmol.isFinite && reading.rawMmol > 0 && reading.rawMmol <= 6553.5 &&
            reading.temperatureC.isFinite && reading.temperatureC > 0 && reading.temperatureC <= 80
    }

    private mutating func ensureUniqueCore() {
        guard !isKnownUniquelyReferenced(&coreBox) else { return }
        let copy = Sibionics2V116AFacade(sensitivity: sensitivity)
        if copy.restoreHex(coreBox.value.snapshotHex()) {
            coreBox = CoreBox(copy)
        }
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
