package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class AccountPreferenceStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId(UUID.randomUUID().toString())
    private val device = DeviceId(UUID.randomUUID().toString())
    private fun store() = SqliteClientStore(context, actor, device)
    private fun id() = UUID.randomUUID().toString().uppercase()
    @Test fun serverDeadlineAndLocalAdmissionRemainDistinctAfterDatabaseReopen() = runBlocking {
        var store = store()
        var local = 1_000_000_000L
        val anchor = ServerTimeAnchor { 0L }.apply { observe(1_000) }
        var command: PreferenceCommand? = null
        var phase = 0
        val edge = object : AuthenticatedTransport {
            override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                return when (phase++) {
                    0 -> {
                        assertTrue(path.endsWith("/baseline"))
                        EdgeResponse(200, buildJsonObject {
                            put("ownerUserID", buildJsonObject { put("rawValue", actor.value) })
                            put("value", PreferenceValue(PreferenceKind.ReadReceipts, false, false).payload()); put("revision", 7)
                        })
                    }
                    1 -> {
                        assertTrue(path.endsWith("/submit")); assertEquals(command!!.payload(), payload)
                        throw java.io.IOException("lost response")
                    }
                    else -> {
                        assertTrue(path.endsWith("/recover")); assertEquals(command!!.recovery(true), payload)
                        EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
                    }
                }
            }
        }
        fun service() = AccountPreferenceService(actor, AccountPreferenceClient(edge, actor), store, { local }, { 0L }, anchor::now)
        try {
            val first = service()
            first.enqueue(PreferencePatch(PreferenceKind.ReadReceipts, first = true)); first.flush()
            command = requireNotNull(store.preferenceWorks().single().command)
            assertEquals(116_000L, command!!.deadline)
            assertEquals(1_000_115_000L, store.preferenceWorks().single().confirmedUntil)
            anchor.reset()
            store.close(); store = store()
            service().flush()
            assertEquals(command, store.preferenceWorks().single().command)
            assertTrue(store.preferenceWorks().single().reconcile)
            local += 120_000
            store.close(); store = store()
            service().flush()
            assertEquals(3, phase)
            assertEquals(command, store.preferenceWorks().single().command)
        } finally { store.close() }
    }
    @Test fun cancelledCommandKeepsRetryEvidenceAcrossDatabaseReopenAndManualRoundReset() = runBlocking {
        var store=store();var now=1000L;var calls=0
        val operation=id();val patch=PreferencePatch(PreferenceKind.StrangerMessages,first=true)
        val command=PreferenceCommand(actor,operation,PreferenceValue(PreferenceKind.StrangerMessages,true),7,116000)
        val edge=object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse {
                val intent=requireNotNull(currentCoroutineContext()[NetworkWorkIntent]);calls++
                assertEquals(calls>1,intent.isRetry)
                assertEquals(if(calls==1) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery,intent.priority)
                return when(calls) {
                    1->{assertTrue(path.endsWith("/submit"));throw CancellationException("fixture cancellation")}
                    2->{assertTrue(path.endsWith("/recover"));EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})}
                    else->{assertTrue(path.endsWith("/submit"));throw java.io.IOException("fixture lost reply")}
                }
            }
        }
        fun service()=AccountPreferenceService(actor,AccountPreferenceClient(edge,actor),store,{now},{now*1_000_000})
        try {
            val draft=store.preparePreference(PreferenceWork(actor,operation,patch,"test",116000))
            assertNull(draft.executionStarted)
            store.updatePreference(draft,draft.copy(command=command,status=PreferenceStatus.Pending,executionStarted=false))
            try {service().flush();fail("expected cancellation")} catch(_:CancellationException) {}
            store.close();store=store()
            var work=store.preferenceWorks().single();assertEquals(true,work.executionStarted);assertEquals(0,work.attempts)
            try {store.updatePreference(work,work.copy(executionStarted=false));fail("erased execution evidence")} catch(_:IllegalArgumentException) {}
            service().retry(operation);service().flush()
            work=store.preferenceWorks().single();assertFalse(work.reconcile);assertEquals(true,work.executionStarted)
            store.close();store=store();now=work.nextAttemptMilliseconds
            service().retry(operation);assertEquals(0,store.preferenceWorks().single().attempts);service().flush()
            assertEquals(3,calls);assertEquals(command,store.preferenceWorks().single().command)
            assertEquals(true,store.preferenceWorks().single().executionStarted)
        } finally {store.close()}
    }
    @Test fun draftReplacementFrozenCommandAndReceiptRemainAtomicAcrossReopen() = runBlocking {
        var store = store()
        val draft = store.preparePreference(PreferenceWork(actor, id(), PreferencePatch(PreferenceKind.LiveActivity, second = false), "first", 116000))
        val paused = draft.copy(status = PreferenceStatus.DraftPaused, nextAttemptMilliseconds = 90000)
        store.updatePreference(draft, paused)
        val replacement = store.replacePreferenceDraft(paused, draft.copy(operation = id(), activation = "second", confirmedUntil = 200000))
        assertEquals(90000L, replacement.nextAttemptMilliseconds)
        store.close(); store = store()
        assertEquals(PreferenceStatus.DraftCancelled, store.preferenceWorks().first { it.operation == draft.operation }.status)
        val command = PreferenceCommand(actor, replacement.operation, PreferenceValue(PreferenceKind.LiveActivity, true, false), 1, 190000)
        val frozen = replacement.copy(status = PreferenceStatus.Pending, command = command)
        store.updatePreference(replacement, frozen)
        try { store.updatePreference(frozen, frozen.copy(command = command.copy(revision = 2))); fail("rewrote frozen revision") } catch (_: IllegalArgumentException) { }
        try { store.preparePreference(draft.copy(operation = id())); fail("two unfinished writes") } catch (_: IllegalStateException) { }
        store.close(); store = store(); assertEquals(frozen, store.preferenceWorks().first { it.operation == frozen.operation })
        fun receipt(digest: String) = buildJsonObject {
            put("identity", command.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", digest) }); put("resolvedAtMilliseconds", 10000)
            put("outcome", buildJsonObject { put("applied", buildJsonObject { put("value", command.value.payload()); put("revision", 2) }) })
        }.toString()
        try { store.updatePreference(frozen, frozen.copy(status = PreferenceStatus.Committed, receipt = receipt("foreign"))); fail("accepted foreign proof") } catch (_: ClientFailure.Protocol) { }
        assertTrue(store.preferenceSnapshots().isEmpty())
        store.updatePreference(frozen, frozen.copy(status = PreferenceStatus.Committed, receipt = receipt(command.fingerprint)))
        store.close(); store = store()
        assertEquals(PreferenceSnapshot(actor, command.value, 2), store.preferenceSnapshots().single())
        assertEquals(PreferenceStatus.Committed, store.preferenceWorks().first { it.operation == frozen.operation }.status)
        store.close()
    }
    @Test fun oldSnapshotsCannotRegressConfirmedPrivacyAndProjectionConflictRollsBackCursor() = runBlocking {
        var store = store(); val kind = PreferenceKind.ReadReceipts
        val confirmed = PreferenceSnapshot(actor, PreferenceValue(kind, false, false), 4)
        store.savePreference(confirmed)
        fun payload(revision: Int, direct: Boolean, time: Int = revision) = buildJsonObject {
            put("allows_direct_read_receipts", direct); put("allows_group_read_receipts", false); put("preference_revision", revision); put("updated_at_ms", time)
        }
        fun batch(sequence: Long, value: JsonObject) = SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("token-$sequence").setSyncReceipt("receipt-$sequence")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId("preference-$sequence").setProjectionKind(kind.projection).setPayload(ByteString.copyFromUtf8(value.toString()))).build()
        store.commit(batch(1, payload(3, true)), store.cursor()); assertEquals(confirmed, store.preferenceSnapshots().single())
        val cursor = store.cursor()
        try { store.commit(batch(2, payload(3, true, 90)), cursor); fail("same revision timestamp changed") } catch (_: ClientFailure.Protocol) { }
        assertEquals(cursor, store.cursor())
        try { store.commit(batch(2, payload(4, true)), cursor); fail("contradicted confirmed receipt") } catch (_: ClientFailure.Protocol) { }
        assertEquals(cursor, store.cursor())
        val items = persistentListOf(SnapshotItem(kind.projection, "account", "snapshot", 1, ByteString.copyFromUtf8(payload(2, true).toString())))
        store.activateFixture(SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(1).setNextSyncToken("snapshot-token").build(), items)
        assertEquals(confirmed, store.preferenceSnapshots().single())
        store.close(); store = store(); assertEquals(confirmed, store.snapshot().preferences.single())
        store.close()
    }
}
