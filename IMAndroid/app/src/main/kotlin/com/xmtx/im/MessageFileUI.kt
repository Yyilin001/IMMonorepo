package com.xmtx.im

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.core.net.toUri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentSetOf

@Composable internal fun MessageFileScreen(app: AppState,state: MessageFileState?,selection: MessageFileSelection,active: Boolean,
    begin: ()->String?,result: (String,Uri?)->Unit,pickerFailed: (String)->Unit,retry: ()->Unit,openFailed: ()->Unit,
    present: ((TemporaryFileMode)->Unit)?=null,claim: suspend (String)->Boolean={false},launched: (String)->Unit={},returned: (String)->Unit={},failed: (String)->Unit={},play: (()->Unit)?=null,openSources: (RoomId)->MessageSourceSession?={null}) {
    val context=LocalContext.current
    val sources=rememberMessageSources(selection.location.room,persistentSetOf(selection.location.message),app,active,openSources)
    val message=sources.state.messages[selection.location.message]
    val descriptor=message?.takeUnless { it.withdrawn || it.redacted || it.delivery!=Delivery.Accepted }?.media?.presentations?.firstOrNull { it.media==selection.media }?.descriptor
    val value=state?.takeIf { it.selection==selection }
    val allowed=active && rememberReadForeground() && selection.location.room !in app.snapshot.revokedRooms && descriptor!=null && value?.available==true && value.read?.matchesMessage(message,descriptor)==true
    var request by rememberSaveable(selection) { mutableStateOf<String?>(null) }
    val launcher=rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(descriptor?.contentType ?: "application/octet-stream")) { uri -> request?.let { result(it,uri) };request=null }
    var presentationOwner by rememberSaveable(selection) { mutableStateOf<String?>(null) }
    val external=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { presentationOwner?.let(returned);presentationOwner=null }
    val action=value?.action
    LaunchedEffect(action?.id,allowed,active) {
        if(action!=null && allowed && claim(action.id)) {
            presentationOwner=action.id
            try { external.launch(temporaryFileIntent(action));launched(action.id) }
            catch(_: Exception) { presentationOwner=null;failed(action.id) }
        }
    }
    Column(Modifier.fillMaxSize()) {
        if(sources.state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        sources.state.feedback?.let {Text(it,Modifier.padding(16.dp));TextButton(onClick=sources.retry) {Text("重试读取消息")}}
        MessageFileContent(descriptor,value,allowed,present=present,play=play,save={
            val id=begin()
            if(id!=null && descriptor!=null) {
                request=id
                try { launcher.launch(descriptor.displayName) } catch(_: Exception) { request=null;pickerFailed(id) }
            }
        },retry=retry,open={
            value?.savedUri?.let { location ->
                try { context.startActivity(savedDocumentIntent(location.toUri(),descriptor?.contentType ?: "application/octet-stream")) }
                catch(_: Exception) { openFailed() }
            }
        })
    }
}

internal fun temporaryFileIntent(action: TemporaryFileAction): Intent {
    val uri=action.uri.toUri();require(uri.scheme=="content")
    val intent=Intent(if(action.mode==TemporaryFileMode.Open) Intent.ACTION_VIEW else Intent.ACTION_SEND)
        .setDataAndType(uri,action.contentType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply {
            clipData=ClipData.newRawUri("文件附件",uri)
            if(action.mode==TemporaryFileMode.Share) putExtra(Intent.EXTRA_STREAM,uri)
        }
    return if(action.mode==TemporaryFileMode.Share) Intent.createChooser(intent,"分享文件") else intent
}

internal fun savedDocumentIntent(uri: Uri,contentType: String): Intent {
    require(uri.scheme=="content")
    return Intent(Intent.ACTION_VIEW).setDataAndType(uri,contentType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply { clipData=ClipData.newRawUri("已保存的附件",uri) }
}

@Composable internal fun MessageFileContent(descriptor: ResourceDescriptor?,state: MessageFileState?,allowed: Boolean,
    save: ()->Unit,retry: ()->Unit,open: ()->Unit,present: ((TemporaryFileMode)->Unit)?=null,play: (()->Unit)?=null) {
    val busy=state?.opening==true || state?.phase in setOf(FileSavePhase.Choosing,FileSavePhase.Waiting,FileSavePhase.Writing)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(16.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        Icon(Icons.AutoMirrored.Outlined.InsertDriveFile,null,Modifier.size(72.dp))
        Text(descriptor?.displayName ?: "附件当前不可用",style=MaterialTheme.typography.titleLarge)
        descriptor?.let { Text(Formatter.formatShortFileSize(LocalContext.current,it.byteCount),style=MaterialTheme.typography.bodyLarge);Text(it.contentType,style=MaterialTheme.typography.bodySmall) }
        Text(if(present==null) "将附件保存到你选择的位置，然后使用支持此格式的应用打开。" else "使用其他应用打开或分享附件，也可保存一份到文件。",style=MaterialTheme.typography.bodyMedium)
        if(busy) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(if(state?.opening==true) "正在准备临时文件…" else when(state?.phase) { FileSavePhase.Choosing->"请选择保存位置";FileSavePhase.Waiting->"返回应用后开始保存";else->"正在下载并保存文件…" })
        }
        state?.feedback?.let { Text(it,Modifier.testTag("message-file-feedback"),style=MaterialTheme.typography.bodySmall) }
        if(!allowed) Text("文件来源当前不可访问",style=MaterialTheme.typography.bodySmall)
        if(play!=null && (descriptor?.contentType?.startsWith("audio/")==true || descriptor?.contentType?.startsWith("video/")==true)) Button(play,enabled=allowed && !busy,modifier=Modifier.fillMaxWidth()) {Text("应用内播放")}
        if(present!=null) {
            Button({present(TemporaryFileMode.Open)},enabled=allowed && !busy,modifier=Modifier.fillMaxWidth()) { Text("用其他应用打开") }
            OutlinedButton({present(TemporaryFileMode.Share)},enabled=allowed && !busy,modifier=Modifier.fillMaxWidth()) { Text("分享文件") }
        }
        Button(save,enabled=allowed && !busy,modifier=Modifier.fillMaxWidth().testTag("message-file-save")) { Text("保存到文件") }
        if(state?.savedUri!=null) OutlinedButton(open,enabled=allowed && !busy,modifier=Modifier.fillMaxWidth()) { Text("打开已保存文件") }
        TextButton(retry,enabled=!busy) { Text("重新加载") }
    }
}
