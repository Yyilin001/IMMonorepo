package com.xmtx.im

import android.app.Application
import android.database.sqlite.SQLiteDatabase
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class DatabaseNavigationRestorationTests {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private inner class Fixture {
        val user = UserId(UUID.randomUUID().toString())
        val device = DeviceId(UUID.randomUUID().toString())
        val original = SqliteClientStore(context, user, device).use { it.databaseIdentity }
        val name = "navigation-identity-${UUID.randomUUID()}"
        val model = AppViewModel(context.applicationContext as Application,
            AppDependencies(credentialsName = name, preferencesName = "$name-prefs"))
        val owners = ViewModelStore().apply { put("navigation", model) }
        val restoration = StateRestorationTester(compose)
        // Deliberately not snapshot state: a new identity is read only when the saved composition is
        // recreated, so the test restores the OLD bundle under the NEW database lifetime.
        var restoredIdentity = original
        var restoredUser = UserId("demo-me")
        var loading = false
        val rerender = mutableStateOf(0)
        fun mount() {
            compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut }
            compose.runOnIdle { model.demo() }
            val app = model.state.value
            restoration.setContent {
                rerender.value
                MaterialTheme { IMApp(if (loading) AppState() else app.copy(session = SessionUi.SignedIn(restoredUser, demo = true,
                    databaseIdentity = restoredIdentity)), model) }
            }
        }
        fun recover() = runBlocking {
            val bootstrap = LocalStoreBootstrapper(context)
            bootstrap.recoverLocalStore(bootstrap.previewRecovery(user, device))
            restoredIdentity = bootstrap.open(user, device).use { it.databaseIdentity }
            assertNotEquals(original, restoredIdentity)
        }
        fun close() {
            compose.runOnIdle { owners.clear() }
            runBlocking { model.awaitShutdown(); KeystoreSecretStore(context, name).delete() }
            context.getSharedPreferences("$name-prefs", 0).edit().clear().commit()
            val scope = MessageDigest.getInstance("SHA-256").digest("${user.value}/${device.value}".toByteArray())
                .joinToString("") { "%02x".format(it) }
            SQLiteDatabase.deleteDatabase(File(context.noBackupFilesDir, "im-$scope.db"))
            File(context.noBackupFilesDir, "local-recovery/$scope").deleteRecursively()
        }
    }
    private fun fixture(test: Fixture.() -> Unit) {
        val f = Fixture()
        try { f.mount(); f.test() } finally { f.close() }
    }
    private fun openContactChat() {
        compose.onNodeWithTag("root-tab-Contacts").performClick()
        compose.onNodeWithText("@lin").performClick()
        compose.onNodeWithText("发消息").performClick()
    }
    @Test fun sameDatabaseRestoresSharedDetailsDraftAndSelectedTab() = fixture {
        openContactChat()
        compose.onNodeWithText("发送消息…").performTextInput("仍属原库的草稿")
        restoredIdentity = SqliteClientStore(context, user, device).use { it.databaseIdentity }
        assertEquals(original, restoredIdentity)
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("仍属原库的草稿").assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithTag("root-tab-Contacts").assertIsSelected()
    }

    @Test fun archivedDatabaseCannotRestoreItsDetailsTabOrDraftIntoTheReplacement() = fixture {
        openContactChat()
        compose.onNodeWithText("发送消息…").performTextInput("旧库专属草稿")
        recover()
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
        compose.onNodeWithText("旧库专属草稿").assertDoesNotExist()
        openContactChat()
        compose.onNodeWithText("旧库专属草稿").assertDoesNotExist()
        compose.onNodeWithText("发送消息…").assertExists()
        // Returning to an earlier scope must not resurrect state cached in the holder either.
        compose.runOnIdle { restoredIdentity = original; rerender.value++ }
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
        openContactChat()
        compose.onNodeWithText("旧库专属草稿").assertDoesNotExist()
    }

    @Test fun changedAccountCannotAdoptRestoredStateEvenWithTheSameDatabaseIdentifier() = fixture {
        compose.onNodeWithTag("root-tab-Account").performClick()
        compose.onNodeWithText("传输任务").performScrollTo().performClick()
        compose.onNodeWithTag("resource-transfers").assertIsDisplayed()
        compose.runOnIdle { restoredUser = UserId("another-demo-user") }
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithTag("resource-transfers").assertDoesNotExist()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }

    @Test fun asynchronousLocalOpeningDoesNotConsumeOrReviveAnotherDatabasesSavedState() = fixture {
        compose.onNodeWithTag("root-tab-Account").performClick()
        compose.onNodeWithText("传输任务").performScrollTo().performClick()
        compose.onNodeWithTag("resource-transfers").assertIsDisplayed()
        // Match cold startup: first restore the Activity while the account is still loading.
        loading = true
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithTag("resource-transfers").assertDoesNotExist()
        compose.runOnIdle { loading = false; rerender.value++ }
        compose.onNodeWithTag("resource-transfers").assertIsDisplayed()
        // Restore another saved bundle through the same loading gap, now after rebuilding SQLite.
        recover(); loading = true
        restoration.emulateSavedInstanceStateRestore()
        compose.runOnIdle { loading = false; rerender.value++ }
        compose.onNodeWithTag("resource-transfers").assertDoesNotExist()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }
}
