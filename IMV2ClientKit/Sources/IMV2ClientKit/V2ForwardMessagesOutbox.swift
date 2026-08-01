import Foundation
import IMV2Core

public struct V2PendingForwardMessagesCommand: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let command: V2ForwardMessagesCommand; public let state: State; public let attemptCount: Int; public let nextAttemptAt: Date; public let terminalCode: String?
}

public protocol V2LocalForwardMessagesStore: Sendable {
    func enqueueOrReuseForwardMessages(_ pending: V2PendingForwardMessagesCommand) async throws -> V2PendingForwardMessagesCommand
    func nextReadyForwardMessages(now: Date) async throws -> V2PendingForwardMessagesCommand?
    func markForwardMessagesAcknowledged(operationID: MessageForwardOperationID) async throws
    func scheduleForwardMessagesRetry(operationID: MessageForwardOperationID, nextAttemptAt: Date) async throws
    func rejectForwardMessages(operationID: MessageForwardOperationID, code: String) async throws
}

public enum V2ForwardMessagesFlushResult: Equatable, Sendable { case idle, acknowledged(MessageForwardOperationID, [V2ForwardMessageResult]), retryScheduled(MessageForwardOperationID), rejected(MessageForwardOperationID, code: String) }

public actor V2ForwardMessagesOutboxEngine {
    private let store: any V2LocalForwardMessagesStore; private let transport: any V2ClientForwardMessagesTransport; private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    public init(store: any V2LocalForwardMessagesStore, transport: any V2ClientForwardMessagesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }
    public func enqueue(sourceMessageIDs: [MessageID], targetRoomIDs: [RoomID]) async throws -> V2PendingForwardMessagesCommand { let command = try V2ForwardMessagesCommand(operationID: .init(makeUUID().uuidString), sourceMessageIDs: sourceMessageIDs, targetRoomIDs: targetRoomIDs); return try await store.enqueueOrReuseForwardMessages(.init(command: command, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }
    public func flushOnce() async throws -> V2ForwardMessagesFlushResult { guard let pending = try await store.nextReadyForwardMessages(now: now()) else { return .idle }; do { let results = try await transport.forwardMessages(command: pending.command); try Task.checkCancellation(); try await store.markForwardMessagesAcknowledged(operationID: pending.command.operationID); return .acknowledged(pending.command.operationID, results) } catch is CancellationError { throw CancellationError() } catch let error as V2RealtimeTransportError { if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectForwardMessages(operationID: pending.command.operationID, code: code); return .rejected(pending.command.operationID, code: code) }; let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }(); try await store.scheduleForwardMessagesRetry(operationID: pending.command.operationID, nextAttemptAt: now().addingTimeInterval(delay)); return .retryScheduled(pending.command.operationID) } catch { try await store.scheduleForwardMessagesRetry(operationID: pending.command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay)); return .retryScheduled(pending.command.operationID) } }
}
