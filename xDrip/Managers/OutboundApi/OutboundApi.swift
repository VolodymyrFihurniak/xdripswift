//
//  OutboundApi.swift
//  xdrip
//
//  Outbound API: sends each new reading to a Telegram bot or to a custom JSON webhook. Port of
//  the Telegram and custom JSON presets of JugglucoNG OutboundApi / OutboundApiSettings
//  (docs/outbound-api.md). The VK and Delta Chat presets are not ported.
//
//  iOS differences from JugglucoNG:
//  - A send happens when the app stores a reading (foreground, or a Bluetooth background wake).
//    There is no background timer, so the Telegram "stale / missed reading" message cannot be
//    posted while readings are missing: it is posted before the next reading that arrives.
//  - Bot tokens, webhook URLs and headers are kept in the Keychain; the rest of a destination is a
//    JSON value in UserDefaults and the delivery state (last message id, last result) another one.
//    Neither key is part of backups.
//

import Foundation
import os
import Security
import UIKit

// MARK: - Texts

/// Localised texts for the Outbound API (SettingsViews table, `outbound.` keys).
enum OutboundApiTexts {
    static func text(_ key: String, _ english: String) -> String {
        NSLocalizedString("outbound." + key, tableName: "SettingsViews", bundle: .main, value: english, comment: "")
    }
}

// MARK: - Model

enum OutboundApiPreset: String, Codable, CaseIterable {
    case telegramBot = "telegram_bot"
    case customJSON = "custom_json"

    var defaultName: String {
        switch self {
        case .telegramBot: return OutboundApiTexts.text("presetTelegram", "Telegram bot")
        case .customJSON: return OutboundApiTexts.text("presetWebhook", "Custom JSON webhook")
        }
    }

    var defaultTemplate: String {
        switch self {
        case .telegramBot: return OutboundApiDefaults.chatTemplate
        case .customJSON: return OutboundApiDefaults.webhookTemplate
        }
    }
}

/// When a reading is sent (JugglucoNG trigger modes).
enum OutboundApiTriggerMode: String, Codable, CaseIterable {
    case always = "always"
    case atOrBelow = "at_or_below"
    case atOrAbove = "at_or_above"
    case outsideRange = "outside_range"
}

/// The range status a message can show with `{status}` and `{status_emoji}`.
enum OutboundApiStatus: String {
    case inRange = "in_range"
    case high = "high"
    case low = "low"
    case stale = "stale"
    case missed = "missed"

    var emoji: String {
        switch self {
        case .high: return "\u{1F7E1}"
        case .low: return "\u{1F534}"
        case .stale: return "\u{26A0}\u{FE0F}"
        case .missed: return "\u{26AA}"
        case .inRange: return "\u{1F7E2}"
        }
    }
}

enum OutboundApiDefaults {
    static let chatTemplate = "{status_emoji} {value} {unit} {trend_arrow} {time}"
    static let webhookTemplate = "{value} {unit} {trend_arrow} ({rate_mgdl} mg/dL/min) {time}"
    static let minIntervalMinutes = 5
    static let lowMgdl = 70
    static let highMgdl = 180
    static let refreshWindowMinutes = 15
    static let suppressDeltaBelowMgdl = 1
    static let staleThresholdMinutes = 10
    static let missedThresholdMinutes = 15
    /// A reading older than this is not sent as if it were live.
    static let maxReadingAge: TimeInterval = 15 * 60
    /// Telegram refuses a text longer than this.
    static let telegramTextLimit = 4096
}

/// One place readings go to. The bot token, webhook URL and headers are not part of it: they are
/// `OutboundApiSecrets`, kept in the Keychain.
struct OutboundApiDestination: Codable, Equatable, Identifiable {
    var id: String
    var enabled: Bool
    var name: String
    var preset: OutboundApiPreset
    /// Telegram: chat ids or @channel names, separated by comma, semicolon or new line.
    var chatId: String
    var messageTemplate: String
    /// Webhook: a raw JSON body with placeholders. Empty sends the standard body.
    var bodyTemplate: String
    /// 0 sends every reading.
    var minIntervalMinutes: Int
    var triggerMode: OutboundApiTriggerMode
    var triggerLowMgdl: Int
    var triggerHighMgdl: Int
    /// Telegram: edit the last message instead of posting a new one while it is recent.
    var refreshInPlaceEnabled: Bool
    var refreshWindowMinutes: Int
    var suppressDeltaBelowMgdl: Int
    /// Telegram: post a note before the next reading when readings were missing for a while.
    var staleEnabled: Bool
    var staleThresholdMinutes: Int
    var missedThresholdMinutes: Int

