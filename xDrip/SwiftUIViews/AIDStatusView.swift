//
//  AIDStatusView.swift
//  xdrip
//
//  Created by Paul Plant on 3/11/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import SwiftUI
import Combine

struct AIDStatusView: View {
    // MARK: - environment objects
    
    /// reference to nightscoutSyncManager
    @EnvironmentObject var nightscoutSyncManager: NightscoutSyncManager
    
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    
    // MARK: - private properties
    
    // enum to hold the different views in the picker
    private enum PickerViews: String, Hashable, Identifiable, CaseIterable {
        case deviceStatus
        case profile
        
        var id: String { rawValue }

        var name: String {
            switch self {
            case .deviceStatus:
                return String(localized: "Device Status")
            case .profile:
                return String(localized: "Profile")
            }
        }
    }
    
    // store a boolean flag. We'll toggle this with the timer to refresh the view
    @State private var refreshView = false
    
    // store the current pickerview index
    @State private var pickerViewSelected: PickerViews = .deviceStatus
    
    // save typing
    /// is true if the user is using mg/dL units (pulled from UserDefaults)
    private let isMgDl: Bool = UserDefaults.standard.bloodGlucoseUnitIsMgDl
    
    /// a common string to show in case a property/value is nil
    private let nilString = "-"
    
    /// used to refresh the view every few seconds in case the device status has been updated in the background
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    
    // MARK: - SwiftUI views
    
