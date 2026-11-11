package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*

internal fun formatName(kind: RichTextKind)=when(kind) {
    RichTextKind.bold->"加粗";RichTextKind.italic->"斜体";RichTextKind.underline->"下划线";RichTextKind.strikethrough->"删除线"
    RichTextKind.spoiler->"剧透";RichTextKind.code->"行内代码";RichTextKind.preformatted->"预格式文本";RichTextKind.link->"链接"
}
@Composable internal fun ComposeContentScreen(app: AppState,room: RoomId,active: Boolean,edit: (String,String,MessageRichContent)->Unit,mentions: (String,String)->Unit,openSources: (RoomId)->MessageSourceSession?={null}) {
    val state=app.chatComposer?.takeIf {it.room==room};val foreground=rememberReadForeground()
    val allowed=active && foreground && room !in app.snapshot.revokedRooms && state?.available==true && state.draft!=null && !state.loading && !state.sending && !state.contentLocked && state.sendingPolicy.allowsNewContent
    val replySources=rememberMessageSources(room,state?.rich?.replyTo?.let {persistentSetOf(it)} ?: persistentSetOf(),app,active,openSources)
    val group=app.snapshot.conversations.any {it.id==room && it.kind==RoomKind.Group}
    var field by remember(state?.id) {mutableStateOf(TextFieldValue(state?.text.orEmpty()))}
    LaunchedEffect(state?.text) {val text=state?.text.orEmpty();if(field.text!=text) field=TextFieldValue(text,TextRange(field.selection.start.coerceAtMost(text.length),field.selection.end.coerceAtMost(text.length)))}
    var menu by remember {mutableStateOf(false)};var link by remember {mutableStateOf(false)}
    var url by rememberSaveable(room.value,state?.id) {mutableStateOf("")}
    var handles by rememberSaveable(room.value,state?.id) {mutableStateOf("")}
    var error by remember(state?.id) {mutableStateOf<String?>(null)}
    LaunchedEffect(allowed) {if(!allowed) {menu=false;link=false}}
    fun format(kind:RichTextKind,target:String?=null) {
        val value=state ?: return
        if(!allowed || field.text!=value.text || field.selection.collapsed) return
        try {
            val entity=if(kind==RichTextKind.link) RichTextEntity.link(field.selection.min,field.selection.max-field.selection.min,requireNotNull(target)) else RichTextEntity(field.selection.min,field.selection.max-field.selection.min,kind)
            val rich=value.rich.copy(entities=if(entity in value.rich.entities) value.rich.entities.remove(entity) else value.rich.entities.add(entity))
            rich.validate(value.text);edit(value.id,value.text,rich);error=null
        } catch(_:Exception) {error="无法应用格式，请检查选区、链接或格式数量"}
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
        state?.sendingPolicy?.restriction?.let {Text(it,style=MaterialTheme.typography.bodySmall)}
        Text("选中文字后应用格式，修改会自动保存到当前草稿。",style=MaterialTheme.typography.bodySmall)
        if(state==null || state.loading || state.resolvingMentions) LinearProgressIndicator(Modifier.fillMaxWidth())
        OutlinedTextField(field,{next->
            if(next.text.toByteArray(Charsets.UTF_8).size>32768) {error="正文最多 32768 UTF-8 字节";return@OutlinedTextField}
            field=next
            if(state!=null && allowed && next.text!=state.text) try {edit(state.id,next.text,rebaseRichContent(state.text,next.text,state.rich));error=null} catch(_:Exception) {error="文字范围无效"}
        },enabled=allowed,label={Text("消息正文")},minLines=4,maxLines=10,modifier=Modifier.fillMaxWidth().testTag("rich-draft-input"))
        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            Box {
                OutlinedButton(onClick={menu=true},enabled=allowed && !field.selection.collapsed) {Text("选区格式")}
                DropdownMenu(expanded=menu,onDismissRequest={menu=false}) {
                    RichTextKind.entries.forEach {kind->DropdownMenuItem(text={Text(formatName(kind))},onClick={menu=false;if(kind==RichTextKind.link) link=true else format(kind)})}
                }
            }
            TextButton(onClick={state?.let {edit(it.id,it.text,it.rich.copy(entities=persistentListOf()))}},enabled=allowed && state?.rich?.entities?.isNotEmpty()==true) {Text("清除格式")}
        }
        if(state!=null) {
            if(state.rich.entities.isNotEmpty()) {
                Text("预览 · ${state.rich.entities.size} 个格式片段",style=MaterialTheme.typography.labelLarge)
                OutlinedCard(Modifier.fillMaxWidth()) {Box(Modifier.padding(12.dp)) {
                    RichMessageText(Message(MessageId(state.id),room,(app.session as? SessionUi.SignedIn)?.user ?: UserId(state.id),state.text,0,rich=state.rich),active=allowed)
                }}
            }
            val target=state.rich.replyTo?.let {replySources.state.messages[it]}
            if(state.rich.replyTo!=null) {
                Text("正在回复",style=MaterialTheme.typography.labelLarge)
                if(target!=null) RichMessageText(target,preview=true) else if(replySources.state.loading) Text("正在读取回复消息…") else Text("回复的消息当前不可用")
                replySources.state.feedback?.let {Text(it);TextButton(onClick=replySources.retry) {Text("重试读取消息")}}
                TextButton(onClick={edit(state.id,state.text,state.rich.copy(replyTo=null))},enabled=allowed) {Text("取消回复")}
            }
            HorizontalDivider()
            Text("提及",style=MaterialTheme.typography.titleMedium)
            if(group) {
                OutlinedTextField(handles,{handles=it},label={Text("公开 ID，逗号或换行分隔")},supportingText={Text("最多 20 个目标；@all 提及所有人，实际权限由群聊决定。")},enabled=allowed && !state.resolvingMentions,modifier=Modifier.fillMaxWidth().testTag("mention-handles"))
                OutlinedButton(onClick={mentions(state.id,handles)},enabled=allowed && !state.resolvingMentions) {Text("应用提及")}
            } else Text("仅群聊支持提及成员",style=MaterialTheme.typography.bodySmall)
            if(state.rich.mentions.isNotEmpty()) {
                Text(mentionedSummary(state.rich),Modifier.testTag("draft-mentions"))
                TextButton(onClick={edit(state.id,state.text,state.rich.copy(mentions=persistentListOf()))},enabled=allowed && !state.resolvingMentions) {Text("清除提及")}
            }
            if(state.saving) Text("正在保存草稿…")
            state.feedback?.let {Text(it,Modifier.testTag("rich-draft-feedback"),style=MaterialTheme.typography.bodySmall)}
        }
        error?.let {Text(it,style=MaterialTheme.typography.bodySmall)}
    }
    if(link) AlertDialog(onDismissRequest={link=false},title={Text("链接地址")},text={OutlinedTextField(url,{url=it},label={Text("HTTP 或 HTTPS 地址")},modifier=Modifier.testTag("rich-link-input"))},
        confirmButton={TextButton(onClick={format(RichTextKind.link,url.trim());link=false},enabled=allowed) {Text("应用链接")}},dismissButton={TextButton(onClick={link=false}) {Text("取消")}})
}
