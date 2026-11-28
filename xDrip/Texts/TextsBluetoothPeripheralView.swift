import Foundation

class Texts_BluetoothPeripheralView {
    
    static private let filename = "BluetoothPeripheralView"

    static let sibionics1SensitivityTitle = NSLocalizedString("sibionics1.sensitivityTitle", tableName: filename, bundle: .main, value: "Factory sensitivity", comment: "Sibionics 1 factory sensitivity row")
    static let sibionics1LabelScannerTitle = NSLocalizedString("sibionics1.labelScannerTitle", tableName: filename, bundle: .main, value: "Scan sensor label", comment: "Title of the Sibionics 1 label scanner")
    static let sibionics1LabelScannerGuidance = NSLocalizedString("sibionics1.labelScannerGuidance", tableName: filename, bundle: .main, value: "Point the camera at the code on the sensor package", comment: "Guidance shown while scanning a Sibionics 1 label")
    static let sibionics1LabelIsSibionics2 = NSLocalizedString("sibionics1.labelIsSibionics2", tableName: filename, bundle: .main, value: "This is a Sibionics 2 label. Add the sensor as Sibionics 2.", comment: "A Sibionics 2 label was scanned for a Sibionics 1 sensor")
    static let sibionics2LabelScanTitle = NSLocalizedString("sibionics2.labelScanTitle", tableName: filename, bundle: .main, value: "Scan sensor label", comment: "Optional scan of the Sibionics 2 label instead of typing the probe code")
    static let sibionics2LabelIsSibionics1 = NSLocalizedString("sibionics2.labelIsSibionics1", tableName: filename, bundle: .main, value: "This is a Sibionics 1 label. Add the sensor as Sibionics 1.", comment: "A Sibionics 1 label was scanned for a Sibionics 2 sensor")
    static let sibionics2LabelHasNoFactoryCode = NSLocalizedString("sibionics2.labelHasNoFactoryCode", tableName: filename, bundle: .main, value: "This label carries no factory code. The sensor name is used instead.", comment: "A Sibionics 2 label without a decodable factory code was scanned")
    static let sibionics1LabelRemove = NSLocalizedString("sibionics1.labelRemove", tableName: filename, bundle: .main, value: "Remove scanned label code", comment: "Removes the short code read from a Sibionics 1 label")
    static let sibionics1SensitivityFallback = NSLocalizedString("sibionics1.sensitivityFallback", tableName: filename, bundle: .main, value: "sensor type default", comment: "Sibionics 1 sensitivity comes from JugglucoNG's fallback code for the sensor type")
    static let sibionics1DiscoveryTitle = NSLocalizedString("sibionics1.discoveryTitle", tableName: filename, bundle: .main, value: "Nearby Sibionics 1 sensors", comment: "Sibionics 1 sensor settings")
    static let sibionics1DiscoveryEmpty = NSLocalizedString("sibionics1.discoveryEmpty", tableName: filename, bundle: .main, value: "Searching for Sibionics 1 sensors…", comment: "Sibionics 1 sensor settings")
    static let sibionics1SettingsTitle = NSLocalizedString("sibionics1.settingsTitle", tableName: filename, bundle: .main, value: "Sibionics 1 settings", comment: "Sibionics 1 sensor settings")
    static let sibionics1SettingsFooter = NSLocalizedString("sibionics1.settingsFooter", tableName: filename, bundle: .main, value: "The sensor protocol is detected automatically. Factory sensitivity comes from the scanned sensor label, the sensor name or, when neither carries it, the default for the sensor type. Calibration adjusts readings using fingersticks. You can reset the sensor manually.", comment: "Sibionics 1 sensor settings")

