package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class LocalExitStartupTests {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
        .joinToString("") { "%02x".format(it) }
    private inner class Fixture(withCredentials: Boolean, malformed: Boolean) {
        val name = "exit-startup-${UUID.randomUUID()}"
        val user = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val marker = FileLocalExitMarker(context, name)
        val markerFile = File(context.noBackupFilesDir, "local-exit-${hash(name)}.json")
        val database = File(context.noBackupFilesDir, "im-${hash("${user.value}/${device.value}")}.db")
        val secrets = KeystoreSecretStore(context, name)
        val owners = ViewModelStore()
        var displayed by mutableStateOf<AppViewModel?>(null)
        val model get() = requireNotNull(displayed)
        init {
            runBlocking {
                if (withCredentials) {
                    val credentials = Credentials(user, device, "fixture-access", System.currentTimeMillis() + 600_000,
                        "fixture-refresh", "imv2-revoke-v1.${"A".repeat(43)}", System.currentTimeMillis() + 600_000)
                    secrets.write(buildJsonObject { put("credentials", Json.encodeToJsonElement(credentials)) }.toString())
                }
                marker.markPending()
                if (malformed) markerFile.writeText("interrupted fixture record")
            }
        }
        fun start() {
            compose.runOnIdle {
                displayed = AppViewModel(context.applicationContext as Application,
                    AppDependencies(credentialsName = name, preferencesName = "$name-prefs"))
                owners.put("exit-startup", model)
            }
            compose.waitUntil(15_000) { model.state.value.session != SessionUi.Loading }
        }
        fun stop() {
            val old = displayed ?: return
            compose.runOnIdle { displayed = null; owners.clear() }
            runBlocking { old.awaitShutdown() }
        }
        fun close() {
            stop(); runBlocking { secrets.delete() }
            context.getSharedPreferences("$name-prefs", 0).edit().clear().commit()
            for (suffix in listOf("", ".bak", ".new")) File(markerFile.path + suffix).delete()
            android.database.sqlite.SQLiteDatabase.deleteDatabase(database)
        }
    }
    private fun fixture(credentials: Boolean = false, malformed: Boolean = false, test: Fixture.() -> Unit) {
        val f = Fixture(credentials, malformed)
        try {
            compose.setContent { f.displayed?.let { model -> val state by model.state.collectAsState(); MaterialTheme { IMApp(state, model) } } }
            f.start(); f.test()
        } finally { f.close() }
    }

    @Test fun pendingExitWithOldCredentialsNeverOpensTheAccountOrChangesServerOnRestart() = fixture(credentials = true) {
        val before = runBlocking { secrets.read() }
        assertEquals(SessionUi.SignedOut, model.state.value.session); assertTrue(model.state.value.cleanupPending)
        compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
        compose.onNodeWithText("重试完成退出登录").performScrollTo().assertIsDisplayed()
        compose.runOnIdle {
            model.login("account", "password123456", false, "", "", "https://another.invalid")
            model.demo()
        }
        assertEquals(SessionUi.SignedOut, model.state.value.session)
        assertNull(context.getSharedPreferences("$name-prefs", 0).getString("url", null))
        assertEquals(before, runBlocking { secrets.read() }); assertFalse(database.exists())
        stop(); start()
        assertTrue(model.state.value.cleanupPending); assertFalse(database.exists())
        assertEquals(before, runBlocking { secrets.read() })
    }

    @Test fun retryFinishesPendingExitAfterCredentialsWereAlreadyDeleted() = fixture {
        assertTrue(model.state.value.cleanupPending)
        compose.onNodeWithText("重试完成退出登录").performScrollTo().performClick()
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending }
        assertFalse(runBlocking { marker.isPending() }); assertNull(runBlocking { secrets.read() })
        stop(); start()
        assertEquals(SessionUi.SignedOut, model.state.value.session); assertFalse(model.state.value.cleanupPending)
    }

    @Test fun malformedMarkerBlocksStartupAndExplicitExitRetryRepairsItWithoutOpeningAnAccount() = fixture(malformed = true) {
        assertEquals(SessionUi.SignedOut, model.state.value.session); assertTrue(model.state.value.cleanupPending)
        assertEquals("interrupted fixture record", markerFile.readText())
        compose.onNodeWithText("本机退出状态暂时无法读取，请重试完成退出。").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("重试完成退出登录").performScrollTo().performClick()
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending }
        assertFalse(runBlocking { marker.isPending() }); assertFalse(database.exists())
    }
}
