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

class OperationWorkStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture(val limits: OperationAdmissionLimits = OperationAdmissionLimits()) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id()); val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device, operationLimits = limits)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device, operationLimits = limits) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
        suspend fun enqueue(deadline: Long = 1_000_000): NameWork {
            val target = NameTarget.Contact(UserId(id()))
            store.saveNameSnapshot(NameSnapshot(actor, target, null, null))
            return store.enqueueName(NameCommand(actor, target, id(), "私人备注", null, deadline), 1_000)
        }
        fun <T> sql(body: (SQLiteDatabase, SqliteOperationWork) -> T): T = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
            db.beginTransaction()
            try { body(db, SqliteOperationWork(db, actor)).also { db.setTransactionSuccessful() } } finally { db.endTransaction() }
        }
    }
    private fun closed(command: NameCommand): NameResult.Receipt = NameOperationClient.decodeReceipt(command, buildJsonObject {
        put("identity", command.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) })
        put("resolvedAtMilliseconds", 2_000); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
    })

    @Test fun twoOwnersCannotShareAClaimOrStealAnExpiredLeaseAndOldFailureIsFenced() = runBlocking {
        val f = Fixture()
        try {
            val work = f.enqueue(); val owner = id(); val otherOwner = id()
            val results = awaitAll(async { f.store.claimName(work.command.operation, owner, 1_000) }, async { f.store.claimName(work.command.operation, otherOwner, 1_000) })
            val first = results.filterNotNull().single(); val holder = first.claim.owner
            assertEquals(1, f.store.operationWork(work.command.operation)!!.attemptCount)
            assertNull(f.store.claimName(work.command.operation, holder, 90_000))
            assertNull(f.store.claimName(work.command.operation, id(), 90_000))
            f.reopen(); f.store.recoverNameClaimsAfterDrain(holder, 90_000)
            assertNull(f.store.claimName(work.command.operation, holder, 90_000))
            val successor = id(); f.store.recoverNameClaimsAfterDrain(successor, 90_000)
            val next = requireNotNull(f.store.claimName(work.command.operation, successor, 90_000))
            assertEquals(OperationWorkAction.Reconcile, next.claim.action)
            assertEquals(first.work.command, next.work.command); assertEquals(2, next.claim.work.attemptCount)
            try { f.store.deferName(first, 100_000, "old failure", true, OperationWorkAction.Reconcile); fail("stale failure changed new owner") }
            catch (_: StaleOperationClaim) { }
            assertEquals(next.claim.work, f.store.operationWork(work.command.operation))
            // Authoritative receipts use frozen identity, not a now-obsolete claim token.
            f.store.completeName(first, closed(first.work.command), 91_000)
            assertEquals(OperationExecutionState.Closed, f.store.operationWork(work.command.operation)!!.execution)
            f.store.deferName(next, 100_000, "late failure", true, OperationWorkAction.Reconcile)
            assertEquals(NameStatus.Closed, f.store.nameWork(work.command.operation)!!.status)
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun realServiceCancellationDrainsBeforeReleasingAndConcurrentServiceDoesNotSubmit() = runBlocking {
        val f = Fixture(); var now = 1_000L
        try {
            val work = f.enqueue(); val entered = CompletableDeferred<Unit>(); var submits = 0; var recoveries = 0
            val transport = object: NameTransport {
                override suspend fun snapshot(actor: UserId, target: NameTarget) = error("unused")
                override suspend fun submit(command: NameCommand): NameResult.Receipt {
                    submits++; assertEquals(OperationSchedulingState.Claimed, f.store.operationWork(command.operation)!!.scheduling)
                    entered.complete(Unit); awaitCancellation()
                }
                override suspend fun recover(command: NameCommand, close: Boolean): NameResult { recoveries++; return closed(command) }
            }
            val service = NameOperationService(f.actor, transport, f.store) { now }
            val job = launch { service.flush() }; entered.await(); now = 90_000
            NameOperationService(f.actor, transport, f.store) { now }.flush()
            assertEquals(1, submits); job.cancelAndJoin()
            assertEquals(OperationExecutionState.AwaitingConfirmation, f.store.operationWork(work.command.operation)!!.execution)
            assertEquals(OperationSchedulingState.BackingOff, f.store.operationWork(work.command.operation)!!.scheduling)
            service.flush(); assertEquals(1, recoveries)
            assertEquals(NameStatus.Closed, f.store.nameWork(work.command.operation)!!.status)
            val timedOut = f.enqueue()
            try { withTimeout(100) { service.flush() }; fail("outer timeout was swallowed") }
            catch (_: TimeoutCancellationException) { }
            assertEquals(OperationSchedulingState.BackingOff, f.store.operationWork(timedOut.command.operation)!!.scheduling)
            assertEquals(OperationWorkAction.Reconcile, f.store.operationWork(timedOut.command.operation)!!.nextAction)
        } finally { f.close() }
    }

    @Test fun independentRoundsAndUserRetryPreserveLifetimeCountIdentityAndCooldown() = runBlocking {
        val f = Fixture()
        try {
            val work = f.enqueue(); val owner = id()
            repeat(5) {
                val submit = requireNotNull(f.store.claimName(work.command.operation, owner, 1_000))
                assertEquals(OperationWorkAction.Submit, submit.claim.action)
                f.store.deferName(submit, 1_000, "unknown", false, OperationWorkAction.Reconcile)
                val recover = requireNotNull(f.store.claimName(work.command.operation, owner, 1_000))
                assertEquals(OperationWorkAction.Reconcile, recover.claim.action)
                f.store.deferName(recover, 1_000, "unresolved", false, OperationWorkAction.Submit)
            }
            assertNull(f.store.claimName(work.command.operation, owner, 1_000))
            val stopped = f.store.operationWork(work.command.operation)!!
            assertEquals(10, stopped.attemptCount); assertEquals(5, stopped.submissionRoundAttempts); assertEquals(5, stopped.reconciliationRoundAttempts)
            assertEquals(NameStatus.NeedsAttention, f.store.nameWork(work.command.operation)!!.status)
            f.store.retryName(work.command.operation, 2_000)
            val attempt = requireNotNull(f.store.claimName(work.command.operation, owner, 2_000))
            assertEquals(11, attempt.claim.work.attemptCount); assertEquals(OperationWorkAction.Reconcile, attempt.claim.action)
            f.store.deferName(attempt, 120_000, "server cooldown", true, OperationWorkAction.Reconcile)
            f.store.retryName(work.command.operation, 3_000)
            assertNull(f.store.claimName(work.command.operation, owner, 119_999))
            val snapshot = f.store.operationWork(work.command.operation)!!
            assertEquals(120_000L, snapshot.nextActionAt); assertEquals(11, snapshot.attemptCount)
            assertEquals(work.command, f.store.nameWork(work.command.operation)!!.command)
            f.reopen(); assertEquals(snapshot, f.store.operationWork(work.command.operation))
        } finally { f.close() }
    }

    @Test fun metadataQuotaRollbackAndLegacyMigrationDoNotInventCreationTime() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 100_000))
        try {
            val work = f.enqueue()
            assertEquals(1_000L, f.store.operationWork(work.command.operation)!!.originalCreatedAt)
            try { f.enqueue(); fail("quota bypassed") } catch (_: OperationCapacityExceeded) { }
            f.sql { db, _ -> db.rawQuery("SELECT COUNT(*) FROM operation_work", null).use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)) } }
            val unknown = work.copy(submissionStarted = true, reconcile = true, attempts = 2, roundStarted = 1_000)
            f.store.updateName(work, unknown)
            f.sql { db, _ -> db.execSQL("DELETE FROM operation_work WHERE id=?", arrayOf(work.command.operation)) }
            f.reopen(); val legacy = f.store.operationWork(work.command.operation)!!
            assertNull(legacy.originalCreatedAt); assertEquals(2, legacy.submissionRoundAttempts); assertEquals(2, legacy.reconciliationRoundAttempts)
            val claim = requireNotNull(f.store.claimName(work.command.operation, id(), 2_000))
            assertEquals(OperationWorkAction.Reconcile, claim.claim.action); assertEquals(work.command, claim.work.command)
            try { f.store.updateName(claim.work, claim.work.copy(status = NameStatus.NeedsAttention)); fail("legacy CAS replaced active claim") }
            catch (_: StaleOperationClaim) { }
        } finally { f.close() }
    }

    @Test fun expiryIsLocalAndNoTransportCallCanOccur() = runBlocking {
        val f = Fixture()
        try {
            val work = f.enqueue(deadline = 999)
            val transport = object: NameTransport {
                override suspend fun snapshot(actor: UserId, target: NameTarget) = error("unused")
                override suspend fun submit(command: NameCommand): NameResult.Receipt = error("expired operation submitted")
                override suspend fun recover(command: NameCommand, close: Boolean): NameResult = error("unsubmitted operation recovered")
            }
            NameOperationService(f.actor, transport, f.store) { 1_000 }.flush()
            assertEquals(OperationExecutionState.ExpiredUnsubmitted, f.store.operationWork(work.command.operation)!!.execution)
            assertEquals(0, f.store.operationWork(work.command.operation)!!.attemptCount)
            assertEquals(NameStatus.Cancelled, f.store.nameWork(work.command.operation)!!.status)
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun dependenciesAreImmutablePreexistingAndBlockUntilCommittedWithBoundedCandidates() {
        val f = Fixture()
        try { f.sql { db, journal ->
            fun input(order: String = id()): OperationWork {
                val command = NameCommand(f.actor, NameTarget.Contact(UserId(id())), id(), "备注", null, 1_000_000)
                return OperationWork(command.operation, f.actor, OperationKind.ContactAlias, command.identity().toString(), command.fingerprint,
                    order, 1, nextActionAt = 1_000, admissionDeadline = command.deadline, originalCreatedAt = 1_000)
            }
            val parent = journal.insert(input("ordered")); val childInput = input(); val child = journal.insert(childInput, persistentListOf(parent.id))
            val later = journal.insert(input("ordered"))
            assertEquals(listOf(parent.id), journal.due(1_000, 32).map { it.id })
            assertEquals(OperationWorkClaimResult.Unavailable, journal.claim(child.id, id(), OperationWorkAction.Submit, 1_000))
            try { journal.insert(input(), persistentListOf(id())); fail("missing parent") } catch (_: IllegalArgumentException) { }
            val self = input()
            try { journal.insert(self, persistentListOf(self.id)); fail("self dependency") } catch (_: IllegalArgumentException) { }
            try { journal.insert(childInput, persistentListOf(later.id)); fail("dependencies replaced") } catch (_: IllegalArgumentException) { }
            val claimed = (journal.claim(parent.id, id(), OperationWorkAction.Submit, 1_000) as OperationWorkClaimResult.Claimed).claim
            journal.complete(parent.id, claimed.work.fingerprint, OperationExecutionState.Committed, "{}", 2_000)
            assertEquals(listOf(child.id, later.id), journal.due(2_000, 32).map { it.id })
            repeat(40) { journal.insert(input()) }; assertEquals(32, journal.due(2_000, 32).size)
            try { journal.due(2_000, 33); fail("unbounded candidates") } catch (_: IllegalArgumentException) { }
            // A damaged missing parent never turns into successful dependency evidence.
            db.execSQL("DELETE FROM operation_work WHERE id=?", arrayOf(parent.id))
            assertFalse(journal.due(2_000, 32).any { it.id == child.id })
        } } finally { f.close() }
    }
}
