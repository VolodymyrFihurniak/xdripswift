package tk.glucodata.drivers.sibionics

import kotlin.test.*

class Sibionics1V115GFacadeTest {
    @Test
    fun facadeCarriesExactStateThroughChunkedSnapshotsAndReset() {
        val source = Sibionics1V115GFacade(1.4f)
        assertTrue(source.process(29.3f, 30.5f, 26).isNaN())
        val initial = Sibionics1V115GFacade(1.4f).snapshotHex()
        val hex = source.snapshotHex()
        val chunks = (0 until source.snapshotByteCount() step 256).map { offset ->
            source.snapshotHexChunk(offset, minOf(256, source.snapshotByteCount() - offset))
        }
        assertEquals(hex, chunks.joinToString(""))
        val target = Sibionics1V115GFacade(1.4f)
        assertTrue(target.beginRestoreHex(hex.length))
        chunks.forEach { assertTrue(target.appendRestoreHexChunk(it)) }
        assertTrue(target.finishRestoreHex())
        assertEquals(hex, target.snapshotHex())
        assertEquals(source.process(7.8f, 33.7f, 30), target.process(7.8f, 33.7f, 30))
        target.reset()
        assertEquals(initial, target.snapshotHex())
        assertFalse(target.restoreHex(hex.dropLast(2)))
        assertFalse(target.beginRestoreHex(16_386))
        assertFalse(target.beginRestoreHex(3))
        assertTrue(target.beginRestoreHex(2))
        assertFalse(target.appendRestoreHexChunk("zz"))
        assertFalse(target.finishRestoreHex())
        assertFalse(Sibionics2V116AFacade(1.4f).restoreHex(hex))
        assertFalse(Sibionics1V115GFacade(1.4f).restoreHex(Sibionics2V116AFacade(1.4f).snapshotHex()))
    }

    @Test
    fun commonSnapshotPrimitivesMatchJavaBigEndianBytes() {
        val bytes = java.io.ByteArrayOutputStream()
        val javaOutput = java.io.DataOutputStream(bytes)
        val common = V115GSnapshotWriter()
        for (value in listOf(0, 1, -1, Int.MIN_VALUE, Int.MAX_VALUE, 0x12345678)) {
            javaOutput.writeInt(value)
            common.writeInt(value)
        }
        for (value in listOf(0f, -0f, 1.4f, -23.5f, Float.POSITIVE_INFINITY, Float.NaN,
            Float.fromBits(0x7fa12345))) {
            javaOutput.writeFloat(value)
            common.writeFloat(value)
        }
        javaOutput.writeBoolean(true)
        javaOutput.writeBoolean(false)
        common.writeBoolean(true)
        common.writeBoolean(false)
        common.write(byteArrayOf(-1, 0, 1))
        javaOutput.write(byteArrayOf(-1, 0, 1))
        assertContentEquals(bytes.toByteArray(), common.toByteArray())
        val reader = V115GSnapshotReader(common.toByteArray())
        repeat(6) { reader.readInt() }
        val javaInput = java.io.DataInputStream(java.io.ByteArrayInputStream(bytes.toByteArray()))
        repeat(6) { javaInput.readInt() }
        repeat(7) { assertEquals(javaInput.readFloat().toBits(), reader.readFloat().toBits()) }
        assertTrue(reader.readBoolean())
        assertFalse(reader.readBoolean())
        val tail = ByteArray(3)
        reader.readFully(tail)
        assertContentEquals(byteArrayOf(-1, 0, 1), tail)
        assertEquals(0, reader.available())
        assertFails { reader.readInt() }
    }
}
