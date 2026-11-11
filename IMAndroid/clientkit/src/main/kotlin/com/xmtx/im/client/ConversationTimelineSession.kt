package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.Closeable

data class TimelineNavigation(val revision: Long, val message: MessageId?, val highlight: Boolean = false, val latest: Boolean = false,val itemKey:String?=message?.value)
data class TimelineViewState(val window: ConversationTimelineWindow = ConversationTimelineWindow(),
    val loaded: Boolean = false, val loading: Boolean = false, val closed: Boolean = false,
    val navigation: TimelineNavigation? = null, val feedback: String? = null)

/** One page's finite local read owner. Call methods from the supplied serial UI scope.
 * Cancellation is not a fence: revision checks also reject non-cooperative late database results.
 * A refresh never accumulates pages and never changes a history window's upper bound. */
class ConversationTimelineSession(private val store: ConversationTimelineStore, val room: RoomId, val viewer: UserId,
    parent: CoroutineScope, private val closed: () -> Unit = {}, private val limit: Int = 120) : Closeable {
    init { require(limit in 4..200) }
    private val owner = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + owner)
    private val mutableState = MutableStateFlow(TimelineViewState())
    val state = mutableState.asStateFlow()
    private var revision = 0L
    private var job: Job? = null
    private var dirty = false
    private var following = true
    private var initialized = false
    private var lastSelection: TimelineSelection = TimelineSelection.Latest

    fun followLatest(value: Boolean) { if (!state.value.closed) following = value }
    fun latest() {
        following = true
        read(TimelineSelection.Latest, null, latest = true)
    }
    fun older() {
        val window = state.value.window
        if (state.value.loading || window.olderCursor == null) return
        following = false
        val entries=window.entries
        val overlap = entries.size / 2
        read(TimelineSelection.Before(entries[overlap].cursor), (entries.first() as? ConversationTimelineEntry.MessageEntry)?.message?.id,itemKey=entries.first().key)
    }
    fun newer() {
        val window = state.value.window
        if (state.value.loading || window.newerBoundary == null) return
        following = false
        val entries=window.entries
        val overlap = (entries.size / 2 - 1).coerceAtLeast(0)
        read(TimelineSelection.After(entries[overlap].cursor), (entries.last() as? ConversationTimelineEntry.MessageEntry)?.message?.id,itemKey=entries.last().key)
    }
    fun locate(message:MessageId,highlight:Boolean=true)=locateEntry(message,null,highlight)
    fun locateActivity(source:String)=locateEntry(null,source,false)
    private fun locateEntry(message:MessageId?,activity:String?,highlight:Boolean) {
        request { version ->
            val result = if(message!=null) store.locateTimelineMessage(room, viewer, message, (limit - 1) / 2, limit / 2)
                else store.locateTimelineActivity(room,viewer,requireNotNull(activity),(limit-1)/2,limit/2)
            if (!current(version)) return@request
            if (result is TimelineLocation.Found) {
                following = false
                lastSelection=result.window.entries.lastOrNull()?.cursor?.let {TimelineSelection.Through(it)} ?: TimelineSelection.Latest
            }
            mutableState.value = when (result) {
                is TimelineLocation.Found -> state.value.copy(window = result.window, loaded = true, feedback = null,
                    navigation = TimelineNavigation(version, message, highlight,itemKey=message?.value ?: "activity:$activity"))
                TimelineLocation.Withdrawn, TimelineLocation.Unavailable -> state.value.copy(loaded = true,
                    window = if(message==null) state.value.window else state.value.window.copy(replySources = state.value.window.replySources.remove(message)),
                    feedback = if (result == TimelineLocation.Withdrawn) "这条消息已撤回。" else "这条消息当前不可用。")
            }
            // Restored anchors may have expired. Give the user a usable window without inventing a match.
            if (result !is TimelineLocation.Found && state.value.window.entries.isEmpty()) {
                val fallback = store.conversationTimeline(room, viewer, limit = limit)
                if (current(version)) mutableState.value = state.value.copy(window = fallback)
            }
        }
    }
    fun refresh() {
        if (!initialized || state.value.closed) return
        if (state.value.loading) { dirty = true; return }
        val bound = state.value.window.entries.lastOrNull()?.cursor
        read(when {following->TimelineSelection.Latest;bound!=null->TimelineSelection.Through(bound);!state.value.window.latest->lastSelection;else->TimelineSelection.Latest}, null, navigate = false)
    }
    private fun read(selection: TimelineSelection, target: MessageId?, latest: Boolean = false, navigate: Boolean = true,itemKey:String?=target?.value) {
        request { version ->
            val window = store.conversationTimeline(room, viewer, selection, limit)
            if (current(version)) {
                lastSelection=selection
                mutableState.value = state.value.copy(window = window, loaded = true, feedback = null,
                    navigation = if (navigate) TimelineNavigation(version, target ?: (window.entries.firstOrNull() as? ConversationTimelineEntry.MessageEntry)?.message?.id, latest = latest,itemKey=itemKey ?: window.entries.firstOrNull()?.key) else state.value.navigation)
            }
        }
    }
    private fun current(version: Long) = !state.value.closed && revision == version
    private fun request(body: suspend (Long) -> Unit) {
        if (state.value.closed) return
        initialized = true
        val version = ++revision
        job?.cancel(); dirty = false
        mutableState.value = state.value.copy(loading = true, feedback = null)
        job = scope.launch {
            try { body(version) }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { if (current(version)) mutableState.value = state.value.copy(feedback = "本地消息读取失败，请重试。") }
            finally { if (current(version)) {
                mutableState.value = state.value.copy(loading = false)
                if (dirty) { dirty = false; refresh() }
            } }
        }
    }
    override fun close() {
        if (state.value.closed) return
        revision++; owner.cancel(); mutableState.value = TimelineViewState(closed = true); closed()
    }
    suspend fun awaitClosed() { owner.join() }
}
