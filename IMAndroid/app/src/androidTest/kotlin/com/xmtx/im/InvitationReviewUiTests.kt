package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

class InvitationReviewUiTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun user(n:Int)=UserId("10000000-0000-0000-0000-${n.toString().padStart(12,'0')}")
    private fun request(n:Int)="20000000-0000-0000-0000-${n.toString().padStart(12,'0')}"
    private inner class Fixture:AutoCloseable {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id())
        val avatars=DirectoryAvatarFixture(actor,device,room)
        private val context=InstrumentationRegistry.getInstrumentation().targetContext
        private val store=openBoundFixtureStore(context,actor,device)
        var permitted=true
        private val api=object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse =
                if(!permitted) EdgeResponse(403,buildJsonObject {}) else EdgeResponse(200,
                    if(path.endsWith("baseline")) buildJsonObject {put("roomID",buildJsonObject {put("rawValue",room.value)});put("membershipRevision",7)}
                    else buildJsonObject {put("items",JsonArray(emptyList()))})
            override suspend fun requestWithQuery(path:String,query:Map<String,String>,maximumBytes:Long)=
                if(!permitted) EdgeResponse(403,buildJsonObject {}) else EdgeResponse(200,buildJsonObject {
                    put("items",JsonArray((1..40).map {n->buildJsonObject {
                        put("request_id",request(n));put("invite_id",room.value);put("room_id",room.value)
                        put("applicant_user_id",user(n).value);put("state","pending");put("created_at_ms",1000)
                    }}))
                })
        }
        private val client=InvitationClient(api)
        private val service=InvitationService(actor,client,store,KeystoreInvitationSecrets(context,"https://review-test",actor,device))
        fun open(target:RoomId?):InvitationManagement {assertEquals(room,target);return InvitationManagement(room,client,InvitationDirectory(api),service,store)}
        override fun close() {avatars.close();store.close()}
    }
    @Test fun onlyVisibleApplicantsReceiveReviewNamesAndAvatarsAndRevocationRetiresThem() {
        val f=Fixture();val session=SessionUi.SignedIn(f.actor)
        var app by mutableStateOf(AppState(session=session,snapshot=ClientSnapshot(presentationGeneration="directory")))
        var active by mutableStateOf(true)
        try {
            compose.setContent {MaterialTheme {InvitationsPage(f.room,app,session,active,f::open,f.avatars::open)}}
            compose.waitUntil(15000) {compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("成员 001").assertIsDisplayed()
            assertTrue(f.avatars.reads.size<40)
            assertFalse(f.avatars.reads.any {it.user==user(40)})
            assertTrue(f.avatars.reads.all {it.context==ProfileContext.GroupJoinReview(f.room)})
            val first=f.avatars.grants.first()
            compose.onNodeWithTag("invitation-page").performScrollToNode(hasTestTag("invite-applicant/${request(40)}"))
            compose.waitUntil(15000) {f.avatars.grants.any {it.home==ResourceHome.Account(user(40))}}
            compose.onNodeWithText("成员 040").assertIsDisplayed()
            runBlocking {assertTrue(runCatching {first.requireValid()}.exceptionOrNull() is AvatarAccessFailure)}
            compose.runOnIdle {app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(f.room)))}
            compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).assertCountEquals(0)
            compose.onNodeWithText("成员 040").assertDoesNotExist()
            runBlocking {f.avatars.grants.forEach {assertTrue(runCatching {it.requireValid()}.exceptionOrNull() is AvatarAccessFailure)}}
        } finally {compose.runOnIdle {active=false};compose.waitForIdle();f.close()}
    }
    @Test fun permissionFailureDropsApplicantsAndLateProfileReadCannotRestoreTheirPresentation() {
        val f=Fixture();val session=SessionUi.SignedIn(f.actor)
        val app=AppState(session=session,snapshot=ClientSnapshot(presentationGeneration="directory"))
        var active by mutableStateOf(true);val gate=CompletableDeferred<Unit>();val resumed=CompletableDeferred<Unit>()
        f.avatars.beforeRead={withContext(NonCancellable) {gate.await();resumed.complete(Unit)}}
        try {
            compose.setContent {MaterialTheme {InvitationsPage(f.room,app,session,active,f::open,f.avatars::open)}}
            compose.waitUntil(10000) {f.avatars.reads.isNotEmpty()}
            compose.onNodeWithText("成员 001").assertDoesNotExist()
            compose.onNodeWithText(user(1).value,substring=true).assertDoesNotExist()
            compose.runOnIdle {f.permitted=false}
            compose.onNodeWithText("刷新",substring=false).performScrollTo().performClick()
            compose.waitUntil(5000) {compose.onAllNodesWithText("无法读取邀请和申请，请刷新后重试").fetchSemanticsNodes().isNotEmpty()}
            gate.complete(Unit)
            compose.waitUntil(5000) {resumed.isCompleted}
            compose.waitForIdle()
            compose.waitUntil(5000) {f.avatars.pages.all {it.state.value.display.profiles.isEmpty()}}
            compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).assertCountEquals(0)
            compose.onNodeWithTag("invite-applicant/${request(1)}").assertDoesNotExist()
        } finally {gate.complete(Unit);compose.runOnIdle {active=false};compose.waitForIdle();f.close()}
    }
}
