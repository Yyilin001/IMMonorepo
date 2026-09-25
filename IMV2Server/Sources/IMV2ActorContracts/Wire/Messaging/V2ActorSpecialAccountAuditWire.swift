import Foundation
import IMV2Core

/// 独立的发送后房间审计写入器所用的服务器主体输入。
/// 它不是公开的网关命令；审计时钟由执行器提供。
public struct V2ActorSpecialAccountMessageWire: Codable, Equatable, Sendable {
    public let stableAccountKey: String
    public let servicePrincipal: String
    public let operatorID: String?
    public let operationID: ClientMessageID
    public let requestFingerprint: String
    public let customerUserID: UserID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2ActorMentionTargetWire]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?

    public init(stableAccountKey: String, servicePrincipal: String, operatorID: String?,
                operationID: ClientMessageID, requestFingerprint: String, customerUserID: UserID,
                text: String, media: [V2MediaReference], mentions: [V2ActorMentionTargetWire],
                entities: [V2MessageEntity], replyTo: V2MessageReplyReference?) {
        self.stableAccountKey = stableAccountKey
        self.servicePrincipal = servicePrincipal
        self.operatorID = operatorID
        self.operationID = operationID
        self.requestFingerprint = requestFingerprint
        self.customerUserID = customerUserID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}

public struct V2ActorResolvedSpecialAccountWire: Codable, Equatable, Sendable {
    public let userID: UserID
    public let stableKey: String
    public let kind: V2AccountKind

    public init(userID: UserID, stableKey: String, kind: V2AccountKind) {
        self.userID = userID
        self.stableKey = stableKey
        self.kind = kind
    }
}

/// 审计写入器接收确切的已接受结果；线路上新生成的时间戳不具权威性。
public struct V2ActorSpecialAccountAuditWire: Codable, Equatable, Sendable {
    public let request: V2ActorSpecialAccountMessageWire
    public let account: V2ActorResolvedSpecialAccountWire
    public let roomID: RoomID
    public let outcome: V2ActorSendMessageResultWire

    public init(request: V2ActorSpecialAccountMessageWire,
                account: V2ActorResolvedSpecialAccountWire, roomID: RoomID,
                outcome: V2ActorSendMessageResultWire) {
        self.request = request
        self.account = account
        self.roomID = roomID
        self.outcome = outcome
    }

    public var actorUserID: UserID { account.userID }
    public var operationID: ClientMessageID { request.operationID }
    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}

public enum V2ActorSpecialAccountAuditResultWire: Codable, Equatable, Sendable {
    case recorded
    case failure(V2ActorSpecialAccountFailureWire)
}

public enum V2ActorSpecialAccountFailureWire: String, Codable, Equatable, Sendable {
    case invalidRequest, accountUnavailable, deliveryDenied, idempotencyConflict
    case unavailable, corruptPersistenceState
}
