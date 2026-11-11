package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class OperationAdmissionStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture(val limits: OperationAdmissionLimits) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val account = UserId(id()); val device = DeviceId(id())
        val file = accountDatabaseFile(context, account, device)
        var store = SqliteClientStore(context, account, device, operationLimits = limits)
        fun reopen() { store.close(); store = SqliteClientStore(context, account, device, operationLimits = limits) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
        fun direct() = DirectRoomCommand.create(account, UserId(id()), 1_000)
        fun preference(kind: PreferenceKind = PreferenceKind.StrangerMessages) =
            PreferenceWork(account, id(), PreferencePatch(kind, first = false), "activation", 116_000)
        fun proposal() = SocialProposal(id(), account, UserId(id()), SocialAction.Request)
        fun closed(work: DirectRoomWork): DirectRoomWork {
            val command = work.command
            val receipt = buildJsonObject {
                put("identity", command.identity())
                put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) })
                put("resolvedAtMilliseconds", 3_000)
                put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
            }
            return work.copy(status = DirectWorkStatus.Closed, receipt = receipt.toString())
        }
        fun inspect(body: (SQLiteDatabase) -> Unit) {
            store.close()
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(body)
            store = SqliteClientStore(context, account, device, operationLimits = limits)
        }
    }
    private suspend fun capacity(body: suspend () -> Unit) {
        try { body(); fail("over-capacity work admitted") } catch (_: OperationCapacityExceeded) { }
    }

    @Test fun crossDomainCountIsAtomicIdempotentAndTerminalCompletionReleasesIt() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(2, 1_000_000))
        try {
            val direct = f.store.prepareDirect(f.direct())
            val preference = f.store.preparePreference(f.preference())
            val before = f.store.operationAdmissionUsage()
            assertEquals(2L, before.activeCount); assertEquals(21, before.domains.size)
            assertEquals(direct, f.store.prepareDirect(direct.command))
            assertEquals(preference, f.store.preparePreference(preference))
            val rejected = f.direct()
            capacity { f.store.prepareDirect(rejected) }
            assertNull(f.store.directWork(rejected.operation)); assertEquals(before, f.store.operationAdmissionUsage())
            f.reopen(); assertEquals(before, f.store.operationAdmissionUsage())
            f.store.updateDirect(direct, f.closed(direct))
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            f.store.prepareDirect(rejected)
            assertEquals(2L, f.store.operationAdmissionUsage().activeCount)
            assertEquals(2L, before.activeCount) // Previously published value stays immutable.
        } finally { f.close() }
    }

    @Test fun proposalToFrozenCommandTransfersExactByteReservationAtFullCapacity() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 73_728))
        try {
            val proposal = f.store.saveSocialProposal(f.proposal())
            assertEquals(73_728L, f.store.operationAdmissionUsage().reservedBytes)
            capacity { f.store.preparePreference(f.preference()) }
            assertTrue(f.store.preferenceWorks().isEmpty())
            val command = SocialCommand(f.account, proposal.target, id(), proposal.action, 0, 116_000)
            val frozen = f.store.confirmSocial(proposal, command)
            assertTrue(f.store.socialProposals().isEmpty())
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            assertEquals(73_728L, f.store.operationAdmissionUsage().reservedBytes)
            val unknown = frozen.copy(status = SocialWorkStatus.NeedsAttention, executionStarted = true, reconcile = true)
            f.store.updateSocial(frozen, unknown); f.reopen()
            assertEquals(unknown, f.store.socialWork(command.operation))
            assertEquals(73_728L, f.store.operationAdmissionUsage().reservedBytes)
            capacity { f.store.saveSocialProposal(f.proposal()) }
        } finally { f.close() }
    }

    @Test fun bytesAreEnforcedIndependentlyOfCountAndDiscardReleasesReservation() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(100, 73_728))
        try {
            val proposal = f.store.saveSocialProposal(f.proposal())
            capacity { f.store.saveSocialProposal(f.proposal()) }
            assertEquals(1, f.store.socialProposals().size)
            f.store.discardSocialProposal(proposal.id)
            assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
            f.store.preparePreference(f.preference()); f.reopen()
            assertEquals(73_728L, f.store.operationAdmissionUsage().reservedBytes)
        } finally { f.close() }
    }

    @Test fun replacingPausedDraftTransfersReservationWithoutChargingCancelledHistory() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 73_728))
        try {
            val draft = f.store.preparePreference(f.preference())
            val paused = draft.copy(status = PreferenceStatus.DraftPaused)
            f.store.updatePreference(draft, paused)
            val replacement = f.store.replacePreferenceDraft(paused, draft.copy(operation = id()))
            assertEquals(2, f.store.preferenceWorks().size)
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            f.store.updatePreference(replacement, replacement.copy(status = PreferenceStatus.DraftCancelled))
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            f.reopen(); assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
        } finally { f.close() }
    }

    @Test fun legacyMigrationKeepsOverLimitWorkRecoverableAndBlocksGrowth() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 73_728))
        try {
            val first = DirectRoomWork.fresh(f.direct(), null)
            val second = DirectRoomWork.fresh(f.direct(), null)
            f.inspect { db ->
                db.execSQL("INSERT INTO direct_operations VALUES (?,?)", arrayOf(first.command.operation, Json.encodeToString(first)))
                db.execSQL("INSERT INTO direct_operations VALUES (?,?)", arrayOf(second.command.operation, Json.encodeToString(second)))
                // Simulate an old database that predates the ledger.
                db.rawQuery("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'operation_reservation_%'", null).use { rows ->
                    val names = buildList { while (rows.moveToNext()) add(rows.getString(0)) }
                    names.forEach { db.execSQL("DROP TRIGGER $it") }
                }
                listOf("operation_reservations", "operation_reservation_dirty", "operation_reservation_versions").forEach { db.execSQL("DROP TABLE $it") }
            }
            assertEquals(2L, f.store.operationAdmissionUsage().activeCount)
            val unknown = first.copy(executionStarted = true, reconcile = true, status = DirectWorkStatus.NeedsAttention)
            f.store.updateDirect(first, unknown); f.reopen()
            assertEquals(unknown, f.store.directWork(first.command.operation))
            capacity { f.store.saveSocialProposal(f.proposal()) }
            f.store.updateDirect(unknown, f.closed(unknown))
            f.store.updateDirect(second, f.closed(second))
            f.store.saveSocialProposal(f.proposal())
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun sqliteFailureAfterDomainWriteRollsBackBothReservationAndIntent() = runBlocking {
        val f = Fixture(OperationAdmissionLimits())
        try {
            f.inspect { it.execSQL("CREATE TRIGGER admission_test_abort BEFORE INSERT ON operation_reservations BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            val command = f.direct()
            try { f.store.prepareDirect(command); fail("injected transaction failure ignored") }
            catch (_: android.database.sqlite.SQLiteException) { }
            assertNull(f.store.directWork(command.operation)); assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            f.inspect { db ->
                assertEquals(0L, db.compileStatement("SELECT COUNT(*) FROM operation_reservation_dirty").use { it.simpleQueryForLong() })
                db.execSQL("DROP TRIGGER admission_test_abort")
            }
            f.store.prepareDirect(command); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun concurrentDomainAdmissionsCannotBothSpendLastSlot() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val admitted = coroutineScope {
                listOf(async { runCatching { f.store.prepareDirect(f.direct()) } },
                    async { runCatching { f.store.saveSocialProposal(f.proposal()) } }).map { it.await() }
            }
            assertEquals(1, admitted.count { it.isSuccess })
            assertTrue(admitted.single { it.isFailure }.exceptionOrNull() is OperationCapacityExceeded)
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }
}
