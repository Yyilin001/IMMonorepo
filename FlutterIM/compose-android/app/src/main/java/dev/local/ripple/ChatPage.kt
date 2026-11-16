package dev.local.ripple

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.launch

@Composable fun ChatPage(store: ImStore, id: Int, nav: (Route) -> Unit, back: (() -> Unit)?, historyRequest: Int) {
    val flow = remember(id) { store.window(id) }
    val w by flow.ui()
    val prefs by store.prefs.ui()
    val backgrounds by store.backgrounds.ui()
    val notes by store.notes.ui()
    val n = notes[id] ?: Note()
    val name = n.remark.ifBlank { originalName(id) }
    val initial = remember(id) { flow.value }
    val index = initial.messages.indexOfLast { it.seq == initial.anchor }
    val state = rememberLazyListState(if (index < 0) 0 else initial.messages.lastIndex - index, initial.offset)
    val scope = rememberCoroutineScope()
    var attach by rememberSaveable { mutableStateOf(false) }
    var gallery by remember { mutableStateOf<PersistentList<Message>?>(null) }
    var startPage by remember { mutableIntStateOf(0) }
    var seenRequest by rememberSaveable { mutableIntStateOf(historyRequest) }
    val arrivedAfter = remember(id) { System.currentTimeMillis() }
    fun showHistory() {
        scope.launch {
            val list = flow.value.messages
            if (list.isNotEmpty()) state.scrollToItem(list.lastIndex)
            store.load(id)
        }
    }
    LaunchedEffect(historyRequest) {
        if (seenRequest != historyRequest) { seenRequest = historyRequest; showHistory() }
    }
    LaunchedEffect(id, state) {
        snapshotFlow {
            val layout = state.layoutInfo
            val scrolled = state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset > 10
            val anchor = layout.visibleItemsInfo.firstOrNull()?.key as? Int ?: 0
            Triple(anchor, state.firstVisibleItemScrollOffset, scrolled)
        }.collect { (anchor, offset, scrolled) ->
            store.position(id, anchor, offset, scrolled)
        }
    }
    LaunchedEffect(id, state) {
        snapshotFlow {
            val layout = state.layoutInfo
            val first = layout.visibleItemsInfo.firstOrNull()?.index ?: 0
            val last = layout.visibleItemsInfo.lastOrNull()?.index ?: 0
            val scrolling = state.isScrollInProgress
            when {
                scrolling && last > 0 && last >= layout.totalItemsCount - 10 && w.more && w.error.isEmpty() && !w.loading -> -1
                scrolling && first < 5 && w.newer && w.error.isEmpty() && !w.loading -> 1
                else -> 0
            }
        }.collect { if (it != 0) store.load(id, newer = it == 1) }
    }
    // reverseLayout keeps the live edge at index zero; stable message keys anchor a reader up-thread.
    val following = !w.reading && !state.isScrollInProgress
    val latestSeq = w.messages.lastOrNull()?.seq
    var previousSeq by remember { mutableStateOf(latestSeq) }
    SideEffect {
        if (following && latestSeq != previousSeq) state.requestScrollToItem(0)
        previousSeq = latestSeq
    }
    fun returnToLatest() { store.latest(id); state.requestScrollToItem(0) }
    BackHandler(enabled = attach && gallery == null) { attach = false }
    Column(Modifier.fillMaxSize().background((backgrounds[id] ?: prefs.background).color)) {
        Row(Modifier.fillMaxWidth().background(White).heightIn(min = 60.dp).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            if (back != null) Action(Icons.AutoMirrored.Rounded.ArrowBack, "返回", back)
            Row(Modifier.weight(1f).clickable { nav(Contact(id)) }, verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Avatar(id, name, 34)
                Column { Label(name, 17, bold = true, lines = 1); Label(if (isGroup(id)) "${memberCount(id)} 位成员" else "本地会话", 12, Muted) }
            }
            Action(Icons.Rounded.History, "查看历史记录", ::showHistory)
            Action(Icons.Rounded.MoreHoriz, "聊天设置") { nav(ChatOptions(id)) }
        }
        HorizontalDivider(color = Line)
        Box(Modifier.fillMaxWidth().weight(1f)) {
            LazyColumn(Modifier.fillMaxSize(), state = state, reverseLayout = true,
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp, Alignment.Bottom)) {
                items(w.messages.size, key = { w.messages[w.messages.lastIndex - it].seq }) { i ->
                    val message = w.messages[w.messages.lastIndex - i]
                    Bubble(store, id, message, prefs, nav,
                        animate = message.time >= arrivedAfter && message.seq > seedCount(id) && i < 4 &&
                            !w.reading && !state.isScrollInProgress && (store.runtime.value.rate == 0 || message.sender == null),
                        preview = {
                            val pictures = (w.messages.filter { it.image } + store.cachedImages(id))
                                .distinctBy { it.seq }.sortedBy { it.seq }.toPersistentList()
                            startPage = pictures.indexOf(message).coerceAtLeast(0)
                            gallery = pictures
                        })
                }
                item(key = "older") {
                    Box(Modifier.fillMaxWidth(), Alignment.Center) {
                        when {
                            w.loading -> Label("正在加载历史记录…", 12, Muted)
                            w.error.isNotEmpty() && !w.failedNewer -> TextButton({ store.load(id) }) { Text("${w.error} · 重试加载") }
                            w.gap -> Label("部分历史记录已过期", 12, Muted)
                            !w.more -> Label(if (w.messages.isEmpty()) "暂无消息，发送一条开始对话" else "没有更早的消息了", 12, Muted)
                            w.messages.size >= 2000 -> Label("当前已展开 2,000 条历史记录", 12, Muted)
                            else -> TextButton({ store.load(id) }) { Text("加载更早消息") }
                        }
                    }
                }
            }
            if (w.error.isNotEmpty() && w.failedNewer) TextButton({ store.load(id, newer = true) },
                Modifier.align(Alignment.BottomStart).background(White)) { Text("重试加载新消息") }
            if (w.reading || w.pending > 0) FilledTonalButton(::returnToLatest, Modifier.align(Alignment.BottomEnd).padding(12.dp)) {
                Text(if (w.pending == 0) "回到最新" else "${w.pending} 条新消息 ↓")
            }
        }
        HorizontalDivider(color = Line)
        if (n.deleted) {
            Row(Modifier.fillMaxWidth().background(White).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Label("联系人已删除 · 聊天记录已保留", 14, Muted, modifier = Modifier.weight(1f))
                TextButton({ store.setNote(id, n.copy(deleted = false)) }) { Text("重新添加") }
            }
        } else {
            val focus = LocalFocusManager.current
            Composer(store, id, prefs.size.sp, { if (!attach) focus.clearFocus(); attach = !attach },
                { text -> store.send(id, text); attach = false; returnToLatest() }, { attach = false })
            AttachmentPicker(store, id, name, attach) { attach = false; returnToLatest() }
        }
    }
    gallery?.let { Gallery(it, startPage) { gallery = null } }
}

