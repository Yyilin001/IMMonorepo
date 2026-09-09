import Foundation
import IMV2Core

public struct V2PendingMessageReaction: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID; public let operationID: MessageReactionOperationID; public let messageID: MessageID
    public let reaction: String; public let action: V2MessageReactionAction; public let state: State
    public let attemptCount: Int; public let nextAttemptAt: Date; public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
}

public protocol V2LocalMessageReactionStore: Sendable {
    func enqueue(_ command: V2PendingMessageReaction) async throws
    /// Identical pending reaction changes retain their operation ID across
    /// retries and restarts; a different action remains a new intent.
    func enqueueOrReusePendingMessageReaction(_ command: V2PendingMessageReaction) async throws -> V2PendingMessageReaction
    func nextReadyMessageReaction(now: Date) async throws -> V2PendingMessageReaction?
    func markMessageReactionAcknowledged(operationID: MessageReactionOperationID, roomSequence: UInt64) async throws
    func scheduleMessageReactionRetry(operationID: MessageReactionOperationID, nextAttemptAt: Date) async throws
    func rejectMessageReaction(operationID: MessageReactionOperationID, code: String) async throws
}

public enum V2MessageReactionFlushResult: Equatable, Sendable { case idle, acknowledged(MessageReactionOperationID), retryScheduled(MessageReactionOperationID), rejected(MessageReactionOperationID, code: String) }

public actor V2MessageReactionOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2MessageReactionFlushResult>()

    private let store: any V2LocalMessageReactionStore; private let transport: any V2ClientMessageReactionTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    public init(store: any V2LocalMessageReactionStore, transport: any V2ClientMessageReactionTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }
    public func enqueueReaction(roomID: RoomID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2PendingMessageReaction {
        let command = try V2PendingMessageReaction(roomID: roomID, operationID: .init(makeUUID().uuidString), messageID: messageID, reaction: reaction, action: action, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingRoomSequence: nil, terminalCode: nil)
        return try await store.enqueueOrReusePendingMessageReaction(command)
    }
    public func flushOnce() async throws -> V2MessageReactionFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    private func flushNextReadyCommand() async throws -> V2MessageReactionFlushResult {
        guard let command = try await store.nextReadyMessageReaction(now: now()) else { return .idle }
        do {
            let result = try await transport.changeMessageReaction(roomID: command.roomID, operationID: command.operationID, messageID: command.messageID, reaction: command.reaction, action: command.action)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.messageID == command.messageID, result.reaction == command.reaction, result.action == command.action else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageReactionAcknowledged(operationID: command.operationID, roomSequence: result.roomSequence); return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectMessageReaction(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code) }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleMessageReactionRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(command.operationID)
        } catch { try await store.scheduleMessageReactionRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID) }
    }
}

extension V2MessageReactionOutboxEngine: V2CommandFlushControlling {
    public func suspendCommandFlushing() async { await flushFlight.suspend() }
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
