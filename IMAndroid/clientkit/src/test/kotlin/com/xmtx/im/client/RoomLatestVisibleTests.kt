package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class RoomLatestVisibleTests {
    private val room=RoomId("00000000-0000-0000-0000-000000000001")
    private val message="00000000-0000-0000-0000-000000000002"
    private val sender="00000000-0000-0000-0000-000000000003"
    private fun snapshot()=RoomLatestVisibleSnapshot.newBuilder().setOwnerEpoch(1).setViewerMembershipRevision(2).setHead(10)
        .setLatest(RoomLatestVisibleMessage.newBuilder().setMessageId(message).setSenderUserId(sender).setRoomSequence(8).setMessageRevision(1).setPreview("最新摘要").setCreatedAtMs(100))
    private fun result(value: RoomLatestVisibleSnapshot.Builder=snapshot())=RoomLatestVisibleResult.newBuilder().setRoomId(room.value).setSnapshot(value)
    private class Wire(var response: Envelope): EnvelopeTransport {
        var request: Envelope?=null
        override suspend fun request(body: Envelope.Builder): Envelope {request=body.build();return response}
    }
    private fun envelope(vararg items: RoomLatestVisibleResult.Builder)=Envelope.newBuilder().setRoomLatestVisibleBatchResult(RoomLatestVisibleBatchResult.newBuilder().addAllRooms(items.map {it.build()})).build()
    @Test fun `batch normalizes deduplicates and binds explicit results to every requested room`()=runTest {
        val wire=Wire(envelope(result()));val client=RoomLatestVisibleClient(wire)
        val got=client.fetch(persistentListOf(room,room)).getValue(room) as LatestVisibleResult.Snapshot
        assertEquals(1,wire.request!!.roomLatestVisibleBatch.roomIdsCount);assertEquals(10,got.value.head);assertEquals("最新摘要",got.value.previewText)
        wire.response=envelope(result(),result());assertFailsWith<ClientFailure.Protocol> {client.fetch(persistentListOf(room))}
        wire.response=envelope(result().setRoomId(sender));assertFailsWith<ClientFailure.Protocol> {client.fetch(persistentListOf(room))}
        wire.response=envelope();assertFailsWith<ClientFailure.Protocol> {client.fetch(persistentListOf(room))}
    }
    @Test fun `empty observation and attachment only preview remain explicit immutable values`()=runTest {
        val wire=Wire(envelope(result(snapshot().clearLatest())));val client=RoomLatestVisibleClient(wire)
        val empty=(client.fetch(persistentListOf(room)).getValue(room) as LatestVisibleResult.Snapshot).value
        assertNull(empty.latest);assertEquals("暂无消息",empty.previewText)
        wire.response=envelope(result(snapshot().apply {latest=latest.toBuilder().setPreview("").setMediaCount(1).build()}))
        val media=(client.fetch(persistentListOf(room)).getValue(room) as LatestVisibleResult.Snapshot).value
        assertEquals("[附件]",media.previewText);assertNull(empty.latest)
    }
    @Test fun `uint fields preserve full retry and media range while signed persistence bounds are rejected`()=runTest {
        val wire=Wire(envelope(result().clearSnapshot().setRetry(RoomSyncStateRetry.newBuilder().setRetryAfterSeconds(-1))));val client=RoomLatestVisibleClient(wire)
        assertEquals(4_294_967_295_000L,(client.fetch(persistentListOf(room)).getValue(room) as LatestVisibleResult.Retry).afterMillis)
        wire.response=envelope(result(snapshot().apply {latest=latest.toBuilder().setMediaCount(-1).build()}))
        assertEquals(4_294_967_295L,(client.fetch(persistentListOf(room)).getValue(room) as LatestVisibleResult.Snapshot).value.latest!!.mediaCount)
        for(bad in listOf(snapshot().setHead(-1),snapshot().setOwnerEpoch(-1),snapshot().setViewerMembershipRevision(-1),snapshot().setHead(7))) {
            wire.response=envelope(result(bad));assertFailsWith<ClientFailure.Protocol> {client.fetch(persistentListOf(room))}
        }
    }
    @Test fun `latest identities positive revisions and UTF8 preview limit match Swift contract`()=runTest {
        val wire=Wire(envelope(result()));val client=RoomLatestVisibleClient(wire)
        val valid=snapshot().latest
        for(bad in listOf(valid.toBuilder().setMessageId("bad"),valid.toBuilder().setSenderUserId("bad"),valid.toBuilder().setMessageRevision(0),
            valid.toBuilder().setRoomSequence(0),valid.toBuilder().setPreview("界".repeat(171)))) {
            wire.response=envelope(result(snapshot().setLatest(bad)))
            assertTrue(runCatching {client.fetch(persistentListOf(room))}.isFailure)
        }
        wire.response=envelope(result(snapshot().setLatest(valid.toBuilder().setPreview("界".repeat(170)).setCreatedAtMs(-1))))
        assertEquals(-1,(client.fetch(persistentListOf(room)).getValue(room) as LatestVisibleResult.Snapshot).value.latest!!.createdAt)
    }
    @Test fun `unavailable retry zero and missing result are distinct`()=runTest {
        val wire=Wire(envelope(result().clearSnapshot().setUnavailable(RoomSyncStateUnavailable.getDefaultInstance())));val client=RoomLatestVisibleClient(wire)
        assertEquals(LatestVisibleResult.Unavailable,client.fetch(persistentListOf(room)).getValue(room))
        wire.response=envelope(result().clearSnapshot().setRetry(RoomSyncStateRetry.getDefaultInstance()))
        assertEquals(LatestVisibleResult.Retry(1_000),client.fetch(persistentListOf(room)).getValue(room))
        wire.response=envelope(result().clearSnapshot());assertFailsWith<ClientFailure.Protocol> {client.fetch(persistentListOf(room))}
    }
}
