# Sibionics 2 Support for xDripSwift

**Status:** Design for review  
**Date:** 2026-09-26  
**Target branch:** `f/sibionics2`

## Goal

Add direct Bluetooth support for the Sibionics 2 CGM to xDripSwift. A user must be able to add the sensor through the existing Bluetooth setup flow, connect to it, receive glucose readings, and see those readings in the same app surfaces used by the currently supported CGMs.

## User requirements

- Target the Sibionics 2 sensor family.
- Follow xDripSwift's existing Swift, Bluetooth, Core Data, and CGM delegate patterns.
- Use ctqvva/iglucco as a technical example for the Sibionics 2 protocol and connection sequence.
- Build the feature branch through a GitHub Actions workflow and test the resulting build on an iPhone through TestFlight.

## Existing project constraints

xDripSwift uses `BluetoothTransmitter` as the shared CoreBluetooth owner and uses `CGMTransmitter` / `CGMTransmitterDelegate` to send readings into the application's existing CGM data pipeline. Bluetooth peripheral kinds are registered through `BluetoothPeripheralType`, stored through the Core Data `BLEPeripheral` relationships, and instantiated by `BluetoothPeripheralManager`.

The new implementation should reuse those lifecycles rather than add a second central-manager owner. The UI, reading persistence, charting, alarms, and downstream sharing should receive data through the existing CGM path.

## Proposed design

### 1. Sibionics 2 protocol layer

Add a focused protocol implementation for the Sibionics 2 variant and a pure `Sibionics2GlucoseProcessor`. Keep packet construction, encryption/checksum handling, parsing, and stock-path glucose processing testable independently from CoreBluetooth callbacks.

Use iGlucco's Sibionics 2 / V120 path as the behavioral reference. The observed BLE surface is service `FF30`, notify characteristic `FF31`, and write characteristic `FF32`. Implement only the commands and responses required to authenticate/activate the sensor, synchronize time, request data, and receive the stream. Do not add reset or maintenance commands.

iGlucco's repository has no explicit license file. Use it to understand protocol behavior, but write an independent implementation in xDripSwift style rather than copying its source files. Cross-check protocol facts and algorithm behavior against ctqvva/JugglucoNG, which is GPL-3.0. Any code actually adapted from Juggluco must retain required attribution and license notices; the target repository is also GPL-3.0.

### 2. xDripSwift Bluetooth integration

Add a dedicated Sibionics 2 transmitter that subclasses `BluetoothTransmitter` and conforms to `CGMTransmitter`. Keep CoreBluetooth state transitions in that class, using the base class for scanning, connection ownership, reconnect behavior, service discovery, and characteristic subscription.

Register Sibionics 2 in the existing peripheral selection and persistence path. Add the required Core Data peripheral entity/relationship and manager construction/mapping. Give the sensor a distinct CGM transmitter and sensor type so existing Dexcom, Libre, and Medtrum behavior remains unchanged.

### 3. Reading processing

Decode sensor index, event time, temperature, trend, and glucose fields, then produce `GlucoseData` for the standard delegate. Preserve event timestamps and indexes so reconnects can avoid duplicates and request missing readings when the sensor protocol provides history.

Use iGlucco's stock Sibionics processing path as a behavioral reference and implement it in xDripSwift style; cross-check the output against Juggluco's stock-path fixtures or independently captured sensor traces. Do not treat a packet's raw glucose field as a verified final value. Keep the first version limited to the stock Sibionics 2 path; exclude experimental alternative algorithms and sensor maintenance actions.

### 4. Build workflow

The temporary direct build workflow currently checks out `master` explicitly. Update its checkout to use the ref selected when manually dispatching the workflow, so a dispatch on `f/sibionics2` builds this feature branch. Do not run or publish a TestFlight build as part of implementation; the user will trigger the workflow after reviewing the changes.

## Scope

Included:

- Sibionics 2 discovery, add-peripheral setup, BLE connection, required protocol handshake, and data notifications.
- Live reading delivery and protocol-supported history/backfill.
- Registration in peripheral setup, persistence, CGM type mapping, and ordinary reading display.
- Unit tests for protocol vectors, invalid/checksum-failed packets, stock-path reading conversion, and type/data-pipeline mapping.
- Branch-selectable manual build workflow for the feature branch.

Excluded:

- Sibionics GS1, Chinese legacy, and GS3 sensor variants.
- User-selectable experimental algorithm variants.
- Sensor reset/maintenance controls.
- Running the user's TestFlight release workflow or merging the branch.

## Verification and acceptance

The implementation is ready for TestFlight evaluation when:

1. The Sibionics 2 option appears in the existing add-peripheral flow.
2. xDripSwift can connect, complete the required handshake, and receive sensor packets on an iPhone.
3. Valid readings enter the standard CGM pipeline with correct units and event times; malformed packets do not create readings.
4. Reconnection does not duplicate already stored readings and requests available missing history.
5. Unit tests cover protocol parsing, packet validation, reading conversion, and transmitter type registration.
6. The manually dispatched direct-build workflow checks out the selected feature branch.

The local execution environment is Linux and has no `xcodebuild`; therefore an Apple-platform build must be verified by GitHub Actions. The final end-to-end connection and displayed values require the user's TestFlight run with a real Sibionics 2 sensor. Until that device check confirms the algorithm and readings, the feature must be reported as unverified on hardware.

## Reference sources

- xDripSwift: https://github.com/VolodymyrFihurniak/xdripswift
- iGlucco BLE protocol: https://github.com/ctqvva/iglucco/tree/main/iGlucco/Services/Bluetooth/SiBionics
- iGlucco stock algorithm reference: https://github.com/ctqvva/iglucco/blob/main/iGlucco/Services/Bluetooth/SiBionics/SiBionicsAlgorithmContext.swift
- iGlucco protocol tests: https://github.com/ctqvva/iglucco/blob/main/Tests/SiBionicsProtocolTests.swift
- JugglucoNG Sibionics driver: https://github.com/ctqvva/JugglucoNG/tree/main/Common/src/main/java/tk/glucodata/drivers/sibionics


## Task 2 architecture addendum (2026-09-26)

The pinned stock V116A implementation is a 907 KB generated state machine with over 27,000 lines. A hand-written Swift recreation or the unrelated iGlucco approximation would not preserve the required behavior. Task 2 therefore uses a minimal standalone Kotlin Multiplatform module solely to compile the complete JugglucoNG GPL-3.0 V116A core into a static Kotlin/Native XCFramework. The module contains minimal DTOs, four narrowly scoped portability substitutions, a primitive-only process/reset/snapshot bridge, and a JVM target for fixture differential tests. BLE, sensitivity resolution, xDrip validation, live/replay correction, persistence, unit conversion, and delivery stay in Swift.

Task 4 must run `gradle -p Sibionics2Core assembleSibionics2CoreReleaseXCFramework` with JDK 17 on macOS before Xcode/Fastlane. Expected output: `Sibionics2Core/build/XCFrameworks/release/Sibionics2Core.xcframework`.
