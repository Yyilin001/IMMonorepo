/// A capability's retry semantics, assigned by the implementation, not the caller.
public enum V2RoomReplayPolicy: String, Codable, Sendable {
    case readOnly
    case durableIdempotent
    case noAutomaticRetry
}

/// Finite runtime failures; transport messages never carry arbitrary DB errors.
public enum V2RoomFailureReason: String, Codable, Sendable {
    case staleActivation
    case notReady
    case retired
    case leaseLost
    case unavailable
    case overloaded
    case deadlineExceeded
    case cancelled
    case notFound
    case forbidden
    case invalidRequest
    case unsupportedVersion
    case idempotencyConflict
}

/// Describes what the runtime can prove, rather than what a timeout suggests.
public enum V2RoomCallFailure: Error, Equatable, Codable, Sendable {
    /// Admission never accepted the request.
    case notAccepted(V2RoomFailureReason)
    /// The transaction definitely rolled back and no durable effect remains.
    case rolledBack(V2RoomFailureReason)
    /// A dispatched write may have committed. Keep its stable operation identity.
    case outcomeUnknown
}

public enum V2RoomRetryAction: Equatable, Sendable {
    case returnFailure
    case refreshLocation
    case retryRead
    case retrySameOperation
    case reconcile
}

extension V2RoomCallFailure {
    /// This classifies retries; the caller must additionally enforce its total
    /// monotonic deadline and attempt limit. It never manufactures an operation ID.
    public func retryAction(
        policy: V2RoomReplayPolicy,
        hasStableOperationID: Bool
    ) -> V2RoomRetryAction {
        switch self {
        case .outcomeUnknown:
            switch policy {
            case .readOnly: .retryRead
            case .durableIdempotent:
                hasStableOperationID ? .retrySameOperation : .reconcile
            case .noAutomaticRetry: .reconcile
            }
        case .notAccepted(let reason), .rolledBack(let reason):
            switch reason {
            case .staleActivation, .notReady, .retired, .leaseLost, .unavailable:
                .refreshLocation
            case .overloaded, .deadlineExceeded, .cancelled, .notFound, .forbidden,
                 .invalidRequest, .unsupportedVersion, .idempotencyConflict:
                .returnFailure
            }
        }
    }
}

/// Shared database batchers report a transaction result to every participating
/// room turn. Unknown completion must stop all those turns, not only the caller.
public enum V2RoomTransactionCompletion<Value: Sendable>: Sendable {
    case committed(Value)
    case rolledBack(V2RoomFailureReason)
    case outcomeUnknown
}