    init(id: String = UUID().uuidString,
         enabled: Bool = true,
         name: String,
         preset: OutboundApiPreset,
         chatId: String = "",
         messageTemplate: String = "",
         bodyTemplate: String = "",
         minIntervalMinutes: Int = OutboundApiDefaults.minIntervalMinutes,
         triggerMode: OutboundApiTriggerMode = .always,
         triggerLowMgdl: Int = OutboundApiDefaults.lowMgdl,
         triggerHighMgdl: Int = OutboundApiDefaults.highMgdl,
         refreshInPlaceEnabled: Bool = true,
         refreshWindowMinutes: Int = OutboundApiDefaults.refreshWindowMinutes,
         suppressDeltaBelowMgdl: Int = OutboundApiDefaults.suppressDeltaBelowMgdl,
         staleEnabled: Bool = true,
         staleThresholdMinutes: Int = OutboundApiDefaults.staleThresholdMinutes,
         missedThresholdMinutes: Int = OutboundApiDefaults.missedThresholdMinutes) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.preset = preset
        self.chatId = chatId
        self.messageTemplate = messageTemplate
        self.bodyTemplate = bodyTemplate
        self.minIntervalMinutes = minIntervalMinutes
        self.triggerMode = triggerMode
        self.triggerLowMgdl = triggerLowMgdl
        self.triggerHighMgdl = triggerHighMgdl
        self.refreshInPlaceEnabled = refreshInPlaceEnabled
        self.refreshWindowMinutes = refreshWindowMinutes
        self.suppressDeltaBelowMgdl = suppressDeltaBelowMgdl
        self.staleEnabled = staleEnabled
        self.staleThresholdMinutes = staleThresholdMinutes
        self.missedThresholdMinutes = missedThresholdMinutes
    }

    /// A new destination with the defaults of its preset.
    static func make(preset: OutboundApiPreset) -> OutboundApiDestination {
        OutboundApiDestination(name: preset.defaultName, preset: preset, messageTemplate: preset.defaultTemplate)
    }

    // Every field is optional when reading, so a later version can add fields without losing the
    // destinations an earlier one saved.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = OutboundApiPreset(rawValue: (try? container.decode(String.self, forKey: .preset)) ?? "") ?? .customJSON
        self.init(
            id: (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            enabled: (try? container.decode(Bool.self, forKey: .enabled)) ?? false,
            name: (try? container.decode(String.self, forKey: .name)) ?? preset.defaultName,
            preset: preset,
            chatId: (try? container.decode(String.self, forKey: .chatId)) ?? "",
            messageTemplate: (try? container.decode(String.self, forKey: .messageTemplate)) ?? "",
            bodyTemplate: (try? container.decode(String.self, forKey: .bodyTemplate)) ?? "",
            minIntervalMinutes: max((try? container.decode(Int.self, forKey: .minIntervalMinutes)) ?? OutboundApiDefaults.minIntervalMinutes, 0),
            triggerMode: OutboundApiTriggerMode(rawValue: (try? container.decode(String.self, forKey: .triggerMode)) ?? "") ?? .always,
            triggerLowMgdl: (try? container.decode(Int.self, forKey: .triggerLowMgdl)) ?? OutboundApiDefaults.lowMgdl,
            triggerHighMgdl: (try? container.decode(Int.self, forKey: .triggerHighMgdl)) ?? OutboundApiDefaults.highMgdl,
            refreshInPlaceEnabled: (try? container.decode(Bool.self, forKey: .refreshInPlaceEnabled)) ?? true,
            refreshWindowMinutes: (try? container.decode(Int.self, forKey: .refreshWindowMinutes)) ?? OutboundApiDefaults.refreshWindowMinutes,
            suppressDeltaBelowMgdl: (try? container.decode(Int.self, forKey: .suppressDeltaBelowMgdl)) ?? OutboundApiDefaults.suppressDeltaBelowMgdl,
            staleEnabled: (try? container.decode(Bool.self, forKey: .staleEnabled)) ?? true,
            staleThresholdMinutes: (try? container.decode(Int.self, forKey: .staleThresholdMinutes)) ?? OutboundApiDefaults.staleThresholdMinutes,
            missedThresholdMinutes: (try? container.decode(Int.self, forKey: .missedThresholdMinutes)) ?? OutboundApiDefaults.missedThresholdMinutes
        )
    }

    /// The chat ids of a Telegram destination.
    var recipients: [String] {
        chatId.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? preset.defaultName : trimmed
    }

    var resolvedTemplate: String {
        let trimmed = messageTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? preset.defaultTemplate : trimmed
    }
}

/// What must not sit in UserDefaults: the bot token, the webhook URL (often holds a key) and the
/// headers (often an Authorization value).
struct OutboundApiSecrets: Codable, Equatable {
    var token = ""
    var url = ""
    var headers = ""

    init(token: String = "", url: String = "", headers: String = "") {
        self.token = token
        self.url = url
        self.headers = headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = (try? container.decode(String.self, forKey: .token)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        headers = (try? container.decode(String.self, forKey: .headers)) ?? ""
    }

    var isEmpty: Bool { token.isEmpty && url.isEmpty && headers.isEmpty }
}

/// The last message of a Telegram chat, so the next reading can edit it.
struct OutboundApiBubble: Codable, Equatable {
    var messageId: Int64
    /// When a reading last arrived for it (also when the reading itself was not sent).
    var sentAt: Date
    var mgdl: Int
}

/// What a destination has done, shown in its settings and used to decide the next send.
struct OutboundApiDestinationState: Codable, Equatable {
    var lastQueuedEventId = ""
    var lastQueuedReadingAt: Date?
    /// When the last reading arrived at this destination, sent or not (drives the stale notice).
    var lastSeenAt: Date?
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastResponseCode = 0
    var lastError: String?
    /// Telegram: the last message per chat id.
    var bubbles: [String: OutboundApiBubble] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastQueuedEventId = (try? container.decode(String.self, forKey: .lastQueuedEventId)) ?? ""
        lastQueuedReadingAt = try? container.decode(Date.self, forKey: .lastQueuedReadingAt)
        lastSeenAt = try? container.decode(Date.self, forKey: .lastSeenAt)
        lastAttemptAt = try? container.decode(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try? container.decode(Date.self, forKey: .lastSuccessAt)
        lastResponseCode = (try? container.decode(Int.self, forKey: .lastResponseCode)) ?? 0
        lastError = try? container.decode(String.self, forKey: .lastError)
        bubbles = (try? container.decode([String: OutboundApiBubble].self, forKey: .bubbles)) ?? [:]
    }
}

// MARK: - The reading as a message sees it

struct OutboundApiReading: Equatable {
    var eventId: String
    var sensorId: String
    var timestamp: Date
    var mgdl: Double
    /// mg/dL per minute, nil when the app cannot compute a slope.
    var slopeMgdlPerMinute: Double?
    /// Nightscout trend name (`Flat`, `SingleUp` ...), empty when unknown.
    var trendName: String
    /// The user's unit, for `{value}`.
    var isMmol: Bool
    var test: Bool

    var roundedMgdl: Int { mgdl.isFinite ? Int(mgdl.rounded()) : 0 }
    var mmol: Double { mgdl * ConstantsBloodGlucose.mgDlToMmoll }
    var timeMillis: Int64 { Int64((timestamp.timeIntervalSince1970 * 1000).rounded()) }
    var trendArrow: String { OutboundApiTrend.arrow(forName: trendName) }

    static func makeEventId(sensorId: String, timeMillis: Int64, mgdl: Int) -> String {
        sensorId + ":" + String(timeMillis) + ":" + String(mgdl)
    }
}

enum OutboundApiTrend {
    /// The arrow of a Nightscout trend name, empty for an unknown one: a flat arrow for a slope the
    /// app could not compute would be wrong (JugglucoNG shows a flat arrow there).
    static func arrow(forName name: String) -> String {
        switch name {
        case "DoubleUp": return "\u{2191}\u{2191}"
        case "SingleUp": return "\u{2191}"
        case "FortyFiveUp": return "\u{2197}"
        case "Flat": return "\u{2192}"
        case "FortyFiveDown": return "\u{2198}"
        case "SingleDown": return "\u{2193}"
        case "DoubleDown": return "\u{2193}\u{2193}"
        default: return ""
        }
    }

