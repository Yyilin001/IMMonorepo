package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import java.io.Closeable
import java.util.UUID

/** Hints never contain a committed local cursor, nor grant room access. */
sealed interface RealtimeSyncHint {
    data class Account(val event: Long, val head: Long) : RealtimeSyncHint
    data class AccountResync(val recoveryEpoch: String) : RealtimeSyncHint
    data class Room(val room: RoomId, val head: Long, val liveEvents: PersistentList<RoomLiveEvent> = persistentListOf()) : RealtimeSyncHint
    data class Coverage(val scope: SyncCoverageScope, val scopeId: String, val revision: Long,
        val generation: Long, val head: Long, val state: ActivityCoverageState, val reason: SyncCoverageReason, val connectionEpoch: String="") : RealtimeSyncHint
    companion object {
        internal fun decode(envelope: Envelope): RealtimeSyncHint? = try {
            when {
                envelope.hasAccountRoomResyncRequired() -> AccountResync(recoveryEpoch(envelope.accountRoomResyncRequired.connectionEpoch))
                envelope.hasSyncAvailable() -> envelope.syncAvailable.let {
                    require(it.eventId >= 0 && it.highWatermark >= 0); Account(it.eventId,it.highWatermark)
                }
                envelope.hasGroupEventAvailable() -> envelope.groupEventAvailable.let {
                    require(it.highWatermark >= 0)
                    Room(RoomId(it.roomId),it.highWatermark,RoomLiveEvents.decode(it))
                }
                envelope.hasRealtimeCoverage() -> envelope.realtimeCoverage.let {
                    val scope = when(it.scope) {
                        RealtimeCoverage.Scope.ACCOUNT -> SyncCoverageScope.Account
                        RealtimeCoverage.Scope.ROOM -> SyncCoverageScope.Room
                        RealtimeCoverage.Scope.DIRECTORY -> SyncCoverageScope.Directory
                        else -> return null
                    }
                    val value = RealtimeCoverageState.decode(it, 1)
                    Coverage(scope,value.scopeId,value.revision,value.scopeGeneration,value.highWatermark,value.status,value.reason,value.connectionEpoch)
                }
                else -> null
            }
        } catch (_: IllegalArgumentException) { throw ClientFailure.Protocol() }
    }
}
enum class SyncCoverageScope { Account, Room, Directory }
enum class SyncCoverageReason { Confirmed, Installing, Lost, Unavailable, Cancelled }
data class RealtimeSyncEvent(val connectionEpoch: Long, val hint: RealtimeSyncHint)
data class RoomEventSubscription(val room: RoomId, val head: Long, val membershipRevision: Long)
class RoomEventSubscriptionClient(private val transport: EnvelopeTransport) : RoomEventSubscriptionCommands {
    override suspend fun subscribe(room: RoomId, appliedThrough: Long): RoomEventSubscription {
        require(appliedThrough >= 0)
        val reply = transport.request(Envelope.newBuilder().setGroupEventSubscribe(GroupEventSubscribe.newBuilder()
            .setRoomId(room.value).setAfterRoomSequence(appliedThrough)))
        if(!reply.hasGroupEventSubscribed() || reply.groupEventSubscribed.roomId != room.value ||
            reply.groupEventSubscribed.highWatermark < 0 || reply.groupEventSubscribed.membershipRevision < 0) throw ClientFailure.Protocol()
        return RoomEventSubscription(room,reply.groupEventSubscribed.highWatermark,reply.groupEventSubscribed.membershipRevision)
    }
    override suspend fun unsubscribe(room: RoomId) {
        if(!transport.request(Envelope.newBuilder().setGroupEventUnsubscribe(GroupEventUnsubscribe.newBuilder().setRoomId(room.value))).hasAcknowledged())
            throw ClientFailure.Protocol()
    }
}
data class RoomSyncWake(val room: RoomId, val head: Long, val force: Boolean = false, val readyAtNanos: Long? = null,
    val liveEvents: PersistentList<RoomLiveEvent> = persistentListOf())
data class RealtimeSyncWork(val selectedRoom: RoomId?, val account: Boolean, val refreshDirectory: Boolean,
    val rooms: PersistentList<RoomSyncWake>, val restartAccountEpoch: String? = null)

/** Single-dispatcher, bounded/coalescing work inbox. Taking work never acknowledges delivery.
 * A new hint received while work is suspended remains in the next turn; hot rooms rejoin at the tail.
 */
