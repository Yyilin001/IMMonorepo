package dev.local.ripple

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.StateFlow
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

val Ink = Color(0xFF183D32)
val Green = Color(0xFF19846A)
val Muted = Color(0xFF82928B)
val Line = Color(0xFFE7ECE9)
val Mint = Color(0xFFEDF6F0)
val Mist = Color(0xFFF3F6F5)
val White = Color.White
val Backdrop.color: Color get() = when (this) {
    Backdrop.Light -> Color(0xFFFAFCFA)
    Backdrop.Mint -> Color(0xFFEAF4EE)
    Backdrop.Warm -> Color(0xFFFAF1E5)
}
private val avatarBg = persistentListOf(0xFFDCEBDC, 0xFFF1E7DA, 0xFFE1E9F1, 0xFFECE2ED, 0xFFF0E5DB)
private val avatarFg = persistentListOf(0xFF487158, 0xFF98764D, 0xFF5C7D9A, 0xFF8C6D94, 0xFFA37F61)
private val timeFormat = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault())
fun clock(time: Long): String = timeFormat.format(Instant.ofEpochMilli(time))
fun number(n: Number) = String.format(Locale.US, "%,d", n.toLong())
@Composable fun <T> StateFlow<T>.ui() = collectAsStateWithLifecycle()
@Composable fun Label(text: String, size: Int = 14, color: Color = Ink, bold: Boolean = false,
                      modifier: Modifier = Modifier, lines: Int = Int.MAX_VALUE) =
    Text(text, modifier, color = color, fontSize = size.sp, lineHeight = (size * 1.35f).sp,
        fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal, maxLines = lines, overflow = TextOverflow.Ellipsis)

@Composable fun Avatar(id: Int, name: String, size: Int, group: Boolean = isGroup(id)) {
    Box(Modifier.size(size.dp).background(Color(avatarBg[id % 5]), RoundedCornerShape((size * .3f).dp)), Alignment.Center) {
        if (group) Icon(Icons.Rounded.Forum, null, Modifier.size((size * .47f).dp), tint = Color(avatarFg[id % 5]))
        else Label(name.take(1), (size * .38f).toInt(), Color(avatarFg[id % 5]), true)
    }
}
@Composable fun Action(icon: ImageVector, label: String, onClick: () -> Unit) =
    IconButton(onClick) { Icon(icon, label, Modifier.size(22.dp), tint = Green) }

@Composable fun Header(title: String, back: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().background(White).padding(start = if (back == null) 20.dp else 4.dp, end = 10.dp)
        .heightIn(min = if (back == null) 66.dp else 54.dp), verticalAlignment = Alignment.CenterVertically) {
        if (back != null) Action(Icons.AutoMirrored.Rounded.ArrowBack, "返回", back)
        Label(title, if (back == null) 30 else 19, bold = true, modifier = Modifier.weight(1f))
        actions()
    }
}

@Composable fun Pill(text: String, selected: Boolean, onClick: () -> Unit) {
    Box(Modifier.clip(RoundedCornerShape(8.dp)).background(if (selected) Mint else Color.Transparent)
        .clickable(onClick = onClick).padding(horizontal = 15.dp, vertical = 9.dp)) {
        Label(text, 14, if (selected) Green else Muted, selected)
    }
}
@Composable fun Panel(content: @Composable ColumnScope.() -> Unit) =
    Column(Modifier.fillMaxWidth().background(White, RoundedCornerShape(18.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp), content = content)

@Composable fun FormPage(title: String, back: () -> Unit, action: @Composable RowScope.() -> Unit = {},
                         body: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(Mist)) {
        Header(title, back, action)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp), content = body)
    }
}
@Composable fun LinkRow(title: String, detail: String = "", icon: ImageVector? = null, click: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = click).heightIn(min = 50.dp).padding(4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (icon != null) Icon(icon, null, Modifier.size(22.dp), tint = Green)
        Column(Modifier.weight(1f)) { Label(title, 16); if (detail.isNotEmpty()) Label(detail, 13, Muted) }
        Icon(Icons.Rounded.ChevronRight, null, tint = Muted)
    }
}
@Composable fun Info(key: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Label(key, 14, Muted, modifier = Modifier.widthIn(min = 66.dp))
        Label(value.ifBlank { "未填写" }, 15)
    }
}
@Composable fun Toggle(title: String, detail: String, value: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { change(!value) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Label(title, 16); Label(detail, 13, Muted) }
        Switch(value, change)
    }
}
@Composable fun Confirm(title: String, message: String, ok: String, dismiss: () -> Unit, confirm: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, title = { Label(title, 20, bold = true) }, text = { Label(message) },
        confirmButton = { TextButton(onClick = confirm) { Text(ok) } },
        dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
@Composable fun About(close: () -> Unit) {
    AlertDialog(onDismissRequest = close, title = { Label("涟漪 · Local IM", 20, bold = true) },
        text = { Label("1.0.0\n\n完全本地运行的即时通讯体验。联系人和消息均为模拟数据，无需登录。") },
        confirmButton = { TextButton(close) { Text("关闭") } })
}
