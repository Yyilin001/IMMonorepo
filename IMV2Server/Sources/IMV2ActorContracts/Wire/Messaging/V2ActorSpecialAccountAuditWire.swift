import Foundation
import IMV2Core

/// Server-principal input for the separate post-send room audit writer.
/// It is not a public Gateway command; the executor supplies the audit clock.
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

/// Audit writer receives the exact accepted outcome; no fresh timestamp is authoritative on wire.
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

public enum V2ActorSpecialAccountAuditResultWire: String, Codable, Equatable, Sendable {
    case recorded
}
