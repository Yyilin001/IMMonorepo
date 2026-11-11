package com.xmtx.im.client

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlin.test.*

class ResourceImportTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val fixtures by lazy { javaClass.getResourceAsStream("/resource-import-swift.txt")!!.bufferedReader().useLines { lines -> lines.associate { it.substringBefore('\t') to Json.parseToJsonElement(it.substringAfter('\t')).jsonObject } } }
    private fun wire(key: String)=fixtures.getValue(key)
    private class Transport: AuthenticatedTransport {
        var response=EdgeResponse(200,buildJsonObject {});var path="";var payload: JsonObject?=null;var calls=0;var replay=true;var bound=0L
        override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse { this.path=path;this.payload=payload;calls++;bound=maximumBytes;return response }
        override suspend fun requestWithoutReplay(path: String,payload: JsonObject,maximumBytes: Long): EdgeResponse { replay=false;return request(path,payload,maximumBytes=maximumBytes) }
    }
    @Test fun `all 38 actual Swift fixtures round trip with exact source and target identities`() {
        assertEquals(38,fixtures.size)
        fixtures.forEach { (key,value) -> assertEquals(value,when {
            key.startsWith("source-")->ResourceImportSource.decode(value).payload()
            key.endsWith("-locator")->ResourceImportLocator.decode(value).payload()
            "state" in value->ResourceImportStatus.decode(value).payload()
            else->ResourceImportRequest.decode(value).also { assertEquals(if(key.endsWith("-user")) ResourceHome.Account(actor) else ResourceHome.Room(room),it.locator(actor).home) }.payload()
        },key) }
    }
    @Test fun `create status cancel bind locators and use bounded nonreplaying HTTP`()=runTest {
        val transport=Transport();val client=ResourceImportClient(transport,actor)
        for(target in listOf("user","group","attachment")) {
            val request=ResourceImportRequest.decode(wire("message-variant-$target"));val home=if(target=="user") "account" else "room"
            for(state in ResourceImportState.entries) {
                transport.response=EdgeResponse(200,wire("$home-${state.wire}"));transport.replay=true
                val created=client.create(request);assertEquals(request.payload(),transport.payload);assertEquals("/v2/resource-imports",transport.path);assertFalse(transport.replay)
                assertEquals(created,client.status(request.locator(actor)));assertEquals("/v2/resource-imports/status",transport.path)
                assertEquals(created,client.cancel(request.locator(actor)));assertEquals("/v2/resource-imports/cancel",transport.path)
                assertEquals(request.locator(actor).payload(),transport.payload);assertEquals(65536L,transport.bound)
            }
        }
    }
    @Test fun `unrelated responses and foreign account locators never authorize target`()=runTest {
        val transport=Transport();val client=ResourceImportClient(transport,actor);val request=ResourceImportRequest.decode(wire("relationship-user"))
        val status=ResourceImportStatus.decode(wire("account-ready"))
        for(wrong in listOf(status.copy(media=room.value),status.copy(locator=status.locator.copy(operation=room.value)),status.copy(locator=status.locator.copy(home=ResourceHome.Room(room))))) {
            transport.response=EdgeResponse(200,wrong.payload());assertFails { client.create(request) }
        }
        val before=transport.calls;assertFails { client.status(status.locator.copy(home=ResourceHome.Account(UserId(room.value)))) };assertEquals(before,transport.calls)
        transport.response=EdgeResponse(200,status.copy(locator=status.locator.copy(operation=room.value)).payload());assertFails { client.cancel(status.locator) }
        assertFails { request.copy(targetMedia=request.source.media) }
    }
    @Test fun `ready has mandatory finite signed deadline and is never a byte capability`() {
        val ready=ResourceImportStatus.decode(wire("account-ready"));assertTrue(ready.bindable(1799999999999));assertFalse(ready.bindable(1800000000000))
        assertFalse(ready.copy(bindableUntil=-1).bindable(0))
        for(change in listOf("bindableUntilUnixMilliseconds" to JsonNull,"bindableUntilUnixMilliseconds" to JsonPrimitive("1800000000000"),"bindableUntilUnixMilliseconds" to JsonPrimitive("9223372036854775808"),"state" to JsonPrimitive("unknown"))) {
            assertFails { ResourceImportStatus.decode(JsonObject(wire("account-ready")+change)) }
        }
        assertFails { ResourceImportStatus.decode(JsonObject(wire("account-pending")+("bindableUntilUnixMilliseconds" to JsonPrimitive(1)))) }
        val enriched=JsonObject(wire("account-ready")+("downloadURL" to JsonPrimitive("https://private.invalid/secret")))
        assertEquals(wire("account-ready"),ResourceImportStatus.decode(enriched).payload())
        assertFails { ResourceImportSource.decode(JsonObject(wire("source-message-original")+wire("source-relationship"))) }
    }
    @Test fun `HTTP uncertainty and retry hints are returned without replay or success inference`()=runTest {
        val transport=Transport();val client=ResourceImportClient(transport,actor);val request=ResourceImportRequest.decode(wire("relationship-user"))
        for(code in listOf(201,401,403,404,409,410,429,503)) {
            transport.response=EdgeResponse(code,wire("account-ready"),"120");val before=transport.calls
            val failure=assertFailsWith<ClientFailure.Http> { client.create(request) };assertEquals(code,failure.status);assertEquals("120",failure.retryAfter);assertEquals(before+1,transport.calls)
            assertFailsWith<ClientFailure.Http> { client.status(request.locator(actor)) };assertFailsWith<ClientFailure.Http> { client.cancel(request.locator(actor)) }
        }
    }
    @Test fun `profile import persistence preserves wire identity and rejects mixed preparations`() {
        val source=ProfileAvatarImport(room.value,ResourceImportRequest.decode(wire("relationship-user")))
        val intent=ProfileIntent(actor.value,actor,source.request.operation,1,1800000000000,serverImport=source)
        assertEquals(intent,Json.decodeFromString<ProfileIntent>(Json.encodeToString(intent)))
        assertEquals(source.request.payload(),Json.parseToJsonElement(Json.encodeToString(source.request)))
        val frozen=intent.copy(frozen=true);assertEquals(ProfileAvatarPatch.Set(source.request.targetMedia),frozen.command().patch.avatar)
        assertFails { intent.copy(avatar=ProfileAvatarPatch.Remove) }
        assertFails { ResourceImportWork(source.id,source.request,0,businessBound=true) }
        val bound=ResourceImportWork(source.id,source.request,0,ResourceImportStatus.decode(wire("account-ready")),businessBound=true)
        assertFalse(bound.bindable(0));assertFails { bound.copy(cancellationRequested=true) }
        assertFails { intent.copy(upload=ProfileAvatarUpload(actor.value,room.value,"avatar.png","image/png",1)) }
        assertFails { source.copy(request=source.request.copy(targetUsage=ResourceUsage.GroupAvatar(room))) }
    }
    @Test fun `legacy profile intent payloads decode without an import dependency`() {
        val intent=ProfileIntent(actor.value,actor,room.value,1,1800000000000,name="原名称")
        val json=Json.encodeToString(intent);assertFalse(json.contains("serverImport"));assertEquals(intent,Json.decodeFromString<ProfileIntent>(json));assertNull(Json.decodeFromString<ProfileIntent>(json).serverImport)
    }

}
