package com.xmtx.im

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ContactWindowUiTests {
    @get:Rule val compose=createComposeRule()
    private fun user(n:Int)=UserId("20000000-0000-0000-0000-${n.toString().padStart(12,'0')}")
    private inner class Store:RelationshipWindowStore {
        var rows=(1..120).map {Relationship(user(it),RelationshipState.Accepted,null,1)}
        override suspend fun processRelationshipSearchIndex(maximumUsers:Int)=true
        private fun page(values:List<Relationship>,more:Boolean,request:RelationshipPageRequest)=RelationshipPage(values.toPersistentList(),
            if(more) RelationshipCursor(values.last().target,1,"fixture",request.scope,request.query) else null)
        override suspend fun relationshipPage(viewer:UserId,request:RelationshipPageRequest):RelationshipPage {
            val found=rows.filter {request.cursor==null || it.target.value>request.cursor!!.target.value}
            return page(found.take(request.limit),found.size>request.limit,request)
        }
        override suspend fun relationshipWindow(viewer:UserId,request:RelationshipPageRequest,anchor:RelationshipAnchor,precedingCount:Int):RelationshipWindow {
            val before=rows.filter {it.target.value<anchor.target.value}.asReversed();val after=rows.filter {it.target.value>=anchor.target.value}
            var n=minOf(precedingCount,before.size);val m=minOf(request.limit-n,after.size);n=minOf(request.limit-m,before.size)
            val values=before.take(n).asReversed()+after.take(m)
            return RelationshipWindow(page(values,after.size>m,request),(after.firstOrNull() ?: before.firstOrNull())?.let {RelationshipAnchor(it.target,it.updatedAt)},before.size>n)
        }
    }
    @Test fun measuredAnchorSurvivesRefreshRetirementAndSavedStateThenFallsForwardWhenRemoved() {
        val store=Store();val changes=MutableStateFlow(0L);val signedIn=SessionUi.SignedIn(user(999))
        var active by mutableStateOf(true);var page:RelationshipPageSession?=null
        lateinit var list:LazyListState;lateinit var owner:CoroutineScope
        val restoration=StateRestorationTester(compose)
        restoration.setContent {
            list=rememberLazyListState();owner=rememberCoroutineScope()
            MaterialTheme {Contacts(AppState(session=signedIn),signedIn,active,{null},
                {RelationshipPageSession(store,signedIn.user,owner,changes).also {page=it}},{},list)}
        }
        compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.size==50}
        compose.onNodeWithTag("contacts-next").performClick()
        compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.firstOrNull()?.target==user(51)}
        compose.runOnIdle {owner.launch {list.scrollToItem(27,19)}}
        fun anchored(id:UserId,offset:Int)=list.layoutInfo.visibleItemsInfo.firstOrNull {it.index==list.firstVisibleItemIndex}?.key==id.value && list.firstVisibleItemScrollOffset==offset
        compose.waitUntil(5000) {anchored(user(75),19)};compose.waitForIdle()
        compose.runOnIdle {store.rows=(listOf(Relationship(user(0),RelationshipState.Accepted,null,1))+store.rows).filter {it.target!=user(55)};changes.value++}
        compose.waitUntil(5000) {page?.state?.value?.navigation?.target==user(75) && anchored(user(75),19)}
        assertEquals(50,page!!.state.value.page.relationships.size)
        val retired=page;compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(retired!!.state.value.closed)
        compose.runOnIdle {active=true}
        compose.waitUntil(5000) {page!==retired && page?.state?.value?.navigation?.target==user(75) && anchored(user(75),19)}
        restoration.emulateSavedInstanceStateRestore()
        compose.waitUntil(5000) {page?.state?.value?.navigation?.target==user(75) && anchored(user(75),19)}
        compose.runOnIdle {store.rows=store.rows.filter {it.target!=user(75)};changes.value++}
        compose.waitUntil(5000) {page?.state?.value?.navigation?.target==user(76) && anchored(user(76),0)}
        compose.onNodeWithTag("contacts-first").performClick()
        compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.firstOrNull()?.target==user(0) && list.firstVisibleItemIndex==0}
        assertFalse(page!!.state.value.canPrevious);compose.runOnIdle {active=false}
    }
}
