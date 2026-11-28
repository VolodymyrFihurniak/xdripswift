import Foundation
import CoreData

extension MQ {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<MQ> {
        NSFetchRequest<MQ>(entityName: "MQ")
    }

    @NSManaged public var blePeripheral: BLEPeripheral
}
