package tk.glucodata.drivers.sibionics

import kotlin.test.*
import tk.glucodata.drivers.sibionics.reference.ReferenceAdaptiveAlgorithmContext

class SibionicsAdaptiveV1Test {
    private data class Row(val index: Int, val rawMmol: Float, val temperatureC: Float)

    private fun replayRows(): List<Row> =
        javaClass.classLoader!!
            .getResourceAsStream("sibionics1_v115g_replay.csv")
            ?.bufferedReader()
            ?.useLines { lines ->
                lines.drop(1).map { line ->
                    val fields = line.split(',')
                    Row(fields[0].toInt(), fields[1].toFloat(), fields[2].toFloat())
                }.toList()
            }
            ?: error("missing Sibionics V115G replay fixture")

    private fun eventTime(index: Int) = 1_700_000_000_000L + index * 60_000L

    /** Synthetic inputs exercising warm-up, steady tracking, a fall and a temperature jump. */
    private fun synthetic(): List<FloatArray> = (1..400).map { index ->
        val stock = when {
            index < 200 -> 7f + 0.4f * kotlin.math.sin(index / 15f)
            index < 260 -> 7f - (index - 200) * 0.06f
            else -> 3.4f + (index - 260) * 0.02f
        }
        val chemical = stock * 1.05f + 0.2f + (if (index % 3 == 0) 0.05f else -0.03f)
        val temperature = if (index == 300) 38.5f else 34f
        floatArrayOf(index.toFloat(), stock, stock * 1.27f, temperature, 1000f + index, chemical)
    }

    @Test
    fun vendoredCopyMatchesJugglucoNGOutputsAndSnapshotBytes() {
        val vendored = SibionicsAdaptiveAlgorithmContext().also { it.configure(1.27f) }
        val reference = ReferenceAdaptiveAlgorithmContext().also { it.configure(1.27f) }
        for (sample in synthetic()) {
            val index = sample[0].toInt()
            val a = vendored.process(sample[1], sample[2], sample[3], sample[4], index, eventTime(index), emptyList(), sample[5], 0, sample[1])
            val b = reference.process(sample[1], sample[2], sample[3], sample[4], index, eventTime(index), emptyList(), sample[5], 0, sample[1])
            assertEquals(b.toBits(), a.toBits(), "minute $index")
            if (index % 50 == 0) assertContentEquals(reference.snapshot(), vendored.snapshot(), "snapshot at minute $index")
        }
        // A JugglucoNG snapshot restores into the vendored copy and the other way round.
        val fromReference = SibionicsAdaptiveAlgorithmContext().also { it.configure(1.27f) }
        assertTrue(fromReference.restore(reference.snapshot()))
        assertContentEquals(reference.snapshot(), fromReference.snapshot())
    }

    @Test
    fun facadeFollowsStockBeforeWarmUpAndContinuesFromItsSnapshot() {
        val rows = replayRows().take(1_500)
        val stock = Sibionics1V115GFacade(1.27f)
        val model = SibionicsAdaptiveV1Facade(1.27f)
        var stockMinutes = 0
        val outputs = rows.map { row ->
            val value = stock.process(row.rawMmol, row.temperatureC, row.index)
            if (!value.isFinite()) Float.NaN
            else {
                if (value > 0f) stockMinutes++
                stock.processAdaptiveV1(model, value, row.rawMmol, row.temperatureC, 1000f, row.index, eventTime(row.index))
            }
        }
        // A value for every minute with a usable stock value, never a new one.
        val finite = outputs.filter { it.isFinite() }
        assertTrue(stockMinutes > 100)
        assertEquals(stockMinutes, finite.size)
        assertTrue(finite.all { it in 1f..30f })

        // Snapshot halfway, continue both, and compare.
        val half = rows.size / 2
        val source = Sibionics1V115GFacade(1.27f)
        val sourceModel = SibionicsAdaptiveV1Facade(1.27f)
        fun step(core: Sibionics1V115GFacade, m: SibionicsAdaptiveV1Facade, row: Row): Float {
            val value = core.process(row.rawMmol, row.temperatureC, row.index)
            return if (!value.isFinite()) Float.NaN
            else core.processAdaptiveV1(m, value, row.rawMmol, row.temperatureC, 1000f, row.index, eventTime(row.index))
        }
        rows.take(half).forEach { step(source, sourceModel, it) }
        val restoredModel = SibionicsAdaptiveV1Facade(1.27f)
        assertTrue(restoredModel.restoreHex(sourceModel.snapshotHex()))
        val restoredCore = Sibionics1V115GFacade(1.27f)
        assertTrue(restoredCore.restoreHex(source.snapshotHex()))
        rows.drop(half).forEach { row ->
            assertEquals(step(source, sourceModel, row).toBits(), step(restoredCore, restoredModel, row).toBits())
        }
        assertFalse(SibionicsAdaptiveV1Facade(1.44f).restoreHex(sourceModel.snapshotHex()))
    }
}
