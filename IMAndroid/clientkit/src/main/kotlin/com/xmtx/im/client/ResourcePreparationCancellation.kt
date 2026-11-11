package com.xmtx.im.client

/** Opaque preview issued by one account-store instance. No message bodies or source capabilities escape. */
data class ResourcePreparationCancellationPlan(val id:String,val transfer:ResourceTransferId,val messageCount:Int) {
    init {require(uuidId(id)==id && transfer.kind!=ResourceTransferKind.Download && messageCount in 1..64)}
}
data class ResourcePreparationCancellationResult(val cancelledMessages:Int,val requestedUploadCancellations:Int,val requestedImportCancellations:Int) {
    init {require(cancelledMessages in 1..64 && requestedUploadCancellations>=0 && requestedImportCancellations>=0 && requestedUploadCancellations.toLong()+requestedImportCancellations<=cancelledMessages*10L)}
}
interface ResourcePreparationCancellationStore {
    suspend fun planResourcePreparationCancellation(transfer:ResourceTransferId):ResourcePreparationCancellationPlan
    /** Rechecks the reviewed parent set and the absence of any outbox handoff in the same transaction. */
    suspend fun cancelResourcePreparation(plan:ResourcePreparationCancellationPlan):ResourcePreparationCancellationResult
}
