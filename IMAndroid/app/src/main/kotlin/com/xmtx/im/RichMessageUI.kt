package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.*
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*

internal fun richDisplayText(text: String,rich: MessageRichContent,reveal: Boolean): String {
    if(reveal || rich.entities.none {it.kind==RichTextKind.spoiler}) return text
    val chars=text.toCharArray()
    rich.entities.filter {it.kind==RichTextKind.spoiler}.forEach {e->for(i in e.offsetUTF16 until e.offsetUTF16+e.lengthUTF16) if(chars[i]!='\n') chars[i]='•'}
    return chars.concatToString()
}
internal fun annotatedMessage(text: String,rich: MessageRichContent,reveal: Boolean,links: Boolean,primary: Color,codeBackground: Color,open: (String)->Unit): AnnotatedString {
    rich.validate(text)
    val shown=richDisplayText(text,rich,reveal)
    val points=(listOf(0,text.length)+rich.entities.flatMap {listOf(it.offsetUTF16,it.offsetUTF16+it.lengthUTF16)}).distinct().sorted()
    return buildAnnotatedString {
        append(shown)
        points.zipWithNext().forEach {(start,end)->
            if(start==end) return@forEach
            val active=rich.entities.filter {it.offsetUTF16<=start && it.offsetUTF16+it.lengthUTF16>=end}
            val kinds=active.map {it.kind}.toSet();val hidden=!reveal && RichTextKind.spoiler in kinds
            val link=active.lastOrNull {it.kind==RichTextKind.link}?.linkURL?.takeUnless {hidden}
            val decorations=buildList {if(RichTextKind.underline in kinds || link!=null) add(TextDecoration.Underline);if(RichTextKind.strikethrough in kinds) add(TextDecoration.LineThrough)}
            val code=RichTextKind.code in kinds || RichTextKind.preformatted in kinds
            addStyle(SpanStyle(fontWeight=if(RichTextKind.bold in kinds) FontWeight.Bold else null,fontStyle=if(RichTextKind.italic in kinds) FontStyle.Italic else null,
                fontFamily=if(code) FontFamily.Monospace else null,background=if(code || hidden) codeBackground else Color.Unspecified,
                color=if(link!=null) primary else Color.Unspecified,textDecoration=if(decorations.isEmpty()) null else TextDecoration.combine(decorations)),start,end)
            if(link!=null && links) addLink(LinkAnnotation.Url(link,linkInteractionListener={open(link)}),start,end)
        }
    }
}
@Composable internal fun RichMessageText(message: Message,active: Boolean=true,preview: Boolean=false) {
    val foreground=rememberReadForeground();val allowed=active && foreground && !preview && !message.withdrawn && !message.redacted
    val rich=message.rich ?: MessageRichContent.Empty
    var revealed by remember(message.roomId,message.id,message.revision,message.text,rich) {mutableStateOf(false)}
    var feedback by remember(message.id,message.revision) {mutableStateOf<String?>(null)}
    LaunchedEffect(allowed) {if(!allowed) {revealed=false;feedback=null}}
    val valid=remember(message.text,rich) {runCatching {rich.validate(message.text)}.isSuccess}
    val uri=LocalUriHandler.current;val currentAllowed by rememberUpdatedState(allowed)
    val text=if(message.redacted) "消息已由管理员移除" else if(message.withdrawn) "消息已撤回" else message.text
    val effective=if(message.withdrawn || message.redacted) MessageRichContent.Empty else rich
    val annotated=if(valid || message.withdrawn || message.redacted) annotatedMessage(text,effective,revealed && allowed,allowed,MaterialTheme.colorScheme.primary,MaterialTheme.colorScheme.surfaceVariant) {url->
        if(currentAllowed) try {uri.openUri(url)} catch(_:Exception) {feedback="无法打开链接"}
    } else AnnotatedString("消息格式无效")
    Column(verticalArrangement=Arrangement.spacedBy(4.dp)) {
        Text(annotated,style=if(preview) MaterialTheme.typography.bodySmall else MaterialTheme.typography.bodyLarge,
            maxLines=if(preview) 2 else Int.MAX_VALUE,overflow=TextOverflow.Ellipsis,modifier=Modifier.testTag(if(preview) "reply-preview-text" else "rich-message-${message.id.value}"))
        if(!preview && valid && !message.withdrawn && !message.redacted && rich.entities.any {it.kind==RichTextKind.spoiler}) TextButton(onClick={revealed=!revealed},enabled=allowed) {Text(if(revealed && allowed) "隐藏剧透内容" else "显示隐藏内容")}
        feedback?.let {Text(it,style=MaterialTheme.typography.labelSmall)}
    }
}
@Composable internal fun MessageReplyReference(message: Message,source: Message?,active: Boolean,jump: (() -> Unit)?) {
    if(message.withdrawn || message.redacted || message.rich?.replyTo==null) return
    val target=source?.takeIf {it.id==message.rich?.replyTo && it.roomId==message.roomId && !it.withdrawn && !it.redacted && it.delivery==Delivery.Accepted}
    if(target==null) Text("回复的消息当前不可用",style=MaterialTheme.typography.labelSmall)
    else OutlinedCard(onClick={jump?.invoke()},enabled=active && jump!=null,modifier=Modifier.fillMaxWidth().testTag("reply-reference-${message.id.value}")) {
        Column(Modifier.padding(8.dp)) {Text("回复消息",style=MaterialTheme.typography.labelSmall);RichMessageText(target,active=false,preview=true)}
    }
}
