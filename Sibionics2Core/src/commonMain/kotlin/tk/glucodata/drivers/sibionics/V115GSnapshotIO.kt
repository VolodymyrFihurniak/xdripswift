package tk.glucodata.drivers.sibionics

/** Big-endian equivalents of the Java data-stream primitives used by V115G. */
internal class V115GSnapshotWriter {
    private val bytes = ArrayList<Byte>()

    fun writeInt(value: Int) {
        for (shift in 24 downTo 0 step 8) bytes.add((value ushr shift).toByte())
    }

    // DataOutputStream.writeFloat canonicalizes NaN, unlike toRawBits().
    fun writeFloat(value: Float) = writeInt(value.toBits())

    fun writeBoolean(value: Boolean) { bytes.add(if (value) 1 else 0) }

    fun write(value: ByteArray) { value.forEach { bytes.add(it) } }

    fun toByteArray(): ByteArray = bytes.toByteArray()
}

internal class V115GSnapshotReader(private val bytes: ByteArray) {
    private var offset = 0

    private fun readByte(): Int {
        require(offset < bytes.size) { "Truncated V115G snapshot" }
        return bytes[offset++].toInt() and 0xff
    }

    fun readInt(): Int = (readByte() shl 24) or (readByte() shl 16) or
        (readByte() shl 8) or readByte()

    fun readFloat(): Float = Float.fromBits(readInt())

    fun readBoolean(): Boolean = readByte() != 0

    fun readFully(destination: ByteArray) {
        require(destination.size <= available()) { "Truncated V115G snapshot" }
        bytes.copyInto(destination, startIndex = offset, endIndex = offset + destination.size)
        offset += destination.size
    }

    fun available(): Int = bytes.size - offset
}