    /// The trend name when it is one of the seven known ones, else empty.
    static func knownName(_ name: String) -> String {
        arrow(forName: name).isEmpty ? "" : name
    }
}

// MARK: - Template

enum OutboundApiTemplate {
    /// The placeholders a template understands, as shown in the settings.
    static let tokenNames = [
        "value", "unit", "mgdl", "mmol", "trend", "trend_arrow", "rate_mgdl", "rate_mmol",
        "status", "status_emoji", "time", "timestamp", "sensor", "event_id", "recipient", "test", "message"
    ]

    /// Replaces every `{name}` that has a value; an unknown `{name}` stays as written. Values are
    /// inserted once and never scanned again. `escapeJSON` makes a value safe inside a JSON string.
    static func render(_ template: String, values: [String: String], escapeJSON: Bool = false) -> String {
        let characters = Array(template)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "{", let close = closingBrace(in: characters, after: index) {
                let name = String(characters[(index + 1)..<close])
                if let value = values[name] {
                    output += escapeJSON ? jsonEscaped(value) : value
                    index = close + 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// The index of the `}` ending a placeholder that starts at `open`: the name between them is
    /// not empty and holds no brace or whitespace (JugglucoNG `PLACEHOLDER`).
    private static func closingBrace(in characters: [Character], after open: Int) -> Int? {
        var index = open + 1
        while index < characters.count {
            let character = characters[index]
            if character == "}" { return index > open + 1 ? index : nil }
            if character == "{" || character.isWhitespace { return nil }
            index += 1
        }
        return nil
    }

    /// The text escaped for the inside of a JSON string (no surrounding quotes).
    static func jsonEscaped(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

    /// A number with a fixed number of decimals and a dot, without a minus sign on a zero.
    static func number(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "" }
        let text = String(format: "%.\(decimals)f", value)
        if text.hasPrefix("-"), let parsed = Double(text), parsed == 0 { return String(text.dropFirst()) }
        return text
    }

    /// The value of every placeholder for one reading and one recipient.
    static func values(reading: OutboundApiReading, recipient: String, lowMgdl: Int, highMgdl: Int,
                       formatTime: (Date) -> String) -> [String: String] {
        let status = OutboundApiTrigger.status(lowMgdl: lowMgdl, highMgdl: highMgdl, mgdl: reading.roundedMgdl)
        var values: [String: String] = [:]
        values["value"] = reading.isMmol ? number(reading.mmol, decimals: 1) : String(reading.roundedMgdl)
        values["unit"] = reading.isMmol ? "mmol/L" : "mg/dL"
        values["mgdl"] = String(reading.roundedMgdl)
        values["mmol"] = number(reading.mmol, decimals: 2)
        values["trend"] = reading.trendName
        values["trend_arrow"] = reading.trendArrow
        if let slope = reading.slopeMgdlPerMinute {
            values["rate_mgdl"] = number(slope, decimals: 1)
            values["rate_mmol"] = number(slope * ConstantsBloodGlucose.mgDlToMmoll, decimals: 3)
        } else {
            values["rate_mgdl"] = ""
            values["rate_mmol"] = ""
        }
        values["status"] = status.rawValue
        values["status_emoji"] = status.emoji
        values["time"] = formatTime(reading.timestamp)
        values["timestamp"] = String(reading.timeMillis)
        values["sensor"] = reading.sensorId
        values["event_id"] = reading.eventId
        values["recipient"] = recipient
        values["test"] = reading.test ? "true" : "false"
        return values
    }
}

// MARK: - Trigger, interval and decision

enum OutboundApiTrigger {
    /// JugglucoNG `shouldSendForGlucose`. Both thresholds are inclusive.
    static func shouldSend(mode: OutboundApiTriggerMode, lowMgdl: Int, highMgdl: Int, mgdl: Int) -> Bool {
        guard mgdl > 0 else { return false }
        let low = min(max(lowMgdl, 1), 600)
        let high = min(max(highMgdl, 1), 600)
        switch mode {
        case .always: return true
        case .atOrBelow: return mgdl <= low
        case .atOrAbove: return mgdl >= high
        case .outsideRange: return mgdl <= low || mgdl >= high
        }
    }

    /// JugglucoNG `rangeStatus`: below the low threshold is low, above the high one is high.
    static func status(lowMgdl: Int, highMgdl: Int, mgdl: Int) -> OutboundApiStatus {
        guard mgdl > 0 else { return .inRange }
        let low = min(max(lowMgdl, 1), 600)
        let high = min(max(highMgdl, 1), 600)
        if mgdl < low { return .low }
        if mgdl > high { return .high }
        return .inRange
    }
}

enum OutboundApiGateResult: Equatable {
    case allowed
    case duplicate
    case tooSoon
}

enum OutboundApiIntervalGate {
    /// Readings of a sensor that reads every five minutes arrive a few seconds early or late; a
    /// five minute interval must not drop every second one.
    static let slackSeconds: TimeInterval = 10
    /// While power saving applies, a destination gets at most one reading per this many minutes.
    static let powerSavingMinutes = 5

    static func effectiveMinIntervalMinutes(configured: Int, powerSavingThrottle: Bool) -> Int {
        let base = max(configured, 0)
        return powerSavingThrottle ? max(base, powerSavingMinutes) : base
    }

    /// JugglucoNG `shouldQueue`, on the time of the reading instead of the time it arrived.
    static func check(eventId: String, lastEventId: String, readingDate: Date, lastQueuedReadingDate: Date?,
                      minIntervalMinutes: Int) -> OutboundApiGateResult {
        if eventId == lastEventId { return .duplicate }
        guard minIntervalMinutes > 0, let last = lastQueuedReadingDate else { return .allowed }
        let required = TimeInterval(minIntervalMinutes) * 60 - slackSeconds
        return readingDate.timeIntervalSince(last) >= required ? .allowed : .tooSoon
    }
}

enum OutboundApiSkipReason: Equatable {
    case invalidReading
    case oldReading
    case trigger
    case duplicate
    case interval
}

enum OutboundApiDecision: Equatable {
    case send
    case skip(OutboundApiSkipReason)
}

enum OutboundApiPlanner {
    /// Whether a reading goes to a destination now: a usable and recent reading, the trigger, then
    /// the interval gate (JugglucoNG order).
    static func decide(destination: OutboundApiDestination, state: OutboundApiDestinationState, reading: OutboundApiReading,
                       now: Date, powerSavingThrottle: Bool) -> OutboundApiDecision {
        let mgdl = reading.roundedMgdl
        guard mgdl > 0 else { return .skip(.invalidReading) }
        guard now.timeIntervalSince(reading.timestamp) <= OutboundApiDefaults.maxReadingAge else { return .skip(.oldReading) }
        guard OutboundApiTrigger.shouldSend(mode: destination.triggerMode, lowMgdl: destination.triggerLowMgdl,
                                            highMgdl: destination.triggerHighMgdl, mgdl: mgdl) else { return .skip(.trigger) }
        let interval = OutboundApiIntervalGate.effectiveMinIntervalMinutes(configured: destination.minIntervalMinutes,
                                                                          powerSavingThrottle: powerSavingThrottle)
        switch OutboundApiIntervalGate.check(eventId: reading.eventId, lastEventId: state.lastQueuedEventId,
                                             readingDate: reading.timestamp, lastQueuedReadingDate: state.lastQueuedReadingAt,
                                             minIntervalMinutes: interval) {
        case .allowed: return .send
        case .duplicate: return .skip(.duplicate)
        case .tooSoon: return .skip(.interval)
        }
    }
}

// MARK: - Telegram message editing and the gap notice

enum OutboundApiBubbleAction: Equatable {
    /// The last message already shows this value: send nothing.
    case suppress(messageId: Int64)
    case edit(messageId: Int64)
    case send
}

enum OutboundApiGapKind: Equatable {
    case stale
    case missed
}

enum OutboundApiBubblePlanner {
    /// JugglucoNG `sendTelegram`: inside the refresh window the last message is edited, or left
    /// alone when the value changed by less than `suppressBelowMgdl`. A test is never suppressed.
    static func plan(refreshEnabled: Bool, windowMinutes: Int, suppressBelowMgdl: Int, bubble: OutboundApiBubble?,
                     mgdl: Int, isTest: Bool, now: Date) -> OutboundApiBubbleAction {
        guard refreshEnabled, let bubble = bubble, bubble.messageId > 0 else { return .send }
        let window = TimeInterval(min(max(windowMinutes, 1), 60) * 60)
        guard now.timeIntervalSince(bubble.sentAt) <= window else { return .send }
        let threshold = min(max(suppressBelowMgdl, 0), 100)
        if !isTest, threshold > 0, abs(mgdl - bubble.mgdl) < threshold { return .suppress(messageId: bubble.messageId) }
        return .edit(messageId: bubble.messageId)
    }

    /// JugglucoNG posts "stale" and "missed" from a timer. iOS has none, so the silence is
    /// noticed when the next reading arrives: `previousSeenAt` is when the one before it did.
    static func gapNotice(enabled: Bool, staleMinutes: Int, missedMinutes: Int, hasBubble: Bool,
                          previousSeenAt: Date?, now: Date) -> OutboundApiGapKind? {
        guard enabled, hasBubble, let previous = previousSeenAt else { return nil }
        let stale = min(max(staleMinutes, 1), 120)
        let missed = min(max(missedMinutes, stale + 1), 240)
        let gap = now.timeIntervalSince(previous)
        if gap >= TimeInterval(missed * 60) { return .missed }
        if gap >= TimeInterval(stale * 60) { return .stale }
        return nil
    }
}

// MARK: - Validation

enum OutboundApiConfigIssue: Equatable {
    case missingToken
    case invalidToken
    case missingChatId
    case invalidChatId
    case missingURL
    case invalidURL
}

enum OutboundApiValidation {
    /// The token as the Bot API wants it: trimmed, without a leading "bot".
    static func normalizedTelegramToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("bot") ? String(trimmed.dropFirst(3)) : trimmed
    }

    /// `<bot id>:<secret>`. Anything else could change the path of the request URL.
    static func isTelegramToken(_ token: String) -> Bool {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let digits = Set("0123456789")
        let secret = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return parts[0].allSatisfy { digits.contains($0) } && parts[1].allSatisfy { secret.contains($0) }
    }

    /// A numeric chat id (negative for groups and channels) or an @channel name.
    static func isTelegramRecipient(_ recipient: String) -> Bool {
        let digits = Set("0123456789")
        if recipient.hasPrefix("@") {
            let name = recipient.dropFirst()
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
            return !name.isEmpty && name.allSatisfy { allowed.contains($0) }
        }
        let number = recipient.hasPrefix("-") ? recipient.dropFirst() : Substring(recipient)
        return !number.isEmpty && number.allSatisfy { digits.contains($0) }
    }

    static func webhookURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// What is wrong with a destination, nil when it can send.
    static func issue(for destination: OutboundApiDestination, secrets: OutboundApiSecrets) -> OutboundApiConfigIssue? {
        switch destination.preset {
        case .telegramBot:
            let token = normalizedTelegramToken(secrets.token)
            if token.isEmpty { return .missingToken }
            if !isTelegramToken(token) { return .invalidToken }
            let recipients = destination.recipients
            if recipients.isEmpty { return .missingChatId }
            if !recipients.allSatisfy({ isTelegramRecipient($0) }) { return .invalidChatId }
            return nil
        case .customJSON:
            if secrets.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingURL }
            return webhookURL(secrets.url) == nil ? .invalidURL : nil
        }
    }

    /// The trigger thresholds are stored in mg/dL and edited in the user's unit.
    static func displayThreshold(mgdl: Int, isMmol: Bool) -> Double {
        isMmol ? (Double(mgdl) * ConstantsBloodGlucose.mgDlToMmoll * 10).rounded() / 10 : Double(mgdl)
    }

    static func thresholdMgdl(display: Double, isMmol: Bool) -> Int {
        isMmol ? Int((display / ConstantsBloodGlucose.mgDlToMmoll).rounded()) : Int(display.rounded())
    }
}

// MARK: - Requests and responses

enum OutboundApiRequestBuilder {
    static var userAgent: String { ConstantsHomeView.applicationName + " outbound API" }

