package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import java.util.UUID

internal suspend fun verifyNameOperationBackend(context: Context,a: Credentials,b: Credentials,initial: SqliteClientStore,peerStore: SqliteClientStore,
    api: AuthenticatedTransport,peerApi: AuthenticatedTransport,run: String): SqliteClientStore {
    var store = initial;var phase = "private alias baseline"
    val client = NameOperationClient(api);val target = NameTarget.Contact(b.userId)
    try {
        // Earlier social tests intentionally ended the friendship; aliases require an accepted relationship.
        phase = "restore friendship for private alias"
        suspend fun social(service: SocialService,local: SqliteClientStore,target: UserId,action: SocialAction) {
            val work = service.enqueue(target,action)
            withTimeout(30000) { while(!local.socialWorks().first { it.command.operation == work.command.operation }.terminal) { service.flush();delay(100) } }
            assertEquals(SocialWorkStatus.Committed,local.socialWorks().first { it.command.operation == work.command.operation }.status)
        }
        social(SocialService(a.userId,SocialClient(api,a.userId),store),store,b.userId,SocialAction.Request)
        social(SocialService(b.userId,SocialClient(peerApi,b.userId),peerStore),peerStore,a.userId,SocialAction.Accept)
        phase = "private alias baseline"
        val baseline = client.snapshot(a.userId,target);store.saveNameSnapshot(baseline)
        var dropped = false
        val lossy = object: NameTransport by client {
            override suspend fun submit(command: NameCommand): NameResult.Receipt {
                val result = client.submit(command)
                if(!dropped) { dropped = true;throw java.io.IOException("simulated lost name reply") }
                return result
            }
        }
        var service = NameOperationService(a.userId,lossy,store)
        val work = service.save(baseline,"我的私人备注");service.flush();assertTrue(dropped)
        assertTrue(store.nameWorks().first { it.command.operation == work.command.operation }.reconcile)
        phase = "reopen and recover original alias receipt"
        store.close();store = SqliteClientStore(context,a.userId,a.deviceId);service = NameOperationService(a.userId,client,store)
        service.recoverAfterPreviousOwnerDrained()
        suspend fun settled(id: String): NameWork {
            withTimeout(30000) { while(!store.nameWorks().first { it.command.operation == id }.terminal) { service.flush();delay(100) } }
            return store.nameWorks().first { it.command.operation == id }
        }
        assertEquals(NameStatus.Committed,settled(work.command.operation).status)
        val first = service.refresh(target);assertEquals("我的私人备注",first.name);assertEquals((baseline.revision ?: 0)+1,first.revision)
        val display = ProfilePresentationClient(api,a.userId,a.deviceId)
        val key = ProfileKey(b.userId,ProfileContext.DirectConversation)
        assertEquals("我的私人备注",(display.read(persistentListOf(key)).single() as ProfileReadResult.Available).profile.displayName())
        assertEquals(NameStatus.Conflicted,client.submit(work.command.copy(operation = UUID.randomUUID().toString().uppercase(),name = "旧版本覆盖")).status)
        val cleared = service.save(first,null);assertEquals(NameStatus.Committed,settled(cleared.command.operation).status)
        assertNull(service.refresh(target).name)
        assertEquals("设备 B",(display.read(persistentListOf(key)).single() as ProfileReadResult.Available).profile.displayName())
        phase = "group nickname baseline and member presentation"
        val groups = GroupCreationService(a.userId,GroupCreationClient(api),store)
        val creation = groups.prepare("昵称验收 $run",persistentListOf(b.userId))
        withTimeout(30000) { while(!store.groupWorks().first { it.command.operation == creation.command.operation }.terminal) { groups.flush();delay(100) } }
        val room = requireNotNull(store.groupWorks().first { it.command.operation == creation.command.operation }.room)
        val group = NameTarget.Group(room);val groupBaseline = service.refresh(group)
        val nickname = service.save(groupBaseline,"本群昵称");assertEquals(NameStatus.Committed,settled(nickname.command.operation).status)
        val peer = ProfilePresentationClient(peerApi,b.userId,b.deviceId);val author = ProfileKey(a.userId,ProfileContext.Room(room))
        assertEquals("本群昵称",(peer.read(persistentListOf(author)).single() as ProfileReadResult.Available).profile.displayName())
        val removed = service.save(service.refresh(group),null);assertEquals(NameStatus.Committed,settled(removed.command.operation).status)
        assertEquals("设备 A",(peer.read(persistentListOf(author)).single() as ProfileReadResult.Available).profile.displayName())
        return store
    } catch(error: Throwable) { if(store !== initial) store.close();throw AssertionError("Name operations failed during $phase",error) }
}
