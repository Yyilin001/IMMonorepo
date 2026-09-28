import Foundation
import IMV2ActorContracts
import IMV2Core

/// 在调用带前置条件的领域构造器前执行结构检查。
public enum V2ActorMessagingMappingError: Error, Equatable, Sendable {
    case invalidSequence
    case invalidMembershipRevision
    case invalidMediaPresentationIdentity
    case invalidDate
    case noncanonicalReaction
    case invalidRetryDelay
}

private func checkSequence(_ value: UInt64) throws {
    guard value > 0, value <= UInt64(Int64.max) else { throw V2ActorMessagingMappingError.invalidSequence }
}

private func checkDate(_ value: Date) throws {
    guard value.timeIntervalSince1970.isFinite else { throw V2ActorMessagingMappingError.invalidDate }
}

private func checkRevision(_ value: UInt64?) throws {
    guard value.map({ $0 <= UInt64(Int64.max) }) ?? true else {
        throw V2ActorMessagingMappingError.invalidMembershipRevision
    }
}

private func checkPresentations(_ media: [V2MediaReference], _ presentations: [V2MediaPresentation]) throws {
    guard media.map(\.mediaID) == presentations.map(\.mediaID) else {
        throw V2ActorMessagingMappingError.invalidMediaPresentationIdentity
    }
    for presentation in presentations {
        _ = try V2MediaPresentation(mediaID: presentation.mediaID, kind: presentation.kind,
                                    contentType: presentation.contentType, byteCount: presentation.byteCount)
    }
}

private func checkReaction(_ value: String) throws {
    guard value.utf8.elementsEqual(value.precomposedStringWithCanonicalMapping.utf8),
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.utf8.count <= V2MessageReactionLimits.maximumReactionBytes,
          value.unicodeScalars.allSatisfy({
              !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0)
          })
    else { throw V2ActorMessagingMappingError.noncanonicalReaction }
}

public extension V2ActorMentionTargetWire {
    init(_ value: V2MentionTarget) {
        switch value {
        case .user(let id): self = .user(id)
        case .everyone: self = .everyone
        }
    }

    func toDomain() -> V2MentionTarget {
        switch self {
        case .user(let id): .user(id)
        case .everyone: .everyone
        }
    }
}

public extension V2ActorSendMessageWire {
    init(_ value: V2AuthenticatedSendMessage) {
        self.init(roomID: value.roomID, actorUserID: value.actorUserID,
                  clientMessageID: value.clientMessageID, text: value.text, media: value.media,
                  mentions: value.mentions.map(V2ActorMentionTargetWire.init),
                  entities: value.entities, replyTo: value.replyTo)
    }

    /// 本地执行器自行提供文本预算；调用方仍须认证 actorUserID。
    func toAuthenticated(limits: V2MessageCommandLimits) throws -> V2AuthenticatedSendMessage {
        let targets = mentions.map { $0.toDomain() }
        _ = try V2SendMessageCommand(roomID: roomID, senderUserID: actorUserID,
                                     clientMessageID: clientMessageID, text: text, media: media,
                                     mentions: targets, entities: entities, replyTo: replyTo, limits: limits)
        return .init(roomID: roomID, actorUserID: actorUserID, clientMessageID: clientMessageID,
                     text: text, media: media, mentions: targets, entities: entities, replyTo: replyTo)
    }
}







public extension V2ActorAcceptedMessageWire {
    init(_ value: V2AcceptedMessage) {
        self.init(messageID: value.messageID, roomID: value.roomID, roomSequence: value.roomSequence,
                  timelineSequence: value.timelineSequence, senderUserID: value.senderUserID,
                  clientMessageID: value.clientMessageID, text: value.text, media: value.media,
                  mediaPresentations: value.mediaPresentations,
                  mentions: value.mentions.map(V2ActorMentionTargetWire.init), entities: value.entities,
                  replyTo: value.replyTo, groupCapacityClass: value.groupCapacityClass,
                  sourceEventID: value.sourceEventID,
                  acceptedMembershipRevision: value.acceptedMembershipRevision,
                  directRecipientUserID: value.directRecipientUserID,
                  projectionCreatedAtUnixMilliseconds: value.projectionCreatedAtUnixMilliseconds,
                  createdAt: value.createdAt)
    }

