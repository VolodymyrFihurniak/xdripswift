//
//  Sibionics2Handshake.swift
//  xdrip
//

import CoreBluetooth
import Foundation

private enum Sibionics2AdvertisementFormat {
    static let normalizedNameLength = 8...16
    static let serialPrefixDigitCount = 3
    static let uppercaseASCIIRange: ClosedRange<UInt8> = 65...90
    static let decimalASCIIRange: ClosedRange<UInt8> = 48...57
    static let prefix: UInt8 = 80 // ASCII "P"
    static let hyphen: UInt8 = 45
    static let underscore: UInt8 = 95
}

enum Sibionics2DeviceIdentity {
    /// Sibionics 2 transmitter advertisements use P followed by three digits.
    /// Keep the suffix alphanumeric and the whole normalized name within 8...16 bytes.
    static func isSibionics2(name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let characters = Array(name.uppercased().utf8)
        guard characters.allSatisfy({
            Sibionics2AdvertisementFormat.uppercaseASCIIRange.contains($0) ||
                Sibionics2AdvertisementFormat.decimalASCIIRange.contains($0) ||
                $0 == Sibionics2AdvertisementFormat.hyphen ||
                $0 == Sibionics2AdvertisementFormat.underscore
        }) else {
            return false
        }
        let normalized = characters.filter {
            $0 != Sibionics2AdvertisementFormat.hyphen &&
                $0 != Sibionics2AdvertisementFormat.underscore
        }
        guard Sibionics2AdvertisementFormat.normalizedNameLength.contains(normalized.count),
              normalized[0] == Sibionics2AdvertisementFormat.prefix else { return false }
        let serialPrefixEnd = 1 + Sibionics2AdvertisementFormat.serialPrefixDigitCount
        return normalized[1..<serialPrefixEnd].allSatisfy {
            Sibionics2AdvertisementFormat.decimalASCIIRange.contains($0)
        }
    }

    static func matchesSearch(name: String, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedQuery.isEmpty else { return true }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .contains(normalizedQuery)
    }
}

/// MAC representation required by the Sibionics V120 authentication packet.
private enum Sibionics2BluetoothAddressFormat {
    static let byteCount = 6
    static let hexDigitsPerByte = 2
    static let separator: Character = ":"
    static let compactHexCharacterCount = byteCount * hexDigitsPerByte
    static let hexadecimalDigits = CharacterSet(charactersIn: "0123456789ABCDEF")
}

/// Resolves the Bluetooth address carried by the V120 authentication packet.
/// iOS does not publish a public MAC API; some CoreBluetooth versions expose
/// private selectors used by the reference apps, so the explicit address field
/// remains available as a fallback when those selectors are absent.
enum Sibionics2AuthenticationAddress {
    private static let keyPrefix = "sibionics2.authenticationAddress."
    private static let detectedKeyPrefix = "sibionics2.detectedBluetoothAddress."
    private static let candidatesKeyPrefix = "sibionics2.bluetoothAddressCandidates."
    private static let maximumStoredCandidates = 6
    /// Device Information characteristics that commonly carry the BLE address.
    static let deviceInformationServiceUUID = CBUUID(string: "180A")
    static let systemIDCharacteristicUUID = CBUUID(string: "2A23")
    static let serialNumberCharacteristicUUID = CBUUID(string: "2A25")

    static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let compact: String

        if trimmed.contains(Sibionics2BluetoothAddressFormat.separator) {
            let octets = trimmed.split(
                separator: Sibionics2BluetoothAddressFormat.separator,
                omittingEmptySubsequences: false
            )
            guard octets.count == Sibionics2BluetoothAddressFormat.byteCount,
                  octets.allSatisfy({
                      $0.unicodeScalars.count == Sibionics2BluetoothAddressFormat.hexDigitsPerByte &&
                          $0.unicodeScalars.allSatisfy({
                              Sibionics2BluetoothAddressFormat.hexadecimalDigits.contains($0)
                          })
                  }) else { return nil }
            compact = octets.map { String($0) }.joined()
        } else {
            guard trimmed.unicodeScalars.count == Sibionics2BluetoothAddressFormat.compactHexCharacterCount,
                  trimmed.unicodeScalars.allSatisfy({
                      Sibionics2BluetoothAddressFormat.hexadecimalDigits.contains($0)
                  }) else {
                return nil
            }
            compact = trimmed
        }

