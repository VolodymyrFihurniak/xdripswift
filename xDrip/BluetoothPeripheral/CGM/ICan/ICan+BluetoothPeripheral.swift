import Foundation

extension ICan: BluetoothPeripheral {

    func bluetoothPeripheralType() -> BluetoothPeripheralType {
        .iCanType
    }
}
