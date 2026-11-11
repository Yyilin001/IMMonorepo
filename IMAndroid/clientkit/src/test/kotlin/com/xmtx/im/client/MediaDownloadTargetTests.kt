package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class MediaDownloadTargetTests {
    private val fixtures=javaClass.getResourceAsStream("/swift-media-download-fixtures.tsv")!!.bufferedReader().useLines { lines -> lines.associate { val (name,value)=it.split('\t',limit=2);name to Json.parseToJsonElement(value).jsonObject } }
    private val media="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private val location=MediaMessageLocation(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),MessageId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
    private class Transport: AuthenticatedTransport {
        var response=EdgeResponse(200,JsonObject(emptyMap()));var calls=0;var path="";var query: Map<String,String> = emptyMap()
        override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse=error("replaying boundary must not be used")
        override suspend fun mediaTarget(path: String,query: Map<String,String>,maximumBytes: Long): EdgeResponse { assertEquals(524288L,maximumBytes);calls++;this.path=path;this.query=query;return response }
    }
    @Test fun `Swift original preview and empty envelopes preserve the actual GET contract`()=runTest {
        val api=Transport();val client=MediaDownloadTargetClient(api,{1999999900000},{100})
        for((name,body) in fixtures) {
            api.response=EdgeResponse(200,body);val size=if(name=="preview") MediaImagePreviewSize.Thumbnail else null
            val target=client.resolve(media,location,size)
            assertEquals(ResourceTransferMode.Get,target.plan.mode);assertEquals(body.resourceObject("plan").resourceNumber("expectedByteCount"),target.plan.expectedBytes)
            assertEquals("/v2/media/$media",api.path);assertEquals(location.room.value,api.query["room_id"]);assertEquals(location.message.value,api.query["message_id"])
            assertEquals(size?.pixels?.toString(),api.query["image_size"]);assertFalse(target.toString().contains("signature"));assertFalse(target.toString().contains("Object fixture"))
            if(size!=null) assertEquals(body.resourceObject("preview"),target.preview!!.payload()) else assertNull(target.preview)
        }
        assertEquals(3,api.calls)
    }
    @Test fun `preview identity checksum length and rendition cannot be rebound`()=runTest {
        val api=Transport();val client=MediaDownloadTargetClient(api,{1999999900000},{100});val wire=fixtures.getValue("preview")
        val original=wire.resourceObject("preview");val variant=ResourceVariantDescriptor.decode(original)
        for(wrong in listOf(variant.copy(key=variant.key.copy(resource=ResourceKey(ResourceHome.Room(location.room),location.message.value))),
            variant.copy(key=variant.key.copy(resource=ResourceKey(ResourceHome.Account(UserId(location.room.value)),media))),
            variant.copy(key=variant.key.copy(rendition=ResourceRendition.Original)),variant.copy(checksum=ResourceChecksum("b".repeat(64))),variant.copy(byteCount=17))) {
            api.response=EdgeResponse(200,JsonObject(wire+("preview" to wrong.payload())))
            assertEquals(MediaReadFailureReason.InvalidResponse,assertFailsWith<MediaReadFailure> { client.resolve(media,location,MediaImagePreviewSize.Large) }.reason)
        }
        val plan=wire.resourceObject("plan")
        for(fields in listOf(JsonObject(plan+("mode" to JsonPrimitive("http_put"))),JsonObject(plan+("checksum" to JsonNull)),JsonObject(plan+("expectedByteCount" to JsonPrimitive(2097153))))) {
            val large=if(fields.resourceNumber("expectedByteCount")==2097153L) variant.copy(byteCount=2097153).payload() else original
            api.response=EdgeResponse(200,JsonObject(wire+mapOf("plan" to fields,"preview" to large)))
            assertEquals(MediaReadFailureReason.InvalidResponse,assertFailsWith<MediaReadFailure> { client.resolve(media,location,MediaImagePreviewSize.Thumbnail) }.reason)
        }
        api.response=EdgeResponse(200,fixtures.getValue("original"));assertFailsWith<MediaReadFailure> { client.resolve(media,location,MediaImagePreviewSize.Thumbnail) }
        api.response=EdgeResponse(200,wire);assertFailsWith<MediaReadFailure> { client.resolve(media,location,null) }
        val calls=api.calls;assertFails { client.resolve(media,null,MediaImagePreviewSize.Large) };assertEquals(calls,api.calls)
    }
    @Test fun `authorization errors expiry and cancellation cannot produce a target or trigger replay`()=runTest {
        val api=Transport();var nano=100L;val client=MediaDownloadTargetClient(api,{1999999900000},{nano})
        for((status,reason) in listOf(401 to MediaReadFailureReason.AuthorizationUnavailable,403 to MediaReadFailureReason.Denied,404 to MediaReadFailureReason.Denied,429 to MediaReadFailureReason.Unavailable,503 to MediaReadFailureReason.Unavailable,201 to MediaReadFailureReason.InvalidResponse)) {
            api.response=EdgeResponse(status,JsonObject(emptyMap()),"20");val before=api.calls
            val failure=assertFailsWith<MediaReadFailure> { client.resolve(media,location,null) };assertEquals(reason,failure.reason);assertEquals("20",failure.retryAfter);assertEquals(before+1,api.calls)
        }
        api.response=EdgeResponse(200,fixtures.getValue("original"));val target=client.resolve(media,location,null);nano=100000000100
        assertEquals(MediaReadFailureReason.Expired,assertFailsWith<MediaReadFailure> { target.requireValid() }.reason)
        val expired=MediaDownloadTargetClient(api,{2000000000001},{nano});assertFailsWith<MediaReadFailure> { expired.resolve(media,location,null) }
        var returned=false
        val cancelling=object: AuthenticatedTransport by api {
            override suspend fun mediaTarget(path: String,query: Map<String,String>,maximumBytes: Long): EdgeResponse { currentCoroutineContext().cancel();return api.response }
        }
        val job=launch { MediaDownloadTargetClient(cancelling,{1999999900000},{100}).resolve(media,location,null);returned=true };job.join();assertTrue(job.isCancelled);assertFalse(returned)
    }
    @Test fun `auth boundary rejects raw and encoded business tokens without refreshing rejected GETs`()=runTest {
        val authApi=FakeAccount();val auth=AuthSession(MemorySecrets(),authApi) { 0 };val credentials=auth.login("account","password123456")
        var calls=0;var response=EdgeResponse(401,JsonObject(emptyMap()));val credentialCalls=authApi.requests.size
        val edge=object: EdgeTransport {
            override suspend fun request(path: String,credentials: Credentials,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse=error("multi-query GET required")
            override suspend fun requestWithQuery(path: String,credentials: Credentials,query: Map<String,String>,maximumBytes: Long): EdgeResponse { calls++;assertEquals(3,query.size);return response }
        }
        val api=AuthenticatedApi(auth,edge,credentials.userId,credentials.deviceId)
        val client=MediaDownloadTargetClient(api,{1999999900000},{100})
        assertEquals(MediaReadFailureReason.AuthorizationUnavailable,assertFailsWith<MediaReadFailure> { client.resolve(media,location,MediaImagePreviewSize.Thumbnail) }.reason)
        assertEquals(1,calls);assertEquals(credentialCalls,authApi.requests.size)
        for(value in listOf("sensitive-access","sensitive%2Daccess")) {
            response=EdgeResponse(200,buildJsonObject { put("url","https://provider.invalid/?secret=$value") })
            assertEquals(MediaReadFailureReason.InvalidResponse,assertFailsWith<MediaReadFailure> { client.resolve(media,location,MediaImagePreviewSize.Thumbnail) }.reason)
        }
        auth.logout();assertFailsWith<ClientFailure.SignedOut> { client.resolve(media,location,MediaImagePreviewSize.Thumbnail) };assertEquals(3,calls)
    }
}
