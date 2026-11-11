package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class ResourceBackgroundUploadTests {
    private val actor=UserId("11111111-1111-1111-1111-111111111111")
    private val room=RoomId("22222222-2222-2222-2222-222222222222")
    private val media="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private val sessionID="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private val issued=1_750_000_000_000L
    private val checksum=ResourceChecksum("a".repeat(64))
    private val fixtures by lazy {javaClass.getResourceAsStream("/resource-background-swift.txt")!!.bufferedReader().readLines().associate {it.substringBefore('\t') to Json.parseToJsonElement(it.substringAfter('\t')).jsonObject}}
    private fun request()=ResourceUploadRequest("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",media,ResourceUsage.Attachment(room),"image/png",16,checksum,persistentListOf(ResourceTransferMode.Put,ResourceTransferMode.PartPut))
    private fun session()=ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),sessionID),media,3,ResourceSessionState.Uploading,ResourceState.Pending,issued+3_600_000,null,persistentListOf(),null)
    private fun wire(key:String)=fixtures.getValue(key)
    private class Transport:AuthenticatedTransport {
        var calls=0;var payload:JsonObject?=null;var response=JsonArray(emptyList());var onRequest:()->Unit={}
        override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unexpected object request")
        override suspend fun requestArray(path:String,payload:JsonObject,maximumBytes:Long):EdgeResponse {
            assertEquals("/v2/resource-uploads/targets",path);assertEquals(524288,maximumBytes);calls++;this.payload=payload;onRequest()
            return EdgeResponse(200,buildJsonObject {},arrayBody=response)
        }
    }
    @Test fun `actual Swift whole part and sorted request encodings match immutable Kotlin values`() {
        for(key in listOf("whole","part")) {
            val decoded=ResourceBackgroundUploadAuthorization.decode(wire(key))
            assertEquals(wire(key),decoded.payload());assertEquals(sessionID,decoded.session);assertEquals(3,decoded.generation)
            assertFalse(decoded.payload().toString().contains("private-"));assertFalse(decoded.payload().containsKey("url"))
            val later=decoded.copy(generation=4);assertEquals(3,decoded.generation);assertEquals(4,later.generation)
        }
        assertEquals(ResourceBackgroundUploadScope.Whole(16,checksum),ResourceBackgroundUploadAuthorization.decode(wire("whole")).scope)
        assertEquals(ResourceBackgroundUploadScope.Part(2),ResourceBackgroundUploadAuthorization.decode(wire("part")).scope)
        for(key in listOf("wholePlan","partPlan")) assertFalse(ResourceTransferPlan.decode(wire(key)).toString().contains("private-"))
    }
    @Test fun `grant constructors and wire cannot bypass byte time generation or scope boundaries`() {
        val whole=ResourceBackgroundUploadAuthorization.decode(wire("whole"))
        for(change in listOf("generation" to JsonPrimitive(0),"issuedAtMilliseconds" to JsonPrimitive(0),"expiresAtMilliseconds" to JsonPrimitive(issued),"expiresAtMilliseconds" to JsonPrimitive(issued+900001),"scope" to buildJsonObject {put("whole",wire("whole").resourceObject("scope").resourceObject("whole"));put("part",buildJsonObject {put("number",1)})})) {
            assertFails {ResourceBackgroundUploadAuthorization.decode(JsonObject(wire("whole")+change))}
        }
        assertFails {whole.copy(id="wrong")};assertFails {whole.copy(session="wrong")};assertFails {whole.copy(media="wrong")}
        assertFails {ResourceBackgroundUploadScope.Part(0)};assertFails {ResourceBackgroundUploadScope.Part(33)}
        assertFails {ResourceBackgroundUploadScope.Whole(0,checksum)};assertFails {ResourceBackgroundUploadScope.Whole(256L*1024*1024+1,checksum)}
        assertEquals(32,ResourceBackgroundUploadScope.Part(32).number)
        assertEquals(256L*1024*1024,ResourceBackgroundUploadScope.Whole(256L*1024*1024,checksum).byteCount)
    }
    @Test fun `delegated plans cannot widen method expiry headers bytes hash or part number`() {
        val whole=ResourceTransferPlan.decode(wire("wholePlan"));val part=ResourceTransferPlan.decode(wire("partPlan"))
        assertFails {whole.copy(mode=ResourceTransferMode.Get)};assertFails {whole.copy(expiresAt=whole.expiresAt+1)}
        assertFails {whole.copy(expectedBytes=17)};assertFails {whole.copy(checksum=ResourceChecksum("b".repeat(64)))}
        assertFails {whole.copy(headers=persistentListOf(ResourceTransferHeader("Authorization","Object secret",ResourceHeaderKind.ObjectCapability)))}
        assertFails {whole.copy(headers=persistentListOf(ResourceTransferHeader("X-Key","secret",ResourceHeaderKind.ObjectCapability)))}
        assertFails {part.copy(part=1)};assertFails {part.copy(expectedBytes=8L*1024*1024+1,range=ResourceRange(0,8L*1024*1024))}
        assertFails {part.copy(backgroundDownload=ResourceBackgroundDownloadAuthorization(whole.backgroundUpload!!.id,8,checksum,issued,part.expiresAt))}
        assertFails {ResourceTransferPlan.decode(JsonObject(wire("wholePlan")+("url" to JsonPrimitive("https://private@objects.invalid/x"))))}
        assertEquals(part.backgroundUpload,part.copy(headers=persistentListOf(ResourceTransferHeader("Content-Type","image/png",ResourceHeaderKind.Content))).backgroundUpload)
    }
    @Test fun `explicit target opt in matches Swift sorted request and foreground refuses grants`()=runTest {
        val transport=Transport();val client=ResourceUploadClient(transport,actor,{issued+1000},{1000})
        transport.response=JsonArray(listOf(wire("partPlan")))
        val result=client.backgroundTargets(session(),request(),persistentListOf(2,1))
        assertEquals(wire("targets"),transport.payload);assertEquals(1,result.size);result.single().requireValid(session(),request())
        assertFalse(result.single().toString().contains("private-"))
        transport.response=JsonArray(listOf(wire("wholePlan")))
        val next=client.backgroundTargets(session(),request());assertEquals(wire("nextTarget"),transport.payload);assertEquals(16,next.single().plan.expectedBytes)
        assertFails {client.target(session(),request())};assertFalse(transport.payload!!.getValue("background").jsonPrimitive.boolean)
        assertEquals(1,result.size);assertEquals(ResourceTransferMode.PartPut,result.single().plan.mode)
    }
    @Test fun `invalid requests fail before network and response cannot change upload identity`()=runTest {
        val transport=Transport();val client=ResourceUploadClient(transport,actor,{issued+1000},{1000})
        for(parts in listOf(persistentListOf(0),persistentListOf(33),persistentListOf(1,1),(1..17).toPersistentList())) assertFails {client.backgroundTargets(session(),request(),parts)}
        assertFails {client.backgroundTargets(session(),request().copy(usage=ResourceUsage.UserAvatar))}
        assertFails {client.backgroundTargets(session(),request().copy(usage=ResourceUsage.GroupAvatar(room)))}
        assertFails {client.backgroundTargets(session().copy(state=ResourceSessionState.Finalizing),request())}
        assertEquals(0,transport.calls)
        val grant=ResourceBackgroundUploadAuthorization.decode(wire("whole"))
        for(invalid in listOf(grant.copy(session=media),grant.copy(media=sessionID),grant.copy(generation=4),grant.copy(issuedAt=issued-900000,expiresAt=issued))) {
            val plan=JsonObject(wire("wholePlan")+mapOf("backgroundAuthorization" to invalid.payload(),"expiresAtUnixMilliseconds" to JsonPrimitive(invalid.expiresAt)))
            transport.response=JsonArray(listOf(plan));assertFails {client.backgroundTargets(session(),request())}
        }
        transport.response=JsonArray(listOf(JsonObject(wire("wholePlan")-"backgroundAuthorization")))
        assertFails {client.backgroundTargets(session(),request())}
    }
    @Test fun `batched plans reject duplicate grants parts foreign ranges and unsolicited parts`()=runTest {
        val transport=Transport();val client=ResourceUploadClient(transport,actor,{issued+1000},{1000})
        val part=wire("partPlan")
        transport.response=JsonArray(listOf(part,part));assertFails {client.backgroundTargets(session(),request(),persistentListOf(1,2))}
        transport.response=JsonArray(listOf(part));assertFails {client.backgroundTargets(session(),request(),persistentListOf(1))}
        assertFails {client.backgroundTargets(session().copy(parts=persistentListOf(ResourceUploadPart(2,8))),request())}
        val outside=JsonObject(part+("byteRange" to ResourceRange(16,23).payload()))
        transport.response=JsonArray(listOf(outside));assertFails {client.backgroundTargets(session(),request())}
        transport.response=JsonArray(listOf(part,part));assertFails {client.backgroundTargets(session(),request())}
    }
    @Test fun `handoff rechecks current generation scope cancellation confirmed part and monotonic deadline`()=runTest {
        var wall=issued+1000;var monotonic=1000L
        val transport=Transport();val client=ResourceUploadClient(transport,actor,{wall},{monotonic})
        transport.response=JsonArray(listOf(wire("partPlan")));val target=client.backgroundTargets(session(),request()).single()
        for(changed in listOf(session().copy(generation=4),session().copy(state=ResourceSessionState.Cancelled),session().copy(parts=persistentListOf(ResourceUploadPart(2,8))),session().copy(expiresAt=issued+2000))) assertFails {target.requireValid(changed,request())}
        assertFails {target.requireValid(session(),request().copy(checksum=ResourceChecksum("b".repeat(64))))}
        assertFails {target.requireValid(session(),request().copy(usage=ResourceUsage.GroupAvatar(room)))}
        target.requireValid(session(),request())
        monotonic+=899000L*1_000_000;wall=issued+500;assertFails {target.requireValid(session(),request())}
    }
    @Test fun `provider issue timestamp is not a client clock not before restriction`()=runTest {
        var monotonic=1000L
        val transport=Transport();val client=ResourceUploadClient(transport,actor,{issued},{monotonic})
        val grant=ResourceBackgroundUploadAuthorization.decode(wire("whole")).copy(issuedAt=issued+500,expiresAt=issued+900500)
        transport.response=JsonArray(listOf(JsonObject(wire("wholePlan")+mapOf("backgroundAuthorization" to grant.payload(),"expiresAtUnixMilliseconds" to JsonPrimitive(grant.expiresAt)))))
        val target=client.backgroundTargets(session(),request()).single();target.requireValid(session(),request())
        monotonic+=900000L*1_000_000;assertFails {target.requireValid(session(),request())}
    }
    @Test fun `server may issue its full duration after request starts without extending local elapsed budget`()=runTest {
        var wall=issued;var monotonic=1000L
        val transport=Transport();val client=ResourceUploadClient(transport,actor,{wall},{monotonic})
        transport.onRequest={wall+=500;monotonic+=500_000_000}
        val grant=ResourceBackgroundUploadAuthorization.decode(wire("whole")).copy(issuedAt=issued+500,expiresAt=issued+900500)
        transport.response=JsonArray(listOf(JsonObject(wire("wholePlan")+mapOf("backgroundAuthorization" to grant.payload(),"expiresAtUnixMilliseconds" to JsonPrimitive(grant.expiresAt)))))
        val result=client.backgroundTargets(session(),request()).single();result.requireValid(session(),request())
        wall=issued+899999;monotonic=1000+900000L*1_000_000;assertFails {result.requireValid(session(),request())}
    }
}
