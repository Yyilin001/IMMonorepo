import FluentKit
import Foundation
import IMV2Core
import IMV2ServerContracts

/// The same user-route fence as personal sync. No room mutation or live room
/// subscription is involved in accepting account-level delivery responsibility.
public struct V2RoutedRoomDispatchProjector: V2RoomDispatchProjecting {
    private let routeFence: any V2UserShardRouteFencing & V2UserShardRouteBatchFencing
    private let registry: any V2UserShardStorageResolving

    public init(routeFence: any V2UserShardRouteFencing & V2UserShardRouteBatchFencing, registry: any V2UserShardStorageResolving) {
        self.routeFence = routeFence; self.registry = registry
    }

    public func project(_ lease: V2RoomDispatchLease, to userID: UserID) async throws {
        try await project([lease], to: userID)
    }

    public func project(_ leases: [V2RoomDispatchLease], to userID: UserID) async throws {
        try await routeFence.withCurrentRoute(for: userID) { route, _ in
            let owner = try registry.location(for: route.bucket)
            let target = (owner.database as? V2EventLoopBalancedDatabase)?.usingObservationSource(.userStateProjection) ?? owner.database
            try await PostgresV2UserStateEventProjector(database: target, schema: owner.schema)
                .projectRoomChanges(leases, to: userID)
        }
    }

    public func projectTargets(_ targets: [V2RoomDispatchTarget]) async throws -> Set<UserID> {
        guard targets.count <= 1024 else { throw V2RoomDispatchError.invalidInput }
        guard !targets.isEmpty else { return [] }
        return try await routeFence.withCurrentRoutes(for: targets.map(\.userID)) { routes, _ in
            guard routes.count == targets.count else { throw V2RoomDispatchError.corruptPersistence }
            var groups: [String: [V2RoomDispatchTarget]] = [:]
            for (route, target) in zip(routes, targets) { groups[route.bucket, default: []].append(target) }
            // Separate physical destinations commit independently. Each batch is
            // bounded; a failed destination never acknowledges another's work.
            var accepted = Set<UserID>()
            for (bucket, batch) in groups.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                let owner = try registry.location(for: bucket)
                let database = (owner.database as? V2EventLoopBalancedDatabase)?.usingObservationSource(.userStateProjection) ?? owner.database
                do {
                    try await PostgresV2UserStateEventProjector(database: database, schema: owner.schema).appendRoomChanges(batch)
                    accepted.formUnion(batch.map(\.userID))
                } catch is CancellationError { throw CancellationError() }
                catch { /* Durable source leases retry unaccepted targets. */ }
            }
            return accepted
        }
    }

}

extension PostgresV2UserStateEventProjector {
    /// Receipt, account sequence, wake intent and notification responsibility
    /// commit together. Replaying after source-ACK loss never recreates a sent alert.
    package func projectRoomChange(_ lease: V2RoomDispatchLease, to userID: UserID) async throws -> UInt64 {
        let event = try v2AccountRoomChangeEvent(lease, userID: userID)
        return try await projectResolved(event, notification: lease.messageID == nil ? nil : lease).sequence
    }
}

func v2AccountRoomChangeEvent(_ lease: V2RoomDispatchLease, userID: UserID) throws -> V2UserStateEvent {
    let head = try V2AccountRoomHead(roomID: lease.roomID, roomSequence: lease.roomSequence,
        membershipRevision: lease.membershipRevision)
    // Keep all immutable notification facts in the receipt identity too.
    var object: [String: Any] = [
        "room_id": head.roomID.rawValue, "room_sequence": head.roomSequence,
        "membership_revision": head.membershipRevision
    ]
    if let message = lease.messageID {
        guard let sender = lease.senderID else { throw V2RoomDispatchError.corruptPersistence }
        object["message_id"] = message.uuidString
        object["sender_user_id"] = sender.rawValue
        object["is_mention"] = lease.mentionsEveryone || lease.mentionedUserIDs.contains(userID)
    }
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try V2UserStateEvent(sourceEventID: .init(uuid: lease.eventID), userID: userID,
        kind: .roomHead, payload: payload, createdAt: lease.createdAtTimestamp)
}
