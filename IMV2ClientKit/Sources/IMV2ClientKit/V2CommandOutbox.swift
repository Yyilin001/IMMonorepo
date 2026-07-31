import Foundation
import IMV2Core

public struct V2PendingMessageCommand: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, accepted, rejected }
    public let roomID: RoomID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let acceptedMessageID: MessageID?
    /// Canonical room position returned by the acceptance transaction.  This
    /// is persisted with the server message ID so an optimistic row can be
    /// reconciled without waiting for a later sync batch.
    public let acceptedRoomSequence: UInt64?
    public let terminalCode: String?

    public init(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil, state: State, attemptCount: Int, nextAttemptAt: Date, acceptedMessageID: MessageID?, acceptedRoomSequence: UInt64?, terminalCode: String?) {
        self.roomID = roomID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.acceptedMessageID = acceptedMessageID
        self.acceptedRoomSequence = acceptedRoomSequence
        self.terminalCode = terminalCode
    }
}

public enum V2ClientCommandError: Error, Equatable, Sendable {
    case invalidText
    case commandConflict
    case commandNotPending
}

/// A device-local outbox survives connection loss and reset snapshots. The
/// immutable client message ID is the server deduplication key for every retry.
public protocol V2LocalCommandStore: Sendable {
    func enqueue(_ command: V2PendingMessageCommand) async throws
    func nextReadyMessage(now: Date) async throws -> V2PendingMessageCommand?
    func markMessageAccepted(clientMessageID: ClientMessageID, messageID: MessageID, roomSequence: UInt64) async throws
    func scheduleMessageRetry(clientMessageID: ClientMessageID, nextAttemptAt: Date) async throws
    func rejectMessage(clientMessageID: ClientMessageID, code: String) async throws
}

public enum V2CommandFlushResult: Equatable, Sendable {
    case idle
    case accepted(ClientMessageID)
    case retryScheduled(ClientMessageID)
    case rejected(ClientMessageID, code: String)
}

/// Narrow lifecycle boundary used by the realtime runtime after an
/// authenticated reconnect. It makes durable command replay injectable in
/// tests without exposing a concrete outbox actor to UI code.
public protocol V2ClientCommandFlushing: Sendable {
    func flushOnce() async throws -> V2CommandFlushResult
}

/// Serializes local command enqueue/retry. A send is retried only with its
/// original client message ID, including after process restart or sync reset.
public actor V2CommandOutboxEngine {
    private let store: any V2LocalCommandStore
    private let transport: any V2ClientMessageTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalCommandStore, transport: any V2ClientMessageTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
    }

    @discardableResult
    public func enqueueMessage(roomID: RoomID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) async throws -> V2PendingMessageCommand {
        guard !text.isEmpty || !media.isEmpty,
              media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count,
              mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2ClientCommandError.invalidText }
        try V2RichMessageContent.validate(text: text, entities: entities)
        let command = try V2PendingMessageCommand(roomID: roomID, clientMessageID: .init(makeUUID().uuidString), text: text, media: media, mentions: mentions, entities: entities, replyTo: replyTo, state: .pending, attemptCount: 0, nextAttemptAt: now(), acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(command)
        return command
    }

    public func flushOnce() async throws -> V2CommandFlushResult {
        guard let command = try await store.nextReadyMessage(now: now()) else { return .idle }
        do {
            let accepted = try await transport.sendMessage(roomID: command.roomID, clientMessageID: command.clientMessageID, text: command.text, media: command.media, mentions: command.mentions, entities: command.entities, replyTo: command.replyTo)
            try Task.checkCancellation()
            try await store.markMessageAccepted(clientMessageID: command.clientMessageID, messageID: accepted.messageID, roomSequence: accepted.roomSequence)
            return .accepted(command.clientMessageID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            switch error {
            case .server(let code, let retryable, let retryAfter, _):
                // A rate-limit response is a conclusive rejection of this
                // particular send attempt. Although the server permits a
                // later request, silently replaying chat content after the
                // cooldown would surprise the sender. Keep the draft in the
                // UI and require an explicit subsequent send instead.
                if code == "RATE_LIMITED" {
                    try await store.rejectMessage(clientMessageID: command.clientMessageID, code: code)
                    return .rejected(command.clientMessageID, code: code)
                }
                if retryable {
                    try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: now().addingTimeInterval(TimeInterval(max(retryAfter, 1))))
                    return .retryScheduled(command.clientMessageID)
                }
                try await store.rejectMessage(clientMessageID: command.clientMessageID, code: code)
                return .rejected(command.clientMessageID, code: code)
            default:
                try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: now().addingTimeInterval(retryDelay))
                return .retryScheduled(command.clientMessageID)
            }
        } catch {
            try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: now().addingTimeInterval(retryDelay))
            return .retryScheduled(command.clientMessageID)
        }
    }
}

extension V2CommandOutboxEngine: V2ClientCommandFlushing {}
