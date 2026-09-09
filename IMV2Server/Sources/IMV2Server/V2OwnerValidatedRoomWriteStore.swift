import Foundation
import IMV2Core

/// The route belongs to this exact immutable command, even when several
/// logical shards share a physical transaction.
public struct V2OwnerValidatedRoomWriteRequest: Sendable {
    public let request: V2RoomWriteRequest
    public let ownerRoute: V2RoomShardRoute

    public init(request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute) {
        self.request = request
        self.ownerRoute = ownerRoute
    }
}

/// Production routing requires these methods. There is deliberately no
/// default implementation that can silently discard the selected epoch.
public protocol V2OwnerValidatedRoomWriteStore: V2AtomicRoomWriteBatchStore {
    func acceptOwnerValidated(
        request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute
    ) async throws -> V2SendMessageOutcome

    func acceptAtomicallyOwnerValidated(
        requests: [V2OwnerValidatedRoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome]
}
