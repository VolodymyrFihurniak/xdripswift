import Foundation
import CoreData

public class Sibionics2: NSManagedObject {

    init(address: String, name: String, alias: String?, nsManagedObjectContext: NSManagedObjectContext) {
        let entity = NSEntityDescription.entity(forEntityName: "Sibionics2", in: nsManagedObjectContext)!
        super.init(entity: entity, insertInto: nsManagedObjectContext)

        blePeripheral = BLEPeripheral(
            address: address,
            name: name,
            alias: alias,
            bluetoothPeripheralType: .Sibionics2Type,
            nsManagedObjectContext: nsManagedObjectContext
        )
    }

    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
        super.init(entity: entity, insertInto: context)
    }
}
