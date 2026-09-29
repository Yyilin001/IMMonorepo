import Foundation
import IMV2Core
import IMV2ActorContracts

/// Room operations retain their caller identity and durable recovery contract.
/// Adapters own routing, deadlines and validation of returned receipts.
public protocol V2MessageSendOperationHandling: Sendable {
    func sendOperation(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult
    func recoverSendOperation(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult
}

public protocol V2MessageMutationOperationHandling: Sendable {
    func editOperation(_ command: V2MessageEditOperationCommand) async throws -> V2MessageMutationRecoveryResult
    func withdrawOperation(_ command: V2MessageWithdrawalOperationCommand) async throws -> V2MessageMutationRecoveryResult
    func recoverMutation(_ request: V2MessageMutationRecoveryRequest) async throws -> V2MessageMutationRecoveryResult
}

public protocol V2MessageReactionOperationHandling: Sendable {
    func reactionOperation(_ command: V2MessageReactionOperationCommand) async throws -> V2MessageReactionRecoveryResult
    func recoverReaction(_ request: V2MessageReactionRecoveryRequest) async throws -> V2MessageReactionRecoveryResult
    func reactionSnapshot(roomID: RoomID, actorUserID: UserID, messageID: MessageID, reaction: String) async throws -> V2MessageReactionSnapshot
}

public protocol V2MemberAdministrationOperationHandling: Sendable {
    func admitMemberAdministration(_ intent: V2MemberAdministrationIntent) async throws -> V2MemberAdministrationAdmissionResult
    func submitMemberAdministration(_ input: V2MemberAdministrationCommand) async throws -> V2MemberAdministrationRecoveryResult
    func recoverMemberAdministration(_ input: V2MemberAdministrationRecoveryRequest) async throws -> V2MemberAdministrationRecoveryResult
}

public protocol V2MembershipOperationHandling: Sendable {
    func admitMembershipOperation(_ intent: V2MembershipIntent) async throws -> V2MembershipAdmissionResult
    func submitMembershipOperation(_ input: V2MembershipOperationCommand) async throws -> V2MembershipRecoveryResult
    func recoverMembershipOperation(_ input: V2MembershipRecoveryRequest) async throws -> V2MembershipRecoveryResult
}

public protocol V2GroupCapabilityOperationHandling: Sendable {
    func admitGroupCapability(_ intent: V2GroupCapabilityIntent) async throws -> V2GroupCapabilityAdmissionResult
    func submitGroupCapability(_ input: V2GroupCapabilityCommand) async throws -> V2GroupCapabilityRecoveryResult
    func recoverGroupCapability(_ input: V2GroupCapabilityRecoveryRequest) async throws -> V2GroupCapabilityRecoveryResult
    func pinnedBaseline(actorUserID: UserID, roomID: RoomID, messageID: MessageID) async throws -> V2PinnedMessageBaseline
}

public protocol V2MessageModerationOperationHandling: Sendable {
    func messageModerationBaseline(_ query: V2MessageModerationBaselineQuery) async throws -> V2MessageModerationBaseline
    func admitMessageModeration(_ intent: V2MessageModerationIntent) async throws -> V2MessageModerationAdmissionResult
    func submitMessageModeration(_ input: V2MessageModerationCommand) async throws -> V2MessageModerationRecoveryResult
    func recoverMessageModeration(_ input: V2MessageModerationRecoveryRequest) async throws -> V2MessageModerationRecoveryResult
}

public protocol V2PersonalPreferenceRecovering: Sendable {
    func recoverPersonalPreference(actorUserID: UserID, request: V2PersonalPreferenceRecoveryRequest) async throws -> V2PersonalPreferenceRecoveryResult
}

public protocol V2ReadReceiptRecovering: Sendable {
    func recoverReadReceipt(_ request: V2ReadReceiptRecoveryRequest) async throws -> V2ReadReceiptRecoveryResult
}

public protocol V2GroupInvitationOperationHandling: Sendable {
    func operationBaseline(roomID: RoomID, actorUserID: UserID, deadline: ContinuousClock.Instant) async throws -> V2GroupInvitationOperationBaseline
    func admitOperation(_ request: V2GroupInvitationAdmissionRequest, deadline: ContinuousClock.Instant) async throws -> V2GroupInvitationAdmissionResult
    func submitOperation(_ input: V2GroupInvitationSubmission, deadline: ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult
    func recoverOperation(_ input: V2GroupInvitationRecoveryRequest, deadline: ContinuousClock.Instant) async throws -> V2GroupInvitationOperationRecoveryResult
}
