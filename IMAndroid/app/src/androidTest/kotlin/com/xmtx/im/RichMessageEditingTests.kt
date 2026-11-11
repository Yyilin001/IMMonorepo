package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RichMessageEditingTests {
    private val user=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    @Test fun changesRebaseUnaffectedUTF16RangesAndDropIntersectingFormats() {
        val original="😀 bold link"
        val rich=MessageRichContent(persistentListOf(MentionTarget.User(user)),persistentListOf(RichTextEntity(0,2,RichTextKind.bold),RichTextEntity(3,4,RichTextKind.italic),RichTextEntity(8,4,RichTextKind.link,"https://example.test")))
        val next=rebaseRichContent(original,"前😀 bold link",rich);assertEquals(listOf(1,4,9),next.entities.map {it.offsetUTF16});assertEquals(rich.mentions,next.mentions)
        val changed=rebaseRichContent(original,"😎 bold link",rich);assertEquals(listOf(3,8),changed.entities.map {it.offsetUTF16})
        assertEquals(listOf(0,3),rebaseRichContent(original,"😀 bold next",rich).entities.map {it.offsetUTF16})
        val middle=rebaseRichContent(original,"😀 biold link",rich);assertEquals(listOf(0,9),middle.entities.map {it.offsetUTF16})
        assertEquals(rich,rebaseRichContent(original,original,rich))
    }
    @Test fun mentionInputResolvesExactHandlesWithOpaqueFailuresAndNoLocalPermissionClaims()=runBlocking {
        val calls=mutableListOf<String>()
        val resolved=resolveChatMentions(" member,\n@ALL ",true) {calls+=it;user}
        assertEquals(listOf("member"),calls);assertEquals(persistentListOf(MentionTarget.User(user),MentionTarget.Everyone),resolved)
        assertTrue(runCatching {resolveChatMentions("member,other",true) {user}}.exceptionOrNull()!!.message!!.contains("重复"))
        assertTrue(runCatching {resolveChatMentions("member",false) {error("must not run")}}.exceptionOrNull()!!.message!!.contains("仅群聊"))
        assertTrue(runCatching {resolveChatMentions((1..21).joinToString(","),true) {error("must not run")}}.exceptionOrNull()!!.message!!.contains("20"))
        assertEquals("无法解析提及对象，请检查公开 ID 后重试",runCatching {resolveChatMentions("member",true) {error("secret implementation error")}}.exceptionOrNull()!!.message)
        assertTrue(resolveChatMentions(" , \n",false) {error("must not run")}.isEmpty())
    }
}
