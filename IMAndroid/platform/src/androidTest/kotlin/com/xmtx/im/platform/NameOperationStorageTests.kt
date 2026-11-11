package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class NameOperationStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private val actor = UserId(id());private val device = DeviceId(id());private val target = NameTarget.Contact(UserId(id()))
    private fun store() = SqliteClientStore(InstrumentationRegistry.getInstrumentation().targetContext,actor,device)
    private suspend fun aliasFloor(store: SqliteClientStore,revision: Long) {
        val cursor = store.cursor();store.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("next")
            .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind("contact_alias").setUserSyncSequence(cursor.sequence+1)
                .setPayload(ByteString.copyFromUtf8(buildJsonObject { put("target_user_id",target.user.value);put("revision",revision) }.toString()))).build(),cursor)
    }
    @Test fun baselinesRejectEqualVersionConflictsAndSyncFloorsHideStaleEditableFields() = runBlocking {
        var store = store();try {
            val value = NameSnapshot(actor,target,"私人备注",2);val original = store.snapshot().presentationGeneration
            assertEquals(value,store.saveNameSnapshot(value));assertNotEquals(original,store.snapshot().presentationGeneration)
            assertEquals(value,store.saveNameSnapshot(value.copy(name = "旧",revision = 1)))
            try { store.saveNameSnapshot(value.copy(name = "冲突"));fail() } catch(_: IllegalArgumentException) { }
            aliasFloor(store,3);assertTrue(store.snapshot().nameSnapshots.isEmpty());assertNull(store.saveNameSnapshot(value))
            try { store.enqueueName(NameCommand(actor,target,id(),"新",2,100000));fail() } catch(_: IllegalArgumentException) { }
            store.close();store = store();assertTrue(store.snapshot().nameSnapshots.isEmpty())
            val fresh = value.copy(name = null,revision = 3);assertEquals(fresh,store.saveNameSnapshot(fresh))
            assertEquals(fresh,store.snapshot().nameSnapshots.single())
            assertEquals(3L,store.profileFences(persistentListOf(ProfileKey(target.user,ProfileContext.Relationship))).floors.values.single().aliasRevision)
        } finally { store.close() }
    }
    @Test fun frozenCommandsSurviveReopenAndUpdatesRequireOriginalIdentity() = runBlocking {
        var store = store();try {
            val baseline = NameSnapshot(actor,target,null,null);store.saveNameSnapshot(baseline)
            val command = NameCommand(actor,target,id(),"备注",null,100000);val queued = store.enqueueName(command)
            try { store.enqueueName(command.copy(operation = id()));fail() } catch(_: IllegalStateException) { }
            val uncertain = queued.copy(submissionStarted = true,reconcile = true,attempts = 1,roundStarted = 1000)
            store.updateName(queued,uncertain);store.close();store = store();assertEquals(uncertain,store.nameWorks().single())
            assertEquals(uncertain,store.nameWork(command.operation));assertNull(store.nameWork(id()))
            try { store.updateName(uncertain,uncertain.copy(command = command.copy(name = "其他")));fail() } catch(_: IllegalArgumentException) { }
            try { store.updateName(uncertain,uncertain.copy(status = NameStatus.Cancelled));fail() } catch(_: IllegalArgumentException) { }
            val closing = uncertain.copy(closeRequested = true);store.updateName(uncertain,closing)
            try { store.updateName(closing,uncertain);fail() } catch(_: IllegalArgumentException) { }
            assertEquals(closing,store.nameWorks().single())
        } finally { store.close() }
    }
    @Test fun onlyVerifiedReceiptCommitsOwnFieldAndInvalidatesDisplayGeneration() = runBlocking {
        val store = store();try {
            store.saveNameSnapshot(NameSnapshot(actor,target,null,null))
            val command = NameCommand(actor,target,id(),"备注",null,100000);val queued = store.enqueueName(command)
            val work = queued.copy(submissionStarted = true,reconcile = true);store.updateName(queued,work)
            fun receipt(name: String) = buildJsonObject {
                put("unexpectedProfile","不得保存的未知资料");put("identity",command.identity());put("fingerprint",buildJsonObject { put("version",1);put("digest",command.fingerprint) });put("resolvedAtMilliseconds",1000)
                put("outcome",buildJsonObject { put("committed",buildJsonObject { put("_0",buildJsonObject {
                    put("ownerUserID",buildJsonObject { put("rawValue",actor.value) });put("targetUserID",buildJsonObject { put("rawValue",target.user.value) });put("remarkName",name);put("revision",1)
                }) }) })
            }.toString()
            try { store.updateName(work,work.copy(status = NameStatus.Committed,receipt = receipt("伪造")));fail() } catch(_: IllegalArgumentException) { }
            assertEquals(work,store.nameWorks().single());val generation = store.snapshot().presentationGeneration
            store.updateName(work,work.copy(status = NameStatus.Committed,receipt = receipt("备注")))
            assertFalse(store.nameWorks().single().receipt!!.contains("不得保存"));assertEquals("备注",store.snapshot().nameSnapshots.single().name);assertNotEquals(generation,store.snapshot().presentationGeneration)
        } finally { store.close() }
    }
}
