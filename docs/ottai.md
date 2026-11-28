# Ottai / Syai CGM

xDrip4iOS can follow an Ottai (and Syai) CGM sensor directly over Bluetooth, without the
manufacturer's app and **without the manufacturer's online service**. That second part decides what
you get: read "The sensor material" before you scan. Without it the sensor is shown as unsupported.

**Nothing in this driver has been compiled, tested or tried on a real sensor.** It is a port of
JugglucoNG's `drivers/ottai` package (GPL-3.0, commit `7a224e159d38726ba527b7db3cef6725fbea367a`)
written without a Swift compiler and without hardware. The unit tests use vectors computed by
running the unchanged Kotlin code on the JVM (a harness holding verbatim copies of the Kotlin
functions, with the Android calls replaced); they prove the arithmetic and the decision tables, not
the behaviour of a sensor or of iOS. The small helpers in `OttaiDriverTests` (poll interval, lifetime
decoding, watchdog threshold) were checked with a Python mirror instead. Expect to find problems; the troubleshooting log (source
"Ottai") is the first place to look.

**Do not dose insulin on these values without checking.** The glucose value is computed on the phone
from the sensor's raw current with an expression and coefficients that the vendor issues per sensor;
whether this reproduces the vendor's own numbers has never been compared with a reference here.

## Where

Bluetooth → **+** → CGM → **Ottai**. The add screen has a **Sensor material** section: import the
material first (see below), then tap **Scan**. A notice explains the preparation. Scanning runs in the
foreground only and connects to the first advertisement whose name contains `ottai` (any case) and
which has not been rejected before. Once a sensor is known the app reconnects to its address.

The device screen shows the Bluetooth name, the sensor state (not activated, running, ended), the
session start and expected end, the lifetime the sensor itself reported, the sensor temperature, the
last reading and the last link problem, and a second section for the sensor material (import from the
clipboard, remove).

## Before you scan

