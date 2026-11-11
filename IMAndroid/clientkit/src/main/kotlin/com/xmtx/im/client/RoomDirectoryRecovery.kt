package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

data class RoomDirectoryEntry(val room: RoomId, val kind: RoomKind, val membership: Long, val owner: Long)
data class RoomDirectoryPage(val entries: PersistentList<RoomDirectoryEntry>, val next: String, val topology: String) {
    fun validate() {
        if(entries.size > 100 || entries.map {it.room}.toSet().size != entries.size || topology.isEmpty() || topology.toByteArray().size > 128 || next.toByteArray().size > 2048 ||
            entries.any {it.membership < 0 || it.owner < 0 || runCatching {UUID.fromString(it.room.value).toString().equals(it.room.value,true)}.getOrDefault(false).not()}) throw ClientFailure.Protocol()
    }
    companion object {
        fun decode(page: UserRoomDirectoryPage) = RoomDirectoryPage(page.roomsList.map {
            RoomDirectoryEntry(RoomId(it.roomId),when(it.roomKind) {"direct" -> RoomKind.Direct;"group" -> RoomKind.Group;else -> throw ClientFailure.Protocol()},it.viewerMembershipRevision,it.ownerEpoch)
        }.toPersistentList(),page.nextCursor,page.topologyGeneration).also {it.validate()}
    }
}
data class RoomDirectoryScan(val scope: String, val round: String, val cursor: String, val topology: String?, val complete: Boolean, val personalGeneration: Long)
data class RoomDirectoryWork(val room: RoomId, val revision: String, val minimumMembership: Long = 0, val minimumOwner: Long = 0, val requiresSummary: Boolean = true, val targetHead: Long = 0)
data class RoomDirectoryProgress(val complete: Boolean, val pendingRooms: Int, val nextAttemptAt: Long?)
data class RoomDirectoryBudgetResult(val directoryPages: Int, val processedRooms: Int,
    val appliedEventCount: Int, val progress: RoomDirectoryProgress)
data class RoomRecoveryCandidate(val scope: String, val round: String, val generation: Long, val minimumSequence: Long)
class RoomDirectoryFailure(val reason: Reason): Exception(reason.name) {enum class Reason {StaleScope, StalePage, TopologyChanged}}
interface RoomDirectoryStore {
    suspend fun beginDirectory(): String
    suspend fun directoryScan(scope: String): RoomDirectoryScan
    suspend fun restartDirectory(scope: String)
    suspend fun commitDirectoryPage(request: RoomDirectoryScan,page: RoomDirectoryPage)
    suspend fun directoryWork(scope: String,now: Long,limit: Int,oldestFirst: Boolean = false): PersistentList<RoomDirectoryWork>
    suspend fun finishDirectoryWork(scope: String,work: RoomDirectoryWork,retryAt: Long?)
    suspend fun directoryProgress(scope: String): RoomDirectoryProgress
    suspend fun recoveryCandidate(scope: String): RoomRecoveryCandidate?
    suspend fun verifyRecoveryCandidate(candidate: RoomRecoveryCandidate, personal: SyncCursor): Boolean
}

