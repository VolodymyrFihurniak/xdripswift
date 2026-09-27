//
//  Sibionics2Handshake.swift
//  xdrip
//

import Foundation

enum Sibionics2DeviceIdentity {
    /// Sibionics 2 transmitter advertisements use P followed by three digits.
    /// Keep the suffix alphanumeric and the whole normalized name within 8...16 bytes.
    static func isSibionics2(name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let characters = Array(name.uppercased().utf8)
        guard characters.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            return false
        }
        let normalized = characters.filter { $0 != 45 && $0 != 95 }
        guard (8...16).contains(normalized.count), normalized[0] == 80 else { return false }
        return normalized[1...3].allSatisfy { (48...57).contains($0) }
    }

    static func matchesSearch(name: String, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedQuery.isEmpty else { return true }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .contains(normalizedQuery)
    }
}

/// Core Bluetooth identifies peripherals by UUID, which is not the Bluetooth address
/// carried in a Sibionics V120 authentication command. A sensor-specific address
/// can be entered from a verified device log when the zero-address fallback is
/// acknowledged but the sensor never sends readings.
enum Sibionics2AuthenticationAddress {
    private static let keyPrefix = "sibionics2.authenticationAddress."

    static func normalize(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { part -> UInt8? in
            guard part.count == 2 else { return nil }
            return UInt8(part, radix: 16)
        }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func override(for identifier: String, userDefaults: UserDefaults = .standard) -> String? {
        guard let key = key(for: identifier),
              let saved = userDefaults.string(forKey: key) else { return nil }
        return normalize(saved)
    }

    static func macBytes(for identifier: String, userDefaults: UserDefaults = .standard) -> [UInt8] {
        guard let address = override(for: identifier, userDefaults: userDefaults) else {
            return [UInt8](repeating: 0, count: 6)
        }
        return address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }

    @discardableResult
    static func setOverride(
        _ value: String?,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(for: identifier) else { return false }
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            userDefaults.removeObject(forKey: key)
            return true
        }
        guard let address = normalize(text) else { return false }
        userDefaults.set(address, forKey: key)
        return true
    }

    private static func key(for identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return keyPrefix + normalized
    }
}

struct Sibionics2Handshake {
    private enum Phase { case idle, awaitingAuthentication, awaitingTimeSync, awaitingDataRequest, awaitingStreaming, streaming }

    private let macAddress: [UInt8]
    private let sessionKey: Data
    private let lastDeliveredIndex: UInt16?
    private let codec = Sibionics2ProtocolCodec()
    private var phase: Phase = .idle

    init(macAddress: [UInt8], sessionKey: Data, lastDeliveredIndex: UInt16?) {
        self.macAddress = macAddress.count == 6 ? macAddress : [UInt8](repeating: 0, count: 6)
        self.sessionKey = sessionKey
        self.lastDeliveredIndex = lastDeliveredIndex
    }

    mutating func start(at date: Date) -> Data {
        let command = codec.buildAuthPacket(macAddress: macAddress, sessionKey: sessionKey)
        if !command.isEmpty { phase = .awaitingAuthentication }
        return command
    }

    var isStreaming: Bool {
        if case .streaming = phase { return true }
        return false
    }

    /// A valid data frame itself establishes streaming on V120; some firmware
    /// does not send a separate streaming-ready acknowledgement.
    mutating func receiveReadings() -> Bool {
        switch phase {
        case .awaitingTimeSync, .awaitingDataRequest, .awaitingStreaming:
            phase = .streaming
            return true
        case .streaming:
            return true
        default:
            return false
        }
    }

    mutating func receive(_ response: Sibionics2HandshakeResponse, at date: Date) -> Data? {
        switch (phase, response) {
        case (.awaitingAuthentication, .authenticationAccepted):
            phase = .awaitingTimeSync
            return codec.buildActivationPacket(at: date)
        case (.awaitingTimeSync, .timeSyncNeeded):
            phase = .awaitingDataRequest
            return codec.buildTimeSyncPacket(at: date)
        case (.awaitingTimeSync, .dataRequested), (.awaitingDataRequest, .dataRequested):
            phase = .awaitingStreaming
            return codec.buildDataRequestPacket(lastIndex: lastDeliveredIndex ?? 0)
        case (.awaitingStreaming, .streamingReady):
            phase = .streaming
            return nil
        default:
            return nil
        }
    }
}

 
/// A history request is complete only when Core Bluetooth accepted the write
/// for queuing. Failed writes remain eligible for the retry on the same cursor.
struct Sibionics2HistoryRequestTracker {
    private var requestedStart: Date?
    private var requestedCursor: UInt16?

    func needsRequest(for start: Date, cursor: UInt16) -> Bool {
        requestedStart != start || requestedCursor != cursor
    }

    mutating func record(for start: Date, cursor: UInt16, queued: Bool) {
        guard queued else { return }
        requestedStart = start
        requestedCursor = cursor
    }

    mutating func reset() {
        requestedStart = nil
        requestedCursor = nil
    }
}
