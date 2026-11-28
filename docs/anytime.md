# Anytime / Yuwell CGM

xDrip4iOS can read an Anytime (Yuwell) CGM transmitter of the CT2, CT4 or CT5 family directly over
Bluetooth, without the manufacturer's app.

**Nothing in this driver has been compiled, tested or tried on a real sensor.** It is a port of
JugglucoNG's `drivers/anytime` package (GPL-3.0, commit `7a224e159d38726ba527b7db3cef6725fbea367a`)
written without a Swift compiler and without hardware. The unit tests use vectors computed by
running the unchanged Kotlin code on the JVM; they prove the arithmetic and the decision tables, not
the behaviour of a transmitter or of iOS. Expect to find problems; the troubleshooting log (source
"Anytime") is the first place to look.

## Where

Bluetooth → **+** → CGM → **Anytime**. A notice explains the preparation, then **Scan** connects to
the first advertisement whose name belongs to a supported family. Scanning runs in the foreground
only; once a transmitter is known the app reconnects to its address. The device screen shows the
family, Bluetooth name, transmitter version, whether it is bound to this phone, the sensor code (when
one is known), session start, expected end, latest record number, battery, last reading, working and
baseline currents, temperature, counter electrode voltage, and the last link problem.

## Families

The family comes from the advertised name (JugglucoNG `AnytimeRegistry`):

| Family | Name | Service | Values |
| --- | --- | --- | --- |
| CT2 | `SN04…` and the other CT2 prefixes | 16-bit `FFF0` (notify `FFF2`, write `FFF1`) | JugglucoNG's empirical CT-14 model |
| CT4 | `SN72…` to `SN90…` | 128-bit `00001000-1212-efde-1523-785feabcd123` (notify `…1001…`, write `…1002…`) | MK4 chain (`AnytimeCalibrator`) |
| CT5 | `Anytime…` | same 128-bit service, frames encrypted | computed by the transmitter itself |

**Refused:** CT2.5, every CT3 family (CT3, CT3-Plus, CT3-Yuwell, CT3-Ultrasonic) and names the table
does not know. The driver connects, recognises the name, shows "Unsupported family" as the last link
problem and disconnects. Their glucose comes from `AnytimeNativeAlgorithm`, JugglucoNG's 1,000-line
port of a decompiled vendor kernel, which this fork does not carry (see below).

