import Foundation

extension AiDex: BluetoothPeripheral {

    func bluetoothPeripheralType() -> BluetoothPeripheralType {
        .aiDexType
    }
}
