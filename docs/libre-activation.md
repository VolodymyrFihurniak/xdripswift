# Activating FreeStyle Libre sensors

xDrip4iOS can start a new FreeStyle Libre sensor by NFC, without the Libre app.

## Where

Bluetooth → **+** → CGM → **Libre 2/2+ EU**, **MiaoMiao** or **Nano/Bubble/Bubble Mini** →
**Sensor activation → Activate a new sensor**. The row is there while the device is being added and
afterwards, so a replacement sensor can be started from the same screen.

1. Apply the sensor.
2. Tap **Activate a new sensor**, confirm, and hold the top of the iPhone to the sensor.
3. The sensor warms up for 60 minutes.
   - **Libre 2**: on a device that is being added, **Connect** starts the usual scan that enables
     Bluetooth streaming.
   - **MiaoMiao / Bubble**: the transmitter reads the sensor after the warm-up.

Libre 3 / 3 Plus sensors are started from their own setup (Add CGM → Libre 3 → Start a new sensor).

## Which sensors

| Sensor (patch info) | Activation |
|---|---|
| Libre 1 (`DF`, `A2`) | NFC command `A0` with the Libre 1 key |
| Libre 2 EU (`9D`, `C5`, `7F 0E 30`) | NFC command `A1 1B` + key derived from the sensor UID |
| Libre 2 Plus EU (`C6`, `7F 0E 31`) | as Libre 2 EU |
| Libre 2 / 2 Plus Gen2 (US, RU, LA; third patch-info byte low nibble ≥ 9) | not possible: needs Abbott's own code |
| Libre US 14-day (`E5`, `E6`), Libre Pro (`70`) | not possible |
| Libre 3 / 3 Plus | own setup screen |

## Safety

- The sensor's FRAM is read first (and decrypted for Libre 2). The command is sent **only** when the
  header's crc is valid and its state byte says *not yet started*. A running, expired or failed sensor
  is left alone; so is one whose state could not be read cleanly.
- After the command the state is read again. Only *warming up* or *ready* counts as success, so a lost
  answer is not mistaken for a failure, and a refused command is not mistaken for a start.
- Activation starts the sensor's wear period and cannot be undone. The Libre app does not know a
  sensor started this way.

## Sources

JugglucoNG activates in `ScanNfcV`/`AlgNfcV.activate` before enabling streaming, but builds the command
through Abbott's own native library (`getActivationCommand` / `getActivationPayload`; Gen2 through
`Gen2.activate`), which cannot be used on iOS. The commands here follow DiaBLE (gui-dos/DiaBLE, GPL-3.0:
`Sensor.activationCommand`, `nfcCommand(.activate)`), whose Libre 2 key derivation xDrip4iOS already uses
to enable streaming (`PreLibre2.usefulFunction`).

Code: `LibreSensorActivation` (plan, testable) and `LibreSensorActivator` (CoreNFC session) in
`xDrip/BluetoothTransmitter/CGM/Libre/Utilities/LibreNFC.swift`; the screen row in
`BluetoothPeripheralDetailState.makeLibreActivationSection()`. Tests: `LibreSensorActivationTests`.
Not yet tried on a real sensor from an iPhone.
