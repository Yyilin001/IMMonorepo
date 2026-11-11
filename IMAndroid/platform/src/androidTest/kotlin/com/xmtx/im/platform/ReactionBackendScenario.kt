package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID

/** Own-key HTTP versions and public room-log counts are deliberately verified separately. */
internal suspend fun verifyReactionBackend(context: Context, actor: Credentials, peer: Credentials, directRoom: RoomId,
    initialStore: SqliteClientStore, peerStore: SqliteClientStore, api: AuthenticatedTransport, peerApi: AuthenticatedTransport,
    socket: RealtimeConnection, peerSocket: RealtimeConnection): SqliteClientStore {
    var store = initialStore
    try {
        val source = store.snapshot().messages.first { it.roomId == directRoom && it.sender == actor.userId && !it.withdrawn }
        val client = MessageReactionClient(api)
        fun service() = MessageReactionService(actor.userId, client, store)
        suspend fun settled(worker: MessageReactionService, target: SqliteClientStore, id: String, status: ReactionStatus = ReactionStatus.Committed): ReactionWork {
            withTimeout(30000) {
                while(!target.reactionWorks().first { it.intent.operation == id }.terminal) {
                    worker.flush()
                    val current = target.reactionWorks().first { it.intent.operation == id }
                    assertFalse("Reaction requires attention: ${current.reason}", current.status in setOf(ReactionStatus.NeedsAttention, ReactionStatus.PreparationPaused))
                    delay(200)
                }
            }
            return target.reactionWorks().first { it.intent.operation == id }.also { assertEquals(status, it.status) }
        }
        suspend fun counts(count: Int, own: Boolean, peerOwn: Boolean) {
            withTimeout(10000) {
                do {
                    RoomSyncEngine(socket, store).synchronize(); RoomSyncEngine(peerSocket, peerStore).synchronize()
                    val a = store.snapshot().reactions.firstOrNull { it.message == source.id && it.reaction == "👍" }
                    val b = peerStore.snapshot().reactions.firstOrNull { it.message == source.id && it.reaction == "👍" }
                    if(a?.count == count && b?.count == count && a.own == own && b.own == peerOwn) break
                    delay(200)
                } while(true)
            }
        }
        val add = service().enqueue(directRoom, source.id, "👍", true)
        service().flush()
        val frozen = store.reactionWorks().first { it.intent.operation == add.intent.operation }
        val original = requireNotNull(frozen.command); assertEquals(0L, original.revision)
        store.updateReaction(frozen, frozen.copy(reconcile = true))
        val accepted = client.execute(original, false, false) as ReactionResult.Receipt
        assertEquals(ReactionStatus.Committed, accepted.status); assertNotNull(accepted.commit!!.event)
        assertTrue(store.snapshot().reactions.isEmpty())
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        settled(service(), store, original.intent.operation)
        assertTrue(store.snapshot().reactions.isEmpty()); counts(1, true, false)
        val peerService = MessageReactionService(peer.userId, MessageReactionClient(peerApi), peerStore)
        val peerAdd = peerService.enqueue(directRoom, source.id, "👍", true)
        settled(peerService, peerStore, peerAdd.intent.operation); counts(2, true, true)
        // An already-present target still advances the own-key version, without a public event.
        val noOp = original.copy(intent = original.intent.copy(operation = UUID.randomUUID().toString().uppercase()), revision = 1)
        val noOpReceipt = client.execute(noOp, false, false) as ReactionResult.Receipt
        assertEquals(ReactionStatus.Committed, noOpReceipt.status); assertEquals(2L, noOpReceipt.commit!!.revision); assertNull(requireNotNull(noOpReceipt.commit).event)
        val remove = service().enqueue(directRoom, source.id, "👍", false)
        val removed = settled(service(), store, remove.intent.operation)
        assertEquals(2L, removed.command!!.revision); counts(1, false, true)
        assertEquals(ReactionStatus.Committed, (client.execute(original, false, false) as ReactionResult.Receipt).status)
        assertEquals(3L, client.baseline(original.intent).revision); counts(1, false, true)
        val stale = service().enqueue(directRoom, source.id, "👍", false); service().flush()
        val staleCommand = requireNotNull(store.reactionWorks().first { it.intent.operation == stale.intent.operation }.command)
        assertEquals(3L, staleCommand.revision)
        val competing = staleCommand.copy(intent = staleCommand.intent.copy(operation = UUID.randomUUID().toString().uppercase(), present = true))
        assertEquals(ReactionStatus.Committed, (client.execute(competing, false, false) as ReactionResult.Receipt).status)
        settled(service(), store, stale.intent.operation, ReactionStatus.Conflicted); counts(2, true, true)
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        assertEquals(2, store.snapshot().reactions.first { it.message == source.id }.count)
        return store
    } catch(error: Throwable) { store.close(); throw error }
}
