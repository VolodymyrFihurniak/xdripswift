import Foundation
import CoreData

/// MQ / Glutec CGM sensor. Everything the driver learns about the sensor is kept per address in
/// `MQDeviceState` (UserDefaults), so the entity only links to its BLEPeripheral.
public class MQ: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {
        let entity = NSEntityDescription.entity(forEntityName: "MQ", in: nsManagedObjectContext)!
        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(
            address: address,
            name: name,
            alias: alias,
            bluetoothPeripheralType: .mqType,
            nsManagedObjectContext: nsManagedObjectContext
        )
    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }
}
