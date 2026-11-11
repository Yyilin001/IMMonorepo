package com.xmtx.im.platform

import android.content.Context
import android.graphics.Bitmap
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import java.util.UUID

/** Real room-home upload, logical command receipts and independent presentation authorization. */
internal suspend fun verifyGroupAvatarBackend(context: Context,a: Credentials,b: Credentials,room: RoomId,
    api: AuthenticatedTransport,peerApi: AuthenticatedTransport,http: OkHttpClient,store: SqliteClientStore,socket: RealtimeConnection)=coroutineScope {
    fun id()=UUID.randomUUID().toString().uppercase()
    val commands=GroupAvatarCommandClient(api,a.userId,a.deviceId)
    val reader=GroupAvatarPresentationClient(api,a.userId,a.deviceId)
    val peerReader=GroupAvatarPresentationClient(peerApi,b.userId,b.deviceId)
    val initial=reader.read(room);assertEquals(0L,initial.state.revision);assertTrue(initial.canManage);assertNull(initial.avatar)
    assertFalse(peerReader.read(room).canManage)
    val resources=AccountResourceActivity(context,store,ResourceUploadClient(api,a.userId)) { ManagedResourceUploadBytes(it,ResourcePlanUploader(http)) }
    val repository=GroupAvatarRepository(a.userId,a.deviceId,reader,store::groupAvatarFence,this)
    val cache=AvatarCache(a.userId,a.deviceId,AvatarDownloader(http)::download)
    var localNow=System.currentTimeMillis()
    val intents=GroupAvatarIntentService(a.userId,a.deviceId,commands,reader,store) { localNow }
    suspend fun transfer(id: String) {
        val job=launch { resources.runForeground() }
        try { withTimeout(30000) { while(!store.resourceUploads().first { it.id==id }.terminal) {
            assertFalse(store.resourceUploads().first { it.id==id }.execution.attention);delay(100)
        } } } finally { job.cancelAndJoin() }
        assertEquals(ResourceUploadStage.Ready,store.resourceUploads().first { it.id==id }.stage)
    }
    var phase="group-owned image preparation"
    try {
        val bitmap=Bitmap.createBitmap(80,80,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
        try { bitmap.eraseColor(android.graphics.Color.MAGENTA);assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,bytes)) } finally { bitmap.recycle() }
        val photo=PhotoPreparation().prepare(bytes.toByteString())
        val asset=resources.files.importPhoto(photo,ResourceUsage.GroupAvatar(room))
        val intent=intents.enqueue(intents.refresh(room),asset)
        val upload=store.resourceUploads().first { it.id==intent.upload }.request
        transfer(requireNotNull(intent.upload))
        val ready=store.resourceUploads().first { it.id==intent.upload }
        assertEquals(ResourceHome.Room(room),ready.session!!.locator.home)
        phase="durable lost reply recovers original command after SQLite reopen"
        val set=intent.command
        val lossy=object: GroupAvatarCommands by commands {
            override suspend fun submit(command: GroupAvatarCommand): GroupAvatarCommandResponse {
                commands.submit(command);throw java.io.IOException("simulated lost group avatar reply")
            }
        }
        GroupAvatarIntentService(a.userId,a.deviceId,lossy,reader,store) { localNow }.recoverOnce()
        val uncertain=store.groupAvatarIntents().first { it.id==intent.id }
        assertEquals(GroupAvatarRecoveryAction.Query,uncertain.action);assertFalse(uncertain.sourceReleased)
        // A fresh SQLite connection reads the committed journal; it does not receive an in-memory intent.
        val reopened=SqliteClientStore(context,a.userId,a.deviceId)
        try {
            assertEquals(uncertain,reopened.groupAvatarIntents().first { it.id==intent.id })
            localNow=maxOf(System.currentTimeMillis(),uncertain.retryAt)
            GroupAvatarIntentService(a.userId,a.deviceId,commands,reader,reopened) { localNow }.recoverOnce()
        } finally { reopened.close() }
        val committed=store.groupAvatarIntents().first { it.id==intent.id }
        assertEquals(GroupAvatarStage.Committed,committed.stage);assertTrue(committed.sourceReleased)
        val receipt=requireNotNull(committed.receipt)
        assertEquals(upload.media,receipt.state.media);assertEquals(1L,receipt.state.revision)
        assertEquals(receipt,(commands.submit(set).outcome as GroupAvatarOutcome.Committed).change)
        resources.files.cleanup();assertTrue(store.resourceFiles().none { it.id==asset.file })
        phase="viewer-bound presentation and permission rejection"
        val shown=reader.read(room);assertEquals(receipt.state,shown.state);assertTrue(shown.resourceGeneration!!>0)
        assertEquals(upload.media,shown.avatar!!.content.media);assertTrue(shown.valid());assertNotNull(shown.avatar!!.plan)
        phase="durable room invalidation and authorized group pixels"
        backendSync { RoomSyncEngine(socket,store).synchronize() }
        assertEquals(1L,store.groupAvatarFence(room).revision)
        val token=repository.activate(room);repository.read(token)
        val grant=requireNotNull(repository.avatarReadGrant(token));assertEquals(ResourceHome.Room(room),grant.home)
        val pixels=cache.read(grant);assertTrue(PhotoPreparation().prepare(pixels.read()).dimensions.width>0)
        val peerShown=peerReader.read(room);assertEquals(shown.state,peerShown.state);assertEquals(b.userId,peerShown.actor)
        val forbidden=GroupAvatarCommandClient(peerApi,b.userId,b.deviceId).submit(GroupAvatarCommand(id(),room,1,GroupAvatarMutation.Remove))
        assertEquals(GroupAvatarOutcome.Forbidden,forbidden.outcome)
        phase="revision conflict remains unresolved until explicit closure"
        val stale=GroupAvatarCommand(id(),room,0,GroupAvatarMutation.Remove)
        assertEquals(GroupAvatarOutcome.RevisionConflict,commands.submit(stale).outcome)
        assertEquals(GroupAvatarRecoveryResult.Unresolved,commands.recover(GroupAvatarRecoveryRequest(stale,GroupAvatarRecoveryAction.Query)).result)
        assertEquals(GroupAvatarRecoveryResult.Closed,commands.recover(GroupAvatarRecoveryRequest(stale,GroupAvatarRecoveryAction.CloseIfAbsent)).result)
        val late=runCatching { commands.submit(stale) }.exceptionOrNull();assertTrue(late is ClientFailure.Http && late.status==410)
        phase="conflicting durable image intent closes then transfers source to fresh replacement"
        val replacementSource=resources.files.importPhoto(photo,ResourceUsage.GroupAvatar(room))
        val conflicting=intents.enqueue(intents.refresh(room),replacementSource)
        transfer(requireNotNull(conflicting.upload))
        val intervening=commands.submit(GroupAvatarCommand(id(),room,1,GroupAvatarMutation.Remove))
        assertEquals(2L,(intervening.outcome as GroupAvatarOutcome.Committed).change.state.revision)
        intents.recoverOnce();intents.recoverOnce()
        val closed=store.groupAvatarIntents().first { it.id==conflicting.id }
        assertEquals(GroupAvatarStage.Closed,closed.stage);assertNotNull(closed.proof);assertFalse(closed.sourceReleased)
        val replacement=intents.replace(conflicting.id,intents.refresh(room))
        assertNotEquals(conflicting.upload,replacement.upload);assertNotEquals(conflicting.command.mutation.mediaId,replacement.command.mutation.mediaId)
        assertEquals(replacementSource.id,replacement.asset)
        assertEquals(GroupAvatarDisposition.Replaced,store.groupAvatarIntents().first { it.id==conflicting.id }.disposition)
        transfer(requireNotNull(replacement.upload));intents.recoverOnce()
        val replaced=store.groupAvatarIntents().first { it.id==replacement.id }
        assertEquals(GroupAvatarStage.Committed,replaced.stage);assertEquals(3L,replaced.receipt!!.state.revision)
        resources.files.cleanup();assertTrue(store.resourceFiles().none { it.id==replacementSource.file })
        phase="durable remove advances revision while original receipt remains stable"
        val remove=intents.enqueue(intents.refresh(room));intents.recoverOnce()
        val removed=requireNotNull(store.groupAvatarIntents().first { it.id==remove.id }.receipt)
        assertEquals(4L,removed.state.revision);assertNull(removed.state.media)
        val empty=reader.read(room);assertEquals(removed.state,empty.state);assertNull(empty.avatar);assertNull(empty.resourceGeneration)
        backendSync { RoomSyncEngine(socket,store).synchronize() }
        assertEquals(4L,store.groupAvatarFence(room).revision)
        assertTrue(runCatching { pixels.read() }.exceptionOrNull() is AvatarAccessFailure)
        repository.read(token);assertNull(repository.avatarReadGrant(token))
        assertEquals(receipt,(commands.recover(GroupAvatarRecoveryRequest(set,GroupAvatarRecoveryAction.CloseIfAbsent)).result as GroupAvatarRecoveryResult.Committed).change)
        resources.files.cleanup()
    } catch(error: Throwable) { throw AssertionError("Group avatar failed during $phase",error) }
    finally { repository.close();cache.close();resources.close() }
}
