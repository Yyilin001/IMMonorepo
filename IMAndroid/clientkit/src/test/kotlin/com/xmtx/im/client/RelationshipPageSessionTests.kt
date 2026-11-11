package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RelationshipPageSessionTests {
    private val actor=UserId("actor")
    private fun row(name:String)=Relationship(UserId(name),RelationshipState.Accepted,null,1)
    @Test fun `bounded index work precedes publication and navigation replaces finite pages`()=runTest {
        var indexed=0
        val first=RelationshipCursor(UserId("one"),1,"store",RelationshipPageScope.Accepted,"name")
        val store=object:RelationshipPageStore {
            override suspend fun processRelationshipSearchIndex(maximumUsers:Int):Boolean {assertEquals(64,maximumUsers);indexed++;return indexed>=2}
            override suspend fun relationshipPage(viewer:UserId,request:RelationshipPageRequest):RelationshipPage {
                assertEquals(actor,viewer);if(indexed<2) throw RelationshipPageFailure.Building()
                return if(request.cursor==null) RelationshipPage(persistentListOf(row("one")),first) else RelationshipPage(persistentListOf(row("two")))
            }
        }
        val page=RelationshipPageSession(store,actor,this);page.update(RelationshipPageRequest("name"));advanceUntilIdle()
        assertEquals(2,indexed);val initial=page.state.value;assertEquals("one",initial.page.relationships.single().target.value)
        page.next();advanceUntilIdle();assertTrue(page.state.value.canPrevious);assertEquals("two",page.state.value.page.relationships.single().target.value)
        page.previous();advanceUntilIdle();assertFalse(page.state.value.canPrevious);assertEquals(initial.page,page.state.value.page)
        page.close();page.awaitClosed();assertTrue(page.state.value.closed);assertTrue(page.state.value.page.relationships.isEmpty())
        assertEquals("one",initial.page.relationships.single().target.value)
    }
    @Test fun `cancel resistant older query cannot replace latest query or closed state`()=runTest {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val store=object:RelationshipPageStore {
            override suspend fun processRelationshipSearchIndex(maximumUsers:Int)=true
            override suspend fun relationshipPage(viewer:UserId,request:RelationshipPageRequest):RelationshipPage {
                if(request.query=="old") withContext(NonCancellable) {entered.complete(Unit);release.await()}
                return RelationshipPage(persistentListOf(row(request.query)))
            }
        }
        val page=RelationshipPageSession(store,actor,this);page.update(RelationshipPageRequest("old"));advanceTimeBy(251);runCurrent();entered.await()
        page.update(RelationshipPageRequest("new"));advanceTimeBy(251);runCurrent();assertEquals("new",page.state.value.page.relationships.single().target.value)
        page.close();release.complete(Unit);advanceUntilIdle();page.awaitClosed();assertTrue(page.state.value.closed);assertTrue(page.state.value.page.relationships.isEmpty())
    }
    @Test fun `failed refresh clears stale search hits and retry preserves query`()=runTest {
        var fail=false
        val store=object:RelationshipPageStore {
            override suspend fun processRelationshipSearchIndex(maximumUsers:Int)=true
            override suspend fun relationshipPage(viewer:UserId,request:RelationshipPageRequest):RelationshipPage {
                if(fail) throw RelationshipPageFailure.InvalidQuery()
                return RelationshipPage(persistentListOf(row("friend")))
            }
        }
        val page=RelationshipPageSession(store,actor,this);page.update(RelationshipPageRequest("query"));advanceUntilIdle()
        fail=true;page.refresh();advanceUntilIdle();assertTrue(page.state.value.page.relationships.isEmpty());assertNotNull(page.state.value.feedback)
        fail=false;page.retry();advanceUntilIdle();assertEquals("query",page.state.value.request.query);assertEquals(1,page.state.value.page.relationships.size)
        page.close();page.awaitClosed()
    }
}
