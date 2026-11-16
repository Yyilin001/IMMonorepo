package dev.local.ripple

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.collections.immutable.toPersistentList

fun copyText(context: Context, label: String, value: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, value))
    android.widget.Toast.makeText(context, "${label}已复制", android.widget.Toast.LENGTH_SHORT).show()
}

@Composable fun MePage(store: ImStore, nav: (Route) -> Unit, monitor: () -> Unit) {
    val me by store.me.ui()
    val notes by store.notes.ui()
    var about by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(Mist)) {
        Header("我") { Action(Icons.Rounded.Settings, "设置") { nav(Settings) } }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(18.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Panel {
                Row(Modifier.fillMaxWidth().clickable { nav(Profile) }, verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Avatar(9, me.name, 64)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Label(me.name, 22, bold = true); Label("账号：ripple_me", 13, Muted)
                        Label(me.bio.ifBlank { "还没有填写签名" }, 14, Muted)
                    }
                    Icon(Icons.Rounded.ChevronRight, "我的资料", tint = Muted)
                }
            }
            Panel { Info("好友", "${number(7499 - notes.values.count { it.deleted })} 位"); Info("群聊", "2,501 个") }
            Panel {
                LinkRow("编辑资料", icon = Icons.Rounded.Edit) { nav(EditProfile) }
                LinkRow("运行监控", icon = Icons.Rounded.Tune, click = monitor)
                LinkRow("关于涟漪", icon = Icons.Rounded.Info) { about = true }
            }
            Label("当前为本地体验账号，资料修改在重启后恢复默认。", 12, Muted)
        }
    }
    if (about) About { about = false }
}

@Composable private fun Identity(id: Int, name: String, account: String, group: Boolean = false) {
    val context = LocalContext.current
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Avatar(id, name, 76, group); Label(name, 23, bold = true)
        TextButton({ copyText(context, "账号", account) }) { Text("账号：$account"); Icon(Icons.Rounded.ContentCopy, "复制账号", Modifier.size(15.dp)) }
    }
}
@Composable fun MyProfilePage(store: ImStore, nav: (Route) -> Unit, back: () -> Unit) {
    val me by store.me.ui()
    FormPage("我的资料", back, { Action(Icons.Rounded.Settings, "设置") { nav(Settings) } }) {
        Identity(9, me.name, "ripple_me")
        Panel { Info("昵称", me.name); Info("地区", me.region); Info("个性签名", me.bio) }
        Button({ nav(EditProfile) }, Modifier.fillMaxWidth()) { Text("编辑资料") }
    }
}
@Composable private fun Field(label: String, value: String, limit: Int, lines: Int = 1, type: KeyboardType = KeyboardType.Text,
                              change: (String) -> Unit) {
    OutlinedTextField(value, { if (it.codePointCount(0, it.length) <= limit) change(it) }, Modifier.fillMaxWidth(),
        label = { Text(label) }, minLines = lines, singleLine = lines == 1,
        keyboardOptions = KeyboardOptions(keyboardType = type))
}
@Composable fun EditProfilePage(store: ImStore, back: () -> Unit) {
    val me = store.me.value
    var name by rememberSaveable { mutableStateOf(me.name) }
    var region by rememberSaveable { mutableStateOf(me.region) }
    var bio by rememberSaveable { mutableStateOf(me.bio) }
    var error by rememberSaveable { mutableStateOf(false) }
    FormPage("编辑资料", back, { TextButton({
        if (name.isBlank()) error = true else { store.setProfile(MyProfile(name.trim(), region.trim(), bio.trim())); back() }
    }) { Text("保存") } }) {
        Field("昵称", name, 24) { name = it; error = false }
        if (error) Label("请输入昵称", color = MaterialTheme.colorScheme.error)
        Field("地区", region, 32) { region = it }; Field("个性签名", bio, 120, 3) { bio = it }
        Label("个人资料仅在本次运行中保留。", 13, Muted)
    }
}
@Composable fun ContactPage(store: ImStore, id: Int, nav: (Route) -> Unit, back: () -> Unit) {
    val notes by store.notes.ui()
    val note = notes[id] ?: Note()
    val name = note.remark.ifEmpty { originalName(id) }
    val group = isGroup(id)
    val context = LocalContext.current
    FormPage(if (group) "群聊资料" else "个人资料", back,
        { Action(Icons.Rounded.MoreHoriz, "资料设置") { nav(ContactOptions(id)) } }) {
        Identity(id, name, handle(id), group)
        if (note.deleted) {
            Label("已删除该联系人", color = Muted)
            Button({ store.setNote(id, note.copy(deleted = false)) }, Modifier.fillMaxWidth()) { Text("重新添加联系人") }
            TextButton({ nav(Chat(id)) }) { Text("查看已有聊天记录") }
        } else Button({ nav(Chat(id)) }, Modifier.fillMaxWidth().heightIn(min = 50.dp)) { Text(if (group) "进入群聊" else "发消息") }
        if (group) GroupMembers(store, id, nav)
        Label("备注与联系信息", 14, Muted, true)
        Panel {
            if (!note.deleted) LinkRow(note.remark.ifEmpty { "设置备注与标签" },
                note.tags.joinToString(" · ").ifEmpty { "添加标签、联系方式和补充说明" }, Icons.Rounded.EditNote) { nav(EditNote(id)) }
            else { Info("原备注", note.remark); if (note.tags.isNotEmpty()) Info("标签", note.tags.joinToString(" · ")) }
            if (note.phone.isNotEmpty()) LinkRow("电话号码", note.phone, Icons.Rounded.Phone) { copyText(context, "电话号码", note.phone) }
            if (note.description.isNotEmpty()) Info("补充说明", note.description)
        }
        Label("基本资料", 14, Muted, true)
        Panel {
            Info(if (group) "群名称" else "昵称", originalName(id))
            if (!group) Info("地区", listOf("杭州", "上海", "成都", "深圳", "北京", "苏州")[id % 6])
            Info(if (group) "群介绍" else "个性签名", if (group) "欢迎来到${name}，在这里分享日常、交流想法。"
                else listOf("保持好奇，慢慢成长。","认真生活，也享受日常。","有空一起喝杯咖啡。","分享想法，保持联系。")[id % 4])
        }
        Label("更多信息", 14, Muted, true)
        Panel {
            Info("来源", if (group) "通过邀请加入群聊" else listOf("通过账号搜索添加", "通过联系人推荐添加", "通过群聊添加")[id % 3])
            Info(if (group) "加入时间" else "添加时间", "2026年10月${1 + id % 28}日")
        }
    }
}

