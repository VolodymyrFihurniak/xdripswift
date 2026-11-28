# xDripSwift fork — working notes

Fork of `JohanDegraeve/xdripswift` that adds **Sibionics 1 and Sibionics 2** CGM support,
ported from `ctqvva/JugglucoNG` (GPL-3.0, see `THIRD_PARTY_NOTICES.md`). JugglucoNG is the
reference for every Sibionics behaviour: when in doubt, read its code
(`Common/src/main/java/tk/glucodata/drivers/sibionics/`, `.../data/calibration/CalibrationMath.kt`)
and match it rather than inventing. User-facing docs: `docs/sibionics2-troubleshooting.md`.

## Build and verification

**New session? Read `docs/development-notes.md` first**: owner preferences (answer in Ukrainian,
build fixes after a merged PR go straight to `master`), the verification tools, and the mistakes
that broke the CI before. Before every commit: `python3 tools/check_swift.py` and
`python3 tools/check_strings.py`.

- No Swift/Xcode in cloud sessions: code cannot be compiled or tested locally. Build and tests run
  only in GitHub Actions (`.github/workflows/build_xdrip.yml`, macOS). Say so when reporting work.
- `Sibionics2Core` is a Kotlin Multiplatform XCFramework (vendored JugglucoNG V116A/V115G stock
  algorithms). CI builds it with `gradle -p Sibionics2Core assembleSibionics2CoreReleaseXCFramework`.
- The Kotlin core's JVM target does build here: copy `Sibionics2Core` to the scratchpad, set
  `jvmToolchain(21)` and an absolute fixtures path there, run `gradle cleanJvmTest jvmTest`
  (Maven Central may answer 429 at first; retry). The iOS targets still need macOS.
- Before adding numeric test expectations, verify them with a small Python port of the logic
  (done for calibration math, sensitivity decoding, label parsing). Never guess expected values.
- Avoid new source files where possible: adding files requires hand-editing
  `xdrip.xcodeproj/project.pbxproj`. Extending an existing file (e.g. the scanner lives in
  `SwiftUIViews/Sensor/SensorCodeScannerView.swift`) avoids that.
- Localised strings: update `Texts*.swift` defaults **and** `en.lproj` / `uk.lproj` `.strings`.

## Upstream sync

- `git remote add upstream https://github.com/JohanDegraeve/xdripswift.git`, merge `upstream/master`.
- Core Data: the fork keeps its own models `xdrip v33 Sibionics` / `xdrip v34 Sibionics` (needed to
  migrate installed fork builds). The current model is the latest upstream model **plus** the
  `Sibionics2` entity (`sensorVariant` Int16 default 2, relationship `blePeripheral`) and
  `BLEPeripheral.sibionics2` (optional, cascade). When upstream adds a version, create a new fork
  version = upstream latest + those additions, set it current in `.xccurrentversion` and in the
  pbxproj `XCVersionGroup`. Never edit an existing shipped model version.
- Upstream ships `uk.lproj` too since 7.2.1, so string tables conflict on merge: keep both sides,
  then drop the fork's copy of any key upstream now defines (duplicate keys: the later one wins).
  The build workflow syncs upstream first and fails on a conflict, so merge upstream by hand.
- After merging, check every `switch` over `BluetoothPeripheralType`, `CGMTransmitterType` and
  troubleshooting sources lists both upstream's new cases and `Sibionics1Type`/`Sibionics2Type`/
  `.sibionics2`. The peripheral-loading loop in `BluetoothPeripheralManager` must
  `break bluetoothPeripheralTypeLoop` after the shared Sibionics entity (S1 and S2 share it;
  without the break each sensor is listed twice and two transmitters fight over one link).

## Sibionics architecture (`xDrip/BluetoothTransmitter/CGM/Sibionics2/`)

- One transmitter `CGMSibionics2Transmitter` for both variants (`SibionicsDeviceVariant`).
  BLE service FF30, notify FF31, write FF32 (prefer acknowledged writes: the 26-byte auth packet
  exceeds a 20-byte ATT payload). Also reads Device Information `180A` and Battery `180F`.
- **V120** (Sibionics 2, EU/Hematonix S1): RC4-encrypted handshake auth → activation → time sync
  → data request → streaming. Key groups Eco/Sijoy/Hematonix rotate when auth gets no answer
  (5 s); the group that produced readings is saved and tried first; order is frozen per connection.
  Streaming is pushed by the sensor — **no polling timer** (the user removed it on purpose).
- **Chinese S1** (AA55 plaintext): must be asked every 60 s (protocol requirement, not a setting),
  every 30 s until the first page. An AA55 07 echo or saved mode confirms Chinese; only the V120
  marker or no answer switches to V120.
