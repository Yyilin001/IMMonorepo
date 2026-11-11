package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList

/** Allocated disk bytes and quota charges are deliberately separate. No file path or resource name escapes. */
data class ResourceStorageSnapshot(val policy:ResourceOriginalPolicy,val cacheAllocatedBytes:Long,val retainedAllocatedBytes:Long,
    val originalAllocatedBytes:Long,val transferAllocatedBytes:Long,val cacheChargedBytes:Long,val retainedChargedBytes:Long,
    val originalChargedBytes:Long,val temporaryReservedBytes:Long,val cacheEntries:Int, val managedChargedBytes:Long) {
    init {require(listOf(cacheAllocatedBytes,retainedAllocatedBytes,originalAllocatedBytes,transferAllocatedBytes,cacheChargedBytes,retainedChargedBytes,originalChargedBytes,temporaryReservedBytes).all {it>=0});require(cacheEntries>=0 && managedChargedBytes>=0)}
    val totalAllocatedBytes get()=listOf(cacheAllocatedBytes,retainedAllocatedBytes,originalAllocatedBytes,transferAllocatedBytes).fold(0L) {a,b->if(a>Long.MAX_VALUE-b) Long.MAX_VALUE else a+b}
    val cacheOverageBytes get()=(cacheChargedBytes-policy.maximumCacheBytes).coerceAtLeast(0)
    val managedOverageBytes get()=policy.maximumManagedBytes?.let {(managedChargedBytes-it).coerceAtLeast(0)} ?: 0
    val retainedWarning get()=retainedChargedBytes>=policy.retainedWarningBytes
    val cacheOverLimit get()=cacheOverageBytes>0 || cacheEntries>policy.maximumCacheEntries
}
data class ResourceStoragePolicyResult(val snapshot:ResourceStorageSnapshot,val cleanupDeferred:Boolean)

/** Single-use, account/file-owner scoped preview; expires after 30 seconds and cannot survive owner recreation. */
data class ResourceCleanupPlan(val id:String,val fileCount:Int,val estimatedBytes:Long,val skippedCount:Int) {
    init {require(id.isNotBlank() && fileCount>=0 && estimatedBytes>=0 && skippedCount>=0)}
}
data class ResourceCleanupResult(val deletedCount:Int,val releasedBytes:Long,val skippedCount:Int,val failedCount:Int) {
    init {require(deletedCount>=0 && releasedBytes>=0 && skippedCount>=0 && failedCount>=0)}
}
interface ResourceCleanupFiles {
    suspend fun planCacheCleanup():ResourceCleanupPlan
    suspend fun commitCacheCleanup(plan:ResourceCleanupPlan):ResourceCleanupResult
}
/** Logical selection resolves to a frozen, deduplicated subset of published files only. */
data class ResourceSelectionCleanupPlan(val plan:ResourceCleanupPlan,val resourceCount:Int,
    val unavailableResourceCount:Int,val absentResourceCount:Int) {
    init {require(resourceCount in 1..100 && unavailableResourceCount>=0 && absentResourceCount>=0 &&
        unavailableResourceCount.toLong()+absentResourceCount<=resourceCount)}
}
interface ResourceSelectionCleanupFiles {
    suspend fun planSelectedCacheCleanup(resources:PersistentList<ResourceKey>):ResourceSelectionCleanupPlan
}
interface ResourceStorageFiles {
    suspend fun storageSnapshot():ResourceStorageSnapshot
    suspend fun setStoragePolicy(policy:ResourceOriginalPolicy):ResourceStoragePolicyResult
    suspend fun setCacheLimit(maximumBytes:Long):ResourceStoragePolicyResult
    suspend fun setManagedLimit(maximumBytes:Long?):ResourceStoragePolicyResult
}
