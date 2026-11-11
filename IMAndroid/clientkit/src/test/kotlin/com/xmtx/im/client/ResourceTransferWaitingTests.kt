package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ResourceTransferWaitingTests {
    private fun id()=ResourceTransferId(ResourceTransferKind.Download,UUID.randomUUID().toString().uppercase())
    @Test fun `request slot changes to service cooldown then disappears at admission`()=runTest {
        val hub=ResourceTransferWaiting();val id=id();var now=0L
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1),{now},StandardTestDispatcher(testScheduler))
        val held=scheduler.acquire(NetworkWorkContext("account"))
        val pending=async(ResourceTransferWaitScope(id,hub)) {scheduler.withPermit(NetworkWorkContext("account")) {}}
        try {
            runCurrent();assertEquals(ResourceTransferWaitingReason.RequestSlot,hub.state.value[id])
            scheduler.coolDown("account",1000);assertEquals(ResourceTransferWaitingReason.ServiceCooldown,hub.state.value[id])
            scheduler.release(held);assertFalse(pending.isCompleted)
            now=1000;scheduler.setDegraded(false);pending.await();assertTrue(hub.state.value.isEmpty())
        } finally {pending.cancelAndJoin();scheduler.release(held);scheduler.closeAndDrain();hub.close()}
    }
    @Test fun `byte wait ends on cancellation and scheduler close without leaking observation`()=runTest {
        val hub=ResourceTransferWaiting();val id=id()
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=1,interactiveByteReserve=0),dispatcher=StandardTestDispatcher(testScheduler))
        val held=scheduler.acquire(NetworkWorkContext("media",kind=NetworkWorkKind.Download))
        try {
            val pending=launch(ResourceTransferWaitScope(id,hub)) {scheduler.withPermit(NetworkWorkContext("media",kind=NetworkWorkKind.Download)) {}}
            runCurrent();assertEquals(ResourceTransferWaitingReason.TransferSlot,hub.state.value[id]);pending.cancelAndJoin();assertTrue(hub.state.value.isEmpty())
            val next=async(ResourceTransferWaitScope(id,hub)) {runCatching {scheduler.acquire(NetworkWorkContext("media",kind=NetworkWorkKind.Download))}}
            runCurrent();assertNotNull(hub.state.value[id]);scheduler.beginClose();assertTrue(next.await().isFailure);assertTrue(hub.state.value.isEmpty())
        } finally {scheduler.release(held);scheduler.closeAndDrain()}
    }
    @Test fun `retry bucket wait is reported as cooldown and late callbacks cannot revive closed hub`()=runTest {
        val hub=ResourceTransferWaiting();val id=id();var now=0L
        val scheduler=AccountWorkScheduler(nowMillis={now},dispatcher=StandardTestDispatcher(testScheduler))
        try {
            repeat(5) {scheduler.withPermit(NetworkWorkContext("media",isRetry=true)) {}}
            val pending=async(ResourceTransferWaitScope(id,hub)) {scheduler.withPermit(NetworkWorkContext("media",isRetry=true)) {}}
            runCurrent();assertEquals(ResourceTransferWaitingReason.ServiceCooldown,hub.state.value[id])
            now=2000;scheduler.setDegraded(false);pending.await();assertTrue(hub.state.value.isEmpty())
            val observation=hub.begin(id,ResourceTransferWaitingReason.RequestSlot)!!;hub.close()
            observation.update(ResourceTransferWaitingReason.ServiceCooldown);observation.end()
            assertTrue(hub.state.value.isEmpty());assertNull(hub.begin(id,ResourceTransferWaitingReason.TransferSlot))
        } finally {scheduler.closeAndDrain()}
    }
    @Test fun `positive observed bytes suppress sibling waits without changing durable facts`() {
        val hub=ResourceTransferWaiting();val id=id()
        val wait=hub.begin(id,ResourceTransferWaitingReason.TransferSlot)!!;val old=hub.state.value
        val active=hub.beginAttempt(id,100)!!;assertEquals(old,hub.state.value);active.report(1);assertTrue(hub.state.value.isEmpty());assertEquals(1,old.size)
        wait.update(ResourceTransferWaitingReason.ServiceCooldown);assertTrue(hub.state.value.isEmpty())
        active.end();assertEquals(ResourceTransferWaitingReason.ServiceCooldown,hub.state.value[id])
        val row=ManagedResourceTransfer(id,1,"original",null,null,ResourceTransferGroup.Active,ResourceTransferPhase.Transferring,actions=persistentSetOf(ResourceTransferAction.Cancel))
        val page=ResourceTransferPage(persistentListOf(row));val observed=page.applyingWaiting(hub.state.value)
        assertEquals(row.actions,observed.entries.single().actions);assertNull(page.entries.single().waitingReason)
        for(phase in listOf(ResourceTransferPhase.Paused,ResourceTransferPhase.Cancelling,ResourceTransferPhase.Completed,ResourceTransferPhase.RequiresAttention,ResourceTransferPhase.Processing)) {
            assertNull(ResourceTransferPage(persistentListOf(row.copy(phase=phase))).applyingWaiting(hub.state.value).entries.single().waitingReason)
        }
        wait.end();assertTrue(hub.state.value.isEmpty())
    }
}