/** One durable directory page and bounded room catch-up per turn. The account channel must be installed first. */
class RoomDirectoryRecovery(private val transport: EnvelopeTransport,private val store: RoomDirectoryStore,
    private val rooms: RoomSyncEngine,private val now: () -> Long = System::currentTimeMillis,private val contentBatchSize: Int = 2) {
    init {require(contentBatchSize in 1..16)}
    private val mutex=Mutex()
    private var scope: String?=null
    private var selectionRound=0
    suspend fun start()=mutex.withLock {scope=store.beginDirectory()}
    suspend fun ensureVisible(rooms: PersistentList<RoomId>)=mutex.withLock {
        require(rooms.size<=100)
        (store as? RoomLatestVisibleStore)?.ensureLatestVisible(requireNotNull(scope),rooms)
    }
    suspend fun restart()=mutex.withLock {store.restartDirectory(requireNotNull(scope))}
    suspend fun progress(): RoomDirectoryProgress=mutex.withLock {store.directoryProgress(requireNotNull(scope))}
    suspend fun runTurn(maximumPages: Int=1,maximumRooms: Int=4): RoomDirectoryProgress = runBudget(maximumPages,maximumRooms).progress
    /** Counts committed directory pages and processed content rooms, not HTTP requests or summary watermarks. */
    suspend fun runBudget(maximumPages: Int=1,maximumRooms: Int=4,roomPageLimit: Int=2): RoomDirectoryBudgetResult=mutex.withLock {
        require(maximumPages in 0..4 && maximumRooms in 0..16 && roomPageLimit in 1..2)
        currentCoroutineContext().ensureActive()
        var scanned=0;var processed=0;var applied=0
        val scope=requireNotNull(scope)
        for(index in 0 until maximumPages) {
            val scan=store.directoryScan(scope)
            if(scan.complete) break
            try {
                val response=transport.request(Envelope.newBuilder().setUserRoomDirectoryList(UserRoomDirectoryList.newBuilder().setCursor(scan.cursor).setPageSize(100)))
                currentCoroutineContext().ensureActive()
                if(!response.hasUserRoomDirectoryPage()) throw ClientFailure.Protocol()
                store.commitDirectoryPage(scan,RoomDirectoryPage.decode(response.userRoomDirectoryPage));scanned++
            } catch(e: GatewayFailure) {
                currentCoroutineContext().ensureActive()
                if(e.code != "ROOM_DIRECTORY_RESET_REQUIRED") throw e
                store.restartDirectory(scope);break
            } catch(e: RoomDirectoryFailure) {
                currentCoroutineContext().ensureActive()
                when(e.reason) {
                    RoomDirectoryFailure.Reason.TopologyChanged -> store.restartDirectory(scope)
                    RoomDirectoryFailure.Reason.StalePage -> Unit // A concurrent snapshot or restart already invalidated this page.
                    RoomDirectoryFailure.Reason.StaleScope -> throw e
                }
                break
            }
        }
        if(maximumRooms > 0) selectionRound=(selectionRound+1)%4
        val selected=if(maximumRooms>0) store.directoryWork(scope,now(),maximumRooms,oldestFirst=selectionRound==0) else persistentListOf()
        val blocked=mutableSetOf<RoomId>()
        val targets=selected.associate {it.room to it.targetHead}.toMutableMap()
        val summaries=store as? RoomLatestVisibleStore
        val summaryWork=selected.filter {it.requiresSummary && summaries!=null}
        val stateWork=if(rooms.supportsContentBatch) selected else summaryWork
        if(stateWork.isNotEmpty()) {
            val observed=rooms.observeRooms(stateWork.map {it.room}.toPersistentList())
            val available=stateWork.filter {work ->
                val state=observed.getValue(work.room)
                val wait=when {
                    state.unavailable -> null
                    state.retryAfterMillis>0 -> state.retryAfterMillis
                    state.membershipRevision<work.minimumMembership || state.ownerEpoch<work.minimumOwner -> 1_000L
                    else -> 0L
                }
                if(wait!=0L) {store.finishDirectoryWork(scope,work,wait?.let {now()+it});blocked+=work.room}
                else targets[work.room]=maxOf(work.targetHead,state.observedHead)
                wait==0L
            }
            val eligible=available.filter {it.requiresSummary && summaries!=null}
            if(eligible.isNotEmpty() && summaries!=null) {
                val request=summaries.beginLatestVisible(scope)
                val fetched=RoomLatestVisibleClient(transport).fetch(eligible.map {it.room}.toPersistentList())
                currentCoroutineContext().ensureActive()
                val snapshots=eligible.mapNotNull {work -> (fetched.getValue(work.room) as? LatestVisibleResult.Snapshot)?.let {LatestVisibleCommit(work,it.value)}}.toPersistentList()
                val accepted=if(snapshots.isEmpty()) persistentSetOf() else summaries.commitLatestVisibleBatch(request,snapshots)
                for(work in eligible) when(val summary=fetched.getValue(work.room)) {
                    LatestVisibleResult.Unavailable -> {rooms.revoke(work.room);store.finishDirectoryWork(scope,work,null);blocked+=work.room}
                    is LatestVisibleResult.Retry -> {store.finishDirectoryWork(scope,work,now()+summary.afterMillis);blocked+=work.room}
                    is LatestVisibleResult.Snapshot -> {
                        if(work.room !in accepted) {store.finishDirectoryWork(scope,work,now()+1_000);blocked+=work.room}
                        else targets[work.room]=maxOf(targets.getValue(work.room),summary.value.head)
                    }
                }
            }
        }
        val content=selected.filter {it.room !in blocked}.map {it.copy(targetHead=targets.getValue(it.room))}.toPersistentList()
        val batch=if(rooms.supportsContentBatch && content.isNotEmpty()) rooms.synchronizeRoomBatches(scope,content,contentBatchSize) else null
        for(work in selected) if(work.room !in blocked) {
            val result=batch?.getValue(work.room) ?: rooms.synchronizeRoom(work.room,maximumPages=roomPageLimit)
            currentCoroutineContext().ensureActive()
            processed++;applied+=result.appliedEventCount
            val delay=when {result.unavailable -> null;result.retryAfterMillis > 0 -> result.retryAfterMillis;result.hasMore || result.appliedThrough < targets.getValue(work.room) -> 250L;result.membershipRevision < work.minimumMembership || result.ownerEpoch < work.minimumOwner -> 1_000L;else -> null}
            store.finishDirectoryWork(scope,work,delay?.let {now()+it})
        }
        RoomDirectoryBudgetResult(scanned,processed,applied,store.directoryProgress(scope))
    }
    /** A final personal turn must follow candidate capture. Notification stability is owned by the runtime. */
    suspend fun completeIfCaughtUp(personal: SyncEngine, notificationsStable: () -> Boolean): Boolean=mutex.withLock {
        val scope=requireNotNull(scope)
        if(!notificationsStable()) return@withLock false
        val candidate=store.recoveryCandidate(scope) ?: return@withLock false
        val checkpoint=personal.synchronizeForCompletion() ?: return@withLock false
        if(!notificationsStable()) return@withLock false
        val verified=store.verifyRecoveryCandidate(candidate,checkpoint)
        verified && notificationsStable()
    }
}
