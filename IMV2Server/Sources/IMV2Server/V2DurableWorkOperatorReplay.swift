import Foundation
import IMV2Core

/// The closed durable-work shapes that an operator may replay.  This is a
/// closed vocabulary so the control plane can never turn an arbitrary table
/// update into an administrative API.
public enum V2DurableWorkReplayTargetKind: String, CaseIterable, Codable, Equatable, Sendable {
    case roomOutbox = "room_outbox"
    case fanoutDelivery = "fanout_delivery"
    case contentReview = "content_review"
    case mediaScan = "media_scan"
    case mediaPurge = "media_purge"
    case readReceiptPreferencePropagation = "read_receipt_preference_propagation"
    case userProjection = "user_projection"
}

/// A bounded, reviewable statement of why an operator has cleared a paused
/// row. Free-form incident text belongs in the external incident system, not
/// in an operational API or the authoritative chat database.
public enum V2DurableWorkReplayReason: String, CaseIterable, Codable, Equatable, Sendable {
    case dependencyRecovered = "dependency_recovered"
    case dataRepaired = "data_repaired"
    case falsePositive = "false_positive"
}

public struct V2DurableWorkReplayTarget: Equatable, Sendable {
    public let kind: V2DurableWorkReplayTargetKind
    public let sourceEventID: EventID
    public let targetUserID: UserID?
    public let projectionKind: String?

    public init(
        kind: V2DurableWorkReplayTargetKind,
        sourceEventID: EventID,
        targetUserID: UserID? = nil,
        projectionKind: String? = nil
    ) throws {
        switch kind {
        case .roomOutbox, .contentReview, .mediaScan, .mediaPurge:
            guard targetUserID == nil, projectionKind == nil else {
                throw V2DurableWorkReplayValidationError.invalidTargetShape
            }
        case .readReceiptPreferencePropagation, .userProjection:
            guard targetUserID != nil, projectionKind == nil else {
                throw V2DurableWorkReplayValidationError.invalidTargetShape
            }
        case .fanoutDelivery:
            guard targetUserID != nil,
                  let projectionKind,
                  !projectionKind.isEmpty,
                  projectionKind.utf8.count <= 64
            else { throw V2DurableWorkReplayValidationError.invalidTargetShape }
        }
        self.kind = kind
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
    }
}

public struct V2DurableWorkReplayCommand: Equatable, Sendable {
    public let operationID: UUID
    public let target: V2DurableWorkReplayTarget
    public let reason: V2DurableWorkReplayReason

    public init(operationID: UUID, target: V2DurableWorkReplayTarget, reason: V2DurableWorkReplayReason) {
        self.operationID = operationID
        self.target = target
        self.reason = reason
    }
}

public enum V2DurableWorkReplayOutcome: String, Codable, Equatable, Sendable {
    /// A paused row was returned to `pending` and its retry budget reset.
    case requeued
    /// The target was not paused. This is durable audit evidence, not an error:
    /// it makes retries and concurrent incident responders deterministic.
    case notPaused = "not_paused"
}

public struct V2DurableWorkReplayResult: Equatable, Sendable {
    public let operationID: UUID
    public let outcome: V2DurableWorkReplayOutcome
    public let wasIdempotent: Bool

    public init(operationID: UUID, outcome: V2DurableWorkReplayOutcome, wasIdempotent: Bool) {
        self.operationID = operationID
        self.outcome = outcome
        self.wasIdempotent = wasIdempotent
    }
}

public enum V2DurableWorkReplayValidationError: Error, Equatable, Sendable {
    case invalidTargetShape
}

public enum V2DurableWorkReplayStoreError: Error, Equatable, Sendable {
    case idempotencyConflict
    case corruptPersistenceState
}

/// Implementations atomically record the operator action and perform the
/// replay. The audit record is therefore never evidence of a replay that did
/// not commit, and a retry of the same operation has a stable result.
public protocol V2DurableWorkReplayStore: Sendable {
    func replay(
        _ command: V2DurableWorkReplayCommand,
        operatorPrincipal: String,
        now: Date
    ) async throws -> V2DurableWorkReplayResult
}

public struct V2DurableWorkOperatorReplayService: Sendable {
    private let store: any V2DurableWorkReplayStore
    private let operatorPrincipal: String
    private let now: @Sendable () -> Date

    public init(
        store: any V2DurableWorkReplayStore,
        operatorPrincipal: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal))
        self.store = store
        self.operatorPrincipal = operatorPrincipal
        self.now = now
    }

    public func replay(_ command: V2DurableWorkReplayCommand) async throws -> V2DurableWorkReplayResult {
        try await store.replay(command, operatorPrincipal: operatorPrincipal, now: now())
    }

    public static func isValidPrincipal(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
            ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) ||
            $0 == "-" || $0 == "_" || $0 == "." || $0 == ":"
        }
    }
}