    var body: some View {
        let profile = nightscoutSyncManager.profile
        let deviceStatus = nightscoutSyncManager.deviceStatus
        
        NavigationStack {
            VStack {
                // show a nice colourful header to represent the AID system being followed and the status.
                AIDStatusBanner(
                    systemName: deviceStatus.systemName() ?? "Status",
                    detail: deviceStatus.appVersion?.components(separatedBy: "-").first,
                    statusTitle: deviceStatus.deviceStatusTitle(),
                    statusColor: deviceStatus.deviceStatusColor(),
                    backgroundColor: deviceStatus.deviceStatusBannerBackgroundColor()
                ) {
                    Group {
                        if let systemIcon = deviceStatus.systemIcon() {
                            systemIcon.scaledToFit()
                        }
                    }
                } statusIcon: {
                    deviceStatus.deviceStatusIconImage()
                }
                .id(refreshView)
                
                // after the header, show a picker view to allow different list views to be displayed
                Picker("Chose Status or Profile", selection: $pickerViewSelected) {
                    ForEach(PickerViews.allCases, id: \.id) { item in
                        Text(item.name)
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(EdgeInsets(top: 0, leading: 18, bottom: 5, trailing: 18))
                
                if pickerViewSelected == .deviceStatus {
                    // this is the main list view for all AID parameters
                    List {
                        Section(header: Text("System Status")) {
                            // if more than a few seconds difference between the last connection and last loop date, then show the connection separately
                            if deviceStatus.lastLoopDate.timeIntervalSince(deviceStatus.createdAt) > 5 {
                                row(title: String(localized: "Last cycle"), data: "\(deviceStatus.createdAt.formatted(date: .omitted, time: .shortened)) (\(deviceStatus.createdAt.daysAndHoursAgo(appendAgo: true)))")
                            }
                            
                            // show the last loop date only if it exists
                            if deviceStatus.lastLoopDate != .distantPast {
                                row(title: String(localized: "Last loop"), data: "\(deviceStatus.lastLoopDate.formatted(date: .omitted, time: .shortened)) (\(deviceStatus.lastLoopDate.daysAndHoursAgo(appendAgo: true)))")
                                
                                // if not, show the nil string rather than just hiding the row. This gives context.
                            } else {
                                row(title: String(localized: "Last loop"), data: nilString)
                            }
                            
                            // show the active profile if available (AAPS)
                            if let activeProfile = deviceStatus.activeProfile {
                                row(title: String(localized: "Active profile"), data: activeProfile)
                            }
                            
                            // show the override enabled if application (Loop)
                            if let overrideIsActive = deviceStatus.overrideActive, overrideIsActive, let overrideName = deviceStatus.overrideName {
                                if let overrideMaxValue = deviceStatus.overrideMaxValue, let overrideMinValue = deviceStatus.overrideMinValue {
                                    row(title: String(localized: "Override"), data: "\(overrideName) (\(overrideMinValue.mgDlToMmolAndToString(mgDl: isMgDl))-\(overrideMaxValue.mgDlToMmolAndToString(mgDl: isMgDl)))")
                                } else {
                                    row(title: String(localized: "Override"), data: "\(overrideName)")
                                }
                            }
                            
                            if let error = deviceStatus.error {
                                HStack(spacing: 8) {
                                    Text("Error")
                                    Spacer()
                                    Text(error)
                                        .foregroundColor(.red)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                        }
                        
                        Section(header: Text("Uploader")) {
                            if let deviceName = deviceStatus.deviceName() {
                                row(title: String(localized: "Device"), data: deviceName)
                            }
                            
                            HStack {
                                Text("Battery")
                                
                                Spacer()
                                
                                // show if the uploader is charging (AAPS)
                                if let uploaderBatteryChargingImage = deviceStatus.uploaderBatteryChargingImage() {
                                    uploaderBatteryChargingImage.image
                                        .foregroundStyle(uploaderBatteryChargingImage.color)
                                        .imageScale(.small)
                                }
                                
                                if let uploaderBatteryImage = deviceStatus.batteryImage(percent: deviceStatus.uploaderBatteryPercent) {
                                    uploaderBatteryImage.image
                                        .foregroundStyle(uploaderBatteryImage.color)
                                }
                                
                                Text("\(deviceStatus.uploaderBatteryPercent?.description ?? nilString) %")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Section(header: Text("\(deviceStatus.systemName() ?? "AID") Specific")) {
                            row(title: String(localized: "Basal rate"), data: (deviceStatus.rate?.round(toDecimalPlaces: 2).description ?? "-") + " " + Texts_TreatmentsView.basalRateUnit)
                            
                            row(title: String(localized: "Duration"), data: (deviceStatus.duration?.description ?? "-") + " " + Texts_TreatmentsView.exerciseUnit)
                            
                            if let bolusVolume = deviceStatus.bolusVolume {
                                row(title: String(localized: "Auto-bolus given"), data: bolusVolume.round(toDecimalPlaces: 2).description + " " + Texts_TreatmentsView.insulinUnit)
                            }
                            
                            row(title: String(localized: "IOB"), data: (deviceStatus.iob?.round(toDecimalPlaces: 2).stringWithoutTrailingZeroes ?? nilString) + " " + Texts_TreatmentsView.insulinUnit)
                            
                            row(title: String(localized: "COB"), data: (deviceStatus.cob?.round(toDecimalPlaces: 0).stringWithoutTrailingZeroes ?? nilString) + " " + Texts_TreatmentsView.carbsUnit)
                            
                            if let isf = deviceStatus.isf {
                                row(title: String(localized: "ISF"), data: isf.round(toDecimalPlaces: 0).stringWithoutTrailingZeroes)
                            }
                            
                            if let sensitivityRatio = deviceStatus.sensitivityRatio {
                                row(title: String(localized: "Autosens"), data: sensitivityRatio.round(toDecimalPlaces: 1).description)
                            }
                            
                            if let tdd = deviceStatus.tdd {
                                row(title: String(localized: "TDD"), data: tdd.round(toDecimalPlaces: 1).description + " " + Texts_TreatmentsView.insulinUnit)
                            }
                            
                            if let currentTarget = deviceStatus.currentTarget {
                                row(title: String(localized: "Current target"), data: "\(currentTarget.mgDlToMmolAndToString(mgDl: isMgDl)) \(isMgDl ? Texts_Common.mgdl : Texts_Common.mmol)")
                            }
                            
                            if let eventualBG = deviceStatus.eventualBG {
                                row(title: String(localized: "Eventual BG"), data: "\(eventualBG.mgDlToMmolAndToString(mgDl: isMgDl)) \(isMgDl ? Texts_Common.mgdl : Texts_Common.mmol)")
                            }
                            
                            if let insulinReq = deviceStatus.insulinReq {
                                row(title: String(localized: "Required insulin"), data: insulinReq.round(toDecimalPlaces: 2).description + " " + Texts_TreatmentsView.insulinUnit)
                            }
                        }
                        
                        Section(header: Text("Pump")) {
                            // show the pump type if available
                            if let pumpModel = deviceStatus.pumpModel {
                                row(title: String(localized: "Model"), data: "\(deviceStatus.pumpManufacturer ?? "") \(pumpModel)")
                            }
                            
                            if let pumpStatus = deviceStatus.pumpStatus {
                                row(title: String(localized: "Status"), data: pumpStatus.capitalized)
                            }
                            
                            HStack {
                                Text(Texts_HomeView.pumpBattery)
                                
                                Spacer()
                                
                                if let pumpBatteryImage = deviceStatus.batteryImage(percent: deviceStatus.pumpBatteryPercent) {
                                    pumpBatteryImage.image
                                        .foregroundStyle(pumpBatteryImage.color)
                                }
                                
                                Text("\(deviceStatus.pumpBatteryPercent?.description ?? nilString) %")
                                    .foregroundColor(.secondary)
                            }
                            
                            if let pumpReservoir = deviceStatus.pumpReservoir, pumpReservoir == ConstantsNightscout.omniPodReservoirFlagNumber {
                                row(title: Texts_HomeView.pumpReservoir, data: "50+ " + Texts_TreatmentsView.insulinUnit)
                                
                            } else {
                                if let pumpReservoir = deviceStatus.pumpReservoir {
                                    // show one decimal place if available when less than 10 units
                                    row(title: Texts_HomeView.pumpReservoir, data: (pumpReservoir.round(toDecimalPlaces: pumpReservoir < ConstantsHomeView.pumpReservoirUrgent ? 1 : 0).stringWithoutTrailingZeroes) + " " + Texts_TreatmentsView.insulinUnit)
                                } else {
                                    row(title: Texts_HomeView.pumpReservoir, data: nilString + " " + Texts_TreatmentsView.insulinUnit)
                                }
                            }
                            
                            if let baseBasalRate = deviceStatus.baseBasalRate {
                                row(title: String(localized: "Scheduled basal rate"), data: baseBasalRate.round(toDecimalPlaces: 1).description + " " + Texts_TreatmentsView.basalRateUnit)
                            }
                        }
                        
                        if deviceStatus.reason != nil {
                            Section(header: Text("\(deviceStatus.systemName() ?? "AID") response")) {
                                if let reasonValuesArray = deviceStatus.reasonValuesArray() {
                                    ForEach(reasonValuesArray, id: \.self) { reasonValue in
                                        Text(reasonValue.trimmingCharacters(in: .whitespaces))
                                            .foregroundStyle(Color(.colorSecondary))
                                    }
                                    
                                } else {
                                    Text("Nothing enacted or suggested in current Nightscout response at \(deviceStatus.updatedDate.formatted(date: .omitted, time: .shortened))")
                                }
                            }
                        }
                        
                        // Diagnostic timestamps
                        Section(header: Text("Debug")) {
                            row(title: String(localized: "Last Nightscout check"), data: deviceStatus.lastCheckedDate.formatted(date: .omitted, time: .standard))
                            row(title: String(localized: "Last device status update"), data: deviceStatus.updatedDate.formatted(date: .omitted, time: .standard))
                            row(title: String(localized: "Created at"), data: deviceStatus.createdAt.formatted(date: .omitted, time: .standard))
                            row(title: String(localized: "Last loop date"), data: deviceStatus.lastLoopDate.formatted(date: .omitted, time: .standard))
                        }
                        
                    }
                    
                    // using a simple if/else as only two options are to be used at the moment for the pickerview.
                } else {
                    
                    if profile.profileName == nil {
                        Text("No Profile Data Available")
                            .foregroundStyle(Color(.systemRed))
                            .padding()
                    }
                    
                    List {
                        Section(header: Text("Current Profile Information")) {
                            if let profileName = profile.profileName {
                                row(title: String(localized: "Name"), data: profileName)
                            }
                            
                            row(title: String(localized: "Started"), data: profile.startDate != .distantPast ? "\(profile.startDate.daysAndHoursAgo(appendAgo: true))" : nilString)
                            
                            row(title: String(localized: "Stored by"), data: profile.enteredBy ?? nilString)
                            
                            row(title: String(localized: "Timezone"), data: profile.timezone ?? nilString)
                            
                            if let isMgDl = profile.isMgDl {
                                row(title: String(localized: "Units"), data: isMgDl ? Texts_Common.mgdl : Texts_Common.mmol)
                            }
                            
                            if let dia = profile.dia {
                                row(title: String(localized: "DIA"), data: "\(dia.stringWithoutTrailingZeroes) \(Texts_Common.hours)")
                            } else {
                                row(title: String(localized: "DIA"), data: nilString)
                            }
                        }
                        
                        Section(header: Text("Scheduled Basal Rates")) {
                            if let items = profile.basal {
                                ForEach(items, id: \.self) { item in
                                    // conver timeAsSecondsFromMidnight to a real start time to show to the user
                                    let fromHour = Date().toMidnight().addingTimeInterval(TimeInterval(item.timeAsSecondsFromMidnight))
                                    
                                    row(title: fromHour.formatted(date: .omitted, time: .shortened), data: "\(item.value.round(toDecimalPlaces: 2).description) U/hr")
                                }
                            } else {
                                Text("No basal rates in profile")
                            }
                        }
                        
                        Section(header: Text("Scheduled ISF")) {
                            if let items = profile.sensitivity {
                                ForEach(items, id: \.self) { item in
                                    // conver timeAsSecondsFromMidnight to a real start time to show to the user
                                    let fromHour = Date().toMidnight().addingTimeInterval(TimeInterval(item.timeAsSecondsFromMidnight))
                                    
                                    row(title: fromHour.formatted(date: .omitted, time: .shortened), data: "\(item.value.stringWithoutTrailingZeroes) U")
                                }
                            } else {
                                Text("No ISF stored in profile")
                            }
                        }
                        
                        Section(header: Text("Scheduled Carb Ratios")) {
                            if let items = profile.carbratio {
                                ForEach(items, id: \.self) { item in
                                    // conver timeAsSecondsFromMidnight to a real start time to show to the user
                                    let fromHour = Date().toMidnight().addingTimeInterval(TimeInterval(item.timeAsSecondsFromMidnight))
                                    
                                    row(title: fromHour.formatted(date: .omitted, time: .shortened), data: "\(item.value.round(toDecimalPlaces: 1).description) g")
                                }
                            } else {
                                Text("No carb ratios stored in profile")
                            }
                        }
                    }
                }
            }
            .ipadReadableContentWidth(920)
            .background(ConstantsAppColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("Follow Status")
            .toolbarBackground(ConstantsAppColors.groupedBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    SheetCloseButton {
                        self.presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onReceive(timer, perform: { _ in
                refreshView.toggle()
            })
        }
        .colorScheme(.dark)
    }
    
    // MARK: - private functions
    
    /// returns a row view so that all rows are the same
    /// - parameters:
    ///   - title: the title text
    ///   - data: the value text
    /// - returns:
    ///   - a view with the formatted row inside it
    private func row(title: String, data: String) -> AnyView {
        // wrap the HStack in an AnyView so that it can be returned back to the caller
        let rowView = AnyView(HStack {
            Text(title)
                .foregroundStyle(ConstantsAppColors.rowTitleText)
            Spacer()
            Text(data)
                .foregroundStyle(ConstantsAppColors.rowDetailText)
        })
        
        return rowView
    }
}

struct AIDStatusView_Previews: PreviewProvider {
    static var previews: some View {
        AIDStatusView()
    }
}
