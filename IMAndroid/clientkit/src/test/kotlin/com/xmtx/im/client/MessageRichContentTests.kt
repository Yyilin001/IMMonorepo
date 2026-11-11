package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlin.test.*

class MessageRichContentTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val operation="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private val reply=MessageId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    @Test fun `actual Swift rich command fingerprints and protobuf roundtrip agree`() {
        javaClass.getResourceAsStream("/rich-message-swift.jsonl")!!.bufferedReader().useLines {lines->lines.forEach {line->
            val value=Json.parseToJsonElement(line).jsonObject;val name=value.getValue("name").jsonPrimitive.content;val text=value.getValue("text").jsonPrimitive.content
            val projected=MessageRichContent.decodeProjection(text,buildJsonObject {put("entities",value.getValue("entities"))})
            val mentions=when(name) {"full"->persistentListOf(MentionTarget.Everyone,MentionTarget.User(actor));"ordered"->persistentListOf(MentionTarget.User(actor),MentionTarget.Everyone);else->persistentListOf()}
            val rich=projected.copy(mentions=mentions,replyTo=if(name=="plain") null else reply)
            val command=MessageCommand.text(actor,room,text,1800000000000,operation,rich)
            fun hex(bytes: ByteArray)=bytes.joinToString("") {"%02x".format(it)}
            assertEquals(value.getValue("domain").jsonPrimitive.content,hex(command.domainFingerprint.toByteArray()))
            assertEquals(value.getValue("fingerprint").jsonPrimitive.content,hex(command.fingerprint.toByteArray()))
            assertEquals(rich,MessageRichContent.fromCommand(command));assertEquals(rich,Json.decodeFromString<MessageRichContent>(Json.encodeToString(rich)))
            assertEquals(rich.projectionOrder(),MessageRichContent.decodeProjection(text,rich.payload(),complete=true))
        }}
    }
    @Test fun `UTF16 validation accepts scalar boundaries and rejects surrogate halves overflow and duplicates`() {
        val text="A😀e\u0301"
        fun check(start:Int,length:Int)=MessageRichContent(entities=persistentListOf(RichTextEntity(start,length,RichTextKind.bold))).validate(text)
        check(1,2);check(3,1);check(4,1)
        assertFails {MessageRichContent.Empty.validate("\uD83D")};assertFails {MessageRichContent.Empty.validate("\uDC00")}
        assertFails {check(1,1)};assertFails {check(2,1)};assertFails {check(Int.MAX_VALUE,Int.MAX_VALUE)};assertFails {check(0,6)}
        assertFails {RichTextEntity(-1,1,RichTextKind.bold)};assertFails {RichTextEntity(0,0,RichTextKind.bold)}
        val entity=RichTextEntity(0,1,RichTextKind.bold)
        assertFails {MessageRichContent(entities=persistentListOf(entity,entity))}
        assertFails {MessageRichContent(entities=(0..100).map {entity.copy(offsetUTF16=it)}.toPersistentList())}
        MessageRichContent(entities=persistentListOf(entity,entity.copy(kind=RichTextKind.italic))).validate(text)
    }
    @Test fun `mention identity limits reply and URL shape remain strict`() {
        assertFails {MessageRichContent(mentions=persistentListOf(MentionTarget.User(actor),MentionTarget.User(UserId(actor.value.lowercase()))))}
        assertFails {MessageRichContent(mentions=(0..20).map {MentionTarget.User(UserId(java.util.UUID.randomUUID().toString()))}.toPersistentList())}
        for(url in listOf("file:///private","javascript:alert(1)","https:/missing-host")) assertFails {RichTextEntity(0,1,RichTextKind.link,url)}
        assertFails {RichTextEntity(0,1,RichTextKind.link)};assertFails {RichTextEntity(0,1,RichTextKind.bold,"https://example.test")}
        assertFails {MessageRichContent(replyTo=MessageId("bad"))}
        val good=MessageRichContent(mentions=persistentListOf(MentionTarget.Everyone),replyTo=reply)
        for(key in listOf("mention_user_ids","mentions_everyone","entities","reply_to_message_id")) assertFails {MessageRichContent.decodeProjection("a",JsonObject(good.payload()-key),complete=true)}
        assertFails {MessageRichContent.decodeProjection("a",JsonObject(good.payload()+("mentions_everyone" to JsonPrimitive("true"))))}
    }
    @Test fun `user link input normalizes Unicode and spaces before fingerprints are frozen`() {
        val link=RichTextEntity.link(0,1," https://中文.test/a b?q=中#部分 ")
        assertEquals("https://xn--fiq228c.test/a%20b?q=%E4%B8%AD#%E9%83%A8%E5%88%86",link.linkURL)
        assertEquals("https://example.test/a%2Fb?x=1&x=2",RichTextEntity.link(0,1,"https://example.test/a%2Fb?x=1&x=2").linkURL)
        assertFails {RichTextEntity.link(0,1,"file:///private")}
        val rich=MessageRichContent(entities=persistentListOf(link));assertEquals(rich,MessageRichContent.fromCommand(MessageCommand.text(actor,room,"中",1,rich=rich)))
    }
    @Test fun `frozen send intent retains all content across serialization and invalid text is rejected`() {
        val rich=MessageRichContent(persistentListOf(MentionTarget.User(actor)),persistentListOf(RichTextEntity(1,2,RichTextKind.bold)),reply)
        val draft=ConversationDraft(room,text=" 😀 ",rich=rich);assertEquals(" 😀 ",draft.sendText);assertFalse(draft.empty)
        val intent=SendIntent(operation,actor,room,operation,draft.sendText,persistentListOf(),100,86400100,rich=rich)
        assertEquals(intent,Json.decodeFromString<SendIntent>(Json.encodeToString(intent)))
        assertFails {intent.copy(text="a")};assertFails {MessageCommand.text(actor,room,"a",1,rich=rich)}
    }
}
