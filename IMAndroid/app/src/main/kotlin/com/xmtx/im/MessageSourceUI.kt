package com.xmtx.im

import androidx.compose.runtime.*
import androidx.compose.foundation.lazy.LazyListState
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*

internal data class MessageSourcePresentation(val state: MessageSourceState,val retry: ()->Unit)

/** Route lifecycle adapter; database ownership and async work remain outside Compose. */
@Composable internal fun rememberMessageSources(room: RoomId,ids: PersistentSet<MessageId>,app: AppState,active: Boolean,
    open: (RoomId)->MessageSourceSession?): MessageSourcePresentation {
    val session=app.session as? SessionUi.SignedIn
    val allowed=active && rememberReadForeground() && session!=null && room !in app.snapshot.revokedRooms
    var page by remember(room,session) {mutableStateOf<MessageSourceSession?>(null)}
    val currentOpen by rememberUpdatedState(open)
    DisposableEffect(room,session,allowed) {
        val opened=if(allowed && session?.demo==false) currentOpen(room)?.let {
            if(it.room==room && it.viewer==session.user) it else {it.close();null}
        } else null
        page=opened
        onDispose {opened?.close();if(page===opened) page=null}
    }
    val openedPage=page
    val result=openedPage?.state?.collectAsState()?.value
    LaunchedEffect(openedPage,ids) {openedPage?.select(ids)}
    val shown=when {
        !allowed -> MessageSourceState(ids=ids,loaded=true)
        session?.demo==true -> MessageSourceState(ids=ids,loaded=true,messages=app.snapshot.messages.filter {
            it.id in ids && it.roomId==room && !it.withdrawn && !it.redacted && it.delivery==Delivery.Accepted && it.revision>0
        }.associateBy {it.id}.toPersistentMap())
        result!=null && result.ids==ids -> result
        else -> MessageSourceState(ids=ids,loading=openedPage!=null,feedback=if(openedPage==null) "本地消息暂不可读取，请重新打开页面。" else null)
    }
    return MessageSourcePresentation(shown,{openedPage?.refresh()})
}

@Composable internal fun visibleMessageSourceIds(list: LazyListState,rows: PersistentMap<String,MessageId>): PersistentSet<MessageId> {
    val current by rememberUpdatedState(rows)
    return produceState(persistentSetOf<MessageId>(),list) {
        snapshotFlow {list.layoutInfo.visibleItemsInfo.mapNotNull {current[it.key]}.take(100).toPersistentSet()}.collect {value=it}
    }.value
}

/** Rendering requires both the selected local message and the resource owner's exact source proof. */
internal fun MessageResourceRead.matchesMessage(message: Message?,descriptor: ResourceDescriptor?): Boolean =
    message!=null && descriptor!=null && this.descriptor==descriptor && source.room==message.roomId &&
        source.message==message.id && source.revision==message.revision && !message.withdrawn && !message.redacted && message.delivery==Delivery.Accepted
