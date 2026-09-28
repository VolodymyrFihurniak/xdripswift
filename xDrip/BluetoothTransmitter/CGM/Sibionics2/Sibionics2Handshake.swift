//
//  Sibionics2Handshake.swift
//  xdrip
//

import CoreBluetooth
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

/// Resolves the Bluetooth address carried by the V120 authentication packet.
/// iOS does not publish a public MAC API; some CoreBluetooth versions expose
/// private selectors used by the reference apps, so the explicit address field
/// remains available as a fallback when those selectors are absent.
enum Sibionics2AuthenticationAddress {
    private static let keyPrefix = "sibionics2.authenticationAddress."
    private static let detectedKeyPrefix = "sibionics2.detectedBluetoothAddress."

    static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hexDigits = CharacterSet(charactersIn: "0123456789ABCDEF")
        let compact: String

        if trimmed.contains(":") {
            let octets = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard octets.count == 6,
                  octets.allSatisfy({
                      $0.unicodeScalars.count == 2 &&
                          $0.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
                  }) else { return nil }
            compact = octets.map(String.init).joined()
        } else {
            guard trimmed.unicodeScalars.count == 12,
                  trimmed.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else { return nil }
            compact = trimmed
        }

        let bytes = stride(from: 0, to: compact.count, by: 2).compactMap { offset -> UInt8? in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            return UInt8(compact[start..<end], radix: 16)
        }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02X", Int($0)) }.joined(separator: ":")
    }

    static func address(from value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return normalize(text) }
        if let data = value as? Data, data.count == 6 {
            return normalize(data.map { String(format: "%02X", Int($0)) }.joined(separator: ":"))
        }
        if let data = value as? NSData, data.length == 6 {
            return address(from: Data(referencing: data))
        }
        if let numbers = value as? [NSNumber], numbers.count == 6,
           numbers.allSatisfy({ (0...255).contains($0.intValue) }) {
            return normalize(numbers.map { String(format: "%02X", $0.intValue) }.joined(separator: ":"))
        }
        return nil
    }

    static func automaticAddress(for peripheral: CBPeripheral, centralManager: CBCentralManager) -> String? {
        let peripheralSelector = NSSelectorFromString("BDAddress")
        if peripheral.responds(to: peripheralSelector),
           let result = peripheral.perform(peripheralSelector)?.takeUnretainedValue(),
           let address = address(from: result) {
            return address
        }

        let centralSelector = NSSelectorFromString("retrieveAddressForPeripheral:")
        if centralManager.responds(to: centralSelector),
           let result = centralManager.perform(centralSelector, with: peripheral)?.takeUnretainedValue(),
           let address = address(from: result) {
            return address
        }
        return nil
    }

    static func override(for identifier: String, userDefaults: UserDefaults = .standard) -> String? {
        guard let key = key(for: identifier),
              let saved = userDefaults.string(forKey: key) else { return nil }
        return normalize(saved)
    }

    static func detected(for identifier: String, userDefaults: UserDefaults = .standard) -> String? {
        guard let key = detectedKey(for: identifier),
              let saved = userDefaults.string(forKey: key) else { return nil }
        return normalize(saved)
    }

    @discardableResult
    static func setDetected(_ value: String?, for identifier: String, userDefaults: UserDefaults = .standard) -> Bool {
        guard let key = detectedKey(for: identifier) else { return false }
        guard let value else {
            userDefaults.removeObject(forKey: key)
            return true
        }
        guard let address = normalize(value) else { return false }
        userDefaults.set(address, forKey: key)
        return true
    }

    static func effectiveAddress(for identifier: String, userDefaults: UserDefaults = .standard) -> String? {
        override(for: identifier, userDefaults: userDefaults)
            ?? detected(for: identifier, userDefaults: userDefaults)
    }

    static func macBytes(for identifier: String, userDefaults: UserDefaults = .standard) -> [UInt8] {
        guard let address = effectiveAddress(for: identifier, userDefaults: userDefaults) else {
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

    private static func detectedKey(for identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return detectedKeyPrefix + normalized
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