1. Close the manufacturer's app. A sensor talks to one phone at a time.
2. The sensor has to be **activated** already. This driver does not activate a sensor (see "What is not
   done"); use the manufacturer's app for that, then close it.
3. Import the sensor material of that sensor.
4. Keep other Ottai sensors out of range if you can. The first connection checks the sensor's
   signature against the imported material and drops a sensor that does not match (see "A sensor that
   is not yours").

## The sensor material

The sensor does not send glucose. It sends an electrode current and a temperature, encrypted with a
session key. Two things are needed to turn that into a value, and **neither can be computed on the
phone**:

- the six 16-byte authentication keys (`keyAHex`, 192 hex digits) that let the app prove itself to
  the sensor and check the sensor's own signature, and
- the glucose expression and its coefficients (`method`, `coefficient`) that turn a current into
  mmol/L.

The vendor's online service issues both to the account that owns the sensor. JugglucoNG fetches them
after a login. This fork never contacts that service, never logs in to it and never will: nothing
about the vendor's login, request signing, network security or regional endpoints is ported (see
"What is not done"). So there is no automatic source, and the fork does not guess.

What it does instead: you import the **sensor material**, the portable JSON that JugglucoNG exports
for a sensor (format version 1). It is read from the clipboard. The fields the fork uses:

| Field | Meaning |
| --- | --- |
| `sensorId` | The 12 hexadecimal digits printed on the sensor's box. They sign the handshake. Required |
| `keyAHex` | The six authentication keys, 192 hex digits. Required |
| `method`, `coefficient` | The glucose expression and its coefficients. Without them no value can be computed (the import says so) |
| `displayName` | A name; optional |
| `activeTimeMs` | The activation time (epoch milliseconds, or seconds when 10 digits or fewer); optional, learned from the stream when missing |
| `activeExpireTimeMs`, `acceptedMaxActiveMs` | The rated lifetime; optional (15 days when unknown) |
| `deviceVersion` | Firmware text; optional |

Other fields JugglucoNG writes (`bleAddress`, calibration values, retain and preheat times, `deviceId`)
are ignored. Import fails with a plain message when the text is not JSON, has no sensor id, the id is
not 12 hexadecimal digits, or the keys are not valid.

Where the material comes from is your business: it belongs to the vendor account that owns the
sensor, and it is as sensitive as a password for that sensor. The fork keeps it in this device's
**Keychain** only (accessible after the first unlock, this device only, never synchronised), never in
UserDefaults, never in app backups and never in a trace or the Activity Log. While adding a sensor it
is stored as a "pending" item; the first signature that matches moves it to the sensor's own item.
Deleting the peripheral deletes the item.

## What it does

- **Services**: Device Information `180A` (current time `2A2B`, lifetime `B8FD9848…`, CGM info
  `CB627922…`), CGM `181F` (live read/notify `2AA7`, history request `CCECB015…`, history notify
  `69E4F45F…`, command status `D78D0706…`) and the authentication service `E06E1D43…`
  (device parameter `86805092…`, app parameter `1756EF6E…`, signature `785022C6…`).
- **Handshake ("BLE Auth V2")**: read the device time and the device parameter (key index, device
  time, the sensor's secp256r1 public key), read the sensor's signature and **verify it against the
  key the sensor named**, generate an app key pair, write the app parameter (`index || time3 || pubX ||
  pubY`) and the app signature (`SHA-256(key || sensorId || pubX || pubY || time3)`), then derive the
  session key from the ECDH shared secret. Payloads are AES-ECB with zero padding. The private key
  lives in memory for one handshake.
- **A sensor that is not yours**: the first connection to an address that fails the signature check
  (or has none of the three services) is **rejected**: the address is remembered (at most 20), the
  state says so, and the app never connects to it again until you import other material (which
  forgives the rejection). A sensor that matched before and fails once is only noted; JugglucoNG does
  the same, the sensor's own check decides.
- **Command status** (`D78D0706…`): 0 to 2 means the sensor is not activated (the driver notes it,
  hangs up and tries again in 5 minutes), 3 means running, 4 and above means ended (hangs up, tries
  again in 30 minutes, nothing is published). Without material the app does not touch the radio and
  looks again after a minute.
- **Live value**: a read of `2AA7` shortly after the command status, then every 60 seconds (the sensor
  can ask for another interval in its CGM info; the app keeps it for the next connection). The same
  characteristic also notifies; notifications and reads are both decrypted with the session key.
- **Records**: 8 or 9 byte records (the width is learned from the frames and kept) become 12-byte
  parser records: counter, current, temperature. A record is dated from its **counter** (one per
  minute) against a stream clock that is corrected from the arrival time, not from the arrival time
  itself, so history and live values share one timeline.
- **The pipeline** (the same gates as JugglucoNG): a counter too far ahead of the stream clock is
  dropped, the first ten minutes after activation are decoded but never published, the glucose
  expression is evaluated by a small stack machine (the standard 14-coefficient expression is used
  when only coefficients exist), and the output gate refuses glucose above 40 mmol/L, a raw current
  below 1000 and a temperature outside 15 to 45 °C. A continuity gate also refuses a one-minute point
  that moves by 1.5 mmol/L or more while the current jumps by 18 % or more; after three refusals in a
  row it yields and re-baselines on the next sample, so a genuine level change is not refused for good.
  Readings are one per minute.
- **History gap fill**: one request after the first connection (the last day at most when nothing is
  stored, otherwise everything after the last stored counter), then a request when a live record shows
  that counters were skipped. Chunks of 270 records, 0.75 s apart, a 12 s page timeout, three retries;
  at most eight gaps are queued. A window the sensor does not deliver is given up, not remembered.
- **Watchdogs**: no progress for 90 s while setting up, or no frame for three poll intervals while
  streaming (at least three minutes), hangs up so that the link is rebuilt. No reading 5 minutes after
  streaming started only notes a link problem (no readings, or no usable expression).
- **A new session** is announced to xDrip (`newSensorDetected`) once per session, when the start moved
  by more than an hour. xDrip's own warm-up is 0 because the pipeline withholds the first ten minutes.
- The device screen's "Last link problem" line names what went wrong last (link lost, not an Ottai
  sensor, no material, sensor does not match the material, signature mismatch, notifications could not
  be switched on, setup timeout, a read failed, handshake rejected, session key failed, not activated,
  ended, state unreadable, silent, no readings, frames could not be decrypted, no usable expression).
  A reading clears it.

## What differs from JugglucoNG because of iOS or the missing cloud

- **No MAC address.** The peripheral is known by its Core Bluetooth identifier. The 12-digit sensor id
  that signs the handshake comes from the imported material, so a sensor can only be used with the
  material of that sensor.
- **No bond-state API.** JugglucoNG decides on some steps from the bond state; iOS has no such call, so
  those decisions use what the sensor answers instead.
- **A read and a notification of `2AA7` look the same** in Core Bluetooth (both arrive as an updated
  value). A counter of reads in flight decides: a value that arrives while a read is outstanding counts
  as that read's answer. A notification that arrives at the same moment can be taken for a read; the
  frame is decrypted and recorded the same either way, only the poll timing can differ.
- **MTU.** The largest ATT payload iOS negotiates is 185 bytes; the Android driver works with 247. The
  history frames are sized for the larger value, so a chunk of 270 records may arrive truncated on iOS.
  A frame that fails to decrypt is counted and shown as "Data frames could not be decrypted" after
  three in a row; a history window that comes back short is retried and then given up. **This is the
  largest untested risk of this driver.** If history never fills, this is the first suspect; a smaller
  chunk size would be the fix.
- **A stranger gets a Core Data peripheral.** The base transmitter tells the manager about a connection
  before the handshake, so the manager creates the peripheral for any Ottai advertisement the first
  scan accepts, even one that is then rejected. The address is remembered as rejected and the device
  screen shows "The sensor does not match the imported material"; delete the entry. Accepted limitation.
- The base class traces every received value. The values on the authentication characteristics are
  public keys and signatures or encrypted, and the app's own authentication writes are written with
  `logPayload: false`.
- The first scan has no service filter (the name decides), and iOS delivers such a scan only while the
  app is in the foreground. Once the sensor is known the app reconnects by address, which also works in
  the background.
- Per-address state is `OttaiDeviceState`, a JSON value in UserDefaults (`OttaiDeviceStore`): counters,
  the stream clock, the last reading, the command status, the learned record width, the last link
  problem. It holds no secret. A different sensor id in the material starts it over. The material is
  `OttaiMaterialsStore` in the Keychain.

## What is not done

Deliberate differences from JugglucoNG. Each one is a gap to close with a real sensor in hand.

- **The vendor cloud**: `OttaiCloudClient` (login, sensor binding, key and coefficient download),
  `OttaiNetSecurity` and `OttaiRegionalTransport` (request signing and regional endpoints),
  `OttaiPhoneNumber` (login identifier handling), `OttaiV3BootstrapPolicy` and the server-mediated
  active authentication of the Chinese V3 firmware. The fork makes no network call to the vendor's
  servers and does not reproduce their client-side protections. The keys and coefficients have to come
  from you.
- **Firmware update**: `OttaiFirmwareController`, `OttaiFirmwareDiscovery`, `OttaiFirmwareJournal`,
  `OttaiFirmwareSession`, `OttaiOtaPackage`.
- **Activating a new sensor** (the activation negotiation after command status 0 to 2) and NFC
  (`OttaiNfc`, `OttaiNfcWakeReminder`: an optional reminder that wakes the connection by tapping the
  sensor; iOS opens an NFC session only on the user's tap, so it would need its own screen).
- **Ended sensors**: the last history of an ended sensor is not fetched.
- The Room diff and the history hole ledger that survives a restart (here pending gaps live in memory
  and the first fill reaches back one day at most), the provisional start taken from the CGM-info
  window, the managed-sensor identity adapter, the native glucose mirror, the advertisement probe, and
  the registry (the material is a Keychain item instead).
- A device picker: the first connection takes the first matching advertisement that is not rejected.
- Fingerstick calibration (`NoCalibrator`: the value is the vendor's expression applied to the current).
- Battery.

## Where the code is

| What | Where |
| --- | --- |
| Services, identity rules, handshake maths, AES-ECB payloads, record parser, expression evaluator, output gate, material format | `xDrip/BluetoothTransmitter/CGM/Ottai/OttaiProtocol.swift` |
| Timing helpers, stream clock, continuity gate, pipeline, history window and chain, CGM info and lifetime | `xDrip/BluetoothTransmitter/CGM/Ottai/OttaiSession.swift` |
| Connection, device state store, material store (Keychain), link problems, history engine, delivery to xDrip | `xDrip/BluetoothTransmitter/CGM/Ottai/CGMOttaiTransmitter.swift` |
| Peripheral and Core Data entity | `xDrip/BluetoothPeripheral/CGM/Ottai/`, model `xdrip v43 Ottai` |
| Device screen, add-screen material section, scan notice and guard | `BluetoothPeripheralDetailState.swift` (`makeOttaiSections`, `makeOttaiMaterialAddSection`, `importOttaiMaterialsFromClipboard`, `scanPreparationNotice`) |
| Strings | `Texts_BluetoothPeripheralView` (`ottai*`), `xDrip/Storyboards/{en,uk}.lproj/BluetoothPeripheralView.strings` (`ottai.*`) |
| Tests | `xDrip Tests/Ottai{Protocol,Formula,Session,Driver}Tests.swift` |

The Core Data entity (`Ottai`, model `xdrip v43 Ottai` = v42 MQ + this entity) only links to its
`BLEPeripheral`. The type is `BluetoothPeripheralType.ottaiType` and `CGMTransmitterType.ottai`
(`NoCalibrator`; `isWebOOPEnabled()` is true, warm-up 0, one reading per minute). Persisted raw
values (`OttaiLinkProblem`) are pinned by tests.

## Notes for the next driver

On top of the checklist at the end of `docs/ican.md` and the notes in `docs/aidex.md`,
`docs/anytime.md` and `docs/mq.md`:

- A driver whose secrets only a vendor cloud can issue should still be built from the standalone
  parts: keep the protocol maths pure and testable, take the secrets as an explicit user import, keep
  them in the Keychain, and make the missing secret a visible state instead of a guess.
- CoreBluetooth cannot tell a read result from a notification of the same characteristic. Count the
  reads in flight.
- The base transmitter's `didConnect` reaches the manager before any handshake, so a rejected stranger
  is still a peripheral to delete. The base class also traces every received value: keep secrets off
  characteristics it subscribes to, and write secrets with `logPayload: false`.
- The transmitter owns its copy of the persisted state. A screen that changes the state must ask the
  transmitter to apply the change (`sensorMaterialsDidChange`), or the next `persistState()` overwrites
  it.
- Pbxproj ids of this driver start with `07701`; pick another prefix for a new driver.
