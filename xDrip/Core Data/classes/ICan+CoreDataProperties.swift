import Foundation
import CoreData

extension ICan {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ICan> {
        NSFetchRequest<ICan>(entityName: "ICan")
    }

    @NSManaged public var blePeripheral: BLEPeripheral
}
