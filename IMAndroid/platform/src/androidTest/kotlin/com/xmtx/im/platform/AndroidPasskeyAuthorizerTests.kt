package com.xmtx.im.platform

import android.app.Activity
import android.content.Intent
import android.os.Looper
import androidx.credentials.*
import androidx.credentials.exceptions.*
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class PasskeyTestActivity:Activity()

class AndroidPasskeyAuthorizerTests {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private fun request()=PasskeyAssertionRequest("fresh-challenge",ByteString.copyFrom(byteArrayOf(1,2,3)),"im.example.com",persistentListOf(ByteString.copyFrom(byteArrayOf(7))))
    private fun response(challenge:String="AQID"):GetCredentialResponse {
        val client=Base64.getUrlEncoder().withoutPadding().encodeToString("""{"type":"webauthn.get","challenge":"$challenge","origin":"android:apk-key-hash:fixture"}""".toByteArray())
        return GetCredentialResponse(PublicKeyCredential("""{"type":"public-key","id":"Bw","rawId":"Bw","response":{"clientDataJSON":"$client","authenticatorData":"Ag","signature":"Aw","userHandle":null}}"""))
    }
    private suspend fun <T> activity(block:suspend (Activity)->T):T {
        val a=instrumentation.startActivitySync(Intent(instrumentation.targetContext,PasskeyTestActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return try {block(a)} finally {withContext(Dispatchers.Main) {a.finish()};instrumentation.waitForIdleSync()}
    }
    private suspend fun failure(block:suspend ()->Unit):PasskeyFailure {
        try {block();error("Expected PasskeyFailure")} catch(error:PasskeyFailure) {return error}
    }
    @Test fun bridgeUsesForegroundContextPublicKeyOnlyAndSystemOrigin()=runBlocking<Unit> {activity {a->
        val authorizer=AndroidPasskeyAuthorizer.testing(a) {context,options->
            assertSame(Looper.getMainLooper(),Looper.myLooper());assertSame(a,context.baseContext);assertNull(options.origin)
            val option=options.credentialOptions.single() as GetPublicKeyCredentialOption
            assertEquals(Json.parseToJsonElement(request().webAuthnRequestJson()),Json.parseToJsonElement(option.requestJson))
            response()
        }
        assertEquals(ByteString.copyFrom(byteArrayOf(7)),authorizer.authorize(request()).credentialID)
    }}
    @Test fun cancellationDrainsTheWaiterAndAllowsAnExplicitNewAttempt()=runBlocking<Unit> {activity {a->
        val entered=CompletableDeferred<Unit>();var blocking=true
        val authorizer=AndroidPasskeyAuthorizer.testing(a) {_,_->if(blocking) {entered.complete(Unit);awaitCancellation()} else response()}
        val first=async {authorizer.authorize(request())};withTimeout(5000) {entered.await()}
        assertEquals(PasskeyFailureReason.Unavailable,failure {authorizer.authorize(request())}.reason)
        first.cancelAndJoin();blocking=false;assertEquals(ByteString.copyFrom(byteArrayOf(7)),authorizer.authorize(request()).credentialID)
    }}
    @Test fun aLateProviderCallbackCannotPublishAfterCallerCancellation()=runBlocking<Unit> {activity {a->
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var returned=false
        val authorizer=AndroidPasskeyAuthorizer.testing(a) {_,_->withContext(NonCancellable) {entered.complete(Unit);release.await();response()}}
        val first=launch {authorizer.authorize(request());returned=true};withTimeout(5000) {entered.await()}
        first.cancel();release.complete(Unit);withTimeout(5000) {first.join()};assertFalse(returned);assertTrue(first.isCancelled)
    }}
    @Test fun providerCancellationIsCancellationAndDetailsNeverLeak()=runBlocking<Unit> {activity {a->
        val authorizer=AndroidPasskeyAuthorizer.testing(a) {_,_->throw GetCredentialCancellationException("PRIVATE-PLATFORM-MATERIAL")}
        val error=try {authorizer.authorize(request());error("Expected cancellation")} catch(e:CancellationException) {e}
        assertFalse(error.toString().contains("PRIVATE-PLATFORM-MATERIAL"));assertNull(error.cause)
    }}
    @Test fun absenceAndProviderFailureStayDistinctWithoutSensitiveCauses()=runBlocking<Unit> {activity {a->
        for(absent in listOf(true,false)) {
            val authorizer=AndroidPasskeyAuthorizer.testing(a) {_,_->if(absent) throw NoCredentialException("PRIVATE-MATERIAL") else throw GetCredentialUnknownException("PRIVATE-MATERIAL")}
            val error=failure {authorizer.authorize(request())}
            assertEquals(if(absent) PasskeyFailureReason.NoCredential else PasskeyFailureReason.Unavailable,error.reason)
            assertFalse(error.toString().contains("PRIVATE-MATERIAL"));assertNull(error.cause)
        }
    }}
    @Test fun wrongCredentialTypeAndStaleChallengeNeverBecomeAnAccountAssertion()=runBlocking<Unit> {activity {a->
        val password=AndroidPasskeyAuthorizer.testing(a) {_,_->GetCredentialResponse(PasswordCredential("account","SECRET-PASSWORD"))}
        assertEquals(PasskeyFailureReason.InvalidResponse,failure {password.authorize(request())}.reason)
        val stale=AndroidPasskeyAuthorizer.testing(a) {_,_->response("BA")}
        assertEquals(PasskeyFailureReason.InvalidResponse,failure {stale.authorize(request())}.reason)
    }}
    @Test fun aFinishedActivityCannotLaunchNewCredentialUI()=runBlocking<Unit> {activity {a->
        var calls=0;val authorizer=AndroidPasskeyAuthorizer.testing(a) {_,_->calls++;response()}
        withContext(Dispatchers.Main) {a.finish()}
        assertEquals(PasskeyFailureReason.Unavailable,failure {authorizer.authorize(request())}.reason);assertEquals(0,calls)
    }}
}
