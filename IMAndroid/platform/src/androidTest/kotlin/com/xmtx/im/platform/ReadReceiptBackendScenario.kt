package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.io.IOException
import java.util.UUID

internal suspend fun verifyReadReceiptBackend(context: Context,a: Credentials,b: Credentials,direct: RoomId,first: SqliteClientStore,second: SqliteClientStore,
    api: AuthenticatedTransport,peerApi: AuthenticatedTransport,aSocket: RealtimeConnection,bSocket: RealtimeConnection,run: String): SqliteClientStore {
    var store = first;var phase = "enable disclosure"
    val client = ReadReceiptClient(aSocket,api);val peer = ReadReceiptClient(bSocket,peerApi)
    try {
        suspend fun preference(actor: Credentials,target: SqliteClientStore,edge: AuthenticatedTransport,direct: Boolean,group: Boolean) {
            val service = AccountPreferenceService(actor.userId,AccountPreferenceClient(edge,actor.userId),target)
            val work = service.enqueue(PreferencePatch(PreferenceKind.ReadReceipts,direct,group))
            withTimeout(30000) { while(!target.preferenceWorks().first { it.operation == work.operation }.terminal) { service.flush();delay(100) } }
            assertEquals(PreferenceStatus.Committed,target.preferenceWorks().first { it.operation == work.operation }.status)
        }
        suspend fun personal() {
            while(true) {
                try { SyncEngine(aSocket,store).synchronize();SyncEngine(bSocket,second).synchronize();return }
                catch(e: GatewayFailure) { if(e.code != "RATE_LIMITED" || !e.retryable) throw e;delay(maxOf(1000,e.retryAfterSeconds.toLong()*1000)) }
            }
        }
        suspend fun sync() = backendSync { personal();RoomSyncEngine(aSocket,store).synchronize();RoomSyncEngine(bSocket,second).synchronize() }
        preference(a,store,api,true,true);preference(b,second,peerApi,true,true);sync()
        suspend fun send(socket: RealtimeConnection,actor: UserId,room: RoomId,text: String): Message {
            val result = socket.request(Envelope.newBuilder().setMessageSendOperation(MessageCommand.text(actor,room,text,System.currentTimeMillis()+595000))).messageSendOperationResult
            assertTrue(result.hasReceipt() && result.receipt.hasAccepted())
            return withTimeout(15000) { while(true) { sync();store.snapshot().messages.firstOrNull { it.roomId == room && it.text == text }?.let { assertEquals(result.receipt.accepted.roomSequence,it.roomSequence);return@withTimeout it };delay(100) };error("unreachable") }
        }
        phase = "lost direct receipt reply"
        val message = send(bSocket,b.userId,direct,"已读恢复 $run")
        val lost = object: ReadReceiptTransport {
            override suspend fun submit(command: ReadCommand): ReadResult.Confirmed { client.submit(command);throw IOException("test reply lost") }
            override suspend fun recover(command: ReadCommand) = client.recover(command)
        }
        ReadReceiptService(a.userId,lost,store).also { assertTrue(it.enqueue(direct,message.roomSequence));it.flush() }
        val original = store.readWorks().single { it.command.room == direct };assertTrue(original.submissionStarted);assertTrue(original.reconcile)
        store.close();store = SqliteClientStore(context,a.userId,a.deviceId)
        val worker = ReadReceiptService(a.userId,client,store)
        withTimeout(15000) { while(store.readWorks().first { it.command.operation == original.command.operation }.status != ReadStatus.Confirmed) { worker.flush();delay(100) } }
        val recovered = store.readWorks().first { it.command.operation == original.command.operation };assertEquals(original.command,recovered.command);assertEquals(true,recovered.originalReceipt)
        val proof = client.recover(original.command.copy(operation = UUID.randomUUID().toString().uppercase())) as ReadResult.Confirmed
        assertFalse(proof.original);assertTrue(proof.watermark.sequence >= message.roomSequence)
        phase = "direct disclosure and privacy tombstone"
        withTimeout(15000) { while(second.snapshot().directReads.none { it.room == direct && it.reader == a.userId && it.sequence >= message.roomSequence }) { personal();delay(500) } }
        preference(a,store,api,false,true)
        assertFalse(store.allowsReadPublication(direct))
        withTimeout(15000) { while(second.snapshot().directReads.any { it.room == direct }) { personal();delay(500) } }
        assertTrue((client.recover(original.command) as ReadResult.Confirmed).original)
        phase = "group reader query"
        val creator = GroupCreationService(a.userId,GroupCreationClient(api),store);val draft = creator.prepare("已读详情 $run",persistentListOf(b.userId))
        withTimeout(30000) { while(!store.groupWorks().first { it.command.operation == draft.command.operation }.terminal) { creator.flush();delay(100) } }
        val group = requireNotNull(store.groupWorks().first { it.command.operation == draft.command.operation }.room)
        val source = send(aSocket,a.userId,group,"群消息已读 $run")
        val peerWork = ReadReceiptService(b.userId,peer,second);assertTrue(peerWork.enqueue(group,source.roomSequence))
        withTimeout(15000) { while(second.readWorks().none { it.command.room == group && it.status == ReadStatus.Confirmed }) { peerWork.flush();delay(100) } }
        val readers = client.readers(group,source.id);assertTrue(b.userId in readers.readers);assertEquals(readers.readers.size,readers.readers.toSet().size)
        phase = "group disclosure preference hides reader"
        preference(b,second,peerApi,true,false);assertFalse(second.allowsReadPublication(group))
        assertFalse(b.userId in client.readers(group,source.id).readers)
        val groupCommand = second.readWorks().first { it.command.room == group }.command
        assertTrue((peer.recover(groupCommand) as ReadResult.Confirmed).original)
        sync();return store
    } catch(error: Throwable) { store.close();throw AssertionError("Read receipt failed during $phase",error) }
}
