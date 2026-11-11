package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*

/** Logical identity only; this value cannot authorize reads or locate a provider object. */
data class ResourceKey(val home: ResourceHome,val media: String) {
    init { require(uuidId(media)==media) }
    fun payload()=buildJsonObject { put("home",home.payload());put("mediaID",wireId(media)) }
    companion object { fun decode(value: JsonObject)=ResourceKey(ResourceHome.decode(value.resourceObject("home")),value.resourceId("mediaID")) }
}
/** Display metadata, never a file path, download plan, or byte-read capability. */
data class ResourceDescriptor(val key: ResourceKey,val revision: Long,val displayName: String,val contentType: String,val byteCount: Long,
    val checksum: ResourceChecksum?,val state: ResourceState,val pixelWidth: Long?=null,val pixelHeight: Long?=null,val durationMilliseconds: Long?=null) {
    init {
        require(revision>0 && byteCount>0 && resourceDisplayName(displayName)==displayName);requireResourceContentType(contentType)
        require((pixelWidth==null)==(pixelHeight==null) && (pixelWidth==null || pixelWidth>0) && (pixelHeight==null || pixelHeight>0))
        require(durationMilliseconds==null || durationMilliseconds>=0);require(state!=ResourceState.Ready || checksum!=null)
    }
    fun payload()=buildJsonObject {
        put("key",key.payload());put("revision",revision);put("displayName",displayName);put("contentType",contentType);put("byteCount",byteCount);put("state",state.wire)
        checksum?.let { put("checksum",it.payload()) };pixelWidth?.let { put("pixelWidth",it) };pixelHeight?.let { put("pixelHeight",it) };durationMilliseconds?.let { put("durationMilliseconds",it) }
    }
    companion object { fun decode(value: JsonObject)=ResourceDescriptor(ResourceKey.decode(value.resourceObject("key")),value.resourceNumber("revision"),resourceDisplayName(value.resourceString("displayName")),
        value.resourceString("contentType"),value.resourceNumber("byteCount"),value.resourceOptionalObject("checksum")?.let(ResourceChecksum::decode),
        ResourceState.entries.firstOrNull { it.wire==value.resourceString("state") } ?: throw ClientFailure.Protocol(),
        value.resourceOptionalNumber("pixelWidth"),value.resourceOptionalNumber("pixelHeight"),value.resourceOptionalNumber("durationMilliseconds")) }
}
sealed interface ResourceRendition {
    data object Original: ResourceRendition
    data class Derived(val id: String,val version: Long): ResourceRendition { init { require(uuidId(id)==id && version>0) } }
    fun payload()=buildJsonObject { when(val value=this@ResourceRendition) {
        Original->put("original",buildJsonObject {})
        is Derived->put("derived",buildJsonObject { put("id",wireId(value.id));put("version",value.version) })
    } }
    companion object { fun decode(value: JsonObject): ResourceRendition {
        require(value.size==1)
        return when(value.keys.single()) {
            "original"->{ require(value.resourceObject("original").isEmpty());Original }
            "derived"->{ val fields=value.resourceObject("derived");Derived(fields.resourceId("id"),fields.resourceNumber("version")) }
            else->throw ClientFailure.Protocol()
        }
    } }
}
data class ResourceVariantKey(val resource: ResourceKey,val rendition: ResourceRendition=ResourceRendition.Original) {
    fun payload()=buildJsonObject { put("resource",resource.payload());put("rendition",rendition.payload()) }
    companion object { fun decode(value: JsonObject)=ResourceVariantKey(ResourceKey.decode(value.resourceObject("resource")),ResourceRendition.decode(value.resourceObject("rendition"))) }
}
data class ResourceVariantDescriptor(val key: ResourceVariantKey,val checksum: ResourceChecksum,val byteCount: Long) {
    init { require(byteCount>0) }
    fun payload()=buildJsonObject { put("key",key.payload());put("checksum",checksum.payload());put("byteCount",byteCount) }
    companion object { fun decode(value: JsonObject)=ResourceVariantDescriptor(ResourceVariantKey.decode(value.resourceObject("key")),ResourceChecksum.decode(value.resourceObject("checksum")),value.resourceNumber("byteCount")) }
}
enum class ResourceCategory(val wire: String) {
    All("all"),Image("image"),Video("video"),Audio("audio"),File("file");
    fun includes(contentType: String)=when(this) { All->true;Image->contentType.startsWith("image/");Video->contentType.startsWith("video/");Audio->contentType.startsWith("audio/");File->!listOf("image/","video/","audio/").any(contentType::startsWith) }
}
private const val maximumResourceTime=253402300799000L
private fun resourceCursor(value: String?) { require(value==null || value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size<=4096) }
/** Time limits are exclusive Unix milliseconds. Cursors are opaque and must never be logged. */
data class RoomResourceQuery(val category: ResourceCategory=ResourceCategory.All,val limit: Int=50,val cursor: String?=null,val before: Long?=null,val after: Long?=null) {
    init {
        require(limit in 1..100);resourceCursor(cursor)
        require(before==null || before in 0..maximumResourceTime);require(after==null || after in 0..maximumResourceTime)
        require(before==null || after==null || after<before)
    }
    override fun toString()="RoomResourceQuery(category=$category, limit=$limit, cursor=${if(cursor==null) "null" else "<redacted>"}, before=$before, after=$after)"
    fun payload()=buildJsonObject { put("category",category.wire);put("limit",limit);cursor?.let { put("cursor",it) };before?.let { put("before",it) };after?.let { put("after",it) } }
    companion object { fun decode(value: JsonObject)=RoomResourceQuery(ResourceCategory.entries.firstOrNull { it.wire==value.resourceString("category") } ?: throw ClientFailure.Protocol(),
        Math.toIntExact(value.resourceNumber("limit")),value.resourceOptionalString("cursor"),value.resourceOptionalNumber("before"),value.resourceOptionalNumber("after")) }
}
data class RoomResourcePosition(val sequence: Long,val ordinal: Int,val media: String): Comparable<RoomResourcePosition> {
    init { require(sequence>0 && ordinal in 0..<10 && uuidId(media)==media) }
    override fun compareTo(other: RoomResourcePosition)=compareValuesBy(this,other,RoomResourcePosition::sequence,RoomResourcePosition::ordinal,RoomResourcePosition::media)
    fun payload()=buildJsonObject { put("roomSequence",sequence);put("ordinal",ordinal);put("mediaID",wireId(media)) }
    companion object { fun decode(value: JsonObject)=RoomResourcePosition(value.resourceNumber("roomSequence"),Math.toIntExact(value.resourceNumber("ordinal")),value.resourceId("mediaID")) }
}
data class RoomResourceItem(val message: MessageId,val messageRevision: Long,val position: RoomResourcePosition,val createdAt: Long,val descriptor: ResourceDescriptor) {
    init { uuidId(message.value);require(messageRevision>0 && createdAt in 0..maximumResourceTime && position.media==descriptor.key.media) }
    fun payload()=buildJsonObject { put("messageID",wireId(message.value));put("messageRevision",messageRevision);put("position",position.payload());put("createdAt",createdAt);put("descriptor",descriptor.payload()) }
    companion object { fun decode(value: JsonObject)=RoomResourceItem(MessageId(value.resourceId("messageID")),value.resourceNumber("messageRevision"),RoomResourcePosition.decode(value.resourceObject("position")),value.resourceNumber("createdAt"),ResourceDescriptor.decode(value.resourceObject("descriptor"))) }
}
data class RoomResourcePage(val items: PersistentList<RoomResourceItem>,val snapshotUpper: Long,val nextCursor: String?) {
    init {
        require(items.size<=100 && snapshotUpper>=0 && items.all { it.position.sequence<=snapshotUpper })
        require(items.zipWithNext().all { (a,b)->a.position>b.position });resourceCursor(nextCursor);require(nextCursor==null || items.isNotEmpty())
    }
    override fun toString()="RoomResourcePage(items=${items.size}, snapshotUpper=$snapshotUpper, nextCursor=${if(nextCursor==null) "null" else "<redacted>"})"
    fun boundTo(room: RoomId,query: RoomResourceQuery) {
        require(items.size<=query.limit && (nextCursor==null || nextCursor!=query.cursor))
        require(items.all { it.descriptor.key.home==ResourceHome.Room(room) && it.descriptor.state==ResourceState.Ready && query.category.includes(it.descriptor.contentType) &&
            (query.before==null || it.createdAt<query.before) && (query.after==null || it.createdAt>query.after) })
    }
    fun payload()=buildJsonObject { put("items",JsonArray(items.map { it.payload() }));put("snapshotUpperRoomSequence",snapshotUpper);nextCursor?.let { put("nextCursor",it) } }
    companion object { fun decode(value: JsonObject)=RoomResourcePage(value.resourceArray("items").map { RoomResourceItem.decode(it as? JsonObject ?: throw ClientFailure.Protocol()) }.toPersistentList(),value.resourceNumber("snapshotUpperRoomSequence"),value.resourceOptionalString("nextCursor")) }
}
