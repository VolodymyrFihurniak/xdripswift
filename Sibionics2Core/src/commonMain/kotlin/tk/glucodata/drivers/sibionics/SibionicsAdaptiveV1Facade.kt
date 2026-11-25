// Public primitive-only bridge to JugglucoNG's Adaptive V1 ("state model") for xDripSwift.
package tk.glucodata.drivers.sibionics

private const val MAXIMUM_ADAPTIVE_SNAPSHOT_HEX_LENGTH = 16_384

/**
 * Adaptive V1 beside a stock core. The stock facade hands over its stock value and the vendor's
 * compensated chemical signal of the sample it has just processed
 * ([Sibionics2V116AFacade.processAdaptiveV1], [Sibionics1V115GFacade.processAdaptiveV1]).
 * Before minute 120, or without a chemical signal, the result is the stock value itself, as in
 * JugglucoNG; NaN only when the stock value is unusable.
 */
class SibionicsAdaptiveV1Facade(sensitivity: Float) {
    private val context = SibionicsAdaptiveAlgorithmContext().also { it.configure(sensitivity) }
    private var pendingRestoreBytes: ByteArray? = null
    private var expectedRestoreHexLength = 0
    private var appendedRestoreHexLength = 0

    fun configure(sensitivity: Float) = context.configure(sensitivity)

    fun reset() = context.reset()

    internal fun process(
        stockMmol: Float,
        rawMmol: Float,
        temperatureC: Float,
        impedance: Float,
        index: Int,
        eventTimeMs: Long,
        chemical: SibionicsChemicalSignal?,
    ): Float = context.process(
        stockMmol = stockMmol,
        rawMmol = rawMmol,
        temperatureC = temperatureC,
        impedance = impedance,
        index = index,
        eventTimeMs = eventTimeMs,
        anchors = emptyList(),
        chemicalMmol = chemical?.mmol ?: Float.NaN,
        chemicalQualityFlags = chemical?.qualityFlags ?: 0,
        vendorStockMmol = stockMmol,
    )

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
