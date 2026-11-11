package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.flow.StateFlow

/** Typed references to the canonical journals, never another writable task queue. */
enum class ResourceTransferKind(val key:String) { Upload("upload"),Download("download"),ServerImport("import") }
data class ResourceTransferId(val kind:ResourceTransferKind,val value:String) {
    init {require(uuidId(value)==value)}
    val key get()="${kind.key}/$value"
}
enum class ResourceTransferGroup { Active,Attention,Finished }
enum class ResourceTransferAction { Retry,RetryCancellation,Pause,Resume,Cancel,CancelUnbound,CancelPreparation }
enum class ResourceTransferPhase { Queued,Preparing,Transferring,Confirming,Verifying,Processing,Pausing,Paused,Cancelling,WaitingRetry,RequiresAttention,Completed,Cancelled,Failed }
enum class ManagedResourceTransferFailure { Network,Integrity,Storage,SourceUnavailable,Authorization,Rejected,Expired,NeedsAttention,CancellationUnconfirmed }
data class ResourceTransferCursor(val createdAt:Long,val id:ResourceTransferId) {init {require(createdAt>=0)}}
data class ResourceTransferQuery(val group:ResourceTransferGroup?=null,val before:ResourceTransferCursor?=null,val limit:Int=30) {init {require(limit in 1..100)}}
data class ManagedResourceTransfer(val id:ResourceTransferId,val createdAt:Long,val displayName:String?,val usage:ResourceUsage?,
    val resource:ResourceKey?,val group:ResourceTransferGroup,val phase:ResourceTransferPhase,val failure:ManagedResourceTransferFailure?=null,
    val totalBytes:Long?=null,val confirmedBytes:Long?=null,val retryAt:Long?=null,
    val actions:PersistentSet<ResourceTransferAction> = persistentSetOf(),val hasBusinessOwners:Boolean=false,val cancellableMessageCount:Int?=null,val waitingReason:ResourceTransferWaitingReason?=null,val attemptProgress:ResourceTransferAttemptProgress?=null) {
    init {
        require(createdAt>=0 && (totalBytes==null || totalBytes>0) && (confirmedBytes==null || totalBytes!=null && confirmedBytes in 0..totalBytes))
        require((phase==ResourceTransferPhase.WaitingRetry)==(retryAt!=null) && (retryAt==null || retryAt>=0))
        require(!hasBusinessOwners || ResourceTransferAction.CancelUnbound !in actions)
        require((cancellableMessageCount!=null)==(ResourceTransferAction.CancelPreparation in actions))
        require(cancellableMessageCount==null || id.kind!=ResourceTransferKind.Download && usage is ResourceUsage.Attachment && cancellableMessageCount in 1..64)
    }
    val cursor get()=ResourceTransferCursor(createdAt,id)
}
data class ResourceTransferPage(val entries:PersistentList<ManagedResourceTransfer>,val next:ResourceTransferCursor?=null) {
    init {require(entries.size<=100 && entries.map {it.id}.distinct().size==entries.size);require(next==null || next==entries.lastOrNull()?.cursor)}
}
class ResourceTransferActionUnavailable:IllegalStateException("传输状态已变化，当前操作不可用")
enum class ResourceTransferBatchOutcome { Requested,Skipped,Failed }
data class ResourceTransferBatchItem(val id:ResourceTransferId,val outcome:ResourceTransferBatchOutcome)
data class ResourceTransferBatchResult(val action:ResourceTransferAction,val items:PersistentList<ResourceTransferBatchItem>) {
    init {require(action in setOf(ResourceTransferAction.Retry,ResourceTransferAction.RetryCancellation));require(items.size in 1..100 && items.map {it.id}.distinct().size==items.size)}
    val requestedCount get()=items.count {it.outcome==ResourceTransferBatchOutcome.Requested}
    val skippedCount get()=items.count {it.outcome==ResourceTransferBatchOutcome.Skipped}
    val failedIds get()=items.filter {it.outcome==ResourceTransferBatchOutcome.Failed}.map {it.id}.toPersistentList()
}
interface ResourceTransferStore {
    val resourceTransferChanges:StateFlow<Long>
    suspend fun resourceTransfers(query:ResourceTransferQuery=ResourceTransferQuery(),now:Long=System.currentTimeMillis()):ResourceTransferPage
    suspend fun controlResourceTransfer(id:ResourceTransferId,action:ResourceTransferAction,now:Long=System.currentTimeMillis())
    suspend fun retryResourceTransfers(ids:PersistentList<ResourceTransferId>,action:ResourceTransferAction,now:Long=System.currentTimeMillis()):ResourceTransferBatchResult
}

