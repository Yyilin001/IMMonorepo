package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*

/** Rebase unaffected ranges around a text replacement; changed spans are removed instead of pointing at new text. */
internal fun rebaseRichContent(old: String,next: String,rich: MessageRichContent): MessageRichContent {
    if(old==next) return rich
    var start=0
    while(start<minOf(old.length,next.length) && old[start]==next[start]) start++
    if(start>0 && start<old.length && old[start-1].isHighSurrogate() && old[start].isLowSurrogate()) start--
    var before=old.length;var after=next.length
    while(before>start && after>start && old[before-1]==next[after-1]) {before--;after--}
    if(before>0 && before<old.length && old[before-1].isHighSurrogate() && old[before].isLowSurrogate()) {before++;after++}
    val delta=next.length-old.length
    val entities=rich.entities.mapNotNull {e->
        when {e.offsetUTF16+e.lengthUTF16<=start->e;e.offsetUTF16>=before->e.copy(offsetUTF16=e.offsetUTF16+delta);else->null}
    }.toPersistentList()
    return rich.copy(entities=entities).also {it.validate(next)}
}
internal suspend fun resolveChatMentions(input: String,group: Boolean,resolve: suspend (String)->UserId): PersistentList<MentionTarget> {
    val handles=input.split(',', '\n').map {it.trim()}.filter {it.isNotEmpty()}
    require(handles.isEmpty() || group) {"仅群聊支持提及成员"}
    require(handles.size<=20) {"每条消息最多提及 20 个目标"}
    val targets=handles.map {handle->
        if(handle.equals("@all",ignoreCase=true)) MentionTarget.Everyone
        else try {MentionTarget.User(resolve(handle))} catch(error: kotlinx.coroutines.CancellationException) {throw error} catch(_:Exception) {throw IllegalArgumentException("无法解析提及对象，请检查公开 ID 后重试")}
    }.toPersistentList()
    require(targets.distinct().size==targets.size) {"提及对象不能重复"}
    return targets
}
internal fun mentionedSummary(rich: MessageRichContent,user: UserId?=null): String {
    val parts=buildList {
        if(MentionTarget.Everyone in rich.mentions) add("@所有人")
        val users=rich.mentions.filterIsInstance<MentionTarget.User>()
        if(users.isNotEmpty()) add(if(user!=null && users.any {it.id==user}) "提及了你${if(users.size>1) "等 ${users.size} 位成员" else ""}" else "提及 ${users.size} 位成员")
    }
    return parts.joinToString(" · ")
}
