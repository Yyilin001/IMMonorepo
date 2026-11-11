package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.text.DateFormat
import java.util.Date
import java.util.UUID

@Composable internal fun DevicesPage(model: AppViewModel, demo: Boolean, active: Boolean) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var management by remember { mutableStateOf<DeviceManagement?>(null) }
    val scope = rememberCoroutineScope()
    var failure by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(active, lifecycle) {
        if(active) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val opened = model.openDevices() ?: return@repeatOnLifecycle; management = opened
            try {
                coroutineScope {
                    launch { opened.refresh() }
                    while(isActive) { opened.tick(); delay(1000) }
                }
            } finally { opened.close(); if(management === opened) management = null }
        }
    }
    val current = management
    val state = current?.state?.collectAsState()?.value ?: DeviceManagementState(loading = true)
    fun act(action: suspend () -> Unit) { scope.launch {
        try { failure = null; action() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { failure = "操作未确认，请刷新设备列表" }
    } }
    LazyColumn(Modifier.fillMaxSize().testTag("device-list"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if(demo) item { Text("离线演示 · 以下设备仅用于界面体验") }
        item { Text("仅退出本次确认列出的设备，之后登录的新设备不在范围内。") }
        item { TextButton(onClick = { current?.let { act { it.refresh() } } }, enabled = !state.loading) { Text("刷新设备") } }
        if(state.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        (failure ?: state.error)?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        if(state.baseline == null && !state.loading) item { Text("请刷新后确认设备范围。已有操作仍可继续确认。") }
        items(state.sessions, key = { it.device.value }) { device ->
            val pending = state.works.any { it.receipt == null && device.device in it.command.targets }
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(if(device.current) "${device.name} · 当前设备" else device.name, style = MaterialTheme.typography.titleMedium)
                Text(device.platform); Text(device.device.value, style = MaterialTheme.typography.bodySmall)
                Text("最近活跃：${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(device.lastActiveAt))}", style = MaterialTheme.typography.bodySmall)
                if(device.current) Text("退出当前设备请返回「我的」", style = MaterialTheme.typography.bodySmall)
                else TextButton(onClick = { current?.let { act { it.propose(device.device) } } },
                    enabled = !pending && !state.loading && device.device in (state.baseline?.targets ?: persistentListOf()),
                    modifier = Modifier.testTag("revoke/${device.device.value}")) { Text(if(pending) "等待确认" else "退出此设备") }
            } }
        }
        if(state.cursor != null) item { TextButton(onClick = { current?.let { act { it.more() } } }, enabled = !state.loadingMore && !state.loading) { Text(if(state.loadingMore) "正在加载…" else "加载更多设备") } }
        item { OutlinedButton(onClick = { current?.let { act { it.propose(null) } } }, enabled = !state.loading && state.baseline?.targets?.isNotEmpty() == true &&
            state.works.none { it.receipt == null && it.command.targets.any { target -> target in (state.baseline?.targets ?: persistentListOf()) } }) { Text("退出已观察到的其他设备") } }
        if(state.works.isNotEmpty()) item { Text("设备操作记录", style = MaterialTheme.typography.titleMedium) }
        items(state.works.reversed(), key = { it.command.operation }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp)) {
                Text("${work.command.targets.size} 台设备 · ${when(work.receipt?.outcome) {
                    DeviceRevocationOutcome.Revoked -> "已退出"; DeviceRevocationOutcome.Closed -> "已关闭，未执行退出"
                    DeviceRevocationOutcome.Rejected -> "服务端已拒绝"; null -> if(work.needsAttention) "需要继续确认" else "正在确认结果"
                }}")
                Text("操作 ${work.command.operation.takeLast(8)}", style = MaterialTheme.typography.bodySmall)
                if(work.needsAttention && work.receipt == null) TextButton(onClick = { current?.let { act { it.resume(work.command.operation) } } }) { Text("继续确认原操作") }
            } }
        }
    }
    state.prompt?.let { prompt ->
        LaunchedEffect(prompt.command.operation) {
            delay(((prompt.deadlineNanos - System.nanoTime()) / 1000000).coerceAtLeast(0)); current?.dismiss()
        }
        AlertDialog(onDismissRequest = { current?.dismiss() }, title = { Text("确认退出 ${prompt.command.targets.size} 台设备？") },
            text = { LazyColumn(Modifier.heightIn(max = 360.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item { Text("只处理以下完整列表。之后登录的新设备不在本次范围内；取消不会发起操作。") }
                items(prompt.command.targets) { id -> Column {
                    Text(state.sessions.firstOrNull { it.device == id }?.name ?: "设备（尚未加载名称）")
                    Text(id.value, style = MaterialTheme.typography.bodySmall)
                } }
            } }, confirmButton = { TextButton(onClick = { current?.let { act { it.confirm() } } }) { Text("确认退出列出的设备") } },
            dismissButton = { TextButton(onClick = { current?.dismiss() }) { Text("取消") } })
    }
}

/** Isolated UI preview only; never shared with authenticated services or platform storage. */
internal class DemoDevices : AuthenticatedTransport, SecretStore {
    val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    val current = DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private var devices = persistentListOf(current, DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"), DeviceId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
    private var journal: String? = null
    private var receipts = persistentMapOf<String, JsonObject>()
    override suspend fun read() = journal
    override suspend fun write(value: String) { journal = value }
    override suspend fun delete() { journal = null }
    override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
        val now = System.currentTimeMillis()
        val body = when {
            path.endsWith("revocation-baseline") -> DeviceRevocationBaseline(UUID.randomUUID().toString().uppercase(), actor, current,
                devices.filter { it != current }.toPersistentList(), now, now + 120000).payload()
            path == "/v2/devices" -> buildJsonObject { put("sessions", JsonArray(devices.mapIndexed { index, id -> buildJsonObject {
                put("deviceID", id.value); put("deviceName", if(id == current) "Android" else if(index == 1) "MacBook" else "iPad")
                put("platform", if(id == current) "Android" else "Apple"); put("createdAtMilliseconds", now - 3600000)
                put("lastActiveAtMilliseconds", now - 60000); put("isCurrentDevice", id == current)
            } })) }
            else -> {
                val command = DeviceRevocationCommand.decode(if(path.endsWith("submit")) requireNotNull(payload) else requireNotNull(payload).getValue("command").jsonObject)
                val receipt = receipts[command.operation] ?: buildJsonObject {
                    put("actorUserID", command.baseline.payload().getValue("actorUserID")); put("currentDeviceID", command.baseline.payload().getValue("currentDeviceID"))
                    put("operationID", command.operation); put("fingerprint", command.fingerprint); put("targetDeviceIDs", JsonArray(command.targets.map { buildJsonObject { put("rawValue", it.value) } }))
                    put("resolvedAtMilliseconds", now); put("outcome", buildJsonObject { put(if(path.endsWith("submit")) "revoked" else "closed", buildJsonObject {}) })
                }.also {
                    receipts = receipts.put(command.operation, it)
                    if(path.endsWith("submit")) devices = devices.filter { it !in command.targets }.toPersistentList()
                }
                buildJsonObject { put("receipt", buildJsonObject { put("_0", receipt) }) }
            }
        }
        return EdgeResponse(200, body)
    }
}
