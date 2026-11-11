package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Immutable data class AdministrationPrompt(val room: RoomId,val target: UserId,val action: AdministrationAction,val revision: Long,
    val confirmation: AdministrationConfirmation?,val deadlineNanos: Long,val draft: String?)
@Composable internal fun AdministrationConfirmationDialog(prompt: AdministrationPrompt?,confirm: suspend () -> Unit,dismiss: () -> Unit) {
    if(prompt == null) return
    val scope = rememberCoroutineScope()
    LaunchedEffect(prompt) { while(prompt.deadlineNanos > System.nanoTime()) delay(((prompt.deadlineNanos-System.nanoTime())/1000000).coerceIn(1,30000));dismiss() }
    val mute = prompt.action as? AdministrationAction.Mute
    AlertDialog(onDismissRequest = dismiss,title = { Text(if(mute != null) "确认禁言？" else "确认管理移除？") },
        text = { Text("用户 ${prompt.target.value.takeLast(8)}\n" + if(mute != null) "禁言至 ${java.text.DateFormat.getDateTimeInstance().format(java.util.Date(mute.until))}。此操作保留管理审计记录。" else "将此成员移出群聊，并保留管理审计记录。") },
        confirmButton = { TextButton(onClick = { scope.launch { confirm() } }) { Text("确认") } },dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
@Composable internal fun AdministrationWorkCard(work: AdministrationWork,fresh: Boolean,reconfirm: () -> Unit,discard: () -> Unit,retry: () -> Unit) {
    Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp)) {
        Text("${if(work.intent.action is AdministrationAction.Mute) "成员禁言" else "管理移除"} · ${work.intent.target.value.takeLast(8)}",style = MaterialTheme.typography.titleSmall)
        Text(when(work.status) {
            AdministrationStatus.DraftReady -> "正在核对管理权限";AdministrationStatus.DraftPaused -> "尚未提交，请刷新成员后重新确认"
            AdministrationStatus.DraftCancelled -> "草稿已取消";AdministrationStatus.Pending -> "正在确认原命令"
            AdministrationStatus.NeedsAttention -> "结果尚未确定，请继续核对";AdministrationStatus.Committed -> "操作成功，成员状态由同步更新"
            AdministrationStatus.Rejected -> "操作未获允许，请刷新群状态";AdministrationStatus.Conflicted -> "成员版本变化，未覆盖新的状态"
            AdministrationStatus.Closed -> "原命令已关闭"
        })
        Row {
            if(work.status == AdministrationStatus.DraftPaused) TextButton(onClick = reconfirm,enabled = fresh) { Text("重新确认") }
            if(work.draft && !work.terminal) TextButton(onClick = discard) { Text("取消草稿") }
            if(work.status == AdministrationStatus.NeedsAttention) TextButton(onClick = retry) { Text("继续核对") }
        }
    } }
}
