package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID

internal suspend fun verifyOwnProfileBackend(context: Context,a: Credentials,b: Credentials,initial: SqliteClientStore,
    api: AuthenticatedTransport,peerApi: AuthenticatedTransport,transport: AccountClient,run: String,password: String): SqliteClientStore {
    var store = initial;var phase = "own baseline"
    val client = OwnProfileClient(api,a.userId)
    val otherAuth = AuthSession(KeystoreSecretStore(context,"e2e-$run-own-profile-other"),transport)
    try {
        val original = client.current();assertEquals(a.userId,original.user);store.saveOwnProfile(original)
        val other = otherAuth.login("device_${run}_a",password);assertEquals(a.userId,other.userId);assertNotEquals(a.deviceId,other.deviceId)
        val otherClient = OwnProfileClient(AuthenticatedApi(otherAuth,transport,other.userId,other.deviceId),a.userId)
        fun command(base: ProfileView,name: String) = OwnProfileCommand(a.userId,UUID.randomUUID().toString().uppercase(),base.revision,OwnProfilePatch(name),System.currentTimeMillis()+86400000)
        var dropped = false
        val lossy = object: OwnProfileTransport by client {
            override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt {
                val result = client.submit(command);if(!dropped) { dropped = true;throw java.io.IOException("simulated lost profile reply") };return result
            }
        }
        var service = OwnProfileService(a.userId,lossy,store)
        val first = service.save(original,OwnProfilePatch("首次公开修改 $run"));service.flush();assertTrue(dropped)
        val afterFirst = otherClient.current();assertEquals(original.revision+1,afterFirst.revision)
        val changed = otherClient.submit(command(afterFirst,"另一设备修改 $run"));assertEquals(OwnProfileStatus.Committed,changed.status)
        phase = "reopen original receipt with newer current snapshot"
        store.close();store = SqliteClientStore(context,a.userId,a.deviceId);service = OwnProfileService(a.userId,client,store)
        suspend fun settle(operation: String): OwnProfileWork {
            withTimeout(30000) { while(!store.ownProfileWorks().first { it.command.operation == operation }.terminal) { service.flush();delay(100) } }
            return store.ownProfileWorks().first { it.command.operation == operation }
        }
        val recovered = settle(first.command.operation);assertEquals(OwnProfileStatus.Committed,recovered.status)
        assertEquals(first.command,recovered.command);assertEquals(changed.snapshot,store.ownProfile())
        val oldResult = OwnProfileClient.decodeResult(first.command,kotlinx.serialization.json.Json.parseToJsonElement(recovered.receipt!!).let { it as kotlinx.serialization.json.JsonObject })
        assertEquals(afterFirst.revision,oldResult.revision);assertEquals(changed.revision,oldResult.snapshot!!.revision)
        phase = "conflict and explicit reapplication"
        val draft = service.save(requireNotNull(store.ownProfile()),OwnProfilePatch("本机重新确认 $run"))
        val competing = otherClient.submit(command(otherClient.current(),"另一设备再次修改 $run"));assertEquals(OwnProfileStatus.Committed,competing.status)
        assertEquals(OwnProfileStatus.Conflicted,settle(draft.command.operation).status)
        val replacement = service.reapply(draft.command.operation);assertNotEquals(draft.command.operation,replacement.command.operation)
        assertEquals(competing.revision,replacement.command.revision);assertEquals(draft.command.patch,replacement.command.patch)
        assertEquals(OwnProfileStatus.Committed,settle(replacement.command.operation).status)
        assertEquals(draft.command,store.ownProfileWorks().first { it.command.operation == draft.command.operation }.command)
        val current = service.refresh();assertEquals("本机重新确认 $run",current.identity!!.displayName)
        val replay = client.submit(first.command);assertEquals(afterFirst.revision,replay.revision);assertEquals(current,replay.snapshot)
        phase = "unchanged commit and authorized peer name"
        val noop = client.submit(command(current,current.identity!!.displayName));assertEquals(current.revision,noop.revision);assertEquals(current,noop.snapshot)
        val peer = ProfilePresentationClient(peerApi,b.userId,b.deviceId);val key = ProfileKey(a.userId,ProfileContext.DirectConversation)
        withTimeout(15000) { while(true) {
            val visible = peer.read(persistentListOf(key)).single() as? ProfileReadResult.Available
            if(visible?.profile?.view?.identity?.displayName == current.identity!!.displayName) break
            delay(250)
        } }
        phase = "close absent identity and restore original public name"
        val absent = command(current,"从未提交")
        assertEquals(OwnProfileStatus.Closed,(client.recover(absent,true) as OwnProfileResult.Receipt).status)
        assertEquals(OwnProfileStatus.Closed,client.submit(absent).status)
        val restored = service.save(service.refresh(),OwnProfilePatch(original.identity!!.displayName));assertEquals(OwnProfileStatus.Committed,settle(restored.command.operation).status)
        assertEquals(original.identity!!.displayName,service.refresh().identity!!.displayName)
        return store
    } catch(error: Throwable) { if(store !== initial) store.close();throw AssertionError("Own profile failed during $phase",error) }
    finally { withContext(NonCancellable) { withTimeout(30000) { otherAuth.logout() } } }
}
