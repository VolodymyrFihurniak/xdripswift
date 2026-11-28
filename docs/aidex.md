# AiDex X / LinX CGM

xDrip4iOS can read an AiDex X or LinX sensor (including rebrands such as LUMI) directly over Bluetooth, without the manufacturer's app. The same driver also starts a sensor
that has not been started yet.

**Nothing in this driver has been compiled, tested or tried on a real sensor.** It is a port of
JugglucoNG's `drivers/aidex` package (GPL-3.0, commit `7a224e159d38726ba527b7db3cef6725fbea367a`)
written without a Swift compiler and without hardware. The unit tests use vectors computed by
running the unchanged Kotlin code on the JVM (and cross-checked with a small Python port); they
prove the arithmetic and the decision tables, not the behaviour of a sensor or of iOS. Expect to
find problems; the troubleshooting log (source "AiDex") is the first place to look.

## Where

Bluetooth → **+** → CGM → **AiDex**. A notice explains the preparation, then **Scan** connects to
the first sensor whose name looks like an AiDex sensor (`AiDEX…`, `LinX…`, `CGM…`, `Smart-…`,
`IndiaX-…`, `VitaTok-…`, or a name that carries an `X-…` serial). Scanning runs in the foreground
only; once a sensor is known the app reconnects to that sensor's address. The device screen shows
the model, serial, firmware, hardware, rated wear time, whether a pairing key is stored, session
start, expected end, battery voltage, last reading and the last link problem.

## Before you scan

1. Close the manufacturer's app. A sensor talks to one phone at a time.
2. Keep other AiDex sensors out of range: the first connection takes the first one it finds.
3. When iOS asks to pair with the sensor, accept. The first characteristic the driver touches
   (`F001`) needs an encrypted link, so iOS pairs on access. A declined or dismissed prompt counts
   as a failed key exchange (see below).
4. **F-series sensors (advertised as `AiDEX F-…`) are not supported.** They get sensor-specific
   pairing keys from the manufacturer's cloud, and this app does not use that service. The driver
   recognises them, does not try the serial-derived key and shows "F-series sensor: needs a
   manufacturer's cloud key, not supported" as the last link problem.

## What it does

- Connects to the CGM service `181F` (vendor characteristics `F001`, `F002`, `F003`, plus the
  standard Session Start Time `2AAA` and Session Run Time `2AAB`) and to Device Information `180A`
  (model, software revision, manufacturer).
- Derives the secret and the IV from the sensor serial (MD5 of the serial bytes mapped with
  `b*13+61` and `b*17+19`), writes the challenge to `F001` and receives the PAIR key as a
  notification. It then reads the 17-byte BOND vector from `F002`, decrypts it with the PAIR key
  and the serial IV and checks its CRC-8/MAXIM; the result is the session key for AES-128-CFB.
- Sends the startup control writes, then the encrypted device-info command (`0x10`, with retries),
  and subscribes to live frames on `F003`. Live frames are 17 bytes (AES-CFB, CRC-16 trailer); 5-byte
  frames carry the battery voltage; 13-byte notifications carry calibration records and are ignored.
- Resolves the minute offset of each live frame against the sensor's history range (`AiDexLiveOffset`)
  so that a reading is stored at the time the sensor measured it.
- Downloads missed minutes with `0x22` (range), `0x23` (raw ADC pages, cached) and `0x24`
  (calibrated pages, merged with the cache), page by page with a 25 s timeout, a persisted cursor
  and a window of at most 24 hours. The first download starts when the live stream has delivered a
  frame, or after 65 s without one.
- Takes the sensor start from `2AAA` and the run time, corrected from the minute offsets; xDrip
  starts a sensor automatically from that date. A sensor that shows no session is activated once
  (`0x20` with the local start time and time zone in quarter hours), and no second activation is sent
  within 10 minutes.
- The sensor's own factory-calibrated readings are delivered as they are (no xDrip calibration;
  `NoCalibrator`). Readings arrive every minute. Rated wear time comes from the sensor, 15 days until
  it has reported one. Warm-up is 0, as in JugglucoNG.
- Watchdogs: 80 s without a live frame while connected (first the `F002`/`F003` notifications are
  switched off and on, then the link is recycled), 5 minutes without any frame at all.
- Key exchange failures follow `AiDexKeyExchangePolicy`: a stored key is tried first and a failed
  exchange is retried on a clean link (3 s, 6 s, then the third failure ends the series). After the
  third failure a phone that holds a stored key asks the sensor for a new one on the next connection;
  otherwise the driver waits 15 minutes (a stored key was refused) or 5 minutes (no key) before it
  reconnects.

## What differs from JugglucoNG because of iOS

