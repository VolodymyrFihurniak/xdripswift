// Adapted from ctqvva/JugglucoNG a2070a6b7af03cc255e0b32f124c3200b13da30f (GPL-3.0).
// Column vendor_mmol is the proprietary output; exact_mmol is an older comparison.
package tk.glucodata.drivers.sibionics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SibionicsExactV115GCoreConformanceTest {
    @Test
    fun replayMatchesProprietaryV115GOutput() {
        val core = SibionicsExactV115GCore(decodedSensitivity = 1.40f)
        var displayCount = 0
        val selected = mapOf(25 to 0f, 30 to 16.8f, 35 to 6.1f)
        replayRows().forEach { row ->
            val actual = core.process(row.rawMmol, row.temperatureC, row.index)
            selected[row.index]?.let { expected ->
                assertNotNull(actual)
                assertEquals(expected, actual!!, 0.0001f)
            }
            if (row.exactMmol == null) {
                assertNull("unexpected display at index ${row.index}", actual)
            } else {
                displayCount++
                assertNotNull("missing display at index ${row.index}", actual)
                assertEquals("display at index ${row.index}", row.exactMmol, actual!!, 0.0001f)
            }
        }
        assertEquals(3_153, displayCount)
    }

    @Test
    fun snapshotRestoresExactStateMidReplay() {
        val rows = replayRows()
        val uninterrupted = SibionicsExactV115GCore(decodedSensitivity = 1.40f)
        val restored = SibionicsExactV115GCore(decodedSensitivity = 1.40f)
        val splitAt = rows.indexOfFirst { it.index == 7_500 }
        require(splitAt > 0)

        rows.take(splitAt).forEach { row ->
            uninterrupted.process(row.rawMmol, row.temperatureC, row.index)
        }
        val checkpoint = uninterrupted.snapshot()
        assertTrue(restored.restore(checkpoint))
        org.junit.Assert.assertArrayEquals(checkpoint, restored.snapshot())

        rows.drop(splitAt).forEach { row ->
            val expected = uninterrupted.process(row.rawMmol, row.temperatureC, row.index)
            val actual = restored.process(row.rawMmol, row.temperatureC, row.index)
            if (expected == null) {
                assertNull("restored non-display index ${row.index}", actual)
            } else {
                assertNotNull("restored missing display index ${row.index}", actual)
                assertEquals("restored display index ${row.index}", expected, actual!!, 0.0001f)
            }
        }
    }

    @Test
    fun restoresA11xCheckpointWithoutTheHeldStageTerms() {
        // 1.2 appended the held stage terms and bumped the version; rejecting the
        // 1.1.x checkpoint forced a replay of the sensor's whole life on update.
        val rows = replayRows()
        val uninterrupted = SibionicsExactV115GCore(decodedSensitivity = 1.40f)
        val restored = SibionicsExactV115GCore(decodedSensitivity = 1.40f)
        val splitAt = rows.indexOfFirst { it.index == 7_500 }
        require(splitAt > 0)
        rows.take(splitAt).forEach { row ->
            uninterrupted.process(row.rawMmol, row.temperatureC, row.index)
        }

        assertTrue(restored.restore(asPreObservationSnapshot(uninterrupted.snapshot())))

        rows.drop(splitAt).forEach { row ->
            val expected = uninterrupted.process(row.rawMmol, row.temperatureC, row.index)
            val actual = restored.process(row.rawMmol, row.temperatureC, row.index)
            if (expected == null) {
                assertNull("legacy-restored non-display index ${row.index}", actual)
            } else {
                assertNotNull("legacy-restored missing display index ${row.index}", actual)
                assertEquals("legacy-restored display index ${row.index}", expected, actual!!, 0.0001f)
            }
        }
    }

    @Test
    fun rejectsALegacyCheckpointForADifferentSensitivity() {
        val source = SibionicsExactV115GCore(decodedSensitivity = 1.40f)
        replayRows().take(200).forEach { source.process(it.rawMmol, it.temperatureC, it.index) }
        val other = SibionicsExactV115GCore(decodedSensitivity = 1.27f)
        assertFalse(other.restore(asPreObservationSnapshot(source.snapshot())))
    }

    /**
     * Rewrites a current (v3) snapshot into the 1.1.x (v2) layout: the same
     * fields without heldBase (f32), heldEsaCompensation (f32) and
     * hasStageState (bool), which sit just before the trailing clip block.
     */
    private fun asPreObservationSnapshot(current: ByteArray): ByteArray {
        val buffer = java.nio.ByteBuffer.wrap(current)
        val clipSize = (current.size - 4 downTo 1).first { size ->
            buffer.getInt(current.size - 4 - size) == size
        }
        val heldStart = current.size - 4 - clipSize - 9
        val legacy = current.copyOfRange(0, heldStart) + current.copyOfRange(heldStart + 9, current.size)
        java.nio.ByteBuffer.wrap(legacy).putInt(4, 2)
        return legacy
    }

    private fun replayRows(): List<ReplayRow> =
        resourceLines("sibionics1_v115g_replay.csv")
            .asSequence()
            .drop(1)
            .map { line ->
                val fields = line.split(',')
                val index = fields[0].toInt()
                ReplayRow(
                    index = index,
                    rawMmol = fields[1].toFloat(),
                    temperatureC = fields[2].toFloat(),
                    exactMmol = fields[3].toFloat().takeIf { index % 5 == 0 },
                )
            }
            .toList()

    private fun resourceLines(name: String): List<String> =
        javaClass.classLoader!!
            .getResourceAsStream(name)
            ?.bufferedReader()
            ?.use { it.readLines() }
            ?: error("missing Sibionics exact fixture $name")

    private data class ReplayRow(
        val index: Int,
        val rawMmol: Float,
        val temperatureC: Float,
        val exactMmol: Float?,
    )
}
