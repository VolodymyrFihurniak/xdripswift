import Foundation
import CoreData

extension Sibionics2 {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Sibionics2> {
        NSFetchRequest<Sibionics2>(entityName: "Sibionics2")
    }

    @NSManaged public var sensorVariant: Int16
    @NSManaged public var blePeripheral: BLEPeripheral
}
