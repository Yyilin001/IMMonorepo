package com.xmtx.im.client

import kotlinx.coroutines.*

/** Matches the domain registration keys in IMV2Core.ApplicationOperation; never an operation identity. */
@kotlinx.serialization.Serializable enum class OperationKind {
    SendMessage,WithdrawMessage,EditMessage,Reaction,ReadReceipt,DirectRoom,GroupRoom,Membership,
    Moderation,MemberMute,ModeratedMemberRemoval,StrangerMessagePreference,UserAddPreference,
    ReadReceiptPreference,LiveActivityPreference,Relationship,UserBlock,ConversationPreference,
    MessageFavorite,PinnedMessage,GroupAnnouncement,GroupPermission,GroupRole,GroupOwnership,
    GroupDissolution,ForwardMessage,ProfileUpdate,ContactAlias,GroupNickname,GroupInvite,
    GroupJoinRequest,GroupJoinDecision,MediaUpload,GroupAvatar
}
@kotlinx.serialization.Serializable enum class OperationWorkAction { Submit,Reconcile }
@kotlinx.serialization.Serializable enum class OperationExecutionState {
    Prepared,Submitting,Processing,AwaitingConfirmation,Committed,Rejected,Conflicted,Closed,CancelledLocally,ExpiredUnsubmitted
}
@kotlinx.serialization.Serializable enum class OperationSchedulingState {
    Ready,Claimed,WaitingForDependency,WaitingForAuthentication,WaitingForNetwork,BackingOff,NeedsAttention,Suspended,Finished
}
/** A journal observation, not an outcome inferred from handler return or transport success. */
data class OperationStepObservation(val execution:OperationExecutionState,val scheduling:OperationSchedulingState)
data class OperationStepMetric(val kind:OperationKind,val action:OperationWorkAction,val attempt:Int,
    val priority:NetworkWorkPriority,val candidateWaitNanos:Long,val handlerElapsedNanos:Long,
    val completion:Completion,val observation:OperationStepObservation?) {
    enum class Completion { Returned,Threw,Cancelled }
    init {require(attempt>0 && candidateWaitNanos>=0 && handlerElapsedNanos>=0)}
    val certainty:NetworkMetric.Certainty get()=when(observation?.execution) {
        OperationExecutionState.Committed,OperationExecutionState.Rejected,OperationExecutionState.Conflicted,
        OperationExecutionState.Closed->NetworkMetric.Certainty.ResponseReceived
        OperationExecutionState.Prepared,OperationExecutionState.CancelledLocally,OperationExecutionState.ExpiredUnsubmitted->NetworkMetric.Certainty.NotStarted
        else->NetworkMetric.Certainty.OutcomeUnknown
    }
}

/** Observation happens after the handler and is excluded from its elapsed time. A diagnostic read
 * failure must not replace the handler result/error. The account owner still drains this child before
 * closing its store. No identity, payload or error object escapes into the diagnostics window.
 */
internal suspend fun <T> measureOperationStep(kind:OperationKind,action:OperationWorkAction,attempt:Int,
    isRetry:Boolean,candidatesObservedNanos:Long,observe:suspend ()->OperationStepObservation?,
    nanoTime:()->Long=System::nanoTime,diagnosticsProvider:(()->NetworkDiagnostics?)?=null,
    priority:NetworkWorkPriority=if(isRetry) NetworkWorkPriority.Recovery else NetworkWorkPriority.Interactive,body:suspend ()->T):T {
    val context=currentCoroutineContext()
    val diagnostics=context[NetworkWorkScope]?.scheduler?.networkDiagnostics ?: context[NetworkDiagnosticsScope]?.diagnostics
    if(diagnosticsProvider==null && (diagnostics==null || diagnostics.snapshot().closed)) return body()
    val start=nanoTime()
    var completion=OperationStepMetric.Completion.Returned
    try {return body()}
    catch(error:Throwable) {
        completion=if(error is CancellationException) OperationStepMetric.Completion.Cancelled else OperationStepMetric.Completion.Threw
        throw error
    } finally {
        val elapsed=(nanoTime()-start).coerceAtLeast(0)
        // A connection-bound account wins over caller scope, even if captured during the handler.
        val selected=diagnosticsProvider?.invoke() ?: diagnostics
        if(selected!=null && !selected.snapshot().closed) {
        // Cancellation/failed persistence provides no journal proof. Avoid new reads on cancellation.
        val observation=if(context.isActive) try {observe()} catch(_:Exception) {null} else null
        selected.record(OperationStepMetric(kind,action,attempt,
            priority,
            (start-candidatesObservedNanos).coerceAtLeast(0),elapsed,completion,observation))
        }
    }
}

