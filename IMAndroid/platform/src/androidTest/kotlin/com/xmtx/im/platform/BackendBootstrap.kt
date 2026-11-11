package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*

internal data class BackendBootstrap(val first: SqliteClientStore, val second: SqliteClientStore, val api: AuthenticatedApi, val peerApi: AuthenticatedApi, val room: RoomId)

/** Test polling is faster than the App lifecycle loop. Resume only durable synchronization/ACKs after an explicit rejection. */
internal suspend fun backendSync(block: suspend ()->Unit) = withTimeout(60000) {
    var attempts=0
    while(true) {
        try { block();delay(250);return@withTimeout }
        catch(error: GatewayFailure) {
            if(error.code!="RATE_LIMITED" || !error.retryable || ++attempts>=5) throw error
            delay(maxOf(1000L,error.retryAfterSeconds.toLong()*1000))
        }
    }
}
internal suspend fun bootstrapBackend(context: Context, a: Credentials, b: Credentials, aAuth: AuthSession, bAuth: AuthSession,
    transport: AccountClient, aSocket: RealtimeConnection, bSocket: RealtimeConnection, run: String, secrets: SecretStore): BackendBootstrap {
    var aStore: SqliteClientStore? = null
    var bStore: SqliteClientStore? = null
    try {
        val restored = AuthSession(secrets, transport).current()
        assertEquals(a, restored)
        aStore = SqliteClientStore(context, a.userId, a.deviceId)
        val api = AuthenticatedApi(aAuth, transport, a.userId, a.deviceId)
        val found = PublicIdentityDirectory(api, a.userId, a.deviceId).resolve("device_${run}_b")
        assertEquals(b.userId, found.identity.user)
        val work = DirectRoomService(a.userId, DirectRoomClient(api), aStore!!).prepare(b.userId)
        aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
        val directs = DirectRoomService(a.userId, DirectRoomClient(api), aStore!!)
        var room: RoomId? = null
        repeat(30) {
            if (room == null) {
                directs.flush()
                room = aStore!!.directWorks().first { it.command.operation == work.command.operation }.room
                if (room == null) delay(1000)
            }
        }
        assertNotNull("Direct operation not confirmed", room)
        bStore = SqliteClientStore(context, b.userId, b.deviceId)
        aSocket.connect(aAuth.access()); bSocket.connect(bAuth.access())
        SyncEngine(aSocket, aStore!!).synchronize(); SyncEngine(bSocket, bStore!!).synchronize()
        val text = "设备持久化 $run"
        MessageOutbox(aSocket, aStore!!).send(a.userId, room!!, text)
        val receiver = RoomSyncEngine(bSocket, bStore!!)
        repeat(30) {
            if (bStore!!.snapshot().messages.none { it.text == text }) { receiver.synchronize(); delay(200) }
        }
        assertTrue("Recipient SQLite projection missing", bStore!!.snapshot().messages.any { it.text == text })
        val reply = "设备回复 $run"
        MessageOutbox(bSocket, bStore!!).send(b.userId, room!!, reply)
        val sender = RoomSyncEngine(aSocket, aStore!!)
        repeat(30) {
            if (aStore!!.snapshot().messages.none { it.text == reply }) { sender.synchronize(); delay(200) }
        }
        assertTrue("Sender SQLite projection missing", aStore!!.snapshot().messages.any { it.text == reply })
        aStore!!.close(); aStore = SqliteClientStore(context, a.userId, a.deviceId)
        bStore!!.close(); bStore = SqliteClientStore(context, b.userId, b.deviceId)
        assertTrue(aStore!!.snapshot().messages.any { it.text == reply })
        assertTrue(bStore!!.snapshot().messages.any { it.text == text })
        assertEquals(DirectWorkStatus.Opened, aStore!!.directWorks().single().status)
        val bApi = AuthenticatedApi(bAuth, transport, b.userId, b.deviceId)
        return BackendBootstrap(aStore!!, bStore!!, api, bApi, requireNotNull(room))
    } catch(error: Throwable) { aStore?.close(); bStore?.close(); throw error }
}