    static let sibionics2DiscoveryTitle = NSLocalizedString("sibionics2.discoveryTitle", tableName: filename, bundle: .main, value: "Nearby Sibionics 2 sensors", comment: "Heading for nearby Sibionics 2 scan results")
    static let sibionics2DiscoveryFooter = NSLocalizedString("sibionics2.discoveryFooter", tableName: filename, bundle: .main, value: "Keep this screen open and select your sensor when it appears.", comment: "Instructions for selecting a discovered Sibionics 2 sensor")
    static let sibionics2DiscoveryEmpty = NSLocalizedString("sibionics2.discoveryEmpty", tableName: filename, bundle: .main, value: "Searching for Sibionics 2 sensors…", comment: "Shown while no Sibionics 2 devices have appeared yet")
    static let sibionics2DiscoveryNoMatches = NSLocalizedString("sibionics2.discoveryNoMatches", tableName: filename, bundle: .main, value: "No matching sensors", comment: "Shown when a search filters all Sibionics 2 scan results")
    static let sibionics2DiscoverySearch = NSLocalizedString("sibionics2.discoverySearch", tableName: filename, bundle: .main, value: "Search sensors", comment: "Search prompt for Sibionics 2 scan results")
    static let sibionics2ConnectionTitle = NSLocalizedString("sibionics2.connectionTitle", tableName: filename, bundle: .main, value: "Sensor connection", comment: "Section heading for Sibionics 2 connection settings")
    static let sibionicsGS3Title = NSLocalizedString("sibionics.gs3Title", tableName: filename, bundle: .main, value: "GS3 sensor", comment: "Sibionics 1 device screen: the sensor is a Sibionics GS3")
    static let sibionicsGlucoseModelTitle = NSLocalizedString("sibionics.glucoseModelTitle", tableName: filename, bundle: .main, value: "Glucose model", comment: "Selector of the algorithm that turns the Sibionics signal into glucose")
    static let sibionicsGlucoseModelStock = NSLocalizedString("sibionics.glucoseModelStock", tableName: filename, bundle: .main, value: "Stock (default)", comment: "The manufacturer's Sibionics algorithm")
    static let sibionicsGlucoseModelAdaptiveV1 = NSLocalizedString("sibionics.glucoseModelAdaptiveV1", tableName: filename, bundle: .main, value: "Adaptive V1 (experimental)", comment: "JugglucoNG's Adaptive V1 Sibionics glucose model")
    static let sibionicsGlucoseModelBalanced = NSLocalizedString("sibionics.glucoseModelBalanced", tableName: filename, bundle: .main, value: "Balanced (experimental)", comment: "JugglucoNG's Balanced Sibionics glucose model")
    static let sibionicsGlucoseModelResponsive = NSLocalizedString("sibionics.glucoseModelResponsive", tableName: filename, bundle: .main, value: "Responsive (experimental)", comment: "JugglucoNG's Responsive Sibionics glucose model")
    static let sibionicsGlucoseModelAdaptiveV2 = NSLocalizedString("sibionics.glucoseModelAdaptiveV2", tableName: filename, bundle: .main, value: "Adaptive V2 (experimental)", comment: "JugglucoNG's Adaptive V2 glucose model")
    static let sibionicsGlucoseModelFooter = NSLocalizedString("sibionics.glucoseModelFooter", tableName: filename, bundle: .main, value: "Stock is the manufacturer's algorithm. Balanced (from JugglucoNG) smooths the stock value's small 0.1 mmol/L steps and follows it at once on a real change, a turn or a low. Responsive (from JugglucoNG) tracks glucose and its speed and leans a little ahead of a trend, never far from the stock value. Adaptive V1 (from JugglucoNG) follows the sensor's chemical signal with two motion models and returns to the stock value whenever the evidence weakens; it shows the stock value for the first two hours. Adaptive V2 is an experimental estimator from JugglucoNG: it works from the sensor's calibrated signal before the manufacturer's display filtering, follows changes sooner and is less smooth. A minute it cannot estimate shows the stock value. Changing the model recalculates the sensor's history. Compare with a meter before relying on it.", comment: "Explains the Sibionics glucose models")
    static let sibionicsManualSensitivityTitle = NSLocalizedString("sibionics.manualSensitivityTitle", tableName: filename, bundle: .main, value: "Manual sensitivity", comment: "Sibionics factory sensitivity entered by hand")
    static let sibionicsManualSensitivityOff = NSLocalizedString("sibionics.manualSensitivityOff", tableName: filename, bundle: .main, value: "Off", comment: "No manual Sibionics sensitivity")
    static let sibionicsManualSensitivityMessage = NSLocalizedString("sibionics.manualSensitivityMessage", tableName: filename, bundle: .main, value: "A value from 0.8 to 2.5 overrides the probe code, label and sensor name, and history is recalculated with it. Leave empty to use the codes again.", comment: "Explains the manual Sibionics sensitivity")
    static let sibionicsReadingAgeTitle = NSLocalizedString("sibionics.readingAgeTitle", tableName: filename, bundle: .main, value: "Last reading", comment: "Age of the latest Sibionics sensor sample")
    static let sibionicsReadingAgeWaiting = NSLocalizedString("sibionics.readingAgeWaiting", tableName: filename, bundle: .main, value: "Waiting for reading", comment: "Shown before a Sibionics sensor sample is stored")
    static let sibionicsReadingAgeSecondsFormat = NSLocalizedString("sibionics.readingAgeSecondsFormat", tableName: filename, bundle: .main, value: "%d sec ago", comment: "Elapsed seconds since the last Sibionics sample")
    static let sibionicsReadingAgeMinutesFormat = NSLocalizedString("sibionics.readingAgeMinutesFormat", tableName: filename, bundle: .main, value: "%d min ago", comment: "Elapsed whole minutes since the last Sibionics sample")
    static let sibionics1SensorLifeTitle = NSLocalizedString("sibionics1.sensorLifeTitle", tableName: filename, bundle: .main, value: "Sensor life", comment: "Sibionics 1 sensor lifetime row")
    static let sibionicsGS3SensorLifeDetail = NSLocalizedString("sibionics.gs3SensorLifeDetail", tableName: filename, bundle: .main, value: "14 days, extended automatically to 15 d 12 h", comment: "Sibionics GS3 official lifetime and the JugglucoNG extension")
    static let sibionics1SensorLifeDetail = NSLocalizedString("sibionics1.sensorLifeDetail", tableName: filename, bundle: .main, value: "14 days, extended automatically to 23 d 19 h", comment: "Sibionics 1 official lifetime and the automatic JugglucoNG extension")
    static let sibionics2BluetoothAddressTitle = NSLocalizedString("sibionics2.bluetoothAddressTitle", tableName: filename, bundle: .main, value: "Bluetooth address", comment: "Optional BLE MAC address carried in the Sibionics authentication command")
    static let sibionics2BluetoothAddressFooter = NSLocalizedString("sibionics2.bluetoothAddressFooter", tableName: filename, bundle: .main, value: "If the sensor acknowledges the connection but sends no readings, enter its Bluetooth MAC address from a trusted Android device log. iOS does not expose this address. Leave blank for the automatic fallback.", comment: "Why and where to enter an optional Sibionics BLE address")
    static let sibionics2BluetoothAddressAutomatic = NSLocalizedString("sibionics2.bluetoothAddressAutomatic", tableName: filename, bundle: .main, value: "not detected; enter manually", comment: "Private Bluetooth address selectors did not provide a MAC")
    static let sibionics2BluetoothAddressInvalid = NSLocalizedString("sibionics2.bluetoothAddressInvalid", tableName: filename, bundle: .main, value: "Enter six hexadecimal pairs separated by colons.", comment: "Validation message for a Sibionics BLE address")
    static let sibionics2DetectedBluetoothAddress = NSLocalizedString("sibionics2.bluetoothAddressDetected", tableName: filename, bundle: .main, value: "detected automatically", comment: "Indicates the Sibionics MAC was detected from the sensor and confirmed by readings")
    static let sibionics2ProbeCodeTitle = NSLocalizedString("sibionics2.probeCodeTitle", tableName: filename, bundle: .main, value: "Sensor QR code", comment: "Input for the full Sibionics probe code used to decode factory sensitivity")
    static let sibionics2SettingsTitle = NSLocalizedString("sibionics2.settingsTitle", tableName: filename, bundle: .main, value: "Sibionics 2 settings", comment: "Section heading for Sibionics 2 sensor-specific settings")
    static let sibionics2SettingsFooter = NSLocalizedString("sibionics2.settingsFooter", tableName: filename, bundle: .main, value: "The QR code supplies factory sensitivity. Calibration adjusts readings using fingersticks. Automatic reset can begin four hours before day 22 when glucose is stable; a safety reset is forced four hours before day 23 even if automatic reset is off. You can also reset manually.", comment: "Summary of Sibionics 2 calibration and reset controls")
    static let sibionics2ProbeCodeFooter = NSLocalizedString("sibionics2.probeCodeFooter", tableName: filename, bundle: .main, value: "Enter the 14-character probe code from the sensor QR label. The stock JugglucoNG algorithm decodes its factory sensitivity automatically. Leave empty to use the sensor advertisement fallback.", comment: "Instructions for providing a full Sibionics QR probe code")
    static let sibionics2ProbeCodeAutomatic = NSLocalizedString("sibionics2.probeCodeAutomatic", tableName: filename, bundle: .main, value: "automatic from Bluetooth name", comment: "No full Sibionics probe QR code was supplied")
    static let sibionics2ProbeCodeInvalid = NSLocalizedString("sibionics2.probeCodeInvalid", tableName: filename, bundle: .main, value: "Enter a valid 14-character sensor probe code.", comment: "Validation message for an invalid Sibionics sensor probe code")
    static let sibionicsDeviceInfoTitle = NSLocalizedString("sibionics.deviceInfoTitle", tableName: filename, bundle: .main, value: "Sensor information", comment: "Sibionics device screen, sensor information")
    static let sibionicsDeviceInfoFooter = NSLocalizedString("sibionics.deviceInfoFooter", tableName: filename, bundle: .main, value: "Reported by the sensor over Bluetooth. The battery level (Sibionics 2 only) is read at each connection and every six hours.", comment: "Sibionics device screen, sensor information")
    static let sibionicsBattery = NSLocalizedString("sibionics.battery", tableName: filename, bundle: .main, value: "Sensor battery", comment: "Sibionics device screen, sensor information")
    static let sibionicsLastLinkProblem = NSLocalizedString("sibionics.lastLinkProblem", tableName: filename, bundle: .main, value: "Last link problem", comment: "Sibionics device screen, link status")
    static let sibionicsNoLinkProblem = NSLocalizedString("sibionics.noLinkProblem", tableName: filename, bundle: .main, value: "None since the last reading", comment: "Sibionics device screen, link status")
    static let sibionicsProblemLinkLost = NSLocalizedString("sibionics.problemLinkLost", tableName: filename, bundle: .main, value: "Link lost", comment: "Sibionics device screen, link status")
    static let sibionicsProblemNoReadings = NSLocalizedString("sibionics.problemNoReadings", tableName: filename, bundle: .main, value: "No readings while connected", comment: "Sibionics device screen, link status")
    static let sibionicsProblemNotResponding = NSLocalizedString("sibionics.problemNotResponding", tableName: filename, bundle: .main, value: "Sensor not responding", comment: "Sibionics device screen, link status")
    static let sibionicsProblemAddressRefused = NSLocalizedString("sibionics.problemAddressRefused", tableName: filename, bundle: .main, value: "Sensor refused every address", comment: "Sibionics device screen, link status")
    static let sibionicsProblemAuthentication = NSLocalizedString("sibionics.problemAuthentication", tableName: filename, bundle: .main, value: "Authentication failed", comment: "Sibionics device screen, link status")
    static let sibionicsNotReported = NSLocalizedString("sibionics.notReported", tableName: filename, bundle: .main, value: "Not reported yet", comment: "Sibionics device screen, sensor information")
    static let sibionicsSkinTemperature = NSLocalizedString("sibionics.skinTemperature", tableName: filename, bundle: .main, value: "Skin temperature", comment: "Sibionics device screen, the temperature the sensor last reported")
    static let sibionicsModel = NSLocalizedString("sibionics.model", tableName: filename, bundle: .main, value: "Model", comment: "Sibionics device screen, sensor information")
    static let sibionicsFirmware = NSLocalizedString("sibionics.firmware", tableName: filename, bundle: .main, value: "Firmware", comment: "Sibionics device screen, sensor information")
    static let sibionicsHardware = NSLocalizedString("sibionics.hardware", tableName: filename, bundle: .main, value: "Hardware", comment: "Sibionics device screen, sensor information")
    static let sibionicsSoftware = NSLocalizedString("sibionics.software", tableName: filename, bundle: .main, value: "Software", comment: "Sibionics device screen, sensor information")
    static let sibionicsManufacturer = NSLocalizedString("sibionics.manufacturer", tableName: filename, bundle: .main, value: "Manufacturer", comment: "Sibionics device screen, sensor information")
    static let sibionicsProtocol = NSLocalizedString("sibionics.protocol", tableName: filename, bundle: .main, value: "Protocol", comment: "Sibionics device screen, sensor information")
    static let sibionicsProtocolV120 = NSLocalizedString("sibionics.protocolV120", tableName: filename, bundle: .main, value: "V120 (encrypted)", comment: "Sibionics device screen, sensor information")
    static let sibionicsProtocolChinese = NSLocalizedString("sibionics.protocolChinese", tableName: filename, bundle: .main, value: "AA55 (Chinese)", comment: "Sibionics device screen, sensor information")
    static let sibionicsKeyGroup = NSLocalizedString("sibionics.keyGroup", tableName: filename, bundle: .main, value: "Key group", comment: "Sibionics device screen, sensor information")
    static let sibionicsLogTitle = NSLocalizedString("sibionics.logTitle", tableName: filename, bundle: .main, value: "Connection log", comment: "Sibionics device screen, connection log")
    static let sibionicsLogFooter = NSLocalizedString("sibionics.logFooter", tableName: filename, bundle: .main, value: "The latest events on the sensor link, newest first; up to 200 are kept. Copy the log to send it with a problem report.", comment: "Sibionics device screen, connection log")
    static let sibionicsLogCopy = NSLocalizedString("sibionics.logCopy", tableName: filename, bundle: .main, value: "Copy log", comment: "Sibionics device screen, connection log")
    static let sibionicsLogCopied = NSLocalizedString("sibionics.logCopied", tableName: filename, bundle: .main, value: "Copied", comment: "Sibionics device screen, connection log")
    static let sibionicsLogEmpty = NSLocalizedString("sibionics.logEmpty", tableName: filename, bundle: .main, value: "No events yet", comment: "Sibionics device screen, connection log")
    static let sibionics2CalibrationTitle = NSLocalizedString("sibionics2.calibrationTitle", tableName: filename, bundle: .main, value: "Calibration method", comment: "Calibration algorithm selector for Sibionics 2")
    static let sibionics2CalibrationFooter = NSLocalizedString("sibionics2.calibrationFooter", tableName: filename, bundle: .main, value: "All methods work on top of the stock Sibionics correction. xDrip+ uses xDrip's weighted calibration. Weighted regression is the default.", comment: "Explains the Sibionics calibration methods")
    static let sibionics2CalibrationXDripPlus = NSLocalizedString("sibionics2.calibrationXdripPlus", tableName: filename, bundle: .main, value: "xDrip+", comment: "xDrip calibration strategy")
    static let sibionics2CalibrationJugglucoNG = NSLocalizedString("sibionics2.calibrationJugglucoNG", tableName: filename, bundle: .main, value: "Weighted regression (default)", comment: "JugglucoNG sane weighted OLS calibration, its default")
    static let sibionics2CalibrationJugglucoMedianSlope = NSLocalizedString("sibionics2.calibrationJugglucoMedianSlope", tableName: filename, bundle: .main, value: "Median slope", comment: "JugglucoNG Theil-Sen median slope calibration")
    static let sibionics2CalibrationJugglucoRobust = NSLocalizedString("sibionics2.calibrationJugglucoRobust", tableName: filename, bundle: .main, value: "Robust regression", comment: "JugglucoNG time-weighted robust regression calibration")
    static let sibionics2CalibrationJugglucoElastic = NSLocalizedString("sibionics2.calibrationJugglucoElastic", tableName: filename, bundle: .main, value: "Elastic interpolation", comment: "JugglucoNG elastic time-weighted interpolation calibration")
    static let sibionics2CalibrationJugglucoEnsemble = NSLocalizedString("sibionics2.calibrationJugglucoEnsemble", tableName: filename, bundle: .main, value: "Adaptive ensemble", comment: "JugglucoNG adaptive ensemble calibration")
    static let sibionics2CalibrationWeightingTitle = NSLocalizedString("sibionics2.calibrationWeightingTitle", tableName: filename, bundle: .main, value: "Calibration weighting", comment: "JugglucoNG calibration weight profile setting")
    static let sibionics2CalibrationWeightingFooter = NSLocalizedString("sibionics2.calibrationWeightingFooter", tableName: filename, bundle: .main, value: "How quickly older fingersticks lose influence. Fresh follows the latest fingersticks (default); Stable keeps older ones longer.", comment: "Explains the JugglucoNG calibration weight profile")
    static let sibionics2CalibrationWeightingFresh = NSLocalizedString("sibionics2.calibrationWeightingFresh", tableName: filename, bundle: .main, value: "Fresh", comment: "JugglucoNG calibration weight profile")
    static let sibionics2CalibrationWeightingBalanced = NSLocalizedString("sibionics2.calibrationWeightingBalanced", tableName: filename, bundle: .main, value: "Balanced", comment: "JugglucoNG calibration weight profile")
    static let sibionics2CalibrationWeightingStable = NSLocalizedString("sibionics2.calibrationWeightingStable", tableName: filename, bundle: .main, value: "Stable", comment: "JugglucoNG calibration weight profile")
    static let sibionics2AutoResetTitle = NSLocalizedString("sibionics2.autoResetTitle", tableName: filename, bundle: .main, value: "Automatic sensor reset", comment: "Toggle automatic reset for Sibionics 2")
    static let sibionics2ResetTitle = NSLocalizedString("sibionics2.resetTitle", tableName: filename, bundle: .main, value: "Reset sensor", comment: "Manual Sibionics reset action")
    static let sibionics2ResetReminderTitle = NSLocalizedString("sibionics2.resetReminderTitle", tableName: filename, bundle: .main, value: "Sibionics 2 reset coming up", comment: "Title of the Sibionics 2 reset reminder notification")
    static let sibionics2ResetReminderText = NSLocalizedString("sibionics2.resetReminderText", tableName: filename, bundle: .main, value: "The sensor reaches its reset point in about %d hours. Reset it in time to keep it running.", comment: "Body of the Sibionics 2 reset reminder notification, %d = hours")
    static let sibionics2ResetReminderPostpone = NSLocalizedString("sibionics2.resetReminderPostpone", tableName: filename, bundle: .main, value: "Postpone 2 hours", comment: "Action of the Sibionics 2 reset reminder notification")
    static let sibionics2ResetConfirmTitle = NSLocalizedString("sibionics2.resetConfirmTitle", tableName: filename, bundle: .main, value: "Reset sensor?", comment: "Confirmation title before resetting a Sibionics sensor")
    static let sibionics2ResetConfirmMessage = NSLocalizedString("sibionics2.resetConfirmMessage", tableName: filename, bundle: .main, value: "This sends a reset command to the sensor. Continue only if you intend to start a new sensor session.", comment: "Confirmation message before resetting Sibionics 2")
    static let bluetoothAccessNotEnabled = NSLocalizedString("bluetoothAccessNotEnabled", tableName: filename, bundle: .main, value: "Bluetooth access is not enabled", comment: "Status banner when Bluetooth permission is denied or restricted")
    static let bluetoothAccessInstructions = NSLocalizedString("bluetoothAccessInstructions", tableName: filename, bundle: .main, value: "To connect, open Settings → Privacy & Security → Bluetooth and allow access for %@.", comment: "Bluetooth permission instructions. %@ is the installed app name")
    static let bluetoothAccessRestrictedInstructions = NSLocalizedString("bluetoothAccessRestrictedInstructions", tableName: filename, bundle: .main, value: "Device restrictions prevent Bluetooth access. Check Screen Time or contact your device administrator to enable access.", comment: "Instructions when device restrictions block Bluetooth permission")

