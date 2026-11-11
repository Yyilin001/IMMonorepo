package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import java.io.IOException
import java.util.UUID

/** Real HTTPS + server-side object copy; fresh SQLite connection recovers a deliberately lost create reply. */
internal suspend fun verifyResourceImportBackend(context: Context,credentials: Credentials,api: AuthenticatedTransport,
    http: OkHttpClient,initial: SqliteClientStore): SqliteClientStore {
    var store=initial;var resources: AccountResourceActivity?=null;var success=false;var phase="authorized source"
    var lastFailure="none"
    val raw=ResourceImportClient(api,credentials.userId)
    suspend fun observed(action: String,body: suspend ()->ResourceImportStatus): ResourceImportStatus = try { body() } catch(error: Exception) {
        lastFailure=action+" "+(if(error is ClientFailure.Http) "HTTP "+error.status else error.javaClass.simpleName);throw error
    }
    val client=object: ResourceImportControl {
        override suspend fun create(request: ResourceImportRequest)=observed("create") { raw.create(request) }
        override suspend fun status(locator: ResourceImportLocator)=observed("status") { raw.status(locator) }
        override suspend fun cancel(locator: ResourceImportLocator)=observed("cancel") { raw.cancel(locator) }
    }
    val profiles=OwnProfileClient(api,credentials.userId)
    val reader=ProfilePresentationClient(api,credentials.userId,credentials.deviceId);val key=ProfileKey(credentials.userId,ProfileContext.Relationship)
    fun id()=UUID.randomUUID().toString().uppercase()
    suspend fun currentAvatar(): AvatarContent {
        val visible=reader.read(persistentListOf(key)).single() as ProfileReadResult.Available
        return requireNotNull(visible.avatar).content
    }
    suspend fun waitWork(work: String,predicate: (ResourceImportWork)->Boolean)=withTimeout(30000) {
        while(true) { val value=store.resourceImports().first { it.id==work };if(predicate(value)) break;assertFalse("$phase: state=${value.status?.state}, issue=${value.execution.issue}, calls=$lastFailure",value.execution.attention);delay(50) }
    }
    suspend fun foreground(control: ResourceImportControl,body: suspend ()->Unit)=coroutineScope {
        val owner=AccountResourceActivity(context,store,ResourceUploadClient(api,credentials.userId),imports=control) { ManagedResourceUploadBytes(it,ResourcePlanUploader(http)) }
        resources=owner;val job=launch { owner.runForeground() }
        try { body() } finally { job.cancelAndJoin();owner.close();resources=null }
    }
    try {
        val source=currentAvatar();val request=ResourceImportRequest(id(),ResourceImportSource.Avatar(key,source.media,source.variant),ResourceUsage.UserAvatar,id())
        val work=store.prepareResourceImport(id(),request,System.currentTimeMillis());var creates=0
        val lossy=object: ResourceImportControl by client {
            override suspend fun create(request: ResourceImportRequest): ResourceImportStatus { creates++;client.create(request);throw IOException("simulated lost resource import reply") }
        }
        phase="lost create reply"
        foreground(lossy) { waitWork(work.id) { it.execution.attempts==1 && it.execution.owner==null } }
        val unknown=store.resourceImports().first { it.id==work.id };assertNull(unknown.status);assertEquals(1,creates)
        phase="remove original source from current profile and reopen SQLite"
        val before=profiles.current();val removed=profiles.submit(OwnProfileCommand(credentials.userId,id(),before.revision,OwnProfilePatch(avatar=ProfileAvatarPatch.Remove),System.currentTimeMillis()+86400000))
        assertEquals(OwnProfileStatus.Committed,removed.status);assertNull(profiles.current().avatarMediaId)
        store.close();store=SqliteClientStore(context,credentials.userId,credentials.deviceId)
        val noCreate=object: ResourceImportControl by client { override suspend fun create(request: ResourceImportRequest): ResourceImportStatus=error("original successful import must recover without source access") }
        phase="recover original target after source is no longer current"
        foreground(noCreate) { waitWork(work.id) { it.terminal } }
        val ready=store.resourceImports().first { it.id==work.id };assertTrue(ready.bindable(System.currentTimeMillis()));assertEquals(request,ready.request)
        phase="durable profile consumer adopts recovered import and loses committed reply"
        var loseProfile=true
        val profileTransport=object: OwnProfileTransport by profiles {
            override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt {
                val result=profiles.submit(command);if(loseProfile) { loseProfile=false;throw IOException("simulated lost imported profile receipt") };return result
            }
        }
        var own=OwnProfileService(credentials.userId,profileTransport,store)
        val intents=ProfileIntentService(credentials.userId,own,store)
        val intent=intents.enqueueImportedAvatar(intents.refresh(),ProfileAvatarImport(work.id,request))
        assertTrue(intents.prepareNext());own.flush()
        val uncertain=store.ownProfileWorks().first { it.command.operation==intent.operation };assertTrue(uncertain.reconcile);assertFalse(uncertain.terminal)
        assertTrue(store.profileIntents().first { it.intent.id==intent.id }.sourceRetained)
        assertTrue(runCatching { store.cancelResourceImport(work.id) }.isFailure)
        store.close();store=SqliteClientStore(context,credentials.userId,credentials.deviceId)
        own=OwnProfileService(credentials.userId,profiles,store)
        phase="recover original profile receipt and protect consumed imported media"
        withTimeout(30000) { while(!store.ownProfileWorks().first { it.command.operation==intent.operation }.terminal) { own.flush();delay(50) } }
        val committed=store.profileIntents().first { it.intent.id==intent.id };assertEquals(ProfileIntentPhase.Committed,committed.phase);assertFalse(committed.sourceRetained)
        assertEquals(uncertain.command,store.ownProfileWorks().first { it.command.operation==intent.operation }.command)
        assertTrue(store.resourceImports().first { it.id==work.id }.businessBound);assertTrue(runCatching { store.cancelResourceImport(work.id) }.isFailure)
        assertEquals(request.targetMedia,profiles.current().avatarMediaId)
        phase="read fresh authorized bytes from durably bound import"
        val scope=ProfilePresentationScope(credentials.userId,credentials.deviceId,reader::read);val cache=AvatarCache(credentials.userId,credentials.deviceId,AvatarDownloader(http)::download)
        try {
            scope.interests(persistentListOf(key));scope.refresh();val grant=requireNotNull(scope.avatarReadGrant(key));assertEquals(request.targetMedia,grant.content.media)
            val image=PhotoPreparation().prepare(cache.read(grant).read());assertTrue(image.dimensions.width>0);assertTrue(image.dimensions.height>0)
        } finally { scope.close();cache.close() }
        phase="completed import cancellation conflict recovers authoritative terminal status"
        val nextSource=currentAvatar();val nextRequest=ResourceImportRequest(id(),ResourceImportSource.Avatar(key,nextSource.media,nextSource.variant),ResourceUsage.UserAvatar,id())
        val next=store.prepareResourceImport(id(),nextRequest,System.currentTimeMillis())
        foreground(client) { waitWork(next.id) { it.terminal };store.cancelResourceImport(next.id);waitWork(next.id) { it.cancellationResolved } }
        val cancelled=store.resourceImports().first { it.id==next.id };assertEquals(ResourceImportState.Ready,cancelled.status!!.state);assertTrue(cancelled.cancellationResolved);assertEquals("cancel HTTP 409",lastFailure);assertFalse(cancelled.bindable(System.currentTimeMillis()))
        assertEquals(ResourceImportState.Ready,client.status(nextRequest.locator(credentials.userId)).state)
        store.releaseResourceImport(next.id);success=true;return store
    } catch(error: Throwable) { throw AssertionError("Resource import failed during $phase",error) }
    finally { resources?.close();if(!success && store!==initial) store.close() }
}
