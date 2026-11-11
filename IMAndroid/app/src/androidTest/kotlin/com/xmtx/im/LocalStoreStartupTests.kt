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
import java.util.UUID

class LocalStoreStartupTests {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun fixture(legacy: Boolean, damageReason: LocalStoreFailure.Reason? = null, check: (AppViewModel, Credentials) -> Unit) {
        val user = UserId(UUID.randomUUID().toString())
        val device = DeviceId(UUID.randomUUID().toString())
        val credentials = Credentials(user, device, "fixture-access", System.currentTimeMillis() + 600_000,
            "fixture-refresh", "imv2-revoke-v1.${"A".repeat(43)}", System.currentTimeMillis() + 3_600_000)
        val name = "binding-startup-${UUID.randomUUID()}"
        val secrets = KeystoreSecretStore(context, name)
        val binding = object: InstallationBindingRepairing {
            var value: LocalInstallationBinding? = null
            var damaged = false
            override suspend fun load(): LocalInstallationBinding? {
                if (damaged) throw LocalStoreFailure(requireNotNull(damageReason))
                return value
            }
            override suspend fun save(binding: LocalInstallationBinding) { value = binding }
            override suspend fun delete() { value = null }
            override suspend fun inspectDamage() = if (damaged) InstallationBindingDamage(requireNotNull(damageReason), "a".repeat(64)) else null
            override suspend fun replaceDamagedBinding(expected: InstallationBindingDamage, replacement: LocalInstallationBinding) {
                check(inspectDamage() == expected); value = replacement; damaged = false
            }
        }
        runBlocking {
            if (damageReason != null) {
                LocalStoreBootstrapper(context, binding).open(user, device).close()
                binding.damaged = true
            }
            if (legacy) SqliteClientStore(context, user, device).close()
            secrets.write(buildJsonObject { put("credentials", Json.encodeToJsonElement(credentials)) }.toString())
        }
        lateinit var model: AppViewModel
        val owners = ViewModelStore()
        compose.runOnIdle {
            model = AppViewModel(context.applicationContext as Application,
                AppDependencies(credentialsName = name, preferencesName = "$name-prefs",
                    installationBindings = { if (damageReason == null) KeystoreInstallationBindingStore(it) else binding }))
            owners.put("binding-startup", model)
        }
        try {
            compose.setContent { val app by model.state.collectAsState(); MaterialTheme { IMApp(app, model) } }
            compose.waitUntil(15_000) { model.state.value.session != SessionUi.Loading }
            check(model, credentials)
        } finally {
            compose.runOnIdle { owners.clear() }
            runBlocking { model.awaitShutdown(); secrets.delete() }
            context.getSharedPreferences("$name-prefs", 0).edit().clear().commit()
            val digest = java.security.MessageDigest.getInstance("SHA-256")
                .digest("${user.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
            android.database.sqlite.SQLiteDatabase.deleteDatabase(java.io.File(context.noBackupFilesDir, "im-$digest.db"))
            java.io.File(context.noBackupFilesDir, "resources-$digest").deleteRecursively()
            java.io.File(context.noBackupFilesDir, "local-recovery/$digest").deleteRecursively()
        }
    }

    @Test fun freshAccountOpensThroughProductionBindingWithoutNetworkAuthentication() = fixture(false) { model, credentials ->
        val session = model.state.value.session as SessionUi.SignedIn
        assertEquals(credentials.userId, session.user); assertFalse(session.demo)
        runBlocking { LocalStoreBootstrapper(context).open(credentials.userId, credentials.deviceId).use { assertEquals(it.databaseIdentity, session.databaseIdentity) } }
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
        runBlocking { LocalStoreBootstrapper(context).verifyExistingBinding(credentials.userId, credentials.deviceId) }
    }

