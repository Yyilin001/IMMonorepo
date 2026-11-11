package com.xmtx.im

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*

/** Only currently laid-out rows request presentation. Invisible IDs never become display names. */
@Composable internal fun visibleProfileKeys(list: LazyListState,users: PersistentList<UserId>,context: ProfileContext): PersistentList<ProfileKey> {
    val known = remember(users,context) { users.associate { it.value to ProfileKey(it,context) }.toPersistentMap() }
    return visiblePresentationKeys(list,known)
}
@Composable internal fun visiblePresentationKeys(list: LazyListState,rows: PersistentMap<String,ProfileKey>): PersistentList<ProfileKey> {
    return remember(list,rows) { derivedStateOf {
        list.layoutInfo.visibleItemsInfo.filter { it.offset < list.layoutInfo.viewportEndOffset && it.offset+it.size > list.layoutInfo.viewportStartOffset }
            .mapNotNull { rows[it.key] }.distinct().take(128).toPersistentList()
    } }.value
}
internal fun Conversation.presentationKey(): ProfileKey? = peer?.takeIf { kind == RoomKind.Direct }?.let { ProfileKey(it,ProfileContext.DirectConversation) }
internal fun ProfilePresentationSnapshot.title(conversation: Conversation?,demo: Boolean): String = when {
    conversation == null -> "会话"
    demo || conversation.kind == RoomKind.Group -> conversation.title
    else -> conversation.presentationKey()?.let { displayName(it) } ?: "会话"
}
@Composable internal fun rememberConversationTitles(list: LazyListState?,state: AppState,active: Boolean,
    rows: PersistentMap<String,RoomId>,open: () -> ProfilePresentationPage?): ProfilePresentationSnapshot {
    val session = state.session as? SessionUi.SignedIn ?: return ProfilePresentationSnapshot()
    val conversations = state.snapshot.conversations.associateBy { it.id }
    val mapping = if(session.demo) persistentMapOf() else rows.mapNotNull { (row,room) ->
        conversations[room]?.takeIf { room !in state.snapshot.revokedRooms }?.presentationKey()?.let { row to it }
    }.toMap().toPersistentMap()
    val keys = if(list == null) mapping.values.distinct().take(128).toPersistentList() else visiblePresentationKeys(list,mapping)
    return rememberProfilePresentation(keys,state.snapshot.presentationGeneration,active && !session.demo,session.user,open)
}
@Composable internal fun rememberProfilePresentation(keys: PersistentList<ProfileKey>,generation: String,active: Boolean,
    owner: UserId,open: () -> ProfilePresentationPage?): ProfilePresentationSnapshot = rememberProfilePresentation(keys,generation,active,owner,open,false)
@Composable internal fun rememberProfilePresentation(keys: PersistentList<ProfileKey>,generation: String,active: Boolean,
    owner: UserId,open: () -> ProfilePresentationPage?,avatars: Boolean): ProfilePresentationSnapshot {
    val foreground = rememberReadForeground()
    val currentOpen by rememberUpdatedState(open)
    var page by remember(owner) { mutableStateOf<ProfilePresentationPage?>(null) }
    DisposableEffect(active,foreground,owner) {
        val opened = if(active && foreground) currentOpen() else null
        page = opened
        onDispose { opened?.close();if(page === opened) page = null }
    }
    LaunchedEffect(page,keys,generation,avatars) { page?.update(keys,generation,if(avatars) keys else persistentListOf()) }
    val observed = page?.state?.collectAsState()?.value
    return if(active && foreground && observed?.generation == generation) observed.display else ProfilePresentationSnapshot()
}
internal fun ProfilePresentationSnapshot.name(user: UserId,context: ProfileContext): String =
    displayName(ProfileKey(user,context)) ?: "资料暂不可用"
private fun ProfilePresentationSnapshot.displayName(key: ProfileKey): String? =
    if (localNames != null) localNames?.get(key)?.name else profiles[key]?.takeIf { it.valid() }?.profile?.displayName()
internal fun ProfilePresentationSnapshot.identity(key: ProfileKey): PublicIdentity? =
    if (localNames != null) localNames?.get(key)?.identity else profiles[key]?.takeIf { it.valid() }?.profile?.view?.identity

internal fun Route.Profile.presentationKey(demo: Boolean): ProfileKey? = if(demo) null else
    ProfileKey(UserId(user),room?.let {ProfileContext.Room(RoomId(it))} ?: ProfileContext.Relationship)

/** Restored member routes retain their original authority context; a relationship is a separate read. */
@Composable internal fun rememberRouteProfile(destination: Route.Profile,state: AppState,session: SessionUi.SignedIn,active: Boolean,
    open: ()->ProfilePresentationPage?): ProfilePresentationSnapshot {
    val key=destination.presentationKey(session.demo)
    val permitted=destination.room?.let {RoomId(it) !in state.snapshot.revokedRooms}!=false
    return rememberProfilePresentation(key?.let {persistentListOf(it)} ?: persistentListOf(),state.snapshot.presentationGeneration,
        active && !session.demo && permitted,session.user,open,avatars=true)
}
