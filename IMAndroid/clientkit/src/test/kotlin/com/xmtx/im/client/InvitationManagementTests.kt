package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class InvitationManagementTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val invite = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private val secret = InvitationSecret("A".repeat(43))
    private val store = MemoryInvitations()
    private fun controller(api: AuthenticatedTransport, manage: Boolean = false, mono: () -> Long = { 0 }): InvitationManagement {
        val client = InvitationClient(api)
        return InvitationManagement(if(manage) room else null,client,InvitationDirectory(api),InvitationService(actor,client,store,MemoryInviteSecrets(), { 1000 },mono),store,mono)
    }
    private fun preview() = buildJsonObject {
        put("invite_id",invite);put("room_id",room.value);put("room_title","群邀请");put("expires_at_ms",300000);put("is_already_member",false)
    }
    private fun link() = buildJsonObject {
        put("invite_id",invite);put("room_id",room.value);put("room_title","群邀请");put("token",secret.rawValue);put("state","active")
        put("maximum_approved_uses",5);put("approved_use_count",0);put("created_at_ms",1000);put("expires_at_ms",300000)
    }
    private fun edge(answer: suspend (String,JsonObject?) -> EdgeResponse) = object : AuthenticatedTransport {
        override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long) = answer(path,payload)
        override suspend fun requestWithQuery(path: String, query: Map<String,String>, maximumBytes: Long) = answer(path,null)
    }
    private fun answer(path: String) = EdgeResponse(200, when {
        path.endsWith("baseline") -> buildJsonObject { put("roomID",wireId(room.value));put("membershipRevision",7) }
        path == "/v2/group-invites" -> buildJsonObject { put("items",JsonArray(listOf(link()))) }
        path == "/v2/group-join-requests" -> buildJsonObject { put("items",JsonArray(emptyList())) }
        else -> preview()
    })
    @Test fun `editing input fences delayed preview and clears invalid previous invitation`() = runTest {
        val gate = CompletableDeferred<Unit>(); var delayed = true
        val api = edge { path,_ -> if(delayed) gate.await(); answer(path) }
        val page = controller(api)
        val pending = launch { page.preview(secret.rawValue) }; runCurrent()
        page.inputChanged(); gate.complete(Unit); pending.join(); assertNull(page.state.value.preview)
        delayed = false; page.preview(secret.rawValue); assertNotNull(page.state.value.preview)
        page.submit("申请"); assertNotNull(page.state.value.prompt)
        page.preview("bad"); assertNull(page.state.value.preview); assertNull(page.state.value.prompt)
        page.confirm(); assertTrue(store.records.isEmpty())
    }
    @Test fun `preview rejects malformed room identity and nonpositive expiry`() = runTest {
        for((field,value) in listOf("room_id" to JsonPrimitive("not-a-uuid"),"expires_at_ms" to JsonPrimitive(0))) {
            val bad = JsonObject(preview().toMutableMap().apply { put(field,value) })
            val page = controller(edge { _,_ -> EdgeResponse(200,bad) })
            page.preview(secret.rawValue); assertNull(page.state.value.preview); assertNotNull(page.state.value.error)
        }
    }
    @Test fun `permission loss clears bearer links request authority and confirmation`() = runTest {
        var permitted = true; val api = edge { path,_ -> if(permitted) answer(path) else EdgeResponse(403,buildJsonObject {}) }
        val page = controller(api,true); page.refresh(); assertEquals(1,page.state.value.links.size)
        page.create(); assertNotNull(page.state.value.prompt)
        permitted = false; page.refresh()
        assertTrue(page.state.value.links.isEmpty());assertTrue(page.state.value.requests.isEmpty());assertNull(page.state.value.revision);assertNull(page.state.value.prompt)
        page.confirm();assertTrue(store.records.isEmpty())
    }
    @Test fun `stale membership observation and expired confirmation cannot submit`() = runTest {
        var nanos = 0L; val api = edge { path,_ -> answer(path) }; val page = controller(api,true) { nanos }
        page.refresh(); nanos = 115000000001; page.create(); assertNull(page.state.value.prompt)
        page.refresh(); page.create(); assertNotNull(page.state.value.prompt)
        nanos += 30000000001; page.confirm(); assertTrue(store.records.isEmpty())
    }
    @Test fun `closing page erases authorized presentation and rejects late reads`() = runTest {
        val gate = CompletableDeferred<Unit>(); var delayed = false
        val api = edge { path,_ -> if(delayed) gate.await(); answer(path) }; val page = controller(api,true)
        page.refresh(); assertEquals(1,page.state.value.links.size)
        delayed = true; val request = launch { page.refresh() }; runCurrent(); page.close(); gate.complete(Unit); request.join()
        assertEquals(InvitationManagementState(),page.state.value);page.create(); assertNull(page.state.value.prompt)
    }
    @Test fun `first observation of completed decision refreshes the request directory once`() = runTest {
        var directories=0
        val page=controller(edge {path,_ -> if(path=="/v2/group-join-requests") directories++;answer(path)},true)
        page.refresh();assertEquals(1,directories)
        val intent=InvitationIntent(actor,room,"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            InvitationAction.Decide("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",false,7),300000)
        store.records=kotlinx.collections.immutable.persistentListOf(InvitationWork(intent,"test",InvitationStatus.Committed))
        page.tick();assertEquals(2,directories)
        page.tick();assertEquals(2,directories)
    }
    @Test fun `applicant key is scoped to review authority and never relationship or membership`() {
        val request=GroupJoinRequest("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",invite,room,actor,null,"pending",null,1000,null)
        assertEquals(ProfileKey(actor,ProfileContext.GroupJoinReview(room)),request.presentationKey)
        assertNotEquals(ProfileKey(actor,ProfileContext.Relationship),request.presentationKey)
        assertNotEquals(ProfileKey(actor,ProfileContext.Room(room)),request.presentationKey)
    }

    @Test fun `completion during a directory read queues a fresh read after the old response`() = runTest {
        var directories=0;var delayRead=false;val gate=CompletableDeferred<Unit>()
        val page=controller(edge {path,_ ->
            val response=answer(path)
            if(path=="/v2/group-join-requests") {directories++;if(delayRead) gate.await()}
            response
        },true)
        page.refresh();assertEquals(1,directories)
        delayRead=true;val reading=launch {page.refresh()};runCurrent();assertTrue(page.state.value.loading)
        val intent=InvitationIntent(actor,room,"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            InvitationAction.Decide("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",false,7),300000)
        store.records=kotlinx.collections.immutable.persistentListOf(InvitationWork(intent,"test",InvitationStatus.Committed))
        page.tick();assertEquals(2,directories)
        delayRead=false;gate.complete(Unit);reading.join()
        page.tick();assertEquals(3,directories)
        page.tick();assertEquals(3,directories)
    }

}
