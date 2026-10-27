import Foundation
import IMV2Core

public enum V2GroupAvatarPreparation: Equatable, Sendable {
    case upload(UUID), serverImport(UUID)
}

/// An account-owned, frozen management operation, independent of message outboxes.
/// It never contains a provider URL, credential or presentation lease.
public struct V2GroupAvatarIntent: Identifiable, Equatable, Sendable {
    public enum Stage: String, Sendable { case preparing, submitted, needsAttention, committed, cancelled, closed }
    public enum ClosedDisposition: String, Sendable { case awaitingDecision, abandoned, replaced }
    public enum Issue: String, Sendable {
        case preparationUnavailable, outcomeUnknown, authorizationUnavailable, invalidResponse, throttled
        case revisionConflict, idempotencyConflict, resourceUnavailable, forbidden
    }
    public var id: GroupAvatarOperationID { command.operationID }
    public let actorUserID: UserID
    public let command: V2GroupAvatarCommand
    public let preparation: V2GroupAvatarPreparation?
    public var uploadJobID: UUID? { if case .upload(let id) = preparation { id } else { nil } }
    public var importJobID: UUID? { if case .serverImport(let id) = preparation { id } else { nil } }
    public let stage: Stage
    public let submissionStarted: Bool
    public let recoveryAction: V2GroupAvatarRecoveryRequest.Action?
    public let closedDisposition: ClosedDisposition
    public let attempts: Int
    public let retryAt: Date
    public let issue: Issue?
    public let receipt: V2GroupAvatarChange?
    public let closureProof: V2GroupAvatarRecoveryResponse?
    public var canCancel: Bool { !submissionStarted && stage != .cancelled && stage != .committed }
}

public enum V2GroupAvatarIntentError: Error, Equatable, Sendable {
    case accountMismatch, conflict, missing, busy, invalidRecord, alreadySubmitted, recoveryUnavailable
}

struct V2GroupAvatarSubmissionClaim: Sendable {
    let id: UUID
    let intent: V2GroupAvatarIntent
}
