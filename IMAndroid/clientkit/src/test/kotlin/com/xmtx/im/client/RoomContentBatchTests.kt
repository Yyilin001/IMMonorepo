package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.io.IOException
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RoomContentBatchTests {
    private val a=RoomId(UUID.randomUUID().toString());private val b=RoomId(UUID.randomUUID().toString())
    private fun page(room: RoomId,next: Long=1,more: Boolean=false)=GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(next).setHasMore(more).build()
    private fun result(room: RoomId,page: GroupEventPage)=GroupEventPageResult.newBuilder().setRoomId(room.value).setPage(page).build()
    private fun failure(room: RoomId,code: String,retry: Boolean=false)=GroupEventPageResult.newBuilder().setRoomId(room.value)
        .setError(com.xmtx.imclientkit.generated.im.realtime.v2.Error.newBuilder().setCode(code).setRetryable(retry)).build()
    private fun batch(vararg entries: GroupEventPageResult)=Envelope.newBuilder().setGroupEventPageBatch(GroupEventPageBatch.newBuilder().addAllRooms(entries.toList())).build()
    private class Wire(val respond: suspend (Envelope)->Envelope): EnvelopeTransport {
        val calls=mutableListOf<Envelope>()
        override suspend fun request(body: Envelope.Builder)=body.build().let {calls+=it;respond(it)}
    }
    private class Store: LiveRoomStore,RoomContentStore {
        val cursors=mutableMapOf<RoomId,RoomCursor>();val denied=mutableSetOf<RoomId>();var commits=0;var fail=false;var live=0
        override suspend fun beginRoomContent(scope: String,work: PersistentList<RoomDirectoryWork>)=RoomContentRequest(scope,1,
            work.associate {it.room to RoomContentFence(cursors[it.room] ?: RoomCursor(),1,1,RoomMembershipFence(1,"grant",true))}.toPersistentMap())
        override suspend fun commitRoomContent(request: RoomContentRequest,response: RoomContentResponse): PersistentMap<RoomId,RoomCursor> {
            if(fail) throw IOException("commit failed")
            commits++;denied+=response.unavailable
            return response.pages.mapValues {(room,page) -> RoomCursor(page.nextRoomSequence).also {cursors[room]=it}}.toPersistentMap()
        }
        override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId,RoomKind>)=error("Unexpected directory")
        override suspend fun acceptStates(states: PersistentMap<RoomId,RoomSyncState>) {}
        override suspend fun acceptState(room: RoomId,state: RoomSyncState)=error("Unexpected state")
        override suspend fun unavailable(room: RoomId) {denied+=room}
        override suspend fun roomCursor(room: RoomId)=cursors[room] ?: RoomCursor()
        override suspend fun commitRoom(page: GroupEventPage,expected: RoomCursor)=error("Batch required")
        override suspend fun commitLiveRoom(page: GroupEventPage,expected: RoomCursor): Boolean {live++;return true}
    }
    private fun works(rooms: List<RoomId>)=rooms.map {RoomDirectoryWork(it,"revision",1,1,false,50)}.toPersistentList()
    private fun works(first: RoomId,second: RoomId?=null)=works(listOfNotNull(first,second))
    @Test fun `batch commit precedes a single exact progress report and per-room continuation remains independent`()=runTest {
        val s=Store();val wire=Wire {request -> when {
            request.hasGroupEventPullBatch() -> {
                assertEquals(setOf(a.value,b.value),request.groupEventPullBatch.roomsList.map {it.roomId}.toSet())
                assertTrue(request.groupEventPullBatch.roomsList.all {it.pageSize==32 && it.afterRoomSequence==0L})
                batch(result(a,page(a,50)),result(b,page(b,32,true)))
            }
            else -> {
                assertEquals(1,s.commits);assertEquals(mapOf(a to RoomCursor(50),b to RoomCursor(32)),s.cursors)
                Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList)).build()
            }
        }}
        val results=RoomSyncEngine(wire,s).synchronizeRoomBatch("scope",works(a,b))
        assertFalse(results.getValue(a).hasMore);assertTrue(results.getValue(b).hasMore)
        assertEquals(1,wire.calls.count {it.hasDeviceRoomProgressReport()})
    }
    @Test fun `all response identities and page budgets validate before any commit`()=runTest {
        val reads=persistentMapOf(a to RoomContentRead(RoomCursor(),1),b to RoomContentRead(RoomCursor(),1))
        val event=GroupEvent.newBuilder().setSourceEventId(UUID.randomUUID().toString()).setRoomSequence(1).setProjectionKind("room")
            .setPayload(ByteString.copyFromUtf8("""{"room_id":"${a.value}"}""")).build()
        val tooMany=page(a,2).toBuilder().addEvents(event).addEvents(event.toBuilder().setRoomSequence(2)).build()
        val invalid=listOf(batch(result(a,page(a))),batch(result(a,page(a)),result(a,page(a))),
            batch(result(a,page(b)),result(b,page(b))),batch(result(a,tooMany),result(b,page(b))),
            batch(GroupEventPageResult.newBuilder().setRoomId(a.value).build(),result(b,page(b))),
            batch(result(a,page(a,0,true)),result(b,page(b))),batch(result(a,page(a,-1)),result(b,page(b))),
            batch(result(a,page(a)),result(RoomId(UUID.randomUUID().toString()),page(b))))
        for(response in invalid) assertFailsWith<ClientFailure.Protocol> {RoomContentClient(Wire {response}).fetch(reads)}
    }
    @Test fun `size fallback preserves cursor and budget while denial never falls back`()=runTest {
        val wire=Wire {request -> if(request.hasGroupEventPullBatch()) batch(failure(a,"BATCH_PAGE_REQUIRES_SINGLE_PULL"),failure(b,"FORBIDDEN")) else {
            assertEquals(a.value,request.groupEventPull.roomId);assertEquals(7,request.groupEventPull.afterRoomSequence);assertEquals(3,request.groupEventPull.pageSize)
            Envelope.newBuilder().setGroupEventPage(page(a,10)).build()
        }}
        val response=RoomContentClient(wire).fetch(persistentMapOf(a to RoomContentRead(RoomCursor(7),3),b to RoomContentRead(RoomCursor(),4)))
        assertEquals(setOf(a),response.pages.keys);assertEquals(setOf(b),response.unavailable);assertEquals(2,wire.calls.size)
        val invalid=Wire {batch(failure(a,"BATCH_PAGE_REQUIRES_SINGLE_PULL"),result(b,page(a)))}
        assertFailsWith<ClientFailure.Protocol> {RoomContentClient(invalid).fetch(persistentMapOf(a to RoomContentRead(RoomCursor(),1),b to RoomContentRead(RoomCursor(),1)))}
        assertEquals(1,invalid.calls.size)
    }
    @Test fun `non-permanent forbidden and other room failures cannot commit valid siblings`()=runTest {
        for(error in listOf(failure(b,"FORBIDDEN",true),failure(b,"OVERLOADED",true),failure(b,"INTERNAL"))) {
            val s=Store();val wire=Wire {batch(result(a,page(a)),error)}
            assertFailsWith<GatewayFailure> {RoomSyncEngine(wire,s).synchronizeRoomBatch("scope",works(a,b))}
            assertEquals(0,s.commits);assertTrue(s.denied.isEmpty());assertEquals(1,wire.calls.size)
        }
    }
    @Test fun `storage failure emits no progress and bad receipt does not roll back committed content`()=runTest {
        val s=Store().apply {fail=true};val wire=Wire {if(it.hasGroupEventPullBatch()) batch(result(a,page(a))) else Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.getDefaultInstance()).build()}
        val engine=RoomSyncEngine(wire,s)
        assertFailsWith<IOException> {engine.synchronizeRoomBatch("scope",works(a))};assertEquals(1,wire.calls.size)
        s.fail=false;assertFailsWith<ClientFailure.Protocol> {engine.synchronizeRoomBatch("scope",works(a))}
        assertEquals(RoomCursor(1),s.cursors[a]);assertEquals(1,s.commits)
    }
    @Test fun `mixed denial commits with valid pages and reports only durable accessible rooms`()=runTest {
        val s=Store();val wire=Wire {if(it.hasGroupEventPullBatch()) batch(result(a,page(a)),failure(b,"FORBIDDEN")) else {
            assertEquals(setOf(b),s.denied);assertEquals(listOf(a.value),it.deviceRoomProgressReport.roomsList.map {r -> r.roomId})
            Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(it.deviceRoomProgressReport.roomsList)).build()
        }}
        val result=RoomSyncEngine(wire,s).synchronizeRoomBatch("scope",works(a,b))
        assertTrue(result.getValue(b).unavailable);assertEquals(1,s.commits)
    }
    @Test fun `sixteen-room sizing bounds total budget and preserves narrow gaps`()=runTest {
        val ids=(1..16).map {RoomId(UUID.randomUUID().toString())};val s=Store();s.cursors[ids.first()]=RoomCursor(49)
        val wire=Wire {if(it.hasGroupEventPullBatch()) {
            assertEquals(61,it.groupEventPullBatch.roomsList.sumOf {r -> r.pageSize})
            batch(*it.groupEventPullBatch.roomsList.map {r -> result(RoomId(r.roomId),page(RoomId(r.roomId),50))}.toTypedArray())
        } else Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(it.deviceRoomProgressReport.roomsList)).build()}
        RoomSyncEngine(wire,s).synchronizeRoomBatch("scope",works(ids))
        assertFailsWith<IllegalArgumentException> {RoomSyncEngine(wire,s).synchronizeRoomBatch("scope",works(ids+RoomId(UUID.randomUUID().toString())))}
    }
    @Test fun `batch reserves room engine against online commits and cancellation leaves no writes`()=runTest {
        val s=Store();val entered=CompletableDeferred<Unit>();val wire=Wire {entered.complete(Unit);awaitCancellation()}
        val engine=RoomSyncEngine(wire,s);val job=launch {engine.synchronizeRoomBatch("scope",works(a,b))};entered.await()
        assertFalse(engine.applyOnlineEvents(RealtimeSyncHint.Room(a,1)))
        job.cancelAndJoin();assertEquals(0,s.commits);assertEquals(0,s.live);assertEquals(1,wire.calls.size)
    }
    @Test fun `disjoint batches overlap two flights and the next starts when either finishes`()=runTest {
        val ids=(1..8).map {RoomId(UUID.randomUUID().toString())};val s=Store()
        val started=kotlinx.coroutines.channels.Channel<Int>(8)
        val releases=List(4) {CompletableDeferred<Unit>()};var active=0;var maximum=0;var next=0
        val wire=Wire {request -> if(request.hasGroupEventPullBatch()) {
            val index=next++;active++;maximum=maxOf(maximum,active);started.send(index)
            releases[index].await();active--
            batch(*request.groupEventPullBatch.roomsList.map {result(RoomId(it.roomId),page(RoomId(it.roomId),50))}.toTypedArray())
        } else Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList)).build()}
        val engine=RoomSyncEngine(wire,s);val result=async {engine.synchronizeRoomBatches("scope",works(ids))}
        assertEquals(0,started.receive());assertEquals(1,started.receive());runCurrent();assertTrue(started.tryReceive().isFailure)
        assertFalse(engine.applyOnlineEvents(RealtimeSyncHint.Room(ids.first(),50)))
        releases[1].complete(Unit);assertEquals(2,started.receive())
        releases[2].complete(Unit);assertEquals(3,started.receive())
        releases[0].complete(Unit);releases[3].complete(Unit)
        assertEquals(ids.toSet(),result.await().keys);assertEquals(2,maximum);assertEquals(4,s.commits)
        assertEquals(4,wire.calls.count {it.hasDeviceRoomProgressReport()})
        assertEquals(ids.toSet(),wire.calls.filter {it.hasGroupEventPullBatch()}.flatMap {it.groupEventPullBatch.roomsList}.map {RoomId(it.roomId)}.toSet())
    }
    @Test fun `a failed concurrent batch cancels its sibling and duplicate reservations fail before networking`()=runTest {
        val ids=(1..4).map {RoomId(UUID.randomUUID().toString())};val s=Store();val waiting=CompletableDeferred<Unit>();var cancelled=false
        val wire=Wire {request -> if(request.groupEventPullBatch.getRooms(0).roomId==ids.first().value) {
            waiting.complete(Unit);try {awaitCancellation()} finally {cancelled=true}
        } else {waiting.await();throw IOException("batch failed")}}
        val engine=RoomSyncEngine(wire,s)
        assertFailsWith<IOException> {engine.synchronizeRoomBatches("scope",works(ids))}
        assertTrue(cancelled);assertEquals(0,s.commits)
        val count=wire.calls.size
        assertFailsWith<IllegalArgumentException> {engine.synchronizeRoomBatches("scope",works(ids+ids.first()))}
        assertEquals(count,wire.calls.size)
    }

}