- iOS has no bond-state API and does not let the app trigger pairing. "Paired here" therefore means
  "a PAIR key is stored for this sensor"; the encrypted link is created by iOS when `F001` is first
  written.
- The PAIR key is kept in the Keychain (`AiDexPairKeyStore`, service `<bundle id>.aidex`, account
  `pairKey.<address>`, available after first unlock, this device only) and not in UserDefaults.
  Everything else the driver learns (serial, model, firmware, wear time, session start, history
  cursors, last problem) is `AiDexDeviceState`, a JSON value in UserDefaults keyed by the Bluetooth
  address (`AiDexDeviceStore`). Both are removed when the peripheral is deleted.
- The post-bond configuration write on `F001` that JugglucoNG performs is skipped: the same `0x10`
  command is sent on `F002`, where it is already encrypted.
- The base transmitter class traces every received value; `F001` values (key material) bypass it and
  are never written to the trace.
- A cooldown is a delayed reconnect (iOS has no scan or connect throttle API to lean on).

## What is not done

These are deliberate differences from JugglucoNG. Each one is a gap to close once a real sensor is
available.

- **The manufacturer's China-mainland cloud key endpoint** (`AiDexCnCloudClient`) is not ported, on
  purpose: it needs a spoofed `X-Forwarded-For` header and talks to a service this app has no
  agreement with. Consequently F-series sensors and anything else that needs provisioned pairing
  material (`AiDexProvisioningStore`, `AiDexPairingMaterialFile`, `AiDexSetupKeyGate`) cannot be
  used.
- Default-parameter provisioning (`0x30`), the wear-profile catalogue and wear-profile extras.
- The broadcast scan payload parser and the connected broadcast command (`0x11`), and the BLE
  continuity sync that merges broadcasts with a link.
- Blood-glucose calibration (`0x25`..`0x27` are parsed, never sent), BloodControl and the retained
  calibration.
- The adaptive algorithm (Adaptive V2) and the algorithm controller: the sensor's own value is used.
- The skin temperature sidecar (`AiDexTemperatureStore`).
- Resetting or unpairing from the app. To pair with a sensor again, remove the pairing in iOS
  Bluetooth settings and delete the peripheral here.
- Backup or export of the PAIR key. A new phone pairs afresh.
- History older than 24 hours. JugglucoNG asks for the whole session.
- A device picker. The first connection takes the first matching advertisement.

## Where the code is

| What | Where |
| --- | --- |
| Protocol maths (serial crypto, CRCs, AES-CFB, key exchange, command builder, parsers, history merge, policies) | `xDrip/BluetoothTransmitter/CGM/AiDex/AiDexProtocol.swift` |
| Connection, state store (`AiDexDeviceStore`), PAIR key store (`AiDexPairKeyStore`), link problems | `xDrip/BluetoothTransmitter/CGM/AiDex/CGMAiDexTransmitter.swift` |
| Peripheral and Core Data entity | `xDrip/BluetoothPeripheral/CGM/AiDex/`, `xDrip/Core Data/classes/AiDex+*.swift`, model `xdrip v40 AiDex` |
| Device screen, scan notice | `BluetoothPeripheralDetailState.swift` (`makeAiDexSections`, `scanPreparationNotice`) |
| Strings | `Texts_BluetoothPeripheralView` (`aidex.*`), `xDrip/Storyboards/{en,uk}.lproj/BluetoothPeripheralView.strings` |
| Tests | `xDrip Tests/AiDexProtocolTests.swift` |

The Core Data entity (`AiDex`, model `xdrip v40 AiDex` = v39 iCan + this entity) only links to its
`BLEPeripheral`. The type is `BluetoothPeripheralType.aiDexType` (raw value `AiDex`) and
`CGMTransmitterType.aiDex`.

## Notes for the next driver

On top of the checklist at the end of `docs/ican.md`:

- Generate test vectors by running the unchanged reference code (a throw-away Kotlin JVM project
  that depends on the copied sources) and cross-check them with a Python port; never type an
  expected value by hand.
- `BluetoothTransmitter` only enables notifications on the receive characteristic and traces every
  value it receives. Secrets must be handled in an override that does not call `super`, and
  closures that need `super` must go through a private helper (`super.` inside an escaping closure
  does not compile).
- `tools/check_swift.py` without file arguments only inspects files changed against `origin/master`;
  pass explicit paths for untracked files.
- A commit that adds enum cases but not yet the `BluetoothPeripheralManager` switches does not
  compile; keep the Core Data and enum commit and the transmitter wiring commit in one push.
- New peripheral strings live in `xDrip/Storyboards/{en,uk}.lproj/BluetoothPeripheralView.strings`,
  not in `Localizable.strings`.
