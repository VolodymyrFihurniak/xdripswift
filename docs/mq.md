# MQ / Glutec CGM

xDrip4iOS can follow an MQ / Glutec CGM transmitter directly over Bluetooth, without the
manufacturer's app and **without the manufacturer's online service**. That second part decides what
you get: read "What you need to see a value" before you scan.

**Nothing in this driver has been compiled, tested or tried on a real sensor.** It is a port of
JugglucoNG's `drivers/mq` package (GPL-3.0, commit `7a224e159d38726ba527b7db3cef6725fbea367a`)
written without a Swift compiler and without hardware. The unit tests use vectors computed by
running the unchanged Kotlin code on the JVM (and cross-checked with a small Python port); they
prove the arithmetic and the decision tables, not the behaviour of a transmitter or of iOS. Expect
to find problems; the troubleshooting log (source "MQ") is the first place to look.

**The glucose values have not been compared with a reference.** JugglucoNG's own notes
(`docs/mq-bootstrap-evidence.md` there) record that the scaling of the factory sensitivity was
checked, that packets then gave 3.4 to 4.2 mmol/L, and that this verified the arithmetic but not the
accuracy. They also record an unresolved excursion (see "Accuracy"). Do not dose insulin on these
values without checking.

## Where

Bluetooth → **+** → CGM → **MQ**. A notice explains the preparation, then **Scan** connects to the
first advertisement whose name starts with `Glutec`, `MQ` or `RU-` (any case). Scanning runs in the
foreground only; once a transmitter is known the app reconnects to its address. The device screen
shows the Bluetooth name, session start, expected end (16 days), latest packet number, the raw
battery byte, the last reading, how the glucose is being calculated, the last link problem, the
algorithm inputs and a reset button.

## Before you scan

1. Close the manufacturer's app. A transmitter talks to one phone at a time.
2. Keep other MQ transmitters out of range: the first connection takes the first one it finds.
3. The protocol is not encrypted. If iOS asks to pair, accept.

## What you need to see a value

The transmitter sends a raw sensor current every 3 minutes, never a glucose value. The vendor
algorithm turns it into glucose with a slope K that comes from the **factory sensitivity of the
sensor**. In the official app and in JugglucoNG that sensitivity (and the algorithm version, the
number of packages per session and a multiplier) is fetched from the vendor's server after the
sensor's QR code is scanned. This fork does not talk to that server (see "What is not done"), so
there is no automatic source for them. The fork therefore never shows a value until one of these
exists:

| Path | What you do | When it works |
| --- | --- | --- |
| Sensitivity | Type the sensor's factory sensitivity on the device screen (for example 2.93) **and** choose its scale | From packet 19 (about one hour after the session start) |
| Fingerstick | Use xDrip's ordinary calibration button | After packet 8; a value given earlier is kept for the next packet |

Until one of them exists the transmitter is followed (packets are counted, the session is timed,
the battery byte is shown) and the device screen says "Needs a sensitivity or a fingerstick". The
alternative would be to invent a slope, which would give confident but wrong numbers.

The **scale** matters. The vendor's server tells the official app, per transmitter, whether the
sensitivity printed for the sensor is used as it is or multiplied by ten (then cut to one decimal:
2.93 becomes 29.3). Choosing the wrong one makes every value roughly ten times too high or too
low, so the scale starts as "Not known" and an unknown scale means the typed sensitivity is not
used at all. The fork cannot find the right scale for you.

A fingerstick solves the slope on the spot (JugglucoNG `calibrateSensor`): the value is converted
to the vendor's mmol/L tenths and becomes the reference of the latest packet. Fingersticks outside
40 to 400 mg/dL are ignored. The slope then stays until you change an input or reset the
transmitter. When no value exists yet, the first fingerstick produces one at once. When a value for the
latest packet already exists (for example from a typed sensitivity), the slope is corrected at once
but xDrip treats a second value at the same timestamp as a duplicate, so the corrected value
appears with the next packet.

The other inputs (algorithm version, packages per session, multiplier) start at JugglucoNG's
built-in defaults: version 0, 720 packages, multiplier 1.1. JugglucoNG's traces showed a server
that answered version 1, 720 and multiplier 1.0. The fork has no way to know which your sensor
would get; change them only if you know the values. Changing any input discards the slope solved so
far (the next packets start again from the new values); readings already stored are not rewritten.

## Accuracy

