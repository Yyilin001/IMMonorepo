package com.xmtx.im.client

import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal val preferenceValues = listOf(PreferenceValue(PreferenceKind.StrangerMessages, false), PreferenceValue(PreferenceKind.UserAdd, true),
    PreferenceValue(PreferenceKind.ReadReceipts, false, true), PreferenceValue(PreferenceKind.LiveActivity, true, false))
internal fun preferenceBaseline(value: PreferenceValue, revision: Long = 7) = buildJsonObject { put("ownerUserID", wireId(actorId.value)); put("value", value.payload()); put("revision", revision) }
internal fun preferenceReceipt(command: PreferenceCommand, conflict: Boolean = false) = buildJsonObject {
    put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", 3000)
    put("outcome", if(conflict) buildJsonObject { put("rejected", buildJsonObject { put("_0", buildJsonObject { put("revisionConflict", buildJsonObject { put("currentRevision", command.revision + 1) }) }) }) }
    else buildJsonObject { put("applied", buildJsonObject { put("value", command.value.payload()); put("revision", command.revision + 1) }) })
}
internal class MemoryPreferences : AccountPreferenceStore {
    val works = mutableListOf<PreferenceWork>(); val snapshots = mutableListOf<PreferenceSnapshot>()
    override suspend fun preferenceWorks() = works.toPersistentList()
    override suspend fun preferenceSnapshots() = snapshots.toPersistentList()
    override suspend fun savePreference(snapshot: PreferenceSnapshot) {
        val old = snapshots.firstOrNull { it.value.kind == snapshot.value.kind }
        if(old != null && old.revision >= snapshot.revision) { if(old.revision == snapshot.revision) require(old == snapshot); return }
        snapshots.remove(old); snapshots.add(snapshot)
    }
    override suspend fun preparePreference(work: PreferenceWork): PreferenceWork { check(works.none { !it.terminal && it.patch.kind == work.patch.kind }); works.add(work); return work }
    override suspend fun replacePreferenceDraft(expected: PreferenceWork, replacement: PreferenceWork): PreferenceWork {
        require(expected.status == PreferenceStatus.DraftPaused && expected.command == null && expected.patch == replacement.patch)
        updatePreference(expected, expected.copy(status = PreferenceStatus.DraftCancelled))
        return replacement.copy(nextAttemptMilliseconds = expected.nextAttemptMilliseconds).also(works::add)
    }
    override suspend fun updatePreference(expected: PreferenceWork, updated: PreferenceWork) {
        val index = works.indexOf(expected); check(index >= 0); if(expected.command != null) require(expected.command == updated.command)
        updated.receipt?.let { AccountPreferenceClient.decodeReceipt(requireNotNull(updated.command), Json.parseToJsonElement(it).jsonObject).applied?.let { value -> savePreference(value) } }
        works[index] = updated
    }
}
class AccountPreferenceTests {
    @Test fun `four commands baselines and receipts match actual Swift fingerprints and Codable fixtures`() = runTest {
        val lines = javaClass.getResourceAsStream("/account-preferences-swift.txt")!!.bufferedReader().readLines()
        preferenceValues.forEachIndexed { index, value ->
            val command = PreferenceCommand(actorId, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", value, 7, 116000)
            assertEquals(lines[index * 4].split(' ')[1], command.fingerprint)
            assertEquals(Json.parseToJsonElement(lines[index * 4 + 1]), command.payload())
            val receipt = AccountPreferenceClient.decodeReceipt(command, Json.parseToJsonElement(lines[index * 4 + 2]).jsonObject)
            assertEquals(PreferenceSnapshot(actorId, value, 8), receipt.applied)
            val api = FakeEdge { path, body -> assertTrue(path.endsWith("/${value.kind.wire}/baseline")); assertNull(body); EdgeResponse(200, Json.parseToJsonElement(lines[index * 4 + 3]).jsonObject) }
            assertEquals(PreferenceSnapshot(actorId, value, 7), AccountPreferenceClient(api, actorId).baseline(value.kind))
        }
    }
    @Test fun `patch preserves untouched fields from the newly read baseline`() {
        val original = PreferenceValue(PreferenceKind.LiveActivity, false, true)
        assertEquals(original.copy(second = false), PreferencePatch(PreferenceKind.LiveActivity, second = false).apply(original))
        assertEquals(original.copy(first = true), PreferencePatch(PreferenceKind.LiveActivity, first = true).apply(original))
        assertFails { PreferencePatch(PreferenceKind.ReadReceipts) }
        assertFails { PreferencePatch(PreferenceKind.UserAdd, second = true) }
        assertFails { PreferenceValue(PreferenceKind.StrangerMessages, true, true) }
        assertFails { PreferencePatch(PreferenceKind.ReadReceipts, first = false).apply(original) }
    }
    @Test fun `baseline is account and kind bound and requires strict Boolean and revision fields`() = runTest {
        val body = preferenceBaseline(preferenceValues[2], 0)
        val api = FakeEdge { _, _ -> EdgeResponse(200, body) }; val client = AccountPreferenceClient(api, actorId)
        assertEquals(0, client.baseline(PreferenceKind.ReadReceipts).revision)
        assertFails { client.baseline(PreferenceKind.LiveActivity) }
        assertFails { AccountPreferenceClient(api, targetId).baseline(PreferenceKind.ReadReceipts) }
        api.answer = { _, _ -> EdgeResponse(200, Json.parseToJsonElement(body.toString().replace("\"allowsDirectReadReceipts\":false", "\"allowsDirectReadReceipts\":\"false\"")).jsonObject) }
        assertFails { client.baseline(PreferenceKind.ReadReceipts) }
        api.answer = { _, _ -> EdgeResponse(200, preferenceBaseline(preferenceValues[2], -1)) }; assertFails { client.baseline(PreferenceKind.ReadReceipts) }
    }
    @Test fun `applied receipt binds exact value revision and actor while backpressure requires proof`() = runTest {
        val command = PreferenceCommand(actorId, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", preferenceValues[2], 7, 116000)
        val receipt = preferenceReceipt(command)
        assertFails { AccountPreferenceClient.decodeReceipt(command, Json.parseToJsonElement(receipt.toString().replace("\"revision\":8", "\"revision\":9")).jsonObject) }
        assertFails { AccountPreferenceClient.decodeReceipt(command.copy(value = command.value.copy(second = false)), receipt) }
        assertFails { AccountPreferenceClient.decodeReceipt(command.copy(actor = targetId), receipt) }
        val hint = buildJsonObject { put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("reason", "rateLimited"); put("retryAfterMilliseconds", 1000) }
        val api = FakeEdge { _, _ -> EdgeResponse(429, directResult("deferred", hint), "9") }
        assertEquals(9000, (AccountPreferenceClient(api, actorId).execute(command, true, false) as PreferenceResult.Deferred).delayMilliseconds)
        api.answer = { _, _ -> EdgeResponse(503, buildJsonObject {}, "9") }; assertFails { AccountPreferenceClient(api, actorId).execute(command, false, false) }
    }
    @Test fun `draft restart pauses and explicit replacement preserves Retry After floor`() = runTest {
        val store = MemoryPreferences(); var now = 1000L
        val api = FakeEdge { _, _ -> EdgeResponse(429, buildJsonObject {}, "90") }
        fun service() = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { now }, { now * 1000000 })
        val first = service(); val work = first.enqueue(PreferencePatch(PreferenceKind.LiveActivity, second = false)); first.flush()
        assertEquals(PreferenceStatus.DraftPaused, store.works.single().status)
        val resumed = service(); val next = resumed.reconfirm(work.operation)
        assertNotEquals(work.operation, next.operation); assertEquals(91000, next.nextAttemptMilliseconds)
        now = 90000; api.answer = { _, _ -> fail("bypassed server floor") }; resumed.flush()
        now = 91000; service().flush(); assertEquals(PreferenceStatus.DraftPaused, store.works.last().status)
    }
    @Test fun `frozen command survives lost response restart without reading a new baseline`() = runTest {
        val store = MemoryPreferences(); var now = 1000L
        val api = FakeEdge { _, _ -> EdgeResponse(200, preferenceBaseline(PreferenceValue(PreferenceKind.LiveActivity, false, true))) }
        fun service() = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { now }, { now * 1000000 })
        val first = service(); first.enqueue(PreferencePatch(PreferenceKind.LiveActivity, second = false)); first.flush()
        val command = requireNotNull(store.works.single().command)
        assertEquals(PreferenceValue(PreferenceKind.LiveActivity, false, false), command.value); assertEquals(116000, command.deadline)
        api.answer = { path, body -> assertTrue(path.endsWith("/submit")); assertEquals(command.payload(), body); assertCommandAttempt(false); throw IOException("unknown outcome") }; first.flush()
        now = 5000; api.answer = { path, body -> assertCommandAttempt(true); assertTrue(path.endsWith("/recover")); assertEquals(command.recovery(false), body); EdgeResponse(200, directResult("receipt", preferenceReceipt(command))) }
        service().flush(); assertEquals(PreferenceStatus.Committed, store.works.single().status); assertEquals(8, store.snapshots.single().revision)
    }
    @Test fun `late preparation cannot freeze a command and version conflicts do not rebase`() = runTest {
        val store = MemoryPreferences(); var now = 1000L
        val api = FakeEdge { _, _ -> now += 61000; EdgeResponse(200, preferenceBaseline(preferenceValues[2])) }
        val service = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { now }, { now * 1000000 })
        val draft = service.enqueue(PreferencePatch(PreferenceKind.ReadReceipts, first = true)); service.flush()
        assertEquals(PreferenceStatus.DraftPaused, store.works.single().status); assertNull(store.works.single().command)
        api.answer = { _, _ -> EdgeResponse(200, preferenceBaseline(preferenceValues[2])) }; service.reconfirm(draft.operation); service.flush()
        val command = requireNotNull(store.works.last().command)
        api.answer = { _, _ -> EdgeResponse(200, directResult("receipt", preferenceReceipt(command, true))) }; service.flush()
        assertEquals(PreferenceStatus.Conflicted, store.works.last().status)
        api.answer = { _, _ -> fail("conflict retried") }; service.flush()
    }
    @Test fun `expired submission closes original identity even after restart`() = runTest {
        val store = MemoryPreferences(); var now = 1000L
        val api = FakeEdge { _, _ -> EdgeResponse(200, preferenceBaseline(preferenceValues[0])) }
        var service = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { now }, { now * 1000000 })
        service.enqueue(PreferencePatch(PreferenceKind.StrangerMessages, first = true)); service.flush(); val command = requireNotNull(store.works.single().command)
        now = 117000
        api.answer = { _, body -> assertEquals(command.recovery(true), body); EdgeResponse(200, directResult("receipt", buildJsonObject {
            put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", now); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
        })) }
        service = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { now }, { now * 1000000 }); service.flush()
        assertEquals(PreferenceStatus.Closed, store.works.single().status)
    }
    @Test fun `local privacy restrictions apply while queued and pending grants never loosen confirmed denial`() {
        val snapshots = persistentListOf(PreferenceSnapshot(actorId, PreferenceValue(PreferenceKind.LiveActivity, false, true), 3))
        val patch = PreferencePatch(PreferenceKind.LiveActivity, first = true, second = false)
        val work = PreferenceWork(actorId, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", patch, "activation", 116000, PreferenceStatus.DraftPaused)
        val policy = PreferencePublicationPolicy.derive(snapshots, persistentListOf(work))
        assertFalse(policy.online); assertFalse(policy.typing)
        val cancelled = PreferencePublicationPolicy.derive(snapshots, persistentListOf(work.copy(status = PreferenceStatus.DraftCancelled)))
        assertFalse(cancelled.online); assertTrue(cancelled.typing)
    }
}
