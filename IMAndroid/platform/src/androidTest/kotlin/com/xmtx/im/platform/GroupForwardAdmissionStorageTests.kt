package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class GroupForwardAdmissionStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture(var limits: OperationAdmissionLimits = OperationAdmissionLimits()) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id())
        val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device, operationLimits = limits)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device, operationLimits = limits) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
        fun group(members: Int = 1) = GroupCreationCommand.create(actor, "测试群", (1..members).map { UserId(id()) }.toPersistentList(), 1_000)
        fun forward() = ForwardCommand(actor, id(), persistentListOf(ForwardSource(RoomId(id()), MessageId(id()), 1)), persistentListOf(RoomId(id())), 601_000)
        fun closed(work: GroupCreationWork) = work.copy(status = GroupCreationStatus.Closed, receipt = buildJsonObject {
            put("identity", work.command.identity())
            put("fingerprint", buildJsonObject { put("version", 1); put("digest", work.command.fingerprint) })
            put("resolvedAtMilliseconds", 2_000); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
        }.toString())
    }
    private suspend fun capacity(body: suspend () -> Unit) {
        try { body(); fail("over-capacity command admitted") } catch (_: OperationCapacityExceeded) { }
    }

    @Test fun largeAudienceReservesEncodedMembersAndPendingCancellationDoesNotReleaseIt() = runBlocking {
        val f = Fixture()
        try {
            val command = f.group(513); val work = f.store.prepareGroup(command)
            val audience = JsonArray(command.members.map { buildJsonObject { put("rawValue", it.value) } })
            val expected = command.payload().toString().toByteArray().size.toLong() + audience.toString().toByteArray().size + 4_096 + 65_536
            val before = f.store.operationAdmissionUsage()
            assertEquals(expected, before.reservedBytes); assertEquals(1L, before.activeCount)
            assertEquals(work, f.store.prepareGroup(command.copy(operation = id())))
            val unknown = work.copy(status = GroupCreationStatus.NeedsAttention, cancellationRequested = true, reconcile = true, retryRequired = true)
            f.store.updateGroup(work, unknown); f.reopen()
            assertEquals(unknown, f.store.groupWork(command.operation)); assertEquals(before, f.store.operationAdmissionUsage())
            f.store.updateGroup(unknown, f.closed(unknown))
            assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
        } finally { f.close() }
    }

    @Test fun forwardReservesProgressBeforeIoAndSharesCapacityWithGroupCreation() = runBlocking {
        val f = Fixture()
        try {
            val command = f.forward()
            val bytes = command.payload().toString().toByteArray().size.toLong() + 1_048_576 + 65_536
            f.limits = OperationAdmissionLimits(100, bytes); f.reopen()
            val work = f.store.enqueueForward(command)
            assertEquals(bytes, f.store.operationAdmissionUsage().reservedBytes)
            assertEquals(work, f.store.enqueueForward(command.copy(operation = id())))
            val group = f.group()
            capacity { f.store.prepareGroup(group) }; assertNull(f.store.groupWork(group.operation))
            f.store.updateForward(work, work.copy(status = ForwardStatus.Cancelled, cancelRequested = true))
            assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
            f.store.prepareGroup(group); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun uncertainForwardCannotFreeItsCreditByRequestingCancellation() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 2_000_000))
        try {
            val work = f.store.enqueueForward(f.forward())
            val unknown = work.copy(status = ForwardStatus.NeedsAttention, submissionStarted = true, reconcile = true, cancelRequested = true)
            f.store.updateForward(work, unknown); val before = f.store.operationAdmissionUsage(); f.reopen()
            assertEquals(unknown, f.store.forwardWork(work.command.operation))
            assertEquals(before, f.store.operationAdmissionUsage())
            capacity { f.store.prepareGroup(f.group()) }
            try { f.store.updateForward(unknown, unknown.copy(status = ForwardStatus.Cancelled)); fail("uncertain result discarded") }
            catch (_: IllegalArgumentException) { }
            assertEquals(before, f.store.operationAdmissionUsage())
        } finally { f.close() }
    }

    @Test fun migrationRestoresExistingGroupAndForwardReservationsEvenWhenAlreadyOverLimit() = runBlocking {
        val f = Fixture()
        try {
            val group = f.store.prepareGroup(f.group()); val forward = f.store.enqueueForward(f.forward())
            val before = f.store.operationAdmissionUsage(); f.store.close()
            SQLiteDatabase.openDatabase(f.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("DELETE FROM operation_reservations WHERE source IN ('group_creations','forward_operations')")
                db.execSQL("DELETE FROM operation_reservation_versions WHERE source IN ('group_creations','forward_operations')")
            }
            f.limits = OperationAdmissionLimits(1, 80_000); f.reopen()
            assertEquals(before, f.store.operationAdmissionUsage())
            val unknown = forward.copy(status = ForwardStatus.NeedsAttention, submissionStarted = true, reconcile = true)
            f.store.updateForward(forward, unknown); f.store.updateGroup(group, f.closed(group))
            capacity { f.store.saveSocialProposal(SocialProposal(id(), f.actor, UserId(id()), SocialAction.Request)) }
            assertEquals(unknown, f.store.forwardWork(forward.command.operation))
        } finally { f.close() }
    }
}
