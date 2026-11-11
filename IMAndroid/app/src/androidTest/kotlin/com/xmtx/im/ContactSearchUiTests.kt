package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ContactSearchUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("10000000-0000-0000-0000-000000000001")
    @Test fun finitePagesSavedSearchAndRetirementKeepProfileNavigationBoundToSelectedUser() {
        var active by mutableStateOf(true);var page:RelationshipPageSession?=null;var route:Route?=null
        val users=(1..60).map {UserId("20000000-0000-0000-0000-${it.toString().padStart(12,'0')}")}
        val store=object:RelationshipPageStore {
            override suspend fun processRelationshipSearchIndex(maximumUsers:Int)=true
            override suspend fun relationshipPage(viewer:UserId,request:RelationshipPageRequest):RelationshipPage {
                val filtered=users.filter {request.query.isBlank() || it.value.endsWith(request.query)}
                    .filter {request.cursor==null || it.value>request.cursor!!.target.value}
                val rows=filtered.take(request.limit).map {Relationship(it,RelationshipState.Accepted,null,1)}.toPersistentList()
                return RelationshipPage(rows,if(filtered.size>request.limit) RelationshipCursor(rows.last().target,1,"test",request.scope,request.query) else null)
            }
        }
        val session=SessionUi.SignedIn(actor);val app=AppState(session=session)
        val restoration=StateRestorationTester(compose)
        restoration.setContent {
            val owner=rememberCoroutineScope()
            MaterialTheme {Contacts(app,session,active,{null},{RelationshipPageSession(store,actor,owner).also {page=it}},{route=it})}
        }
        compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.size==50}
        compose.onNodeWithTag("contacts-next").performClick();compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.size==10}
        compose.onNodeWithTag("contacts-previous").performClick();compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.size==50}
        compose.onNodeWithTag("contacts-search-query").performTextInput("60");compose.onNodeWithTag("contacts-search-query").performImeAction()
        compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.size==1}
        restoration.emulateSavedInstanceStateRestore();compose.onNodeWithTag("contacts-search-query").assertTextContains("60")
        compose.waitUntil(5000) {page?.state?.value?.page?.relationships?.size==1}
        val old=page;compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(old!!.state.value.closed)
        compose.runOnIdle {active=true};compose.waitUntil(5000) {page!==old && page?.state?.value?.page?.relationships?.size==1}
        compose.onNodeWithTag("contacts-row-${users.last().value}").performScrollTo().performClick();assertEquals(Route.Profile(users.last().value),route)
        compose.runOnIdle {active=false}
    }
    @Test fun demoSearchStaysLocalAndRetainsFriendAndGroupEntrypoints() {
        val session=SessionUi.SignedIn(actor,demo=true)
        val contacts=persistentListOf(Contact(UserId("lin"),"林晓","设计师"),Contact(UserId("chen"),"陈晨","朋友"),Contact(UserId("zhou"),"周宁","同事"))
        val app=AppState(session=session,snapshot=ClientSnapshot(contacts=contacts))
        var route:Route?=null
        compose.setContent {MaterialTheme {Contacts(app,session,true,{error("demo requested profiles")},{error("demo requested store")},{route=it})}}
        compose.waitUntil(5000) {compose.onAllNodesWithText("林晓").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("contacts-search-query").performTextInput("林");compose.onNodeWithTag("contacts-search-query").performImeAction()
        compose.waitUntil(5000) {compose.onAllNodesWithText("陈晨").fetchSemanticsNodes().isEmpty()}
        compose.onNodeWithTag("contacts-row-lin").performScrollTo();compose.onNodeWithText("林晓").assertIsDisplayed();compose.onNodeWithText("新的朋友").assertIsDisplayed();compose.onNodeWithText("群聊").assertIsDisplayed()
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        context.openFileOutput("contact-search-page.png",0).use {compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)}
        compose.onNodeWithTag("contacts-row-lin").performClick();assertEquals(Route.Profile("lin"),route)
        compose.onNodeWithText("新的朋友").performClick();assertEquals(Route.Page(PageKind.Requests),route)
    }
}
