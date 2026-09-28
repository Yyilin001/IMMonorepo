import Foundation
import IMV2Core

/// Fixed owner placement is supplied only by the authenticated control owner.
public struct V2ProvenDirectBootstrap: Codable, Equatable, Sendable {
    public let command: V2DirectRoomOperationCommand
    public let roomID: RoomID
    public let roomShardID: String
    public init(command: V2DirectRoomOperationCommand, roomID: RoomID, roomShardID: String) {
        self.command = command; self.roomID = roomID; self.roomShardID = roomShardID
    }
}
public struct V2ProvenDirectRecovery: Codable, Equatable, Sendable {
    public let request: V2DirectRoomOperationRecoveryRequest
    public let roomID: RoomID
    public let roomShardID: String
    public init(request: V2DirectRoomOperationRecoveryRequest, roomID: RoomID, roomShardID: String) {
        self.request = request; self.roomID = roomID; self.roomShardID = roomShardID
    }
}
