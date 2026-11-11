package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID

internal suspend fun verifyMessageModerationBackend(context: Context,a: Credentials,b: Credentials,first: SqliteClientStore,second: SqliteClientStore,
    api: AuthenticatedTransport,peerApi: AuthenticatedTransport,aSocket: RealtimeConnection,bSocket: RealtimeConnection,run: String): SqliteClientStore {
    var store = first;val client = MessageModerationClient(api)
    fun service() = MessageModerationService(a.userId,client,store)
    val creator = GroupCreationService(a.userId,GroupCreationClient(api),store)
    val draft = creator.prepare("消息审核 $run",persistentListOf(b.userId))
    withTimeout(30000) { while(!store.groupWorks().first { it.command.operation == draft.command.operation }.terminal) { creator.flush();delay(100) } }
    val room = requireNotNull(store.groupWorks().first { it.command.operation == draft.command.operation }.room)
    suspend fun sync() = backendSync { SyncEngine(aSocket,store).synchronize();SyncEngine(bSocket,second).synchronize();RoomSyncEngine(aSocket,store).synchronize();RoomSyncEngine(bSocket,second).synchronize() }
    sync()
    suspend fun send(text: String): Message {
        val command = MessageCommand.text(b.userId,room,text,System.currentTimeMillis()+595000)
        val result = bSocket.request(Envelope.newBuilder().setMessageSendOperation(command)).messageSendOperationResult
        assertTrue(result.hasReceipt() && result.receipt.hasAccepted())
        return withTimeout(15000) {
            while(true) { sync();store.snapshot().messages.firstOrNull { it.roomId == room && it.text == text }?.let { return@withTimeout it };delay(100) }
            @Suppress("UNREACHABLE_CODE") error("message not observed")
        }
    }
    suspend fun settle(worker: MessageModerationService,work: ModerationWork,status: ModerationStatus = ModerationStatus.Committed): ModerationWork {
        withTimeout(30000) { while(!store.moderationWorks().first { it.intent.key == work.intent.key }.terminal) {
            worker.flush();assertNotEquals(ModerationStatus.NeedsAttention,store.moderationWorks().first { it.intent.key == work.intent.key }.status);delay(100)
        } }
        return store.moderationWorks().first { it.intent.key == work.intent.key }.also { assertEquals(status,it.status) }
    }
    val source = send("需审核的真实消息 $run")
    val reaction = MessageReactionService(a.userId,MessageReactionClient(api),store)
    val reactionWork = reaction.enqueue(room,source.id,"👍",true)
    withTimeout(30000) { while(!store.reactionWorks().first { it.intent.operation == reactionWork.intent.operation }.terminal) { reaction.flush();delay(100) } }
    withTimeout(15000) { while(store.snapshot().reactions.none { it.message == source.id }) { sync();delay(100) } }
    val worker = service();val work = worker.enqueue(worker.confirmation(client.baseline(room,source.id),"ADMIN_ACTION"));worker.flush()
    val frozen = store.moderationWorks().first { it.intent.key == work.intent.key };assertNotNull(frozen.command())
    store.updateModeration(frozen,frozen.copy(reconcile = true,submissionStarted = true,attempts = frozen.attempts+1))
    val committed = client.execute(frozen.intent,frozen.command(),recover = false) as ModerationResult.Receipt
    assertEquals(ModerationStatus.Committed,committed.status);assertEquals(source.revision+1,committed.revision)
    assertFalse(store.snapshot().messages.first { it.id == source.id }.redacted)
    store.close();store = SqliteClientStore(context,a.userId,a.deviceId)
    val restored = settle(service(),work);assertEquals(committed.wire,restored.receipt)
    assertFalse(store.snapshot().messages.first { it.id == source.id }.redacted)
    withTimeout(15000) { while(listOf(store,second).any { it.snapshot().messages.firstOrNull { it.id == source.id }?.redacted != true }) { sync();delay(100) } }
    for(target in listOf(store,second)) {
        val removed = target.snapshot().messages.first { it.id == source.id }
        assertEquals("消息已由管理员移除",removed.text);assertTrue(removed.withdrawn);assertNull(removed.forwardedFrom)
        assertTrue(target.snapshot().reactions.none { it.message == source.id })
    }
    val baseline = client.baseline(room,source.id);assertTrue(baseline.redacted)
    val noOpService = service();val noOp = settle(noOpService,noOpService.enqueue(noOpService.confirmation(baseline,"ADMIN_ACTION")))
    val noOpReceipt = MessageModerationClient.decodeReceipt(noOp.intent,kotlinx.serialization.json.Json.parseToJsonElement(requireNotNull(noOp.receipt)) as kotlinx.serialization.json.JsonObject)
    assertNull(noOpReceipt.event);assertEquals(baseline.messageRevision,noOpReceipt.revision)
    assertEquals(committed.wire,(client.execute(frozen.intent,frozen.command(),recover = false) as ModerationResult.Receipt).wire)
    // An edit made after admission conflicts with the exact confirmed message version.
    val changed = send("审核前将修改 $run");val staleService = service()
    val stale = staleService.enqueue(staleService.confirmation(client.baseline(room,changed.id),"ADMIN_ACTION"));staleService.flush()
    val edit = MessageMutationCommand(b.userId,room,changed.id,UUID.randomUUID().toString().uppercase(),changed.revision,"修改后保留的内容 $run",System.currentTimeMillis()+595000)
    assertEquals(MutationStatus.Committed,(MessageMutationClient(peerApi).execute(edit,false,false) as MutationResult.Receipt).status)
    val conflict = settle(staleService,stale,ModerationStatus.Conflicted);assertEquals("messageChanged",conflict.reason)
    sync();assertFalse(store.snapshot().messages.first { it.id == changed.id }.redacted)
    // A regular member cannot acquire moderation authority even with an observed valid baseline.
    val current = client.baseline(room,changed.id);val peerService = MessageModerationService(b.userId,MessageModerationClient(peerApi),second)
    val deniedIntent = peerService.confirmation(current,"ADMIN_ACTION").intent
    val denied = MessageModerationClient(peerApi).admit(deniedIntent) as ModerationAdmissionResult.Unavailable
    assertEquals("permissionDenied",denied.reason)
    // Restarting before admission only closes the exact original operation.
    val unstartedService = service();val unstarted = unstartedService.enqueue(unstartedService.confirmation(current,"ADMIN_ACTION"))
    store.close();store = SqliteClientStore(context,a.userId,a.deviceId)
    val closed = settle(service(),unstarted,ModerationStatus.Closed);assertTrue(closed.recoveryOnly);assertNull(closed.admission)
    assertEquals(ModerationStatus.Closed,(client.execute(unstarted.intent,close = true) as ModerationResult.Receipt).status)
    sync();assertFalse(store.snapshot().messages.first { it.id == changed.id }.redacted)
    return store
}
