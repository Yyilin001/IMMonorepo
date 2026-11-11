package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID

/** Kept outside the full scenario to keep the generated coroutine below the JVM method limit. */
internal suspend fun verifyMutationBackend(context: Context, actor: Credentials, peer: Credentials, directRoom: RoomId,
    initialStore: SqliteClientStore, peerStore: SqliteClientStore, api: AuthenticatedTransport, peerApi: AuthenticatedTransport,
    socket: RealtimeConnection, peerSocket: RealtimeConnection, run: String): SqliteClientStore {
    var store = initialStore
    try {
        val source = store.snapshot().messages.first { it.roomId == directRoom && it.sender == actor.userId && !it.withdrawn }
        val client = MessageMutationClient(api)
        fun service() = MessageMutationService(actor.userId, client, store)
        suspend fun settled(id: String, status: MutationStatus = MutationStatus.Committed): MessageMutationWork {
            val worker = service()
            withTimeout(30000) {
                while(!store.mutationWorks().first { it.command.operation == id }.terminal) {
                    worker.flush()
                    val current = store.mutationWorks().first { it.command.operation == id }
                    assertNotEquals("Mutation requires attention: ${current.reason}", MutationStatus.NeedsAttention, current.status)
                    delay(200)
                }
            }
            return store.mutationWorks().first { it.command.operation == id }.also { assertEquals(status, it.status) }
        }
        suspend fun rooms(revision: Long) {
            withTimeout(10000) {
                do {
                    RoomSyncEngine(socket, store).synchronize(); RoomSyncEngine(peerSocket, peerStore).synchronize()
                    if(listOf(store, peerStore).all { store -> store.snapshot().messages.any { it.id == source.id && it.revision == revision } }) break
                    delay(200)
                } while(true)
            }
        }
        val edit = service().enqueue(directRoom, source.id, source.revision, "编辑后的真实消息 $run")
        store.updateMutation(edit, edit.copy(reconcile = true))
        assertEquals(MutationStatus.Committed, (client.execute(edit.command, false, false) as MutationResult.Receipt).status)
        assertEquals(source.text, store.snapshot().messages.first { it.id == source.id }.text)
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        settled(edit.command.operation)
        assertEquals(source.text, store.snapshot().messages.first { it.id == source.id }.text)
        rooms(source.revision + 1)
        assertEquals(edit.command.text, peerStore.snapshot().messages.first { it.id == source.id }.text)
        val stale = service().enqueue(directRoom, source.id, source.revision + 1, "不能覆盖的新版本")
        val competing = stale.command.copy(operation = UUID.randomUUID().toString().uppercase(), text = "其他设备修改 $run")
        assertEquals(MutationStatus.Committed, (client.execute(competing, false, false) as MutationResult.Receipt).status)
        settled(stale.command.operation, MutationStatus.Conflicted)
        assertEquals(MutationStatus.Committed, (client.execute(edit.command, false, false) as MutationResult.Receipt).status)
        rooms(source.revision + 2)
        assertEquals(competing.text, store.snapshot().messages.first { it.id == source.id }.text)
        val denied = competing.copy(actor = peer.userId, operation = UUID.randomUUID().toString().uppercase(), revision = source.revision + 2, text = "无权编辑")
        val denial = MessageMutationClient(peerApi).execute(denied, false, false) as MutationResult.Receipt
        assertEquals(MutationStatus.Rejected, denial.status); assertEquals("permissionDenied", denial.reason)
        val withdrawal = service().enqueue(directRoom, source.id, source.revision + 2, null)
        store.updateMutation(withdrawal, withdrawal.copy(reconcile = true))
        assertEquals(MutationStatus.Committed, (client.execute(withdrawal.command, false, false) as MutationResult.Receipt).status)
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        settled(withdrawal.command.operation); rooms(source.revision + 3)
        assertTrue(store.snapshot().messages.first { it.id == source.id }.withdrawn)
        assertTrue(peerStore.snapshot().messages.first { it.id == source.id }.withdrawn)
        assertFalse(store.snapshot().reactions.any { it.message == source.id })
        assertFalse(peerStore.snapshot().reactions.any { it.message == source.id })
        assertEquals("消息已撤回", peerStore.snapshot().messages.first { it.id == source.id }.text)
        val late = withdrawal.command.copy(operation = UUID.randomUUID().toString().uppercase(), text = "不能恢复已撤回内容", revision = source.revision + 3)
        val rejection = client.execute(late, false, false) as MutationResult.Receipt
        assertEquals(MutationStatus.Rejected, rejection.status); assertEquals("alreadyWithdrawn", rejection.reason)
        val reaction = ReactionCommand(ReactionIntent(actor.userId, directRoom, source.id, UUID.randomUUID().toString().uppercase(), "👍", true, System.currentTimeMillis() + 595000), 0)
        val reactionDenial = MessageReactionClient(api).execute(reaction, false, false) as ReactionResult.Receipt
        assertEquals(ReactionStatus.Rejected, reactionDenial.status); assertEquals("messageWithdrawn", reactionDenial.reason)
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        assertTrue(store.snapshot().messages.first { it.id == source.id }.withdrawn)
        return store
    } catch(error: Throwable) { store.close(); throw error }
}
