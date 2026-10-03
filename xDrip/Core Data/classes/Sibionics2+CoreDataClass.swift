import Foundation
import CoreData

public class Sibionics2: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext, variant: SibionicsDeviceVariant = .sibionics2) {
        let entity = NSEntityDescription.entity(forEntityName: "Sibionics2", in: nsManagedObjectContext)!
        super.init(entity: entity, insertInto: nsManagedObjectContext)

        sensorVariant = variant.rawValue
        blePeripheral = BLEPeripheral(
            address: address,
            name: name,
            alias: alias,
            bluetoothPeripheralType: variant.peripheralType,
            nsManagedObjectContext: nsManagedObjectContext
        )
    }

    var variant: SibionicsDeviceVariant {
        SibionicsDeviceVariant(rawValue: sensorVariant) ?? .sibionics2
    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }
}
