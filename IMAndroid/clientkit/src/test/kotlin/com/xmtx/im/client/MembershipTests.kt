package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal class MemoryMembership : MembershipStore {
    val works = mutableListOf<MembershipWork>()
    override suspend fun membershipWorks() = works.toPersistentList()
    override suspend fun prepareMembership(intent: MembershipIntent, activation: String): MembershipWork {
        check(works.none { !it.terminal && it.intent.room == intent.room })
        return MembershipWork(intent, activation).also { works.add(it) }
    }
    override suspend fun replaceMembershipDraft(expected: MembershipWork, intent: MembershipIntent, activation: String): MembershipWork {
        check(expected.status == MembershipStatus.DraftPaused && expected.admission == null)
        updateMembership(expected, expected.copy(status = MembershipStatus.DraftCancelled))
        return MembershipWork(intent, activation, nextAttemptMilliseconds = expected.nextAttemptMilliseconds).also { works.add(it) }
    }
    override suspend fun updateMembership(expected: MembershipWork, updated: MembershipWork) {
        val index = works.indexOf(expected); check(index >= 0); if (expected.admission != null) check(expected.admission == updated.admission)
        updated.admission?.validate(updated.intent); works[index] = updated
    }
}
private val membershipRoom = RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
internal fun admission(intent: MembershipIntent) = MembershipAdmission("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", intent.fingerprint,
    intent.action, intent.revision, if(intent.action == MembershipAction.Remove) 3 else null, 2000, minOf(112000, intent.confirmedUntilMilliseconds))
