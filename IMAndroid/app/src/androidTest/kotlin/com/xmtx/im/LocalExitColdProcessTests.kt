package com.xmtx.im

import android.app.Application
import android.os.Process
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
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Two explicit instrumentation invocations separated by force-stop; never uses production secrets. */
class LocalExitColdProcessTests {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun scope(): String {
        val value = InstrumentationRegistry.getArguments().getString("localExitScope")
        assumeTrue("explicit isolated cold-process scope required", value != null)
        require(UUID.fromString(value).toString() == value)
        return "exit-cold-$value"
    }
    private fun withModel(name: String, test: (AppViewModel) -> Unit) {
        val owners = ViewModelStore(); lateinit var model: AppViewModel
        compose.runOnIdle {
            model = AppViewModel(context.applicationContext as Application,
                AppDependencies(credentialsName = name, preferencesName = "$name-prefs"))
            owners.put("cold-exit", model)
        }
        try {
            compose.setContent { val state by model.state.collectAsState(); MaterialTheme { IMApp(state, model) } }
            compose.waitUntil(15_000) { model.state.value.session != SessionUi.Loading }
            assertEquals(SessionUi.SignedOut, model.state.value.session)
            assertTrue(model.state.value.cleanupPending)
            compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
            test(model)
        } finally { compose.runOnIdle { owners.clear() }; runBlocking { model.awaitShutdown() } }
    }
    @Test fun preparePendingExit() {
        val name = scope(); val secrets = KeystoreSecretStore(context, name)
        runBlocking {
            check(secrets.read() == null)
            val credentials = Credentials(UserId(UUID.randomUUID().toString()), DeviceId(UUID.randomUUID().toString()),
                "fixture-access", System.currentTimeMillis() + 600_000, "fixture-refresh",
                "imv2-revoke-v1.${"A".repeat(43)}", System.currentTimeMillis() + 600_000)
            secrets.write(buildJsonObject { put("credentials", Json.encodeToJsonElement(credentials)) }.toString())
            FileLocalExitMarker(context, name).markPending()
        }
        assertTrue(context.getSharedPreferences("$name-prefs", 0).edit().putInt("preparing-process", Process.myPid()).commit())
        withModel(name) { assertNotNull(runBlocking { secrets.read() }) }
        // Files intentionally survive this phase; only the matching resume phase removes them.
    }
    @Test fun resumePendingExitInAnotherProcess() {
        val name = scope(); val secrets = KeystoreSecretStore(context, name); val marker = FileLocalExitMarker(context, name)
        val preferences = context.getSharedPreferences("$name-prefs", 0)
        val prior = preferences.getInt("preparing-process", -1)
        assertTrue(prior > 0); assertNotEquals(prior, Process.myPid())
        assertTrue(runBlocking { marker.isPending() }); assertNotNull(runBlocking { secrets.read() })
        try {
            withModel(name) { model ->
                // Simulate credential deletion having completed before marker cleanup. The explicit
                // fixture owns this record; no remote revocation or real account request is issued.
                runBlocking { secrets.delete() }
                compose.onNodeWithText("重试完成退出登录").performScrollTo().performClick()
                compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending }
                assertFalse(runBlocking { marker.isPending() }); assertNull(runBlocking { secrets.read() })
            }
        } finally {
            runBlocking { secrets.delete() }
            preferences.edit().clear().commit()
            val hash = MessageDigest.getInstance("SHA-256").digest(name.toByteArray()).joinToString("") { "%02x".format(it) }
            for (suffix in listOf("", ".bak", ".new")) File(context.noBackupFilesDir, "local-exit-$hash.json$suffix").delete()
        }
    }
}
