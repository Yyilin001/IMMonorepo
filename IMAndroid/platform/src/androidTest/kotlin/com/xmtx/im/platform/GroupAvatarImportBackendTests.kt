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

class GroupAvatarImportBackendTests {
    @Test fun importAndGroupAvatarCommitRecoverAfterSourceWithdrawalAndSQLiteReopen() {
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
        var resources: AccountResourceActivity?=null
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
                    fun id()=UUID.randomUUID().toString().uppercase()
                    val api=bootstrap.api;val peerApi=bootstrap.peerApi;val sourceRoom=bootstrap.room
                    val groups=GroupCreationService(a.userId,GroupCreationClient(api),aStore!!)
                    val creation=groups.prepare("导入群头像 $run",kotlinx.collections.immutable.persistentListOf(b.userId))
                    withTimeout(45000) {while(!aStore!!.groupWorks().first {it.command.operation==creation.command.operation}.terminal) {groups.flush();delay(100)}}
                    val created=aStore!!.groupWorks().first {it.command.operation==creation.command.operation}
                    assertEquals(GroupCreationStatus.Created,created.status);val room=requireNotNull(created.room)
                    backendSync {SyncEngine(aSocket,aStore!!).synchronize();SyncEngine(bSocket,bStore!!).synchronize();RoomSyncEngine(aSocket,aStore!!).synchronize()}
                    phase="upload and bind an authorized source message"
                    resources=AccountResourceActivity(context,aStore!!,ResourceUploadClient(api,a.userId)) {ManagedResourceUploadBytes(it,ResourcePlanUploader(trustedHttp))}
                    val bitmap=android.graphics.Bitmap.createBitmap(96,64,android.graphics.Bitmap.Config.ARGB_8888)
                    val bytes=com.google.protobuf.ByteString.newOutput()
                    try {bitmap.eraseColor(android.graphics.Color.CYAN);assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,bytes))} finally {bitmap.recycle()}
                    val photo=resources!!.files.importPhoto(PhotoPreparation().prepare(bytes.toByteString()),ResourceUsage.Attachment(sourceRoom))
                    val sending=SendIntentService(a.userId,aStore!!)
                    val sourceIntent=sending.enqueue(sourceRoom,"群头像导入来源 $run",kotlinx.collections.immutable.persistentListOf(SendAttachment(photo.id,photo.id,photo.displayName,photo.contentType,photo.byteCount)))
                    coroutineScope {
                        val transfer=launch {resources!!.runForeground()};val prepare=launch {sending.runPreparation()}
                        try {withTimeout(45000) {while(aStore!!.pending().none {it.clientMessageId==sourceIntent.operation}) delay(100)}}
                        finally {prepare.cancelAndJoin();transfer.cancelAndJoin()}
                    }
                    MessageOutbox(aSocket,aStore!!).flush()
                    withTimeout(15000) {while(aStore!!.snapshot().messages.none {it.text==sourceIntent.text && it.revision>0}) {RoomSyncEngine(aSocket,aStore!!).synchronize();delay(100)}}
                    val message=aStore!!.snapshot().messages.single {it.text==sourceIntent.text && it.revision>0}
                    resources!!.close();resources=null
                    val reader=GroupAvatarPresentationClient(api,a.userId,a.deviceId)
                    val commands=GroupAvatarCommandClient(api,a.userId,a.deviceId)
                    phase="select the synchronized chat image and atomically admit its group consumer"
                    val selection=aStore!!.selectAvatarResource(ResourceKey(ResourceHome.Room(sourceRoom),photo.id))
                    assertEquals(message.id,selection.source.message)
                    var service=GroupAvatarIntentService(a.userId,a.deviceId,commands,reader,aStore!!)
                    val intent=GroupAvatarResourceSelectionService(a.userId,a.deviceId,aStore!!).submit(service.refresh(room),selection)
                    val source=requireNotNull(intent.serverImport);val request=source.request
                    assertEquals(ResourceUsage.GroupAvatar(room),request.targetUsage);assertEquals(selection.importSource,request.source)
                    service.recoverOnce();assertFalse(aStore!!.groupAvatarIntents().single().submissionStarted)
                    phase="lose import create reply then withdraw its original source message"
                    val client=ResourceImportClient(api,a.userId);var creates=0
                    val lossyImport=object:ResourceImportControl by client {override suspend fun create(request: ResourceImportRequest):ResourceImportStatus {
                        creates++;client.create(request);throw IOException("simulated lost group import creation reply")
                    }}
                    ResourceImportService(a.userId,aStore!!,lossyImport).recoverOnce()
                    assertEquals(1,creates);assertNull(aStore!!.resourceImports().single().status)
                    val mutation=MessageMutationService(a.userId,MessageMutationClient(api),aStore!!)
                    val withdrawal=mutation.enqueue(sourceRoom,message.id,message.revision,null)
                    withTimeout(15000) {while(!aStore!!.mutationWorks().first {it.command.operation==withdrawal.command.operation}.terminal) {mutation.flush();delay(100)}}
                    assertEquals(MutationStatus.Committed,aStore!!.mutationWorks().first {it.command.operation==withdrawal.command.operation}.status)
                    aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                    val queryImport=object:ResourceImportControl by client {override suspend fun create(request: ResourceImportRequest):ResourceImportStatus=error("Existing import must recover its original target")}
                    resources=AccountResourceActivity(context,aStore!!,ResourceUploadClient(api,a.userId),imports=queryImport) {ManagedResourceUploadBytes(it,ResourcePlanUploader(trustedHttp))}
                    coroutineScope {
                        val task=launch {resources!!.runForeground()}
                        try {withTimeout(45000) {while(aStore!!.resourceImports().single().status?.state!=ResourceImportState.Ready) {
                            assertFalse(aStore!!.resourceImports().single().execution.attention);delay(100)
                        }}} finally {task.cancelAndJoin()}
                    }
                    resources!!.close();resources=null;assertEquals(request,aStore!!.resourceImports().single().request)
                    phase="lose committed group avatar response while retaining its import owner"
                    var submissions=0
                    val lostCommand=object:GroupAvatarCommands by commands {override suspend fun submit(command: GroupAvatarCommand):GroupAvatarCommandResponse {
                        assertEquals(intent.command,command);submissions++;val response=commands.submit(command);assertTrue(response.outcome is GroupAvatarOutcome.Committed)
                        throw IOException("simulated lost imported group avatar receipt")
                    }}
                    GroupAvatarIntentService(a.userId,a.deviceId,lostCommand,reader,aStore!!).recoverOnce()
                    val uncertain=aStore!!.groupAvatarIntents().single();assertEquals(GroupAvatarRecoveryAction.Query,uncertain.action);assertFalse(uncertain.sourceReleased)
                    assertTrue(runCatching {aStore!!.cancelResourceImport(source.id)}.isFailure)
                    aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                    val queryOnly=object:GroupAvatarCommands by commands {override suspend fun submit(command: GroupAvatarCommand):GroupAvatarCommandResponse=error("Unknown command must query its original identity")}
                    service=GroupAvatarIntentService(a.userId,a.deviceId,queryOnly,reader,aStore!!)
                    withTimeout(15000) {while(!aStore!!.groupAvatarIntents().single().terminal) {service.recoverOnce();delay(100)}}
                    val committed=aStore!!.groupAvatarIntents().single();assertEquals(GroupAvatarStage.Committed,committed.stage);assertEquals(1,submissions)
                    assertEquals(intent.command,committed.command);assertEquals(source,committed.serverImport);assertTrue(committed.sourceReleased)
                    assertTrue(aStore!!.resourceImports().single().businessBound);assertFalse(aStore!!.resourceImports().single().cancellationRequested)
                    assertEquals(committed.receipt,(commands.submit(intent.command).outcome as GroupAvatarOutcome.Committed).change)
                    phase="fresh owner and peer presentations expose independently authorized imported pixels"
                    backendSync {RoomSyncEngine(aSocket,aStore!!).synchronize();RoomSyncEngine(bSocket,bStore!!).synchronize()}
                    val shown=reader.read(room);val peer=GroupAvatarPresentationClient(peerApi,b.userId,b.deviceId).read(room)
                    assertEquals(request.targetMedia,shown.state.media);assertEquals(shown.state,peer.state);assertTrue(shown.canManage);assertFalse(peer.canManage)
                    val repository=GroupAvatarRepository(a.userId,a.deviceId,reader,aStore!!::groupAvatarFence,this)
                    val cache=AvatarCache(a.userId,a.deviceId,AvatarDownloader(trustedHttp)::download)
                    try {
                        val token=repository.activate(room);repository.read(token)
                        val grant=requireNotNull(repository.avatarReadGrant(token));assertEquals(request.targetMedia,grant.content.media)
                        val image=PhotoPreparation().prepare(cache.read(grant).read());assertTrue(image.dimensions.width>0 && image.dimensions.height>0)
                    } finally {repository.close();cache.close()}
                    aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                    assertEquals(committed,aStore!!.groupAvatarIntents().single());assertTrue(aStore!!.resourceImports().single().businessBound)
                }
            } catch(error: Throwable) {throw AssertionError("Group avatar import backend phase: $phase",error)}
            finally {resources?.close();aSocket.close();bSocket.close();aStore?.close();bStore?.close();trustedHttp.connectionPool.evictAll();trustedHttp.dispatcher.executorService.shutdown()}
        }
    }
}
