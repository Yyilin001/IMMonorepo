package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ProfilePageSnapshot(val generation: String = "",val display: ProfilePresentationSnapshot = ProfilePresentationSnapshot())
internal data class ProfileAuthorDemand(val keys: PersistentList<ProfileKey> = persistentListOf(),val revision: Long=0,val closed: Boolean=false)

/** Lifecycle owner calls update/close on its UI dispatcher. Network, renewal and expiry live outside Compose. */
class ProfilePresentationPage(actor: UserId,device: DeviceId,reader: ProfilePresentationReading,
    private val fences: suspend (PersistentList<ProfileKey>) -> ProfileFenceSnapshot,parent: CoroutineScope,
    private val nanoTime: () -> Long = System::nanoTime,private val onClose: (ProfilePresentationPage) -> Unit = {},
    private val avatarReader: (suspend (AvatarReadGrant)->AvatarDownloadedBytes)?=null,
    private val localDisplays: LocalProfileDisplaySaving? = null,
    localDisplayReader: LocalProfileDisplayReading? = null,
    localDisplayChanges: Flow<Long> = emptyFlow()) : AutoCloseable {
    private val work = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + work)
    private val presentations = ProfilePresentationScope(actor,device,reader,nanoTime)
    private val mutable = MutableStateFlow(ProfilePageSnapshot())
    val state = mutable.asStateFlow()
    private var keys = persistentListOf<ProfileKey>()
    private var generation = ""
    private var request: Job? = null
    private var expiry: Job? = null
    private var epoch = 0L
    private var closed = false
    private var avatarKeys=persistentListOf<ProfileKey>()
    private var images=persistentMapOf<ProfileKey,AvatarPresentationBytes>()
    private val avatarJobs=mutableMapOf<ProfileKey,Job>()
    private val avatarJobContents=mutableMapOf<ProfileKey,AvatarContent>()
    private val avatarRenewals=mutableMapOf<ProfileKey,Int>()
    private val wake=Channel<Unit>(Channel.CONFLATED)
    private val authorMutable=MutableStateFlow(ProfileAuthorDemand())
    internal val authorDemand=authorMutable.asStateFlow()
    private var authorBinding: ProfileAuthorBinding?=null
    private val journalWrites = Mutex()
    private var journaledProfiles = persistentMapOf<ProfileKey, ProfileReadResult.Available>()
    private var journaledDenials = persistentSetOf<ProfileKey>()
    private var localNames: PersistentMap<ProfileKey, LocalProfileDisplaySnapshot.Value>? =
        if (localDisplayReader == null) null else persistentMapOf()
    private val localText = localDisplayReader?.let { reader ->
        LocalProfilePage(actor, scope, reader, fences, localDisplayChanges) { names ->
            if (!closed) { localNames = names; publish(ProfilePageSnapshot(generation, presentations.snapshot())) }
        }
    }
    private fun publish(incoming: ProfilePageSnapshot) {
        // Expiry/viewport callbacks can run while journal I/O suspends. They must not expose a
        // newly accepted author/HTTP result before that result's transaction has completed.
        val snapshot = if (localDisplays == null) incoming else incoming.copy(display = incoming.display.copy(
            profiles = incoming.display.profiles.filter { (key, value) -> journaledProfiles[key] == value }.toPersistentMap(),
            unavailable = incoming.display.unavailable.filter { it in journaledDenials }.toPersistentSet()))
        images=images.filter { (key,image) -> key in avatarKeys && image.valid(nanoTime()) && snapshot.display.profiles[key]?.let { it.valid(nanoTime()) && it.avatar?.content==image.content }==true }.toPersistentMap()
        expiry?.cancel();mutable.value = snapshot.copy(display=snapshot.display.copy(avatars=images,localNames=localNames))
        val now = nanoTime()
        val remaining = (snapshot.display.profiles.values.map { it.deadlineNanos-now }+images.values.map { it.deadlineNanos-now }+listOfNotNull(presentations.nextScheduledDeadline()?.minus(now))).minOrNull() ?: return
        val nonce = epoch
        expiry = scope.launch {
            delay((remaining.coerceAtLeast(0) + 999_999)/1_000_000)
            if(!closed && epoch == nonce) {
                publish(ProfilePageSnapshot(generation,presentations.snapshot()))
                loadAvatars()
                wake.trySend(Unit)
            }
        }
    }
    fun observeGeneration(generation: String) { update(keys,generation,avatarKeys) }
    suspend fun avatarReadGrant(key: ProfileKey): AvatarReadGrant? {
        if(closed || key !in keys) return null
        val capturedEpoch=epoch;val capturedGeneration=generation;val requested=keys
        val authority=fences(requested)
        if(closed || epoch!=capturedEpoch || authority.generation!=capturedGeneration) return null
        return presentations.avatarReadGrant(key) {
            !closed && epoch==capturedEpoch && fences(requested)==authority && !closed && epoch==capturedEpoch
        }?.also { it.requireValid() }
    }
    fun update(interests: PersistentList<ProfileKey>,generation: String,avatarInterests: PersistentList<ProfileKey> = persistentListOf()) {
        if(closed || interests == keys && generation == this.generation && avatarInterests==avatarKeys) return
        require(interests.size <= 128 && interests.toSet().size == interests.size)
        require(avatarInterests.distinct().size==avatarInterests.size && avatarInterests.all { it in interests })
        val authorityChanged=generation!=this.generation
        avatarJobs.values.toList().forEach { it.cancel() };avatarJobs.clear();avatarJobContents.clear();avatarRenewals.clear();images=persistentMapOf();avatarKeys=avatarInterests
        keys = interests;this.generation = generation;val nonce = ++epoch
        request?.cancel();presentations.interests(interests)
        if(authorityChanged) {
            authorBinding?.let {presentations.unbindAuthor(it)};authorBinding=null;presentations.invalidateAll()
        }
        localText?.update(interests, generation)
        authorMutable.value=ProfileAuthorDemand(interests,authorMutable.value.revision+if(authorityChanged) 1 else 0)
        publish(ProfilePageSnapshot(generation,presentations.snapshot()))
        if(interests.isEmpty()) return
        request = scope.launch {
            delay(40) // Coalesce viewport/layout changes before admitting a bounded read.
            while(isActive && !closed && nonce == epoch) {
                try {
                    delay(presentations.nextReadDelayMillis())
                    val before = fences(interests)
                    if(before.generation != generation) return@launch // Await the matching published local snapshot.
                    if(applyFences(before) && authorBinding!=null) retireAuthorForAuthority()
                    val promoted=presentations.promoteAuthor()
                    if(promoted.isNotEmpty()) {
                        if (!saveLocalDisplays(before, nonce)) return@launch
                        publish(ProfilePageSnapshot(generation,presentations.snapshot()));loadAvatars()
                    }
                    presentations.refresh(excluding=promoted) { !closed && nonce==epoch && fences(interests)==before }
                    val after = fences(interests)
                    ensureActive()
                    if(closed || nonce != epoch) return@launch
                    if(before != after) { presentations.invalidateAll();retireAuthorForAuthority();publish(ProfilePageSnapshot(generation));return@launch }
                    if (!saveLocalDisplays(after, nonce)) return@launch
                    val result=presentations.snapshot()
                    publish(ProfilePageSnapshot(generation,result))
                    loadAvatars()
                    val remaining = result.profiles.values.minOfOrNull { it.deadlineNanos - nanoTime() }
                    val scheduled=presentations.nextScheduledDeadline()?.let {((it-nanoTime()).coerceAtLeast(0)+999_999)/1_000_000}
                    val pause=if(remaining == null) 30_000 else ((remaining.coerceAtLeast(0) + 999_999)/1_000_000).coerceAtLeast(1)
                    withTimeoutOrNull(minOf(pause,scheduled ?: Long.MAX_VALUE).coerceAtLeast(1)) { wake.receive() }
                    ensureActive()
                    publish(ProfilePageSnapshot(generation,presentations.snapshot()))
                } catch(error: CancellationException) { throw error }
                catch(error: Exception) {
                    if(closed || nonce!=epoch) return@launch
                    if(error is ClientFailure.SignedOut || error is ClientFailure.Http && error.status in setOf(401,403)) {
                        presentations.invalidateAll()
                        authorBinding?.let {presentations.unbindAuthor(it)};authorBinding=null
                        authorMutable.value=authorMutable.value.copy(revision=authorMutable.value.revision+1)
                        publish(ProfilePageSnapshot(generation));return@launch
                    }
                    publish(ProfilePageSnapshot(generation,presentations.snapshot()))
                    val pause = (error as? ClientFailure.Http)?.retryAfter?.let { retryAfterMilliseconds(it,System.currentTimeMillis()) } ?: 5_000
                    delay(maxOf(5_000,pause))
                }
            }
        }
    }
    private fun applyFences(value: ProfileFenceSnapshot): Boolean {
        var changed=false;value.floors.forEach {(key,floor)->if(presentations.fence(key,floor)) changed=true};return changed
    }
    private suspend fun saveLocalDisplays(expected: ProfileFenceSnapshot, nonce: Long): Boolean = journalWrites.withLock {
        val journal = localDisplays ?: return@withLock true
        if (closed || nonce != epoch) return@withLock false
        val results = presentations.localDisplayResults().filter { it.key in expected.floors }.toPersistentList()
        try {
            val accepted = results.isEmpty() || journal.save(results, expected)
            currentCoroutineContext().ensureActive()
            if (closed || nonce != epoch) return@withLock false
            if (!accepted) {
                presentations.invalidateAll(); retireAuthorForAuthority(); publish(ProfilePageSnapshot(generation))
            } else for (result in results) when (result) {
                is ProfileReadResult.Available -> { journaledProfiles = journaledProfiles.put(result.key, result); journaledDenials = journaledDenials.remove(result.key) }
                is ProfileReadResult.Unavailable -> { journaledProfiles = journaledProfiles.remove(result.key); journaledDenials = journaledDenials.add(result.key) }
                is ProfileReadResult.Retryable -> Unit
            }
            journaledProfiles = journaledProfiles.filterKeys { it in keys }.toPersistentMap()
            journaledDenials = journaledDenials.filter { it in keys }.toPersistentSet()
            accepted
        } catch (error: Exception) {
            if (!closed && nonce == epoch) {
                presentations.invalidateAll(); retireAuthorForAuthority(); publish(ProfilePageSnapshot(generation))
            }
            throw error
        }
    }
    private fun retireAuthorForAuthority() {
        authorBinding?.view?.let(::unbindAuthor)
        authorMutable.value=authorMutable.value.copy(revision=authorMutable.value.revision+1)
    }
    internal suspend fun prepareAuthor(): Boolean {
        val nonce=epoch;val requested=keys;val current=fences(requested)
        if(closed || nonce!=epoch || current.generation!=generation) return false
        if(applyFences(current) && authorBinding!=null) retireAuthorForAuthority()
        return true
    }
    internal fun bindAuthor(view: AuthorPresentationView,pool: AuthorPresentationCandidates?=null) {
        check(!closed)
        authorBinding=if(pool==null) presentations.bindAuthor(view) else presentations.bindAuthor(view,pool)
    }
    internal fun unbindAuthor(view: AuthorPresentationView) {
        val binding=authorBinding?.takeIf {it.view==view} ?: return
        presentations.unbindAuthor(binding);authorBinding=null
        if(!closed) {publish(ProfilePageSnapshot(generation,presentations.snapshot()));loadAvatars();wake.trySend(Unit)}
    }
    internal suspend fun ingestAuthor(delta: ReceivedAuthorPresentationDelta) {
        val binding=authorBinding?.takeIf {it.view==delta.view} ?: return
        val nonce=epoch;val requested=delta.entries.map {it.key}.toPersistentList()
        val before=fences(requested)
        if(closed || nonce!=epoch || authorBinding!==binding || before.generation!=generation) return
        var changed=false
        before.floors.forEach {(key,floor)->if(presentations.candidateFence(key,floor)) changed=true}
        if(changed) {retireAuthorForAuthority();return}
        val after=fences(requested)
        currentCoroutineContext().ensureActive()
        if(closed || nonce!=epoch || authorBinding!==binding) return
        if(before!=after) {
            presentations.invalidateAll();unbindAuthor(delta.view)
            authorMutable.value=authorMutable.value.copy(revision=authorMutable.value.revision+1)
            return
        }
        presentations.ingestAuthor(delta,binding)
        if (!saveLocalDisplays(after, nonce)) return
        publish(ProfilePageSnapshot(generation,presentations.snapshot()));loadAvatars()
        if(delta.entries.any {it !is ReceivedAuthorPresentationEntry.Available}) wake.trySend(Unit)
    }
    internal fun retainedAuthor(delta: ReceivedAuthorPresentationDelta): PersistentMap<ProfileKey,Long> =
        authorBinding?.takeIf {!closed && it.view==delta.view}?.let {presentations.retainedAuthor(delta,it)} ?: persistentMapOf()
    /** Bounded visible bytes; names and avatar retry schedules remain independent. */
    private fun loadAvatars() {
        val reader=avatarReader ?: return
        if(closed) return
        val display=mutable.value.display;var budget=8L*1024*1024
        val wanted=avatarKeys.filter { key ->
            val content=display.profiles[key]?.takeIf { it.valid(nanoTime()) }?.avatar?.content
            if(content!=null && content.byteCount<=budget) { budget-=content.byteCount;true } else false
        }.take(32).toSet()
        avatarJobs.filterKeys { it !in wanted }.values.toList().forEach { it.cancel() }
        if(images.keys.any { it !in wanted }) { images=images.filterKeys { it in wanted }.toPersistentMap();publish(mutable.value) }
        for(key in wanted) {
            val current=display.profiles.getValue(key)
            if(avatarJobContents[key]!=current.avatar?.content) { avatarJobs.remove(key)?.cancel();avatarJobContents.remove(key) }
            if(images[key]?.let { it.valid(nanoTime()) && it.content==current.avatar?.content }==true || avatarJobs[key]?.isActive==true) continue
            val nonce=epoch
            val job=scope.launch(start=CoroutineStart.LAZY) {
                try {
                    repeat(3) { attempt ->
                        try {
                            val grant=avatarReadGrant(key) ?: return@launch
                            val bytes=reader(grant).read();grant.requireValid();ensureActive()
                            if(closed || nonce!=epoch || key !in avatarKeys) return@launch
                            images=images.put(key,AvatarPresentationBytes(grant.content,bytes,grant.deadlineNanos));avatarRenewals.remove(key)
                            publish(mutable.value);return@launch
                        } catch(error: CancellationException) { throw error }
                        catch(error: Exception) {
                            if(closed || nonce!=epoch) return@launch
                            val renew=error is AvatarTargetExpired || error is ClientFailure.Http && error.status in setOf(401,403,404)
                            if(renew) {
                                val count=avatarRenewals[key] ?: 0
                                if(count<3) {
                                    avatarRenewals[key]=count+1;delay(3000)
                                    if(!closed && nonce==epoch) {
                                        // A Main.immediate receiver may resume inside trySend; release this slot first.
                                        if(avatarJobs[key]===currentCoroutineContext().job) { avatarJobs.remove(key);avatarJobContents.remove(key) }
                                        wake.trySend(Unit)
                                    }
                                }
                                return@launch
                            }
                            if(error is AvatarAccessFailure || attempt==2) return@launch
                            val retry=(error as? ClientFailure.Http)?.retryAfter?.let { retryAfterMilliseconds(it,System.currentTimeMillis()) } ?: 3000
                            delay(maxOf(3000,retry))
                        }
                    }
                } finally { if(avatarJobs[key]===currentCoroutineContext().job) { avatarJobs.remove(key);avatarJobContents.remove(key) } }
            }
            avatarJobs[key]=job;avatarJobContents[key]=requireNotNull(current.avatar).content;job.start()
        }
    }
    override fun close() {
        if(closed) return
        closed = true;epoch++;authorBinding=null;authorMutable.value=ProfileAuthorDemand(closed=true);request?.cancel();expiry?.cancel();work.cancel();wake.close();avatarJobs.clear();avatarJobContents.clear();avatarRenewals.clear();images=persistentMapOf();avatarKeys=persistentListOf();presentations.close();keys = persistentListOf();mutable.value = ProfilePageSnapshot()
        localText?.close(); localNames = null
        journaledProfiles = persistentMapOf(); journaledDenials = persistentSetOf()
        onClose(this)
    }
}
