package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class DirectoryAvatarUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val room=RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val session=SessionUi.SignedIn(actor)
    private fun user(index: Int)=UserId("00000000-0000-0000-0000-${index.toString().padStart(12,'0')}")
    private fun awaitImage(fixture: DirectoryAvatarFixture,count: Int=1) {
        try {compose.waitUntil(10000) {compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).fetchSemanticsNodes().size>=count}}
        catch(error: Throwable) {throw AssertionError(fixture.diagnostics(),error)}
    }
    @Test fun restoredMemberProfileUsesRoomAuthorityAndCannotReuseItAfterRevocationOrContextChange() {
        val fixture=DirectoryAvatarFixture(actor,device,room)
        var route by mutableStateOf(Json.decodeFromString<Route.Profile>(Json.encodeToString(Route.Profile(user(1).value,room.value))))
        var state by mutableStateOf(AppState(session=session,snapshot=ClientSnapshot(presentationGeneration="directory")))
        var active by mutableStateOf(true)
        try {
            compose.setContent {MaterialTheme {
                val display=rememberRouteProfile(route,state,session,active,fixture::open)
                Avatar("成员",image=display.avatars[requireNotNull(route.presentationKey(false))])
            }}
            awaitImage(fixture);assertEquals(setOf(ProfileContext.Room(room)),fixture.reads.map {it.context}.toSet())
            val roomGrant=fixture.grants.first()
            compose.runOnIdle {state=state.copy(snapshot=state.snapshot.copy(revokedRooms=persistentSetOf(room)))}
            compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).assertCountEquals(0)
            runBlocking {assertTrue(runCatching {roomGrant.requireValid()}.exceptionOrNull() is AvatarAccessFailure)}
            compose.runOnIdle {route=Route.Profile(user(1).value)}
            awaitImage(fixture);assertTrue(fixture.reads.any {it.context==ProfileContext.Relationship})
            compose.runOnIdle {route=Route.Profile(user(1).value,room.value)}
            compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).assertCountEquals(0)
        } finally {compose.runOnIdle {active=false};compose.waitForIdle();fixture.close()}
    }
    @Test fun readersDownloadOnlyVisibleRoomAvatarsAndScrollingOrRevocationRetiresOldGrants() {
        val fixture=DirectoryAvatarFixture(actor,device,room);val message=Message(MessageId(device.value),room,actor,"消息",1000,roomSequence=1)
        val users=(1..40).map(::user).toPersistentList()
        var state by mutableStateOf(AppState(session=session,snapshot=ClientSnapshot(presentationGeneration="directory",messages=persistentListOf(message))))
        var active by mutableStateOf(true)
        try {
            compose.setContent {MaterialTheme {ReadReadersScreen(room,message.id,state,session,active,fixture::open,
                openSources={MessageSourceSession(messageSourceFixture(actor,message),room,actor,fixture.scope)},
                fetch={_,_,_->ReadReadersPage(room,message.id,users,null)})}}
            awaitImage(fixture)
            compose.runOnIdle {
                assertTrue(fixture.reads.size<users.size);assertFalse(fixture.reads.any {it.user==users.last()})
                assertTrue(fixture.reads.all {it.context==ProfileContext.Room(room)})
            }
            val first=fixture.grants.first()
            compose.onNodeWithTag("readers-list").performScrollToIndex(39)
            compose.waitUntil(10000) {fixture.grants.any {it.home==ResourceHome.Account(users.last())}}
            compose.onNodeWithText("成员 040").assertIsDisplayed();awaitImage(fixture)
            runBlocking {assertTrue(runCatching {first.requireValid()}.exceptionOrNull() is AvatarAccessFailure)}
            compose.runOnIdle {state=state.copy(snapshot=state.snapshot.copy(revokedRooms=persistentSetOf(room)))}
            compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).assertCountEquals(0)
            runBlocking {fixture.grants.forEach {assertTrue(runCatching {it.requireValid()}.exceptionOrNull() is AvatarAccessFailure)}}
            assertTrue(fixture.requests.isNotEmpty())
        } finally {compose.runOnIdle {active=false};compose.waitForIdle();fixture.close()}
    }
    @Test fun membersIncludeOwnAuthorizedAvatarAndLeavingThePageRemovesAllImages() {
        val fixture=DirectoryAvatarFixture(actor,device,room);val models=ViewModelStore();lateinit var model:AppViewModel
        val isolated=UUID.randomUUID().toString()
        compose.runOnUiThread {
            model=AppViewModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application,
                AppDependencies(preferencesName="avatar-ui-$isolated",credentialsName="avatar-ui-$isolated"));models.put("test",model)
        }
        val state=AppState(session=session,snapshot=ClientSnapshot(presentationGeneration="directory"),
            members=MembersState(room,revision=1,actorRole=MemberRole.Member,items=persistentListOf(GroupMember(actor,MemberRole.Member),GroupMember(user(1),MemberRole.Owner)),stale=false))
        var active by mutableStateOf(true)
        try {
            compose.setContent {MaterialTheme {MembersPage(room,state,session,model,active,{},{},fixture::open)}}
            awaitImage(fixture,2)
            compose.onNodeWithText("我").assertIsDisplayed();compose.onNodeWithText("成员 001").assertIsDisplayed()
            assertEquals(setOf(actor,user(1)),fixture.reads.map {it.user}.toSet())
            assertTrue(fixture.reads.all {it.context==ProfileContext.Room(room)})
            compose.runOnIdle {active=false}
            compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).assertCountEquals(0)
            runBlocking {fixture.grants.forEach {assertTrue(runCatching {it.requireValid()}.exceptionOrNull() is AvatarAccessFailure)}}
        } finally {
            compose.runOnIdle {active=false};compose.waitForIdle();fixture.close()
            compose.runOnUiThread {models.clear()};runBlocking {withTimeout(5000) {model.awaitShutdown()}}
        }
    }
}
