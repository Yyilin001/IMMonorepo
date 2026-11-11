package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlin.test.*

internal class BackgroundRoomStore : RoomDirectoryStore, RoomLatestVisibleStore, RoomStore, RoomContentStore, AccountRoomHeadStore {
    var scan=RoomDirectoryScan("initial","round","",null,false,1)
    var starts=0;var directoryCommits=0;var stateCommits=0;var summaryCommits=0;var bodyCommits=0
    var heads=persistentListOf<AccountRoomHead>()
    val queued=linkedMapOf<RoomId,RoomDirectoryWork>();val due=mutableMapOf<RoomId,Long>()
    val cursors=mutableMapOf<RoomId,RoomCursor>();val denied=mutableSetOf<RoomId>()
    val headReads=mutableListOf<Pair<RoomId?,Int>>()
    val oldestSelections=mutableListOf<Boolean>()
    override suspend fun beginDirectory(): String {starts++;scan=scan.copy(scope="scope-$starts");return scan.scope}
    private fun checkScope(scope:String) {if(scope!=scan.scope) throw RoomDirectoryFailure(RoomDirectoryFailure.Reason.StaleScope)}
    override suspend fun directoryScan(scope:String)=scan.also {checkScope(scope)}
    override suspend fun restartDirectory(scope:String) {checkScope(scope);scan=scan.copy(cursor="",topology=null,complete=false)}
    override suspend fun commitDirectoryPage(request:RoomDirectoryScan,page:RoomDirectoryPage) {
        assertEquals(scan,request);directoryCommits++;page.entries.forEach {queued[it.room]=RoomDirectoryWork(it.room,it.room.value,it.membership,it.owner)}
        scan=scan.copy(cursor=page.next,topology=page.topology,complete=page.next.isEmpty())
    }
    override suspend fun directoryWork(scope:String,now:Long,limit:Int,oldestFirst:Boolean):PersistentList<RoomDirectoryWork> {
        checkScope(scope);oldestSelections+=oldestFirst;return queued.values.filter {(due[it.room] ?: 0)<=now}.take(limit).toPersistentList()
    }
    override suspend fun finishDirectoryWork(scope:String,work:RoomDirectoryWork,retryAt:Long?) {
        checkScope(scope);if(retryAt==null) queued.remove(work.room) else due[work.room]=retryAt
    }
    override suspend fun directoryProgress(scope:String)=RoomDirectoryProgress(scan.complete,queued.size,due.values.minOrNull()).also {checkScope(scope)}
    override suspend fun recoveryCandidate(scope:String):RoomRecoveryCandidate?=error("Background cannot prove final coverage")
    override suspend fun verifyRecoveryCandidate(candidate:RoomRecoveryCandidate,personal:SyncCursor):Boolean=error("No final personal catchup")
    override suspend fun ensureLatestVisible(scope:String,rooms:PersistentList<RoomId>) {checkScope(scope);rooms.forEach {queued.putIfAbsent(it,RoomDirectoryWork(it,it.value))}}
    override suspend fun beginLatestVisible(scope:String)=LatestVisibleRequest(scope,1).also {checkScope(scope)}
    override suspend fun commitLatestVisible(request:LatestVisibleRequest,work:RoomDirectoryWork,snapshot:LatestVisibleSnapshot):Boolean {summaryCommits++;return true}
    override suspend fun commitLatestVisibleBatch(request:LatestVisibleRequest,entries:PersistentList<LatestVisibleCommit>):PersistentSet<RoomId> {
        checkScope(request.scope);entries.forEach {assertEquals(1,it.snapshot.owner);assertEquals(1,it.snapshot.membership)};summaryCommits+=entries.size;return entries.map {it.work.room}.toPersistentSet()
    }
    override suspend fun pendingRoomHeads(after:RoomId?,limit:Int):PersistentList<AccountRoomHead> {
        headReads+=after to limit
        val pending=heads.filter {it.sequence>(cursors[it.room]?.sequence ?: 0) && it.room !in denied}
        val next=pending.filter {after==null || it.room.value>after.value}.ifEmpty {pending}
        return next.take(limit).toPersistentList()
    }
    override suspend fun reconcileDirectory(rooms:PersistentMap<RoomId,RoomKind>)=error("No unbounded scan")
    override suspend fun acceptState(room:RoomId,state:RoomSyncState) {stateCommits++}
    override suspend fun acceptStates(states:PersistentMap<RoomId,RoomSyncState>) {stateCommits+=states.size}
    override suspend fun unavailable(room:RoomId) {denied+=room}
    override suspend fun roomCursor(room:RoomId)=cursors[room] ?: RoomCursor()
    override suspend fun commitRoom(page:GroupEventPage,expected:RoomCursor) {bodyCommits++;cursors[RoomId(page.roomId)]=RoomCursor(page.nextRoomSequence)}
    override suspend fun beginRoomContent(scope:String,work:PersistentList<RoomDirectoryWork>):RoomContentRequest {
        checkScope(scope);return RoomContentRequest(scope,1,work.associate {it.room to RoomContentFence(cursors[it.room] ?: RoomCursor(),1,1,null)}.toPersistentMap())
    }
    override suspend fun commitRoomContent(request:RoomContentRequest,response:RoomContentResponse):PersistentMap<RoomId,RoomCursor> {
        checkScope(request.scope);bodyCommits++;denied+=response.unavailable
        return response.pages.mapValues {(room,page)->RoomCursor(page.nextRoomSequence).also {cursors[room]=it}}.toPersistentMap()
    }
}
internal class BackgroundRoomWire(val store:BackgroundRoomStore) : EnvelopeTransport {
    val calls=mutableListOf<Envelope>()
    var custom:(suspend (Envelope)->Envelope?)?=null
    var includeEvent=true;var more=false
    val epoch="00000000-0000-0000-0000-000000000099"
    override suspend fun request(body:Envelope.Builder):Envelope {
        val request=body.build();calls+=request
        return custom?.invoke(request) ?: respond(request)
    }
    fun respond(request:Envelope):Envelope=Envelope.newBuilder().apply {when {
        request.hasAccountRoomChangesStart()->setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder().setConnectionEpoch(epoch))
        request.hasUserRoomDirectoryList()->setUserRoomDirectoryPage(UserRoomDirectoryPage.newBuilder().setTopologyGeneration("topology"))
        request.hasRoomSyncStateBatch()->setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder().addAllRooms(request.roomSyncStateBatch.roomIdsList.map {id->
            RoomSyncStateResult.newBuilder().setRoomId(id).setState(RoomSyncState.newBuilder().setRoomId(id).setHead(10).setUnreadCount(10).setViewerMembershipRevision(1).setOwnerEpoch(1)).build()
        }))
        request.hasRoomLatestVisibleBatch()->setRoomLatestVisibleBatchResult(RoomLatestVisibleBatchResult.newBuilder().addAllRooms(request.roomLatestVisibleBatch.roomIdsList.map {id->
            RoomLatestVisibleResult.newBuilder().setRoomId(id).setSnapshot(RoomLatestVisibleSnapshot.newBuilder().setOwnerEpoch(1).setViewerMembershipRevision(1).setHead(10)).build()
        }))
        request.hasGroupEventPullBatch()->setGroupEventPageBatch(GroupEventPageBatch.newBuilder().addAllRooms(request.groupEventPullBatch.roomsList.map {pull->
            GroupEventPageResult.newBuilder().setRoomId(pull.roomId).setPage(page(pull)).build()
        }))
        request.hasGroupEventPull()->setGroupEventPage(page(request.groupEventPull))
        request.hasDeviceRoomProgressReport()->{
            assertTrue(store.bodyCommits>0)
            request.deviceRoomProgressReport.roomsList.forEach {assertEquals(store.cursors[RoomId(it.roomId)]?.sequence,it.appliedThrough)}
            setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList))
        }
        else->error("Unexpected background request ${request.bodyCase}")
    }}.build()
    private fun page(pull:GroupEventPull)=GroupEventPage.newBuilder().setRoomId(pull.roomId).setNextRoomSequence(pull.afterRoomSequence+1).setHasMore(more).apply {
        if(includeEvent) addEvents(GroupEvent.newBuilder().setSourceEventId("event-${pull.afterRoomSequence+1}").setRoomSequence(pull.afterRoomSequence+1).setProjectionKind("room")
            .setPayload(ByteString.copyFromUtf8("""{"room_id":"${pull.roomId}"}""")))
    }.build()
}

