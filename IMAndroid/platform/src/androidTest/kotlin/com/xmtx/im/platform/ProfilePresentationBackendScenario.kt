package com.xmtx.im.platform

import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*

internal suspend fun verifyProfilePresentationBackend(a: Credentials,b: Credentials,store: SqliteClientStore,api: AuthenticatedTransport,
    peerApi: AuthenticatedTransport,socket: RealtimeConnection,run: String) {
    var phase = "direct context"
    val client = ProfilePresentationClient(api,a.userId,a.deviceId)
    val peer = ProfilePresentationClient(peerApi,b.userId,b.deviceId)
    try {
        val direct = ProfileKey(b.userId,ProfileContext.DirectConversation)
        val conversation = store.snapshot().conversations.single { it.kind == RoomKind.Direct && it.peer == b.userId }
        assertEquals("会话",conversation.title)
        val authorKey = ProfileKey(b.userId,ProfileContext.Room(conversation.id))
        val directResults = client.read(persistentListOf(direct,authorKey))
        val directResult = directResults.first() as ProfileReadResult.Available
        val author = directResults.last() as ProfileReadResult.Available
        assertEquals(authorKey,author.key);assertEquals("设备 B",author.profile.displayName())
        assertTrue(directResult.valid());assertEquals("设备 B",directResult.profile.view.identity!!.displayName)
        assertEquals(a.userId,directResult.profile.lease.actor);assertEquals(a.deviceId,directResult.profile.lease.device)
        phase = "create profile room"
        val groups = GroupCreationService(a.userId,GroupCreationClient(api),store)
        val creation = groups.prepare("授权资料 $run",persistentListOf(b.userId))
        withTimeout(30000) { while(!store.groupWorks().first { it.command.operation == creation.command.operation }.terminal) { groups.flush();delay(100) } }
        val room = requireNotNull(store.groupWorks().first { it.command.operation == creation.command.operation }.room)
        val ownerKey = ProfileKey(b.userId,ProfileContext.Room(room));val peerKey = ProfileKey(a.userId,ProfileContext.Room(room))
        val owner = client.read(persistentListOf(ownerKey)).single() as ProfileReadResult.Available
        assertEquals("设备 B",owner.profile.displayName());assertEquals(room,owner.profile.lease.authority.room)
        val scope = ProfilePresentationScope(b.userId,b.deviceId,peer)
        try {
            phase = "member profile read"
            scope.interests(persistentListOf(peerKey));scope.refresh()
            val original = requireNotNull(scope.snapshot().profiles[peerKey])
            assertEquals("设备 A",original.profile.displayName())
            val members = MembershipService(a.userId,MembershipClient(api),store)
            suspend fun change(action: MembershipAction) {
                val baseline = MemberDirectory(socket).page(room)
                val work = members.enqueue(b.userId,members.confirmation(room,action,baseline.revision))
                withTimeout(30000) { while(!store.membershipWorks().first { it.intent.operation == work.intent.operation }.terminal) { members.flush();delay(100) } }
                assertEquals(MembershipStatus.Committed,store.membershipWorks().first { it.intent.operation == work.intent.operation }.status)
            }
            phase = "removal denies cached member presentation"
            change(MembershipAction.Remove)
            withTimeout(15000) { do { scope.refresh();if(peerKey !in scope.snapshot().unavailable) delay(250) } while(peerKey !in scope.snapshot().unavailable) }
            assertTrue(scope.snapshot().profiles.isEmpty())
            phase = "rejoin requires newer authority"
            change(MembershipAction.Add)
            withTimeout(15000) { while(scope.snapshot().profiles.isEmpty()) { scope.refresh();if(scope.snapshot().profiles.isEmpty()) delay(250) } }
            val restored = requireNotNull(scope.snapshot().profiles[peerKey])
            assertTrue(restored.profile.lease.authority.isAtLeast(original.profile.lease.authority))
            assertTrue(restored.profile.lease.authority.membership > original.profile.lease.authority.membership)
            assertEquals("设备 A",restored.profile.displayName());assertTrue(scope.snapshot().unavailable.isEmpty())
        } finally { scope.close();assertTrue(scope.snapshot().profiles.isEmpty()) }
    } catch(error: Throwable) { throw AssertionError("Profile presentation failed during $phase",error) }
}
