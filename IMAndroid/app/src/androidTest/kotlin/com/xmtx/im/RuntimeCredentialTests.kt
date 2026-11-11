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
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID

class RuntimeCredentialTests {
    @get:Rule val compose=createComposeRule()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun hash(s:String)=MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") {"%02x".format(it)}
    private inner class Fixture {
        val name="credential-runtime-${UUID.randomUUID()}"
        val user=UserId(UUID.randomUUID().toString());val device=DeviceId(UUID.randomUUID().toString())
        val file=File(context.noBackupFilesDir,"$name.enc")
        val scope=hash("${user.value}/${device.value}");val database=File(context.noBackupFilesDir,"im-$scope.db")
        val store=KeystoreCredentialStore(context,name);val marker=FileLocalExitMarker(context,name)
        val owners=ViewModelStore();var displayed by mutableStateOf<AppViewModel?>(null)
        val model get()=requireNotNull(displayed)
        var locked=false
        val networks=mutableListOf<AccountNetworkActivity>()
        val work=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        init {runBlocking {
            val c=Credentials(user,device,"fixture-access",1,"fixture-refresh","imv2-revoke-v1.${"A".repeat(43)}",1)
            store.write(buildJsonObject {put("credentials",Json.encodeToJsonElement(c))}.toString())
            LocalStoreBootstrapper(context).open(user,device).close()
        }}
        fun start() {
            compose.runOnIdle {
                displayed=AppViewModel(context.applicationContext as Application,AppDependencies(credentialsName=name,preferencesName="$name-prefs",
                    networkActivity={AccountNetworkActivity().also {networks.add(it)}},
                    credentialStore={_,_->object:SecretStore by store {override suspend fun read():String? {if(locked) throw IOException("private credential detail");return store.read()}}}))
                owners.put("credentials",model)
            }
            compose.waitUntil(15_000) {model.state.value.session!=SessionUi.Loading}
        }
        fun stop() {val old=displayed ?: return;compose.runOnIdle {displayed=null;owners.clear()};runBlocking {old.awaitShutdown()}}
        fun close() {
            work.cancel();stop();runBlocking {store.delete()};context.getSharedPreferences("$name-prefs",0).edit().clear().commit()
            for(suffix in listOf("",".bak",".new")) File(context.noBackupFilesDir,"local-exit-${hash(name)}.json$suffix").delete()
            android.database.sqlite.SQLiteDatabase.deleteDatabase(database);File(context.noBackupFilesDir,"resources-$scope").deleteRecursively()
            KeyStore.getInstance("AndroidKeyStore").apply {load(null);deleteEntry("com.xmtx.im.$name.v1")}
        }
    }
    private fun fixture(body:Fixture.()->Unit) {
        val f=Fixture();try {
            compose.setContent {f.displayed?.let {m->val state by m.state.collectAsState();MaterialTheme {IMApp(state,m)}}}
            f.body()
        } finally {f.close()}
    }
    private fun Fixture.assertDrained(index:Int=0) {
        val value=runBlocking {networks[index].scheduler.snapshot()}
        assertTrue(value.closed);assertEquals(0,value.active);assertEquals(0,value.waiting)
    }
    @Test fun ordinaryHttpCredentialFailureWithdrawsTheAccountAndRetryCreatesANewOwner()=fixture {
        start();assertTrue(model.state.value.session is SessionUi.SignedIn)
        val bytes=file.readBytes();locked=true
        compose.runOnIdle {work.launch {model.lookup("runtime_peer")}}
        compose.waitUntil(15_000) {model.state.value.session is SessionUi.CredentialsUnavailable}
        assertDrained();assertTrue(model.state.value.snapshot.conversations.isEmpty())
        compose.onNodeWithTag("credentials-unavailable").assertIsDisplayed()
        compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
        assertArrayEquals(bytes,file.readBytes());assertFalse(runBlocking {marker.isPending()})
        locked=false;compose.onNodeWithTag("credentials-retry").performClick()
        compose.waitUntil(15_000) {model.state.value.session is SessionUi.SignedIn}
        assertEquals(user,(model.state.value.session as SessionUi.SignedIn).user)
        assertEquals(2,networks.size);assertDrained();assertFalse(runBlocking {networks.last().scheduler.snapshot().closed})
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }
    @Test fun realtimeCredentialFailureAndPendingExitDrainInsteadOfReconnecting()=fixture {
        start();locked=true;compose.runOnIdle {model.foreground(true)}
        compose.waitUntil(15_000) {model.state.value.session is SessionUi.CredentialsUnavailable}
        assertDrained();assertFalse(runBlocking {marker.isPending()})
        compose.runOnIdle {model.foreground(false)};locked=false
        compose.onNodeWithTag("credentials-retry").performClick()
        compose.waitUntil(15_000) {model.state.value.session is SessionUi.SignedIn}
        runBlocking {marker.markPending()};compose.runOnIdle {model.foreground(true)}
        compose.waitUntil(15_000) {model.state.value.session==SessionUi.SignedOut && model.state.value.cleanupPending}
        assertDrained(1);assertTrue(runBlocking {marker.isPending()})
        compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
    }
    @Test fun replacedCredentialsArePreservedWhenTheOriginalRuntimeIsRetired()=fixture {
        start()
        val c=Credentials(UserId(UUID.randomUUID().toString()),DeviceId(UUID.randomUUID().toString()),"replacement-access",1,"replacement-refresh","imv2-revoke-v1.${"A".repeat(43)}",1)
        runBlocking {store.write(buildJsonObject {put("credentials",Json.encodeToJsonElement(c))}.toString())}
        val replacement=file.readBytes();compose.runOnIdle {model.foreground(true)}
        compose.waitUntil(15_000) {model.state.value.session==SessionUi.SignedOut}
        assertDrained();assertFalse(model.state.value.cleanupPending);assertFalse(runBlocking {marker.isPending()})
        assertArrayEquals(replacement,file.readBytes())
        stop();start()
        try {assertEquals(c.userId,(model.state.value.session as SessionUi.SignedIn).user)}
        finally {
            stop();val replacementScope=hash("${c.userId.value}/${c.deviceId.value}")
            android.database.sqlite.SQLiteDatabase.deleteDatabase(File(context.noBackupFilesDir,"im-$replacementScope.db"))
            File(context.noBackupFilesDir,"resources-$replacementScope").deleteRecursively()
        }
    }
    @Test fun unreadableExitMarkerDuringRuntimeWithdrawsToCleanupWithoutRepairingTheRecord()=fixture {
        start();val markerFile=File(context.noBackupFilesDir,"local-exit-${hash(name)}.json")
        markerFile.writeText("malformed exit record")
        compose.runOnIdle {model.foreground(true)}
        compose.waitUntil(15_000) {model.state.value.session==SessionUi.SignedOut && model.state.value.cleanupPending}
        assertDrained();assertEquals("malformed exit record",markerFile.readText())
        compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
    }

}
