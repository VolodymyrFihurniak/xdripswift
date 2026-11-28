import Foundation

extension Anytime: BluetoothPeripheral {

    func bluetoothPeripheralType() -> BluetoothPeripheralType {
        .anytimeType
    }
}
