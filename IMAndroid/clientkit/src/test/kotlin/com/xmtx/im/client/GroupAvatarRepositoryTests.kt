package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class GroupAvatarRepositoryTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val room=RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val wire by lazy { javaClass.getResourceAsStream("/group-avatar-swift.txt")!!.bufferedReader().useLines { lines -> Json.parseToJsonElement(lines.first { it.startsWith("presentation\t") }.substringAfter('\t')).jsonObject } }
    private fun presentation(room: RoomId=this.room,now: Long=0,revision: Long=5): GroupAvatarPresentation {
        val state=JsonObject(wire.resourceObject("state")+mapOf("roomID" to wireId(room.value),"revision" to JsonPrimitive(revision)))
        return GroupAvatarPresentationClient.decode(JsonObject(wire+("state" to state)),actor,device,room,now,now)
    }
    private fun fence()=GroupAvatarFence("epoch",0,1,true)
    @Test fun `same-room demand shares one request but a newly visible activation reauthorizes`()=runTest {
        val gate=CompletableDeferred<Unit>();var count=0
        val repository=GroupAvatarRepository(actor,device,{ count++;gate.await();presentation() },{fence()},backgroundScope,{testScheduler.currentTime*1_000_000})
        val a=repository.activate(room);val b=repository.activate(room)
        val first=async { repository.read(a) };val second=async { repository.read(b) };runCurrent()
        assertEquals(1,count);assertEquals(2,repository.diagnostics().waiting)
        first.cancelAndJoin();assertEquals(1,repository.diagnostics().waiting)
        gate.complete(Unit);assertEquals(5,second.await().state.revision)
        assertNull(repository.cached(a));assertNotNull(repository.cached(b));assertEquals(1,count)
        val c=repository.activate(room);assertNull(repository.cached(c));repository.read(c);assertEquals(2,count)
        repository.close()
    }
    @Test fun `frozen grants validate SQLite epoch before bytes even before a UI sync publication`()=runTest {
        var floor=fence();var version=5L
        val repository=GroupAvatarRepository(actor,device,{presentation(revision=version)},{floor},backgroundScope,{testScheduler.currentTime*1_000_000})
        val token=repository.activate(room);repository.read(token);val grant=repository.avatarReadGrant(token)!!
        assertEquals(ResourceHome.Room(room),grant.home);grant.requireValid()
        val invalidated=async(start=CoroutineStart.UNDISPATCHED) { repository.invalidations(token).first() }
        floor=floor.copy(generation="new",revision=6)
        assertFailsWith<AvatarAccessFailure> { grant.requireValid() };invalidated.await();assertNull(repository.cached(token))
        assertFailsWith<AvatarAccessFailure> { repository.read(token) }
        version=6;repository.read(token);assertNotNull(repository.avatarReadGrant(token))
        repository.deactivate(token);assertFailsWith<AvatarAccessFailure> { repository.read(token) };repository.close()
    }
    @Test fun `changed content revokes other visible pages while unchanged renewal cannot extend old grant`()=runTest {
        var version=5L
        val repository=GroupAvatarRepository(actor,device,{presentation(now=testScheduler.currentTime*1_000_000,revision=version)},{fence()},backgroundScope,{testScheduler.currentTime*1_000_000})
        val a=repository.activate(room);repository.read(a);val old=repository.avatarReadGrant(a)!!
        advanceTimeBy(1000)
        val b=repository.activate(room);repository.read(b);old.requireValid() // Same content, independent frozen deadline.
        val invalidated=async(start=CoroutineStart.UNDISPATCHED) { repository.invalidations(a).first() }
        version=6;val c=repository.activate(room);repository.read(c);invalidated.await()
        assertFailsWith<AvatarAccessFailure> { old.requireValid() };assertNull(repository.cached(a));assertNull(repository.cached(b))
        val fresh=repository.avatarReadGrant(c)!!;advanceTimeBy(300001);runCurrent()
        assertFailsWith<AvatarAccessFailure> { fresh.requireValid() };assertNull(repository.cached(c));repository.close()
    }
    @Test fun `cancelled physical IO retains both slots and queues new rooms fairly`()=runTest {
        val rooms=(1..4).map { RoomId("00000000-0000-0000-0000-${it.toString().padStart(12,'0')}") }
        val gates=rooms.associateWith { CompletableDeferred<Unit>() };val starts=mutableListOf<RoomId>()
        val repository=GroupAvatarRepository(actor,device,{ r -> starts.add(r);withContext(NonCancellable) { gates.getValue(r).await() };presentation(r) },{fence()},backgroundScope,{0})
        val tokens=rooms.map { repository.activate(it) }
        val reads=tokens.map { async { runCatching { repository.read(it) } } };runCurrent();assertEquals(rooms.take(2),starts)
        reads[0].cancelAndJoin();runCurrent();assertEquals(2,repository.diagnostics().flights)
        gates.getValue(rooms[0]).complete(Unit);runCurrent();assertEquals(rooms.take(3),starts)
        gates.getValue(rooms[1]).complete(Unit);runCurrent();assertEquals(rooms,starts)
        assertEquals(rooms[1],reads[1].await().getOrThrow().state.room)
        val closing=async { repository.close() };runCurrent();assertFalse(closing.isCompleted)
        gates.getValue(rooms[2]).complete(Unit);gates.getValue(rooms[3]).complete(Unit);closing.await()
        reads.drop(2).forEach { assertTrue(it.await().isFailure) };assertEquals(0,repository.diagnostics().flights)
    }
    @Test fun `denial revokes existing authority with bounded cooldown but transient failure is not cached`()=runTest {
        var calls=0;var status=200
        val repository=GroupAvatarRepository(actor,device,{ calls++;if(status!=200) throw ClientFailure.Http(status,retryAfter="40");presentation(now=testScheduler.currentTime*1_000_000) },{fence()},backgroundScope,{testScheduler.currentTime*1_000_000},{0})
        val a=repository.activate(room);repository.read(a);val grant=repository.avatarReadGrant(a)!!
        val b=repository.activate(room);status=503;assertFailsWith<ClientFailure.Http> { repository.read(b) };grant.requireValid()
        status=200;repository.read(b);assertEquals(3,calls)
        val c=repository.activate(room);status=403;assertFailsWith<ClientFailure.Http> { repository.read(c) };assertFailsWith<AvatarAccessFailure> { grant.requireValid() }
        status=200;assertFailsWith<ClientFailure.Http> { repository.read(c) };assertEquals(4,calls)
        advanceTimeBy(30001);repository.read(c);assertEquals(5,calls);repository.close()
    }
    @Test fun `late responses after epoch switch cannot authorize fresh activations and expired URLs renew only within budget`()=runTest {
        var gate=CompletableDeferred<Unit>();var calls=0
        val repository=GroupAvatarRepository(actor,device,{ calls++;withContext(NonCancellable) { gate.await() };presentation(now=testScheduler.currentTime*1_000_000) },{fence()},backgroundScope,{testScheduler.currentTime*1_000_000})
        val old=repository.activate(room);val pending=async { runCatching { repository.read(old) } };runCurrent();repository.endAllActivations()
        val token=repository.activate(room);val fresh=async { repository.read(token) };runCurrent();assertEquals(1,calls)
        gate.complete(Unit);fresh.await();assertTrue(pending.await().isFailure);assertEquals(2,calls)
        val previous=repository.cached(token)!!.avatar
        repository.refreshAvatarReadGrant(token,previous);assertEquals(3,calls)
        assertFailsWith<ClientFailure.Http> { repository.refreshAvatarReadGrant(token,previous) };assertEquals(3,calls)
        advanceTimeBy(2501);repository.refreshAvatarReadGrant(token,previous);assertEquals(4,calls)
        repository.close()
    }
    @Test fun `bounded activations and pending rooms reject overload without growing work`()=runTest {
        val repository=GroupAvatarRepository(actor,device,{ awaitCancellation() },{fence()},backgroundScope,{0})
        val tokens=(1..256).map { repository.activate(RoomId("00000000-0000-0000-0000-${it.toString().padStart(12,'0')}")) }
        assertFailsWith<GroupAvatarOverloaded> { repository.activate(room) }
        val pending=tokens.take(129).map { async { runCatching { repository.read(it) } } };runCurrent()
        assertEquals(128,repository.diagnostics().rooms);assertEquals(2,repository.diagnostics().flights)
        assertIs<GroupAvatarOverloaded>(pending.last().await().exceptionOrNull())
        repository.close();pending.forEach { assertTrue(it.await().isFailure) };assertEquals(0,repository.diagnostics().waiting)
    }
    @Test fun `renewal keeps original byte deadline and descriptor cache stays within its byte budget`()=runTest {
        val repository=GroupAvatarRepository(actor,device,{ r -> presentation(r,now=testScheduler.currentTime*1_000_000).copy(wireBytes=64*1024) },{fence()},backgroundScope,{testScheduler.currentTime*1_000_000})
        val a=repository.activate(room);repository.read(a);val old=repository.avatarReadGrant(a)!!
        advanceTimeBy(1000);val b=repository.activate(room);repository.read(b);val renewed=repository.avatarReadGrant(b)!!
        advanceTimeBy(299001);assertFailsWith<AvatarAccessFailure> { old.requireValid() };renewed.requireValid()
        repeat(40) { i -> val r=RoomId("00000000-0000-0000-0000-${(i+1).toString().padStart(12,'0')}");repository.read(repository.activate(r)) }
        assertEquals(32,repository.diagnostics().cached);assertEquals(2*1024*1024,repository.diagnostics().bytes)
        assertFailsWith<AvatarAccessFailure> { renewed.requireValid() };repository.close()
    }
    @Test fun `malformed throttle completes every waiter and authority changing during IO rejects the reply`()=runTest {
        var floor=fence();var mode=0;var calls=0
        val repository=GroupAvatarRepository(actor,device,{
            calls++;if(mode==0) throw ClientFailure.Http(429,retryAfter="invalid")
            if(mode==1) floor=floor.copy(generation="changed")
            presentation(now=testScheduler.currentTime*1_000_000)
        },{floor},backgroundScope,{testScheduler.currentTime*1_000_000})
        val token=repository.activate(room);assertFailsWith<ClientFailure.Http> { repository.read(token) }
        assertEquals(0,repository.diagnostics().waiting);assertFailsWith<ClientFailure.Http> { repository.read(token) };assertEquals(1,calls)
        advanceTimeBy(1001);mode=1;assertFailsWith<AvatarAccessFailure> { repository.read(token) };assertNull(repository.cached(token))
        mode=2;repository.read(token);val grant=repository.avatarReadGrant(token)!!
        floor=floor.copy(generation="revoked",authorized=false);repository.reconcile();assertFailsWith<AvatarAccessFailure> { grant.requireValid() }
        repository.close()
    }
    @Test fun `invalidation payload admits only logical facts and binds outer room and sequence`() {
        val payload=buildJsonObject { put("event_type","group.avatar_changed");put("room_id",room.value);put("revision",5);put("room_sequence",8);put("server_created_at_ms",1000) }
        val effect=GroupAvatarEffect.decode("event",payload,room,8);assertEquals("06dbdf1c6d62c53ae5d6a6ccc03b65a0a7980ee02287e1cf2360e9787639f63d",effect.digest)
        for(extra in listOf("media_id" to JsonPrimitive("private"),"revision" to JsonPrimitive("5"),"room_sequence" to JsonPrimitive(-1),"server_created_at_ms" to JsonPrimitive(-1)))
            assertFails { GroupAvatarEffect.decode("event",JsonObject(payload+extra),room,8) }
        assertFails { GroupAvatarEffect.decode("event",payload,RoomId(actor.value),8) }
        assertFails { GroupAvatarEffect.decode("event",payload,room,9) }
    }
    @Test fun `account close drains in-progress durable fence reads before the backing database may close`()=runTest {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var block=false
        val repository=GroupAvatarRepository(actor,device,{presentation()},{
            if(block) { entered.complete(Unit);withContext(NonCancellable) { release.await() } };fence()
        },backgroundScope,{0})
        val token=repository.activate(room);repository.read(token);val grant=repository.avatarReadGrant(token)!!
        block=true;val borrowing=async { runCatching { grant.requireValid() } };entered.await()
        val closing=async { repository.close() };runCurrent();assertFalse(closing.isCompleted)
        release.complete(Unit);closing.await();assertTrue(borrowing.await().isFailure)
    }
    @Test fun `parent cancellation before worker scheduling still drains every registered slot`()=runTest {
        val parent=CoroutineScope(coroutineContext+Job())
        val repository=GroupAvatarRepository(actor,device,{awaitCancellation()},{fence()},parent,{0})
        val token=repository.activate(room);val pending=async(start=CoroutineStart.UNDISPATCHED) { runCatching { repository.read(token) } }
        parent.cancel();repository.close();assertTrue(pending.await().isFailure);assertEquals(0,repository.diagnostics().flights)
    }
}
