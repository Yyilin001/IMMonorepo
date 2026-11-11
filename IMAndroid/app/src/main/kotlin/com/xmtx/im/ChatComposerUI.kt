package com.xmtx.im

import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.xmtx.im.client.*

@Composable internal fun ChatComposerBar(room: RoomId,state: ChatComposerState?,enabled: Boolean,
    edit: (String,String)->Unit,beginPick: (String)->Boolean,picked: (String,android.net.Uri?)->Unit,pickerFailed: (String)->Unit,
    remove: (String,String)->Unit,send: (String)->Unit,retry: (String)->Unit,
    beginDocument: (String)->Boolean={ false },documentPicked: (String,android.net.Uri?)->Unit={ _,_-> },
    takePicture: (String,(android.net.Uri)->Unit)->Unit={ _,_-> },captured: (String,Boolean)->Unit={ _,_-> },pickedPhotos: ((String,List<android.net.Uri>)->Unit)?=null,
    openImage: ((String)->Unit)?=null,move: ((String,String,Int)->Unit)?=null,openContent: (()->Unit)?=null,cancelReply: ((String)->Unit)?=null,openChatResources: (()->Unit)?=null) {
    var pickerOwner by rememberSaveable(room.value) { mutableStateOf<String?>(null) }
    val launcher=rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> pickerOwner?.let { picked(it,uri) };pickerOwner=null }
    val remaining=(10-(state?.resources?.size ?: 0)).coerceIn(1,10)
    val multipleLauncher=rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(remaining.coerceAtLeast(2))) { uris -> pickerOwner?.let { pickedPhotos?.invoke(it,uris) };pickerOwner=null }
    var documentOwner by rememberSaveable(room.value) { mutableStateOf<String?>(null) }
    var cameraOwner by rememberSaveable(room.value) { mutableStateOf<String?>(null) }
    val documentLauncher=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> documentOwner?.let { documentPicked(it,uri) };documentOwner=null }
    val cameraLauncher=rememberCameraCaptureLauncher { success -> cameraOwner?.let { captured(it,success) };cameraOwner=null }
    var attachmentsMenu by remember { mutableStateOf(false) }
    val value=state?.takeIf { it.room==room };val available=enabled && value?.available==true && value.draft!=null && !value.loading
    val canCompose=available && value?.sendingPolicy?.allowsNewContent==true
    LaunchedEffect(canCompose) { if(!canCompose) attachmentsMenu=false }
    val context=LocalContext.current
    Surface { Column(Modifier.fillMaxWidth().padding(8.dp)) {
        if(value==null || value.loading || value.preparing) LinearProgressIndicator(Modifier.fillMaxWidth())
        value?.sendingPolicy?.restriction?.let {Text(it,style=MaterialTheme.typography.labelSmall)}
        value?.capabilityFeedback?.let {Text(it,style=MaterialTheme.typography.labelSmall)}
        value?.progress?.let { Text("正在准备附件 ${it.completed}/${it.total}",style=MaterialTheme.typography.labelSmall) }
        if(value!=null && value.resources.isNotEmpty()) LazyRow(horizontalArrangement=Arrangement.spacedBy(8.dp),modifier=Modifier.fillMaxWidth().testTag("composer-attachments")) {
            items(value.resources,key={ it.asset }) { attachment ->
                OutlinedCard { Column { Row(Modifier.padding(start=12.dp),verticalAlignment=Alignment.CenterVertically) {
                    if(!attachment.imported && attachment.contentType.startsWith("image/")) Box(Modifier.clickable(enabled=available && !value.preparing && !value.picking && !value.sending && attachment.asset !in value.unavailable && openImage!=null,onClickLabel="查看草稿图片",role=Role.Button) { openImage?.invoke(attachment.asset) }.semantics { contentDescription="查看${attachment.displayName}" }.testTag("open-draft-image-${attachment.asset}")) {
                        DraftThumbnail(attachment.asset,value.thumbnails[attachment.asset],available && attachment.asset !in value.unavailable)
                    }
                    Column(Modifier.widthIn(max=160.dp).padding(horizontal=4.dp)) {
                        Text(attachment.displayName,maxLines=1,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.labelLarge)
                        Text(if(attachment.asset in value.unavailable) {if(attachment.imported) "来源不可用，请移除" else "原件不可用，请移除"} else if(attachment.imported) "聊天附件 · ${Formatter.formatShortFileSize(context,attachment.byteCount)}" else if(attachment.asset in value.thumbnailFailures) "无法预览 · ${Formatter.formatShortFileSize(context,attachment.byteCount)}" else Formatter.formatShortFileSize(context,attachment.byteCount),style=MaterialTheme.typography.labelSmall)
                    }
                    IconButton(onClick={ remove(value.id,attachment.asset) },enabled=available && !value.sending && !value.preparing && !value.contentLocked,modifier=Modifier.testTag("remove-attachment-${attachment.asset}")) { Icon(Icons.Outlined.Close,"移除${attachment.displayName}") }
                }
                    if(move!=null && value.resources.size>1) Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                        val index=value.resources.indexOf(attachment);val canMove=available && !value.preparing && !value.picking && !value.sending && !value.contentLocked
                        IconButton(onClick={ move(value.id,attachment.asset,-1) },enabled=canMove && index>0,modifier=Modifier.testTag("draft-move-back-${attachment.asset}")) { Icon(Icons.AutoMirrored.Outlined.ArrowBack,"前移附件") }
                        Text("${index+1}/${value.resources.size}",style=MaterialTheme.typography.labelSmall)
                        IconButton(onClick={ move(value.id,attachment.asset,1) },enabled=canMove && index<value.resources.lastIndex,modifier=Modifier.testTag("draft-move-forward-${attachment.asset}")) { Icon(Icons.AutoMirrored.Outlined.ArrowForward,"后移附件") }
                    }
                } }
            }
        }
        value?.feedback?.let { feedback -> Row(verticalAlignment=Alignment.CenterVertically) {
            Text(feedback,Modifier.weight(1f),style=MaterialTheme.typography.labelSmall)
            if(feedback.contains("重试")) TextButton(onClick={ retry(value.id) },enabled=available && !value.sending) { Text("重试") }
        } }
        if(value!=null && (openContent!=null || value.rich.replyTo!=null || value.rich.mentions.isNotEmpty())) Row(verticalAlignment=Alignment.CenterVertically) {
            if(openContent!=null) TextButton(onClick=openContent,enabled=canCompose && !value.sending && !value.contentLocked) {Text("编辑消息内容")}
            if(value.rich.replyTo!=null) {
                Text("正在回复",style=MaterialTheme.typography.labelSmall)
                if(cancelReply!=null) TextButton(onClick={cancelReply(value.id)},enabled=canCompose && !value.contentLocked) {Text("取消回复")}
            }
            else if(value.rich.mentions.isNotEmpty()) Text(mentionedSummary(value.rich),style=MaterialTheme.typography.labelSmall)
        }
        Row(verticalAlignment=Alignment.CenterVertically) {
            Box {
                IconButton(onClick={ attachmentsMenu=true },enabled=canCompose && value?.preparing==false && !value.picking && !value.sending && !value.contentLocked && value.resources.size<10) { Icon(Icons.Outlined.AttachFile,"添加附件") }
                DropdownMenu(expanded=attachmentsMenu,onDismissRequest={ attachmentsMenu=false }) {
                    DropdownMenuItem(text={ Text("选择图片") },onClick={
                        attachmentsMenu=false
                        if(value!=null && beginPick(value.id)) {
                            pickerOwner=value.id
                            try {
                                val request=PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                                if(pickedPhotos!=null && remaining>1) multipleLauncher.launch(request) else launcher.launch(request)
                            }
                            catch(_: Exception) { pickerOwner=null;pickerFailed(value.id) }
                        }
                    })
                    DropdownMenuItem(text={ Text("选择文件（最多 50 MB）") },onClick={
                        attachmentsMenu=false
                        if(value!=null && beginDocument(value.id)) {
                            documentOwner=value.id
                            try { documentLauncher.launch(arrayOf("*/*")) }
                            catch(_: Exception) { documentOwner=null;pickerFailed(value.id) }
                        }
                    })
                    if(openChatResources!=null) DropdownMenuItem(text={Text("从聊天附件选择")},onClick={attachmentsMenu=false;openChatResources()})
                    DropdownMenuItem(text={ Text("拍照") },onClick={
                        attachmentsMenu=false
                        if(value!=null) takePicture(value.id) { uri -> cameraOwner=value.id;cameraLauncher(uri) }
                    })
                }
            }
            OutlinedTextField(value?.text.orEmpty(),{ text -> value?.let { edit(it.id,text) } },placeholder={ Text("发送消息…") },enabled=canCompose,maxLines=5,modifier=Modifier.weight(1f).testTag("persistent-message-draft"))
            IconButton(onClick={ value?.let { send(it.id) } },enabled=canCompose && value?.preparing==false && !value.picking && !value.sending && !value.resolvingMentions && value.unavailable.isEmpty() && (value.text.isNotBlank() || value.resources.isNotEmpty())) { Icon(Icons.AutoMirrored.Outlined.Send,"发送") }
        }
        if(value?.saving==true) Text("正在保存草稿…",style=MaterialTheme.typography.labelSmall)
    } }
}

