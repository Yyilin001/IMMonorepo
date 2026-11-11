package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList

/** Availability is a cache hint, never permission to read bytes or a durable path. */
data class ResourceVariantSnapshot(val descriptor:ResourceVariantDescriptor,val retained:Boolean,val availableLocally:Boolean)

/** Mutations belong to the account file owner, sharing serialization with eviction and publication. */
interface ResourceRetentionFiles {
    suspend fun resourceVariants(resource:ResourceKey):PersistentList<ResourceVariantSnapshot>
    suspend fun setResourceRetained(key:ResourceVariantKey,retained:Boolean)
}

enum class ResourceRetentionBatchOutcome { Changed, Unchanged, Unavailable, LimitReached, Failed }
data class ResourceRetentionBatchItem(val key:ResourceKey,val outcome:ResourceRetentionBatchOutcome)
/** Ordered, deduplicated outcomes. Failed identities can be explicitly retried without repeating successes. */
data class ResourceRetentionBatchResult(val retained:Boolean,val items:PersistentList<ResourceRetentionBatchItem>) {
    init {require(items.size in 1..100 && items.map {it.key}.distinct().size==items.size)}
    val changedCount get()=items.count {it.outcome==ResourceRetentionBatchOutcome.Changed}
    val unchangedCount get()=items.count {it.outcome==ResourceRetentionBatchOutcome.Unchanged}
    val unavailableCount get()=items.count {it.outcome==ResourceRetentionBatchOutcome.Unavailable}
    val limitReachedCount get()=items.count {it.outcome==ResourceRetentionBatchOutcome.LimitReached}
    val failedKeys get()=items.filter {it.outcome==ResourceRetentionBatchOutcome.LimitReached || it.outcome==ResourceRetentionBatchOutcome.Failed}.map {it.key}.toPersistentList()
    val skippedCount get()=unchangedCount+unavailableCount
}
interface ResourceBatchRetentionFiles {
    /** Retains/releases original variants only; does not initiate a download or delete bytes. */
    suspend fun setResourcesRetained(resources:PersistentList<ResourceKey>,retained:Boolean):ResourceRetentionBatchResult
}

/** Opaque account-scoped preview; inaccessible resource identities and names never enter this value. */
data class ResourceUnavailableRetentionPlan(val id:String,val count:Int,val hasMore:Boolean,val expiresAt:Long) {
    init {require(uuidId(id)==id && count in 0..100 && expiresAt>=0);require(!hasMore || count==100)}
}
data class ResourceUnavailableRetentionResult(val releasedCount:Int,val skippedCount:Int) {
    init {require(releasedCount>=0 && skippedCount>=0 && releasedCount.toLong()+skippedCount<=100)}
}
interface ResourceUnavailableRetentionFiles {
    suspend fun planUnavailableRetentionRelease():ResourceUnavailableRetentionPlan
    suspend fun releaseUnavailableRetention(plan:ResourceUnavailableRetentionPlan):ResourceUnavailableRetentionResult
}
