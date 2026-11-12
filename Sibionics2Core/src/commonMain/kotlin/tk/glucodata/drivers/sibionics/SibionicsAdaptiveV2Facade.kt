// Public primitive-only bridge to JugglucoNG's Adaptive V2 estimator for xDripSwift.
package tk.glucodata.drivers.sibionics

import tk.glucodata.drivers.sibionics.adaptive2.SibionicsAdaptiveV2Context

private const val MAXIMUM_ADAPTIVE_SNAPSHOT_HEX_LENGTH = 16_384

/**
 * Adaptive V2 beside a stock core. The stock facade hands over the vendor's
 * sensor-state-calibrated observation of the sample it has just processed
 * ([Sibionics2V116AFacade.processAdaptiveV2], [Sibionics1V115GFacade.processAdaptiveV2]);
 * a sample without a usable observation or estimate is NaN, and the caller
 * keeps the stock value for it without feeding it back into the estimator.
 */
class SibionicsAdaptiveV2Facade(sensitivity: Float) {
    private val context = SibionicsAdaptiveV2Context().also { it.configure(sensitivity) }
    private var pendingRestoreBytes: ByteArray? = null
    private var expectedRestoreHexLength = 0
    private var appendedRestoreHexLength = 0

    fun configure(sensitivity: Float) = context.configure(sensitivity)

    fun reset() = context.reset()

    internal fun process(
        observation: SibionicsSensorObservation?,
        temperatureC: Float,
        impedance: Float,
        eventTimeMs: Long,
    ): Float {
        if (observation == null || !observation.isUsable) return Float.NaN
        val estimate = context.process(observation, temperatureC, impedance, eventTimeMs)
        return if (estimate != null && estimate.isUsable) estimate.glucoseMmol else Float.NaN
    }

    /** Bounds of the latest estimate's 90 % interval and its confidence; NaN before the first estimate. */
    fun latestLower90Mmol(): Float = context.latestEstimate()?.lower90Mmol ?: Float.NaN

    fun latestUpper90Mmol(): Float = context.latestEstimate()?.upper90Mmol ?: Float.NaN

    fun latestConfidence(): Float = context.latestEstimate()?.confidence ?: Float.NaN

    /** Hex snapshots cross the Swift boundary in bounded chunks. */
    fun snapshotByteCount(): Int = context.snapshot().size

    fun snapshotHexChunk(offsetBytes: Int, lengthBytes: Int): String {
        val snapshot = context.snapshot()
        if (offsetBytes < 0 || lengthBytes <= 0 ||
            lengthBytes > snapshot.size || offsetBytes > snapshot.size - lengthBytes
        ) return ""
        return snapshot.copyOfRange(offsetBytes, offsetBytes + lengthBytes).toHex()
    }

    fun snapshotHex(): String = context.snapshot().toHex()

    fun beginRestoreHex(characterCount: Int): Boolean {
        discardPendingRestore()
        if (characterCount % 2 != 0 || characterCount !in 2..MAXIMUM_ADAPTIVE_SNAPSHOT_HEX_LENGTH) {
            return false
        }
        pendingRestoreBytes = ByteArray(characterCount / 2)
        expectedRestoreHexLength = characterCount
        return true
    }

    fun appendRestoreHexChunk(chunk: String): Boolean {
        val bytes = pendingRestoreBytes ?: return false
        if (chunk.isEmpty() || chunk.length % 2 != 0 ||
            chunk.length > expectedRestoreHexLength - appendedRestoreHexLength
        ) {
            discardPendingRestore()
            return false
        }
        for (index in chunk.indices step 2) {
            val high = chunk[index].digitToIntOrNull(16)
            val low = chunk[index + 1].digitToIntOrNull(16)
            if (high == null || low == null) {
                discardPendingRestore()
                return false
            }
            bytes[(appendedRestoreHexLength + index) / 2] = ((high shl 4) or low).toByte()
        }
        appendedRestoreHexLength += chunk.length
        return true
    }

    /** A snapshot the estimator cannot vouch for leaves it reset, to start again from the next sample. */
    fun finishRestoreHex(): Boolean {
        val bytes = pendingRestoreBytes ?: return false
        if (appendedRestoreHexLength != expectedRestoreHexLength) {
            discardPendingRestore()
            return false
        }
        discardPendingRestore()
        return context.restore(bytes)
    }

    fun restoreHex(snapshot: String): Boolean {
        if (!beginRestoreHex(snapshot.length)) return false
        if (!appendRestoreHexChunk(snapshot)) return false
        return finishRestoreHex()
    }

    private fun discardPendingRestore() {
        pendingRestoreBytes = null
        expectedRestoreHexLength = 0
        appendedRestoreHexLength = 0
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
