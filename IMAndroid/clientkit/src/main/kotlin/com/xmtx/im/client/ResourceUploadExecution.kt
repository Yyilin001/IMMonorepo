package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable enum class ResourceUploadAction { Create, Status, Upload, Finalize, Cancel }
@Serializable enum class ResourceUploadError { OutcomeUnknown, Transport, NeedsAttention, BudgetExhausted, ProcessingBudgetExhausted, BackgroundOutcomeUnknown }
@Serializable data class ResourceUploadExecution(val next: ResourceUploadAction=ResourceUploadAction.Create,val userPaused: Boolean=false,
    val attempts: Int=0,val totalAttempts: Long=0,val polls: Int=0,val deadline: Long?=null,val retryAt: Long=0,val serverRetryAt: Long=0,
    val attention: Boolean=false,val error: ResourceUploadError?=null,val owner: String?=null,val token: String?=null,val backgroundPending:Boolean=false,val backgroundAttempts:Int=0) {
    init {
        require(backgroundAttempts in 0..5 && (!backgroundPending || owner==null && token==null))
        require(attempts>=0 && totalAttempts>=0 && polls>=0 && retryAt>=0 && serverRetryAt>=0 && (deadline==null || deadline>=0))
        require((owner==null)==(token==null));owner?.let { require(uuidId(it)==it) };token?.let { require(uuidId(it)==it) }
    }
}
data class ResourceUploadClaim(val work: ResourceUploadWork,val owner: String,val token: String)
interface ResourceUploadJournal {
    val resourceUploadChanges: StateFlow<Long>
    suspend fun resourceUploads(): PersistentList<ResourceUploadWork>
    suspend fun resourceUpload(id: String): ResourceUploadWork? = resourceUploads().firstOrNull { it.id == id }
    suspend fun recoverResourceUploadClaims(owner: String)
    suspend fun claimResourceUpload(id: String,owner: String,now: Long): ResourceUploadClaim?
    suspend fun finishResourceUpload(claim: ResourceUploadClaim,session: ResourceUploadSession?,next: ResourceUploadAction,retryAt: Long,processingPoll: Boolean=false,preserveBudget: Boolean=false)
    suspend fun failResourceUpload(claim: ResourceUploadClaim,error: ResourceUploadError,retryAt: Long?,serverRetryAt: Long=0,cancelled: Boolean=false,session: ResourceUploadSession?=null)
    suspend fun requestResourceUploadCancellation(id: String): ResourceUploadWork
    suspend fun controlResourceUpload(id: String,paused: Boolean,retry: Boolean=false)
}
interface ResourceUploadControl {
    suspend fun create(request: ResourceUploadRequest): ResourceUploadSession
    suspend fun status(previous: ResourceUploadSession): ResourceUploadSession
    suspend fun target(session: ResourceUploadSession,request: ResourceUploadRequest): ResourceTransferPlan?
    suspend fun finalize(session: ResourceUploadSession): ResourceUploadSession
    suspend fun cancel(session: ResourceUploadSession): ResourceUploadSession
}
/** Optional provider capability, requested only during an explicit background execution lease. */
interface ResourceBackgroundUploadControl {
    suspend fun backgroundTargets(session:ResourceUploadSession,request:ResourceUploadRequest,
        parts:PersistentList<Int> = kotlinx.collections.immutable.persistentListOf()):PersistentList<ResourceBackgroundUploadTarget>
}
/** Acquisition excludes another account engine. Transfer returns only after the physical file borrow drains. */
interface ResourceUploadBytes {
    suspend fun acquire(owner: String)
    suspend fun release(owner: String)
    suspend fun transfer(owner: String,work: ResourceUploadWork,plan: ResourceTransferPlan)
}
open class ResourceSourceUnavailable: java.io.IOException("资源原文件不可用")
