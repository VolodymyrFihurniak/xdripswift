# iCan (Sinocare) i3 / i6 CGM

xDrip4iOS can read an iCan (Sinocare) i3 or i6 sensor directly over Bluetooth, without the
manufacturer's app, after the sensor has been started.

**Nothing in this driver has been compiled, tested or tried on a real sensor.** It is a port of
JugglucoNG's `drivers/icanhealth` package (GPL-3.0, commit `7a224e159d38726ba527b7db3cef6725fbea367a`,
protocol notes in its `docs/ican-cgm-protocol.md`) written without a Swift compiler and without
hardware. The unit tests use vectors computed with a Python port of the same maths and
JugglucoNG's captured live frames; they prove the arithmetic, not the behaviour of a sensor.
Expect to find problems; the troubleshooting log (source "iCan") is the first place to look.

## Where

Bluetooth → **+** → CGM → **iCan**. A notice explains the preparation, then **Scan** connects to
the first sensor whose name looks like an iCan sensor (`iCGM-…`, `Sinocare …`, `LT…`, or the
`P#########XXX` / `LT######XX` serial forms). Scanning runs in the foreground only. The device
screen shows the model, serial, firmware, authentication state, calibration marker, sensor state,
session start, expected end, last reading and the last link problem.

## Before you scan

1. Start the sensor with the manufacturer's app (this app cannot start a sensor).
2. Close the manufacturer's app. A sensor talks to one phone at a time.
3. Keep other iCan sensors out of range: the first connection takes the first one it finds.
4. A sensor that was never authenticated becomes bound to the user id this app derives from the
   sensor's serial. A sensor already bound to another id answers the first attempt with that id
   (encrypted); the driver adopts it and retries once.

## What it does

- Connects to the CGM service `181F` and Device Information `180A`.
- Derives the key family (old or new firmware generation) from the serial, then runs the vendor
  handshake on `2AAC`: `F3` challenge, `F4` token (AES-128-CBC of the user id), `F6` calibration
  marker.
- Live readings arrive on `2AA7` as 19-byte AES-CBC frames. The glucose value is a 12-bit mantissa
  in hundredths of mmol/L, converted at 18.0182 and accepted between 10 and 551 mg/dL. The first
  minutes of a session are hidden by a warm-up XOR table which the driver removes.
- Missed minutes are fetched from the Record Access Control Point (`2A52`) when the app starts,
  after a gap and after a reconnect. The request reaches back at most 24 hours. The modern
  command prefix is tried first, the legacy one after a refusal, then one retry from the live
  edge.
- The sensor's own readings are delivered as they are (no xDrip calibration; `NoCalibrator`).
  Reading intervals follow the model: 1 minute for the i7 family, 3 minutes for i3, i6, H3, H6 and
  the default.
- The sensor start comes from the session start characteristic (`2AAA`) when it agrees with the
  sensor's minute counter (within 30 minutes), otherwise from the counter itself. xDrip starts a
  sensor automatically from that date.
- A link that delivers no live frame for 210 s is hung up and reconnected.

## What is not done

These are deliberate differences from JugglucoNG. Each one is a gap to close once a real sensor is
available.

- **Vendor cloud** (`ICanHealthCloudCode`) and anything that needs the vendor server
  (provisioning of a sensor that has no calibration code, the native-library rebuild).
- **Finger-stick calibration** (the CE algorithm) and writing a calibration code. The calibration
  marker is only displayed (`0xFFFF` means the sensor holds no factory calibration).
- Battery level, the original-history (raw) RACP phase, the "direct 16-bit glucose" encoding (it is
  parsed and tested, the transmitter never uses it), the 28-day ENDED cap, the persisted
  covered-edge bookkeeping, the sensor `0x1A` start command and the `F2` / `F7` writes.
- History older than 24 hours. JugglucoNG asks for the whole session.
- A device picker. The first connection takes the first matching advertisement, and JugglucoNG's
  broad `^[0-9A-Z]{12,32}$` name rule is deliberately not used (it matches too many devices).
  Entering the serial printed on the box is not supported.
- JugglucoNG's checks for the models `h6-14`, `h6-15` and `h6-7` use a hyphenated, lower-case
  spelling that can never match its own normalised model string. They are ported literally and so
  never match either (a JugglucoNG test asserts `H6-14` resolves to the default profile).
- JugglucoNG chooses the modern or legacy history command from the Android MTU. iOS has no such
  choice, hence the try-modern-then-legacy order above.
- Scanning is not filtered by service (iOS cannot confirm that these sensors advertise `181F`),
  so the first scan works in the foreground only.

## Where the code is

| What | Where |
| --- | --- |
| Protocol maths (keys, AES, frames, history, timeline) | `xDrip/BluetoothTransmitter/CGM/ICan/ICanProtocol.swift` |
| Connection, state store (`ICanDeviceStore`) | `xDrip/BluetoothTransmitter/CGM/ICan/CGMICanTransmitter.swift` |
| Peripheral and Core Data entity | `xDrip/BluetoothPeripheral/CGM/ICan/`, `xDrip/Core Data/classes/ICan+*.swift`, model `xdrip v39 iCan` |
| Device screen, scan notice | `BluetoothPeripheralDetailState.swift` (`makeICanSections`, `scanPreparationNotice`) |
| Tests | `xDrip Tests/ICanProtocolTests.swift` |

The Core Data entity only links to its `BLEPeripheral`. Everything the driver learns about a sensor
(model, serial, authentication result, recovered user id, session start, highest delivered sequence,
last problem) lives in `ICanDeviceState`, a JSON value in UserDefaults keyed by the Bluetooth
address and removed when the peripheral is deleted.

## Adding another driver on top of this branch

The iCan commits touch every place a new CGM needs. For the next driver, mirror them:

1. Core Data: a new model version = latest version + the new entity (never edit a shipped
   version), `.xccurrentversion`, the pbxproj `XCVersionGroup` (file reference and `currentVersion`),
   `<Entity>+CoreDataClass.swift`, `<Entity>+CoreDataProperties.swift`, and the optional cascade
   relationship on `BLEPeripheral`.
2. Enums: `BluetoothPeripheralType` (case, `createNewBluetoothPeripheral`, `category`),
   `CGMTransmitterType` (case plus its `sensorType`, `canDetectNewSensor`,
   `allowManualSensorStart`, battery level and unit), `CGMSensorType`, `ConstantsLog` category.
3. Every exhaustive switch: `AlertKind` battery kind, `BgPostProcessingManager` (adjustment reason
   and connected-peripheral lookup), `LoopManager` (sensor type, source, interval, warm-up),
   `RootApplicationCoordinator` (calibrator and warm-up), `SensorManagementView`, `OnlineHelp`,
   `TroubleshootingLog` (source, both initialisers, name, follower flag), `Trace` (info block),
   `BluetoothPeripheralsViewModel.addFlowPreferredOrder`.
4. `BluetoothPeripheralManager`: the no-op reading list, `getBluetoothTransmitter`,
   `getTransmitterType`, `createNewTransmitter`, the loading loop, the parameter-check list and
   `deleteBluetoothPeripheral` (clear per-address stores).
5. `BluetoothPeripheralDetailState`: the sections switch and, if wanted, the scan notice.
6. Strings: `Texts*.swift` default plus `en.lproj` and `uk.lproj`.
7. pbxproj: a build file, file reference, group child and Sources entry for each new file (tests
   go into the test target's Sources phase).
8. Docs: a `docs/<driver>.md` and a paragraph in `CLAUDE.md`.
