import IMV2ActorContracts
import IMV2Core

extension V2ActorRoomCreationErrorWire {
    public init(domain: V2DirectMessagingValidationError) {
        switch domain { case .selfTargetingNotAllowed: self = .selfTargetingNotAllowed }
    }
    public init(domain: V2GroupMessagingValidationError) {
        switch domain {
        case .invalidTitle: self = .invalidTitle
        case .invalidInitialMembers: self = .invalidInitialMembers
        case .invalidMemberCount: self = .invalidMemberCount
        }
    }

    public init(domain: V2GroupRoomCreationIntentStoreError) {
        switch domain {
        case .invalidIntent: self = .invalidIntent
        case .routeConflict: self = .routeConflict
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }
    public init(domain: V2GroupMessagingPolicyError) {
        switch domain {
        case .invalidRoomShard: self = .invalidRoomShard
        case .invalidInitialMembership: self = .invalidInitialMembership
        }
    }
    public func toGroupMessagingValidationError() throws -> V2GroupMessagingValidationError {
        switch self {
        case .invalidTitle: .invalidTitle
        case .invalidInitialMembers: .invalidInitialMembers
        case .invalidMemberCount: .invalidMemberCount
        default: throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
    }

    public func toCreationIntentError() throws -> V2GroupRoomCreationIntentStoreError {
        switch self {
        case .invalidIntent: .invalidIntent
        case .routeConflict: .routeConflict
        case .corruptPersistenceState: .corruptPersistenceState
        default: throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
    }
}

extension V2ActorRoomCreationErrorWire {
    public func toDirectMessagingValidationError() throws -> V2DirectMessagingValidationError {
        guard self == .selfTargetingNotAllowed else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        return .selfTargetingNotAllowed
    }
    public func toGroupMessagingPolicyError() throws -> V2GroupMessagingPolicyError {
        switch self {
        case .invalidRoomShard: .invalidRoomShard
        case .invalidInitialMembership: .invalidInitialMembership
        default: throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
    }
}
