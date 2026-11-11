package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import kotlinx.coroutines.*
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

class ConcurrentRecoveryBackendTests {
    @Test fun twoDisjointContentFlightsOverlapAndCommitBeforeIndependentProgress()=runBlocking<Unit> {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend",endpoint != null)
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager).build()
        val api=AccountClient(endpoint!!,http);val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-","").take(12)
        val aAuth=AuthSession(KeystoreSecretStore(context,"concurrent-$run-a"),api);val bAuth=AuthSession(KeystoreSecretStore(context,"concurrent-$run-b"),api)
        val cAuth=AuthSession(KeystoreSecretStore(context,"concurrent-$run-c"),api)
        val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val aSocket=RealtimeConnection("localhost",port,ssl.socketFactory);val bSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        val cSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        var aStore: SqliteClientStore?=null;var bStore: SqliteClientStore?=null;var cStore: SqliteClientStore?=null
        try {
            withTimeout(120_000) {
                val password=UUID.randomUUID().toString()+"aA1!"
                val a=aAuth.login("concurrent_${run}_a",password,true,"concurrent_${run}_a","可见 A")
                val b=bAuth.login("concurrent_${run}_b",password,true,"concurrent_${run}_b","可见 B")
                val c=cAuth.login("concurrent_${run}_c",password,true,"concurrent_${run}_c","批量 C")
                suspend fun open(from: Credentials,auth: AuthSession): RoomId {
                    val direct=DirectRoomClient(AuthenticatedApi(auth,api,from.userId,from.deviceId))
                    val command=DirectRoomCommand.create(from.userId,b.userId,System.currentTimeMillis())
                    var processing=false;var opened: RoomId?=null
                    repeat(30) {if(opened==null) when(val result=direct.execute(command,processing,false)) {
                        is DirectRoomResult.Receipt -> opened=requireNotNull(result.room)
                        DirectRoomResult.Processing -> {processing=true;delay(250)}
                        is DirectRoomResult.Deferred -> delay(maxOf(250,result.delayMilliseconds))
                        DirectRoomResult.Unresolved -> delay(250)
                        DirectRoomResult.Conflict -> error("Direct-room conflict")
                    }}
                    return requireNotNull(opened)
                }
                val roomA=open(a,aAuth);val roomC=open(c,cAuth)
                aStore=SqliteClientStore(context,a.userId,a.deviceId);bStore=SqliteClientStore(context,b.userId,b.deviceId)
                cStore=SqliteClientStore(context,c.userId,c.deviceId)
                suspend fun social(from: Credentials,auth: AuthSession,store: SqliteClientStore,to: UserId,action: SocialAction) {
                    val service=SocialService(from.userId,SocialClient(AuthenticatedApi(auth,api,from.userId,from.deviceId),from.userId),store)
                    val work=service.enqueue(to,action)
                    repeat(40) {if(!store.socialWorks().first {it.command.operation==work.command.operation}.terminal) {service.flush();delay(200)}}
                    assertEquals(SocialWorkStatus.Committed,store.socialWorks().first {it.command.operation==work.command.operation}.status)
                }
                // More than three messages requires a real friendship under the isolated backend's stranger quota.
                social(a,aAuth,aStore!!,b.userId,SocialAction.Request)
                social(b,bAuth,bStore!!,a.userId,SocialAction.Accept)
                aSocket.connect(aAuth.access());bSocket.connect(bAuth.access());cSocket.connect(cAuth.access())
                AccountRoomChangesClient(aSocket).start();AccountRoomChangesClient(bSocket).start();AccountRoomChangesClient(cSocket).start()
                SyncEngine(aSocket,aStore!!).synchronize();SyncEngine(bSocket,bStore!!).synchronize();SyncEngine(cSocket,cStore!!).synchronize()
                RoomSyncEngine(aSocket,aStore!!).synchronize();RoomSyncEngine(cSocket,cStore!!).synchronize()
                val expected=mapOf(roomA to "batch A $run",roomC to "batch C $run")
                val outboxA=MessageOutbox(aSocket,aStore!!);val outboxC=MessageOutbox(cSocket,cStore!!)
                suspend fun sendConfirmed(outbox: MessageOutbox,store: SqliteClientStore,user: UserId,room: RoomId,text: String) {
                    outbox.send(user,room,text)
                    // Admission may defer a frozen command; enqueue/flush returning is not an accepted receipt.
                    while(store.pending().isNotEmpty()) {delay(1_000);outbox.flush()}
                }
                repeat(39) {sendConfirmed(outboxA,aStore!!,a.userId,roomA,"content $it $run")}
                sendConfirmed(outboxA,aStore!!,a.userId,roomA,expected.getValue(roomA))
                sendConfirmed(outboxC,cStore!!,c.userId,roomC,expected.getValue(roomC))
                var observedBeforePull=false
                val calls=mutableListOf<Envelope>()
                var firstFlights=0;val bothFlights=CompletableDeferred<Unit>()
                val wire=object: EnvelopeTransport {override suspend fun request(body: Envelope.Builder): Envelope {
                    val command=body.build()
                    if((command.hasGroupEventPull() || command.hasGroupEventPullBatch()) && !observedBeforePull) {
                        for((room,text) in expected) {
                            assertEquals(text,bStore!!.snapshot().conversations.single {it.id==room}.preview)
                            assertEquals(0L,bStore!!.roomCursor(room).sequence)
                        }
                        assertTrue(bStore!!.snapshot().messages.isEmpty())
                        assertTrue(calls.none {it.hasDeviceRoomProgressReport()});observedBeforePull=true
                    }
                    if(command.hasGroupEventPullBatch() && firstFlights<2) {
                        firstFlights++;if(firstFlights==2) bothFlights.complete(Unit)
                        withTimeout(10_000) {bothFlights.await()}
                    }
                    if(command.hasDeviceRoomProgressReport()) {
                        assertEquals(1,command.deviceRoomProgressReport.roomsCount)
                        for(cursor in command.deviceRoomProgressReport.roomsList) {
                            val room=RoomId(cursor.roomId)
                            assertEquals(bStore!!.roomCursor(room).sequence,cursor.appliedThrough)
                            assertTrue(bStore!!.snapshot().messages.any {it.roomId==room})
                        }
                    }
                    calls+=command;return bSocket.request(body)
                }}
                var directory=RoomDirectoryRecovery(wire,bStore!!,RoomSyncEngine(wire,bStore!!),contentBatchSize=1);directory.start()
                var progress=directory.runTurn(maximumPages=1,maximumRooms=4)
                assertEquals(1,progress.pendingRooms)
                assertTrue(bStore!!.snapshot().messages.count {it.roomId==roomA} in 1..32)
                assertEquals(1,bStore!!.snapshot().messages.count {it.roomId==roomC})
                repeat(10) {if(progress.pendingRooms>0) {delay(300);progress=directory.runTurn()}}
                assertTrue(observedBeforePull);assertTrue(progress.complete);assertEquals(0,progress.pendingRooms)
                assertEquals(expected.keys.map {it.value}.toSet(),calls.first {it.hasRoomSyncStateBatch()}.roomSyncStateBatch.roomIdsList.toSet())
                val latest=calls.filter {it.hasRoomLatestVisibleBatch()}
                assertEquals(1,latest.size)
                assertEquals(expected.keys.map {it.value}.toSet(),latest.single().roomLatestVisibleBatch.roomIdsList.toSet())
                for((room,text) in expected) {
                    assertTrue(bStore!!.snapshot().messages.any {it.roomId==room && it.text==text})
                    assertTrue(bStore!!.roomCursor(room).sequence>0)
                }
                assertEquals(40,bStore!!.snapshot().messages.count {it.roomId==roomA})
                assertTrue(calls.none {it.hasGroupEventPull()})
                val bodyBatches=calls.filter {it.hasGroupEventPullBatch()}
                assertTrue(bodyBatches.size>=2)
                assertEquals(2,firstFlights)
                assertEquals(setOf(roomA.value,roomC.value),bodyBatches.take(2).flatMap {it.groupEventPullBatch.roomsList}.map {it.roomId}.toSet())
                assertTrue(bodyBatches.all {it.groupEventPullBatch.roomsCount==1})
                assertTrue(bodyBatches.drop(2).all {it.groupEventPullBatch.getRooms(0).roomId==roomA.value})
                assertEquals(bodyBatches.size-1,calls.count {it.hasRoomSyncStateBatch()})
                assertTrue(directory.completeIfCaughtUp(SyncEngine(wire,bStore!!)) {true})
                assertTrue(bStore!!.pendingRoomHeads().isEmpty());assertNull(bStore!!.cursor().pendingReceipt)
                bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                for((room,text) in expected) assertEquals(text,bStore!!.snapshot().conversations.single {it.id==room}.preview)
                directory=RoomDirectoryRecovery(wire,bStore!!,RoomSyncEngine(wire,bStore!!),contentBatchSize=1);directory.start()
                val before=calls.size
                assertEquals(0,directory.runTurn().pendingRooms);assertEquals(before,calls.size)

            }
        } finally {
            aSocket.close();bSocket.close();cSocket.close();aStore?.close();bStore?.close();cStore?.close()
            withContext(NonCancellable) {withTimeout(45_000) {aAuth.logout();bAuth.logout();cAuth.logout()}}
        }
    }
}
