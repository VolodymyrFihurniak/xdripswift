//
//  AppShortcuts.swift
//  xdrip
//
//  Created by Guy Shaviv on 31/12/2023.
//  Copyright © 2023 Johan Degraeve. All rights reserved.
//

import AppIntents
import Foundation

struct AppsShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GlucoseIntent(),
            phrases: [
                "What is my glucose in \(.applicationName)",
                "What's my glucose in \(.applicationName)",
                "What is my glucose level in \(.applicationName)",
                "What's my glucose level in \(.applicationName)",
                "What is my \(.applicationName) glucose",
                "What's my \(.applicationName) glucose",
                "What is my \(.applicationName) glucose level",
                "What's my \(.applicationName) glucose level",
          ],
            shortTitle: "Blood Glucose",
            systemImageName: "drop"
        )
        AppShortcut(
            intent: LogCarbsIntent(),
            phrases: ["Log carbs in \(.applicationName)", "Add carbs in \(.applicationName)"],
            shortTitle: "Log carbs",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: LogInsulinIntent(),
            phrases: ["Log insulin in \(.applicationName)", "Add insulin in \(.applicationName)"],
            shortTitle: "Log insulin",
            systemImageName: "syringe"
        )
        AppShortcut(
            intent: EnableSpeakReadingsIntent(),
            phrases: ["Enable Speak Readings in \(.applicationName)"],
            shortTitle: "Enable Speak Readings",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: DisableSpeakReadingsIntent(),
            phrases: ["Disable Speak Readings in \(.applicationName)"],
            shortTitle: "Disable Speak Readings",
            systemImageName: "speaker.slash"
        )
    }
}

/// Sets an explicit state so repeating an exercise automation never reverses its intended effect.
/// Runs without opening the app or requiring unlock, and returns without a dialog so the next
/// Shortcuts action can proceed. The shared preference also updates Settings and Home Screen actions.
struct EnableSpeakReadingsIntent: AppIntent {
    static var title: LocalizedStringResource = "Enable Speak Readings"
    static var description = IntentDescription("Enable automatic speech for subsequent glucose readings using your existing speech settings.", categoryName: "Speech")
    static var openAppWhenRun = false
    static var authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        // Set only the master switch. BGReadingSpeaker still applies the daily schedule and
        // existing speech settings to new readings; this does not announce the current value.
        UserDefaults.standard.speakReadings = true
        return .result()
    }
}

/// The matching background action for ending an automation; repeated calls leave speech disabled.
/// Like the existing Settings toggle, this prevents future announcements rather than cancelling
/// an utterance already in progress. No dialog or foreground presentation interrupts the sequence.
struct DisableSpeakReadingsIntent: AppIntent {
    static var title: LocalizedStringResource = "Disable Speak Readings"
    static var description = IntentDescription("Disable automatic speech for subsequent glucose readings without changing your other speech settings.", categoryName: "Speech")
    static var openAppWhenRun = false
    static var authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.speakReadings = false
        return .result()
    }
}

/// Logs a treatment typed by the person, as the treatment editor does: a new entry, entered by
/// xDrip, marked for the next Nightscout sync. Uses the app's store when the app is running.
enum QuickTreatmentLog {
    static let carbRange = 1.0...300.0
    static let insulinRange = 0.1...50.0

    @MainActor
    static func log(type: TreatmentType, value: Double, date: Date = Date()) async -> Bool {
        let coreDataManager: CoreDataManager
        if let configured = TherapyMetricsManager.shared.configuredCoreDataManager {
            coreDataManager = configured
        } else {
            coreDataManager = await CoreDataManager.create(for: ConstantsCoreData.modelName)
        }
        _ = TreatmentEntry(date: date, value: value, treatmentType: type, nightscoutEventType: nil, enteredBy: nil,
                           nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        guard coreDataManager.saveChanges() else { return false }
        UserDefaults.standard.timeStampLatestNightscoutSyncRequest = .now
        UserDefaults.standard.nightscoutSyncRequired = true
        return true
    }
}

/// Logs carbs now from Siri, Shortcuts or the Action button. Needs an unlocked phone.
struct LogCarbsIntent: AppIntent {
    static var title: LocalizedStringResource = "Log carbs"
    static var description = IntentDescription("Adds a carbs entry now, as the treatment editor does.", categoryName: "Treatments")
    static var openAppWhenRun = false
    static var authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Grams")
    var grams: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$grams) g of carbs")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard QuickTreatmentLog.carbRange.contains(grams) else {
            throw IntentError.message(String(localized: "Carbs must be between 1 and 300 g."))
        }
        guard await QuickTreatmentLog.log(type: .Carbs, value: grams) else {
            throw IntentError.message(String(localized: "The entry could not be saved."))
        }
        let amount = ExperimentalPredictionModel.compact(grams)
        return .result(dialog: "Logged \(amount) g of carbs")
    }
}

/// Logs a bolus now from Siri, Shortcuts or the Action button, with the default bolus insulin.
/// Needs an unlocked phone.
struct LogInsulinIntent: AppIntent {
    static var title: LocalizedStringResource = "Log insulin"
    static var description = IntentDescription("Adds a bolus entry now, as the treatment editor does. It records a dose already given; it does not deliver insulin.", categoryName: "Treatments")
    static var openAppWhenRun = false
    static var authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Units")
    var units: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$units) U of insulin")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard QuickTreatmentLog.insulinRange.contains(units) else {
            throw IntentError.message(String(localized: "Insulin must be between 0.1 and 50 U."))
        }
        guard await QuickTreatmentLog.log(type: .Insulin, value: units) else {
            throw IntentError.message(String(localized: "The entry could not be saved."))
        }
        let amount = ExperimentalPredictionModel.compact(units)
        return .result(dialog: "Logged \(amount) U of insulin")
    }
}
