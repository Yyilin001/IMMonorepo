package com.xmtx.im.client

/** Frozen profile payload paired with its immutable ownership token. */
data class OwnProfileOperationClaim(val claim: OperationWorkClaim, val work: OwnProfileWork) {
    init { require(claim.work.id == work.command.operation && claim.work.actor == work.command.actor && claim.work.fingerprint == work.command.fingerprint && claim.work.kind == OperationKind.ProfileUpdate) }
}

interface OwnProfileOperationClaimStore : OwnProfileStore, OperationWorkReading {
    suspend fun enqueueOwnProfile(command: OwnProfileCommand, replaces: String?, now: Long): OwnProfileWork
    /** Call only after stopping and awaiting the previous owner's physical steps. */
    suspend fun recoverOwnProfileClaimsAfterDrain(owner: String, now: Long)
    suspend fun claimOwnProfile(operation: String, owner: String, now: Long): OwnProfileOperationClaim?
    suspend fun deferOwnProfile(claim: OwnProfileOperationClaim, until: Long, code: String, attention: Boolean, nextAction: OperationWorkAction)
    suspend fun completeOwnProfile(claim: OwnProfileOperationClaim, receipt: OwnProfileResult.Receipt, now: Long)
    suspend fun retryOwnProfile(operation: String, now: Long)
}
