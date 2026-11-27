//
//  OutboundApiSettingsView.swift
//  xdrip
//
//  Settings > Sharing and services > Outbound API: Telegram bot and JSON webhook destinations
//  that get each new reading (OutboundApi.swift, docs/outbound-api.md).
//

import SwiftUI

/// The row of Sharing and services that opens the destinations.
struct OutboundApiSettingsProvider: SettingsNativeSectionProvider {
    static var screen: SettingsScreen {
        SettingsScreen(title: OutboundApiTexts.text("title", "Outbound API"),
                       introduction: { OutboundApiTexts.text("introduction", "Sends each new reading to a Telegram bot or to a web address (webhook) of your own, as a message you design. Off until you add a destination.") },
                       providers: { [OutboundApiSettingsProvider()] })
    }

    /// Shown on the Sharing and services row.
    static func summary() -> String? {
        let count = OutboundApiStore.shared.destinations.filter { $0.enabled }.count
        return count == 0 ? nil : String(count)
    }

    func sectionTitle() -> String? { nil }

    func sectionFooter() -> String? {
        OutboundApiTexts.text("footer", "A reading is sent when the app receives it, in the foreground or during a Bluetooth background wake. iOS has no background timer, so nothing is sent while no readings arrive. A failed send is not repeated: the next reading is sent as usual. Bot tokens, web addresses and headers are kept in the Keychain of this iPhone and are not part of backups.")
    }

    func settingsRows(sectionID: Int) -> [SettingsRow] {
        [
            SettingsRow(id: "outboundApi.destinations", title: OutboundApiTexts.text("destinations", "Destinations"), accessory: .none,
                        control: .custom(content: {
                            AnyView(NavigationLink {
                                OutboundApiDestinationsView()
                            } label: {
                                LabeledContent(OutboundApiTexts.text("destinations", "Destinations"),
                                               value: OutboundApiSettingsProvider.summary() ?? Texts_Common.off)
                            })
                        }))
        ]
    }

    private func row(at index: Int) -> SettingsRow? {
        let rows = settingsRows(sectionID: 0)
        return rows.indices.contains(index) ? rows[index] : nil
    }

    func settingsRowText(index: Int) -> String { row(at: index)?.title ?? "" }
    func accessoryType(index: Int) -> SettingsAccessory { .none }
    func detailedText(index: Int) -> String? { nil }
    func numberOfRows() -> Int { settingsRows(sectionID: 0).count }
    func onRowSelect(index: Int) -> SettingsSelectedRowAction { .nothing }
    func isEnabled(index: Int) -> Bool { true }
    func completeSettingsViewRefreshNeeded(index: Int) -> Bool { false }
    func storeMessageHandler(messageHandler: @escaping ((String, String) -> Void)) {}
    func storeRowReloadClosure(rowReloadClosure: @escaping ((Int) -> Void)) {}
}

// MARK: - Destinations

struct OutboundApiDestinationsView: View {
    @State private var destinations = OutboundApiStore.shared.destinations

    var body: some View {
        List {
            Section {
                if destinations.isEmpty {
                    Text(OutboundApiTexts.text("none", "No destination yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(destinations) { destination in
                    NavigationLink {
                        OutboundApiDestinationEditor(destinationId: destination.id)
                    } label: {
                        OutboundApiDestinationRow(destination: destination)
                    }
                }
            }
            Section {
                Button(OutboundApiTexts.text("addTelegram", "Add a Telegram bot")) { add(.telegramBot) }
                Button(OutboundApiTexts.text("addWebhook", "Add a JSON webhook")) { add(.customJSON) }
            }
        }
        .navigationTitle(OutboundApiTexts.text("destinations", "Destinations"))
        .onAppear { destinations = OutboundApiStore.shared.destinations }
    }

    private func add(_ preset: OutboundApiPreset) {
        OutboundApiStore.shared.upsert(OutboundApiDestination.make(preset: preset), secrets: OutboundApiSecrets())
        destinations = OutboundApiStore.shared.destinations
    }
}

private struct OutboundApiDestinationRow: View {
    let destination: OutboundApiDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(destination.resolvedName)
            Text(statusText.text)
                .font(.footnote)
                .foregroundStyle(statusText.color)
        }
    }

