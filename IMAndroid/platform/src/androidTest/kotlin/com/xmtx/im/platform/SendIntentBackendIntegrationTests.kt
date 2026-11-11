package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
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

/** Explicit opt-in; a private test CA is supplied as public certificate bytes, never by disabling TLS checks. */
class SendIntentBackendIntegrationTests {
    @Test fun durableAttachmentsRecoverUploadHandoffAndAcceptedMessageAcrossReopen() {
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
            try { withTimeout(180_000) {
                val password=UUID.randomUUID().toString()+"aA1!"
                val a=aAuth.login("device_${run}_a",password,true,"device_${run}_a","附件设备 A")
                val b=bAuth.login("device_${run}_b",password,true,"device_${run}_b","附件设备 B")
                val bootstrap=bootstrapBackend(context,a,b,aAuth,bAuth,transport,aSocket,bSocket,run,aSecrets)
                aStore=bootstrap.first;bStore=bootstrap.second
                val sendAdmission=AccountRetryAdmission()
                fun activity()=AccountResourceActivity(context,aStore!!,ResourceUploadClient(bootstrap.api,a.userId),imports=ResourceImportClient(bootstrap.api,a.userId),download=MediaFileDownloader(trustedHttp)::download) { ManagedResourceUploadBytes(it,ResourcePlanUploader(trustedHttp)) }
                resources=activity();val room=bootstrap.room
                phase="atomically freeze a photo and a text file"
                val bitmap=android.graphics.Bitmap.createBitmap(160,100,android.graphics.Bitmap.Config.ARGB_8888)
                val encoded=com.google.protobuf.ByteString.newOutput()
                try { bitmap.eraseColor(android.graphics.Color.BLUE);assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,encoded)) } finally { bitmap.recycle() }
                val photo=resources!!.files.importPhoto(PhotoPreparation().prepare(encoded.toByteString()),ResourceUsage.Attachment(room))
                val source=java.io.File.createTempFile("durable-send-",".txt",context.filesDir)
                val file=try { source.writeText("独立附件 $run");resources!!.files.importDocument(context.contentResolver,DocumentTestProvider.uri(source),ResourceUsage.Attachment(room),4096) } finally { source.delete() }
                suspend fun importPlayable(name: String,type: String): ResourceLocalAsset {
                    val staged=java.io.File.createTempFile("playback-upload-",".bin",context.filesDir)
                    return try {
                        InstrumentationRegistry.getInstrumentation().context.assets.open("playback/$name").use { input->staged.outputStream().use {input.copyTo(it)} }
                        resources!!.files.importFile(staged,name,type,ResourceUsage.Attachment(room),1024*1024)
                    } finally {staged.delete()}
                }
                val audio=importPlayable("tone.wav","audio/wav");val video=importPlayable("sample.mp4","video/mp4")
                val imported=persistentListOf(photo,file,audio,video).map { SendAttachment(it.id,it.id,it.displayName,it.contentType,it.byteCount) }.toPersistentList()
                var service=SendIntentService(a.userId,aStore!!)
                // Restore published selections, persist the text, then reopen before the atomic handoff.
                val replyTarget=aStore!!.snapshot().messages.first {it.roomId==room && it.sender==b.userId && it.delivery==Delivery.Accepted}
                val text=" A😀e\u0301 中文 link $run "
                val rich=MessageRichContent(persistentListOf(MentionTarget.User(b.userId)),persistentListOf(
                    RichTextEntity(2,2,RichTextKind.bold),RichTextEntity(4,2,RichTextKind.italic),RichTextEntity(5,1,RichTextKind.underline),
                    RichTextEntity(7,2,RichTextKind.strikethrough),RichTextEntity(7,2,RichTextKind.spoiler),RichTextEntity(1,1,RichTextKind.code),
                    RichTextEntity(0,10,RichTextKind.preformatted),RichTextEntity(10,4,RichTextKind.link,"https://example.test/a?q=%E4%B8%AD#fragment")),replyTarget.id)
                val originalDraft=aStore!!.saveConversationContent(aStore!!.conversationDraft(room),text,rich,System.currentTimeMillis())
                assertEquals(imported,originalDraft.attachments)
                val draft=aStore!!.reorderConversationAttachments(originalDraft,originalDraft.attachments.asReversed().map { it.asset }.toPersistentList(),System.currentTimeMillis())
                val selected=draft.attachments
                resources!!.close();aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId);resources=activity();service=SendIntentService(a.userId,aStore!!)
                assertEquals(draft,aStore!!.conversationDraft(room))
                val intent=service.prepare(room,draft.sendText,draft.attachments,draft.rich)
                aStore!!.submitConversationDraft(draft,intent,System.currentTimeMillis())
                assertTrue(aStore!!.conversationDraft(room).empty)
                val next=aStore!!.saveConversationText(aStore!!.conversationDraft(room),"下一条草稿 $run",System.currentTimeMillis())
                aStore!!.submitConversationDraft(draft,intent,System.currentTimeMillis())
                assertEquals(next,aStore!!.conversationDraft(room))
                assertEquals(selected.map { it.id },aStore!!.resourceUploads().map { it.id });assertTrue(aStore!!.pending().isEmpty())
                resources!!.close();aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId);resources=activity();service=SendIntentService(a.userId,aStore!!)
                assertEquals(intent,aStore!!.sendIntents().single().intent);assertEquals(next,aStore!!.conversationDraft(room))
                phase="account workers upload and freeze the original ordered message"
                coroutineScope {
                    val upload=launch { resources!!.runForeground() };val prepare=launch { service.runPreparation() }
                    try { withTimeout(60000) { while(aStore!!.pending().none { it.clientMessageId==intent.operation }) {
                        val status=aStore!!.sendIntents().single()
                        assertTrue(status.phase in setOf(SendIntentPhase.Preparing,SendIntentPhase.Confirming))
                        delay(50)
                    } } } finally { prepare.cancelAndJoin();upload.cancelAndJoin() }
                }
                val frozen=aStore!!.pending().single();assertEquals(selected.map { it.id },frozen.mediaIdsList);assertEquals(rich,MessageRichContent.fromCommand(frozen))
                resources!!.close();resources=null;aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                assertEquals(frozen,aStore!!.pending().single())
                phase="accepted reply lost before receipt persistence"
                var accepted:MessageSendOperationReceipt?=null
                val lossy=object: EnvelopeTransport { override suspend fun request(body:Envelope.Builder):Envelope {
                    assertEquals(frozen,body.build().messageSendOperation)
                    val response=aSocket.request(body);assertTrue(response.messageSendOperationResult.hasReceipt())
                    accepted=response.messageSendOperationResult.receipt;assertTrue(accepted!!.hasAccepted())
                    throw java.io.IOException("simulated lost accepted send receipt")
                } }
                assertTrue(runCatching { MessageOutbox(lossy,aStore!!,sendAdmission).flush() }.exceptionOrNull() is java.io.IOException)
                assertEquals(SendIntentPhase.Confirming,aStore!!.sendIntents().single().phase)
                assertTrue(runCatching { SendIntentService(a.userId,aStore!!).discard(intent.id) }.isFailure)
                aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                assertEquals(frozen,aStore!!.pending().single())
                withTimeout(15000) {while(aStore!!.pending().any {it.clientMessageId==intent.operation}) {MessageOutbox(aSocket,aStore!!,sendAdmission).flush();delay(100)}}
                assertEquals(SendIntentPhase.Accepted,aStore!!.sendIntents().single().phase);assertTrue(aStore!!.sendIntents().single().intent.sourcesReleased)
                phase="recipient projection preserves attachment order and verified descriptors"
                withTimeout(15000) { while(bStore!!.snapshot().messages.none { it.id.value==accepted!!.accepted.messageId && it.media?.presentations!=null }) {
                    RoomSyncEngine(bSocket,bStore!!).synchronize();delay(100)
                } }
                val received=bStore!!.snapshot().messages.single { it.id.value==accepted!!.accepted.messageId }
                assertEquals(rich,received.rich);assertEquals(intent.text,received.text);assertEquals(selected.map { it.id },received.media!!.ids)
                assertEquals(listOf(MessageMediaKind.Video,MessageMediaKind.Audio,MessageMediaKind.File,MessageMediaKind.Image),received.media!!.presentations!!.map { it.kind })
                assertEquals(listOf(video.checksum,audio.checksum,file.checksum,photo.checksum),received.media!!.presentations!!.map { it.descriptor.checksum })
                assertEquals(1,bStore!!.snapshot().messages.count { it.text==intent.text })
                phase="recipient authorizes and exports original file through a content provider"
                val recipientFiles=ManagedResourceFiles(context,bStore!!,download=MediaFileDownloader(trustedHttp)::download)
                val recipientApi=AuthenticatedApi(bAuth,transport,b.userId,b.deviceId)
                val originalFiles=MessageOriginalFiles(MediaDownloadTargetClient(recipientApi),bStore!!,recipientFiles)
                val temporary=TemporaryResourceFiles(context,this,bStore!!.resourceDirectoryChanges) { bStore!!.isMessageResourceCurrent(it) }
                val exported=java.io.File.createTempFile("export-received-",".txt",context.filesDir)
                val destination=android.net.Uri.parse("content://com.xmtx.im.platform.test.exports/${exported.name}")
                try {
                    for(playable in received.media!!.presentations!!.filter {it.kind in setOf(MessageMediaKind.Audio,MessageMediaKind.Video)}) {
                        originalFiles.withAuthorizedOriginal(playable.descriptor.key,message=MediaMessageLocation(room,received.id)) { authorized,original->
                            assertEquals(playable.descriptor,authorized.evidence.descriptor)
                            assertEquals(playable.byteCount,original.length())
                            assertEquals(playable.descriptor.checksum,ResourceChecksum(java.security.MessageDigest.getInstance("SHA-256").digest(original.readBytes()).joinToString("") {"%02x".format(it)}))
                        }
                    }
                    val descriptor=received.media!!.presentations!!.single {it.kind==MessageMediaKind.File}.descriptor
                    originalFiles.withAuthorizedOriginal(descriptor.key,message=MediaMessageLocation(room,received.id)) { authorized,original ->
                        assertEquals(descriptor,authorized.evidence.descriptor)
                        DocumentExport.copy(context.contentResolver,destination,original,descriptor,authorized.deadlineNanos) {
                            check(bStore!!.isMessageResourceCurrent(authorized.evidence))
                        }
                    }
                    val temporaryLease=requireNotNull(originalFiles.withAuthorizedOriginal(descriptor.key,message=MediaMessageLocation(room,received.id)) { authorized,original -> temporary.prepare(authorized,original) })
                    try {
                        assertEquals("独立附件 $run",context.contentResolver.openInputStream(temporaryLease.uri)!!.bufferedReader().use { it.readText() })
                        assertTrue(runCatching { context.contentResolver.openFileDescriptor(temporaryLease.uri,"rw")?.close() }.isFailure)
                    } finally { temporaryLease.release() }
                    assertTrue(runCatching { context.contentResolver.openInputStream(temporaryLease.uri)?.close() }.isFailure)
                    assertEquals("独立附件 $run",exported.readText())
                    assertEquals(descriptor.byteCount,exported.length())
                    assertEquals(descriptor.checksum,ResourceChecksum(java.security.MessageDigest.getInstance("SHA-256").digest(exported.readBytes()).joinToString("") { "%02x".format(it) }))
                } finally { temporary.close();originalFiles.close();recipientFiles.close();exported.delete() }
                phase="server imports and one new upload freeze as a mixed ordered message"
                resources=activity();service=SendIntentService(a.userId,aStore!!)
                val mixedPreparation=prepareMixedDraftBackend(aStore!!,aSocket,resources!!.files,service,room,photo.id,file.id,run)
                val mixed=mixedPreparation.intent
                coroutineScope {
                    val transfers=launch {resources!!.runForeground()};val preparing=launch {service.runPreparation()}
                    try {withTimeout(60000) {while(aStore!!.pending().none {it.clientMessageId==mixed.operation}) {
                        val task=aStore!!.sendIntents().first {it.intent.id==mixed.id}
                        assertTrue("Import preparation failed: ${task.phase}",task.phase in setOf(SendIntentPhase.Preparing,SendIntentPhase.Confirming));delay(50)
                    }}} finally {preparing.cancelAndJoin();transfers.cancelAndJoin()}
                }
                val mixedCommand=aStore!!.pending().single();assertEquals(mixed.mediaIds,mixedCommand.mediaIdsList)
                resources!!.close();resources=null
                var mixedReceipt: MessageSendOperationReceipt?=null
                val lostImportedReply=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
                    assertEquals(mixedCommand,body.build().messageSendOperation)
                    mixedReceipt=aSocket.request(body).messageSendOperationResult.receipt;assertTrue(mixedReceipt!!.hasAccepted())
                    throw java.io.IOException("simulated lost imported send receipt")
                }}
                assertTrue(runCatching {MessageOutbox(lostImportedReply,aStore!!,sendAdmission).flush()}.exceptionOrNull() is java.io.IOException)
                assertTrue(runCatching {aStore!!.cancelResourceImport(mixedPreparation.photoImport)}.isFailure)
                aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                val onlyQuery=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
                    assertTrue(body.hasMessageSendOperationRecover());assertEquals(mixed.operation,body.messageSendOperationRecover.identity.operationId)
                    return aSocket.request(body)
                }}
                withTimeout(15000) {while(aStore!!.pending().any {it.clientMessageId==mixed.operation}) {MessageOutbox(onlyQuery,aStore!!,sendAdmission).flush();delay(100)}}
                assertTrue(aStore!!.resourceImports().all {it.businessBound && !it.cancellationRequested})
                assertTrue(aStore!!.sendIntents().first {it.intent.id==mixed.id}.intent.sourcesReleased)
                withTimeout(15000) {while(bStore!!.snapshot().messages.none {it.id.value==mixedReceipt!!.accepted.messageId && it.media?.presentations!=null}) {
                    RoomSyncEngine(bSocket,bStore!!).synchronize();delay(100)
                }}
                val importedMessage=bStore!!.snapshot().messages.single {it.id.value==mixedReceipt!!.accepted.messageId}
                assertEquals(mixed.mediaIds,importedMessage.media!!.ids)
                assertEquals(listOf(photo.checksum,mixedPreparation.extraChecksum,file.checksum),importedMessage.media!!.presentations!!.map {it.descriptor.checksum})
                assertEquals(1,bStore!!.snapshot().messages.count {it.text==mixed.text})
                phase="plain edit clears format but preserves mentions and reply, then withdrawal clears all"
                RoomSyncEngine(aSocket,aStore!!).synchronize()
                val mutations=MessageMutationService(a.userId,MessageMutationClient(bootstrap.api),aStore!!)
                val edit=mutations.enqueue(room,received.id,received.revision,"edited rich $run");mutations.flush()
                assertEquals(MutationStatus.Committed,aStore!!.mutationWorks().first {it.command.operation==edit.command.operation}.status)
                withTimeout(15000) {while(bStore!!.snapshot().messages.first {it.id==received.id}.revision==received.revision) {RoomSyncEngine(bSocket,bStore!!).synchronize();delay(100)}}
                val edited=bStore!!.snapshot().messages.first {it.id==received.id};assertEquals(rich.copy(entities=persistentListOf()),edited.rich)
                RoomSyncEngine(aSocket,aStore!!).synchronize()
                val withdrawal=mutations.enqueue(room,received.id,edited.revision,null);mutations.flush()
                assertEquals(MutationStatus.Committed,aStore!!.mutationWorks().first {it.command.operation==withdrawal.command.operation}.status)
                withTimeout(15000) {while(!bStore!!.snapshot().messages.first {it.id==received.id}.withdrawn) {RoomSyncEngine(bSocket,bStore!!).synchronize();delay(100)}}
                bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                assertEquals(MessageRichContent.Empty,bStore!!.snapshot().messages.first {it.id==received.id}.rich)
                phase="copied attachment remains independently readable after original message withdrawal"
                val copiedFiles=ManagedResourceFiles(context,bStore!!,download=MediaFileDownloader(trustedHttp)::download)
                val copiedReader=MessageOriginalFiles(MediaDownloadTargetClient(bootstrap.peerApi),bStore!!,copiedFiles)
                try {
                    val descriptor=importedMessage.media!!.presentations!!.last().descriptor
                    copiedReader.withAuthorizedOriginal(descriptor.key,message=MediaMessageLocation(room,importedMessage.id)) {_,original->
                        assertEquals("独立附件 $run",original.readText())
                        assertEquals(file.checksum,ResourceChecksum(java.security.MessageDigest.getInstance("SHA-256").digest(original.readBytes()).joinToString("") {"%02x".format(it)}))
                    }
                } finally {copiedReader.close();copiedFiles.close()}

                resources=activity();resources!!.files.cleanup();assertTrue(aStore!!.resourceFiles().isEmpty())
                assertTrue(aStore!!.resourceUploads().all { it.sourceReleased });assertEquals(mixedPreparation.next,aStore!!.conversationDraft(room))
            } } catch(error:Throwable) { throw AssertionError("Durable attachment send failed during $phase",error) }
            finally {
                resources?.close();aSocket.close();bSocket.close();aStore?.close();bStore?.close()
                withContext(NonCancellable) { withTimeout(45000) { aAuth.logout();bAuth.logout() } }
            }
        }
    }
}
