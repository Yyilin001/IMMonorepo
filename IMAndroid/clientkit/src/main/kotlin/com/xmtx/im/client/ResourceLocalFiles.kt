package com.xmtx.im.client

import kotlinx.collections.immutable.*

/** Selection, upload identity, and physical bytes have independent lifetimes. No local path is durable metadata. */
enum class ResourceAssetAvailability { Importing, Local, Unavailable }
enum class ResourceFileState { Publishing, Published, Missing, Invalid, Retiring }
enum class ResourceFileKind { Original,Cache }
data class ResourceLocalAsset(val id: String,val plannedFile: String,val file: String?,val displayName: String,val contentType: String,
    val byteCount: Long,val checksum: ResourceChecksum,val purpose: ResourceUsage,val dimensions: ResourceDimensions?,
    val availability: ResourceAssetAvailability,val selectionActive: Boolean,val createdAt: Long) {
    init {
        require(uuidId(id)==id && uuidId(plannedFile)==plannedFile && (file==null || uuidId(file)==file))
        require(byteCount>0 && createdAt>=0 && resourceDisplayName(displayName)==displayName);requireResourceContentType(contentType)
        require(dimensions==null || contentType.startsWith("image/"));require(availability!=ResourceAssetAvailability.Local || file!=null)
    }
}
data class ResourceLocalFile(val id: String,val byteCount: Long,val checksum: ResourceChecksum,val state: ResourceFileState,val allocatedBytes: Long=0,
    val kind: ResourceFileKind=ResourceFileKind.Original,val lastUsed: Long=0,val retained:Boolean=false) {
    init { require(uuidId(id)==id && byteCount>=0 && (kind==ResourceFileKind.Cache || byteCount>0) && allocatedBytes>=0 && lastUsed>=0) }
    val chargedBytes get()=maxOf(byteCount,allocatedBytes)
}
data class ResourceOriginalPolicy(val maximumOriginalBytes: Long=2L*1024*1024*1024,val maximumTemporaryBytes: Long=512L*1024*1024,
    val minimumFreeBytes: Long=16L*1024*1024,val maximumSelections: Int=256,
    val maximumCacheBytes: Long=512L*1024*1024,val maximumCacheEntries: Int=256,
    val retainedWarningBytes:Long=2L*1024*1024*1024,val maximumRetainedEntries:Int=4096,val maximumManagedBytes:Long?=null) {
    init { require(maximumOriginalBytes in 1..Long.MAX_VALUE/8 && maximumTemporaryBytes in 1..Long.MAX_VALUE/8 && minimumFreeBytes in 0..Long.MAX_VALUE/8 && maximumSelections in 1..256 && maximumCacheBytes in 1..Long.MAX_VALUE/8 && maximumCacheEntries in 1..4096 && retainedWarningBytes in 1..Long.MAX_VALUE/8 && maximumRetainedEntries in 1..4096 && (maximumManagedBytes==null || maximumManagedBytes in 1..Long.MAX_VALUE/8)) }
}
enum class ResourceUploadStage { Prepared, Transferring, Processing, Ready, Paused, Cancelled, Rejected, Expired }
/** Only validated control facts are stored. Transfer plans and provider response bodies have no field here. */
data class ResourceUploadWork(val id: String,val asset: String,val request: ResourceUploadRequest,val session: ResourceUploadSession?=null,
    val stage: ResourceUploadStage=ResourceUploadStage.Prepared,val cancellationRequested: Boolean=false,val sourceReleased: Boolean=false,val execution: ResourceUploadExecution=ResourceUploadExecution()) {
    init {
        require(uuidId(id)==id && uuidId(asset)==asset)
        require(session==null || session.media==request.media)
        require(!sourceReleased || terminal)
    }
    val terminal get()=stage in setOf(ResourceUploadStage.Ready,ResourceUploadStage.Cancelled,ResourceUploadStage.Rejected,ResourceUploadStage.Expired)
}
/** Mutations run in the same transaction as resource upload source claims. */
interface ResourceFileJournal {
    suspend fun resourceAssets(): PersistentList<ResourceLocalAsset>
    suspend fun resourceFiles(): PersistentList<ResourceLocalFile>
    suspend fun beginResourceImport(asset: ResourceLocalAsset,policy: ResourceOriginalPolicy): ResourceLocalAsset
    suspend fun reserveResourceAllocation(file: String,allocatedBytes: Long,policy: ResourceOriginalPolicy)
    suspend fun publishResourceImport(asset: String,file: String,allocatedBytes: Long): ResourceLocalAsset
    suspend fun markResourceFile(file: String,state: ResourceFileState)
    suspend fun markResourceAssetUnavailable(asset: String)
    suspend fun releaseResourceSelection(asset: String)
    suspend fun resourceOriginal(selection: String?=null,upload: String?=null,profile: ProfileOriginalConsumer?=null): ResourceLocalAsset
    suspend fun retireResourceFiles(excluding: PersistentSet<String>): PersistentList<ResourceLocalFile>
    suspend fun deleteResourceFile(file: String)
    suspend fun prepareResourceUpload(id: String,asset: String,request: ResourceUploadRequest): ResourceUploadWork
    suspend fun resourceUploads(): PersistentList<ResourceUploadWork>
    suspend fun saveResourceUploadSession(id: String,session: ResourceUploadSession): ResourceUploadWork
    suspend fun requestResourceUploadCancellation(id: String): ResourceUploadWork
    suspend fun confirmResourceUploadCancellation(id: String,session: ResourceUploadSession): ResourceUploadWork
    suspend fun releaseResourceUploadSource(id: String)
}
