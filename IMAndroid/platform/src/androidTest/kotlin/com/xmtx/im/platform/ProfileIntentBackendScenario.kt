package com.xmtx.im.platform

import android.content.Context
import android.graphics.Bitmap
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList
import okhttp3.OkHttpClient
import org.junit.Assert.*
import java.util.UUID

internal suspend fun verifyProfileIntentBackend(context: Context,credentials: Credentials,api: AuthenticatedTransport,
    http: OkHttpClient,initial: SqliteClientStore,run: String): SqliteClientStore {
    val client=OwnProfileClient(api,credentials.userId);var store=initial;var phase="avatar preparation admission"
    var resources: AccountResourceActivity?=AccountResourceActivity(context,store,ResourceUploadClient(api,credentials.userId)) { ManagedResourceUploadBytes(it,ResourcePlanUploader(http)) }
    var files: ManagedResourceFiles?=null;var success=false;var drop=false
    fun id()=UUID.randomUUID().toString().uppercase()
    val lossy=object: OwnProfileTransport by client {
        override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt {
            val result=client.submit(command);if(drop) { drop=false;throw java.io.IOException("simulated lost avatar profile reply") };return result
        }
    }
    try {
        var own=OwnProfileService(credentials.userId,lossy,store)
        var intents=ProfileIntentService(credentials.userId,own,store)
        val original=intents.refresh();val pixels=Bitmap.createBitmap(80,80,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
        try { pixels.eraseColor(android.graphics.Color.GREEN);assertTrue(pixels.compress(Bitmap.CompressFormat.PNG,100,bytes)) } finally { pixels.recycle() }
        val prepared=PhotoPreparation().prepare(bytes.toByteString())
        val asset=resources!!.files.importPhoto(prepared,ResourceUsage.UserAvatar)
        val upload=ProfileAvatarUpload(id(),asset.id,asset.displayName,asset.contentType,asset.byteCount)
        val intent=intents.enqueue(original,upload=upload)
        assertTrue(store.ownProfileWorks().none { it.command.operation==intent.operation });assertTrue(store.resourceUploads().none { it.id==upload.id })
        intents.prepareNext()
        coroutineScope {
            val owner=resources!!;val transfer=launch { owner.runForeground() }
            try { withTimeout(30000) { while(store.resourceUploads().first { it.id==upload.id }.stage!=ResourceUploadStage.Ready) {
                assertFalse(store.resourceUploads().first { it.id==upload.id }.execution.attention);delay(100)
            } } } finally { transfer.cancelAndJoin() }
        }
        phase="original captured revision conflict and explicit ready source adoption"
        val changed=client.submit(OwnProfileCommand(credentials.userId,id(),original.revision,OwnProfilePatch("头像并发修改 $run"),System.currentTimeMillis()+86400000))
        assertEquals(OwnProfileStatus.Committed,changed.status);intents.refresh()
        intents.prepareNext();own.flush()
        assertEquals(ProfileIntentPhase.NeedsAttention,store.profileIntents().first { it.intent.id==intent.id }.phase)
        assertEquals(OwnProfileStatus.Conflicted,store.ownProfileWorks().first { it.command.operation==intent.operation }.status)
        val replacement=intents.resumeOrReapply(intent.id);assertEquals(upload,replacement.upload);assertNotEquals(intent.operation,replacement.operation)
        assertEquals(changed.revision,replacement.revision);resources!!.files.cleanup()
        resources!!.files.withOriginal(profile=ProfileOriginalConsumer(replacement.id)) { assertTrue(it.exists()) }
        intents.prepareNext();drop=true;own.flush()
        val uncertain=store.ownProfileWorks().first { it.command.operation==replacement.operation };assertTrue(uncertain.reconcile && uncertain.submissionStarted)
        assertFalse(uncertain.terminal);assertTrue(store.profileIntents().last().sourceRetained)
        assertEquals(upload.id,client.current().avatarMediaId)
        phase="database reopen recovers original profile receipt and releases retained source"
        resources!!.close();resources=null;store.close();store=SqliteClientStore(context,credentials.userId,credentials.deviceId)
        files=ManagedResourceFiles(context,store);own=OwnProfileService(credentials.userId,client,store);intents=ProfileIntentService(credentials.userId,own,store)
        assertEquals(uncertain.command,store.ownProfileWorks().first { it.command.operation==replacement.operation }.command)
        withTimeout(30000) { while(!store.ownProfileWorks().first { it.command.operation==replacement.operation }.terminal) { own.flush();delay(100) } }
        val committed=store.profileIntents().first { it.intent.id==replacement.id }
        assertEquals(ProfileIntentPhase.Committed,committed.phase);assertFalse(committed.sourceRetained)
        assertEquals(upload.id,store.ownProfile()!!.avatarMediaId);files!!.cleanup()
        assertTrue(store.resourceFiles().isEmpty())
        phase="authorized current avatar download and page revocation"
        val key=ProfileKey(credentials.userId,ProfileContext.Relationship)
        val presentationClient=ProfilePresentationClient(api,credentials.userId,credentials.deviceId);var withoutPlan=false
        val presentations=ProfilePresentationScope(credentials.userId,credentials.deviceId,{ keys -> presentationClient.read(keys).map { value ->
            if(withoutPlan && value is ProfileReadResult.Available) value.copy(avatar=value.avatar?.copy(plan=null),avatarDownloadDeadlineNanos=null) else value
        }.toPersistentList() })
        val cache=AvatarCache(credentials.userId,credentials.deviceId,AvatarDownloader(http)::download)
        try {
            presentations.interests(persistentListOf(key));presentations.refresh()
            val grant=requireNotNull(presentations.avatarReadGrant(key))
            assertEquals(upload.id,grant.content.media)
            val downloaded=cache.read(grant)
            val avatar=PhotoPreparation().prepare(downloaded.read())
            assertTrue(avatar.dimensions.width>0 && avatar.dimensions.height>0)
            withoutPlan=true;presentations.invalidate(key);presentations.refresh()
            val renewed=requireNotNull(presentations.avatarReadGrant(key))
            assertEquals(downloaded.content,renewed.content)
            val cached=cache.read(renewed);assertEquals(grant.content.byteCount,cached.read().size().toLong())
            cache.close();assertTrue(runCatching { cached.read() }.exceptionOrNull() is AvatarAccessFailure)
            presentations.close()
            assertTrue(runCatching { downloaded.read() }.exceptionOrNull() is AvatarAccessFailure)
        } finally { presentations.close();cache.close() }
        phase="server-side import recovery and imported avatar binding"
        files!!.close();files=null
        store=verifyResourceImportBackend(context,credentials,api,http,store)
        files=ManagedResourceFiles(context,store);own=OwnProfileService(credentials.userId,client,store);intents=ProfileIntentService(credentials.userId,own,store)
        phase="ordered restoration through the same durable preparation layer"
        val restored=intents.enqueue(intents.refresh(),name=original.identity!!.displayName,avatar=original.avatarMediaId?.let { ProfileAvatarPatch.Set(it) } ?: ProfileAvatarPatch.Remove)
        intents.prepareNext();own.flush();assertEquals(ProfileIntentPhase.Committed,store.profileIntents().first { it.intent.id==restored.id }.phase)
        val current=client.current();assertEquals(original.identity!!.displayName,current.identity!!.displayName);assertEquals(original.avatarMediaId,current.avatarMediaId)
        success=true;return store
    } catch(error: Throwable) { throw AssertionError("Profile intent failed during $phase",error) }
    finally { resources?.close();files?.close();if(!success && store!==initial) store.close() }
}
