package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AccountRoomRecoveryTests {
    private val id="00000000-0000-0000-0000-000000000001"
    @Test fun `head merge retains maximum sequence and rejects conflicting or regressing membership`() {
        val head=AccountRoomHead(RoomId(id),10,3)
        assertEquals(head,head.merging(head.copy(sequence=9,membershipRevision=4)))
        assertEquals(head,head.merging(head.copy()))
        assertEquals(11,head.merging(head.copy(sequence=11,membershipRevision=4)).sequence)
        assertFailsWith<ClientFailure.Protocol> {head.merging(head.copy(membershipRevision=4))}
        assertFailsWith<ClientFailure.Protocol> {head.merging(head.copy(sequence=11,membershipRevision=2))}
    }
    @Test fun `head payload follows Swift UUID and numeric bounds without accepting numeric strings`() {
        val valid=buildJsonObject {put("room_id",id);put("room_sequence",1);put("membership_revision",0)}
        assertEquals(AccountRoomHead(RoomId(id),1,0),AccountRoomHead.decode(valid))
        for(invalid in listOf(JsonObject(valid+("room_sequence" to JsonPrimitive("1"))),JsonObject(valid+("room_sequence" to JsonPrimitive(0))),
            JsonObject(valid+("membership_revision" to JsonPrimitive(-1))),JsonObject(valid+("room_id" to JsonPrimitive("room")))))
            assertFailsWith<ClientFailure.Protocol> {AccountRoomHead.decode(invalid)}
    }
    @Test fun `account start binds ready epoch and rejects unrelated or malformed response`()=runTest {
        var response=Envelope.newBuilder().setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder().setConnectionEpoch(id)).build()
        val client=AccountRoomChangesClient(object: EnvelopeTransport {override suspend fun request(body: Envelope.Builder): Envelope {
            assertTrue(body.hasAccountRoomChangesStart());return response
        }})
        assertEquals(id,client.start())
        response=Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
        assertFailsWith<ClientFailure.Protocol> {client.start()}
        response=Envelope.newBuilder().setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder().setConnectionEpoch("invalid")).build()
        assertFailsWith<ClientFailure.Protocol> {client.start()}
        assertFailsWith<ClientFailure.Protocol> {RealtimeSyncHint.decode(Envelope.newBuilder().setAccountRoomResyncRequired(AccountRoomResyncRequired.newBuilder().setConnectionEpoch("invalid")).build())}
    }
    @Test fun `resync boundary wakes both recovery paths and is consumed once`()=runTest {
        val events=MutableSharedFlow<RealtimeSyncEvent>(extraBufferCapacity=4);val pending=RealtimeSyncWakeups(4,events,this)
        try {
            events.emit(RealtimeSyncEvent(3,RealtimeSyncHint.AccountResync(id)));runCurrent();assertNull(pending.take().restartAccountEpoch)
            events.emit(RealtimeSyncEvent(4,RealtimeSyncHint.AccountResync(id)));runCurrent()
            val work=pending.take();assertEquals(id,work.restartAccountEpoch);assertTrue(work.account);assertTrue(work.refreshDirectory)
            assertNull(pending.take().restartAccountEpoch)
        } finally {pending.close()}
    }
}
