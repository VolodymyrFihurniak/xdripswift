# Sibionics 2 troubleshooting

## Add a sensor

1. Open Devices and add Sibionics 2.
2. Start scanning and keep the iPhone near the sensor.
3. Choose the matching nearby sensor by its Bluetooth name and signal level.
4. Keep the app open while it connects and requests readings.

Only advertisements that match the Sibionics 2 name pattern and FF30 service are listed. If the list stays empty, confirm Bluetooth is enabled, move the iPhone closer, and restart the scan.

## Connected, but no glucose

Check the Sibionics 2 device logs for FF31 notifications, handshake responses, parsed reading indices, and the reading processor cursor. The saved cursor advances only through contiguous history so the exact algorithm can replay missing minutes. The replay target is saved with the processor state and restored after an app restart.

Sensitivity is inferred from a short code when the BLE name contains one. If the name does not carry that value, xDripSwift uses the existing 1.44 fallback. Some sensors may have a different individual sensitivity; verify displayed values against the sensor official reader during testing.