internal fun operationObservation(terminal:OperationExecutionState?,submitted:Boolean,attention:Boolean,
    nextAttempt:Long,now:Long,processing:Boolean=false,dependency:Boolean=false)=OperationStepObservation(
    terminal ?: when {processing->OperationExecutionState.Processing;submitted->OperationExecutionState.AwaitingConfirmation;else->OperationExecutionState.Prepared},
    when {terminal!=null->OperationSchedulingState.Finished;attention->OperationSchedulingState.NeedsAttention
        dependency->OperationSchedulingState.WaitingForDependency;nextAttempt>now->OperationSchedulingState.BackingOff;else->OperationSchedulingState.Ready})

internal fun NameWork.operationObservation(now:Long)=operationObservation(when(status) {
    NameStatus.Committed->OperationExecutionState.Committed;NameStatus.Rejected->OperationExecutionState.Rejected
    NameStatus.Conflicted->OperationExecutionState.Conflicted;NameStatus.Closed->OperationExecutionState.Closed
    NameStatus.Cancelled->if(reason=="expiredUnsubmitted") OperationExecutionState.ExpiredUnsubmitted else OperationExecutionState.CancelledLocally
    NameStatus.Pending,NameStatus.NeedsAttention->null
},submissionStarted,status==NameStatus.NeedsAttention,nextAttempt,now)

internal fun OwnProfileWork.operationObservation(now:Long)=operationObservation(when(status) {
    OwnProfileStatus.Committed->OperationExecutionState.Committed;OwnProfileStatus.Rejected->OperationExecutionState.Rejected
    OwnProfileStatus.Conflicted->OperationExecutionState.Conflicted;OwnProfileStatus.Closed->OperationExecutionState.Closed
    OwnProfileStatus.Expired->OperationExecutionState.ExpiredUnsubmitted
    OwnProfileStatus.Pending,OwnProfileStatus.NeedsAttention->null
},submissionStarted,status==OwnProfileStatus.NeedsAttention,nextAttempt,now)

internal fun PersonalWork.operationObservation(now:Long)=operationObservation(when(status) {
    PersonalStatus.Committed->OperationExecutionState.Committed;PersonalStatus.Rejected->OperationExecutionState.Rejected
    PersonalStatus.Conflicted->OperationExecutionState.Conflicted;PersonalStatus.Closed->OperationExecutionState.Closed
    PersonalStatus.Expired->OperationExecutionState.ExpiredUnsubmitted;PersonalStatus.Cancelled->OperationExecutionState.CancelledLocally
    PersonalStatus.Pending,PersonalStatus.NeedsAttention,PersonalStatus.Queued->null
},submissionStarted,status==PersonalStatus.NeedsAttention,nextAttempt,now,dependency=status==PersonalStatus.Queued)

internal fun ForwardWork.operationObservation(now:Long)=operationObservation(when(status) {
    ForwardStatus.Committed->OperationExecutionState.Committed;ForwardStatus.Rejected->OperationExecutionState.Rejected
    ForwardStatus.Closed->OperationExecutionState.Closed;ForwardStatus.Expired->OperationExecutionState.ExpiredUnsubmitted
    // Cancellation of a submitted forward may already have delivered some targets. It is not NotStarted.
    ForwardStatus.Cancelled->if(submissionStarted) OperationExecutionState.Closed else OperationExecutionState.CancelledLocally
    ForwardStatus.Pending,ForwardStatus.NeedsAttention->null
},submissionStarted,status==ForwardStatus.NeedsAttention,nextAttempt,now,processing=progress!=null)

internal fun MessageMutationWork.operationObservation(now:Long)=operationObservation(when(status) {
    MutationStatus.Committed->OperationExecutionState.Committed;MutationStatus.Rejected->OperationExecutionState.Rejected
    MutationStatus.Conflicted->OperationExecutionState.Conflicted;MutationStatus.Closed->OperationExecutionState.Closed
    MutationStatus.Pending,MutationStatus.NeedsAttention->null
},commandExecutionStarted(executionStarted),status==MutationStatus.NeedsAttention,nextAttempt,now)

