package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.MessageSendOperation
import kotlinx.collections.immutable.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.net.URI
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

@Serializable sealed interface MentionTarget {
    @Serializable data class User(val id: UserId): MentionTarget { init { require(uuidId(id.value)==id.value) } }
    @Serializable data object Everyone: MentionTarget
}
@Serializable enum class RichTextKind { bold, italic, underline, strikethrough, spoiler, code, preformatted, link }
@Serializable data class RichTextEntity(val offsetUTF16: Int,val lengthUTF16: Int,val kind: RichTextKind,val linkURL: String?=null) {
    init {
        require(offsetUTF16>=0 && lengthUTF16>0)
        if(kind==RichTextKind.link) {
            val uri=URI(requireNotNull(linkURL));require(uri.scheme?.lowercase() in setOf("http","https") && !uri.rawAuthority.isNullOrEmpty())
            // Transport uses Foundation URL.absoluteString, so require an already escaped ASCII URL.
            require(uri.toASCIIString()==linkURL);uri.toURL()
        } else require(linkURL==null)
    }
    companion object {
        /** User-entered HTTP(S) addresses become escaped canonical URLs before freezing the content. */
        fun link(offsetUTF16: Int,lengthUTF16: Int,input: String)=RichTextEntity(offsetUTF16,lengthUTF16,RichTextKind.link,
            requireNotNull(input.trim().toHttpUrlOrNull()) {"请输入有效的 HTTP 或 HTTPS 地址"}.toUri().toASCIIString())
    }
}
internal object MentionTargetsSerializer: ForwardListSerializer<MentionTarget>(MentionTarget.serializer())
internal object RichTextEntitiesSerializer: ForwardListSerializer<RichTextEntity>(RichTextEntity.serializer())
/** Ordered immutable content facts. Neither mentions nor a reply ID establish room visibility or permission. */
@Serializable data class MessageRichContent(
    @Serializable(with=MentionTargetsSerializer::class) val mentions: PersistentList<MentionTarget> = persistentListOf(),
    @Serializable(with=RichTextEntitiesSerializer::class) val entities: PersistentList<RichTextEntity> = persistentListOf(),val replyTo: MessageId?=null) {
    init {
        require(mentions.size<=20 && mentions.distinct().size==mentions.size)
        require(entities.size<=100 && entities.distinct().size==entities.size)
        replyTo?.let {require(uuidId(it.value)==it.value)}
    }
    fun validate(text: String) {
        var index=0
        while(index<text.length) {
            val unit=text[index++]
            if(unit.isHighSurrogate()) {require(index<text.length && text[index].isLowSurrogate());index++}
            else require(!unit.isLowSurrogate())
        }
        fun boundary(index: Int)=index==0 || index==text.length || !(text[index-1].isHighSurrogate() && text[index].isLowSurrogate())
        for(entity in entities) {
            val end=entity.offsetUTF16.toLong()+entity.lengthUTF16
            require(end<=text.length && boundary(entity.offsetUTF16) && boundary(end.toInt())) { "格式范围必须对应完整 UTF-16 字符" }
        }
    }
    /** Sync stores user targets in order, followed by the separate broadcast flag. */
    fun projectionOrder()=copy(mentions=(mentions.filterIsInstance<MentionTarget.User>()+mentions.filter {it==MentionTarget.Everyone}).toPersistentList())
    fun payload()=buildJsonObject {
        put("mention_user_ids",JsonArray(mentions.filterIsInstance<MentionTarget.User>().map {JsonPrimitive(it.id.value)}))
        put("mentions_everyone",MentionTarget.Everyone in mentions)
        put("entities",JsonArray(entities.map {e->buildJsonObject {
            put("offsetUTF16",e.offsetUTF16);put("lengthUTF16",e.lengthUTF16);put("kind",e.kind.name);e.linkURL?.let {put("linkURL",it)}
        }}));put("reply_to_message_id",replyTo?.let {JsonPrimitive(it.value)} ?: JsonNull)
    }
    companion object {
        val Empty=MessageRichContent()
        fun decodeProjection(text: String,value: JsonObject,complete: Boolean=false): MessageRichContent = try {
            if(complete) require(listOf("mention_user_ids","mentions_everyone","entities","reply_to_message_id").all {it in value})
            fun array(key: String)=value[key]?.takeUnless {it is JsonNull}?.let {it as? JsonArray ?: error("array")} ?: JsonArray(emptyList())
            fun string(v: JsonElement)=(v as? JsonPrimitive)?.takeIf {it.isString}?.content ?: error("string")
            val users=array("mention_user_ids").map {MentionTarget.User(UserId(string(it)))}
            val broadcast=value["mentions_everyone"]?.takeUnless {it is JsonNull}?.let {(it as? JsonPrimitive)?.takeUnless {it.isString}?.booleanOrNull ?: error("boolean")} ?: false
            if(complete) require(value["mention_user_ids"] is JsonArray && value["entities"] is JsonArray && value["mentions_everyone"]!=JsonNull)
            val entities=array("entities").map {
                val e=it as? JsonObject ?: error("entity")
                fun number(key: String)=(e[key] as? JsonPrimitive)?.takeUnless {it.isString}?.intOrNull ?: error("integer")
                RichTextEntity(number("offsetUTF16"),number("lengthUTF16"),RichTextKind.valueOf(string(e.getValue("kind"))),e["linkURL"]?.takeUnless {it is JsonNull}?.let(::string))
            }.toPersistentList()
            MessageRichContent((users+if(broadcast) listOf(MentionTarget.Everyone) else emptyList()).toPersistentList(),entities,
                value["reply_to_message_id"]?.takeUnless {it is JsonNull}?.let {MessageId(string(it))}).also {it.validate(text)}
        } catch(_: Exception) {throw ClientFailure.Protocol()}
        fun fromCommand(command: MessageSendOperation)=MessageRichContent(command.mentionsList.map {
            when {it.hasUserId()->MentionTarget.User(UserId(it.userId));it.hasEveryone() && it.everyone->MentionTarget.Everyone;else->throw ClientFailure.Protocol()}
        }.toPersistentList(),command.entitiesList.map {RichTextEntity(it.offsetUtf16,it.lengthUtf16,RichTextKind.valueOf(it.kind),if(it.hasLinkUrl()) it.linkUrl else null)}.toPersistentList(),
            if(command.hasReplyToMessageId()) MessageId(command.replyToMessageId) else null).also {it.validate(command.text)}
    }
}
