package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class OwnProfileExecutionStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id()); val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device)
        val baseline = ProfileView(actor, PublicIdentity(actor, PublicHandle("execution_profile"), "原名", AccountKind.Regular), null, ProfileState.Active, 1, 1)
        suspend fun enqueue(deadline: Long = 1_000_000): OwnProfileWork {
            store.saveOwnProfile(baseline)
            return store.enqueueOwnProfile(OwnProfileCommand(actor, id(), 1, OwnProfilePatch("新名"), deadline), null, 1_000)
        }
        suspend fun name(): NameWork {
            val target = NameTarget.Contact(UserId(id())); store.saveNameSnapshot(NameSnapshot(actor, target, null, null))
            return store.enqueueName(NameCommand(actor, target, id(), "备注", null, 1_000_000), 1_000)
        }
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
    }
    private fun closed(command: OwnProfileCommand, snapshot: ProfileView? = null): OwnProfileResult.Receipt = OwnProfileClient.decodeResult(command, buildJsonObject {
        put("receipt", buildJsonObject {
            put("actorUserID", buildJsonObject { put("rawValue", command.actor.value) })
            put("operationID", buildJsonObject { put("rawValue", command.operation) })
            put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) })
            put("resolvedAtMilliseconds", 2_000); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
        })
        snapshot?.let { put("currentSnapshot", OwnProfileClient.profilePayload(it)) }
    })
    @Test fun separateOwnersRecoverOnlyTheirDomainAndStaleFailureCannotReplaceVerifiedOutcome() = runBlocking {
        val f = Fixture()
        try {
            val profile = f.enqueue(); val name = f.name(); val owner = id()
            val first = requireNotNull(f.store.claimOwnProfile(profile.command.operation, owner, 1_000))
            val nameClaim = requireNotNull(f.store.claimName(name.command.operation, id(), 1_000))
            assertNull(f.store.claimOwnProfile(profile.command.operation, id(), 90_000))
            f.store.recoverNameClaimsAfterDrain(id(), 90_000)
            assertEquals(first.claim.work, f.store.operationWork(profile.command.operation))
            val nextName = requireNotNull(f.store.claimName(name.command.operation, id(), 90_000))
            assertEquals(OperationWorkAction.Reconcile, nextName.claim.action)
            f.reopen(); f.store.recoverOwnProfileClaimsAfterDrain(owner, 90_000)
            assertEquals(first.claim.work, f.store.operationWork(profile.command.operation))
            val nextOwner = id(); f.store.recoverOwnProfileClaimsAfterDrain(nextOwner, 90_000)
            assertEquals(nextName.claim.work, f.store.operationWork(name.command.operation))
            val next = requireNotNull(f.store.claimOwnProfile(profile.command.operation, nextOwner, 90_000))
            assertEquals(OperationWorkAction.Reconcile, next.claim.action)
            try { f.store.deferOwnProfile(first, 100_000, "old", true, OperationWorkAction.Reconcile); fail("stale failure") } catch (_: StaleOperationClaim) { }
            try { f.store.updateOwnProfile(next.work, next.work.copy(status = OwnProfileStatus.NeedsAttention)); fail("legacy claim bypass") } catch (_: StaleOperationClaim) { }
            try { f.store.completeOwnProfile(first, closed(profile.command).copy(status = OwnProfileStatus.Committed), 91_000); fail("unverified outcome") } catch (_: IllegalArgumentException) { }
            assertEquals(next.claim.work, f.store.operationWork(profile.command.operation))
            f.store.completeOwnProfile(first, closed(profile.command), 91_000)
            f.store.deferOwnProfile(next, 100_000, "late", true, OperationWorkAction.Reconcile)
            // The original outcome remains closed even when a later query carries a newer snapshot.
            val newer = f.baseline.copy(revision = 3, visibilityRevision = 3, identity = f.baseline.identity!!.copy(displayName = "其他修改"))
            f.store.completeOwnProfile(first, closed(profile.command, newer), 92_000)
            assertEquals(OwnProfileStatus.Closed, f.store.ownProfileWork(profile.command.operation)!!.status)
            assertTrue(f.store.ownProfileWork(profile.command.operation)!!.draftRetained)
            assertEquals(newer, f.store.ownProfile()); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            assertEquals(nameClaim.work.command, nextName.work.command)
        } finally { f.close() }
    }
    @Test fun actualServiceCancellationAndOuterTimeoutReleaseOnlyAfterPhysicalStepStops() = runBlocking {
        val f = Fixture(); var now = 1_000L
        try {
            val work = f.enqueue(); var submits = 0; var queries = 0; val entered = CompletableDeferred<Unit>()
            val transport = object: OwnProfileTransport {
                override suspend fun current() = f.baseline
                override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt {
                    submits++; assertEquals(OperationSchedulingState.Claimed, f.store.operationWork(command.operation)!!.scheduling)
                    entered.complete(Unit); awaitCancellation()
                }
                override suspend fun recover(command: OwnProfileCommand, close: Boolean): OwnProfileResult { queries++; return closed(command) }
            }
            val service = OwnProfileService(f.actor, transport, f.store) { now }
            val job = launch { service.flush() }; entered.await(); now = 90_000
            OwnProfileService(f.actor, transport, f.store) { now }.flush(); assertEquals(1, submits)
            job.cancelAndJoin(); assertEquals(OperationSchedulingState.BackingOff, f.store.operationWork(work.command.operation)!!.scheduling)
            service.flush(); assertEquals(1, queries); assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            val timed = f.enqueue()
            try { withTimeout(100) { service.flush() }; fail("outer timeout swallowed") } catch (_: TimeoutCancellationException) { }
            assertEquals(OperationSchedulingState.BackingOff, f.store.operationWork(timed.command.operation)!!.scheduling)
            assertEquals(OperationWorkAction.Reconcile, f.store.operationWork(timed.command.operation)!!.nextAction)
        } finally { f.close() }
    }
    @Test fun boundedKindQueryDoesNotStarveProfilesBehindNamesAndPreservesProfileOrder() = runBlocking {
        val f = Fixture()
        try {
            repeat(40) { f.name() }; val first = f.enqueue(); val second = f.enqueue()
            assertEquals(32, f.store.dueOperationWork(1_000).size)
            val kinds = persistentSetOf(OperationKind.ProfileUpdate)
            assertEquals(listOf(first.command.operation), f.store.dueOperationWork(1_000, 32, kinds).map { it.id })
            assertTrue(f.store.dueOperationWork(1_000, 32, persistentSetOf()).isEmpty())
            assertNull(f.store.claimOwnProfile(second.command.operation, id(), 1_000))
            val claim = requireNotNull(f.store.claimOwnProfile(first.command.operation, id(), 1_000))
            f.store.completeOwnProfile(claim, closed(first.command), 2_000)
            assertEquals(listOf(second.command.operation), f.store.dueOperationWork(2_000, 32, kinds).map { it.id })
        } finally { f.close() }
    }
    @Test fun legacyUnknownMigrationPreservesBudgetsAndIntentRetryPreservesCooldown() = runBlocking {
        val f = Fixture()
        try {
            f.store.saveOwnProfile(f.baseline)
            val intent = ProfileIntent(id(), f.actor, id(), 1, 86_401_000, name = "新名")
            f.store.enqueueProfileIntent(intent, 1_000); assertNull(f.store.operationWork(intent.operation))
            f.store.advanceProfileIntents(2_000)
            assertEquals(2_000L, f.store.operationWork(intent.operation)!!.originalCreatedAt)
            val prepared = f.store.ownProfileWork(intent.operation)!!
            val unknown = prepared.copy(submissionStarted = true, reconcile = true, attempts = 2, roundStarted = 2_000, nextAttempt = 5_000)
            f.store.updateOwnProfile(prepared, unknown)
            f.store.close()
            SQLiteDatabase.openDatabase(f.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { it.execSQL("DELETE FROM operation_work WHERE id=?", arrayOf(intent.operation)) }
            f.store = SqliteClientStore(f.context, f.actor, f.device)
            val migrated = f.store.operationWork(intent.operation)!!
            assertNull(migrated.originalCreatedAt); assertEquals(2, migrated.submissionRoundAttempts); assertEquals(2, migrated.reconciliationRoundAttempts)
            val claim = requireNotNull(f.store.claimOwnProfile(intent.operation, id(), 5_000))
            assertEquals(OperationWorkAction.Reconcile, claim.claim.action)
            f.store.deferOwnProfile(claim, 125_000, "rateLimited", true, OperationWorkAction.Reconcile)
            f.store.resumeProfileIntent(intent.id, 6_000)
            val retry = f.store.operationWork(intent.operation)!!
            assertEquals(3, retry.attemptCount); assertEquals(0, retry.submissionRoundAttempts); assertEquals(0, retry.reconciliationRoundAttempts)
            assertEquals(125_000L, retry.nextActionAt); assertNull(f.store.claimOwnProfile(intent.operation, id(), 124_999))
            assertEquals(prepared.command, f.store.ownProfileWork(intent.operation)!!.command)
        } finally { f.close() }
    }
    @Test fun expiredUnsubmittedProfileRetainsDraftWithoutNetworkOrCapacity() = runBlocking {
        val f = Fixture()
        try {
            val work = f.enqueue(2_000)
            val transport = object: OwnProfileTransport {
                override suspend fun current() = error("network")
                override suspend fun submit(command: OwnProfileCommand) = error("network")
                override suspend fun recover(command: OwnProfileCommand, close: Boolean) = error("network")
            }
            OwnProfileService(f.actor, transport, f.store) { 2_000 }.flush()
            assertEquals(OperationExecutionState.ExpiredUnsubmitted, f.store.operationWork(work.command.operation)!!.execution)
            assertEquals(OwnProfileStatus.Expired, f.store.ownProfileWork(work.command.operation)!!.status)
            assertTrue(f.store.ownProfileWork(work.command.operation)!!.draftRetained)
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }
}