/** All exposed collections are persistent; progress is derived only from server-confirmed facts. */
object ResourceTransferProjection {
    fun upload(work:ResourceUploadWork,createdAt:Long,hasOwners:Boolean,now:Long):ManagedResourceTransfer {
        val e=work.execution;val busy=e.owner!=null || e.backgroundPending;val stalled=work.cancellationRequested && e.attention && !busy && !work.terminal
        val phase=when {
            busy && work.stage==ResourceUploadStage.Ready->ResourceTransferPhase.Verifying
            busy && work.stage==ResourceUploadStage.Cancelled->ResourceTransferPhase.Cancelling
            stalled->ResourceTransferPhase.RequiresAttention
            !work.terminal && work.cancellationRequested->ResourceTransferPhase.Cancelling
            !work.terminal && e.userPaused->if(busy) ResourceTransferPhase.Pausing else ResourceTransferPhase.Paused
            work.stage==ResourceUploadStage.Ready->ResourceTransferPhase.Completed
            work.stage==ResourceUploadStage.Cancelled->ResourceTransferPhase.Cancelled
            work.stage in setOf(ResourceUploadStage.Rejected,ResourceUploadStage.Expired)->ResourceTransferPhase.Failed
            e.attention->ResourceTransferPhase.RequiresAttention
            work.stage==ResourceUploadStage.Paused && !busy->if(maxOf(e.retryAt,e.serverRetryAt)>now) ResourceTransferPhase.WaitingRetry else ResourceTransferPhase.Queued
            work.stage==ResourceUploadStage.Processing->ResourceTransferPhase.Processing
            e.backgroundPending->ResourceTransferPhase.Transferring
            e.next==ResourceUploadAction.Status->ResourceTransferPhase.Confirming
            e.next==ResourceUploadAction.Finalize->ResourceTransferPhase.Verifying
            busy->if(e.next==ResourceUploadAction.Upload) ResourceTransferPhase.Transferring else ResourceTransferPhase.Preparing
            maxOf(e.retryAt,e.serverRetryAt)>now->ResourceTransferPhase.WaitingRetry
            else->ResourceTransferPhase.Queued
        }
        val group=when {
            !busy && work.stage in setOf(ResourceUploadStage.Ready,ResourceUploadStage.Cancelled)->ResourceTransferGroup.Finished
            work.stage in setOf(ResourceUploadStage.Rejected,ResourceUploadStage.Expired) || e.attention || e.userPaused && !busy->ResourceTransferGroup.Attention
            else->ResourceTransferGroup.Active
        }
        val actions=mutableSetOf<ResourceTransferAction>()
        if(!work.terminal) {
            if(stalled) actions+=ResourceTransferAction.RetryCancellation
            if(!work.cancellationRequested) {
                if(e.attention && !e.userPaused && !busy) actions+=ResourceTransferAction.Retry
                if(!e.userPaused && !e.attention) actions+=ResourceTransferAction.Pause
                if(e.userPaused && !busy) actions+=ResourceTransferAction.Resume
                if(!hasOwners) actions+=ResourceTransferAction.CancelUnbound
            }
        }
        var confirmed=0L
        work.session?.parts?.forEach {require(it.byteCount<=work.request.byteCount-confirmed);confirmed+=it.byteCount}
        return ManagedResourceTransfer(ResourceTransferId(ResourceTransferKind.Upload,work.id),createdAt,work.request.displayName,work.request.usage,null,group,phase,
            when {stalled->ManagedResourceTransferFailure.CancellationUnconfirmed;work.stage==ResourceUploadStage.Rejected->ManagedResourceTransferFailure.Rejected;work.stage==ResourceUploadStage.Expired->ManagedResourceTransferFailure.Expired;e.attention->ManagedResourceTransferFailure.NeedsAttention;else->null},
            work.request.byteCount,if(work.stage==ResourceUploadStage.Ready) work.request.byteCount else confirmed.takeIf {it>0},
            maxOf(e.retryAt,e.serverRetryAt).takeIf {phase==ResourceTransferPhase.WaitingRetry},actions.toPersistentSet(),hasOwners)
    }
    fun serverImport(work:ResourceImportWork,hasOwners:Boolean,now:Long):ManagedResourceTransfer {
        val e=work.execution;val busy=e.owner!=null;val stalled=work.cancellationRequested && e.attention && !busy && !work.terminal
        val phase=when {
            !work.terminal && stalled->ResourceTransferPhase.RequiresAttention
            !work.terminal && work.cancellationRequested->ResourceTransferPhase.Cancelling
            !work.terminal && e.paused->if(busy) ResourceTransferPhase.Pausing else ResourceTransferPhase.Paused
            work.terminal && work.status?.state==ResourceImportState.Ready->ResourceTransferPhase.Completed
            work.status?.state==ResourceImportState.Cancelled->ResourceTransferPhase.Cancelled
            work.status?.state==ResourceImportState.Failed->ResourceTransferPhase.Failed
            e.attention->ResourceTransferPhase.RequiresAttention
            work.status?.state==ResourceImportState.Copying->ResourceTransferPhase.Transferring
            work.status?.state==ResourceImportState.Processing->ResourceTransferPhase.Processing
            busy->ResourceTransferPhase.Confirming
            maxOf(e.retryAt,e.serverRetryAt)>now->ResourceTransferPhase.WaitingRetry
            else->ResourceTransferPhase.Queued
        }
        val group=when {
            work.terminal && !busy && work.status?.state in setOf(ResourceImportState.Ready,ResourceImportState.Cancelled)->ResourceTransferGroup.Finished
            work.status?.state==ResourceImportState.Failed || !busy && (e.attention || e.paused)->ResourceTransferGroup.Attention
            else->ResourceTransferGroup.Active
        }
        val actions=mutableSetOf<ResourceTransferAction>()
        if(!work.terminal) {
            if(stalled) actions+=ResourceTransferAction.RetryCancellation
            if(!work.cancellationRequested) {
                if(e.attention && !e.paused && !busy) actions+=ResourceTransferAction.Retry
                if(!e.paused && !e.attention) actions+=ResourceTransferAction.Pause
                if(e.paused && !busy) actions+=ResourceTransferAction.Resume
                if(!hasOwners && !work.businessBound && work.request.targetUsage is ResourceUsage.Attachment) actions+=ResourceTransferAction.CancelUnbound
            }
        }
        return ManagedResourceTransfer(ResourceTransferId(ResourceTransferKind.ServerImport,work.id),work.createdAt,null,work.request.targetUsage,null,group,phase,
            when {stalled->ManagedResourceTransferFailure.CancellationUnconfirmed;work.status?.state==ResourceImportState.Failed->ManagedResourceTransferFailure.Rejected;e.attention->ManagedResourceTransferFailure.NeedsAttention;else->null},
            retryAt=maxOf(e.retryAt,e.serverRetryAt).takeIf {phase==ResourceTransferPhase.WaitingRetry},actions=actions.toPersistentSet(),hasBusinessOwners=hasOwners)
    }
    fun download(row:ResourceDownloadSnapshot,now:Long):ManagedResourceTransfer {
        val w=row.work;val busy=w.owner!=null || w.backgroundPending
        val phase=when {
            w.phase==ResourceDownloadPhase.Completed->ResourceTransferPhase.Completed
            w.phase==ResourceDownloadPhase.Stopped->ResourceTransferPhase.Cancelled
            w.control==ResourceDownloadControl.Cancel->ResourceTransferPhase.Cancelling
            w.control==ResourceDownloadControl.Pause->if(busy) ResourceTransferPhase.Pausing else ResourceTransferPhase.Paused
            busy->ResourceTransferPhase.Transferring
            !w.requested->ResourceTransferPhase.RequiresAttention
            maxOf(w.retryAt,w.serverRetryAt)>now->ResourceTransferPhase.WaitingRetry
            else->ResourceTransferPhase.Queued
        }
        val group=when {w.terminal->ResourceTransferGroup.Finished;!busy && (w.control==ResourceDownloadControl.Pause || !w.requested && w.control!=ResourceDownloadControl.Cancel)->ResourceTransferGroup.Attention;else->ResourceTransferGroup.Active}
        val actions=mutableSetOf<ResourceTransferAction>()
        if(!w.terminal && w.control!=ResourceDownloadControl.Cancel) {
            actions+=ResourceTransferAction.Cancel
            if(row.sourceAvailable) {
                if(w.control==ResourceDownloadControl.Run && (w.requested || busy)) actions+=ResourceTransferAction.Pause
                if(!busy && w.control==ResourceDownloadControl.Pause) actions+=ResourceTransferAction.Resume
                if(!busy && w.control==ResourceDownloadControl.Run && !w.requested) actions+=ResourceTransferAction.Retry
            }
        }
        return ManagedResourceTransfer(ResourceTransferId(ResourceTransferKind.Download,w.id),w.createdAt,w.descriptor.displayName.takeIf {row.sourceAvailable},null,w.descriptor.key.takeIf {row.sourceAvailable},group,phase,
            if(phase!=ResourceTransferPhase.RequiresAttention) null else when(w.issue) {ResourceDownloadIssue.Unavailable->ManagedResourceTransferFailure.SourceUnavailable;ResourceDownloadIssue.Authorization->ManagedResourceTransferFailure.Authorization;ResourceDownloadIssue.Integrity->ManagedResourceTransferFailure.Integrity;ResourceDownloadIssue.Storage->ManagedResourceTransferFailure.Storage;else->ManagedResourceTransferFailure.Network},
            w.descriptor.byteCount,w.descriptor.byteCount.takeIf {w.phase==ResourceDownloadPhase.Completed},maxOf(w.retryAt,w.serverRetryAt).takeIf {phase==ResourceTransferPhase.WaitingRetry},actions.toPersistentSet())
    }
}
