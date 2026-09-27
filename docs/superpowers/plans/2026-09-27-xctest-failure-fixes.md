# xDrip XCTest Failure Fixes Implementation Plan

> **For agentic workers:** Use the already selected Subagent-driven execution method when it is available; otherwise apply each task sequentially and review the GitHub diff after every task.

**Goal:** Resolve the failing assertions reported by workflow run 36314220395 on `f/sibionics2`.

**Architecture:** Keep the Sibionics V1.1.6A correction algorithm and CGM delivery policy unchanged while fixing snapshot continuation at the Swift/Kotlin boundary. Correct the troubleshooting log's replayable reduction, the Dexcom test vectors, and Core Data test persistence boundaries where the run identifies mismatches.

**Tech Stack:** Swift, XCTest, Core Data, Kotlin Multiplatform, GitHub Actions.

**Spec:** Failing test evidence from workflow run 36314220395, job 108605967122.

## Global Constraints

- Do not publish raw Sibionics glucose as a fallback when correction state is missing.
- Preserve existing user-visible troubleshooting log wording and only retain one row for one recovery.
- Keep parser behavior consistent with the encoded GS1 application identifiers.
- Do not trigger GitHub Actions; the user runs workflow dispatch manually.
- Update only branch `f/sibionics2`.

## Review Focus

- Snapshot taken before the first exact correction resumes from the identical core state; prove with a direct facade round-trip and the processor checkpoint test.
- Snapshot taken after correction preserves the live correction delta; prove with the existing state store and reconnect tests.
- Replaying troubleshooting-log reduction over already reduced entries does not duplicate a Bluetooth recovery; prove with the existing recovery test.
- Search only matches text that is actually rendered in the report; prove with the activity filter test.
- Persisted Core Data test objects are fetched only after both parent and store saves complete; prove with the Core Data round-trip tests.

---

### Task 1: Sibionics snapshot restoration

**Files:**
- Modify: `xDrip/BluetoothTransmitter/CGM/Sibionics2/Sibionics2GlucoseProcessor.swift` and/or `Sibionics2Core/src/commonMain/kotlin/tk/glucodata/drivers/sibionics/Sibionics2V116AFacade.kt` only if the new direct round-trip assertion isolates the bridge.
- Test: `xDrip Tests/Sibionics2GlucoseProcessorTests.swift`
- Test: `xDrip Tests/Sibionics2RegistrationAndDeliveryTests.swift`

**Interfaces:**
- Consumes: `Sibionics2GlucoseProcessor.snapshot()`, `restore(from:)`, and `Sibionics2V116AFacade.snapshotHex()/restoreHex(snapshot:)`.
- Produces: continuation that accepts the same snapshot and emits the same next processed reading.

- [ ] Add a direct core-facade round-trip assertion at the failing early checkpoint and a failure message identifying the checkpoint.
- [ ] Use the current CI failure as the RED evidence: `testSnapshotRestoresTheSameNextReading` failed at `XCTAssertTrue`; delivery and reconnect tests emitted uncorrected 115.2/118.8 mg/dL instead of 64.8 mg/dL.
- [ ] Isolate whether Swift envelope validation or Kotlin/Native facade restoration rejects the checkpoint, then make the smallest fix at that boundary.
- [ ] Verify the processor snapshot, state-store, reconnect, session-reset, and delegate-delivery tests.

### Task 2: Troubleshooting log behavior

**Files:**
- Modify: `xDrip/Utilities/TroubleshootingLog.swift`
- Test: `xDrip Tests/TroubleshootingLogTests.swift`

**Interfaces:**
- Consumes: `TroubleshootingLogReport.entries(matching:)` and the typed Bluetooth event reducer.
- Produces: filtering over rendered report messages and an idempotent Bluetooth recovery reduction.

- [ ] Change the query assertion to text present in the rendered reading message.
- [ ] Make a previously reduced `.reconnectedToExisting` entry restore healthy Bluetooth state during replay so a later duplicate connection is suppressed.
- [ ] Verify both failing troubleshooting log tests.

### Task 3: Dexcom observed-label test vectors

**Files:**
- Test: `xDrip Tests/DexcomG6SensorLabelTests.swift`

**Interfaces:**
- Consumes: `DexcomG6SensorLabelParser.parse(_:)`.
- Produces: observed-label payloads whose AI 21 serial value matches the asserted serial.

- [ ] Correct the three payloads whose encoded AI 21 fields omit a leading serial digit; keep parser behavior unchanged.
- [ ] Verify all observed G6/ONE label samples.

### Task 4: Core Data round-trip test persistence

**Files:**
- Test: `xDrip Tests/DexcomG6SensorLabelTests.swift`
- Uses: `CoreDataManager.saveChangesSynchronously()`

- [ ] Wait for the child and parent context saves to finish before resetting the context and fetching.
- [ ] Verify the Dexcom G7 and Sensor metadata round-trips.

### Final verification

- [ ] Review the complete branch diff and verify all assertions from run 36314220395 are addressed.
- [ ] Report that Xcode tests still need a fresh user-triggered workflow run; do not claim they pass without that run.
