package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.StateFlow

/** Metadata-only local index. Byte retention, downloads and read authorization are separate services. */
data class ResourceCatalogCursor(val indexedAt: Long,val key: ResourceKey) { init { require(indexedAt>=0) } }
data class ResourceCatalogQuery(val room: RoomId?=null,val category: ResourceCategory=ResourceCategory.All,val search: String="",
    val before: ResourceCatalogCursor?=null,val limit: Int=50,val retainedOnly:Boolean=false) {
    init { room?.let { uuidId(it.value) };require(search.toByteArray(Charsets.UTF_8).size<=255 && limit in 1..100) }
}
data class ResourceCatalogEntry(val descriptor: ResourceDescriptor,val indexedAt: Long,val referenceCount: Int,val retained:Boolean=false) {
    init { require(indexedAt>=0 && referenceCount>0) }
}
data class ResourceCatalogPage(val entries: PersistentList<ResourceCatalogEntry>,val nextCursor: ResourceCatalogCursor?,val isIndexing: Boolean)
@kotlinx.serialization.Serializable data class MessageResourceSource(val room: RoomId,val message: MessageId,val ordinal: Int,val revision: Long) {
    init { uuidId(room.value);uuidId(message.value);require(ordinal in 0..<10 && revision>0) }
}
data class ResourceSourceCursor(val message: MessageId,val ordinal: Int) { init { uuidId(message.value);require(ordinal in 0..<10) } }
data class ResourceSourcePage(val sources: PersistentList<MessageResourceSource>,val nextCursor: ResourceSourceCursor?)
/** One transaction's metadata; no file path or read permission is included. */
data class ResourceDetailSnapshot(val descriptor:ResourceDescriptor,val variants:PersistentList<ResourceVariantSnapshot>,val sources:ResourceSourcePage)
/** A frozen admission token for one page; tokens and opaque server cursors stay out of diagnostics. */
data class ResourceDirectoryScan(val id: String,val room: RoomId,val query: RoomResourceQuery,val hasPage: Boolean=false,
    val snapshotUpper: Long?=null,val lastPosition: RoomResourcePosition?=null,val generation: String) {
    init {
        uuidId(id);uuidId(room.value);require(generation.matches(Regex("[0-9A-F]{32}")))
        require(hasPage==(snapshotUpper!=null) && (snapshotUpper==null || snapshotUpper>=0))
        require(hasPage || query.cursor==null && lastPosition==null)
        require(lastPosition==null || snapshotUpper!=null && lastPosition.sequence<=snapshotUpper)
    }
    val finished get()=hasPage && query.cursor==null
    override fun toString()="ResourceDirectoryScan(room=$room, hasPage=$hasPage, finished=$finished)"
}
class ResourceCatalogConflict: Exception("资源目录状态已变化，请重新查询")
interface ResourceCatalogStore {
    val resourceDirectoryChanges: StateFlow<Long>
    suspend fun resourceDirectory(query: ResourceCatalogQuery=ResourceCatalogQuery()): ResourceCatalogPage
    suspend fun resourceSources(key: ResourceKey,before: ResourceSourceCursor?=null,limit: Int=50): ResourceSourcePage
    suspend fun containsResourceSource(key: ResourceKey,source: MessageResourceSource): Boolean
    suspend fun beginResourceDirectoryScan(room: RoomId,query: RoomResourceQuery=RoomResourceQuery()): ResourceDirectoryScan
    suspend fun resourceDirectoryScan(room: RoomId,query: RoomResourceQuery=RoomResourceQuery()): ResourceDirectoryScan?
    suspend fun applyResourceDirectoryPage(scan: ResourceDirectoryScan,page: RoomResourcePage): ResourceDirectoryScan
    suspend fun denyResourceDirectory(scan: ResourceDirectoryScan)
    /** Process a bounded durable backfill and return whether work remains. */
    suspend fun indexResourceProjectionBatch(limit: Int=50): Boolean
}
class ResourceDirectorySynchronizer(private val store: ResourceCatalogStore,private val reader: RoomResourceDirectoryReading) {
    suspend fun refresh(room: RoomId,query: RoomResourceQuery=RoomResourceQuery()): ResourceDirectoryScan = step(store.beginResourceDirectoryScan(room,query))
    suspend fun step(scan: ResourceDirectoryScan): ResourceDirectoryScan {
        require(!scan.finished)
        val page=try { reader.query(scan.room,scan.query) } catch(error: ResourceDirectoryFailure) {
            currentCoroutineContext().ensureActive()
            if(error.reason==ResourceDirectoryFailureReason.NotVisible) store.denyResourceDirectory(scan)
            throw error
        }
        currentCoroutineContext().ensureActive()
        return store.applyResourceDirectoryPage(scan,page)
    }
}
