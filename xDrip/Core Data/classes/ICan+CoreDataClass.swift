import Foundation
import CoreData

/// iCan (Sinocare) i3/i6 CGM sensor. Everything the driver learns about the sensor is kept per
/// address in `ICanDeviceState` (UserDefaults), so the entity only links to its BLEPeripheral.
public class ICan: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {
        let entity = NSEntityDescription.entity(forEntityName: "ICan", in: nsManagedObjectContext)!
        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(
            address: address,
            name: name,
            alias: alias,
            bluetoothPeripheralType: .iCanType,
            nsManagedObjectContext: nsManagedObjectContext
        )
    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }
}
