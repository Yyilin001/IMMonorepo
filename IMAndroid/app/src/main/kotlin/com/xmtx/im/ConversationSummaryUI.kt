package com.xmtx.im

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import java.io.Closeable

/** A page owns display interest only. It cannot grant access, start I/O or acknowledge recovery. */
class ConversationSummaryPage(private val changed: (PersistentList<RoomId>)->Unit,private val closed: ()->Unit): Closeable {
    private var isClosed=false
    private var rooms=persistentListOf<RoomId>()
    fun update(value: PersistentList<RoomId>) {
        require(value.size<=100)
        if(isClosed || value==rooms) return
        rooms=value;changed(value)
    }
    override fun close() {if(!isClosed) {isClosed=true;rooms=persistentListOf();closed()}}
}

@Composable internal fun ConversationSummaryDemand(list: LazyListState,rows: PersistentMap<String,RoomId>,active: Boolean,
    owner: UserId,open: ()->ConversationSummaryPage?) {
    val foreground=rememberReadForeground()
    val currentOpen by rememberUpdatedState(open)
    var page by remember(owner) {mutableStateOf<ConversationSummaryPage?>(null)}
    val visible=remember(list,rows) {derivedStateOf {
        list.layoutInfo.visibleItemsInfo.filter {it.offset<list.layoutInfo.viewportEndOffset && it.offset+it.size>list.layoutInfo.viewportStartOffset}
            .mapNotNull {rows[it.key]}.distinct().take(100).toPersistentList()
    }}.value
    DisposableEffect(active,foreground,owner) {
        val opened=if(active && foreground) currentOpen() else null
        page=opened
        onDispose {opened?.close();if(page===opened) page=null}
    }
    LaunchedEffect(page,visible) {page?.update(visible)}
}