@OptIn(ExperimentalCoroutinesApi::class)
class BackgroundRoomSyncTests {
    private fun room(index:Int)=RoomId("00000000-0000-0000-0000-${index.toString().padStart(12,'0')}")
    private class Harness {
        val store=BackgroundRoomStore();val wire=BackgroundRoomWire(store)
        val state=MutableStateFlow(RealtimeConnectionState(1,true));val events=MutableSharedFlow<RealtimeSyncEvent>(extraBufferCapacity=16)
        var retired=0
        val sync=BackgroundRoomSync(wire,state,events,{retired++},store,store,store,{1000L})
    }
    @Test fun `directory pages and content rooms spend one budget and durable bodies precede progress`()=runTest {
        val h=Harness();h.store.heads=persistentListOf(AccountRoomHead(room(1),10,1),AccountRoomHead(room(2),10,1))
        val result=h.sync.run(3)
        assertEquals(IncrementalSyncResult(3,true,IncrementalSyncStopReason.PageLimit),result)
        assertEquals(1,h.store.directoryCommits);assertEquals(2,h.store.stateCommits);assertEquals(2,h.store.summaryCommits)
        assertEquals(1,h.wire.calls.count {it.hasGroupEventPullBatch()});assertEquals(1,h.wire.calls.count {it.hasDeviceRoomProgressReport()})
        assertTrue(h.wire.calls.first().hasAccountRoomChangesStart());assertEquals(0,h.retired)
    }
    @Test fun `one remaining unit prioritizes pending content and hot room receives only one page`()=runTest {
        val h=Harness();h.store.heads=persistentListOf(AccountRoomHead(room(1),10,1));h.wire.more=true
        assertEquals(1,h.sync.run(1).processedPageCount)
        assertEquals(0,h.store.directoryCommits);assertEquals(1,h.store.cursors.getValue(room(1)).sequence)
        assertEquals(1,h.wire.calls.count {it.hasGroupEventPullBatch()});assertEquals(1250,h.store.due[room(1)])
    }
    @Test fun `empty filtered directory pages resume the saved cursor across new connection scopes`()=runTest {
        val h=Harness();h.wire.custom={request->if(request.hasUserRoomDirectoryList()) Envelope.newBuilder().setUserRoomDirectoryPage(
            UserRoomDirectoryPage.newBuilder().setTopologyGeneration("t").setNextCursor("next-${h.store.directoryCommits+1}")).build() else null}
        assertEquals(2,h.sync.run(2).processedPageCount);assertEquals(2,h.sync.run(2).processedPageCount)
        assertEquals(listOf("","next-1","next-2","next-3"),h.wire.calls.filter {it.hasUserRoomDirectoryList()}.map {it.userRoomDirectoryList.cursor})
        assertEquals(2,h.store.starts);assertEquals(4,h.store.directoryCommits)
    }
    @Test fun `idle or deferred work returns page limit without spin final personal catchup or false new records`()=runTest {
        for(mode in listOf("empty","deferred","denied")) {
            val h=Harness();h.store.scan=h.store.scan.copy(complete=true)
            if(mode!="empty") h.store.heads=persistentListOf(AccountRoomHead(room(1),10,1))
            if(mode=="deferred") h.store.due[room(1)]=2000
            if(mode=="denied") h.wire.custom={request->if(request.hasRoomSyncStateBatch()) Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder()
                .addRooms(RoomSyncStateResult.newBuilder().setRoomId(room(1).value).setUnavailable(RoomSyncStateUnavailable.getDefaultInstance()))).build() else null}
            assertEquals(IncrementalSyncResult(0,false,IncrementalSyncStopReason.PageLimit),h.sync.run(10000))
            assertTrue(h.wire.calls.size<=2);assertEquals(0,h.store.bodyCommits)
        }
    }
    @Test fun `trimmed cursor progress without actual events does not report new records`()=runTest {
        val h=Harness();h.store.heads=persistentListOf(AccountRoomHead(room(1),10,1));h.wire.includeEvent=false
        assertFalse(h.sync.run(1).didCommitNewRecords);assertEquals(1,h.store.cursors.getValue(room(1)).sequence)
    }
    @Test fun `cancellation after late directory state summary or body response cannot write that response`()=runTest {
        for(stage in listOf("directory","state","summary","body")) {
            val h=Harness();if(stage!="directory") h.store.heads=persistentListOf(AccountRoomHead(room(1),10,1))
            val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            h.wire.custom={request->
                val matches=when(stage) {"directory"->request.hasUserRoomDirectoryList();"state"->request.hasRoomSyncStateBatch();"summary"->request.hasRoomLatestVisibleBatch();else->request.hasGroupEventPullBatch()}
                if(matches) {entered.complete(Unit);withContext(NonCancellable) {release.await()};h.wire.respond(request)} else null
            }
            val work=async {h.sync.run(1)};entered.await();work.cancel();runCurrent();assertFalse(work.isCompleted)
            release.complete(Unit);work.join()
            when(stage) {"directory"->assertEquals(0,h.store.directoryCommits);"state"->assertEquals(0,h.store.stateCommits);"summary"->assertEquals(0,h.store.summaryCommits);else->assertEquals(0,h.store.bodyCommits)}
            assertFalse(h.wire.calls.any {it.hasDeviceRoomProgressReport()});assertEquals(0,h.events.subscriptionCount.value)
        }
    }
    @Test fun `coverage loss closes connection immediately and drains late directory response`()=runTest {
        for(wrong in listOf(false,true)) {
            val h=Harness();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            h.wire.custom={request->if(request.hasUserRoomDirectoryList()) {entered.complete(Unit);withContext(NonCancellable) {release.await()};h.wire.respond(request)} else null}
            val work=async {runCatching {h.sync.run(2)}};entered.await()
            h.events.emit(RealtimeSyncEvent(1,RealtimeSyncHint.AccountResync(if(wrong) "wrong" else h.wire.epoch)));runCurrent()
            assertEquals(1,h.retired);assertFalse(work.isCompleted);release.complete(Unit)
            val error=work.await().exceptionOrNull();if(wrong) assertIs<ClientFailure.Protocol>(error) else assertIs<BackgroundRoomCoverageLost>(error)
            assertEquals(0,h.store.directoryCommits);assertEquals(0,h.events.subscriptionCount.value)
        }
    }
    @Test fun `listener installed before ready observes immediate resync and ignores old physical connection`()=runTest {
        val h=Harness();h.wire.custom={request->if(request.hasAccountRoomChangesStart()) {
            assertEquals(1,h.events.subscriptionCount.value)
            h.events.emit(RealtimeSyncEvent(0,RealtimeSyncHint.AccountResync(h.wire.epoch)))
            h.events.emit(RealtimeSyncEvent(1,RealtimeSyncHint.AccountResync(h.wire.epoch)))
            yield();h.wire.respond(request)
        } else null}
        assertFailsWith<BackgroundRoomCoverageLost> {h.sync.run(1)}
        assertEquals(0,h.store.directoryCommits);assertEquals(1,h.retired)
    }
    @Test fun `concurrent invocation is rejected and physical connection replacement cancels active run`()=runTest {
        val h=Harness();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        h.wire.custom={request->if(request.hasUserRoomDirectoryList()) {entered.complete(Unit);withContext(NonCancellable) {release.await()};h.wire.respond(request)} else null}
        val work=async {runCatching {h.sync.run(2)}};entered.await()
        assertFailsWith<IllegalStateException> {h.sync.run(1)};assertEquals(1,h.store.starts)
        h.state.value=RealtimeConnectionState(2,true);runCurrent();assertEquals(1,h.retired)
        release.complete(Unit);assertIs<BackgroundRoomCoverageLost>(work.await().exceptionOrNull());assertEquals(0,h.store.directoryCommits)
        h.wire.custom=null;assertEquals(1,h.sync.run(1).processedPageCount)
    }
    @Test fun `invalid budgets and disconnected caller do not mutate directory or issue requests`()=runTest {
        val h=Harness()
        for(budget in listOf(0,-1,10001)) assertFailsWith<IllegalArgumentException> {h.sync.run(budget)}
        h.state.value=RealtimeConnectionState(1,false)
        assertFailsWith<RealtimeUnavailableBeforeAdmission> {h.sync.run(1)}
        assertTrue(h.wire.calls.isEmpty());assertEquals(0,h.store.starts)
    }
    @Test fun `single room fallback obeys one page budget and counts applied events`()=runTest {
        val h=Harness();h.store.heads=persistentListOf(AccountRoomHead(room(1),10,1));h.wire.more=true
        val single=object:RoomStore by h.store {}
        val sync=BackgroundRoomSync(h.wire,h.state,h.events,{h.retired++},h.store,single,h.store,{1000L})
        assertEquals(IncrementalSyncResult(1,true,IncrementalSyncStopReason.PageLimit),sync.run(1))
        assertEquals(1,h.wire.calls.count {it.hasGroupEventPull()});assertFalse(h.wire.calls.any {it.hasGroupEventPullBatch()})
    }
    @Test fun `late single room success or forbidden response after cancellation cannot mutate content or denial`()=runTest {
        for(forbidden in listOf(false,true)) {
            val h=Harness();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            h.wire.custom={request->if(request.hasGroupEventPull()) {
                entered.complete(Unit);withContext(NonCancellable) {release.await()}
                if(forbidden) throw GatewayFailure("FORBIDDEN",false,0)
                h.wire.respond(request)
            } else null}
            val work=async {RoomSyncEngine(h.wire,h.store).synchronizeRoom(room(1),1)}
            entered.await();work.cancel();release.complete(Unit);work.join()
            assertEquals(0,h.store.bodyCommits);assertTrue(h.store.denied.isEmpty())
            assertFalse(h.wire.calls.any {it.hasDeviceRoomProgressReport()})
        }
    }
    @Test fun `lost directory coverage retires work while ordinary account hints do not invent completion`()=runTest {
        val h=Harness();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        h.wire.custom={request->if(request.hasUserRoomDirectoryList()) {entered.complete(Unit);withContext(NonCancellable) {release.await()};h.wire.respond(request)} else null}
        val work=async {runCatching {h.sync.run(1)}};entered.await()
        h.events.emit(RealtimeSyncEvent(1,RealtimeSyncHint.Account(1,10)));runCurrent();assertEquals(0,h.retired)
        h.events.emit(RealtimeSyncEvent(1,RealtimeSyncHint.Coverage(SyncCoverageScope.Directory,room(1).value,1,1,0,
            ActivityCoverageState.Recovering,SyncCoverageReason.Lost,h.wire.epoch)))
        runCurrent();assertEquals(1,h.retired);release.complete(Unit)
        assertIs<BackgroundRoomCoverageLost>(work.await().exceptionOrNull());assertEquals(0,h.store.directoryCommits)
    }

    @Test fun `short background invocations preserve oldest-work rotation across connection scopes`()=runTest {
        val h=Harness();h.store.scan=h.store.scan.copy(complete=true)
        repeat(8) {assertEquals(0,h.sync.run(1).processedPageCount)}
        assertEquals(listOf(false,false,false,true,false,false,false,true),h.store.oldestSelections)
        assertEquals(8,h.store.starts);assertEquals(0,h.events.subscriptionCount.value)
    }

}