    static let signalStrengthDisconnected = NSLocalizedString("signalStrengthDisconnected", tableName: filename, bundle: .main, value: "Disconnected", comment: "Signal value replacement while an always-on device is disconnected")
    static let signalStrength = NSLocalizedString("signalStrength", tableName: filename, bundle: .main, value: "Signal Strength", comment: "Bluetooth signal strength row")
    static let signalStrengthLastMeasurement = NSLocalizedString("signalStrengthLastMeasurement", tableName: filename, bundle: .main, value: "Last measurement", comment: "Elapsed time since RSSI measurement for intermittent devices")
    static let signalStrengthWeak = NSLocalizedString("signalStrengthWeak", tableName: filename, bundle: .main, value: "Weak", comment: "Weak reception end of RSSI gauge")
    static let signalStrengthStrong = NSLocalizedString("signalStrengthStrong", tableName: filename, bundle: .main, value: "Strong", comment: "Strong reception end of RSSI gauge")
    static let signalStrengthChartExplanation = NSLocalizedString("signalStrengthChartExplanation", tableName: filename, bundle: .main, value: "Live signal over the last two minutes. New measurements arrive about every second while connected.", comment: "Live RSSI chart timing and gaps")
    
    static let address: String = {
        return NSLocalizedString("address", tableName: filename, bundle: Bundle.main, value: "Address:", comment: "when M5Stack is shown, title of the cell with the address")
    }()

    static let status: String = {
        return NSLocalizedString("status", tableName: filename, bundle: Bundle.main, value: "Status:", comment: "when Bluetooth Peripheral is shown, title of the cell with the status")
    }()

    static let runningInCoexistenceMode: String = {
        return NSLocalizedString("runningInCoexistenceMode", tableName: filename, bundle: Bundle.main, value: "Running in Coexistence mode", comment: "Dexcom bluetooth status footer. Another app authenticates with the transmitter.")
    }()

    static let runningInPrimaryMode: String = {
        return NSLocalizedString("runningInPrimaryMode", tableName: filename, bundle: Bundle.main, value: "Running in Primary mode", comment: "Dexcom bluetooth status footer. This app controls the transmitter connection.")
    }()

    static let connectionDiagramOtherApp = NSLocalizedString("connectionDiagramOtherApp", tableName: filename, bundle: .main, value: "Other App", comment: "Other app label in the connection diagram")
    static let connectionMode = NSLocalizedString("dexcomConnectionMode", tableName: filename, bundle: .main, value: "Connection Mode", comment: "Title for the first Dexcom add-device step")
    static let primaryMode = NSLocalizedString("dexcomPrimaryMode", tableName: filename, bundle: .main, value: "Primary", comment: "Dexcom connection mode choice")
    static let coexistenceMode = NSLocalizedString("dexcomCoexistenceMode", tableName: filename, bundle: .main, value: "Coexistence", comment: "Dexcom connection mode choice")
    static let primaryModePickerOption = NSLocalizedString("dexcomPrimaryModePickerOption", tableName: filename, bundle: .main, value: "Primary Mode", comment: "Full title for the Dexcom primary connection mode")
    static let coexistenceModePickerOption = NSLocalizedString("dexcomCoexistenceModePickerOption", tableName: filename, bundle: .main, value: "Coexistence Mode", comment: "Full title for the Dexcom coexistence connection mode")
    static let dexcomConnectionModeSelectionExplanation = NSLocalizedString("dexcomConnectionModeSelectionExplanation", tableName: filename, bundle: .main, value: "Primary Mode connects this app directly and requires any other app that connects to the Dexcom device to be closed.\n\nCoexistence Mode relies on another app to maintain the Dexcom connection and receive readings.", comment: "Required explanation shown above the Dexcom connection mode picker")
    static let primaryModeAddFlowMessage = NSLocalizedString("dexcomPrimaryModeAddFlowMessage", tableName: filename, bundle: .main, value: "Connect directly as the main app. Disconnect any other app from this Dexcom.", comment: "Explanation below the Primary choice")
    static let coexistenceModeAddFlowMessage = NSLocalizedString("dexcomCoexistenceModeAddFlowMessage", tableName: filename, bundle: .main, value: "Share the connection with another app. Keep the Dexcom or CamAPS app working correctly in the background.", comment: "Explanation below the Coexistence choice")
    static let dexcomG6ModeSelectionFooter = NSLocalizedString("dexcomG6ModeSelectionFooter", tableName: filename, bundle: .main, value: "You can change the G6 connection mode later in the transmitter settings.", comment: "Footer below the G6 initial connection-mode choices")
    static let sensorCode = Texts_HomeView.sensorCode
    static let dexcomG7NoSensorLabelFound = NSLocalizedString("dexcomG7NoSensorLabelFound", tableName: filename, bundle: .main, value: "No Dexcom G7 sensor label was found in the photo.", comment: "No G7 Data Matrix found in selected photo")
    static let dexcomG7InvalidSensorLabelFound = NSLocalizedString("dexcomG7InvalidSensorLabelFound", tableName: filename, bundle: .main, value: "A Data Matrix was found, but it was not a valid Dexcom G7 sensor label.", comment: "Invalid G7 Data Matrix found in selected photo")
    
    static let connected: String = {
        return NSLocalizedString("connected", tableName: filename, bundle: Bundle.main, value: "Connected", comment: "when Bluetooth Peripheral is shown, connection status, connected")
    }()
    
    static let donotconnect: String = {
        return NSLocalizedString("donotconnect", tableName: filename, bundle: Bundle.main, value: "Stop Scanning", comment: "text in button top right, this button will disable automatic connect")
    }()
    
    static let selectAliasText: String = {
        return NSLocalizedString("selectAliasText", tableName: filename, bundle: Bundle.main, value: "Choose an alias for this bluetooth device, the name will be shown in the app and is easier for you to recognize", comment: "Bluetooth Peripheral view, when user clicks alias field")
    }()
    
    static let aliasAlreadyExists: String = {
        return NSLocalizedString("aliasAlreadyExists", tableName: filename, bundle: Bundle.main, value: "There is already a bluetooth device with this alias", comment: "Bluetooth Peripheral view, when user clicks alias field")
    }()
    
    static let confirmDeletionBluetoothPeripheral: String = {
        return NSLocalizedString("confirmDeletionPeripheral", tableName: filename, bundle: Bundle.main, value: "Do you want to delete bluetooth device: ", comment: "Bluetooth Peripheral view, when user clicks the trash button - this is not the complete sentence, it will be followed either by 'name' or 'alias', depending on the availability of an alias")
    }()
    
    static let bluetoothPeripheralAlias: String = {
        return NSLocalizedString("bluetoothPeripheralAlias", tableName: filename, bundle: Bundle.main, value: "Alias:", comment: "BluetoothPeripheral view, this is a name of a BluetoothPeripheral assigned by the user, to recognize the device")
    }()

    static let sensorSerialNumber: String = {
        return NSLocalizedString("SensorSerialNumber", tableName: filename, bundle: Bundle.main, value: "Sensor Serial Number:", comment: "BluetoothPeripheral view, text of the cell with the sensor serial number")
    }()
    
    static let sensorType: String = {
        return NSLocalizedString("sensorType", tableName: filename, bundle: Bundle.main, value: "Sensor Type:", comment: "BluetoothPeripheral view, text of the cell with the sensor type (only used for Libre)")
    }()
    
    static let serialNumber: String = {
        return NSLocalizedString("serialNumber", tableName: filename, bundle: Bundle.main, value: "Serial Number:", comment: "BluetoothPeripheral view, text of the cell with the serial number (this is not the sensor serial number")
    }()
    
    static let battery: String = {
        return NSLocalizedString("battery", tableName: filename, bundle: Bundle.main, value: "Battery", comment: "BluetoothPeripheral view, section title with battery info")
    }()

