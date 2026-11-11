package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class PolicyRecoveryStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId(UUID.randomUUID().toString());private val peer = UserId(UUID.randomUUID().toString());private val device = DeviceId(UUID.randomUUID().toString())
    private val room = RoomId(UUID.randomUUID().toString());private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context,actor,device)
    private suspend fun ready(store: SqliteClientStore) {
        store.reconcileDirectory(persistentMapOf(room to RoomKind.Group));store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(100).build())
    }
    private fun baseline(revision: Long = 8,membership: Long = 2,admin: PersistentSet<GroupPermission> = persistentSetOf(),member: PersistentSet<GroupPermission> = persistentSetOf()) = GroupPolicies(room,revision,membership,revision*10,admin,member)
    private suspend fun effect(store: SqliteClientStore,sequence: Long,revision: Long,role: String,permissions: List<String>) {
        val payload = buildJsonObject { put("event_type","group.role_permissions_changed");put("room_id",room.value);put("role",role);put("revision",revision);put("permissions",JsonArray(permissions.map(::JsonPrimitive))) }
        store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId(id()).setProjectionKind("group_capability").setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),store.roomCursor(room))
    }
    private suspend fun member(store: SqliteClientStore,target: UserId,revision: Long,action: String) {
        val cursor = store.cursor();val sequence = cursor.sequence+1
        val payload = buildJsonObject { put("event_type","membership_changed");put("room_id",room.value);put("target_user_id",target.value);put("membership_revision",revision);put("action",action);put("title","group") }
        store.commit(SyncBatch.newBuilder().setGeneration(maxOf(1,cursor.generation)).setNextSyncToken("$sequence").setSyncReceipt("$sequence")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId(id()).setProjectionKind("membership").setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),cursor)
    }
    @Test fun pendingRequestSurvivesReopenAndCompleteObservationMergesOnlyNewerRoleFacts() = runBlocking {
        var store = store();try {
            ready(store);assertEquals(1,store.discoverPolicyRecovery(1));assertEquals(0,store.discoverPolicyRecovery(1))
            val request = store.requestPolicyRecovery(room);store.close();store = store();assertEquals(request,store.requestPolicyRecovery(room))
            effect(store,1,7,"member",listOf("send_messages"));effect(store,2,8,"member",emptyList());effect(store,3,9,"admin",listOf("invite_members"))
            assertTrue(store.completePolicyRecovery(request,baseline()))
            val state = store.snapshot().groupPolicyStates.single();assertEquals(PolicyRecoveryStatus.Ready,state.status);assertEquals(2,state.policies.size)
            assertEquals(persistentSetOf(GroupPermission.Invite),state.policies.first { it.role == MemberRole.Admin }.permissions)
            assertTrue(state.policies.first { it.role == MemberRole.Member }.permissions.isEmpty());assertTrue(state.policies.all { it.revision == 9L })
            assertTrue(store.duePolicyRecovery(Long.MAX_VALUE,10).isEmpty())
            val refresh = store.requestPolicyRecovery(room);assertFalse(store.completePolicyRecovery(refresh,baseline(6)))
            try { store.completePolicyRecovery(refresh,baseline(9));fail("baseline contradicted source fact") } catch(_: ClientFailure.Protocol) { }
            assertTrue(store.completePolicyRecovery(refresh,baseline(10)));assertTrue(store.snapshot().groupPolicyStates.single().policies.all { it.revision == 10L && it.permissions.isEmpty() })
        } finally { store.close() }
    }
    @Test fun profileMembershipGrantAccountAndDeviceChangesRejectLateReads() = runBlocking {
        val store = store();try {
            ready(store);val first = store.requestPolicyRecovery(room)
            assertFalse(store.completePolicyRecovery(first.copy(binding = first.binding.copy(actor = peer)),baseline()))
            assertFalse(store.completePolicyRecovery(first.copy(binding = first.binding.copy(device = DeviceId(id()))),baseline()))
            member(store,peer,3,"add");assertFalse(store.completePolicyRecovery(first,baseline(membership = 3)));assertEquals(1,store.discoverPolicyRecovery(1))
            val second = store.requestPolicyRecovery(room);assertNotEquals(first.id,second.id);assertEquals(3L,second.binding.membership);assertEquals(2L,second.binding.grant)
            assertTrue(store.completePolicyRecovery(second,baseline(membership = 3)))
            val inFlight = store.requestPolicyRecovery(room);member(store,actor,4,"remove")
            assertFalse(store.completePolicyRecovery(inFlight,baseline(membership = 4)));assertTrue(store.snapshot().groupPolicyStates.isEmpty())
            member(store,actor,5,"add");val fresh = store.requestPolicyRecovery(room)
            assertFalse(store.completePolicyRecovery(inFlight,baseline(membership = 5)));assertTrue(store.completePolicyRecovery(fresh,baseline(membership = 5)))
        } finally { store.close() }
    }
    @Test fun syncResetFencesReadsAndSameGrantRetainsBaselineWithoutPreservingOldRequestAuthority() = runBlocking {
        val store = store();try {
            ready(store);assertTrue(store.completePolicyRecovery(store.requestPolicyRecovery(room),baseline()))
            val inFlight = store.requestPolicyRecovery(room)
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(10).setNextSyncToken("snapshot").build()
            val items = persistentListOf(SnapshotItem("room","room:${room.value}","snapshot",1,ByteString.copyFromUtf8(buildJsonObject {
                put("event_type","room.created");put("room_id",room.value);put("membership_revision",2);put("title","group")
                put("viewer_membership_revision",2);put("viewer_is_member",true);put("viewer_membership_source_event_id","grant")
            }.toString())))
            store.stage(manifest);assertEquals(PolicyRecoveryStatus.WaitingForSync,store.snapshot().groupPolicyStates.single().status)
            try { store.completePolicyRecovery(inFlight,baseline());fail("read installed through reset") } catch(_: PolicyRecoverySyncPending) { }
            store.validateSnapshot(items);store.activateFixture(manifest,items);store.reconcileDirectory(persistentMapOf(room to RoomKind.Group))
            assertFalse(store.completePolicyRecovery(inFlight,baseline()));assertEquals(2,store.snapshot().groupPolicyStates.single().policies.size)
            assertEquals(1,store.discoverPolicyRecovery(1));val renewed = store.requestPolicyRecovery(room);assertEquals(2L,renewed.binding.generation);assertNotEquals(inFlight.id,renewed.id)
            assertTrue(store.completePolicyRecovery(renewed,baseline()))
        } finally { store.close() }
    }
    @Test fun sameRevisionContentAndCrossedObservationTimesAreRejectedWhileOldEventsCannotOverrideBaseline() = runBlocking {
        val store = store();try {
            ready(store);assertTrue(store.completePolicyRecovery(store.requestPolicyRecovery(room),baseline()))
            val request = store.requestPolicyRecovery(room)
            try { store.completePolicyRecovery(request,baseline(member = persistentSetOf(GroupPermission.Send)));fail("same revision changed") } catch(_: ClientFailure.Protocol) { }
            try { store.completePolicyRecovery(request,baseline(9).copy(roomSequence = 79));fail("sequence moved backward") } catch(_: ClientFailure.Protocol) { }
            try { store.completePolicyRecovery(request,baseline(membership = 1));fail("older than bound member version") } catch(_: ClientFailure.Protocol) { }
            assertTrue(store.completePolicyRecovery(request,baseline().copy(roomSequence = 70))) // Same content, older observation does not replace the saved one.
            effect(store,1,7,"member",listOf("send_messages"));assertTrue(store.snapshot().groupPolicyStates.single().policies.all { it.permissions.isEmpty() })
            assertTrue(store.snapshot().rolePolicies.isEmpty()) // A baseline is not forged into source events.
            try { effect(store,2,8,"member",listOf("send_messages"));fail("event contradicted baseline") } catch(_: ClientFailure.Protocol) { }
            assertEquals(1L,store.roomCursor(room).sequence)
        } finally { store.close() }
    }
    @Test fun backoffPauseAndResumePersistAndUnauthorizedNeedsFreshRoomAuthorization() = runBlocking {
        var store = store();try {
            ready(store);val request = store.requestPolicyRecovery(room);assertTrue(store.failPolicyRecovery(request,PolicyRecoveryDisposition.Retry(90000)))
            store.close();store = store();assertTrue(store.duePolicyRecovery(89999,10).isEmpty());val retried = store.duePolicyRecovery(90000,10).single();assertEquals(1,retried.attempts)
            assertFalse(store.failPolicyRecovery(request,PolicyRecoveryDisposition.Pause));assertTrue(store.failPolicyRecovery(retried,PolicyRecoveryDisposition.Pause))
            assertEquals(PolicyRecoveryStatus.Paused,store.snapshot().groupPolicyStates.single().status);assertEquals(0,store.discoverPolicyRecovery(10))
            val resumed = store.requestPolicyRecovery(room,true);assertNotEquals(request.id,resumed.id);assertEquals(0,resumed.attempts)
            assertTrue(store.completePolicyRecovery(resumed,baseline()));val denied = store.requestPolicyRecovery(room)
            assertTrue(store.failPolicyRecovery(denied,PolicyRecoveryDisposition.Unauthorized));val state = store.snapshot().groupPolicyStates.single()
            assertEquals(PolicyRecoveryStatus.Unavailable,state.status);assertTrue(state.policies.isEmpty());assertEquals(0,store.discoverPolicyRecovery(10))
            assertFalse(store.completePolicyRecovery(denied,baseline()));try { store.requestPolicyRecovery(room);fail("denied request reopened") } catch(_: PolicyRecoveryUnauthorized) { }
            store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(100).build());assertEquals(1,store.discoverPolicyRecovery(10))
        } finally { store.close() }
    }
    @Test fun newerOwnGrantWithoutObservedRemovalClearsOldPolicyObservationAndRequest() = runBlocking {
        val store = store();try {
            ready(store);assertTrue(store.completePolicyRecovery(store.requestPolicyRecovery(room),baseline()))
            val old = store.requestPolicyRecovery(room);member(store,actor,5,"add")
            assertFalse(store.completePolicyRecovery(old,baseline(membership = 5)))
            val state = store.snapshot().groupPolicyStates.single();assertTrue(state.policies.isEmpty());assertEquals(PolicyRecoveryStatus.Needed,state.status)
            assertTrue(store.completePolicyRecovery(store.requestPolicyRecovery(room),baseline(membership = 5)))
        } finally { store.close() }
    }
    @Test fun boundedDiscoveryDoesNotStarveLaterRoomsBehindPausedRequests() = runBlocking {
        val store = store();try {
            val rooms = (1..6).map { RoomId("10000000-0000-0000-0000-%012d".format(it)) }
            store.reconcileDirectory(rooms.associateWith { RoomKind.Group }.toPersistentMap())
            rooms.forEach { store.acceptState(it,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(0).build()) }
            assertEquals(2,store.discoverPolicyRecovery(2))
            store.duePolicyRecovery(0,10).forEach { store.failPolicyRecovery(it,PolicyRecoveryDisposition.Pause) }
            assertEquals(2,store.discoverPolicyRecovery(2));assertEquals(rooms.drop(2).take(2),store.duePolicyRecovery(0,10).map { it.room })
            store.duePolicyRecovery(0,10).forEach { store.failPolicyRecovery(it,PolicyRecoveryDisposition.Retry(90000)) }
            assertEquals(2,store.discoverPolicyRecovery(2));assertEquals(rooms.drop(4),store.duePolicyRecovery(0,10).map { it.room })
            assertEquals(0,store.discoverPolicyRecovery(2))
        } finally { store.close() }
    }
}
