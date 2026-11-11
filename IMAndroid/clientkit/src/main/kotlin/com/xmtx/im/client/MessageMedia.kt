package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*

enum class MessageMediaKind(val wire: String) {
    Image("image"),AnimatedImage("animated_image"),Video("video"),Audio("audio"),File("file");
    companion object {
        fun forContentType(type: String)=when {
            type.startsWith("image/gif")->AnimatedImage
            type.startsWith("image/")->Image
            type.startsWith("video/")->Video
            type.startsWith("audio/")->Audio
            else->File
        }
    }
}
/** Verified display facts from a message projection, never permission to read bytes. */
data class MessageMediaPresentation(val media: String,val kind: MessageMediaKind,val contentType: String,val byteCount: Long,val descriptor: ResourceDescriptor) {
    init {
        require(uuidId(media)==media && contentType==contentType.trim().lowercase() && contentType.contains('/') && contentType.toByteArray(Charsets.UTF_8).size<=127)
        require(contentType.none { it.code<32 || it.code==127 } && byteCount>=0)
        require(descriptor.key.media==media && descriptor.state==ResourceState.Ready && descriptor.contentType==contentType && descriptor.byteCount==byteCount)
        require(kind==MessageMediaKind.forContentType(contentType))
    }
    fun payload()=buildJsonObject {
        put("media_id",media);put("kind",kind.wire);put("content_type",contentType);put("byte_count",byteCount);put("resource_descriptor",descriptor.payload())
    }
    companion object {
        fun decode(value: JsonObject)=MessageMediaPresentation(uuidId(value.resourceString("media_id")),
            MessageMediaKind.entries.firstOrNull { it.wire==value.resourceString("kind") } ?: throw ClientFailure.Protocol(),
            value.resourceString("content_type"),value.resourceNumber("byte_count"),ResourceDescriptor.decode(value.resourceObject("resource_descriptor")))
    }
}
/** Null presentations are local command identities only; empty presentations prove an attachment-free projection. */
data class MessageMedia(val ids: PersistentList<String>,val presentations: PersistentList<MessageMediaPresentation>?=null) {
    init {
        require(ids.size<=10 && ids.distinct().size==ids.size && ids.all { uuidId(it)==it })
        require(presentations==null || presentations.map { it.media }==ids)
    }
    fun payload()=buildJsonObject {
        put("media_ids",JsonArray(ids.map(::JsonPrimitive)))
        presentations?.let { put("media_presentations",JsonArray(it.map(MessageMediaPresentation::payload))) }
    }
    companion object {
        val Empty=MessageMedia(persistentListOf(),persistentListOf())
        /** Decode only accepted synchronization state, with complete ordered descriptors bound to this room. */
        fun decodeProjection(room: RoomId,value: JsonObject): MessageMedia {
            fun array(key: String)=value[key]?.takeUnless { it is JsonNull }?.let { it as? JsonArray ?: throw ClientFailure.Protocol() } ?: JsonArray(emptyList())
            val ids=array("media_ids").map { uuidId((it as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()) }.toPersistentList()
            val presentations=array("media_presentations").map { MessageMediaPresentation.decode(it as? JsonObject ?: throw ClientFailure.Protocol()) }.toPersistentList()
            require(presentations.all { it.descriptor.key.home==ResourceHome.Room(room) })
            return MessageMedia(ids,presentations)
        }
    }
}
