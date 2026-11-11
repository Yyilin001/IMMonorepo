package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class InvitationStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val device = DeviceId(UUID.randomUUID().toString())
    private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context, actor, device)
    private val secret = InvitationSecret("A".repeat(43))
    private fun intent() = InvitationIntent(actor, room, id(), InvitationAction.Submit("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", secret.digest, "申请"), 116000)
    @Test fun pausedDraftTransfersEncryptedReferenceAtomicallyAndRejectsStaleUpdates() = runBlocking {
        var store = store(); val secrets = KeystoreInvitationSecrets(context, "https://example.test", actor, device)
        val reference = id(); secrets.save(reference, actor, secret)
        try {
            val work = store.prepareInvitation(intent(), "old", reference)
            val paused = work.copy(status = InvitationStatus.DraftPaused, nextAttempt = 100000)
            store.updateInvitation(work, paused); store.close(); store = store()
            val replacement = store.replaceInvitationDraft(paused, paused.intent.copy(operation = id(), deadline = 200000), "new")
            assertEquals(reference, replacement.secretReference); assertEquals(100000L, replacement.nextAttempt)
            assertNull(store.invitationWorks().first().secretReference)
            assertEquals(InvitationStatus.DraftCancelled, store.invitationWorks().first().status)
            try { store.updateInvitation(paused, paused.copy(status = InvitationStatus.DraftCancelled)); fail("stale draft wrote") } catch(_: IllegalStateException) { }
            try { store.prepareInvitation(intent(), "another", id()); fail("parallel room mutation") } catch(_: IllegalStateException) { }
            assertEquals(secret, KeystoreInvitationSecrets(context, "https://example.test", actor, device).load(reference, actor))
            assertFalse(store.invitationWorks().toString().contains(secret.rawValue))
        } finally { store.close(); secrets.remove(reference, actor) }
    }
    @Test fun encryptedItemsAreBoundToServerAccountDeviceAndCannotBeRebound() = runBlocking {
        val secrets = KeystoreInvitationSecrets(context, "https://example.test", actor, device); val reference = id()
        try {
            secrets.save(reference, actor, secret); secrets.save(reference, actor, secret)
            val file = context.noBackupFilesDir.listFiles()!!.single { it.name.endsWith("-$reference.enc") }
            assertFalse(file.readText().contains(secret.rawValue))
            try { secrets.save(reference, actor, InvitationSecret("B".repeat(43))); fail("reference rebound") } catch(_: IllegalArgumentException) { }
            for(other in listOf(KeystoreInvitationSecrets(context, "https://other.test", actor, device),
                KeystoreInvitationSecrets(context, "https://example.test", actor, DeviceId(id())))) {
                try { other.load(reference, actor); fail("cross-binding secret read") } catch(_: InvitationSecretUnavailable) { }
            }
            val bytes = file.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); file.writeBytes(bytes)
            try { secrets.load(reference, actor); fail("corrupt ciphertext accepted") } catch(_: InvitationSecretUnavailable) { }
            assertArrayEquals(bytes, file.readBytes())
        } finally { secrets.remove(reference, actor) }
        try { secrets.load(reference, actor); fail("removed secret returned") } catch(_: InvitationSecretUnavailable) { }
    }
    @Test fun proofIsRequiredForTerminalRecordsAndNeverProjectsMembership() = runBlocking {
        var store = store()
        try {
            val intent = InvitationIntent(actor, room, "10000000-0000-0000-0000-000000000001", InvitationAction.Create(300,5,7),116000)
            val draft = store.prepareInvitation(intent, "activation", null)
            val admission = InvitationAdmission("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",intent.fingerprint,7,2000,110000)
            val pending = draft.copy(executionStarted = true,status = InvitationStatus.Pending, admission = admission, submissionStarted = true, reconcile = true)
            store.updateInvitation(draft, pending)
            try { store.updateInvitation(pending, pending.copy(executionStarted = false)); fail("erased execution evidence") } catch (_: IllegalArgumentException) { }
            try { store.updateInvitation(pending, pending.copy(intent = intent.copy(deadline = 200000))); fail("frozen identity changed") } catch(_: IllegalArgumentException) { }
            try { store.updateInvitation(pending, pending.copy(status = InvitationStatus.Committed)); fail("unproven receipt") } catch(_: IllegalArgumentException) { }
            val lines = InstrumentationRegistry.getInstrumentation().context.assets.open("invitations-swift.txt").bufferedReader().use { it.readLines() }
            val value = Json.parseToJsonElement(lines[4]).jsonObject.getValue("receipt").jsonObject.getValue("_0").jsonObject
            val receipt = InvitationClient.decodeReceipt(intent,value)
            store.updateInvitation(pending, pending.copy(status = receipt.status, receipt = receipt.wire))
            store.close(); store = store(); assertEquals(InvitationStatus.Committed, store.snapshot().invitationOperations.single().status)
            assertTrue(store.snapshot().conversations.isEmpty())
            try { store.updateInvitation(store.invitationWorks().single(), pending); fail("terminal receipt erased") } catch(_: IllegalArgumentException) { }
        } finally { store.close() }
    }
}