    func toDomain() throws -> V2AcceptedMessage {
        try checkSequence(roomSequence)
        try checkSequence(timelineSequence)
        try checkRevision(acceptedMembershipRevision)
        try checkDate(createdAt)
        try checkPresentations(media, mediaPresentations)
        try V2RichMessageContent.validate(text: text, entities: entities)
        return .init(messageID: messageID, roomID: roomID, roomSequence: roomSequence,
                     timelineSequence: timelineSequence, senderUserID: senderUserID,
                     clientMessageID: clientMessageID, text: text, media: media,
                     mediaPresentations: mediaPresentations, mentions: mentions.map { $0.toDomain() },
                     entities: entities, replyTo: replyTo, groupCapacityClass: groupCapacityClass,
                     sourceEventID: sourceEventID,
                     acceptedMembershipRevision: acceptedMembershipRevision,
                     directRecipientUserID: directRecipientUserID,
                     projectionCreatedAtUnixMilliseconds: projectionCreatedAtUnixMilliseconds,
                     createdAt: createdAt)
    }
}

public extension V2ActorMessageAcceptanceReceiptWire {
    init(_ value: V2MessageAcceptanceReceipt) {
        self.init(messageID: value.messageID, roomID: value.roomID, roomSequence: value.roomSequence,
                  timelineSequence: value.timelineSequence, senderUserID: value.senderUserID,
                  clientMessageID: value.clientMessageID, groupCapacityClass: value.groupCapacityClass,
                  sourceEventID: value.sourceEventID,
                  acceptedMembershipRevision: value.acceptedMembershipRevision,
                  directRecipientUserID: value.directRecipientUserID, createdAt: value.createdAt)
    }

    func toDomain() throws -> V2MessageAcceptanceReceipt {
        try checkSequence(roomSequence)
        try checkSequence(timelineSequence)
        try checkRevision(acceptedMembershipRevision)
        try checkDate(createdAt)
        return .init(messageID: messageID, roomID: roomID, roomSequence: roomSequence,
                     timelineSequence: timelineSequence, senderUserID: senderUserID,
                     clientMessageID: clientMessageID, groupCapacityClass: groupCapacityClass,
                     sourceEventID: sourceEventID,
                     acceptedMembershipRevision: acceptedMembershipRevision,
                     directRecipientUserID: directRecipientUserID, createdAt: createdAt)
    }
}

public extension V2ActorDirectMessageDeniedWire {
    init(_ value: V2DirectMessageDenied) {
        self.init(roomID: value.roomID, sourceEventID: value.sourceEventID,
                  timelineSequence: value.timelineSequence, createdAt: value.createdAt,
                  reason: value.reason == .generic ? .generic : .systemAccountReadOnly)
    }

    func toDomain() throws -> V2DirectMessageDenied {
        try checkSequence(timelineSequence)
        try checkDate(createdAt)
        return .init(roomID: roomID, sourceEventID: sourceEventID,
                     timelineSequence: timelineSequence, createdAt: createdAt,
                     reason: reason == .generic ? .generic : .systemAccountReadOnly)
    }
}

public extension V2ActorMessageEditWire {
    init(_ value: V2MessageEdit) {
        self.init(roomID: value.roomID, messageID: value.messageID, text: value.text,
                  messageRevision: value.messageRevision, roomSequence: value.roomSequence,
                  eventID: value.eventID, createdAt: value.createdAt)
    }

    func toDomain() throws -> V2MessageEdit {
        try checkDate(createdAt)
        return try .init(roomID: roomID, messageID: messageID, text: text,
                         messageRevision: messageRevision, roomSequence: roomSequence,
                         eventID: eventID, createdAt: createdAt)
    }
}

public extension V2ActorMessageWithdrawalWire {
    init(_ value: V2MessageWithdrawal) {
        self.init(roomID: value.roomID, messageID: value.messageID,
                  messageRevision: value.messageRevision, roomSequence: value.roomSequence,
                  eventID: value.eventID, createdAt: value.createdAt)
    }

    func toDomain() throws -> V2MessageWithdrawal {
        try checkDate(createdAt)
        return try .init(roomID: roomID, messageID: messageID,
                         messageRevision: messageRevision, roomSequence: roomSequence,
                         eventID: eventID, createdAt: createdAt)
    }
}

public extension V2ActorMessageReactionChangeWire {
    init(_ value: V2MessageReactionChange) {
        self.init(roomID: value.roomID, messageID: value.messageID,
                  actorUserID: value.actorUserID, reaction: value.reaction, action: value.action,
                  roomSequence: value.roomSequence, eventID: value.eventID, createdAt: value.createdAt)
    }

    func toDomain() throws -> V2MessageReactionChange {
        try checkDate(createdAt)
        try checkReaction(reaction)
        return try .init(roomID: roomID, messageID: messageID, actorUserID: actorUserID,
                         reaction: reaction, action: action, roomSequence: roomSequence,
                         eventID: eventID, createdAt: createdAt)
    }
}
