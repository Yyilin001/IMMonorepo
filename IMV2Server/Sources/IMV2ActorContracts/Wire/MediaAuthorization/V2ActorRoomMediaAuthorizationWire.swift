import Foundation
import IMV2Core

/// Room-only visibility input. Device/account authority is checked by media
/// control at issuance and exchange; it is never asserted by the caller here.
public struct V2ActorMessageMediaVisibilityWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let mediaID: MediaID
    public let actorUserID: UserID

    public init(roomID: RoomID, messageID: MessageID, mediaID: MediaID,
                actorUserID: UserID) {
        self.roomID = roomID; self.messageID = messageID
        self.mediaID = mediaID; self.actorUserID = actorUserID
    }
}

public enum V2RoomMediaAuthorizationQuery: Codable, Equatable, Sendable {
    case messageVisibility(V2ActorMessageMediaVisibilityWire)

    public var roomID: RoomID {
        switch self { case .messageVisibility(let value): value.roomID }
    }
    public var actorUserID: UserID {
        switch self { case .messageVisibility(let value): value.actorUserID }
    }
    public var retryPolicy: V2RoomReplayPolicy { .readOnly }
}

/// The versioned room fact used to compare issue/redeem authorization reads.
public struct V2ActorMessageMediaVisibilitySnapshotWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let mediaID: MediaID
    public let membershipRevision: UInt64
    public let contentRevision: UInt64
    public let mediaUpdatedAt: Date
    public let uploadSessionID: UUID

    public init(roomID: RoomID, messageID: MessageID, mediaID: MediaID,
                membershipRevision: UInt64, contentRevision: UInt64,
                mediaUpdatedAt: Date, uploadSessionID: UUID) {
        self.roomID = roomID; self.messageID = messageID; self.mediaID = mediaID
        self.membershipRevision = membershipRevision
        self.contentRevision = contentRevision
        self.mediaUpdatedAt = mediaUpdatedAt
        self.uploadSessionID = uploadSessionID
    }
}

public enum V2RoomMediaAuthorizationResult: Codable, Equatable, Sendable {
    case visible(V2ActorMessageMediaVisibilitySnapshotWire)
    case notVisible
}
