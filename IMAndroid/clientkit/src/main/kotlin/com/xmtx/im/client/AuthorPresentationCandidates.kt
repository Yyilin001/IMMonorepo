package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

/** Account-local early delivery. Entries share immutable values; page ownership adds only a bounded token.
 * This is never a display grant, receipt, journal or download queue.
 */
internal class AuthorPresentationCandidates(private val nanoTime: ()->Long=System::nanoTime) {
    internal data class Candidate(val view: AuthorPresentationView,val sequence: Long,val entry: ReceivedAuthorPresentationEntry,
        val expires: Long,val owners: PersistentSet<UUID>,val valueBytes: Int) {val cost get()=valueBytes+owners.size*64}
    private val values=linkedMapOf<ProfileKey,Candidate>()
    private val observations=linkedMapOf<ProfileKey,ProfileRevisionFloor>()
    private val denials=linkedMapOf<ProfileKey,ProfileAuthority>()
    var fencedAt: Long?=null;private set
    private val deadline=MutableStateFlow<Long?>(null)
    val nextExpiry=deadline.asStateFlow()
    private var bytes=0
    @Synchronized fun peek(key: ProfileKey,owner: UUID): Candidate? {prune();return values[key]?.takeIf {owner in it.owners}}
    @Synchronized fun peekAny(key: ProfileKey): Candidate? {prune();return values[key]}
    @Synchronized fun observed(key: ProfileKey)=observations[key]
    @Synchronized fun denial(key: ProfileKey)=denials[key]
    @Synchronized fun observe(profiles: PersistentMap<ProfileKey,ProfileReadResult.Available>) {
        profiles.forEach {(key,value)->
            if(value.meetsObservedFloor(observations[key])) storeObservation(key,ProfileRevisionFloor.from(value,observations[key]))
        }
    }
    @Synchronized fun detach(owner: UUID) {removeOwner(owner)}
    @Synchronized fun inherit(previous: AuthorPresentationCandidates) {
        if(previous===this) return
        previous.observationSnapshot().forEach {(key,floor)->storeObservation(key,observations[key]?.merged(floor) ?: floor)}
        previous.denialSnapshot().forEach {(key,authority)->storeDenial(key,denials[key]?.merged(authority) ?: authority)}
        previous.fencedAt?.let {if(fencedAt?.let {old->it-old>0}!=false) fencedAt=it}
    }
    @Synchronized private fun denialSnapshot()=denials.toMap()
    @Synchronized private fun observationSnapshot()=observations.toMap()
    private fun storeObservation(key: ProfileKey,floor: ProfileRevisionFloor) {
        if(key !in observations && observations.size>=2048) {observations.remove(observations.keys.first());fencedAt=nanoTime()}
        observations[key]=floor
    }
    @Synchronized fun recordDenial(value: ProfileReadResult.Unavailable): Boolean {
        val authorities=listOfNotNull(observations[value.key]?.authority)+
            listOfNotNull((peekAny(value.key)?.entry as? ReceivedAuthorPresentationEntry.Available)?.value?.profile?.lease?.authority)
        if(authorities.any {it.isAtLeast(value.authority) && it!=value.authority}) return false
        var floor=value.authority
        authorities.forEach {floor=floor.merged(it)};denials[value.key]?.let {floor=floor.merged(it)}
        storeDenial(value.key,floor);return true
    }
    private fun storeDenial(key: ProfileKey,authority: ProfileAuthority) {
        if(key !in denials && denials.size>=2048) {denials.remove(denials.keys.first());fencedAt=nanoTime()}
        denials[key]=authority
    }
    @Synchronized fun restore(value: ProfileReadResult.Available) {
        denials[value.key]?.let {if(value.profile.lease.authority.isAtLeast(it) && value.profile.lease.authority!=it) denials.remove(value.key)}
    }
    @Synchronized fun stage(view: AuthorPresentationView,sequence: Long,entry: ReceivedAuthorPresentationEntry,owner: UUID) {
        prune();val now=nanoTime()
        val remaining=minOf(5_000_000_000L,view.renewByNanos-now,when(entry) {
            is ReceivedAuthorPresentationEntry.Available->entry.value.deadlineNanos-now
            is ReceivedAuthorPresentationEntry.Unavailable->entry.untilNanos-now
            is ReceivedAuthorPresentationEntry.Retryable->entry.notBeforeNanos-now
        })
        if(remaining<=0) return
        val old=values[entry.key]?.takeIf {it.view==view && it.sequence==sequence && it.entry==entry}
        val candidate=Candidate(view,sequence,entry,old?.expires?.takeIf {it-now<=remaining} ?: now+remaining,
            (old?.owners ?: persistentSetOf()).add(owner),old?.valueBytes ?: cost(entry))
        remove(entry.key)
        if(candidate.cost>MaximumBytes) {publish();return}
        while(values.size>=MaximumEntries || bytes>MaximumBytes-candidate.cost) {
            val victim=values.minByOrNull {it.value.expires-now}?.key ?: break
            remove(victim)
        }
        values[entry.key]=candidate;bytes+=candidate.cost;publish()
    }
    @Synchronized fun take(key: ProfileKey,owner: UUID): Candidate?=peek(key,owner)?.also {removeOwner(owner,key)}
    @Synchronized fun removeOwner(owner: UUID,key: ProfileKey?=null) {
        values.keys.toList().filter {key==null || key==it}.forEach {lookup->
            val old=values.getValue(lookup)
            if(owner in old.owners) {
                remove(lookup)
                val owners=old.owners.remove(owner)
                if(owners.isNotEmpty()) {val next=old.copy(owners=owners);values[lookup]=next;bytes+=next.cost}
            }
        };publish()
    }
    @Synchronized fun prune() {
        val now=nanoTime();values.filterValues {it.expires-now<=0 || it.view.renewByNanos-now<=0}.keys.toList().forEach(::remove);publish()
    }
    @Synchronized fun clear() {values.clear();bytes=0;publish()}
    @Synchronized fun diagnostics(): Pair<Int,Int> {prune();return values.size to bytes}
    private fun remove(key: ProfileKey) {values.remove(key)?.let {bytes-=it.cost}}
    private fun publish() {val now=nanoTime();deadline.value=values.values.minByOrNull {it.expires-now}?.expires}
    companion object {
        const val MaximumEntries=64
        const val MaximumBytes=256*1024
        /** Conservative UTF-8 charge including escaped names, capability targets and headers.
         * Redacted toString() values cannot measure capability storage. Nothing encoded here leaves memory.
         */
        private fun cost(entry: ReceivedAuthorPresentationEntry): Int {
            fun text(value: String?)=value?.let {JsonPrimitive(it).toString().toByteArray(Charsets.UTF_8).size} ?: 0
            var size=entry.key.payload().toString().toByteArray(Charsets.UTF_8).size+128
            if(entry is ReceivedAuthorPresentationEntry.Available) {
                val value=entry.value;val profile=value.profile
                size+=1024+OwnProfileClient.profilePayload(profile.view).toString().toByteArray(Charsets.UTF_8).size
                size+=text(profile.alias?.name)+text(profile.groupName?.name)
                value.avatar?.let {avatar->
                    size+=512
                    avatar.plan?.let {plan->size+=1024+text(plan.url)+text(plan.formFileField)
                        size+=plan.headers.sumOf {64+text(it.name)+text(it.value)}
                        size+=plan.formFields.entries.sumOf {32+text(it.key)+text(it.value)}
                    }
                }
            }
            return size
        }
    }
}
