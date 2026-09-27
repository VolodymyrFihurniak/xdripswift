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
    private static let snapshotVersion: UInt16 = 2
    private static let maximumCoreHexLength = 16_384
    private static let coreSnapshotChunkByteCount = 256

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
        guard let bytes = Self.snapshotCoreHexBytes(from: coreBox.value),
              !bytes.isEmpty, bytes.count <= Self.maximumCoreHexLength else { return Data() }
        var flags: UInt8 = 0
        if liveDeltaMmol != nil { flags |= 1 }
        if replayDeltaMmol != nil { flags |= 2 }
        if lastIndex != nil { flags |= 4 }

        var data = Data(Self.snapshotMagic)
        data.appendUInt16BE(Self.snapshotVersion)
        data.append(flags)
        // The reserved field is one byte; an untyped literal selects Data.append<Int>.
        data.append(UInt8(0))
        data.appendUInt32BE(sensitivity.bitPattern)
        data.appendUInt32BE(UInt32(lastIndex ?? 0))
        data.appendUInt32BE((liveDeltaMmol ?? 0).bitPattern)
        data.appendUInt32BE((replayDeltaMmol ?? 0).bitPattern)
        data.appendUInt32BE(UInt32(bytes.count))
        data.append(contentsOf: bytes)
        let checksum = Self.checksum(data)
        data.appendUInt32BE(checksum)
        return data
    }

    mutating func restore(from data: Data) -> Bool {
        let headerSize = 28
        let checksumSize = 4
        guard validSensitivity, data.count >= headerSize + checksumSize,
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
              coreLength % 2 == 0,
              data.count == headerSize + Int(coreLength) + checksumSize
        else { return false }

        let checksumOffset = data.count - checksumSize
        guard let storedChecksum = data.uint32BE(at: checksumOffset),
              Self.checksum(Data(data.prefix(checksumOffset))) == storedChecksum
        else { return false }
        let coreHexBytes = Array(data[headerSize..<checksumOffset])
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

        let restored = Sibionics2V116AFacade(sensitivity: sensitivity)
        guard Self.restoreCoreSnapshot(hexBytes: coreHexBytes, into: restored) else { return false }
        coreBox = CoreBox(restored)
        self.lastIndex = restoredIndex
        self.liveDeltaMmol = (flags & 1) == 0 ? nil : liveDelta
        self.replayDeltaMmol = (flags & 2) == 0 ? nil : replayDelta
        return true
    }

    private static func snapshotCoreHexBytes(from core: Sibionics2V116AFacade) -> [UInt8]? {
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

    private static func restoreCoreSnapshot(hexBytes: [UInt8], into core: Sibionics2V116AFacade) -> Bool {
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
        reading.index > 0 && reading.index <= Int(UInt16.max) &&
            reading.rawMmol.isFinite && reading.rawMmol > 0 && reading.rawMmol <= 6553.5 &&
            reading.temperatureC.isFinite && reading.temperatureC > 0 && reading.temperatureC <= 80
    }

    private mutating func ensureUniqueCore() {
        guard !isKnownUniquelyReferenced(&coreBox) else { return }
        let copy = Sibionics2V116AFacade(sensitivity: sensitivity)
        if let hexBytes = Self.snapshotCoreHexBytes(from: coreBox.value),
           Self.restoreCoreSnapshot(hexBytes: hexBytes, into: copy) {
            coreBox = CoreBox(copy)
        }
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
