package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.flow.StateFlow

sealed interface ResourceBusinessOwner {
    val id:String
    val kind:String
    data class Profile(override val id:String):ResourceBusinessOwner {
        init {require(uuidId(id)==id)}
        override val kind get()="profile"
    }
    data class Group(val room:RoomId,override val id:String):ResourceBusinessOwner {
        init {require(uuidId(id)==id);uuidId(room.value)}
        override val kind get()="group"
    }
    val key get()="$kind/$id"
}
data class ResourceBusinessOwnerEntry(val owner:ResourceBusinessOwner,val createdAt:Long) {init {require(createdAt>=0)}}
data class ResourceBusinessOwnerCursor(val transfer:ResourceTransferId,val createdAt:Long,val kind:String,val id:String) {
    init {require(createdAt>=0 && kind in setOf("profile","group") && uuidId(id)==id)}
}
data class ResourceBusinessOwnerQuery(val transfer:ResourceTransferId,val before:ResourceBusinessOwnerCursor?=null,val limit:Int=25) {
    init {require(limit in 1..100 && (before==null || before.transfer==transfer))}
}
data class ResourceBusinessOwnerPage(val entries:PersistentList<ResourceBusinessOwnerEntry>,val next:ResourceBusinessOwnerCursor?=null) {
    init {
        require(entries.size<=100 && entries.map {it.owner.key}.distinct().size==entries.size)
        require(next==null || entries.lastOrNull()?.let {it.createdAt==next.createdAt && it.owner.kind==next.kind && it.owner.id==next.id}==true)
    }
}
enum class ResourceProfileDispositionEffect { WithdrawUnsubmittedChange,ReleaseFinishedSource }
data class ResourceProfileDispositionPlan(val id:String,val transfer:ResourceTransferId,val intent:String,val effect:ResourceProfileDispositionEffect) {
    init {require(uuidId(id)==id && uuidId(intent)==intent && transfer.kind!=ResourceTransferKind.Download)}
}
interface ResourceBusinessOwnerStore {
    val resourceBusinessOwnerChanges:StateFlow<Long>
    suspend fun resourceBusinessOwners(query:ResourceBusinessOwnerQuery):ResourceBusinessOwnerPage
    suspend fun resourceHasBusinessOwner(transfer:ResourceTransferId,owner:ResourceBusinessOwner):Boolean
    suspend fun resourceProfileIntent(transfer:ResourceTransferId,intent:String):ProfileIntentStatus?
    suspend fun planResourceProfileDisposition(transfer:ResourceTransferId,intent:String):ResourceProfileDispositionPlan
    suspend fun commitResourceProfileDisposition(plan:ResourceProfileDispositionPlan)
}
