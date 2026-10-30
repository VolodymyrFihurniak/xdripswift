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

## Authentication retries

FF32 commands use acknowledged writes whenever the characteristic supports them. The 26-byte V120 authentication packet is longer than the default 20-byte BLE payload, and iOS only splits acknowledged writes, so an unacknowledged auth packet can be lost without an error.

If authentication draws no response within 5 seconds, the next registration key group is tried, as in JugglucoNG: Sibionics 2 tries the Eco key first, then the EU (Sijoy) and Hematonix keys; Sibionics 1 starts with the EU key. The trace logs the key group with `authentication address source`. A later handshake step that is not answered within 15 seconds restarts authentication, up to twice per connection. When the sensor sends the plain V120 authentication marker, a new handshake is started.

## Automatic Bluetooth address

iOS does not expose a peripheral's BLE MAC address, and the private CoreBluetooth selectors used earlier are absent on current iOS versions, so detection always fell back to the zero address. The address is now collected from sources a sensor can publish:

- the advertisement manufacturer data, after its 2-byte company identifier, in both byte orders;
- the Device Information System ID (`2A23`) when it is built from the address with an inserted `FFFE`;
- the Device Information serial number (`2A25`). Sibionics 2 publishes the six raw address bytes there, least significant first: `32 5B D1 B0 71 C7` is address `C7:71:B0:D1:5B:32`.

Authentication waits up to 3 seconds for Device Information so the published address is used in the first session.

The sensor accepts any address at authentication, so these values are unverified candidates. Each connection tries one: the detected address first, then the candidates, then the zero address. A connection that ends without glucose readings moves to the next candidate; the first one that produces readings is saved as the detected address and shown as such on the device screen. A manual **Bluetooth address** always takes priority and is never rotated.

If detection still fails, export a trace and look for `advertisement manufacturer data`, `device information 2A23`/`2A25` and `authentication address source`. Those lines show what the sensor publishes, which is needed to add another source.
