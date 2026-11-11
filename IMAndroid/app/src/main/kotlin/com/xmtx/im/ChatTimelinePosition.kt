package com.xmtx.im

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first

/** Main-thread viewport owner. Saved state contains identities and geometry, never message bodies. */
@Stable
internal class ChatTimelinePosition(
    following: Boolean=true, focused: String?=null, anchor: String?=null, offset: Int=0,
) {
    var following by mutableStateOf(following);private set
    var focused by mutableStateOf(focused);private set
    var feedback by mutableStateOf<String?>(null);private set
    internal var anchor by mutableStateOf(anchor)
    internal var offset by mutableIntStateOf(offset)
    internal var ready by mutableStateOf(false)
    internal var programmatic by mutableStateOf(false)
    private var manual=false
    private var command=0L
    private var job: Job?=null
    internal fun focus(id: String) {following=false;focused=id;feedback=null}
    internal fun latest() {following=true;focused=null;feedback=null}
    internal fun history() {following=false;focused=null;feedback=null}
    internal fun unavailable(withdrawn: Boolean) {
        focused=null;feedback=if(withdrawn) "这条消息已撤回。" else "这条消息当前不可用。"
    }
    internal fun observe(scrolling: Boolean,nearTail: Boolean,id: String?,offset: Int) {
        if(!ready || programmatic) return
        if(scrolling) {manual=true;focused=null;following=nearTail;feedback=null}
        else if(manual) {manual=false;following=nearTail}
        if(!following && id!=null) {anchor=id;this.offset=offset}
    }
    internal fun stop() {manual=false;command++;job?.cancel();job=null;programmatic=false}
    internal fun move(scope: kotlinx.coroutines.CoroutineScope,action: suspend ()->Unit) {
        stop();val current=command;programmatic=true
        job=scope.launch {try {action()} finally {if(command==current) {programmatic=false;job=null}}}
    }
    companion object {
        val Saver=listSaver<ChatTimelinePosition,Any>(save={listOf(it.following,it.focused.orEmpty(),it.anchor.orEmpty(),it.offset)},
            restore={ChatTimelinePosition(it[0] as Boolean,(it[1] as String).ifEmpty {null},(it[2] as String).ifEmpty {null},it[3] as Int)})
    }
}

private data class TimelineViewportSample(val scrolling: Boolean,val nearTail: Boolean,val anchor: String?,val offset: Int,val ready: Boolean,val programmatic: Boolean)

@Composable
internal fun rememberChatTimelinePosition(room: RoomId,viewer: UserId,list: LazyListState,
    messages: PersistentList<Message>,active: Boolean,latestAvailable: Boolean = true,
    navigation: TimelineNavigation? = null,navigationOwner: Any? = null,rowKeys:PersistentList<String> = messages.map {it.id.value}.toPersistentList()): ChatTimelinePosition {
    val position=rememberSaveable(room.value,viewer.value,saver=ChatTimelinePosition.Saver) {ChatTimelinePosition()}
    val scope=rememberCoroutineScope()
    var consumedNavigation by remember(position,navigationOwner) {mutableStateOf<Long?>(null)}
    val tailDistance=with(LocalDensity.current) {80.dp.roundToPx()}
    val currentKeys by rememberUpdatedState(rowKeys)
    val enabled by rememberUpdatedState(active)
    val canFollow by rememberUpdatedState(latestAvailable)
    LaunchedEffect(position,list,tailDistance) {
        snapshotFlow {
            val layout=list.layoutInfo
            val last=layout.visibleItemsInfo.lastOrNull()
            val nearTail=last!=null && last.index==layout.totalItemsCount-1 &&
                last.offset+last.size-layout.viewportEndOffset<=tailDistance
            val first=layout.visibleItemsInfo.firstOrNull {it.index==list.firstVisibleItemIndex}
            // Include readiness and command state so a completed explicit jump captures its stable anchor.
            TimelineViewportSample(list.isScrollInProgress,nearTail,first?.key as? String,list.firstVisibleItemScrollOffset,position.ready,position.programmatic)
        }.collect {value -> if(enabled) position.observe(value.scrolling,value.nearTail && canFollow,value.anchor,value.offset)}
    }
    LaunchedEffect(position,messages,rowKeys,active,navigation,navigationOwner) {
        if(!active) {position.stop();position.ready=false;return@LaunchedEffect}
        val target=position.focused?.let {id -> messages.firstOrNull {it.id.value==id && it.roomId==room}}
        if(position.focused!=null && (target==null || target.withdrawn || target.redacted || target.delivery!=Delivery.Accepted))
            position.unavailable(target?.withdrawn==true)
        if(rowKeys.isEmpty()) return@LaunchedEffect
        fun moveTo(id: String?,offset: Int=0,latest: Boolean=false) {
            position.move(scope) {
                // A newly bound window must be measured before an index can be applied to it.
                snapshotFlow {list.layoutInfo.totalItemsCount to currentKeys.size}.first {it.first==it.second && it.first>0}
                val index=if(latest) currentKeys.lastIndex else currentKeys.indexOf(id)
                if(index>=0) list.scrollToItem(index,offset)
            }
        }
        if(navigation!=null && consumedNavigation!=navigation.revision) {
            consumedNavigation=navigation.revision
            if(navigation.latest) {position.latest();moveTo(null,latest=true)}
            else {
                val id=navigation.itemKey
                val offset=if(!navigation.highlight && position.anchor==id) position.offset else 0
                if(navigation.highlight && id!=null) position.focus(id) else position.history()
                moveTo(id,offset)
            }
        } else if(!position.ready && !position.following) {
            val key=position.focused ?: position.anchor
            if(key in rowKeys) moveTo(key,if(position.focused==null) position.offset else 0)
        } else if(position.following) moveTo(null,latest=true)
        position.ready=true
    }
    DisposableEffect(position,active) {onDispose {position.stop()}}
    return position
}
