// Portable stand-ins for the java.io data streams the Adaptive V2 snapshot code is written against.
package tk.glucodata.drivers.sibionics.adaptive2

/** Big-endian writer with the DataOutputStream calls Adaptive V2 uses. */
internal class DataOutputStream {
    private val bytes = ArrayList<Byte>()

    fun writeInt(value: Int) {
        for (shift in 24 downTo 0 step 8) bytes.add((value ushr shift).toByte())
    }

    fun writeLong(value: Long) {
        for (shift in 56 downTo 0 step 8) bytes.add((value ushr shift).toByte())
    }

    // The java.io writers canonicalise NaN, as toBits() does.
    fun writeFloat(value: Float) = writeInt(value.toBits())

    fun writeDouble(value: Double) = writeLong(value.toBits())

    fun writeBoolean(value: Boolean) { bytes.add(if (value) 1 else 0) }

    fun toByteArray(): ByteArray = bytes.toByteArray()
}

/** Big-endian reader; a truncated snapshot throws, as DataInputStream does. */
internal class DataInputStream(private val bytes: ByteArray) {
    private var offset = 0

    private fun readByte(): Int {
        require(offset < bytes.size) { "Truncated Adaptive V2 snapshot" }
        return bytes[offset++].toInt() and 0xff
    }

    fun readInt(): Int = (readByte() shl 24) or (readByte() shl 16) or (readByte() shl 8) or readByte()

    fun readLong(): Long = (readInt().toLong() shl 32) or (readInt().toLong() and 0xffffffffL)

    fun readFloat(): Float = Float.fromBits(readInt())

    fun readDouble(): Double = Double.fromBits(readLong())

    fun readBoolean(): Boolean = readByte() != 0

    fun available(): Int = bytes.size - offset
}
