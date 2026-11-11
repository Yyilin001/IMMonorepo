package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.UUID

class PreparedOperationDiagnosticsStorageTests {
    @Test fun legacyPreferenceQueriesBeforeReplayingFrozenCommandAcrossReopen() = exercise(0)
    @Test fun legacyCapabilityQueriesBeforeReplayingFrozenAdmissionAcrossReopen() = exercise(1)
    @Test fun legacyMembershipQueriesBeforeReplayingFrozenAdmissionAcrossReopen() = exercise(2)

    private fun exercise(type: Int) = runBlocking {
        fun id() = UUID.randomUUID().toString().uppercase()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id()); val room = RoomId(id()); val target = UserId(id())
        val operation = id(); val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device)
        var now = 1000L; var calls = 0
        val preference = PreferenceCommand(actor, operation, PreferenceValue(PreferenceKind.StrangerMessages, true), 7, 116000)
        val capabilityIntent = GroupCapabilityIntent(actor, room, operation, GroupAction.Role(target, MemberRole.Admin, 7), 116000)
        val capabilityAdmission = GroupCapabilityAdmission(id(), capabilityIntent.fingerprint, 1000, 110000, 3)
        val membershipIntent = MembershipIntent(actor, room, operation, target, MembershipAction.Remove, 7, 116000)
        val membershipAdmission = MembershipAdmission(id(), membershipIntent.fingerprint, MembershipAction.Remove, 7, 3, 1000, 110000)
        var expectedSubmit: JsonObject? = null; var expectedRecovery: JsonObject? = null
        val edge = object : AuthenticatedTransport {
            override suspend fun request(path: String, payload: JsonObject?, query: Pair<String, String>?, maximumBytes: Long): EdgeResponse {
                calls++
                val intent = requireNotNull(currentCoroutineContext()[NetworkWorkIntent])
                assertTrue(intent.isRetry); assertEquals(NetworkWorkPriority.Recovery, intent.priority)
                if (calls == 1) {
                    assertTrue(path.endsWith("/recover")); assertEquals(expectedRecovery, payload)
                    return EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
                }
                assertEquals(2, calls); assertTrue(path.endsWith("/submit")); assertEquals(expectedSubmit, payload)
                throw IOException("fixture lost reply")
            }
        }
        suspend fun flush() {
            when (type) {
                0 -> AccountPreferenceService(actor, AccountPreferenceClient(edge, actor), store, {now}, {now * 1_000_000}).flush()
                1 -> GroupCapabilityService(actor, GroupCapabilityClient(edge), store, {now}, {now * 1_000_000}).flush()
                else -> MembershipService(actor, MembershipClient(edge), store, {now}, {now * 1_000_000}).flush()
            }
        }
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device) }
        suspend fun verifyStored(attempts: Int, reconcile: Boolean): Long = when (type) {
            0 -> requireNotNull(store.preferenceWork(operation)).let {
                assertEquals(it, store.preferenceWorks().single()); assertEquals(preference, it.command)
                assertEquals(attempts, it.attempts); assertEquals(reconcile, it.reconcile)
                assertEquals(if(attempts == 0) null else true, it.executionStarted)
                assertNull(store.preferenceWork(id())); it.nextAttemptMilliseconds
            }
            1 -> requireNotNull(store.capabilityWork(operation)).let {
                assertEquals(it, store.capabilityWorks().single()); assertEquals(capabilityIntent, it.intent); assertEquals(capabilityAdmission, it.admission)
                assertEquals(attempts, it.attempts); assertEquals(reconcile, it.reconcile)
                assertEquals(if(attempts == 0) null else true, it.executionStarted)
                assertNull(store.capabilityWork(id())); it.nextAttemptMilliseconds
            }
            else -> requireNotNull(store.membershipWork(operation)).let {
                assertEquals(it, store.membershipWorks().single()); assertEquals(membershipIntent, it.intent); assertEquals(membershipAdmission, it.admission)
                assertEquals(attempts, it.attempts); assertEquals(reconcile, it.reconcile)
                assertEquals(if(attempts == 0) null else true, it.executionStarted)
                assertNull(store.membershipWork(id())); it.nextAttemptMilliseconds
            }
        }
        try {
            when (type) {
                0 -> {
                    val draft = store.preparePreference(PreferenceWork(actor, operation, PreferencePatch(PreferenceKind.StrangerMessages, first = true), "old", 116000))
                    store.updatePreference(draft, draft.copy(command = preference, status = PreferenceStatus.Pending))
                    expectedSubmit = preference.payload(); expectedRecovery = preference.recovery(false)
                }
                1 -> {
                    val draft = store.prepareCapability(capabilityIntent, "old")
                    val pending = draft.copy(admission = capabilityAdmission, status = GroupCapabilityStatus.Pending)
                    store.updateCapability(draft, pending)
                    expectedSubmit = pending.command().payload(); expectedRecovery = pending.command().recovery(false)
                }
                else -> {
                    val draft = store.prepareMembership(membershipIntent, "old")
                    val pending = draft.copy(admission = membershipAdmission, status = MembershipStatus.Pending)
                    store.updateMembership(draft, pending)
                    expectedSubmit = pending.command().payload(); expectedRecovery = pending.command().recovery(false)
                }
            }
            reopen(); verifyStored(0, false)
            val diagnostics = NetworkDiagnostics()
            withContext(NetworkDiagnosticsScope(diagnostics)) {
                flush(); reopen(); now = verifyStored(1, false)
                flush(); reopen(); assertTrue(verifyStored(2, true) > now)
            }
            assertEquals(2, calls)
            val samples = diagnostics.snapshot().operations
            assertEquals(listOf(OperationWorkAction.Reconcile, OperationWorkAction.Submit), samples.map {it.action})
            val kind = listOf(OperationKind.StrangerMessagePreference, OperationKind.GroupRole, OperationKind.Membership)[type]
            assertTrue(samples.all {it.kind == kind && it.priority == NetworkWorkPriority.Recovery})
            assertTrue(samples.all {it.certainty == NetworkMetric.Certainty.OutcomeUnknown})
            assertTrue(samples.all {it.observation?.scheduling == OperationSchedulingState.BackingOff})
        } finally {
            store.close(); SQLiteDatabase.deleteDatabase(file)
        }
    }
}
