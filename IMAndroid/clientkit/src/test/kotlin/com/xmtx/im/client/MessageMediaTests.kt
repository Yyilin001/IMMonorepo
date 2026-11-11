package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import kotlin.test.*

class MessageMediaTests {
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val media="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    private fun fixture(): List<JsonObject> = javaClass.getResourceAsStream("/media-presentation-swift.txt")!!.bufferedReader().useLines { lines -> lines.map {
        val core=Json.parseToJsonElement(it.substringAfter('\t')).jsonObject
        // The server projection uses snake_case keys; Core's Codable value uses camelCase.
        buildJsonObject {
            put("media_id",core.getValue("mediaID").jsonObject.getValue("rawValue"));put("kind",core.getValue("kind"))
            put("content_type",core.getValue("contentType"));put("byte_count",core.getValue("byteCount"));put("resource_descriptor",core.getValue("resourceDescriptor"))
        }
    }.toList() }
    private fun projection(p: JsonObject,ids: JsonArray=JsonArray(listOf(JsonPrimitive(media))))=buildJsonObject {
        put("media_ids",ids);put("media_presentations",JsonArray(listOf(p)))
    }
    @Test fun `five actual Swift media presentations preserve metadata and category`() {
        val fixtures=fixture();assertEquals(5,fixtures.size)
        fixtures.forEach { value ->
            val presentation=MessageMediaPresentation.decode(value);assertEquals(value,presentation.payload())
            val state=MessageMedia.decodeProjection(room,projection(value));assertEquals(persistentListOf(media),state.ids)
            assertEquals(persistentListOf(presentation),state.presentations);assertEquals(projection(value),state.payload())
        }
        assertEquals(MessageMediaKind.AnimatedImage,MessageMediaKind.forContentType("image/gif-extra"))
    }
    @Test fun `accepted projections reject incomplete foreign duplicated or mismatched descriptions`() {
        val value=fixture().first();val p=MessageMediaPresentation.decode(value)
        assertFails { MessageMedia.decodeProjection(room,buildJsonObject { put("media_ids",JsonArray(listOf(JsonPrimitive(media)))) }) }
        assertFails { MessageMedia.decodeProjection(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),projection(value)) }
        assertFails { MessageMedia.decodeProjection(room,projection(value,JsonArray(listOf(JsonPrimitive(media),JsonPrimitive(media.lowercase()))))) }
        assertFails { MessageMedia.decodeProjection(room,projection(value,JsonArray(listOf(JsonPrimitive(7))))) }
        assertFails { p.copy(kind=MessageMediaKind.Video) };assertFails { p.copy(byteCount=1235) };assertFails { p.copy(contentType="IMAGE/PNG") }
        assertFails { p.copy(descriptor=p.descriptor.copy(state=ResourceState.Deleted)) }
        assertFails { MessageMediaPresentation.decode(JsonObject(value-"resource_descriptor")) }
        assertFails { MessageMedia(List(11) { java.util.UUID.randomUUID().toString().uppercase() }.toPersistentList()) }
    }
    @Test fun `local identities and legacy unknown state cannot imply trusted descriptors`() {
        val local=MessageMedia(persistentListOf(media));assertNull(local.presentations)
        assertFails { MessageMedia.decodeProjection(room,local.payload()) }
        assertEquals(MessageMedia.Empty,MessageMedia.decodeProjection(room,buildJsonObject {}))
        val description=fixture().first()
        val withCapability=JsonObject(description+("url" to JsonPrimitive("private-capability")))
        assertEquals(description,MessageMediaPresentation.decode(withCapability).payload())
        val snapshot=Message(MessageId(media),room,UserId(room.value),"legacy",0)
        assertNull(snapshot.media)
    }
}
