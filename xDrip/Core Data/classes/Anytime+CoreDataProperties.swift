import Foundation
import CoreData

extension Anytime {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Anytime> {
        NSFetchRequest<Anytime>(entityName: "Anytime")
    }

    @NSManaged public var blePeripheral: BLEPeripheral
}
