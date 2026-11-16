package dev.local.ripple

import android.icu.text.Transliterator
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable private fun SearchBar(hint: String, query: String, change: (String) -> Unit,
                                   open: () -> Unit, back: (() -> Unit)?, submit: () -> Unit) {
    val requester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = if (back != null) 10.dp else 0.dp),
        verticalAlignment = Alignment.CenterVertically) {
        val face = Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).background(Mist)
        Row((if (back == null) face.clickable(onClick = open) else face).heightIn(min = 44.dp).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Rounded.Search, null, Modifier.size(20.dp), tint = Muted)
            if (back == null) Label(hint, 15, Muted) else {
                BasicTextField(query, change, Modifier.weight(1f).focusRequester(requester)
                    .semantics { contentDescription = hint }, singleLine = true, textStyle = TextStyle(fontSize = 15.sp, color = Ink),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { submit(); keyboard?.hide() }),
                    decorationBox = { inner -> Box { if (query.isEmpty()) Label(hint, 15, Muted); inner() } })
                if (query.isNotEmpty()) Action(Icons.Rounded.Close, "清除搜索") { change("") }
            }
        }
        if (back != null) TextButton(onClick = { submit(); back() }) { Text("取消") }
    }
    if (back != null) LaunchedEffect(Unit) { requester.requestFocus() }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun Recent(store: ImStore, key: String, hint: String, choose: (String) -> Unit) {
    val all by store.recent.ui()
    val items = all[key].orEmpty()
    if (items.isEmpty()) Box(Modifier.fillMaxSize(), Alignment.Center) { Label(hint, 14, Muted) }
    else Column(Modifier.fillMaxWidth().padding(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Label("最近搜索", 16, bold = true, modifier = Modifier.weight(1f))
            TextButton({ store.rememberQuery(key, null) }) { Text("清空") }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items.forEach { AssistChip({ choose(it) }, label = { Text(it) }) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun ConversationPage(store: ImStore, nav: (Route) -> Unit, monitor: () -> Unit,
                                 back: (() -> Unit)? = null, initialUnread: Boolean = false, selected: Int? = null) {
    var unread by rememberSaveable { mutableStateOf(initialUnread) }
    var query by rememberSaveable { mutableStateOf("") }
    var menu by rememberSaveable { mutableStateOf<Int?>(null) }
    val state = rememberLazyListState()
    val scope = rememberCoroutineScope()
    fun change(text: String) { query = text; scope.launch { state.scrollToItem(0) } }
    val open: (Int) -> Unit = { id ->
        if (back != null) store.rememberQuery("chats", query)
        nav(Chat(id))
    }
    Column(Modifier.fillMaxSize().background(White)) {
        if (back == null) Header("消息") {
            Action(Icons.Rounded.DoneAll, "全部标为已读", store::readAll)
            Action(Icons.Rounded.Tune, "查看性能指标", monitor)
        }
        SearchBar(if (back == null) "搜索" else "搜索会话名称、备注或编号", query, ::change,
            { nav(Search("chats", unread)) }, back) { store.rememberQuery("chats", query) }
        Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Pill("全部", !unread) { unread = false; scope.launch { state.scrollToItem(0) } }
            Pill("未读", unread) { unread = true; scope.launch { state.scrollToItem(0) } }
            Spacer(Modifier.weight(1f)); Icon(Icons.Rounded.SwapVert, null, Modifier.size(17.dp), tint = Muted)
        }
        if (back != null && query.isBlank()) Recent(store, "chats", "输入会话名称、备注或编号", ::change)
        else {
            if (back != null) Label("会话搜索结果", 12, Muted, modifier = Modifier.padding(start = 18.dp))
            val away by remember { derivedStateOf { state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset > 20 } }
            val filter = remember(query, unread, away) { store.filter(query, unread, away) }
            DisposableEffect(filter) { onDispose { store.release(filter) } }
            val current by filter.visible.ui()
            val order = current
            if (order == null) Box(Modifier.fillMaxSize(), Alignment.Center) { Label("没有找到会话", 14, Muted) }
            else {
                LazyColumn(Modifier.weight(1f), state) {
                    items(order.size) { index ->
                        val id = order[index]
                        ConversationSlot(store, id, selected == id, open) { menu = it }
                    }
                }
                if (away && back == null) Label("回到顶部，恢复会话排序", 11, Green, modifier = Modifier.padding(12.dp))
            }
        }
    }
    menu?.let { id ->
        val c by store.row(id).ui()
        ModalBottomSheet(onDismissRequest = { menu = null }, containerColor = White) {
            Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 22.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(id, c.name, 46); Label(c.name, 19, bold = true)
                }
                LinkRow(if (c.pinned) "取消置顶" else "置顶聊天", icon = Icons.Rounded.PushPin) { store.pin(id); menu = null }
                LinkRow(if (c.muted) "关闭免打扰" else "消息免打扰", icon = Icons.Rounded.NotificationsOff) { store.mute(id); menu = null }
                LinkRow("标为已读", icon = Icons.Rounded.DoneAll) { store.markRead(id); menu = null }
            }
        }
    }
}

@Composable private fun ConversationSlot(store: ImStore, id: Int, selected: Boolean, open: (Int) -> Unit, menu: (Int) -> Unit) {
    val c by store.row(id).ui()
    val prefs by store.prefs.ui()
    val notes by store.notes.ui()
    val haptic = LocalHapticFeedback.current
    val currentId by rememberUpdatedState(id)
    val onOpen by rememberUpdatedState(open)
    val onMenu by rememberUpdatedState(menu)
    val vibrate by rememberUpdatedState(prefs.haptics)
    Column(Modifier.fillMaxWidth().background(if (selected) Mint else White)
        .pointerInput(Unit) {
            var pressed = currentId
            detectTapGestures(onPress = { pressed = currentId }, onTap = { onOpen(pressed) },
                onLongPress = { if (vibrate) haptic.performHapticFeedback(HapticFeedbackType.LongPress); onMenu(pressed) })
        }.semantics(mergeDescendants = true) {
            onClick { onOpen(id); true }; onLongClick { onMenu(id); true }
        }) {
        Row(Modifier.fillMaxWidth().heightIn(min = 81.dp).padding(horizontal = 20.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Avatar(id, c.name, 50)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Label(c.name, 16, bold = selected, modifier = Modifier.weight(1f), lines = 1)
                    Label(clock(c.time), 11, Muted)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    val preview = when {
                        notes[id]?.deleted == true -> "联系人已删除 · 聊天记录已保留"
                        prefs.preview -> c.preview
                        else -> "消息内容已隐藏"
                    }
                    Label(preview, 14, Muted, modifier = Modifier.weight(1f), lines = 1)
                    if (c.muted) Icon(Icons.Rounded.NotificationsOff, "消息免打扰", Modifier.size(13.dp), tint = Muted)
                    if (c.unread > 0) Box(Modifier.background(if (c.muted) Muted else Green, RoundedCornerShape(8.dp))
                        .padding(horizontal = 5.dp, vertical = 1.dp)) { Label(if (c.unread > 99) "99+" else "${c.unread}", 10, White) }
                    else if (c.pinned) Icon(Icons.Rounded.PushPin, "已置顶", Modifier.size(13.dp), tint = Muted)
                }
            }
        }
        HorizontalDivider(thickness = .5.dp, color = Line)
    }
}

