package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RelationshipWindowSessionTests {
    private val actor=UserId("actor")
    private class Store:RelationshipWindowStore {
        val rows=(1..100).map {Relationship(UserId(it.toString().padStart(3,'0')),RelationshipState.Accepted,null,1)}
        val requests=mutableListOf<RelationshipAnchor>();var entered:CompletableDeferred<Unit>?=null;var release:CompletableDeferred<Unit>?=null;var pageRelease:CompletableDeferred<Unit>?=null
        override suspend fun processRelationshipSearchIndex(maximumUsers:Int)=true
        override suspend fun relationshipPage(viewer:UserId,request:RelationshipPageRequest):RelationshipPage {
            val latch=pageRelease;pageRelease=null
            if(latch!=null) withContext(NonCancellable) {entered!!.complete(Unit);latch.await()}
            val found=rows.filter {request.cursor==null || it.target.value>request.cursor!!.target.value}
            return page(found.take(request.limit),found.size>request.limit,request)
        }
        private fun page(rows:List<Relationship>,more:Boolean,request:RelationshipPageRequest)=RelationshipPage(rows.toPersistentList(),
            if(more) RelationshipCursor(rows.last().target,1,"test",request.scope,request.query) else null)
        override suspend fun relationshipWindow(viewer:UserId,request:RelationshipPageRequest,anchor:RelationshipAnchor,precedingCount:Int):RelationshipWindow {
            requests+=anchor
            val latch=release;release=null
            if(latch!=null) withContext(NonCancellable) {entered!!.complete(Unit);latch.await()}
            val i=rows.indexOfFirst {it.target==anchor.target}.coerceAtLeast(0)
            val start=(i-precedingCount).coerceAtLeast(0).coerceAtMost(rows.size-request.limit)
            val values=rows.drop(start).take(request.limit)
            return RelationshipWindow(page(values,start+values.size<rows.size,request),anchor,start>0)
        }
    }
    @Test fun `restored viewport navigates within bounded window and explicit navigation retains window history`()=runTest {
        val store=Store();val owner=RelationshipPageSession(store,actor,this)
        val saved=RelationshipViewport(RelationshipAnchor(UserId("045"),1),23)
        owner.update(RelationshipPageRequest(),saved);advanceUntilIdle()
        val before=owner.state.value
        assertEquals(saved.anchor.target,before.navigation!!.target);assertEquals(23,before.navigation.offset);assertTrue(before.canPrevious)
        assertEquals(50,before.page.relationships.size)
        owner.next();advanceUntilIdle();assertEquals("085",owner.state.value.page.relationships.first().target.value)
        owner.previous();advanceUntilIdle();assertEquals(before.page,owner.state.value.page)
        owner.first();advanceUntilIdle();assertEquals("001",owner.state.value.page.relationships.first().target.value);assertFalse(owner.state.value.canPrevious);assertNull(owner.state.value.navigation!!.target)
        owner.close();owner.awaitClosed()
    }
    @Test fun `moving viewport during delayed refresh discards the obsolete restoration`()=runTest {
        val store=Store();val owner=RelationshipPageSession(store,actor,this);owner.update(RelationshipPageRequest());advanceUntilIdle()
        owner.observeViewport(UserId("020"),17)
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();store.entered=entered;store.release=release
        owner.refresh();runCurrent();entered.await()
        owner.observeViewport(UserId("030"),31);release.complete(Unit);advanceUntilIdle()
        assertEquals(listOf("020","030"),store.requests.map {it.target.value})
        assertEquals(UserId("030"),owner.state.value.navigation!!.target);assertEquals(31,owner.state.value.navigation!!.offset)
        owner.close();owner.awaitClosed()
    }
    @Test fun `source refresh waits for scrolling to settle and then uses the final visible row`()=runTest {
        val store=Store();val owner=RelationshipPageSession(store,actor,this);owner.update(RelationshipPageRequest());advanceUntilIdle()
        owner.observeViewport(UserId("020"),17,true);owner.refresh();advanceUntilIdle();assertTrue(store.requests.isEmpty())
        owner.observeViewport(UserId("025"),8,false);advanceUntilIdle()
        assertEquals(listOf("025"),store.requests.map {it.target.value});assertEquals(UserId("025"),owner.state.value.navigation!!.target)
        owner.close();owner.awaitClosed()
    }
    @Test fun `source change while advancing cannot resurrect the previous page viewport`()=runTest {
        val store=Store();val owner=RelationshipPageSession(store,actor,this)
        owner.update(RelationshipPageRequest(),RelationshipViewport(RelationshipAnchor(UserId("045"),1),7));advanceUntilIdle()
        owner.observeViewport(UserId("045"),7)
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();store.entered=entered;store.pageRelease=release
        owner.next();runCurrent();entered.await();owner.refresh();release.complete(Unit);advanceUntilIdle()
        assertEquals(UserId("085"),store.requests.last().target)
        assertEquals(50,owner.state.value.page.relationships.size)
        assertEquals(UserId("085"),owner.state.value.navigation!!.target)
        owner.close();owner.awaitClosed()
    }

    @Test fun `replayed changes before initial request cannot publish a default scope over saved viewport`()=runTest {
        val changes=kotlinx.coroutines.flow.MutableStateFlow(9L)
        val store=Store();val owner=RelationshipPageSession(store,actor,this,changes)
        advanceUntilIdle();owner.refresh();owner.retry();advanceUntilIdle()
        assertNull(owner.state.value.navigation);assertTrue(store.requests.isEmpty());assertTrue(owner.state.value.page.relationships.isEmpty())
        val saved=RelationshipViewport(RelationshipAnchor(UserId("076"),1),19)
        owner.update(RelationshipPageRequest(scope=RelationshipPageScope.Incoming),saved);advanceUntilIdle()
        assertEquals(RelationshipPageScope.Incoming,owner.state.value.request.scope)
        assertEquals(saved.anchor.target,owner.state.value.navigation!!.target);assertEquals(saved.offset,owner.state.value.navigation!!.offset)
        changes.value++;advanceUntilIdle()
        assertEquals(saved.anchor.target,owner.state.value.navigation!!.target)
        owner.close();owner.awaitClosed()
    }

}
