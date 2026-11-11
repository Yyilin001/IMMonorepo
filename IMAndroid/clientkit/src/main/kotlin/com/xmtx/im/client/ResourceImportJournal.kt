package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable enum class ResourceImportIssue { Unknown, Transport, AuthorizationUnavailable, InvalidResponse, BudgetExhausted, PollingExhausted }
@Serializable data class ResourceImportExecution(val owner: String?=null,val token: String?=null,val attempts: Int=0,val polls: Int=0,
    val deadline: Long?=null,val retryAt: Long=0,val serverRetryAt: Long=0,val paused: Boolean=false,val attention: Boolean=false,val issue: ResourceImportIssue?=null) {
    init {
        require((owner==null)==(token==null));listOfNotNull(owner,token).forEach { require(uuidId(it)==it) }
        require(attempts in 0..5 && polls in 0..60 && retryAt>=0 && serverRetryAt>=0 && (deadline==null || deadline>=0))
    }
}
/** Cancellation resolution may mean completion won; it never restores eligibility for business binding. */
data class ResourceImportWork(val id: String,val request: ResourceImportRequest,val createdAt: Long,val status: ResourceImportStatus?=null,
    val cancellationRequested: Boolean=false,val cancellationResolved: Boolean=false,val retained: Boolean=true,val execution: ResourceImportExecution=ResourceImportExecution(),val businessBound: Boolean=false) {
    init { require(uuidId(id)==id && createdAt>=0);require(!cancellationResolved || cancellationRequested);require(!businessBound || status?.state==ResourceImportState.Ready && !cancellationRequested && execution.owner==null) }
    val terminal get()=status?.state?.let { it.terminal && (it!=ResourceImportState.Ready || !cancellationRequested || cancellationResolved) }==true
    fun bindable(now: Long)=!businessBound && !cancellationRequested && status?.bindable(now)==true && execution.owner==null
}
data class ResourceImportClaim(val work: ResourceImportWork,val owner: String,val token: String) {
    init { require(work.execution.owner==owner && work.execution.token==token) }
}
/** Typed, namespaced durable business ownership; implementations cannot expose arbitrary consumer keys. */
sealed interface ResourceImportConsumer { val key: String }
interface ResourceImportJournal {
    val resourceImportChanges: StateFlow<Long>
    suspend fun resourceImports(): PersistentList<ResourceImportWork>
    suspend fun prepareResourceImport(id: String,request: ResourceImportRequest,now: Long): ResourceImportWork
    suspend fun recoverResourceImportClaims(owner: String)
    suspend fun claimResourceImport(id: String,owner: String,now: Long): ResourceImportClaim?
    suspend fun finishResourceImport(claim: ResourceImportClaim,status: ResourceImportStatus,now: Long)
    suspend fun failResourceImport(claim: ResourceImportClaim,issue: ResourceImportIssue,retryAt: Long?,serverRetryAt: Long=0,cancelled: Boolean=false)
    suspend fun cancelResourceImport(id: String)
    suspend fun controlResourceImport(id: String,paused: Boolean,retry: Boolean=false)
    suspend fun releaseResourceImport(id: String)
}
