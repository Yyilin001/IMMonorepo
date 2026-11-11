package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class ResourceControlTests {
    private val actor = UserId("11111111-1111-1111-1111-111111111111")
    private val room = RoomId("22222222-2222-2222-2222-222222222222")
    private val fixtures by lazy { javaClass.getResourceAsStream("/resource-upload-swift.txt")!!.bufferedReader().readLines().associate { it.substringBefore('\t') to Json.parseToJsonElement(it.substringAfter('\t')) } }
    private fun wire(key: String) = fixtures.getValue(key).jsonObject
    private fun request(usage: ResourceUsage = ResourceUsage.Attachment(room)) = ResourceUploadRequest("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",usage,"image/png",16,ResourceChecksum("a".repeat(64)),persistentListOf(ResourceTransferMode.Put,ResourceTransferMode.PartPut),"é.png",ResourceDimensions(2,2))
    private fun uploading() = ResourceUploadSession.decode(wire("uploading"))
    private class Transport: AuthenticatedTransport {
        var response = EdgeResponse(200,buildJsonObject {})
        var path: String? = null;var payload: JsonObject? = null;var bound = 0L;var replay = true
        override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse {
            this.path=path;this.payload=payload;bound=maximumBytes;return response
        }
        override suspend fun requestWithoutReplay(path: String,payload: JsonObject,maximumBytes: Long): EdgeResponse { replay=false;return request(path,payload,maximumBytes=maximumBytes) }
        override suspend fun requestArray(path: String,payload: JsonObject,maximumBytes: Long) = request(path,payload,maximumBytes=maximumBytes)
    }
    @Test fun `request usages homes canonical names and sessions match actual Swift encoding`() {
        for((key,usage) in listOf("attachment" to ResourceUsage.Attachment(room),"userAvatar" to ResourceUsage.UserAvatar,"groupAvatar" to ResourceUsage.GroupAvatar(room))) {
            assertEquals(wire(key),request(usage).payload());assertEquals(wire(key),ResourceUploadRequest.decode(wire(key)).payload());assertEquals(wire(key+"Home"),usage.home(actor).payload());assertEquals(usage.home(actor),ResourceHome.decode(wire(key+"Home")))
        }
        for(key in listOf("uploading","ready")) assertEquals(wire(key),ResourceUploadSession.decode(wire(key)).payload())
        val raw = listOf("a\\b\\ e\u0301.txt ","\u0000\u200B附件\u202E.txt"," /目录/文件/","\u0085空格\u00A0","a\u200Cb","  ../文件  ")
        raw.forEachIndexed { i,name -> assertEquals(fixtures.getValue("name$i").jsonPrimitive.content,resourceDisplayName(name)) }
        assertFalse(uploading().bindable(1));val ready=ResourceUploadSession.decode(wire("ready"));assertTrue(ready.bindable(ready.bindableUntil!!-1));assertFalse(ready.bindable(ready.bindableUntil!!))
    }
    @Test fun `Swift capabilities negotiate a nonempty mode intersection and enforce image ceiling`() {
        val caps=ResourceCapabilities.decode(wire("capabilities"));assertTrue(caps.allows(request()))
        assertTrue(caps.copy(modes=persistentListOf(ResourceTransferMode.Put),maximumParts=0).allows(request()))
        assertFalse(caps.allows(request().copy(byteCount=500001)));assertTrue(caps.allows(request().copy(byteCount=500000)))
        assertFalse(caps.copy(usages=persistentSetOf("userAvatar")).allows(request()))
        assertFailsWith<IllegalArgumentException> { caps.copy(modes=persistentListOf(ResourceTransferMode.Get)) }
        assertFailsWith<IllegalArgumentException> { caps.copy(maximumImageBytes=1000001) }
    }
    @Test fun `control requests bind exact session and use nonreplayed create finalize`() = runTest {
        val transport=Transport();val client=ResourceUploadClient(transport,actor);val session=uploading()
        transport.response=EdgeResponse(200,wire("capabilities"));assertEquals(1000000L,client.capabilities().maximumBytes);assertEquals("/v2/resource-capabilities",transport.path);assertNull(transport.payload)
        transport.response=EdgeResponse(200,wire("uploading"));assertEquals(session,client.create(request()));assertEquals(wire("attachment"),transport.payload);assertEquals("/v2/resource-uploads",transport.path);assertFalse(transport.replay);assertEquals(524288L,transport.bound)
        assertEquals(session,client.status(session));assertEquals(session.locator.payload(),transport.payload);assertEquals("/v2/resource-uploads/status",transport.path)
        transport.response=EdgeResponse(200,buildJsonObject {},arrayBody=buildJsonArray { add(wire("partPlan")) })
        val target=client.target(session,request())!!;assertEquals(ResourceTransferMode.PartPut,target.mode);assertEquals(ResourceRange(8,15),target.range);assertEquals(wire("targets"),transport.payload)
        transport.response=EdgeResponse(200,wire("ready"));transport.replay=true;assertTrue(client.finalize(session).bindable(1));assertEquals(wire("finalize"),transport.payload);assertFalse(transport.replay)
        transport.response=EdgeResponse(200,session.copy(state=ResourceSessionState.Cancelled).payload());assertEquals(ResourceSessionState.Cancelled,client.cancel(session).state);assertEquals(wire("cancel"),transport.payload)
    }
    @Test fun `cross home media rollback and oversized confirmed parts never become upload authority`() = runTest {
        val transport=Transport();val client=ResourceUploadClient(transport,actor);val session=uploading()
        for(invalid in listOf(session.copy(locator=session.locator.copy(home=ResourceHome.Account(actor))),session.copy(media="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"),session.copy(parts=persistentListOf(ResourceUploadPart(1,17))))) {
            transport.response=EdgeResponse(200,invalid.payload());assertFailsWith<IllegalArgumentException> { client.create(request()) }
        }
        transport.response=EdgeResponse(200,session.copy(generation=2).payload());assertFailsWith<IllegalArgumentException> { client.status(session) }
        transport.response=EdgeResponse(200,buildJsonObject {},arrayBody=buildJsonArray { add(wire("putPlan"));add(wire("putPlan")) });assertFailsWith<IllegalArgumentException> { client.target(session,request()) }
        transport.response=EdgeResponse(200,buildJsonObject {},arrayBody=buildJsonArray { add(wire("partPlan")) });assertFailsWith<IllegalArgumentException> { client.target(session,request().copy(byteCount=15)) }
        assertFailsWith<IllegalArgumentException> { client.target(session.copy(state=ResourceSessionState.Finalizing),request()) }
    }
    @Test fun `wire rejects unsupported grant versions duplicate headers and unsafe metadata`() {
        val plan=ResourceTransferPlan.decode(wire("putPlan"));assertEquals(16L,plan.expectedBytes);assertFalse(plan.toString().contains("signature"));assertFalse(plan.headers.last().toString().contains("fixture-capability"))
        for(change in listOf("version" to JsonPrimitive(2),"backgroundDownloadAuthorization" to buildJsonObject {})) {
            assertFailsWith<IllegalArgumentException> { ResourceTransferPlan.decode(JsonObject(wire("putPlan")+change)) }
        }
        assertFailsWith<ClientFailure.Protocol> { ResourceTransferPlan.decode(JsonObject(wire("putPlan")+("backgroundAuthorization" to buildJsonObject {}))) }
        for(name in listOf("Host","Cookie","Content-Length","Range","Origin","Sec-Fetch-Site","Proxy-Authorization","X-Forwarded-For","bad header")) assertFailsWith<IllegalArgumentException> { ResourceTransferHeader(name,"value",ResourceHeaderKind.Content) }
        assertFailsWith<IllegalArgumentException> { ResourceTransferHeader("Authorization","Bearer value",ResourceHeaderKind.Content) }
        assertFailsWith<IllegalArgumentException> { plan.copy(headers=persistentListOf(plan.headers.first(),plan.headers.first().copy(name="content-type"))) }
        for(url in listOf("http://example.test","https://user:pass@example.test","https://example.test/#fragment")) assertFailsWith<IllegalArgumentException> { plan.copy(url=url) }
        val invalidURL=assertFailsWith<IllegalArgumentException> { plan.copy(url="https://[bad]/?token=private-capability") };assertFalse(invalidURL.toString().contains("private-capability"));assertNull(invalidURL.cause)
        assertFailsWith<IllegalArgumentException> { ResourceRange(0,Long.MAX_VALUE) };assertFailsWith<IllegalArgumentException> { ResourceDimensions(16384,16384) }
        assertFailsWith<IllegalArgumentException> { request().copy(contentType="Image/PNG") };assertFailsWith<IllegalArgumentException> { request().copy(displayName="../name") }
        assertFailsWith<IllegalArgumentException> { uploading().copy(state=ResourceSessionState.Cancelled,bindableUntil=1) }
        assertFailsWith<IllegalArgumentException> { uploading().copy(resourceState=ResourceState.Ready) }
    }
    @Test fun `canonical mode and part order survive durable round trips and retain hash identity`() {
        val original=request();val restored=ResourceUploadRequest.decode(original.payload())
        assertEquals(original,restored);assertEquals(original.hashCode(),restored.hashCode())
        val session=uploading().copy(parts=persistentListOf(ResourceUploadPart(2,8),ResourceUploadPart(1,8)))
        val recovered=ResourceUploadSession.decode(session.payload());assertEquals(session,recovered);assertEquals(session.hashCode(),recovered.hashCode())
    }
}