    static let batteryHistory = NSLocalizedString("batteryHistory", tableName: filename, bundle: .main, value: "Battery History", comment: "Title and row that open the saved battery history chart")
    static let batteryHistoryTransmitterID = NSLocalizedString("batteryHistoryTransmitterID", tableName: filename, bundle: .main, value: "Transmitter ID", comment: "Battery history row showing the Bluetooth device name")
    static let batteryHistoryNoData = NSLocalizedString("batteryHistoryNoData", tableName: filename, bundle: .main, value: "No battery history", comment: "Empty-state title before any genuine battery observation is saved")
    static let batteryHistoryBeginsAfterReading = NSLocalizedString("batteryHistoryBeginsAfterReading", tableName: filename, bundle: .main, value: "History begins after the next genuine battery reading.", comment: "Empty-state explanation for battery history")
    static let batteryHistoryRange = NSLocalizedString("batteryHistoryRange", tableName: filename, bundle: .main, value: "Range", comment: "Label for the battery history time-range selector")
    static let batteryHistoryRangeAccessibility = NSLocalizedString("batteryHistoryRangeAccessibility", tableName: filename, bundle: .main, value: "Battery history range", comment: "Accessibility label for the battery history time-range selector")
    static let batteryHistoryRangeExplanation = NSLocalizedString("batteryHistoryRangeExplanation", tableName: filename, bundle: .main, value: "Fixed ranges run from now back to the selected number of days. Gaps show periods without a reading.", comment: "Explanation below the battery history chart")
    static let batteryHistoryInactive = NSLocalizedString("batteryHistoryInactive", tableName: filename, bundle: .main, value: "Transmitter Inactive", comment: "Label identifying battery history for a disabled transmitter")
    static let batteryHistoryHistoricalRangeExplanation = NSLocalizedString("batteryHistoryHistoricalRangeExplanation", tableName: filename, bundle: .main, value: "Ranges end at the last recorded reading. Gaps show periods without a reading.", comment: "Section footer below an inactive transmitter battery history chart")

    static let versionCode: String = {
        return NSLocalizedString("versionCode", tableName: filename, bundle: Bundle.main, value: "Version Code", comment: "Dexcom G7 family firmware compatibility version code")
    }()

    static let voltageA: String = {
        return NSLocalizedString("voltageA", tableName: filename, bundle: Bundle.main, value: "Voltage A", comment: "Dexcom transmitter battery voltage A")
    }()

    static let voltageB: String = {
        return NSLocalizedString("voltageB", tableName: filename, bundle: Bundle.main, value: "Voltage B", comment: "Dexcom transmitter battery voltage B")
    }()

    static let waitingForData: String = {
        return NSLocalizedString("waitingForData", tableName: filename, bundle: Bundle.main, value: "Waiting for data...", comment: "Battery row before the first transmitter battery response")
    }()
    
    static let needsTransmitterId: String = {
        return NSLocalizedString("needsTransmitterId", tableName: filename, bundle: Bundle.main, value: "Missing Transmitter ID", comment: "cell text, if user needs to set the transmitter id")
    }()
    
    static let scan: String = {
        return NSLocalizedString("scan", tableName: filename, bundle: Bundle.main, value: "Scan", comment: "text in button to start scanning")
    }()

    static let medtrumNanoPumpScanNoticeTitle: String = {
        return NSLocalizedString("medtrumNanoPumpScanNoticeTitle", tableName: filename, bundle: Bundle.main, value: "Medtrum Nano Pump Connection", comment: "title of the notice shown before scanning for a Medtrum Nano Pump")
    }()

    static let medtrumNanoPumpScanNoticeMessage: String = {
        return NSLocalizedString(
            "medtrumNanoPumpScanNoticeMessage",
            tableName: filename,
            bundle: Bundle.main,
            value: "This option connects to the Medtrum Nano Pump, not directly to the Nano CGM transmitter.\n\nBefore scanning, make sure EasyPatch is running, connected to the pump, and receiving current CGM values.\n\nEasyPatch must remain running and continue receiving values at all times.",
            comment: "notice shown before scanning for a Medtrum Nano Pump, explaining that the CGM connection is relayed by the pump and requires EasyPatch"
        )
    }()

    static let libre2ScanNoticeTitle: String = {
        return NSLocalizedString("libre2ScanNoticeTitle", tableName: filename, bundle: Bundle.main, value: "Libre App Bluetooth", comment: "title of the notice shown before scanning for a Libre 2 sensor")
    }()

    static let libre2ScanNoticeMessage: String = {
        return NSLocalizedString(
            "libre2ScanNoticeMessage",
            tableName: filename,
            bundle: Bundle.main,
            value: "Before scanning, disable Bluetooth permission for the Libre app in your iPhone settings.\n\nBluetooth permission for the Libre app must remain disabled at all times. Otherwise, the Libre app may take over the sensor connection and stop this app from receiving values.",
            comment: "notice shown before scanning for a Libre 2 sensor, explaining that Bluetooth permission for the Libre app must remain disabled"
        )
    }()

    static let dexcomG6ScanNoticeTitle: String = {
        return NSLocalizedString("dexcomG6ScanNoticeTitle", tableName: filename, bundle: Bundle.main, value: "Dexcom App Connection", comment: "title of the notice shown before scanning for a Dexcom G6 or ONE transmitter")
    }()

    static let dexcomG6ScanNoticeMessage: String = {
        return NSLocalizedString(
            "dexcomG6ScanNoticeMessage",
            tableName: filename,
            bundle: Bundle.main,
            value: "Before scanning, force-close the Dexcom app or disable Bluetooth permission for it.\n\nThe Dexcom app must not be connected to the transmitter while this app is scanning or receiving values.",
            comment: "notice shown before scanning for a Dexcom G6 or ONE transmitter, explaining how to avoid a competing Dexcom app connection"
        )
    }()

    static let dexcomG7ScanNoticeTitle: String = {
        return NSLocalizedString("dexcomG7ScanNoticeTitle", tableName: filename, bundle: Bundle.main, value: "Dexcom G7 App Required", comment: "title of the notice shown before scanning for a Dexcom G7 sensor")
    }()

    static let dexcomG7ScanNoticeMessage: String = {
        return NSLocalizedString(
            "dexcomG7ScanNoticeMessage",
            tableName: filename,
            bundle: Bundle.main,
            value: "Before scanning, make sure the Dexcom G7 app is running in the background, connected to the sensor, and receiving current glucose values.\n\nThe Dexcom G7 app must remain running and continue receiving values at all times.",
            comment: "notice shown before scanning for a Dexcom G7 sensor, explaining that the Dexcom G7 app must remain running and receiving values"
        )
    }()
    
    static let readyToScan: String = {
        return NSLocalizedString("readyToScan", tableName: filename, bundle: Bundle.main, value: "Ready to Scan", comment: "text in status row, if ready to start scanning")
    }()
    
    static let scanning: String = {
        return NSLocalizedString("scanning", tableName: filename, bundle: Bundle.main, value: "Scanning", comment: "text in status row, if scanning ongoing")
    }()

    static let scanningForTransmitter: String = {
        return NSLocalizedString("scanningForTransmitter", tableName: filename, bundle: Bundle.main, value: "Scanning...", comment: "full status while discovering a new unknown Bluetooth transmitter")
    }()

    static let connecting: String = {
        return NSLocalizedString("connecting", tableName: filename, bundle: Bundle.main, value: "Connecting", comment: "compact status before the first successful Bluetooth connection after activation")
    }()

    static let connectingToTransmitter: String = {
        return NSLocalizedString("connectingToTransmitter", tableName: filename, bundle: Bundle.main, value: "Connecting...", comment: "full status before the first successful Bluetooth connection after activation")
    }()

    static let reconnecting: String = {
        return NSLocalizedString("reconnecting", tableName: filename, bundle: Bundle.main, value: "Reconnecting", comment: "compact warning status for an unexpectedly disconnected continuously connected device")
    }()

    static let reconnectingToTransmitter: String = {
        return NSLocalizedString("reconnectingToTransmitter", tableName: filename, bundle: Bundle.main, value: "Reconnecting...", comment: "full warning status for an unexpectedly disconnected continuously connected device")
    }()

    static let waiting: String = {
        return NSLocalizedString("waiting", tableName: filename, bundle: Bundle.main, value: "Waiting...", comment: "healthy status for an intermittent Dexcom device between normal Bluetooth advertisements; used in both full and compact presentations")
    }()
    
    static let disconnect: String = {
        return NSLocalizedString("disconnect", tableName: filename, bundle: Bundle.main, value: "Disconnect", comment: "button text, to disconnect")
    }()
    
    static let tryingToConnect: String = {
        return NSLocalizedString("tryingToConnect", tableName: filename, bundle: Bundle.main, value: "Scanning", comment: "text in status rown, when not connect but app is trying to connect")
    }()
    
    static let notTryingToConnect: String = {
        return NSLocalizedString("notTryingToConnect", tableName: filename, bundle: Bundle.main, value: "Not Scanning", comment: "text in status row, when not connected and app is not scanning")
    }()
    
    static let connect: String = {
        return NSLocalizedString("connect", tableName: filename, bundle: Bundle.main, value: "Connect", comment: "button text, to connect")
    }()
    
    static let connectedAt: String = {
        return NSLocalizedString("connectedAt", tableName: filename, bundle: Bundle.main, value: "Connected At:", comment: "cell text, where the connection timestamp is shown")
    }()
    
    static let disConnectedAt: String = {
        return NSLocalizedString("disConnectedAt", tableName: filename, bundle: Bundle.main, value: "Disconnected At:", comment: "cell text, where the disconnection timestamp is shown")
    }()
    
    static let resetRequired: String = {
        return NSLocalizedString("resetRequired", tableName: filename, bundle: Bundle.main, value: "Reset Transmitter", comment: "cell text, where user can select to reset a transmitter at next connect. Only for Dexcom")
    }()
    
    static let lastResetTimeStamp: String = {
        return NSLocalizedString("lastReset", tableName: filename, bundle: Bundle.main, value: "Last Reset:", comment: "cell text, shows when last reset was done, if known. Only for Dexcom")
    }()
    
    static let transmittterStartDate: String = {
        return NSLocalizedString("transmittterStartDate", tableName: filename, bundle: Bundle.main, value: "Transmitter Started", comment: "cell text, transmitter start time")
    }()
    
    static let transmittterExpiryDate: String = {
        return NSLocalizedString("transmittterExpiryDate", tableName: filename, bundle: Bundle.main, value: "Transmitter Expires", comment: "cell text, transmitter expiry date")
    }()

    static let transmitterExpiresLabel = NSLocalizedString("transmitterExpiresLabel", tableName: filename, bundle: .main, value: "Expires", comment: "Label before the transmitter expiry date in its information message")

    static let sensorStartDate: String = {
        return NSLocalizedString("sensorStartDate", tableName: filename, bundle: Bundle.main, value: "Sensor Started", comment: "cell text, sensor start time")
    }()
    
    static let lastResetTimeStampNotKnown: String = {
        return NSLocalizedString("lastResetNotKnown", tableName: filename, bundle: Bundle.main, value: "Last Reset Timestamp is not known", comment: "cell text, shows when last reset was done, if known. Only for Dexcom")
    }()
   
    static let transmitterResetResult: String = {
        return NSLocalizedString("transmitterResultResult", tableName: filename, bundle: Bundle.main, value: "Transmitter Reset Result", comment: "To give result about transitter result in notification body")
    }()
    
