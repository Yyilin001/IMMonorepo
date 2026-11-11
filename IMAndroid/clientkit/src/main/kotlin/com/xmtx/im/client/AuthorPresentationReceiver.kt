package com.xmtx.im.client

import kotlinx.collections.immutable.*
import java.util.UUID

/** A causal local nonce. Neither a room interest nor a nonce grants access. */
@ConsistentCopyVisibility
data class AuthorPresentationView internal constructor(val start: AuthorPresentationStart,val startedNanos: Long,val renewByNanos: Long)
sealed interface ReceivedAuthorPresentationEntry {
    val key: ProfileKey
    data class Available(val value: ProfileReadResult.Available): ReceivedAuthorPresentationEntry {override val key get()=value.key}
    data class Unavailable(val value: ProfileReadResult.Unavailable,val untilNanos: Long): ReceivedAuthorPresentationEntry {override val key get()=value.key}
    data class Retryable(override val key: ProfileKey,val notBeforeNanos: Long): ReceivedAuthorPresentationEntry
}
data class ReceivedAuthorPresentationDelta(val view: AuthorPresentationView,val sequence: Long,val entries: PersistentList<ReceivedAuthorPresentationEntry>)

/** Account/device-local, thread-safe memory owner. Receiving never writes messages, fetches bytes or acknowledges retention. */
class AuthorPresentationReceiver(private val actor: UserId,private val device: DeviceId,private val nanoTime: ()->Long=System::nanoTime) : AutoCloseable {
    init {uuidId(actor.value);uuidId(device.value)}
    private var current: AuthorPresentationView?=null
    private var lastSequence=0L
    private var closed=false
    @Synchronized fun begin(stream: String,messageRooms: PersistentList<RoomId>): AuthorPresentationView {
        check(!closed)
        val now=nanoTime()
        return AuthorPresentationView(AuthorPresentationStart(stream,UUID.randomUUID().toString().uppercase(),messageRooms),now,
            now+AuthorPresentationDelta.MaximumViewAgeMillis*1_000_000).also {current=it;lastSequence=0}
    }
    @Synchronized fun end(view: AuthorPresentationView) {if(current==view) {current=null;lastSequence=0}}
    @Synchronized fun receive(bytes: ByteArray,view: AuthorPresentationView): ReceivedAuthorPresentationDelta? {
        val now=nanoTime()
        if(!active(view,now)) return null
        return receive(AuthorPresentationDelta.decode(bytes),view,now)
    }
    @Synchronized internal fun receive(delta: AuthorPresentationDelta,view: AuthorPresentationView,now: Long=nanoTime()): ReceivedAuthorPresentationDelta? {
        if(!active(view,now)) return null
        if(delta.stream!=view.start.stream || delta.view!=view.start.view || delta.actor!=actor || delta.device!=device) throw ClientFailure.Protocol()
        if(delta.sequence<=lastSequence) return null
        val age=now-view.startedNanos
        val serverAge=delta.serverViewAgeMillis*1_000_000
        if(serverAge>age) throw ClientFailure.Protocol()
        val transit=age-serverAge
        fun deadline(expiry: Long): Long? {
            val lifetime=try {Math.subtractExact(expiry,delta.serverNowMillis)} catch(_: ArithmeticException) {return null}
            if(lifetime !in 1..300_000) return null
            val remaining=lifetime*1_000_000-transit
            return if(remaining>0) now+remaining else null
        }
        val entries=delta.entries.mapNotNull {entry->when(entry) {
            is AuthorPresentationEntry.Available->deadline(entry.profile.lease.validUntil)?.let {expires->
                val avatarExpiry=entry.avatar?.plan?.let {deadline(it.expiresAt)}
                val avatar=if(avatarExpiry==null) entry.avatar?.copy(plan=null) else entry.avatar
                ReceivedAuthorPresentationEntry.Available(ProfileReadResult.Available(entry.profile,expires,avatar,avatarExpiry))
            }
            is AuthorPresentationEntry.Unavailable->(30_000_000_000-age).takeIf {it>0}?.let {ReceivedAuthorPresentationEntry.Unavailable(entry.denial,now+it)}
            is AuthorPresentationEntry.Retryable->ReceivedAuthorPresentationEntry.Retryable(entry.key,now+requireNotNull(delta.retryAfterMillis)*1_000_000)
        }}.toPersistentList()
        lastSequence=delta.sequence
        return ReceivedAuthorPresentationDelta(view,delta.sequence,entries)
    }
    private fun active(view: AuthorPresentationView,now: Long)=!closed && current==view && now-view.startedNanos>=0 && view.renewByNanos-now>0
    @Synchronized override fun close() {closed=true;current=null;lastSequence=0}
}

/** Synchronous receive-pump inbox. All calls belong to the connection lock. Drops oldest supplements, never extends leases. */
internal class AuthorPresentationInbox(private val stream: String,private val actor: UserId,private val device: DeviceId,
    private val nanoTime: ()->Long=System::nanoTime) : AutoCloseable {
    private val receiver=AuthorPresentationReceiver(actor,device,nanoTime)
    var view: AuthorPresentationView?=null;private set
    private var confirmed=false
    private val queue=ArrayDeque<Pair<ReceivedAuthorPresentationDelta,Int>>()
    var queuedBytes=0;private set
    val queuedFrames get()=queue.size
    fun begin(rooms: PersistentList<RoomId>): AuthorPresentationView=receiver.begin(stream,rooms).also {view=it;confirmed=false;clear()}
    fun end(expected: AuthorPresentationView) {if(view==expected) {receiver.end(expected);view=null;confirmed=false;clear()}}
    fun requested(start: AuthorPresentationStart): AuthorPresentationView {
        val current=view ?: throw ClientFailure.Protocol()
        if(current.start!=start || current.renewByNanos-nanoTime()<=0) throw ClientFailure.Protocol()
        return current
    }
    fun requireIdentity(expectedStream: String,expectedView: String,ending: Boolean=false) {
        if(expectedStream!=stream) throw ClientFailure.Protocol()
        if(!ending && (view?.start?.view!=expectedView || requireNotNull(view).renewByNanos-nanoTime()<=0)) throw ClientFailure.Protocol()
        uuidId(expectedView)
    }
    fun confirm(expected: AuthorPresentationView,response: AuthorPresentationStart) {
        if(expected.start!=response) throw ClientFailure.Protocol()
        if(view==expected && expected.renewByNanos-nanoTime()>0) confirmed=true
    }
    fun accept(bytes: ByteArray) {
        val delta=AuthorPresentationDelta.decode(bytes)
        if(delta.stream!=stream || delta.actor!=actor || delta.device!=device) throw ClientFailure.Protocol()
        val current=view ?: return
        if(!confirmed || current.start.view!=delta.view) return
        val received=receiver.receive(delta,current) ?: return
        if(received.entries.isEmpty()) return
        while(queue.isNotEmpty() && (queue.size>=8 || queuedBytes+bytes.size>64*1024)) {queuedBytes-=queue.removeFirst().second}
        queue.addLast(received to bytes.size);queuedBytes+=bytes.size
    }
    fun next(expected: AuthorPresentationView): ReceivedAuthorPresentationDelta? {
        check(view==expected && expected.renewByNanos-nanoTime()>0)
        if(queue.isEmpty()) return null
        return queue.removeFirst().also {queuedBytes-=it.second}.first
    }
    private fun clear() {queue.clear();queuedBytes=0}
    override fun close() {view=null;confirmed=false;clear();receiver.close()}
}
