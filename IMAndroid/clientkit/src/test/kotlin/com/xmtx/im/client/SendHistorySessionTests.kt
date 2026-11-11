package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class SendHistorySessionTests {
    private val actor=UserId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private val item=SendHistoryItem(UUID.randomUUID().toString(),"body",1,Delivery.Pending)
    private val cursor=SendHistoryCursor("store",room,1)
    private class Store: SendHistoryStore {
        val calls=mutableListOf<SendHistorySelection>()
        var read:suspend (SendHistorySelection)->SendHistoryPage={SendHistoryPage()}
        override suspend fun sendHistory(room: RoomId,viewer: UserId,selection: SendHistorySelection,limit: Int): SendHistoryPage {
            assertEquals(50,limit);calls+=selection;return read(selection)
        }
    }
    @Test fun bidirectionalNavigationReplacesThePageAndFailureRetriesTheSameSelection()=runTest {
        val store=Store();var fail=false
        store.read={if(fail) error("disk") else if(it==SendHistorySelection.Latest) SendHistoryPage(persistentListOf(item),next=cursor) else SendHistoryPage(persistentListOf(item.copy(text="next")),previous=cursor)}
        SendHistorySession(store,room,actor,this).use {page->
            page.latest();runCurrent();assertEquals("body",page.state.value.page.items.single().text)
            fail=true;page.next();assertTrue(page.state.value.page.items.isEmpty());runCurrent();assertNotNull(page.state.value.feedback)
            fail=false;page.refresh();runCurrent();assertEquals(SendHistorySelection.Before(cursor),store.calls.last());assertEquals("next",page.state.value.page.items.single().text)
            page.previous();runCurrent();assertEquals(SendHistorySelection.After(cursor),store.calls.last())
            page.latest();runCurrent();assertEquals(SendHistorySelection.Latest,store.calls.last())
        }
    }
    @Test fun invalidationCoalescesAndNeverPublishesObsoleteResults()=runTest {
        val store=Store();val first=CompletableDeferred<Unit>();val next=CompletableDeferred<Unit>()
        store.read={if(store.calls.size==1) {first.await();SendHistoryPage(persistentListOf(item))} else {next.await();SendHistoryPage()}}
        SendHistorySession(store,room,actor,this).use {page->
            page.latest();runCurrent();repeat(50) {page.refresh()};first.complete(Unit);runCurrent()
            assertEquals(2,store.calls.size);assertTrue(page.state.value.page.items.isEmpty());assertTrue(page.state.value.loading)
            next.complete(Unit);runCurrent();assertTrue(page.state.value.loaded);assertFalse(page.state.value.loading)
        }
    }
    @Test fun closedOwnerDrainsNonCooperativeReadAndClearsAllBodies()=runTest {
        val store=Store();val gate=CompletableDeferred<Unit>();var closed=0
        store.read={withContext(NonCancellable) {gate.await();SendHistoryPage(persistentListOf(item))}}
        val page=SendHistorySession(store,room,actor,this) {closed++};page.latest();runCurrent();page.close()
        val drain=async {page.awaitClosed()};runCurrent();assertFalse(drain.isCompleted)
        gate.complete(Unit);runCurrent();drain.await();page.close();page.latest();page.refresh();assertEquals(1,closed)
        assertEquals(1,store.calls.size);assertTrue(page.state.value.page.items.isEmpty());assertTrue(page.state.value.closed)
    }
    @Test fun replacementRejectsLateResultsAndOversizedOrDuplicatePages()=runTest {
        val store=Store();val gate=CompletableDeferred<Unit>()
        store.read={if(store.calls.size==1) withContext(NonCancellable) {gate.await();SendHistoryPage(persistentListOf(item))} else SendHistoryPage()}
        SendHistorySession(store,room,actor,this).use {page->
            page.latest();runCurrent();page.latest();runCurrent();gate.complete(Unit);runCurrent();assertTrue(page.state.value.page.items.isEmpty())
            store.read={SendHistoryPage(persistentListOf(item,item))};page.refresh();runCurrent();assertNotNull(page.state.value.feedback)
            store.read={SendHistoryPage((1..51).map {item.copy(operation=UUID(0,it.toLong()).toString())}.toPersistentList())}
            page.refresh();runCurrent();assertNotNull(page.state.value.feedback);assertFalse(page.state.value.loaded)
        }
    }
    @Test fun samePageRefreshKeepsStableRowsUntilReplacementButFailuresClearThem()=runTest {
        val store=Store();store.read={SendHistoryPage(persistentListOf(item))}
        SendHistorySession(store,room,actor,this).use {page->
            page.latest();runCurrent();val old=page.state.value.page
            val gate=CompletableDeferred<Unit>();store.read={gate.await();SendHistoryPage(persistentListOf(item.copy(text="new")))}
            page.refresh();runCurrent();assertEquals(old,page.state.value.page)
            repeat(20) {page.refresh()};gate.complete(Unit);runCurrent();assertEquals("new",page.state.value.page.items.single().text)
            store.read={error("disk")};page.refresh();runCurrent();assertTrue(page.state.value.page.items.isEmpty());assertNotNull(page.state.value.feedback)
        }
    }

}
