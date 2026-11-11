package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import java.util.UUID
import kotlin.test.*

private class MemoryPolicies: RolePolicyRecoveryStore {
    var works = persistentListOf<PolicyRecoveryRequest>();var failures = persistentListOf<PolicyRecoveryDisposition>();var completed = 0;var reset = false
    override suspend fun discoverPolicyRecovery(limit: Int): Int { if(reset) throw PolicyRecoverySyncPending();return 0 }
    override suspend fun duePolicyRecovery(now: Long,limit: Int) = works.filter { !it.paused && it.nextAttempt <= now }.take(limit).toPersistentList()
    override suspend fun requestPolicyRecovery(room: RoomId,resume: Boolean) = works.first { it.room == room }
    override suspend fun completePolicyRecovery(request: PolicyRecoveryRequest,baseline: GroupPolicies): Boolean { completed++;works = works.remove(request);return true }
    override suspend fun failPolicyRecovery(request: PolicyRecoveryRequest,disposition: PolicyRecoveryDisposition): Boolean {
        failures = failures.add(disposition);val index = works.indexOf(request)
        works = when(disposition) {
            PolicyRecoveryDisposition.Unauthorized -> works.remove(request)
            PolicyRecoveryDisposition.Pause -> works.set(index,request.copy(paused = true,attempts = request.attempts+1))
            is PolicyRecoveryDisposition.Retry -> works.set(index,request.copy(nextAttempt = disposition.at,attempts = request.attempts+1))
        };return true
    }
}
class RolePolicyRecoveryTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val device = DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private fun room(index: Int) = RoomId("10000000-0000-0000-0000-%012d".format(index))
    private fun work(index: Int = 1) = PolicyRecoveryRequest(UUID.randomUUID().toString().uppercase(),PolicyRecoveryBinding(actor,device,room(index),1,2,"source",1,"grant"))
    private fun baseline(room: RoomId) = GroupPolicies(room,5,2,20,persistentSetOf(),persistentSetOf(GroupPermission.Send))
    @Test fun `runner respects bounded batch and excludes paused and future requests`() = runTest {
        val store = MemoryPolicies();store.works = persistentListOf(work(1).copy(paused = true),work(2).copy(nextAttempt = 5000),work(3),work(4))
        val rooms = mutableListOf<RoomId>();val runner = RolePolicyRecoveryRunner(store,{ rooms.add(it);baseline(it) },1,{1000})
        assertEquals(1,runner.recoverOnce());assertEquals(listOf(room(3)),rooms);assertEquals(1,store.completed)
        assertEquals(1,runner.recoverOnce());assertEquals(listOf(room(3),room(4)),rooms)
    }
    @Test fun `server retry floor and capped exponential backoff persist per room`() = runTest {
        val store = MemoryPolicies();store.works = persistentListOf(work());var now = 1000L
        var failure: Exception = GatewayFailure("BUSY",true,90)
        val runner = RolePolicyRecoveryRunner(store,{ throw failure },now = {now})
        runner.recoverOnce();assertEquals(91000L,store.works.single().nextAttempt);assertEquals(1,store.works.single().attempts)
        assertEquals(0,runner.recoverOnce());now = 91000;failure = IOException();runner.recoverOnce();assertEquals(93000L,store.works.single().nextAttempt)
        store.works = persistentListOf(work().copy(attempts = 20));runner.recoverOnce();assertEquals(151000L,store.works.single().nextAttempt)
    }
    @Test fun `malformed and terminal errors pause while forbidden stops access and session errors propagate`() = runTest {
        for(error in listOf(ClientFailure.Protocol(),GatewayFailure("INVALID_ARGUMENT",false,0),GatewayFailure("FORBIDDEN",false,0),GatewayFailure("SESSION_REVOKED",false,0))) {
            val store = MemoryPolicies();store.works = persistentListOf(work());val runner = RolePolicyRecoveryRunner(store,{ throw error })
            if(error is GatewayFailure && error.code == "SESSION_REVOKED") { assertFailsWith<GatewayFailure> { runner.recoverOnce() };assertTrue(store.failures.isEmpty()) }
            else { runner.recoverOnce();assertEquals(if(error is GatewayFailure && error.code == "FORBIDDEN") PolicyRecoveryDisposition.Unauthorized else PolicyRecoveryDisposition.Pause,store.failures.single()) }
        }
    }
    @Test fun `cancellation never becomes a durable rejection or retry`() = runTest {
        val store = MemoryPolicies();store.works = persistentListOf(work());val entered = CompletableDeferred<Unit>()
        val runner = RolePolicyRecoveryRunner(store,{ entered.complete(Unit);awaitCancellation() })
        val job = launch { runner.recoverOnce() };entered.await();job.cancelAndJoin()
        assertEquals(0,store.completed);assertTrue(store.failures.isEmpty());assertEquals(0,store.works.single().attempts)
    }
    @Test fun `overlapping runner returns zero and reset prevents any request`() = runTest {
        val store = MemoryPolicies();store.works = persistentListOf(work());store.reset = true;var calls = 0
        val gate = CompletableDeferred<Unit>();val entered = CompletableDeferred<Unit>()
        val runner = RolePolicyRecoveryRunner(store,{ calls++;entered.complete(Unit);gate.await();baseline(it) })
        assertEquals(0,runner.recoverOnce());assertEquals(0,calls);store.reset = false
        val first = async { runner.recoverOnce() };entered.await();assertEquals(0,runner.recoverOnce());gate.complete(Unit);assertEquals(1,first.await());assertEquals(1,calls)
    }
    @Test fun `bounded read timeout retries without terminalizing the room`() = runTest {
        val store = MemoryPolicies();store.works = persistentListOf(work())
        val runner = RolePolicyRecoveryRunner(store,{ delay(20000);baseline(it) },now = {1000})
        assertEquals(1,runner.recoverOnce());assertEquals(2000L,store.works.single().nextAttempt);assertFalse(store.works.single().paused)
    }
}
