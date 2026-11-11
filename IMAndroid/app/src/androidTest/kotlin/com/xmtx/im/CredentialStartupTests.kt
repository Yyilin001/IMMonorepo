package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.client.Credentials
import com.xmtx.im.platform.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID

class CredentialStartupTests {
    @get:Rule val compose=createComposeRule()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun hash(s:String)=MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") {"%02x".format(it)}
    private inner class Fixture {
        val name="credential-startup-${UUID.randomUUID()}"
        val user=UserId(UUID.randomUUID().toString());val device=DeviceId(UUID.randomUUID().toString())
        val file=File(context.noBackupFilesDir,"$name.enc")
        val scope=hash("${user.value}/${device.value}");val database=File(context.noBackupFilesDir,"im-$scope.db")
        val store=KeystoreCredentialStore(context,name);val marker=FileLocalExitMarker(context,name)
        val owners=ViewModelStore();var displayed by mutableStateOf<AppViewModel?>(null)
        val model get()=requireNotNull(displayed)
        var locked=false
        var failDelete=false
        val issuedDevices=java.util.concurrent.CopyOnWriteArrayList<DeviceId>()
        val http=OkHttpClient.Builder().addInterceptor {chain->
            val request=chain.request()
            val body=when(request.url.encodedPath) {
                "/v2/account-auth/password/assertion"->buildJsonObject {put("accountAssertion","fixture-assertion")}
                "/v2/device-credentials"->{
                    val payload=Json.parseToJsonElement(Buffer().also {request.body!!.writeTo(it)}.readUtf8()).jsonObject
                    val registered=DeviceId(payload.getValue("deviceID").jsonPrimitive.content);issuedDevices.add(registered)
                    buildJsonObject {
                        put("userID",user.value);put("deviceID",registered.value);put("accessToken","fixture-access")
                        put("accessTokenExpiresAtMilliseconds",System.currentTimeMillis()+600000);put("refreshCredential","fixture-refresh")
                        put("revocationCredential","imv2-revoke-v1.${"A".repeat(43)}");put("revocationCredentialExpiresAtMilliseconds",System.currentTimeMillis()+3600000)
                        put("registrationCancellation",payload.getValue("cancellation"))
                    }
                }
                else->error("Unexpected request during credential recovery")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("fixture")
                .body(body.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        init {runBlocking {
            val c=Credentials(user,device,"fixture-access",1,"fixture-refresh","imv2-revoke-v1.${"A".repeat(43)}",1)
            store.write(buildJsonObject {put("credentials",Json.encodeToJsonElement(c))}.toString())
            LocalStoreBootstrapper(context).open(user,device).close()
        }}
        fun start() {
            compose.runOnIdle {
                displayed=AppViewModel(context.applicationContext as Application,AppDependencies(credentialsName=name,preferencesName="$name-prefs",
                    account={AccountClient(it,http)},credentialStore={_,_->object:SecretStore by store {
                        override suspend fun read():String? {if(locked) throw IOException("private credential detail");return store.read()}
                        override suspend fun delete() {if(failDelete) throw IOException();store.delete()}
                    }}))
                owners.put("credentials",model)
            }
            compose.waitUntil(15_000) {model.state.value.session!=SessionUi.Loading}
        }
        fun stop() {val old=displayed ?: return;compose.runOnIdle {displayed=null;owners.clear()};runBlocking {old.awaitShutdown()}}
        fun close() {
            stop();runBlocking {store.delete()};context.getSharedPreferences("$name-prefs",0).edit().clear().commit()
            for(suffix in listOf("",".bak",".new")) File(context.noBackupFilesDir,"local-exit-${hash(name)}.json$suffix").delete()
            android.database.sqlite.SQLiteDatabase.deleteDatabase(database);File(context.noBackupFilesDir,"resources-$scope").deleteRecursively()
            val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null);deleteEntry("com.xmtx.im.$name.v1")}
            for(kind in listOf("receipts","revocations","registrations")) {
                val journal="credential-$kind-${hash(credentialRecoveryNamespace(name,"https://localhost:8443"))}"
                for(suffix in listOf("",".bak",".new")) File(context.noBackupFilesDir,"$journal.enc$suffix").delete()
                keys.deleteEntry("com.xmtx.im.$journal.v1")
            }
            issuedDevices.forEach {newDevice->
                val newScope=hash("${user.value}/${newDevice.value}")
                android.database.sqlite.SQLiteDatabase.deleteDatabase(File(context.noBackupFilesDir,"im-$newScope.db"))
                File(context.noBackupFilesDir,"resources-$newScope").deleteRecursively()
            }
            http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()
        }
    }
    private fun fixture(body:Fixture.()->Unit) {
        val f=Fixture();try {
            compose.setContent {f.displayed?.let {m->val state by m.state.collectAsState();MaterialTheme {IMApp(state,m)}}}
            f.body()
        } finally {f.close()}
    }
    @Test fun temporarilyUnavailableCredentialsKeepDataAndRetryRestoresTheSameAccount()=fixture {
        locked=true;val credentials=file.readBytes();val bytes=database.readBytes();start()
        assertEquals(SessionUi.CredentialsUnavailable(CredentialStoreFailure.Reason.Unavailable),model.state.value.session)
        compose.onNodeWithTag("credentials-unavailable").assertIsDisplayed();compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
        compose.runOnIdle {model.login("account","password123456",false,"","","https://another.invalid");model.demo()}
        assertTrue(model.state.value.session is SessionUi.CredentialsUnavailable)
        assertNull(context.getSharedPreferences("$name-prefs",0).getString("url",null))
        assertArrayEquals(credentials,file.readBytes());assertArrayEquals(bytes,database.readBytes());assertFalse(runBlocking {marker.isPending()})
        locked=false;compose.onNodeWithTag("credentials-retry").performClick()
        compose.waitUntil(15_000) {model.state.value.session is SessionUi.SignedIn}
        assertEquals(user,(model.state.value.session as SessionUi.SignedIn).user)
        assertArrayEquals(credentials,file.readBytes());compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }
    @Test fun malformedRecordAndMissingKeyRemainBlockedAcrossOwners()=fixture {
        val original=file.readBytes();runBlocking {store.write("invalid credential JSON")};val damaged=file.readBytes();start()
        assertEquals(SessionUi.CredentialsUnavailable(CredentialStoreFailure.Reason.Malformed),model.state.value.session)
        compose.onNodeWithTag("credentials-retry").performClick();compose.waitUntil(15_000) {model.state.value.session is SessionUi.CredentialsUnavailable}
        assertArrayEquals(damaged,file.readBytes());stop()
        file.writeBytes(original);KeyStore.getInstance("AndroidKeyStore").apply {load(null);deleteEntry("com.xmtx.im.$name.v1")};start()
        assertEquals(SessionUi.CredentialsUnavailable(CredentialStoreFailure.Reason.PermanentlyInvalidated),model.state.value.session)
        assertArrayEquals(original,file.readBytes());assertFalse(runBlocking {marker.isPending()})
    }
    @Test fun pendingExitWinsOverUnavailableCredentialsAndRetryNeverReopensTheAccount()=fixture {
        locked=true;runBlocking {marker.markPending()};start()
        assertEquals(SessionUi.SignedOut,model.state.value.session);assertTrue(model.state.value.cleanupPending)
        compose.onNodeWithTag("credentials-unavailable").assertDoesNotExist()
        compose.runOnIdle {model.retryCredentialAccess();model.demo()}
        assertTrue(model.state.value.cleanupPending);assertTrue(runBlocking {marker.isPending()})
    }
    @Test fun explicitExitOfMissingDeviceKeyPreservesMessagesAndAllowsProductionLoginAgain()=fixture {
        val original=database.readBytes();val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null)}
        keys.deleteEntry("com.xmtx.im.$name.v1");start()
        assertEquals(SessionUi.CredentialsUnavailable(CredentialStoreFailure.Reason.PermanentlyInvalidated),model.state.value.session)
        compose.onNodeWithTag("credentials-sign-out").performClick()
        compose.waitUntil(15000) {model.state.value.session==SessionUi.SignedOut && !model.state.value.cleanupPending && model.credentialRecovery.value==CredentialRecoveryUi.Empty}
        assertFalse(file.exists());assertFalse(runBlocking {marker.isPending()});assertFalse(keys.containsAlias("com.xmtx.im.$name.v1"))
        assertArrayEquals(original,database.readBytes());assertTrue(model.state.value.notice!!.contains("无法确认"))
        compose.runOnIdle {model.login("account","password123456",false,"","","https://localhost:8443")}
        compose.waitUntil(15000) {model.state.value.session is SessionUi.SignedIn}
        assertEquals(1,issuedDevices.size);assertNotEquals(device,issuedDevices.single());assertTrue(keys.containsAlias("com.xmtx.im.$name.v1"))
        assertArrayEquals(original,database.readBytes());stop();start();assertTrue(model.state.value.session is SessionUi.SignedIn)
        assertEquals(1,issuedDevices.size)
    }
    @Test fun failedMalformedRecordDeletionStaysPendingAcrossOwnersUntilExplicitRetry()=fixture {
        runBlocking {store.write("invalid JSON")};val damaged=file.readBytes();val data=database.readBytes();failDelete=true;start()
        compose.onNodeWithTag("credentials-sign-out").performClick()
        compose.waitUntil(15000) {model.state.value.session==SessionUi.SignedOut && model.state.value.cleanupPending}
        assertArrayEquals(damaged,file.readBytes());assertTrue(runBlocking {marker.isPending()});assertNull(model.state.value.notice)
        stop();start();assertTrue(model.state.value.cleanupPending);assertArrayEquals(data,database.readBytes())
        failDelete=false;compose.onNodeWithText("重试完成退出登录").performScrollTo().performClick()
        compose.waitUntil(15000) {model.state.value.session==SessionUi.SignedOut && !model.state.value.cleanupPending && model.credentialRecovery.value==CredentialRecoveryUi.Empty}
        assertFalse(file.exists());assertFalse(runBlocking {marker.isPending()});assertArrayEquals(data,database.readBytes());assertTrue(issuedDevices.isEmpty())
    }
}
