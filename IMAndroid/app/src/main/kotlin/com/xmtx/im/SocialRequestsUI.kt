package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*

/** Each direction has its own saved viewport; only the visible lane owns a read session. */
@Composable internal fun SocialRequestsPage(state: AppState, session: SessionUi.SignedIn, active: Boolean,
    openRelationships: () -> RelationshipPageSession?, openProfiles: () -> ProfilePresentationPage?,
    change: suspend (UserId, SocialAction) -> Unit, prepare: suspend (String) -> Unit,
    discard: suspend (String) -> Unit, retry: suspend (String) -> Unit, push: (Route) -> Unit) {
    key(session.user, session.databaseIdentity) {
        var selected by rememberSaveable { mutableIntStateOf(0) }
        val saved = rememberSaveableStateHolder()
        val resumed = rememberReadForeground()
        Column(Modifier.fillMaxSize()) {
            SecondaryTabRow(selectedTabIndex = selected) {
                Tab(selected == 0, { selected = 0 }, text = { Text("收到的申请") }, modifier = Modifier.testTag("requests-incoming"))
                Tab(selected == 1, { selected = 1 }, text = { Text("已发出的申请") }, modifier = Modifier.testTag("requests-outgoing"))
                Tab(selected == 2, { selected = 2 }, text = { Text("操作记录") }, modifier = Modifier.testTag("requests-operations"))
            }
            state.error?.let { Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
            saved.SaveableStateProvider(selected) {
                if (selected == 2) SocialRequestOperations(state, active && resumed, prepare, discard, retry)
                else SocialRequestLane(state, session, active && resumed,
                    if (selected == 0) RelationshipPageScope.Incoming else RelationshipPageScope.Outgoing,
                    openRelationships, openProfiles, change, push)
            }
        }
    }
}

@Composable private fun SocialRequestLane(state: AppState, session: SessionUi.SignedIn, active: Boolean,
    direction: RelationshipPageScope, openRelationships: () -> RelationshipPageSession?,
    openProfiles: () -> ProfilePresentationPage?, change: suspend (UserId, SocialAction) -> Unit, push: (Route) -> Unit) {
    val owner = rememberCoroutineScope()
    val currentOpen by rememberUpdatedState(openRelationships)
    val demo = remember(session.user, session.demo, state.snapshot.contacts, state.snapshot.relationships) {
        if (session.demo) DemoRelationshipPages(state.snapshot.contacts, state.snapshot.relationships) else null
    }
    var page by remember { mutableStateOf<RelationshipPageSession?>(null) }
    DisposableEffect(active, direction, demo) {
        val opened = if (active) {
            if (session.demo) RelationshipPageSession(requireNotNull(demo), session.user, owner) else currentOpen()
        } else null
        page = opened
        onDispose { opened?.close(); if (page === opened) page = null }
    }
    val value = page?.state?.collectAsState()?.value ?: RelationshipPageState()
    val rows = value.page.relationships
    val list = rememberLazyListState()
    val position = rememberContactListPosition(session, direction.name, list, page, value, active, headerCount = 0)
    LaunchedEffect(page, direction) { page?.update(RelationshipPageRequest(scope = direction), position.viewport) }
    LaunchedEffect(page, state.snapshot.relationships, state.snapshot.presentationGeneration) { page?.refresh() }
    val keys = if (session.demo) persistentListOf() else visibleProfileKeys(list, rows.map { it.target }.toPersistentList(), ProfileContext.Relationship)
    val profiles = rememberProfilePresentation(keys, state.snapshot.presentationGeneration, active && !session.demo, session.user, openProfiles, avatars = true)
    Column(Modifier.fillMaxSize()) {
        if (value.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        value.feedback?.let { feedback ->
            Row(Modifier.padding(horizontal = 16.dp)) {
                Text(feedback, Modifier.weight(1f))
                TextButton({ page?.retry() }, enabled = active && !value.loading, modifier = Modifier.testTag("requests-retry")) { Text("重试") }
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("requests-list"), state = list,
            contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (rows.isEmpty() && !value.loading && value.feedback == null) item {
                Text(if (direction == RelationshipPageScope.Incoming) "暂无待处理申请" else "暂无已发申请", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(rows, key = { it.target.value }) { relation ->
                val name = if (session.demo) state.snapshot.contacts.firstOrNull { it.id == relation.target }?.name ?: "用户 ${relation.target.value.takeLast(8)}"
                    else profiles.name(relation.target, ProfileContext.Relationship)
                Card(Modifier.fillMaxWidth().testTag("requests-row-${relation.target.value}")) {
                    Column(Modifier.padding(16.dp)) {
                        TextButton({ push(Route.Profile(relation.target.value)) }, enabled = active,
                            modifier = Modifier.testTag("requests-profile-${relation.target.value}")) {
                            Avatar(name, image = profiles.avatars[ProfileKey(relation.target, ProfileContext.Relationship)])
                            Spacer(Modifier.width(12.dp)); Text(name)
                        }
                        Text(if (direction == RelationshipPageScope.Outgoing) "等待对方接受" else "请求添加你为朋友")
                        Row {
                            if (direction == RelationshipPageScope.Outgoing) SocialActionButton(relation.target, SocialAction.Remove, state, change, "取消申请", active)
                            else {
                                SocialActionButton(relation.target, SocialAction.Accept, state, change, enabled = active)
                                SocialActionButton(relation.target, SocialAction.Reject, state, change, enabled = active)
                            }
                        }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton({ page?.previous() }, enabled = active && value.canPrevious && !value.loading, modifier = Modifier.testTag("requests-previous")) { Text("上一页") }
            TextButton({ page?.first() }, enabled = active && value.canPrevious && !value.loading, modifier = Modifier.testTag("requests-first")) { Text("回到开头") }
            TextButton({ page?.next() }, enabled = active && value.page.next != null && !value.loading, modifier = Modifier.testTag("requests-next")) { Text("下一页") }
        }
    }
}
