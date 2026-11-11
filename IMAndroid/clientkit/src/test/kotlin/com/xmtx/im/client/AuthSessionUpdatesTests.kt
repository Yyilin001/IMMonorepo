package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AuthSessionUpdatesTests {
    @Test fun observationIsLocalAndCancellingItDoesNotAffectTheSession() = runTest {
        val backing=MemorySecrets();val api=FakeAccount();val auth=AuthSession(backing,api){0}
        assertEquals(AuthSessionState.Uninitialized,auth.currentState())
        val event=auth.sessionUpdates(auth.currentEpoch()).first()
        assertEquals(AuthSessionSnapshot.Status.Active(AuthSessionState.Uninitialized),event.status)
        assertNull(backing.value);assertTrue(api.requests.isEmpty())
        auth.login("account","password123456")
        val identity=auth.localAccountIdentity();val before=backing.value;api.requests.clear()
        val listener=backgroundScope.launch {auth.sessionUpdates(identity.epoch).collect()};runCurrent();listener.cancelAndJoin()
        assertEquals(identity,auth.localAccountIdentity());assertEquals(before,backing.value);assertTrue(api.requests.isEmpty())
    }
    @Test fun refreshPublishesTokenFreeStatesAndKeepsItsEpoch()=runTest {
        val backing=MemorySecrets();val api=FakeAccount();val auth=AuthSession(backing,api){0}
        val credentials=auth.login("account","password123456");val epoch=auth.currentEpoch()
        val events=mutableListOf<AuthSessionSnapshot>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {auth.sessionUpdates(epoch).collect {events.add(it)}}
        runCurrent();api.accessExpiry=200_000;auth.access(credentials);runCurrent()
        assertSame(epoch,auth.currentEpoch());assertEquals(AuthSessionState.Authenticated(200_000),auth.currentState())
        assertTrue(events.all {it.epoch===epoch && it.status is AuthSessionSnapshot.Status.Active})
        assertFalse(events.toString().contains(credentials.accessToken));assertFalse(events.toString().contains(credentials.refreshCredential))
    }
    @Test fun temporaryCredentialFailurePublishesUnavailableWithoutChangingIdentityOrIssuingRequests()=runTest {
        val backing=MemorySecrets();val api=FakeAccount();AuthSession(backing,api){0}.login("account","password123456")
        var fail=false
        val auth=AuthSession(ClassifiedCredentialStore(object:SecretStore by backing {override suspend fun read():String? {if(fail) throw IOException();return backing.read()}}),api){0}
        val identity=auth.localAccountIdentity();val before=backing.value;api.requests.clear()
        fail=true;assertFailsWith<CredentialStoreFailure> {auth.current()}
        val event=auth.sessionUpdates(identity.epoch).first()
        assertEquals(AuthSessionSnapshot.Status.Active(AuthSessionState.CredentialsUnavailable(CredentialStoreFailure.Reason.Unavailable)),event.status)
        fail=false;assertEquals(identity,auth.localAccountIdentity());assertEquals(before,backing.value);assertTrue(api.requests.isEmpty())
    }
    @Test fun failedExitEndsOldObserversEvenWhenThereIsNoDurableWrite()=runTest {
        val backing=MemorySecrets();val api=FakeAccount();val auth=AuthSession(backing,api){0};auth.login("account","password123456")
        val epoch=auth.currentEpoch();val stream=async {auth.sessionUpdates(epoch).toList()};runCurrent()
        backing.failWrite=true;assertFailsWith<IOException> {auth.logout()};runCurrent()
        val end=AuthSessionSnapshot.Status.Ended(AuthSessionSnapshot.EndReason.CredentialDeletionPending)
        assertEquals(end,stream.await().last().status);assertEquals(end,auth.sessionUpdates(epoch).single().status)
        assertEquals(AuthSessionState.CleanupPending,auth.currentState());assertNull(auth.current())
    }
    @Test fun replacementEndsOnlyTheOriginalEpochAndCannotBeRetiredByItsStaleOwner()=runTest {
        val backing=MemorySecrets();val api=FakeAccount();val auth=AuthSession(backing,api){0};auth.login("account","password123456")
        val epoch=auth.currentEpoch();val stream=async {auth.sessionUpdates(epoch).toList()};runCurrent()
        val journal=Json.parseToJsonElement(backing.value!!).jsonObject
        val credentials=journal.getValue("credentials").jsonObject
        backing.value=JsonObject(journal+ ("credentials" to JsonObject(credentials+("userId" to JsonPrimitive("replacement"))))).toString()
        val before=backing.value;val next=auth.localAccountIdentity();runCurrent()
        assertNotSame(epoch,next.epoch)
        assertEquals(AuthSessionSnapshot.Status.Ended(AuthSessionSnapshot.EndReason.Superseded),stream.await().last().status)
        assertFailsWith<ClientFailure.SessionInvalidated> {auth.prepareLocalExit(epoch)}
        assertEquals(before,backing.value);assertFalse(auth.hasCleanup())
        assertEquals(AuthSessionSnapshot.Status.Active(AuthSessionState.Authenticated(100_000)),auth.sessionUpdates(next.epoch).first().status)
    }
    @Test fun absentCredentialsEndAsAuthenticationRequiredAndForeignEpochsEndImmediately()=runTest {
        val backing=MemorySecrets();val api=FakeAccount();val auth=AuthSession(backing,api){0};auth.login("account","password123456")
        val epoch=auth.currentEpoch();backing.value=null;assertNull(auth.current())
        assertEquals(AuthSessionSnapshot.Status.Ended(AuthSessionSnapshot.EndReason.AuthenticationRequired),auth.sessionUpdates(epoch).single().status)
        val foreign=AuthSession(MemorySecrets(),FakeAccount()).currentEpoch()
        assertEquals(AuthSessionSnapshot.Status.Ended(AuthSessionSnapshot.EndReason.Superseded),auth.sessionUpdates(foreign).single().status)
    }
    @Test fun slowObserverKeepsTerminalSnapshotAndCancelledReadsDoNotPublishUnavailable()=runTest {
        val backing=MemorySecrets();val api=FakeAccount();var blocked=false
        val entered=CompletableDeferred<Unit>()
        val auth=AuthSession(object:SecretStore by backing {override suspend fun read():String? {
            if(blocked) {entered.complete(Unit);awaitCancellation()};return backing.read()
        }},api){0}
        auth.login("account","password123456");val epoch=auth.currentEpoch()
        blocked=true;val reader=launch {auth.current()};entered.await();reader.cancelAndJoin();blocked=false
        assertTrue(auth.currentState() is AuthSessionState.Authenticated)
        val gate=CompletableDeferred<Unit>();val events=mutableListOf<AuthSessionSnapshot>()
        val observer=async {auth.sessionUpdates(epoch).collect {events.add(it);if(events.size==1) gate.await()}}
        runCurrent();auth.prepareLocalExit();auth.logout();gate.complete(Unit);observer.await()
        assertEquals(2,events.size)
        assertEquals(AuthSessionSnapshot.Status.Ended(AuthSessionSnapshot.EndReason.CredentialDeletionPending),events.last().status)
        assertEquals(AuthSessionState.Unauthenticated,auth.currentState())
    }
    @Test fun unreadableExitMarkerPublishesItsOwnStateWithoutClearingOrRepairingIt()=runTest {
        val backing=MemorySecrets();val api=FakeAccount();var unreadable=false
        val marker=object:LocalExitMarker {
            override suspend fun isPending():Boolean {if(unreadable) throw LocalExitFailure(LocalExitFailure.Reason.Malformed);return false}
            override suspend fun markPending()=error("unexpected repair")
            override suspend fun clearPending()=error("unexpected clear")
        }
        val auth=AuthSession(backing,api,marker){0};auth.login("account","password123456")
        val epoch=auth.currentEpoch();unreadable=true
        assertFailsWith<LocalExitFailure> {auth.current()}
        assertEquals(AuthSessionSnapshot.Status.Active(AuthSessionState.ExitUnavailable(LocalExitFailure.Reason.Malformed)),auth.sessionUpdates(epoch).first().status)
        assertFailsWith<LocalExitFailure> {auth.current()}
    }

    @Test fun endingManyImmediateCollectorsDoesNotMutateTheObserverIteration()=runTest {
        val backing=MemorySecrets();val auth=AuthSession(backing,FakeAccount()){0};auth.login("account","password123456")
        val epoch=auth.currentEpoch()
        val observers=(1..16).map {async(UnconfinedTestDispatcher(testScheduler)) {auth.sessionUpdates(epoch).toList()}}
        runCurrent();auth.prepareLocalExit()
        observers.forEach {assertEquals(AuthSessionSnapshot.Status.Ended(AuthSessionSnapshot.EndReason.CredentialDeletionPending),it.await().last().status)}
    }

}
