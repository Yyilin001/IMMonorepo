package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.security.MessageDigest
import kotlinx.collections.immutable.persistentListOf
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.IOException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** Opt-in isolated server validation: errors and ACKs come from the real gateway. */
class SyncRecoveryBackendTests {
    @Test fun realGatewayRejectsCapabilitiesThenReplaysAndResumesAcknowledgedSnapshot() {
        val arguments=InstrumentationRegistry.getArguments()
        val endpoint=arguments.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend arguments",endpoint!=null)
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(arguments.getString("e2eCA"))).inputStream())
        val trust=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(trust)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager).build()
        val transport=AccountClient(endpoint!!,http)
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-","").take(12)
        val secrets=KeystoreSecretStore(context,"sync-$run-a")
        val aAuth=AuthSession(secrets,transport)
        val bAuth=AuthSession(KeystoreSecretStore(context,"sync-$run-b"),transport)
        val port=requireNotNull(arguments.getString("e2eTLSPort")).toInt()
        val aSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        val bSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        var s:SqliteClientStore?=null;var peer:SqliteClientStore?=null
        runBlocking {
            try {withTimeout(180_000) {
                val password=UUID.randomUUID().toString()+"aA1!"
                val a=aAuth.login("device_${run}_a",password,true,"device_${run}_a","同步恢复 A")
                val b=bAuth.login("device_${run}_b",password,true,"device_${run}_b","同步恢复 B")
                val boot=bootstrapBackend(context,a,b,aAuth,bAuth,transport,aSocket,bSocket,run,secrets)
                s=boot.first;peer=boot.second
                withTimeout(30_000) {while(s!!.conversationSendingPolicy(boot.room,a.userId).accountKind==null) {backendSync {SyncEngine(aSocket,s!!).synchronize()};delay(250)}}
                assertEquals(AccountKind.Regular,s!!.conversationSendingPolicy(boot.room,a.userId).accountKind)
                // Recreate a pre-classification cache and replenish only the public kind through a real authorized read.
                val hash=MessageDigest.getInstance("SHA-256").digest("${a.userId.value}/${a.deviceId.value}".toByteArray()).joinToString("") {"%02x".format(it)}
                SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$hash.db").path,null,SQLiteDatabase.OPEN_READWRITE).use {it.execSQL("DELETE FROM direct_account_kinds WHERE room=?",arrayOf(boot.room.value))}
                val kindKeys=persistentListOf(ProfileKey(b.userId,ProfileContext.DirectConversation));val kindFence=s!!.profileFences(kindKeys)
                val kindRead=ProfilePresentationClient(boot.api,a.userId,a.deviceId).read(kindKeys).single() as ProfileReadResult.Available
                assertTrue(s!!.adoptDirectAccountKind(boot.room,kindRead,kindFence));assertEquals(AccountKind.Regular,s!!.conversationSendingPolicy(boot.room,a.userId).accountKind)
                val social=SocialService(a.userId,SocialClient(boot.api,a.userId),s!!)
                val block=social.enqueue(b.userId,SocialAction.Block)
                withTimeout(30_000) {while(s!!.socialWorks().first {it.command.operation==block.command.operation}.status!=SocialWorkStatus.Committed) {social.flush();delay(250)}}
                // A blocked send is visible only as a private activity to its sender, not as a room message.
                MessageOutbox(bSocket,peer!!).send(b.userId,boot.room,"restricted private activity $run")
                withTimeout(30_000) {while(peer!!.conversationTimeline(boot.room,b.userId).activities.isEmpty()) {
                    backendSync {SyncEngine(bSocket,peer!!).synchronize()};delay(250)
                }}
                withTimeout(30_000) {while(peer!!.directSendingCapability(boot.room,b.userId)?.canSend!=false) {backendSync {SyncEngine(bSocket,peer!!).synchronize()};delay(250)}}
                val deniedCapability=requireNotNull(peer!!.directSendingCapability(boot.room,b.userId))
                val savedDraft=peer!!.saveConversationText(peer!!.conversationDraft(boot.room),"权限恢复后发送",System.currentTimeMillis())
                val frozen=SendIntentService(b.userId,peer!!).prepareDraft(savedDraft)
                assertTrue(runCatching {peer!!.submitConversationDraft(savedDraft,frozen,System.currentTimeMillis())}.exceptionOrNull() is ConversationDraftSubmissionRejected)
                assertEquals(savedDraft,peer!!.conversationDraft(boot.room))
                val activity=peer!!.conversationTimeline(boot.room,b.userId).activities.single()
                assertEquals(TimelineActivityKind.DirectMessageRestricted,activity.kind)
                assertTrue(s!!.conversationTimeline(boot.room,a.userId).activities.isEmpty())
                peer!!.close();peer=SqliteClientStore(context,b.userId,b.deviceId)
                assertEquals(deniedCapability,peer!!.directSendingCapability(boot.room,b.userId))
                assertEquals(savedDraft,peer!!.conversationDraft(boot.room))
                assertEquals(activity,peer!!.conversationTimeline(boot.room,b.userId).activities.single())
                assertEquals(TimelineLocation.Unavailable,peer!!.locateTimelineMessage(boot.room,b.userId,MessageId(activity.sourceEvent)))
                // Retain an applied but unacknowledged event, so a capability-free pull must replay it.
                val noAck=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {
                    if(body.hasSyncAck()) throw IOException("test before ACK")
                    return aSocket.request(body)
                }}
                withTimeout(30_000) {while(s!!.cursor().pendingReceipt==null) {
                    try {backendSync {SyncEngine(noAck,s!!).synchronize()}} catch(expected:IOException) {assertNotNull(s!!.cursor().pendingReceipt)}
                    if(s!!.cursor().pendingReceipt==null) delay(250)
                }}
                val before=s!!.cursor();assertTrue(before.sequence>0)
                var corruptToken=true;var corruptReceipt=true
                val rejected=mutableSetOf<String>();var replays=0
                val recovery=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {
                    val outgoing=body.build().toBuilder()
                    if(outgoing.hasSyncPull() && corruptToken) {corruptToken=false;outgoing.syncPull=outgoing.syncPull.toBuilder().setSyncToken("invalid-test-token").build()}
                    if(outgoing.hasSyncAck() && corruptReceipt) {corruptReceipt=false;outgoing.syncAck=outgoing.syncAck.toBuilder().setSyncReceipt("invalid-test-receipt").build()}
                    try {
                        val result=aSocket.request(outgoing)
                        if(result.hasSyncBatch()) replays+=result.syncBatch.recordsList.count {it.userSyncSequence<=before.sequence}
                        return result
                    } catch(error:GatewayFailure) {rejected+=error.code;throw error}
                }}
                backendSync {SyncEngine(recovery,s!!).synchronize()}
                assertTrue(rejected.containsAll(setOf("SYNC_TOKEN_INVALID","SYNC_RECEIPT_INVALID")))
                assertTrue(replays>0);assertTrue(s!!.cursor().sequence>=before.sequence);assertNull(s!!.cursor().pendingReceipt)
                assertTrue(s!!.snapshot().conversations.any {it.id==boot.room})
                assertTrue(s!!.conversationTimeline(boot.room,a.userId).activities.isEmpty())

                // The gateway accepts the snapshot; lose only its reply before local activation.
                val oldGeneration=s!!.cursor().generation
                s!!.requestSnapshotRebuild()
                var lost=false
                val loss=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {
                    val reply=aSocket.request(body)
                    if(body.hasSnapshotAck()) {assertTrue(reply.hasAcknowledged());lost=true;throw IOException("test ACK reply loss")}
                    return reply
                }}
                suspend fun awaitSnapshot()=withTimeout(60_000) {
                    while(true) {
                        try {backendSync {SyncEngine(loss,s!!).synchronize()};return@withTimeout}
                        catch(error:GatewayFailure) {
                            if(error.code!="RESET_PREPARING" || !error.retryable) throw error
                            delay(maxOf(1000L,error.retryAfterSeconds.toLong()*1000))
                        }
                    }
                }
                try {awaitSnapshot();fail("Expected ACK reply loss")} catch(expected:IOException) {assertTrue(lost)}
                val pending=requireNotNull(s!!.pendingSnapshot())
                assertEquals(oldGeneration,s!!.cursor().generation)
                s!!.close();s=SqliteClientStore(context,a.userId,a.deviceId)
                val requests=mutableListOf<Envelope>()
                val resume=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {requests+=body.build();return aSocket.request(body)}}
                backendSync {SyncEngine(resume,s!!).synchronize()}
                assertTrue(requests.first().hasSnapshotAck())
                assertEquals(pending.syncReceipt,requests.first().snapshotAck.snapshotReceipt)
                assertEquals(pending.generation,s!!.cursor().generation);assertTrue(s!!.cursor().generation>oldGeneration)
                assertNull(s!!.pendingSnapshot());assertFalse(s!!.requiresSnapshotRebuild())
                assertTrue(s!!.snapshot().conversations.any {it.id==boot.room})
                val restoredSocial=SocialService(a.userId,SocialClient(boot.api,a.userId),s!!)
                val unblock=restoredSocial.enqueue(b.userId,SocialAction.Unblock)
                withTimeout(30_000) {while(s!!.socialWorks().first {it.command.operation==unblock.command.operation}.status!=SocialWorkStatus.Committed) {restoredSocial.flush();delay(250)}}
                // Unblock alone emits no capability: a lower-level successful send models another client restoring authority.
                MessageOutbox(bSocket,peer!!).send(b.userId,boot.room,"accepted restore probe $run")
                withTimeout(30_000) {while(peer!!.directSendingCapability(boot.room,b.userId)?.canSend!=true) {backendSync {SyncEngine(bSocket,peer!!).synchronize()};delay(250)}}
                assertTrue(peer!!.directSendingCapability(boot.room,b.userId)!!.stateVersion>deniedCapability.stateVersion)
                assertEquals(frozen,peer!!.submitConversationDraft(savedDraft,frozen,System.currentTimeMillis()))
                assertTrue(peer!!.conversationDraft(boot.room).empty)
            }} finally {
                aSocket.close();bSocket.close();s?.close();peer?.close()
                try {withContext(NonCancellable) {withTimeout(45_000) {aAuth.logout();bAuth.logout()}}}
                finally {http.dispatcher.executorService.shutdown();http.connectionPool.evictAll()}
            }
        }
    }
}
