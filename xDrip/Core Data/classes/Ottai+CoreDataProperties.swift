import Foundation
import CoreData

extension Ottai {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Ottai> {
        NSFetchRequest<Ottai>(entityName: "Ottai")
    }

    @NSManaged public var blePeripheral: BLEPeripheral
}
