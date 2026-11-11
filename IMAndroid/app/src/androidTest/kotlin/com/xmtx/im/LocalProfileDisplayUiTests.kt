package com.xmtx.im

import android.database.sqlite.SQLiteDatabase
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class LocalProfileDisplayUiTests {
    @get:Rule val compose = createComposeRule()
    @Test fun acceptedNameSurvivesPageRetirementAndContextDenialPersistsBeforeFallback() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(UUID.randomUUID().toString()); val peer = UserId(UUID.randomUUID().toString())
        val device = DeviceId(UUID.randomUUID().toString()); val room = RoomId(UUID.randomUUID().toString())
        val key = ProfileKey(peer, ProfileContext.DirectConversation)
        val hash = MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(context.noBackupFilesDir, "im-$hash.db")
        var store = SqliteClientStore(context, actor, device)
        var active by mutableStateOf(true)
        var page: ProfilePresentationPage? = null
        var result: ProfileReadResult = ProfileReadResult.Available(AuthorizedProfile(
            ProfileView(peer, PublicIdentity(peer, PublicHandle("friend"), "持久授权姓名", AccountKind.Regular), null, ProfileState.Active, 1, 1),
            ProfileLease(actor, device, key, 1, 1, 1, ProfileAuthority(1, room, 1, 0), 0, 60_000)), System.nanoTime() + 60_000_000_000)
        val generation = runBlocking { store.profileFences(persistentListOf(key)).generation }
        val state = AppState(session = SessionUi.SignedIn(actor), snapshot = ClientSnapshot(presentationGeneration = generation,
            conversations = persistentListOf(Conversation(room, "不应显示的发现名称", peer = peer))))
        try {
            compose.setContent {
                val owner = rememberCoroutineScope()
                MaterialTheme { Conversations(state, SessionUi.SignedIn(actor), active, {
                    ProfilePresentationPage(actor, device, { persistentListOf(result) }, store::profileFences, owner,
                        localDisplays = LocalProfileDisplaySaving(store::saveLocalProfileDisplays),
                        localDisplayReader = LocalProfileDisplayReading(store::readLocalProfileDisplays), localDisplayChanges = store.localDisplayChanges).also { page = it }
                }, {}) }
            }
            compose.waitUntil(10_000) { compose.onAllNodesWithText("持久授权姓名").fetchSemanticsNodes().isNotEmpty() }
            assertEquals("持久授权姓名", runBlocking { store.cachedLocalProfileDisplays(persistentListOf(key)).value(key)?.name })
            compose.runOnIdle { active = false }; compose.onNodeWithText("持久授权姓名").assertDoesNotExist()
            store.close(); store = SqliteClientStore(context, actor, device)
            assertEquals("持久授权姓名", runBlocking { store.cachedLocalProfileDisplays(persistentListOf(key)).value(key)?.name })
            compose.runOnIdle { result = ProfileReadResult.Unavailable(key, ProfileAuthority(2, room, 1, 0)); active = true }
            compose.waitUntil(10_000) { page?.state?.value?.display?.unavailable?.contains(key) == true }
            compose.onNodeWithText("会话").assertIsDisplayed(); compose.onNodeWithText("持久授权姓名").assertDoesNotExist()
            compose.runOnIdle { active = false }; compose.waitForIdle()
            store.close(); store = SqliteClientStore(context, actor, device)
            val contact = ProfileKey(peer, ProfileContext.Relationship)
            val cached = runBlocking { store.cachedLocalProfileDisplays(persistentListOf(key, contact)) }
            assertNull(cached.value(key)); assertEquals("持久授权姓名", cached.value(contact)?.name)
        } finally {
            compose.runOnIdle { active = false; page?.close() }
            store.close(); SQLiteDatabase.deleteDatabase(file)
        }
    }
    @Test fun coldCachedTextDisplaysWithoutHttpAndClearingCacheRemovesItFromActivePage() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(UUID.randomUUID().toString()); val peer = UserId(UUID.randomUUID().toString())
        val device = DeviceId(UUID.randomUUID().toString()); val room = RoomId(UUID.randomUUID().toString())
        val key = ProfileKey(peer, ProfileContext.DirectConversation)
        val hash = MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(context.noBackupFilesDir, "im-$hash.db")
        var store = SqliteClientStore(context, actor, device)
        var active by mutableStateOf(true); var page: ProfilePresentationPage? = null
        val available = ProfileReadResult.Available(AuthorizedProfile(
            ProfileView(peer, PublicIdentity(peer, PublicHandle("offline_friend"), "离线缓存姓名", AccountKind.Regular), null, ProfileState.Active, 1, 1),
            ProfileLease(actor, device, key, 1, 1, 1, ProfileAuthority(1, room, 1, 0), 0, 60_000)), System.nanoTime() + 60_000_000_000)
        try {
            runBlocking { assertTrue(store.saveLocalProfileDisplays(persistentListOf(available), store.profileFences(persistentListOf(key)))) }
            store.close(); store = SqliteClientStore(context, actor, device)
            val generation = runBlocking { store.profileFences(persistentListOf(key)).generation }
            val state = AppState(session = SessionUi.SignedIn(actor), snapshot = ClientSnapshot(presentationGeneration = generation,
                conversations = persistentListOf(Conversation(room, "不能作为后备的发现名称", peer = peer))))
            compose.setContent {
                val owner = rememberCoroutineScope()
                MaterialTheme { Conversations(state, SessionUi.SignedIn(actor), active, {
                    ProfilePresentationPage(actor, device, { awaitCancellation() }, store::profileFences, owner,
                        localDisplayReader = LocalProfileDisplayReading(store::readLocalProfileDisplays),
                        localDisplayChanges = store.localDisplayChanges).also { page = it }
                }, {}) }
            }
            compose.waitUntil(10_000) { compose.onAllNodesWithText("离线缓存姓名").fetchSemanticsNodes().isNotEmpty() }
            compose.runOnIdle {
                assertTrue(page!!.state.value.display.profiles.isEmpty()); assertTrue(page!!.state.value.display.avatars.isEmpty())
                assertEquals("offline_friend", page!!.state.value.display.identity(key)?.handle?.value)
                active = false
            }
            compose.onNodeWithText("离线缓存姓名").assertDoesNotExist()
            compose.runOnIdle { active = true }
            compose.waitUntil(10_000) { compose.onAllNodesWithText("离线缓存姓名").fetchSemanticsNodes().isNotEmpty() }
            runBlocking { store.clearLocalProfileDisplays() }
            compose.waitUntil(10_000) { page?.state?.value?.display?.localNames?.isEmpty() == true }
            compose.onNodeWithText("离线缓存姓名").assertDoesNotExist()
            compose.onNodeWithText("不能作为后备的发现名称").assertDoesNotExist()
            compose.onNodeWithText("会话").assertIsDisplayed()
        } finally {
            compose.runOnIdle { active = false; page?.close() }; store.close(); SQLiteDatabase.deleteDatabase(file)
        }
    }

}