@Composable internal fun SendTasksScreen(app: AppState,room: RoomId,active: Boolean,retry: (String)->Unit,discard: (String)->Unit) {
    val allowed=active && rememberReadForeground()
    val canRetry=allowed && room !in app.snapshot.revokedRooms
    val tasks=app.snapshot.sendIntents.filter { it.intent.room==room && !it.intent.sourcesReleased }
    var confirm by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(allowed) { if(!allowed) confirm=null }
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        if(tasks.isEmpty()) item { Text("没有待处理的发送任务") }
        items(tasks,key={ it.intent.id }) { task ->
            val intent=task.intent
            OutlinedCard(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text(intent.text.ifEmpty { "附件消息" },maxLines=3,overflow=TextOverflow.Ellipsis)
                val names=intent.attachments.associate {it.id to it.displayName}
                intent.attachmentOrder.forEach { Text(names[it] ?: "导入的附件",style=MaterialTheme.typography.bodySmall) }
                Text(when(task.phase) {
                    SendIntentPhase.Preparing->"正在准备附件";SendIntentPhase.NeedsAttention->"需要处理，请重试或放弃";SendIntentPhase.Expired->"准备或绑定已过期，重试将创建新的发送任务"
                    SendIntentPhase.Confirming->when(task.recovery) {
                        SendRecoveryStatus.WaitingForNetwork->"等待网络连接后继续"
                        SendRecoveryStatus.WaitingForAuthentication->"等待登录恢复后继续"
                        else->if(task.canResumeConfirmation) "原消息结果未知，确认已暂停" else "正在确认发送结果，恢复连接后继续"
                    };SendIntentPhase.Accepted->"已受理";SendIntentPhase.Rejected->"发送被拒绝";SendIntentPhase.Closed->"消息未发送，已关闭";SendIntentPhase.Cancelled->"已取消"
                },style=MaterialTheme.typography.bodySmall)
                Row {
                    if(task.canResumeConfirmation) TextButton(onClick={retry(intent.id)},enabled=canRetry) {Text("继续确认")}
                    if(task.canReplace || task.phase==SendIntentPhase.NeedsAttention) TextButton(onClick={ retry(intent.id) },enabled=canRetry) { Text("重试") }
                    if(task.phase!=SendIntentPhase.Confirming) TextButton(onClick={ confirm=intent.id },enabled=allowed) { Text("放弃发送") }
                }
            } }
        }
    }
    confirm?.let { selected -> tasks.firstOrNull { it.intent.id==selected && it.phase!=SendIntentPhase.Confirming }?.let {
        AlertDialog(onDismissRequest={ confirm=null },title={ Text("放弃这条消息？") },text={ Text("该任务不会继续发送。附件任务将取消或清理。") },
            confirmButton={ TextButton(onClick={ confirm=null;discard(selected) },enabled=allowed) { Text("放弃发送") } },dismissButton={ TextButton(onClick={ confirm=null }) { Text("保留") } })
    } }
}