    private var statusText: (text: String, color: Color) {
        let store = OutboundApiStore.shared
        if let issue = OutboundApiValidation.issue(for: destination, secrets: store.secrets(id: destination.id)) {
            return (OutboundApiDestinationEditor.text(for: issue), Color.orange)
        }
        if !destination.enabled { return (Texts_Common.off, Color.secondary) }
        let state = store.state(id: destination.id)
        if state.lastError != nil { return (OutboundApiTexts.text("statusFailed", "The last send failed"), Color.red) }
        if let success = state.lastSuccessAt {
            return (String(format: OutboundApiTexts.text("statusSent", "Last sent %@"), success.formatted(date: .abbreviated, time: .shortened)), Color.secondary)
        }
        return (OutboundApiTexts.text("statusWaiting", "Waiting for the next reading"), Color.secondary)
    }
}

// MARK: - One destination

struct OutboundApiDestinationEditor: View {
    let destinationId: String
    @Environment(\.dismiss) private var dismiss
    @State private var destination: OutboundApiDestination
    @State private var secrets: OutboundApiSecrets
    @State private var state: OutboundApiDestinationState
    @State private var testing = false
    @State private var testMessage: String?
    @State private var confirmDelete = false
    @State private var deleted = false

    init(destinationId: String) {
        self.destinationId = destinationId
        let store = OutboundApiStore.shared
        _destination = State(initialValue: store.destination(id: destinationId) ?? OutboundApiDestination.make(preset: .customJSON))
        _secrets = State(initialValue: store.secrets(id: destinationId))
        _state = State(initialValue: store.state(id: destinationId))
    }

    private var isMmol: Bool { !UserDefaults.standard.bloodGlucoseUnitIsMgDl }
    private var issue: OutboundApiConfigIssue? { OutboundApiValidation.issue(for: destination, secrets: secrets) }
    private var isTelegram: Bool { destination.preset == .telegramBot }

    var body: some View {
        Form {
            generalSection
            targetSection
            messageSection
            triggerSection
            if isTelegram {
                telegramSection
            }
            testSection
            statusSection
            deleteSection
        }
        .navigationTitle(destination.resolvedName)
        .onChange(of: destination) { _ in persist() }
        .onChange(of: secrets) { _ in persist() }
        .onDisappear { persist() }
        .confirmationDialog(OutboundApiTexts.text("deleteConfirm", "Delete this destination?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(OutboundApiTexts.text("delete", "Delete destination"), role: .destructive) {
                deleted = true
                OutboundApiStore.shared.remove(id: destinationId)
                dismiss()
            }
        }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section {
            Toggle(OutboundApiTexts.text("enabled", "Send readings"), isOn: $destination.enabled)
            TextField(OutboundApiTexts.text("name", "Name"), text: $destination.name)
        }
    }