        let bytes = stride(
            from: 0,
            to: compact.count,
            by: Sibionics2BluetoothAddressFormat.hexDigitsPerByte
        ).compactMap { offset -> UInt8? in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: Sibionics2BluetoothAddressFormat.hexDigitsPerByte)
            return UInt8(compact[start..<end], radix: 16)
        }
        guard bytes.count == Sibionics2BluetoothAddressFormat.byteCount,
              bytes.contains(where: { $0 != 0 }),
              bytes.contains(where: { $0 != 0xFF }) else { return nil }
        return bytes.map { String(format: "%02X", Int($0)) }
            .joined(separator: String(Sibionics2BluetoothAddressFormat.separator))
    }

    static func address(from value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return normalize(text) }
        if let data = value as? Data, data.count == Sibionics2BluetoothAddressFormat.byteCount {
            let formattedAddress = data
                .map { String(format: "%02X", Int($0)) }
                .joined(separator: String(Sibionics2BluetoothAddressFormat.separator))
            return normalize(formattedAddress)
        }
        if let data = value as? NSData, data.length == Sibionics2BluetoothAddressFormat.byteCount {
            return address(from: Data(referencing: data))
        }
        if let numbers = value as? [NSNumber],
           numbers.count == Sibionics2BluetoothAddressFormat.byteCount,
           numbers.allSatisfy({ (0...255).contains($0.intValue) }) {
            let formattedAddress = numbers
                .map { String(format: "%02X", $0.intValue) }
                .joined(separator: String(Sibionics2BluetoothAddressFormat.separator))
            return normalize(formattedAddress)
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

    /// Addresses a manufacturer-data payload may carry after its 2-byte company
    /// identifier. Byte order is not standardized, so both orders are offered and
    /// only an address that later produces glucose readings is kept as detected.
    static func advertisementCandidates(manufacturerData: Data?) -> [String] {
        guard let manufacturerData else { return [] }
        let bytes = [UInt8](manufacturerData)
        let byteCount = Sibionics2BluetoothAddressFormat.byteCount
        let companyIdentifierLength = 2
        var windows = [[UInt8]]()
        if bytes.count == byteCount {
            windows.append(bytes)
        }
        if bytes.count >= companyIdentifierLength + byteCount {
            windows.append(Array(bytes[companyIdentifierLength..<(companyIdentifierLength + byteCount)]))
            if bytes.count > companyIdentifierLength + byteCount {
                windows.append(Array(bytes.suffix(byteCount)))
            }
        }
        return unique(windows.flatMap { [address(from: Data($0)), address(from: Data($0.reversed()))] }
            .compactMap { $0 })
    }

    /// Decodes a Device Information System ID built from the BLE address, where
    /// FFFE is inserted between its OUI and device-specific bytes (EUI-64 style).
    static func systemIDAddress(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count == 8,
              (bytes[3] == 0xFE && bytes[4] == 0xFF) || (bytes[3] == 0xFF && bytes[4] == 0xFE) else { return nil }
        // System ID is little endian; the printed address is most significant byte first.
        return address(from: Data([bytes[7], bytes[6], bytes[5], bytes[2], bytes[1], bytes[0]]))
    }

    /// A Device Information serial number that is itself a BLE address.
    static func serialNumberAddress(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return normalize(text.trimmingCharacters(in: .controlCharacters))
    }

    static func candidates(for identifier: String, userDefaults: UserDefaults = .standard) -> [String] {
        guard let key = candidatesKey(for: identifier) else { return [] }
        return (userDefaults.stringArray(forKey: key) ?? []).compactMap(normalize)
    }

    /// Stores unverified addresses, keeping the newest first.
    @discardableResult
    static func addCandidates(_ values: [String], for identifier: String, userDefaults: UserDefaults = .standard) -> Bool {
        guard let key = candidatesKey(for: identifier) else { return false }
        let existing = candidates(for: identifier, userDefaults: userDefaults)
        let updated = Array(unique(values.compactMap(normalize) + existing).prefix(maximumStoredCandidates))
        guard updated != existing else { return false }
        userDefaults.set(updated, forKey: key)
        return true
    }

    /// Addresses to try in authentication, one per connection. A manual address
    /// is used alone; otherwise the detected address leads, unverified candidates
    /// follow, and `nil` (the zero address) is the final fallback.
    static func authenticationCandidates(for identifier: String, userDefaults: UserDefaults = .standard) -> [String?] {
        if let manual = override(for: identifier, userDefaults: userDefaults) { return [manual] }
        let automatic = unique([detected(for: identifier, userDefaults: userDefaults)].compactMap { $0 }
            + candidates(for: identifier, userDefaults: userDefaults))
        return automatic.map { Optional($0) } + [nil]
    }

    /// Removes everything learned automatically for a peripheral.
    static func clearAutomatic(for identifier: String, userDefaults: UserDefaults = .standard) {
        if let key = detectedKey(for: identifier) { userDefaults.removeObject(forKey: key) }
        if let key = candidatesKey(for: identifier) { userDefaults.removeObject(forKey: key) }
    }

    static func macBytes(address: String?) -> [UInt8] {
        guard let address = address.flatMap(normalize) else {
            return [UInt8](repeating: 0, count: Sibionics2BluetoothAddressFormat.byteCount)
        }
        return address
            .split(separator: Sibionics2BluetoothAddressFormat.separator)
            .compactMap { UInt8($0, radix: 16) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
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
        macBytes(address: effectiveAddress(for: identifier, userDefaults: userDefaults))
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

    private static func candidatesKey(for identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return candidatesKeyPrefix + normalized
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
        self.macAddress = macAddress.count == Sibionics2BluetoothAddressFormat.byteCount
            ? macAddress
            : [UInt8](repeating: 0, count: Sibionics2BluetoothAddressFormat.byteCount)
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

    var isAwaitingAuthentication: Bool {
        if case .awaitingAuthentication = phase { return true }
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
        case (.awaitingStreaming, .dataRequested):
            // The sensor repeats the request when the previous write did not arrive.
            return codec.buildDataRequestPacket(lastIndex: lastDeliveredIndex ?? 0)
        case (.awaitingTimeSync, .streamingReady), (.awaitingDataRequest, .streamingReady),
             (.awaitingStreaming, .streamingReady):
            // Some firmware acknowledges streaming without asking for a data request.
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
