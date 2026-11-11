package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class OwnProfileStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private val actor = UserId(id());private val device = DeviceId(id())
    private fun store() = SqliteClientStore(InstrumentationRegistry.getInstrumentation().targetContext,actor,device)
    private fun profile(revision: Long = 3,name: String = "原名称") = ProfileView(actor,PublicIdentity(actor,PublicHandle("own_account"),name,AccountKind.Regular),null,ProfileState.Active,revision,revision+2)
    private fun command() = OwnProfileCommand(actor,id(),3,OwnProfilePatch("新名称"),1700000000000)
    private fun result(command: OwnProfileCommand,current: ProfileView? = profile(5,"另一设备"),revision: Long = 4) = buildJsonObject {
        put("unknown","不可保存")
        put("receipt",buildJsonObject {
            put("actorUserID",buildJsonObject { put("rawValue",actor.value) });put("operationID",buildJsonObject { put("rawValue",command.operation) })
            put("fingerprint",buildJsonObject { put("version",1);put("digest",command.fingerprint) });put("resolvedAtMilliseconds",1000)
            put("outcome",buildJsonObject { put("committed",buildJsonObject { put("revision",revision);put("visibilityRevision",revision+2) }) })
        });current?.let { put("currentSnapshot",OwnProfileClient.profilePayload(it)) }
    }.toString()
    @Test fun ownSnapshotIsMonotonicRejectsEqualVersionConflictsAndHonorsSecurityFloor() = runBlocking {
        var store = store();try {
            val value = profile(5);assertEquals(value,store.saveOwnProfile(value));assertEquals(value,store.saveOwnProfile(profile(3)))
            for(invalid in listOf(value.copy(identity = value.identity!!.copy(displayName = "冲突")),profile(6).copy(visibilityRevision = 6),profile(3).copy(visibilityRevision = 8))) {
                try { store.saveOwnProfile(invalid);fail() } catch(_: IllegalArgumentException) { }
            }
            val cursor = store.cursor();store.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("next")
                .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setUserSyncSequence(cursor.sequence+1).setProjectionKind("profile_invalidation")
                    .setPayload(ByteString.copyFromUtf8(buildJsonObject { put("user_id",actor.value);put("minimum_profile_revision",5);put("profile_state","hidden") }.toString()))).build(),cursor)
            assertNull(store.ownProfile());store.close();store = store();assertNull(store.snapshot().ownProfile)
            assertEquals(profile(6),store.saveOwnProfile(profile(6)))
        } finally { store.close() }
    }
    @Test fun originalReceiptAndNewerCurrentSnapshotSurviveReopenWithoutRevertingName() = runBlocking {
        var store = store();try {
            store.saveOwnProfile(profile());val command = command();val queued = store.enqueueOwnProfile(command)
            val uncertain = queued.copy(submissionStarted = true,reconcile = true,attempts = 1);store.updateOwnProfile(queued,uncertain)
            store.close();store = store();assertEquals(uncertain,store.ownProfileWorks().single())
            assertEquals(uncertain,store.ownProfileWork(command.operation));assertNull(store.ownProfileWork(id()))
            val wire = result(command);val completed = uncertain.copy(status = OwnProfileStatus.Committed,receipt = wire,draftRetained = false)
            store.updateOwnProfile(uncertain,completed)
            val saved = store.ownProfileWorks().single();assertFalse(saved.receipt!!.contains("不可保存"));assertEquals(4L,OwnProfileClient.decodeResult(command,Json.parseToJsonElement(saved.receipt!!).jsonObject).revision)
            assertEquals(profile(5,"另一设备"),store.ownProfile());store.saveOwnProfile(profile(4,"新名称"));assertEquals("另一设备",store.ownProfile()!!.identity!!.displayName)
            store.close();store = store();assertEquals(5L,store.ownProfile()!!.revision)
        } finally { store.close() }
    }
    @Test fun corruptCommitRollsBackAndReceiptWithoutSnapshotHidesOlderBase() = runBlocking {
        val store = store();try {
            store.saveOwnProfile(profile());val command = command();val queued = store.enqueueOwnProfile(command)
            val uncertain = queued.copy(submissionStarted = true,reconcile = true);store.updateOwnProfile(queued,uncertain)
            try { store.updateOwnProfile(uncertain,uncertain.copy(status = OwnProfileStatus.Committed,receipt = result(command,profile(4,"错误正文")),draftRetained = false));fail() } catch(_: IllegalArgumentException) { }
            assertEquals(uncertain,store.ownProfileWorks().single());assertEquals(profile(),store.ownProfile())
            store.updateOwnProfile(uncertain,uncertain.copy(status = OwnProfileStatus.Committed,receipt = result(command,null),draftRetained = false))
            assertNull(store.ownProfile());assertEquals(profile(4,"新名称"),store.saveOwnProfile(profile(4,"新名称")))
        } finally { store.close() }
    }
    @Test fun queueKeepsFrozenRevisionAndReapplicationAtomicallyReleasesOnlyTerminalDraft() = runBlocking {
        val store = store();try {
            store.saveOwnProfile(profile());val first = store.enqueueOwnProfile(command());val second = store.enqueueOwnProfile(command().copy(patch = OwnProfilePatch("另一个选择")))
            assertEquals(listOf(first,second),store.ownProfileWorks())
            try { store.discardOwnProfileDraft(first.command.operation);fail() } catch(_: IllegalArgumentException) { }
            try { store.enqueueOwnProfile(first.command.copy(operation = id()),first.command.operation);fail() } catch(_: IllegalArgumentException) { }
            val expired = first.copy(status = OwnProfileStatus.Expired,reason = "expiredUnsubmitted");store.updateOwnProfile(first,expired)
            store.saveOwnProfile(profile(5,"当前名称"))
            val replacement = store.enqueueOwnProfile(first.command.copy(operation = id(),revision = 5),first.command.operation)
            assertFalse(store.ownProfileWorks().first().draftRetained);assertEquals(3L,store.ownProfileWorks()[1].command.revision);assertEquals(5L,replacement.command.revision)
        } finally { store.close() }
    }
}
