package dev.local.ripple

import android.os.Bundle
import android.view.FrameMetrics
import android.os.Handler
import android.os.Looper
import android.view.Window
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.navigation3.runtime.*
import androidx.navigation3.ui.NavDisplay
import kotlinx.serialization.Serializable

class MainActivity : ComponentActivity() {
    private val store: ImStore by viewModels()
    private val frameListener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
        store.frame(metrics.getMetric(FrameMetrics.TOTAL_DURATION) / 1_000_000f)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { RippleApp(store) }
    }
    override fun onStart() {
        super.onStart()
        window.addOnFrameMetricsAvailableListener(frameListener, Handler(Looper.getMainLooper()))
    }
    override fun onStop() {
        window.removeOnFrameMetricsAvailableListener(frameListener)
        super.onStop()
    }
}

@Serializable sealed interface Route : NavKey
@Serializable data object Home : Route
@Serializable data class Search(val directory: String, val unread: Boolean = false) : Route
@Serializable data class Chat(val id: Int) : Route
@Serializable data class ChatOptions(val id: Int) : Route
@Serializable data class Contact(val id: Int) : Route
@Serializable data class ContactOptions(val id: Int) : Route
@Serializable data class EditNote(val id: Int) : Route
@Serializable data object Profile : Route
@Serializable data object EditProfile : Route
@Serializable data object Settings : Route
@Serializable data object Appearance : Route
@Serializable data object Privacy : Route

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun RippleApp(store: ImStore) {
    val stack = rememberNavBackStack(Home)
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var selected by rememberSaveable { mutableIntStateOf(0) }
    var monitor by rememberSaveable { mutableStateOf(false) }
    var historyRequest by rememberSaveable { mutableIntStateOf(0) }
    val tabs = rememberSaveableStateHolder()
    val back = { if (stack.size > 1) stack.removeAt(stack.lastIndex); Unit }
    MaterialTheme(colorScheme = lightColorScheme(primary = Green, secondary = Green, surface = White,
        background = Mist, onSurface = Ink, primaryContainer = Mint)) {
        BoxWithConstraints(Modifier.fillMaxSize().background(White).safeDrawingPadding().imePadding()) {
            val wide = maxWidth >= 900.dp
            val dashboard = maxWidth >= 1250.dp
            val navigate: (Route) -> Unit = { route ->
                if (route is Chat && wide) {
                    while (stack.size > 1) stack.removeAt(stack.lastIndex)
                    selected = route.id
                    tab = 0
                } else if (route is Chat && stack.contains(route)) {
                    while (stack.last() != route) stack.removeAt(stack.lastIndex)
                } else if (stack.last() != route) stack.add(route)
            }
            val activeChat = stack.filterIsInstance<Chat>().lastOrNull()?.id ?: selected.takeIf { wide && tab == 0 }
            LaunchedEffect(activeChat) { store.select(activeChat) }
            NavDisplay(backStack = stack, onBack = back, entryProvider = entryProvider {
                entry<Home> {
                    Row(Modifier.fillMaxSize()) {
                        if (wide) TabBar(store, tab, true, { monitor = true }) { tab = it }
                        Column(Modifier.weight(1f).then(if (wide) Modifier.background(Mist).padding(20.dp) else Modifier)) {
                            if (wide && tab == 0) WideHeader(store) { monitor = true }
                            Box(Modifier.weight(1f).then(if (wide) Modifier.clip(RoundedCornerShape(18.dp)).background(White) else Modifier)) {
                                tabs.SaveableStateProvider(tab) {
                                    when (tab) {
                                        0 -> Row {
                                            Box(if (wide) Modifier.width(300.dp) else Modifier.fillMaxWidth()) {
                                                ConversationPage(store, navigate, { monitor = true }, selected = selected.takeIf { wide })
                                            }
                                            if (wide) {
                                                VerticalDivider()
                                                Box(Modifier.weight(1f)) { key(selected) {
                                                    ChatPage(store, selected, navigate, null, historyRequest)
                                                } }
                                                if (dashboard) { VerticalDivider(); Box(Modifier.width(270.dp)) { Monitor(store, null) } }
                                            }
                                        }
                                        1 -> ContactsPage(store, navigate)
                                        else -> MePage(store, navigate) { monitor = true }
                                    }
                                }
                            }
                            if (!wide) TabBar(store, tab, false, { monitor = true }) { tab = it }
                        }
                    }
                }
                entry<Search> { s ->
                    if (s.directory == "chats") ConversationPage(store, navigate, { monitor = true }, back, s.unread)
                    else ContactsPage(store, navigate, back, s.directory == "groups")
                }
                entry<Chat> { ChatPage(store, it.id, navigate, back, historyRequest) }
                entry<ChatOptions> { ChatSettings(store, it.id, navigate, back) { historyRequest++; back() } }
                entry<Contact> { ContactPage(store, it.id, navigate, back) }
                entry<ContactOptions> { ContactSettings(store, it.id, navigate, back) }
                entry<EditNote> { NotesPage(store, it.id, back) }
                entry<Profile> { MyProfilePage(store, navigate, back) }
                entry<EditProfile> { EditProfilePage(store, back) }
                entry<Settings> { SettingsPage(store, navigate, back) }
                entry<Appearance> { AppearancePage(store, back) }
                entry<Privacy> { PrivacyPage(store, back) }
            })
            if (monitor) ModalBottomSheet(onDismissRequest = { monitor = false }, containerColor = Mist,
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
                Box(Modifier.fillMaxHeight(.91f)) { Monitor(store) { monitor = false } }
            }
        }
    }
}

@Composable private fun TabBar(store: ImStore, selected: Int, rail: Boolean, monitor: () -> Unit, choose: (Int) -> Unit) {
    val labels = listOf("消息","联系人","我")
    val icons = listOf(Icons.Rounded.ChatBubbleOutline, Icons.Rounded.Contacts, Icons.Rounded.PersonOutline)
    val icon: @Composable (Int) -> Unit = { i ->
        if (i == 0) {
            val total by store.total.ui()
            val prefs by store.prefs.ui()
            BadgedBox(modifier = Modifier.semantics { if (prefs.badge) contentDescription = if (total == 0) "没有未读消息" else "$total 条未读消息" }, badge = {
                if (total > 0 && prefs.badge) Badge(containerColor = Green, contentColor = White) {
                    Text(if (total > 99) "99+" else "$total")
                }
            }) { Icon(icons[i], null) }
        } else Icon(icons[i], null)
    }
    if (rail) NavigationRail(containerColor = Ink, header = {
        Box(Modifier.padding(vertical = 22.dp).size(42.dp).background(Mint, RoundedCornerShape(15.dp)), Alignment.Center) {
            Icon(Icons.Rounded.Waves, "涟漪", tint = Ink)
        }
    }) {
        labels.forEachIndexed { i, label -> NavigationRailItem(selected == i, { choose(i) }, { icon(i) },
            label = { Label(label, 12, White) }, colors = NavigationRailItemDefaults.colors(indicatorColor = Mint, unselectedIconColor = White)) }
        Spacer(Modifier.weight(1f))
        IconButton(monitor) { Icon(Icons.Rounded.Insights, "运行监控", tint = White) }
    } else {
        HorizontalDivider(color = Line)
        Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).background(White), verticalAlignment = Alignment.CenterVertically) {
            labels.forEachIndexed { i, label ->
                NavigationBarItem(selected == i, { choose(i) }, { icon(i) }, label = { Label(label, 12) },
                    colors = NavigationBarItemDefaults.colors(indicatorColor = Mint, selectedIconColor = Green, unselectedIconColor = Muted))
            }
        }
    }
}
