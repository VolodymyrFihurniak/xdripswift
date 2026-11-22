import Foundation

class TextsLibreNFC {
    
    static private let filename = "LibreNFC"
    
    static let scanComplete: String = {
        return NSLocalizedString("scanComplete", tableName: filename, bundle: Bundle.main, value: "Sensor scan successful", comment: "after scanning NFC, scan complete message")
    }()

    static let holdTopOfIphoneNearSensor: String = {
        return NSLocalizedString("holdTopOfIphoneNearSensor", tableName: filename, bundle: Bundle.main, value: "Hold the top of your iPhone near the sensor until it stops vibrating.", comment: "when NFC scanning is started, this message will appear")
    }()
    
    static let deviceMustSupportNFC: String = {
        return NSLocalizedString("deviceMustSupportNFC", tableName: filename, bundle: Bundle.main, value: "This iPhone does not support NFC", comment: "Device must support NFC")
    }()
    
    static let deviceMustSupportIOS14: String = {
        return NSLocalizedString("deviceMustSupportIOS14", tableName: filename, bundle: Bundle.main, value: "To connect to Libre 2, this iPhone needs upgrading to iOS14", comment: "Device must support at least iOS 14.0")
    }()
    
    static let donotusethelibrelinkapp: String = {
        return String(format: NSLocalizedString("donotusethelibrelinkapp", tableName: filename, bundle: Bundle.main, value: "Connected to Libre 2.\n\nPlease ensure you have disabled bluetooth permission for the Libre app in your iPhone settings.\n\nIf you don't do this, when you scan with the Libre app you will break the connection between %@ and the Libre 2.\n\nPlease note that there is a %@ minute warm-up period after starting a new Libre 2 before you will get readings.", comment: "After Libre NFC scanning, and after successful bluetooth connection, this message will be shown to explain that he or she should not allow bluetooth permission on the Libre app"), ConstantsHomeView.applicationName, Int(ConstantsMaster.minimumSensorWarmUpRequiredInMinutes).description)
    }()
    
    static let connectedLibre2DoesNotMatchScannedLibre2: String = {
        return String(format: NSLocalizedString("connectedLibre2DoesNotMatchScannedLibre2", tableName: filename, bundle: Bundle.main, value: "You have scanned a new Libre sensor, but %@ has connected to a different sensor.\n\nTo solve this do NOT delete this old sensor just yet. Click 'Disconnect' or 'Stop Scanning', go back to the previous screen and add a new CGM of type Libre 2 and scan the sensor again.\n\n%@ should now try and connect to the new sensor.", comment: "The user has connected to another (older?) Libre 2 with bluetooth than the one for which NFC scan was done, in that case, inform user that he/she should click 'disconnect', add a new CGM sensor and scan again."), ConstantsHomeView.applicationName, ConstantsHomeView.applicationName)
    }()
    
    // nfcErrorRetryScan is no longer used
    static let nfcErrorRetryScan: String = {
        return NSLocalizedString("nfcErrorRetryScan", tableName: filename, bundle: Bundle.main, value: "NFC sensor scan failure.\n\nTry scanning again.", comment: "Sometimes NFC scanning creates errors, retrying solves the problem. This is to explain this to the user")
    }()
        
    static let nfcScanFailedTitle: String = {
        return NSLocalizedString("nfcScanFailedTitle", tableName: filename, bundle: Bundle.main, value: "⚠️ Sensor Scan Failed", comment: "Sensor scan error, title")
    }()
    
    static let nfcScanFailedMessage: String = {
        return NSLocalizedString("nfcScanFailedMessage", tableName: filename, bundle: Bundle.main, value: "Please scan again", comment: "Ask if the user wants to try and scan the sensor again")
    }()
    
    static let nfcScanFailedScanAgainButton: String = {
        return NSLocalizedString("nfcScanFailedScanAgainButton", tableName: filename, bundle: Bundle.main, value: "Scan Again", comment: "Scan again button")
    }()
    
    static let nfcScanSuccessfulTitle: String = {
        return NSLocalizedString("nfcScanSuccessfulTitle", tableName: filename, bundle: Bundle.main, value: "✅ Sensor Scan Successful!", comment: "Sensor scan successful, title")
    }()
    
