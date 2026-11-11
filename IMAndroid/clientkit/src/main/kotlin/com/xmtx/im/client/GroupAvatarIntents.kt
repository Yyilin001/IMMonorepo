package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable enum class GroupAvatarStage { Preparing, Submitted, NeedsAttention, Committed, Cancelled, Closed }
@Serializable enum class GroupAvatarDisposition { AwaitingDecision, Abandoned, Replaced }
@Serializable enum class GroupAvatarIssue { PreparationUnavailable, OutcomeUnknown, AuthorizationUnavailable, InvalidResponse, Throttled, RevisionConflict, IdempotencyConflict, ResourceUnavailable, Forbidden }
@Serializable data class GroupAvatarClosureProof(val actor: UserId,val device: DeviceId,val request: GroupAvatarRecoveryRequest)
@Serializable data class GroupAvatarImportPreparation(val id: String,val request: ResourceImportRequest) {
    init {require(uuidId(id)==id && request.targetUsage is ResourceUsage.GroupAvatar)}
}
@Serializable data class GroupAvatarIntent(val actor: UserId,val device: DeviceId,val command: GroupAvatarCommand,val createdAt: Long,
    val upload: String?=null,val asset: String?=null,val stage: GroupAvatarStage=GroupAvatarStage.Preparing,
    val submissionStarted: Boolean=false,val action: GroupAvatarRecoveryAction?=null,val disposition: GroupAvatarDisposition=GroupAvatarDisposition.AwaitingDecision,
    val attempts: Int=0,val retryAt: Long=0,val serverRetryAt: Long=0,val issue: GroupAvatarIssue?=null,
    val claim: String?=null,val claimUntil: Long?=null,val receipt: GroupAvatarChange?=null,val proof: GroupAvatarClosureProof?=null,
    val serverImport: GroupAvatarImportPreparation?=null,
    val sourceReleased: Boolean=upload==null && serverImport==null,val replacementOf: String?=null) {
    init {
        uuidId(actor.value);require(createdAt>=0 && retryAt>=0 && serverRetryAt>=0 && attempts in 0..5)
        listOfNotNull(upload,asset,claim,replacementOf).forEach { require(uuidId(it)==it) }
        require((upload==null)==(asset==null) && (upload==null || serverImport==null))
        require((upload==null && serverImport==null)==(command.mutation==GroupAvatarMutation.Remove))
        require(upload!=null || serverImport!=null || sourceReleased)
        serverImport?.let {require(it.request.targetUsage==ResourceUsage.GroupAvatar(command.room) && it.request.targetMedia==command.mutation.mediaId)}
        require((claim==null)==(claimUntil==null) && (claimUntil==null || claimUntil>=0))
        require(claim==null || stage==GroupAvatarStage.Submitted)
        require((stage==GroupAvatarStage.Committed)==(receipt!=null) && (stage==GroupAvatarStage.Closed)==(proof!=null))
        require(stage==GroupAvatarStage.Closed || disposition==GroupAvatarDisposition.AwaitingDecision)
        require(stage !in setOf(GroupAvatarStage.Submitted,GroupAvatarStage.Committed,GroupAvatarStage.Closed) || submissionStarted)
        require(stage !in setOf(GroupAvatarStage.Preparing,GroupAvatarStage.Cancelled) || !submissionStarted)
        require(action==null || submissionStarted)
        receipt?.boundTo(command)
        proof?.let { require(it.actor==actor && it.device==device && it.request.command==command) }
    }
    val id get()=command.operation
    val terminal get()=stage in setOf(GroupAvatarStage.Committed,GroupAvatarStage.Cancelled,GroupAvatarStage.Closed)
    val pending get()=!terminal || stage==GroupAvatarStage.Closed && disposition==GroupAvatarDisposition.AwaitingDecision
}
/** Cannot substitute a stored logical avatar state for a current management authorization. */
data class GroupAvatarEditAuthority(val presentation: GroupAvatarPresentation,val fence: GroupAvatarFence)
data class GroupAvatarUploadPreparation(val id: String,val asset: String,val request: ResourceUploadRequest) {
    init { require(uuidId(id)==id && uuidId(asset)==asset) }
}
data class GroupAvatarOriginalConsumer(val intent: String): ResourceImportConsumer {
    init { require(uuidId(intent)==intent) }
    override val key get()="groupAvatar/$intent"
}
data class GroupAvatarClaim(val intent: GroupAvatarIntent,val token: String) {
    init { require(intent.claim==token) }
}
interface GroupAvatarIntentStore {
    val groupAvatarIntentChanges: StateFlow<Long>
    suspend fun groupAvatarIntents(): PersistentList<GroupAvatarIntent>
    suspend fun groupAvatarIntent(id: String): GroupAvatarIntent? = groupAvatarIntents().firstOrNull { it.id == id }
    suspend fun groupAvatarFence(room: RoomId): GroupAvatarFence
    suspend fun enqueueGroupAvatar(authority: GroupAvatarEditAuthority,command: GroupAvatarCommand,upload: GroupAvatarUploadPreparation?,now: Long): GroupAvatarIntent
    suspend fun enqueueImportedGroupAvatar(authority: GroupAvatarEditAuthority,command: GroupAvatarCommand,source: GroupAvatarImportPreparation,now: Long): GroupAvatarIntent
    suspend fun prepareGroupAvatars(now: Long)
    suspend fun dueGroupAvatars(now: Long): PersistentList<String>
    suspend fun claimGroupAvatar(id: String,now: Long): GroupAvatarClaim?
    suspend fun finishGroupAvatar(claim: GroupAvatarClaim,response: GroupAvatarCommandResponse,now: Long)
    suspend fun finishGroupAvatarRecovery(claim: GroupAvatarClaim,response: GroupAvatarRecoveryResponse,now: Long)
    suspend fun failGroupAvatar(claim: GroupAvatarClaim,issue: GroupAvatarIssue,retryAt: Long,attention: Boolean,serverRetryAt: Long=0)
    suspend fun retryGroupAvatar(id: String)
    suspend fun requestGroupAvatarRecovery(id: String,action: GroupAvatarRecoveryAction)
    suspend fun cancelGroupAvatar(id: String)
    suspend fun abandonGroupAvatar(id: String)
    suspend fun replaceGroupAvatar(id: String,authority: GroupAvatarEditAuthority,operation: String,upload: String,media: String,now: Long): GroupAvatarIntent
}
internal fun newGroupAvatarId()=UUID.randomUUID().toString().uppercase()
