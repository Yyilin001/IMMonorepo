package com.xmtx.im.client

data class NameOperationClaim(val claim: OperationWorkClaim, val work: NameWork) {
    init { require(claim.work.id == work.command.operation && claim.work.actor == work.command.actor && claim.work.fingerprint == work.command.fingerprint) }
}

/** Transactional adapter for platforms with durable operation ownership. */
interface NameOperationClaimStore : NameOperationStore, OperationWorkReading {
    suspend fun enqueueName(command: NameCommand, now: Long): NameWork
    /** Explicit ownership handoff; callers must first stop and await all previous physical steps. */
    suspend fun recoverNameClaimsAfterDrain(owner: String, now: Long)
    suspend fun claimName(operation: String, owner: String, now: Long): NameOperationClaim?
    suspend fun deferName(claim: NameOperationClaim, until: Long, code: String, attention: Boolean, nextAction: OperationWorkAction)
    suspend fun completeName(claim: NameOperationClaim, receipt: NameResult.Receipt, now: Long)
    suspend fun retryName(operation: String, now: Long)
    suspend fun cancelOrCloseName(operation: String, now: Long)
}