- **Bluetooth MAC for auth**: iOS has no MAC API. Sibionics 2 publishes it in Device Information
  serial `2A25` as six raw bytes, least significant first (`32 5B D1 B0 71 C7` = `C7:71:B0:D1:5B:32`).
  Candidates (detected, unverified, zero) rotate one per connection; the one that yields readings
  is saved. A manual override always wins. Auth waits up to 3 s for Device Information.
  Rotation (`Sibionics2ConnectionPolicy.shouldTryNextAuthenticationAddress`): a lost link proves
  nothing, so a confirmed address is only left after 3 sessions in a row without readings. Chinese S1
  says itself whether it accepts the address in the request echo (`AA55 07 01 01` yes, `00 00` no,
  `echoAcceptsAddress`): yes confirms it, no tries the next candidate at once in the same connection
  (after a refusal the sensor sends nothing, so a background app is never woken to try again).
- **Algorithm**: V116A for Sibionics 2 and EU/Hematonix, V115G for Chinese S1. Unusable minutes
  advance the cursor (do not filter by temperature/impedance — that stalled history).
- **Sensitivity**: S2 = probe code (14 chars) → label short code → BLE name → `0316015A`.
  S1 = label short code → `deriveShortCode(BLE name)` → family fallback
  (EU `YMWD016F` 1.58, Hematonix `YEZ1450H` 1.47, Chinese `GEPD802J` 1.27) → 1.27.
  GS1 label scanning (`SibionicsSensorLabel`) follows JugglucoNG `SibionicsRegistry`.
- **GS3** (JugglucoNG `Variant.GS3`): a Sibionics 1 with the device-screen toggle "GS3 sensor"
  (`Sibionics2Configuration.isGS3`, fixes the protocol to V120). V120 with the EU/Sijoy session key, the
  V115G algorithm, fallback `YEZ1450H` (`Sibionics1Family.gs3`), lifetime 14 d + 36 h, name "Sibionics GS3".
- **Lifetime / warm-up**: S1 = JugglucoNG `EXTENDED_CHINESE_LIFETIME_MS` (572 h − 19 min,
  `Sibionics1SensorProfile`), label 14 days; S2 = 23 days. `sensorWarmupDurationInMinutes()` is 0
  (JugglucoNG has no Sibionics warm-up; xDrip's 45-min default hid a new sensor's readings).
- **Name**: S1 and S2 share `CGMTransmitterType.sibionics2` (persisted raw value). Use
  `CGMSibionics2Transmitter.productName` / `SibionicsDeviceVariant.productName` wherever the
  product name is shown (active sensor description, Activity Log source, Loop, reports).
- **Manual sensitivity** (`Sibionics2Configuration.manualSensitivity`, 0.8–2.5) wins over probe code,
  label and name; changing it replays history like a new label code.
- **Glucose model** (`Sibionics2GlucoseModel`, per sensor, `Sibionics2Configuration.glucoseModel`):
  stock (default), JugglucoNG Adaptive V1 (raw 2; vendored Kotlin `SibionicsAdaptiveAlgorithm.kt` behind
  `SibionicsAdaptiveV1Facade`, fed the stock value and the core's `latestChemicalSignal`, snapshot version 6,
  JVM test checks it byte for byte against the unchanged JugglucoNG file in `jvmTest/.../reference`),
  JugglucoNG Balanced (raw 4) / Responsive (raw 6) — Swift ports
  `SibionicsBalancedTracker` / `SibionicsResponsiveEstimator` fed the stock value, no anchors (as in
  JugglucoNG), snapshot versions 4 / 5, tests use vectors from the Kotlin originals on the JVM — or
  JugglucoNG Adaptive V2 (raw 8). The estimator is vendored Kotlin in
  `Sibionics2Core/.../adaptive2` behind `SibionicsAdaptiveV2Facade`; the stock facade feeds it its
  `latestSensorObservation` (`processAdaptiveV2`). A usable estimate replaces the stock value, which
  stays the fallback, at full precision (JugglucoNG e64e3fd3e; only display rounds). Its 90 % interval
  (`Sibionics2ProcessedGlucose.lowerMgDl/upperMgDl`) goes to `GlucoseUncertaintyStore` (36 h JSON) and
  is drawn as JugglucoNG's uncertainty ribbon on the Home chart (`experimentalUncertaintyRibbonEnabled`). Processor snapshot version 3 = version 2 + estimator state; the other
  model's snapshot is refused, so changing the model replays history.
- **Source journal** (`SibionicsSourceJournal`, end of `Sibionics2ReadingBatchProcessor.swift`, JugglucoNG
  `SibionicsSampleJournal` record layout SJR1 + CRC-32): every received raw minute per sensor in Application
  Support/sibionics-source, new session = new journal. `probeCodeDidChange` (sensitivity, model, GS3) replays
  the contiguous journal locally a day per step (`replayFromJournal`), then asks the sensor for newer minutes.
  Backups carry the journals (`BackupPayload.sibionicsSourceJournals`), restored by merge, phone wins.
