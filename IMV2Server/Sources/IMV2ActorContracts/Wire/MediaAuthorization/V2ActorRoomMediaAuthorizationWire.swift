import Foundation
import IMV2Core

/// 仅用于房间可见性的输入。媒体控制在签发和交换时检查设备／账户权限；
/// 此处不由调用方声明这项权限。
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

/// 用于比较签发与兑现授权读取结果的版本化房间事实。
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