@Composable private fun GroupMembers(store: ImStore, id: Int, nav: (Route) -> Unit) {
    val me by store.me.ui()
    val notes by store.notes.ui()
    var expanded by rememberSaveable { mutableStateOf(false) }
    val count = memberCount(id)
    Panel {
        Label("群成员 · $count", 16, bold = true)
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val columns = (maxWidth.value / 76f).toInt().coerceIn(1, 6)
            val visible = if (expanded) count else minOf(columns * 2, count)
            Column {
                for (row in (0 until visible).chunked(columns)) {
                    Row(Modifier.fillMaxWidth()) {
                        for (index in row) {
                            val member = if (index == 0) 9 else memberAt(id, index)
                            val name = if (index == 0) me.name else notes[member]?.remark?.ifEmpty { originalName(member) } ?: originalName(member)
                            Column(Modifier.weight(1f).clickable { nav(if (index == 0) Profile else Contact(member)) }
                                .padding(vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                                Avatar(member, name, 38, false); Label(name, 11, lines = 1)
                            }
                        }
                        repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
                if (count > columns * 2) TextButton({ expanded = !expanded }) { Text(if (expanded) "收起成员" else "查看全部成员") }
            }
        }
    }
}

@Composable fun NotesPage(store: ImStore, id: Int, back: () -> Unit) {
    val n = store.notes.value[id] ?: Note()
    var remark by rememberSaveable { mutableStateOf(n.remark) }
    var tags by rememberSaveable { mutableStateOf(n.tags.joinToString("，")) }
    var phone by rememberSaveable { mutableStateOf(n.phone) }
    var desc by rememberSaveable { mutableStateOf(n.description) }
    var error by rememberSaveable { mutableStateOf("") }
    FormPage("备注与标签", back, { TextButton({
        val parts = tags.split(',', '，','、',';','；').map(String::trim).filter(String::isNotEmpty).distinct()
        error = when {
            parts.size > 6 -> "最多添加 6 个标签"
            parts.any { it.codePointCount(0, it.length) > 12 } -> "每个标签最多 12 个字"
            else -> ""
        }
        if (error.isEmpty()) { store.setNote(id, n.copy(remark = remark.trim(), tags = parts.toPersistentList(), phone = phone.trim(), description = desc.trim())); back() }
    }) { Text("保存") } }) {
        Label("${if (isGroup(id)) "群名" else "昵称"}：${originalName(id)}", color = Muted)
        Field("备注名", remark, 24) { remark = it }
        Field("标签", tags, 100) { tags = it }
        if (error.isNotEmpty()) Label(error, color = MaterialTheme.colorScheme.error)
        if (!isGroup(id)) Field("电话号码", phone, 32, type = KeyboardType.Phone) { phone = it }
        Field("补充说明", desc, 200, 4) { desc = it }
    }
}
@Composable fun ContactSettings(store: ImStore, id: Int, nav: (Route) -> Unit, back: () -> Unit) {
    val notes by store.notes.ui()
    val note = notes[id] ?: Note()
    var deleting by rememberSaveable { mutableStateOf(false) }
    FormPage("资料设置", back) {
        if (!note.deleted) Panel { LinkRow("备注与标签", "填写只对自己可见的联系信息", Icons.Rounded.Edit) { nav(EditNote(id)) } }
        ConversationToggles(store, id)
        Label("置顶与免打扰仅在本次运行中保留。", 13, Muted)
        if (!isGroup(id)) TextButton({ if (note.deleted) store.setNote(id, note.copy(deleted = false)) else deleting = true }) {
            Text(if (note.deleted) "重新添加联系人" else "删除联系人", color = MaterialTheme.colorScheme.error)
        }
    }
    if (deleting) Confirm("删除联系人？", "将从通讯录移除，已有会话、聊天记录和备注会保留。", "删除", { deleting = false }) {
        store.setNote(id, note.copy(deleted = true)); deleting = false; back()
    }
}
