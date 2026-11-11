package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import java.util.UUID

/** The staged UUID is also the original upload and media identity, as in the Swift adapter. */
@Serializable data class ProfileAvatarUpload(val id: String,val asset: String,val displayName: String,val contentType: String,val byteCount: Long) {
    init {
        require(uuidId(id)==id && uuidId(asset)==asset && resourceDisplayName(displayName)==displayName)
        requireResourceContentType(contentType);require(contentType.startsWith("image/") && byteCount in 1..50L*1024*1024)
    }
}
@Serializable data class ProfileAvatarImport(val id: String,val request: ResourceImportRequest) {
    init { require(uuidId(id)==id && request.targetUsage==ResourceUsage.UserAvatar) }
}
@Serializable enum class ProfilePreparation { Pending, NeedsAttention, Failed, Expired, Cancelled }
@Serializable data class ProfileIntent(val id: String,val actor: UserId,val operation: String,val revision: Long,val deadline: Long,
    val name: String?=null,val avatar: ProfileAvatarPatch=ProfileAvatarPatch.Unchanged,val upload: ProfileAvatarUpload?=null,
    val frozen: Boolean=false,val preparation: ProfilePreparation=ProfilePreparation.Pending,val sourceReleased: Boolean=false,val serverImport: ProfileAvatarImport?=null) {
    init {
        require(uuidId(id)==id && uuidId(operation)==operation);uuidId(actor.value);require(revision>0 && deadline>0)
        name?.let { require(OwnProfilePatch.normalizedName(it)==it) }
        require(name!=null || avatar!=ProfileAvatarPatch.Unchanged || upload!=null || serverImport!=null)
        require(upload==null || avatar==ProfileAvatarPatch.Unchanged)
        require(serverImport==null || upload==null && avatar==ProfileAvatarPatch.Unchanged)
        require(!frozen || preparation==ProfilePreparation.Pending)
    }
    val locallyTerminal get()=preparation in setOf(ProfilePreparation.Failed,ProfilePreparation.Expired,ProfilePreparation.Cancelled)
    fun command(): OwnProfileCommand {
        check(frozen)
        return OwnProfileCommand(actor,operation,revision,OwnProfilePatch(name,upload?.let { ProfileAvatarPatch.Set(it.id) } ?: serverImport?.let { ProfileAvatarPatch.Set(it.request.targetMedia) } ?: avatar),deadline)
    }
}
enum class ProfileIntentPhase { WaitingToSubmit, PreparingAvatar, Confirming, Committed, NeedsAttention, Closed }
data class ProfileIntentStatus(val intent: ProfileIntent,val work: OwnProfileWork?,val phase: ProfileIntentPhase,val canReplace: Boolean) {
    val sourceRetained get()=!intent.sourceReleased
}
/** Typed original consumer; an upload's own source reference has an independent lifetime. */
data class ProfileOriginalConsumer(val intent: String): ResourceImportConsumer {
    init { require(uuidId(intent)==intent) }
    override val key get()="profileIntent/$intent"
}
interface ProfileIntentStore {
    val profileIntentChanges: StateFlow<Long>
    suspend fun profileIntents(): PersistentList<ProfileIntentStatus>
    suspend fun enqueueProfileIntent(intent: ProfileIntent,now: Long): ProfileIntent
    suspend fun advanceProfileIntents(now: Long): Boolean
    suspend fun profilePreparationDeadline(): Long?
    suspend fun resumeProfileIntent(id: String,now: Long): ProfileIntent?
    suspend fun replaceProfileIntent(id: String,newId: String,newOperation: String,newUpload: String,revision: Long,now: Long): ProfileIntent
    suspend fun discardProfileIntent(id: String)
}

/** Resource dependency preparation does not own network permits or a page's lifetime. */
class ProfileIntentService(private val actor: UserId,private val profiles: OwnProfileService,private val store: ProfileIntentStore,
    private val now: ()->Long=System::currentTimeMillis) {
    private val mutex=Mutex()
    suspend fun refresh()=profiles.refresh()
    suspend fun enqueue(baseline: ProfileView,name: String?=null,avatar: ProfileAvatarPatch=ProfileAvatarPatch.Unchanged,upload: ProfileAvatarUpload?=null)=mutex.withLock {
        require(baseline.user==actor && baseline.state==ProfileState.Active)
        val time=now()
        store.enqueueProfileIntent(ProfileIntent(id(),actor,id(),baseline.revision,Math.addExact(time,86400000),name,avatar,upload),time)
    }
    suspend fun enqueueImportedAvatar(baseline: ProfileView,source: ProfileAvatarImport,name: String?=null)=mutex.withLock {
        require(baseline.user==actor && baseline.state==ProfileState.Active)
        val time=now()
        store.enqueueProfileIntent(ProfileIntent(id(),actor,id(),baseline.revision,Math.addExact(time,86400000),name=name,serverImport=source),time)
    }
    suspend fun resumeOrReapply(id: String)=mutex.withLock {
        val original=store.profileIntents().first { it.intent.id==id };require(original.intent.actor==actor && original.sourceRetained)
        store.resumeProfileIntent(id,now())?.let { return@withLock it }
        val latest=refresh();require(latest.state==ProfileState.Active)
        store.replaceProfileIntent(id,id(),id(),id(),latest.revision,now())
    }
    suspend fun discard(id: String)=mutex.withLock { store.discardProfileIntent(id) }
    suspend fun prepareNext()=store.advanceProfileIntents(now())
    suspend fun runPreparation(): Unit=coroutineScope {
        val wake=Channel<Unit>(Channel.CONFLATED)
        val observer=launch { store.profileIntentChanges.collect { wake.trySend(Unit) } }
        try {
            while(isActive) {
                if(prepareNext()) continue
                val deadline=store.profilePreparationDeadline()
                if(deadline==null) wake.receive()
                else withTimeoutOrNull((deadline-now()).coerceIn(1,60000)) { wake.receive() }
            }
        } finally { observer.cancel();wake.close() }
    }
    private fun id()=UUID.randomUUID().toString().uppercase()
}
