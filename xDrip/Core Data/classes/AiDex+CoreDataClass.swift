import Foundation
import CoreData

/// AiDex X / LinX CGM sensor. Everything the driver learns about the sensor is kept per address in
/// `AiDexDeviceState` (UserDefaults) and the PAIR key in the Keychain, so the entity only links to its
/// BLEPeripheral.
public class AiDex: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {
        let entity = NSEntityDescription.entity(forEntityName: "AiDex", in: nsManagedObjectContext)!
        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(
            address: address,
            name: name,
            alias: alias,
            bluetoothPeripheralType: .aiDexType,
            nsManagedObjectContext: nsManagedObjectContext
        )
    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }
}
