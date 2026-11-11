package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import okhttp3.OkHttpClient
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

class RoomLiveBackendTests {
    @Test fun subscribedBodyCommitsWithoutPullAndSurvivesDatabaseReopen()=runBlocking<Unit> {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend",endpoint != null)
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager).build()
        val api=AccountClient(endpoint!!,http);val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-","").take(12)
        val aAuth=AuthSession(KeystoreSecretStore(context,"live-$run-a"),api);val bAuth=AuthSession(KeystoreSecretStore(context,"live-$run-b"),api)
        val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val aSocket=RealtimeConnection("localhost",port,ssl.socketFactory);val bSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        var aStore: SqliteClientStore?=null;var bStore: SqliteClientStore?=null;var listener: Job?=null
        try {
            withTimeout(120_000) {
                val password=UUID.randomUUID().toString()+"aA1!"
                val a=aAuth.login("live_${run}_a",password,true,"live_${run}_a","实时 A")
                val b=bAuth.login("live_${run}_b",password,true,"live_${run}_b","实时 B")
                val direct=DirectRoomClient(AuthenticatedApi(aAuth,api,a.userId,a.deviceId))
                val command=DirectRoomCommand.create(a.userId,b.userId,System.currentTimeMillis())
                var processing=false;var opened: RoomId?=null
                repeat(30) {if(opened == null) when(val result=direct.execute(command,processing,false)) {
                    is DirectRoomResult.Receipt -> opened=requireNotNull(result.room)
                    DirectRoomResult.Processing -> {processing=true;delay(250)}
                    is DirectRoomResult.Deferred -> delay(maxOf(250,result.delayMilliseconds))
                    DirectRoomResult.Unresolved -> delay(250)
                    DirectRoomResult.Conflict -> error("Direct-room conflict")
                }}
                val room=requireNotNull(opened)
                aStore=SqliteClientStore(context,a.userId,a.deviceId);bStore=SqliteClientStore(context,b.userId,b.deviceId)
                aSocket.connect(aAuth.access());bSocket.connect(bAuth.access())
                AccountRoomChangesClient(aSocket).start();val oldEpoch=AccountRoomChangesClient(bSocket).start()
                SyncEngine(aSocket,aStore!!).synchronize();SyncEngine(bSocket,bStore!!).synchronize()
                RoomSyncEngine(aSocket,aStore!!).synchronize();RoomSyncEngine(bSocket,bStore!!).synchronize()
                RoomEventSubscriptionClient(bSocket).subscribe(room,bStore!!.roomCursor(room).sequence)
                val wakes=Channel<RealtimeSyncEvent>(64)
                listener=launch(start=CoroutineStart.UNDISPATCHED) {bSocket.syncEvents.collect {wakes.send(it)}}
                val calls=mutableListOf<Envelope>()
                val wire=object: EnvelopeTransport {override suspend fun request(body: Envelope.Builder): Envelope {
                    val request=body.build();calls+=request
                    assertTrue("Live application must only send post-commit delivery progress",request.hasDeviceRoomProgressReport())
                    assertEquals(bStore!!.roomCursor(room).sequence,request.deviceRoomProgressReport.getRooms(0).appliedThrough)
                    return bSocket.request(body)
                }}
                val engine=RoomSyncEngine(wire,bStore!!)
                repeat(2) {index ->
                    val before=bStore!!.roomCursor(room)
                    val text="live body $run $index"
                    MessageOutbox(aSocket,aStore!!).send(a.userId,room,text)
                    var received: RealtimeSyncHint.Room?=null
                    withTimeout(30_000) {
                        while(received == null) {
                            val hint=wakes.receive().hint
                            if(hint is RealtimeSyncHint.Room && hint.room == room && hint.head > before.sequence && hint.liveEvents.isNotEmpty()) received=hint
                        }
                    }
                    assertEquals(before,bStore!!.roomCursor(room));assertTrue(bStore!!.snapshot().messages.none {it.text==text})
                    val hint=requireNotNull(received)
                    assertTrue(engine.applyOnlineEvents(hint));assertTrue(bStore!!.snapshot().messages.any {it.text==text})
                    assertEquals(hint.head,bStore!!.roomCursor(room).sequence)
                    val count=calls.size;assertTrue(engine.applyOnlineEvents(hint));assertEquals(count,calls.size)
                }
                assertEquals(2,calls.size)
                val committed=bStore!!.roomCursor(room)
                bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                assertEquals(committed,bStore!!.roomCursor(room));assertEquals(2,bStore!!.snapshot().messages.count {it.text.startsWith("live body $run")})
                RoomEventSubscriptionClient(bSocket).unsubscribe(room)
                listener?.cancelAndJoin();listener=null
                bSocket.close();bSocket.connect(bAuth.access())
                assertNotEquals(oldEpoch,AccountRoomChangesClient(bSocket).start())
            }
        } finally {
            listener?.cancelAndJoin();aSocket.close();bSocket.close();aStore?.close();bStore?.close()
            withContext(NonCancellable) {withTimeout(45_000) {aAuth.logout();bAuth.logout()}}
        }
    }
}
