package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.collections.immutable.persistentMapOf
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ReadAdmissionStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture(val limits: OperationAdmissionLimits = OperationAdmissionLimits()) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id())
        val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device, operationLimits = limits)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device, operationLimits = limits) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
        suspend fun read(room: RoomId = RoomId(id()), sequence: Long = 7): ReadWork {
            assertTrue(store.enqueueRead(room, sequence)); store.prepareReads()
            return store.readWorks().single { it.command.room == room && it.command.sequence == sequence }
        }
        suspend fun archive(work: ReadWork) {
            val pending = work.copy(submissionStarted = true, reconcile = true, status = ReadStatus.NeedsAttention, reason = "currentUnavailable:permissionDenied")
            store.updateRead(work, pending); store.archiveRead(work.command.operation, 1_000)
        }
        suspend fun confirmed(work: ReadWork) {
            store.updateRead(work, work.copy(submissionStarted = true, status = ReadStatus.Confirmed,
                watermark = ReadWatermark(work.command.room, actor, work.command.sequence, 2_000), originalReceipt = false))
        }
    }
    private suspend fun capacity(body: suspend () -> Unit) {
        try { body(); fail("capacity exceeded without rollback") } catch (_: OperationCapacityExceeded) { }
    }

    @Test fun readIntentSharesOrdinaryQuotaAndFreezesWithoutDoubleReservation() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(2, 1_000_000))
        try {
            val proposal = SocialProposal(id(), f.actor, UserId(id()), SocialAction.Request)
            f.store.saveSocialProposal(proposal)
            val room = RoomId(id()); f.store.enqueueRead(room, 8); f.store.enqueueRead(room, 9)
            val before = f.store.operationAdmissionUsage()
            capacity { f.store.enqueueRead(RoomId(id()), 1) }
            f.store.prepareReads(); val work = f.store.readWorks().single()
            assertEquals(9L, work.command.sequence); assertEquals(before, f.store.operationAdmissionUsage())
            f.reopen(); assertEquals(before, f.store.operationAdmissionUsage())
            f.confirmed(work)
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            f.store.discardSocialProposal(proposal.id)
            assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
        } finally { f.close() }
    }

    @Test fun controlQueryCannotSubmitUntilAnotherDomainReleasesOrdinaryCapacity() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val room = RoomId(id())
            f.store.reconcileDirectory(persistentMapOf(room to RoomKind.Direct))
            f.store.acceptState(room, RoomSyncState.newBuilder().setHead(20).setViewerMembershipRevision(1).build())
            val original = f.read(room); f.archive(original)
            val proposal = f.store.saveSocialProposal(SocialProposal(id(), f.actor, UserId(id()), SocialAction.Request))
            f.store.restoreRead(original.command.operation, 1_000); f.reopen()
            var now = 1_000L; var queries = 0; var submissions = 0
            val remote = object : ReadReceiptTransport {
                override suspend fun recover(command: ReadCommand): ReadResult { assertEquals(original.command, command); queries++; return ReadResult.Unresolved }
                override suspend fun submit(command: ReadCommand): ReadResult.Confirmed {
                    assertEquals(original.command, command); submissions++
                    return ReadResult.Confirmed(ReadWatermark(room, f.actor, 7, now), true)
                }
            }
            val service = ReadReceiptService(f.actor, remote, f.store, { now }, { now })
            service.flush()
            var saved = requireNotNull(f.store.readWork(original.command.operation))
            assertEquals("controlCapacityRequired", saved.reason); assertTrue(saved.control)
            assertEquals(ReadStatus.NeedsAttention, saved.status); assertEquals(1, queries); assertEquals(0, submissions)
            assertEquals(1L, f.store.operationAdmissionUsage().controlCount)
            f.store.discardSocialProposal(proposal.id)
            now = saved.nextAttempt
            service.retry(saved.command.operation); service.flush()
            saved = requireNotNull(f.store.readWork(saved.command.operation))
            assertFalse(saved.control); assertFalse(saved.reconcile); assertEquals(original.command, saved.command)
            assertEquals(0L, f.store.operationAdmissionUsage().controlCount); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            now = saved.nextAttempt; service.flush()
            assertEquals(2, queries); assertEquals(1, submissions)
            assertEquals(ReadStatus.Confirmed, f.store.readWork(saved.command.operation)?.status)
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun controlByteLimitLeavesArchiveUntouchedAndConfirmationReleasesControlCredit() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val archived = buildList {
                repeat(16) { val work = f.read(); f.archive(work); add(work) }
            }
            archived.take(15).forEach { f.store.restoreRead(it.command.operation, 2_000) }
            val before = f.store.operationAdmissionUsage()
            assertEquals(0L, before.activeCount); assertEquals(15L, before.controlCount)
            assertTrue(before.controlReservedBytes <= 1_048_576)
            capacity { f.store.restoreRead(archived.last().command.operation, 2_000) }
            assertEquals(ReadStatus.Archived, f.store.readWork(archived.last().command.operation)?.status)
            assertEquals(before, f.store.operationAdmissionUsage()); f.reopen()
            assertEquals(before, f.store.operationAdmissionUsage())
            f.confirmed(requireNotNull(f.store.readWork(archived.first().command.operation)))
            f.store.restoreRead(archived.last().command.operation, 3_000)
            assertEquals(15L, f.store.operationAdmissionUsage().controlCount)
        } finally { f.close() }
    }

    @Test fun restoredControlKeepsSuccessorIntentFrozenUntilOriginalFinishes() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val first = f.read(); f.archive(first); f.store.restoreRead(first.command.operation, 2_000)
            f.store.enqueueRead(first.command.room, 10); f.store.prepareReads()
            assertEquals(1, f.store.readWorks().size)
            assertEquals(10L, f.store.roomReadWatermarks(persistentListOf(first.command.room))[first.command.room])
            val before = f.store.operationAdmissionUsage()
            assertEquals(1L, before.activeCount); assertEquals(1L, before.controlCount)
            f.confirmed(requireNotNull(f.store.readWork(first.command.operation)))
            f.store.prepareReads(); assertEquals(2, f.store.readWorks().size)
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount); assertEquals(0L, f.store.operationAdmissionUsage().controlCount)
        } finally { f.close() }
    }

    @Test fun byteGrowthOfCoalescedIntentRollsBackItsReadingWatermark() = runBlocking {
        val dummy = "00000000-0000-0000-0000-000000000000"
        val size = ReadCommand(UserId(dummy), RoomId(dummy), dummy, 9).payload().toString().toByteArray().size.toLong()
        val f = Fixture(OperationAdmissionLimits(2, size))
        try {
            val room = RoomId(id()); f.store.enqueueRead(room, 9)
            capacity { f.store.enqueueRead(room, 10) }
            assertEquals(9L, f.store.roomReadWatermarks(persistentListOf(room))[room])
            f.store.prepareReads(); assertEquals(9L, f.store.readWorks().single().command.sequence)
            assertEquals(size, f.store.operationAdmissionUsage().reservedBytes)
        } finally { f.close() }
    }

    @Test fun oldSinglePoolSchemaMigratesBothReadPoolsWithoutChangingCommands() = runBlocking {
        val f = Fixture()
        try {
            val control = f.read(); f.archive(control); f.store.restoreRead(control.command.operation, 2_000)
            val ordinary = f.read(); val before = f.store.operationAdmissionUsage()
            f.store.close()
            SQLiteDatabase.openDatabase(f.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("ALTER TABLE operation_reservations RENAME TO newer_reservations")
                db.execSQL("CREATE TABLE operation_reservations(source TEXT NOT NULL,id TEXT NOT NULL,bytes INTEGER NOT NULL,PRIMARY KEY(source,id))")
                db.execSQL("INSERT INTO operation_reservations SELECT source,id,bytes FROM newer_reservations WHERE source NOT IN ('read_operations','read_intents')")
                db.execSQL("DROP TABLE newer_reservations")
                db.execSQL("DELETE FROM operation_reservation_versions WHERE source IN ('read_operations','read_intents')")
            }
            f.reopen()
            assertEquals(before, f.store.operationAdmissionUsage())
            assertEquals(control.command, f.store.readWork(control.command.operation)?.command)
            assertEquals(ordinary, f.store.readWork(ordinary.command.operation))
        } finally { f.close() }
    }
}