internal fun ReactionWork.operationObservation(now:Long)=operationObservation(when(status) {
    ReactionStatus.Committed->OperationExecutionState.Committed;ReactionStatus.Rejected->OperationExecutionState.Rejected
    ReactionStatus.Conflicted->OperationExecutionState.Conflicted;ReactionStatus.Closed->OperationExecutionState.Closed
    ReactionStatus.Expired->OperationExecutionState.ExpiredUnsubmitted;ReactionStatus.Cancelled->OperationExecutionState.CancelledLocally
    ReactionStatus.Draft,ReactionStatus.PreparationPaused,ReactionStatus.Pending,ReactionStatus.NeedsAttention->null
},command!=null && commandExecutionStarted(executionStarted),
    status==ReactionStatus.NeedsAttention || status==ReactionStatus.PreparationPaused,nextAttempt,now,
    dependency=command==null)

internal fun ReadWork.operationObservation(now:Long):OperationStepObservation {
    // As in Swift's durable journal, either validated original receipt or covering watermark
    // satisfies the read intent. Committed here does not assert execution of the original request.
    val value=operationObservation(if(status==ReadStatus.Confirmed) OperationExecutionState.Committed else null,
        submissionStarted,status==ReadStatus.NeedsAttention,nextAttempt,now)
    return if(status==ReadStatus.Archived) value.copy(scheduling=OperationSchedulingState.Suspended) else value
}

internal fun DirectRoomWork.operationObservation(now:Long)=operationObservation(when(status) {
    DirectWorkStatus.Opened->OperationExecutionState.Committed;DirectWorkStatus.Rejected->OperationExecutionState.Rejected
    DirectWorkStatus.Closed->OperationExecutionState.Closed;DirectWorkStatus.Pending,DirectWorkStatus.NeedsAttention->null
},commandExecutionStarted(executionStarted),status==DirectWorkStatus.NeedsAttention,nextAttemptMilliseconds,now,processing=processing)

internal fun SocialWork.operationObservation(now:Long)=operationObservation(when(status) {
    SocialWorkStatus.Committed->OperationExecutionState.Committed;SocialWorkStatus.Rejected->OperationExecutionState.Rejected
    SocialWorkStatus.Conflicted->OperationExecutionState.Conflicted;SocialWorkStatus.Closed->OperationExecutionState.Closed
    SocialWorkStatus.Pending,SocialWorkStatus.NeedsAttention->null
},commandExecutionStarted(executionStarted),status==SocialWorkStatus.NeedsAttention,nextAttemptMilliseconds,now)

/** Caller supplies persisted recovery state, not a newly proposed defer state. */
fun SendRecovery.operationObservation(now:Long,claimed:Boolean=false):OperationStepObservation {
    val execution=when {status==SendRecoveryStatus.ExpiredUnsubmitted->OperationExecutionState.ExpiredUnsubmitted
        submitted->OperationExecutionState.AwaitingConfirmation;else->OperationExecutionState.Prepared}
    val scheduling=when(status) {
        SendRecoveryStatus.ExpiredUnsubmitted->OperationSchedulingState.Finished
        SendRecoveryStatus.NeedsAttention->OperationSchedulingState.NeedsAttention
        SendRecoveryStatus.WaitingForNetwork->OperationSchedulingState.WaitingForNetwork
        SendRecoveryStatus.WaitingForAuthentication->OperationSchedulingState.WaitingForAuthentication
        SendRecoveryStatus.Queued,SendRecoveryStatus.Confirming->when {claimed->OperationSchedulingState.Claimed
            nextAt>now->OperationSchedulingState.BackingOff;else->OperationSchedulingState.Ready}
    }
    return OperationStepObservation(execution,scheduling)
}