    static let bootLoader: String = {
        return NSLocalizedString("bootLoader", tableName: filename, bundle: Bundle.main, value: "Bootloader", comment: "row in bluetoothperipheral view, title")
    }()

    static let cannotActiveCGMInFollowerMode: String = {
        return NSLocalizedString("cannotActiveCGMInFollowerMode", tableName: filename, bundle: Bundle.main, value: "You cannot activate or connect to a CGM whilst in Follower Mode.", comment: "User tries to add a CGM or connect an already existing CGM, while in follower mode.")
    }()
    
    static let confirmDisconnectTitle: String = {
        return NSLocalizedString("confirmDisconnectTitle", tableName: filename, bundle: Bundle.main, value: "Confirm Disconnect", comment: "Disconnect transmitter, title")
    }()
    
    static let confirmDisconnectMessage: String = {
        return NSLocalizedString("confirmDisconnectMessage", tableName: filename, bundle: Bundle.main, value: "Click 'Disconnect' to confirm that you really want to disconnect from the transmitter.", comment: "Confirm that the user wants to really disconnect the transmitter, title")
    }()
    
    static let dexcomG6BluetoothSlot: String = {
        return NSLocalizedString("dexcomG6BluetoothSlot", tableName: filename, bundle: Bundle.main, value: "Bluetooth Channel", comment: "Dexcom G6 Bluetooth screen. Picker title for the authentication role/slot.")
    }()

    static let dexcomBluetoothChannelSelectionExplanation: String = {
        return NSLocalizedString("dexcomBluetoothChannelSelectionExplanation", tableName: filename, bundle: Bundle.main, value: "Choose the Bluetooth channel that this app will use. Select Mobile App unless you need to leave that channel available for another connection.", comment: "Required explanation shown above the Dexcom Bluetooth channel picker for every Dexcom model.")
    }()

    static let dexcomG6MobileAppSlot: String = {
        return NSLocalizedString("dexcomG6MobileAppSlot", tableName: filename, bundle: Bundle.main, value: "Slot 2: Mobile App (Default)", comment: "Dexcom G6 Bluetooth slot picker. Default mobile-app role.")
    }()

    static let dexcomG6MobileAppSlotShort: String = {
        return NSLocalizedString("dexcomG6MobileAppSlotShort", tableName: filename, bundle: Bundle.main, value: "Mobile App", comment: "Dexcom G6 Bluetooth screen. Compact detail value for the default mobile-app role.")
    }()

    static let dexcomG6MedicalDeviceSlot: String = {
        return NSLocalizedString("dexcomG6MedicalDeviceSlot", tableName: filename, bundle: Bundle.main, value: "Slot 1: Receiver or Pump", comment: "Dexcom G6 Bluetooth slot picker. Receiver-or-pump role.")
    }()

    static let dexcomG6MedicalDeviceSlotShort: String = {
        return NSLocalizedString("dexcomG6MedicalDeviceSlotShort", tableName: filename, bundle: Bundle.main, value: "Pump", comment: "Dexcom G6 Bluetooth screen. Compact detail value for the receiver or pump role.")
    }()

    static let dexcomG6AnubisSlot: String = {
        return NSLocalizedString("dexcomG6AnubisSlot", tableName: filename, bundle: Bundle.main, value: "Slot 3: Anubis Extra", comment: "Dexcom G6 Bluetooth slot picker. Extra slot implemented by Anubis transmitters.")
    }()

    static let dexcomG6AnubisSlotShort: String = {
        return NSLocalizedString("dexcomG6AnubisSlotShort", tableName: filename, bundle: Bundle.main, value: "Slot 3", comment: "Dexcom G6 Bluetooth screen. Compact detail value for the experimental Anubis third slot.")
    }()

    static let dexcomG6MobileAppSlotFooter: String = {
        return NSLocalizedString("dexcomG6MobileAppSlotFooter", tableName: filename, bundle: Bundle.main, value: "The Mobile App channel is the default for phone connections.", comment: "Dexcom G6 Bluetooth screen. Footer shown while the default mobile-app channel is selected.")
    }()

    static let dexcomG6MedicalDeviceSlotFooter: String = {
        return NSLocalizedString("dexcomG6MedicalDeviceSlotFooter", tableName: filename, bundle: Bundle.main, value: "The Receiver or Pump channel is normally reserved for the Dexcom receiver or a compatible pump. Using it for this app leaves the Mobile App channel available for a phone or another device.", comment: "Dexcom G6 Bluetooth screen. Footer shown while the receiver or pump channel is selected.")
    }()

    static let dexcomG6AnubisSlotFooter: String = {
        return NSLocalizedString("dexcomG6AnubisSlotFooter", tableName: filename, bundle: Bundle.main, value: "Slot 3 is available only on Anubis transmitters. It is experimental and leaves the Mobile App and Receiver or Pump channels available for other devices.", comment: "Dexcom G6 Bluetooth screen. Footer shown while the experimental Anubis third slot is selected.")
    }()

    static let dexcomG6BluetoothSlotUnavailableInCoexistenceMode: String = {
        return NSLocalizedString("dexcomG6BluetoothSlotUnavailableInCoexistenceMode", tableName: filename, bundle: Bundle.main, value: "Unavailable in Co-existence mode", comment: "Dexcom G6 Bluetooth screen. Footer shown when Bluetooth channel selection is disabled by Coexistence Mode.")
    }()

    static let dexcomG6MedicalDeviceSlotWarning: String = {
        return NSLocalizedString("dexcomG6MedicalDeviceSlotWarning", tableName: filename, bundle: Bundle.main, value: "The Receiver or Pump channel is normally reserved for a Dexcom receiver or compatible pump. Selecting it can prevent that device from connecting.\n\nUsing the Receiver or Pump channel should be considered for experimental use only. The selection takes effect on the next authentication.", comment: "Safety warning before selecting the experimental Dexcom G6 receiver-or-pump Bluetooth channel.")
    }()

    static let dexcomG6AnubisSlotWarning: String = {
        return NSLocalizedString("dexcomG6AnubisSlotWarning", tableName: filename, bundle: Bundle.main, value: "Slot 3 is an experimental channel available only on Anubis transmitters.\n\nUse Slot 3 for testing only. The selection takes effect on the next authentication.", comment: "Safety warning before selecting the experimental Anubis third Bluetooth slot.")
    }()

    static let dexcomG6CoexistenceModeFooter: String = {
        return NSLocalizedString("useOtherDexcomAppCoexistenceFooter", tableName: filename, bundle: Bundle.main, value: "Coexistence mode is selected. Another app such as Dexcom or CamAPS must keep running in the background.", comment: "Dexcom G6 Bluetooth screen. Footer explaining the selected coexistence mode.")
    }()

    static let dexcomG6PrimaryModeFooter: String = {
        return NSLocalizedString("useOtherDexcomAppPrimaryFooter", tableName: filename, bundle: Bundle.main, value: "Primary mode is selected. This app connects as the main app and controls the connection.", comment: "Dexcom G6 Bluetooth screen. Footer explaining the selected primary mode.")
    }()

    static let dexcomG7PairingCodeMessage: String = {
        return NSLocalizedString("dexcomG7PairingCodeMessage", tableName: filename, bundle: Bundle.main, value: "Enter the four-digit sensor pairing code from the current applicator. Primary mode cannot authenticate without this code.", comment: "Dexcom G7 bluetooth screen. Explanation for the native authentication pairing code.")
    }()

    static let dexcomG7BluetoothSlot: String = {
        return NSLocalizedString("dexcomG7BluetoothSlot", tableName: filename, bundle: Bundle.main, value: "Bluetooth Channel", comment: "Dexcom G7 Bluetooth screen. Picker title for the authentication role/slot.")
    }()

    static let dexcomG7MobileAppSlot: String = {
        return NSLocalizedString("dexcomG7MobileAppSlot", tableName: filename, bundle: Bundle.main, value: "Slot 2: Mobile App (Default)", comment: "Dexcom G7 Bluetooth slot picker. Default mobile-app role.")
    }()

    static let dexcomG7MobileAppSlotShort: String = {
        return NSLocalizedString("dexcomG7MobileAppSlotShort", tableName: filename, bundle: Bundle.main, value: "Mobile App", comment: "Dexcom G7 Bluetooth screen. Compact detail for the mobile-app role.")
    }()

    static let dexcomG7MedicalDeviceSlot: String = {
        return NSLocalizedString("dexcomG7MedicalDeviceSlot", tableName: filename, bundle: Bundle.main, value: "Slot 1: Receiver or Pump", comment: "Dexcom G7 Bluetooth slot picker. Receiver-or-pump role.")
    }()

    static let dexcomG7MedicalDeviceSlotShort: String = {
        return NSLocalizedString("dexcomG7MedicalDeviceSlotShort", tableName: filename, bundle: Bundle.main, value: "Pump", comment: "Dexcom G7 Bluetooth screen. Compact detail for the receiver-or-pump role.")
    }()

    static let dexcomG7SmartWatchSlot: String = {
        return NSLocalizedString("dexcomG7SmartWatchSlot", tableName: filename, bundle: Bundle.main, value: "Slot 3: Smart Watch", comment: "Dexcom G7 Bluetooth slot picker. Factory smart-watch role.")
    }()

    static let dexcomG7SmartWatchSlotShort: String = {
        return NSLocalizedString("dexcomG7SmartWatchSlotShort", tableName: filename, bundle: Bundle.main, value: "Smart Watch", comment: "Dexcom G7 Bluetooth screen. Compact detail for the smart-watch role.")
    }()

    static let dexcomG7MobileAppSlotFooter: String = {
        return NSLocalizedString("dexcomG7MobileAppSlotFooter", tableName: filename, bundle: Bundle.main, value: "The Mobile App channel (slot 2) is the default and is the currently validated native G7 connection.", comment: "Dexcom G7 Bluetooth screen. Footer for the default mobile-app channel.")
    }()

    static let dexcomG7MedicalDeviceSlotFooter: String = {
        return NSLocalizedString("dexcomG7MedicalDeviceSlotFooter", tableName: filename, bundle: Bundle.main, value: "The Receiver or Pump channel uses authentication slot 1.", comment: "Dexcom G7 Bluetooth screen. Footer for the receiver-or-pump channel.")
    }()

    static let dexcomG7SmartWatchSlotFooter: String = {
        return NSLocalizedString("dexcomG7SmartWatchSlotFooter", tableName: filename, bundle: Bundle.main, value: "The Smart Watch channel uses the factory authentication slot 3.", comment: "Dexcom G7 Bluetooth screen. Footer for the smart-watch channel.")
    }()
    
    static let dexcomG6CoexistenceModeSelectionMessage: String = {
        return String(format: NSLocalizedString("dexcomG6CoexistenceModeSelectionMessage", tableName: filename, bundle: Bundle.main, value: "Coexistence mode has been selected. Another app, such as Dexcom G6 or CamAPS, must connect to and authenticate with the G6 transmitter.\n\nKeep the other app running in the background or %@ will not receive readings.", comment: "Dexcom G6 Bluetooth screen. Message shown after selecting coexistence mode."), ConstantsHomeView.applicationName)
    }()

