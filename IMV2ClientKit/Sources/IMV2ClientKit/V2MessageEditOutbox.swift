import Foundation
import IMV2Core

public struct V2PendingMessageEdit: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID; public let operationID: MessageEditOperationID; public let messageID: MessageID
    public let expectedMessageRevision: UInt64; public let text: String; public let state: State
    public let attemptCount: Int; public let nextAttemptAt: Date; public let resultingMessageRevision: UInt64?
    public let resultingRoomSequence: UInt64?; public let terminalCode: String?; public let terminalCurrentRevision: UInt64?
}

public protocol V2LocalMessageEditStore: Sendable {
    func enqueue(_ command: V2PendingMessageEdit) async throws
    func nextReadyMessageEdit(now: Date) async throws -> V2PendingMessageEdit?
    func markMessageEditAcknowledged(operationID: MessageEditOperationID, messageRevision: UInt64, roomSequence: UInt64) async throws
    func scheduleMessageEditRetry(operationID: MessageEditOperationID, nextAttemptAt: Date) async throws
    func rejectMessageEdit(operationID: MessageEditOperationID, code: String, currentRevision: UInt64?) async throws
}

public enum V2MessageEditFlushResult: Equatable, Sendable { case idle, acknowledged(MessageEditOperationID), retryScheduled(MessageEditOperationID), rejected(MessageEditOperationID, code: String) }

public actor V2MessageEditOutboxEngine {
    private let store: any V2LocalMessageEditStore; private let transport: any V2ClientMessageEditTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    public init(store: any V2LocalMessageEditStore, transport: any V2ClientMessageEditTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0); self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }
    public func enqueueEdit(roomID: RoomID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2PendingMessageEdit {
        let command = V2PendingMessageEdit(roomID: roomID, operationID: try .init(makeUUID().uuidString), messageID: messageID, expectedMessageRevision: expectedMessageRevision, text: text, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingMessageRevision: nil, resultingRoomSequence: nil, terminalCode: nil, terminalCurrentRevision: nil)
        try await store.enqueue(command); return command
    }
    public func flushOnce() async throws -> V2MessageEditFlushResult {
        guard let command = try await store.nextReadyMessageEdit(now: now()) else { return .idle }
        do {
            let result = try await transport.editMessage(roomID: command.roomID, operationID: command.operationID, messageID: command.messageID, expectedMessageRevision: command.expectedMessageRevision, text: command.text)
            guard result.roomID == command.roomID, result.messageID == command.messageID, result.text == command.text else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageEditAcknowledged(operationID: command.operationID, messageRevision: result.messageRevision, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, let currentRevision) = error, !retryable {
                try await store.rejectMessageEdit(operationID: command.operationID, code: code, currentRevision: currentRevision)
                return .rejected(command.operationID, code: code)
            }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleMessageEditRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(delay)); return .retryScheduled(command.operationID)
        } catch { try await store.scheduleMessageEditRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay)); return .retryScheduled(command.operationID) }
    }
}
