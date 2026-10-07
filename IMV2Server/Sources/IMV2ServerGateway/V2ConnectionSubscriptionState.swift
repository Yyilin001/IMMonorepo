import Foundation
import IMV2Core

/// Registry-isolated subscription indexes and mutation fences.
///
/// This value owns local watching relationships, not connection identity,
/// permission proofs, interest acquisition tickets, or asynchronous cleanup.
/// Registry remains its sole mutator and checks the authoritative connection
/// lifecycle plus the captured mutation token after every external await.
struct V2ConnectionSubscriptionState: Sendable {
    var foregroundGroupByConnection: [UUID: RoomID] = [:]
    var foregroundMutationByConnection: [UUID: UInt64] = [:]

    var presenceByConnection: [UUID: (roomID: RoomID, targetUserID: UserID)] = [:]
    var presenceMutationByConnection: [UUID: UInt64] = [:]
    var presenceWatchersByTarget: [UserID: [UUID: V2GatewayByteStream]] = [:]

    var typingRoomByConnection: [UUID: RoomID] = [:]
    var typingMutationByConnection: [UUID: UInt64] = [:]
    var typingWatchersByRoom: [RoomID: [UUID: V2GatewayByteStream]] = [:]

    var mutationCount: Int {
        foregroundMutationByConnection.count + presenceMutationByConnection.count
            + typingMutationByConnection.count
    }

    /// Remove detail identity before asynchronous cleanup. Registry captures
    /// the exact stream from its routing index before any suspension.
    /// Mutation fences survive until the corresponding token is consumed.
    mutating func detachForeground(connectionID: UUID) -> RoomID? {
        foregroundGroupByConnection.removeValue(forKey: connectionID)
    }

    mutating func detachPresence(connectionID: UUID) -> (roomID: RoomID, targetUserID: UserID, stream: V2GatewayByteStream?)? {
        guard let watch = presenceByConnection.removeValue(forKey: connectionID) else { return nil }
        let stream = presenceWatchersByTarget[watch.targetUserID]?.removeValue(forKey: connectionID)
        if presenceWatchersByTarget[watch.targetUserID]?.isEmpty == true {
            presenceWatchersByTarget.removeValue(forKey: watch.targetUserID)
        }
        return (watch.roomID, watch.targetUserID, stream)
    }

    mutating func detachTyping(connectionID: UUID) -> (roomID: RoomID, stream: V2GatewayByteStream?)? {
        guard let room = typingRoomByConnection.removeValue(forKey: connectionID) else { return nil }
        let stream = typingWatchersByRoom[room]?.removeValue(forKey: connectionID)
        if typingWatchersByRoom[room]?.isEmpty == true { typingWatchersByRoom.removeValue(forKey: room) }
        return (room, stream)
    }
}
