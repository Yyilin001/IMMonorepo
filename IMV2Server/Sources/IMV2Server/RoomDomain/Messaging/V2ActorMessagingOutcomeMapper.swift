import IMV2ActorContracts
import IMV2Core

public extension V2ActorSendMessageResultWire {
    init(_ value: V2SendMessageOutcome) {
        switch value {
        case .accepted(let message): self = .accepted(.init(message))
        case .idempotent(let receipt): self = .idempotent(.init(receipt))
        case .idempotencyConflict: self = .idempotencyConflict
        case .rateLimited(let delay): self = .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): self = .unavailable(.init(reason))
        case .denied(let denied): self = .denied(.init(denied))
        }
    }

    func toDomain() throws -> V2SendMessageOutcome {
        switch self {
        case .accepted(let message): return .accepted(try message.toDomain())
        case .idempotent(let receipt): return .idempotent(try receipt.toDomain())
        case .idempotencyConflict: return .idempotencyConflict
        case .rateLimited(let delay):
            try V2ActorMessagingMapping.validateRetryDelay(delay)
            return .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): return .unavailable(reason.toDomain())
        case .denied(let denied): return .denied(try denied.toDomain())
        }
    }
}

public extension V2ActorMessageEditResultWire {
    init(_ value: V2MessageEditOutcome) {
        switch value {
        case .edited(let edit): self = .edited(.init(edit))
        case .idempotent(let edit): self = .idempotent(.init(edit))
        case .idempotencyConflict: self = .idempotencyConflict
        case .revisionConflict(let current): self = .revisionConflict(current: current)
        case .alreadyWithdrawn: self = .alreadyWithdrawn
        case .rateLimited(let delay): self = .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): self = .unavailable(.init(reason))
        }
    }

    func toDomain() throws -> V2MessageEditOutcome {
        switch self {
        case .edited(let edit): return .edited(try edit.toDomain())
        case .idempotent(let edit): return .idempotent(try edit.toDomain())
        case .idempotencyConflict: return .idempotencyConflict
        case .revisionConflict(let current):
            try V2ActorMessagingMapping.validateRevision(current)
            return .revisionConflict(current: current)
        case .alreadyWithdrawn: return .alreadyWithdrawn
        case .rateLimited(let delay):
            try V2ActorMessagingMapping.validateRetryDelay(delay)
            return .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): return .unavailable(reason.toDomain())
        }
    }
}

public extension V2ActorMessageWithdrawalResultWire {
    init(_ value: V2MessageWithdrawalOutcome) {
        switch value {
        case .withdrawn(let withdrawal): self = .withdrawn(.init(withdrawal))
        case .idempotent(let withdrawal): self = .idempotent(.init(withdrawal))
        case .idempotencyConflict: self = .idempotencyConflict
        case .revisionConflict(let current): self = .revisionConflict(current: current)
        case .alreadyWithdrawn: self = .alreadyWithdrawn
        case .rateLimited(let delay): self = .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): self = .unavailable(.init(reason))
        }
    }

    func toDomain() throws -> V2MessageWithdrawalOutcome {
        switch self {
        case .withdrawn(let withdrawal): return .withdrawn(try withdrawal.toDomain())
        case .idempotent(let withdrawal): return .idempotent(try withdrawal.toDomain())
        case .idempotencyConflict: return .idempotencyConflict
        case .revisionConflict(let current):
            try V2ActorMessagingMapping.validateRevision(current)
            return .revisionConflict(current: current)
        case .alreadyWithdrawn: return .alreadyWithdrawn
        case .rateLimited(let delay):
            try V2ActorMessagingMapping.validateRetryDelay(delay)
            return .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): return .unavailable(reason.toDomain())
        }
    }
}

public extension V2ActorMessageReactionResultWire {
    init(_ value: V2MessageReactionOutcome) {
        switch value {
        case .changed(let change): self = .changed(.init(change))
        case .idempotent(let change): self = .idempotent(.init(change))
        case .idempotencyConflict: self = .idempotencyConflict
        case .alreadyInDesiredState: self = .alreadyInDesiredState
        case .rateLimited(let delay): self = .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): self = .unavailable(.init(reason))
        }
    }

    func toDomain() throws -> V2MessageReactionOutcome {
        switch self {
        case .changed(let change): return .changed(try change.toDomain())
        case .idempotent(let change): return .idempotent(try change.toDomain())
        case .idempotencyConflict: return .idempotencyConflict
        case .alreadyInDesiredState: return .alreadyInDesiredState
        case .rateLimited(let delay):
            try V2ActorMessagingMapping.validateRetryDelay(delay)
            return .rateLimited(retryAfterSeconds: delay)
        case .unavailable(let reason): return .unavailable(reason.toDomain())
        }
    }
}

private enum V2ActorMessagingMapping {
    static func validateRetryDelay(_ value: Int) throws {
        guard value >= 0 else { throw V2ActorMessagingMappingError.invalidRetryDelay }
    }
    static func validateRevision(_ value: UInt64) throws {
        guard value > 0, value <= UInt64(Int64.max) else {
            throw V2ActorMessagingMappingError.invalidSequence
        }
    }
}
