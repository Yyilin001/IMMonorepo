import Foundation
import IMV2Core

/// A durable, authenticated moderator command. The reason is a bounded
/// reason code rather than free text so it remains safe to persist locally.
public struct V2PendingMessageRedaction: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }

    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let messageID: MessageID
    public let reasonCode: V2ModerationReasonCode
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let resultingMessageRevision: UInt64?
    public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
}

public protocol V2LocalMessageRedactionStore: Sendable {
    func enqueue(_ command: V2PendingMessageRedaction) async throws
    /// Equivalent pending moderator redactions retain one operation ID across
    /// retries and restarts so their audit trail stays singular.
    func enqueueOrReusePendingMessageRedaction(_ command: V2PendingMessageRedaction) async throws -> V2PendingMessageRedaction
    func nextReadyMessageRedaction(now: Date) async throws -> V2PendingMessageRedaction?
    func markMessageRedactionAcknowledged(operationID: ModerationOperationID, messageRevision: UInt64, roomSequence: UInt64) async throws
    func scheduleMessageRedactionRetry(operationID: ModerationOperationID, nextAttemptAt: Date) async throws
    func rejectMessageRedaction(operationID: ModerationOperationID, code: String) async throws
}

public enum V2MessageRedactionFlushResult: Equatable, Sendable {
    case idle
    case acknowledged(ModerationOperationID)
    case retryScheduled(ModerationOperationID)
    case rejected(ModerationOperationID, code: String)
}

/// Serializes a moderator redaction through the same offline-first command
/// rules as every other mutating client operation. The operation ID is never
/// regenerated during retry, so the server's audit record remains singular.
public actor V2MessageRedactionOutboxEngine {
    private let store: any V2LocalMessageRedactionStore
    private let transport: any V2ClientMessageRedactionTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalMessageRedactionStore, transport: any V2ClientMessageRedactionTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
    }

    @discardableResult
    public func enqueueRedaction(roomID: RoomID, messageID: MessageID, reasonCode: V2ModerationReasonCode) async throws -> V2PendingMessageRedaction {
        let command = try V2PendingMessageRedaction(
            roomID: roomID,
            operationID: .init(makeUUID().uuidString),
            messageID: messageID,
            reasonCode: reasonCode,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: now(),
            resultingMessageRevision: nil,
            resultingRoomSequence: nil,
            terminalCode: nil
        )
        return try await store.enqueueOrReusePendingMessageRedaction(command)
    }

    public func flushOnce() async throws -> V2MessageRedactionFlushResult {
        guard let command = try await store.nextReadyMessageRedaction(now: now()) else { return .idle }
        do {
            let result = try await transport.redactMessage(roomID: command.roomID, operationID: command.operationID, messageID: command.messageID, reasonCode: command.reasonCode)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.messageID == command.messageID,
                  result.messageRevision > 1, result.roomSequence > 0
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageRedactionAcknowledged(operationID: command.operationID, messageRevision: result.messageRevision, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            switch error {
            case .server(let code, let retryable, let retryAfter, _):
                if retryable {
                    try await store.scheduleMessageRedactionRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(TimeInterval(max(retryAfter, 1))))
                    return .retryScheduled(command.operationID)
                }
                try await store.rejectMessageRedaction(operationID: command.operationID, code: code)
                return .rejected(command.operationID, code: code)
            default:
                try await store.scheduleMessageRedactionRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
                return .retryScheduled(command.operationID)
            }
        } catch {
            try await store.scheduleMessageRedactionRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}
