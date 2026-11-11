package com.xmtx.im.client

import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourceBusinessOwnerContractTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    @Test fun ownerCursorCannotBeReusedForAnotherTransferOrOversizedPage() {
        val key=ResourceTransferId(ResourceTransferKind.Upload,id());val owner=ResourceBusinessOwner.Profile(id())
        val cursor=ResourceBusinessOwnerCursor(key,10,owner.kind,owner.id)
        assertEquals(cursor,ResourceBusinessOwnerQuery(key,cursor).before)
        assertTrue(runCatching {ResourceBusinessOwnerQuery(key.copy(kind=ResourceTransferKind.ServerImport),cursor)}.isFailure)
        assertTrue(runCatching {ResourceBusinessOwnerQuery(key,limit=101)}.isFailure)
        assertTrue(runCatching {cursor.copy(kind="message")}.isFailure)
    }
    @Test fun pageSnapshotsRemainIndependentAndDispositionCannotTargetADownload() {
        val key=ResourceTransferId(ResourceTransferKind.Upload,id());val first=ResourceBusinessOwnerEntry(ResourceBusinessOwner.Profile(id()),10)
        val entries=persistentListOf(first);val page=ResourceBusinessOwnerPage(entries)
        val next=page.copy(entries=entries.add(ResourceBusinessOwnerEntry(ResourceBusinessOwner.Group(RoomId(id()),id()),9)))
        assertEquals(1,page.entries.size);assertEquals(2,next.entries.size)
        assertTrue(runCatching {page.copy(entries=entries.add(first))}.isFailure)
        val plan=ResourceProfileDispositionPlan(id(),key,first.owner.id,ResourceProfileDispositionEffect.WithdrawUnsubmittedChange)
        assertTrue(runCatching {plan.copy(transfer=key.copy(kind=ResourceTransferKind.Download))}.isFailure)
    }
}
