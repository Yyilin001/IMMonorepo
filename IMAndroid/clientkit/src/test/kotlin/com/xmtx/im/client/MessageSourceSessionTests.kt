package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class MessageSourceSessionTests {
    private val actor=UserId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private val one=Message(MessageId(UUID.randomUUID().toString()),room,actor,"one",1)
    private val two=Message(MessageId(UUID.randomUUID().toString()),room,actor,"two",2)
    private class Store: MessageSourceStore {
        val calls=mutableListOf<PersistentSet<MessageId>>()
        var read: suspend (PersistentSet<MessageId>)->PersistentMap<MessageId,Message> ={persistentMapOf()}
        override suspend fun messageSources(room: RoomId,viewer: UserId,ids: PersistentSet<MessageId>)=read(ids.also {calls+=it})
    }
    @Test fun selectionReplacementAndEmptyDemandNeverRetainOldBodies()=runTest {
        val store=Store();store.read={ids->listOf(one,two).filter {it.id in ids}.associateBy {it.id}.toPersistentMap()}
        MessageSourceSession(store,room,actor,this).use {page->
            page.select(persistentSetOf(one.id));runCurrent();assertEquals(persistentMapOf(one.id to one),page.state.value.messages)
            page.select(persistentSetOf(two.id));assertTrue(page.state.value.messages.isEmpty());runCurrent()
            assertEquals(persistentMapOf(two.id to two),page.state.value.messages)
            page.select(persistentSetOf());assertTrue(page.state.value.loaded);assertTrue(page.state.value.messages.isEmpty());runCurrent();assertEquals(2,store.calls.size)
        }
    }
    @Test fun nonCooperativeOldReadCannotReplaceSelectionAndCloseWaitsForIt()=runTest {
        val store=Store();val gate=CompletableDeferred<Unit>()
        store.read={ids->if(one.id in ids) withContext(NonCancellable) {gate.await();persistentMapOf(one.id to one)} else persistentMapOf(two.id to two)}
        val page=MessageSourceSession(store,room,actor,this)
        page.select(persistentSetOf(one.id));runCurrent();page.select(persistentSetOf(two.id));runCurrent()
        assertEquals(two,page.state.value.messages[two.id]);page.close()
        val drain=async {page.awaitClosed()};runCurrent();assertFalse(drain.isCompleted)
        gate.complete(Unit);runCurrent();drain.await();assertTrue(page.state.value.closed);assertTrue(page.state.value.messages.isEmpty())
    }
    @Test fun repeatedInvalidationCoalescesAndSuppressesObsoleteRead()=runTest {
        val store=Store();val first=CompletableDeferred<Unit>();val second=CompletableDeferred<Unit>();var count=0
        store.read={if(++count==1) {first.await();persistentMapOf(one.id to one)} else {second.await();persistentMapOf()}}
        MessageSourceSession(store,room,actor,this).use {page->
            page.select(persistentSetOf(one.id));runCurrent();repeat(50) {page.refresh()}
            first.complete(Unit);runCurrent();assertEquals(2,count);assertTrue(page.state.value.messages.isEmpty());assertTrue(page.state.value.loading)
            second.complete(Unit);runCurrent();assertTrue(page.state.value.loaded);assertFalse(page.state.value.loading)
        }
    }
    @Test fun invalidStoreResultOrFailureClearsPreviouslyVisibleSourcesAndCanRetry()=runTest {
        val store=Store();store.read={persistentMapOf(one.id to one)}
        MessageSourceSession(store,room,actor,this).use {page->
            page.select(persistentSetOf(one.id));runCurrent()
            store.read={persistentMapOf(two.id to two)};page.refresh();runCurrent()
            assertTrue(page.state.value.messages.isEmpty());assertNotNull(page.state.value.feedback)
            store.read={persistentMapOf(one.id to one.copy(withdrawn=true))};page.refresh();runCurrent();assertFalse(page.state.value.loaded)
            store.read={error("disk")};page.refresh();runCurrent();assertTrue(page.state.value.messages.isEmpty())
            store.read={persistentMapOf(one.id to one.copy(revision=2))};page.refresh();runCurrent();assertEquals(2L,page.state.value.messages[one.id]?.revision);assertNull(page.state.value.feedback)
        }
    }
    @Test fun demandLimitAndClosedSessionRejectExtraWork()=runTest {
        val store=Store();var closed=0
        val page=MessageSourceSession(store,room,actor,this,closed={closed++})
        assertFailsWith<IllegalArgumentException> {page.select((1..101).map {MessageId(UUID(0,it.toLong()).toString())}.toPersistentSet())}
        page.close();page.close();page.select(persistentSetOf(one.id));page.refresh();runCurrent()
        assertEquals(1,closed);assertTrue(store.calls.isEmpty())
    }
}
