package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class ProfilePresentationTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val target = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val device = DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val room = RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    private val keys = persistentListOf(ProfileKey(target,ProfileContext.Relationship),ProfileKey(target,ProfileContext.DirectConversation),
        ProfileKey(target,ProfileContext.Room(room)),ProfileKey(target,ProfileContext.GroupJoinReview(room)))
    private val lines get() = javaClass.getResourceAsStream("/profile-presentations-swift.txt")!!.bufferedReader().readLines()
    private fun wire(index: Int) = Json.parseToJsonElement(lines[index]).jsonObject
    private fun decode(body: JsonObject = wire(1),requested: PersistentList<ProfileKey> = keys,started: Long = 100,received: Long = 100) =
        ProfilePresentationClient.decode(requested,body,actor,device,started,received)
    private fun available() = decode().filterIsInstance<ProfileReadResult.Available>().first()
    private fun replaced(body: JsonObject,old: String,new: String) = Json.parseToJsonElement(body.toString().replace(old,new)).jsonObject

    @Test fun `Swift four contexts and authorized name priorities match`() = runTest {
        assertEquals(wire(0),ProfileReadBatch.payload(keys))
        val transport = object: AuthenticatedTransport {
            override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse {
                assertEquals("/v2/profile-presentations/batch",path);assertEquals(wire(0),payload);assertEquals(2097152L,maximumBytes)
                return EdgeResponse(200,wire(1))
            }
        }
        val result = ProfilePresentationClient(transport,actor,device,{100}).read(keys)
        assertEquals(keys,result.map { it.key });val profiles = result.map { (it as ProfileReadResult.Available).profile }
        assertTrue(profiles.all { it.displayName() == "私人备注" })
        assertEquals("群内昵称",profiles[2].displayName(false));assertEquals("好友 B",profiles[0].displayName(false))
        assertEquals(11,profiles[2].groupName!!.revision)
        val statuses = decode(wire(2));assertIs<ProfileReadResult.Retryable>(statuses[0]);assertIs<ProfileReadResult.Unavailable>(statuses[1])
        for((index,name) in listOf("资料暂不可用","已注销用户","受限用户").withIndex()) {
            val hidden = decode(wire(index+3),persistentListOf(keys[0])).single() as ProfileReadResult.Available
            assertEquals(name,hidden.profile.displayName());assertNull(hidden.profile.view.identity);assertNull(hidden.profile.alias)
        }
    }

    @Test fun `bounded selection distinguishes room review and each direct target`() {
        val rooms = (1..8).map { ProfileKey(target,ProfileContext.Room(RoomId("00000000-0000-0000-0000-${it.toString().padStart(12,'0')}"))) }.toPersistentList()
        assertEquals(8,ProfileReadBatch.select(rooms.add(keys[1]).add(keys[0])).count { it.context != ProfileContext.Relationship })
        assertEquals(keys[0],ProfileReadBatch.select(rooms.add(keys[1]).add(keys[0])).last())
        assertFails { ProfileReadBatch.payload(rooms.add(keys[1])) };assertFails { ProfileReadBatch.payload(keys.add(keys[0])) }
        assertFails { ProfileReadBatch.payload(persistentListOf()) };assertEquals(0,ProfileReadBatch.select(keys,0).size)
        assertEquals(4,ProfileReadBatch.select(keys).size)
        val directs = rooms.map { ProfileKey(UserId((it.context as ProfileContext.Room).room.value),ProfileContext.DirectConversation) }.toPersistentList()
        assertEquals(8,ProfileReadBatch.select(directs.add(keys[1])).size)
        assertFails { ProfileReadBatch.payload(rooms.take(7).toPersistentList().add(keys[2]).add(keys[3])) }
    }

    @Test fun `leases bind actor device key values and independent authority revisions`() {
        for(pair in listOf(
            "\"actorUserID\":{\"rawValue\":\"${actor.value}\"}" to "\"actorUserID\":{\"rawValue\":\"${target.value}\"}",
            "\"deviceID\":{\"rawValue\":\"${device.value}\"}" to "\"deviceID\":{\"rawValue\":\"${actor.value}\"}",
            "\"profileRevision\":3" to "\"profileRevision\":4",
            "\"visibilityRevision\":5" to "\"visibilityRevision\":0",
            "\"contextRevision\":17" to "\"contextRevision\":18",
            "\"membershipRevision\":17" to "\"membershipRevision\":0",
            "\"permissionRevision\":19" to "\"permissionRevision\":-1",
            "\"controlSequence\":13" to "\"controlSequence\":\"13\"",
            "\"revision\":3" to "\"revision\":9223372036854775808",
            "\"validUntilUnixMilliseconds\":1700000300000" to "\"validUntilUnixMilliseconds\":1700000300001",
            "\"serverNowUnixMilliseconds\":1700000001000" to "\"serverNowUnixMilliseconds\":1699999999999"
        )) assertFails("Accepted invalid mutation $pair") { decode(replaced(wire(1),pair.first,pair.second)) }
        assertFails { decode(requested = keys.set(0,ProfileKey(actor,ProfileContext.Relationship))) }
        val results = wire(1).getValue("results").jsonArray
        assertFails { decode(JsonObject(wire(1) + ("results" to JsonArray(results.dropLast(1)+results.first())))) }
        assertEquals(keys,decode(JsonObject(wire(1) + ("results" to JsonArray(results.reversed())))).map { it.key })
    }

    @Test fun `nonactive profiles and private fields cannot escape their owner or room`() {
        val body = wire(1)
        for(pair in listOf(
            "\"state\":\"active\"" to "\"state\":\"hidden\"",
            "\"ownerUserID\":{\"rawValue\":\"${actor.value}\"}" to "\"ownerUserID\":{\"rawValue\":\"${target.value}\"}",
            "\"remarkName\":\"私人备注\"" to "\"remarkName\":\" 私人备注 \"",
            "\"groupNickname\":\"群内昵称\"" to "\"groupNickname\":\"\"",
            "\"rawValue\":\"friend_b\"" to "\"rawValue\":\"@FRIEND_B\"",
            "\"accountKind\":\"regular\"" to "\"accountKind\":\"owner\""
        )) assertFails { decode(replaced(body,pair.first,pair.second)) }
        val group = (decode()[2] as ProfileReadResult.Available).profile
        assertFails { group.copy(groupName = group.groupName!!.copy(room = RoomId(actor.value))) }
        assertFails { group.copy(lease = group.lease.copy(key = keys[3])) }
    }

    @Test fun `request duration reduces monotonic permission including nanoTime wrap`() {
        val grant = decode(started = 100,received = 100+2_000_000_000).first() as ProfileReadResult.Available
        assertEquals(299_000_000_100,grant.deadlineNanos)
        assertFalse(grant.valid(grant.deadlineNanos));assertTrue(grant.valid(grant.deadlineNanos-1))
        assertTrue(decode(received = 100+299_000_000_000).all { it is ProfileReadResult.Retryable })
        val wrappedStart = Long.MAX_VALUE-10
        val wrapped = decode(started = wrappedStart,received = wrappedStart+100).first() as ProfileReadResult.Available
        assertTrue(wrapped.valid(wrappedStart+100));assertFails { decode(started = 200,received = 100) }
    }

    @Test fun `scope revokes on invalidation interest loss close and response expiry`() = runTest {
        var now = 100L;var entered = CompletableDeferred<Unit>();var released = CompletableDeferred<Unit>()
        val reader = ProfilePresentationReading { requested -> entered.complete(Unit);released.await();decode().filter { it.key in requested }.toPersistentList() }
        val scope = ProfilePresentationScope(actor,device,reader,{now});scope.interests(persistentListOf(keys[0]))
        val first = async { scope.refresh() };entered.await();scope.invalidate(keys[0]);released.complete(Unit)
        assertTrue(first.await().profiles.isEmpty())
        entered = CompletableDeferred();released = CompletableDeferred();val second = async { scope.refresh() };entered.await();released.complete(Unit)
        assertEquals(1,second.await().profiles.size)
        now = available().deadlineNanos;assertTrue(scope.snapshot().profiles.isEmpty());assertTrue(keys[0] in scope.snapshot().retryable)
        now = 100;entered = CompletableDeferred();released = CompletableDeferred();val third = async { scope.refresh() };entered.await()
        scope.interests(persistentListOf());scope.interests(persistentListOf(keys[0]));released.complete(Unit);assertTrue(third.await().profiles.isEmpty())
        entered = CompletableDeferred();released = CompletableDeferred();val fourth = async { scope.refresh() };entered.await();scope.close();released.complete(Unit)
        assertTrue(fourth.await().profiles.isEmpty());assertFails { scope.refresh() }
    }

    @Test fun `denial merges crossed floors and only a strictly newer authority may restore display`() = runTest {
        val initial = decode()[2] as ProfileReadResult.Available;val key = initial.key
        var result: ProfileReadResult = initial
        val scope = ProfilePresentationScope(actor,device,ProfilePresentationReading { persistentListOf(result) },{100})
        scope.interests(persistentListOf(key));scope.refresh();assertEquals(1,scope.snapshot().profiles.size)
        val old = initial.profile.lease.authority
        result = ProfileReadResult.Unavailable(key,old.copy(control = old.control-1));scope.refresh();assertEquals(1,scope.snapshot().profiles.size)
        result = ProfileReadResult.Unavailable(key,old.copy(control = old.control+1,membership = old.membership-1));scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        fun grant(authority: ProfileAuthority) = initial.copy(profile = initial.profile.copy(lease = initial.profile.lease.copy(authority = authority,contextRevision = authority.membership)))
        result = grant(old.copy(control = old.control+1));scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        result = ProfileReadResult.Retryable(key);scope.refresh();assertTrue(key in scope.snapshot().unavailable)
        result = grant(old.copy(control = old.control+2));scope.refresh();assertEquals(1,scope.snapshot().profiles.size);assertTrue(scope.snapshot().unavailable.isEmpty())
    }

    @Test fun `profile alias and nickname floors survive hiding and reject same revision changes`() = runTest {
        val initial = decode()[2] as ProfileReadResult.Available;val key = initial.key
        var result = initial
        val scope = ProfilePresentationScope(actor,device,ProfilePresentationReading { persistentListOf(result) },{100})
        scope.interests(persistentListOf(key));scope.refresh();scope.invalidate(key)
        result = initial.copy(profile = initial.profile.copy(alias = initial.profile.alias!!.copy(name = "同版本改名")))
        scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        val hidden = initial.profile.copy(view = initial.profile.view.copy(identity = null,state = ProfileState.Hidden),groupName = null,alias = null)
        result = initial.copy(profile = hidden);scope.refresh();assertEquals(ProfileState.Hidden,scope.snapshot().profiles.getValue(key).profile.view.state)
        scope.invalidate(key);result = initial.copy(profile = initial.profile.copy(alias = null,groupName = null));scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        scope.invalidate(key,minimumProfile = 4,minimumAlias = 8,minimumGroupName = 12);result = initial;scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        result = initial.copy(profile = initial.profile.copy(view = initial.profile.view.copy(revision = 4),lease = initial.profile.lease.copy(profileRevision = 4),
            alias = initial.profile.alias!!.copy(revision = 8),groupName = initial.profile.groupName!!.copy(revision = 12)))
        scope.refresh();assertEquals(1,scope.snapshot().profiles.size)
    }

    @Test fun `batch validation is atomic and auth failure clears live display`() = runTest {
        var response = decode();var failure: Exception? = null
        val scope = ProfilePresentationScope(actor,device,ProfilePresentationReading { failure?.let { throw it };response },{100})
        scope.interests(keys);scope.refresh();assertEquals(4,scope.snapshot().profiles.size);scope.invalidateAll()
        response = response.set(3,(response[3] as ProfileReadResult.Available).let { it.copy(profile = it.profile.copy(lease = it.profile.lease.copy(device = DeviceId(actor.value)))) })
        assertFails { scope.refresh() };assertTrue(scope.snapshot().profiles.isEmpty())
        response = decode();scope.refresh();failure = ClientFailure.Http(403);assertFailsWith<ClientFailure.Http> { scope.refresh() };assertTrue(scope.snapshot().profiles.isEmpty())
        failure = null;scope.refresh();failure = ClientFailure.SignedOut();assertFailsWith<ClientFailure.SignedOut> { scope.refresh() };assertTrue(scope.snapshot().profiles.isEmpty())
    }

    @Test fun `scope bounds visible demand and serializes concurrent refreshes without retrying temporary failures`() = runTest {
        val interests = (1..128).map { ProfileKey(UserId("00000000-0000-0000-0000-${it.toString().padStart(12,'0')}"),ProfileContext.Relationship) }.toPersistentList()
        val entered = CompletableDeferred<Unit>();val release = CompletableDeferred<Unit>();val sizes = mutableListOf<Int>()
        var active = 0;var maximum = 0
        val scope = ProfilePresentationScope(actor,device,ProfilePresentationReading { batch ->
            active++;maximum = maxOf(maximum,active);sizes.add(batch.size);entered.complete(Unit)
            release.await();active--;batch.map { ProfileReadResult.Retryable(it) }.toPersistentList()
        },{100})
        scope.interests(interests);assertFails { scope.interests(interests.add(keys[0])) }
        val first = async { scope.refresh() };entered.await();val second = async { scope.refresh() }
        yield();assertEquals(listOf(100),sizes);release.complete(Unit);first.await();second.await()
        assertEquals(listOf(100,28,100,28),sizes);assertEquals(1,maximum)
        assertEquals(128,scope.snapshot().retryable.size);assertTrue(scope.snapshot().unavailable.isEmpty())
    }

    @Test fun `HTTP backpressure is preserved and cancelled noncooperative replies cannot publish`() = runTest {
        var count = 0
        val throttled = object: AuthenticatedTransport {
            override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse {
                count++;return EdgeResponse(429,buildJsonObject {},"23")
            }
        }
        val error = assertFailsWith<ClientFailure.Http> { ProfilePresentationClient(throttled,actor,device).read(keys) }
        assertEquals("23",error.retryAfter);assertEquals(1,count)
        val entered = CompletableDeferred<Unit>();val release = CompletableDeferred<Unit>()
        val reader = ProfilePresentationReading { withContext(NonCancellable) { entered.complete(Unit);release.await();decode() } }
        val scope = ProfilePresentationScope(actor,device,reader,{100});scope.interests(keys)
        val request = async { scope.refresh() };entered.await();request.cancel();release.complete(Unit)
        assertFailsWith<CancellationException> { request.await() };assertTrue(scope.snapshot().profiles.isEmpty());scope.close()
    }
}