- **Skin temperature** (`SibionicsSkinTemperatureStore`, end of `Sibionics2ReadingBatchProcessor.swift`; JugglucoNG
  `SensorTemperature` + Statistics temperature card; display only, never feeds glucose): recorded in `process` for every
  unique minute (live, history, journal replay), one sample per five-minute window (newest wins, keyed by time so replays
  never double count), last 48 h from the newest sample, one JSON per sensor in Application Support/`sibionics-temperature`,
  cleared with the peripheral. Shown as a row in the device info section and as a card in Statistics > CGM data (series of
  whichever sensor reported last). Always °C: the app has no temperature unit setting.
- **Last link problem** (`Sibionics2DeviceStatus.lastLinkProblem`, JugglucoNG "Last BLE status"): set by
  `noteLinkProblem` on lost links, refusals, stalls and auth failures, cleared by a reading; shown on the
  device screen. Home says "no signal" after 3 min for 1-minute sensors (`RootHomeSensorReach`).
- **Reset**: manual for all variants (S2 encrypted `0x10`, EU/Hematonix `24 E7 6F 34`,
  Chinese `AA 55 10 F1`); automatic only for Sibionics 2. The post-reset session probe is one-shot.
  `Sibionics2ResetReminder` (JugglucoNG `SibionicsResetReminder`, S2 only): scheduled UNNotification 4 h
  before day 22, repeats every 2 h, actions reset / postpone 2 h (`resetPostponedUntil` holds only the
  comfortable reset), handled in `RootApplicationCoordinator`.
- **Calibration** (`xDrip/Calibration/Sibionics2Calibrator.swift`): xDrip+ or JugglucoNG
  `CalibrationMath` (weighted OLS default, median slope, robust, elastic, ensemble) with
  Fresh/Balanced/Stable weighting, evaluated in the user's display unit. Mode raw value 1 must stay
  weighted OLS.

## Fork defaults

- Nightscout uploads every new reading (`storeFrequentReadingsInNightscout` defaults to true;
  toggle "Upload Every Reading" in Nightscout > Upload Options, the old developer row is hidden).
  Off restores upstream's one reading per 5 minutes.
- Apple Health (`storeFrequentReadingsInHealthKit`) and Dexcom Share (`dexcomShareUploadEveryReading`)
  also take every reading by default, with the same toggle in their settings.

## Experimental features (`docs/experimental-features.md`)

Settings → Experimental features (`SettingsRootSection.experimental`,
`xDrip/SwiftUIViews/Settings/ExperimentalSettingsView.swift`). Models in
`xDrip/Managers/Therapy/ExperimentalTherapy.swift`: JugglucoNG `GlucosePredictionKernel` +
treatment model, `JournalInsulinCurveCatalogue` (22 insulins), `InsulinActivityStack`.
Drawn only on the Home main chart via `GlucoseChartView.experimentalPlots(_:)`; the chart types
it needs live in `GlucoseChartView.swift` because that file is also compiled into the widget,
watch and notification extensions. A treatment's insulin is named in its `notes`
(`InsulinProfile.matching(notes:)`); every per-dose choice must round-trip through its
`shortName`. All off by default; IOB/COB is untouched. Also: `AlertKind.predictedLow` (raw 16),
prediction periods/body weight/protein-fat/intensity (notes tokens `P:20 F:15`, `intensity:light`),
`TherapyParameterEstimator` (sensitivity / carb ratio suggestions from clean corrections and meals, per
period, applied only on tap), `AlertKind.predictedHigh` (raw 17, `PredictedHighAlert`, JugglucoNG PRE_HIGH + `ForecastIobCoverage`),
`AlertKind.persistentHigh` (raw 18, `PersistentHighAlert`, JugglucoNG PERSISTENT_HIGH: stateless replay of 4 h of readings, run of values
above the alert value for `experimentalPersistentHighMinutes`, quiet while falling ≥ 1 mg/dL/min without ending the run, own group after High),
accuracy recorder (Application Support JSON, 14 days; `PredictionInspector` + `ExperimentalPredictionInspectorView` = JugglucoNG prediction inspector), Nightscout devicestatus forecast
(`openaps.suggested.predBGs.IOB`, only when no AID status is followed), and
`ExperimentalCompanionForecast` for widgets, Live Activity and watch (optional fields).
The line style reaches widgets/Live Activity/watch through optional `experimentalGlucoseLine`
fields and the landscape AGP chart through `AGPChartView(drawsGlucoseAsLine:)`. Chart cursor
(`GlucoseChartCursor`, `GlucoseChartCursorGeometry` reported from the chart overlay, gesture in
`RootHomeMainChartView`) and insulin on board (`InsulinActivityStack.remaining/onBoard`,
`GlucoseChartExperimentalPlots.onBoardNow`) follow JugglucoNG `DashboardChart`/`JournalIobMath`.
Adaptive prediction (`xDrip/Managers/Therapy/AdaptiveGlucoseForecast.swift`): JugglucoNG
`AdaptiveGlucoseForecast` + `AdaptivePredictionStore`; model JSON in UserDefaults
(`experimentalAdaptiveForecastModel`), daily refit on a private-queue context over 29 days of
`BgReading` dictionaries; alerts and Nightscout stay on the standard forecast. Fork extension:
`AdaptiveTreatmentFeatures` (insulin / carbs still to come, 30-minute treatment effect) as features
9–11, kept only when they beat the CGM-only model on the holdout (`usesTreatments`); every forecast
caller passes them, a treatment model without them has no answer. `PredictionAccuracySummary` (hourly, per
recorded model and horizon: RMSE, 10th/90th residual percentiles) feeds `ForecastBlend` (inverse-MSE
mix of adaptive and standard, recorded as model `blend`) and `PredictionRange` (band around the
forecast, `GlucoseChartExperimentalPlots.predictionRange`).
Power saving (`ExperimentalPowerSaving`, mode Off/On/Automatic, never while charging) throttles the
"every reading" uploads, Live Activity/widget refresh (`allowsRefresh`, urgent out of range), the
Home chart minute redraw and the adaptive refit — never readings or alarms. Alarms (`AlertKind.swift`/`AlertManager`):
`GDHDeltaRun` (JugglucoNG GDH delta alarm, replayed statelessly over 45 min of readings, change scaled
to 5 min), `SameDirectionAlertRule` (Fast Drop ↔ predicted low after a snooze) and
`ExperimentalQuietWindow` (sound/vibration held back, lows always break through) — all off by default. Basal injections
(Nightscout event type Note) always count in `ExperimentalTreatment.fetch`.

