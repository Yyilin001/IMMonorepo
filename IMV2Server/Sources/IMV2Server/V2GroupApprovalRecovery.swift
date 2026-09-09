import Foundation

public struct V2GroupApprovalRecoveryScope: Equatable, Sendable {
    public let shardID: String
    public let ownerEpoch: Int64
    public let roomID: UUID
    public init(shardID: String, ownerEpoch: Int64, roomID: UUID) throws {
        guard !shardID.isEmpty, shardID.utf8.count <= 128,
              shardID == shardID.trimmingCharacters(in: .whitespacesAndNewlines), ownerEpoch >= 0
        else { throw V2GroupApprovalRecoveryError.invalidRequest }
        self.shardID = shardID; self.ownerEpoch = ownerEpoch; self.roomID = roomID
    }
}

public struct V2GroupApprovalRecoveryCommand: Equatable, Sendable {
    public let operationID: UUID
    public let scope: V2GroupApprovalRecoveryScope
    public let requestID: UUID
    public let reviewerUserID: UUID
    public let decisionOperationID: UUID
    public let reason: V2DurableWorkReplayReason
    public init(operationID: UUID, scope: V2GroupApprovalRecoveryScope, requestID: UUID,
                reviewerUserID: UUID, decisionOperationID: UUID, reason: V2DurableWorkReplayReason) {
        self.operationID = operationID; self.scope = scope; self.requestID = requestID
        self.reviewerUserID = reviewerUserID; self.decisionOperationID = decisionOperationID; self.reason = reason
    }
}

public struct V2GroupApprovalRecoveryCandidate: Equatable, Codable, Sendable {
    public let requestID: UUID
    public let reviewerUserID: UUID
    public let decisionOperationID: UUID
    public let applicantUserID: UUID
    public let preparedRevision: Int64
    public init(requestID: UUID, reviewerUserID: UUID, decisionOperationID: UUID,
                applicantUserID: UUID, preparedRevision: Int64) {
        self.requestID = requestID; self.reviewerUserID = reviewerUserID
        self.decisionOperationID = decisionOperationID; self.applicantUserID = applicantUserID
        self.preparedRevision = preparedRevision
    }
}

public struct V2GroupApprovalRecoveryPage: Equatable, Codable, Sendable {
    public let candidates: [V2GroupApprovalRecoveryCandidate]
    public let nextCursor: UUID?
    public init(candidates: [V2GroupApprovalRecoveryCandidate], nextCursor: UUID?) {
        self.candidates = candidates; self.nextCursor = nextCursor
    }
}

public enum V2GroupApprovalRecoveryOutcome: String, Codable, Sendable {
    case completed, released, quarantined
    case notApproving = "not_approving"
}

public enum V2GroupApprovalRecoveryDetail: String, Codable, Sendable {
    case committedOperation = "committed_operation"
    case noHistoricalAdd = "no_historical_add"
    case operationMismatch = "operation_mismatch"
    case historicalAddWithoutReceipt = "historical_add_without_receipt"
    case invalidRevision = "invalid_revision"
    case inviteExhausted = "invite_exhausted"
    case notApproving = "not_approving"
}

public struct V2GroupApprovalRecoveryResult: Equatable, Codable, Sendable {
    public let operationID: UUID
    public let outcome: V2GroupApprovalRecoveryOutcome
    public let detail: V2GroupApprovalRecoveryDetail
    public let wasIdempotent: Bool
    public init(operationID: UUID, outcome: V2GroupApprovalRecoveryOutcome,
                detail: V2GroupApprovalRecoveryDetail, wasIdempotent: Bool) {
        self.operationID = operationID; self.outcome = outcome
        self.detail = detail; self.wasIdempotent = wasIdempotent
    }
}

public enum V2GroupApprovalRecoveryError: Error, Equatable, Sendable {
    case invalidRequest, unknownShard, ownerChanged, requestNotFound, decisionChanged
    case idempotencyConflict, corruptPersistenceState
}

public protocol V2GroupApprovalRecoveryStore: Sendable {
    func candidates(scope: V2GroupApprovalRecoveryScope, after: UUID?, limit: Int) async throws -> V2GroupApprovalRecoveryPage
    func recover(_ command: V2GroupApprovalRecoveryCommand, operatorPrincipal: String, now: Date) async throws -> V2GroupApprovalRecoveryResult
}

/// Recovery never adds a member. Released requests must pass the ordinary
/// approval path with a new operation and current reviewer authorization.
public struct V2GroupApprovalRecoveryService: Sendable {
    private let stores: [String: any V2GroupApprovalRecoveryStore]
    private let principal: String
    private let now: @Sendable () -> Date
    public init(stores: [String: any V2GroupApprovalRecoveryStore], operatorPrincipal: String,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal)
        else { throw V2GroupApprovalRecoveryError.invalidRequest }
        self.stores = stores; principal = operatorPrincipal; self.now = now
    }
    public func candidates(scope: V2GroupApprovalRecoveryScope, after: UUID?, limit: Int) async throws -> V2GroupApprovalRecoveryPage {
        guard (1...100).contains(limit) else { throw V2GroupApprovalRecoveryError.invalidRequest }
        guard let store = stores[scope.shardID] else { throw V2GroupApprovalRecoveryError.unknownShard }
        return try await store.candidates(scope: scope, after: after, limit: limit)
    }
    public func recover(_ command: V2GroupApprovalRecoveryCommand) async throws -> V2GroupApprovalRecoveryResult {
        guard let store = stores[command.scope.shardID] else { throw V2GroupApprovalRecoveryError.unknownShard }
        return try await store.recover(command, operatorPrincipal: principal, now: now())
    }
}
