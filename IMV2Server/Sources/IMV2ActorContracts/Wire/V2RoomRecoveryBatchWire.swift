import IMV2Core

/// A trusted Gateway forwards each real viewer, never a fabricated batch user.
public struct V2RoomRecoveryBatchWireItem: Codable, Equatable, Sendable {
    public let token: V2RoomActivationToken
    public let query: V2ActorRoomRecoveryItemQuery
    public init(token: V2RoomActivationToken, query: V2ActorRoomRecoveryItemQuery) {
        self.token = token; self.query = query
    }
}

public struct V2RoomRecoveryBatchWireOutcome: Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case result(V2RoomResponse)
        case failure(V2RoomCallFailure)
    }
    public let token: V2RoomActivationToken
    public let query: V2ActorRoomRecoveryItemQuery
    public let outcome: Outcome
    public init(token: V2RoomActivationToken, query: V2ActorRoomRecoveryItemQuery, outcome: Outcome) {
        self.token = token; self.query = query; self.outcome = outcome
    }
}