    @ViewBuilder private var targetSection: some View {
        if isTelegram {
            Section(footer: Text(OutboundApiTexts.text("telegramFooter", "Create a bot with @BotFather and paste its token. Then write to the bot (or add it to a group or channel) and enter the chat ID: a number, negative for groups and channels, or @channelname. Several chats can be separated by commas."))) {
                SecureField(OutboundApiTexts.text("botToken", "Bot token"), text: $secrets.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(OutboundApiTexts.text("chatId", "Chat ID"), text: $destination.chatId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let issue = issue {
                    Text(Self.text(for: issue)).foregroundStyle(Color.orange).font(.footnote)
                }
            }
        } else {
            Section(footer: Text(OutboundApiTexts.text("webhookFooter", "The reading is sent to this address with POST and a JSON body. Use https: iOS refuses plain http to most servers. One header per line, as Name: value (for example Authorization: Bearer ...). Content-Type is always JSON."))) {
                TextField(OutboundApiTexts.text("webhookURL", "Web address (URL)"), text: $secrets.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(OutboundApiTexts.text("headers", "Headers (optional)"), text: $secrets.headers, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let issue = issue {
                    Text(Self.text(for: issue)).foregroundStyle(Color.orange).font(.footnote)
                }
            }
        }
    }

    private var templateFooter: String {
        let tokens = OutboundApiTemplate.tokenNames.map { "{" + $0 + "}" }.joined(separator: " ")
        let intro = OutboundApiTexts.text("templateFooter", "Placeholders, replaced by the reading:")
        let notes = OutboundApiTexts.text("templateFooter2", "{value} follows your unit; {mgdl} is always mg/dL and {mmol} always mmol/L. {time} is the time of the reading. {message} is only for a body template.")
        return intro + " " + tokens + "\n\n" + notes
    }

    private var messageSection: some View {
        Section(footer: Text(templateFooter)) {
            TextField(destination.preset.defaultTemplate, text: $destination.messageTemplate, axis: .vertical)
                .lineLimit(1...5)
                .autocorrectionDisabled()
            if !isTelegram {
                VStack(alignment: .leading, spacing: 4) {
                    Text(OutboundApiTexts.text("bodyTemplate", "Body template (optional)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField(#"{"bg": {mgdl}, "text": "{message}"}"#, text: $destination.bodyTemplate, axis: .vertical)
                        .lineLimit(2...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(OutboundApiTexts.text("bodyHint", "Empty sends the standard body (schema xdrip.outbound.glucose.v1). A body template is sent as it is, so it must be valid JSON; values are escaped for you, put quotes around text placeholders."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var triggerSection: some View {
        Section(footer: Text(OutboundApiTexts.text("triggerFooter", "The interval is counted between readings, so 5 minutes sends every reading of a sensor that reads every 5 minutes; 0 sends every reading. While Power saving applies, at most one reading per 5 minutes is sent, except when glucose is out of range."))) {
            Picker(OutboundApiTexts.text("trigger", "Send"), selection: $destination.triggerMode) {
                ForEach(OutboundApiTriggerMode.allCases, id: \.self) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            }
            if destination.triggerMode == .atOrBelow || destination.triggerMode == .outsideRange {
                Stepper(value: thresholdBinding(\.triggerLowMgdl), in: isMmol ? 2.0...11.0 : 40.0...200.0, step: isMmol ? 0.5 : 5) {
                    Text(OutboundApiTexts.text("lowAt", "At or below") + " " + thresholdText(destination.triggerLowMgdl))
                }
            }
            if destination.triggerMode == .atOrAbove || destination.triggerMode == .outsideRange {
                Stepper(value: thresholdBinding(\.triggerHighMgdl), in: isMmol ? 5.0...22.0 : 100.0...400.0, step: isMmol ? 0.5 : 5) {
                    Text(OutboundApiTexts.text("highAt", "At or above") + " " + thresholdText(destination.triggerHighMgdl))
                }
            }
            Stepper(value: $destination.minIntervalMinutes, in: 0...180) {
                Text(OutboundApiTexts.text("interval", "At most every") + " " + intervalText)
            }
        }
    }

    private var telegramSection: some View {
        Section(footer: Text(OutboundApiTexts.text("bubbleFooter", "Editing keeps a chat from filling with one message per reading; Telegram does not notify for an edit. The stale and missed notes cannot be sent on time: iOS has no background timer, so while readings are missing nothing can be sent. The note is posted just before the next reading that arrives, saying how long none came."))) {
            Toggle(OutboundApiTexts.text("refreshInPlace", "Edit the last message"), isOn: $destination.refreshInPlaceEnabled)
            if destination.refreshInPlaceEnabled {
                Stepper(value: $destination.refreshWindowMinutes, in: 1...60) {
                    Text(OutboundApiTexts.text("refreshWindow", "For") + " " + OutboundApiDestinationEditor.minutesText(destination.refreshWindowMinutes))
                }
                Toggle(OutboundApiTexts.text("skipUnchanged", "Skip a reading that did not change"), isOn: skipUnchangedBinding)
            }
            Toggle(OutboundApiTexts.text("staleEnabled", "Note a gap in the readings"), isOn: $destination.staleEnabled)
            if destination.staleEnabled {
                Stepper(value: $destination.staleThresholdMinutes, in: 1...120) {
                    Text(OutboundApiTexts.text("staleAfter", "Stale after") + " " + OutboundApiDestinationEditor.minutesText(destination.staleThresholdMinutes))
                }
                Stepper(value: $destination.missedThresholdMinutes, in: (destination.staleThresholdMinutes + 1)...240) {
                    Text(OutboundApiTexts.text("missedAfter", "Missed after") + " " + OutboundApiDestinationEditor.minutesText(destination.missedThresholdMinutes))
                }
            }
        }
    }

    private var testSection: some View {
        Section(footer: Text(testMessage ?? OutboundApiTexts.text("testFooter", "Sends the newest reading now, whatever the trigger and interval say."))) {
            Button {
                runTest()
            } label: {
                HStack {
                    Text(OutboundApiTexts.text("test", "Send a test message"))
                    if testing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(testing || issue != nil)
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent(OutboundApiTexts.text("lastSent", "Last sent"), value: dateText(state.lastSuccessAt))
            LabeledContent(OutboundApiTexts.text("lastAttempt", "Last attempt"), value: dateText(state.lastAttemptAt))
            if state.lastResponseCode != 0 {
                LabeledContent(OutboundApiTexts.text("lastCode", "Last answer"), value: String(state.lastResponseCode))
            }
            if let error = state.lastError, !error.isEmpty {
                Text(error).foregroundStyle(Color.red).font(.footnote)
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(OutboundApiTexts.text("delete", "Delete destination"), role: .destructive) { confirmDelete = true }
        }
    }

    // MARK: Helpers

    private func persist() {
        guard !deleted else { return }
        OutboundApiStore.shared.upsert(destination, secrets: secrets)
    }

    private func runTest() {
        persist()
        testing = true
        testMessage = nil
        Task { @MainActor in
            let outcome = await OutboundApiManager.shared.sendTest(destinationId: destinationId)
            testing = false
            testMessage = Self.text(for: outcome)
            state = OutboundApiStore.shared.state(id: destinationId)
        }
    }

    /// The trigger thresholds are stored in mg/dL and edited in the user's unit.
    private func thresholdBinding(_ keyPath: WritableKeyPath<OutboundApiDestination, Int>) -> Binding<Double> {
        Binding(get: { OutboundApiValidation.displayThreshold(mgdl: destination[keyPath: keyPath], isMmol: isMmol) },
                set: { destination[keyPath: keyPath] = OutboundApiValidation.thresholdMgdl(display: $0, isMmol: isMmol) })
    }

    private var skipUnchangedBinding: Binding<Bool> {
        Binding(get: { destination.suppressDeltaBelowMgdl > 0 },
                set: { destination.suppressDeltaBelowMgdl = $0 ? OutboundApiDefaults.suppressDeltaBelowMgdl : 0 })
    }

    private func thresholdText(_ mgdl: Int) -> String {
        let value = OutboundApiValidation.displayThreshold(mgdl: mgdl, isMmol: isMmol)
        return (isMmol ? String(format: "%.1f", value) : String(Int(value))) + " " + (isMmol ? "mmol/L" : "mg/dL")
    }

    private var intervalText: String {
        destination.minIntervalMinutes == 0
            ? OutboundApiTexts.text("everyReading", "every reading")
            : Self.minutesText(destination.minIntervalMinutes)
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? OutboundApiTexts.text("never", "Never")
    }

    static func minutesText(_ minutes: Int) -> String {
        DateComponentsFormatter.localizedString(from: DateComponents(minute: minutes), unitsStyle: .short) ?? String(minutes)
    }

    static func title(for mode: OutboundApiTriggerMode) -> String {
        switch mode {
        case .always: return OutboundApiTexts.text("triggerAlways", "Every reading")
        case .atOrBelow: return OutboundApiTexts.text("triggerLow", "Only when low")
        case .atOrAbove: return OutboundApiTexts.text("triggerHigh", "Only when high")
        case .outsideRange: return OutboundApiTexts.text("triggerOutside", "Only when low or high")
        }
    }

    static func text(for issue: OutboundApiConfigIssue) -> String {
        switch issue {
        case .missingToken: return OutboundApiTexts.text("issueMissingToken", "Enter the bot token.")
        case .invalidToken: return OutboundApiTexts.text("issueInvalidToken", "The bot token is not valid.")
        case .missingChatId: return OutboundApiTexts.text("issueMissingChatId", "Enter a chat ID.")
        case .invalidChatId: return OutboundApiTexts.text("issueInvalidChatId", "A chat ID is a number or @channelname.")
        case .missingURL: return OutboundApiTexts.text("issueMissingURL", "Enter the web address.")
        case .invalidURL: return OutboundApiTexts.text("issueInvalidURL", "The webhook URL is not valid.")
        }
    }

    static func text(for outcome: OutboundApiTestOutcome) -> String {
        switch outcome {
        case .sent: return OutboundApiTexts.text("testSent", "Test message sent.")
        case .notConfigured(let issue): return text(for: issue)
        case .noReading: return OutboundApiTexts.text("testNoReading", "There is no recent reading yet. Try again when one has arrived.")
        case .failed(let message):
            return message.isEmpty ? OutboundApiTexts.text("testFailed", "The message could not be sent.") : message
        }
    }
}