    static let dexcomG6PrimaryModeSelectionMessage: String = {
        return String(format: NSLocalizedString("dexcomG6PrimaryModeSelectionMessage", tableName: filename, bundle: Bundle.main, value: "Primary mode has been selected. %@ must be the only app connecting to and authenticating with the G6 transmitter.\n\nClose any other app that connects to the transmitter or disable its Bluetooth permission. Otherwise, %@ or the other app may not receive readings.", comment: "Dexcom G6 Bluetooth screen. Message shown after selecting primary mode."), ConstantsHomeView.applicationName, ConstantsHomeView.applicationName)
    }()
    
    static let nfcScanNeeded: String = {
        return NSLocalizedString("nfcScanNeeded", tableName: filename, bundle: Bundle.main, value: "NFC scan needed", comment: "text in status row, when waiting for a successful NFC scan before starting bluetooth scanning")
    }()
    
    static let nonFixedSlopeWarning: String = {
        return NSLocalizedString("nonFixedSlopeWarning", tableName: filename, bundle: Bundle.main, value: "Multi-point calibration is an advanced feature.\n\nPlease do not use this feature until you have read the calibration section of the online help and understand how it works.", comment: "text to inform the user that multi-point calibration is an advanced option and could be dangerous if used incorrectly")
    }()
    
    static let warmingUpUntil: String = {
        return NSLocalizedString("warmingUpUntil", tableName: filename, bundle: Bundle.main, value: "Warmup until", comment: "Compact sensor warm-up label followed by the localized completion time")
    }()
    
    static let nativeAlgorithm: String = {
        return NSLocalizedString("nativeAlgorithm", tableName: filename, bundle: Bundle.main, value: "Native Algorithm", comment: "native or transmitter algorithm type text")
    }()
    
    static let xDripAlgorithm: String = {
        return NSLocalizedString("xDripAlgorithm", tableName: filename, bundle: Bundle.main, value: "xDrip Algorithm", comment: "xDrip algorithm type text")
    }()
    
    static let confirmAlgorithmChangeToTransmitterMessage: String = {
        return NSLocalizedString("confirmAlgorithmChangeToTransmitterMessage", tableName: filename, bundle: Bundle.main, value: "Please confirm that you want to change back to the native/transmitter algorithm.", comment: "Confirm that the user wants to really change the transmitter or native algorithm type, message")
    }()
    
    static let confirmAlgorithmChangeToxDripMessage: String = {
        return NSLocalizedString("confirmAlgorithmChangeToxDripMessage", tableName: filename, bundle: Bundle.main, value: "Please confirm that you want to change the the xDrip algorithm.\n\nThis will stop readings for a short time and ask you for a initial calibration value when ready.", comment: "Confirm that the user wants to really change the xDrip algorithm type, message")
    }()
    
    static let confirmCalibrationChangeToSinglePointMessage: String = {
        return NSLocalizedString("confirmCalibrationChangeToSinglePointMessage", tableName: filename, bundle: Bundle.main, value: "Please confirm that you want to change the calibration type to the standard calibration\n\nThis will stop readings for a short time and ask you for a initial calibration value when ready.", comment: "Confirm that the user wants to really change the calibration type to multi-point, message")
    }()
    
    static let confirmCalibrationChangeToMultiPointMessage: String = {
        return NSLocalizedString("confirmCalibrationChangeToMultiPointMessage", tableName: filename, bundle: Bundle.main, value: "Please confirm that you want to change the calibration type to multi-point\n\n⚠️ Please note that this method is only for advanced users and could potentially give dangerous results if not correctly calibrated.\n\nIf you are unsure how to use this method, please press Cancel.", comment: "Confirm that the user wants to really change the calibration type to multi-point, message")
    }()
    
    static let confirm: String = {
        return NSLocalizedString("confirm", tableName: filename, bundle: Bundle.main, value: "Confirm", comment: "button text, confirm")
    }()
    
    static let maxSensorAgeInDaysOverridenAnubis: String = {
        return NSLocalizedString("maxSensorAgeInDaysOverridenAnubis", tableName: filename, bundle: Bundle.main, value: "Maximum Sensor Days", comment: "user can override the maximum sensor days if using an anubis transmitter")
    }()
    
    static let maxSensorAgeInDaysOverridenAnubisMessage = {
        return String(format: NSLocalizedString("maxSensorAgeInDaysOverridenAnubisMessage", tableName: filename, bundle: Bundle.main, value: "If using an Anubis transmitter, you can enter here the maximum number of days for the sensor lifetime (maximum %@)\n\nNote that this is only a visual reminder. It will not end the sensor session when reached.\n\nEnter 0 to use the default of %@ days", comment: "user can override the maximum sensor days if using an anubis transmitter"), ConstantsDexcomG5.maxSensorAgeInDaysOverridenAnubisMaximum.stringWithoutTrailingZeroes, ConstantsDexcomG5.maxSensorAgeInDays.stringWithoutTrailingZeroes)
    }()
    
    static let isAnubis: String = {
        return NSLocalizedString("isAnubis", tableName: filename, bundle: Bundle.main, value: "Is Anubis?", comment: "Dexcom bluetooth screen. Is it an anubis transmitter")
    }()
    
    static let readSuccess: String = {
        return NSLocalizedString("readSuccess", tableName: filename, bundle: Bundle.main, value: "Read Success", comment: "Bluetooth peripheral screen. row title for the read success line")
    }()

    static let readSuccessLast24Hours: String = {
        return NSLocalizedString("readSuccessLast24Hours", tableName: filename, bundle: Bundle.main, value: "Last 24 Hours", comment: "Bluetooth peripheral Read Success screen. Section title for the hourly read success timeline")
    }()

    static let readSuccessNow: String = {
        return NSLocalizedString("readSuccessNow", tableName: filename, bundle: Bundle.main, value: "Now", comment: "Bluetooth peripheral Read Success screen. Timeline axis label for the current time")
    }()

    static func readSuccessReadingsReceived(actual: Int, expected: Int) -> String {
        return String(format: NSLocalizedString("readSuccessReadingsReceived", tableName: filename, bundle: Bundle.main, value: "%d of %d readings received", comment: "Bluetooth peripheral Read Success screen. Summary of received readings out of expected readings"), actual, expected)
    }

    static func readSuccessCadenceFooter(bluetoothPeripheralType: String) -> String {
        return String(format: NSLocalizedString("readSuccessCadenceFooter", tableName: filename, bundle: Bundle.main, value: "Expected readings are based on the observed transmitter cadence for %@.", comment: "Bluetooth peripheral Read Success screen. Footer explaining how expected readings are calculated. Placeholder is the transmitter type"), bluetoothPeripheralType)
    }

    static let readSuccessLegendGood: String = {
        return NSLocalizedString("readSuccessLegendGood", tableName: filename, bundle: Bundle.main, value: "Good", comment: "Bluetooth peripheral Read Success screen. Timeline legend label for good read success")
    }()

    static let readSuccessLegendLow: String = {
        return NSLocalizedString("readSuccessLegendLow", tableName: filename, bundle: Bundle.main, value: "Low", comment: "Bluetooth peripheral Read Success screen. Timeline legend label for reduced read success")
    }()

    static let readSuccessLegendPoor: String = {
        return NSLocalizedString("readSuccessLegendPoor", tableName: filename, bundle: Bundle.main, value: "Poor", comment: "Bluetooth peripheral Read Success screen. Timeline legend label for poor read success")
    }()

    static let readSuccessLegendNoData: String = {
        return NSLocalizedString("readSuccessLegendNoData", tableName: filename, bundle: Bundle.main, value: "No data", comment: "Bluetooth peripheral Read Success screen. Timeline legend label when no readings are expected or available")
    }()

    static let readSuccessNoReadingsExpected: String = {
        return NSLocalizedString("readSuccessNoReadingsExpected", tableName: filename, bundle: Bundle.main, value: "No readings expected", comment: "Bluetooth peripheral Read Success screen. Accessibility label for timeline hours with no expected readings")
    }()

    static func readSuccessTimelineAccessibility(success: Double, actual: Int, expected: Int) -> String {
        return String(format: NSLocalizedString("readSuccessTimelineAccessibility", tableName: filename, bundle: Bundle.main, value: "%0.1f percent, %d of %d readings", comment: "Bluetooth peripheral Read Success screen. Accessibility label for an hourly timeline bucket"), success, actual, expected)
    }
}

// MARK: - iCan

extension Texts_BluetoothPeripheralView {