    @Test fun legacyAccountShowsRecoveryStateAndRetryDoesNotPresentUnverifiedData() = fixture(true) { model, credentials ->
        assertEquals(SessionUi.LocalUnavailable(LocalStoreFailure.Reason.BindingMismatch), model.state.value.session)
        compose.onNodeWithTag("local-store-unavailable").assertIsDisplayed()
        compose.onNodeWithText("无法确认本机数据的安装与账号归属。原有数据已保留。").assertIsDisplayed()
        compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
        compose.onNodeWithText("重试打开").performClick()
        compose.waitUntil(10_000) { model.state.value.session is SessionUi.LocalUnavailable }
        compose.onNodeWithTag("local-store-unavailable").assertIsDisplayed()
        // No marker was silently attached to the legacy file; the low-level fixture still opens it.
        SqliteClientStore(context, credentials.userId, credentials.deviceId).close()
    }

    @Test fun confirmedRecoveryPreservesTheLegacyCopyAndReopensTheSameAccount() = fixture(true) { model, credentials ->
        compose.runOnIdle { model.foreground(true) }
        compose.onNodeWithText("保留副本并重新同步").performClick()
        compose.waitUntil(10_000) { model.state.value.localRecovery.preview != null }
        compose.onNodeWithText("保留副本并重新同步？").assertIsDisplayed()
        compose.runOnIdle { model.foreground(false) }
        compose.onNodeWithText("确认恢复").assertDoesNotExist()
        assertTrue(model.state.value.session is SessionUi.LocalUnavailable)
        compose.runOnIdle { model.foreground(true) }
        compose.onNodeWithText("保留副本并重新同步").performClick()
        compose.waitUntil(10_000) { model.state.value.localRecovery.preview != null }
        compose.onNodeWithText("取消").performClick()
        assertTrue(model.state.value.session is SessionUi.LocalUnavailable)
        compose.onNodeWithText("保留副本并重新同步").performClick()
        compose.waitUntil(10_000) { model.state.value.localRecovery.preview != null }
        compose.onNodeWithText("确认恢复").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick) { action ->
            action(); model.foreground(false) // Keep this storage fixture offline after the confirmed operation.
        }
        compose.waitUntil(15_000) { model.state.value.session is SessionUi.SignedIn }
        val session = model.state.value.session as SessionUi.SignedIn
        assertEquals(credentials.userId, session.user); assertFalse(session.demo)
        runBlocking { LocalStoreBootstrapper(context).open(credentials.userId, credentials.deviceId).use { assertEquals(it.databaseIdentity, session.databaseIdentity) } }
        runBlocking { LocalStoreBootstrapper(context).verifyExistingBinding(credentials.userId, credentials.deviceId) }
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest("${credentials.userId.value}/${credentials.deviceId.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        val copy = java.io.File(context.noBackupFilesDir, "local-recovery/$digest").listFiles()!!.single()
        assertTrue(java.io.File(copy, "Database").isFile); assertTrue(java.io.File(copy, "manifest.json").isFile)
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }
    @Test fun terminalBindingFailureOffersExplicitRepairAndReopensAfterLifecycleCancellation() =
        fixture(false, LocalStoreFailure.Reason.BindingInvalidated) { model, credentials ->
            assertEquals(SessionUi.LocalUnavailable(LocalStoreFailure.Reason.BindingInvalidated), model.state.value.session)
            compose.runOnIdle { model.foreground(true) }
            compose.onNodeWithText("保留副本并重新同步").performClick()
            compose.waitUntil(10_000) { model.state.value.localRecovery.preview != null }
            assertTrue(model.state.value.localRecovery.preview!!.rebuildsInstallationBinding)
            compose.onNodeWithText("将重建设备保护信息。", substring = true).assertIsDisplayed()
            compose.runOnIdle { model.foreground(false) }
            compose.onNodeWithText("确认恢复").assertDoesNotExist()
            compose.runOnIdle { model.foreground(true) }
            compose.onNodeWithText("保留副本并重新同步").performClick()
            compose.waitUntil(10_000) { model.state.value.localRecovery.preview != null }
            compose.onNodeWithText("确认恢复").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick) { action ->
                action(); model.foreground(false)
            }
            compose.waitUntil(15_000) { model.state.value.session is SessionUi.SignedIn }
            assertEquals(credentials.userId, (model.state.value.session as SessionUi.SignedIn).user)
            compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
        }

}
