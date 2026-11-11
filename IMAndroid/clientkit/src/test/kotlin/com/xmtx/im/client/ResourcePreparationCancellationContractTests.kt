package com.xmtx.im.client

import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourcePreparationCancellationContractTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    @Test fun plansAreBoundedTypedOpaqueValues() {
        val key=ResourceTransferId(ResourceTransferKind.Upload,id());val plan=ResourcePreparationCancellationPlan(id(),key,64)
        assertEquals(plan,plan.copy());assertTrue(runCatching {plan.copy(messageCount=65)}.isFailure);assertTrue(runCatching {plan.copy(messageCount=0)}.isFailure)
        assertTrue(runCatching {plan.copy(transfer=key.copy(kind=ResourceTransferKind.Download))}.isFailure)
        assertEquals(ResourcePreparationCancellationResult(1,2,3),ResourcePreparationCancellationResult(1,2,3))
        assertTrue(runCatching {ResourcePreparationCancellationResult(1,6,5)}.isFailure)
    }
    @Test fun cancellationCapabilityRequiresAVisibleBoundedParentCount() {
        val row=ManagedResourceTransfer(ResourceTransferId(ResourceTransferKind.Upload,id()),1,null,ResourceUsage.Attachment(RoomId(id())),null,ResourceTransferGroup.Active,ResourceTransferPhase.Queued)
        assertTrue(runCatching {row.copy(actions=persistentSetOf(ResourceTransferAction.CancelPreparation))}.isFailure)
        assertTrue(runCatching {row.copy(cancellableMessageCount=1)}.isFailure)
        assertEquals(1,row.copy(actions=persistentSetOf(ResourceTransferAction.CancelPreparation),cancellableMessageCount=1).cancellableMessageCount)
    }
}
