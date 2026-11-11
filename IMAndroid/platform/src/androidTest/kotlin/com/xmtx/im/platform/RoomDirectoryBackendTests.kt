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

class RoomDirectoryBackendTests {
    @Test fun durableDiscoveryResumesAfterReopenAndFinalPersonalTailVerifiesRecovery()=runBlocking<Unit> {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend",endpoint != null)
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager).build()
        val api=AccountClient(endpoint!!,http);val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-","").take(12)
        val aAuth=AuthSession(KeystoreSecretStore(context,"directory-$run-a"),api);val bAuth=AuthSession(KeystoreSecretStore(context,"directory-$run-b"),api)
        val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val aSocket=RealtimeConnection("localhost",port,ssl.socketFactory);val bSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        var aStore: SqliteClientStore?=null;var bStore: SqliteClientStore?=null;var listener: Job?=null
        try {
            withTimeout(120_000) {
                val password=UUID.randomUUID().toString()+"aA1!"
                val a=aAuth.login("dir_${run}_a",password,true,"dir_${run}_a","目录 A")
                val b=bAuth.login("dir_${run}_b",password,true,"dir_${run}_b","目录 B")
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
                RoomSyncEngine(aSocket,aStore!!).synchronize()
                val calls=mutableListOf<Envelope>()
                val wire=object: EnvelopeTransport {override suspend fun request(body: Envelope.Builder): Envelope {
                    calls+=body.build();return bSocket.request(body)
                }}
                var directory=RoomDirectoryRecovery(wire,bStore!!,RoomSyncEngine(wire,bStore!!))
                directory.start()
                val discovered=directory.runTurn(maximumPages=1,maximumRooms=0)
                assertTrue(discovered.complete);assertTrue(discovered.pendingRooms>0)
                assertFalse(directory.completeIfCaughtUp(SyncEngine(wire,bStore!!)) {true})
                val text="directory recovery $run"
                MessageOutbox(aSocket,aStore!!).send(a.userId,room,text)
                bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                directory=RoomDirectoryRecovery(wire,bStore!!,RoomSyncEngine(wire,bStore!!));directory.start()
                val pages=calls.count {it.hasUserRoomDirectoryList()}
                var progress=directory.runTurn()
                repeat(10) {if(progress.pendingRooms>0) {delay(300);progress=directory.runTurn()}}
                assertEquals(0,progress.pendingRooms);assertEquals(pages,calls.count {it.hasUserRoomDirectoryList()})
                assertTrue(bStore!!.snapshot().messages.any {it.text==text})
                val beforeFinal=calls.size
                assertTrue(directory.completeIfCaughtUp(SyncEngine(wire,bStore!!)) {true})
                assertTrue(calls.drop(beforeFinal).any {it.hasSyncPull()});assertNull(bStore!!.cursor().pendingReceipt)
                assertTrue(bStore!!.pendingRoomHeads().isEmpty())
                bSocket.close();bSocket.connect(bAuth.access())
                assertNotEquals(oldEpoch,AccountRoomChangesClient(bSocket).start())
                directory=RoomDirectoryRecovery(wire,bStore!!,RoomSyncEngine(wire,bStore!!));directory.start()
                assertTrue(directory.runTurn().complete);assertEquals(pages,calls.count {it.hasUserRoomDirectoryList()})
                assertTrue(directory.completeIfCaughtUp(SyncEngine(wire,bStore!!)) {true})
            }
        } finally {
            listener?.cancelAndJoin();aSocket.close();bSocket.close();aStore?.close();bStore?.close()
            withContext(NonCancellable) {withTimeout(45_000) {aAuth.logout();bAuth.logout()}}
        }
    }
}