internal fun membershipReceipt(command: MembershipCommand, conflict: Boolean = false) = buildJsonObject {
    put("identity", command.intent.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", 3000)
    put("outcome", if (conflict) buildJsonObject { put("rejected", buildJsonObject { put("_0", buildJsonObject { put("membershipChanged", buildJsonObject { put("currentRevision", command.intent.revision + 1) }) }) }) }
        else buildJsonObject { put("changed", buildJsonObject { put("_0", buildJsonObject {
            put("membershipRevision", command.intent.revision + 1); put("roomSequence", 40); put("eventID", wireId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"))
        }) }) })
}
class MembershipTests {
    @Test fun `Swift generated membership intent and admission command fingerprints remain identical`() {
        val intent = MembershipIntent(actorId, membershipRoom, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", targetId, MembershipAction.Remove, 7, 116000)
        assertEquals("WU4koQS3UvAoinPiEwyZqT24PENyy6MIEjICxRBaDdI=", intent.fingerprint)
        assertEquals("9igpPPul5yy3PJwHFNvIgR6aNYE/ayoQt9ofp1Uzktk=", MembershipCommand(intent, admission(intent)).fingerprint)
    }
    @Test fun `admission binds membership incarnation actor target deadline and final receipt revision`() = runTest {
        val intent = MembershipIntent(actorId, membershipRoom, "operation", targetId, MembershipAction.Remove, 7, 116000)
        val proof = admission(intent)
        val api = FakeEdge { _, _ -> EdgeResponse(200, directResult("admitted", proof.payload(intent))) }
        val actual = (MembershipClient(api).admit(intent) as MembershipAdmissionResult.Admitted).admission
        val command = MembershipCommand(intent, actual)
        assertEquals(3, command.admission.joinedRevision)
        assertEquals(MembershipStatus.Committed, MembershipClient.decodeReceipt(command, membershipReceipt(command)).status)
        assertFailsWith<ClientFailure.Protocol> { MembershipCommand(intent.copy(target = UserId("other")), proof) }
        assertFailsWith<ClientFailure.Protocol> { MembershipCommand(intent.copy(confirmedUntilMilliseconds = 100000), proof) }
        val mismatched = JsonObject(membershipReceipt(command) + ("outcome" to membershipReceipt(MembershipCommand(intent.copy(revision = 8), admission(intent.copy(revision = 8)))).getValue("outcome")))
        assertFailsWith<ClientFailure.Protocol> { MembershipClient.decodeReceipt(command, mismatched) }
        assertNotEquals(command.fingerprint, MembershipCommand(intent, proof.copy(joinedRevision = 4)).fingerprint)
    }
    @Test fun `unadmitted draft survives restart but cannot silently renew its user confirmation`() = runTest {
        val store = MemoryMembership()
        val api = FakeEdge { _, _ -> fail("must not admit an old activation") }
        fun service() = MembershipService(actorId, MembershipClient(api), store, { 1000 }, { 0 })
        val old = service(); val saved = old.enqueue(targetId, old.confirmation(membershipRoom, MembershipAction.Add, 7))
        val restored = service(); restored.flush()
        assertEquals(MembershipStatus.DraftPaused, store.works.single().status)
        val replacement = restored.reconfirm(saved.intent.operation, restored.confirmation(membershipRoom, MembershipAction.Add, 9))
        assertNotEquals(saved.intent.operation, replacement.intent.operation); assertEquals(9, replacement.intent.revision)
        assertEquals(MembershipStatus.DraftCancelled, store.works.first().status)
    }
    @Test fun `frozen admission survives lost response and restart without replacement admission`() = runTest {
        val store = MemoryMembership(); var now = 1000L
        val api = FakeEdge { path, _ -> assertTrue(path.endsWith("admissions")); val work = store.works.single(); EdgeResponse(200, directResult("admitted", admission(work.intent).payload(work.intent))) }
        fun service() = MembershipService(actorId, MembershipClient(api), store, { now }, { now * 1_000_000 })
        val first = service(); first.enqueue(targetId, first.confirmation(membershipRoom, MembershipAction.Remove, 7)); first.flush()
        val original = store.works.single().command()
        api.answer = { path, _ -> assertTrue(path.endsWith("submit")); assertTrue(store.works.single().reconcile); assertCommandAttempt(false); throw IOException() }
        first.flush(); now = 4000
        api.answer = { path, body -> assertCommandAttempt(true); assertTrue(path.endsWith("operations/recover")); assertEquals("query", body!!.string("action")); EdgeResponse(200, directResult("receipt", membershipReceipt(original))) }
        service().flush()
        assertEquals(original, store.works.single().command()); assertEquals(MembershipStatus.Committed, store.works.single().status)
    }
    @Test fun `late admission cannot freeze after the bounded preparation window`() = runTest {
        val store = MemoryMembership(); var nanos = 0L
        val api = FakeEdge { _, _ -> nanos = 61_000_000_000; val intent = store.works.single().intent; EdgeResponse(200, directResult("admitted", admission(intent).payload(intent))) }
        val service = MembershipService(actorId, MembershipClient(api), store, { 1000 }, { nanos })
        service.enqueue(targetId, service.confirmation(membershipRoom, MembershipAction.Add, 7)); service.flush()
        assertNull(store.works.single().admission); assertEquals(MembershipStatus.DraftPaused, store.works.single().status)
    }
    @Test fun `reconfirm preserves server backpressure floor and requires a new operation identity`() = runTest {
        val store = MemoryMembership(); var now = 1000L
        val api = FakeEdge { _, _ -> EdgeResponse(429, buildJsonObject {}, "90") }
        val service = MembershipService(actorId, MembershipClient(api), store, { now }, { now * 1_000_000 })
        val work = service.enqueue(targetId, service.confirmation(membershipRoom, MembershipAction.Add, 7)); service.flush()
        assertEquals(MembershipStatus.DraftPaused, store.works.single().status); assertEquals(91000, store.works.single().nextAttemptMilliseconds)
        val replacement = service.reconfirm(work.intent.operation, service.confirmation(membershipRoom, MembershipAction.Add, 8))
        assertEquals(91000, replacement.nextAttemptMilliseconds)
        api.answer = { _, _ -> fail("reconfirmation bypassed Retry-After") }; now = 90000; service.flush()
    }
    @Test fun `expired admission closes original command and a conflict never rebases`() = runTest {
        val store = MemoryMembership(); var now = 1000L
        val api = FakeEdge { _, _ -> val intent = store.works.single().intent; EdgeResponse(200, directResult("admitted", admission(intent).payload(intent))) }
        val service = MembershipService(actorId, MembershipClient(api), store, { now }, { now * 1_000_000 })
        service.enqueue(targetId, service.confirmation(membershipRoom, MembershipAction.Remove, 7)); service.flush()
        val command = store.works.single().command(); now = 200000
        api.answer = { path, body -> assertTrue(path.endsWith("recover")); assertEquals("closeIfAbsent", body!!.string("action")); EdgeResponse(200, directResult("receipt", membershipReceipt(command, true))) }
        service.flush(); assertEquals(MembershipStatus.Conflicted, store.works.single().status)
        api.answer = { _, _ -> fail("terminal conflict rebased") }; service.retry(command.intent.operation); service.flush()
    }
    @Test fun `directory pages validate room bounds roles duplicates and zero revision`() = runTest {
        var page = RoomMembersPage.newBuilder().setRoomId(membershipRoom.value).setMembershipRevision(0).setActorRoleValue(1)
            .addMembers(RoomMember.newBuilder().setUserId(actorId.value).setRoleValue(1)).build()
        val transport = object : EnvelopeTransport { override suspend fun request(body: Envelope.Builder) = Envelope.newBuilder().setRoomMembersPage(page).build() }
        val directory = MemberDirectory(transport)
        assertEquals(0, directory.page(membershipRoom).revision)
        page = page.toBuilder().addMembers(page.getMembers(0)).build()
        assertFailsWith<ClientFailure.Protocol> { directory.page(membershipRoom) }
        page = page.toBuilder().clearMembers().setActorRoleValue(99).build()
        assertFailsWith<ClientFailure.Protocol> { directory.page(membershipRoom) }
        page = page.toBuilder().setActorRoleValue(1).setNextCursor("stuck").build()
        assertFailsWith<ClientFailure.Protocol> { directory.page(membershipRoom, "stuck") }
    }
    @Test fun `complete role baseline preserves explicit empty permissions and rejects unknown or duplicate grants`() = runTest {
        var baseline = GroupRolePolicyBaseline.newBuilder().setRoomId(membershipRoom.value).setPermissionRevision(1)
            .addPolicies(GroupRolePolicy.newBuilder().setRole("admin").addPermissions(GroupRolePermission.newBuilder().setPermission("invite_members")))
            .addPolicies(GroupRolePolicy.newBuilder().setRole("member")).build()
        val transport = object : EnvelopeTransport { override suspend fun request(body: Envelope.Builder) = Envelope.newBuilder().setGroupRolePolicyBaseline(baseline).build() }
        val reader = MemberDirectory(transport); val policies = reader.policies(membershipRoom)
        assertTrue(policies.allows(MemberRole.Admin, GroupPermission.Invite)); assertFalse(policies.allows(MemberRole.Member, GroupPermission.Send))
        assertTrue(policies.allows(MemberRole.Owner, GroupPermission.Remove))
        baseline = baseline.toBuilder().setPolicies(1, GroupRolePolicy.newBuilder().setRole("member").addPermissions(GroupRolePermission.newBuilder().setPermission("unknown"))).build()
        assertFailsWith<ClientFailure.Protocol> { reader.policies(membershipRoom) }
        baseline = baseline.toBuilder().setPolicies(1, baseline.getPolicies(0)).build()
        assertFailsWith<ClientFailure.Protocol> { reader.policies(membershipRoom) }
    }
}
