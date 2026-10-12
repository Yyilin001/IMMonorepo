import IMV2Core

public enum V2RoomActorStateError: Error, Equatable, Sendable {
    case roomNotFound
    case ownerChanged
    case activationChanged
    case epochExhausted
    /// Persistence outcome could not be confirmed.
    case outcomeUnknown
}

/// 数据所有者查询封装在运行时内部；调用方只提供 RoomID。
public protocol V2RoomDataOwnerResolving: Sendable {
    func owner(for roomID: RoomID) async throws -> V2RoomDataOwner
}

public enum V2RoomActivationPhase: String, Codable, Sendable {
    case acquiring
    case restoring
    case ready
    case draining
    case uncertain
    case stopped
}
