import IMV2ActorContracts

public extension V2ActorForwardFailureWire {
    init?(domainError: any Error) {
        switch domainError {
        case let error as V2ForwardExportError:
            switch error {
            case .ownerChanged, .corruptPersistenceState: return nil
            case .invalidRequest: self = .export(.invalidRequest)
            case .sourceUnavailable: self = .export(.sourceUnavailable)
            case .sourceChanged: self = .export(.sourceChanged)
            case .mediaUnavailable: self = .export(.mediaUnavailable)
            case .idempotencyConflict: self = .export(.idempotencyConflict)
            case .capacityExceeded: self = .export(.capacityExceeded)
            case .payloadCompacted: self = .export(.payloadCompacted)
            }
        case let error as V2ForwardInboxError:
            switch error {
            case .ownerChanged, .corruptPersistenceState: return nil
            case .targetNotFound: self = .inbox(.targetNotFound)
            case .idempotencyConflict: self = .inbox(.idempotencyConflict)
            case .capacityExceeded: self = .inbox(.capacityExceeded)
            }
        default: return nil
        }
    }

    func domainError() -> any Error {
        switch self {
        case .export(let value):
            switch value {
            case .invalidRequest: V2ForwardExportError.invalidRequest
            case .sourceUnavailable: V2ForwardExportError.sourceUnavailable
            case .sourceChanged: V2ForwardExportError.sourceChanged
            case .mediaUnavailable: V2ForwardExportError.mediaUnavailable
            case .idempotencyConflict: V2ForwardExportError.idempotencyConflict
            case .capacityExceeded: V2ForwardExportError.capacityExceeded
            case .payloadCompacted: V2ForwardExportError.payloadCompacted
            }
        case .inbox(let value):
            switch value {
            case .targetNotFound: V2ForwardInboxError.targetNotFound
            case .idempotencyConflict: V2ForwardInboxError.idempotencyConflict
            case .capacityExceeded: V2ForwardInboxError.capacityExceeded
            }
        }
    }
}
