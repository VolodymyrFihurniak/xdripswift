//
//  Sibionics2Protocol.swift
//  xdrip
//

import CoreBluetooth
import Foundation

enum Sibionics2Trend: UInt8 {
    case notDetermined = 0
    case risingRapidly = 1
    case rising = 2
    case risingSlowly = 3
    case stable = 4
    case fallingSlowly = 5
    case falling = 6
    case fallingRapidly = 7
}

struct Sibionics2RawReading {
    let index: Int
    let eventTime: Date
    let temperatureC: Double
    let impedance: Int
    let rawMmol: Double
    let trend: Sibionics2Trend
    let reindex: Int
}

/// Numeric encoding shared by all V120 measurement fields.
enum Sibionics2V120ReadingFormat {
    static let measurementScale: Double = 10
    static let maximumIndex = Int(UInt16.max)
    static let maximumEncodedValue = Double(UInt16.max)
}

enum Sibionics2HandshakeResponse: UInt8 {
    case authenticationAccepted = 0x01
    case timeSyncNeeded = 0x07
    case dataRequested = 0x03
    case streamingReady = 0x08
}

enum Sibionics2ParseResult {
    case handshake(Sibionics2HandshakeResponse)
    case readings([Sibionics2RawReading])
    case malformed
}

struct Sibionics2ProtocolCodec {
    static let serviceUUID = CBUUID(string: "FF30")
    static let notifyUUID = CBUUID(string: "FF31")
    static let writeUUID = CBUUID(string: "FF32")

    // V120 packet cipher key. A new cipher state is created for each notification or command.
    private static let packetKey: [UInt8] = [
        0x01, 0x38, 0x0B, 0x9A, 0x00, 0x5B, 0x02, 0x5D,
        0xCD, 0x9E, 0xC3, 0x99, 0x09, 0x37, 0xAA, 0xE8
    ]
    private static let ecoRegistration = "068449FA5C1B1F97EEC9C1475A8752D5C387D17A65B002D9132489C0BFDFC99F0CAC670E9AB10D62FDE0B2B1E7"

    func deriveSessionKey() -> Data? {
        let characters = Array(Self.ecoRegistration.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var registration = [UInt8]()
        registration.reserveCapacity(characters.count / 2)
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard let pair = String(bytes: characters[offset..<(offset + 2)], encoding: .ascii),
                  let byte = UInt8(pair, radix: 16) else { return nil }
            registration.append(byte)
        }
        let decoded = [UInt8](decrypt(Data(registration)))
        guard decoded.count >= 22 + "com.sisensing.eco".utf8.count,
              let identity = String(bytes: decoded[22...], encoding: .utf8),
              identity.hasPrefix("com.sisensing.eco") else { return nil }
        return Data(decoded[6..<22])
    }

    func encrypt(_ data: Data) -> Data {
        var permutation = Array(UInt8.min...UInt8.max)
        var keyIndex = 0
        for index in 0..<permutation.count {
            keyIndex = (keyIndex + Int(permutation[index]) + Int(Self.packetKey[index % Self.packetKey.count])) & 0xFF
            permutation.swapAt(index, keyIndex)
        }
        var first = 0
        var second = 0
        var encrypted = [UInt8]()
        encrypted.reserveCapacity(data.count)
        for byte in data {
            first = (first + 1) & 0xFF
            second = (second + Int(permutation[first])) & 0xFF
            permutation.swapAt(first, second)
            let mask = permutation[(Int(permutation[first]) + Int(permutation[second])) & 0xFF]
            encrypted.append(byte ^ mask)
        }
        return Data(encrypted)
    }

    func decrypt(_ data: Data) -> Data { encrypt(data) }

    func parseV120(_ data: Data) -> Sibionics2ParseResult {
        let packet = [UInt8](decrypt(data))
        guard packet.count >= 5, Int(packet[0]) + 1 == packet.count,
              packet.reduce(UInt8(0), { $0 &+ $1 }) == 0 else { return .malformed }

        if packet.count == 5 {
            guard let response = Sibionics2HandshakeResponse(rawValue: packet[1]) else { return .malformed }
            return .handshake(response)
        }

        guard packet.count >= 10, packet[1] == 0x08 else { return .malformed }
        let count = Int(packet[2])
        guard packet.count >= 10 + count * 8 else { return .malformed }
        let firstIndex = Int(Self.word(packet, at: 3))
        guard firstIndex + count <= Sibionics2V120ReadingFormat.maximumIndex + 1 else { return .malformed }
        let epoch = UInt32(packet[5]) | (UInt32(packet[6]) << 8)
            | (UInt32(packet[7]) << 16) | (UInt32(packet[8]) << 24)
        var readings = [Sibionics2RawReading]()
        readings.reserveCapacity(count)
        for position in 0..<count {
            let start = 9 + position * 8
            let trendValue = (packet[start + 6] >> 3) & 0x07
            guard let trend = Sibionics2Trend(rawValue: trendValue) else { return .malformed }
            readings.append(Sibionics2RawReading(
                index: firstIndex + position,
                eventTime: Date(
                    timeIntervalSince1970: TimeInterval(epoch) +
                        TimeInterval(position) * Sibionics2SensorProfile.sampleInterval
                ),
                temperatureC: Double(Self.word(packet, at: start)) / Sibionics2V120ReadingFormat.measurementScale,
                impedance: Int(Self.word(packet, at: start + 2)),
                rawMmol: Double(Self.word(packet, at: start + 4)) / Sibionics2V120ReadingFormat.measurementScale,
                trend: trend,
                reindex: count - position - 1
            ))
        }
        return .readings(readings)
    }

    func buildAuthPacket(macAddress: [UInt8], sessionKey: Data) -> Data {
        guard sessionKey.count == 16 else { return Data() }
        let mac = macAddress.count == 6 ? macAddress : [UInt8](repeating: 0, count: 6)
        return packet([0x01, 0] + Array(mac.reversed()) + Array(sessionKey))
    }

    func buildActivationPacket(at date: Date) -> Data {
        packet([0x07] + Self.littleEndianSeconds(date) + [0xD2, 0x04, 0, 0])
    }

    func buildTimeSyncPacket(at date: Date) -> Data {
        packet([0x03] + Self.littleEndianSeconds(date))
    }

    func buildDataRequestPacket(lastIndex: UInt16) -> Data {
        packet([0x08, UInt8(truncatingIfNeeded: lastIndex), UInt8(truncatingIfNeeded: lastIndex >> 8), 0, 0])
    }

    /// V120 maintenance reset command from JugglucoNG's Sibionics protocol.
    /// Reset is intentionally independent of local history; the batch processor
    /// switches sessions only after the sensor confirms its new start/index.
    func buildResetPacket(resetType: UInt8 = 0) -> Data {
        packet([0x10, resetType])
    }

    private func packet(_ body: [UInt8]) -> Data {
        var bytes = [UInt8(body.count + 1)] + body
        bytes.append(0 &- bytes.reduce(UInt8(0), { $0 &+ $1 }))
        return encrypt(Data(bytes))
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleEndianSeconds(_ date: Date) -> [UInt8] {
        let seconds = UInt32(clamping: Int64(date.timeIntervalSince1970))
        return (0..<4).map { UInt8(truncatingIfNeeded: seconds >> ($0 * 8)) }
    }
}
