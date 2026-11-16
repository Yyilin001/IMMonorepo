package dev.local.ripple

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Chat
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

@Composable fun ConversationToggles(store: ImStore, id: Int) {
    val flow = store.row(id)
    val flags by remember(flow) { flow.map { it.pinned to it.muted }.distinctUntilChanged() }
        .collectAsStateWithLifecycle(flow.value.pinned to flow.value.muted)
    Panel {
        Toggle("置顶聊天", "在会话列表顶部显示", flags.first) { store.pin(id) }
        Toggle("消息免打扰", "消息照常接收，未读标记使用灰色", flags.second) { store.mute(id) }
    }
}
@Composable private fun Backgrounds(value: Backdrop, choose: (Backdrop) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Backdrop.entries.forEach { Pill(it.label, it == value) { choose(it) } }
    }
}
@Composable fun ChatSettings(store: ImStore, id: Int, nav: (Route) -> Unit, back: () -> Unit, history: () -> Unit) {
    val notes by store.notes.ui()
    val name = notes[id]?.remark?.ifEmpty { originalName(id) } ?: originalName(id)
    val prefs by store.prefs.ui()
    val backgrounds by store.backgrounds.ui()
    FormPage("聊天设置", back) {
        Panel { LinkRow(name, if (isGroup(id)) "查看群聊资料" else "查看个人资料", Icons.Rounded.AccountCircle) { nav(Contact(id)) } }
        ConversationToggles(store, id)
        Panel { LinkRow("查看聊天记录", icon = Icons.Rounded.History, click = history) }
        Panel { Label("聊天背景", 16, bold = true); Backgrounds(backgrounds[id] ?: prefs.background) { store.setBackground(id, it) } }
    }
}
@Composable fun SettingsPage(store: ImStore, nav: (Route) -> Unit, back: () -> Unit) {
    val p by store.prefs.ui()
    var reset by rememberSaveable { mutableStateOf(false) }
    var about by rememberSaveable { mutableStateOf(false) }
    FormPage("设置", back) {
        Panel { LinkRow("编辑个人资料", "昵称、地区和个性签名", Icons.Rounded.Edit) { nav(EditProfile) } }
        Panel {
            LinkRow("聊天外观", "字体大小、默认背景与消息动画", Icons.Rounded.Palette) { nav(Appearance) }
            LinkRow("消息与隐私", "未读角标、会话内容预览", Icons.AutoMirrored.Rounded.Chat) { nav(Privacy) }
            Toggle("操作触感", "长按会话或消息时轻微振动", p.haptics) { store.setPrefs(p.copy(haptics = it)) }
        }
        Panel {
            LinkRow("关于涟漪", "版本 1.0.0", Icons.Rounded.Info) { about = true }
            LinkRow("恢复默认设置", "恢复本页偏好，保留消息和个人资料", Icons.Rounded.Restore) { reset = true }
        }
    }
    if (about) About { about = false }
    if (reset) Confirm("恢复默认设置？", "将恢复聊天外观、操作触感和消息显示偏好。", "恢复默认", { reset = false }) {
        store.setPrefs(Preferences()); reset = false
    }
}
@Composable fun AppearancePage(store: ImStore, back: () -> Unit) {
    val p by store.prefs.ui()
    FormPage("聊天外观", back) {
        Column(Modifier.fillMaxWidth().background(p.background.color, RoundedCornerShape(14.dp)).padding(18.dp)) {
            Label("涟漪", 13, Muted)
            Label("你好，这是一条预览消息。", p.size.sp, modifier = Modifier.background(White, RoundedCornerShape(12.dp)).padding(12.dp))
        }
        Panel {
            Label("字体大小", 16, bold = true)
            FlowRow { FontSize.entries.forEach { Pill(it.label, it == p.size) { store.setPrefs(p.copy(size = it)) } } }
        }
        Panel { Label("默认聊天背景", 16, bold = true); Backgrounds(p.background) { store.setPrefs(p.copy(background = it)) } }
        Panel { Toggle("新消息动画", "新消息轻微淡入；高速接收和阅读历史时自动跳过", p.animate) { store.setPrefs(p.copy(animate = it)) } }
    }
}
@Composable fun PrivacyPage(store: ImStore, back: () -> Unit) {
    val p by store.prefs.ui()
    FormPage("消息与隐私", back) { Panel {
        Toggle("显示未读总数", "在消息导航入口显示未读角标", p.badge) { store.setPrefs(p.copy(badge = it)) }
        Toggle("显示会话内容预览", "关闭后，会话列表隐藏最后一条消息内容", p.preview) { store.setPrefs(p.copy(preview = it)) }
    } }
}
