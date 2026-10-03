import Foundation

extension Sibionics2: BluetoothPeripheral {

    func bluetoothPeripheralType() -> BluetoothPeripheralType {
        variant.peripheralType
    }
}
