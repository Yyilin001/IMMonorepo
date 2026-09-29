import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2Core

extension V2ActorInvitationErrorWire {
    public init(domain: V2GroupInvitationServiceError) {
        switch domain {
        case .invalidConfiguration: self = .invalidConfiguration
        case .invalidRequest: self = .invalidRequest
        case .roomNotFound: self = .roomNotFound
        case .inviteNotFound: self = .inviteNotFound
        case .requestNotFound: self = .requestNotFound
        case .permissionDenied: self = .permissionDenied
        case .rateLimited: self = .rateLimited
        case .conflict: self = .conflict
        case .creationExpired: self = .creationExpired
        case .ownerChanged: self = .ownerChanged
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }
    public func toServiceError() throws -> V2GroupInvitationServiceError {
        switch self {
        case .invalidConfiguration: .invalidConfiguration
        case .invalidRequest: .invalidRequest
        case .roomNotFound: .roomNotFound
        case .inviteNotFound: .inviteNotFound
        case .requestNotFound: .requestNotFound
        case .permissionDenied: .permissionDenied
        case .rateLimited: .rateLimited
        case .conflict: .conflict
        case .creationExpired: .creationExpired
        case .ownerChanged: .ownerChanged
        case .corruptPersistenceState: .corruptPersistenceState
        default: throw V2GroupInvitationServiceError.invalidRequest
        }
    }
    public init(directoryError: V2GroupInviteDirectoryError) {
        switch directoryError {
        case .invalidRequest: self = .invalidRequest
        case .conflict: self = .directoryConflict
        case .ownerResultMismatch: self = .ownerResultMismatch
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }
    public func toDirectoryError() throws -> V2GroupInviteDirectoryError {
        switch self {
        case .invalidRequest: .invalidRequest
        case .directoryConflict: .conflict
        case .ownerResultMismatch: .ownerResultMismatch
        case .corruptPersistenceState: .corruptPersistenceState
        default: throw V2GroupInvitationServiceError.invalidRequest
        }
    }
    public init(validationError: V2GroupInvitationValidationError) {
        switch validationError {
        case .invalidSecret: self = .invalidSecret
        case .invalidLink: self = .invalidLink
        case .invalidPreview: self = .invalidPreview
        case .invalidRequest: self = .invalidGroupJoinRequest
        }
    }
    public func toValidationError() throws -> V2GroupInvitationValidationError {
        switch self {
        case .invalidSecret: .invalidSecret
        case .invalidLink: .invalidLink
        case .invalidPreview: .invalidPreview
        case .invalidGroupJoinRequest: .invalidRequest
        default: throw V2GroupInvitationServiceError.invalidRequest
        }
    }
}
