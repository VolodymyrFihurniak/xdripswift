# Sibionics 2 V116A core

This module vendors the complete stock V1.1.6A algorithm from ctqvva/JugglucoNG at commit `34ad7bbdcf3b53d1690347738a6a70f6a985b251`, under GPL-3.0, so the iOS app can use the same tested state machine instead of a guessed or fitted approximation. The copied algorithm has only the portability edits listed in `THIRD_PARTY_NOTICES.md`; BLE, sensitivity selection, input validation, live/replay correction state, persistence, unit conversion, and app delivery remain Swift code in xDrip.

Kotlin Multiplatform is a build bridge for the unchanged V116A core, not a move of the xDrip driver architecture. `commonMain` contains the core and minimal DTOs, `jvmTest` checks all 130 licensed fixture rows plus native state/snapshot vectors, and the iOS targets are combined into a static XCFramework.

The macOS workflow must build the framework before Xcode/Fastlane:

```sh
gradle -p Sibionics2Core assembleSibionics2CoreReleaseXCFramework
```

Gradle task: `assembleSibionics2CoreReleaseXCFramework`  
Output: `Sibionics2Core/build/XCFrameworks/release/Sibionics2Core.xcframework`

The build requires JDK 17 and an Apple host with Xcode command-line tools. This execution environment has neither Swift/Xcode nor Gradle/Kotlin, so those builds and tests have not been run here.
