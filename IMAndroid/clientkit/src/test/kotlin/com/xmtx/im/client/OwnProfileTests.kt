package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class OwnProfileTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val op = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private val media = "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    private val lines get() = javaClass.getResourceAsStream("/own-profile-swift.txt")!!.bufferedReader().readLines()
    private fun wire(index: Int) = Json.parseToJsonElement(lines[index]).jsonObject
    private fun command(index: Int = 0) = OwnProfileCommand(actor,op,3,when(index) {
        0 -> OwnProfilePatch("Café");1 -> OwnProfilePatch(avatar = ProfileAvatarPatch.Remove);else -> OwnProfilePatch("新名称",ProfileAvatarPatch.Set(media))
    },1700000000000)
    private fun profile(revision: Long = 4,name: String = "Café") = ProfileView(actor,PublicIdentity(actor,PublicHandle("own_account"),name,AccountKind.Regular),null,ProfileState.Active,revision,revision+2)
    @Test fun `Swift patches fingerprints original results and recovery preserve current snapshot separately`() = runTest {
        for(index in 0..2) {
            val offset = index*8;val command = command(index)
            assertEquals(wire(offset),command.payload());assertEquals(wire(offset+1).string("digest"),command.fingerprint);assertEquals(wire(offset+4),command.recovery(false))
            val api = object: AuthenticatedTransport {
                override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse {
                    assertEquals(65536L,maximumBytes)
                    return if(payload == null) { assertEquals("/v2/profile/me",path);EdgeResponse(200,wire(offset+2)) }
                    else { assertEquals("/v2/profile/me/operations/recover",path);assertEquals(command.recovery(false),payload);EdgeResponse(200,wire(offset+5)) }
                }
                override suspend fun putWithoutReplay(path: String,payload: JsonObject,maximumBytes: Long): EdgeResponse {
                    assertEquals("/v2/profile/me",path);assertEquals(command.payload(),payload);return EdgeResponse(200,wire(offset+3))
                }
            }
            val client = OwnProfileClient(api,actor);val current = client.current();assertEquals(wire(offset+2),OwnProfileClient.profilePayload(current))
            val result = client.submit(command);assertEquals(current,result.snapshot);assertEquals(4L,result.revision);assertEquals(result,client.recover(command,false))
            val replay = OwnProfileClient.decodeResult(command,wire(offset+6));assertEquals(4L,replay.revision);assertEquals(5L,replay.snapshot!!.revision);assertEquals("另一设备的名称",replay.snapshot.identity!!.displayName)
            val conflict = OwnProfileClient.decodeResult(command,wire(offset+7));assertEquals(OwnProfileStatus.Conflicted,conflict.status);assertEquals(5L,conflict.conflictRevision)
        }
    }
    @Test fun `normalization no-op revision and corrupt or unrelated receipt claims are validated`() {
        assertEquals("Café",OwnProfilePatch.normalizedName(" Cafe\u0301 \n"))
        for(input in listOf("","a\tb","a\nb","a\u0000b","a".repeat(81),"a\u00a0b")) assertFails { OwnProfilePatch.normalizedName(input) }
        assertFails { OwnProfilePatch() };assertFails { OwnProfilePatch("e\u0301") }
        val unchanged = JsonObject(wire(3)+( "currentSnapshot" to OwnProfileClient.profilePayload(profile(3))))
        val noop = Json.parseToJsonElement(unchanged.toString().replace("\"revision\":4","\"revision\":3").replace("\"visibilityRevision\":6","\"visibilityRevision\":5")).jsonObject
        assertEquals(3L,OwnProfileClient.decodeResult(command(),noop).revision)
        for((from,to) in listOf("\"revision\":4" to "\"revision\":2","\"revision\":4" to "\"revision\":7",
            "\"visibilityRevision\":6" to "\"visibilityRevision\":0","\"version\":1" to "\"version\":\"1\"",
            "Café" to "different",actor.value to media,"\"resolvedAtMilliseconds\":1699999999999" to "\"resolvedAtMilliseconds\":-1")) {
            assertFails { OwnProfileClient.decodeResult(command(),Json.parseToJsonElement(lines[3].replace(from,to)).jsonObject) }
        }
        val extra = JsonObject(wire(3)+("unknownDownloadPlan" to JsonPrimitive("discard-this")))
        assertFalse(OwnProfileClient.decodeResult(command(),extra).wire.contains("discard-this"))
    }
    private class Store(initial: OwnProfileWork,val latest: ProfileView): OwnProfileStore {
        var work = initial;var replaced: String? = null
        override suspend fun ownProfile() = latest
        override suspend fun ownProfileWorks() = persistentListOf(work)
        override suspend fun saveOwnProfile(profile: ProfileView) = latest
        override suspend fun enqueueOwnProfile(command: OwnProfileCommand,replaces: String?) = OwnProfileWork(command).also { work = it;replaced = replaces }
        override suspend fun updateOwnProfile(expected: OwnProfileWork,updated: OwnProfileWork) { assertEquals(work,expected);work = updated }
        override suspend fun discardOwnProfileDraft(operation: String) { require(work.terminal);work = work.copy(draftRetained = false) }
    }
    @Test fun `lost reply persists uncertainty then recovery never changes original command`() = runTest {
        var now = 1000L;val command = command();val store = Store(OwnProfileWork(command),profile());val calls = mutableListOf<String>()
        val client = object: OwnProfileTransport {
            override suspend fun current() = profile()
            override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt {
                assertCommandAttempt(calls.isNotEmpty());assertTrue(store.work.submissionStarted && store.work.reconcile);calls.add("put");throw java.io.IOException()
            }
            override suspend fun recover(command: OwnProfileCommand,close: Boolean): OwnProfileResult {
                assertCommandAttempt(true)
                assertEquals(store.work.command,command);calls.add(if(close) "close" else "query");return OwnProfileClient.decodeResult(command,wire(6))
            }
        }
        OwnProfileService(actor,client,store,{now}).flush();assertTrue(store.work.reconcile);now = store.work.nextAttempt
        OwnProfileService(actor,client,store,{now}).flush();assertEquals(listOf("put","query"),calls);assertEquals(command,store.work.command)
        assertEquals(OwnProfileStatus.Committed,store.work.status);assertFalse(store.work.draftRetained)
    }
    @Test fun `reapply requires terminal outcome and freezes highest stored revision with new identity`() = runTest {
        val original = command();val store = Store(OwnProfileWork(original,OwnProfileStatus.NeedsAttention),profile(8,"当前名称"))
        val client = object: OwnProfileTransport {
            override suspend fun current() = profile(6,"迟到的副本")
            override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt = error("unused")
            override suspend fun recover(command: OwnProfileCommand,close: Boolean): OwnProfileResult = error("unused")
        }
        val service = OwnProfileService(actor,client,store,{1000})
        assertFails { service.reapply(op) };service.retry(op);assertEquals(original,store.work.command)
        store.work = store.work.copy(status = OwnProfileStatus.Conflicted)
        val replacement = service.reapply(op);assertNotEquals(op,replacement.command.operation);assertEquals(original.patch,replacement.command.patch)
        assertEquals(8L,replacement.command.revision);assertEquals(86401000L,replacement.command.deadline);assertEquals(op,store.replaced)
    }
    @Test fun `deadline expires only never submitted work and uncertain operation closes original identity`() = runTest {
        val command = command().copy(deadline = 1000);val store = Store(OwnProfileWork(command),profile());var closed = false
        val client = object: OwnProfileTransport {
            override suspend fun current() = profile()
            override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt = error("expired put")
            override suspend fun recover(command: OwnProfileCommand,close: Boolean): OwnProfileResult { assertTrue(close);closed = true;return OwnProfileResult.Unresolved }
        }
        val service = OwnProfileService(actor,client,store,{2000});service.flush();assertEquals(OwnProfileStatus.Expired,store.work.status);assertFalse(closed)
        store.work = OwnProfileWork(command,submissionStarted = true,reconcile = true);service.flush();assertTrue(closed);assertTrue(store.work.reconcile)
    }
    @Test fun `retry after budget and cancellation preserve original uncertainty`() = runTest {
        var now = 1000L;val store = Store(OwnProfileWork(command()),profile())
        val client = object: OwnProfileTransport {
            override suspend fun current() = profile()
            override suspend fun submit(command: OwnProfileCommand): OwnProfileResult.Receipt = throw ClientFailure.Http(429,retryAfter = "120")
            override suspend fun recover(command: OwnProfileCommand,close: Boolean): OwnProfileResult = throw CancellationException()
        }
        val service = OwnProfileService(actor,client,store,{now});service.flush();assertEquals(OwnProfileStatus.NeedsAttention,store.work.status)
        service.retry(op);service.flush();assertEquals(0,store.work.attempts);assertEquals(121000L,store.work.nextAttempt)
        now = store.work.nextAttempt;assertFailsWith<CancellationException> { service.flush() };assertEquals(1,store.work.attempts);assertTrue(store.work.reconcile)
    }
    @Test fun `profile diagnostic observes original conflict rather than newer current profile`() = runTest {
        val diagnostics=NetworkDiagnostics();val store=Store(OwnProfileWork(command()),profile(8))
        val client=object:OwnProfileTransport {
            override suspend fun current()=profile(8)
            override suspend fun submit(command:OwnProfileCommand)=OwnProfileClient.decodeResult(command,wire(7))
            override suspend fun recover(command:OwnProfileCommand,close:Boolean):OwnProfileResult=error("unused")
        }
        withContext(NetworkDiagnosticsScope(diagnostics)) {OwnProfileService(actor,client,store,{1000}).flush()}
        val sample=diagnostics.snapshot().operations.single()
        assertEquals(OperationKind.ProfileUpdate,sample.kind);assertEquals(OperationWorkAction.Submit,sample.action)
        assertEquals(OperationExecutionState.Conflicted,sample.observation?.execution)
        assertEquals(OperationSchedulingState.Finished,sample.observation?.scheduling)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,sample.certainty)
    }

}
