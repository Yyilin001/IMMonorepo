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
