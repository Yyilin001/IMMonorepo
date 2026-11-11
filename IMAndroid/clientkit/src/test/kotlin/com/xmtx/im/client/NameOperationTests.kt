package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

class NameOperationTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val target = NameTarget.Contact(UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
    private val group = NameTarget.Group(RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
    private val op = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private val lines get() = javaClass.getResourceAsStream("/name-operations-swift.txt")!!.bufferedReader().readLines()
    private fun wire(index: Int) = Json.parseToJsonElement(lines[index]).jsonObject
    private fun command(clear: Boolean = false,groupName: Boolean = false) = NameCommand(actor,if(groupName) group else target,op,
        if(clear) null else if(groupName) "我的群昵称" else "Café",if(clear) 3 else null,1700000000000)
    @Test fun `Swift commands fingerprints snapshots receipts and recovery match for set and clear`() = runTest {
        for(clear in listOf(false,true)) for(isGroup in listOf(false,true)) {
            val index = (if(clear) 12 else 0)+(if(isGroup) 6 else 0);val command = command(clear,isGroup)
            assertEquals(wire(index),command.payload());assertEquals(wire(index+1).string("digest"),command.fingerprint)
            assertEquals(wire(index+4),command.recovery(isGroup))
            assertEquals(if(isGroup) "/v2/profile-presentations/groups/DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD/nickname" else "/v2/profile-presentations/contact-aliases/BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",command.target.path)
            val snapshot = NameOperationClient.decodeSnapshot(actor,command.target,wire(index+2));assertEquals(command.name,snapshot.name)
            val api = object: AuthenticatedTransport {
                override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse {
                    assertEquals(65536L,maximumBytes);return if(payload == null) { assertEquals(command.target.path,path);EdgeResponse(200,wire(index+2)) }
                    else { assertEquals(command.target.path+"/operations/recover",path);assertEquals(command.recovery(isGroup),payload);EdgeResponse(200,wire(index+5)) }
                }
                override suspend fun putWithoutReplay(path: String,payload: JsonObject,maximumBytes: Long): EdgeResponse {
                    assertEquals(command.target.path,path);assertEquals(command.payload(),payload);return EdgeResponse(200,wire(index+3))
                }
            }
            val client = NameOperationClient(api);assertEquals(snapshot,client.snapshot(actor,command.target))
            assertEquals(snapshot,client.submit(command).snapshot);assertEquals(client.submit(command),client.recover(command,isGroup))
        }
    }
    @Test fun `name normalization limits and hostile receipt claims fail closed`() {
        assertEquals("Café",NameCommand.normalizedName(" Cafe\u0301 \n"));assertNull(NameCommand.normalizedName(" \n"))
        assertFails { command().copy(name = "a".repeat(81)) };assertFails { command().copy(name = "a\u0000") }
        assertFails { command().copy(name = "e\u0301") };assertFails { command().copy(target = NameTarget.Contact(actor)) }
        assertFails { command().copy(revision = 0) };assertFails { command().copy(revision = Long.MAX_VALUE) }
        for((from,to) in listOf("\"revision\":1" to "\"revision\":2","\"revision\":1" to "\"revision\":\"1\"",
            "\"remarkName\":\"Café\"" to "\"remarkName\":\"other\"","\"version\":1" to "\"version\":\"1\"",
            "\"resolvedAtMilliseconds\":1699999999999" to "\"resolvedAtMilliseconds\":-1",target.user.value to actor.value)) {
            assertFails { NameOperationClient.decodeReceipt(command(),Json.parseToJsonElement(lines[3].replace(from,to)).jsonObject) }
        }
        assertFails { NameOperationClient.decodeSnapshot(actor,group,wire(2)) }
    }
    private class Store(initial: NameWork): NameOperationStore {
        var work = initial
        override suspend fun nameWorks() = persistentListOf(work)
        override suspend fun saveNameSnapshot(snapshot: NameSnapshot) = snapshot
        override suspend fun enqueueName(command: NameCommand) = NameWork(command).also { work = it }
        override suspend fun updateName(expected: NameWork,updated: NameWork) { assertEquals(work,expected);work = updated }
    }
    @Test fun `uncertain PUT survives restart then queries before exact replay`() = runTest {
        var now = 1000L;val command = command().copy(deadline = 100000);val store = Store(NameWork(command));val calls = mutableListOf<String>()
        val client = object: NameTransport {
            override suspend fun snapshot(actor: UserId,target: NameTarget) = error("unused")
            override suspend fun submit(command: NameCommand): NameResult.Receipt {
                assertCommandAttempt(calls.isNotEmpty());assertTrue(store.work.submissionStarted && store.work.reconcile);assertEquals(command,store.work.command);calls.add("put");throw java.io.IOException()
            }
            override suspend fun recover(command: NameCommand,close: Boolean): NameResult {
                assertCommandAttempt(true)
                calls.add(if(close) "close" else "query");return NameResult.Unresolved
            }
        }
        NameOperationService(actor,client,store,{now}).flush();assertEquals(listOf("put"),calls)
        now = store.work.nextAttempt;val restarted = NameOperationService(actor,client,store,{now});restarted.flush();assertEquals(listOf("put","query"),calls)
        now = store.work.nextAttempt;restarted.flush();assertEquals(listOf("put","query","put"),calls)
        restarted.discard(command.operation);assertTrue(store.work.closeRequested)
        now = store.work.nextAttempt;restarted.flush();assertEquals("close",calls.last());assertEquals(command,store.work.command)
        now = store.work.nextAttempt;restarted.flush();assertEquals("close",calls.last())
    }
    @Test fun `recovery rounds and retry after are bounded and cancellation keeps uncertainty`() = runTest {
        var now = 1000L;val store = Store(NameWork(command()))
        val client = object: NameTransport {
            override suspend fun snapshot(actor: UserId,target: NameTarget) = error("unused")
            override suspend fun submit(command: NameCommand): NameResult.Receipt = throw ClientFailure.Http(429,retryAfter = "120")
            override suspend fun recover(command: NameCommand,close: Boolean): NameResult = throw CancellationException()
        }
        val service = NameOperationService(actor,client,store,{now});service.flush()
        assertEquals(NameStatus.NeedsAttention,store.work.status);assertEquals(121000L,store.work.nextAttempt)
        service.retry(op);service.flush();assertEquals(0,store.work.attempts)
        now = 121000;assertFailsWith<CancellationException> { service.flush() };assertTrue(store.work.reconcile);assertEquals(1,store.work.attempts)
        val fresh = Store(NameWork(command().copy(deadline = 999)));NameOperationService(actor,client,fresh,{now}).flush()
        assertEquals(NameStatus.Cancelled,fresh.work.status);assertFalse(fresh.work.submissionStarted)
    }
    @Test fun `five unresolved attempts stop and explicit retry preserves original command`() = runTest {
        var now = 1000L;val command = command();val store = Store(NameWork(command,reconcile = true,submissionStarted = true))
        val client = object: NameTransport {
            override suspend fun snapshot(actor: UserId,target: NameTarget) = error("unused")
            override suspend fun submit(command: NameCommand): NameResult.Receipt = throw java.io.IOException()
            override suspend fun recover(command: NameCommand,close: Boolean) = NameResult.Unresolved
        }
        val service = NameOperationService(actor,client,store,{now})
        repeat(5) { service.flush();now = store.work.nextAttempt }
        assertEquals(5,store.work.attempts);assertEquals(NameStatus.NeedsAttention,store.work.status)
        service.retry(op);assertEquals(command,store.work.command);assertEquals(0,store.work.attempts)
    }
    @Test fun `diagnostics distinguish successful return from durable settlement and query action`() = runTest {
        var now=1000L;val store=Store(NameWork(command()));val diagnostics=NetworkDiagnostics()
        val client=object:NameTransport {
            override suspend fun snapshot(actor:UserId,target:NameTarget)=error("unused")
            override suspend fun submit(command:NameCommand):NameResult.Receipt=throw java.io.IOException()
            override suspend fun recover(command:NameCommand,close:Boolean)=NameOperationClient.decodeReceipt(command,wire(3))
        }
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            val service=NameOperationService(actor,client,store,{now});service.flush()
            val initial=diagnostics.snapshot().operations.single()
            assertEquals(OperationWorkAction.Submit,initial.action);assertEquals(OperationKind.ContactAlias,initial.kind)
            assertEquals(OperationStepMetric.Completion.Returned,initial.completion)
            assertEquals(OperationExecutionState.AwaitingConfirmation,initial.observation?.execution)
            assertEquals(OperationSchedulingState.BackingOff,initial.observation?.scheduling)
            assertEquals(NetworkMetric.Certainty.OutcomeUnknown,initial.certainty)
            now=store.work.nextAttempt;service.flush()
        }
        val settled=diagnostics.snapshot().operations.last()
        assertEquals(OperationWorkAction.Reconcile,settled.action);assertEquals(2,settled.attempt)
        assertEquals(NetworkWorkPriority.Recovery,settled.priority)
        assertEquals(OperationExecutionState.Committed,settled.observation?.execution)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,settled.certainty)
    }

}
