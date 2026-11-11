package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class RoomDirectoryRecoveryTests {
    private val room=RoomId("00000000-0000-0000-0000-000000000001")
    private class Store: RoomDirectoryStore,RoomLatestVisibleStore,RoomStore,SyncStore {
        var scan=RoomDirectoryScan("scope","round","",null,false,1);var position=SyncCursor(1);var restarts=0;var verified=0
        var queued=persistentListOf<RoomDirectoryWork>();val finished=mutableListOf<Pair<RoomDirectoryWork,Long?>>()
        var summaryAccepted=true;var summaryCommitted=false;var revoked=false
        val visibleRequests=mutableListOf<PersistentList<RoomId>>()
        val selections=mutableListOf<Boolean>()
        val summaryBatches=mutableListOf<PersistentList<LatestVisibleCommit>>()
        override suspend fun ensureLatestVisible(scope: String,rooms: PersistentList<RoomId>) {visibleRequests+=rooms}
        override suspend fun beginLatestVisible(scope: String)=LatestVisibleRequest(scope,position.generation)
        override suspend fun commitLatestVisibleBatch(request: LatestVisibleRequest,entries: PersistentList<LatestVisibleCommit>): PersistentSet<RoomId> {
            summaryBatches+=entries
            return entries.filter {commitLatestVisible(request,it.work,it.snapshot)}.map {it.work.room}.toPersistentSet()
        }
        override suspend fun commitLatestVisible(request: LatestVisibleRequest,work: RoomDirectoryWork,snapshot: LatestVisibleSnapshot): Boolean {
            assertEquals(0,local.sequence);summaryCommitted=true;return summaryAccepted
        }
        var local=RoomCursor();var candidateAllowed=true;var beforeVerify: (() -> Unit)?=null
        override suspend fun beginDirectory()=scan.scope
        override suspend fun directoryScan(scope: String)=scan
        override suspend fun restartDirectory(scope: String) {restarts++;scan=scan.copy(round="round-$restarts",cursor="",topology=null,complete=false)}
        override suspend fun commitDirectoryPage(request: RoomDirectoryScan,page: RoomDirectoryPage) {
            if(scan.topology != null && scan.topology != page.topology) throw RoomDirectoryFailure(RoomDirectoryFailure.Reason.TopologyChanged)
            scan=scan.copy(cursor=page.next,topology=page.topology,complete=page.next.isEmpty())
        }
        override suspend fun directoryWork(scope: String,now: Long,limit: Int,oldestFirst: Boolean): PersistentList<RoomDirectoryWork> {
            selections+=oldestFirst;return queued.take(limit).toPersistentList()
        }
        override suspend fun finishDirectoryWork(scope: String,work: RoomDirectoryWork,retryAt: Long?) {finished+=work to retryAt;if(retryAt==null) queued=queued.remove(work)}
        override suspend fun directoryProgress(scope: String)=RoomDirectoryProgress(scan.complete,queued.size,null)
        override suspend fun recoveryCandidate(scope: String)=if(candidateAllowed && scan.complete && queued.isEmpty()) RoomRecoveryCandidate(scope,scan.round,position.generation,position.sequence) else null
        override suspend fun verifyRecoveryCandidate(candidate: RoomRecoveryCandidate,personal: SyncCursor): Boolean {
            verified++;beforeVerify?.invoke()
            return candidate.round==scan.round && candidate.generation==position.generation && position==personal && position.pendingReceipt==null
        }
        override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId,RoomKind>)=error("No full directory scan")
        override suspend fun acceptStates(states: kotlinx.collections.immutable.PersistentMap<RoomId,RoomSyncState>) {states.forEach {(room,state) -> acceptState(room,state)}}
        override suspend fun acceptState(room: RoomId,state: RoomSyncState) {}
        override suspend fun unavailable(room: RoomId) {revoked=true}
        override suspend fun roomCursor(room: RoomId)=local
        override suspend fun commitRoom(page: GroupEventPage,expected: RoomCursor) {local=RoomCursor(page.nextRoomSequence)}
        override val syncMutex=kotlinx.coroutines.sync.Mutex()
        private var rebuild=false
        override suspend fun requiresSnapshotRebuild()=rebuild
        override suspend fun requestSnapshotRebuild() {rebuild=true}
        override suspend fun discardSyncCapabilities(expected: SyncCursor) {check(position==expected);position=expected.copy(token="",pendingReceipt=null,pendingSequence=null)}
        override suspend fun cancelSnapshot(expected: SnapshotManifest)=error("Unexpected snapshot")
        override suspend fun cursor()=position
        override suspend fun commit(batch: SyncBatch,expected: SyncCursor) {assertEquals(position,expected);position=SyncCursor(batch.generation,batch.recordsList.lastOrNull()?.userSyncSequence ?: expected.sequence,batch.nextSyncToken,batch.syncReceipt.takeIf {batch.recordsCount>0})}
        override suspend fun acknowledged(expected: SyncCursor) {assertEquals(position,expected);position=position.copy(pendingReceipt=null,pendingSequence=null)}
        private var reset: SyncReset? = null
    override suspend fun pendingReset() = reset
    override suspend fun stageReset(expected: SyncCursor, reset: SyncReset) {check(position==expected);check(this.reset==null || this.reset==reset);this.reset=reset}
    override suspend fun cancelReset(expected: SyncReset) {check(reset==expected);reset=null;position=position.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun pendingSnapshot(): SnapshotManifest?=null
        override suspend fun stage(manifest: SnapshotManifest)=error("Unexpected snapshot")
        override suspend fun page(index: Int): SnapshotPage?=null
        override suspend fun stage(page: SnapshotPage)=error("Unexpected snapshot")
        override suspend fun snapshotImportProgress(manifest:SnapshotManifest)=testSnapshotProgress(manifest)
    override suspend fun importSnapshotPage(manifest:SnapshotManifest,page:SnapshotPage):SnapshotImportProgress {
        val imported=SnapshotImportValidation.advance(manifest,snapshotImportProgress(manifest),page)
        stage(page);return imported.progress
    }
    override suspend fun prepareSnapshotActivation(manifest:SnapshotManifest) {validateSnapshot(testSnapshotItems(manifest))}
    override suspend fun activateAcknowledgedSnapshot(manifest:SnapshotManifest) {activate(manifest,testSnapshotItems(manifest))}
    override suspend fun validateSnapshot(items: PersistentList<SnapshotItem>)=error("Unexpected snapshot")
        override suspend fun activate(manifest: SnapshotManifest,items: PersistentList<SnapshotItem>)=error("Unexpected snapshot")
    }
    private class Wire(val respond: suspend (Envelope)->Envelope): EnvelopeTransport {
        val calls=mutableListOf<Envelope>()
        override suspend fun request(body: Envelope.Builder)=body.build().let {calls+=it;respond(it)}
    }
    private fun directory(next: String="",topology: String="topology")=Envelope.newBuilder().setUserRoomDirectoryPage(UserRoomDirectoryPage.newBuilder().setNextCursor(next).setTopologyGeneration(topology)).build()
    @Test fun `directory pages yield at budget including filtered empty pages and resume saved cursor`()=runTest {
        val store=Store();val wire=Wire {directory(if(it.userRoomDirectoryList.cursor.isEmpty()) "opaque-next" else "")}
        val engine=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store));engine.start()
        assertFalse(engine.runTurn(maximumRooms=0).complete);assertEquals("opaque-next",store.scan.cursor);assertEquals(1,wire.calls.size)
        assertTrue(engine.runTurn(maximumRooms=0).complete);assertEquals("opaque-next",wire.calls.last().userRoomDirectoryList.cursor)
        engine.runTurn(maximumRooms=0);assertEquals(2,wire.calls.size)
    }
    @Test fun `server cursor reset and changed topology restart scan without discarding durable room work`()=runTest {
        val store=Store().apply {scan=scan.copy(cursor="old",topology="old");queued=persistentListOf(RoomDirectoryWork(room,"request"))}
        var reset=true;val wire=Wire {if(reset) {reset=false;throw GatewayFailure("ROOM_DIRECTORY_RESET_REQUIRED",false,0)} else directory(topology="new")}
        val engine=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store));engine.start()
        assertFalse(engine.runTurn(maximumRooms=0).complete);assertEquals(1,store.restarts);assertEquals(1,store.queued.size)
        store.scan=store.scan.copy(cursor="next",topology="old")
        assertFalse(engine.runTurn(maximumRooms=0).complete);assertEquals(2,store.restarts);assertEquals(1,store.queued.size)
    }
    @Test fun `work budget and directory authority floor prevent premature completion`()=runTest {
        val store=Store().apply {scan=scan.copy(complete=true);queued=(1..6).map {RoomDirectoryWork(room.copyId(it),"$it",3,2,requiresSummary=false)}.toPersistentList()}
        val wire=Wire {request -> when {
            request.hasRoomSyncStateBatch() -> Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder().addRooms(RoomSyncStateResult.newBuilder()
                .setRoomId(request.roomSyncStateBatch.getRoomIds(0)).setState(RoomSyncState.newBuilder().setRoomId(request.roomSyncStateBatch.getRoomIds(0)).setHead(0).setOwnerEpoch(1).setViewerMembershipRevision(2)))).build()
            request.hasGroupEventPull() -> Envelope.newBuilder().setGroupEventPage(GroupEventPage.newBuilder().setRoomId(request.groupEventPull.roomId)).build()
            else -> Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList)).build()
        }}
        val engine=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store),{5_000});engine.start()
        engine.runTurn(maximumPages=0,maximumRooms=2)
        assertEquals(2,store.finished.size);assertTrue(store.finished.all {it.second==6_000L});assertEquals(6,store.queued.size)
        assertEquals(2,wire.calls.count {it.hasRoomSyncStateBatch()})
    }
    private fun RoomId.copyId(index: Int)=RoomId("00000000-0000-0000-0000-${index.toString().padStart(12,'0')}")
    private fun batch(sequence: Long=0,more: Boolean=false)=Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base")
        .setNextSyncToken("token-$sequence").setSyncReceipt("receipt").setHasMore(more).apply {if(sequence>0) addRecords(SyncRecord.newBuilder().setUserSyncSequence(sequence)
            .setSourceEventId("record-$sequence").setProjectionKind("room_head").setPayload(ByteString.copyFromUtf8("{}")))}).build()
    @Test fun `completion pulls personal stream after candidate capture and verifies acknowledged checkpoint`()=runTest {
        val store=Store().apply {scan=scan.copy(complete=true)}
        val wire=Wire {if(it.hasSyncPull()) batch(1) else Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()}
        val engine=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store));engine.start()
        assertTrue(engine.completeIfCaughtUp(SyncEngine(wire,store)) {true});assertEquals(1,store.verified)
        assertNull(store.position.pendingReceipt);assertEquals(listOf(true,false),wire.calls.map {it.hasSyncPull()})
    }
    @Test fun `notification race directory restart or personal checkpoint replacement invalidates completion`()=runTest {
        val store=Store().apply {scan=scan.copy(complete=true)};var stable=true
        val wire=Wire {stable=false;batch()};val engine=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store));engine.start()
        assertFalse(engine.completeIfCaughtUp(SyncEngine(wire,store)) {stable});assertEquals(0,store.verified)
        stable=true;val quiet=Wire {batch()}
        store.beforeVerify={store.scan=store.scan.copy(round="new")}
        assertFalse(engine.completeIfCaughtUp(SyncEngine(quiet,store)) {true})
        store.beforeVerify={store.position=store.position.copy(sequence=10)}
        assertFalse(engine.completeIfCaughtUp(SyncEngine(quiet,store)) {true})
    }
    @Test fun `completion yields when final personal catchup exceeds its budget`()=runTest {
        val store=Store().apply {scan=scan.copy(complete=true)}
        val wire=Wire {if(it.hasSyncPull()) batch(store.position.sequence+1,true) else Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()}
        val engine=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store));engine.start()
        assertFalse(engine.completeIfCaughtUp(SyncEngine(wire,store)) {true});assertEquals(4,store.position.sequence);assertEquals(0,store.verified)
    }
    @Test fun `queued notification revision invalidates candidate even when wake is taken during final pull`()=runTest {
        val events=MutableSharedFlow<RealtimeSyncEvent>(extraBufferCapacity=8);val queue=RealtimeSyncWakeups(1,events,this)
        try {
            val revision=queue.notificationRevision
            events.emit(RealtimeSyncEvent(1,RealtimeSyncHint.Account(1,1)));runCurrent();assertTrue(queue.hasPendingRecovery)
            queue.take();assertFalse(queue.hasPendingRecovery);assertNotEquals(revision,queue.notificationRevision)
            val latest=queue.notificationRevision;events.emit(RealtimeSyncEvent(0,RealtimeSyncHint.Account(2,2)));runCurrent();assertEquals(latest,queue.notificationRevision)
        } finally {queue.close()}
    }
    @Test fun `directory decoding rejects unknown kinds duplicate ids and invalid unsigned authority`() {
        val entry=UserRoomDirectoryEntry.newBuilder().setRoomId(room.value).setRoomKind("group").setOwnerEpoch(0).setViewerMembershipRevision(0)
        val page=UserRoomDirectoryPage.newBuilder().setTopologyGeneration("t").addRooms(entry)
        assertEquals(RoomKind.Group,RoomDirectoryPage.decode(page.build()).entries.single().kind)
        assertFailsWith<ClientFailure.Protocol> {RoomDirectoryPage.decode(page.clone().addRooms(entry).build())}
        assertFailsWith<ClientFailure.Protocol> {RoomDirectoryPage.decode(page.clone().setRooms(0,entry.clone().setOwnerEpoch(-1)).build())}
        assertFailsWith<ClientFailure.Protocol> {RoomDirectoryPage.decode(page.clone().setRooms(0,entry.clone().setRoomKind("other")).build())}
    }
    @Test fun `summary is authorized and committed before content pull without acknowledging its watermark`()=runTest {
        val store=Store().apply {scan=scan.copy(complete=true);queued=persistentListOf(RoomDirectoryWork(room,"request"))}
        val wire=Wire {request -> when {
            request.hasRoomSyncStateBatch() -> Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder().addRooms(RoomSyncStateResult.newBuilder()
                .setRoomId(room.value).setState(RoomSyncState.newBuilder().setRoomId(room.value).setHead(1).setUnreadCount(1)))).build()
            request.hasRoomLatestVisibleBatch() -> {assertEquals(0,store.local.sequence);Envelope.newBuilder().setRoomLatestVisibleBatchResult(RoomLatestVisibleBatchResult.newBuilder()
                .addRooms(RoomLatestVisibleResult.newBuilder().setRoomId(room.value).setSnapshot(RoomLatestVisibleSnapshot.newBuilder().setHead(10)))).build()}
            request.hasGroupEventPull() -> {assertTrue(store.summaryCommitted);Envelope.newBuilder().setGroupEventPage(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(1)).build()}
            else -> {assertEquals(1,request.deviceRoomProgressReport.getRooms(0).appliedThrough);Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList)).build()}
        }}
        val recovery=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store),{1_000});recovery.start();recovery.runTurn()
        assertEquals(1,store.local.sequence);assertEquals(1_250,store.finished.single().second)
        assertEquals(1,wire.calls.count {it.hasDeviceRoomProgressReport()});assertEquals(1,store.queued.size)
    }
    @Test fun `summary retry unavailable or stale observation cannot pull or acknowledge content`()=runTest {
        for(mode in listOf("retry","unavailable","stale")) {
            val store=Store().apply {scan=scan.copy(complete=true);queued=persistentListOf(RoomDirectoryWork(room,"request"));summaryAccepted=false}
            val wire=Wire {request -> when {
                request.hasRoomSyncStateBatch() -> Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder().addRooms(RoomSyncStateResult.newBuilder()
                    .setRoomId(room.value).setState(RoomSyncState.newBuilder().setRoomId(room.value)))).build()
                request.hasRoomLatestVisibleBatch() -> Envelope.newBuilder().setRoomLatestVisibleBatchResult(RoomLatestVisibleBatchResult.newBuilder().addRooms(RoomLatestVisibleResult.newBuilder().setRoomId(room.value).apply {
                    when(mode) {"retry" -> setRetry(RoomSyncStateRetry.newBuilder().setRetryAfterSeconds(3));"unavailable" -> setUnavailable(RoomSyncStateUnavailable.getDefaultInstance());else -> setSnapshot(RoomLatestVisibleSnapshot.getDefaultInstance())}
                })).build()
                else -> error("Summary cannot cause delivery progress before a content commit")
            }}
            val recovery=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store),{1_000});recovery.start();recovery.runTurn()
            assertEquals(0,store.local.sequence)
            assertEquals(when(mode) {"retry" -> 4_000L;"unavailable" -> null;else -> 2_000L},store.finished.single().second)
            assertEquals(mode=="unavailable",store.revoked)
        }
    }

    @Test fun `every fourth recovery selection reserves oldest work independently of display priority`()=runTest {
        val store=Store().apply {scan=scan.copy(complete=true)};val wire=Wire {error("No work should issue network requests")}
        val recovery=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store));recovery.start()
        repeat(8) {recovery.runTurn(maximumPages=0);recovery.runTurn(maximumPages=0,maximumRooms=0)}
        assertEquals(listOf(false,false,false,true,false,false,false,true),store.selections)
        val visible=persistentListOf(room)
        recovery.ensureVisible(visible);assertEquals(visible,store.visibleRequests.single())
        assertFailsWith<IllegalArgumentException> {recovery.ensureVisible(List(101) {room}.toPersistentList())}
        assertEquals(1,store.visibleRequests.size)
    }
    @Test fun `display wake interrupts idle runtime without fabricating account or room recovery evidence`()=runTest {
        val queue=RealtimeSyncWakeups(1,MutableSharedFlow(),this)
        try {
            val waiting=async {queue.await(5_000)}
            runCurrent();assertFalse(waiting.isCompleted)
            queue.wakeUp();runCurrent();assertTrue(waiting.isCompleted)
            val work=queue.take();assertFalse(work.account);assertFalse(work.refreshDirectory);assertTrue(work.rooms.isEmpty())
            assertEquals(0,queue.notificationRevision)
        } finally {queue.close()}
    }

    @Test fun `one recovery turn batches authority and summaries while independent retry rooms yield`()=runTest {
        val ids=(1..4).map {room.copyId(it)}
        val store=Store().apply {scan=scan.copy(complete=true);queued=ids.map {RoomDirectoryWork(it,it.value)}.toPersistentList()}
        val wire=Wire {request -> when {
            request.hasRoomSyncStateBatch() -> Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder().addAllRooms(request.roomSyncStateBatch.roomIdsList.map {id ->
                RoomSyncStateResult.newBuilder().setRoomId(id).apply {
                    if(id==ids[3].value) setUnavailable(RoomSyncStateUnavailable.getDefaultInstance()) else setState(RoomSyncState.newBuilder().setRoomId(id))
                }.build()
            })).build()
            request.hasRoomLatestVisibleBatch() -> {
                assertEquals(ids.take(3).map {it.value}.toSet(),request.roomLatestVisibleBatch.roomIdsList.toSet())
                Envelope.newBuilder().setRoomLatestVisibleBatchResult(RoomLatestVisibleBatchResult.newBuilder().addAllRooms(request.roomLatestVisibleBatch.roomIdsList.map {id ->
                    RoomLatestVisibleResult.newBuilder().setRoomId(id).apply {
                        if(id==ids[2].value) setRetry(RoomSyncStateRetry.newBuilder().setRetryAfterSeconds(2)) else setSnapshot(RoomLatestVisibleSnapshot.getDefaultInstance())
                    }.build()
                })).build()
            }
            request.hasGroupEventPull() -> {
                assertEquals(2,store.summaryBatches.single().size);assertTrue(request.groupEventPull.roomId in ids.take(2).map {it.value})
                Envelope.newBuilder().setGroupEventPage(GroupEventPage.newBuilder().setRoomId(request.groupEventPull.roomId)).build()
            }
            else -> Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList)).build()
        }}
        val recovery=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store),{1_000});recovery.start();val progress=recovery.runTurn()
        assertEquals(4,wire.calls.first().roomSyncStateBatch.roomIdsCount)
        assertEquals(1,wire.calls.count {it.hasRoomLatestVisibleBatch()});assertEquals(2,wire.calls.count {it.hasGroupEventPull()})
        assertEquals(1,progress.pendingRooms);assertEquals(ids[2],store.queued.single().room)
        assertEquals(3_000,store.finished.single {it.first.room==ids[2]}.second)
    }

}
