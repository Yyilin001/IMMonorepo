package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class CredentialStoreTests {
    @Test fun unknownBackendFailuresAreUnavailableAndNeverLookLikeMissingCredentials() = runTest {
        var calls=0
        val backend=object : SecretStore {
            override suspend fun read():String? { calls++;throw IOException("private record detail") }
            override suspend fun write(value:String) {calls++;throw IOException(value)}
            override suspend fun delete() {calls++;throw IOException("private deletion detail")}
        }
        val store=ClassifiedCredentialStore(backend)
        for (action in listOf<suspend ()->Unit>({store.read();Unit},{store.write("secret")},{store.delete()})) {
            val error=assertFailsWith<CredentialStoreFailure> {action()}
            assertEquals(CredentialStoreFailure.Reason.Unavailable,error.reason);assertNull(error.cause)
            assertFalse(error.toString().contains("secret"));assertFalse(error.toString().contains("private"))
        }
        assertEquals(3,calls)
        val api=FakeAccount();val auth=AuthSession(store,api)
        assertFailsWith<CredentialStoreFailure> {auth.current()}
        assertFailsWith<CredentialStoreFailure> {auth.login("account","password123456")}
        assertTrue(api.requests.isEmpty())
    }
    @Test fun knownClassificationAndCancellationSurviveTheAdapter() = runTest {
        var failure:Exception=CredentialStoreFailure(CredentialStoreFailure.Reason.PermanentlyInvalidated)
        val store=ClassifiedCredentialStore(object:SecretStore {
            override suspend fun read():String? = throw failure
            override suspend fun write(value:String) {throw failure}
            override suspend fun delete() {throw failure}
        })
        assertSame(failure,assertFailsWith<CredentialStoreFailure> {store.read()})
        failure=CancellationException();assertSame(failure,assertFailsWith<CancellationException> {store.read()})
        assertSame(failure,assertFailsWith<CancellationException> {store.write("fixture")})
        assertSame(failure,assertFailsWith<CancellationException> {store.delete()})
    }
    @Test fun malformedJournalIsPreservedUntilExplicitLogout() = runTest {
        val backing=MemorySecrets().apply {value="malformed fixture token"};val api=FakeAccount()
        val auth=AuthSession(ClassifiedCredentialStore(backing),api)
        for(action in listOf<suspend ()->Unit>({auth.current();Unit},{auth.localAccountIdentity();Unit},{auth.login("account","password123456");Unit})) {
            assertEquals(CredentialStoreFailure.Reason.Malformed,assertFailsWith<CredentialStoreFailure> {action()}.reason)
        }
        assertEquals("malformed fixture token",backing.value);assertTrue(api.requests.isEmpty())
        auth.logout(); assertNull(backing.value); assertTrue(api.requests.isEmpty())
    }
    @Test fun temporaryFailureRetryRetainsTheSameIdentityAndNoTokenRefresh() = runTest {
        val backing=MemorySecrets();val api=FakeAccount();val authWriter=AuthSession(backing,api){0}
        authWriter.login("account","password123456");val before=backing.value;api.requests.clear()
        var locked=false
        val auth=AuthSession(ClassifiedCredentialStore(object:SecretStore by backing {
            override suspend fun read():String? {if(locked) throw IOException();return backing.read()}
        }),api){0}
        val identity=auth.localAccountIdentity();locked=true
        assertEquals(CredentialStoreFailure.Reason.Unavailable,assertFailsWith<CredentialStoreFailure> {auth.localAccountIdentity()}.reason)
        locked=false;assertEquals(identity,auth.localAccountIdentity());assertEquals(before,backing.value);assertTrue(api.requests.isEmpty())
    }
}
