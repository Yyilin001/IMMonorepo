package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.ByteBuffer
import kotlin.test.*

class ProtocolTests {
    private val heartbeat = Envelope.newBuilder().setProtocolVersion(55).setRequestId(42).setHeartbeat(Heartbeat.newBuilder().setClientTimeMs(1)).build()
    @Test fun `header matches Swift big endian contract`() {
        val bytes = FrameCodec.encode(heartbeat)
        assertEquals("494d37000005000000000000002a00000008", bytes.take(18).joinToString("") { "%02x".format(it) })
        assertEquals(heartbeat, FrameCodec.read(ByteArrayInputStream(bytes)))
    }
    @Test fun `fragmented and coalesced stream reads preserve boundaries`() {
        val bytes = FrameCodec.encode(heartbeat) + FrameCodec.encode(heartbeat)
        val input = object : ByteArrayInputStream(bytes) {
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, minOf(1, len))
        }
        assertEquals(heartbeat, FrameCodec.read(input)); assertEquals(heartbeat, FrameCodec.read(input)); assertEquals(-1, input.read())
    }
    @Test fun `header mismatch unsupported flags and oversize fail closed`() {
        for (index in listOf(0, 2, 3, 5, 13)) {
            val bytes = FrameCodec.encode(heartbeat); bytes[index] = (bytes[index] + 1).toByte()
            assertFailsWith<ClientFailure.Protocol> { FrameCodec.read(ByteArrayInputStream(bytes)) }
        }
        val bytes = FrameCodec.encode(heartbeat); ByteBuffer.wrap(bytes).putInt(14, Int.MAX_VALUE)
        assertFailsWith<ClientFailure.Protocol> { FrameCodec.read(ByteArrayInputStream(bytes)) }
    }
    @Test fun `header binding only applies to group event pages`() {
        val message = Envelope.newBuilder().setProtocolVersion(55).setGroupEventPage(GroupEventPage.getDefaultInstance()).build()
        val bytes = FrameCodec.encode(message); bytes[3] = 2; ByteBuffer.wrap(bytes).putLong(6, 999)
        assertEquals(999, FrameCodec.read(ByteArrayInputStream(bytes)).requestId)
    }
    @Test fun `message fingerprint equals existing Swift golden vector`() {
        val command = MessageCommand.text(UserId("user-1"), RoomId("room-1"), "hello", 1000, "client-1")
        assertEquals("10a2d96f23b5dfd34684f2a50ac4c51c275286e9b072f86d807df1f7d0567e31", command.domainFingerprint.toByteArray().joinToString("") { "%02x".format(it) })
        assertNotEquals(command.fingerprint, MessageCommand.text(UserId("user-1"), RoomId("room-1"), "hello", 1001, "client-1").fingerprint)
    }
    @Test fun `UUID spelling canonicalizes without normalizing message text`() {
        val lower = "abcdefab-1234-5678-abcd-abcdefabcdef"
        assertEquals(RoomId(lower.uppercase()), RoomId(lower))
        assertEquals(DeviceId(lower.uppercase()), DeviceId(lower))
        val first = MessageCommand.text(UserId(lower), RoomId(lower), "é", 1000, lower)
        val second = MessageCommand.text(UserId(lower.uppercase()), RoomId(lower.uppercase()), "é", 1000, lower.uppercase())
        assertEquals(first, second)
        assertNotEquals(first.domainFingerprint, MessageCommand.text(UserId(lower), RoomId(lower), "e\u0301", 1000, lower).domainFingerprint)
        listOf("", "../path", "含中文", "a".repeat(129)).forEach { assertFailsWith<IllegalArgumentException> { RoomId(it) } }
    }
    @Test fun `immutable collection edits do not alter earlier snapshots`() {
        val original = ClientSnapshot()
        val next = original.copy(conversations = original.conversations.add(Conversation(RoomId("room"), "会话")))
        assertTrue(original.conversations.isEmpty()); assertEquals(1, next.conversations.size)
    }
}
