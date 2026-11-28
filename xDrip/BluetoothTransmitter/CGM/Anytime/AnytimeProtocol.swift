//
//  AnytimeProtocol.swift
//  xdrip
//
//  Pure protocol layer of the Anytime / Yuwell CGM driver: the GATT layout, the opcode catalogue, the
//  family table that identifies a sensor from its Bluetooth name, the per-family profile, the frame
//  builders and parsers (plain, summed and CT5 encrypted frames), the CT5 identity helpers and the
//  sensor code (QR) parser. Ported from the JugglucoNG `drivers/anytime` package (GPL-3.0, see
//  THIRD_PARTY_NOTICES.md). Nothing here touches Bluetooth, so everything is covered by unit tests
//  (`AnytimeProtocolTests`) whose expected values were computed by running the unchanged Kotlin on the JVM.
//
//  Not ported here: the vendor native library path (JugglucoNG does not ship it either), the CT5
//  credential export file and the SharedPreferences registry (the transmitter keeps its own state).
//
//  Never tried on a real sensor.
//

import CoreBluetooth
import Foundation

// MARK: - Kotlin-compatible number helpers

/// Kotlin `Float.toInt()`: truncates toward zero and saturates; NaN is 0. Swift's `Int(_:)` would trap.
func anytimeKotlinInt(_ value: Float) -> Int {
    if value.isNaN { return 0 }
    if value >= 2147483647 { return Int(Int32.max) }
    if value <= -2147483648 { return Int(Int32.min) }
    return Int(value)
}

/// Kotlin `Float.roundToInt()`: ties go toward positive infinity (`Math.round`), computed without the
/// precision loss of `floor(x + 0.5)`.
func anytimeKotlinRound(_ value: Float) -> Int {
    if value.isNaN { return 0 }
    if value >= 2147483647 { return Int(Int32.max) }
    if value <= -2147483648 { return Int(Int32.min) }
    let floored = value.rounded(.down)
    let rounded = (value - floored) >= 0.5 ? floored + 1 : floored
    return Int(rounded)
}

/// Kotlin `Int.coerceIn`.
func anytimeClamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
    return min(max(value, low), high)
}

// MARK: - GATT

enum AnytimeGATT {
    /// Proprietary 128-bit service of every family except the oldest (CT2).
    static let primaryService = CBUUID(string: "00001000-1212-efde-1523-785feabcd123")
    static let primaryNotify = CBUUID(string: "00001001-1212-efde-1523-785feabcd123")
    static let primaryWrite = CBUUID(string: "00001002-1212-efde-1523-785feabcd123")

    /// Legacy CT2 (Telink chip) service.
    static let legacyService = CBUUID(string: "FFF0")
    static let legacyNotify = CBUUID(string: "FFF2")
    static let legacyWrite = CBUUID(string: "FFF1")
}

// MARK: - Opcodes and constants

enum AnytimeOpcode {
    // phone to sensor
    static let txVersion: UInt8 = 0x01
    static let txSetDate: UInt8 = 0x03
    static let txCheck: UInt8 = 0x05
    static let txInit: UInt8 = 0x06
    static let txPullGlucose: UInt8 = 0x08
    static let txPullGlucoseSeries: UInt8 = 0x22
    static let txInputBgMg: UInt8 = 0x09
    static let txUnbind: UInt8 = 0x0A
    static let txInputKR: UInt8 = 0x0B
    static let txFetchComputedGlucose: UInt8 = 0x0C
    static let txLowPower: UInt8 = 0x0F
    static let txReset: UInt8 = 0x11
    static let txModifyVoltage: UInt8 = 0x15
    static let txTransmitterFormal: UInt8 = 0x20
    static let txCt5SetId: UInt8 = 0x30
    static let txCt5CheckId: UInt8 = 0x31
    static let txCt5PushAck: UInt8 = 0x35
    static let txCt5PullSeries: UInt8 = 0x37
    static let txCt5SetParameters: UInt8 = 0x38
    static let txCt5QuerySsn: UInt8 = 0x3F

    // sensor to phone
    static let rxVersion: UInt8 = 0x01
    static let rxSetDateAckA: UInt8 = 0x03
    static let rxSetDateAckB: UInt8 = 0x04
    static let rxCheck: UInt8 = 0x05
    static let rxInit: UInt8 = 0x06
    static let rxPushGlucose: UInt8 = 0x07
    static let rxPullGlucose: UInt8 = 0x08
    static let rxInputBgAck: UInt8 = 0x09
    static let rxUnbindAck: UInt8 = 0x0A
    static let rxUnbindAckGeneric: UInt8 = 0x58
    static let rxInputKRAck: UInt8 = 0x0B
    static let rxComputedGlucose: UInt8 = 0x0C
    static let rxLowPowerAck: UInt8 = 0x0F
    static let rxReset: UInt8 = 0x11
    static let rxModifyVoltage: UInt8 = 0x15
    static let rxTransmitterFormal: UInt8 = 0x20
    static let rxSeries: UInt8 = 0x22
    static let rxLegacyRawDump: UInt8 = 0x0D
    static let rxCt5CheckId: UInt8 = 0x31
    static let rxCt5PushGlucose: UInt8 = 0x35
    static let rxCt5Series: UInt8 = 0x37
    static let rxCt5SetParameters: UInt8 = 0x38
    static let rxCt5QuerySsn: UInt8 = 0x3F

    // CT2 (legacy) namespace
    static let txCt2Version: UInt8 = 0x03
    static let txCt2Handshake: UInt8 = 0x48
    static let txCt2SetDate: UInt8 = 0x54
    static let txCt2Init: UInt8 = 0x53
    static let txCt2Check: UInt8 = 0x43
    static let txCt2LowPower: UInt8 = 0x57
    static let txCt2Unbind: UInt8 = 0x58
    static let txCt2PullGlucose: UInt8 = 0x55
    static let txCt2InputBgMg: UInt8 = 0x08
    static let rxCt2HandshakeAck: UInt8 = 0x48
    static let rxCt2SetDateAck: UInt8 = 0x54
    static let rxCt2InitAck: UInt8 = 0x53
    static let rxCt2Check: UInt8 = 0x43
    static let rxCt2PushGlucose: UInt8 = 0x44
    static let rxCt2PullResponse: UInt8 = 0x47
}

enum AnytimeConstants {
    static let defaultDisplayName = "Anytime CGM"
    static let provisionalSensorPrefix = "ANY-"
    static let maxNativeSensorIdChars = 16

    static let rawRecordSize = 9
    static let wideRawRecordSize = 11
    static let wideRawSeriesChunkSize = 6
    static let ct5RawChunkSize = 11
    static let ct5VoltageChunkSize = 15
    static let rawRecordContinuationSize = 8
    static let computedRecordSize = 19
    /// The sensor adds 40 to the integer part of the temperature.
    static let tempIntOffset = 40

    static let batteryLowVoltsCT3: Float = 4.05
    static let batteryLowVoltsCT3A: Float = 3.9
    static let batteryLowVoltsCT25: Float = 2.97
    static let batteryLowVoltsCT4: Float = 2.97
    static let batteryFullVolts: Float = 4.2

    static let defaultRatedLifetimeDays = 16
    static let defaultReadingIntervalMinutes = 3
    static let defaultWarmupMinutes = 60
    static let ct5WarmupMinutes = 40
    static let ct5DefaultK: Float = 1.10
    static let ct5DefaultR: Float = 1.0

    /// Output clamp of the algorithms, mg/dL times 10.
    static let algoMgdlMinTimes10 = 170
    static let algoMgdlMaxTimes10 = 4000
    static let algoMmolFloor: Float = 2.2

    /// CT-14 (CT2 family) empirical model.
    static let ct14AgingNaPerDay: Float = 0.4
    static let ct14DefaultSlope: Float = 1.667
    static let ct14DefaultIntercept: Float = 3.33
    /// CT4 reference K0, used when no sensor code gives one.
    static let ct4DefaultK0: Float = 1.13

    /// A link that delivers no data for this long is recycled (JugglucoNG `PULL_WATCHDOG_SECONDS`).
    static let pullWatchdogSeconds: TimeInterval = 190

    /// Whether a sample falls inside the post-activation settling window (a property of the sample,
    /// not of the wall clock, so a history replay reaches the same verdict as the live path).
    static func isWithinWarmup(anchorMs: Int64, sampleMs: Int64, windowMs: Int64) -> Bool {
        return anchorMs > 0 && sampleMs > 0 && windowMs > 0 && sampleMs < anchorMs + windowMs
    }

    /// Whether a CT5 that entered streaming should be re-bound: it has never delivered a frame and no
    /// 0x35/0x37 notification of any kind arrived since streaming began.
    static func ct5CachedCipherLooksUnbound(lastGlucoseId: Int, lastDataRxAtMs: Int64, streamingSinceMs: Int64) -> Bool {
        return lastGlucoseId < 0 && lastDataRxAtMs < streamingSinceMs
    }

    /// Opcodes the CT-14 (CT2 family) owns, including its unbind ack. 0x08 and 0x09 mean different things
    /// in the CT2 and CT3 namespaces, and 0x58 is the CT2 unbind ack but the CT5 generic one.
    static func isCt14Opcode(_ opcode: UInt8) -> Bool {
        switch opcode {
        case AnytimeOpcode.rxCt2HandshakeAck,
             AnytimeOpcode.rxCt2SetDateAck,
             AnytimeOpcode.rxCt2InitAck,
             AnytimeOpcode.rxCt2Check,
             AnytimeOpcode.rxCt2PushGlucose,
             AnytimeOpcode.rxCt2PullResponse,
             AnytimeOpcode.rxUnbindAckGeneric:
            return true
        default:
            return false
        }
    }
}

// MARK: - Families

enum AnytimeFamily: String, Codable, CaseIterable {
    case ct2
    case ct25
    case ct3
    case ct3Plus
    case ct3Yuwell
    case ct3Ultrasonic
    case ct4
    case ct5
    case unknown

    var displayName: String {
        switch self {
        case .ct2: return "CT2"
        case .ct25: return "CT2.5"
        case .ct3: return "CT3"
        case .ct3Plus: return "CT3-Plus"
        case .ct3Yuwell: return "CT3-Yuwell"
        case .ct3Ultrasonic: return "CT3-Ultrasonic"
        case .ct4: return "CT4"
        case .ct5: return "CT5"
        case .unknown: return "Unknown"
        }
    }

    /// CT2 uses the 16-bit 0xFFF0 service, every other family the proprietary 128-bit one.
    var needsLegacyUuids: Bool { return self == .ct2 }

