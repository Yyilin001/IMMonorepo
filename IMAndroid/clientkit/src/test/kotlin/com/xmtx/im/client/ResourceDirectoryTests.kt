package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import kotlin.test.*

class ResourceDirectoryTests {
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val fixtures by lazy { javaClass.getResourceAsStream("/resource-directory-swift.txt")!!.bufferedReader().useLines { rows->rows.associate { it.substringBefore('\t') to Json.parseToJsonElement(it.substringAfter('\t')).jsonObject } } }
    private fun wire(key: String)=fixtures.getValue(key)
    private class Transport: AuthenticatedTransport {
        var result=EdgeResponse(200,buildJsonObject {});var calls=0;var path="";var payload: JsonObject?=null;var bound=0L;var replay=true
        override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse { calls++;this.path=path;this.payload=payload;bound=maximumBytes;return result }
        override suspend fun requestWithoutReplay(path: String,payload: JsonObject,maximumBytes: Long): EdgeResponse { replay=false;return request(path,payload,maximumBytes=maximumBytes) }
    }
    @Test fun `27 Swift fixtures preserve descriptor variant and directory contracts`() {
        assertEquals(27,fixtures.size)
        fixtures.forEach { (key,value)->assertEquals(value,when {
            key.endsWith("-key")->ResourceKey.decode(value).payload()
            key.startsWith("descriptor-")->ResourceDescriptor.decode(value).payload()
            key.startsWith("variant-key-")->ResourceVariantKey.decode(value).payload()
            key.startsWith("variant-")->ResourceVariantDescriptor.decode(value).payload()
            key.startsWith("query-")->RoomResourceQuery.decode(value).payload()
            key=="position"->RoomResourcePosition.decode(value).payload()
            key=="item"->RoomResourceItem.decode(value).payload()
            else->RoomResourcePage.decode(value).payload()
        },key) }
        assertEquals(Long.MAX_VALUE,ResourceDescriptor.decode(wire("descriptor-large-dimensions")).pixelWidth)
    }
    @Test fun `read is bounded nonreplaying and binds room category and exclusive time limits`()=runTest {
        val transport=Transport();transport.result=EdgeResponse(200,wire("page"));val client=RoomResourceDirectoryClient(transport)
        val query=RoomResourceQuery(ResourceCategory.Image,1,before=1800000000001,after=1799999999999)
        val page=client.query(room,query);assertEquals(wire("page"),page.payload());assertEquals("/v2/rooms/${room.value}/resources/query",transport.path)
        assertFalse(transport.replay);assertEquals(512*1024L,transport.bound);assertEquals(query.payload(),transport.payload)
        for(wrong in listOf(query.copy(category=ResourceCategory.Audio),query.copy(before=1800000000000),query.copy(after=1800000000000),query.copy(cursor=page.nextCursor))) {
            assertEquals(ResourceDirectoryFailureReason.InvalidResponse,assertFailsWith<ResourceDirectoryFailure> { client.query(room,wrong) }.reason)
        }
        assertFailsWith<ResourceDirectoryFailure> { client.query(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),query) }
        transport.result=EdgeResponse(200,wire("page-empty"));assertTrue(client.query(room,RoomResourceQuery()).items.isEmpty())
    }
    @Test fun `malformed descriptors positions and pages cannot become catalog facts`() {
        val descriptor=ResourceDescriptor.decode(wire("descriptor-complete"));val item=RoomResourceItem.decode(wire("item"));val page=RoomResourcePage.decode(wire("page"))
        assertFails { descriptor.copy(checksum=null) };assertFails { descriptor.copy(byteCount=0) };assertFails { descriptor.copy(pixelWidth=null) };assertFails { descriptor.copy(durationMilliseconds=-1) }
        assertFails { item.copy(messageRevision=0) };assertFails { item.copy(createdAt=253402300799001) };assertFails { item.copy(position=item.position.copy(media=room.value)) }
        assertFails { item.position.copy(sequence=0) };assertFails { item.position.copy(ordinal=10) }
        assertFails { page.copy(items=persistentListOf(item,item)) };assertFails { page.copy(snapshotUpper=11) };assertFails { page.copy(items=persistentListOf()) }
        val later=item.copy(position=item.position.copy(sequence=13));assertFails { page.copy(items=persistentListOf(item,later)) }
        assertFails { page.copy(items=List(101) { item.copy(position=item.position.copy(sequence=200L-it)) }.toPersistentList(),snapshotUpper=300) }
        for(change in listOf("revision" to JsonPrimitive("7"),"byteCount" to JsonPrimitive(-1),"state" to JsonPrimitive("future"),"pixelWidth" to JsonPrimitive("9223372036854775808"))) {
            assertFails { ResourceDescriptor.decode(JsonObject(wire("descriptor-complete")+change)) }
        }
        assertFails { RoomResourcePosition.decode(JsonObject(wire("position")+("roomSequence" to Json.parseToJsonElement("9223372036854775808")))) }
    }
    @Test fun `metadata encoding removes unknown capabilities and keeps cursors out of diagnostics`() {
        val input=JsonObject(wire("descriptor-complete")+("url" to JsonPrimitive("https://secret.invalid/token")))
        val descriptor=ResourceDescriptor.decode(input);assertEquals(wire("descriptor-complete"),descriptor.payload());assertFalse(descriptor.toString().contains("secret.invalid"))
        val normalized=ResourceDescriptor.decode(JsonObject(input+("displayName" to JsonPrimitive("../目录/图e\u0301.png"))))
        assertEquals("图é.png",normalized.displayName)
        val query=RoomResourceQuery.decode(wire("query-bounded"));val page=RoomResourcePage.decode(wire("page"))
        assertFalse(query.toString().contains(query.cursor!!));assertFalse(page.toString().contains(page.nextCursor!!))
    }
    @Test fun `query and derived version bounds reject ambiguous or oversized values`() {
        for(limit in listOf(0,101)) assertFails { RoomResourceQuery(limit=limit) }
        for(cursor in listOf("","界".repeat(1366))) assertFails { RoomResourceQuery(cursor=cursor) }
        assertFails { RoomResourceQuery(before=0,after=0) };assertFails { RoomResourceQuery(after=-1) };assertFails { RoomResourceQuery(before=253402300799001) }
        assertFails { ResourceRendition.Derived(room.value,0) }
        assertFails { ResourceRendition.decode(buildJsonObject { put("original",buildJsonObject { put("id",1) }) }) }
        assertEquals(ResourceCategory.File,ResourceCategory.entries.single { it!=ResourceCategory.All && it.includes("application/pdf") })
    }
    @Test fun `HTTP outcomes keep denial distinct from transient failures without replay`()=runTest {
        val transport=Transport();val client=RoomResourceDirectoryClient(transport)
        for((code,reason) in listOf(401 to ResourceDirectoryFailureReason.AuthorizationUnavailable,403 to ResourceDirectoryFailureReason.NotVisible,404 to ResourceDirectoryFailureReason.NotVisible,
            400 to ResourceDirectoryFailureReason.InvalidCursor,429 to ResourceDirectoryFailureReason.Unavailable,503 to ResourceDirectoryFailureReason.Unavailable,201 to ResourceDirectoryFailureReason.InvalidResponse)) {
            transport.result=EdgeResponse(code,wire("page"),"120");val before=transport.calls
            val failure=assertFailsWith<ResourceDirectoryFailure> { client.query(room,RoomResourceQuery()) };assertEquals(reason,failure.reason);assertEquals(code,failure.status);assertEquals("120",failure.retryAfter);assertEquals(before+1,transport.calls)
        }
    }
    @Test fun `cancellation of directory work cannot publish a late response`()=runTest {
        var returned=false
        val transport=object: AuthenticatedTransport {
            override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse { delay(20000);return EdgeResponse(200,wire("page")) }
            override suspend fun requestWithoutReplay(path: String,payload: JsonObject,maximumBytes: Long)=request(path,payload,maximumBytes=maximumBytes)
        }
        val task=launch { RoomResourceDirectoryClient(transport).query(room,RoomResourceQuery());returned=true }
        testScheduler.runCurrent();task.cancelAndJoin();assertFalse(returned)
        assertFailsWith<TimeoutCancellationException> { RoomResourceDirectoryClient(transport).query(room,RoomResourceQuery()) }
    }
    @Test fun `actual HTTPS rejects malformed and oversized JSON without exposing body or replaying`()=runBlocking {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        try { MockWebServer().use { server ->
            server.useHttps(keys.sslSocketFactory(),false);server.start()
            val auth=AuthSession(MemorySecrets(),FakeAccount()) { 0 };val credentials=auth.login("account","password123456")
            val edge=AccountClient(server.url("/").toString(),http)
            val client=RoomResourceDirectoryClient(AuthenticatedApi(auth,edge,credentials.userId,credentials.deviceId))
            for(body in listOf("[]","{\"private-cursor\":", "{\"private-cursor\":\""+"a".repeat(524288)+"\"}")) {
                server.enqueue(MockResponse().setHeader("Content-Type","application/json").setChunkedBody(body,8192))
                val failure=assertFailsWith<ResourceDirectoryFailure> { client.query(room,RoomResourceQuery()) }
                assertEquals(ResourceDirectoryFailureReason.InvalidResponse,failure.reason);assertNull(failure.cause)
                assertFalse(failure.toString().contains("private-cursor"))
            }
            server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody(wire("page-empty").toString()))
            assertTrue(client.query(room,RoomResourceQuery()).items.isEmpty());assertEquals(4,server.requestCount)
            val otherAccount=RoomResourceDirectoryClient(AuthenticatedApi(auth,edge,UserId("another-account"),credentials.deviceId))
            assertFailsWith<ClientFailure.SignedOut> { otherAccount.query(room,RoomResourceQuery()) };assertEquals(4,server.requestCount)
        } } finally { http.dispatcher.executorService.shutdown();http.connectionPool.evictAll() }
    }
}