    /// `https://api.telegram.org/bot{token}/{method}`, nil for a token that is not one.
    static func telegramURL(token: String, method: String) -> URL? {
        let normalized = OutboundApiValidation.normalizedTelegramToken(token)
        guard OutboundApiValidation.isTelegramToken(normalized) else { return nil }
        return URL(string: "https://api.telegram.org/bot" + normalized + "/" + method)
    }

    static func telegramRequest(method: String, token: String, payload: [String: Any]) -> URLRequest? {
        guard let url = telegramURL(token: token, method: method) else { return nil }
        var body = payload
        if let text = body["text"] as? String, text.count > OutboundApiDefaults.telegramTextLimit {
            body["text"] = String(text.prefix(OutboundApiDefaults.telegramTextLimit))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return jsonRequest(url: url, headers: "", body: data)
    }

    static func webhookRequest(url: URL, headers: String, body: Data) -> URLRequest {
        jsonRequest(url: url, headers: headers, body: body)
    }

    private static func jsonRequest(url: URL, headers: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for header in parseHeaders(headers) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    /// `Name: value` per line. A line without a name or a value is skipped, and Content-Type
    /// cannot be changed (JugglucoNG `applyHeaders`).
    static func parseHeaders(_ raw: String) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":"), separator != trimmed.startIndex else { continue }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty, name.allSatisfy({ allowed.contains($0) }) else { continue }
            if name.lowercased() == "content-type" { continue }
            headers.append((name: name, value: value))
        }
        return headers
    }

