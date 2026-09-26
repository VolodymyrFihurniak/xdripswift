// Minimal cross-platform DTOs required by the pinned V116A core.
// Adapted from ctqvva/JugglucoNG, commit 34ad7bbdcf3b53d1690347738a6a70f6a985b251 (GPL-3.0).
package tk.glucodata.drivers.sibionics

internal data class SibionicsChemicalSignal(
    val mmol: Float,
    val qualityFlags: Int,
)

internal data class SibionicsSensorObservation(
    val calibratedMmol: Float,
    val chemicalMmol: Float,
    val sensorStateCompensationMmol: Float,
    val qualityFlags: Int,
    val factorySensitivity: Float,
    val activeSensitivity: Float,
    val sensorAgeMinutes: Int,
    val family: Int,
) {
    val isUsable: Boolean
        get() = calibratedMmol.isFinite() && calibratedMmol > 0f &&
            activeSensitivity.isFinite() && activeSensitivity > 0f
}
