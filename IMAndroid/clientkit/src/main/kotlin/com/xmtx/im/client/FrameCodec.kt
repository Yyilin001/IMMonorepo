package com.xmtx.im.client

import com.google.protobuf.CodedInputStream
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import java.io.DataInputStream
import java.io.InputStream
import java.nio.ByteBuffer

/** Matches IMV2Core's 18-byte big-endian frame. Does not negotiate compression implicitly. */
object FrameCodec {
    const val VERSION = 55
    const val HEADER_SIZE = 18
    const val MAX_PAYLOAD = 65_536
    fun command(envelope: Envelope): Int = when (val body = envelope.bodyCase.number) {
        in 10..15 -> body - 9
        0 -> throw ClientFailure.Protocol()
        else -> body
    }
    fun encode(envelope: Envelope, version: Int = VERSION): ByteArray {
        require(version == VERSION || (version == 0 && envelope.hasClientHello()))
        require(envelope.protocolVersion == version)
        val payload = envelope.toByteArray()
        require(payload.size <= MAX_PAYLOAD)
        if(envelope.hasAuthorPresentationDelta()) require(envelope.requestId==0L &&
            envelope.authorPresentationDelta.payload.size()<=AuthorPresentationDelta.MaximumEncodedBytes &&
            payload.size+HEADER_SIZE<=AuthorPresentationDelta.MaximumFrameBytes)
        return ByteBuffer.allocate(HEADER_SIZE + payload.size).putShort(0x494D).put(version.toByte()).put(0)
            .putShort(command(envelope).toShort()).putLong(envelope.requestId).putInt(payload.size).put(payload).array()
    }
    fun read(stream: InputStream): Envelope {
        val input = DataInputStream(stream)
        if (input.readUnsignedShort() != 0x494D) throw ClientFailure.Protocol()
        val version = input.readUnsignedByte()
        val flags = input.readUnsignedByte()
        val command = input.readUnsignedShort()
        val requestId = input.readLong()
        val length = input.readInt()
        if (version != VERSION || length !in 0..MAX_PAYLOAD || flags !in setOf(0, 2) ||
            (flags == 2 && command != 62)) throw ClientFailure.Protocol()
        if(command==121 && (requestId!=0L || length+HEADER_SIZE>AuthorPresentationDelta.MaximumFrameBytes)) throw ClientFailure.Protocol()
        val bytes = ByteArray(length); input.readFully(bytes)
        val coded = CodedInputStream.newInstance(bytes).apply { setRecursionLimit(32); setSizeLimit(MAX_PAYLOAD) }
        val envelope = Envelope.parseFrom(coded)
        if(envelope.hasAuthorPresentationDelta() && envelope.authorPresentationDelta.payload.size()>AuthorPresentationDelta.MaximumEncodedBytes) throw ClientFailure.Protocol()
        if (envelope.protocolVersion != version || command(envelope) != command ||
            envelope.requestId != if (flags == 2) 0L else requestId) throw ClientFailure.Protocol()
        return if (flags == 2) envelope.toBuilder().setRequestId(requestId).build() else envelope
    }
}