    static let iCanScanNoticeTitle = NSLocalizedString("ican.scanNoticeTitle", tableName: filename, bundle: .main, value: "iCan Sensor Connection", comment: "Title of the notice shown before scanning for an iCan sensor")
    static let iCanScanNoticeMessage = NSLocalizedString("ican.scanNoticeMessage", tableName: filename, bundle: .main, value: "This app connects directly to an iCan (Sinocare) i3 or i6 sensor, but it cannot start a sensor. Start the sensor with the manufacturer's app first.\n\nBefore scanning, close the manufacturer's app and keep other iCan sensors out of range: a sensor talks to one phone at a time and the first connection takes the first iCan sensor it finds.\n\nScanning works only while this app is open. This driver has not been tried on a real sensor.", comment: "Notice shown before scanning for an iCan sensor")
    static let iCanSectionTitle = NSLocalizedString("ican.sectionTitle", tableName: filename, bundle: .main, value: "iCan sensor", comment: "Device screen section title")
    static let iCanSectionFooter = NSLocalizedString("ican.sectionFooter", tableName: filename, bundle: .main, value: "Values are the sensor's own readings. Finger-stick calibration, battery level and the manufacturer's cloud are not supported. Never tried on a real sensor.", comment: "Footer of the iCan section on the device screen")
    static let iCanModel = NSLocalizedString("ican.model", tableName: filename, bundle: .main, value: "Model", comment: "iCan device screen row")
    static let iCanFamily = NSLocalizedString("ican.family", tableName: filename, bundle: .main, value: "Sensor family", comment: "iCan device screen row: product family the driver recognised from the model and serial")
    static let iCanSoftware = NSLocalizedString("ican.software", tableName: filename, bundle: .main, value: "Software", comment: "iCan device screen row")
    static let iCanAuthentication = NSLocalizedString("ican.authentication", tableName: filename, bundle: .main, value: "Authentication", comment: "iCan device screen row: vendor handshake result")
    static let iCanAuthAccepted = NSLocalizedString("ican.authAccepted", tableName: filename, bundle: .main, value: "Accepted", comment: "iCan authentication state")
    static let iCanAuthRejected = NSLocalizedString("ican.authRejected", tableName: filename, bundle: .main, value: "Rejected", comment: "iCan authentication state")
    static let iCanAuthNotTried = NSLocalizedString("ican.authNotTried", tableName: filename, bundle: .main, value: "Not tried yet", comment: "iCan authentication state")
    static let iCanCalibration = NSLocalizedString("ican.calibration", tableName: filename, bundle: .main, value: "Factory calibration", comment: "iCan device screen row: calibration marker reported by the sensor")
    static let iCanCalibrationNotInstalled = NSLocalizedString("ican.calibrationNotInstalled", tableName: filename, bundle: .main, value: "Not installed", comment: "iCan calibration marker 0xFFFF")
    static let iCanCalibrationMarkerFormat = NSLocalizedString("ican.calibrationMarkerFormat", tableName: filename, bundle: .main, value: "Marker %d", comment: "iCan calibration marker value")
    static let iCanSensorState = NSLocalizedString("ican.sensorState", tableName: filename, bundle: .main, value: "Sensor state", comment: "iCan device screen row")
    static let iCanStateIdle = NSLocalizedString("ican.stateIdle", tableName: filename, bundle: .main, value: "Not started", comment: "iCan sensor state")
    static let iCanStateWarmup = NSLocalizedString("ican.stateWarmup", tableName: filename, bundle: .main, value: "Warming up", comment: "iCan sensor state")
    static let iCanStateRunning = NSLocalizedString("ican.stateRunning", tableName: filename, bundle: .main, value: "Running", comment: "iCan sensor state")
    static let iCanStateEnded = NSLocalizedString("ican.stateEnded", tableName: filename, bundle: .main, value: "Ended", comment: "iCan sensor state")
    static let iCanStateUnknownFormat = NSLocalizedString("ican.stateUnknownFormat", tableName: filename, bundle: .main, value: "Unknown (%d)", comment: "iCan sensor state byte not recognised")
    static let iCanSensorStart = NSLocalizedString("ican.sensorStart", tableName: filename, bundle: .main, value: "Session start", comment: "iCan device screen row")
    static let iCanExpectedEnd = NSLocalizedString("ican.expectedEnd", tableName: filename, bundle: .main, value: "Expected end", comment: "iCan device screen row: session start plus the rated life of the model")
    static let iCanLastReading = NSLocalizedString("ican.lastReading", tableName: filename, bundle: .main, value: "Last reading", comment: "iCan device screen row")
    static let iCanWaitingForReading = NSLocalizedString("ican.waitingForReading", tableName: filename, bundle: .main, value: "Waiting for reading", comment: "iCan device screen row before the first reading")
    static let iCanLastLinkProblem = NSLocalizedString("ican.lastLinkProblem", tableName: filename, bundle: .main, value: "Last link problem", comment: "iCan device screen row")
    static let iCanNoLinkProblem = NSLocalizedString("ican.noLinkProblem", tableName: filename, bundle: .main, value: "None since the last reading", comment: "iCan device screen row")
    static let iCanProblemLinkLost = NSLocalizedString("ican.problemLinkLost", tableName: filename, bundle: .main, value: "Link lost", comment: "iCan link problem")
    static let iCanProblemNoAnswer = NSLocalizedString("ican.problemNoAnswer", tableName: filename, bundle: .main, value: "Sensor not responding", comment: "iCan link problem")
    static let iCanProblemRejected = NSLocalizedString("ican.problemRejected", tableName: filename, bundle: .main, value: "Authentication rejected", comment: "iCan link problem")
    static let iCanProblemNoReadings = NSLocalizedString("ican.problemNoReadings", tableName: filename, bundle: .main, value: "No readings while connected", comment: "iCan link problem")
    static let iCanProblemHistoryRefused = NSLocalizedString("ican.problemHistoryRefused", tableName: filename, bundle: .main, value: "History request refused", comment: "iCan link problem")
    static let iCanProblemNotACGM = NSLocalizedString("ican.problemNotACGM", tableName: filename, bundle: .main, value: "Device is not an iCan sensor", comment: "iCan link problem")
    static let iCanProblemNotStarted = NSLocalizedString("ican.problemNotStarted", tableName: filename, bundle: .main, value: "Sensor not started: start it with the manufacturer's app", comment: "iCan link problem")
    static let iCanProblemEnded = NSLocalizedString("ican.problemEnded", tableName: filename, bundle: .main, value: "Sensor session ended", comment: "iCan link problem")

    static func iCanProblem(_ problem: ICanLinkProblem) -> String {
        switch problem {
        case .linkLost: return iCanProblemLinkLost
        case .noAuthenticationAnswer: return iCanProblemNoAnswer
        case .authenticationRejected: return iCanProblemRejected
        case .noReadings: return iCanProblemNoReadings
        case .historyRefused: return iCanProblemHistoryRefused
        case .notACGM: return iCanProblemNotACGM
        case .sensorNotStarted: return iCanProblemNotStarted
        case .sensorEnded: return iCanProblemEnded
        }
    }
}

// MARK: - AiDex

extension Texts_BluetoothPeripheralView {

    static let aiDexScanNoticeTitle = NSLocalizedString("aidex.scanNoticeTitle", tableName: filename, bundle: .main, value: "AiDex Sensor Connection", comment: "Title of the notice shown before scanning for an AiDex sensor")
    static let aiDexScanNoticeMessage = NSLocalizedString("aidex.scanNoticeMessage", tableName: filename, bundle: .main, value: "This app connects directly to an AiDex X or LinX sensor and starts one that has not been started yet. Sensors of the F series (named AiDEX F-…) need a key from the manufacturer's cloud, which this app does not use, so they cannot be connected.\n\nBefore scanning, close the manufacturer's app and keep other AiDex sensors out of range: a sensor talks to one phone at a time and the first connection takes the first AiDex sensor it finds. If iOS asks to pair with the sensor, accept.\n\nScanning works only while this app is open. This driver has not been tried on a real sensor.", comment: "Notice shown before scanning for an AiDex sensor")
    static let aiDexSectionTitle = NSLocalizedString("aidex.sectionTitle", tableName: filename, bundle: .main, value: "AiDex sensor", comment: "Device screen section title")
    static let aiDexSectionFooter = NSLocalizedString("aidex.sectionFooter", tableName: filename, bundle: .main, value: "Values are the sensor's own factory-calibrated readings. Calibration, the manufacturer's cloud and F-series sensors are not supported. Never tried on a real sensor.", comment: "Footer of the AiDex section on the device screen")
    static let aiDexModel = NSLocalizedString("aidex.model", tableName: filename, bundle: .main, value: "Model", comment: "AiDex device screen row")
    static let aiDexWearTime = NSLocalizedString("aidex.wearTime", tableName: filename, bundle: .main, value: "Rated wear time", comment: "AiDex device screen row: wear days the sensor reported")
    static let aiDexWearDaysFormat = NSLocalizedString("aidex.wearDaysFormat", tableName: filename, bundle: .main, value: "%d days", comment: "AiDex wear time value")
    static let aiDexPairingKey = NSLocalizedString("aidex.pairingKey", tableName: filename, bundle: .main, value: "Pairing key", comment: "AiDex device screen row: the key the sensor handed out")
    static let aiDexPairingKeyStored = NSLocalizedString("aidex.pairingKeyStored", tableName: filename, bundle: .main, value: "Stored on this phone", comment: "AiDex pairing key state")
    static let aiDexPairingKeyNotStored = NSLocalizedString("aidex.pairingKeyNotStored", tableName: filename, bundle: .main, value: "Not stored yet", comment: "AiDex pairing key state")
    static let aiDexSessionStart = NSLocalizedString("aidex.sessionStart", tableName: filename, bundle: .main, value: "Session start", comment: "AiDex device screen row")
    static let aiDexExpectedEnd = NSLocalizedString("aidex.expectedEnd", tableName: filename, bundle: .main, value: "Expected end", comment: "AiDex device screen row: session start plus the wear time")
    static let aiDexBattery = NSLocalizedString("aidex.battery", tableName: filename, bundle: .main, value: "Sensor battery", comment: "AiDex device screen row: battery voltage from the keepalive frames")
    static let aiDexBatteryFormat = NSLocalizedString("aidex.batteryFormat", tableName: filename, bundle: .main, value: "%.2f V", comment: "AiDex battery voltage in volts")
    static let aiDexLastReading = NSLocalizedString("aidex.lastReading", tableName: filename, bundle: .main, value: "Last reading", comment: "AiDex device screen row")
    static let aiDexWaitingForReading = NSLocalizedString("aidex.waitingForReading", tableName: filename, bundle: .main, value: "Waiting for reading", comment: "AiDex device screen row before the first reading")
    static let aiDexLastLinkProblem = NSLocalizedString("aidex.lastLinkProblem", tableName: filename, bundle: .main, value: "Last link problem", comment: "AiDex device screen row")
    static let aiDexNoLinkProblem = NSLocalizedString("aidex.noLinkProblem", tableName: filename, bundle: .main, value: "None since the last reading", comment: "AiDex device screen row")
    static let aiDexProblemLinkLost = NSLocalizedString("aidex.problemLinkLost", tableName: filename, bundle: .main, value: "Link lost", comment: "AiDex link problem")
    static let aiDexProblemKeyExchange = NSLocalizedString("aidex.problemKeyExchange", tableName: filename, bundle: .main, value: "Key exchange with the sensor failed", comment: "AiDex link problem")
    static let aiDexProblemSavedKeyRejected = NSLocalizedString("aidex.problemSavedKeyRejected", tableName: filename, bundle: .main, value: "Stored pairing key rejected by the sensor", comment: "AiDex link problem")
    static let aiDexProblemPairingRefused = NSLocalizedString("aidex.problemPairingRefused", tableName: filename, bundle: .main, value: "Sensor refused to pair: keep other phones and apps away from it", comment: "AiDex link problem")
    static let aiDexProblemUnsupportedFSeries = NSLocalizedString("aidex.problemUnsupportedFSeries", tableName: filename, bundle: .main, value: "F-series sensor: needs a manufacturer's cloud key, not supported", comment: "AiDex link problem")
    static let aiDexProblemSerialUnknown = NSLocalizedString("aidex.problemSerialUnknown", tableName: filename, bundle: .main, value: "Sensor serial number not found in its Bluetooth name", comment: "AiDex link problem")
    static let aiDexProblemNoReadings = NSLocalizedString("aidex.problemNoReadings", tableName: filename, bundle: .main, value: "No readings while connected", comment: "AiDex link problem")
    static let aiDexProblemHistoryFailed = NSLocalizedString("aidex.problemHistoryFailed", tableName: filename, bundle: .main, value: "History download did not finish", comment: "AiDex link problem")
    static let aiDexProblemNotStarted = NSLocalizedString("aidex.problemNotStarted", tableName: filename, bundle: .main, value: "Sensor not started", comment: "AiDex link problem")
    static let aiDexProblemEnded = NSLocalizedString("aidex.problemEnded", tableName: filename, bundle: .main, value: "Sensor session ended", comment: "AiDex link problem")
    static let aiDexProblemNotAnAiDex = NSLocalizedString("aidex.problemNotAnAiDex", tableName: filename, bundle: .main, value: "Device is not an AiDex sensor", comment: "AiDex link problem")

