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

## FF31 acknowledges the request but no readings arrive

A V120 `FF31 response=8` confirms the command exchange, not glucose delivery. If the link drops and repeats without any `FF31 readings` log entry, open the saved Sibionics 2 device and enter its **Bluetooth address** from a trusted Android device log. This is the six-byte BLE MAC (for example `C7:71:B0:D1:5B:32`), not the sensor serial, the iPhone peripheral UUID, or the factory sensitivity. Saving the address reconnects automatically and uses it in the next authentication packet; clearing it restores the zero-address fallback. The address is specific to that device and is removed when the device is deleted.

For a controlled comparison, pause the Android app's sensor connection while the iPhone connects. Export a trace that includes `authentication address source`, `FF31 response`, and the first `FF31 readings` or the next disconnect. The sensor session and calibration screen remain empty until valid readings reach the CGM pipeline. If readings arrive but the exact stock algorithm still requests early history, let the history replay continue; the factory sensitivity setting is separate from Bluetooth authentication.
