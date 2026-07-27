import Foundation
import IMV2Core

public struct V2PendingMessageWithdrawal: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID
    public let operationID: MessageWithdrawalOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let resultingMessageRevision: UInt64?
    public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
    public let terminalCurrentRevision: UInt64?
}

public protocol V2LocalMessageWithdrawalStore: Sendable {
    func enqueue(_ command: V2PendingMessageWithdrawal) async throws
    /// A retry of the same pending withdrawal must retain its original
    /// operation ID, including when the app has restarted.
    func enqueueOrReusePendingMessageWithdrawal(_ command: V2PendingMessageWithdrawal) async throws -> V2PendingMessageWithdrawal
    func nextReadyMessageWithdrawal(now: Date) async throws -> V2PendingMessageWithdrawal?
    func markMessageWithdrawalAcknowledged(operationID: MessageWithdrawalOperationID, messageRevision: UInt64, roomSequence: UInt64) async throws
    func scheduleMessageWithdrawalRetry(operationID: MessageWithdrawalOperationID, nextAttemptAt: Date) async throws
    func rejectMessageWithdrawal(operationID: MessageWithdrawalOperationID, code: String, currentRevision: UInt64?) async throws
}

public enum V2MessageWithdrawalFlushResult: Equatable, Sendable { case idle, acknowledged(MessageWithdrawalOperationID), retryScheduled(MessageWithdrawalOperationID), rejected(MessageWithdrawalOperationID, code: String) }

public actor V2MessageWithdrawalOutboxEngine {
    private let store: any V2LocalMessageWithdrawalStore
    private let transport: any V2ClientMessageWithdrawalTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalMessageWithdrawalStore, transport: any V2ClientMessageWithdrawalTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    public func enqueueWithdrawal(roomID: RoomID, messageID: MessageID, expectedMessageRevision: UInt64) async throws -> V2PendingMessageWithdrawal {
        let command = V2PendingMessageWithdrawal(roomID: roomID, operationID: try .init(makeUUID().uuidString), messageID: messageID, expectedMessageRevision: expectedMessageRevision, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingMessageRevision: nil, resultingRoomSequence: nil, terminalCode: nil, terminalCurrentRevision: nil)
        return try await store.enqueueOrReusePendingMessageWithdrawal(command)
    }

    public func flushOnce() async throws -> V2MessageWithdrawalFlushResult {
        guard let command = try await store.nextReadyMessageWithdrawal(now: now()) else { return .idle }
        do {
            let result = try await transport.withdrawMessage(roomID: command.roomID, operationID: command.operationID, messageID: command.messageID, expectedMessageRevision: command.expectedMessageRevision)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.messageID == command.messageID else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageWithdrawalAcknowledged(operationID: command.operationID, messageRevision: result.messageRevision, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            switch error {
            case .server(let code, let retryable, let retryAfter, let currentRevision):
                if retryable {
                    try await store.scheduleMessageWithdrawalRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(TimeInterval(max(retryAfter, 1))))
                    return .retryScheduled(command.operationID)
                }
                try await store.rejectMessageWithdrawal(operationID: command.operationID, code: code, currentRevision: currentRevision)
                return .rejected(command.operationID, code: code)
            default:
                try await store.scheduleMessageWithdrawalRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
                return .retryScheduled(command.operationID)
            }
        } catch {
            try await store.scheduleMessageWithdrawalRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}
