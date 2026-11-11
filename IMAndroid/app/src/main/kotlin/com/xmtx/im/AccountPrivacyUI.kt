package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.xmtx.im.client.*
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch

private val PreferenceKind.title get() = when(this) {
    PreferenceKind.StrangerMessages -> "陌生人消息"; PreferenceKind.UserAdd -> "被添加权限"; PreferenceKind.ReadReceipts -> "已读回执"; PreferenceKind.LiveActivity -> "在线与输入状态"
}
@Composable internal fun AccountPrivacyPage(state: AppState, session: SessionUi.SignedIn, model: AppViewModel, active: Boolean, openBlacklist: () -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(active, lifecycle) { if(active) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { model.refreshPreferences(); awaitCancellation() } }
    val scope = rememberCoroutineScope(); var busy by remember { mutableStateOf(false) }
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    val works = state.snapshot.preferenceOperations
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("设置对当前账号生效，不会删除已有聊天或好友关系。") }
        if(state.preferenceLoading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        PreferenceKind.entries.forEach { kind ->
            val confirmed = if(session.demo) state.demoPreferences.firstOrNull { it.kind == kind } else state.snapshot.preferences.firstOrNull { it.value.kind == kind }?.value
            val pending = works.firstOrNull { it.patch.kind == kind && !it.terminal }
            val desired = pending?.command?.value
            val first = if(desired?.first == false || pending?.patch?.first == false) false else confirmed?.first
            val second = if(desired?.second == false || pending?.patch?.second == false) false else confirmed?.second
            val enabled = confirmed != null && pending == null && !busy && !state.preferenceLoading
            item { Text(kind.title, style = MaterialTheme.typography.titleMedium) }
            val firstTitle = when(kind) { PreferenceKind.StrangerMessages -> "允许陌生人发来消息"; PreferenceKind.UserAdd -> "允许别人添加我"; PreferenceKind.ReadReceipts -> "分享私聊已读回执"; PreferenceKind.LiveActivity -> "分享在线状态" }
            item { PrivacySwitch(firstTitle, first, enabled) { value -> act { model.changePreference(PreferencePatch(kind, first = value)) } } }
            if(kind in setOf(PreferenceKind.ReadReceipts, PreferenceKind.LiveActivity)) {
                val secondTitle = if(kind == PreferenceKind.ReadReceipts) "分享群聊已读回执" else "分享正在输入状态"
                item { PrivacySwitch(secondTitle, second, enabled) { value -> act { model.changePreference(PreferencePatch(kind, second = value)) } } }
            }
            if(pending != null) item { Text("修改尚待确认，当前不会提前开启对外共享。", style = MaterialTheme.typography.bodySmall) }
        }
        item { Text("共享许可适用于账号；实际状态由支持该功能的在线设备发布。", style = MaterialTheme.typography.bodySmall) }
        item { Row { TextButton(onClick = { act { model.refreshPreferences() } }, enabled = !busy && !state.preferenceLoading) { Text("刷新设置") }; TextButton(onClick = openBlacklist) { Text("黑名单") } } }
        items(works.filter { it.status != PreferenceStatus.DraftCancelled }, key = { it.operation }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(work.patch.kind.title, style = MaterialTheme.typography.titleSmall)
                Text(work.patch.description)
                Text(when(work.status) {
                    PreferenceStatus.DraftReady -> "修改已保存，正在读取当前设置"
                    PreferenceStatus.DraftPaused -> "尚未提交，需要重新确认或取消"
                    PreferenceStatus.DraftCancelled -> "已取消"
                    PreferenceStatus.Pending -> "正在核对原修改结果"
                    PreferenceStatus.NeedsAttention -> "结果尚未确认，请继续核对"
                    PreferenceStatus.Committed -> "修改已确认"
                    PreferenceStatus.Conflicted -> "设置已在别处修改，请刷新后重新选择"
                    PreferenceStatus.Rejected -> "修改被拒绝，请刷新后重试"
                    PreferenceStatus.Closed -> "原修改已关闭，可重新选择"
                })
                Row {
                    if(work.status == PreferenceStatus.DraftPaused) TextButton(onClick = { act { model.reconfirmPreference(work.operation) } }, enabled = !busy) { Text("重新确认") }
                    if(!work.terminal && work.command == null) TextButton(onClick = { act { model.discardPreference(work.operation) } }, enabled = !busy) { Text("取消修改") }
                    if(work.status == PreferenceStatus.NeedsAttention) TextButton(onClick = { act { model.retryPreference(work.operation) } }, enabled = !busy) { Text("继续核对") }
                }
            } }
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
@Composable private fun PrivacySwitch(title: String, checked: Boolean?, enabled: Boolean, change: (Boolean) -> Unit) {
    ListItem(headlineContent = { Text(title) }, supportingContent = if(checked == null) ({ Text("尚未读取当前设置") }) else null,
        trailingContent = { Switch(checked = checked == true, onCheckedChange = change, enabled = enabled, modifier = Modifier.semantics { contentDescription = title }) })
}

private val PreferencePatch.description: String get() = buildList {
    first?.let { add(when(kind) {
        PreferenceKind.StrangerMessages -> "陌生人消息"; PreferenceKind.UserAdd -> "被添加权限"
        PreferenceKind.ReadReceipts -> "私聊已读回执"; PreferenceKind.LiveActivity -> "在线状态"
    } + "：" + if(it) "开启" else "关闭") }
    second?.let { add((if(kind == PreferenceKind.ReadReceipts) "群聊已读回执" else "输入状态") + "：" + if(it) "开启" else "关闭") }
}.joinToString("；")
