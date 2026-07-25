import Foundation
import IMV2Core

/// Device-local association between a direct room and the public identity that
/// the signed-in user explicitly resolved before opening it. This is a cache
/// of an authorized lookup, not a contact graph or a sync projection.
public struct V2ClientDirectRoomIdentity: Equatable, Sendable {
    public let roomID: RoomID
    public let publicIdentity: V2PublicIdentity
    public let updatedAt: Date

    public init(roomID: RoomID, publicIdentity: V2PublicIdentity, updatedAt: Date) {
        self.roomID = roomID
        self.publicIdentity = publicIdentity
        self.updatedAt = updatedAt
    }
}