internal fun PreferenceKind.operationKind()=when(this) {
    PreferenceKind.StrangerMessages->OperationKind.StrangerMessagePreference;PreferenceKind.UserAdd->OperationKind.UserAddPreference
    PreferenceKind.ReadReceipts->OperationKind.ReadReceiptPreference;PreferenceKind.LiveActivity->OperationKind.LiveActivityPreference
}
internal fun GroupAction.operationKind()=when(this) {
    is GroupAction.Pin->OperationKind.PinnedMessage;is GroupAction.Announcement->OperationKind.GroupAnnouncement
    is GroupAction.Permissions->OperationKind.GroupPermission;is GroupAction.Role->OperationKind.GroupRole
    is GroupAction.Transfer->OperationKind.GroupOwnership;is GroupAction.Dissolve->OperationKind.GroupDissolution
}
internal fun PreferenceWork.operationObservation(now:Long)=operationObservation(when(status) {
    PreferenceStatus.Committed->OperationExecutionState.Committed;PreferenceStatus.Rejected->OperationExecutionState.Rejected
    PreferenceStatus.Conflicted->OperationExecutionState.Conflicted;PreferenceStatus.Closed->OperationExecutionState.Closed
    PreferenceStatus.DraftCancelled->OperationExecutionState.CancelledLocally
    PreferenceStatus.DraftReady,PreferenceStatus.DraftPaused,PreferenceStatus.Pending,PreferenceStatus.NeedsAttention->null
},command!=null && commandExecutionStarted(executionStarted),status==PreferenceStatus.NeedsAttention || status==PreferenceStatus.DraftPaused,
    nextAttemptMilliseconds,now,dependency=command==null)

internal fun GroupCapabilityWork.operationObservation(now:Long)=operationObservation(when(status) {
    GroupCapabilityStatus.Committed->OperationExecutionState.Committed;GroupCapabilityStatus.Rejected->OperationExecutionState.Rejected
    GroupCapabilityStatus.Conflicted->OperationExecutionState.Conflicted;GroupCapabilityStatus.Closed->OperationExecutionState.Closed
    GroupCapabilityStatus.DraftCancelled->OperationExecutionState.CancelledLocally
    GroupCapabilityStatus.DraftReady,GroupCapabilityStatus.DraftPaused,GroupCapabilityStatus.Pending,GroupCapabilityStatus.NeedsAttention->null
},admission!=null && commandExecutionStarted(executionStarted),status==GroupCapabilityStatus.NeedsAttention || status==GroupCapabilityStatus.DraftPaused,
    nextAttemptMilliseconds,now,dependency=admission==null)

internal fun MembershipWork.operationObservation(now:Long)=operationObservation(when(status) {
    MembershipStatus.Committed->OperationExecutionState.Committed;MembershipStatus.Rejected->OperationExecutionState.Rejected
    MembershipStatus.Conflicted->OperationExecutionState.Conflicted;MembershipStatus.Closed->OperationExecutionState.Closed
    MembershipStatus.DraftCancelled->OperationExecutionState.CancelledLocally
    MembershipStatus.DraftReady,MembershipStatus.DraftPaused,MembershipStatus.Pending,MembershipStatus.NeedsAttention->null
},admission!=null && commandExecutionStarted(executionStarted),status==MembershipStatus.NeedsAttention || status==MembershipStatus.DraftPaused,
    nextAttemptMilliseconds,now,dependency=admission==null)

internal fun GroupCreationWork.operationObservation(now: Long) = operationObservation(when(status) {
    GroupCreationStatus.Created -> OperationExecutionState.Committed
    GroupCreationStatus.Rejected -> OperationExecutionState.Rejected
    GroupCreationStatus.Closed -> OperationExecutionState.Closed
    GroupCreationStatus.Pending, GroupCreationStatus.NeedsAttention -> null
}, commandExecutionStarted(retryRequired), status == GroupCreationStatus.NeedsAttention,
    nextAttemptMilliseconds, now, processing = progress != null)

internal fun InvitationAction.operationKind() = when(this) {
    is InvitationAction.Create, is InvitationAction.Revoke -> OperationKind.GroupInvite
    is InvitationAction.Submit, is InvitationAction.Cancel -> OperationKind.GroupJoinRequest
    is InvitationAction.Decide -> OperationKind.GroupJoinDecision
}
internal fun AdministrationAction.operationKind() = when(this) {
    is AdministrationAction.Mute -> OperationKind.MemberMute
    AdministrationAction.Remove -> OperationKind.ModeratedMemberRemoval
}
internal fun InvitationWork.operationObservation(now: Long) = operationObservation(when(status) {
    InvitationStatus.Committed -> OperationExecutionState.Committed
    InvitationStatus.Rejected -> OperationExecutionState.Rejected
    InvitationStatus.Conflicted -> OperationExecutionState.Conflicted
    InvitationStatus.Closed -> OperationExecutionState.Closed
    InvitationStatus.DraftCancelled -> OperationExecutionState.CancelledLocally
    InvitationStatus.DraftReady, InvitationStatus.DraftPaused, InvitationStatus.Pending, InvitationStatus.NeedsAttention -> null
}, !draft && commandExecutionStarted(executionStarted), status == InvitationStatus.NeedsAttention || status == InvitationStatus.DraftPaused,
    nextAttempt, now, dependency = draft)

