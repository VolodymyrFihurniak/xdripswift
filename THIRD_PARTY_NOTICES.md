# Third-party notices

## JugglucoNG Sibionics V116A stock algorithm

The stock Sibionics V1.1.6A algorithm is adapted from [ctqvva/JugglucoNG](https://github.com/ctqvva/JugglucoNG), pinned to commit `34ad7bbdcf3b53d1690347738a6a70f6a985b251`, and licensed under the GNU General Public License version 3 (GPL-3.0). See the upstream revision's [LICENSE.txt](https://github.com/ctqvva/JugglucoNG/blob/34ad7bbdcf3b53d1690347738a6a70f6a985b251/LICENSE.txt). The repository is distributed under GPL-3.0 as well.

Adapted upstream source:
- `Sibionics2Core/src/commonMain/kotlin/tk/glucodata/drivers/sibionics/v116a/SibionicsExactV116A.kt` is the complete V116A state machine from `Common/src/main/java/tk/glucodata/drivers/sibionics/v116a/SibionicsExactV116A.kt`.
- `Sibionics2Core/src/commonMain/kotlin/tk/glucodata/drivers/sibionics/SibionicsNativeModels.kt` contains the two minimal DTOs used by that source.
- `Sibionics2Core/src/commonMain/kotlin/tk/glucodata/drivers/sibionics/Sibionics2V116AFacade.kt` is a new primitive-only Kotlin/Native bridge.

The algorithm source was adapted to common Kotlin: Java unsigned integer comparison became a sign-bit ordered comparison; Java unsigned decimal Long conversion became Kotlin ULong-to-Double conversion; `Math.pow` became `kotlin.math.pow`; and JVM-only hexadecimal formatting became common string formatting. Algorithm branches, constants, state layout, and outputs were not intentionally changed. The facade uses NaN to signal that the stock algorithm has not produced an exact correction.

The Sibionics probe sensitivity decoder in `xDrip/BluetoothTransmitter/CGM/Sibionics2/Sibionics2FactorySensitivity.swift` is behavior-adapted from JugglucoNG's `SibionicsProbeSensitivity.kt` and `SibionicsProtocol.kt`; the short decoder retains the original A/P-base checksum rules. No iGlucco source code is included.

## JugglucoNG V116A conformance fixture

The startup fixture and native-state vectors are adapted from the same pinned revision:
- `Common/src/test/resources/sibionics_exact_v116a_startup.csv`
- `Common/src/test/java/tk/glucodata/drivers/sibionics/SibionicsExactV116ACoreTest.kt`

`xDrip Tests/Fixtures/sibionics2_v116a_startup.csv` renames the CSV and adds attribution comments; all 130 numeric data rows are unchanged. Kotlin/JVM tests assert every exact-core row and selected state hashes/snapshot continuation. Swift XCTest specifies the xDrip wrapper behavior for every row in both live and replay modes, including the documented held-stock-delta rule. Timestamps, impedance, trend, and reindex are synthetic metadata because the source fixture does not contain them.