@Composable private fun Composer(store: ImStore, id: Int, size: Int, attachment: () -> Unit, send: (String) -> Unit, typing: () -> Unit) {
    val drafts by store.drafts.ui()
    val text = drafts[id].orEmpty()
    Row(Modifier.fillMaxWidth().background(White).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        IconButton(attachment, Modifier.size(44.dp).background(Mist, CircleShape)) { Icon(Icons.Rounded.Add, "添加附件", tint = Ink) }
        BasicTextField(text, { if (it != text && it.length <= 2000) { store.draft(id, it); typing() } },
            Modifier.weight(1f).background(Mist, RoundedCornerShape(22.dp)).heightIn(min = 44.dp)
                .semantics { contentDescription = "消息输入框" },
            textStyle = TextStyle(color = Ink, fontSize = size.sp), maxLines = 4,
            decorationBox = { inner -> Box(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), Alignment.CenterStart) {
                if (text.isEmpty()) Label("发送消息…", size, Muted); inner()
            } })
        IconButton({ send(text) }, Modifier.size(44.dp).background(if (text.isBlank()) Mist else Green, CircleShape), enabled = text.isNotBlank()) {
            Icon(Icons.Rounded.ArrowUpward, "发送消息", tint = if (text.isBlank()) Muted else White)
        }
    }
}

@Composable private fun Bubble(store: ImStore, id: Int, m: Message, prefs: Preferences, nav: (Route) -> Unit,
                               animate: Boolean, preview: () -> Unit) {
    val mine = m.sender == null
    val me by store.me.ui()
    val notes by store.notes.ui()
    val sender = m.sender ?: 9
    val name = if (mine) (if (isGroup(id)) me.name else "我") else notes[sender]?.remark?.ifEmpty { originalName(sender) } ?: originalName(sender)
    val progress = remember { Animatable(if (animate && prefs.animate && System.currentTimeMillis() - m.time < 250) 0f else 1f) }
    LaunchedEffect(Unit) { if (progress.value < 1) progress.animateTo(1f, tween(180)) }
    var menu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val avatar: @Composable () -> Unit = {
        Box(Modifier.clickable(onClickLabel = "查看${name}的资料") { nav(if (mine) Profile else Contact(sender)) }) {
            Avatar(sender, name, 44, false)
        }
    }
    Row(Modifier.fillMaxWidth().graphicsLayer { alpha = progress.value; translationY = (1 - progress.value) * 8.dp.toPx() },
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        if (!mine) { avatar(); Spacer(Modifier.width(10.dp)) }
        Column(Modifier.weight(1f, fill = false), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Label(name, prefs.size.sp - 1, bold = true, lines = 1); Label(clock(m.time), 11, Muted)
            }
            Spacer(Modifier.height(4.dp))
            val shape = RoundedCornerShape(topStart = if (mine) 12.dp else 3.dp, topEnd = if (mine) 3.dp else 12.dp,
                bottomStart = 12.dp, bottomEnd = 12.dp)
            Box {
                Box(Modifier.widthIn(max = 350.dp).clip(shape).background(if (mine) Green else White)
                    .border(.7.dp, if (mine) Green else Line, shape)
                    .combinedClickable(hapticFeedbackEnabled = false, onLongClick = {
                        if (prefs.haptics) haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        menu = true
                    }, onClick = { if (m.image) preview() })) {
                    if (m.image) Picture(m.file, m.ratio, mine, Modifier.width(if (m.ratio < 1f) 175.dp else 224.dp))
                    else Label(m.text, prefs.size.sp, if (mine) White else Ink, modifier = Modifier.padding(horizontal = 13.dp, vertical = 11.dp))
                }
                DropdownMenu(menu, { menu = false }, containerColor = Ink) {
                    DropdownMenuItem({ Label(if (m.image) "查看图片" else "复制文字", color = White) }, {
                        menu = false; if (m.image) preview() else copyText(context, "文字", m.text)
                    })
                    DropdownMenuItem({ Label("删除", color = White) }, { menu = false; store.deleteMessage(id, m) })
                }
            }
            if (mine) Label("已送达", 10, Muted)
        }
        if (mine) { Spacer(Modifier.width(10.dp)); avatar() }
    }
}