internal fun AdministrationWork.operationObservation(now: Long) = operationObservation(when(status) {
    AdministrationStatus.Committed -> OperationExecutionState.Committed
    AdministrationStatus.Rejected -> OperationExecutionState.Rejected
    AdministrationStatus.Conflicted -> OperationExecutionState.Conflicted
    AdministrationStatus.Closed -> OperationExecutionState.Closed
    AdministrationStatus.DraftCancelled -> OperationExecutionState.CancelledLocally
    AdministrationStatus.DraftReady, AdministrationStatus.DraftPaused, AdministrationStatus.Pending, AdministrationStatus.NeedsAttention -> null
}, admission != null && commandExecutionStarted(executionStarted), status == AdministrationStatus.NeedsAttention || status == AdministrationStatus.DraftPaused,
    nextAttempt, now, dependency = admission == null)

// Unlike draft preparation, moderation admission is itself a durable dispatch step in Swift.
// Its successful return provides no terminal proof; only the persisted receipt does.
internal fun ModerationWork.operationObservation(now: Long) = operationObservation(when(status) {
    ModerationStatus.Committed -> OperationExecutionState.Committed
    ModerationStatus.Rejected -> OperationExecutionState.Rejected
    ModerationStatus.Conflicted -> OperationExecutionState.Conflicted
    ModerationStatus.Closed -> OperationExecutionState.Closed
    ModerationStatus.Pending, ModerationStatus.NeedsAttention -> null
}, commandExecutionStarted(executionStarted), status == ModerationStatus.NeedsAttention, nextAttempt, now)

internal fun GroupAvatarIntent.operationObservation(now: Long): OperationStepObservation {
    val value=operationObservation(when(stage) {
        GroupAvatarStage.Committed -> OperationExecutionState.Committed
        GroupAvatarStage.Cancelled -> OperationExecutionState.CancelledLocally
        GroupAvatarStage.Closed -> OperationExecutionState.Closed
        GroupAvatarStage.Preparing,GroupAvatarStage.Submitted,GroupAvatarStage.NeedsAttention -> null
    },submissionStarted,stage==GroupAvatarStage.NeedsAttention,maxOf(retryAt,serverRetryAt),now,
        dependency=stage==GroupAvatarStage.Preparing && (upload!=null || serverImport!=null))
    return if(!terminal && claim!=null && claimUntil!!>now) value.copy(scheduling=OperationSchedulingState.Claimed) else value
}

internal fun ResourceUploadWork.operationObservation(now: Long): OperationStepObservation {
    // Terminal resource stages are installed from validated control facts, never from byte-transfer success.
    val value=operationObservation(when(stage) {
        ResourceUploadStage.Ready -> if(session?.state==ResourceSessionState.Completed && session.resourceState==ResourceState.Ready) OperationExecutionState.Committed else null
        ResourceUploadStage.Rejected -> if(session?.state==ResourceSessionState.Failed || session?.resourceState in setOf(ResourceState.Rejected,ResourceState.Deleted,ResourceState.DeletionPending)) OperationExecutionState.Rejected else null
        ResourceUploadStage.Cancelled,ResourceUploadStage.Expired -> if(session?.state in setOf(ResourceSessionState.Cancelled,ResourceSessionState.Expired,ResourceSessionState.Failed)) OperationExecutionState.Closed else null
        ResourceUploadStage.Prepared,ResourceUploadStage.Transferring,ResourceUploadStage.Processing,ResourceUploadStage.Paused -> null
    },execution.totalAttempts>0 || session!=null || stage!=ResourceUploadStage.Prepared,execution.attention,maxOf(execution.retryAt,execution.serverRetryAt),now,
        processing=stage==ResourceUploadStage.Processing)
    if(terminal) return value
    return when {
        execution.owner!=null -> value.copy(scheduling=OperationSchedulingState.Claimed)
        execution.userPaused || execution.backgroundPending -> value.copy(scheduling=OperationSchedulingState.Suspended)
        else -> value
    }
}
