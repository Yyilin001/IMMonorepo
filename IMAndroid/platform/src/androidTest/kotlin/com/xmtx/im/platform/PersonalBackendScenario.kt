package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID
import javax.net.ssl.SSLSocketFactory

internal suspend fun verifyPersonalBackend(context: Context, actor: Credentials, directRoom: RoomId,
    initialStore: SqliteClientStore, peerStore: SqliteClientStore, api: AuthenticatedTransport,
    socket: RealtimeConnection, peerSocket: RealtimeConnection, run: String, password: String,
    transport: AccountClient, port: Int, factory: SSLSocketFactory): SqliteClientStore {
    var store = initialStore
    try {
        val client = PersonalPreferenceClient(socket, api)
        fun service() = PersonalPreferenceService(actor.userId, client, store)
        suspend fun settlePersonal(worker: PersonalPreferenceService, id: String, status: PersonalStatus = PersonalStatus.Committed): PersonalWork {
            withTimeout(30000) {
                while(!store.personalWorks().first { it.operation == id }.terminal) { worker.flush(); delay(200) }
            }
            return store.personalWorks().first { it.operation == id }.also { assertEquals(status, it.status) }
        }

        val message = store.snapshot().messages.first { it.roomId == directRoom && it.delivery == Delivery.Accepted }.id
        var worker = service()
        val first = worker.conversation(directRoom, ConversationPatch(pinned = true))
        val mute = System.currentTimeMillis() + 3600000
        val merged = worker.conversation(directRoom, ConversationPatch(muteUntil = mute))
        assertEquals(first.operation, merged.operation); assertEquals(first.deadline, merged.deadline)
        store.preparePersonal(System.currentTimeMillis())
        val frozen = store.personalWorks().first { it.operation == first.operation }
        val command = requireNotNull(frozen.command)
        assertEquals(PersonalTarget.Conversation(directRoom, true, false, mute), command.target)
        // The server commits, but the process loses its response before local persistence.
        store.updatePersonal(frozen, frozen.copy(submissionStarted = true, reconcile = true))
        assertEquals(PersonalStatus.Committed, client.submit(command).status)
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        worker = service()
        settlePersonal(worker, first.operation)
        val archived = worker.conversation(directRoom, ConversationPatch(archived = true))
        settlePersonal(worker, archived.operation)
        val favorite = worker.favorite(directRoom, message, true)
        val favoriteWork = settlePersonal(worker, favorite.operation)
        SyncEngine(socket, store).synchronize(); SyncEngine(peerSocket, peerStore).synchronize()
        assertTrue(store.snapshot().conversations.first { it.id == directRoom }.let { it.pinned && it.archived && it.muted })
        assertTrue(peerStore.snapshot().personalStates.isEmpty())
        val mirrorAuth = AuthSession(KeystoreSecretStore(context, "e2e-$run-mirror"), transport)
        val mirrorSocket = RealtimeConnection("localhost", port, factory)
        var mirrorStore: SqliteClientStore? = null
        try {
            val mirror = mirrorAuth.login("device_${run}_a", password)
            assertEquals(actor.userId, mirror.userId); assertNotEquals(actor.deviceId, mirror.deviceId)
            mirrorStore = SqliteClientStore(context, mirror.userId, mirror.deviceId)
            mirrorSocket.connect(mirrorAuth.access())
            withTimeout(10000) {
                while(mirrorStore.snapshot().personalStates.size < 2) { SyncEngine(mirrorSocket, mirrorStore).synchronize(); delay(200) }
            }
            assertEquals(PersonalTarget.Conversation(directRoom, true, true, mute), mirrorStore.snapshot().personalStates.first { it.target is PersonalTarget.Conversation }.target)
            assertEquals(PersonalTarget.Favorite(directRoom, message, true), mirrorStore.snapshot().personalStates.first { it.target is PersonalTarget.Favorite }.target)
            // A stale frozen command conflicts after the other installation changes the state.
            val stale = worker.conversation(directRoom, ConversationPatch(pinned = false))
            store.preparePersonal(System.currentTimeMillis())
            val staleCommand = requireNotNull(store.personalWorks().first { it.operation == stale.operation }.command)
            val mirrorApi = AuthenticatedApi(mirrorAuth, transport, mirror.userId, mirror.deviceId)
            val mirrorClient = PersonalPreferenceClient(mirrorSocket, mirrorApi)
            val remote = staleCommand.copy(operation = UUID.randomUUID().toString().uppercase(), target = PersonalTarget.Conversation(directRoom, false, false, 0))
            assertEquals(PersonalStatus.Committed, mirrorClient.submit(remote).status)
            settlePersonal(worker, stale.operation, PersonalStatus.Conflicted)
            assertEquals(PersonalStatus.Committed, client.submit(command).status)
            withTimeout(10000) {
                while(store.snapshot().personalStates.first { it.target is PersonalTarget.Conversation }.revision < remote.revision + 1) { SyncEngine(socket, store).synchronize(); SyncEngine(peerSocket, peerStore).synchronize(); delay(200) }
            }
            assertEquals(remote.target, store.snapshot().personalStates.first { it.target is PersonalTarget.Conversation }.target)
            val unfavorite = worker.favorite(directRoom, message, false); settlePersonal(worker, unfavorite.operation)
            assertEquals(PersonalStatus.Committed, client.recover(requireNotNull(favoriteWork.command), false).let { (it as PersonalResult.Receipt).status })
            withTimeout(10000) {
                while((mirrorStore.snapshot().personalStates.first { it.target is PersonalTarget.Favorite }.target as PersonalTarget.Favorite).favorited) { SyncEngine(mirrorSocket, mirrorStore).synchronize(); delay(200) }
            }
            assertFalse((mirrorStore.snapshot().personalStates.first { it.target is PersonalTarget.Favorite }.target as PersonalTarget.Favorite).favorited)
        } finally {
            mirrorSocket.close(); mirrorStore?.close()
            withContext(NonCancellable) { withTimeout(30000) { mirrorAuth.logout() } }
        }
        store.close(); store = SqliteClientStore(context, actor.userId, actor.deviceId)
        assertEquals(PersonalTarget.Conversation(directRoom), store.snapshot().personalStates.first { it.target is PersonalTarget.Conversation }.target)
        return store
    } catch(error: Throwable) { store.close(); throw error }
}
