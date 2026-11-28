import Foundation
import CoreData

extension AiDex {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<AiDex> {
        NSFetchRequest<AiDex>(entityName: "AiDex")
    }

    @NSManaged public var blePeripheral: BLEPeripheral
}
