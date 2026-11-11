package com.xmtx.im.platform

import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import java.io.IOException
import java.util.UUID

/** The picker SDK path uses actual message context, not an already authorized avatar source. */
internal suspend fun verifyAvatarResourceSelectionBackend(credentials: Credentials,room: RoomId,store: SqliteClientStore,
    api: AuthenticatedTransport,realtime: EnvelopeTransport,http: OkHttpClient,upload: ResourceUploadRequest,files: ManagedResourceFiles) {
    fun id()=UUID.randomUUID().toString().uppercase()
    var phase="send room image and synchronize its resource descriptor"
    var previews: MessageImagePreviews?=null
    var originals: MessageOriginalFiles?=null
    var retainedVariant: ResourceVariantKey?=null
    try {
        val command=MessageCommand.withMedia(credentials.userId,room,"",persistentListOf(upload.media),System.currentTimeMillis()+86400000,id())
        store.enqueue(command);MessageOutbox(realtime,store).flush()
        withTimeout(15000) { while(true) {
            RoomSyncEngine(realtime,store).synchronize()
            if(store.resourceDirectory(ResourceCatalogQuery(room=room,category=ResourceCategory.Image)).entries.any { it.descriptor.key.media==upload.media }) break
            delay(100)
        } }
        val selector=AvatarResourceSelectionService(credentials.userId,store)
        val selection=selector.select(ResourceKey(ResourceHome.Room(room),upload.media))
        assertEquals(upload.checksum,selection.descriptor.checksum);assertEquals(upload.byteCount,selection.descriptor.byteCount)
        phase="authorize bounded derived preview and reuse verified bytes with fresh message authority"
        val targetClient=MediaDownloadTargetClient(api);val bytesClient=MediaPreviewDownloader(http);var authorizations=0;var downloads=0
        previews=MessageImagePreviews({ media,location,size -> authorizations++;targetClient.resolve(media,location,size) },store,{ target -> downloads++;bytesClient.download(target) })
        val firstPreview=previews!!.read(selection.key);val cachedPreview=previews!!.read(selection.key)
        assertEquals(2,authorizations);assertEquals(1,downloads);assertEquals(firstPreview.encoded,cachedPreview.encoded)
        assertEquals(selection.descriptor,firstPreview.read.descriptor);assertEquals(selection.source,firstPreview.read.source)
        assertTrue(firstPreview.variant.key.rendition is ResourceRendition.Derived);assertTrue(firstPreview.encoded.size()<=2*1024*1024)
        val bounds=android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds=true }
        firstPreview.encoded.newInput().use { android.graphics.BitmapFactory.decodeStream(it,null,bounds) }
        assertTrue(bounds.outWidth in 1..320 && bounds.outHeight in 1..320)
        phase="authorize the clicked message for its large viewer preview"
        val viewerLocation=MediaMessageLocation(room,selection.source.message)
        val largePreview=previews!!.read(selection.key,MediaImagePreviewSize.Large,viewerLocation)
        assertEquals(viewerLocation.message,largePreview.read.source.message)
        val largeBounds=android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds=true }
        largePreview.encoded.newInput().use { android.graphics.BitmapFactory.decodeStream(it,null,largeBounds) }
        assertTrue(largeBounds.outWidth in 1..1280 && largeBounds.outHeight in 1..1280)
        val previewAuthorizationCount=authorizations;val previewDownloadCount=downloads
        phase="stream original message image to a verified private file under fresh authorization"
        val originalDirectory=java.io.File(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"original-download-${id()}").apply { mkdirs() }
        try {
            val originalTarget=targetClient.resolve(selection.key.media,MediaMessageLocation(room,selection.source.message),null)
            assertNull(originalTarget.preview);assertEquals(selection.descriptor.checksum,originalTarget.plan.checksum)
            val originalFile=java.io.File(originalDirectory,"verified-original")
            MediaFileDownloader(http,1024).download(originalTarget,originalFile)
            assertEquals(selection.descriptor.byteCount,originalFile.length())
            val digest=java.security.MessageDigest.getInstance("SHA-256")
            originalFile.inputStream().use { input -> val buffer=ByteArray(65536);while(true) { val count=input.read(buffer);if(count<0) break;digest.update(buffer,0,count) } }
            assertEquals(requireNotNull(selection.descriptor.checksum).value,digest.digest().joinToString("") { "%02x".format(it) })
            assertFalse(java.io.File(originalFile.path+".range-journal").exists())
        } finally { originalDirectory.deleteRecursively() }
        phase="authorize each cache borrow and reuse existing managed upload originals"
        var originalAuthorizations=0
        originals=MessageOriginalFiles({ media,location,size -> originalAuthorizations++;targetClient.resolve(media,location,size) },store,files)
        val existingFiles=store.resourceFiles().map { it.id }.toSet()
        repeat(2) { assertEquals(selection.descriptor.byteCount,originals!!.withOriginal(selection.key,message=viewerLocation) { _,file -> file.length() }) }
        assertEquals(2,originalAuthorizations);assertEquals(existingFiles,store.resourceFiles().map { it.id }.toSet())
        phase="decode the original within its message-bound file lease for the viewer"
        originals!!.withAuthorizedOriginal(selection.key,message=viewerLocation) { authorized,file ->
            val prepared=MessageImagePreparation().prepare(file)
            assertEquals(viewerLocation.message,authorized.evidence.source.message);assertTrue(authorized.deadlineNanos>System.nanoTime())
            assertTrue(prepared.dimensions.width in 1..2048 && prepared.dimensions.height in 1..2048);assertTrue(prepared.byteCount<=20*1024*1024)
        }
        val originalAuthorizationCount=originalAuthorizations
        phase="retain the authorized derived version before downloading and preserve it through cache clearing"
        retainedVariant=firstPreview.variant.key
        files.setResourceRetained(retainedVariant!!,true)
        val diskPreview=targetClient.resolve(selection.key.media,MediaMessageLocation(room,selection.source.message),MediaImagePreviewSize.Thumbnail)
        assertEquals(firstPreview.encoded,files.withDownloaded(diskPreview,false) { it.inputStream().use(com.google.protobuf.ByteString::readFrom) })
        files.clearDownloadCache()
        assertTrue(files.resourceVariants(selection.key).any {it.descriptor==firstPreview.variant && it.retained && it.availableLocally})
        assertEquals(firstPreview.encoded,files.withDownloaded(targetClient.resolve(selection.key.media,MediaMessageLocation(room,selection.source.message),MediaImagePreviewSize.Thumbnail),true) { it.inputStream().use(com.google.protobuf.ByteString::readFrom) })
        assertTrue(store.resourceFiles().any { it.kind==ResourceFileKind.Cache && it.state==ResourceFileState.Published && it.retained })
        val profiles=OwnProfileClient(api,credentials.userId);val own=OwnProfileService(credentials.userId,profiles,store)
        val intents=ProfileIntentService(credentials.userId,own,store);val original=intents.refresh()
        val intent=selector.submit(original,selection);val imported=intent.serverImport!!
        assertEquals(selection.importSource,imported.request.source);assertEquals(1L,selection.source.revision)
        assertTrue(store.ownProfileWorks().none { it.command.operation==intent.operation })
        phase="lost message-source import reply recovers the exact consumer-owned target"
        val raw=ResourceImportClient(api,credentials.userId);var creates=0
        val lossy=object: ResourceImportControl by raw {
            override suspend fun create(request: ResourceImportRequest): ResourceImportStatus {
                creates++;raw.create(request);throw IOException("simulated lost selected image import reply")
            }
        }
        suspend fun run(control: ResourceImportControl,predicate: (ResourceImportWork)->Boolean)=coroutineScope {
            val job=launch { ResourceImportService(credentials.userId,store,control).runForeground() }
            try { withTimeout(30000) { while(true) {
                val value=store.resourceImports().first { it.id==imported.id }
                assertFalse("message image import issue=${value.execution.issue}",value.execution.attention)
                if(predicate(value)) break
                delay(50)
            } } } finally { job.cancelAndJoin() }
        }
        run(lossy) { it.execution.attempts==1 && it.execution.owner==null };assertEquals(1,creates)
        val recoverOnly=object: ResourceImportControl by raw { override suspend fun create(request: ResourceImportRequest): ResourceImportStatus=error("must recover the original message-source target") }
        run(recoverOnly) { it.terminal }
        assertTrue(store.resourceImports().first { it.id==imported.id }.bindable(System.currentTimeMillis()))
        phase="withdraw original message after copy and bind the independent avatar target"
        val withdrawal=MessageMutationCommand(credentials.userId,room,selection.source.message,id(),1,null,System.currentTimeMillis()+595000)
        assertEquals(MutationStatus.Committed,(MessageMutationClient(api).execute(withdrawal,false,false) as MutationResult.Receipt).status)
        withTimeout(15000) { while(selector.isCurrent(selection)) { RoomSyncEngine(realtime,store).synchronize();delay(50) } }
        assertTrue(runCatching { previews!!.read(selection.key) }.isFailure)
        assertEquals(previewAuthorizationCount,authorizations);assertEquals(previewDownloadCount,downloads)
        assertTrue(runCatching { originals!!.withOriginal(selection.key,true,message=viewerLocation) { _,_->error("withdrawn source") } }.isFailure);assertEquals(originalAuthorizationCount,originalAuthorizations)
        assertTrue(files.resourceVariants(selection.key).isEmpty())
        files.clearDownloadCache()
        assertTrue(store.resourceFiles().any {it.retained && it.checksum==firstPreview.variant.checksum})
        val denied=runCatching { targetClient.resolve(selection.key.media,MediaMessageLocation(room,selection.source.message),MediaImagePreviewSize.Thumbnail) }.exceptionOrNull()
        assertTrue(denied is MediaReadFailure && denied.reason==MediaReadFailureReason.Denied)
        files.setResourceRetained(retainedVariant!!,false);retainedVariant=null
        files.clearDownloadCache()
        assertFalse(store.resourceFiles().any {it.kind==ResourceFileKind.Cache && it.checksum==firstPreview.variant.checksum})
        assertTrue(intents.prepareNext());own.flush()
        assertEquals(ProfileIntentPhase.Committed,store.profileIntents().first { it.intent.id==intent.id }.phase)
        assertEquals(imported.request.targetMedia,profiles.current().avatarMediaId)
        assertTrue(store.resourceImports().first { it.id==imported.id }.businessBound)
        phase="read avatar pixels under a fresh profile authorization and restore original profile"
        val key=ProfileKey(credentials.userId,ProfileContext.Relationship)
        val reader=ProfilePresentationClient(api,credentials.userId,credentials.deviceId)
        val scope=ProfilePresentationScope(credentials.userId,credentials.deviceId,reader::read)
        val cache=AvatarCache(credentials.userId,credentials.deviceId,AvatarDownloader(http)::download)
        try {
            scope.interests(persistentListOf(key));scope.refresh();val grant=requireNotNull(scope.avatarReadGrant(key))
            assertEquals(imported.request.targetMedia,grant.content.media)
            val photo=PhotoPreparation().prepare(cache.read(grant).read());assertTrue(photo.dimensions.width>0 && photo.dimensions.height>0)
        } finally { scope.close();cache.close() }
        val restored=intents.enqueue(intents.refresh(),avatar=original.avatarMediaId?.let { ProfileAvatarPatch.Set(it) } ?: ProfileAvatarPatch.Remove)
        intents.prepareNext();own.flush();assertEquals(ProfileIntentPhase.Committed,store.profileIntents().first { it.intent.id==restored.id }.phase)
        assertEquals(original.avatarMediaId,profiles.current().avatarMediaId)
    } catch(error: Throwable) { throw AssertionError("Selected avatar resource failed during $phase",error) }
    finally { originals?.close();previews?.close();retainedVariant?.let {files.setResourceRetained(it,false)};files.clearDownloadCache() }
}
