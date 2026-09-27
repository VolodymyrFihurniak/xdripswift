package tk.glucodata.drivers.sibionics.v116a

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import tk.glucodata.drivers.sibionics.Sibionics2V116AFacade

class SibionicsExactV116ACoreConformanceTest {
    @Test
    fun allStartupRowsMatchThePinnedV116AOutputAndStateVectors() {
        val rows = startupRows()
        assertEquals((1..130).toList(), rows.map { it.index })
        val core = SibionicsExactV116ACore(decodedSensitivity = 1.44f)
        val stateHashes = mapOf(
            1 to "c2fec42883fbfcab",
            2 to "f6b369ff13fd358e",
            5 to "0433deef56d902b4",
            50 to "36626f30fef1722b",
            80 to "b3c3dfb7bf444718",
            85 to "7e05a7636421942d",
            100 to "d825ee49e926eae3",
        )

        rows.forEach { row ->
            val actual = core.process(row.rawMmol, row.temperatureC, row.index)
            if (row.exactMmol == 0f) {
                assertNull(actual, "unexpected stock correction at index ${row.index}")
            } else {
                val exact = assertNotNull(actual, "missing stock correction at index ${row.index}")
                assertEquals(row.exactMmol, exact, 0.0001f,
                    "stock correction at index ${row.index}")
            }
            stateHashes[row.index]?.let { expected ->
                assertEquals(expected, core.stateHash(), "V116A state at index ${row.index}")
            }
        }
    }

    @Test
    fun snapshotAndLegacySnapshotResumeTheSameExactState() {
        val rows = startupRows()
        val source = SibionicsExactV116ACore(decodedSensitivity = 1.44f)
        rows.takeWhile { it.index <= 70 }.forEach { source.process(it.rawMmol, it.temperatureC, it.index) }

        val restored = SibionicsExactV116ACore(decodedSensitivity = 1.44f)
        assertTrue(restored.restore(source.snapshot()))
        rows.dropWhile { it.index <= 70 }.forEach { row ->
            assertEquals(source.process(row.rawMmol, row.temperatureC, row.index),
                restored.process(row.rawMmol, row.temperatureC, row.index))
            assertEquals(source.stateHash(), restored.stateHash())
            assertEquals(source.latestSensorObservation, restored.latestSensorObservation)
        }

        val legacySource = SibionicsExactV116ACore(decodedSensitivity = 1.44f)
        rows.takeWhile { it.index <= 70 }.forEach {
            legacySource.process(it.rawMmol, it.temperatureC, it.index)
        }
        val legacySnapshot = legacySource.snapshot().copyOfRange(0, 12 + 0x9ac).also { it[4] = 1 }
        val legacyRestored = SibionicsExactV116ACore(decodedSensitivity = 1.44f)
        assertTrue(legacyRestored.restore(legacySnapshot))
        rows.dropWhile { it.index <= 70 }.forEach { row ->
            assertEquals(legacySource.process(row.rawMmol, row.temperatureC, row.index),
                legacyRestored.process(row.rawMmol, row.temperatureC, row.index))
            assertEquals(legacySource.stateHash(), legacyRestored.stateHash())
        }
    }

    @Test
    fun facadeSnapshotChunksRestoreExactState() {
        val rows = startupRows()
        val source = Sibionics2V116AFacade(sensitivity = 1.44f)
        rows.take(70).forEach { source.process(it.rawMmol, it.temperatureC, it.index) }

        val snapshotByteCount = source.snapshotByteCount()
        assertEquals(2_504, snapshotByteCount)
        val hex = buildString {
            var offset = 0
            while (offset < snapshotByteCount) {
                val chunkByteCount = minOf(256, snapshotByteCount - offset)
                val chunk = source.snapshotHexChunk(offset, chunkByteCount)
                assertEquals(chunkByteCount * 2, chunk.length)
                append(chunk)
                offset += chunkByteCount
            }
        }
        assertEquals(snapshotByteCount * 2, hex.length)

        val restored = Sibionics2V116AFacade(sensitivity = 1.44f)
        assertTrue(restored.beginRestoreHex(hex.length))
        hex.chunked(512).forEach { assertTrue(restored.appendRestoreHexChunk(it)) }
        assertTrue(restored.finishRestoreHex())

        rows.drop(70).forEach { row ->
            val expected = source.process(row.rawMmol, row.temperatureC, row.index)
            val actual = restored.process(row.rawMmol, row.temperatureC, row.index)
            if (expected.isNaN()) {
                assertTrue(actual.isNaN(), "facade output at index ${row.index}")
            } else {
                assertEquals(expected, actual, 0.0001f, "facade output at index ${row.index}")
            }
        }
    }

    @Test
    fun invalidCheckpointIsRejected() {
        val source = SibionicsExactV116ACore(decodedSensitivity = 1.44f)
        startupRows().take(20).forEach { source.process(it.rawMmol, it.temperatureC, it.index) }
        val snapshot = source.snapshot()
        assertFalse(SibionicsExactV116ACore(1.44f).restore(snapshot.copyOfRange(0, 12 + 0x9ac)))
        assertFalse(SibionicsExactV116ACore(1.44f).restore(snapshot.copyOf().also { it[4] = 9 }))
        assertFalse(SibionicsExactV116ACore(1.45f).restore(snapshot))
    }

    private fun startupRows(): List<Row> =
        javaClass.classLoader!!
            .getResourceAsStream("sibionics2_v116a_startup.csv")
            ?.bufferedReader()
            ?.useLines { lines ->
                lines.filterNot { it.startsWith("#") }.drop(1).map { line ->
                    val fields = line.split(',')
                    Row(fields[0].toInt(), fields[1].toFloat(), fields[2].toFloat(), fields[3].toFloat())
                }.toList()
            }
            ?: error("missing Sibionics V116A startup fixture")

    private data class Row(
        val index: Int,
        val rawMmol: Float,
        val temperatureC: Float,
        val exactMmol: Float,
    )
}
