import Foundation
import IMV2Core

/// Frozen at the send action. Editing a composer never mutates this snapshot.
public struct V2SendIntent: Equatable, Sendable {
    public enum Stage: String, Sendable { case preparing, handedOff, cancelled }
    public let id: UUID
    public let roomID: RoomID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    public let attachmentJobIDs: [UUID]
    public let stage: Stage

    public init(id: UUID, roomID: RoomID, clientMessageID: ClientMessageID, text: String, mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil, attachmentJobIDs: [UUID], stage: Stage = .preparing) throws {
        guard !text.isEmpty || !attachmentJobIDs.isEmpty,
              attachmentJobIDs.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(attachmentJobIDs).count == attachmentJobIDs.count,
              mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count else { throw V2ClientCommandError.invalidText }
        try V2RichMessageContent.validate(text: text, entities: entities)
        self.id = id; self.roomID = roomID; self.clientMessageID = clientMessageID
        self.text = text; self.mentions = mentions; self.entities = entities
        self.replyTo = replyTo; self.attachmentJobIDs = attachmentJobIDs; self.stage = stage
    }
}

public enum V2ResourceJournalError: Error, Equatable, Sendable {
    case conflict, invalidRecord, dependencyNotReady, bindingExpired, alreadyHandedOff
}

public struct V2SubmittedSendIntent: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case pending, confirmingOutcome, closed, rejected }
    public let id: UUID
    public let text: String
    public let status: Status
}