@Immutable private data class Person(val id: Int, val name: String, val key: String, val search: String) {
    val initial get() = key.firstOrNull()?.takeIf { it in 'A'..'Z' }?.toString() ?: "#"
}
private fun directory(notes: PersistentMap<Int, Note>, groups: Boolean): PersistentList<Person> {
    val transliterator by lazy { Transliterator.getInstance("Han-Latin; NFD; [:Nonspacing Mark:] Remove; NFC") }
    val cache = HashMap<String, String>()
    fun pinyin(name: String): String {
        val prefix = name.trimEnd { it.isDigit() }
        return cache.getOrPut(prefix) { transliterator.transliterate(prefix).replace(" ", "").uppercase() } + name.removePrefix(prefix)
    }
    return (0 until ConversationCount).asSequence().filter { isGroup(it) == groups && notes[it]?.deleted != true }.map { id ->
        val original = originalName(id)
        val note = notes[id]
        val name = note?.remark?.ifEmpty { original } ?: original
        val key = pinyin(name)
        Person(id, name, key, "$name $original $key ${pinyin(original)} ${handle(id)} ${note?.tags.orEmpty().joinToString(" ")}")
    }.sortedWith(compareBy<Person>({ it.initial == "#" }, { it.key }, { it.id })).toList().toPersistentList()
}

