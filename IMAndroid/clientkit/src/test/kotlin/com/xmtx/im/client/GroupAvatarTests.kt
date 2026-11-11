package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class GroupAvatarTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val room=RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val fixtures by lazy { javaClass.getResourceAsStream("/group-avatar-swift.txt")!!.bufferedReader().useLines { lines -> lines.associate { it.substringBefore('\t') to Json.parseToJsonElement(it.substringAfter('\t')).jsonObject } } }
    private fun wire(key: String)=fixtures.getValue(key)
    private fun command(kind: String="set")=GroupAvatarCommand("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",room,4,
        if(kind=="set") GroupAvatarMutation.Set("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD") else GroupAvatarMutation.Remove)
    private class Transport: AuthenticatedTransport {
        var response=EdgeResponse(200,buildJsonObject {});var path="";var payload: JsonObject?=null;var bound=0L;var calls=0;var replay=true
        override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse {
            this.path=path;this.payload=payload;bound=maximumBytes;calls++;return response
        }
        override suspend fun requestWithoutReplay(path: String,payload: JsonObject,maximumBytes: Long): EdgeResponse { replay=false;return request(path,payload,maximumBytes=maximumBytes) }
    }
    @Test fun `Swift frozen commands and all submission recovery branches bind exact identities`()=runTest {
        val transport=Transport();val client=GroupAvatarCommandClient(transport,actor,device)
        for(kind in listOf("set","remove")) {
            val command=command(kind);assertEquals(wire(kind),command.payload());assertEquals(command,GroupAvatarCommand.decode(wire(kind)))
            for((outcome,status) in listOf("committed" to 200,"revisionConflict" to 409,"idempotencyConflict" to 409,"resourceUnavailable" to 422,"forbidden" to 403)) {
                transport.response=EdgeResponse(status,wire("$kind-$outcome"));val result=client.submit(command)
                assertEquals(command,result.command);assertEquals(command.payload(),transport.payload);assertFalse(transport.replay)
                assertEquals("/v2/rooms/${room.value}/avatar",transport.path);assertEquals(16384L,transport.bound)
                if(result.outcome is GroupAvatarOutcome.Committed) assertEquals(GroupAvatarState.decode(wire(kind+"State")),result.outcome.change.state)
            }
            for(action in GroupAvatarRecoveryAction.entries) {
                val request=GroupAvatarRecoveryRequest(command,action);assertEquals(wire("$kind-${action.wire}"),request.payload())
                for(resultKind in listOf("committed","closed","idempotencyConflict")+(if(action==GroupAvatarRecoveryAction.Query) listOf("unresolved") else emptyList())) {
                    transport.response=EdgeResponse(200,wire("$kind-${action.wire}-$resultKind"));transport.replay=true
                    val result=client.recover(request);assertEquals(request,result.request);assertEquals(request.payload(),transport.payload)
                    assertEquals("/v2/rooms/${room.value}/avatar/recovery",transport.path);assertFalse(transport.replay);assertEquals(16384L,transport.bound)
                }
            }
        }
    }
    @Test fun `unrelated and corrupt receipts never become completion evidence`() {
        val original=wire("set-committed")
        val changes=listOf("actorUserID" to wireId(device.value),"deviceID" to wireId(actor.value),"command" to command().copy(revision=5).payload(),
            "command" to command().copy(operation=actor.value).payload(),"command" to command().copy(room=RoomId(actor.value)).payload(),"command" to command("remove").payload())
        for(change in changes) assertFails { GroupAvatarCommandClient.decodeSubmission(EdgeResponse(200,JsonObject(original+change)),actor,device,command()) }
        for((from,to) in listOf("\"revision\":5" to "\"revision\":4","\"revision\":5" to "\"revision\":6","\"roomSequence\":9" to "\"roomSequence\":0",
            "\"expectedRevision\":4" to "\"expectedRevision\":\"4\"","\"expectedRevision\":4" to "\"expectedRevision\":9223372036854775808")) {
            assertTrue(original.toString().contains(from));assertFails { GroupAvatarCommandClient.decodeSubmission(EdgeResponse(200,Json.parseToJsonElement(original.toString().replace(from,to)).jsonObject),actor,device,command()) }
        }
        assertFails { GroupAvatarCommandClient.decodeSubmission(EdgeResponse(409,original),actor,device,command()) }
        assertFails { GroupAvatarState(room,command().mutation.mediaId,0) }
        assertFails { GroupAvatarChange(GroupAvatarState(room,null,Long.MAX_VALUE),1,0).boundTo(command("remove").copy(revision=Long.MAX_VALUE)) }
    }
    @Test fun `close proof must echo action and cannot claim unresolved`() {
        val request=GroupAvatarRecoveryRequest(command(),GroupAvatarRecoveryAction.CloseIfAbsent)
        assertFails { GroupAvatarCommandClient.decodeRecovery(wire("set-query-closed"),actor,device,request) }
        val invalid=JsonObject(wire("set-closeIfAbsent-closed")+("result" to buildJsonObject { put("unresolved",buildJsonObject {}) }))
        assertFails { GroupAvatarCommandClient.decodeRecovery(invalid,actor,device,request) }
        assertFails { GroupAvatarCommandClient.decodeRecovery(wire("set-closeIfAbsent-committed"),actor,device,request.copy(command=command("remove"))) }
    }
    @Test fun `HTTP hints preserve uncertainty and retry delay without automatic resubmission`()=runTest {
        val transport=Transport();val client=GroupAvatarCommandClient(transport,actor,device)
        for(status in listOf(401,403,410,429,503)) {
            transport.response=EdgeResponse(status,buildJsonObject {},"120")
            val before=transport.calls
            val failure=assertFailsWith<ClientFailure.Http> { client.submit(command()) };assertEquals(status,failure.status);assertEquals("120",failure.retryAfter);assertEquals(before+1,transport.calls)
            assertFailsWith<ClientFailure.Http> { client.recover(GroupAvatarRecoveryRequest(command(),GroupAvatarRecoveryAction.CloseIfAbsent)) }
        }
    }
    @Test fun `Swift group presentation uses independent monotonic byte and display expiry`()=runTest {
        var clock=10_000_000L;val transport=Transport();transport.response=EdgeResponse(200,wire("presentation"))
        val client=GroupAvatarPresentationClient(transport,actor,device) { clock.also { clock+=1_000_000_000 } }
        val live=client.read(room);assertEquals(300_010_000_000,live.deadlineNanos);assertEquals(120_010_000_000,live.downloadDeadlineNanos)
        assertEquals(2,live.resourceGeneration);assertEquals(7,live.membershipRevision);assertTrue(live.canManage)
        assertEquals("/v2/rooms/${room.value}/avatar",transport.path);assertNull(transport.payload);assertEquals(65536L,transport.bound)
        val expiredURL=GroupAvatarPresentationClient.decode(wire("presentation"),actor,device,room,0,121_000_000_000)
        assertTrue(expiredURL.valid(121_000_000_000));assertNull(expiredURL.avatar!!.plan);assertNull(expiredURL.downloadDeadlineNanos)
        assertFailsWith<AvatarAccessFailure> { GroupAvatarPresentationClient.decode(wire("presentation"),actor,device,room,0,300_000_000_000) }
        assertNull(GroupAvatarPresentationClient.decode(wire("withoutPlan"),actor,device,room,0,1).avatar!!.plan)
        val empty=GroupAvatarPresentationClient.decode(wire("empty"),actor,device,room,0,1);assertEquals(0,empty.state.revision);assertNull(empty.avatar)
        assertFalse(live.toString().contains("signature"))
    }
    @Test fun `presentation rejects wrong authority media generation booleans and overflow leases`() {
        val original=wire("presentation")
        for(change in listOf("actorUserID" to wireId(device.value),"deviceID" to wireId(actor.value),"state" to wire("removeState"),
            "avatar" to JsonNull,"resourceGeneration" to JsonNull,"resourceGeneration" to JsonPrimitive(0),"membershipRevision" to JsonPrimitive(-1),
            "validUntilUnixMilliseconds" to JsonPrimitive(Long.MAX_VALUE),"observedAtUnixMilliseconds" to JsonPrimitive(Long.MIN_VALUE),
            "serverNowUnixMilliseconds" to original.getValue("validUntilUnixMilliseconds"),"canManage" to JsonPrimitive("true"))) {
            assertFails { GroupAvatarPresentationClient.decode(JsonObject(original+change),actor,device,room,0,1) }
        }
        assertFails { GroupAvatarPresentationClient.decode(original,actor,device,RoomId(actor.value),0,1) }
        assertFails { GroupAvatarPresentationClient.decode(original,actor,device,room,1,0) }
        val delayed=JsonObject(original+("observedAtUnixMilliseconds" to JsonPrimitive(1799999999999)))
        assertFails { GroupAvatarPresentationClient.decode(delayed,actor,device,room,0,1) }
        val empty=JsonObject(wire("empty")+("resourceGeneration" to JsonPrimitive(1)))
        assertFails { GroupAvatarPresentationClient.decode(empty,actor,device,room,0,1) }
    }
}
