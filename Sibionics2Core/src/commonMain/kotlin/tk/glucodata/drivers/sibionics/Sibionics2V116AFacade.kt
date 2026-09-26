// Public primitive-only bridge for xDripSwift.
package tk.glucodata.drivers.sibionics

import tk.glucodata.drivers.sibionics.v116a.SibionicsExactV116ACore

/**
 * Keeps the stock V1.1.6A state machine behind a stable Kotlin/Native API.
 * A missing exact correction is represented as NaN; callers must never use
 * raw sensor glucose as a fallback.
 */
class Sibionics2V116AFacade(sensitivity: Float) {
    private val core = SibionicsExactV116ACore(sensitivity)

    fun configure(sensitivity: Float) = core.configure(sensitivity)

    fun reset() = core.reset()

    fun process(rawMmol: Float, temperatureC: Float, index: Int): Float =
        core.process(rawMmol, temperatureC, index) ?: Float.NaN

    /** Hex keeps the Swift boundary independent from KotlinByteArray APIs. */
    fun snapshotHex(): String = core.snapshot().toHex()

    fun restoreHex(snapshot: String): Boolean {
        if (snapshot.length % 2 != 0 || snapshot.length !in 2..16_384) return false
        val bytes = ByteArray(snapshot.length / 2)
        for (i in bytes.indices) {
            val high = snapshot[i * 2].digitToIntOrNull(16) ?: return false
            val low = snapshot[i * 2 + 1].digitToIntOrNull(16) ?: return false
            bytes[i] = ((high shl 4) or low).toByte()
        }
        return core.restore(bytes)
    }

    private fun ByteArray.toHex(): String {
        val digits = "0123456789abcdef"
        return buildString(size * 2) {
            for (byte in this@toHex) {
                val value = byte.toInt() and 0xff
                append(digits[value ushr 4])
                append(digits[value and 0x0f])
            }
        }
    }
}
