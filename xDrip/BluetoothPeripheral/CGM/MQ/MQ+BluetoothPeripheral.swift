import Foundation

extension MQ: BluetoothPeripheral {

    func bluetoothPeripheralType() -> BluetoothPeripheralType {
        .mqType
    }
}