Reading interval is 3 minutes for every family. Warm-up is held back by the driver itself (CT2 60
or 180 minutes depending on the prefix, CT5 40, CT4 60, counted from the sensor's own start); xDrip's
own warm-up is 0 so it does not hide readings twice.

## Before you scan

1. Close the manufacturer's app. A transmitter talks to one phone at a time.
2. Keep other Anytime transmitters out of range: the first connection takes the first supported one.
3. If iOS asks to pair, accept.

## What it does

- **CT5.** `getDate` → `check` → `setID` (`0x30`, with random bytes; the answer carries the session
  cipher key) → `querySSN` (`0x3F`, answers with the sensor code the driver decodes into K and R) →
  `setParameters` (`0x38`) → `init` → streaming. A transmitter that is already bound goes
  `checkID` (`0x31`) → date → streaming. A cached cipher alone goes straight to streaming. Every live
  push (`0x35`) is acknowledged at once. The cipher key and the identity bytes are in the Keychain
  and are never written to a trace.
- **CT2.** `0x48` handshake → ack → `setDate` (`0x54`) → ack → `init` (`0x53`) → ack → streaming.
- **CT4.** `transmitterFormal` (`0x20`; `reset` `0x11` instead when the stored state says it is bound, which
  asks the transmitter to confirm the session; `check` straight away for a sensor code with voltage mode 1) →
  optional `modifyVoltage` → `check` → `setDate` and `init`, both best effort → a 650 ms grace → streaming.
- One write slot with a priority queue (a live acknowledgement goes before a history pull), a
  response must match the request that is waiting for it, a command with no answer in 8 s is a
  protocol timeout and recycles the link, and a handshake that stalls for the reading interval plus
  60 s does the same.
- History: pulls the ids a gap left (`0x08` for one record, `0x22` for a series, `0x37` on CT5),
  de-duplicated by id. CT5 keeps a persisted gap record (pending range, failure snapshot, resolved
  and skipped ids, about 1,500 newest) and repairs a gap over several connections; CT2 and CT4 repair
  forward after init and after a reset, and again whenever the live id jumps (60 records on CT2, 480 on
  CT4). A fresh sensor takes only its 24 most recent records.
- The transmitter sends a record number, never a time, so the timeline starts at the arrival of the first
  live record minus its number times 3 minutes. xDrip starts a sensor from that date once, and again after
  the record counter goes back by more than 48 (treated as a new session, the session state is cleared).
- Watchdogs: no sensor data for 4 reading intervals recycles the link, 3 intervals without a live
  push asks for the latest record, and CT4 checks its telemetry hourly.
- Reconnects wait at most 8 seconds (iOS may suspend the app soon after a disconnect); a failed
  connect counts as a timeout for the back-off, which doubles up to one reading interval.

## What differs from JugglucoNG because of iOS

- No bond-state API, no MTU request, no connect timeout. "Bound" is what the transmitter's own
  answers say; CT5 secrets "held here" means they are in the Keychain.
- The primary service's notification is enabled by the base class; the CT2 `FFF2` notification is
  enabled by the driver, and a 6 s fallback starts the handshake if the confirmation never arrives.
- The identity frames of CT5 (`0x30`, `0x31`, `0x38`, `0x3F`) bypass the base class, which traces
  every received value, and their writes are logged without a payload.
- Per-address state is `AnytimeDeviceState`, a JSON value in UserDefaults (`AnytimeDeviceStore`),
  and the CT5 secrets are one Keychain item per address (`AnytimeCt5SecretStore`, device only, after
  first unlock, never synchronised). Both are removed when the peripheral is deleted.
- Readings go straight to xDrip; JugglucoNG's Room import buffer does not exist here.

## CT5 after the rated life (estimate from current)

A CT5 stops computing glucose when its rated life ends (record 7695, about 16 days) but keeps
reporting the working-electrode current. JugglucoNG learns a current-to-glucose scale from the
transmitter's own output and turns later current into an estimate. In this fork that is a toggle on
the device screen, **Estimate from current after rated life**, **off by default**: the estimates are
stored and shown as ordinary readings (Home, alarms, uploads), only the device screen marks the last
one as estimated.

- JugglucoNG measured 1.5 to 4 % mean absolute relative difference out of sample against the
  transmitter's own value one to two days earlier, from a single sensor's life. That is not a
  clinical accuracy figure.
- The scale is not constant: it climbs early in life, peaks around day 4 and then decays about
  0.9 % per day, so a stale scale drifts low.
- With nothing learned (a sensor first seen after the transmitter stopped), the family default of
  13.3 mg/dL per nA is used. The device screen shows the learned scale and its sample count.
- Only used for ids that are not advancing, never during warm-up, and clamped to 20 to 600 mg/dL.

Do not dose insulin on these values without checking.

## What is not done

Deliberate differences from JugglucoNG. Each one is a gap to close with a real sensor in hand.

- **CT2.5 and the CT3 families** (the native kernel `AnytimeNativeAlgorithm`). It is a decompiled
  port with a documented deviation the author could not reproduce (a `rand()`/`time()` driven
  perturbation) and was never compared with a real CT3 capture. The fork refuses these names
  rather than show a guess; JugglucoNG's linear K/R fallback is ported but never presented as glucose.
- **Fingerstick calibration** (`inputBg`) and the calibration-acceptance UI.
- **Typing or scanning a sensor code.** CT5 gets K and R from its own answer (`querySSN`). A CT4
  has no code on the phone and uses the default factory slope `K0 = 1.13`, so its values are less
  accurate than with the code from the box. A CT2 uses its model without one.
- Reset, unbind and end-cycle commands from the app.
- CT5 credential export and import (`AnytimeCt5CredentialFile`), so a new phone cannot take over a
  bound CT5 without unbinding it first.
- `tryCt4HandshakeFallback`, the service-discovery recovery and the older-history background pass.
- The persisted interrupted-backfill record of CT2 and CT4 (CT5 has its own, ported).
- The periodic telemetry check for CT2 (its pushes carry the battery) and CT5.
- History older than what the gap logic asks for; there is no "download the whole session".
- A device picker. The first connection takes the first matching advertisement.

## Where the code is

| What | Where |
| --- | --- |
| Frames, CT5 cipher, sensor code parser, family table, profiles | `xDrip/BluetoothTransmitter/CGM/Anytime/AnytimeProtocol.swift` |
| Retry, history, clock, raw scale, calibration and trend policies | `xDrip/BluetoothTransmitter/CGM/Anytime/AnytimeSession.swift` |
| CT2 / CT4 / CT5 glucose paths, MK4 calibrator | `xDrip/BluetoothTransmitter/CGM/Anytime/AnytimeAlgorithm.swift` |
| Connection, state store, CT5 secret store, settings, link problems | `xDrip/BluetoothTransmitter/CGM/Anytime/CGMAnytimeTransmitter.swift` |
| Peripheral and Core Data entity | `xDrip/BluetoothPeripheral/CGM/Anytime/`, `xDrip/Core Data/classes/Anytime+*.swift`, model `xdrip v41 Anytime` |
| Device screen, scan notice | `BluetoothPeripheralDetailState.swift` (`makeAnytimeSections`, `scanPreparationNotice`) |
| Strings | `Texts_BluetoothPeripheralView` (`anytime.*`), `xDrip/Storyboards/{en,uk}.lproj/BluetoothPeripheralView.strings` |
| Tests | `xDrip Tests/Anytime{Protocol,Session,Algorithm,Driver}Tests.swift` |

The Core Data entity (`Anytime`, model `xdrip v41 Anytime` = v40 AiDex + this entity) only links to
its `BLEPeripheral`. The type is `BluetoothPeripheralType.anytimeType` (raw value `Anytime`) and
`CGMTransmitterType.anytime` (`NoCalibrator`: the values are the transmitter's or the driver's own).

## Notes for the next driver

On top of the checklists at the end of `docs/ican.md` and `docs/aidex.md`:

- Float arithmetic has to stay in `Float` exactly as in Kotlin, and tests compare
  `Float.floatToIntBits` with `Int32(bitPattern:)`. Kotlin `toInt()` and `roundToInt()` differ from
  Swift's conversions on NaN and at the limits; the helpers `anytimeKotlinInt` and `anytimeKotlinRound`
  carry the Kotlin rules.
- A Kotlin `Handler` maps badly onto a central queue. Delayed work goes through one helper with a
  per-name token plus a connection generation, so a timer of an older connection does nothing.
- `super.` inside an escaping closure does not compile; route it through a private method.
- A commit that adds enum cases without the `BluetoothPeripheralManager` switches does not compile;
  keep the enum commit, the manager wiring and the transmitter in one push.
- Anything that turns a sensor's raw signal into a value past its rated life should be opt-in.