@Composable fun ContactsPage(store: ImStore, nav: (Route) -> Unit, back: (() -> Unit)? = null, initialGroups: Boolean = false) {
    var groups by rememberSaveable { mutableStateOf(initialGroups) }
    var query by rememberSaveable { mutableStateOf("") }
    val notes by store.notes.ui()
    val people by produceState(persistentListOf<Person>(), groups, notes) {
        value = withContext(Dispatchers.Default) { directory(notes, groups) }
    }
    val filtered = remember(people, query, groups) {
        people.filter { isGroup(it.id) == groups && it.search.contains(query.trim(), true) }.groupBy { it.initial }
    }
    val state = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val key = if (groups) "groups" else "friends"
    val hint = "搜索昵称、备注、标签或账号"
    fun change(text: String) { query = text; scope.launch { state.scrollToItem(0) } }
    Column(Modifier.fillMaxSize().background(White)) {
        if (back == null) {
            Header("联系人")
            Label("${number(7499 - notes.values.count { it.deleted })} 位好友 · 2,501 个群聊", 13, Muted,
                modifier = Modifier.padding(start = 20.dp, bottom = 16.dp))
        }
        SearchBar(hint, query, ::change, { nav(Search(key)) }, back) { store.rememberQuery(key, query) }
        Row(Modifier.padding(horizontal = 18.dp, vertical = 10.dp)) {
            Pill("好友", !groups) { groups = false; scope.launch { state.scrollToItem(0) } }
            Pill("群聊", groups) { groups = true; scope.launch { state.scrollToItem(0) } }
        }
        if (back != null && query.isBlank()) Recent(store, key, hint, ::change)
        else if (filtered.isEmpty()) Box(Modifier.fillMaxSize(), Alignment.Center) {
            if (people.isEmpty()) CircularProgressIndicator() else Label("没有找到联系人", color = Muted)
        } else Row {
            LazyColumn(Modifier.weight(1f), state) {
                filtered.forEach { (letter, group) ->
                    item(key = letter) { Label(letter, 13, Green, true, Modifier.fillMaxWidth().background(Mint).padding(horizontal = 20.dp, vertical = 6.dp)) }
                    items(group, key = { it.id }) { p ->
                        Row(Modifier.fillMaxWidth().clickable {
                            if (back != null) store.rememberQuery(key, query)
                            nav(Contact(p.id))
                        }.heightIn(min = 76.dp).padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Avatar(p.id, p.name, 46)
                            Column { Label(p.name, 16); Label(handle(p.id), 13, Muted) }
                        }
                        HorizontalDivider(thickness = .5.dp, color = Line)
                    }
                }
            }
            Column(Modifier.align(Alignment.CenterVertically)) {
                var offset = 0
                filtered.forEach { (letter, group) ->
                    val target = offset
                    TextButton({ scope.launch { state.scrollToItem(target) } }, modifier = Modifier.width(32.dp),
                        contentPadding = PaddingValues(0.dp)) { Label(letter, 12, Green, true) }
                    offset += group.size + 1
                }
            }
        }
    }
}