    static let nfcScanSuccessfulMessage: String = {
        return NSLocalizedString("nfcScanSuccessfulMessage", tableName: filename, bundle: Bundle.main, value: "Click OK and just wait to allow the Libre sensor to finish connecting via bluetooth.\n\nIn a short while the status should change to 'Connected'.", comment: "Tell the user the scan was successful and to just wait now for connection")
    }()
    
    static let nfcErrorMessageScanErrorRetrying: String = {
        return NSLocalizedString("nfcErrorMessageScanErrorRetrying", tableName: filename, bundle: Bundle.main, value: "Sensor scan error\n\nRetrying... # ", comment: "Tell the user the scan has failed and we're retrying several times")
    }()
    
    static let nfcErrorMessageScanFailed: String = {
        return NSLocalizedString("nfcErrorMessageScanFailed", tableName: filename, bundle: Bundle.main, value: "Sensor scan has failed", comment: "Tell the user the scan has failed and we're retrying several times")
    }()

    static let activationHoldNearSensor: String = {
        return NSLocalizedString("activationHoldNearSensor", tableName: filename, bundle: Bundle.main, value: "Hold the top of your iPhone near the new sensor until it stops vibrating.", comment: "Libre sensor activation")
    }()

    static let activationUnsupportedType: String = {
        return NSLocalizedString("activationUnsupportedType", tableName: filename, bundle: Bundle.main, value: "This sensor cannot be activated here.", comment: "Libre sensor activation")
    }()

    static let activationReadFailed: String = {
        return NSLocalizedString("activationReadFailed", tableName: filename, bundle: Bundle.main, value: "The sensor could not be read. Nothing was changed. Try again.", comment: "Libre sensor activation")
    }()

    static let activationUseLibre3: String = {
        return NSLocalizedString("activationUseLibre3", tableName: filename, bundle: Bundle.main, value: "This is a Libre 3 sensor: start it from Add CGM > Libre 3.", comment: "Libre sensor activation")
    }()

    static let activationAlreadyStartedShort: String = {
        return NSLocalizedString("activationAlreadyStartedShort", tableName: filename, bundle: Bundle.main, value: "This sensor is already started.", comment: "Libre sensor activation")
    }()

    static let activationFailed: String = {
        return NSLocalizedString("activationFailed", tableName: filename, bundle: Bundle.main, value: "The sensor did not start. Try again.", comment: "Libre sensor activation")
    }()

    static let activationSucceededShort: String = {
        return NSLocalizedString("activationSucceededShort", tableName: filename, bundle: Bundle.main, value: "Sensor activated.", comment: "Libre sensor activation")
    }()

    static let activationSectionTitle: String = {
        return NSLocalizedString("activationSectionTitle", tableName: filename, bundle: Bundle.main, value: "Sensor activation", comment: "Libre sensor activation")
    }()

    static let activationRow: String = {
        return NSLocalizedString("activationRow", tableName: filename, bundle: Bundle.main, value: "Activate a new sensor", comment: "Libre sensor activation")
    }()

    static let activationInProgress: String = {
        return NSLocalizedString("activationInProgress", tableName: filename, bundle: Bundle.main, value: "Scanning…", comment: "Libre sensor activation")
    }()

    static let activationFooter: String = {
        return NSLocalizedString("activationFooter", tableName: filename, bundle: Bundle.main, value: "Starts a new FreeStyle Libre 1, Libre 2 or Libre 2 Plus (EU) sensor by NFC, without the Libre app. Libre 2 sensors from the US and some other regions (Gen2) cannot be activated here; Libre 3 is started from its own setup. A sensor that is already running is left alone.", comment: "Libre sensor activation")
    }()

    static let activationConfirmTitle: String = {
        return NSLocalizedString("activationConfirmTitle", tableName: filename, bundle: Bundle.main, value: "Activate the sensor?", comment: "Libre sensor activation")
    }()

    static let activationConfirmMessage: String = {
        return NSLocalizedString("activationConfirmMessage", tableName: filename, bundle: Bundle.main, value: "Apply the sensor first. Activation starts its wear period and a 60-minute warm-up, and cannot be undone. The Libre app will not know this sensor.", comment: "Libre sensor activation")
    }()

