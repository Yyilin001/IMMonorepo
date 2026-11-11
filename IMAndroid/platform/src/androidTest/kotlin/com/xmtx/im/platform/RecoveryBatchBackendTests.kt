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

class RecoveryBatchBackendTests {
    @Test fun twoRoomSummariesCommitTogetherBeforeContentAndSurviveReopen()=runBlocking<Unit> {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend",endpoint != null)
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager).build()
        val api=AccountClient(endpoint!!,http);val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-","").take(12)
        val aAuth=AuthSession(KeystoreSecretStore(context,"batch-$run-a"),api);val bAuth=AuthSession(KeystoreSecretStore(context,"batch-$run-b"),api)
        val cAuth=AuthSession(KeystoreSecretStore(context,"batch-$run-c"),api)
        val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val aSocket=RealtimeConnection("localhost",port,ssl.socketFactory);val bSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        val cSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        var aStore: SqliteClientStore?=null;var bStore: SqliteClientStore?=null;var cStore: SqliteClientStore?=null
        try {
            withTimeout(120_000) {
                val password=UUID.randomUUID().toString()+"aA1!"
                val a=aAuth.login("batch_${run}_a",password,true,"batch_${run}_a","可见 A")
                val b=bAuth.login("batch_${run}_b",password,true,"batch_${run}_b","可见 B")
                val c=cAuth.login("batch_${run}_c",password,true,"batch_${run}_c","批量 C")
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
                aSocket.connect(aAuth.access());bSocket.connect(bAuth.access());cSocket.connect(cAuth.access())
                AccountRoomChangesClient(aSocket).start();AccountRoomChangesClient(bSocket).start();AccountRoomChangesClient(cSocket).start()
                SyncEngine(aSocket,aStore!!).synchronize();SyncEngine(bSocket,bStore!!).synchronize();SyncEngine(cSocket,cStore!!).synchronize()
                RoomSyncEngine(aSocket,aStore!!).synchronize();RoomSyncEngine(cSocket,cStore!!).synchronize()
                val expected=mapOf(roomA to "batch A $run",roomC to "batch C $run")
                MessageOutbox(aSocket,aStore!!).send(a.userId,roomA,expected.getValue(roomA))
                MessageOutbox(cSocket,cStore!!).send(c.userId,roomC,expected.getValue(roomC))
                var observedBeforePull=false
                val calls=mutableListOf<Envelope>()
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
                    calls+=command;return bSocket.request(body)
                }}
                var directory=RoomDirectoryRecovery(wire,bStore!!,RoomSyncEngine(wire,bStore!!));directory.start()
                var progress=directory.runTurn(maximumPages=1,maximumRooms=4)
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
                assertTrue(directory.completeIfCaughtUp(SyncEngine(wire,bStore!!)) {true})
                assertTrue(bStore!!.pendingRoomHeads().isEmpty());assertNull(bStore!!.cursor().pendingReceipt)
                bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                for((room,text) in expected) assertEquals(text,bStore!!.snapshot().conversations.single {it.id==room}.preview)
                directory=RoomDirectoryRecovery(wire,bStore!!,RoomSyncEngine(wire,bStore!!));directory.start()
                val before=calls.size
                assertEquals(0,directory.runTurn().pendingRooms);assertEquals(before,calls.size)

            }
        } finally {
            aSocket.close();bSocket.close();cSocket.close();aStore?.close();bStore?.close();cStore?.close()
            withContext(NonCancellable) {withTimeout(45_000) {aAuth.logout();bAuth.logout();cAuth.logout()}}
        }
    }
}