IOB and COB through Nightscout (`docs/experimental-features.md`, Settings → Experimental features → "IOB and COB
through Nightscout", UserDefaults `experimentalNightscoutIobUpload` / `experimentalNightscoutIobFollow`, both off;
JugglucoNG `NightscoutIobDeviceStatus` / `RemoteIobSnapshot`): `ExperimentalNightscoutIob` builds the devicestatus
(`openaps.iob.{iob,timestamp}` classic IOB + `jugglucong.{iob,eiob,cob}`, two decimals, device xDrip4iOS), the
cadence (5 min while insulin is on board or values move, 10 min idle — JugglucoNG's 15 would outlast the follower's
window) and the snapshot from this phone's own treatments only (`DataFlowPolicy.localTreatmentsOnly`, rapid insulins,
needs a dose in 24 h); uploaded by `NightscoutSyncManager.uploadExperimentalIobIfDue` next to the forecast upload and
never while an AID's status is followed. Follower: `NightscoutSyncManager.updateRemoteIob` polls `devicestatus?count=10`
(≥ 60 s apart) into `ExperimentalRemoteIobStore`; `ExperimentalRemoteIob` is fresh for 15 min (JugglucoNG 30);
`TherapyMetricsManager.resolve(remoteIob:)` shows it as `TherapyMetricSource.remote` on the Home IOB/COB row only
(`snapshot(includesRemoteIob:)`, labelled "Remote IOB/COB", details sheet shows eIOB), and only when
`DataFlowPolicy.showsRemoteIob` holds and the local treatment window is confirmed empty — a phone with treatments keeps
its own values (JugglucoNG prefers remote), so remote and local never mix. Watch, widgets, Live Activity and chart never see
remote values. Uncompiled, never tried on a real Nightscout or a JugglucoNG phone.

Trend engine (`TrendEngine`, `CausalGlucoseFilter`, `ExperimentalTrendEngine` at the end of ExperimentalTherapy.swift;
JugglucoNG `logic/TrendEngine.kt`, `CausalGlucoseFilter.kt`, `TrendWindows.kt`; keys `experimentalTrendEngine` and
`experimentalTrendEngineCausalFilter`, both off): for Sibionics 1/2 in master mode only (`cgmTransmitterType == .sibionics2`) it
overwrites `calculatedValueSlope`/`hideSlope` at the end of `BgPostProcessingManager.recomputeSlopes` (it runs after every new
reading and every replay and replaces the slope `Calibrator.findSlope` gave at creation, which only the Loop-delay minute list
still sees), with a cadence-scaled, recency-weighted regression over the readings before each
one (suppressed 5-minute-cadence readings are input, never written); no engine trend (< 2 readings) keeps xDrip's slope. Arrow
thresholds stay xDrip's (the engine's `stateFor` 0.5/1/2 is ported and tested, not used for the arrow). Values, uploads of values,
Fast Drop/Rise (they compare two readings) and the delta are untouched; the causal Kalman filter feeds only the regression and
never a stored/displayed value. Vectors in `TrendEngineTests` come from the unchanged Kotlin run on the JVM.

