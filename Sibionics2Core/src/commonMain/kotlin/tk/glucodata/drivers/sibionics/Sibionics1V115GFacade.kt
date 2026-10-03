// Public primitive-only bridge for xDripSwift.
package tk.glucodata.drivers.sibionics

private const val MAXIMUM_SNAPSHOT_HEX_LENGTH = 16_384

/**
 * Keeps the stock V1.1.5G state machine behind a stable Kotlin/Native API.
 * A missing exact correction is represented as NaN; the S1 wrapper may use validated raw
 * glucose only until the first stock correction is available.
 */
class Sibionics1V115GFacade(sensitivity: Float) {
    private val core = SibionicsExactV115GCore(sensitivity)
    private var pendingRestoreBytes: ByteArray? = null
    private var expectedRestoreHexLength = 0
    private var appendedRestoreHexLength = 0

    fun configure(sensitivity: Float) = core.configure(sensitivity)

    fun reset() = core.reset()

    fun process(rawMmol: Float, temperatureC: Float, index: Int): Float =
        core.process(rawMmol, temperatureC, index) ?: Float.NaN

    /** Hex snapshots cross the Swift boundary in bounded chunks. */
    fun snapshotByteCount(): Int = core.snapshot().size

    fun snapshotHexChunk(offsetBytes: Int, lengthBytes: Int): String {
        val snapshot = core.snapshot()
        if (offsetBytes < 0 || lengthBytes <= 0 ||
            lengthBytes > snapshot.size || offsetBytes > snapshot.size - lengthBytes
        ) return ""
        return snapshot.copyOfRange(offsetBytes, offsetBytes + lengthBytes).toHex()
    }

    fun snapshotHex(): String = core.snapshot().toHex()

    fun beginRestoreHex(characterCount: Int): Boolean {
        discardPendingRestore()
        if (characterCount % 2 != 0 || characterCount !in 2..MAXIMUM_SNAPSHOT_HEX_LENGTH) {
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
            val high = chunk[index].digitToIntOrNull(16) ?: run {
                discardPendingRestore()
                return false
            }
            val low = chunk[index + 1].digitToIntOrNull(16) ?: run {
                discardPendingRestore()
                return false
            }
            val destination = (appendedRestoreHexLength + index) / 2
            bytes[destination] = ((high shl 4) or low).toByte()
        }
        appendedRestoreHexLength += chunk.length
        return true
    }

    fun finishRestoreHex(): Boolean {
        val bytes = pendingRestoreBytes ?: return false
        if (appendedRestoreHexLength != expectedRestoreHexLength) {
            discardPendingRestore()
            return false
        }
        discardPendingRestore()
        return core.restore(bytes)
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
