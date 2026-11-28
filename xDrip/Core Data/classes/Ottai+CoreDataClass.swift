import Foundation
import CoreData

/// Ottai / Syai CGM sensor. Everything the driver learns about the sensor is kept per address in
/// `OttaiDeviceState` and `OttaiMaterialsStore` (UserDefaults / Keychain), so the entity only links to
/// its BLEPeripheral.
public class Ottai: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {
        let entity = NSEntityDescription.entity(forEntityName: "Ottai", in: nsManagedObjectContext)!
        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(
            address: address,
            name: name,
            alias: alias,
            bluetoothPeripheralType: .ottaiType,
            nsManagedObjectContext: nsManagedObjectContext
        )
    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }
}
