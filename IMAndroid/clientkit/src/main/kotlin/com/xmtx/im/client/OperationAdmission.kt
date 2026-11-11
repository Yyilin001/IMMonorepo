package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentSet

/** Durable semantic work, independent of HTTP concurrency and resource-file quotas. */
data class OperationAdmissionLimits(val maximumActiveCount: Long = 2_000, val maximumReservedBytes: Long = 32L * 1_024 * 1_024) {
    init { require(maximumActiveCount > 0 && maximumReservedBytes > 0) }
}

/** Explicit coverage while domain adapters are migrated into the common ledger. */
enum class OperationAdmissionDomain {
    DirectRoom, SocialProposal, Social, Membership, Administration, Invitation, GroupCapability, AccountPreference, Moderation,
    ReadIntent, ReadOperation, GroupCreation, ForwardPlan, PersonalPreference, MessageMutation, MessageReaction,
    SendPreparation, MessageSend, ProfilePreparation, OwnProfile, Name
}

/** activeCount/reservedBytes are ordinary admission; recovery control has a separate budget. */
data class OperationAdmissionUsage(val activeCount: Long, val reservedBytes: Long, val domains: PersistentSet<OperationAdmissionDomain>,
    val controlCount: Long = 0, val controlReservedBytes: Long = 0) {
    init { require(activeCount >= 0 && reservedBytes >= 0 && controlCount >= 0 && controlReservedBytes >= 0) }
}

class OperationCapacityExceeded : IllegalStateException("待确认操作已达到本机额度，请先处理已有操作")

interface OperationAdmissionReading {
    /** One database snapshot, without command identities, credentials or payloads. */
    suspend fun operationAdmissionUsage(): OperationAdmissionUsage
}
