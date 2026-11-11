package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class MessageSearchSessionTests {
    private val actor=UserId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private fun hit(text: String)=MessageSearchHit(MessageId(UUID.randomUUID().toString()),room,actor,1,1,1,MessageSearchPreview(text))
    private fun cursor(query: String="a")=MessageSearchCursor(MessageSearchContext("instance",actor,1,1,MessageSearchScope.All,MessageSearchContent.All,null,query),1,1,MessageId(UUID.randomUUID().toString()))
    private class Store: MessageSearchStore {
        val calls=mutableListOf<MessageSearchRequest>()
        var search: suspend (MessageSearchRequest)->MessageSearchPage={MessageSearchPage()}
        override suspend fun searchMessages(viewer: UserId,request: MessageSearchRequest)=search(request.also {calls+=it})
        override suspend fun processMessageSearchIndex(limit: Int)=MessageSearchProgress(true,0,0,1)
        override suspend fun messageSearchProgress()=MessageSearchProgress(true,0,0,1)
        override suspend fun rebuildMessageSearchIndex()=Unit
    }
    @Test fun typingDebouncesAndClearingOrClosingCancelsAllPublication()=runTest {
        val store=Store();store.search={MessageSearchPage(persistentListOf(hit(it.query)))}
        MessageSearchSession(store,actor,this).use {page ->
            page.update(MessageSearchRequest("a"));advanceTimeBy(100);page.update(MessageSearchRequest("ab"));advanceTimeBy(199)
            assertTrue(store.calls.isEmpty());advanceTimeBy(1);runCurrent();assertEquals("ab",page.state.value.page.hits.single().preview.text)
            page.update(MessageSearchRequest(""));runCurrent();assertTrue(page.state.value.page.hits.isEmpty());assertFalse(page.state.value.loading)
            page.close();page.update(MessageSearchRequest("secret"));runCurrent();assertEquals(1,store.calls.size);assertTrue(page.state.value.closed)
        }
    }
    @Test fun lateNonCooperativeSearchCannotReplaceNewQuery()=runTest {
        val store=Store();val release=CompletableDeferred<Unit>()
        store.search={if(it.query=="old") withContext(NonCancellable) {release.await()};MessageSearchPage(persistentListOf(hit(it.query)))}
        MessageSearchSession(store,actor,this).use {page ->
            page.update(MessageSearchRequest("old"));advanceTimeBy(200);runCurrent()
            page.update(MessageSearchRequest("new"));advanceTimeBy(200);runCurrent();release.complete(Unit);runCurrent()
            assertEquals("new",page.state.value.page.hits.single().preview.text)
        }
    }
    @Test fun finitePagesReplaceRowsAndRetryPreservesFailedContinuation()=runTest {
        val store=Store();val first=hit("first");val second=hit("second");val next=cursor();var fail=true
        store.search={if(it.cursor==null) MessageSearchPage(persistentListOf(first),next) else {if(fail) error("disk");MessageSearchPage(persistentListOf(second))}}
        MessageSearchSession(store,actor,this).use {page ->
            page.update(MessageSearchRequest("a"));advanceTimeBy(200);runCurrent();page.next();runCurrent()
            assertEquals(listOf(first),page.state.value.page.hits);assertNotNull(page.state.value.feedback);assertFalse(page.state.value.canPrevious)
            fail=false;page.retry();runCurrent();assertEquals(listOf(second),page.state.value.page.hits);assertTrue(page.state.value.canPrevious)
            assertEquals(next,store.calls.last().cursor)
            page.previous();runCurrent();assertEquals(listOf(first),page.state.value.page.hits);assertFalse(page.state.value.canPrevious)
        }
    }
    @Test fun changingFilterRejectsPendingPaginationAndDropsOldCursor()=runTest {
        val store=Store();val next=cursor();val gate=CompletableDeferred<Unit>()
        store.search={if(it.cursor!=null) withContext(NonCancellable) {gate.await()};MessageSearchPage(persistentListOf(hit(it.content.name)),if(it.content==MessageSearchContent.All) next else null)}
        MessageSearchSession(store,actor,this).use {page ->
            page.update(MessageSearchRequest("a"));advanceTimeBy(200);runCurrent();page.next();runCurrent()
            page.update(MessageSearchRequest("a",content=MessageSearchContent.Image));advanceTimeBy(200);runCurrent();gate.complete(Unit);runCurrent()
            assertEquals("Image",page.state.value.page.hits.single().preview.text);assertNull(page.state.value.request.cursor);assertFalse(page.state.value.canPrevious)
        }
    }
    @Test fun indexReadinessAndReplacementRecoverWithoutReusingOldGeneration()=runTest {
        val store=Store();var building=true
        store.search={if(building) throw MessageSearchFailure.Building();MessageSearchPage(persistentListOf(hit("ready")),cursor())}
        MessageSearchSession(store,actor,this).use {page ->
            page.update(MessageSearchRequest("a"));advanceTimeBy(200);runCurrent();assertTrue(page.state.value.indexing)
            building=false;page.indexChanged(MessageSearchProgress(true,0,1,1));runCurrent();assertFalse(page.state.value.indexing)
            page.indexChanged(MessageSearchProgress(false,0,1,2));assertTrue(page.state.value.page.hits.isEmpty())
            advanceTimeBy(200);runCurrent();assertNull(store.calls.last().cursor)
        }
    }
    @Test fun stalledContinuationRequiresRestartAndCannotDuplicateResults()=runTest {
        val store=Store();val next=cursor();store.search={MessageSearchPage(persistentListOf(hit("a")),next)}
        MessageSearchSession(store,actor,this).use {page ->
            page.update(MessageSearchRequest("a"));advanceTimeBy(200);runCurrent();val first=page.state.value.page
            page.next();runCurrent();assertTrue(page.state.value.restartRequired);assertEquals(first,page.state.value.page)
            page.retry();advanceTimeBy(200);runCurrent();assertNull(store.calls.last().cursor);assertFalse(page.state.value.restartRequired)
        }
    }
}
