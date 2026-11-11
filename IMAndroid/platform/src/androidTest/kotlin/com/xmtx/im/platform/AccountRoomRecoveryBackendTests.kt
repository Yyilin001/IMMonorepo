package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
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

class AccountRoomRecoveryBackendTests {
    @Test fun unopenedRoomRecoversFromPersonalHeadAfterDatabaseReopenWithoutForegroundSubscription()=runBlocking<Unit> {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend",endpoint != null)
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager).build()
        val api=AccountClient(endpoint!!,http);val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-","").take(12)
        val aAuth=AuthSession(KeystoreSecretStore(context,"head-$run-a"),api);val bAuth=AuthSession(KeystoreSecretStore(context,"head-$run-b"),api)
        val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val aSocket=RealtimeConnection("localhost",port,ssl.socketFactory);val bSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        var aStore: SqliteClientStore?=null;var bStore: SqliteClientStore?=null;var listener: Job?=null
        try {
            withTimeout(120_000) {
                val password=UUID.randomUUID().toString()+"aA1!"
                val a=aAuth.login("head_${run}_a",password,true,"head_${run}_a","水位 A")
                val b=bAuth.login("head_${run}_b",password,true,"head_${run}_b","水位 B")
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
                val baseline=bStore!!.cursor().sequence;val roomCursor=bStore!!.roomCursor(room)
                val wakes=Channel<RealtimeSyncEvent>(64)
                listener=launch(start=CoroutineStart.UNDISPATCHED) {bSocket.syncEvents.collect {wakes.send(it)}}
                val text="unopened durable head $run"
                MessageOutbox(aSocket,aStore!!).send(a.userId,room,text)
                var head: AccountRoomHead?=null
                withTimeout(30_000) {
                    while(head == null) {
                        val hint=wakes.receive().hint
                        if(hint is RealtimeSyncHint.Account && hint.head > baseline) {
                            SyncEngine(bSocket,bStore!!).synchronize()
                            head=bStore!!.pendingRoomHeads().firstOrNull {it.room == room}
                        }
                    }
                }
                assertEquals(roomCursor,bStore!!.roomCursor(room));assertTrue(bStore!!.snapshot().messages.none {it.text==text})
                val personal=bStore!!.cursor();assertNull(personal.pendingReceipt)
                bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                assertEquals(personal,bStore!!.cursor());assertEquals(head,bStore!!.pendingRoomHeads().single {it.room==room})
                val result=RoomSyncEngine(bSocket,bStore!!).synchronizeRoom(room)
                assertTrue(result.appliedThrough>=head!!.sequence);assertTrue(bStore!!.snapshot().messages.any {it.text==text})
                assertTrue(bStore!!.pendingRoomHeads().none {it.room==room})
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