What is verified (by JugglucoNG's notes and by the tests here, which run the unchanged Kotlin): the
unit scaling of the sensitivity (2.93 → 29.3), the first-reference calculation (current 175 minus
offset 2 gives reference 5.9 mmol/L and K 29.32) and the decimal truncation of K and B. This is
source-derived arithmetic, not a measurement against a glucose meter.

What is not:

- No comparison with a paired reference glucose exists, in JugglucoNG or here.
- JugglucoNG recorded a daytime excursion to 32.5 mmol/L while other sensors stayed below 6, with
  the sharp rise already present in the received current bytes. The cause (sensor, missing vendor
  compensation or something else) is unresolved. The vendor's own service has history-dependent
  K/B adjustments (daily windows, calibration events, a packet-260 reference insertion) that
  JugglucoNG did not port and this fork does not carry either.
- The first output after a restart can be wrong when the first reference is wrong; JugglucoNG fixed
  one such defect (the elapsed time was passed where the constant 1 belongs) and the port has the
  fix.
- The battery byte is raw telemetry, not a percentage (the official service compares it with 28 and
  keeps separate display logic). It is shown as the raw number and never reported to xDrip's
  battery alerts.
- The sensor's session can restart without being asked (JugglucoNG saw this with status 147 link
  timeouts); the driver treats `BEGIN_WORK` as a new session.

## What it does

- Connects to the Nordic UART service (`6E400001-…`), notifies on TX (`…0003…`) and writes to RX
  (`…0002…`). Frames are `5A A5 CMD LEN payload CRC-hi CRC-lo` with CRC16-Modbus. Firmware that
  JugglucoNG calls Protocol02 sends other CRC values and two marker frames; **inbound CRC
  mismatches are accepted** (the header and length checks filter noise), and the driver remembers
  that it saw a marker.
- `BEGIN_WORK` (`0x06`): the transmitter just started. A running session is superseded (state
  cleared, the next data announces a new sensor to xDrip), the start is set to now when unknown, and
  the captured "with init" acknowledgement is written. More than five in a row reconnects.
- Heartbeat (`0x01`): flushes a pending burst, arms the no-data watchdog and writes the captured
  "without init" acknowledgement.
- Glucose data (`0x04`): 6-byte records (marker `0x40`, packet number, current, raw battery). Records
  of one burst are keyed by packet, acknowledged at once with the captured "BG data" frame and
  processed together 750 ms later in packet order. A transmitter that replays missed packets after a
  reconnect therefore fills the gap by itself; the driver notes in the troubleshooting log when a
  replay still leaves a hole.
- The acknowledgements are the byte strings the official app was seen sending, not computed CRCs,
  exactly as in JugglucoNG.
- The session start is the time `BEGIN_WORK` was seen, repaired from the packet counter when the
  counter says the sensor is older (a running transmitter's counter survives app restarts: start =
  packet arrival minus packet number times 3 minutes, replacing a stored start that is more than
  two intervals later). A new sensor is announced to xDrip once per session, even before the first
  value, so that xDrip has a sensor for the calibration button to work on. Rated life 16 days.
  xDrip's own warm-up is 0 because the algorithm itself withholds values.
- The vendor algorithm works in mmol/L and clamps to 1.7 to 40.0; a reading is `mmol/L × 18.0182`
  kept to a tenth of a mg/dL. xDrip's calibrator is not used (`NoCalibrator`): the fingerstick is the
  algorithm's reference.
- Watchdogs, as in JugglucoNG for the 3-minute interval, each of which hangs up so that the link is
  rebuilt: connected but no first frame within 3.5 minutes, no frame for 6.5 minutes, and (only once a
  value exists) no value for 12 minutes. A transmitter that is merely waiting for a fingerstick or a
  sensitivity is therefore not reconnected over and over.
- **Reset**: the device screen button sends the reset frame (Modbus form, or the captured Protocol02
  form once a marker was seen), forgets the local session and drops the link 0.7 s later so the
  transmitter starts clean. Needs a connected transmitter. The vendor's `protocolType` (from the
  server) is not known here, so only the observed marker selects the Protocol02 form.
- The device screen's "Last link problem" line names what went wrong last: link lost, not an MQ
  transmitter, notifications could not be switched on, connected but nothing sent, silent for too
  long, no glucose for a long time, `BEGIN_WORK` loop, a command could not be written. A reading
  clears it.

## What differs from JugglucoNG because of iOS or the missing cloud

- iOS has no MAC address. The transmitter is known by its Core Bluetooth identifier; the vendor
  serial (`bleId`) rules are ported (`MQVendorIdentity`) but nothing uses them without the cloud.
- There is no vendor session, report, history or snapshot, so a gap longer than what the transmitter
  replays by itself stays a gap. JugglucoNG fills it from the cloud.
- The learned CRC variant is not kept (JugglucoNG never uses it for anything it sends).
- Each notification is parsed on its own, as JugglucoNG does; a frame split across two
  notifications is rejected.
- Per-address state is `MQDeviceState`, a JSON value in UserDefaults (`MQDeviceStore`); the user's
  inputs are `MQConfiguration` (`MQConfigurationStore`, with a revision counter that bumps only when
  a value really changes). Both are removed when the peripheral is deleted. There is no secret: the
  protocol is not encrypted, so nothing is in the Keychain.
