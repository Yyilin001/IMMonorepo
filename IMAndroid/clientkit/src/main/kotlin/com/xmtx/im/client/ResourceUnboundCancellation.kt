package com.xmtx.im.client

/** A single-use review issued by one live account store. The frozen request remains private. */
data class ResourceUnboundCancellationPlan(val id:String,val transfer:ResourceTransferId) {
    init {require(uuidId(id)==id && transfer.kind!=ResourceTransferKind.Download)}
}

interface ResourceUnboundCancellationStore {
    suspend fun planUnboundResourceCancellation(transfer:ResourceTransferId):ResourceUnboundCancellationPlan
    /** Rechecks the original request, source identity, unfinished state and absence of business owners. */
    suspend fun cancelUnboundResource(plan:ResourceUnboundCancellationPlan)
}
