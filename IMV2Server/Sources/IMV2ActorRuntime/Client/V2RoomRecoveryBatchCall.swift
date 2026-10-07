import Foundation
import IMV2ActorContracts

/// Local-only absolute budgets. The signed transport encodes only the remaining
/// common budget, after its actual dispatch admission has completed.
public struct V2RoomRecoveryBatchCallItem: Sendable {
    public let token: V2RoomActivationToken
    public let query: V2ActorRoomRecoveryItemQuery
    public let deadline: ContinuousClock.Instant
    public init(token: V2RoomActivationToken, query: V2ActorRoomRecoveryItemQuery,
                deadline: ContinuousClock.Instant) {
        self.token = token; self.query = query; self.deadline = deadline
    }
}

public typealias V2RoomRecoveryBatchCallOutcome = V2RoomRecoveryBatchWireOutcome

/// Includes resolution failures without inventing a physical activation token.
public struct V2RoomRecoveryQueryOutcome: Sendable {
    public let query: V2ActorRoomRecoveryItemQuery
    public let result: Result<V2RoomResponse, V2RoomCallFailure>
    public init(query: V2ActorRoomRecoveryItemQuery, result: Result<V2RoomResponse, V2RoomCallFailure>) {
        self.query = query; self.result = result
    }
}