- The first scan has no service filter (the name decides), and iOS delivers such a scan only while the
  app is in the foreground. Once the transmitter is known the app reconnects by address, which also
  works in the background.
- There is no source journal and no replay of old currents when an input changes (the Sibionics
  driver has one); a changed input applies from the next packet.

## What is not done

Deliberate differences from JugglucoNG. Each one is a gap to close with a real sensor in hand.

- **The vendor cloud**: `MQCloudClient`, `MQCloudRecovery`, `MQCloudWorkQueue`,
  `MQFollowerManager` and `MQBootstrapClient` (login, QR lookup, session start, report upload, history
  and snapshot restore, follower). The fork makes no network call to the vendor's servers, so the
  factory sensitivity and the algorithm parameters have to come from you. Their pure timing and
  restore rules (`MQCloudHistoryTiming`, `MQSessionRestorePolicy`, `MQBootstrapHistoryPoint`) are
  ported and tested but nothing calls them.
- **Automatic calibration parity with the vendor service** (the history-dependent K/B adjustments
  mentioned above) and the packet-260 reference insertion.
- The native glucose mirror, the managed-sensor identity adapter and the native sensor removal
  (Android internals).
- A device picker: the first connection takes the first matching advertisement.
- Battery as a percentage, and battery alerts.
- History older than what the transmitter itself replays.

## Where the code is

| What | Where |
| --- | --- |
| Frames, CRC, parser, captured acknowledgements, reset command, vendor identity, profile, name matching | `xDrip/BluetoothTransmitter/CGM/MQ/MQProtocol.swift` |
| Glucose algorithm, decimal truncation, first-reference seed | `xDrip/BluetoothTransmitter/CGM/MQ/MQAlgorithm.swift` |
| Session tracker, burst buffer, policies, configuration, typed numbers | `xDrip/BluetoothTransmitter/CGM/MQ/MQSession.swift` |
| Connection, state and configuration stores, link problems, reset, fingerstick | `xDrip/BluetoothTransmitter/CGM/MQ/CGMMQTransmitter.swift` |
| Peripheral and Core Data entity | `xDrip/BluetoothPeripheral/CGM/MQ/`, `xDrip/Core Data/classes/MQ+*.swift`, model `xdrip v42 MQ` |
| Device screen, scan notice | `BluetoothPeripheralDetailState.swift` (`makeMQSections`, `scanPreparationNotice`) |
| Strings | `Texts_BluetoothPeripheralView` (`mq*`), `xDrip/Storyboards/{en,uk}.lproj/BluetoothPeripheralView.strings` (`mq.*`) |
| Tests | `xDrip Tests/MQ{Protocol,Algorithm,Session,Driver}Tests.swift` |

The Core Data entity (`MQ`, model `xdrip v42 MQ` = v41 Anytime + this entity) only links to its
`BLEPeripheral`. The type is `BluetoothPeripheralType.mqType` (raw value `MQ`) and
`CGMTransmitterType.mq` (`NoCalibrator`; `isWebOOPEnabled()` and `overruleIsWebOOPEnabled()` are
true so xDrip's calibration button reaches `calibrate(calibration:)`). Persisted raw values
(`MQSensitivityScale`, `MQLinkProblem`) are pinned by tests.

## Notes for the next driver

On top of the checklist at the end of `docs/ican.md` and the notes in `docs/aidex.md` and
`docs/anytime.md`:

- `CGMTransmitterDelegate.newSensorDetected(sensorStartDate:)` always stops the active sensor and
  starts a new one. Call it once per new session, never per connection, and announce the session
  before the first value when a calibration has to be possible (xDrip's `canCalibrate` needs an
  active sensor).
- A calibration reaches a direct transmitter only when `overruleIsWebOOPEnabled()` is true and the
  calibrator is `NoCalibrator`; xDrip creates the `Calibration` (`bg` in mg/dL) and calls
  `calibrate(calibration:)`. xDrip's calibration alert view clears `pendingAlert` right after the
  primary action runs, so a result alert has to be shown on the next main-queue turn.
- A reading at a timestamp xDrip already has is dropped as a duplicate.
- Values that exist only after a vendor service has been asked cannot be reproduced offline. State
  the missing path in the code header, the docs and the UI, and give the user an explicit input
  instead of a guess; make an unknown scale or unit withhold the value rather than default.
- Persisted inputs that feed a stateful algorithm want a revision counter that bumps only on a real
  change, so the stored solution is discarded exactly when it stops being valid.
- A long array literal of numbers makes the Swift type checker slow; build it with a typed helper or
  split it. `Data.append(1)` writes eight bytes; use `UInt8(1)`.
- Plain `Float` stored values must be recovered through their decimal text where the Kotlin does
  (`MQAlgorithm.decimalParameter`); the mismatch is a one-cent drift in K that compounds.
- Pbxproj ids of this driver are `3A5D0xxx0000000000000001`; pick another prefix for a new driver.
