# xDrip XCTest Failure Fixes Implementation Plan

> **For agentic workers:** Use the already selected Subagent-driven execution method when it is available; otherwise apply each task sequentially and review the GitHub diff after every task.

**Goal:** Resolve the failing assertions reported by workflow run 36314220395 on `f/sibionics2`.

**Architecture:** Keep the Sibionics V1.1.6A correction algorithm and CGM delivery policy unchanged. Transfer core snapshots in bounded hex chunks across Kotlin/Native and Swift, and preserve the troubleshooting log, Dexcom parser, and Core Data production behavior while correcting the test/reducer mismatches identified by CI.

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
- Modify: `xDrip/BluetoothTransmitter/CGM/Sibionics2/Sibionics2GlucoseProcessor.swift`
- Modify: `Sibionics2Core/src/commonMain/kotlin/tk/glucodata/drivers/sibionics/Sibionics2V116AFacade.kt`
- Test: `xDrip Tests/Sibionics2GlucoseProcessorTests.swift`
- Test: `Sibionics2Core/src/jvmTest/kotlin/tk/glucodata/drivers/sibionics/v116a/SibionicsExactV116ACoreConformanceTest.kt`
- Test: `xDrip Tests/Sibionics2RegistrationAndDeliveryTests.swift`

**Interfaces:**
- Consumes: `Sibionics2GlucoseProcessor.snapshot()` and `restore(from:)`, backed by `Sibionics2V116AFacade.snapshotByteCount()`, `snapshotHexChunk`, and chunked restore methods.
- Produces: continuation that accepts the same snapshot and emits the same next processed reading.

- [x] Use the CI failure as RED evidence: `testSnapshotRestoresTheSameNextReading` failed at `XCTAssertTrue`; delivery and reconnect tests emitted uncorrected 115.2/118.8 mg/dL instead of 64.8 mg/dL.
- [x] Trace the reported 5047-byte Swift snapshot to the long hex-string boundary; the current core snapshot format produces 2504 bytes, or 5008 hex characters, for a 5040-byte Swift envelope.
- [x] Transfer snapshot hex in bounded chunks in both directions and validate every emitted chunk before storing a snapshot.
- [x] Add a JVM facade chunk round-trip test and assert the iOS snapshot length and checkpoint-specific restore result.
- [ ] Verify processor snapshot, state-store, reconnect, session-reset, and delegate-delivery tests in a fresh user-triggered workflow.

### Task 2: Troubleshooting log behavior

**Files:**
- Modify: `xDrip/Utilities/TroubleshootingLog.swift`
- Test: `xDrip Tests/TroubleshootingLogTests.swift`

**Interfaces:**
- Consumes: `TroubleshootingLogReport.entries(matching:)` and the typed Bluetooth event reducer.
- Produces: filtering over rendered report messages and an idempotent Bluetooth recovery reduction.

- [x] Change the query assertion to text present in the rendered reading message.
- [x] Make a previously reduced `.reconnectedToExisting` entry restore healthy Bluetooth state during replay so a later duplicate connection is suppressed.
- [ ] Verify both troubleshooting log tests in a fresh user-triggered workflow.

### Task 3: Dexcom observed-label test vectors

**Files:**
- Test: `xDrip Tests/DexcomG6SensorLabelTests.swift`

**Interfaces:**
- Consumes: `DexcomG6SensorLabelParser.parse(_:)`.
- Produces: observed-label payloads whose AI 21 serial value matches the asserted serial.

- [x] Correct the three payloads whose encoded AI 21 fields omit a leading serial digit; keep parser behavior unchanged.
- [ ] Verify all observed G6/ONE label samples in a fresh user-triggered workflow.

### Task 4: Core Data round-trip test persistence

**Files:**
- Test: `xDrip Tests/DexcomG6SensorLabelTests.swift`
- Uses: `CoreDataManager.saveChangesSynchronously()`

- [x] Obtain permanent object IDs and wait for the child and parent context saves to finish before resetting the context and fetching.
- [ ] Verify the Dexcom G7 and Sensor metadata round-trips in a fresh user-triggered workflow.

### Final verification

- [x] Review the branch diff and implement fixes for every assertion group reported by run 36314220395.
- [ ] Run the full Xcode test workflow on the updated branch head and confirm no failures; the user will dispatch this workflow.
- [x] Do not claim the updated tests pass until the fresh workflow result is available.

The reported run tested commit `6be7df00826384957124cd978fce29b43389090a`. The implementation changes end at `b91c3ba4bbc6eff6719655766d6757bcdf155810`; the current branch tip is `745042acf59c258fc973c024d5dd3e5785b29e9f` after this plan-status update.
