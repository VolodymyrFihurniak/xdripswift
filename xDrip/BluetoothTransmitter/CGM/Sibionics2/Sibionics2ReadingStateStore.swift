import Foundation

struct Sibionics2ReadingState: Codable {
    let lastDeliveredIndex: UInt16?
    let processorSnapshot: Data?
    let sensorStartDate: Date?
}

/// Persists one independent decoder/processor continuation per saved BLE peripheral.
final class Sibionics2ReadingStateStore {
    private let userDefaults: UserDefaults
    private let keyPrefix = "sibionics2.readingState."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load(for address: String) -> Sibionics2ReadingState? {
        guard let data = userDefaults.data(forKey: key(for: address)) else { return nil }
        return try? JSONDecoder().decode(Sibionics2ReadingState.self, from: data)
    }

    func save(_ state: Sibionics2ReadingState, for address: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: key(for: address))
    }

    func clear(for address: String) {
        userDefaults.removeObject(forKey: key(for: address))
    }

    private func key(for address: String) -> String {
        keyPrefix + address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
