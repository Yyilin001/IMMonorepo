package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class GroupAvatarListUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val session=SessionUi.SignedIn(actor)
    private inner class Displays {
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        val pages=mutableListOf<Pair<RoomId,GroupAvatarPage>>()
        val reads=mutableListOf<RoomId>()
        val repository=GroupAvatarRepository(actor,device,{ room ->
            reads.add(room);GroupAvatarPresentation(actor,device,GroupAvatarState(room,null,0),1,null,false,null,1000,61000,1000,System.nanoTime()+60000000000,null)
        },{GroupAvatarFence("epoch",0,1,true)},scope)
        fun open(room: RoomId)=GroupAvatarPage(room,repository,{error("empty avatar cannot download")},scope).also { pages.add(room to it) }
        fun close()=runBlocking { pages.toList().forEach { it.second.awaitClosed() };repository.close();scope.cancel() }
    }
    private fun rooms(count: Int)=List(count) { index -> Conversation(RoomId(UUID.randomUUID().toString().uppercase()),"群聊 $index","消息",kind=RoomKind.Group) }.toPersistentList()
    @Test fun scrollingAdmitsOnlyVisibleGroupsAndDeactivatesRowsAndHiddenPage() {
        val displays=Displays();val rooms=rooms(40);var state by mutableStateOf(AppState(session=session,snapshot=ClientSnapshot(conversations=rooms)));var active by mutableStateOf(true)
        try {
            compose.setContent { MaterialTheme { Conversations(state,session,active,{null},{},openGroupAvatar=displays::open) } }
            compose.waitUntil(5000) { displays.reads.isNotEmpty() }
            compose.runOnIdle { assertTrue(displays.reads.size<15);assertFalse(rooms[39].id in displays.reads) }
            compose.onNode(hasScrollAction()).performScrollToNode(hasText("群聊 39"))
            compose.waitUntil(5000) { rooms[39].id in displays.reads }
            compose.runOnIdle {
                assertTrue(displays.pages.filter { it.first==rooms[0].id }.all { it.second.isClosed })
                assertTrue(displays.pages.count { !it.second.isClosed }<15)
                state=state.copy(snapshot=state.snapshot.copy(revokedRooms=persistentSetOf(rooms[39].id)))
            }
            compose.waitUntil(5000) { displays.pages.filter { it.first==rooms[39].id }.all { it.second.isClosed } }
            compose.runOnIdle { active=false }
            compose.waitUntil(5000) { displays.pages.all { it.second.isClosed } }
        } finally { displays.close() }
    }
    @Test fun archivedListNeverReadsDirectRevokedOrUnarchivedRoomsAndDemoDoesNotOpenGroups() {
        val displays=Displays();val values=rooms(4);val archived=values[0].copy(archived=true)
        val direct=values[1].copy(archived=true,kind=RoomKind.Direct);val revoked=values[2].copy(archived=true)
        var session by mutableStateOf(this.session)
        val snapshot=ClientSnapshot(conversations=persistentListOf(archived,direct,revoked,values[3]),revokedRooms=persistentSetOf(revoked.id))
        try {
            compose.setContent { MaterialTheme { Conversations(AppState(session=session,snapshot=snapshot),session,true,{null},{},archived=true,openGroupAvatar=displays::open) } }
            compose.waitUntil(5000) { displays.reads.isNotEmpty() }
            compose.runOnIdle { assertEquals(listOf(archived.id),displays.reads);session=session.copy(demo=true) }
            compose.waitUntil(5000) { displays.pages.all { it.second.isClosed } }
            compose.runOnIdle { assertEquals(1,displays.reads.size) }
        } finally { displays.close() }
    }
    @Test fun groupDirectoryRowKeysFollowViewportAndLeavingDirectoryClosesSubscriptions() {
        val displays=Displays();val values=rooms(30);val state=AppState(session=session,snapshot=ClientSnapshot(conversations=values));var active by mutableStateOf(true)
        try {
            compose.setContent { MaterialTheme { GroupsPage(state,{},{},{},active,displays::open) } }
            compose.waitUntil(5000) { displays.reads.isNotEmpty() }
            compose.runOnIdle { assertTrue(displays.reads.size<15);assertFalse(values.last().id in displays.reads) }
            compose.onNode(hasScrollAction()).performScrollToNode(hasText("群聊 29"))
            compose.waitUntil(5000) { values.last().id in displays.reads }
            compose.runOnIdle { assertTrue(displays.pages.filter { it.first==values[0].id }.all { it.second.isClosed });active=false }
            compose.waitUntil(5000) { displays.pages.all { it.second.isClosed } }
        } finally { displays.close() }
    }
}
