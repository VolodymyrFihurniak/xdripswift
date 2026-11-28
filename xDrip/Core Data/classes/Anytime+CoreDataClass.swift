import Foundation
import CoreData

/// Anytime / Yuwell CGM sensor. Everything the driver learns about the sensor is kept per address in
/// `AnytimeDeviceState` (UserDefaults) and the CT5 identity secrets in the Keychain, so the entity only
/// links to its BLEPeripheral.
public class Anytime: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {
        let entity = NSEntityDescription.entity(forEntityName: "Anytime", in: nsManagedObjectContext)!
        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(
            address: address,
            name: name,
            alias: alias,
            bluetoothPeripheralType: .anytimeType,
            nsManagedObjectContext: nsManagedObjectContext
        )
    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }
}
