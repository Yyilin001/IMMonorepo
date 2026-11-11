package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID

internal suspend fun verifyForwardBackend(context: Context, actor: Credentials, peer: Credentials, directRoom: RoomId,
    initialStore: SqliteClientStore, peerStore: SqliteClientStore, api: AuthenticatedTransport,
    socket: RealtimeConnection, peerSocket: RealtimeConnection, run: String): SqliteClientStore {
    var store = initialStore
    try {
        val groups = GroupCreationService(actor.userId, GroupCreationClient(api), store)
        val creation = groups.prepare("转发验收 $run", persistentListOf(peer.userId))
        withTimeout(30000) {
            while(!store.groupWorks().first { it.command.operation == creation.command.operation }.terminal) { groups.flush(); delay(200) }
        }
        val group = requireNotNull(store.groupWorks().first { it.command.operation == creation.command.operation }.room)
        val prefix = "转发来源 $run "
        repeat(21) { MessageOutbox(socket, store).send(actor.userId, directRoom, "$prefix$it") }
        withTimeout(15000) {
            while(store.snapshot().messages.count { it.text.startsWith(prefix) && it.revision > 0 } < 21) { MessageOutbox(socket, store).flush(); RoomSyncEngine(socket, store).synchronize(); delay(200) }
        }
        val sources = store.snapshot().messages.filter { it.roomId == directRoom && it.text.startsWith(prefix) }.sortedBy { it.roomSequence }
        val references = sources.mapIndexed { index, message -> ForwardSource(directRoom, message.id, message.revision + if(index == 0) 1 else 0) }.toPersistentList()
        val client = ForwardPlanClient(api)
        fun service() = ForwardPlanService(actor.userId, client, store)
        suspend fun settle(id: String, status: ForwardStatus = ForwardStatus.Committed): ForwardWork {
            val worker = service()
            withTimeout(60000) {
                while(!store.forwardWorks().first { it.command.operation == id }.terminal) {
                    worker.flush(); val current = store.forwardWorks().first { it.command.operation == id }
                    assertNotEquals("Forward requires attention: ${current.reason}", ForwardStatus.NeedsAttention, current.status)
                    delay(200)
                }
            }
            return store.forwardWorks().first { it.command.operation == id }.also { assertEquals(status, it.status) }
        }
        val work = service().enqueue(references, persistentListOf(directRoom, group))
        assertEquals(4, work.command.childCount)
        store.updateForward(work, work.copy(submissionStarted = true, reconcile = true))
        val submitted = client.execute(work.command)
        assertTrue(submitted is ForwardResult.Processing || submitted is ForwardResult.Receipt)
        assertTrue(store.snapshot().messages.none { it.forwardedFrom != null })
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        val resolved = settle(work.command.operation)
        assertEquals(40, resolved.succeeded); assertEquals(2, resolved.rejected); assertEquals(0, resolved.unresolved)
        val progress = requireNotNull(resolved.progress)
        assertTrue(progress.children.flatMap { it.items }.filter { it.rejection != null }.all { it.rejection == "sourceRevisionConflict" })
        val accepted = progress.children.flatMap { it.items }.filter { it.message != null }
        suspend fun syncForwarded() {
            withTimeout(20000) {
                do {
                    RoomSyncEngine(socket, store).synchronize(); RoomSyncEngine(peerSocket, peerStore).synchronize()
                    if(listOf(store, peerStore).all { local -> val messages = local.snapshot().messages; accepted.all { item -> messages.any { it.id == item.message && it.roomId == item.target } } }) break
                    delay(200)
                } while(true)
            }
        }
        syncForwarded()
        for(local in listOf(store, peerStore)) {
            val messages = local.snapshot().messages
            accepted.forEach { item ->
                val message = messages.first { it.id == item.message }; val original = sources.first { it.id == item.source }
                assertEquals(original.text, message.text); assertEquals(ForwardAttribution(original.id, actor.userId), message.forwardedFrom)
            }
        }
        val replay = client.execute(work.command) as ForwardResult.Receipt
        assertEquals(progress.children, replay.progress.children)
        syncForwarded(); assertEquals(40, store.snapshot().messages.count { it.forwardedFrom != null })
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        assertEquals(resolved, store.forwardWorks().first { it.command.operation == work.command.operation })
        val cancelled = service().enqueue(persistentListOf(ForwardSource(directRoom, sources.last().id, 1)), persistentListOf(group))
        service().cancel(cancelled.command.operation); assertEquals(ForwardStatus.Cancelled, store.forwardWorks().last().status)
        // A possible submit that never arrived is closed using the original manifest.
        val lost = service().enqueue(persistentListOf(ForwardSource(directRoom, sources.last().id, 1)), persistentListOf(group))
        store.updateForward(lost, lost.copy(submissionStarted = true, reconcile = true))
        service().cancel(lost.command.operation)
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        val closed = settle(lost.command.operation, ForwardStatus.Closed)
        assertEquals(1, closed.cancelled); assertEquals(0, closed.succeeded)
        assertEquals(ForwardStatus.Closed, (client.execute(lost.command) as ForwardResult.Receipt).status)
        return store
    } catch(error: Throwable) { store.close(); throw error }
}