    static func aiDexProblem(_ problem: AiDexLinkProblem) -> String {
        switch problem {
        case .linkLost: return aiDexProblemLinkLost
        case .keyExchangeFailed: return aiDexProblemKeyExchange
        case .savedKeyRejected: return aiDexProblemSavedKeyRejected
        case .pairingRefused: return aiDexProblemPairingRefused
        case .unsupportedFSeries: return aiDexProblemUnsupportedFSeries
        case .serialUnknown: return aiDexProblemSerialUnknown
        case .noReadings: return aiDexProblemNoReadings
        case .historyFailed: return aiDexProblemHistoryFailed
        case .sensorNotStarted: return aiDexProblemNotStarted
        case .sensorEnded: return aiDexProblemEnded
        case .notAnAiDex: return aiDexProblemNotAnAiDex
        }
    }
}

// MARK: - Anytime

extension Texts_BluetoothPeripheralView {

    static let anytimeScanNoticeTitle = NSLocalizedString("anytime.scanNoticeTitle", tableName: filename, bundle: .main, value: "Anytime Sensor Connection", comment: "Title of the notice shown before scanning for an Anytime sensor")
    static let anytimeScanNoticeMessage = NSLocalizedString("anytime.scanNoticeMessage", tableName: filename, bundle: .main, value: "This app connects directly to an Anytime (Yuwell) transmitter of the CT2, CT4 or CT5 family and starts a sensor that has not been started yet. The CT2.5 and CT3 lines compute their glucose in a manufacturer's native library that this app does not have, so they are refused.\n\nBefore scanning, close the manufacturer's app and keep other Anytime transmitters out of range: a transmitter talks to one phone at a time and the first connection takes the first supported one it finds.\n\nScanning works only while this app is open. This driver has not been tried on a real sensor.", comment: "Notice shown before scanning for an Anytime sensor")
    static let anytimeSectionTitle = NSLocalizedString("anytime.sectionTitle", tableName: filename, bundle: .main, value: "Anytime sensor", comment: "Device screen section title")
    static let anytimeSectionFooter = NSLocalizedString("anytime.sectionFooter", tableName: filename, bundle: .main, value: "Values come from the transmitter or from this app's port of the manufacturer's model, depending on the family. Finger calibration is not available, and a CT4 without a sensor code uses a default factory slope. A reading marked as estimated is derived from the sensor current after the transmitter stopped computing glucose and is less accurate. Never tried on a real sensor.", comment: "Footer of the Anytime section on the device screen")
    static let anytimeFamily = NSLocalizedString("anytime.family", tableName: filename, bundle: .main, value: "Sensor family", comment: "Anytime device screen row")
    static let anytimeBluetoothName = NSLocalizedString("anytime.bluetoothName", tableName: filename, bundle: .main, value: "Bluetooth name", comment: "Anytime device screen row: the name the transmitter advertises")
    static let anytimeTransmitterVersion = NSLocalizedString("anytime.transmitterVersion", tableName: filename, bundle: .main, value: "Transmitter version", comment: "Anytime device screen row")
    static let anytimeBound = NSLocalizedString("anytime.bound", tableName: filename, bundle: .main, value: "Bound to this phone", comment: "Anytime device screen row")
    static let anytimeSensorCode = NSLocalizedString("anytime.sensorCode", tableName: filename, bundle: .main, value: "Sensor code", comment: "Anytime device screen row: the factory calibration code")
    static let anytimeSessionStart = NSLocalizedString("anytime.sessionStart", tableName: filename, bundle: .main, value: "Session start", comment: "Anytime device screen row")
    static let anytimeExpectedEnd = NSLocalizedString("anytime.expectedEnd", tableName: filename, bundle: .main, value: "Expected end", comment: "Anytime device screen row: session start plus the rated life")
    static let anytimeRecordNumber = NSLocalizedString("anytime.recordNumber", tableName: filename, bundle: .main, value: "Latest record number", comment: "Anytime device screen row: the sensor's glucose record counter")
    static let anytimeBattery = NSLocalizedString("anytime.battery", tableName: filename, bundle: .main, value: "Transmitter battery", comment: "Anytime device screen row")
    static let anytimeBatteryVoltsFormat = NSLocalizedString("anytime.batteryVoltsFormat", tableName: filename, bundle: .main, value: "%.2f V", comment: "Anytime battery voltage in volts")
    static let anytimeBatteryVoltsPercentFormat = NSLocalizedString("anytime.batteryVoltsPercentFormat", tableName: filename, bundle: .main, value: "%.2f V · %d %%", comment: "Anytime battery voltage in volts and percent")
    static let anytimeBatteryPercentFormat = NSLocalizedString("anytime.batteryPercentFormat", tableName: filename, bundle: .main, value: "%d %%", comment: "Anytime battery in percent")
    static let anytimeLastReading = NSLocalizedString("anytime.lastReading", tableName: filename, bundle: .main, value: "Last reading", comment: "Anytime device screen row")
    static let anytimeLastReadingEstimatedFormat = NSLocalizedString("anytime.lastReadingEstimatedFormat", tableName: filename, bundle: .main, value: "%@ · estimated from current", comment: "Anytime last reading with the note that the value was estimated from the sensor current")
    static let anytimeWaitingForReading = NSLocalizedString("anytime.waitingForReading", tableName: filename, bundle: .main, value: "Waiting for reading", comment: "Anytime device screen row before the first reading")
    static let anytimeWorkingCurrent = NSLocalizedString("anytime.workingCurrent", tableName: filename, bundle: .main, value: "Working electrode current", comment: "Anytime device screen row")
    static let anytimeBaselineCurrent = NSLocalizedString("anytime.baselineCurrent", tableName: filename, bundle: .main, value: "Baseline current", comment: "Anytime device screen row")
    static let anytimeCurrentFormat = NSLocalizedString("anytime.currentFormat", tableName: filename, bundle: .main, value: "%.2f nA", comment: "Anytime current in nanoamperes")
    static let anytimeTemperature = NSLocalizedString("anytime.temperature", tableName: filename, bundle: .main, value: "Temperature", comment: "Anytime device screen row")
    static let anytimeTemperatureFormat = NSLocalizedString("anytime.temperatureFormat", tableName: filename, bundle: .main, value: "%.1f °C", comment: "Anytime temperature in degrees Celsius")
    static let anytimeCounterVoltage = NSLocalizedString("anytime.counterVoltage", tableName: filename, bundle: .main, value: "Counter electrode voltage", comment: "Anytime device screen row")
    static let anytimeCounterVoltageFormat = NSLocalizedString("anytime.counterVoltageFormat", tableName: filename, bundle: .main, value: "%d mV", comment: "Anytime counter electrode voltage in millivolts")
    static let anytimeCurrentScale = NSLocalizedString("anytime.currentScale", tableName: filename, bundle: .main, value: "Current to glucose scale", comment: "Anytime device screen row: learned while the transmitter still computed glucose")
    static let anytimeCurrentScaleFormat = NSLocalizedString("anytime.currentScaleFormat", tableName: filename, bundle: .main, value: "%.2f (%d samples)", comment: "Anytime current scale with the number of samples it was learned from")
    static let anytimeLastLinkProblem = NSLocalizedString("anytime.lastLinkProblem", tableName: filename, bundle: .main, value: "Last link problem", comment: "Anytime device screen row")
    static let anytimeNoLinkProblem = NSLocalizedString("anytime.noLinkProblem", tableName: filename, bundle: .main, value: "None since the last reading", comment: "Anytime device screen row")
    static let anytimeProblemLinkLost = NSLocalizedString("anytime.problemLinkLost", tableName: filename, bundle: .main, value: "Link lost", comment: "Anytime link problem")
    static let anytimeProblemNotAnAnytime = NSLocalizedString("anytime.problemNotAnAnytime", tableName: filename, bundle: .main, value: "Device is not a supported Anytime transmitter", comment: "Anytime link problem")
    static let anytimeProblemUnsupportedFamily = NSLocalizedString("anytime.problemUnsupportedFamily", tableName: filename, bundle: .main, value: "Unsupported family: its glucose needs a native library this app does not have", comment: "Anytime link problem")
    static let anytimeProblemHandshakeStalled = NSLocalizedString("anytime.problemHandshakeStalled", tableName: filename, bundle: .main, value: "The start-up exchange got no answer", comment: "Anytime link problem")
    static let anytimeProblemProtocolTimeout = NSLocalizedString("anytime.problemProtocolTimeout", tableName: filename, bundle: .main, value: "The transmitter stopped answering commands", comment: "Anytime link problem")
    static let anytimeProblemCheckMalformed = NSLocalizedString("anytime.problemCheckMalformed", tableName: filename, bundle: .main, value: "The status reply was not understood", comment: "Anytime link problem")
    static let anytimeProblemLowBattery = NSLocalizedString("anytime.problemLowBattery", tableName: filename, bundle: .main, value: "Transmitter battery is low", comment: "Anytime link problem")
    static let anytimeProblemBindNeverStreamed = NSLocalizedString("anytime.problemBindNeverStreamed", tableName: filename, bundle: .main, value: "Reconnected with a stored key but no data followed", comment: "Anytime link problem")
    static let anytimeProblemNoData = NSLocalizedString("anytime.problemNoData", tableName: filename, bundle: .main, value: "No sensor data while connected", comment: "Anytime link problem")
    static let anytimeProblemHistoryFailed = NSLocalizedString("anytime.problemHistoryFailed", tableName: filename, bundle: .main, value: "History download did not finish", comment: "Anytime link problem")
    static let anytimeProblemSensorRestarted = NSLocalizedString("anytime.problemSensorRestarted", tableName: filename, bundle: .main, value: "The sensor's record counter went back: treated as a new session", comment: "Anytime link problem")

    static func anytimeProblem(_ problem: AnytimeLinkProblem) -> String {
        switch problem {
        case .linkLost: return anytimeProblemLinkLost
        case .notAnAnytime: return anytimeProblemNotAnAnytime
        case .unsupportedFamily: return anytimeProblemUnsupportedFamily
        case .handshakeStalled: return anytimeProblemHandshakeStalled
        case .protocolTimeout: return anytimeProblemProtocolTimeout
        case .checkMalformed: return anytimeProblemCheckMalformed
        case .lowBattery: return anytimeProblemLowBattery
        case .bindNeverStreamed: return anytimeProblemBindNeverStreamed
        case .noData: return anytimeProblemNoData
        case .historyFailed: return anytimeProblemHistoryFailed
        case .sensorRestarted: return anytimeProblemSensorRestarted
        }
    }
}
