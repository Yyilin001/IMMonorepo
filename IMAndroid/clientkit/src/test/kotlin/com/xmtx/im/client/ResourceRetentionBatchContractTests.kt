package com.xmtx.im.client

import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourceRetentionBatchContractTests {
    private fun key()=ResourceKey(ResourceHome.Room(RoomId(UUID.randomUUID().toString().uppercase())),UUID.randomUUID().toString().uppercase())
    @Test fun outcomesKeepSkippedAndRetryableItemsDistinctInOriginalOrder() {
        val items=ResourceRetentionBatchOutcome.entries.map {ResourceRetentionBatchItem(key(),it)}.toPersistentList()
        val result=ResourceRetentionBatchResult(true,items)
        assertEquals(1,result.changedCount);assertEquals(1,result.unchangedCount);assertEquals(1,result.unavailableCount)
        assertEquals(2,result.skippedCount);assertEquals(1,result.limitReachedCount)
        assertEquals(items.takeLast(2).map {it.key},result.failedKeys)
    }
    @Test fun resultRequiresABoundedUniqueSetOfResourceIdentities() {
        val item=ResourceRetentionBatchItem(key(),ResourceRetentionBatchOutcome.Changed)
        assertTrue(runCatching {ResourceRetentionBatchResult(true,persistentListOf())}.isFailure)
        assertTrue(runCatching {ResourceRetentionBatchResult(true,persistentListOf(item,item))}.isFailure)
        assertTrue(runCatching {ResourceRetentionBatchResult(false,List(101) {item.copy(key=key())}.toPersistentList())}.isFailure)
        assertEquals(100,ResourceRetentionBatchResult(false,List(100) {item.copy(key=key())}.toPersistentList()).items.size)
    }
    @Test fun publishedResultAndRetryKeysDoNotChangeWhenABuilderIsReused() {
        val failed=ResourceRetentionBatchItem(key(),ResourceRetentionBatchOutcome.Failed)
        val builder=persistentListOf(failed).builder();val result=ResourceRetentionBatchResult(true,builder.build());val retry=result.failedKeys
        builder[0]=failed.copy(outcome=ResourceRetentionBatchOutcome.Changed);builder.add(failed.copy(key=key()))
        assertEquals(persistentListOf(failed),result.items);assertEquals(persistentListOf(failed.key),retry);assertEquals(0,result.changedCount)
    }
}
