import Foundation
import IMV2Core

/// A bounded account journal page, independent of current room membership.
/// Cursors are local, ephemeral and tied to the account that produced them.
public struct V2PendingGroupAvatarPage: Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public var id: GroupAvatarOperationID { intent.id }
        public let intent: V2GroupAvatarIntent
        public let createdAt: Date
    }
    public struct Cursor: Equatable, Sendable {
        let actorUserID: UserID
        let createdAt: Double
        let operationID: GroupAvatarOperationID
    }
    public let entries: [Entry]
    public let next: Cursor?
}
