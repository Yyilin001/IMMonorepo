package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*

internal suspend fun verifyAdministrationBackend(context: Context,a: Credentials,b: Credentials,first: SqliteClientStore,second: SqliteClientStore,
    api: AuthenticatedTransport,peerApi: AuthenticatedTransport,aSocket: RealtimeConnection,bSocket: RealtimeConnection,run: String): SqliteClientStore {
    var store = first;val client = AdministrationClient(api)
    fun service() = AdministrationService(a.userId,client,store)
    val creator = GroupCreationService(a.userId,GroupCreationClient(api),store)
    val draft = creator.prepare("成员管理 $run",persistentListOf(b.userId))
    withTimeout(30000) { while(!store.groupWorks().first { it.command.operation == draft.command.operation }.terminal) { creator.flush();delay(100) } }
    val room = requireNotNull(store.groupWorks().first { it.command.operation == draft.command.operation }.room)
    suspend fun sync() = backendSync { SyncEngine(aSocket,store).synchronize();SyncEngine(bSocket,second).synchronize();RoomSyncEngine(aSocket,store).synchronize();RoomSyncEngine(bSocket,second).synchronize() }
    sync();val revision = MemberDirectory(aSocket).page(room).revision
    suspend fun settle(service: AdministrationService,work: AdministrationWork): AdministrationWork {
        withTimeout(30000) { while(!store.administrationWorks().first { it.intent.key == work.intent.key }.terminal) { service.flush();delay(100) } }
        return store.administrationWorks().first { it.intent.key == work.intent.key }.also { assertEquals(AdministrationStatus.Committed,it.status) }
    }
    val until = System.currentTimeMillis()+3600000
    val muter = service();val work = muter.enqueue(muter.confirmation(room,b.userId,AdministrationAction.Mute(until),"ADMIN_ACTION",revision))
    muter.flush();val frozen = store.administrationWorks().first { it.intent.key == work.intent.key }
    store.updateAdministration(frozen,frozen.copy(reconcile = true,submissionStarted = true,attempts = 1))
    val committed = client.execute(frozen.command(),recover = false) as AdministrationResult.Receipt
    assertEquals(AdministrationStatus.Committed,committed.status);assertEquals(revision,committed.revision)
    store.close();store = SqliteClientStore(context,a.userId,a.deviceId)
    val restored = settle(service(),work);assertEquals(committed.wire,restored.receipt)
    assertTrue(store.snapshot().moderationFacts.none { it.room == room })
    withTimeout(30000) { while(second.snapshot().moderationFacts.none { it.room == room }) { sync();delay(100) } }
    assertEquals(store.snapshot().moderationFacts.filter { it.room == room },second.snapshot().moderationFacts.filter { it.room == room })
    val fact = second.snapshot().moderationFacts.single { it.room == room }
    val event = aSocket.request(Envelope.newBuilder().setGroupEventPull(GroupEventPull.newBuilder().setRoomId(room.value).setAfterRoomSequence(fact.sequence-1).setPageSize(1))).groupEventPage.eventsList.single()
    assertEquals(fact.source,event.sourceEventId)
    val raw = kotlinx.serialization.json.Json.parseToJsonElement(event.payload.toStringUtf8()) as kotlinx.serialization.json.JsonObject
    assertEquals((raw.getValue("mute_until_ms") as kotlinx.serialization.json.JsonPrimitive).content.toLong(),fact.until)
    // The server persists Foundation Date through PostgreSQL microseconds, then truncates milliseconds.
    // The projection must retain its exact event value, rather than replacing it with the requested deadline.
    assertTrue("server mute timestamp outside millisecond conversion precision",kotlin.math.abs(until-fact.until) <= 1)
    val send = MessageCommand.text(b.userId,room,"禁言后不应发送",System.currentTimeMillis()+595000)
    val blocked = bSocket.request(Envelope.newBuilder().setMessageSendOperation(send)).messageSendOperationResult
    assertTrue("muted sender accepted",blocked.hasReceipt() && blocked.receipt.hasRejected())
    assertEquals(MessageSendOperationRejection.Reason.PERMISSION_DENIED,blocked.receipt.rejected.reason)
    val shorter = service();val satisfied = settle(shorter,shorter.enqueue(shorter.confirmation(room,b.userId,AdministrationAction.Mute(until-10000),"ADMIN_ACTION",revision)))
    assertTrue(satisfied.receipt!!.contains("alreadySatisfied"));sync();assertEquals(1,second.snapshot().moderationFacts.count { it.room == room })
    val peer = AdministrationService(b.userId,AdministrationClient(peerApi),second)
    val forbidden = peer.enqueue(peer.confirmation(room,a.userId,AdministrationAction.Remove,"ADMIN_ACTION",revision));peer.flush()
    assertEquals(AdministrationStatus.DraftPaused,second.administrationWorks().first { it.intent.key == forbidden.intent.key }.status);peer.discard(forbidden.intent.key)
    val remover = service();val removed = settle(remover,remover.enqueue(remover.confirmation(room,b.userId,AdministrationAction.Remove,"ADMIN_ACTION",revision)))
    withTimeout(30000) { while(room !in second.snapshot().revokedRooms) { sync();delay(100) } }
    assertTrue(second.snapshot().moderationFacts.none { it.room == room });assertTrue(second.snapshot().messages.none { it.roomId == room })
    val members = MembershipService(a.userId,MembershipClient(api),store)
    val add = members.enqueue(b.userId,members.confirmation(room,MembershipAction.Add,MemberDirectory(aSocket).page(room).revision))
    withTimeout(30000) { while(!store.membershipWorks().first { it.intent.operation == add.intent.operation }.terminal) { members.flush();delay(100) } }
    assertEquals(MembershipStatus.Committed,store.membershipWorks().first { it.intent.operation == add.intent.operation }.status)
    sync();assertFalse(room in second.snapshot().revokedRooms)
    // The old target-joined revision remains in the original frozen command; replay only returns its old receipt.
    assertEquals(committed.wire,(client.execute(frozen.command(),recover = false) as AdministrationResult.Receipt).wire)
    assertEquals(removed.receipt,(client.execute(removed.command(),recover = false) as AdministrationResult.Receipt).wire)
    assertTrue(MemberDirectory(aSocket).page(room).members.any { it.user == b.userId })
    // The server's room/user mute intentionally outlives membership removal and rejoining.
    val fresh = MessageCommand.text(b.userId,room,"重新入群仍受原禁言约束",System.currentTimeMillis()+595000)
    val stillMuted = bSocket.request(Envelope.newBuilder().setMessageSendOperation(fresh)).messageSendOperationResult
    assertTrue(stillMuted.hasReceipt() && stillMuted.receipt.hasRejected())
    assertEquals(MessageSendOperationRejection.Reason.PERMISSION_DENIED,stillMuted.receipt.rejected.reason)
    return store
}