    static let activationConfirmButton: String = {
        return NSLocalizedString("activationConfirmButton", tableName: filename, bundle: Bundle.main, value: "Activate", comment: "Libre sensor activation")
    }()

    static let activationSucceededTitle: String = {
        return NSLocalizedString("activationSucceededTitle", tableName: filename, bundle: Bundle.main, value: "Sensor activated", comment: "Libre sensor activation")
    }()

    static let activationSucceededMessage: String = {
        return NSLocalizedString("activationSucceededMessage", tableName: filename, bundle: Bundle.main, value: "%@ %@ has started and is warming up for 60 minutes.", comment: "Libre sensor activation")
    }()

    static let activationSucceededConnectHint: String = {
        return NSLocalizedString("activationSucceededConnectHint", tableName: filename, bundle: Bundle.main, value: "Now connect it: tap Connect and scan the sensor once more.", comment: "Libre sensor activation")
    }()

    static let activationSucceededBridgeHint: String = {
        return NSLocalizedString("activationSucceededBridgeHint", tableName: filename, bundle: Bundle.main, value: "Readings arrive through the transmitter after the warm-up.", comment: "Libre sensor activation")
    }()

    static let activationConnectButton: String = {
        return NSLocalizedString("activationConnectButton", tableName: filename, bundle: Bundle.main, value: "Connect", comment: "Libre sensor activation")
    }()

    static let activationAlreadyStartedTitle: String = {
        return NSLocalizedString("activationAlreadyStartedTitle", tableName: filename, bundle: Bundle.main, value: "Already started", comment: "Libre sensor activation")
    }()

    static let activationAlreadyStartedMessage: String = {
        return NSLocalizedString("activationAlreadyStartedMessage", tableName: filename, bundle: Bundle.main, value: "This sensor is not new (state: %@). Nothing was sent to it.", comment: "Libre sensor activation")
    }()

    static let activationNotPossibleTitle: String = {
        return NSLocalizedString("activationNotPossibleTitle", tableName: filename, bundle: Bundle.main, value: "Cannot activate", comment: "Libre sensor activation")
    }()

    static let activationUnsupportedLibre3Message: String = {
        return NSLocalizedString("activationUnsupportedLibre3Message", tableName: filename, bundle: Bundle.main, value: "This is a Libre 3 sensor. Start it from Add CGM > Libre 3 > Start a new sensor.", comment: "Libre sensor activation")
    }()

    static let activationUnsupportedGen2Message: String = {
        return NSLocalizedString("activationUnsupportedGen2Message", tableName: filename, bundle: Bundle.main, value: "This Libre 2 sensor uses Abbott's second-generation security (sold in the US and some other regions). It can only be activated with Abbott's own software.", comment: "Libre sensor activation")
    }()

    static let activationUnsupportedUSMessage: String = {
        return NSLocalizedString("activationUnsupportedUSMessage", tableName: filename, bundle: Bundle.main, value: "Libre 14-day sensors from the US cannot be activated here.", comment: "Libre sensor activation")
    }()

    static let activationUnsupportedProMessage: String = {
        return NSLocalizedString("activationUnsupportedProMessage", tableName: filename, bundle: Bundle.main, value: "Libre Pro sensors cannot be activated here.", comment: "Libre sensor activation")
    }()

    static let activationUnsupportedUnknownMessage: String = {
        return NSLocalizedString("activationUnsupportedUnknownMessage", tableName: filename, bundle: Bundle.main, value: "This is not a sensor type xDrip4iOS can activate.", comment: "Libre sensor activation")
    }()

    static let activationUnreadableMessage: String = {
        return NSLocalizedString("activationUnreadableMessage", tableName: filename, bundle: Bundle.main, value: "The sensor's state could not be read reliably, so nothing was sent. Hold the phone still and try again.", comment: "Libre sensor activation")
    }()

    static let activationFailedMessage: String = {
        return NSLocalizedString("activationFailedMessage", tableName: filename, bundle: Bundle.main, value: "The sensor did not report a start. Scan again: a sensor that did start is left alone, a new one is activated.", comment: "Libre sensor activation")
    }()
}