Food library (`xDrip/SwiftUIViews/Treatments/FoodLibrary.swift`, button in the carbs treatment
editor, no setting): JugglucoNG staples embedded as a `key|carbs|protein|fat|portions|en|uk` table,
custom foods and recents as UserDefaults JSON, Open Food Facts search/barcode (network only on
request). It fills the editor's carbs/protein/fat; the meal itself is not stored.

Amount assist (`TreatmentAmountAssist`, JugglucoNG `JournalAmountAssist`, no setting): stepper step and
usual amount in `TreatmentEditorViewModel` from xDrip-typed entries (`enteredBy` nil or the app name).

Glucose meters (`GlucoseMeterGATT`, `VerioMeterSession`, `GlucoseMeterLink` in ExperimentalTherapy.swift,
`GlucoseMeterSettingsView`): own CBCentralManager, readings saved as BgCheck treatments
(`GlucoseMeterImport`), paired meter in UserDefaults `experimentalGlucoseMeter`; Satellite = `SatelliteMeterProtocol`/`SatelliteMeterSession`.

Insulin pens (`xDrip/Managers/Therapy/InsulinPenReader.swift`): Swift port of JugglucoNG
`NovoPen/opennov` (NFC Type 4 `PenT4` → `PenPHD` record → IEEE 11073 `PenMessage`/`PenMachine`,
run by `PenSession` over a `PenTransport`), `PenDoseParser`, `InsulinPenStore` (UserDefaults JSON,
cursor = newest reviewed pen counter) and `InsulinPenImport`. `PenManualMergePlanner` (JugglucoNG): a dose
that confirms a hand-written insulin entry (same insulin, amount, ≤ 15 min, in order) moves that entry to the
pen's time instead of adding it twice; imported doses carry `enteredBy` "Insulin pen". CoreNFC needs the NDEF AID
`D2760000850101` in Info.plist `...iso7816.select-identifiers`. Tested only against the
`SimulatedPen` in the tests (verified with a Python port) — never against a real pen.

Outbound API (`docs/outbound-api.md`, JugglucoNG `OutboundApi`, Settings → Sharing and services; no VK / Delta Chat): Telegram bot
(`sendMessage`, then `editMessageText` on the last message inside a window, unchanged values skipped) and custom JSON webhook (standard body
`xdrip.outbound.glucose.v1` or a body template), one trigger (every reading / low / high / outside range) and minimum interval per destination.
`xDrip/Managers/OutboundApi/OutboundApi.swift` (`OutboundApiPlanner`, `OutboundApiDispatcher` over `OutboundApiTransport`, `@MainActor OutboundApiManager`),
`OutboundApiSettingsView.swift`. Hooked in `RootApplicationCoordinator.processNewGlucoseData` beside the Dexcom Share upload (foreground or BLE wake,
with a background task); `ExperimentalPowerSaving` raises the interval to 5 min unless urgent. Token, URL and headers live in the Keychain
(`OutboundApiKeychainSecretStore`, one item per destination), config/state in UserDefaults `outboundApiDestinations` / `outboundApiState`, all excluded
from backups. iOS has no timer, so JugglucoNG's stale/missed message is a note posted before the next reading (`gapNotice`), never on time. Not ported:
IOB/COB/raw/battery tokens, retries, Activity Log entries. Never compiled or tried against Telegram.

Libre sensor activation (`docs/libre-activation.md`): `LibreSensorActivation` (plan) and
`LibreSensorActivator` (CoreNFC) at the end of `Libre/Utilities/LibreNFC.swift`, row on the Libre 2,
MiaoMiao and Bubble device screens (also while adding). DiaBLE commands: Libre 1 `A0 C2AD7521`,
Libre 2 / 2 Plus EU `A1 1B`+`PreLibre2.usefulFunction(uid, 0x1B, 0x1B6A)`. Sent only when the decrypted
FRAM header crc is valid and the state is not-yet-started; success = state re-read as starting/ready.
Gen2 (patch info byte 2 low nibble ≥ 9), US 14-day and Pro are refused (JugglucoNG uses Abbott's library
for them); Libre 3 has its own upstream setup. Never tried on a real sensor.