    /// The body a webhook gets when it has no body template (the JugglucoNG fields that this app
    /// has, under its own schema name).
    static func standardBody(destination: OutboundApiDestination, reading: OutboundApiReading, message: String,
                             status: OutboundApiStatus) -> Data {
        let displayValue: String = reading.isMmol ? OutboundApiTemplate.number(reading.mmol, decimals: 1) : String(reading.roundedMgdl)
        let displayUnit: String = reading.isMmol ? "mmol/L" : "mg/dL"
        let glucoseMmol: Double = Double(OutboundApiTemplate.number(reading.mmol, decimals: 2)) ?? 0
        var body: [String: Any] = [:]
        body["schema"] = "xdrip.outbound.glucose.v1"
        body["type"] = "glucose"
        body["destination_id"] = destination.id
        body["destination_preset"] = destination.preset.rawValue
        body["event_id"] = reading.eventId
        body["test"] = reading.test
        body["app"] = ConstantsHomeView.applicationName
        body["sensor_id"] = reading.sensorId
        body["timestamp"] = reading.timeMillis
        body["glucose_mgdl"] = reading.roundedMgdl
        body["glucose_mmol"] = glucoseMmol
        body["display_value"] = displayValue
        body["display_unit"] = displayUnit
        body["trend"] = reading.trendName
        body["trend_arrow"] = reading.trendArrow
        body["status"] = status.rawValue
        body["message"] = message
        if let slope = reading.slopeMgdlPerMinute, slope.isFinite {
            body["rate_mgdl_per_min"] = slope
            body["rate_mmol_per_min"] = slope * ConstantsBloodGlucose.mgDlToMmoll
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

struct OutboundApiResponse: Equatable {
    var code: Int
    var ok: Bool
    var retryable: Bool
    var error: String?
    var messageId: Int64?
}

enum OutboundApiResponseParser {
    /// JugglucoNG `executePostOnce` with `parseTelegramError` / `parseTelegramMessageId`: a body
    /// with `"ok": false` is an error whatever the status code says.
    static func telegram(statusCode: Int, body: Data) -> OutboundApiResponse {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let root = root, let ok = root["ok"] as? Bool, !ok {
            let apiCode = (root["error_code"] as? Int).flatMap { $0 != 0 ? $0 : nil }
            let description = (root["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Telegram API error"
            let code = apiCode ?? statusCode
            let retryableCodes = [429, 500, 502, 503]
            return OutboundApiResponse(code: code, ok: false,
                                       retryable: retryableCodes.contains(apiCode ?? 0) || code == 429 || code >= 500,
                                       error: description, messageId: nil)
        }
        let ok = (200...299).contains(statusCode)
        var messageId: Int64?
        if ok, let result = root?["result"] as? [String: Any], let id = (result["message_id"] as? NSNumber)?.int64Value, id > 0 {
            messageId = id
        }
        return OutboundApiResponse(code: statusCode, ok: ok, retryable: statusCode == 429 || statusCode >= 500,
                                   error: ok ? nil : errorText(body: body, statusCode: statusCode), messageId: messageId)
    }

    static func webhook(statusCode: Int, body: Data) -> OutboundApiResponse {
        let ok = (200...299).contains(statusCode)
        return OutboundApiResponse(code: statusCode, ok: ok, retryable: statusCode == 429 || statusCode >= 500,
                                   error: ok ? nil : errorText(body: body, statusCode: statusCode), messageId: nil)
    }

    private static func errorText(body: Data, statusCode: Int) -> String {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "HTTP " + String(statusCode) : String(text.prefix(500))
    }
}

enum OutboundApiRedactor {
    /// Hides every secret in a text that is stored or shown (an error text can echo a URL).
    static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets.sorted(by: { $0.count > $1.count }) where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return result
    }
}

// MARK: - Secrets

protocol OutboundApiSecretStoring: AnyObject {
    func load(id: String) -> OutboundApiSecrets
    @discardableResult func save(_ secrets: OutboundApiSecrets, id: String) -> Bool
    func delete(id: String)
}

/// One generic-password Keychain item per destination, after first unlock and this device only,
/// so a Bluetooth wake with the phone locked can still send.
final class OutboundApiKeychainSecretStore: OutboundApiSecretStoring {
    private let service: String

    init(service: String = ConstantsHomeView.applicationName + ".outbound") {
        self.service = service
    }

    func load(id: String) -> OutboundApiSecrets {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secrets = try? JSONDecoder().decode(OutboundApiSecrets.self, from: data) else { return OutboundApiSecrets() }
        return secrets
    }

    @discardableResult
    func save(_ secrets: OutboundApiSecrets, id: String) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let query = baseQuery(id: id)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func delete(id: String) {
        SecItemDelete(baseQuery(id: id) as CFDictionary)
    }

    private func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

/// Keeps secrets in memory only, for tests.
final class OutboundApiMemorySecretStore: OutboundApiSecretStoring {
    private let lock = NSLock()
    private var items: [String: OutboundApiSecrets] = [:]

    func load(id: String) -> OutboundApiSecrets {
        lock.lock()
        defer { lock.unlock() }
        return items[id] ?? OutboundApiSecrets()
    }

    @discardableResult
    func save(_ secrets: OutboundApiSecrets, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items[id] = secrets
        return true
    }

    func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        items[id] = nil
    }
}

// MARK: - Store

/// The destinations, their secrets and what each has done. Safe to use from any thread.
final class OutboundApiStore {
    static let shared = OutboundApiStore()
    static let destinationsKey = "outboundApiDestinations"
    static let stateKey = "outboundApiState"

    private let defaults: UserDefaults
    private let secretStore: OutboundApiSecretStoring
    private let lock = NSLock()
    private var cachedDestinations: [OutboundApiDestination]?
    private var cachedState: [String: OutboundApiDestinationState]?
    private var cachedSecrets: [String: OutboundApiSecrets] = [:]

    init(defaults: UserDefaults = .standard, secretStore: OutboundApiSecretStoring = OutboundApiKeychainSecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    var destinations: [OutboundApiDestination] {
        lock.lock()
        defer { lock.unlock() }
        return loadDestinations()
    }

    func destination(id: String) -> OutboundApiDestination? {
        destinations.first { $0.id == id }
    }

    func secrets(id: String) -> OutboundApiSecrets {
        lock.lock()
        defer { lock.unlock() }
        return loadSecrets(id: id)
    }

    /// Adds or replaces a destination, and its secrets when given. Nothing is written when
    /// nothing changed.
    func upsert(_ destination: OutboundApiDestination, secrets: OutboundApiSecrets? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var list = loadDestinations()
        if let index = list.firstIndex(where: { $0.id == destination.id }) {
            if list[index] != destination {
                list[index] = destination
                saveDestinations(list)
            }
        } else {
            list.append(destination)
            saveDestinations(list)
        }
        if let secrets = secrets, loadSecrets(id: destination.id) != secrets {
            secretStore.save(secrets, id: destination.id)
            cachedSecrets[destination.id] = secrets
        }
    }

    func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        saveDestinations(loadDestinations().filter { $0.id != id })
        var states = loadStates()
        states[id] = nil
        saveStates(states)
        secretStore.delete(id: id)
        cachedSecrets[id] = nil
    }

    func state(id: String) -> OutboundApiDestinationState {
        lock.lock()
        defer { lock.unlock() }
        return loadStates()[id] ?? OutboundApiDestinationState()
    }

    func updateState(id: String, _ change: (inout OutboundApiDestinationState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var states = loadStates()
        var state = states[id] ?? OutboundApiDestinationState()
        change(&state)
        states[id] = state
        saveStates(states)
    }

    /// The destinations that are on and complete.
    func readyDestinations() -> [(destination: OutboundApiDestination, secrets: OutboundApiSecrets)] {
        lock.lock()
        defer { lock.unlock() }
        var ready: [(destination: OutboundApiDestination, secrets: OutboundApiSecrets)] = []
        for destination in loadDestinations() where destination.enabled {
            let secrets = loadSecrets(id: destination.id)
            if OutboundApiValidation.issue(for: destination, secrets: secrets) == nil {
                ready.append((destination: destination, secrets: secrets))
            }
        }
        return ready
    }

    // The helpers below expect the lock to be held.

    private func loadDestinations() -> [OutboundApiDestination] {
        if let cached = cachedDestinations { return cached }
        var list: [OutboundApiDestination] = []
        if let data = defaults.data(forKey: Self.destinationsKey),
           let decoded = try? JSONDecoder().decode([OutboundApiDestination].self, from: data) {
            var seen = Set<String>()
            list = decoded.filter { seen.insert($0.id.lowercased()).inserted }
        }
        cachedDestinations = list
        return list
    }

    private func saveDestinations(_ list: [OutboundApiDestination]) {
        cachedDestinations = list
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.destinationsKey)
    }

    private func loadStates() -> [String: OutboundApiDestinationState] {
        if let cached = cachedState { return cached }
        var states: [String: OutboundApiDestinationState] = [:]
        if let data = defaults.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode([String: OutboundApiDestinationState].self, from: data) {
            states = decoded
        }
        cachedState = states
        return states
    }

    private func saveStates(_ states: [String: OutboundApiDestinationState]) {
        cachedState = states
        defaults.set(try? JSONEncoder().encode(states), forKey: Self.stateKey)
    }

    private func loadSecrets(id: String) -> OutboundApiSecrets {
        if let cached = cachedSecrets[id] { return cached }
        let loaded = secretStore.load(id: id)
        // An empty answer may be a Keychain that is not readable yet: ask again next time.
        if !loaded.isEmpty { cachedSecrets[id] = loaded }
        return loaded
    }
}

// MARK: - Sending

protocol OutboundApiTransport {
    func send(_ request: URLRequest) async throws -> (statusCode: Int, body: Data)
}

struct OutboundApiURLSessionTransport: OutboundApiTransport {
    private let session: URLSession

    init(session: URLSession = OutboundApiURLSessionTransport.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (statusCode: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (statusCode: code, body: data)
    }
}

struct OutboundApiDeliveryResult: Equatable {
    var ok: Bool
    var code: Int
    var error: String?
    /// Nothing was sent: the last Telegram message already showed this value.
    var suppressed = false
}

/// Sends one reading to one destination and records what happened. A failed send is not retried:
/// the next reading is sent as usual.
final class OutboundApiDispatcher {
    private let store: OutboundApiStore
    private let transport: OutboundApiTransport

    init(store: OutboundApiStore, transport: OutboundApiTransport = OutboundApiURLSessionTransport()) {
        self.store = store
        self.transport = transport
    }

    func deliver(destination: OutboundApiDestination, secrets: OutboundApiSecrets, reading: OutboundApiReading,
                 previousSeenAt: Date?, now: Date, formatTime: @escaping (Date) -> String) async -> OutboundApiDeliveryResult {
        let result: OutboundApiDeliveryResult
        switch destination.preset {
        case .telegramBot:
            var combined: OutboundApiDeliveryResult?
            for recipient in destination.recipients {
                let one = await deliverTelegram(destination: destination, token: secrets.token, recipient: recipient,
                                                reading: reading, previousSeenAt: previousSeenAt, now: now, formatTime: formatTime)
                if combined == nil || (combined?.ok == true && !one.ok) { combined = one }
            }
            result = combined ?? OutboundApiDeliveryResult(ok: false, code: -1,
                                                           error: OutboundApiTexts.text("issueMissingChatId", "Enter a chat ID."))
        case .customJSON:
            result = await deliverWebhook(destination: destination, secrets: secrets, reading: reading, now: now, formatTime: formatTime)
        }
        record(result, destination: destination, secrets: secrets, now: now)
        return result
    }

    private func record(_ result: OutboundApiDeliveryResult, destination: OutboundApiDestination, secrets: OutboundApiSecrets, now: Date) {
        guard !result.suppressed else { return }
        let hidden = [secrets.token, OutboundApiValidation.normalizedTelegramToken(secrets.token), secrets.url]
        store.updateState(id: destination.id) { state in
            state.lastAttemptAt = now
            state.lastResponseCode = result.code
            if result.ok {
                state.lastSuccessAt = now
                state.lastError = nil
            } else {
                state.lastError = OutboundApiRedactor.redact(result.error ?? "", secrets: hidden)
            }
        }
    }

    // MARK: Telegram

    private func deliverTelegram(destination: OutboundApiDestination, token: String, recipient: String, reading: OutboundApiReading,
                                 previousSeenAt: Date?, now: Date, formatTime: @escaping (Date) -> String) async -> OutboundApiDeliveryResult {
        let bubble = store.state(id: destination.id).bubbles[recipient]
        var mayEdit = true
        if !reading.test, let since = previousSeenAt,
           let gap = OutboundApiBubblePlanner.gapNotice(enabled: destination.staleEnabled, staleMinutes: destination.staleThresholdMinutes,
                                                        missedMinutes: destination.missedThresholdMinutes, hasBubble: bubble != nil,
                                                        previousSeenAt: since, now: now) {
            // The notice is a message of its own, so the reading after it starts a new message.
            _ = await postTelegram(method: "sendMessage", token: token, payload: ["chat_id": recipient, "text": Self.gapText(gap, from: since, to: now)])
            mayEdit = false
        }

        let values = OutboundApiTemplate.values(reading: reading, recipient: recipient, lowMgdl: destination.triggerLowMgdl,
                                                highMgdl: destination.triggerHighMgdl, formatTime: formatTime)
        let text = OutboundApiTemplate.render(destination.resolvedTemplate, values: values)
        let action = OutboundApiBubblePlanner.plan(refreshEnabled: destination.refreshInPlaceEnabled && mayEdit,
                                                   windowMinutes: destination.refreshWindowMinutes,
                                                   suppressBelowMgdl: destination.suppressDeltaBelowMgdl, bubble: bubble,
                                                   mgdl: reading.roundedMgdl, isTest: reading.test, now: now)
        switch action {
        case .suppress:
            // The reading arrived, even though nothing is sent: keep the bubble and the stale clock fresh.
            store.updateState(id: destination.id) { $0.bubbles[recipient]?.sentAt = now }
            return OutboundApiDeliveryResult(ok: true, code: 200, error: nil, suppressed: true)
        case .edit(let messageId):
            let response = await postTelegram(method: "editMessageText", token: token,
                                              payload: ["chat_id": recipient, "message_id": messageId, "text": text])
            if response.ok || response.error?.contains("not modified") == true {
                keepBubble(destination: destination, recipient: recipient, messageId: messageId, reading: reading, now: now)
                return OutboundApiDeliveryResult(ok: true, code: 200, error: nil)
            }
            // A rate limit or a server error keeps the message for the next reading to try again.
            if response.retryable { return Self.result(from: response) }
            // The message is gone or cannot be edited: start a new one.
            store.updateState(id: destination.id) { $0.bubbles[recipient] = nil }
        case .send:
            break
        }

        let response = await postTelegram(method: "sendMessage", token: token, payload: ["chat_id": recipient, "text": text])
        if response.ok, let messageId = response.messageId {
            keepBubble(destination: destination, recipient: recipient, messageId: messageId, reading: reading, now: now)
        }
        return Self.result(from: response)
    }

    private func keepBubble(destination: OutboundApiDestination, recipient: String, messageId: Int64, reading: OutboundApiReading, now: Date) {
        store.updateState(id: destination.id) {
            $0.bubbles[recipient] = OutboundApiBubble(messageId: messageId, sentAt: now, mgdl: reading.roundedMgdl)
        }
    }

    private func postTelegram(method: String, token: String, payload: [String: Any]) async -> OutboundApiResponse {
        guard let request = OutboundApiRequestBuilder.telegramRequest(method: method, token: token, payload: payload) else {
            return OutboundApiResponse(code: -1, ok: false, retryable: false,
                                       error: OutboundApiTexts.text("issueInvalidToken", "The bot token is not valid."), messageId: nil)
        }
        return await perform(request, isTelegram: true)
    }

    static func gapText(_ kind: OutboundApiGapKind, from: Date, to: Date) -> String {
        let status: OutboundApiStatus = kind == .missed ? .missed : .stale
        let format = kind == .missed
            ? OutboundApiTexts.text("gapMissed", "Missed readings: none from %@ to %@.")
            : OutboundApiTexts.text("gapStale", "Stale: no reading from %@ to %@.")
        return status.emoji + " " + String(format: format, OutboundApiFormatting.clock(from), OutboundApiFormatting.clock(to))
    }

    // MARK: Webhook

    private func deliverWebhook(destination: OutboundApiDestination, secrets: OutboundApiSecrets, reading: OutboundApiReading,
                                now: Date, formatTime: @escaping (Date) -> String) async -> OutboundApiDeliveryResult {
        guard let url = OutboundApiValidation.webhookURL(secrets.url) else {
            return OutboundApiDeliveryResult(ok: false, code: -1, error: OutboundApiTexts.text("issueInvalidURL", "The webhook URL is not valid."))
        }
        var values = OutboundApiTemplate.values(reading: reading, recipient: "", lowMgdl: destination.triggerLowMgdl,
                                                highMgdl: destination.triggerHighMgdl, formatTime: formatTime)
        let message = OutboundApiTemplate.render(destination.resolvedTemplate, values: values)
        values["message"] = message
        let bodyTemplate = destination.bodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: Data
        if bodyTemplate.isEmpty {
            let status = OutboundApiTrigger.status(lowMgdl: destination.triggerLowMgdl, highMgdl: destination.triggerHighMgdl,
                                                   mgdl: reading.roundedMgdl)
            body = OutboundApiRequestBuilder.standardBody(destination: destination, reading: reading, message: message, status: status)
        } else {
            body = Data(OutboundApiTemplate.render(bodyTemplate, values: values, escapeJSON: true).utf8)
        }
        let request = OutboundApiRequestBuilder.webhookRequest(url: url, headers: secrets.headers, body: body)
        return Self.result(from: await perform(request, isTelegram: false))
    }

    // MARK: Shared

    private func perform(_ request: URLRequest, isTelegram: Bool) async -> OutboundApiResponse {
        do {
            let (code, body) = try await transport.send(request)
            return isTelegram ? OutboundApiResponseParser.telegram(statusCode: code, body: body)
                              : OutboundApiResponseParser.webhook(statusCode: code, body: body)
        } catch {
            let raw = error.localizedDescription
            let text = isTelegram
                ? String(format: OutboundApiTexts.text("telegramConnectionFailed", "Telegram Bot API connection failed: %@"), raw)
                : raw
            return OutboundApiResponse(code: -1, ok: false, retryable: true, error: text, messageId: nil)
        }
    }

    private static func result(from response: OutboundApiResponse) -> OutboundApiDeliveryResult {
        OutboundApiDeliveryResult(ok: response.ok, code: response.code, error: response.error)
    }
}

enum OutboundApiFormatting {
    /// The time of day in the user's format.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The date and time in the user's format (`{time}`).
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Manager

enum OutboundApiTestOutcome: Equatable {
    case sent
    case notConfigured(OutboundApiConfigIssue)
    case noReading
    case failed(String)
}

/// Called by the coordinator when a new reading is stored, next to the Nightscout and Dexcom
/// Share uploads. Sends nothing while no destination is on and complete.
@MainActor final class OutboundApiManager {
    static let shared = OutboundApiManager()

    private let store: OutboundApiStore
    private let dispatcher: OutboundApiDispatcher
    private var bgReadingsAccessor: BgReadingsAccessor?
    private var sending: Set<String> = []
    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryOutboundApi)

    init(store: OutboundApiStore = .shared, dispatcher: OutboundApiDispatcher? = nil) {
        self.store = store
        self.dispatcher = dispatcher ?? OutboundApiDispatcher(store: store)
    }

    func configure(bgReadingsAccessor: BgReadingsAccessor) {
        self.bgReadingsAccessor = bgReadingsAccessor
    }

    /// Offers the newest reading to every destination that is on.
    func processNewReading(now: Date = Date()) {
        let ready = store.readyDestinations()
        guard !ready.isEmpty, let reading = latestReading(maxAge: nil, test: false, now: now) else { return }
        let throttle = ExperimentalPowerSaving.isActive() && !ExperimentalPowerSaving.isUrgent(mgDl: reading.mgdl)
        for item in ready {
            let destination = item.destination
            let state = store.state(id: destination.id)
            store.updateState(id: destination.id) { $0.lastSeenAt = now }
            guard !sending.contains(destination.id) else { continue }
            guard OutboundApiPlanner.decide(destination: destination, state: state, reading: reading, now: now,
                                            powerSavingThrottle: throttle) == .send else { continue }
            store.updateState(id: destination.id) {
                $0.lastQueuedEventId = reading.eventId
                $0.lastQueuedReadingAt = reading.timestamp
            }
            send(destination: destination, secrets: item.secrets, reading: reading, previousSeenAt: state.lastSeenAt, now: now)
        }
    }

    /// Sends the newest reading to one destination now, whatever its trigger and interval say.
    func sendTest(destinationId: String, now: Date = Date()) async -> OutboundApiTestOutcome {
        guard let destination = store.destination(id: destinationId) else { return .failed("") }
        let secrets = store.secrets(id: destinationId)
        if let issue = OutboundApiValidation.issue(for: destination, secrets: secrets) { return .notConfigured(issue) }
        guard let reading = latestReading(maxAge: 12 * 60 * 60, test: true, now: now) else { return .noReading }
        let result = await dispatcher.deliver(destination: destination, secrets: secrets, reading: reading, previousSeenAt: nil,
                                              now: now, formatTime: { OutboundApiFormatting.dateTime($0) })
        return result.ok ? .sent : .failed(store.state(id: destinationId).lastError ?? "")
    }

    private func send(destination: OutboundApiDestination, secrets: OutboundApiSecrets, reading: OutboundApiReading,
                      previousSeenAt: Date?, now: Date) {
        sending.insert(destination.id)
        let background = OutboundApiBackgroundTask()
        background.begin()
        let destinationId = destination.id
        let name = destination.resolvedName
        Task { @MainActor [weak self] in
            guard let self = self else {
                background.end()
                return
            }
            let result = await self.dispatcher.deliver(destination: destination, secrets: secrets, reading: reading,
                                                       previousSeenAt: previousSeenAt, now: now,
                                                       formatTime: { OutboundApiFormatting.dateTime($0) })
            self.sending.remove(destinationId)
            background.end()
            trace("in OutboundApiManager, destination %{public}@ delivered = %{public}@, code = %{public}@", log: self.log,
                  category: ConstantsLog.categoryOutboundApi, type: result.ok ? .info : .error,
                  name, result.ok.description, result.code.description)
        }
    }

    private func latestReading(maxAge: TimeInterval?, test: Bool, now: Date) -> OutboundApiReading? {
        guard let accessor = bgReadingsAccessor else { return nil }
        let fromDate: Date? = maxAge.map { now.addingTimeInterval(-$0) }
        guard let newest = accessor.getLatestBgReadings(limit: 1, fromDate: fromDate, forSensor: nil, ignoreRawData: true,
                                                        ignoreCalculatedValue: false).first else { return nil }
        let sensorId = newest.sensor?.id ?? ""
        let mgdl = newest.finalValue
        var reading = OutboundApiReading(
            eventId: "",
            sensorId: sensorId,
            timestamp: newest.timeStamp,
            mgdl: mgdl,
            slopeMgdlPerMinute: newest.hideSlope ? nil : newest.calculatedValueSlope * 60000,
            trendName: OutboundApiTrend.knownName(newest.slopeName),
            isMmol: !UserDefaults.standard.bloodGlucoseUnitIsMgDl,
            test: test
        )
        reading.eventId = test
            ? "test-" + String(Int64((now.timeIntervalSince1970 * 1000).rounded()))
            : OutboundApiReading.makeEventId(sensorId: sensorId, timeMillis: reading.timeMillis, mgdl: reading.roundedMgdl)
        return reading
    }
}

/// Keeps the app running for the few seconds a send needs when a Bluetooth wake has started it.
@MainActor private final class OutboundApiBackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Outbound API send") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let finished = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
}
