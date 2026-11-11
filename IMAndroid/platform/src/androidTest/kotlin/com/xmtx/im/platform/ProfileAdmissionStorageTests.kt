package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class ProfileAdmissionStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture(var limits: OperationAdmissionLimits = OperationAdmissionLimits()) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device, operationLimits = limits)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device, operationLimits = limits) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
        fun database(body: (SQLiteDatabase) -> Unit) = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(body)
        suspend fun baseline() { store.saveOwnProfile(ProfileView(actor, PublicIdentity(actor, PublicHandle("admission_profile"), "原名称", AccountKind.Regular), null, ProfileState.Active, 1, 1)) }
        fun profile() = OwnProfileCommand(actor, id(), 1, OwnProfilePatch("资料修改"), 86_401_000)
        fun intent() = ProfileIntent(id(), actor, id(), 1, 86_401_000, name = "资料修改")
        suspend fun name(group: Boolean = false): NameWork {
            val target = if (group) NameTarget.Group(RoomId(id())) else NameTarget.Contact(UserId(id()))
            store.saveNameSnapshot(NameSnapshot(actor, target, null, null))
            return store.enqueueName(NameCommand(actor, target, id(), "私人名称", null, 86_401_000))
        }
    }
    private suspend fun capacity(body: suspend () -> Unit) {
        try { body(); fail("over-capacity operation admitted") } catch (_: OperationCapacityExceeded) { }
    }
    private suspend fun invalid(body: suspend () -> Unit) {
        try { body(); fail("unknown outcome discarded") } catch (_: IllegalArgumentException) { }
    }
    private fun closed(command: OwnProfileCommand) = buildJsonObject {
        put("receipt", buildJsonObject {
            put("actorUserID", buildJsonObject { put("rawValue", command.actor.value) })
            put("operationID", buildJsonObject { put("rawValue", command.operation) })
            put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) })
            put("resolvedAtMilliseconds", 2_000); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
        })
    }.toString()

    @Test fun preparationTransfersFullCountAndBytesToFrozenProfileAlongsideNameWork() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(2, 1_000_000))
        try {
            f.baseline(); val name = f.name(); val intent = f.intent()
            f.store.enqueueProfileIntent(intent, 1_000)
            val before = f.store.operationAdmissionUsage()
            f.limits = OperationAdmissionLimits(2, before.reservedBytes); f.reopen()
            capacity { f.store.enqueueConversation(f.room, ConversationPatch(pinned = true), 2_000) }
            f.store.advanceProfileIntents(2_000)
            val frozen = f.store.profileIntents().single().intent; val work = f.store.ownProfileWorks().single()
            assertEquals(intent.copy(frozen = true), frozen); assertEquals(frozen.command(), work.command)
            val expected = maxOf(Json.encodeToString(frozen).toByteArray().size, Json.encodeToString(work.command).toByteArray().size).toLong() +
                Json.encodeToString(name.command).toByteArray().size
            assertEquals(2L, f.store.operationAdmissionUsage().activeCount); assertEquals(expected, f.store.operationAdmissionUsage().reservedBytes)
            assertTrue(expected <= before.reservedBytes); f.reopen()
            assertEquals(work, f.store.ownProfileWork(intent.operation)); assertEquals(expected, f.store.operationAdmissionUsage().reservedBytes)
        } finally { f.close() }
    }

    @Test fun unknownNameAndProfileKeepCreditUntilVerifiedClosedReceipts() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(2, 1_000_000))
        try {
            f.baseline(); val queuedName = f.name(group = true)
            val name = queuedName.copy(submissionStarted = true, reconcile = true, status = NameStatus.NeedsAttention)
            f.store.updateName(queuedName, name)
            val intent = f.intent(); f.store.enqueueProfileIntent(intent, 1_000); f.store.advanceProfileIntents(2_000)
            val queued = f.store.ownProfileWorks().single()
            val unknown = queued.copy(submissionStarted = true, reconcile = true, status = OwnProfileStatus.NeedsAttention)
            f.store.updateOwnProfile(queued, unknown); val before = f.store.operationAdmissionUsage(); f.reopen()
            invalid { f.store.discardProfileIntent(intent.id) }
            invalid { f.store.updateName(name, name.copy(status = NameStatus.Cancelled)) }
            invalid { f.store.updateOwnProfile(unknown, unknown.copy(status = OwnProfileStatus.Expired)) }
            assertEquals(before, f.store.operationAdmissionUsage())
            capacity { f.name() }
            val receipt = buildJsonObject {
                put("identity", name.command.identity())
                put("fingerprint", buildJsonObject { put("version", 1); put("digest", name.command.fingerprint) })
                put("resolvedAtMilliseconds", 3_000); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
            }.toString()
            f.store.updateName(name, name.copy(status = NameStatus.Closed, receipt = receipt))
            f.store.updateOwnProfile(unknown, unknown.copy(status = OwnProfileStatus.Closed, receipt = closed(unknown.command)))
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            assertTrue(f.store.profileIntents().single().sourceRetained)
            assertTrue(f.store.ownProfileWorks().single().draftRetained)
        } finally { f.close() }
    }

    @Test fun byteOverflowRollsBackAvatarSourceAdoption() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(100, 1))
        val files = ManagedResourceFiles(f.context, f.store)
        val root = File(f.context.noBackupFilesDir, "resources-${f.store.resourceScope}")
        val original = File.createTempFile("profile-admission-", ".png", f.context.cacheDir)
        try {
            f.baseline()
            val bitmap = android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888)
            try { original.outputStream().use { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) } }
            finally { bitmap.recycle() }
            val asset = files.importFile(original, "头像.png", "image/png", ResourceUsage.UserAvatar, 1_024)
            val source = ProfileAvatarUpload(id(), asset.id, asset.displayName, asset.contentType, asset.byteCount)
            val intent = f.intent().copy(upload = source)
            capacity { f.store.enqueueProfileIntent(intent, 1_000) }
            assertTrue(f.store.profileIntents().isEmpty()); assertTrue(f.store.resourceUploads().isEmpty())
            assertEquals(listOf(asset.id), files.selected(ResourceUsage.UserAvatar).map { it.id })
            assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
            capacity { f.store.enqueueOwnProfile(f.profile()) }; assertTrue(f.store.ownProfileWorks().isEmpty())
        } finally { files.close(); f.close(); original.delete(); root.deleteRecursively() }
    }

    @Test fun sharedQuotaReplacesIndependentNameAndProfileQueueCeilings() = runBlocking {
        val names = Fixture(OperationAdmissionLimits(65, 1_000_000))
        try {
            repeat(65) { names.name(group = it % 2 == 0) }
            assertEquals(65L, names.store.operationAdmissionUsage().activeCount)
            capacity { names.name() }; names.reopen(); assertEquals(65, names.store.nameWorks().size)
        } finally { names.close() }
        val profiles = Fixture(OperationAdmissionLimits(17, 1_000_000))
        try {
            profiles.baseline(); repeat(17) { profiles.store.enqueueProfileIntent(profiles.intent(), 1_000) }
            assertEquals(17L, profiles.store.operationAdmissionUsage().activeCount)
            capacity { profiles.store.enqueueProfileIntent(profiles.intent(), 1_000) }
            profiles.reopen(); assertEquals(17, profiles.store.profileIntents().size)
        } finally { profiles.close() }
    }

    @Test fun migrationPreservesOverLimitWorkAndAllowsTerminalReleaseAndHandoff() = runBlocking {
        val f = Fixture()
        try {
            f.baseline(); val own = f.store.enqueueOwnProfile(f.profile()); val name = f.name()
            val intent = f.intent(); f.store.enqueueProfileIntent(intent, 1_000)
            val before = f.store.operationAdmissionUsage()
            f.database {
                it.execSQL("DELETE FROM operation_reservations WHERE source IN ('own_profile_operations','name_operations','profile_intents')")
                it.execSQL("DELETE FROM operation_reservation_versions WHERE source IN ('own_profile_operations','name_operations','profile_intents')")
            }
            f.limits = OperationAdmissionLimits(1, 1); f.reopen(); assertEquals(before, f.store.operationAdmissionUsage())
            capacity { f.name() }
            f.store.updateName(name, name.copy(status = NameStatus.Cancelled))
            f.store.updateOwnProfile(own, own.copy(status = OwnProfileStatus.Expired))
            f.store.advanceProfileIntents(2_000)
            val frozen = requireNotNull(f.store.ownProfileWork(intent.operation))
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            assertEquals(intent.copy(frozen = true).command(), frozen.command)
            f.store.updateOwnProfile(frozen, frozen.copy(status = OwnProfileStatus.Expired))
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun directProfileUsesUtf8BytesAndARejectedReplacementLeavesRetainedDraftUntouched() = runBlocking {
        val f = Fixture()
        try {
            f.baseline(); val command = f.profile()
            val bytes = Json.encodeToString(command).toByteArray().size.toLong()
            f.limits = OperationAdmissionLimits(10, bytes); f.reopen()
            val work = f.store.enqueueOwnProfile(command)
            assertEquals(bytes, f.store.operationAdmissionUsage().reservedBytes)
            capacity { f.name() }
            val expired = work.copy(status = OwnProfileStatus.Expired)
            f.store.updateOwnProfile(work, expired)
            assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
            f.limits = OperationAdmissionLimits(10, 1); f.reopen()
            capacity { f.store.enqueueOwnProfile(command.copy(operation = id()), command.operation) }
            assertEquals(expired, f.store.ownProfileWorks().single())
            assertTrue(f.store.ownProfileWorks().single().draftRetained)
        } finally { f.close() }
    }
}
