package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ConversationTimelineSessionTests {
    private val room = RoomId(UUID.randomUUID().toString())
    private val actor = UserId(UUID.randomUUID().toString())
    private fun message(n: Int) = Message(MessageId(UUID.randomUUID().toString()),room,actor,"$n",n.toLong(),roomSequence=n.toLong())
    private inner class Store : ConversationTimelineStore {
        var messages = (1..1000).map(::message)
        val selections = mutableListOf<TimelineSelection>()
        var read: (suspend () -> Unit)? = null
        var location: TimelineLocation? = null
        private fun window(selected: List<Message>): ConversationTimelineWindow {
            if(selected.isEmpty()) return ConversationTimelineWindow()
            return ConversationTimelineWindow(selected.toPersistentList(),selected.first().takeIf {it != messages.first()}?.timelineCursor(),
                messages.firstOrNull {it.timelineSequence > selected.last().timelineSequence}?.timelineCursor())
        }
        override suspend fun conversationTimeline(room: RoomId,viewer: UserId,selection: TimelineSelection,limit: Int): ConversationTimelineWindow {
            selections += selection
            val selected = when(selection) {
                TimelineSelection.Latest -> messages.takeLast(limit)
                is TimelineSelection.Before -> messages.filter {it.timelineSequence < selection.cursor.sequence}.takeLast(limit)
                is TimelineSelection.Through -> messages.filter {it.timelineSequence <= selection.cursor.sequence}.takeLast(limit)
                is TimelineSelection.After -> messages.filter {it.timelineSequence > selection.cursor.sequence}.take(limit)
            }
            val result=window(selected).let {if(selected.isEmpty()) it.copy(latest=selection==TimelineSelection.Latest) else it};read?.invoke();return result
        }
        override suspend fun locateTimelineMessage(room: RoomId,viewer: UserId,message: MessageId,before: Int,after: Int): TimelineLocation {
            location?.let {return it}
            val index=messages.indexOfFirst {it.id == message}
            return if(index < 0) TimelineLocation.Unavailable else TimelineLocation.Found(window(messages.subList((index-before).coerceAtLeast(0),(index+after+1).coerceAtMost(messages.size))))
        }
    }

    @Test fun pagesStayBoundedAndHistoryRefreshExcludesIncomingMessages() = runTest {
        val store=Store()
        ConversationTimelineSession(store,room,actor,this).use { page ->
            page.latest();runCurrent();assertEquals(120,page.state.value.window.messages.size)
            val tail=page.state.value.window.messages.last()
            page.followLatest(false);store.messages += message(1001);page.refresh();runCurrent()
            assertEquals(tail,page.state.value.window.messages.last());assertIs<TimelineSelection.Through>(store.selections.last())
            assertNotNull(page.state.value.window.newerBoundary)
            repeat(4) { page.older();runCurrent();assertEquals(120,page.state.value.window.messages.size) }
            val historical=page.state.value.window.messages.last().timelineSequence
            page.newer();runCurrent();assertTrue(page.state.value.window.messages.last().timelineSequence > historical)
            page.latest();runCurrent();assertEquals(1001L,page.state.value.window.messages.last().timelineSequence)
        }
    }
    @Test fun replyLocationJumpsDirectlyToAnOldWindowAndRestoresWithoutHighlight() = runTest {
        val store=Store();val target=store.messages[7]
        ConversationTimelineSession(store,room,actor,this).use { page ->
            page.latest();runCurrent();assertFalse(page.state.value.window.messages.any {it.id==target.id})
            page.locate(target.id);runCurrent()
            assertEquals(1,store.selections.size);assertTrue(page.state.value.window.messages.size <= 120)
            assertTrue(page.state.value.window.messages.any {it.id==target.id});assertTrue(page.state.value.navigation!!.highlight)
            page.locate(target.id,highlight=false);runCurrent();assertFalse(page.state.value.navigation!!.highlight)
        }
    }
    @Test fun supersededAndClosedOwnersRejectNonCooperativeLateReads() = runTest {
        val store=Store();val release=CompletableDeferred<Unit>()
        store.read={withContext(NonCancellable) {release.await()}}
        val page=ConversationTimelineSession(store,room,actor,this)
        page.latest();runCurrent()
        store.read=null;page.locate(store.messages[3].id);runCurrent()
        val focused=page.state.value.window
        release.complete(Unit);runCurrent();assertEquals(focused,page.state.value.window)
        val closing=CompletableDeferred<Unit>();store.read={withContext(NonCancellable) {closing.await()}}
        page.latest();runCurrent();page.close()
        var drained=false;val join=launch {page.awaitClosed();drained=true};runCurrent();assertFalse(drained)
        closing.complete(Unit);runCurrent();join.join()
        assertTrue(drained);assertTrue(page.state.value.closed);assertTrue(page.state.value.window.messages.isEmpty())
        val count=store.selections.size;page.latest();page.refresh();page.locate(store.messages[0].id);runCurrent();assertEquals(count,store.selections.size)
    }
    @Test fun invalidationsDuringReadCoalesceAndFetchTheLatestCommittedVersion() = runTest {
        val store=Store();val release=CompletableDeferred<Unit>();store.read={release.await()}
        ConversationTimelineSession(store,room,actor,this).use { page ->
            page.latest();runCurrent();repeat(20) {page.refresh()}
            store.messages += message(1001);store.read=null;release.complete(Unit);runCurrent()
            assertEquals(2,store.selections.size);assertEquals(1001L,page.state.value.window.messages.last().timelineSequence)
            assertFalse(page.state.value.loading)
        }
    }
    @Test fun failedReadsRetainWindowAndWithdrawnReplyDropsItsPreview() = runTest {
        val store=Store()
        ConversationTimelineSession(store,room,actor,this).use { page ->
            page.latest();runCurrent();val initial=page.state.value.window
            store.read={error("storage")};page.refresh();runCurrent()
            assertEquals(initial,page.state.value.window);assertNotNull(page.state.value.feedback);assertFalse(page.state.value.loading)
            store.read=null;page.refresh();runCurrent();assertNull(page.state.value.feedback)
            store.location=TimelineLocation.Withdrawn;page.locate(store.messages[0].id);runCurrent()
            assertEquals(initial,page.state.value.window);assertEquals("这条消息已撤回。",page.state.value.feedback)
        }
    }
    @Test fun expiredRestoredAnchorFallsBackToUsableLocalWindowWithExplicitFeedback() = runTest {
        val store=Store();store.location=TimelineLocation.Unavailable
        ConversationTimelineSession(store,room,actor,this).use { page ->
            page.locate(MessageId(UUID.randomUUID().toString()),highlight=false);runCurrent()
            assertTrue(page.state.value.loaded);assertEquals(120,page.state.value.window.messages.size)
            assertNull(page.state.value.navigation);assertEquals("这条消息当前不可用。",page.state.value.feedback)
        }
    }
    @Test fun emptyHistoryRetainsItsQueryBoundAcrossAutomaticRefresh()=runTest {
        val store=Store()
        ConversationTimelineSession(store,room,actor,this).use {page->
            page.latest();runCurrent();store.messages=emptyList();page.older();runCurrent()
            val bound=store.selections.last();assertIs<TimelineSelection.Before>(bound);assertFalse(page.state.value.window.latest)
            store.messages=listOf(message(2001));page.refresh();runCurrent()
            assertEquals(bound,store.selections.last());assertTrue(page.state.value.window.messages.isEmpty());assertFalse(page.state.value.window.latest)
            page.latest();runCurrent();assertEquals(2001L,page.state.value.window.messages.single().roomSequence)
        }
    }

}
