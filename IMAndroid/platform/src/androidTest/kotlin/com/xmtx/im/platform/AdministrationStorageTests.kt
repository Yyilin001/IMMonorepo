package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class AdministrationStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB");private val target = UserId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val device = DeviceId(UUID.randomUUID().toString())
    private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context,actor,device)
    private fun intent() = AdministrationIntent(actor,room,"10000000-0000-0000-0000-000000000001",target,AdministrationAction.Mute(200000),"ADMIN_ACTION",7,116000)
    @Test fun draftReplacementKeepsOriginalMuteExpiryAndFloorWithPerTargetOrdering() = runBlocking {
        var store = store()
        try {
            val draft = store.prepareAdministration(intent(),"old");val paused = draft.copy(status = AdministrationStatus.DraftPaused,nextAttempt = 90000)
            store.updateAdministration(draft,paused);store.close();store = store()
            try { store.prepareAdministration(intent().copy(operation = id(),action = AdministrationAction.Remove),"new");fail("parallel target administration") } catch(_: IllegalStateException) { }
            try { store.replaceAdministrationDraft(paused,intent().copy(operation = id(),action = AdministrationAction.Mute(300000)),"new");fail("mute extended implicitly") } catch(_: IllegalArgumentException) { }
            val renewed = store.replaceAdministrationDraft(paused,intent().copy(operation = id(),revision = 8,deadline = 200000),"new")
            assertEquals(90000L,renewed.nextAttempt);assertEquals(intent().action,renewed.intent.action)
            assertEquals(AdministrationStatus.DraftCancelled,store.administrationWorks().first().status)
            try { store.updateAdministration(paused,paused.copy(status = AdministrationStatus.DraftCancelled));fail("stale writer") } catch(_: IllegalStateException) { }
            store.prepareAdministration(intent().copy(operation = id(),target = UserId(id())),"independent")
            assertEquals(2,store.administrationWorks().count { !it.terminal })
        } finally { store.close() }
    }
    @Test fun frozenAdmissionAndTerminalProofSurviveReopenWithoutProjectingMute() = runBlocking {
        var store = store()
        try {
            val intent = intent();val draft = store.prepareAdministration(intent,"activation")
            val admission = AdministrationAdmission("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",intent.fingerprint,7,3,2000,110000)
            val pending = draft.copy(executionStarted = true,admission = admission,status = AdministrationStatus.Pending,submissionStarted = true,reconcile = true)
            store.updateAdministration(draft,pending);store.close();store = store()
            try { store.updateAdministration(pending, pending.copy(executionStarted = false)); fail("erased execution evidence") } catch (_: IllegalArgumentException) { }
            try { store.updateAdministration(pending,pending.copy(admission = admission.copy(joined = 4)));fail("new admission") } catch(_: IllegalArgumentException) { }
            try { store.updateAdministration(pending,pending.copy(submissionStarted = false));fail("uncertainty erased") } catch(_: IllegalArgumentException) { }
            try { store.updateAdministration(pending,pending.copy(status = AdministrationStatus.Committed));fail("unproven terminal") } catch(_: IllegalArgumentException) { }
            val lines = InstrumentationRegistry.getInstrumentation().context.assets.open("member-administration-swift.txt").bufferedReader().use { it.readLines() }
            val value = Json.parseToJsonElement(lines[5]).jsonObject.getValue("receipt").jsonObject.getValue("_0").jsonObject
            val receipt = AdministrationClient.decodeReceipt(pending.command(),value)
            val finished = pending.copy(status = receipt.status,receipt = receipt.wire)
            store.updateAdministration(pending,finished);store.close();store = store()
            assertEquals(finished,store.snapshot().administrationOperations.single());assertTrue(store.snapshot().moderationFacts.isEmpty())
            try { store.updateAdministration(finished,pending);fail("terminal work reopened") } catch(_: IllegalArgumentException) { }
        } finally { store.close() }
    }
    @Test fun roomMuteFactsValidateIdentityTimeAndPrivacyThenPurgeOnRevocation() = runBlocking {
        var store = store();val source = id()
        try {
            store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
            fun body(sequence: Long = 1,until: Long = 200000) = buildJsonObject {
                put("event_type","member.muted");put("room_id",room.value);put("room_sequence",sequence);put("actor_user_id",actor.value);put("target_user_id",target.value)
                put("mute_until_ms",until);put("server_created_at_ms",1000);put("private_audit","must-not-persist")
            }
            suspend fun apply(sequence: Long,value: JsonObject,event: String = source) = store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence)
                .addEvents(GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId(event).setProjectionKind("moderation").setPayload(ByteString.copyFromUtf8(value.toString()))).build(),store.roomCursor(room))
            try { apply(1,body(until = 1000));fail("invalid mute expiry") } catch(_: ClientFailure.Protocol) { }
            assertEquals(0L,store.roomCursor(room).sequence)
            apply(1,body());store.close();store = store();assertEquals(200000L,store.snapshot().moderationFacts.single().until)
            try { apply(2,body(2,300000));fail("source identity reused") } catch(_: ClientFailure.Protocol) { }
            assertEquals(1L,store.roomCursor(room).sequence)
            val digest = MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
            SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery("SELECT count(*) FROM records WHERE kind='moderation'",null).use { it.moveToFirst();assertEquals(0,it.getInt(0)) }
                db.rawQuery("SELECT effect FROM moderation_facts",null).use { it.moveToFirst();assertFalse(it.getString(0).contains("must-not-persist")) }
            }
            store.unavailable(room);assertTrue(store.snapshot().moderationFacts.isEmpty())
        } finally { store.close() }
    }
}
