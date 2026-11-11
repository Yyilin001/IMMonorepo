package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import java.io.File
import java.util.UUID

/** Actual HTTPS control and object bytes; the same private test CA verifies both hosts normally. */
internal suspend fun verifyResourceBackend(context: Context,a: Credentials,b: Credentials,room: RoomId,
    api: AuthenticatedTransport,peerApi: AuthenticatedTransport,http: OkHttpClient,run: String,initial: SqliteClientStore,realtime: EnvelopeTransport): SqliteClientStore {
    val source=File.createTempFile("resource-$run-",".txt",context.cacheDir);var phase="capabilities"
    var store=initial;var files=ManagedResourceFiles(context,store);var succeeded=false
    try {
        source.writeText("Android 原生后端上传验证 $run\n")
        val asset=files.importFile(source,"上传验证.txt","text/plain",ResourceUsage.Attachment(room),1024)
        val checksum=asset.checksum
        fun identity()=UUID.randomUUID().toString().uppercase()
        val request=ResourceUploadRequest(identity(),identity(),ResourceUsage.Attachment(room),"text/plain",source.length(),checksum,displayName="上传验证.txt")
        val work=store.prepareResourceUpload(identity(),asset.id,request)
        source.delete()
        var client=ResourceUploadClient(api,a.userId)
        assertTrue(client.capabilities().allows(request))
        phase="idempotent create and original session recovery"
        val created=client.create(request);assertEquals(request.media,created.media);assertEquals(ResourceHome.Room(room),created.locator.home)
        // Simulate a lost create reply: only the original prepared identity exists on disk.
        files.close();store.close();store=SqliteClientStore(context,a.userId,a.deviceId);files=ManagedResourceFiles(context,store)
        val restored=store.resourceUploads().first { it.id==work.id };assertNull(restored.session);assertEquals(request,restored.request)
        client=ResourceUploadClient(api,a.userId)
        val duplicate=client.create(restored.request);assertEquals(created.locator,duplicate.locator);store.saveResourceUploadSession(work.id,duplicate)
        var session=client.status(requireNotNull(store.resourceUploads().first { it.id==work.id }.session));assertEquals(created.locator,session.locator)
        val peer=ResourceUploadClient(peerApi,b.userId)
        val denied=runCatching { peer.status(session) }.exceptionOrNull();assertTrue(denied is ClientFailure.Http && denied.status in setOf(403,404))
        phase="foreground target and exact source upload"
        val target=requireNotNull(client.target(session,request));assertEquals(ResourceTransferMode.Put,target.mode)
        assertEquals(request.byteCount,target.expectedBytes);assertTrue(target.headers.none { it.value.contains(a.accessToken) });assertFalse(target.url.contains(a.accessToken))
        files.withOriginal(upload=work.id) { ResourcePlanUploader(http).upload(it,target,checksum) }
        phase="finalize and processing ready"
        session=client.status(session);session=client.finalize(session)
        withTimeout(30000) { while(!session.bindable(System.currentTimeMillis())) {
            assertTrue(session.state !in setOf(ResourceSessionState.Failed,ResourceSessionState.Cancelled,ResourceSessionState.Expired));assertNotEquals(ResourceState.Rejected,session.resourceState)
            delay(200);session=client.status(session)
        } }
        assertEquals(ResourceSessionState.Completed,session.state);assertEquals(ResourceState.Ready,session.resourceState)
        store.saveResourceUploadSession(work.id,session)
        val repeated=client.finalize(session);assertEquals(session.locator,repeated.locator);assertEquals(session.media,repeated.media);assertTrue(repeated.bindable(System.currentTimeMillis()))
        phase="cancel and recover original cancellation"
        val second=files.withOriginal(upload=work.id) { files.importFile(it,"上传验证.txt","text/plain",ResourceUsage.Attachment(room),1024) }
        val abandonedRequest=request.copy(operation=identity(),media=identity())
        val abandonedWork=store.prepareResourceUpload(identity(),second.id,abandonedRequest)
        store.releaseResourceUploadSource(work.id);files.cleanup();assertEquals(1,store.resourceFiles().size)
        val abandoned=client.create(abandonedRequest);store.saveResourceUploadSession(abandonedWork.id,abandoned)
        store.requestResourceUploadCancellation(abandonedWork.id)
        files.close();store.close();store=SqliteClientStore(context,a.userId,a.deviceId);files=ManagedResourceFiles(context,store)
        assertTrue(store.resourceUploads().first { it.id==abandonedWork.id }.cancellationRequested)
        val cancelled=client.cancel(abandoned);assertEquals(ResourceSessionState.Cancelled,cancelled.state);assertFalse(cancelled.bindable(System.currentTimeMillis()))
        assertEquals(ResourceSessionState.Cancelled,client.status(cancelled).state)
        assertEquals(ResourceSessionState.Cancelled,client.cancel(cancelled).state)
        store.confirmResourceUploadCancellation(abandonedWork.id,cancelled);store.releaseResourceUploadSource(abandonedWork.id);files.cleanup()
        assertTrue(store.resourceFiles().isEmpty());assertTrue(store.resourceUploads().all { it.sourceReleased })
        phase="account foreground activity drains then recovers lost create and finalize replies"
        files.close()
        source.writeText("自动恢复上传 $run\n")
        var lostCreate=false;var lostFinalize=false
        val firstCreated=CompletableDeferred<Unit>()
        val lossy=object: ResourceUploadControl by client {
            override suspend fun create(request: ResourceUploadRequest): ResourceUploadSession {
                val result=client.create(request);if(!lostCreate) { lostCreate=true;firstCreated.complete(Unit);awaitCancellation() };return result
            }
            override suspend fun finalize(session: ResourceUploadSession): ResourceUploadSession {
                val result=client.finalize(session);if(!lostFinalize) { lostFinalize=true;throw java.io.IOException("simulated lost finalize reply") };return result
            }
        }
        val resources=AccountResourceActivity(context,store,lossy,download=MediaFileDownloader(http)::download) { ManagedResourceUploadBytes(it,ResourcePlanUploader(http)) }
        try { coroutineScope {
            val automaticAsset=resources.files.importFile(source,"自动上传.txt","text/plain",ResourceUsage.Attachment(room),1024)
            val automaticRequest=ResourceUploadRequest(identity(),identity(),automaticAsset.purpose,automaticAsset.contentType,automaticAsset.byteCount,automaticAsset.checksum,displayName=automaticAsset.displayName)
            val automatic=store.prepareResourceUpload(identity(),automaticAsset.id,automaticRequest);source.delete()
            val first=launch { resources.runForeground() };withTimeout(15000) { firstCreated.await() }
            first.cancelAndJoin()
            val interrupted=store.resourceUploads().first { it.id==automatic.id };assertNull(interrupted.session);assertNull(interrupted.execution.owner);assertEquals(ResourceUploadAction.Create,interrupted.execution.next)
            val resumed=launch { resources.runForeground() }
            withTimeout(30000) { while(!store.resourceUploads().first { it.id==automatic.id }.terminal) {
                assertFalse(store.resourceUploads().first { it.id==automatic.id }.execution.attention);delay(50)
            } }
            val finished=store.resourceUploads().first { it.id==automatic.id };assertEquals(ResourceUploadStage.Ready,finished.stage);assertEquals(automaticRequest,finished.request)
            assertTrue(finished.session!!.bindable(System.currentTimeMillis()));assertTrue(lostCreate && lostFinalize)
            resumed.cancelAndJoin()
            store.releaseResourceUploadSource(automatic.id);resources.files.cleanup();assertTrue(store.resourceFiles().isEmpty())
            phase="attachment command and authorized resource directory"
            verifyResourceDirectoryBackend(a.userId,room,store,api,peerApi,realtime,kotlinx.collections.immutable.persistentListOf(request,automaticRequest))
            phase="normalized avatar pixels upload, server processing, profile binding and removal"
            val pixels=android.graphics.Bitmap.createBitmap(240,160,android.graphics.Bitmap.Config.ARGB_8888)
            val encoded=com.google.protobuf.ByteString.newOutput()
            try { pixels.eraseColor(android.graphics.Color.BLUE);assertTrue(pixels.compress(android.graphics.Bitmap.CompressFormat.PNG,100,encoded)) }
            finally { pixels.recycle() }
            val processor=PhotoPreparation()
            val photo=processor.crop(processor.prepare(encoded.toByteString()),PhotoCrop(0.2,0.0,0.6,1.0))
            val avatar=resources.files.importPhoto(photo,ResourceUsage.UserAvatar)
            val avatarRequest=ResourceUploadRequest(identity(),identity(),avatar.purpose,avatar.contentType,avatar.byteCount,avatar.checksum,displayName=avatar.displayName,dimensions=avatar.dimensions)
            val avatarWork=store.prepareResourceUpload(identity(),avatar.id,avatarRequest)
            val chatPhoto=resources.files.importPhoto(photo,ResourceUsage.Attachment(room))
            val chatRequest=ResourceUploadRequest(identity(),identity(),chatPhoto.purpose,chatPhoto.contentType,chatPhoto.byteCount,chatPhoto.checksum,displayName=chatPhoto.displayName,dimensions=chatPhoto.dimensions)
            val chatWork=store.prepareResourceUpload(identity(),chatPhoto.id,chatRequest)
            val avatarRun=launch { resources.runForeground() }
            withTimeout(30000) { while(!store.resourceUploads().first { it.id==avatarWork.id }.terminal || !store.resourceUploads().first { it.id==chatWork.id }.terminal) {
                assertFalse(store.resourceUploads().first { it.id==avatarWork.id }.execution.attention);delay(100)
            } }
            val avatarReady=store.resourceUploads().first { it.id==avatarWork.id }
            assertTrue(avatarReady.session!!.bindable(System.currentTimeMillis()));assertEquals(ResourceUploadStage.Ready,avatarReady.stage)
            avatarRun.cancelAndJoin()
            assertTrue(store.resourceUploads().first { it.id==chatWork.id }.session!!.bindable(System.currentTimeMillis()))
            phase="selected chat image imports into an independent personal avatar"
            verifyAvatarResourceSelectionBackend(a,room,store,api,realtime,http,chatRequest,resources.files)
            store.releaseResourceUploadSource(chatWork.id)
            val profile=OwnProfileClient(api,a.userId);val original=profile.current()
            val update=OwnProfileCommand(a.userId,identity(),original.revision,OwnProfilePatch(avatar=ProfileAvatarPatch.Set(avatarRequest.media)),System.currentTimeMillis()+86400000)
            assertEquals(OwnProfileStatus.Committed,profile.submit(update).status)
            val bound=profile.current();assertEquals(avatarRequest.media,bound.avatarMediaId)
            val restored=OwnProfileCommand(a.userId,identity(),bound.revision,OwnProfilePatch(avatar=original.avatarMediaId?.let { ProfileAvatarPatch.Set(it) } ?: ProfileAvatarPatch.Remove),System.currentTimeMillis()+86400000)
            assertEquals(OwnProfileStatus.Committed,profile.submit(restored).status);assertEquals(original.avatarMediaId,profile.current().avatarMediaId)
            store.releaseResourceUploadSource(avatarWork.id);resources.files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } } finally { resources.close() }
        succeeded=true;return store
    } catch(error: Throwable) { throw AssertionError("Resource upload failed during $phase",error) }
    finally { files.close();if(!succeeded && store!==initial) store.close();source.delete() }
}
