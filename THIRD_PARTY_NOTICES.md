# Third-party notices

## JugglucoNG Sibionics V116A conformance fixture

The Sibionics 2 startup fixture and associated conformance-test expectations are adapted from [ctqvva/JugglucoNG](https://github.com/ctqvva/JugglucoNG), commit `34ad7bbdcf3b53d1690347738a6a70f6a985b251`, under the GNU General Public License version 3 (GPL-3.0). See that revision's [LICENSE.txt](https://github.com/ctqvva/JugglucoNG/blob/34ad7bbdcf3b53d1690347738a6a70f6a985b251/LICENSE.txt).

Upstream sources:
- `Common/src/test/resources/sibionics_exact_v116a_startup.csv`
- `Common/src/test/java/tk/glucodata/drivers/sibionics/SibionicsExactV116ACoreTest.kt`

Adapted files:
- `xDrip Tests/Fixtures/sibionics2_v116a_startup.csv`: renamed and prefixed with attribution comments; all 130 numeric data rows are unchanged.
- `xDrip Tests/Sibionics2GlucoseProcessorTests.swift`: Swift XCTest assertions against the required xDripSwift processor API, unit conversion, warm-up rejection, invalid-input rejection, and snapshot continuation. Timestamps, impedance, trend, and reindex are synthetic test metadata because the upstream CSV provides only index, raw mmol/L, temperature, and exact mmol/L.

These files are modified adaptations, not the original upstream files. No iGlucco source code is included. This tests-first contribution does not include a production V116A algorithm implementation.
