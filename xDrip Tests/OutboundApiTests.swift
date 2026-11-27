//
//  OutboundApiTests.swift
//  xdripTests
//
//  Outbound API (Telegram bot and JSON webhook): template, trigger, interval, message editing,
//  validation, requests, responses and the dispatcher. Expected values of the pure helpers come
//  from a Python port of the same logic (scratchpad outbound_port.py), not from reading the code.
//

import XCTest
@testable import xdrip

/// Answers with the queued responses (200 and an empty body when none is left) and keeps the requests.
private final class FakeOutboundTransport: OutboundApiTransport {
    var responses: [(Int, String)] = []
    var failure: Error?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (statusCode: Int, body: Data) {
        requests.append(request)
        if let failure = failure { throw failure }
        let next = responses.isEmpty ? (200, "") : responses.removeFirst()
        return (statusCode: next.0, body: Data(next.1.utf8))
    }

    func json(at index: Int) -> [String: Any] {
        guard requests.indices.contains(index), let body = requests[index].httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }
}

@MainActor final class OutboundApiTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let token = "123456:ABC-def_1"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "OutboundApiTests")!
        defaults.removePersistentDomain(forName: "OutboundApiTests")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "OutboundApiTests")
    }

    // MARK: Helpers

    private func reading(mgdl: Double = 123.4, slope: Double? = -1.2345, trend: String = "FortyFiveDown", isMmol: Bool = false,
                         test: Bool = false, at seconds: Double = 1_800_000_000, sensor: String = "S1", eventId: String? = nil) -> OutboundApiReading {
        let timestamp = Date(timeIntervalSince1970: seconds)
        var reading = OutboundApiReading(eventId: "", sensorId: sensor, timestamp: timestamp, mgdl: mgdl, slopeMgdlPerMinute: slope,
                                         trendName: trend, isMmol: isMmol, test: test)
        reading.eventId = eventId ?? OutboundApiReading.makeEventId(sensorId: sensor, timeMillis: reading.timeMillis, mgdl: reading.roundedMgdl)
        return reading
    }

    private func telegramDestination(template: String = "{value} {unit} {trend_arrow}") -> OutboundApiDestination {
        OutboundApiDestination(name: "Family", preset: .telegramBot, chatId: "42", messageTemplate: template)
    }

    private func makeStore() -> (store: OutboundApiStore, secrets: OutboundApiMemorySecretStore) {
        let secrets = OutboundApiMemorySecretStore()
        return (OutboundApiStore(defaults: defaults, secretStore: secrets), secrets)
    }

    private func makeDispatcher(_ transport: FakeOutboundTransport) -> (dispatcher: OutboundApiDispatcher, store: OutboundApiStore) {
        let store = makeStore().store
        return (OutboundApiDispatcher(store: store, transport: transport), store)
    }

    private func deliver(_ dispatcher: OutboundApiDispatcher, _ destination: OutboundApiDestination, _ secrets: OutboundApiSecrets,
                         _ reading: OutboundApiReading, now: Date, previousSeenAt: Date? = nil) async -> OutboundApiDeliveryResult {
        await dispatcher.deliver(destination: destination, secrets: secrets, reading: reading, previousSeenAt: previousSeenAt,
                                 now: now, formatTime: { _ in "T" })
    }

    private let sent77 = #"{"ok":true,"result":{"message_id":77}}"#

    // MARK: Template

    func testRenderReplacesKnownPlaceholdersOnly() {
        let values = ["value": "120", "unit": "mg/dL", "trend_arrow": "\u{2192}", "mgdl": "120"]
        XCTAssertEqual(OutboundApiTemplate.render("{value} {unit} {trend_arrow} {foo} {{mgdl}} {} {va lue}", values: values),
                       "120 mg/dL \u{2192} {foo} {120} {} {va lue}")
    }

    func testRenderDoesNotScanInsertedValuesAgain() {
        XCTAssertEqual(OutboundApiTemplate.render("{a}{b}", values: ["a": "{b}", "b": "X"]), "{b}X")
    }

    func testRenderEscapesValuesForJSON() {
        let message = "He said \"hi\"\n\\ tab\t ctl\u{01} \u{E9}"
        let body = OutboundApiTemplate.render(#"{"text": "{message}", "n": {mgdl}}"#, values: ["message": message, "mgdl": "120"], escapeJSON: true)
        XCTAssertEqual(body, #"{"text": "He said \"hi\"\n\\ tab\t ctl\u0001 é", "n": 120}"#)
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        XCTAssertEqual(object?["text"] as? String, message)
        XCTAssertEqual(object?["n"] as? Int, 120)
    }

    func testNumberHasDotAndNoMinusOnZero() {
        XCTAssertEqual(OutboundApiTemplate.number(-0.04, decimals: 1), "0.0")
        XCTAssertEqual(OutboundApiTemplate.number(-0.06, decimals: 1), "-0.1")
        XCTAssertEqual(OutboundApiTemplate.number(2.5, decimals: 3), "2.500")
        XCTAssertEqual(OutboundApiTemplate.number(180 * ConstantsBloodGlucose.mgDlToMmoll, decimals: 2), "9.99")
        XCTAssertEqual(OutboundApiTemplate.number(180 * ConstantsBloodGlucose.mgDlToMmoll, decimals: 1), "10.0")
        XCTAssertEqual(OutboundApiTemplate.number(Double.nan, decimals: 1), "")
    }

    func testValuesOfAReadingInMmol() {
        let values = OutboundApiTemplate.values(reading: reading(mgdl: 123.4, slope: -1.2345, trend: "FortyFiveDown", isMmol: true),
                                                recipient: "42", lowMgdl: 70, highMgdl: 180,
                                                formatTime: { "T" + String(Int($0.timeIntervalSince1970)) })
        XCTAssertEqual(values["value"], "6.8")
        XCTAssertEqual(values["unit"], "mmol/L")
        XCTAssertEqual(values["mgdl"], "123")
        XCTAssertEqual(values["mmol"], "6.85")
        XCTAssertEqual(values["trend"], "FortyFiveDown")
        XCTAssertEqual(values["trend_arrow"], "\u{2198}")
        XCTAssertEqual(values["rate_mgdl"], "-1.2")
        XCTAssertEqual(values["rate_mmol"], "-0.069")
        XCTAssertEqual(values["status"], "in_range")
        XCTAssertEqual(values["status_emoji"], "\u{1F7E2}")
        XCTAssertEqual(values["time"], "T1800000000")
        XCTAssertEqual(values["timestamp"], "1800000000000")
        XCTAssertEqual(values["sensor"], "S1")
        XCTAssertEqual(values["event_id"], "S1:1800000000000:123")
        XCTAssertEqual(values["recipient"], "42")
        XCTAssertEqual(values["test"], "false")
    }

    func testValuesOfAHighReadingWithoutSlopeOrTrend() {
        let values = OutboundApiTemplate.values(reading: reading(mgdl: 250, slope: nil, trend: "", test: true, at: 1_800_000_060.5, sensor: "", eventId: "e"),
                                                recipient: "", lowMgdl: 70, highMgdl: 180, formatTime: { _ in "T" })
        XCTAssertEqual(values["value"], "250")
        XCTAssertEqual(values["unit"], "mg/dL")
        XCTAssertEqual(values["mmol"], "13.88")
        XCTAssertEqual(values["rate_mgdl"], "")
        XCTAssertEqual(values["rate_mmol"], "")
        XCTAssertEqual(values["trend"], "")
        XCTAssertEqual(values["trend_arrow"], "")
        XCTAssertEqual(values["status"], "high")
        XCTAssertEqual(values["status_emoji"], "\u{1F7E1}")
        XCTAssertEqual(values["timestamp"], "1800000060500")
        XCTAssertEqual(values["test"], "true")
    }

    func testValuesOfALowReading() {
        let values = OutboundApiTemplate.values(reading: reading(mgdl: 65, slope: 0, trend: "Flat"), recipient: "", lowMgdl: 70, highMgdl: 180,
                                                formatTime: { _ in "T" })
        XCTAssertEqual(values["status"], "low")
        XCTAssertEqual(values["status_emoji"], "\u{1F534}")
        XCTAssertEqual(values["mmol"], "3.61")
        XCTAssertEqual(values["rate_mgdl"], "0.0")
        XCTAssertEqual(values["trend_arrow"], "\u{2192}")
    }

    func testTrendArrows() {
        XCTAssertEqual(OutboundApiTrend.arrow(forName: "DoubleUp"), "\u{2191}\u{2191}")
        XCTAssertEqual(OutboundApiTrend.arrow(forName: "DoubleDown"), "\u{2193}\u{2193}")
        XCTAssertEqual(OutboundApiTrend.arrow(forName: "NOT COMPUTABLE"), "")
        XCTAssertEqual(OutboundApiTrend.knownName("SingleUp"), "SingleUp")
        XCTAssertEqual(OutboundApiTrend.knownName("NONE"), "")
    }

    func testReadingRoundsToTheNearestMgdl() {
        XCTAssertEqual(reading(mgdl: 123.4).roundedMgdl, 123)
        XCTAssertEqual(reading(mgdl: 123.5).roundedMgdl, 124)
        XCTAssertEqual(reading(mgdl: Double.nan).roundedMgdl, 0)
        XCTAssertEqual(OutboundApiReading.makeEventId(sensorId: "S1", timeMillis: 5, mgdl: 100), "S1:5:100")
    }

    // MARK: Trigger and interval

    func testTriggerModes() {
        let levels = [0, 69, 70, 71, 100, 179, 180, 181]
        func table(_ mode: OutboundApiTriggerMode) -> [Bool] {
            levels.map { OutboundApiTrigger.shouldSend(mode: mode, lowMgdl: 70, highMgdl: 180, mgdl: $0) }
        }
        XCTAssertEqual(table(.always), [false, true, true, true, true, true, true, true])
        XCTAssertEqual(table(.atOrBelow), [false, true, true, false, false, false, false, false])
        XCTAssertEqual(table(.atOrAbove), [false, false, false, false, false, false, true, true])
        XCTAssertEqual(table(.outsideRange), [false, true, true, false, false, false, true, true])
    }

    func testTriggerThresholdsAreClamped() {
        XCTAssertTrue(OutboundApiTrigger.shouldSend(mode: .atOrBelow, lowMgdl: 0, highMgdl: 180, mgdl: 1))
        XCTAssertFalse(OutboundApiTrigger.shouldSend(mode: .atOrBelow, lowMgdl: 0, highMgdl: 180, mgdl: 2))
        XCTAssertTrue(OutboundApiTrigger.shouldSend(mode: .atOrAbove, lowMgdl: 70, highMgdl: 900, mgdl: 600))
        XCTAssertFalse(OutboundApiTrigger.shouldSend(mode: .atOrAbove, lowMgdl: 70, highMgdl: 900, mgdl: 599))
    }

    func testStatusBelowLowAndAboveHigh() {
        let statuses = [0, 69, 70, 180, 181].map { OutboundApiTrigger.status(lowMgdl: 70, highMgdl: 180, mgdl: $0) }
        XCTAssertEqual(statuses, [.inRange, .low, .inRange, .inRange, .high])
    }

    func testIntervalGateKeepsTenSecondsOfSlack() {
        func check(_ seconds: Double) -> OutboundApiGateResult {
            OutboundApiIntervalGate.check(eventId: "b", lastEventId: "a", readingDate: t0.addingTimeInterval(seconds),
                                          lastQueuedReadingDate: t0, minIntervalMinutes: 5)
        }
        XCTAssertEqual([0.0, 288.0, 289.0].map(check), [.tooSoon, .tooSoon, .tooSoon])
        XCTAssertEqual([290.0, 300.0, 301.0].map(check), [.allowed, .allowed, .allowed])
    }

    func testIntervalGateDuplicatesAndNoInterval() {
        XCTAssertEqual(OutboundApiIntervalGate.check(eventId: "a", lastEventId: "a", readingDate: t0.addingTimeInterval(999),
                                                     lastQueuedReadingDate: t0, minIntervalMinutes: 5), .duplicate)
        XCTAssertEqual(OutboundApiIntervalGate.check(eventId: "b", lastEventId: "a", readingDate: t0, lastQueuedReadingDate: t0,
                                                     minIntervalMinutes: 0), .allowed)
        XCTAssertEqual(OutboundApiIntervalGate.check(eventId: "b", lastEventId: "a", readingDate: t0.addingTimeInterval(-100),
                                                     lastQueuedReadingDate: t0, minIntervalMinutes: 0), .allowed)
        XCTAssertEqual(OutboundApiIntervalGate.check(eventId: "b", lastEventId: "a", readingDate: t0.addingTimeInterval(1),
                                                     lastQueuedReadingDate: nil, minIntervalMinutes: 5), .allowed)
    }

    func testPowerSavingRaisesTheIntervalToFiveMinutes() {
        XCTAssertEqual(OutboundApiIntervalGate.effectiveMinIntervalMinutes(configured: 0, powerSavingThrottle: true), 5)
        XCTAssertEqual(OutboundApiIntervalGate.effectiveMinIntervalMinutes(configured: 10, powerSavingThrottle: true), 10)
        XCTAssertEqual(OutboundApiIntervalGate.effectiveMinIntervalMinutes(configured: 3, powerSavingThrottle: false), 3)
        XCTAssertEqual(OutboundApiIntervalGate.effectiveMinIntervalMinutes(configured: -2, powerSavingThrottle: false), 0)
        XCTAssertEqual(OutboundApiIntervalGate.effectiveMinIntervalMinutes(configured: 5, powerSavingThrottle: true), 5)
        XCTAssertEqual(OutboundApiIntervalGate.effectiveMinIntervalMinutes(configured: 3, powerSavingThrottle: true), 5)
    }

    // MARK: Decision

    private func decide(mode: OutboundApiTriggerMode = .always, interval: Int = 5, mgdl: Double = 120, lastEvent: String = "",
                        lastQueued: Date? = nil, now: Double = 5, throttle: Bool = false) -> OutboundApiDecision {
        var destination = OutboundApiDestination(name: "x", preset: .telegramBot, minIntervalMinutes: interval, triggerMode: mode)
        destination.triggerLowMgdl = 70
        destination.triggerHighMgdl = 180
        var state = OutboundApiDestinationState()
        state.lastQueuedEventId = lastEvent
        state.lastQueuedReadingAt = lastQueued
        return OutboundApiPlanner.decide(destination: destination, state: state, reading: reading(mgdl: mgdl, eventId: "e1"),
                                         now: t0.addingTimeInterval(now), powerSavingThrottle: throttle)
    }

    func testDecisionSendsAFirstRecentReading() {
        XCTAssertEqual(decide(), .send)
    }

    func testDecisionSkipsAnUnusableReadingAndAnOldOne() {
        XCTAssertEqual(decide(mgdl: 0), .skip(.invalidReading))
        XCTAssertEqual(decide(now: 15 * 60), .send)
        XCTAssertEqual(decide(now: 15 * 60 + 1), .skip(.oldReading))
    }

    func testDecisionAppliesTheTriggerBeforeTheInterval() {
        XCTAssertEqual(decide(mode: .outsideRange, mgdl: 120), .skip(.trigger))
        XCTAssertEqual(decide(mode: .outsideRange, mgdl: 60), .send)
    }

    func testDecisionSkipsADuplicateAndAReadingThatIsTooSoon() {
        XCTAssertEqual(decide(lastEvent: "e1", lastQueued: t0.addingTimeInterval(-600)), .skip(.duplicate))
        XCTAssertEqual(decide(lastEvent: "e0", lastQueued: t0.addingTimeInterval(-120)), .skip(.interval))
        XCTAssertEqual(decide(interval: 0, lastEvent: "e0", lastQueued: t0.addingTimeInterval(-60)), .send)
    }

    func testDecisionUnderPowerSavingSendsOneReadingPerFiveMinutes() {
        XCTAssertEqual(decide(interval: 0, lastEvent: "e0", lastQueued: t0.addingTimeInterval(-60), throttle: true), .skip(.interval))
        XCTAssertEqual(decide(interval: 0, lastEvent: "e0", lastQueued: t0.addingTimeInterval(-300), throttle: true), .send)
    }

    // MARK: Editing the last Telegram message

    private func bubble() -> OutboundApiBubble { OutboundApiBubble(messageId: 77, sentAt: t0, mgdl: 120) }

    private func plan(refresh: Bool = true, window: Int = 15, suppress: Int = 1, bubble: OutboundApiBubble?, mgdl: Int, isTest: Bool = false,
                      after seconds: Double) -> OutboundApiBubbleAction {
        OutboundApiBubblePlanner.plan(refreshEnabled: refresh, windowMinutes: window, suppressBelowMgdl: suppress, bubble: bubble,
                                      mgdl: mgdl, isTest: isTest, now: t0.addingTimeInterval(seconds))
    }

    func testPlanSendsWhenThereIsNothingToEdit() {
        XCTAssertEqual(plan(bubble: nil, mgdl: 120, after: 0), .send)
        XCTAssertEqual(plan(bubble: OutboundApiBubble(messageId: 0, sentAt: t0, mgdl: 120), mgdl: 125, after: 60), .send)
        XCTAssertEqual(plan(refresh: false, bubble: bubble(), mgdl: 125, after: 60), .send)
    }

    func testPlanEditsOrSkipsInsideTheWindow() {
        XCTAssertEqual(plan(bubble: bubble(), mgdl: 125, after: 180), .edit(messageId: 77))
        XCTAssertEqual(plan(bubble: bubble(), mgdl: 120, after: 180), .suppress(messageId: 77))
        XCTAssertEqual(plan(bubble: bubble(), mgdl: 120, isTest: true, after: 180), .edit(messageId: 77))
        XCTAssertEqual(plan(suppress: 0, bubble: bubble(), mgdl: 120, after: 60), .edit(messageId: 77))
        XCTAssertEqual(plan(suppress: 5, bubble: bubble(), mgdl: 123, after: 60), .suppress(messageId: 77))
        XCTAssertEqual(plan(suppress: 5, bubble: bubble(), mgdl: 125, after: 60), .edit(messageId: 77))
    }

    func testPlanStartsANewMessageAfterTheWindow() {
        XCTAssertEqual(plan(bubble: bubble(), mgdl: 120, after: 900), .suppress(messageId: 77))
        XCTAssertEqual(plan(bubble: bubble(), mgdl: 120, after: 901), .send)
        XCTAssertEqual(plan(window: 0, bubble: bubble(), mgdl: 125, after: 60), .edit(messageId: 77))
        XCTAssertEqual(plan(window: 0, bubble: bubble(), mgdl: 125, after: 61), .send)
    }

    // MARK: Gap notice

    private func gap(enabled: Bool = true, stale: Int = 10, missed: Int = 15, hasBubble: Bool = true, previous: Date? = nil,
                     after seconds: Double) -> OutboundApiGapKind? {
        OutboundApiBubblePlanner.gapNotice(enabled: enabled, staleMinutes: stale, missedMinutes: missed, hasBubble: hasBubble,
                                           previousSeenAt: previous ?? t0, now: t0.addingTimeInterval(seconds))
    }

    func testGapNoticeStaleThenMissed() {
        XCTAssertNil(gap(after: 599))
        XCTAssertEqual(gap(after: 600), .stale)
        XCTAssertEqual(gap(after: 899), .stale)
        XCTAssertEqual(gap(after: 900), .missed)
        XCTAssertEqual(gap(after: 1200), .missed)
    }

    func testGapNoticeNeedsAnEnabledNoticeAnEarlierMessageAndAPreviousReading() {
        XCTAssertNil(gap(enabled: false, after: 2000))
        XCTAssertNil(gap(hasBubble: false, after: 2000))
        XCTAssertNil(OutboundApiBubblePlanner.gapNotice(enabled: true, staleMinutes: 10, missedMinutes: 15, hasBubble: true,
                                                        previousSeenAt: nil, now: t0.addingTimeInterval(2000)))
    }

    func testGapNoticeKeepsMissedAfterStale() {
        XCTAssertEqual(gap(stale: 10, missed: 5, after: 659), .stale)
        XCTAssertEqual(gap(stale: 10, missed: 5, after: 660), .missed)
        XCTAssertEqual(gap(stale: 10, missed: 5, after: 600), .stale)
        XCTAssertEqual(gap(stale: 0, missed: 0, after: 60), .stale)
        XCTAssertEqual(gap(stale: 0, missed: 0, after: 120), .missed)
    }

    // MARK: Validation

    func testTelegramToken() {
        XCTAssertEqual(OutboundApiValidation.normalizedTelegramToken("  bot123456:ABC-def_1 \n"), "123456:ABC-def_1")
        XCTAssertTrue(OutboundApiValidation.isTelegramToken("123456:ABC-def_1"))
        for bad in ["123456", ":abc", "12a:abc", "123:ab/c", "123:", "123:ab c"] {
            XCTAssertFalse(OutboundApiValidation.isTelegramToken(bad), bad)
        }
    }

    func testTelegramRecipient() {
        for good in ["123456", "-1001234567890", "@mychannel"] {
            XCTAssertTrue(OutboundApiValidation.isTelegramRecipient(good), good)
        }
        for bad in ["@", "abc", "-", "12 3", "@my channel", "--1"] {
            XCTAssertFalse(OutboundApiValidation.isTelegramRecipient(bad), bad)
        }
    }

    func testRecipientsAreSplitOnCommaSemicolonAndNewline() {
        var destination = telegramDestination()
        destination.chatId = "42, -100123;@chan\n  \n7"
        XCTAssertEqual(destination.recipients, ["42", "-100123", "@chan", "7"])
    }

    func testConfigurationIssues() {
        var telegram = telegramDestination()
        XCTAssertNil(OutboundApiValidation.issue(for: telegram, secrets: OutboundApiSecrets(token: token)))
        XCTAssertEqual(OutboundApiValidation.issue(for: telegram, secrets: OutboundApiSecrets()), .missingToken)
        XCTAssertEqual(OutboundApiValidation.issue(for: telegram, secrets: OutboundApiSecrets(token: "abc")), .invalidToken)
        telegram.chatId = ""
        XCTAssertEqual(OutboundApiValidation.issue(for: telegram, secrets: OutboundApiSecrets(token: token)), .missingChatId)
        telegram.chatId = "42, nope"
        XCTAssertEqual(OutboundApiValidation.issue(for: telegram, secrets: OutboundApiSecrets(token: token)), .invalidChatId)

        let webhook = OutboundApiDestination(name: "Hook", preset: .customJSON)
        XCTAssertEqual(OutboundApiValidation.issue(for: webhook, secrets: OutboundApiSecrets()), .missingURL)
        XCTAssertEqual(OutboundApiValidation.issue(for: webhook, secrets: OutboundApiSecrets(url: "example.com/hook")), .invalidURL)
        XCTAssertEqual(OutboundApiValidation.issue(for: webhook, secrets: OutboundApiSecrets(url: "ftp://example.com/hook")), .invalidURL)
        XCTAssertNil(OutboundApiValidation.issue(for: webhook, secrets: OutboundApiSecrets(url: "https://example.com/hook")))
    }

    func testThresholdsAreEditedInTheUsersUnit() {
        XCTAssertEqual(OutboundApiValidation.displayThreshold(mgdl: 70, isMmol: true), 3.9, accuracy: 1e-9)
        XCTAssertEqual(OutboundApiValidation.displayThreshold(mgdl: 180, isMmol: true), 10.0, accuracy: 1e-9)
        XCTAssertEqual(OutboundApiValidation.displayThreshold(mgdl: 70, isMmol: false), 70.0, accuracy: 1e-9)
        XCTAssertEqual(OutboundApiValidation.thresholdMgdl(display: 3.9, isMmol: true), 70)
        XCTAssertEqual(OutboundApiValidation.thresholdMgdl(display: 10.0, isMmol: true), 180)
        XCTAssertEqual(OutboundApiValidation.thresholdMgdl(display: 4.5, isMmol: true), 81)
        XCTAssertEqual(OutboundApiValidation.thresholdMgdl(display: 70.0, isMmol: false), 70)
    }

    // MARK: Requests

    func testHeadersAreParsedLineByLine() {
        let raw = "Authorization: Bearer abc\n  X-Key :  v: 1 \nContent-Type: text/plain\nbad line\n: novalue\nEmpty:\n\nBad Name: x\r\nX-Two: 2"
        XCTAssertEqual(OutboundApiRequestBuilder.parseHeaders(raw).map { $0.name + "=" + $0.value },
                       ["Authorization=Bearer abc", "X-Key=v: 1", "X-Two=2"])
    }

    func testTelegramRequest() {
        let request = OutboundApiRequestBuilder.telegramRequest(method: "sendMessage", token: "bot" + token + " ",
                                                                payload: ["chat_id": "42", "text": "hi"])
        XCTAssertEqual(request?.url?.absoluteString, "https://api.telegram.org/bot123456:ABC-def_1/sendMessage")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        let body = request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(body?["chat_id"] as? String, "42")
        XCTAssertEqual(body?["text"] as? String, "hi")
    }

    func testTelegramRequestNeedsARealTokenAndLimitsTheText() {
        XCTAssertNil(OutboundApiRequestBuilder.telegramRequest(method: "sendMessage", token: "abc", payload: ["text": "x"]))
        let long = String(repeating: "a", count: 5000)
        let request = OutboundApiRequestBuilder.telegramRequest(method: "sendMessage", token: token, payload: ["chat_id": "1", "text": long])
        let body = request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual((body?["text"] as? String)?.count, 4096)
    }

    func testWebhookRequestAppliesHeadersButNotContentType() {
        let request = OutboundApiRequestBuilder.webhookRequest(url: URL(string: "https://example.com/hook")!,
                                                               headers: "Authorization: Bearer abc\nContent-Type: text/plain", body: Data("{}".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }

    func testStandardBody() throws {
        let destination = OutboundApiDestination(name: "Hook", preset: .customJSON)
        let data = OutboundApiRequestBuilder.standardBody(destination: destination, reading: reading(), message: "m", status: .inRange)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "xdrip.outbound.glucose.v1")
        XCTAssertEqual(object["type"] as? String, "glucose")
        XCTAssertEqual(object["destination_id"] as? String, destination.id)
        XCTAssertEqual(object["destination_preset"] as? String, "custom_json")
        XCTAssertEqual(object["event_id"] as? String, "S1:1800000000000:123")
        XCTAssertEqual(object["test"] as? Bool, false)
        XCTAssertEqual(object["app"] as? String, ConstantsHomeView.applicationName)
        XCTAssertEqual(object["sensor_id"] as? String, "S1")
        XCTAssertEqual((object["timestamp"] as? NSNumber)?.int64Value, 1_800_000_000_000)
        XCTAssertEqual(object["glucose_mgdl"] as? Int, 123)
        XCTAssertEqual(try XCTUnwrap(object["glucose_mmol"] as? Double), 6.85, accuracy: 1e-9)
        XCTAssertEqual(object["display_value"] as? String, "123")
        XCTAssertEqual(object["display_unit"] as? String, "mg/dL")
        XCTAssertEqual(object["trend"] as? String, "FortyFiveDown")
        XCTAssertEqual(object["trend_arrow"] as? String, "\u{2198}")
        XCTAssertEqual(object["status"] as? String, "in_range")
        XCTAssertEqual(object["message"] as? String, "m")
        XCTAssertEqual(try XCTUnwrap(object["rate_mgdl_per_min"] as? Double), -1.2345, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(object["rate_mmol_per_min"] as? Double), -0.06851475, accuracy: 1e-9)
    }

    func testStandardBodyWithoutASlopeHasNoRate() throws {
        let destination = OutboundApiDestination(name: "Hook", preset: .customJSON)
        let data = OutboundApiRequestBuilder.standardBody(destination: destination, reading: reading(slope: nil), message: "m", status: .inRange)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["rate_mgdl_per_min"])
        XCTAssertNil(object["rate_mmol_per_min"])
    }

    // MARK: Responses and redaction

    func testTelegramResponses() {
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 200, body: Data(sent77.utf8)),
                       OutboundApiResponse(code: 200, ok: true, retryable: false, error: nil, messageId: 77))
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 200, body: Data(#"{"ok":true}"#.utf8)),
                       OutboundApiResponse(code: 200, ok: true, retryable: false, error: nil, messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 400, body: Data(#"{"ok":false,"error_code":400,"description":"Bad Request: message is not modified"}"#.utf8)),
                       OutboundApiResponse(code: 400, ok: false, retryable: false, error: "Bad Request: message is not modified", messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 429, body: Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 5"}"#.utf8)),
                       OutboundApiResponse(code: 429, ok: false, retryable: true, error: "Too Many Requests: retry after 5", messageId: nil))
    }

    func testTelegramErrorBodyWinsOverAnOkStatus() {
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 200, body: Data(#"{"ok":false,"description":"odd"}"#.utf8)),
                       OutboundApiResponse(code: 200, ok: false, retryable: false, error: "odd", messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 404, body: Data(#"{"ok":false,"error_code":404}"#.utf8)),
                       OutboundApiResponse(code: 404, ok: false, retryable: false, error: "Telegram API error", messageId: nil))
    }

    func testTelegramResponsesThatAreNotJSON() {
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 502, body: Data()),
                       OutboundApiResponse(code: 502, ok: false, retryable: true, error: "HTTP 502", messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 401, body: Data("not json".utf8)),
                       OutboundApiResponse(code: 401, ok: false, retryable: false, error: "not json", messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.telegram(statusCode: 200, body: Data("not json".utf8)),
                       OutboundApiResponse(code: 200, ok: true, retryable: false, error: nil, messageId: nil))
    }

    func testWebhookResponses() {
        XCTAssertEqual(OutboundApiResponseParser.webhook(statusCode: 204, body: Data()),
                       OutboundApiResponse(code: 204, ok: true, retryable: false, error: nil, messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.webhook(statusCode: 500, body: Data("boom".utf8)),
                       OutboundApiResponse(code: 500, ok: false, retryable: true, error: "boom", messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.webhook(statusCode: 404, body: Data()),
                       OutboundApiResponse(code: 404, ok: false, retryable: false, error: "HTTP 404", messageId: nil))
        XCTAssertEqual(OutboundApiResponseParser.webhook(statusCode: 429, body: Data(" slow down ".utf8)),
                       OutboundApiResponse(code: 429, ok: false, retryable: true, error: "slow down", messageId: nil))
    }

    func testRedactionHidesSecretsLongestFirst() {
        XCTAssertEqual(OutboundApiRedactor.redact("Failed 123456:ABC-def_1 at https://example.com/hook?key=SECRET99 ok",
                                                  secrets: ["123456:ABC-def_1", "https://example.com/hook?key=SECRET99", "", "abc"]),
                       "Failed *** at *** ok")
        XCTAssertEqual(OutboundApiRedactor.redact("token 123456:ABC and 123456:ABCDEF", secrets: ["123456:ABC", "123456:ABCDEF"]),
                       "token *** and ***")
    }

    // MARK: Store

    func testSecretsStayOutOfUserDefaults() {
        let (store, secretStore) = makeStore()
        var destination = telegramDestination()
        destination.bodyTemplate = ""
        store.upsert(destination, secrets: OutboundApiSecrets(token: token, url: "https://example.com/hook?key=SECRET99",
                                                              headers: "Authorization: Bearer abc123"))
        let stored = defaults.data(forKey: OutboundApiStore.destinationsKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(stored.isEmpty)
        for secret in ["ABC-def_1", "SECRET99", "abc123"] {
            XCTAssertFalse(stored.contains(secret), secret)
        }
        let again = OutboundApiStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(again.destinations, [destination])
        XCTAssertEqual(again.secrets(id: destination.id).token, token)
        XCTAssertEqual(again.secrets(id: destination.id).headers, "Authorization: Bearer abc123")
    }

    func testOnlyEnabledCompleteDestinationsAreReady() {
        let (store, _) = makeStore()
        let ready = telegramDestination()
        var off = telegramDestination()
        off.enabled = false
        let incomplete = telegramDestination()
        store.upsert(ready, secrets: OutboundApiSecrets(token: token))
        store.upsert(off, secrets: OutboundApiSecrets(token: token))
        store.upsert(incomplete, secrets: OutboundApiSecrets(token: "abc"))
        XCTAssertEqual(store.readyDestinations().map { $0.destination.id }, [ready.id])
    }

    func testRemovingADestinationRemovesItsSecretsAndState() {
        let (store, secretStore) = makeStore()
        let destination = telegramDestination()
        store.upsert(destination, secrets: OutboundApiSecrets(token: token))
        store.updateState(id: destination.id) { $0.lastError = "x" }
        store.remove(id: destination.id)
        XCTAssertTrue(store.destinations.isEmpty)
        XCTAssertTrue(secretStore.load(id: destination.id).isEmpty)
        XCTAssertNil(store.state(id: destination.id).lastError)
    }

    func testStateSurvivesANewStore() {
        let (store, secretStore) = makeStore()
        store.updateState(id: "a") {
            $0.lastSeenAt = t0
            $0.bubbles["42"] = OutboundApiBubble(messageId: 9, sentAt: t0, mgdl: 101)
        }
        let again = OutboundApiStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(again.state(id: "a").lastSeenAt, t0)
        XCTAssertEqual(again.state(id: "a").bubbles["42"], OutboundApiBubble(messageId: 9, sentAt: t0, mgdl: 101))
    }

    func testADestinationSavedWithFewerFieldsGetsDefaults() {
        defaults.set(Data(#"[{"id":"a","preset":"telegram_bot","chatId":"1"}]"#.utf8), forKey: OutboundApiStore.destinationsKey)
        let destination = makeStore().store.destinations.first
        XCTAssertEqual(destination?.id, "a")
        XCTAssertEqual(destination?.preset, .telegramBot)
        XCTAssertEqual(destination?.chatId, "1")
        XCTAssertEqual(destination?.enabled, false)
        XCTAssertEqual(destination?.name, OutboundApiPreset.telegramBot.defaultName)
        XCTAssertEqual(destination?.minIntervalMinutes, 5)
        XCTAssertEqual(destination?.triggerMode, .always)
        XCTAssertEqual(destination?.triggerLowMgdl, 70)
        XCTAssertEqual(destination?.triggerHighMgdl, 180)
        XCTAssertEqual(destination?.refreshWindowMinutes, 15)
        XCTAssertEqual(destination?.suppressDeltaBelowMgdl, 1)
        XCTAssertEqual(destination?.staleThresholdMinutes, 10)
        XCTAssertEqual(destination?.missedThresholdMinutes, 15)
    }

    func testNewDestinationsUseTheDefaultTemplateOfTheirPreset() {
        XCTAssertEqual(OutboundApiDestination.make(preset: .telegramBot).resolvedTemplate, OutboundApiDefaults.chatTemplate)
        XCTAssertEqual(OutboundApiDestination.make(preset: .customJSON).resolvedTemplate, OutboundApiDefaults.webhookTemplate)
        var destination = OutboundApiDestination.make(preset: .telegramBot)
        destination.messageTemplate = "  "
        XCTAssertEqual(destination.resolvedTemplate, OutboundApiDefaults.chatTemplate)
    }

    // MARK: Dispatcher, Telegram

    func testTelegramSendsThenEditsThenSkipsAnUnchangedReading() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = telegramDestination()
        let secrets = OutboundApiSecrets(token: token)

        transport.responses = [(200, sent77)]
        var result = await deliver(dispatcher, destination, secrets, reading(mgdl: 123.4), now: t0)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://api.telegram.org/bot123456:ABC-def_1/sendMessage")
        XCTAssertEqual(transport.json(at: 0)["chat_id"] as? String, "42")
        XCTAssertEqual(transport.json(at: 0)["text"] as? String, "123 mg/dL \u{2198}")
        XCTAssertEqual(store.state(id: destination.id).bubbles["42"], OutboundApiBubble(messageId: 77, sentAt: t0, mgdl: 123))
        XCTAssertEqual(store.state(id: destination.id).lastSuccessAt, t0)

        // a changed value inside the window edits the same message
        let t120 = t0.addingTimeInterval(120)
        transport.responses = [(200, sent77)]
        result = await deliver(dispatcher, destination, secrets, reading(mgdl: 130, at: 1_800_000_120), now: t120)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[1].url?.absoluteString, "https://api.telegram.org/bot123456:ABC-def_1/editMessageText")
        XCTAssertEqual((transport.json(at: 1)["message_id"] as? NSNumber)?.int64Value, 77)
        XCTAssertEqual(transport.json(at: 1)["text"] as? String, "130 mg/dL \u{2198}")
        XCTAssertEqual(store.state(id: destination.id).bubbles["42"], OutboundApiBubble(messageId: 77, sentAt: t120, mgdl: 130))

        // the same value again sends nothing, but the message stays fresh
        let t180 = t0.addingTimeInterval(180)
        result = await deliver(dispatcher, destination, secrets, reading(mgdl: 130, at: 1_800_000_180), now: t180)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.suppressed)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(store.state(id: destination.id).bubbles["42"], OutboundApiBubble(messageId: 77, sentAt: t180, mgdl: 130))
        XCTAssertEqual(store.state(id: destination.id).lastAttemptAt, t120)
    }

    func testTelegramStartsANewMessageWhenTheOldOneCannotBeEdited() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = telegramDestination()
        let secrets = OutboundApiSecrets(token: token)
        transport.responses = [(200, sent77)]
        _ = await deliver(dispatcher, destination, secrets, reading(mgdl: 123.4), now: t0)

        transport.responses = [(400, #"{"ok":false,"error_code":400,"description":"Bad Request: message to edit not found"}"#),
                               (200, #"{"ok":true,"result":{"message_id":78}}"#)]
        let t240 = t0.addingTimeInterval(240)
        let result = await deliver(dispatcher, destination, secrets, reading(mgdl: 140, at: 1_800_000_240), now: t240)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(transport.requests[1].url?.absoluteString.hasSuffix("/editMessageText") == true)
        XCTAssertTrue(transport.requests[2].url?.absoluteString.hasSuffix("/sendMessage") == true)
        XCTAssertEqual(store.state(id: destination.id).bubbles["42"], OutboundApiBubble(messageId: 78, sentAt: t240, mgdl: 140))
    }

    func testTelegramKeepsTheMessageAfterARateLimit() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = telegramDestination()
        let secrets = OutboundApiSecrets(token: token)
        transport.responses = [(200, sent77)]
        _ = await deliver(dispatcher, destination, secrets, reading(mgdl: 123.4), now: t0)

        transport.responses = [(429, #"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 5"}"#)]
        let result = await deliver(dispatcher, destination, secrets, reading(mgdl: 150, at: 1_800_000_300), now: t0.addingTimeInterval(300))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, 429)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(store.state(id: destination.id).bubbles["42"]?.messageId, 77)
        XCTAssertEqual(store.state(id: destination.id).lastError, "Too Many Requests: retry after 5")
        XCTAssertEqual(store.state(id: destination.id).lastResponseCode, 429)
    }

    func testTelegramPostsAGapNoteBeforeTheNextReading() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = telegramDestination()
        let secrets = OutboundApiSecrets(token: token)
        transport.responses = [(200, sent77)]
        _ = await deliver(dispatcher, destination, secrets, reading(mgdl: 123.4), now: t0)

        // twelve minutes without a reading is stale, and the message is still inside its edit window
        transport.responses = [(200, #"{"ok":true,"result":{"message_id":78}}"#), (200, #"{"ok":true,"result":{"message_id":79}}"#)]
        let later = t0.addingTimeInterval(12 * 60)
        let result = await deliver(dispatcher, destination, secrets, reading(mgdl: 130, at: 1_800_000_720), now: later, previousSeenAt: t0)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(transport.requests[1].url?.absoluteString.hasSuffix("/sendMessage") == true)
        XCTAssertTrue((transport.json(at: 1)["text"] as? String)?.hasPrefix(OutboundApiStatus.stale.emoji + " ") == true)
        // the reading after the note is a new message, not an edit of the one above the note
        XCTAssertTrue(transport.requests[2].url?.absoluteString.hasSuffix("/sendMessage") == true)
        XCTAssertEqual(transport.json(at: 2)["text"] as? String, "130 mg/dL \u{2198}")
        XCTAssertEqual(store.state(id: destination.id).bubbles["42"]?.messageId, 79)
    }

    func testATestMessageIsNeverSkippedAndNeverGetsAGapNote() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = telegramDestination()
        let secrets = OutboundApiSecrets(token: token)
        transport.responses = [(200, sent77)]
        _ = await deliver(dispatcher, destination, secrets, reading(mgdl: 123.4), now: t0)

        transport.responses = [(200, sent77)]
        let result = await deliver(dispatcher, destination, secrets, reading(mgdl: 123.4, test: true, eventId: "test-1"),
                                   now: t0.addingTimeInterval(60), previousSeenAt: t0.addingTimeInterval(-3600))
        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.suppressed)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.requests[1].url?.absoluteString.hasSuffix("/editMessageText") == true)
        XCTAssertNotNil(store.state(id: destination.id).bubbles["42"])
    }

    func testTelegramSendsToEveryChatAndReportsTheFirstFailure() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, _) = makeDispatcher(transport)
        var destination = telegramDestination()
        destination.chatId = "1, 2"
        transport.responses = [(200, #"{"ok":true,"result":{"message_id":5}}"#),
                               (403, #"{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}"#)]
        let result = await deliver(dispatcher, destination, OutboundApiSecrets(token: token), reading(), now: t0)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, 403)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.json(at: 0)["chat_id"] as? String, "1")
        XCTAssertEqual(transport.json(at: 1)["chat_id"] as? String, "2")
    }

    func testAConnectionErrorIsRecordedAndKeepsTheMessage() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = telegramDestination()
        transport.failure = URLError(.notConnectedToInternet)
        let result = await deliver(dispatcher, destination, OutboundApiSecrets(token: token), reading(), now: t0)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, -1)
        XCTAssertFalse((store.state(id: destination.id).lastError ?? "").isEmpty)
        XCTAssertNil(store.state(id: destination.id).bubbles["42"])
        XCTAssertNil(store.state(id: destination.id).lastSuccessAt)
    }

    // MARK: Dispatcher, webhook

    func testWebhookPostsTheStandardBodyWithHeaders() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = OutboundApiDestination(name: "Hook", preset: .customJSON, messageTemplate: "{value} {unit}")
        let secrets = OutboundApiSecrets(url: "https://example.com/hook", headers: "Authorization: Bearer abc123\nX-Test: 1")
        transport.responses = [(200, "ok")]
        let result = await deliver(dispatcher, destination, secrets, reading(), now: t0)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/hook")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        let body = transport.json(at: 0)
        XCTAssertEqual(body["schema"] as? String, "xdrip.outbound.glucose.v1")
        XCTAssertEqual(body["message"] as? String, "123 mg/dL")
        XCTAssertEqual(body["glucose_mgdl"] as? Int, 123)
        XCTAssertEqual(body["test"] as? Bool, false)
        XCTAssertEqual(store.state(id: destination.id).lastSuccessAt, t0)
        XCTAssertEqual(store.state(id: destination.id).lastResponseCode, 200)
        XCTAssertNil(store.state(id: destination.id).lastError)
    }

    func testWebhookBodyTemplateEscapesItsValues() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, _) = makeDispatcher(transport)
        var destination = OutboundApiDestination(name: "Hook", preset: .customJSON, messageTemplate: "say \"{value}\"")
        destination.bodyTemplate = #"{"bg": {mgdl}, "text": "{message}", "arrow": "{trend_arrow}"}"#
        let result = await deliver(dispatcher, destination, OutboundApiSecrets(url: "https://example.com/hook"), reading(), now: t0)
        XCTAssertTrue(result.ok)
        let body = transport.json(at: 0)
        XCTAssertEqual(body["bg"] as? Int, 123)
        XCTAssertEqual(body["text"] as? String, "say \"123\"")
        XCTAssertEqual(body["arrow"] as? String, "\u{2198}")
        XCTAssertNil(body["schema"])
    }

    func testWebhookFailureIsRecordedWithoutTheSecrets() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, store) = makeDispatcher(transport)
        let destination = OutboundApiDestination(name: "Hook", preset: .customJSON)
        transport.responses = [(500, "bad https://example.com/hook?key=SECRET99")]
        let result = await deliver(dispatcher, destination, OutboundApiSecrets(url: "https://example.com/hook?key=SECRET99"), reading(), now: t0)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, 500)
        let state = store.state(id: destination.id)
        XCTAssertEqual(state.lastError, "bad ***")
        XCTAssertEqual(state.lastResponseCode, 500)
        XCTAssertEqual(state.lastAttemptAt, t0)
        XCTAssertNil(state.lastSuccessAt)
    }

    func testWebhookWithoutAValidURLSendsNothing() async {
        let transport = FakeOutboundTransport()
        let (dispatcher, _) = makeDispatcher(transport)
        let destination = OutboundApiDestination(name: "Hook", preset: .customJSON)
        let result = await deliver(dispatcher, destination, OutboundApiSecrets(url: ""), reading(), now: t0)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
