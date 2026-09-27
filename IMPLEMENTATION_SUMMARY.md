# Sibionics 2 integration

## Device discovery

When adding a Sibionics 2 transmitter, xDripSwift scans for the FF30 service and filters advertisements by the Sibionics 2 name pattern. It displays matching nearby devices with their Bluetooth names and signal levels. Select the intended sensor to connect; the first sensor found is no longer connected automatically.

The scan list includes a name search field. Saved devices reconnect by their stored CoreBluetooth identifier.

## Glucose processing

V120 notifications continue through the Sibionics 2 parser, exact processor, and the existing CGM delivery path. History replay keeps a contiguous processor cursor and persists its target index with the processor snapshot, so replay can continue after an app restart.

The manual factory-code field was removed. Sensitivity is derived from a short code when it is present in the advertised device name; otherwise the existing 1.44 fallback is used. A BLE name may not expose the individual sensor calibration value, so the fallback may not match every sensor.

## Build status

The Actions run 36333986684 failed while compiling the previous discovery/fallback changes. The errors were a non-static canAdoptPeripheral call and an out-of-scope fallback-code symbol. The current changes address those compile errors and add the explicit sensor-selection list. A new Xcode workflow has not been run for this revision.
