package com.xmtx.im.client

import kotlinx.collections.immutable.persistentSetOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal val capabilityRoom = RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
internal val capabilityMessage = MessageId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
internal val capabilityActions = listOf(GroupAction.Pin(capabilityMessage, true, 7), GroupAction.Announcement("群公告 🐈", 7),
    GroupAction.Permissions(MemberRole.Member, persistentSetOf(GroupPermission.Send, GroupPermission.Invite), 7),
    GroupAction.Role(targetId, MemberRole.Admin, 7), GroupAction.Transfer(targetId, 7), GroupAction.Dissolve(7))
internal fun capabilityIntent(action: GroupAction = capabilityActions[3]) = GroupCapabilityIntent(actorId, capabilityRoom, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", action, 116000)
internal fun capabilityAdmission(intent: GroupCapabilityIntent) = GroupCapabilityAdmission("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", intent.fingerprint, 2000, minOf(112000, intent.confirmedUntilMilliseconds),
    if(intent.action is GroupAction.Role || intent.action is GroupAction.Transfer) 3 else null)
internal fun capabilityReceipt(command: GroupCapabilityCommand, applied: Boolean = true): JsonObject = buildJsonObject {
    put("identity", command.intent.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", 4000)
    val action = command.intent.action; val revision = action.revision + if(applied) 1 else 0
    put("outcome", buildJsonObject { put(if(applied) "applied" else "alreadySatisfied", buildJsonObject { put("_0", buildJsonObject {
        val key = when(action) { is GroupAction.Pin -> "pinned"; is GroupAction.Announcement -> "announcement"; is GroupAction.Permissions -> "rolePermissions"; is GroupAction.Role -> "memberRole"; is GroupAction.Transfer -> "ownershipTransferred"; is GroupAction.Dissolve -> "dissolved" }
        put(key, buildJsonObject {
            put("roomSequence", if(action is GroupAction.Pin) revision else 40)
            when(action) {
                is GroupAction.Pin -> { put("messageID", wireId(action.message.value)); put("isPinned", action.pinned) }
                is GroupAction.Announcement -> { put("body", action.body); put("revision", revision) }
                is GroupAction.Permissions -> { put("role", action.role.wire); put("permissions", JsonArray(action.permissions.map { JsonPrimitive(it.wire) })); put("revision", revision) }
                is GroupAction.Role -> { put("targetUserID", wireId(action.target.value)); put("role", action.role.wire); put("membershipRevision", revision) }
                is GroupAction.Transfer -> { put("previousOwnerUserID", wireId(command.intent.actor.value)); put("ownerUserID", wireId(action.target.value)); put("membershipRevision", revision) }
                is GroupAction.Dissolve -> put("membershipRevision", revision)
            }
        })
    }) }) })
}
internal class MemoryCapabilities : GroupCapabilityStore {
    val works = mutableListOf<GroupCapabilityWork>()
    override suspend fun capabilityWorks() = works.toPersistentList()
    override suspend fun prepareCapability(intent: GroupCapabilityIntent, activation: String): GroupCapabilityWork {
        check(works.none { !it.terminal && it.intent.room == intent.room }); return GroupCapabilityWork(intent, activation).also(works::add)
    }
    override suspend fun replaceCapabilityDraft(expected: GroupCapabilityWork, intent: GroupCapabilityIntent, activation: String): GroupCapabilityWork {
        require(expected.status == GroupCapabilityStatus.DraftPaused && expected.admission == null && expected.intent.action.sameDesiredValue(intent.action))
        updateCapability(expected, expected.copy(status = GroupCapabilityStatus.DraftCancelled))
        return GroupCapabilityWork(intent, activation, nextAttemptMilliseconds = expected.nextAttemptMilliseconds).also(works::add)
    }
    override suspend fun updateCapability(expected: GroupCapabilityWork, updated: GroupCapabilityWork) {
        val index = works.indexOf(expected); check(index >= 0 && expected.intent == updated.intent)
        if(expected.admission != null) require(expected.admission == updated.admission)
        updated.admission?.validate(updated.intent); works[index] = updated
    }
}
class GroupCapabilityTests {
    @Test fun `six capability fingerprints and Swift Codable payloads match actual Swift fixtures`() {
        val lines = javaClass.getResourceAsStream("/group-capability-swift.txt")!!.bufferedReader().readLines()
        capabilityActions.forEachIndexed { i, action ->
            val intent = capabilityIntent(action); val command = GroupCapabilityCommand(intent, capabilityAdmission(intent))
            val expected = lines[i * 2].split(' ')
            assertEquals(expected[1], intent.fingerprint); assertEquals(expected[2], command.fingerprint)
            // Swift Set array order is unspecified; compare the permission set separately.
            val swift = Json.parseToJsonElement(lines[i * 2 + 1]).jsonObject
            fun canonical(element: JsonElement): JsonElement = when(element) {
                is JsonObject -> JsonObject(element.mapValues { canonical(it.value) })
                is JsonArray -> JsonArray(element.sortedBy { it.toString() }.map(::canonical))
                else -> element
            }
            assertEquals(canonical(swift), canonical(command.payload()))
        }
    }
    @Test fun `intent disallows owner policy self targeting invalid revisions and oversized announcements`() {
        assertFails { capabilityIntent(GroupAction.Role(actorId, MemberRole.Admin, 0)) }
        assertFails { capabilityIntent(GroupAction.Role(targetId, MemberRole.Owner, 7)) }
        assertFails { capabilityIntent(GroupAction.Permissions(MemberRole.Owner, persistentSetOf(), 7)) }
        assertFails { capabilityIntent(GroupAction.Transfer(targetId, 0)) }
        assertFails { capabilityIntent(GroupAction.Dissolve(Long.MAX_VALUE)) }
        assertFails { capabilityIntent(GroupAction.Announcement("  \n", 0)) }
        assertFails { capabilityIntent(GroupAction.Announcement("猫".repeat(1366), 0)) }
        capabilityIntent(GroupAction.Announcement("", 0)); capabilityIntent(GroupAction.Role(targetId, MemberRole.Admin, 0))
    }
    @Test fun `admission verifies message scope actor fingerprint incarnation and confirmation cutoff`() = runTest {
        for(action in capabilityActions) {
            val intent = capabilityIntent(action); val proof = capabilityAdmission(intent)
            val api = FakeEdge { path, _ -> assertTrue(path.endsWith("/group-capability-operations/admissions")); EdgeResponse(200, directResult("admitted", proof.payload(intent))) }
            assertEquals(proof, (GroupCapabilityClient(api).admit(intent) as GroupCapabilityAdmissionResult.Admitted).admission)
            assertFails { proof.copy(intentFingerprint = "wrong").validate(intent) }
            assertFails { proof.copy(expiresAt = 117000).validate(intent) }
            assertFails { proof.copy(joinedRevision = if(proof.joinedRevision == null) 0 else null).validate(intent) }
        }
        val intent = capabilityIntent(); assertFails { capabilityAdmission(intent).copy(joinedRevision = 8).validate(intent) }
    }
    @Test fun `receipt binds desired values exact CAS revision and rejects already satisfied ownership and dissolution`() {
        for(action in capabilityActions) {
            val command = GroupCapabilityCommand(capabilityIntent(action), capabilityAdmission(capabilityIntent(action)))
            val wire = capabilityReceipt(command)
            assertEquals(GroupCapabilityStatus.Committed, GroupCapabilityClient.decodeReceipt(command, wire).status)
            val tampered = Json.parseToJsonElement(wire.toString().replace("\"membershipRevision\":8", "\"membershipRevision\":9").replace("\"revision\":8", "\"revision\":9").replace("\"isPinned\":true", "\"isPinned\":false")).jsonObject
            assertFails { GroupCapabilityClient.decodeReceipt(command, tampered) }
            if(action is GroupAction.Transfer || action is GroupAction.Dissolve) assertFails { GroupCapabilityClient.decodeReceipt(command, capabilityReceipt(command, false)) }
            else assertEquals(GroupCapabilityStatus.Committed, GroupCapabilityClient.decodeReceipt(command, capabilityReceipt(command, false)).status)
        }
    }
    @Test fun `JSON types and deferred identity proof cannot be weakened by quoted values`() = runTest {
        val intent = capabilityIntent(capabilityActions[0]); val command = GroupCapabilityCommand(intent, capabilityAdmission(intent))
        val wire = capabilityReceipt(command)
        for((from, to) in listOf("\"isPinned\":true" to "\"isPinned\":\"true\"", "\"roomSequence\":8" to "\"roomSequence\":\"8\"")) {
            assertFails { GroupCapabilityClient.decodeReceipt(command, Json.parseToJsonElement(wire.toString().replace(from, to)).jsonObject) }
        }
        val hint = buildJsonObject {
            put("identity", intent.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("reason", "rateLimited"); put("retryAfterMilliseconds", 2000)
        }
        val api = FakeEdge { _, _ -> EdgeResponse(429, directResult("deferred", hint), "9") }
        assertEquals(9000, (GroupCapabilityClient(api).execute(command, true, false) as GroupCapabilityResult.Deferred).delayMilliseconds)
        api.answer = { _, _ -> EdgeResponse(429, directResult("deferred", JsonObject(hint + ("fingerprint" to fingerprintPayload("wrong")))), "9") }
        assertFails { GroupCapabilityClient(api).execute(command, true, false) }
    }
    @Test fun `restart pauses unfrozen draft and explicit reconfirm preserves backpressure floor`() = runTest {
        val store = MemoryCapabilities(); var now = 1000L
        val api = FakeEdge { _, _ -> EdgeResponse(429, buildJsonObject {}, "90") }
        fun service() = GroupCapabilityService(actorId, GroupCapabilityClient(api), store, { now }, { now * 1_000_000 })
        val original = service(); val work = original.enqueue(original.confirmation(capabilityRoom, capabilityActions[3])); original.flush()
        assertEquals(GroupCapabilityStatus.DraftPaused, store.works.single().status)
        val restarted = service(); val updated = restarted.reconfirm(work.intent.operation, restarted.confirmation(capabilityRoom, GroupAction.Role(targetId, MemberRole.Admin, 8)))
        assertNotEquals(work.intent.operation, updated.intent.operation); assertEquals(91000, updated.nextAttemptMilliseconds)
        now = 90000; api.answer = { _, _ -> fail("Retry-After bypassed") }; restarted.flush()
        now = 91000; service().flush(); assertEquals(GroupCapabilityStatus.DraftPaused, store.works.last().status)
    }
    @Test fun `frozen command survives lost submit response and restart reconciles exact original identity`() = runTest {
        val store = MemoryCapabilities(); var now = 1000L
        val api = FakeEdge { _, _ -> val intent = store.works.single().intent; EdgeResponse(200, directResult("admitted", capabilityAdmission(intent).payload(intent))) }
        fun service() = GroupCapabilityService(actorId, GroupCapabilityClient(api), store, { now }, { now * 1_000_000 })
        val original = service(); original.enqueue(original.confirmation(capabilityRoom, capabilityActions[3])); original.flush()
        val command = store.works.single().command()
        api.answer = { path, body -> assertTrue(path.endsWith("/submit")); assertEquals(command.payload(), body); assertCommandAttempt(false); throw IOException("lost response") }
        original.flush(); now = 5000
        api.answer = { path, body -> assertCommandAttempt(true); assertTrue(path.endsWith("/operations/recover")); assertEquals(command.recovery(false), body); EdgeResponse(200, directResult("receipt", capabilityReceipt(command))) }
        service().flush(); assertEquals(GroupCapabilityStatus.Committed, store.works.single().status)
    }
    @Test fun `late admission cannot freeze and expired command only closes the original identity`() = runTest {
        val store = MemoryCapabilities(); var now = 1000L
        val api = FakeEdge { _, _ -> now += 61000; val intent = store.works.single().intent; EdgeResponse(200, directResult("admitted", capabilityAdmission(intent).payload(intent))) }
        val service = GroupCapabilityService(actorId, GroupCapabilityClient(api), store, { now }, { now * 1_000_000 })
        service.enqueue(service.confirmation(capabilityRoom, capabilityActions[3])); service.flush()
        assertEquals(GroupCapabilityStatus.DraftPaused, store.works.single().status); assertNull(store.works.single().admission)
        val intent = capabilityIntent(); val command = GroupCapabilityCommand(intent, capabilityAdmission(intent)); store.works.clear(); store.works.add(GroupCapabilityWork(intent, "old", GroupCapabilityStatus.Pending, command.admission))
        now = 120000
        api.answer = { _, body -> assertEquals(command.recovery(true), body); EdgeResponse(200, directResult("receipt", buildJsonObject {
            put("identity", intent.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", now); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
        })) }
        service.flush(); assertEquals(GroupCapabilityStatus.Closed, store.works.single().status)
    }
    @Test fun `deferred proof is mandatory and pin baseline binds exact room message and sequence`() = runTest {
        val intent = capabilityIntent(capabilityActions[0]); val command = GroupCapabilityCommand(intent, capabilityAdmission(intent))
        val api = FakeEdge { _, _ -> EdgeResponse(503, buildJsonObject {}, "5") }
        assertFails { GroupCapabilityClient(api).execute(command, true, false) }
        api.answer = { path, body -> assertNull(body); assertTrue(path.endsWith("/pin-baseline")); EdgeResponse(200, buildJsonObject {
            put("roomID", wireId(capabilityRoom.value)); put("messageID", wireId(capabilityMessage.value)); put("isPinned", true); put("roomSequence", 7)
        }) }
        assertEquals(7, GroupCapabilityClient(api).pinBaseline(capabilityRoom, capabilityMessage).sequence)
        assertFails { GroupCapabilityClient(api).pinBaseline(capabilityRoom, MessageId(targetId.value)) }
    }
}
