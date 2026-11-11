package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

internal class ProfileAuthorBinding(val view: AuthorPresentationView,val id: UUID = UUID.randomUUID()) { var sequence=0L }

data class ProfilePresentationSnapshot(val profiles: PersistentMap<ProfileKey,ProfileReadResult.Available> = persistentMapOf(),
    val unavailable: PersistentSet<ProfileKey> = persistentSetOf(),val retryable: PersistentSet<ProfileKey> = persistentSetOf(),
    val avatars: PersistentMap<ProfileKey,AvatarPresentationBytes> = persistentMapOf(),
    // Null preserves legacy readers. A loaded empty map is authoritative absence, not a live fallback.
    val localNames: PersistentMap<ProfileKey,LocalProfileDisplaySnapshot.Value>? = null)

/** One foreground page activation. Close on leaving/background/logout; construct a fresh scope on return.
 * Reads are bounded/serialized, cancellation is propagated, and invalidation fences non-cooperative replies.
 * Snapshot deadlines remain mandatory: a UI must discard its copy when the earliest deadline expires.
 * No presentation, denial, transfer plan or page activation is durable state.
 */
class ProfilePresentationScope(private val actor: UserId,private val device: DeviceId,private val reader: ProfilePresentationReading,
    private val nanoTime: () -> Long = System::nanoTime) : AutoCloseable {
    private data class Entry(val generation: UUID = UUID.randomUUID(),val floor: ProfileRevisionFloor? = null,val denied: ProfileAuthority? = null,
        val minimumProfile: Long = 0,val minimumAlias: Long = 0,val minimumGroupName: Long = 0,val securityRevision: Long = 0,
        val authorOrigin: UUID? = null,val authorSequence: Long? = null,val authorNotBefore: Long? = null,val denialUntil: Long? = null,val retryUntil: Long? = null)
    private val lock = Any()
    private val reads = Mutex()
    private var closed = false
    private val activatedAt = nanoTime()
    private var authorBinding: ProfileAuthorBinding? = null
    private var lastAuthorView: AuthorPresentationView? = null
    private var candidates=AuthorPresentationCandidates(nanoTime)
    private var authorFloor: Long?=null
    private var entries = persistentMapOf<ProfileKey,Entry>()
    private var interests = persistentListOf<ProfileKey>()
    private var value = ProfilePresentationSnapshot()

    fun interests(keys: PersistentList<ProfileKey>) = synchronized(lock) {
        check(!closed);require(keys.size <= 128 && keys.toSet().size == keys.size)
        val removed=interests.filter {it !in keys}
        removed.forEach {key->entries[key]?.let {entries=entries.put(key,it.copy(generation=UUID.randomUUID(),authorOrigin=null,authorSequence=null))}}
        interests = keys
        keys.forEach {if(it !in entries) entries=entries.put(it,Entry())}
        trimEntries()
        value = value.copy(profiles = value.profiles.filterKeys { it in keys }.toPersistentMap(),
            unavailable = value.unavailable.filter { it in keys }.toPersistentSet(),retryable = value.retryable.filter { it in keys }.toPersistentSet())
        observeVersions()
    }

    /** The durable sync consumer may supply independently observed version floors. These do not grant access. */
    fun invalidate(key: ProfileKey,minimumProfile: Long = 0,minimumAlias: Long = 0,minimumGroupName: Long = 0) = synchronized(lock) {
        require(minimumProfile >= 0 && minimumAlias >= 0 && minimumGroupName >= 0)
        val old = entries[key] ?: return@synchronized
        authorBinding?.let {candidates.removeOwner(it.id,key)}
        entries = entries.put(key,old.copy(generation = UUID.randomUUID(),minimumProfile = maxOf(old.minimumProfile,minimumProfile),
            minimumAlias = maxOf(old.minimumAlias,minimumAlias),minimumGroupName = maxOf(old.minimumGroupName,minimumGroupName),
            authorOrigin = null,authorNotBefore = nanoTime(),denialUntil = null,retryUntil = null))
        value = value.copy(profiles = value.profiles.remove(key),unavailable = value.unavailable.remove(key),retryable = value.retryable.remove(key))
        observeVersions()
    }
    fun invalidateAll() = synchronized(lock) {
        authorFloor=nanoTime();authorBinding?.let {candidates.removeOwner(it.id)}
        entries.keys.toList().forEach { invalidate(it) }
    }
    /** Keep bounded revision/denial tombstones after a row leaves the viewport. */
    private fun trimEntries() {
        while(entries.size>2048) {
            val key=entries.keys.firstOrNull {it !in interests} ?: break
            entries=entries.remove(key);authorBinding?.let {candidates.removeOwner(it.id,key)};authorFloor=nanoTime()
        }
    }
    internal fun candidateFence(key: ProfileKey,floor: ProfileFence): Boolean = synchronized(lock) {
        val old=entries[key]
        if(old!=null) {
            if(key in interests || floor.securityRevision>old.securityRevision) return@synchronized fence(key,floor)
            val next=old.copy(minimumProfile=maxOf(old.minimumProfile,floor.minimumProfileRevision),minimumAlias=maxOf(old.minimumAlias,floor.aliasRevision),
                minimumGroupName=maxOf(old.minimumGroupName,floor.nicknameRevision))
            entries=entries.put(key,next)
            authorBinding?.let {binding->
                val staged=candidates.peek(key,binding.id)?.entry as? ReceivedAuthorPresentationEntry.Available
                if(staged!=null && !meetsFloor(staged.value.profile,next)) candidates.removeOwner(binding.id,key)
            }
            return@synchronized false
        }
        entries=entries.put(key,Entry(minimumProfile=floor.minimumProfileRevision,minimumAlias=floor.aliasRevision,
            minimumGroupName=floor.nicknameRevision,securityRevision=floor.securityRevision))
        trimEntries();false
    }
    fun fence(key: ProfileKey,floor: ProfileFence): Boolean = synchronized(lock) {
        val old = entries[key] ?: return@synchronized false
        if(old.minimumProfile>=floor.minimumProfileRevision && old.minimumAlias>=floor.aliasRevision && old.minimumGroupName>=floor.nicknameRevision && old.securityRevision>=floor.securityRevision) return@synchronized false
        invalidate(key,minimumProfile = floor.minimumProfileRevision,minimumAlias = floor.aliasRevision,minimumGroupName = floor.nicknameRevision)
        entries = entries.put(key,entries.getValue(key).copy(securityRevision = maxOf(old.securityRevision,floor.securityRevision)))
        true
    }

    fun snapshot(): ProfilePresentationSnapshot = synchronized(lock) {
        val expired = value.profiles.filterValues { !it.valid(nanoTime()) }.keys
        if(expired.isNotEmpty()) value = value.copy(profiles = value.profiles.filterKeys { it !in expired }.toPersistentMap(),retryable = value.retryable.addAll(expired))
        val deniedExpired = entries.filterValues { it.denialUntil?.let { until -> until-nanoTime()<=0 }==true }.keys
        if(deniedExpired.isNotEmpty()) {
            deniedExpired.forEach { key -> entries=entries.put(key,entries.getValue(key).copy(denialUntil=null)) }
            value=value.copy(unavailable=value.unavailable.removeAll(deniedExpired),retryable=value.retryable.addAll(deniedExpired.filter {it in interests}))
        }
        observeVersions();value
    }
    /** Optional additional validation belongs to the page's durable authority fences, never to a descriptor. */
    fun avatarReadGrant(key: ProfileKey,validate: suspend ()->Boolean={true}): AvatarReadGrant?=synchronized(lock) {
        if(closed) return@synchronized null
        val current=snapshot().profiles[key] ?: return@synchronized null
        val access=current.avatar ?: return@synchronized null
        val generation=entries[key]?.generation ?: return@synchronized null
        AvatarReadGrant(actor,device,access.content,ResourceHome.Account(key.user),current.deadlineNanos,access.plan,current.avatarDownloadDeadlineNanos,nanoTime) {
            fun live()=synchronized(lock) { !closed && entries[key]?.generation==generation && snapshot().profiles[key]?.let {
                it.profile.view.state==ProfileState.Active && it.avatar?.content==access.content
            }==true }
            live() && validate() && live()
        }
    }
    override fun close() = synchronized(lock) {
        authorBinding?.let {candidates.detach(it.id)}
        closed = true;authorBinding = null;lastAuthorView = null;interests = persistentListOf();entries = persistentMapOf();value = ProfilePresentationSnapshot()
    }

    /** A renewal preserves the exact issued deadline, but a retired nonce cannot bind a new activation. */
    internal fun bindAuthor(view: AuthorPresentationView,pool: AuthorPresentationCandidates=candidates): ProfileAuthorBinding = synchronized(lock) {
        check(!closed && view.startedNanos-activatedAt>=0 && view.renewByNanos-nanoTime()>0)
        authorBinding?.takeIf {it.view==view}?.let {return@synchronized it}
        check(lastAuthorView!=view)
        lastAuthorView?.let {check(view.startedNanos-it.startedNanos>0)}
        val next=ProfileAuthorBinding(view);val previous=authorBinding
        pool.inherit(candidates);previous?.let {candidates.detach(it.id)};candidates=pool
        if(previous!=null) entries=entries.mapValues {(_,entry)->if(entry.authorOrigin==previous.id) entry.copy(authorOrigin=next.id,authorSequence=null) else entry}.toPersistentMap()
        authorBinding=next;lastAuthorView=view;observeVersions();next
    }
    internal fun unbindAuthor(binding: ProfileAuthorBinding) = synchronized(lock) {
        if(authorBinding!==binding) return@synchronized
        candidates.detach(binding.id);authorBinding=null
        val retiring=entries.filterValues {it.authorOrigin==binding.id}.keys
        retiring.forEach {key->entries=entries.put(key,entries.getValue(key).copy(generation=UUID.randomUUID(),authorOrigin=null,authorSequence=null,denialUntil=null))}
        value=value.copy(profiles=value.profiles.filterKeys {it !in retiring}.toPersistentMap(),unavailable=value.unavailable.removeAll(retiring),retryable=value.retryable.addAll(retiring))
    }
    internal fun ingestAuthor(delta: ReceivedAuthorPresentationDelta,binding: ProfileAuthorBinding) = synchronized(lock) {
        check(!closed && authorBinding===binding && delta.view==binding.view && binding.view.renewByNanos-nanoTime()>0)
        require(delta.sequence>0 && delta.entries.size<=16 && delta.entries.map {it.key}.distinct().size==delta.entries.size)
        if(delta.sequence<=binding.sequence) return@synchronized
        val now=nanoTime()
        // Validate the complete frame before either applying entries or advancing its local sequence.
        delta.entries.forEach {entry->when(entry) {
            is ReceivedAuthorPresentationEntry.Available->{
                require(entry.value.profile.lease.actor==actor && entry.value.profile.lease.device==device)
                require(entry.value.deadlineNanos-now<=300_000_000_000L)
            }
            is ReceivedAuthorPresentationEntry.Unavailable->{
                require(entry.untilNanos-binding.view.renewByNanos<=0)
                val current=entries[entry.key]
                val staged=candidates.peekAny(entry.key)?.entry as? ReceivedAuthorPresentationEntry.Available
                val rooms=listOfNotNull(entry.value.authority.room,current?.floor?.authority?.room,current?.denied?.room,candidates.denial(entry.key)?.room,staged?.value?.profile?.lease?.authority?.room)+listOfNotNull(candidates.observed(entry.key)?.authority?.room)
                require(rooms.distinct().size<=1)
            }
            is ReceivedAuthorPresentationEntry.Retryable->require(entry.notBeforeNanos-now<=60_000_000_000L)
        }}
        val canUseView=authorViewAllowed(binding)
        val captured=entries.filter { (key,entry)->key in interests && canUseView && entry.authorNotBefore?.let {floor->binding.view.startedNanos-floor>0}!=false }.mapValues {it.value.generation}
        val accepted=delta.entries.filter {it.key in captured}
        val results=accepted.mapNotNull {entry->when(entry) {
            is ReceivedAuthorPresentationEntry.Available->entry.value.takeIf {it.valid(now)}
            is ReceivedAuthorPresentationEntry.Unavailable->entry.value.takeIf {entry.untilNanos-now>0}
            is ReceivedAuthorPresentationEntry.Retryable->ProfileReadResult.Retryable(entry.key).takeIf {entry.notBeforeNanos-now>0}
        }}.toPersistentList()
        applyResults(results,captured,binding.id,delta.sequence,
            accepted.filterIsInstance<ReceivedAuthorPresentationEntry.Unavailable>().associate {it.key to it.untilNanos},
            accepted.filterIsInstance<ReceivedAuthorPresentationEntry.Retryable>().associate {it.key to it.notBeforeNanos})
        for(entry in delta.entries) {
            if(entry.key in interests) candidates.removeOwner(binding.id,entry.key)
            else stageCandidate(entry,delta.sequence,binding)
        }
        binding.sequence=delta.sequence
    }
    private fun stageCandidate(entry: ReceivedAuthorPresentationEntry,sequence: Long,binding: ProfileAuthorBinding) {
        val key=entry.key;val current=entries[key] ?: Entry().also {entries=entries.put(key,it);trimEntries()}
        if(!authorViewAllowed(binding) || current.authorNotBefore?.let {binding.view.startedNanos-it<=0}==true) return
        val old=candidates.peekAny(key)?.entry as? ReceivedAuthorPresentationEntry.Available
        when(entry) {
            is ReceivedAuthorPresentationEntry.Available->{
                if(!entry.value.valid(nanoTime()) || !meetsFloor(entry.value.profile,current) || !acceptsAvatar(entry.value,current.floor?.avatar)) return
                old?.value?.let {prior->if(!meetsFloor(entry.value.profile,Entry(floor=profileFloor(prior))) || !acceptsAvatar(entry.value,prior.avatar?.content)) return}
                if(!entry.value.meetsObservedFloor(candidates.observed(key))) return
            }
            is ReceivedAuthorPresentationEntry.Unavailable->{
                if(entry.untilNanos-nanoTime()<=0) return
                val authorities=listOfNotNull(current.floor?.authority,old?.value?.profile?.lease?.authority)
                if(authorities.any {it.isAtLeast(entry.value.authority) && it!=entry.value.authority}) return
                if(!candidates.recordDenial(entry.value)) return
                var denied=entry.value.authority
                authorities.forEach {denied=denied.merged(it)};current.denied?.let {denied=denied.merged(it)};candidates.denial(key)?.let {denied=denied.merged(it)}
                candidates.recordDenial(ProfileReadResult.Unavailable(key,denied))
                entries=entries.put(key,current.copy(denied=denied,generation=UUID.randomUUID()))
            }
            is ReceivedAuthorPresentationEntry.Retryable->if(entry.notBeforeNanos-nanoTime()<=0) return
        }
        candidates.stage(binding.view,sequence,entry,binding.id)
    }
    private fun profileFloor(value: ProfileReadResult.Available)=value.profile.let {profile->
        ProfileRevisionFloor(profile.view.revision,profile.view.visibilityRevision,profile.lease.authority,profile.lease.observedAt,profile.alias,profile.groupName,value.avatar?.content)
    }
    private fun acceptsAvatar(value: ProfileReadResult.Available,prior: AvatarContent?): Boolean {
        val avatar=value.avatar?.content
        return avatar==null || prior==null || !avatar.sameVariant(prior) || avatar.version>prior.version || avatar==prior
    }
    private fun authorViewAllowed(binding: ProfileAuthorBinding)=listOfNotNull(authorFloor,candidates.fencedAt).all {binding.view.startedNanos-it>0}
    private fun observeVersions() {candidates.observe(value.profiles)}
    /** Only accepted, currently retained results; staged candidates and retry errors are excluded. */
    internal fun localDisplayResults(): PersistentList<ProfileReadResult> = synchronized(lock) {
        if (closed) return@synchronized persistentListOf()
        val current = snapshot()
        (current.profiles.values + current.unavailable.mapNotNull { key ->
            entries[key]?.denied?.let { ProfileReadResult.Unavailable(key, it) }
        }).toPersistentList()
    }
    /** Called only after the page validates durable fences for its new visible keys. Promotion is not a receipt. */
    internal fun promoteAuthor(): PersistentSet<ProfileKey> = synchronized(lock) {
        val binding=authorBinding ?: return@synchronized persistentSetOf()
        val now=nanoTime()
        if(closed || binding.view.renewByNanos-now<=0 || !authorViewAllowed(binding)) return@synchronized persistentSetOf()
        var promoted=persistentSetOf<ProfileKey>()
        for(key in interests) {
            val candidate=candidates.take(key,binding.id)?.takeIf {it.view==binding.view} ?: continue
            val current=entries[key] ?: continue
            if(current.authorNotBefore?.let {binding.view.startedNanos-it<=0}==true) continue
            val entry=candidate.entry
            val result=when(entry) {
                is ReceivedAuthorPresentationEntry.Available->entry.value.let {value->
                    if(value.avatarDownloadDeadlineNanos?.let {it-now<=0}==true) value.copy(avatar=value.avatar?.copy(plan=null),avatarDownloadDeadlineNanos=null) else value
                }
                is ReceivedAuthorPresentationEntry.Unavailable->entry.value
                is ReceivedAuthorPresentationEntry.Retryable->ProfileReadResult.Retryable(key)
            }
            applyResults(persistentListOf(result),mapOf(key to current.generation),binding.id,null,
                if(entry is ReceivedAuthorPresentationEntry.Unavailable) mapOf(key to entry.untilNanos) else emptyMap(),
                if(entry is ReceivedAuthorPresentationEntry.Retryable) mapOf(key to entry.notBeforeNanos) else emptyMap(),promoting=true)
            if(entries[key]?.authorOrigin==binding.id && (key in value.profiles || key in value.unavailable)) promoted=promoted.add(key)
        }
        promoted
    }
    /** Re-evaluate at receipt construction, after every potentially suspending page/fence lookup. */
    internal fun retainedAuthor(delta: ReceivedAuthorPresentationDelta,binding: ProfileAuthorBinding): PersistentMap<ProfileKey,Long> = synchronized(lock) {
        if(closed || authorBinding!==binding || delta.view!=binding.view || binding.view.renewByNanos-nanoTime()<=0) return@synchronized persistentMapOf()
        snapshot()
        delta.entries.mapNotNull {entry->
            val local=entries[entry.key]
            if(local?.authorOrigin!=binding.id || local.authorSequence!=delta.sequence) null else when(entry) {
                is ReceivedAuthorPresentationEntry.Available->value.profiles[entry.key]?.takeIf {it==entry.value && it.valid(nanoTime())}?.let {entry.key to it.deadlineNanos}
                is ReceivedAuthorPresentationEntry.Unavailable->local.denialUntil?.takeIf {entry.key in value.unavailable && it-nanoTime()>0}?.let {entry.key to if(it-entry.untilNanos<=0) it else entry.untilNanos}
                is ReceivedAuthorPresentationEntry.Retryable->null
            }
        }.toMap().toPersistentMap()
    }
    internal fun nextReadDelayMillis(): Long = synchronized(lock) {
        val now=nanoTime()
        interests.map {key->entries[key]?.let {maxOf((it.retryUntil?.minus(now) ?: 0).coerceAtLeast(0),(it.denialUntil?.minus(now) ?: 0).coerceAtLeast(0))} ?: 0}
            .minOrNull()?.coerceAtLeast(0)?.let {(it+999_999)/1_000_000} ?: 0
    }
    internal fun nextScheduledDeadline(): Long? = synchronized(lock) {
        entries.values.flatMap {listOfNotNull(it.denialUntil,it.retryUntil)}.filter {it-nanoTime()>0}.minByOrNull {it-nanoTime()}
    }

    /** At most 128 interests, split into <=100-key / <=8-authority batches. No implicit retry loop. */
    suspend fun refresh(excluding: PersistentSet<ProfileKey> = persistentSetOf(),validate: suspend ()->Boolean={true}): ProfilePresentationSnapshot = reads.withLock {
        var remaining = synchronized(lock) { check(!closed);interests.filter { key -> key !in excluding && entries[key]?.let { e -> (e.denialUntil?.minus(nanoTime()) ?: 0)<=0 && (e.retryUntil?.minus(nanoTime()) ?: 0)<=0 }==true }.toPersistentList() }
        while(remaining.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val selected = ProfileReadBatch.select(remaining)
            remaining = remaining.filter { it !in selected }.toPersistentList()
            val captured = synchronized(lock) {
                if(closed) return@withLock value
                selected.mapNotNull { key -> entries[key]?.let { key to it.generation } }.toMap()
            }
            val request = selected.filter { it in captured }.toPersistentList()
            if(request.isEmpty()) continue
            val received = try { reader.read(request) } catch(error: Exception) {
                if(error is ClientFailure.SignedOut) close()
                else if(error is ClientFailure.Http && error.status in setOf(401,403)) invalidateAll()
                throw error
            }
            currentCoroutineContext().ensureActive()
            require(received.size == request.size && received.map { it.key }.toSet() == request.toSet())
            // Validate the complete batch before publishing any part of it, including custom SDK readers.
            received.filterIsInstance<ProfileReadResult.Available>().forEach {
                require(it.profile.lease.actor == actor && it.profile.lease.device == device)
            }
            val authorized=validate()
            currentCoroutineContext().ensureActive()
            synchronized(lock) {
                if(closed) return@withLock value
                if(!authorized) {invalidateAll();return@withLock snapshot()}
                applyResults(received,captured)
            }
        }
        snapshot()
    }


    /** Caller holds lock; the entire batch is staged before any public state changes. */
    private fun applyResults(received: PersistentList<ProfileReadResult>,captured: Map<ProfileKey,UUID>,origin: UUID?=null,sequence: Long?=null,
        denials: Map<ProfileKey,Long> = emptyMap(),retries: Map<ProfileKey,Long> = emptyMap(),promoting: Boolean=false) {
        // Stage all changes, so a crossed-room version cannot leave a partially installed batch.
        received.filterIsInstance<ProfileReadResult.Unavailable>().forEach {result->
            val current=entries[result.key]
            val early=candidates.peekAny(result.key)?.entry as? ReceivedAuthorPresentationEntry.Available
            require(listOfNotNull(result.authority.room,current?.floor?.authority?.room,current?.denied?.room,
                candidates.observed(result.key)?.authority?.room,candidates.denial(result.key)?.room,early?.value?.profile?.lease?.authority?.room).distinct().size<=1)
        }
        var stagedEntries = entries;var stagedValue = value
        for(result in received) {
            val key = result.key;val current = entries[key] ?: continue
            if(captured[key] != current.generation) continue
            when(result) {
                is ProfileReadResult.Available -> {
                    val profile = result.profile
                    val avatar=result.avatar?.content
                    val prior=current.floor?.avatar
                    val acceptsAvatar=acceptsAvatar(result,prior)
                    val sharedFloor=result.meetsObservedFloor(candidates.observed(key))
                    if(result.valid(nanoTime()) && meetsFloor(profile,current) && acceptsAvatar && sharedFloor) {
                        candidates.restore(result)
                        val active = profile.view.state == ProfileState.Active
                        stagedEntries = stagedEntries.put(key,current.copy(generation=if(origin!=null && (!promoting || value.profiles[key]!=result)) UUID.randomUUID() else current.generation,authorOrigin=origin,authorSequence=sequence,denialUntil=null,retryUntil=null,denied = null,floor = ProfileRevisionFloor(profile.view.revision,profile.view.visibilityRevision,
                            profile.lease.authority,profile.lease.observedAt,if(active) profile.alias else current.floor?.alias,if(active) profile.groupName else current.floor?.groupName,avatar ?: prior)))
                        stagedValue = stagedValue.copy(profiles = stagedValue.profiles.put(key,result),unavailable = stagedValue.unavailable.remove(key),retryable = stagedValue.retryable.remove(key))
                    } else stagedValue = stagedValue.copy(retryable = stagedValue.retryable.add(key))
                }
                is ProfileReadResult.Unavailable -> {
                    val oldAuthority = current.floor?.authority
                    if(oldAuthority != null && oldAuthority.isAtLeast(result.authority) && oldAuthority != result.authority) continue
                    if(!candidates.recordDenial(result)) continue
                    var denial = result.authority
                    oldAuthority?.let { denial = denial.merged(it) };current.denied?.let { denial = denial.merged(it) };candidates.denial(key)?.let {denial=denial.merged(it)}
                    candidates.recordDenial(ProfileReadResult.Unavailable(key,denial))
                    stagedEntries = stagedEntries.put(key,current.copy(generation=if(origin!=null) UUID.randomUUID() else current.generation,authorOrigin=origin,authorSequence=sequence,denialUntil=denials[key],retryUntil=null,denied = denial))
                    stagedValue = stagedValue.copy(profiles = stagedValue.profiles.remove(key),unavailable = stagedValue.unavailable.add(key),retryable = stagedValue.retryable.remove(key))
                }
                is ProfileReadResult.Retryable -> {
                    retries[key]?.let { deadline -> stagedEntries=stagedEntries.put(key,current.copy(retryUntil=current.retryUntil?.takeIf {it-deadline>0} ?: deadline)) }
                    stagedValue = stagedValue.copy(retryable = stagedValue.retryable.add(key))
                }
            }
        }
        entries = stagedEntries;value = stagedValue;observeVersions()
    }

    private fun meetsFloor(profile: AuthorizedProfile,entry: Entry): Boolean {
        val authority = profile.lease.authority
        if(candidates.denial(profile.lease.key)?.let {!authority.isAtLeast(it) || authority==it}==true) return false
        if(entry.denied?.let { !authority.isAtLeast(it) || authority == it } == true) return false
        if(profile.view.revision < entry.minimumProfile) return false
        if(profile.view.state == ProfileState.Active && profile.view.revision <= entry.securityRevision) return false
        if(profile.view.state == ProfileState.Active && ((profile.alias?.revision ?: 0) < entry.minimumAlias || (profile.groupName?.revision ?: 0) < entry.minimumGroupName)) return false
        return profile.meetsRevisionFloor(entry.floor)
    }
}