class RealtimeSyncWakeups(private val epoch: Long, events: Flow<RealtimeSyncEvent>, scope: CoroutineScope, private val nanoTime: () -> Long = System::nanoTime) : Closeable {
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var selected: RoomId? = null
    private var account = false
    private var directory = false
    private var restartAccountEpoch: String? = null
    var notificationRevision: Long = 0
        private set
    val hasPendingRecovery: Boolean get() = account || directory || rooms.isNotEmpty() || restartAccountEpoch != null
    val availableRoomSlots: Int get() = (64-rooms.size).coerceAtLeast(0)
    private val rooms = linkedMapOf<RoomId,RoomSyncWake>()
    private val coverage = SyncCoverageTracker()
    private var closed = false
    private val collector = scope.launch(start=CoroutineStart.UNDISPATCHED) { events.collect { if(it.connectionEpoch == epoch) accept(it.hint) } }
    fun wakeUp() {if(!closed) wake.trySend(Unit)}
    fun select(room: RoomId?) { if(!closed && selected != room) { selected=room;wake.trySend(Unit) } }
    fun account() { if(!closed) { account=true;wake.trySend(Unit) } }
    /** A personal baseline fences room application; retain watermarks without retaining stale bodies. */
    fun deferForSnapshot(work:RealtimeSyncWork) {
        work.rooms.forEach {room(it.room,it.head,true)}
        account()
    }
    fun room(room: RoomId, head: Long, force: Boolean=false, retryAfterMillis: Long=0, liveEvents: PersistentList<RoomLiveEvent> = persistentListOf()) {
        require(head >= 0 && retryAfterMillis >= 0)
        if(closed) return
        val old=rooms[room]
        val deadline=if(retryAfterMillis == 0L) old?.readyAtNanos else {
            val requested=nanoTime()+retryAfterMillis.coerceAtMost(Long.MAX_VALUE/2/1_000_000)*1_000_000
            old?.readyAtNanos?.let {maxOf(it,requested)} ?: requested
        }
        val mergedHead=maxOf(old?.head ?: 0,head)
        val merged=RoomLiveEvents.merge(mergedHead,old?.liveEvents ?: persistentListOf(),liveEvents)
        val otherBytes=rooms.values.sumOf {if(it.room == room) 0L else RoomLiveEvents.bytes(it.liveEvents)}
        // Optional bodies may be dropped under pressure; retain the recovery watermark.
        val bounded=if(otherBytes+RoomLiveEvents.bytes(merged) <= RoomLiveEvents.inboxBytes) merged else persistentListOf()
        val next=RoomSyncWake(room,mergedHead,force || old?.force == true,deadline,bounded)
        if(next == old) return
        if(old != null || rooms.size < 64) rooms[room]=next
        else directory=true // A full directory pass recovers omitted work; no unbounded room-key retention.
        wake.trySend(Unit)
    }
    private fun accept(hint: RealtimeSyncHint) {
        if(closed) return
        notificationRevision++
        when(hint) {
            is RealtimeSyncHint.Account -> account()
            is RealtimeSyncHint.AccountResync -> {restartAccountEpoch=hint.recoveryEpoch;directory=true;account()}
            is RealtimeSyncHint.Room -> room(hint.room,hint.head,liveEvents=hint.liveEvents)
            is RealtimeSyncHint.Coverage -> {
                if(!coverage.accept(hint)) return
                when(hint.scope) {
                    SyncCoverageScope.Account -> account()
                    SyncCoverageScope.Room -> room(RoomId(hint.scopeId),hint.head,true)
                    SyncCoverageScope.Directory -> { directory=true;wake.trySend(Unit) }
                }
            }
        }
    }
    fun take(maximumRooms: Int = 4): RealtimeSyncWork {
        require(maximumRooms in 1..16)
        wake.tryReceive()
        val batch=rooms.values.filter { it.readyAtNanos == null || it.readyAtNanos <= nanoTime() }.take(maximumRooms).toPersistentList()
        batch.forEach {rooms.remove(it.room)}
        return RealtimeSyncWork(selected,account,directory,batch,restartAccountEpoch).also {account=false;directory=false;restartAccountEpoch=null}
    }
    suspend fun await(maximumWaitMillis: Long) {
        if(closed || account || directory) return
        if(rooms.values.any {it.readyAtNanos == null}) return
        val next=rooms.values.mapNotNull {it.readyAtNanos}.minOrNull()
        if(next != null && next <= nanoTime()) return
        val wait=if(next == null) maximumWaitMillis else minOf(maximumWaitMillis,(next-nanoTime()+999_999)/1_000_000)
        withTimeoutOrNull(wait.coerceAtLeast(1)) {wake.receive()}
    }
    override fun close() {closed=true;collector.cancel();wake.close();rooms.clear();coverage.clear()}
}
