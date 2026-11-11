package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.xmtx.im.client.*
import kotlinx.coroutines.launch

@Composable internal fun OwnProfileScreen(state: AppState,active: Boolean,refresh: suspend () -> ProfileView?,
    save: suspend (ProfileView,String) -> Boolean,retry: suspend (String) -> Unit,reapply: suspend (String) -> Boolean,discard: suspend (String) -> Unit,openAvatar: ()->Unit={}) {
    val session = state.session as? SessionUi.SignedIn ?: return
    val resumed = LocalLifecycleOwner.current.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val allowed = active && resumed && !session.demo
    val profile = state.snapshot.ownProfile?.takeIf { it.user == session.user }
    val avatars=state.snapshot.profileIntents.filter { it.intent.upload!=null || it.intent.serverImport!=null || it.intent.avatar!=ProfileAvatarPatch.Unchanged }.map { it.intent.operation }.toSet()
    val works = state.snapshot.ownProfileOperations.filter { it.command.actor == session.user && it.command.operation !in avatars }
    val pending = state.snapshot.ownProfileOperations.any { !it.terminal } || state.snapshot.profileIntents.any { !it.intent.locallyTerminal && it.work?.terminal!=true }
    var draft by rememberSaveable(session.user.value) { mutableStateOf("") }
    var dirty by rememberSaveable(session.user.value) { mutableStateOf(false) }
    var baseline by remember(session.user) { mutableStateOf<ProfileView?>(null) }
    var refreshKey by remember { mutableIntStateOf(0) };var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(session.user,allowed,refreshKey,state.snapshot.presentationGeneration) {
        baseline = null
        if(allowed) {
            refresh()?.let { value -> baseline = value;if(!dirty) draft = value.identity?.displayName.orEmpty() }
        }
    }
    val fresh = baseline?.takeIf { it == profile && it.state == ProfileState.Active }
    val normalized = runCatching { OwnProfilePatch.normalizedName(draft) }
    LazyColumn(Modifier.fillMaxSize(),contentPadding = PaddingValues(20.dp),verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text(profile?.identity?.displayName ?: "我的公开资料",style = MaterialTheme.typography.headlineSmall) }
        profile?.identity?.handle?.let { item { Text("@${it.value}",color = MaterialTheme.colorScheme.onSurfaceVariant) } }
        item { OutlinedButton(onClick=openAvatar,enabled=active && resumed,modifier=Modifier.fillMaxWidth()) { Text("更换头像") } }
        if(session.demo) item { Text("公开名称编辑需要登录真实账号。") }
        else if(profile != null && profile.state != ProfileState.Active) item { Text("当前资料不可编辑",color = MaterialTheme.colorScheme.error) }
        item { Text("公开名称会向有权查看你资料的人展示。",style = MaterialTheme.typography.bodyMedium) }
        item { OutlinedTextField(draft,{ draft = it;dirty = true;notice = null },label = { Text("公开名称") },singleLine = true,
            enabled = allowed && !busy,isError = dirty && normalized.isFailure,modifier = Modifier.fillMaxWidth()) }
        item { Text("名称不能为空，最多 80 个 UTF-8 字节。",style = MaterialTheme.typography.bodySmall) }
        if(fresh == null && !session.demo) item { Text("刷新当前资料后可保存；旧缓存仅供查看。") }
        if(pending) item { Text("前一笔修改正在确认，请先核对结果。") }
        item { Row {
            Button(onClick = { val value = fresh ?: return@Button;busy = true;scope.launch { try {
                if(save(value,normalized.getOrThrow())) { dirty = false;baseline = null;notice = "修改已保存，正在确认结果" }
            } finally { busy = false } } },enabled = allowed && !busy && !pending && fresh != null && normalized.isSuccess && normalized.getOrNull() != fresh.identity?.displayName) { Text("保存公开名称") }
            TextButton(onClick = { refreshKey++ },enabled = allowed && !busy) { Text("刷新资料") }
        } }
        notice?.let { item { Text(it) } };state.error?.let { item { Text(it,color = MaterialTheme.colorScheme.error) } }
        items(works.reversed(),key = { it.command.operation }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp),verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(work.command.patch.name?.let { "公开名称：$it" } ?: "头像修改")
                Text(when(work.status) {
                    OwnProfileStatus.Pending -> "正在确认修改结果"
                    OwnProfileStatus.NeedsAttention -> "结果尚未确认，请继续核对"
                    OwnProfileStatus.Committed -> "原修改已确认"
                    OwnProfileStatus.Conflicted -> "资料已被更新，原修改未生效"
                    OwnProfileStatus.Rejected -> "原修改被拒绝"
                    OwnProfileStatus.Closed -> "原操作已关闭"
                    OwnProfileStatus.Expired -> "尚未提交的修改已过期"
                })
                if(work.status == OwnProfileStatus.Committed) Text("这里显示原修改记录；当前资料以页面顶部为准。",style = MaterialTheme.typography.bodySmall)
                if(work.status == OwnProfileStatus.NeedsAttention) TextButton(onClick = { busy = true;scope.launch { try { retry(work.command.operation) } finally { busy = false } } },enabled = allowed && !busy) { Text("继续核对") }
                if(work.terminal && work.draftRetained && work.status != OwnProfileStatus.Committed) {
                    TextButton(onClick = { busy = true;scope.launch { try { if(reapply(work.command.operation)) { baseline = null;notice = "已按最新资料重新保存" } } finally { busy = false } } },enabled = allowed && !busy && !pending) { Text("按最新资料重新保存") }
                    TextButton(onClick = { busy = true;scope.launch { try { discard(work.command.operation) } finally { busy = false } } },enabled = allowed && !busy) { Text("放弃这份草稿") }
                }
            } }
        }
    }
}
