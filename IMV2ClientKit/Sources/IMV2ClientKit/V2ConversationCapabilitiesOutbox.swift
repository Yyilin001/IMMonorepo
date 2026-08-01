import Foundation
import IMV2Core

/// Durable, user-scoped commands for conversation presentation state and
/// message favourites. They deliberately share neither message delivery nor
/// room-event ordering: both are private user projections and therefore only
/// become visible once the normal user sync stream applies their projection.
public struct V2PendingConversationStateCommand: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let command: V2ConversationStateCommand
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let terminalCode: String?
}

public struct V2PendingMessageFavoriteCommand: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let command: V2MessageFavoriteCommand
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let terminalCode: String?
}

public protocol V2LocalConversationCapabilitiesStore: Sendable {
    func enqueueOrReuseConversationState(_ command: V2PendingConversationStateCommand) async throws -> V2PendingConversationStateCommand
    func nextReadyConversationState(now: Date) async throws -> V2PendingConversationStateCommand?
    func markConversationStateAcknowledged(operationID: ConversationPreferenceOperationID) async throws
    func scheduleConversationStateRetry(operationID: ConversationPreferenceOperationID, nextAttemptAt: Date) async throws
    func rejectConversationState(operationID: ConversationPreferenceOperationID, code: String) async throws
    func enqueueOrReuseMessageFavorite(_ command: V2PendingMessageFavoriteCommand) async throws -> V2PendingMessageFavoriteCommand
    func nextReadyMessageFavorite(now: Date) async throws -> V2PendingMessageFavoriteCommand?
    func markMessageFavoriteAcknowledged(operationID: MessageFavoriteOperationID) async throws
    func scheduleMessageFavoriteRetry(operationID: MessageFavoriteOperationID, nextAttemptAt: Date) async throws
    func rejectMessageFavorite(operationID: MessageFavoriteOperationID, code: String) async throws
}

public enum V2ConversationCapabilitiesFlushResult: Equatable, Sendable {
    case idle
    case conversationStateAcknowledged(ConversationPreferenceOperationID)
    case messageFavoriteAcknowledged(MessageFavoriteOperationID)
    case conversationStateRetryScheduled(ConversationPreferenceOperationID)
    case messageFavoriteRetryScheduled(MessageFavoriteOperationID)
    case conversationStateRejected(ConversationPreferenceOperationID, code: String)
    case messageFavoriteRejected(MessageFavoriteOperationID, code: String)
}

/// Sends at most one durable personal-capability command per scheduler quantum.
/// State commands are checked first so archiving/muting cannot sit behind a
/// large favourite batch; the common runtime scheduler supplies cross-feature
/// fairness.
public actor V2ConversationCapabilitiesOutboxEngine {
    private let store: any V2LocalConversationCapabilitiesStore
    private let transport: any V2ClientConversationCapabilitiesTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalConversationCapabilitiesStore, transport: any V2ClientConversationCapabilitiesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    public func enqueueConversationState(roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?) async throws -> V2PendingConversationStateCommand {
        let command = try V2ConversationStateCommand(operationID: .init(makeUUID().uuidString), roomID: roomID, isPinned: isPinned, isArchived: isArchived, muteUntil: muteUntil)
        return try await store.enqueueOrReuseConversationState(.init(command: command, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil))
    }

    public func enqueueMessageFavorite(roomID: RoomID, messageID: MessageID, isFavorited: Bool) async throws -> V2PendingMessageFavoriteCommand {
        let command = try V2MessageFavoriteCommand(operationID: .init(makeUUID().uuidString), roomID: roomID, messageID: messageID, isFavorited: isFavorited)
        return try await store.enqueueOrReuseMessageFavorite(.init(command: command, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil))
    }

    public func flushOnce() async throws -> V2ConversationCapabilitiesFlushResult {
        let clock = now()
        if let pending = try await store.nextReadyConversationState(now: clock) {
            return try await flush(pending)
        }
        if let pending = try await store.nextReadyMessageFavorite(now: clock) {
            return try await flush(pending)
        }
        return .idle
    }

    private func flush(_ pending: V2PendingConversationStateCommand) async throws -> V2ConversationCapabilitiesFlushResult {
        do {
            let result = try await transport.setConversationState(command: pending.command)
            try Task.checkCancellation()
            guard result.roomID == pending.command.roomID, result.isPinned == pending.command.isPinned, result.isArchived == pending.command.isArchived, result.muteUntil == pending.command.muteUntil else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markConversationStateAcknowledged(operationID: pending.command.operationID)
            return .conversationStateAcknowledged(pending.command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let code = nonRetryableCode(error) {
                try await store.rejectConversationState(operationID: pending.command.operationID, code: code)
                return .conversationStateRejected(pending.command.operationID, code: code)
            }
            try await store.scheduleConversationStateRetry(operationID: pending.command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay(for: error)))
            return .conversationStateRetryScheduled(pending.command.operationID)
        }
    }

    private func flush(_ pending: V2PendingMessageFavoriteCommand) async throws -> V2ConversationCapabilitiesFlushResult {
        do {
            let result = try await transport.setMessageFavorite(command: pending.command)
            try Task.checkCancellation()
            guard result.roomID == pending.command.roomID, result.messageID == pending.command.messageID, result.isFavorited == pending.command.isFavorited else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageFavoriteAcknowledged(operationID: pending.command.operationID)
            return .messageFavoriteAcknowledged(pending.command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let code = nonRetryableCode(error) {
                try await store.rejectMessageFavorite(operationID: pending.command.operationID, code: code)
                return .messageFavoriteRejected(pending.command.operationID, code: code)
            }
            try await store.scheduleMessageFavoriteRetry(operationID: pending.command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay(for: error)))
            return .messageFavoriteRetryScheduled(pending.command.operationID)
        }
    }

    private func nonRetryableCode(_ error: Error) -> String? {
        guard case let V2RealtimeTransportError.server(code, retryable, _, _) = error, !retryable else { return nil }
        return code
    }

    private func retryDelay(for error: Error) -> TimeInterval {
        if case let V2RealtimeTransportError.server(_, _, retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }
        return retryDelay
    }
}
