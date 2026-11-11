package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

class SendRecoveryBackendTests {
    @Test fun durableOriginalIdentityRecoveryConvergesWithRealServerReceiptsAndSinglePeerProjection() {
        val arguments = InstrumentationRegistry.getArguments()
        val endpoint = arguments.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend instrumentation arguments", endpoint != null)
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(
            Base64.getDecoder().decode(requireNotNull(arguments.getString("e2eCA"))).inputStream())
        val trustStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null); setCertificateEntry("test", certificate) }
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trustStore) }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, managers.trustManagers, null) }
        val trustedHttp = OkHttpClient.Builder()
            .sslSocketFactory(ssl.socketFactory, managers.trustManagers.single() as X509TrustManager).build()
        val transport = AccountClient(endpoint!!, trustedHttp)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val run = UUID.randomUUID().toString().replace("-", "").take(12)
        val aSecrets = KeystoreSecretStore(context, "e2e-$run-a"); val bSecrets = KeystoreSecretStore(context, "e2e-$run-b")
        val aAuth = AuthSession(aSecrets, transport); val bAuth = AuthSession(bSecrets, transport)
        val port = requireNotNull(arguments.getString("e2eTLSPort")).toInt()
        val aSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        val bSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        var aStore: SqliteClientStore? = null; var bStore: SqliteClientStore? = null
        var phase="authentication"
        runBlocking {
            try {
                withTimeout(180_000) {
                    val password = UUID.randomUUID().toString() + "aA1!"
                    val a = aAuth.login("device_${run}_a", password, true, "device_${run}_a", "设备 A")
                    val b = bAuth.login("device_${run}_b", password, true, "device_${run}_b", "设备 B")
                    phase="bootstrap persistence and messages"
                    val bootstrap = bootstrapBackend(context, a, b, aAuth, bAuth, transport, aSocket, bSocket, run, aSecrets)
                    aStore = bootstrap.first; bStore = bootstrap.second
                    val api = bootstrap.api; val bApi = bootstrap.peerApi; val room = bootstrap.room
                    // Use actual friendship so the scenario is independent of the stranger-message quota.
                    suspend fun social(from: Credentials,auth: AuthSession,store: SqliteClientStore,to: UserId,action: SocialAction) {
                        val service=SocialService(from.userId,SocialClient(AuthenticatedApi(auth,transport,from.userId,from.deviceId),from.userId),store)
                        val work=service.enqueue(to,action)
                        while(!store.socialWorks().first {it.command.operation==work.command.operation}.terminal) {service.flush();delay(250)}
                        assertEquals(SocialWorkStatus.Committed,store.socialWorks().first {it.command.operation==work.command.operation}.status)
                    }
                    phase="friendship"
                    social(a,aAuth,aStore!!,b.userId,SocialAction.Request);social(b,bAuth,bStore!!,a.userId,SocialAction.Accept)
                    fun command(text: String,deadline: Long=System.currentTimeMillis()+ClientSubmissionWindow.COMMAND_MILLISECONDS)=MessageCommand.text(a.userId,room,text,deadline)
                    fun receipt(response: Envelope): MessageSendOperationReceipt {
                        assertTrue(response.hasMessageSendOperationResult());assertTrue(response.messageSendOperationResult.hasReceipt())
                        return response.messageSendOperationResult.receipt
                    }
                    suspend fun reopen() {aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)}
                    val admission=AccountRetryAdmission()
                    suspend fun settle(command: MessageSendOperation,transport: EnvelopeTransport) {
                        val outbox=MessageOutbox(transport,aStore!!,admission)
                        withTimeout(45000) {
                            while(aStore!!.pending().any {it.clientMessageId==command.clientMessageId}) {
                                outbox.flush()
                                val record=aStore!!.sendHistory(room,a.userId).items.first {it.operation==command.clientMessageId}
                                assertNotEquals("Unexpected paused confirmation in $phase",SendRecordStatus.NeedsAttention,record.status)
                                delay(250)
                            }
                        }
                    }
                    val acceptedBodies=mutableListOf<String>()
                    phase="disconnected first submission persists until new authenticated connection"
                    aSocket.close()
                    val waiting=command("connection resumed once $run");aStore!!.enqueue(waiting)
                    assertTrue(runCatching {MessageOutbox(aSocket,aStore!!,admission).flush()}.exceptionOrNull() is RealtimeUnavailableBeforeAdmission)
                    reopen()
                    assertEquals(SendRecordStatus.WaitingForNetwork,aStore!!.sendHistory(room,a.userId).items.first {it.operation==waiting.clientMessageId}.status)
                    assertNull(aStore!!.claimSend(System.currentTimeMillis()+1000))
                    aSocket.connect(aAuth.access());aStore!!.resumeNetworkWaitingSends(a.userId,System.currentTimeMillis())
                    var resumedSubmissions=0
                    val resumedSubmit=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
                        assertEquals(waiting,body.build().messageSendOperation);resumedSubmissions++
                        return aSocket.request(body)
                    }}
                    settle(waiting,resumedSubmit);assertEquals(1,resumedSubmissions);acceptedBodies+=waiting.text
                    phase="accepted response lost before durable completion"
                    val lost=command("accepted once $run");aStore!!.enqueue(lost)
                    var originalReceipt: MessageSendOperationReceipt?=null;var submissions=0;var queries=0
                    val lossy=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
                        assertEquals(lost,body.build().messageSendOperation);submissions++
                        val response=aSocket.request(body);originalReceipt=receipt(response);assertTrue(originalReceipt!!.hasAccepted())
                        throw IOException("simulated lost acceptance")
                    }}
                    assertTrue(runCatching {MessageOutbox(lossy,aStore!!,admission).flush()}.exceptionOrNull() is IOException)
                    assertEquals(1,submissions);assertEquals(lost,aStore!!.pending().single());reopen()
                    phase="unknown accepted identity waits for network without returning to submit"
                    aSocket.close();delay(600)
                    assertTrue(runCatching {MessageOutbox(aSocket,aStore!!,admission).flush()}.exceptionOrNull() is RealtimeUnavailableBeforeAdmission)
                    reopen()
                    assertEquals(SendRecordStatus.WaitingForNetwork,aStore!!.sendHistory(room,a.userId).items.first {it.operation==lost.clientMessageId}.status)
                    aSocket.connect(aAuth.access());aStore!!.resumeNetworkWaitingSends(a.userId,System.currentTimeMillis())
                    val queryOnly=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
                        val request=body.build();assertTrue(request.hasMessageSendOperationRecover());val query=request.messageSendOperationRecover
                        assertEquals(MessageSendOperationRecover.Action.QUERY,query.action);assertEquals(lost.clientMessageId,query.identity.operationId)
                        assertEquals(lost.fingerprint,query.fingerprint.digest);assertEquals(lost.domainFingerprint,query.domainFingerprint.digest);queries++
                        return aSocket.request(body)
                    }}
                    settle(lost,queryOnly);assertTrue(queries>=1);assertEquals(1,submissions)
                    val replay=receipt(aSocket.request(Envelope.newBuilder().setMessageSendOperation(lost)))
                    assertEquals(originalReceipt,replay);acceptedBodies+=lost.text
                    assertTrue(aStore!!.sendHistory(room,a.userId).items.first {it.operation==lost.clientMessageId}.status in setOf(SendRecordStatus.AcceptedAwaitingProjection,SendRecordStatus.Accepted))
                    phase="unknown submission which never reached server"
                    val absent=command("query then submit $run");aStore!!.enqueue(absent)
                    val noWrite=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {assertEquals(absent,body.build().messageSendOperation);throw IOException("before server")}}
                    assertTrue(runCatching {MessageOutbox(noWrite,aStore!!,admission).flush()}.exceptionOrNull() is IOException);reopen()
                    val actions=mutableListOf<String>()
                    val observed=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
                        val request=body.build()
                        if(request.hasMessageSendOperationRecover()) {assertEquals(absent.clientMessageId,request.messageSendOperationRecover.identity.operationId);actions+="query"}
                        else {assertEquals(absent,request.messageSendOperation);actions+="submit"}
                        return aSocket.request(body)
                    }}
                    settle(absent,observed);assertEquals("query",actions.first());assertEquals(1,actions.count {it=="submit"});acceptedBodies+=absent.text
                    phase="expired unknown identity closes without submission"
                    val expired=command("must not arrive $run",System.currentTimeMillis()-1000);aStore!!.enqueue(expired)
                    val neverSent=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {assertEquals(expired,body.build().messageSendOperation);throw IOException("before server")}}
                    assertTrue(runCatching {MessageOutbox(neverSent,aStore!!,admission) {expired.firstSubmissionDeadlineMs-100000}.flush()}.exceptionOrNull() is IOException);reopen()
                    val closing=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
                        val request=body.build();assertTrue(request.hasMessageSendOperationRecover())
                        assertEquals(MessageSendOperationRecover.Action.CLOSE_IF_ABSENT,request.messageSendOperationRecover.action)
                        assertEquals(expired.fingerprint,request.messageSendOperationRecover.fingerprint.digest)
                        return aSocket.request(body)
                    }}
                    settle(expired,closing)
                    val closed=receipt(aSocket.request(Envelope.newBuilder().setMessageSendOperation(expired)))
                    assertTrue(closed.hasRejected());assertTrue(closed.rejected.reasonValue in setOf(1,6))
                    assertTrue(aStore!!.sendHistory(room,a.userId).items.first {it.operation==expired.clientMessageId}.status in setOf(SendRecordStatus.Closed,SendRecordStatus.ExpiredUnsubmitted))
                    phase="explicit proven-unsent replacement preserves content under one new identity"
                    backendSync {SyncEngine(bSocket,bStore!!).synchronize();RoomSyncEngine(bSocket,bStore!!).synchronize()}
                    assertTrue(bStore!!.snapshot().messages.none {it.text==expired.text && it.revision>0})
                    val replacement=aStore!!.replaceUnsentText(room,a.userId,expired.clientMessageId,System.currentTimeMillis())
                    assertNotEquals(expired.clientMessageId,replacement);reopen()
                    assertEquals(replacement,aStore!!.replaceUnsentText(room,a.userId,expired.clientMessageId,System.currentTimeMillis()))
                    val replacementCommand=aStore!!.pending().single {it.clientMessageId==replacement}
                    assertEquals(expired.text,replacementCommand.text);assertNotEquals(expired.fingerprint,replacementCommand.fingerprint)
                    settle(replacementCommand,aSocket);acceptedBodies+=expired.text
                    assertEquals(closed,receipt(aSocket.request(Envelope.newBuilder().setMessageSendOperation(expired))))
                    phase="permanent rejection can be abandoned without submitting a new identity"
                    val abandoned=command("abandoned body $run",System.currentTimeMillis()-1000)
                    aStore!!.enqueue(abandoned)
                    val rejected=receipt(aSocket.request(Envelope.newBuilder().setMessageSendOperation(abandoned)))
                    assertTrue(rejected.hasRejected());validateSendReceipt(abandoned,rejected)
                    aStore!!.complete(abandoned.clientMessageId,rejected)
                    aStore!!.abandonUnsentText(room,a.userId,abandoned.clientMessageId);reopen()
                    aStore!!.abandonUnsentText(room,a.userId,abandoned.clientMessageId)
                    assertTrue(aStore!!.sendHistory(room,a.userId).items.first {it.operation==abandoned.clientMessageId}.abandoned)
                    assertTrue(runCatching {aStore!!.replaceUnsentText(room,a.userId,abandoned.clientMessageId,System.currentTimeMillis())}.isFailure)
                    val noAbandonedWork=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {error("Abandoned operation must not request network")}}
                    MessageOutbox(noAbandonedWork,aStore!!,admission).flush()
                    assertEquals(rejected,receipt(aSocket.request(Envelope.newBuilder().setMessageSendOperation(abandoned))))
                    phase="original fingerprint conflict pauses without creating a replacement identity"
                    val reserved=command("reserved server identity $run")
                    val reservedReceipt=receipt(aSocket.request(Envelope.newBuilder().setMessageSendOperation(reserved)));assertTrue(reservedReceipt.hasAccepted());acceptedBodies+=reserved.text
                    val conflicting=MessageCommand.text(a.userId,room,"conflicting local body $run",reserved.firstSubmissionDeadlineMs,reserved.clientMessageId)
                    aStore!!.enqueue(conflicting);MessageOutbox(aSocket,aStore!!,admission).flush()
                    assertEquals(SendRecordStatus.NeedsAttention,aStore!!.sendHistory(room,a.userId).items.first {it.operation==conflicting.clientMessageId}.status)
                    assertEquals(conflicting,aStore!!.pending().single());reopen()
                    aStore!!.resumeNetworkWaitingSends(a.userId,System.currentTimeMillis())
                    assertNull(aStore!!.claimSend(System.currentTimeMillis()))
                    assertTrue(runCatching {aStore!!.replaceUnsentText(room,a.userId,conflicting.clientMessageId,System.currentTimeMillis())}.isFailure)
                    assertTrue(runCatching {aStore!!.abandonUnsentText(room,a.userId,conflicting.clientMessageId)}.isFailure)
                    phase="both devices converge exactly once and survive SQLite reopen"
                    withTimeout(45000) {
                        while(true) {
                            backendSync {SyncEngine(aSocket,aStore!!).synchronize();SyncEngine(bSocket,bStore!!).synchronize();RoomSyncEngine(aSocket,aStore!!).synchronize();RoomSyncEngine(bSocket,bStore!!).synchronize()}
                            if(acceptedBodies.all {text->bStore!!.snapshot().messages.any {it.text==text && it.revision>0}}) break
                            delay(500)
                        }
                    }
                    reopen();bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                    for(store in listOf(aStore!!,bStore!!)) {
                        val projected=store.snapshot().messages.filter {it.revision>0}
                        for(text in acceptedBodies) assertEquals("Duplicate or missing message",1,projected.count {it.text==text})
                        assertTrue(projected.none {it.text==conflicting.text || it.text==abandoned.text})
                    }
                    val recovered=aStore!!.sendHistory(room,a.userId).items.first {it.operation==lost.clientMessageId}
                    assertEquals(SendRecordStatus.Accepted,recovered.status)
                    assertEquals(originalReceipt!!.accepted.messageId,recovered.message!!.value)
                    assertEquals(originalReceipt!!.accepted.messageId,bStore!!.snapshot().messages.single {it.text==lost.text && it.revision>0}.id.value)
                    val replaced=aStore!!.sendHistory(room,a.userId).items.first {it.operation==expired.clientMessageId}
                    assertEquals(replacement,replaced.replacement);assertFalse(replaced.canReplaceText)
                }
            } catch(error: Throwable) {throw AssertionError("Send recovery backend phase: $phase",error)}
            finally {aSocket.close();bSocket.close();aStore?.close();bStore?.close();trustedHttp.connectionPool.evictAll();trustedHttp.dispatcher.executorService.shutdown()}
        }
    }
}
