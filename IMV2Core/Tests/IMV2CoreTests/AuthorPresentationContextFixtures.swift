import Foundation
import IMV2Core

// Single-room construction shorthand for existing fixtures. The current wire
// always carries complete keys and has no legacy room/user-ID decoder.
extension V2AuthorPresentationInterests {
    init(streamID: UUID, viewID: UUID, roomID: RoomID, sequence: UInt64, userIDs: [UserID]) throws {
        try self.init(streamID: streamID, viewID: viewID, sequence: sequence,
            keys: userIDs.map { .init(userID: $0, context: .room(roomID)) })
    }
    var userIDs: [UserID] { keys.map(\.userID) }
}
extension V2AuthorPresentationReceipt {
    init(streamID: UUID, viewID: UUID, roomID: RoomID, sequence: UInt64, userIDs: [UserID], minimumRemainingMilliseconds: Int64) throws {
        try self.init(streamID: streamID, viewID: viewID, sequence: sequence,
            keys: userIDs.map { .init(userID: $0, context: .room(roomID)) }, minimumRemainingMilliseconds: minimumRemainingMilliseconds)
    }
    var userIDs: [UserID] { keys.map(\.userID) }
}
extension V2AuthorPresentationDelta {
    init(streamID: UUID, viewID: UUID, sequence: UInt64, actorUserID: UserID, deviceID: DeviceID,
         roomID: RoomID, serverViewAgeMilliseconds: Int64, batch: V2ProfilePresentationBatchResponse,
         retryAfterMilliseconds: Int64? = nil) throws {
        try self.init(streamID: streamID, viewID: viewID, sequence: sequence, actorUserID: actorUserID,
            deviceID: deviceID, serverViewAgeMilliseconds: serverViewAgeMilliseconds,
            batch: batch, retryAfterMilliseconds: retryAfterMilliseconds)
    }
}
