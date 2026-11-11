package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*

internal suspend fun verifyPolicyRecoveryBackend(context: Context,a: Credentials,b: Credentials,first: SqliteClientStore,second: SqliteClientStore,
    api: AuthenticatedTransport,aSocket: RealtimeConnection,bSocket: RealtimeConnection,run: String): SqliteClientStore {
    var store = first
    var phase = "create group"
    try {
        val creator = GroupCreationService(a.userId,GroupCreationClient(api),store)
        val draft = creator.prepare("完整权限恢复 $run",persistentListOf(b.userId))
        withTimeout(30000) { while(!store.groupWorks().first { it.command.operation == draft.command.operation }.terminal) { creator.flush();delay(100) } }
        val room = requireNotNull(store.groupWorks().first { it.command.operation == draft.command.operation }.room)
        suspend fun sync() = backendSync { SyncEngine(aSocket,store).synchronize();SyncEngine(bSocket,second).synchronize();RoomSyncEngine(aSocket,store).synchronize();RoomSyncEngine(bSocket,second).synchronize() }
        phase = "initial baseline"
        sync()
        val request = store.requestPolicyRecovery(room);val baseline = MemberDirectory(aSocket).policies(room)
        store.close();store = SqliteClientStore(context,a.userId,a.deviceId)
        assertEquals(request,store.requestPolicyRecovery(room));assertTrue(store.completePolicyRecovery(request,baseline))
        val peerBaseline = MemberDirectory(bSocket).policies(room);assertTrue(second.completePolicyRecovery(second.requestPolicyRecovery(room),peerBaseline))
        assertTrue(store.snapshot().rolePolicies.none { it.room == room }) // A read is not a pair of synthetic role events.
        val initial = store.snapshot().groupPolicyStates.single { it.room == room }
        assertEquals(PolicyRecoveryStatus.Ready,initial.status);assertEquals(baseline.admin,initial.policies.first { it.role == MemberRole.Admin }.permissions)
        assertEquals(baseline.member,initial.policies.first { it.role == MemberRole.Member }.permissions)
        val capabilities = GroupCapabilityService(a.userId,GroupCapabilityClient(api),store)
        val empty = capabilities.enqueue(capabilities.confirmation(room,GroupAction.Permissions(MemberRole.Member,persistentSetOf(),baseline.revision)))
        withTimeout(30000) { while(!store.capabilityWorks().first { it.intent.operation == empty.intent.operation }.terminal) { capabilities.flush();delay(100) } }
        assertEquals(GroupCapabilityStatus.Committed,store.capabilityWorks().first { it.intent.operation == empty.intent.operation }.status)
        phase = "observe permission event"
        withTimeout(15000) { while(listOf(store,second).any { target -> target.snapshot().groupPolicyStates.first { it.room == room }.policies.any { it.revision != baseline.revision+1 } }) { sync();delay(100) } }
        for(target in listOf(store,second)) {
            val state = target.snapshot().groupPolicyStates.first { it.room == room }
            assertEquals(baseline.admin,state.policies.first { it.role == MemberRole.Admin }.permissions)
            assertTrue(state.policies.first { it.role == MemberRole.Member }.permissions.isEmpty())
            assertEquals(listOf(MemberRole.Member),target.snapshot().rolePolicies.filter { it.room == room }.map { it.role })
        }
        store.close();store = SqliteClientStore(context,a.userId,a.deviceId)
        assertTrue(store.snapshot().groupPolicyStates.first { it.room == room }.policies.first { it.role == MemberRole.Member }.permissions.isEmpty())
        phase = "remove peer"
        val oldRequest = store.requestPolicyRecovery(room);val oldRead = MemberDirectory(aSocket).policies(room)
        val peerRequest = second.requestPolicyRecovery(room)
        val members = MembershipService(a.userId,MembershipClient(api),store)
        val remove = members.enqueue(b.userId,members.confirmation(room,MembershipAction.Remove,MemberDirectory(aSocket).page(room).revision))
        withTimeout(30000) { while(!store.membershipWorks().first { it.intent.operation == remove.intent.operation }.terminal) { members.flush();delay(100) } }
        assertEquals(MembershipStatus.Committed,store.membershipWorks().first { it.intent.operation == remove.intent.operation }.status)
        // Other members observe removal in the room log; only the removed peer receives personal state.
        // Keep the peer unsynchronized while fencing the owner’s older read.
        phase = "observe membership removal"
        withTimeout(15000) { do { RoomSyncEngine(aSocket,store).synchronize();delay(100) } while(store.snapshot().memberAccess.none { it.room == room && it.user == b.userId && it.action == MemberEffectAction.Remove }) }
        assertFalse(store.completePolicyRecovery(oldRequest,oldRead))
        // The removed peer has not yet consumed revocation; a live baseline refusal must hide cached policies immediately.
        phase = "reject removed peer baseline"
        val peerRecovery = RolePolicyRecoveryRunner(second,MemberDirectory(bSocket)::policies,batchSize = 100)
        withTimeout(15000) { while(second.snapshot().groupPolicyStates.first { it.room == room }.status != PolicyRecoveryStatus.Unavailable) { peerRecovery.recoverOnce();delay(100) } }
        assertTrue(second.snapshot().groupPolicyStates.first { it.room == room }.policies.isEmpty());assertFalse(second.completePolicyRecovery(peerRequest,peerBaseline))
        phase = "refresh owner baseline"
        val recovery = RolePolicyRecoveryRunner(store,MemberDirectory(aSocket)::policies,batchSize = 100)
        withTimeout(15000) { while(store.snapshot().groupPolicyStates.first { it.room == room }.status != PolicyRecoveryStatus.Ready) { recovery.recoverOnce();delay(100) } }
        assertTrue(requireNotNull(store.snapshot().groupPolicyStates.first { it.room == room }.membershipRevision) > oldRead.membershipRevision)
        sync();assertTrue(second.snapshot().groupPolicyStates.none { it.room == room })
        return store
    } catch(error: Throwable) { store.close();throw AssertionError("Role policy recovery failed during $phase",error) }
}
