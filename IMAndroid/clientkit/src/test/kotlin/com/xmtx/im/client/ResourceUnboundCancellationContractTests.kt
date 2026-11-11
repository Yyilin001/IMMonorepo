package com.xmtx.im.client

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourceUnboundCancellationContractTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    @Test fun reviewedIdentityIsOpaqueAndNeverRepresentsADownload() {
        val plan=ResourceUnboundCancellationPlan(id(),ResourceTransferId(ResourceTransferKind.Upload,id()))
        assertEquals(plan,plan.copy())
        assertTrue(runCatching {plan.copy(id=plan.id.lowercase())}.isFailure)
        assertTrue(runCatching {plan.copy(transfer=plan.transfer.copy(kind=ResourceTransferKind.Download))}.isFailure)
    }
    @Test fun standaloneAvatarImportDoesNotExposeAttachmentCancellation() {
        val request=ResourceImportRequest(id(),ResourceImportSource.Message(RoomId(id()),MessageId(id()),id()),ResourceUsage.UserAvatar,id())
        val work=ResourceImportWork(id(),request,createdAt=1)
        assertFalse(ResourceTransferAction.CancelUnbound in ResourceTransferProjection.serverImport(work,false,1).actions)
    }
}
