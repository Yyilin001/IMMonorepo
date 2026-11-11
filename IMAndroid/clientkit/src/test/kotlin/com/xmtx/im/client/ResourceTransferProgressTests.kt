package com.xmtx.im.client

import kotlinx.collections.immutable.*
import java.util.UUID
import kotlin.test.*

class ResourceTransferProgressTests {
    private fun id(kind:ResourceTransferKind=ResourceTransferKind.Upload)=ResourceTransferId(kind,UUID.randomUUID().toString().uppercase())
    @Test fun `progress coalesces intermediate bytes and rejects regression overflow and stale attempts`() {
        var nanos=0L;val hub=ResourceTransferWaiting {nanos};val id=id();val first=hub.beginAttempt(id,100)!!
        assertNull(hub.beginAttempt(id,200));first.report(1);val old=hub.snapshots.value;first.report(25)
        assertEquals(1,hub.snapshots.value.attempts[id]!!.transferredBytes)
        nanos=100_000_000;first.report(26);assertEquals(26,hub.snapshots.value.attempts[id]!!.transferredBytes)
        first.report(12);first.report(101);assertEquals(26,hub.snapshots.value.attempts[id]!!.transferredBytes)
        first.report(100);assertEquals(100,hub.snapshots.value.attempts[id]!!.transferredBytes)
        first.end();val second=hub.beginAttempt(id,4)!!;val newId=hub.snapshots.value.attempts[id]!!.attemptId
        first.report(99);first.end();assertEquals(newId,hub.snapshots.value.attempts[id]!!.attemptId)
        assertEquals(1,old.attempts[id]!!.transferredBytes);assertNotEquals(old.attempts[id]!!.attemptId,newId)
        second.report(4);hub.close();second.report(3);second.end();assertEquals(ResourceTransferObservations(),hub.snapshots.value)
        assertNull(hub.beginAttempt(id,1))
    }
    @Test fun `zero progress preserves waiting but positive bytes override it without confirming the resource`() {
        val hub=ResourceTransferWaiting();val id=id();val wait=hub.begin(id,ResourceTransferWaitingReason.ServiceCooldown)!!
        val attempt=hub.beginAttempt(id,20)!!
        val row=ManagedResourceTransfer(id,1,"file",null,null,ResourceTransferGroup.Active,ResourceTransferPhase.Confirming,
            totalBytes=100,confirmedBytes=40,actions=persistentSetOf(ResourceTransferAction.Pause))
        val original=ResourceTransferPage(persistentListOf(row))
        var observed=original.applyingObservations(hub.snapshots.value).entries.single()
        assertEquals(ResourceTransferWaitingReason.ServiceCooldown,observed.waitingReason);assertNull(observed.attemptProgress)
        attempt.report(20);observed=original.applyingObservations(hub.snapshots.value).entries.single()
        assertNull(observed.waitingReason);assertEquals(ResourceTransferPhase.Transferring,observed.phase)
        assertEquals(20,observed.attemptProgress!!.expectedBytes);assertEquals(40,observed.confirmedBytes);assertEquals(100,observed.totalBytes)
        assertEquals(row.actions,observed.actions);assertEquals(ResourceTransferPhase.Confirming,original.entries.single().phase)
        for(phase in listOf(ResourceTransferPhase.Paused,ResourceTransferPhase.Pausing,ResourceTransferPhase.Cancelling,ResourceTransferPhase.Completed,ResourceTransferPhase.Failed)) {
            val result=ResourceTransferPage(persistentListOf(row.copy(phase=phase))).applyingObservations(hub.snapshots.value).entries.single()
            assertEquals(phase,result.phase);assertNull(result.attemptProgress);assertNull(result.waitingReason)
        }
        attempt.end();assertEquals(ResourceTransferWaitingReason.ServiceCooldown,original.applyingObservations(hub.snapshots.value).entries.single().waitingReason)
        wait.end();assertNull(original.applyingObservations(hub.snapshots.value).entries.single().attemptProgress)
    }
    @Test fun `native observations need positive bytes and overlapping physical owners are omitted`() {
        val hub=ResourceTransferWaiting();val id=id();hub.begin(id,ResourceTransferWaitingReason.RequestSlot)
        val sample=ResourceTransferAttemptProgress(UUID.randomUUID().toString().uppercase(),0,20)
        hub.nativeProgress(persistentMapOf(id to sample));assertEquals(ResourceTransferWaitingReason.RequestSlot,hub.state.value[id])
        hub.nativeProgress(persistentMapOf(id to sample.copy(transferredBytes=20)))
        assertTrue(hub.state.value.isEmpty());assertEquals(sample.attemptId,hub.snapshots.value.attempts[id]!!.attemptId)
        val foreground=hub.beginAttempt(id,100)!!;foreground.report(1)
        assertNull(hub.snapshots.value.attempts[id]);assertEquals(ResourceTransferWaitingReason.RequestSlot,hub.state.value[id])
        foreground.end();assertEquals(20,hub.snapshots.value.attempts[id]!!.transferredBytes)
        hub.nativeProgress(persistentMapOf());assertEquals(ResourceTransferWaitingReason.RequestSlot,hub.state.value[id])
        hub.close();hub.nativeProgress(persistentMapOf(id to sample));assertEquals(ResourceTransferObservations(),hub.snapshots.value)
    }
    @Test fun `waiting precedence does not depend on callback order and imports never acquire byte progress`() {
        val hub=ResourceTransferWaiting();val id=id(ResourceTransferKind.Download)
        hub.begin(id,ResourceTransferWaitingReason.RequestSlot);hub.networkWaiting(persistentMapOf(id to ResourceTransferWaitingReason.NetworkPolicy))
        assertEquals(ResourceTransferWaitingReason.NetworkPolicy,hub.snapshots.value.waiting[id])
        hub.begin(id,ResourceTransferWaitingReason.TransferSlot);assertEquals(ResourceTransferWaitingReason.NetworkPolicy,hub.snapshots.value.waiting[id])
        val network=hub.begin(id,ResourceTransferWaitingReason.Network)!!;assertEquals(ResourceTransferWaitingReason.Network,hub.snapshots.value.waiting[id])
        val cooldown=hub.begin(id,ResourceTransferWaitingReason.ServiceCooldown)!!;assertEquals(ResourceTransferWaitingReason.ServiceCooldown,hub.snapshots.value.waiting[id])
        cooldown.end();network.end();assertEquals(ResourceTransferWaitingReason.NetworkPolicy,hub.snapshots.value.waiting[id])
        assertFailsWith<IllegalArgumentException> {hub.beginAttempt(id(ResourceTransferKind.ServerImport),10)}
        assertFailsWith<IllegalArgumentException> {hub.beginAttempt(id,0)}
        hub.close()
    }
}
