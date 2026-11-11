package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import kotlin.coroutines.coroutineContext

data class RoomCursor(val sequence: Long = 0, val historyIncomplete: Boolean = false)
data class RoomRecoveryResult(val room: RoomId, val appliedThrough: Long = 0, val observedHead: Long = 0,
    val hasMore: Boolean = false, val unavailable: Boolean = false, val retryAfterMillis: Long = 0, val membershipRevision: Long = 0, val ownerEpoch: Long = 0, val appliedEventCount: Int = 0)
interface RoomStore {
    suspend fun reconcileDirectory(rooms: PersistentMap<RoomId, RoomKind>)
    suspend fun acceptState(room: RoomId, state: RoomSyncState)
    /** Commit the validated authorization batch atomically; a storage failure must roll back every entry. */
    suspend fun acceptStates(states: PersistentMap<RoomId,RoomSyncState>)
    suspend fun unavailable(room: RoomId)
    suspend fun roomCursor(room: RoomId): RoomCursor
    suspend fun commitRoom(page: GroupEventPage, expected: RoomCursor)
}

/** V55: both private and group message content belongs to room logs, never the personal stream. */
class RoomSyncEngine(private val transport: EnvelopeTransport, private val store: RoomStore,
    private val nanoTime: () -> Long = System::nanoTime) {
    private val mutex = Mutex()
    private var rotation = 0
    private val retryDeadlines = mutableMapOf<RoomId,Long>()
    private fun retryRemaining(room: RoomId): Long {
        val deadline=retryDeadlines[room] ?: return 0
        return (deadline-nanoTime()).coerceAtLeast(0).let {(it+999_999)/1_000_000}
    }
    private fun defer(room: RoomId, seconds: Int): Long {
        val wait=maxOf(250,Integer.toUnsignedLong(seconds)*1000)
        retryDeadlines[room]=nanoTime()+wait*1_000_000
        return wait
    }
    suspend fun synchronize(maximumRooms: Int = 32) = mutex.withLock {
        require(maximumRooms in 1..100)
        val rooms = linkedMapOf<RoomId, RoomKind>()
        var cursor = ""
        var topology: String? = null
        val seenCursors = mutableSetOf<String>()
        var pageCount = 0
        do {
            coroutineContext.ensureActive()
            if (++pageCount > 100 || !seenCursors.add(cursor)) throw ClientFailure.Protocol()
            val result = transport.request(Envelope.newBuilder().setUserRoomDirectoryList(UserRoomDirectoryList.newBuilder().setPageSize(100).setCursor(cursor)))
            if (!result.hasUserRoomDirectoryPage()) throw ClientFailure.Protocol()
            val page = result.userRoomDirectoryPage
            if (page.roomsCount > 100 || page.topologyGeneration.isBlank() || page.topologyGeneration.toByteArray().size > 128 ||
                page.nextCursor.toByteArray().size > 2048 || (topology != null && topology != page.topologyGeneration)) throw ClientFailure.Protocol()
            topology = page.topologyGeneration
            page.roomsList.forEach {
                // These are nonnegative observations, not positive ownership grants. A new room may report epoch zero.
                if (it.roomKind !in setOf("direct", "group") || it.viewerMembershipRevision < 0 || it.ownerEpoch < 0 || rooms.put(RoomId(it.roomId), if(it.roomKind == "group") RoomKind.Group else RoomKind.Direct) != null) throw ClientFailure.Protocol()
            }
            cursor = page.nextCursor
        } while (cursor.isNotEmpty())
        store.reconcileDirectory(rooms.toPersistentMap())
        retryDeadlines.keys.retainAll(rooms.keys)
        if (rooms.isEmpty()) return@withLock
        val all = rooms.keys.toList()
        val start = rotation.mod(all.size)
        val selected = (all.drop(start) + all.take(start)).take(maximumRooms)
        rotation = (start + selected.size).mod(all.size)
        for (group in selected.chunked(16)) {
            val states=observeRoomsLocked(group.toPersistentList())
            for((room,state) in states) if(!state.unavailable && state.retryAfterMillis==0L) {
                coroutineContext.ensureActive()
                try {pullPage(room)} catch(e: GatewayFailure) {
                    coroutineContext.ensureActive()
                    if(e.code=="FORBIDDEN" && !e.retryable) store.unavailable(room) else throw e
                }
            }
        }
    }
    /** State observation never pulls content or acknowledges a room watermark. */
    suspend fun observeRooms(rooms: PersistentList<RoomId>): PersistentMap<RoomId,RoomRecoveryResult> = mutex.withLock {observeRoomsLocked(rooms)}
    private suspend fun observeRoomsLocked(rooms: PersistentList<RoomId>): PersistentMap<RoomId,RoomRecoveryResult> {
        require(rooms.size in 1..100)
        val results=linkedMapOf<RoomId,RoomRecoveryResult>()
        val due=rooms.distinct().filter {room ->
            val wait=retryRemaining(room)
            if(wait>0) results[room]=RoomRecoveryResult(room,retryAfterMillis=wait)
            wait==0L
        }
        if(due.isEmpty()) return results.toPersistentMap()
        coroutineContext.ensureActive()
        val response=transport.request(Envelope.newBuilder().setRoomSyncStateBatch(RoomSyncStateBatch.newBuilder().addAllRoomIds(due.map {it.value})))
        coroutineContext.ensureActive()
        if(!response.hasRoomSyncStateBatchResult()) throw ClientFailure.Protocol()
        val entries=response.roomSyncStateBatchResult.roomsList
        if(entries.size!=due.size || entries.map {RoomId(it.roomId)}.toSet()!=due.toSet()) throw ClientFailure.Protocol()
        // Validate the entire response before any authority, denial or retry state changes.
        val authorized=linkedMapOf<RoomId,RoomSyncState>()
        for(entry in entries) when {
            entry.hasState() -> {val room=RoomId(entry.roomId);validateState(room,entry.state);authorized[room]=entry.state}
            entry.hasUnavailable() || entry.hasRetry() -> Unit
            else -> throw ClientFailure.Protocol()
        }
        if(authorized.isNotEmpty()) store.acceptStates(authorized.toPersistentMap())
        for(entry in entries) {
            val room=RoomId(entry.roomId)
            results[room]=when {
                entry.hasUnavailable() -> {retryDeadlines.remove(room);store.unavailable(room);RoomRecoveryResult(room,unavailable=true)}
                entry.hasRetry() -> RoomRecoveryResult(room,retryAfterMillis=defer(room,entry.retry.retryAfterSeconds))
                else -> {
                    val state=entry.state;val cursor=store.roomCursor(room)
                    RoomRecoveryResult(room,cursor.sequence,state.head,cursor.sequence<state.head,
                        membershipRevision=state.viewerMembershipRevision,ownerEpoch=state.ownerEpoch)
                }
            }
        }
        return results.toPersistentMap()
    }
    /** Authorization is rechecked before each bounded recovery turn; hints cannot bypass it. */
    suspend fun synchronizeRoom(room: RoomId, maximumPages: Int = 2): RoomRecoveryResult = mutex.withLock {
        require(maximumPages in 0..16)
        val observed=observeRoomsLocked(persistentListOf(room)).getValue(room)
        if(observed.unavailable || observed.retryAfterMillis>0 || maximumPages==0) return@withLock observed
        try {
            var more=false;var applied=0
            repeat(maximumPages) {index -> if(index==0 || more) {
                coroutineContext.ensureActive();val page=pullPage(room);more=page.first;applied+=page.second
            }}
            val cursor=store.roomCursor(room)
            observed.copy(appliedThrough=cursor.sequence,hasMore=more || cursor.sequence<observed.observedHead,appliedEventCount=applied)
        } catch(e: GatewayFailure) {
            coroutineContext.ensureActive()
            if(e.code!="FORBIDDEN" || e.retryable) throw e
            store.unavailable(room);RoomRecoveryResult(room,unavailable=true)
        }
    }
    val supportsContentBatch: Boolean get()=store is RoomContentStore
    /** One bounded page per room. Authorization was observed by the directory phase; storage fences it across I/O. */
    suspend fun synchronizeRoomBatch(scope: String,work: PersistentList<RoomDirectoryWork>): PersistentMap<RoomId,RoomRecoveryResult> = mutex.withLock {
        synchronizeRoomBatchLocked(scope,work).also {results -> results.filterValues {it.unavailable}.keys.forEach {retryDeadlines.remove(it)}}
    }
    /** Disjoint content batches overlap at most two flights; the outer lock reserves all rooms against foreground writes. */
    suspend fun synchronizeRoomBatches(scope: String,work: PersistentList<RoomDirectoryWork>,batchSize: Int=2): PersistentMap<RoomId,RoomRecoveryResult> = mutex.withLock {
        require(work.size in 1..16 && work.map {it.room}.toSet().size==work.size && batchSize in 1..16)
        val permits=Semaphore(2)
        val results=coroutineScope {
            work.chunked(batchSize).map {group -> async {permits.withPermit {synchronizeRoomBatchLocked(scope,group.toPersistentList())}}}.awaitAll()
        }.fold(persistentMapOf<RoomId,RoomRecoveryResult>()) {all,result -> all.putAll(result)}
        results.filterValues {it.unavailable}.keys.forEach {retryDeadlines.remove(it)}
        results
    }
    private suspend fun synchronizeRoomBatchLocked(scope: String,work: PersistentList<RoomDirectoryWork>): PersistentMap<RoomId,RoomRecoveryResult> {
        require(work.size in 1..16 && work.map {it.room}.toSet().size==work.size)
        val content=store as? RoomContentStore ?: error("RoomContentStore required")
        val results=linkedMapOf<RoomId,RoomRecoveryResult>()
        val due=work.filter {item ->
            val wait=retryRemaining(item.room)
            if(wait>0) results[item.room]=RoomRecoveryResult(item.room,retryAfterMillis=wait)
            wait==0L
        }.toPersistentList()
        if(due.isEmpty()) return results.toPersistentMap()
        val request=content.beginRoomContent(scope,due)
        if(request.fences.keys!=due.map {it.room}.toSet()) throw ClientFailure.Protocol()
        val reads=due.associate {item ->
            val cursor=request.fences.getValue(item.room).cursor
            val gap=if(item.targetHead>cursor.sequence) item.targetHead-cursor.sequence else 1L
            item.room to RoomContentRead(cursor,minOf(32L,maxOf(1,64/due.size).toLong(),gap).toInt())
        }.toPersistentMap()
        val response=RoomContentClient(transport).fetch(reads)
        coroutineContext.ensureActive()
        val committed=content.commitRoomContent(request,response)
        if(committed.keys!=response.pages.keys) throw ClientFailure.Protocol()
        // One bounded progress report, strictly after the durable multi-room transaction.
        if(committed.isNotEmpty()) acknowledgeBatch(committed)
        for(item in due) {
            val fence=request.fences.getValue(item.room)
            results[item.room]=if(item.room in response.unavailable) {
                RoomRecoveryResult(item.room,unavailable=true)
            } else {
                val cursor=committed.getValue(item.room);val page=response.pages.getValue(item.room)
                RoomRecoveryResult(item.room,cursor.sequence,item.targetHead,page.hasMore || cursor.sequence<item.targetHead,
                    membershipRevision=fence.membership,ownerEpoch=fence.owner,appliedEventCount=page.eventsCount)
            }
        }
        return results.toPersistentMap()
    }
    private suspend fun acknowledgeBatch(cursors: PersistentMap<RoomId,RoomCursor>) {
        coroutineContext.ensureActive()
        val report=DeviceRoomProgressReport.newBuilder()
        cursors.forEach {(room,cursor) -> report.addRooms(DeviceRoomCursor.newBuilder().setRoomId(room.value).setAppliedThrough(cursor.sequence))}
        val response=transport.request(Envelope.newBuilder().setDeviceRoomProgressReport(report))
        if(!response.hasDeviceRoomProgressRecorded()) throw ClientFailure.Protocol()
        val entries=response.deviceRoomProgressRecorded.roomsList
        if(entries.size!=cursors.size || entries.map {RoomId(it.roomId)}.toSet()!=cursors.keys ||
            entries.any {it.appliedThrough<cursors.getValue(RoomId(it.roomId)).sequence}) throw ClientFailure.Protocol()
    }
    suspend fun revoke(room: RoomId) = mutex.withLock {retryDeadlines.remove(room);store.unavailable(room)}
    /** Apply only a contiguous prefix. Busy, unknown, revoked or gapped rooms use durable recovery. */
    suspend fun applyOnlineEvents(hint: RealtimeSyncHint.Room): Boolean {
        require(hint.head >= 0)
        val liveStore=store as? LiveRoomStore ?: return false
        if(!mutex.tryLock()) return false
        try {
            if(retryRemaining(hint.room) > 0) return false
            val current=store.roomCursor(hint.room)
            if(current.sequence >= hint.head) return true
            val candidates=hint.liveEvents.filter {it.sequence > current.sequence}
            if(candidates.size > RoomLiveEvents.maximumCount || candidates.any {it.sequence > hint.head} ||
                candidates.zipWithNext().any {(a,b) -> a.sequence >= b.sequence}) return false
            val prefix=candidates.takeWhileIndexed(current.sequence)
            if(prefix.isEmpty()) return false
            val page=GroupEventPage.newBuilder().setRoomId(hint.room.value).setNextRoomSequence(prefix.last().sequence)
                .setHasMore(prefix.last().sequence < hint.head)
            prefix.forEach {page.addEvents(GroupEvent.newBuilder().setSourceEventId(it.source).setRoomSequence(it.sequence)
                .setProjectionKind(it.kind).setPayload(it.payload))}
            val built=page.build()
            validateLivePage(hint.room,current,built)
            if(!liveStore.commitLiveRoom(built,current)) return false
            val committed=store.roomCursor(hint.room)
            acknowledge(hint.room,committed)
            return committed.sequence >= hint.head
        } finally {mutex.unlock()}
    }
    private fun List<RoomLiveEvent>.takeWhileIndexed(cursor: Long): List<RoomLiveEvent> {
        var previous=cursor
        return takeWhile {event -> (previous < Long.MAX_VALUE && event.sequence == previous+1).also {if(it) previous=event.sequence}}
    }
    private suspend fun pullPage(room: RoomId): Pair<Boolean,Int> {
        val current = store.roomCursor(room)
        val result = transport.request(Envelope.newBuilder().setGroupEventPull(GroupEventPull.newBuilder()
            .setRoomId(room.value).setAfterRoomSequence(current.sequence).setPageSize(200)))
        coroutineContext.ensureActive()
        if (!result.hasGroupEventPage()) throw ClientFailure.Protocol()
        val page = result.groupEventPage
        validatePage(room, current, page)
        store.commitRoom(page, current)
        val committed = store.roomCursor(room)
        acknowledge(room,committed)
        return page.hasMore to page.eventsCount
    }
    private suspend fun acknowledge(room: RoomId, committed: RoomCursor) {
        coroutineContext.ensureActive()
        // Device delivery progress is a separate post-commit receipt, never a read receipt.
        val ack = transport.request(Envelope.newBuilder().setDeviceRoomProgressReport(DeviceRoomProgressReport.newBuilder()
            .addRooms(DeviceRoomCursor.newBuilder().setRoomId(room.value).setAppliedThrough(committed.sequence))))
        if (!ack.hasDeviceRoomProgressRecorded() || ack.deviceRoomProgressRecorded.roomsCount != 1 ||
            RoomId(ack.deviceRoomProgressRecorded.getRooms(0).roomId) != room ||
            ack.deviceRoomProgressRecorded.getRooms(0).appliedThrough < committed.sequence) throw ClientFailure.Protocol()
    }
    companion object {
        fun validateState(room: RoomId, state: RoomSyncState) {
            if (RoomId(state.roomId) != room || state.ownerEpoch < 0 || state.viewerMembershipRevision < 0 || state.head < 0 || state.trimmedThrough !in 0..state.head ||
                            state.readThrough !in 0..state.head || state.latestOwnMessageSequence !in 0..state.head ||
                            state.unreadCount != state.head - maxOf(state.readThrough, state.latestOwnMessageSequence)) throw ClientFailure.Protocol()
        }
        fun validatePage(room: RoomId, current: RoomCursor, page: GroupEventPage) = validatePage(room,current,page,200)
        fun validateBatchPage(room: RoomId,current: RoomCursor,page: GroupEventPage,maximumEvents: Int=32) {
            require(maximumEvents in 1..32)
            validatePage(room,current,page,maximumEvents)
        }
        fun validateLivePage(room: RoomId, current: RoomCursor, page: GroupEventPage) {
            validatePage(room,current,page,RoomLiveEvents.maximumCount)
            if(page.eventsCount == 0 || page.logTrimmedThroughRoomSequence != 0L ||
                page.nextRoomSequence != page.eventsList.last().roomSequence) throw ClientFailure.Protocol()
            var previous=current.sequence
            var bytes=0L
            for(event in page.eventsList) {
                bytes+=event.payload.size().toLong()+128
                if(previous == Long.MAX_VALUE || event.roomSequence != previous+1 || bytes > RoomLiveEvents.maximumBytes) throw ClientFailure.Protocol()
                previous=event.roomSequence
            }
        }
        private fun validatePage(room: RoomId, current: RoomCursor, page: GroupEventPage, maximumEvents: Int) {
            if (RoomId(page.roomId) != room || page.eventsCount > maximumEvents || page.nextRoomSequence < current.sequence ||
                page.logTrimmedThroughRoomSequence < 0 || page.nextRoomSequence < page.logTrimmedThroughRoomSequence ||
                (page.hasMore && page.nextRoomSequence <= current.sequence)) throw ClientFailure.Protocol()
            var previous = current.sequence
            for (event in page.eventsList) {
                if (event.roomSequence <= previous || event.roomSequence > page.nextRoomSequence || event.sourceEventId.isBlank() || event.payload.isEmpty ||
                    event.projectionKind !in setOf("message", "message_reaction", "moderation", "room", "membership", "group_capability")) throw ClientFailure.Protocol()
                val payload = Json.parseToJsonElement(event.payload.toStringUtf8()).jsonObject
                if (RoomId(payload.string("room_id")) != room) throw ClientFailure.Protocol()
                payload["room_sequence"]?.jsonPrimitive?.longOrNull?.let { if (it != event.roomSequence) throw ClientFailure.Protocol() }
                previous = event.roomSequence
            }
        }
    }
}
