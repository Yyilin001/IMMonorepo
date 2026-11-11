package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class FavoriteMessageSessionTests {
    private val actor=UserId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private val item=FavoriteMessageItem(room,MessageId(UUID.randomUUID().toString()),"body",1,1)
    private val cursor=FavoriteMessageCursor("store",1,room,item.message)
    private class Store: FavoriteMessageStore {
        val calls=mutableListOf<FavoriteMessageSelection>()
        var read:suspend (FavoriteMessageSelection)->FavoriteMessagePage={FavoriteMessagePage()}
        override suspend fun favoriteMessages(viewer: UserId,selection: FavoriteMessageSelection,limit: Int): FavoriteMessagePage {
            assertEquals(50,limit);calls+=selection;return read(selection)
        }
    }
    @Test fun bidirectionalNavigationReplacesThePageAndFailureRetriesTheSameSelection()=runTest {
        val store=Store();var fail=false
        store.read={if(fail) error("disk") else if(it==FavoriteMessageSelection.Latest) FavoriteMessagePage(persistentListOf(item),next=cursor) else FavoriteMessagePage(persistentListOf(item.copy(text="next")),previous=cursor)}
        FavoriteMessageSession(store,actor,this).use {page->
            page.latest();runCurrent();assertEquals("body",page.state.value.page.items.single().text)
            fail=true;page.next();assertTrue(page.state.value.page.items.isEmpty());runCurrent();assertNotNull(page.state.value.feedback)
            fail=false;page.refresh();runCurrent();assertEquals(FavoriteMessageSelection.Before(cursor),store.calls.last());assertEquals("next",page.state.value.page.items.single().text)
            page.previous();runCurrent();assertEquals(FavoriteMessageSelection.After(cursor),store.calls.last())
            page.latest();runCurrent();assertEquals(FavoriteMessageSelection.Latest,store.calls.last())
        }
    }
    @Test fun invalidationCoalescesAndNeverPublishesObsoleteResults()=runTest {
        val store=Store();val first=CompletableDeferred<Unit>();val next=CompletableDeferred<Unit>()
        store.read={if(store.calls.size==1) {first.await();FavoriteMessagePage(persistentListOf(item))} else {next.await();FavoriteMessagePage()}}
        FavoriteMessageSession(store,actor,this).use {page->
            page.latest();runCurrent();repeat(50) {page.refresh()};first.complete(Unit);runCurrent()
            assertEquals(2,store.calls.size);assertTrue(page.state.value.page.items.isEmpty());assertTrue(page.state.value.loading)
            next.complete(Unit);runCurrent();assertTrue(page.state.value.loaded);assertFalse(page.state.value.loading)
        }
    }
    @Test fun closedOwnerDrainsNonCooperativeReadAndClearsAllBodies()=runTest {
        val store=Store();val gate=CompletableDeferred<Unit>();var closed=0
        store.read={withContext(NonCancellable) {gate.await();FavoriteMessagePage(persistentListOf(item))}}
        val page=FavoriteMessageSession(store,actor,this) {closed++};page.latest();runCurrent();page.close()
        val drain=async {page.awaitClosed()};runCurrent();assertFalse(drain.isCompleted)
        gate.complete(Unit);runCurrent();drain.await();page.close();page.latest();page.refresh();assertEquals(1,closed)
        assertEquals(1,store.calls.size);assertTrue(page.state.value.page.items.isEmpty());assertTrue(page.state.value.closed)
    }
    @Test fun replacementRejectsLateResultsAndOversizedOrDuplicatePages()=runTest {
        val store=Store();val gate=CompletableDeferred<Unit>()
        store.read={if(store.calls.size==1) withContext(NonCancellable) {gate.await();FavoriteMessagePage(persistentListOf(item))} else FavoriteMessagePage()}
        FavoriteMessageSession(store,actor,this).use {page->
            page.latest();runCurrent();page.latest();runCurrent();gate.complete(Unit);runCurrent();assertTrue(page.state.value.page.items.isEmpty())
            store.read={FavoriteMessagePage(persistentListOf(item,item))};page.refresh();runCurrent();assertNotNull(page.state.value.feedback)
            store.read={FavoriteMessagePage((1..51).map {item.copy(message=MessageId(UUID(0,it.toLong()).toString()))}.toPersistentList())}
            page.refresh();runCurrent();assertNotNull(page.state.value.feedback);assertFalse(page.state.value.loaded)
        }
    }
    @Test fun samePageRefreshKeepsStableRowsUntilReplacementButFailuresClearThem()=runTest {
        val store=Store();store.read={FavoriteMessagePage(persistentListOf(item))}
        FavoriteMessageSession(store,actor,this).use {page->
            page.latest();runCurrent();val old=page.state.value.page
            val gate=CompletableDeferred<Unit>();store.read={gate.await();FavoriteMessagePage(persistentListOf(item.copy(text="new")))}
            page.refresh();runCurrent();assertEquals(old,page.state.value.page)
            repeat(20) {page.refresh()};gate.complete(Unit);runCurrent();assertEquals("new",page.state.value.page.items.single().text)
            store.read={error("disk")};page.refresh();runCurrent();assertTrue(page.state.value.page.items.isEmpty());assertNotNull(page.state.value.feedback)
        }
    }

}