    /// The CT3 families whose glucose JugglucoNG computes with its CT3 kernel.
    var isCt3Kernel: Bool {
        switch self {
        case .ct3, .ct3Plus, .ct3Yuwell, .ct3Ultrasonic: return true
        default: return false
        }
    }
}

struct AnytimeFamilyEntry: Equatable {
    let prefix: String
    let family: AnytimeFamily
    /// The vendor algorithm id (selects the chemistry specific pipeline in the vendor library).
    let algorithm: Int
    /// The vendor's nominal record horizon.
    let endNumber: Int

    var ratedLifetimeDays: Int { return endNumber / 20 / 24 }
    var matchUpper: String { return prefix.uppercased() }
}

enum AnytimeFamilies {
    static let table: [AnytimeFamilyEntry] = [
        // CT2 (legacy 0xFFF0 chip)
        AnytimeFamilyEntry(prefix: "SN04", family: .ct2, algorithm: 8, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN06", family: .ct2, algorithm: 6, endNumber: 3420),
        AnytimeFamilyEntry(prefix: "SN08", family: .ct2, algorithm: 1, endNumber: 6720),
        AnytimeFamilyEntry(prefix: "SN12", family: .ct2, algorithm: 1, endNumber: 4800),
        AnytimeFamilyEntry(prefix: "SN18", family: .ct2, algorithm: 7, endNumber: 3380),
        AnytimeFamilyEntry(prefix: "SN20", family: .ct2, algorithm: 7, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN22", family: .ct2, algorithm: 1, endNumber: 4800),
        AnytimeFamilyEntry(prefix: "SN48", family: .ct2, algorithm: 7, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN50", family: .ct2, algorithm: 7, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN52", family: .ct2, algorithm: 7, endNumber: 6740),
        // CT2.5
        AnytimeFamilyEntry(prefix: "SN30", family: .ct25, algorithm: 7, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN32", family: .ct25, algorithm: 7, endNumber: 3380),
        AnytimeFamilyEntry(prefix: "SN36", family: .ct25, algorithm: 7, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN38", family: .ct25, algorithm: 7, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN40", family: .ct25, algorithm: 7, endNumber: 6740),
        // CT3 (4 / 4H is SN16)
        AnytimeFamilyEntry(prefix: "SN16", family: .ct3, algorithm: 3, endNumber: 6740),
        // CT3 Yuwell
        AnytimeFamilyEntry(prefix: "SN26", family: .ct3Yuwell, algorithm: 3, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN28", family: .ct3Yuwell, algorithm: 3, endNumber: 3380),
        AnytimeFamilyEntry(prefix: "SN42", family: .ct3Yuwell, algorithm: 3, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN46", family: .ct3Yuwell, algorithm: 3, endNumber: 6740),
        // CT3 Plus
        AnytimeFamilyEntry(prefix: "SN56", family: .ct3Plus, algorithm: 3, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN58", family: .ct3Plus, algorithm: 3, endNumber: 3380),
        AnytimeFamilyEntry(prefix: "SN60", family: .ct3Plus, algorithm: 3, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN62", family: .ct3Plus, algorithm: 3, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN66", family: .ct3Plus, algorithm: 3, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN68", family: .ct3Plus, algorithm: 3, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN70", family: .ct3Plus, algorithm: 12, endNumber: 6740),
        // CT3 Ultrasonic
        AnytimeFamilyEntry(prefix: "SN17", family: .ct3Ultrasonic, algorithm: 9, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN27", family: .ct3Ultrasonic, algorithm: 12, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN29", family: .ct3Ultrasonic, algorithm: 12, endNumber: 3380),
        AnytimeFamilyEntry(prefix: "SN43", family: .ct3Ultrasonic, algorithm: 9, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN47", family: .ct3Ultrasonic, algorithm: 9, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN91", family: .ct3Ultrasonic, algorithm: 10, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN96", family: .ct3Ultrasonic, algorithm: 12, endNumber: 6740),
        AnytimeFamilyEntry(prefix: "SN98", family: .ct3Ultrasonic, algorithm: 12, endNumber: 6740),
        // CT4 (voltage switching)
        AnytimeFamilyEntry(prefix: "SN72", family: .ct4, algorithm: 10, endNumber: 7220),
        AnytimeFamilyEntry(prefix: "SN76", family: .ct4, algorithm: 10, endNumber: 7220),
        AnytimeFamilyEntry(prefix: "SN78", family: .ct4, algorithm: 10, endNumber: 7220),
        AnytimeFamilyEntry(prefix: "SN80", family: .ct4, algorithm: 10, endNumber: 7220),
        AnytimeFamilyEntry(prefix: "SN82", family: .ct4, algorithm: 10, endNumber: 3860),
        AnytimeFamilyEntry(prefix: "SN86", family: .ct4, algorithm: 10, endNumber: 3860),
        AnytimeFamilyEntry(prefix: "SN87", family: .ct4, algorithm: 10, endNumber: 7220),
        AnytimeFamilyEntry(prefix: "SN88", family: .ct4, algorithm: 10, endNumber: 7220),
        AnytimeFamilyEntry(prefix: "SN90", family: .ct4, algorithm: 10, endNumber: 4820),
        // CT5 (integrated transmitter and sensor, encrypted identity and data layer)
        AnytimeFamilyEntry(prefix: "Anytime", family: .ct5, algorithm: 11, endNumber: 7695)
    ]

    /// Fallback when the advertised name matches no known prefix.
    static let unknown = AnytimeFamilyEntry(prefix: "UNKNOWN", family: .unknown, algorithm: 3, endNumber: 6740)

    static func resolve(_ deviceName: String?) -> AnytimeFamilyEntry {
        let trimmed = (deviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 4 { return unknown }
        let upper = trimmed.uppercased()
        if let entry = table.first(where: { upper.hasPrefix($0.matchUpper) }) {
            return entry
        }
        return unknown
    }

    /// A known SN## identity beats the shared "Anytime" brand prefix, whichever source it came from:
    /// SN91 was seen renaming itself to "Anytime  4pro" at the same address. Connect-time names are
    /// preferred over cached or serial names within that specificity; CT5 is selected by brand only
    /// when no SN## is known. If nothing classifies, the first non-blank name wins.
    static func resolveHandshakeName(cachedName: String?, connectedName: String?, activeName: String?, serial: String?) -> String {
        let trimmed = [connectedName, activeName, cachedName, serial].map {
            ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let specific = trimmed.first(where: {
            let family = resolve($0).family
            return family != .unknown && family != .ct5
        }) {
            return specific
        }
        if let known = trimmed.first(where: { resolve($0).family != .unknown }) {
            return known
        }
        return trimmed.first(where: { !$0.isEmpty }) ?? ""
    }

    static func isAnytimeDevice(_ name: String?) -> Bool {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        return resolve(trimmed).family != .unknown || isLikelyPersistedSensorName(trimmed)
    }

    /// Only the CT2 generation answers the on-demand electrode-current self-test.
    static func supportsSelfTest(_ family: AnytimeFamily) -> Bool {
        return family == .ct2
    }

    static func isLikelyPersistedSensorName(_ name: String?) -> Bool {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if isProvisionalSensorId(trimmed) { return true }
        return AnytimeText.matches(trimmed, pattern: "^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$", caseInsensitive: true) ||
            AnytimeText.matches(trimmed, pattern: "^[0-9A-F]{12,16}$", caseInsensitive: true)
    }

    static func isProvisionalSensorId(_ name: String?) -> Bool {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.uppercased().hasPrefix(AnytimeConstants.provisionalSensorPrefix)
    }

    /// Canonical sensor identity: a Bluetooth MAC collapses to colon-free upper case, an advertised
    /// name stays as it is.
    static func canonicalSensorId(_ sensorId: String?) -> String {
        let trimmed = (sensorId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if AnytimeText.matches(trimmed, pattern: "^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$", caseInsensitive: true) {
            return trimmed.uppercased().replacingOccurrences(of: ":", with: "")
        }
        if AnytimeText.matches(trimmed, pattern: "^[0-9A-F]{12,16}$", caseInsensitive: true) {
            return String(trimmed.uppercased().prefix(AnytimeConstants.maxNativeSensorIdChars))
        }
        return trimmed
    }

    static func macAddress(fromSensorId sensorId: String?) -> String? {
        let canonical = canonicalSensorId(sensorId)
        if !AnytimeText.matches(canonical, pattern: "^[0-9A-F]{12}$", caseInsensitive: true) { return nil }
        let characters = Array(canonical)
        var parts = [String]()
        var index = 0
        while index < characters.count {
            parts.append(String(characters[index..<min(index + 2, characters.count)]))
            index += 2
        }
        return parts.joined(separator: ":")
    }

    static func matchesCanonicalOrKnownNativeAlias(_ a: String?, _ b: String?) -> Bool {
        let ca = canonicalSensorId(a).uppercased()
        let cb = canonicalSensorId(b).uppercased()
        if ca.isEmpty || cb.isEmpty { return false }
        if ca == cb { return true }
        let hex = Set("0123456789ABCDEF")
        if !ca.allSatisfy({ hex.contains($0) }) || !cb.allSatisfy({ hex.contains($0) }) { return false }
        let shorter = ca.count < cb.count ? ca : cb
        let longer = ca.count < cb.count ? cb : ca
        return shorter.count >= 7 && longer.hasSuffix(shorter)
    }

    static func deriveInitialSensorId(deviceName: String?, address: String?) -> String {
        let addr = canonicalSensorId(address)
        if !addr.isEmpty && AnytimeText.matches(addr, pattern: "^[0-9A-F]{12,16}$", caseInsensitive: false) {
            return addr
        }
        let letters = (deviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        let limit = AnytimeConstants.maxNativeSensorIdChars - AnytimeConstants.provisionalSensorPrefix.count
        var fallback = String(letters.prefix(limit))
        if fallback.isEmpty { fallback = "PENDING" }
        return AnytimeConstants.provisionalSensorPrefix + fallback
    }
}

// MARK: - Profile

struct AnytimeProfile: Equatable {
    let family: AnytimeFamily
    /// Minutes between consecutive glucose ids. One id is one tick.
    let readingIntervalMinutes: Int
    let warmupMinutes: Int
    let ratedLifetimeDays: Int
    let algorithmId: Int
    let endNumber: Int
    let lowBatteryVolts: Float

    var ratedLifetimeMs: Int64 { return Int64(ratedLifetimeDays) * 24 * 60 * 60 * 1000 }
    var warmupMs: Int64 { return Int64(warmupMinutes) * 60 * 1000 }
    /// Glucose ids covered by the warm-up window at this family's cadence.
    var warmupRecords: Int {
        return readingIntervalMinutes <= 0 ? 0 : warmupMinutes / readingIntervalMinutes
    }
}

enum AnytimeProfileResolver {
    static let defaultProfile = AnytimeProfile(
        family: .unknown,
        readingIntervalMinutes: AnytimeConstants.defaultReadingIntervalMinutes,
        warmupMinutes: AnytimeConstants.defaultWarmupMinutes,
        ratedLifetimeDays: AnytimeConstants.defaultRatedLifetimeDays,
        algorithmId: 3,
        endNumber: 6740,
        lowBatteryVolts: AnytimeConstants.batteryLowVoltsCT3
    )

    static func resolve(_ deviceName: String? = nil) -> AnytimeProfile {
        let entry = AnytimeFamilies.resolve(deviceName)
        if entry.family == .unknown { return defaultProfile }

        let readingMinutes = AnytimeConstants.defaultReadingIntervalMinutes

        // CT5 warm-up is shorter than the shared default. CT2 warm-up is initNumber x 3 minutes:
        // SN06 and SN12 are 180, every other prefix 60.
        let warmupMinutes: Int
        if entry.family == .ct2 && (entry.prefix == "SN06" || entry.prefix == "SN12") {
            warmupMinutes = 180
        } else if entry.family == .ct2 {
            warmupMinutes = 60
        } else if entry.family == .ct5 {
            warmupMinutes = AnytimeConstants.ct5WarmupMinutes
        } else {
            warmupMinutes = AnytimeConstants.defaultWarmupMinutes
        }

        // CT2 battery is a percentage in the record and check bytes, so its volt threshold is unused.
        let lowVolts: Float
        switch entry.family {
        case .ct25: lowVolts = AnytimeConstants.batteryLowVoltsCT25
        case .ct4: lowVolts = AnytimeConstants.batteryLowVoltsCT4
        case .ct3Plus, .ct3Yuwell, .ct3Ultrasonic: lowVolts = AnytimeConstants.batteryLowVoltsCT3A
        default: lowVolts = AnytimeConstants.batteryLowVoltsCT3
        }

        let lifetime = max(7, Int((Int64(entry.endNumber) * Int64(readingMinutes)) / (60 * 24)))
        return AnytimeProfile(
            family: entry.family,
            readingIntervalMinutes: readingMinutes,
            warmupMinutes: warmupMinutes,
            ratedLifetimeDays: lifetime,
            algorithmId: entry.algorithm,
            endNumber: entry.endNumber,
            lowBatteryVolts: lowVolts
        )
    }
}

// MARK: - Text helpers

enum AnytimeText {
    /// Whole-string regular expression match, returning the capture groups ("" for a group that did not
    /// take part, as Kotlin `groupValues` does). The match must cover the entire string.
    static func fullMatch(_ text: String, pattern: String, caseInsensitive: Bool = false) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: whole), match.range == whole else { return nil }
        var groups = [String]()
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location == NSNotFound {
                groups.append("")
            } else if let swiftRange = Range(range, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    static func matches(_ text: String, pattern: String, caseInsensitive: Bool = false) -> Bool {
        return fullMatch(text, pattern: pattern, caseInsensitive: caseInsensitive) != nil
    }

    static func hex(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func compactHex(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func bytes(fromHex text: String) -> [UInt8] {
        let digits = text.filter { $0.isHexDigit }
        var result = [UInt8]()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) ?? digits.endIndex
            if let value = UInt8(digits[index..<next], radix: 16) { result.append(value) }
            index = next
        }
        return result
    }
}

// MARK: - Records

/// One raw current record from a 0x07 push, a 0x08 pull, a 0x22 series, or a CT2 0x44/0x47 frame.
struct AnytimeRawRecord: Equatable {
    var indexInPacket: Int
    var glucoseId: Int
    var ibNa: Float
    var iwNa: Float
    var temperatureC: Float
    var recordBytes: [UInt8]
}

/// A computed-glucose record (CT5 push and series, CT3 on demand).
///
/// A CT5 frame has three possible outcomes that must stay distinguishable: malformed (the parser
/// returns nil), valid without glucose (`hasGlucose` false: warm-up telemetry) and valid with glucose.
struct AnytimeComputedRecord: Equatable {
    var glucoseId: Int
    var hypoEarlyWarnMinutes: Int
    var hyperEarlyWarnMinutes: Int
    var ibNa: Float
    var iwNa: Float
    var temperatureC: Float
    var gluMmol: Float
    var referenceBgMmol: Float
    var errorCode: Int
    var trend: Int
    var warnCode: Int
    var hasGlucose: Bool = true
    /// Marks a field the frame does not carry (the Kotlin `Int.MIN_VALUE`, kept 32-bit so the values match).
    static let unset = Int(Int32.min)
    /// Electrode potentials of the 15-byte chunk, `unset` when the chunk does not carry them.
    var beVoltageMv: Int = AnytimeComputedRecord.unset
    var weVoltageMv: Int = AnytimeComputedRecord.unset
    var reVoltageMv: Int = AnytimeComputedRecord.unset
    var ceVoltageMv: Int = AnytimeComputedRecord.unset
    /// Transmitter supply reading, raw and of unverified unit, so it is never used as a battery level.
    var batteryRaw: Int = AnytimeComputedRecord.unset

    var gluMgdl: Int { return anytimeKotlinInt(gluMmol * 18.0 + 0.5) }
}

struct AnytimeCt5CipherCandidate: Equatable {
    let cipherKey: Int
    let record: AnytimeComputedRecord
}

enum AnytimeCheckFailure: Equatable {
    case lowBattery
    case lowIw
    case badTemperature
    case malformed
}

/// 0x05 check response: battery, sensor age, working electrode current.
struct AnytimeCheckStatus: Equatable {
    let sensorAgeReadings: Int
    let workingElectrodeCurrentNa: Float
    let batteryVolts: Float
    let isHealthy: Bool
    let failure: AnytimeCheckFailure?
}

struct AnytimeResetStatus: Equatable {
    let isBound: Bool
}

/// The strict CT5 0x11 answer: 14 bytes and a valid sum are required before the bind flag is read.
struct AnytimeCt5BindState: Equatable {
    let isBound: Bool
    /// 1 charge, 0 other, -1 when the transmitter did not say.
    let unbindReason: Int
}

struct AnytimeCt2GlucoseFrame: Equatable {
    let record: AnytimeRawRecord
    let isHistorical: Bool
    let batteryPercent: Int?
    /// The transmitter's own end-of-history marker on a pull response (`id == 0xFFFF`).
    let isEndOfHistory: Bool
}

struct AnytimeCt2CheckResult: Equatable {
    let iwNa: Float
    let ibNa: Float
    let temperatureC: Float
    let powerByte: Int
    let passed: Bool
}

// MARK: - Frames

enum AnytimeFrames {

    // MARK: integrity

    /// The 8-bit sum of `bytes[from...to]`.
    static func sum(_ bytes: [UInt8], from: Int = 0, to: Int? = nil) -> UInt8 {
        let last = to ?? (bytes.count - 2)
        var acc = 0
        var index = from
        while index <= last && index < bytes.count {
            if index >= 0 { acc += Int(bytes[index]) }
            index += 1
        }
        return UInt8(truncatingIfNeeded: acc)
    }

    /// Whether the trailing byte equals the sum of everything before it.
    static func verifySum(_ bytes: [UInt8]) -> Bool {
        if bytes.count < 2 { return false }
        return bytes[bytes.count - 1] == sum(bytes, from: 0, to: bytes.count - 2)
    }

    private static func withSum(_ values: [Int]) -> [UInt8] {
        var frame = values.map { UInt8(truncatingIfNeeded: $0) }
        frame.append(sum(frame, from: 0, to: frame.count - 1))
        return frame
    }

    // MARK: builders (phone to sensor)

    enum Builders {
        static func version() -> [UInt8] { return [AnytimeOpcode.txVersion] }

        /// `{0x05}` health check.
        static func check() -> [UInt8] { return [AnytimeOpcode.txCheck] }
        /// `{0x05, 0x55, 0xAA, sum}` for the families that sum their requests.
        static func checkSummed() -> [UInt8] { return AnytimeFrames.withSum([0x05, 0x55, 0xAA]) }

        static func initFrame() -> [UInt8] { return [AnytimeOpcode.txInit] }
        static func initSummed() -> [UInt8] { return AnytimeFrames.withSum([0x06, 0x55, 0xAA]) }

        static func lowPower() -> [UInt8] { return [AnytimeOpcode.txLowPower] }
        static func lowPowerSummed() -> [UInt8] { return AnytimeFrames.withSum([0x0F, 0x55, 0xAA]) }

        static func reset() -> [UInt8] { return [AnytimeOpcode.txReset] }
        static func resetSummed() -> [UInt8] { return AnytimeFrames.withSum([0x11, 0x55, 0xAA]) }

        static func unbind() -> [UInt8] { return [AnytimeOpcode.txUnbind] }
        static func unbindSummed() -> [UInt8] { return AnytimeFrames.withSum([0x0A, 0x55, 0xAA]) }

        /// The vendor SDK's family-less unbind, `{0x58, 0x55, 0xAA, 0x57}`.
        static func unbindGeneric() -> [UInt8] { return AnytimeFrames.withSum([0x58, 0x55, 0xAA]) }

        private static func clockComponents(_ date: Date, _ calendar: Calendar) -> DateComponents {
            return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        }

        /// `{0x03, year-1900, month, day, hour, minute, second}`.
        static func setDate(_ date: Date = Date(), calendar: Calendar = Calendar.current) -> [UInt8] {
            let c = clockComponents(date, calendar)
            return [
                AnytimeOpcode.txSetDate,
                UInt8(truncatingIfNeeded: (c.year ?? 1900) - 1900),
                UInt8(truncatingIfNeeded: c.month ?? 0),
                UInt8(truncatingIfNeeded: c.day ?? 0),
                UInt8(truncatingIfNeeded: c.hour ?? 0),
                UInt8(truncatingIfNeeded: c.minute ?? 0),
                UInt8(truncatingIfNeeded: c.second ?? 0)
            ]
        }

        static func setDateSummed(_ date: Date = Date(), calendar: Calendar = Calendar.current) -> [UInt8] {
            var frame = setDate(date, calendar: calendar)
            frame.append(AnytimeFrames.sum(frame, from: 0, to: frame.count - 1))
            return frame
        }

        /// `{0x08, idLo, idHi}`.
        static func pullGlucose(_ nextId: Int) -> [UInt8] {
            let id = nextId & 0xFFFF
            return [AnytimeOpcode.txPullGlucose, UInt8(id & 0xFF), UInt8((id >> 8) & 0xFF)]
        }

        static func pullGlucoseSummed(_ nextId: Int) -> [UInt8] {
            let id = nextId & 0xFFFF
            return AnytimeFrames.withSum([0x08, id & 0xFF, (id >> 8) & 0xFF])
        }

        /// `{0x22, idLo, idHi, count, sum}`: several records at once, at most 15.
        static func pullGlucoseSeriesSummed(_ nextId: Int, count: Int = 15) -> [UInt8] {
            let id = nextId & 0xFFFF
            return AnytimeFrames.withSum([0x22, id & 0xFF, (id >> 8) & 0xFF, anytimeClamp(count, 1, 15)])
        }

        /// `{0x0C, idLo, idHi}`: fetch a record as transmitter-computed glucose.
        static func fetchComputedGlucose(_ nextId: Int) -> [UInt8] {
            let id = nextId & 0xFFFF
            return [AnytimeOpcode.txFetchComputedGlucose, UInt8(id & 0xFF), UInt8((id >> 8) & 0xFF)]
        }

        /// `{0x09, mmolInt, mmolFrac}` with the reference in mmol/L rounded to one decimal.
        static func inputBgMg(_ mgdl: Int) -> [UInt8] {
            let tenths = anytimeKotlinRound((Float(mgdl) / 18) * 10)
            let intPart = tenths / 10
            let fracPart = tenths - intPart * 10
            return [AnytimeOpcode.txInputBgMg, UInt8(truncatingIfNeeded: intPart), UInt8(truncatingIfNeeded: fracPart)]
        }

        static func inputBgMgSummed(_ mgdl: Int) -> [UInt8] {
            let tenths = anytimeKotlinRound((Float(mgdl) / 18) * 10)
            let intPart = tenths / 10
            let fracPart = tenths - intPart * 10
            return AnytimeFrames.withSum([0x09, intPart & 0xFF, fracPart & 0xFF])
        }

        /// `{0x0B, KInt, KFrac(tenths), RInt, RFrac(tenths)}`.
        static func inputKR(_ k: Float, _ r: Float) -> [UInt8] {
            let kInt = anytimeKotlinInt(k)
            let kFrac = anytimeKotlinInt((k - Float(kInt)) * 10) & 0xFF
            let rInt = anytimeKotlinInt(r)
            let rFrac = anytimeKotlinInt((r - Float(rInt)) * 10) & 0xFF
            return [AnytimeOpcode.txInputKR, UInt8(truncatingIfNeeded: kInt), UInt8(kFrac), UInt8(truncatingIfNeeded: rInt), UInt8(rFrac)]
        }

        /// `{0x0B, KInt, KFrac(hundredths), RInt, RFrac(hundredths), sum}`.
        static func inputKRSummed(_ k: Float, _ r: Float) -> [UInt8] {
            let kInt = anytimeKotlinInt(k)
            let kFrac = anytimeKotlinInt((k - Float(kInt)) * 100) & 0xFF
            let rInt = anytimeKotlinInt(r)
            let rFrac = anytimeKotlinInt((r - Float(rInt)) * 100) & 0xFF
            return AnytimeFrames.withSum([0x0B, kInt & 0xFF, kFrac, rInt & 0xFF, rFrac])
        }

        /// `{0x15, voltage, 0 x 9, sum}`: the voltage switch of CT3-Plus, CT3-Yuwell, CT3-Ultrasonic and
        /// CT4. `voltage` is 0 (1 V mode) or 1 (2 V mode), taken from the first character of the sensor code.
        static func modifyVoltage(_ voltage: Int) -> [UInt8] {
            var frame = [UInt8](repeating: 0, count: 12)
            frame[0] = AnytimeOpcode.txModifyVoltage
            frame[1] = UInt8(truncatingIfNeeded: voltage)
            frame[11] = AnytimeFrames.sum(frame, from: 0, to: 10)
            return frame
        }

        static func transmitterFormal() -> [UInt8] { return [AnytimeOpcode.txTransmitterFormal] }
        static func transmitterFormalSummed() -> [UInt8] { return AnytimeFrames.withSum([0x20, 0x55, 0xAA]) }

        /// CT5 get-date request (the answer is opcode 0x03).
        static func ct5GetDate() -> [UInt8] { return AnytimeFrames.withSum([0x04, 0x55, 0xAA]) }

        /// CT5 reconnect identity check: `{0x31, randomB[4], sum}`.
        static func ct5CheckId(randomB: [Int]) -> [UInt8]? {
            guard randomB.count == 4 else { return nil }
            return AnytimeFrames.withSum([0x31] + randomB)
        }

        /// CT5 identity challenge: `{0x30, randomB[4], convolve(randomB, randomA)[4], sum}`.
        static func ct5SetId(randomA: [Int], randomB: [Int]) -> [UInt8]? {
            guard randomA.count == 4, randomB.count == 4 else { return nil }
            let convolution = AnytimeFrames.ct5Convolve(randomB, randomA)
            return AnytimeFrames.withSum([0x30] + randomB + convolution)
        }

        static func ct5QuerySsn() -> [UInt8] { return AnytimeFrames.withSum([0x3F, 0x55, 0xAA]) }
        static func ct5PushAck() -> [UInt8] { return AnytimeFrames.withSum([0x35, 0x55, 0xAA]) }

        /// CT5 bind-state query, `{0x11, 0x55, 0xAA, 0x10}`: reads the transmitter's bind flag.
        static func ct5BindStateQuery() -> [UInt8] { return AnytimeFrames.withSum([0x11, 0x55, 0xAA]) }

        /// CT5 series history pull, `{0x37, idLo, idHi, count, sum}`.
        static func ct5PullGlucoseSeries(_ nextId: Int, count: Int = 15) -> [UInt8] {
            let id = nextId & 0xFFFF
            return AnytimeFrames.withSum([0x37, id & 0xFF, (id >> 8) & 0xFF, max(count, 1) & 0xFF])
        }

        /// CT5 fingerstick reference: mg/dL big-endian, not mmol split.
        static func ct5InputBgMg(_ mgdl: Int) -> [UInt8] {
            return AnytimeFrames.withSum([0x09, (mgdl >> 8) & 0xFF, mgdl & 0xFF])
        }

        /// CT5 end-cycle frame: opcode 0x0A (the unbind opcode) plus the authenticated four-byte temporary id.
        static func ct5EndCycle(tempId: String) -> [UInt8]? {
            let id = Array(tempId.utf8)
            guard tempId.count == 4, id.count == 4 else { return nil }
            return AnytimeFrames.withSum([Int(AnytimeOpcode.txUnbind)] + id.map { Int($0) })
        }

        /// CT5 encrypted K/R and temporary id setup, `{0x38, 12 encrypted bytes, sum}`.
        static func ct5SetParameters(k: Float, r: Float, cipherKey: Int, tempId: String) -> [UInt8]? {
            guard cipherKey >= 0 && cipherKey <= 255 else { return nil }
            var tempText = String(tempId.prefix(4))
            while tempText.count < 4 { tempText = "0" + tempText }
            let tempBytes = Array(tempText.utf8)
            guard tempBytes.count == 4 else { return nil }
            var payload = [UInt8](repeating: 0, count: 12)
            payload[0] = UInt8(anytimeClamp(anytimeKotlinInt(k), 0, 255))
            payload[1] = fractionByte(k, scale: 100, roundToTenthsFirst: false)
            payload[2] = UInt8(anytimeClamp(anytimeKotlinInt(r), 0, 255))
            payload[3] = fractionByte(r, scale: 100, roundToTenthsFirst: true)
            payload[4] = 0x03
            payload[5] = 0x53
            payload[6] = 0x55
            payload[7] = 0x00
            for index in 0..<4 { payload[8 + index] = tempBytes[index] }
            let encrypted = AnytimeFrames.ct5Decode(payload, cipherKey: cipherKey)
            var frame = [UInt8](repeating: 0, count: 14)
            frame[0] = AnytimeOpcode.txCt5SetParameters
            for index in 0..<encrypted.count { frame[1 + index] = encrypted[index] }
            frame[13] = AnytimeFrames.sum(frame, from: 0, to: 12)
            return frame
        }

        private static func fractionByte(_ value: Float, scale: Int, roundToTenthsFirst: Bool) -> UInt8 {
            let intPart = anytimeKotlinInt(value)
            let rounded: Float
            if roundToTenthsFirst {
                rounded = Float(anytimeKotlinRound(value * 10)) / 10
            } else {
                rounded = Float(anytimeKotlinRound(value * 100)) / 100
            }
            let scaled = anytimeKotlinRound((rounded - Float(intPart)) * Float(scale))
            return UInt8(truncatingIfNeeded: scaled)
        }

        // MARK: CT2

        static func ct2Version() -> [UInt8] { return [AnytimeOpcode.txCt2Version] }

        /// CT2 handshake: `{0x48, ASCII(own advertised name), sum}`.
        static func ct2Handshake(deviceName: String) -> [UInt8] {
            var frame: [UInt8] = [AnytimeOpcode.txCt2Handshake]
            frame.append(contentsOf: Array(deviceName.unicodeScalars.map { $0.value < 128 ? UInt8($0.value) : UInt8(ascii: "?") }))
            frame.append(AnytimeFrames.sum(frame, from: 0, to: frame.count - 1))
            return frame
        }

        /// CT2 setDate: `{0x54, yearHi, yearLo, month, day, hour, minute, second, sum}`. The year is sent in
        /// full, not minus 2000.
        static func ct2SetDate(_ date: Date = Date(), calendar: Calendar = Calendar.current) -> [UInt8] {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let year = (c.year ?? 0) & 0xFFFF
            return AnytimeFrames.withSum([0x54, (year >> 8) & 0xFF, year & 0xFF, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0])
        }

        static func ct2Init() -> [UInt8] { return [0x53, 0x55, 0xAA, 0x52] }
        static func ct2Check() -> [UInt8] { return [0x43, 0x55, 0xAA, 0x42] }
        static func ct2LowPower() -> [UInt8] { return [0x57, 0x55, 0xAA, 0x56] }
        static func ct2Unbind() -> [UInt8] { return [0x58, 0x55, 0xAA, 0x57] }

        /// CT2 pull of one record by id: `{0x55, idHi, idLo, sum}`.
        static func ct2PullGlucose(_ id: Int) -> [UInt8] {
            let value = id & 0xFFFF
            return AnytimeFrames.withSum([0x55, (value >> 8) & 0xFF, value & 0xFF])
        }

        /// CT2 fingerstick reference in mg/dL, big-endian: `{0x08, hi, lo, sum}`.
        static func ct2InputBgMg(_ mgdl: Int) -> [UInt8] {
            let value = mgdl & 0xFFFF
            return AnytimeFrames.withSum([0x08, (value >> 8) & 0xFF, value & 0xFF])
        }
    }

    // MARK: CT5 obfuscation and session helpers

    /// The CT5 identity convolution: `out[i] = sum over j of first[j] * second[i - j]`.
    static func ct5Convolve(_ first: [Int], _ second: [Int]) -> [Int] {
        var out = [Int](repeating: 0, count: first.count)
        for i in 0..<first.count {
            for j in 0..<second.count {
                let k = i - j
                if k >= 0 && j < first.count && k < second.count {
                    out[i] += (first[j] & 0xFF) * (second[k] & 0xFF)
                }
            }
        }
        return out
    }

    /// The vendor `ConvertTools.decode`, used for outgoing encrypted CT5 setup payloads.
    static func ct5Decode(_ bytes: [UInt8], cipherKey: Int) -> [UInt8] {
        var bits = bytesToBits(bytes)
        if bits.count >= 2 {
            var index = bits.count - 2
            while index >= 0 {
                if bits[index + 1] == 0 { bits[index] = bits[index] ^ 1 }
                index -= 1
            }
        }
        var out = [UInt8](repeating: 0, count: bytes.count)
        for index in 0..<out.count {
            out[index] = UInt8(truncatingIfNeeded: bitsToByte(bits, offset: index * 8) ^ (cipherKey & 0xFF))
        }
        return out
    }

    /// The vendor `ConvertTools.encode`, used for incoming encrypted CT5 payloads.
    static func ct5Encode(_ bytes: [UInt8], cipherKey: Int) -> [UInt8] {
        var bits = [Int](repeating: 0, count: bytes.count * 8)
        for index in 0..<bytes.count {
            let value = Int(bytes[index]) ^ (cipherKey & 0xFF)
            for bit in 0..<8 {
                bits[index * 8 + bit] = (value >> (7 - bit)) & 1
            }
        }
        var i = 0
        while i < bits.count - 1 {
            if bits[i + 1] == 0 { bits[i] = bits[i] ^ 1 }
            i += 1
        }
        var out = [UInt8](repeating: 0, count: bytes.count)
        for byteIndex in 0..<out.count {
            out[byteIndex] = UInt8(truncatingIfNeeded: bitsToByte(bits, offset: byteIndex * 8))
        }
        return out
    }

    /// The session cipher key from the answer to the 0x30 identity challenge, -1 when it does not fit.
    static func ct5SessionKey(fromSetIdResponse bytes: [UInt8], randomA: [Int]) -> Int {
        if randomA.count != 4 || bytes.isEmpty || bytes[0] != AnytimeOpcode.txCt5SetId { return -1 }
        if !verifySum(bytes) || bytes.count < 7 { return -1 }
        let tail = bytes[5..<(bytes.count - 1)].map { Int($0) }
        if tail.isEmpty { return -1 }
        let folded = ct5Convolve(tail, randomA).reduce(0) { $0 ^ $1 }
        return folded & 0xFF
    }

    /// The sensor code the transmitter answers to 0x3F, decrypted. nil when blank.
    static func parseCt5QuerySsnResponse(_ bytes: [UInt8], cipherKey: Int) -> String? {
        if bytes.isEmpty || bytes[0] != AnytimeOpcode.rxCt5QuerySsn || cipherKey < 0 || cipherKey > 255 { return nil }
        let decoded = ct5Encode(Array(bytes[1...]), cipherKey: cipherKey)
        let trimmed = trimNonPrintable(decoded)
        if trimmed.isEmpty { return nil }
        // US-ASCII decoding as the Kotlin original: every byte above 0x7F becomes one replacement character.
        var text = ""
        for byte in trimmed { text.unicodeScalars.append(byte < 0x80 ? UnicodeScalar(byte) : "\u{FFFD}") }
        return text
    }

    /// Kotlin `trim { it <= ' ' || it.code > 0x7E }` over ASCII bytes.
    static func trimNonPrintable(_ bytes: [UInt8]) -> [UInt8] {
        func isTrim(_ byte: UInt8) -> Bool { return byte <= 0x20 || byte > 0x7E }
        var start = 0
        var end = bytes.count
        while start < end && isTrim(bytes[start]) { start += 1 }
        while end > start && isTrim(bytes[end - 1]) { end -= 1 }
        return Array(bytes[start..<end])
    }

    static func parseCt5CurrentRecord(_ bytes: [UInt8], cipherKey: Int) -> AnytimeComputedRecord? {
        let voltage = bytes.count == 19
        let expected = voltage ? 19 : 15
        if bytes.count != expected || bytes[0] != AnytimeOpcode.rxCt5PushGlucose { return nil }
        if cipherKey < 0 || cipherKey > 255 || !verifySum(bytes) { return nil }
        let decoded = decryptCt5PayloadFrame(bytes, cipherKey: cipherKey)
        let glucoseId = Int(decoded[1]) | (Int(decoded[2]) << 8)
        return parseCt5DecodedRecord(decoded, offset: 3, glucoseId: glucoseId, chunkSize: voltage ? 15 : 11)
    }

    /// Recover the cipher key from one live record when the stored one is missing. Accepts only a key
    /// whose decoded record looks like a live record, and only if every surviving key gives the same
    /// clinical fields (the bit transform leaves one trailing payload bit ambiguous).
    static func inferCt5CipherFromCurrentRecord(_ bytes: [UInt8], maxGlucoseId: Int = Int.max) -> AnytimeCt5CipherCandidate? {
        let voltage = bytes.count == 19
        let expected = voltage ? 19 : 15
        if bytes.count != expected || bytes[0] != AnytimeOpcode.rxCt5PushGlucose { return nil }
        if !verifySum(bytes) { return nil }

        var candidates = [AnytimeCt5CipherCandidate]()
        for key in 0...255 {
            guard let record = parseCt5CurrentRecord(bytes, cipherKey: key) else { continue }
            if !looksLikeCt5LiveRecord(record, maxGlucoseId: maxGlucoseId) { continue }
            candidates.append(AnytimeCt5CipherCandidate(cipherKey: key, record: record))
        }
        if candidates.isEmpty { return nil }
        var signatures = [String]()
        for candidate in candidates {
            let signature = ct5RecordSignature(candidate.record)
            if !signatures.contains(signature) { signatures.append(signature) }
        }
        return signatures.count == 1 ? candidates[0] : nil
    }

    static func parseCt5SeriesRecords(_ bytes: [UInt8], cipherKey: Int, voltage: Bool = false) -> [AnytimeComputedRecord] {
        let chunkSize = voltage ? AnytimeConstants.ct5VoltageChunkSize : AnytimeConstants.ct5RawChunkSize
        if bytes.isEmpty || bytes[0] != AnytimeOpcode.rxCt5Series || cipherKey < 0 || cipherKey > 255 { return [] }
        if !verifySum(bytes) { return [] }
        let sanitized = sanitizeCt5SeriesFrame(bytes, chunkSize: chunkSize)
        // A frame shorter than id + sum cannot hold a record (the Kotlin original would throw here).
        if sanitized.count <= 4 { return [] }
        let decoded = decryptCt5PayloadFrame(sanitized, cipherKey: cipherKey)
        let startId = Int(decoded[1]) | (Int(decoded[2]) << 8)
        let count = (decoded.count - 4) / chunkSize
        var out = [AnytimeComputedRecord]()
        for index in 0..<max(count, 0) {
            if let record = parseCt5DecodedRecord(decoded, offset: 3 + index * chunkSize, glucoseId: startId + index, chunkSize: chunkSize) {
                out.append(record)
            }
        }
        return out
    }

    private static func looksLikeCt5LiveRecord(_ record: AnytimeComputedRecord, maxGlucoseId: Int) -> Bool {
        return record.glucoseId >= 0 && record.glucoseId <= maxGlucoseId &&
            record.errorCode == 0 &&
            (!record.hasGlucose || (record.gluMgdl >= 20 && record.gluMgdl <= 600)) &&
            record.temperatureC >= 15 && record.temperatureC <= 45 &&
            record.ibNa >= 0 && record.ibNa <= 100 &&
            record.iwNa >= 0 && record.iwNa <= 100 &&
            record.trend >= 0 && record.trend <= 10
    }

    private static func ct5RecordSignature(_ record: AnytimeComputedRecord) -> String {
        return [
            String(record.glucoseId),
            String(record.hasGlucose),
            String(record.gluMgdl),
            String(anytimeKotlinRound(record.temperatureC * 10)),
            String(record.trend),
            String(record.errorCode)
        ].joined(separator: ":")
    }

    /// Decode the payload of a CT5 frame (everything between the id and the sum) and refresh the sum.
    private static func decryptCt5PayloadFrame(_ bytes: [UInt8], cipherKey: Int) -> [UInt8] {
        let payload: [UInt8] = bytes.count > 4 ? Array(bytes[3..<(bytes.count - 1)]) : []
        let decodedPayload = ct5Encode(payload, cipherKey: cipherKey)
        var decoded = bytes
        for index in 0..<decodedPayload.count { decoded[3 + index] = decodedPayload[index] }
        decoded[decoded.count - 1] = sum(decoded, from: 0, to: decoded.count - 2)
        return decoded
    }

    /// Drop the all-0xFF filler chunks and stop at the first all-0xFC chunk of a CT5 series answer.
    private static func sanitizeCt5SeriesFrame(_ bytes: [UInt8], chunkSize: Int) -> [UInt8] {
        if bytes.count <= 4 { return bytes }
        var chunks = [[UInt8]]()
        var offset = 3
        while offset + chunkSize <= bytes.count - 1 {
            let chunk = Array(bytes[offset..<(offset + chunkSize)])
            if chunk.allSatisfy({ $0 == 0xFC }) { break }
            if !chunk.allSatisfy({ $0 == 0xFF }) { chunks.append(chunk) }
            offset += chunkSize
        }
        var out: [UInt8] = [bytes[0], bytes[1], bytes[2]]
        for chunk in chunks { out.append(contentsOf: chunk) }
        out.append(bytes[bytes.count - 1])
        return out
    }

    private static func parseCt5DecodedRecord(_ decoded: [UInt8], offset: Int, glucoseId: Int, chunkSize: Int) -> AnytimeComputedRecord? {
        if offset + chunkSize > decoded.count - 1 { return nil }
        let ibRaw = u16(decoded[offset], decoded[offset + 1])
        let iwRaw = u16(decoded[offset + 2], decoded[offset + 3])
        let tPlus40 = Int(decoded[offset + 4])
        let tFrac = Int(decoded[offset + 5])
        let temperature = Float(tPlus40 - AnytimeConstants.tempIntOffset) + Float(tFrac) / 100
        if ibRaw >= 0xFFF0 || iwRaw >= 0xFFF0 || temperature < -20 || temperature > 80 { return nil }
        let trendAndHigh = Int(decoded[offset + 6])
        let trend = (trendAndHigh >> 4) & 0x0F
        let glucoseMgdl = ((trendAndHigh & 0x0F) << 8) | Int(decoded[offset + 7])
        let error = Int(decoded[offset + 8])
        // A glucose of 0 is a valid warm-up or status record, not a malformed frame.
        let hasGlucose = glucoseMgdl > 0
        let hasVoltages = chunkSize >= AnytimeConstants.ct5VoltageChunkSize
        var record = AnytimeComputedRecord(
            glucoseId: glucoseId,
            hypoEarlyWarnMinutes: 0,
            hyperEarlyWarnMinutes: 0,
            ibNa: Float(ibRaw) / 100,
            iwNa: Float(iwRaw) / 100,
            temperatureC: temperature,
            gluMmol: hasGlucose ? Float(glucoseMgdl) / 18 : 0,
            referenceBgMmol: 0,
            errorCode: error,
            trend: trend,
            warnCode: 0,
            hasGlucose: hasGlucose
        )
        if hasVoltages {
            record.beVoltageMv = Int(decoded[offset + 9]) * 6
            record.weVoltageMv = Int(decoded[offset + 10]) * 6
            record.reVoltageMv = Int(decoded[offset + 11]) * 6
            record.ceVoltageMv = Int(decoded[offset + 12]) * 6
            record.batteryRaw = u16(decoded[offset + 13], decoded[offset + 14])
        }
        return record
    }

    private static func bytesToBits(_ bytes: [UInt8]) -> [Int] {
        var bits = [Int](repeating: 0, count: bytes.count * 8)
        for index in 0..<bytes.count {
            let value = Int(bytes[index])
            for bit in 0..<8 {
                bits[index * 8 + bit] = (value >> (7 - bit)) & 1
            }
        }
        return bits
    }

    private static func bitsToByte(_ bits: [Int], offset: Int) -> Int {
        var value = 0
        for bit in 0..<8 { value = (value << 1) | (bits[offset + bit] & 1) }
        return value & 0xFF
    }

    private static func u16(_ hi: UInt8, _ lo: UInt8) -> Int {
        return (Int(hi) << 8) | Int(lo)
    }

    // MARK: parsers (sensor to phone)

    /// Raw current records of a 0x07 push or 0x08 pull. The first record is 9 bytes with its opcode,
    /// every continuation 8 bytes.
    static func parseRawRecords(_ bytes: [UInt8], wideRecords: Bool = false) -> [AnytimeRawRecord] {
        if wideRecords { return parseWideRawRecords(bytes) }
        if bytes.count < AnytimeConstants.rawRecordSize { return [] }
        if bytes[0] != AnytimeOpcode.rxPushGlucose && bytes[0] != AnytimeOpcode.rxPullGlucose { return [] }
        var out = [AnytimeRawRecord]()
        var offset = 1
        var index = 0
        while offset + AnytimeConstants.rawRecordContinuationSize <= bytes.count {
            if let record = decodeRaw(bytes, base: offset, index: index) { out.append(record) }
            offset += AnytimeConstants.rawRecordContinuationSize
            index += 1
        }
        return out
    }

    private static func parseWideRawRecords(_ bytes: [UInt8]) -> [AnytimeRawRecord] {
        if bytes.count < AnytimeConstants.wideRawRecordSize { return [] }
        if bytes[0] != AnytimeOpcode.rxPushGlucose && bytes[0] != AnytimeOpcode.rxPullGlucose { return [] }
        var out = [AnytimeRawRecord]()
        var offset = 0
        var index = 0
        while offset + AnytimeConstants.wideRawRecordSize <= bytes.count {
            let opcode = bytes[offset]
            if opcode != AnytimeOpcode.rxPushGlucose && opcode != AnytimeOpcode.rxPullGlucose { break }
            let idLo = Int(bytes[offset + 1])
            let idHi = Int(bytes[offset + 2])
            let isPlaceholder = offset + 10 < bytes.count && (offset + 3...offset + 10).allSatisfy { bytes[$0] == 0xFF }
            if isPlaceholder { break }
            let ibRaw = (Int(bytes[offset + 3]) << 8) | Int(bytes[offset + 4])
            let iwRaw = (Int(bytes[offset + 5]) << 8) | Int(bytes[offset + 6])
            let tPlus40 = Int(bytes[offset + 7])
            let tFrac = Int(bytes[offset + 8])
            let temperature = Float(tPlus40 - AnytimeConstants.tempIntOffset) + Float(tFrac) / 100
            if temperature < -10 || temperature > 60 || ibRaw >= 0xFFF0 || iwRaw >= 0xFFF0 { break }
            out.append(AnytimeRawRecord(
                indexInPacket: index,
                glucoseId: idLo | (idHi << 8),
                ibNa: Float(ibRaw) / 100,
                iwNa: Float(iwRaw) / 100,
                temperatureC: temperature,
                recordBytes: Array(bytes[(offset + 1)..<(offset + AnytimeConstants.wideRawRecordSize)])
            ))
            offset += AnytimeConstants.wideRawRecordSize
            index += 1
        }
        return out
    }

    /// The answer to a counted 0x22 pull, `{0x22, startIdLo, startIdHi, N x [ibHi, ibLo, iwHi, iwLo, t+40,
    /// tFrac], sum}`, or the unsolicited 0x0D legacy dump of the same layout.
    static func parseWideRawSeriesRecords(_ bytes: [UInt8]) -> [AnytimeRawRecord] {
        guard let opcode = bytes.first, bytes.count >= 4,
              opcode == AnytimeOpcode.rxSeries || opcode == AnytimeOpcode.rxLegacyRawDump,
              verifySum(bytes) else { return [] }
        let startId = Int(bytes[1]) | (Int(bytes[2]) << 8)
        let payloadEndExclusive = bytes.count - 1
        if payloadEndExclusive <= 3 { return [] }
        let chunkCount = (payloadEndExclusive - 3) / AnytimeConstants.wideRawSeriesChunkSize
        var out = [AnytimeRawRecord]()
        for index in 0..<chunkCount {
            let offset = 3 + index * AnytimeConstants.wideRawSeriesChunkSize
            let ibRaw = u16(bytes[offset], bytes[offset + 1])
            let iwRaw = u16(bytes[offset + 2], bytes[offset + 3])
            let tPlus40 = Int(bytes[offset + 4])
            let tFrac = Int(bytes[offset + 5])
            let temperature = Float(tPlus40 - AnytimeConstants.tempIntOffset) + Float(tFrac) / 100
            if ibRaw >= 0xFFF0 || iwRaw >= 0xFFF0 || temperature < -20 || temperature > 80 { break }
            let id = startId + index
            var recordBytes: [UInt8] = [UInt8(id & 0xFF), UInt8((id >> 8) & 0xFF)]
            recordBytes.append(contentsOf: bytes[offset..<(offset + 6)])
            out.append(AnytimeRawRecord(
                indexInPacket: index,
                glucoseId: id,
                ibNa: Float(ibRaw) / 100,
                iwNa: Float(iwRaw) / 100,
                temperatureC: temperature,
                recordBytes: recordBytes
            ))
        }
        return out
    }

    private static func decodeRaw(_ source: [UInt8], base: Int, index: Int) -> AnytimeRawRecord? {
        // layout after the opcode: id_lo, id_hi, ib_int, ib_frac, iw_int, iw_frac, t+40, t_frac
        if base + 7 >= source.count { return nil }
        let idLo = Int(source[base])
        let idHi = Int(source[base + 1])
        let ibInt = Int(source[base + 2])
        let ibFrac = Int(source[base + 3])
        let iwInt = Int(source[base + 4])
        let iwFrac = Int(source[base + 5])
        let tPlus40 = Int(source[base + 6])
        let tFrac = Int(source[base + 7])
        return AnytimeRawRecord(
            indexInPacket: index,
            glucoseId: idLo | (idHi << 8),
            ibNa: Float(ibInt) + Float(ibFrac) / 100,
            iwNa: Float(iwInt) + Float(iwFrac) / 100,
            temperatureC: Float(tPlus40 - AnytimeConstants.tempIntOffset) + Float(tFrac) / 100,
            recordBytes: Array(source[base..<(base + 8)])
        )
    }

    /// A 19-byte 0x0C computed-glucose record.
    static func parseComputedRecord(_ bytes: [UInt8]) -> AnytimeComputedRecord? {
        if bytes.count < AnytimeConstants.computedRecordSize { return nil }
        if bytes[0] != AnytimeOpcode.rxComputedGlucose { return nil }
        let gluInt = Int(bytes[11])
        let gluFrac = Int(bytes[12])
        return AnytimeComputedRecord(
            glucoseId: Int(bytes[1]) | (Int(bytes[2]) << 8),
            hypoEarlyWarnMinutes: Int(bytes[3]),
            hyperEarlyWarnMinutes: Int(bytes[4]),
            ibNa: Float(Int(bytes[5])) + Float(Int(bytes[6])) / 100,
            iwNa: Float(Int(bytes[7])) + Float(Int(bytes[8])) / 100,
            temperatureC: Float(Int(bytes[9]) - AnytimeConstants.tempIntOffset) + Float(Int(bytes[10])) / 100,
            gluMmol: Float(gluInt) + Float(gluFrac) / 100,
            referenceBgMmol: Float(Int(bytes[13])) + Float(Int(bytes[14])) / 10,
            errorCode: Int(bytes[15]),
            trend: Int(bytes[16]),
            warnCode: Int(bytes[17]),
            hasGlucose: gluInt != 0 || gluFrac != 0
        )
    }

    /// The 0x05 check response: battery in bytes 9 and 10 (int + frac / 100), sensor age counter in
    /// bytes 2 and 3. Bytes 6 and 7 are diagnostic and must not block the handshake.
    static func parseCheckResponse(_ bytes: [UInt8], lowBatteryThresholdVolts: Float) -> AnytimeCheckStatus {
        if bytes.count < 12 || bytes[0] != AnytimeOpcode.rxCheck {
            return AnytimeCheckStatus(sensorAgeReadings: 0, workingElectrodeCurrentNa: 0, batteryVolts: 0, isHealthy: false, failure: .malformed)
        }
        let field23 = (Int(bytes[2]) << 8) | Int(bytes[3])
        let checkCurrent = Float(field23) / 100
        let diagCurrent = Float(Int(bytes[6])) + Float(Int(bytes[7])) / 100
        let iw: Float
        if diagCurrent >= 0.5 && diagCurrent <= 80 {
            iw = diagCurrent
        } else if checkCurrent >= 0.5 && checkCurrent <= 80 {
            iw = checkCurrent
        } else {
            iw = 0
        }
        let volts = Float(Int(bytes[9])) + Float(Int(bytes[10])) / 100
        let failure: AnytimeCheckFailure? = (volts > 0 && volts < lowBatteryThresholdVolts) ? .lowBattery : nil
        return AnytimeCheckStatus(
            sensorAgeReadings: field23,
            workingElectrodeCurrentNa: iw,
            batteryVolts: volts,
            isHealthy: failure == nil || failure == .lowBattery,
            failure: failure
        )
    }

    static func parseResetResponse(_ bytes: [UInt8]) -> AnytimeResetStatus? {
        if bytes.count < 3 { return nil }
        if bytes[0] != AnytimeOpcode.rxReset { return nil }
        return AnytimeResetStatus(isBound: bytes[2] != 0)
    }

    static func parseCt5BindState(_ bytes: [UInt8]) -> AnytimeCt5BindState? {
        if bytes.count < 14 { return nil }
        if bytes[0] != AnytimeOpcode.rxReset { return nil }
        if !verifySum(bytes) { return nil }
        let isBound = bytes[2] != 0
        var reason = -1
        if !isBound && bytes[12] == 0x22 {
            let value = Int(bytes[8])
            reason = (value == 0 || value == 1) ? value : -1
        }
        return AnytimeCt5BindState(isBound: isBound, unbindReason: reason)
    }

    /// A 15-byte CT2 glucose record (live push 0x44 or pull response 0x47): opcode, id (bytes 1-2,
    /// big-endian), date and time, Iw (bytes 8-9 /10), Ib (bytes 10-11 /10), temperature, battery or
    /// sentinel, sum. Iw comes before Ib here, the reverse of CT3 and CT2.5.
    static func parseCt2GlucoseRecord(_ bytes: [UInt8]) -> AnytimeCt2GlucoseFrame? {
        if bytes.count != 15 { return nil }
        if !verifySum(bytes) { return nil }
        let isHistorical: Bool
        switch bytes[0] {
        case AnytimeOpcode.rxCt2PushGlucose: isHistorical = false
        case AnytimeOpcode.rxCt2PullResponse: isHistorical = true
        default: return nil
        }
        let id = u16(bytes[1], bytes[2])
        let iw = Float(u16(bytes[8], bytes[9])) / 10
        let ib = Float(u16(bytes[10], bytes[11])) / 10
        let temperature = decodeCt2Temperature(bytes[12])
        let batteryByte = Int(bytes[13])
        return AnytimeCt2GlucoseFrame(
            record: AnytimeRawRecord(indexInPacket: 0, glucoseId: id, ibNa: ib, iwNa: iw, temperatureC: temperature, recordBytes: bytes),
            isHistorical: isHistorical,
            batteryPercent: isHistorical ? nil : batteryByte,
            isEndOfHistory: isHistorical && id == 0xFFFF
        )
    }

    /// CT2 temperature byte: bit 7 set means (b - 128) + 0.5, otherwise b.
    static func decodeCt2Temperature(_ byte: UInt8) -> Float {
        let value = Int(byte)
        return (value & 0x80) != 0 ? Float((value - 128) & 0xFF) + 0.5 : Float(value)
    }

    /// The CT2 self-test (0x43) response.
    static func parseCt2CheckResponse(_ bytes: [UInt8]) -> AnytimeCt2CheckResult? {
        if bytes.count < 8 { return nil }
        if !verifySum(bytes) { return nil }
        let iw = Float(u16(bytes[1], bytes[2])) / 10
        let ib = Float(u16(bytes[3], bytes[4])) / 10
        let temperature = decodeCt2Temperature(bytes[5])
        let power = Int(bytes[6])
        return AnytimeCt2CheckResult(iwNa: iw, ibNa: ib, temperatureC: temperature, powerByte: power, passed: !(temperature >= 50) && !(power < 50))
    }

    /// The version string of a 0x20 formal-version answer (best effort).
    static func parseFormalVersion(_ bytes: [UInt8]) -> String {
        if bytes.count < 2 || bytes[0] != AnytimeOpcode.rxTransmitterFormal { return "" }
        var end = bytes.count
        if let zero = bytes.firstIndex(of: 0), zero > 1 { end = zero }
        let raw = Array(bytes[1..<min(end, bytes.count)])
        let text = String(decoding: raw.map { $0 > 0x7F ? UInt8(ascii: "?") : $0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    /// Battery percentage from volts, a rough linear mapping between the family's low threshold and 4.2 V.
    static func batteryPercent(volts: Float, lowThresholdVolts: Float) -> Int {
        if volts <= 0 { return -1 }
        let span = AnytimeConstants.batteryFullVolts - lowThresholdVolts
        if span <= 0 { return -1 }
        let pct = ((volts - lowThresholdVolts) / span) * 100
        return anytimeClamp(anytimeKotlinInt(pct), 0, 100)
    }
}

// MARK: - Sensor code (QR)

/// Calibration data of a sensor code, mirroring the vendor SDK's `KRDecodeData`.
struct AnytimeQrCalibration: Equatable {
    enum Format: String, Codable {
        case a = "A"
        case b = "B"
        case c = "C"
        case d = "D"
        case manual = "MANUAL"
        case udi = "UDI"
        case defaultCalibration = "DEFAULT"
    }

    var rawQr: String
    var format: Format
    /// Calibration slope.
    var k: Float
    /// Calibration intercept.
    var r: Float
    var lifeTime: Int
    var productMonth: Int
    var productYear: Int
    var electrodeType: String
    var electrodeTecNo: String
    var enzymeTecNo: String
    var membraneTecNo: String
    var marketNo: String
    var serialNo: String
    var sensorNo: String
    var unitOrder: Int
    var voltageFlag: Int
    var calibrationCount: Int

    /// A decoded factory calibration (not a product label, not the default).
    var isFactoryCalibration: Bool {
        return format != .udi && format != .defaultCalibration && k > 0 && r > 0
    }

    /// K and R that may be written to a transmitter: a factory code or the CT5 default, never a product label.
    var hasTransmitterKr: Bool {
        return format != .udi && k > 0 && r > 0
    }
}

enum AnytimeQr {
    // The vendor library's own patterns (verbatim from its .rodata).
    private static let month = "(0[1-9]|[1-9][0-9]|[A-Z][1-9A-Z])"
    private static let threeDigit = "(00[1-9]|0[1-9][0-9]|[1-9][0-9][0-9])"

    static let patternA = "^([A-Z0-9])([0-9])" + month + threeDigit + threeDigit + "([0-9]{5})([0-9A-Z]{3})$"
    static let patternB = "^([1-3])([1-9])([A-Z0-9])([0-9])" + month + threeDigit + threeDigit + "([0-9]{6})([0-9A-Z]{3})$"
    static let patternC = "^([A-C])([1-9])([A-Z0-9])([0-9])" + month + threeDigit + threeDigit + "([0-9]{5})([0-9A-HJ-NP-Z])([0-9A-Z]{3})$"
    static let patternD = "^([1-9A-ZABDEFYTSRQ])([1-9])([A-Z0-9])([0-9])" + month + threeDigit + threeDigit + "([0-9]{6})([0-9A-Z]{3})$"
    static let patternManual = "^[A-Z0-9]{7}$"
    /// The "00"-lead pattern of the Anytime 5 app. CT5 answers its sensor code query in it.
    static let patternCt5Ssn00 = "^00([A-Z0-9])([0-9])" + month + threeDigit + threeDigit + "([0-9]{6})([0-9A-Z]{3})$"
    static let patternGs1Udi = "^01(\\d{14})11(\\d{6})17(\\d{6})10(.+)$"

    /// The official `PocDevice.getVoltage()`: a numeric first character is voltage mode 0, anything else 1.
    static func inferVoltageFlag(_ qr: String?) -> Int {
        guard let first = qr?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return 0 }
        return (first >= "0" && first <= "9") ? 0 : 1
    }

    /// Parse a sensor code. Factory calibration codes give K and R, a product label (GS1 / UDI) is
    /// accepted as metadata only, with no calibration.
    static func parse(_ qr: String?) -> AnytimeQrCalibration? {
        guard let source = qr else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return nil }

        if let parsed = parseTrailingKrFactoryCode(trimmed) { return parsed }
        if let groups = AnytimeText.fullMatch(trimmed, pattern: patternA) { return parseFormatA(trimmed, groups) }
        if let groups = AnytimeText.fullMatch(trimmed, pattern: patternB) { return parseFormatB(trimmed, groups) }
        if let groups = AnytimeText.fullMatch(trimmed, pattern: patternC) { return parseFormatC(trimmed, groups) }
        if let groups = AnytimeText.fullMatch(trimmed, pattern: patternD) { return parseFormatD(trimmed, groups) }
        if let parsed = parseManual(trimmed) { return parsed }
        if let parsed = parseGs1Udi(trimmed) { return parsed }
        return nil
    }

    /// K and R for the CT5 parameter setup when the transmitter's own code did not decode: the stored
    /// calibration if it carries K and R for a transmitter, otherwise the CT5 default.
    static func ct5SetupCalibration(stored: AnytimeQrCalibration?, voltageFlag: Int) -> AnytimeQrCalibration {
        if let stored = stored, stored.hasTransmitterKr { return stored }
        return ct5Default(voltageFlag: voltageFlag)
    }

    static func ct5Default(voltageFlag: Int) -> AnytimeQrCalibration {
        return AnytimeQrCalibration(
            rawQr: "",
            format: .defaultCalibration,
            k: AnytimeConstants.ct5DefaultK,
            r: AnytimeConstants.ct5DefaultR,
            lifeTime: AnytimeConstants.defaultRatedLifetimeDays,
            productMonth: 0,
            productYear: 0,
            electrodeType: "",
            electrodeTecNo: "",
            enzymeTecNo: "",
            membraneTecNo: "",
            marketNo: "",
            serialNo: "",
            sensorNo: "",
            unitOrder: 0,
            voltageFlag: voltageFlag,
            calibrationCount: 0
        )
    }

    private static func digit(_ text: String, at index: Int) -> Int? {
        let characters = Array(text)
        guard index >= 0 && index < characters.count, let value = characters[index].wholeNumberValue,
              characters[index] >= "0" && characters[index] <= "9" else { return nil }
        return value
    }

    private static func firstDigit(_ text: String) -> Int {
        return digit(text, at: 0) ?? 0
    }

    private static func substring(_ text: String, _ from: Int, _ to: Int) -> String {
        let characters = Array(text)
        let lower = max(0, min(from, characters.count))
        let upper = max(lower, min(to, characters.count))
        return String(characters[lower..<upper])
    }

    private static func parseTrailingKrFactoryCode(_ qr: String) -> AnytimeQrCalibration? {
        let characters = Array(qr)
        if characters.count != 21 { return nil }
        let first = characters[0]
        if !(first >= "A" && first <= "C") && !AnytimeText.matches(qr, pattern: patternCt5Ssn00) { return nil }
        let kDigits = substring(qr, 13, 16)
        let rDigits = substring(qr, 16, 18)
        if kDigits.contains(where: { !($0 >= "0" && $0 <= "9") }) || rDigits.contains(where: { !($0 >= "0" && $0 <= "9") }) { return nil }
        let kText = String(kDigits.prefix(1)) + "." + String(kDigits.dropFirst())
        let rText = String(rDigits.prefix(1)) + "." + String(rDigits.dropFirst())
        guard let k = Float(kText), let r = Float(rText), k > 0, r > 0 else { return nil }

        return AnytimeQrCalibration(
            rawQr: qr,
            format: .c,
            k: k,
            r: r,
            lifeTime: inferLifeTimeDays(String(qr.suffix(3))),
            productMonth: Int(substring(qr, 4, 6)) ?? 0,
            productYear: 2000 + (digit(qr, at: 1) ?? 0) + 10,
            electrodeType: substring(qr, 2, 3),
            electrodeTecNo: substring(qr, 4, 6),
            enzymeTecNo: kDigits,
            membraneTecNo: rDigits,
            marketNo: String(qr.suffix(3)),
            serialNo: substring(qr, 7, 13),
            sensorNo: substring(qr, 0, 2),
            unitOrder: 0,
            voltageFlag: inferVoltageFlag(qr),
            calibrationCount: digit(qr, at: 3) ?? 0
        )
    }

    private static func parseFormatA(_ qr: String, _ g: [String]) -> AnytimeQrCalibration {
        // groups: 1 electrode type, 2 year, 3 month, 4 K, 5 R, 6 serial, 7 market number
        let kRaw = Int(g[4]) ?? 0
        let rRaw = Int(g[5]) ?? 0
        return AnytimeQrCalibration(
            rawQr: qr,
            format: .a,
            k: Float(kRaw) / 100,
            r: Float(rRaw) / 10,
            lifeTime: inferLifeTimeDays(g[7]),
            productMonth: parseMonth(g[3]),
            productYear: 2000 + (Int(g[2]) ?? 0) + 10,
            electrodeType: g[1],
            electrodeTecNo: g[3],
            enzymeTecNo: g[4],
            membraneTecNo: g[7],
            marketNo: g[7],
            serialNo: g[6],
            sensorNo: substring(qr, 0, 2),
            unitOrder: firstDigit(g[1]),
            voltageFlag: inferVoltageFlag(qr),
            calibrationCount: 0
        )
    }

    private static func parseFormatB(_ qr: String, _ g: [String]) -> AnytimeQrCalibration {
        // groups: 1 unit order, 2 year, 3 electrode type, 4 product month digit, 5 month, 6 K, 7 R, 8 serial, 9 market number
        let kRaw = Int(g[6]) ?? 0
        let rRaw = Int(g[7]) ?? 0
        return AnytimeQrCalibration(
            rawQr: qr,
            format: .b,
            k: Float(kRaw) / 100,
            r: Float(rRaw) / 10,
            lifeTime: inferLifeTimeDays(g[9]),
            productMonth: parseMonth(g[5]),
            productYear: 2000 + (Int(g[2]) ?? 0) + 10,
            electrodeType: g[3],
            electrodeTecNo: g[5],
            enzymeTecNo: g[6],
            membraneTecNo: g[7],
            marketNo: g[9],
            serialNo: g[8],
            sensorNo: substring(qr, 0, 2),
            unitOrder: firstDigit(g[1]),
            voltageFlag: inferVoltageFlag(qr),
            calibrationCount: Int(g[4]) ?? 0
        )
    }

    private static func parseFormatC(_ qr: String, _ g: [String]) -> AnytimeQrCalibration {
        // groups: 1 unit, 2 year, 3 electrode type, 4 product month digit, 5 month, 6 K, 7 R, 8 serial (5), 9 lot character, 10 market number
        let kRaw = Int(g[6]) ?? 0
        let rRaw = Int(g[7]) ?? 0
        return AnytimeQrCalibration(
            rawQr: qr,
            format: .c,
            k: Float(kRaw) / 100,
            r: Float(rRaw) / 10,
            lifeTime: inferLifeTimeDays(g[10]),
            productMonth: parseMonth(g[5]),
            productYear: 2000 + (Int(g[2]) ?? 0) + 10,
            electrodeType: g[3],
            electrodeTecNo: g[5],
            enzymeTecNo: g[4],
            membraneTecNo: g[5],
            marketNo: g[10],
            serialNo: g[8] + g[9],
            sensorNo: substring(qr, 0, 2),
            unitOrder: firstDigit(g[1]),
            voltageFlag: inferVoltageFlag(qr),
            calibrationCount: Int(g[4]) ?? 0
        )
    }

    private static func parseFormatD(_ qr: String, _ g: [String]) -> AnytimeQrCalibration {
        let kRaw = Int(g[6]) ?? 0
        let rRaw = Int(g[7]) ?? 0
        return AnytimeQrCalibration(
            rawQr: qr,
            format: .d,
            k: Float(kRaw) / 100,
            r: Float(rRaw) / 10,
            lifeTime: inferLifeTimeDays(g[9]),
            productMonth: parseMonth(g[5]),
            productYear: 2000 + (Int(g[2]) ?? 0) + 10,
            electrodeType: g[3],
            electrodeTecNo: g[5],
            enzymeTecNo: g[6],
            membraneTecNo: g[7],
            marketNo: g[9],
            serialNo: g[8],
            sensorNo: substring(qr, 0, 2),
            unitOrder: firstDigit(g[1]),
            voltageFlag: inferVoltageFlag(qr),
            calibrationCount: Int(g[4]) ?? 0
        )
    }

    /// A 7-character manual code: K = code[2] "." code[3..4], R = code[5].
    private static func parseManual(_ qr: String) -> AnytimeQrCalibration? {
        if !AnytimeText.matches(qr, pattern: patternManual) { return nil }
        guard let k = Float(substring(qr, 2, 3) + "." + substring(qr, 3, 5)),
              let r = Float(substring(qr, 5, 6)), k > 0, r > 0 else { return nil }
        return AnytimeQrCalibration(
            rawQr: qr,
            format: .manual,
            k: k,
            r: r,
            lifeTime: AnytimeConstants.defaultRatedLifetimeDays,
            productMonth: 0,
            productYear: 0,
            electrodeType: "",
            electrodeTecNo: "",
            enzymeTecNo: "",
            membraneTecNo: "",
            marketNo: "",
            serialNo: "",
            sensorNo: substring(qr, 0, 2),
            unitOrder: 0,
            voltageFlag: inferVoltageFlag(qr),
            calibrationCount: 0
        )
    }

    /// A GS1 / UDI product label: still an Anytime label, but it carries no K and R.
    private static func parseGs1Udi(_ qr: String) -> AnytimeQrCalibration? {
        let normalized = qr.uppercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .filter { !$0.isWhitespace }
        guard let g = AnytimeText.fullMatch(normalized, pattern: patternGs1Udi) else { return nil }
        let gtin = g[1]
        let manufactureDate = g[2]
        let expiryDate = g[3]
        let lot = String(g[4].split(separator: "\u{1D}", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !isGs1DateToken(manufactureDate) || !isGs1DateToken(expiryDate) || lot.isEmpty { return nil }

        return AnytimeQrCalibration(
            rawQr: qr,
            format: .udi,
            // placeholders only: the package label has no calibration and these must not reach a transmitter
            k: 0.30,
            r: 50,
            lifeTime: AnytimeConstants.defaultRatedLifetimeDays,
            productMonth: Int(substring(manufactureDate, 2, 4)) ?? 0,
            productYear: 2000 + (Int(substring(manufactureDate, 0, 2)) ?? 0),
            electrodeType: "",
            electrodeTecNo: "",
            enzymeTecNo: "",
            membraneTecNo: "",
            marketNo: lot,
            serialNo: gtin,
            sensorNo: String(gtin.suffix(6)),
            unitOrder: 0,
            voltageFlag: inferVoltageFlag(normalized),
            calibrationCount: 0
        )
    }

    private static func isGs1DateToken(_ token: String) -> Bool {
        if token.count != 6 || token.contains(where: { !($0 >= "0" && $0 <= "9") }) { return false }
        guard let month = Int(substring(token, 2, 4)), let day = Int(substring(token, 4, 6)) else { return false }
        return month >= 1 && month <= 12 && day >= 1 && day <= 31
    }

    private static func parseMonth(_ token: String) -> Int {
        if token.isEmpty { return 0 }
        if let value = Int(token) { return value }
        guard let first = token.first, first >= "A" && first <= "Z", let ascii = first.asciiValue else { return 0 }
        return 10 + Int(ascii) - Int(UInt8(ascii: "A"))
    }

    /// Lifetime from the market number's chemistry suffix: 44 is 16 days, 55 is 15, 33 is 14.
    private static func inferLifeTimeDays(_ marketNo: String) -> Int {
        if marketNo.hasPrefix("44") { return 16 }
        if marketNo.hasPrefix("55") { return 15 }
        if marketNo.hasPrefix("33") { return 14 }
        return AnytimeConstants.defaultRatedLifetimeDays
    }
}
