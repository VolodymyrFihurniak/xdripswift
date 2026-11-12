package tk.glucodata.drivers.sibionics

import kotlin.math.abs
import kotlin.test.*

class SibionicsAdaptiveV2FacadeTest {
    private data class Row(val index: Int, val rawMmol: Float, val temperatureC: Float)

    private fun startupRows(): List<Row> =
        javaClass.classLoader!!
            .getResourceAsStream("sibionics2_v116a_startup.csv")
            ?.bufferedReader()
            ?.useLines { lines ->
                lines.filterNot { it.startsWith("#") }.drop(1).map { line ->
                    val fields = line.split(',')
                    Row(fields[0].toInt(), fields[1].toFloat(), fields[2].toFloat())
                }.toList()
            }
            ?: error("missing Sibionics V116A startup fixture")

    private fun eventTime(index: Int) = 1_700_000_000_000L + index * 60_000L

    private fun run(rows: List<Row>, stock: Sibionics2V116AFacade, v2: SibionicsAdaptiveV2Facade): List<Float> =
        rows.map { row ->
            stock.process(row.rawMmol, row.temperatureC, row.index)
            stock.processAdaptiveV2(v2, row.temperatureC, 1000f, eventTime(row.index))
        }

    @Test
    fun estimatesEveryMinuteOnceTheStockCoreHasAnObservation() {
        val rows = startupRows()
        val stock = Sibionics2V116AFacade(1.4f)
        val v2 = SibionicsAdaptiveV2Facade(1.4f)
        assertTrue(v2.latestLower90Mmol().isNaN())
        val estimates = run(rows, stock, v2)
        // No observation before the stock core's first correction.
        assertTrue(estimates.take(4).all { it.isNaN() })
        assertTrue(estimates.drop(4).all { it.isFinite() && it > 1f && it < 30f })
        // The estimate sits inside its own 90 % interval.
        assertTrue(v2.latestLower90Mmol() <= estimates.last() && estimates.last() <= v2.latestUpper90Mmol())
        assertTrue(v2.latestConfidence() in 0f..1f)
        // By the end of the fixture the estimate and the stock value agree to within 0.5 mmol/L.
        val lastStock = Sibionics2V116AFacade(1.4f).let { again -> rows.map { again.process(it.rawMmol, it.temperatureC, it.index) }.last() }
        assertTrue(abs(estimates.last() - lastStock) < 0.5f, "estimate ${estimates.last()} stock $lastStock")
    }

    @Test
    fun sameInputsGiveTheSameEstimates() {
        val rows = startupRows()
        val first = run(rows, Sibionics2V116AFacade(1.4f), SibionicsAdaptiveV2Facade(1.4f))
        val second = run(rows, Sibionics2V116AFacade(1.4f), SibionicsAdaptiveV2Facade(1.4f))
        assertEquals(first.map { it.toBits() }, second.map { it.toBits() })
    }

    @Test
    fun chunkedSnapshotContinuesTheFilterExactly() {
        val rows = startupRows()
        val stock = Sibionics2V116AFacade(1.4f)
        val v2 = SibionicsAdaptiveV2Facade(1.4f)
        run(rows.take(80), stock, v2)

        val hex = v2.snapshotHex()
        assertTrue(hex.length <= 16_384)
        val chunks = (0 until v2.snapshotByteCount() step 256).map { offset ->
            v2.snapshotHexChunk(offset, minOf(256, v2.snapshotByteCount() - offset))
        }
        assertEquals(hex, chunks.joinToString(""))
        val restoredStock = Sibionics2V116AFacade(1.4f)
        assertTrue(restoredStock.restoreHex(stock.snapshotHex()))
        val restored = SibionicsAdaptiveV2Facade(1.4f)
        assertTrue(restored.beginRestoreHex(hex.length))
        chunks.forEach { assertTrue(restored.appendRestoreHexChunk(it)) }
        assertTrue(restored.finishRestoreHex())
        assertEquals(hex, restored.snapshotHex())

        val expected = run(rows.drop(80), stock, v2)
        val actual = run(rows.drop(80), restoredStock, restored)
        assertEquals(expected.map { it.toBits() }, actual.map { it.toBits() })
    }

    @Test
    fun rejectedSnapshotLeavesAFreshEstimator() {
        val rows = startupRows()
        val v2 = SibionicsAdaptiveV2Facade(1.4f)
        run(rows.take(40), Sibionics2V116AFacade(1.4f), v2)
        val hex = v2.snapshotHex()
        val initial = SibionicsAdaptiveV2Facade(1.4f).snapshotHex()

        assertFalse(v2.restoreHex(hex.dropLast(2)))
        assertEquals(initial, v2.snapshotHex())
        assertFalse(v2.restoreHex("00" + hex.drop(2)))
        assertFalse(v2.restoreHex(hex + "00"))
        assertFalse(v2.beginRestoreHex(3))
        assertFalse(v2.beginRestoreHex(16_386))
        assertTrue(v2.beginRestoreHex(2))
        assertFalse(v2.appendRestoreHexChunk("zz"))
        assertFalse(v2.finishRestoreHex())
        assertTrue(v2.restoreHex(hex))
        v2.reset()
        assertEquals(initial, v2.snapshotHex())
    }

    @Test
    fun chineseStockCoreFeedsTheEstimatorToo() {
        val stock = Sibionics1V115GFacade(1.27f)
        val v2 = SibionicsAdaptiveV2Facade(1.27f)
        var finite = 0
        for (index in 1..180) {
            val raw = 6.0f + (index % 30) * 0.05f
            stock.process(raw, 34.0f, index)
            val estimate = stock.processAdaptiveV2(v2, 34.0f, Float.NaN, eventTime(index))
            if (estimate.isFinite()) {
                finite++
                assertTrue(estimate > 1f && estimate < 30f, "estimate $estimate at $index")
            }
        }
        assertTrue(finite > 100, "only $finite estimates")
    }

    @Test
    fun snapshotPrimitivesMatchJavaBigEndianBytes() {
        val bytes = java.io.ByteArrayOutputStream()
        val javaOutput = java.io.DataOutputStream(bytes)
        val common = tk.glucodata.drivers.sibionics.adaptive2.DataOutputStream()
        val doubles = listOf(0.0, -0.0, 1.4, -23.5e-7, Double.MAX_VALUE, Double.NEGATIVE_INFINITY, Double.NaN)
        val longs = listOf(0L, -1L, Long.MIN_VALUE, Long.MAX_VALUE, 0x0123456789abcdefL)
        javaOutput.writeInt(0x12345678); common.writeInt(0x12345678)
        longs.forEach { javaOutput.writeLong(it); common.writeLong(it) }
        doubles.forEach { javaOutput.writeDouble(it); common.writeDouble(it) }
        javaOutput.writeFloat(1.27f); common.writeFloat(1.27f)
        javaOutput.writeBoolean(true); common.writeBoolean(true)
        assertContentEquals(bytes.toByteArray(), common.toByteArray())

        val reader = tk.glucodata.drivers.sibionics.adaptive2.DataInputStream(common.toByteArray())
        assertEquals(0x12345678, reader.readInt())
        longs.forEach { assertEquals(it, reader.readLong()) }
        doubles.forEach { assertEquals(it.toBits(), reader.readDouble().toBits()) }
        assertEquals(1.27f, reader.readFloat())
        assertTrue(reader.readBoolean())
        assertEquals(0, reader.available())
        assertFails { reader.readInt() }
    }
}