Libre 2 link (`CGMLibre2Transmitter`, after JugglucoNG #773 and 3e7789f9e): a connected link without a
complete frame for 150 s is hung up and reconnected 5 s later (an immediate reconnect after the app's
own hangup is never logged in); every link ends with a `Libre 2 link ended:` trace line
(`Libre2LinkSummary`: reason, duration, frames, last frame age).

Statistics → CGM data: "Time in ranges by time of day" (JugglucoNG `StatsRangeFlow` + day-part strip):
`GlucoseReportAnalytics.hourlyRanges` (24 × five bands, `GlucoseReportHourRanges`), blocks
`GlucoseReportDayPart` combine by hour mask, none = whole day. "Patterns" (fork extension, `GlucoseReportInsights`): low (< 70)
and very high (> 250) episodes starting in the same two hours on ≥ 3 days, and the mean rise after
breakfast / lunch / dinner (peak within 3 h − reading at the meal, ≥ 3 meals).

Automatic backup (`AutomaticBackup` in `Utilities/Backup/BackupService.swift`, JugglucoNG
`ScheduledBackupPolicy`; Settings → Data management toggle, off by default): at most once per 20 h on
launch (+60 s) or foreground, settings + readings + treatments without accounts to
Documents/Automatic backups (visible in Files), kept 7 days / 4 ISO weeks / 6 months, notification when
it shrinks below half of the previous one.

Settings search (`SettingsSearchIndex` in `SettingsView.swift`, JugglucoNG 726ad73a8): `.searchable` on the
root list; the index walks rows that open a child `SettingsScreen` (depth 4) when a search starts, and a
result pushes the screen chain (`SettingsActionPresenter.show(settingsScreens:)`). Rows inside custom
SwiftUI screens (e.g. `.custom` NavigationLinks) are found only as far as their parent screen.

Quick treatment logging (`AppShortcuts.swift`): `LogCarbsIntent` / `LogInsulinIntent` (Siri, Shortcuts,
Action button; unlocked phone only) save a `TreatmentEntry` like the editor (`QuickTreatmentLog`, app's store
when running, else `CoreDataManager.create`) and request a Nightscout sync. Strings in `Localizable.strings`.

iCan (Sinocare) i3/i6 CGM (`docs/ican.md`, JugglucoNG `drivers/icanhealth`; **uncompiled, never tried on a real sensor**):
`xDrip/BluetoothTransmitter/CGM/ICan/ICanProtocol.swift` (pure maths: key families, AES-128-CBC frames, F3/F4/F6 handshake, live
frames, RACP/SN history, timeline; vectors in `ICanProtocolTests` come from a Python port and JugglucoNG's captured frames) and
`CGMICanTransmitter.swift` (connection; `ICanDeviceStore` keeps per-address state in UserDefaults, cleared with the peripheral).
Own Core Data entity `ICan` (model `xdrip v39 iCan` = v38 + entity, only a link to `BLEPeripheral`), `BluetoothPeripheralType.iCanType`,
`CGMTransmitterType.iCan` (own switch cases everywhere; `NoCalibrator`, readings from the sensor's own algorithm). Foreground scan with
no service filter, first connect takes the first name that looks like an iCan sensor (no picker). Skipped on purpose: vendor cloud and
provisioning, native-library rebuild, finger calibration (CE), battery, original-history RACP phase, direct 16-bit encoding, ENDED
28-day cap, covered-edge persistence, `0x1A`/`F2`/`F7` writes, history beyond 24 h. JugglucoNG's hyphenated `h6-14/15/7` checks never
match and are ported as they are.

AiDex X / LinX CGM (`docs/aidex.md`, JugglucoNG `drivers/aidex`; **uncompiled, never tried on a real sensor**):
`xDrip/BluetoothTransmitter/CGM/AiDex/AiDexProtocol.swift` (pure: serial-derived MD5 secret/IV, AES-128-CFB, CRC-8/MAXIM and CRC-16, F001/F002/F003
key exchange, command builder, live/history parsers, `AiDexHistoryMerge`, key-exchange / streaming / history policies; vectors in `AiDexProtocolTests`
come from the unchanged Kotlin run on the JVM, cross-checked in Python) and `CGMAiDexTransmitter.swift` (connection; `AiDexDeviceStore` per-address state
in UserDefaults, `AiDexPairKeyStore` the PAIR key in the Keychain; both cleared with the peripheral). Own Core Data entity `AiDex` (model `xdrip v40 AiDex` =
v39 iCan + entity, only a link to `BLEPeripheral`), `BluetoothPeripheralType.aiDexType`, `CGMTransmitterType.aiDex` (`NoCalibrator`, the sensor's own
factory-calibrated values, 1-minute readings). iOS has no bond-state API: "paired here" = a stored key, pairing happens on the first `F001` access, and the
`F001` values bypass `super` (the base class traces every received value). F-series sensors (`AiDEX F-…`, cloud-provisioned keys) are refused with a clear
link problem. Skipped on purpose: `AiDexCnCloudClient` (China cloud key endpoint, spoofed `X-Forwarded-For`; never port it), default-parameter provisioning,
wear-profile catalogue, broadcast scan / `0x11` parser and BLE continuity sync, blood-glucose calibration / BloodControl, Adaptive V2, temperature sidecar,
reset/unpair actions, PAIR key backup, history beyond 24 h.

Anytime / Yuwell CGM (`docs/anytime.md`, JugglucoNG `drivers/anytime`; **uncompiled, never tried on a real sensor**):
`xDrip/BluetoothTransmitter/CGM/Anytime/AnytimeProtocol.swift` (pure: frame builders/parsers, CT5 cipher, sensor code `AnytimeQr`, family table and
profiles), `AnytimeSession.swift` (connect/session retry, history gap arithmetic, caught-up cooldown, CT5 live clock and learned current scale,
calibration policy, trend estimator), `AnytimeAlgorithm.swift` (CT2 CT-14 model, CT4 MK4 `AnytimeCalibrator`, CT5 computed by the transmitter; float
arithmetic kept in `Float`, tests compare bit patterns; vectors in `AnytimeProtocolTests`/`AnytimeSessionTests`/`AnytimeAlgorithmTests` come from the unchanged
Kotlin run on the JVM) and `CGMAnytimeTransmitter.swift` (connection, one write slot with priorities, CT2/CT4/CT5 handshakes, history engine, CT5 gap repair
persisted; `AnytimeDeviceStore` per-address state in UserDefaults, `AnytimeCt5SecretStore` the CT5 cipher key in the Keychain, `AnytimeConfiguration`; all cleared
with the peripheral). Own Core Data entity `Anytime` (model `xdrip v41 Anytime` = v40 AiDex + entity, only a link to `BLEPeripheral`), `BluetoothPeripheralType.anytimeType`,
`CGMTransmitterType.anytime` (`NoCalibrator`, 3-minute readings, warm-up held back by the driver itself, `sensorWarmupDurationInMinutes()` 0). Families by BLE name: CT2
(`SN04…`, legacy `FFF0`), CT4 (`SN72…SN90`), CT5 (`Anytime…`, encrypted); **CT2.5, every CT3 family and unknown names are refused** with a link problem (their glucose is
JugglucoNG's `AnytimeNativeAlgorithm`, a decompiled vendor kernel, not ported). The CT5 "estimate from current after the rated life" (JugglucoNG `AnytimeCt5RawScale`) is
an opt-in toggle, off by default, because the estimates look like ordinary readings (`AnytimeConfiguration.ct5EstimatesFromCurrent`). iOS has no bond-state API: "bound" is
the transmitter's own answer. CT5 identity frames (`0x30/0x31/0x38/0x3F`) bypass `super.didUpdateValueFor`. Skipped on purpose: fingerstick calibration, typing or
scanning a sensor code (a CT4 uses `K0` 1.13), reset/unbind/end-cycle commands, CT5 credential export, `tryCt4HandshakeFallback`, the Room import buffer, the older-history
background pass, the persisted interrupted-backfill record of CT2/CT4, periodic telemetry for CT2/CT5, a device picker.

MQ / Glutec CGM (`docs/mq.md`, JugglucoNG `drivers/mq`; **uncompiled, never tried on a real sensor**):
`xDrip/BluetoothTransmitter/CGM/MQ/MQProtocol.swift` (pure: Nordic UART layout, `5A A5 CMD LEN payload CRC` frames, CRC16-Modbus with inbound mismatches accepted, 6-byte
record parser, captured acknowledgements `MQAckFrames`, `MQResetCommand`, `MQVendorIdentity`, `MQProfile`, name prefixes), `MQAlgorithm.swift` (vendor current → mmol/L
algorithm, K/B truncated to two decimals, `Float` storage recovered through its decimal text, `MQBootstrapSeed` first reference), `MQSession.swift` (`MQSessionTracker`,
burst buffer, session timing/restore/link policies, `MQConfiguration`, `MQInputText`) and `CGMMQTransmitter.swift` (connection; `MQDeviceStore` per-address state and
`MQConfigurationStore` user inputs in UserDefaults, both cleared with the peripheral; no Keychain item, the link is not encrypted; vectors in `MQProtocolTests`/
`MQAlgorithmTests`/`MQSessionTests` come from the unchanged Kotlin run on the JVM, cross-checked in Python). Own Core Data entity `MQ` (model `xdrip v42 MQ` = v41 Anytime +
entity, only a link to `BLEPeripheral`), `BluetoothPeripheralType.mqType`, `CGMTransmitterType.mq` (`NoCalibrator`, `overruleIsWebOOPEnabled()` true so xDrip's calibration
button reaches `calibrate(calibration:)`; 3-minute readings, rated life 16 days, `sensorWarmupDurationInMinutes()` 0). **The vendor cloud is not ported** (`MQCloudClient`,
`MQCloudRecovery`, `MQCloudWorkQueue`, `MQFollowerManager`, `MQBootstrapClient`; no network call to the vendor), so the factory sensitivity, algorithm version, packages and
multiplier are not available: **no value is shown until the user types the sensitivity and its scale (used from packet 19; an unknown scale withholds the seed) or enters a
fingerstick (after packet 8)**, never a guessed slope. Defaults are JugglucoNG's built-ins (version 0, 720, 1.1) while its traces showed 1, 720, 1.0. A changed input bumps
`MQConfiguration.revision` and discards K/B at the next burst or calibration. The session is announced with `newSensorDetected` before the first value (calibration needs an
active sensor); `newSensorDetected` always replaces the active sensor, so call it once per session. A fingerstick on a packet that already has a value is a duplicate timestamp
for xDrip until the next packet. Accuracy was never compared with a reference (JugglucoNG records an unexplained excursion and vendor K/B adjustments it did not port); the
battery byte is raw, not a percentage. Pure cloud timing/restore policies are ported and tested but unused. Skipped on purpose: the cloud, learned CRC variant, frame
reassembly across notifications, source journal/replay, `protocolType` from the server (reset uses the observed Protocol02 marker only), native mirror, battery percentage, a
device picker, history beyond what the transmitter replays.

Ottai / Syai CGM (`docs/ottai.md`, JugglucoNG `drivers/ottai`; **uncompiled, never tried on a real sensor**):
`xDrip/BluetoothTransmitter/CGM/Ottai/OttaiProtocol.swift` (pure: BLE layout 180A/181F/E06E1D43, "BLE Auth V2" secp256r1 ECDH + SHA-256 signatures, AES-ECB zero-padded
payloads, 8/9-byte record parser, RPN glucose expression `OttaiFormula`, `OttaiOutputFilter`, `OttaiMaterials` portable JSON), `OttaiSession.swift` (`OttaiTiming`,
stream clock `OttaiArrivalStartCorrection`, `OttaiPipeline`, history window/chain, `OttaiCgmInfo`) and `CGMOttaiTransmitter.swift` (connection; `OttaiDeviceStore`
per-address state and the rejected-address list in UserDefaults, `OttaiMaterialsStore` the keys in the Keychain, one item per address plus a "pending" item the add
screen fills, adopted by the first sensor whose signature matches; all cleared with the peripheral; vectors in `OttaiProtocolTests`/`OttaiFormulaTests`/`OttaiSessionTests`
come from the unchanged Kotlin run on the JVM). Own Core Data entity `Ottai` (model `xdrip v43 Ottai` = v42 MQ + entity, only a link to `BLEPeripheral`),
`BluetoothPeripheralType.ottaiType`, `CGMTransmitterType.ottai` (`NoCalibrator`, 1-minute readings, `sensorWarmupDurationInMinutes()` 0, the pipeline withholds the first
10 minutes). **The six authentication keys and the per-sensor glucose coefficients exist only in the vendor cloud** (account that owns the sensor), so the driver never
contacts it and **shows a sensor as unsupported until the user imports the material** (JugglucoNG's portable JSON v1 from the clipboard, device screen or add screen);
nothing is guessed. Never port the cloud client (`OttaiCloudClient` sends spoofed forwarded-IP headers), `OttaiNetSecurity`, `OttaiRegionalTransport` or the phone-number login. A first signature that does
not match the material rejects the peripheral for good (address kept in `OttaiDeviceStore.rejectedAddresses`, max 20; importing other material forgives it); the manager
still creates a Core Data peripheral for it before the handshake (accepted). iOS has no MAC (the 12-digit sensor id comes from the material), no bond-state API, no way to tell a
read from a notification of `2AA7` (reads in flight counter), and a 185-byte MTU against Android's 247 (history frames may arrive truncated: the largest untested risk). The
transmitter owns its copy of the state: the screen calls `sensorMaterialsDidChange(removed:)` instead of writing the store. Skipped on purpose: the cloud, firmware/OTA,
activation of a new sensor (command status 0-2 only hangs up and retries after 5 minutes), NFC wake reminder, ended-sensor history, Room diff / persistent hole ledger,
provisional start from the CGM info, CN V3 server-mediated active authentication, native mirror, fingerstick calibration, battery, a device picker.

## Localisation

Ukrainian and English are complete; other languages are left as upstream has them. Every new
user-facing string needs an English default in code **and** a `uk.lproj` entry (same format
specifiers). SwiftUI `Text("literal")` looks the literal up in `Localizable.strings`, so add the
literal as a key there (en + uk); a `String` parameter is shown verbatim, so wrap literals with
`String(localized:)` or a `Texts_*` constant. Widgets only bundle `Common`/`HomeView`, the watch
`Common`/`HomeView`/`WatchApp`. PDF reports translate in code (`GlucoseReportText.ukrainian`);
speech uses `uk.lproj/SpeakReading.strings`; permission prompts `InfoPlist.strings`.

## Not ported (yet)

Automatic sensor handover (JugglucoNG `SensorHandoverRuntime`, `ManagedSensorHandoff`, `MultiSensorSelection`): not ported. It
relies on several sensors running at once and one of them taking over as primary when the other reaches its official end.
xDrip4iOS keeps exactly one active CGM transmitter and one active `Sensor`, so a switch at expiry would only automate what the
user does by hand and would not remove the gap the handover exists to close. It needs a multi-sensor architecture first.

NovoPen unattended background read: iOS opens an NFC session only on the user's tap (no background
ISO 7816 reading), so a pen is always read from the Insulin pens screen.

## Git

Develop on the session's designated branch; a merged PR is finished — restart the branch from
`master` for follow-up work. Do not push to `master` unless the user asks.
