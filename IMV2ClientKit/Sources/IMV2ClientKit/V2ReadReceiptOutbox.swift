import Foundation
import IMV2Core

public struct V2PendingReadReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID; public let operationID: ReadReceiptOperationID; public let readThroughRoomSequence: UInt64
    public let state: State; public let attemptCount: Int; public let nextAttemptAt: Date
    public let resultingRoomSequence: UInt64?; public let terminalCode: String?
}
public protocol V2LocalReadReceiptStore: Sendable {
    func enqueue(_ command: V2PendingReadReceipt) async throws
    /// Atomically persists only a receipt that advances this room's durable
    /// local high-water mark. Pending retries count, so reopening a room does
    /// not create a duplicate operation after an offline attempt or restart.
    func enqueueIfReadReceiptAdvances(_ command: V2PendingReadReceipt) async throws -> Bool
    func nextReadyReadReceipt(now: Date) async throws -> V2PendingReadReceipt?
    func markReadReceiptAcknowledged(operationID: ReadReceiptOperationID, roomSequence: UInt64) async throws
    func scheduleReadReceiptRetry(operationID: ReadReceiptOperationID, nextAttemptAt: Date) async throws
    func rejectReadReceipt(operationID: ReadReceiptOperationID, code: String) async throws
}
public enum V2ReadReceiptFlushResult: Equatable, Sendable { case idle, acknowledged(ReadReceiptOperationID), retryScheduled(ReadReceiptOperationID), rejected(ReadReceiptOperationID, code: String) }
public actor V2ReadReceiptOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2ReadReceiptFlushResult>()

    private let store: any V2LocalReadReceiptStore; private let transport: any V2ClientReadReceiptTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    public init(store: any V2LocalReadReceiptStore, transport: any V2ClientReadReceiptTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { precondition(retryDelay > 0); self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }
    public func enqueueReceipt(roomID: RoomID, readThroughRoomSequence: UInt64) async throws -> V2PendingReadReceipt {
        // The authoritative PostgreSQL and local SQLite columns are signed
        // BIGINT. Protobuf permits uint64, so reject an unpersistable value at
        // the client boundary instead of trapping during Int64 conversion.
        guard readThroughRoomSequence > 0, readThroughRoomSequence <= UInt64(Int64.max) else {
            throw V2ClientCommandError.commandConflict
        }
        let command = try V2PendingReadReceipt(roomID: roomID, operationID: .init(makeUUID().uuidString), readThroughRoomSequence: readThroughRoomSequence, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(command); return command
    }

    /// Returns `nil` when this room has already durably queued or acknowledged
    /// an equal-or-newer receipt. The comparison and insertion share the local
    /// SQLite write transaction, preventing concurrent UI refreshes from
    /// creating duplicate viewing operations.
    public func enqueueReceiptIfAdvancing(roomID: RoomID, readThroughRoomSequence: UInt64) async throws -> V2PendingReadReceipt? {
        guard readThroughRoomSequence > 0, readThroughRoomSequence <= UInt64(Int64.max) else {
            throw V2ClientCommandError.commandConflict
        }
        let command = try V2PendingReadReceipt(
            roomID: roomID,
            operationID: .init(makeUUID().uuidString),
            readThroughRoomSequence: readThroughRoomSequence,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: now(),
            resultingRoomSequence: nil,
            terminalCode: nil
        )
        return try await store.enqueueIfReadReceiptAdvances(command) ? command : nil
    }
    public func flushOnce() async throws -> V2ReadReceiptFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    private func flushNextReadyCommand() async throws -> V2ReadReceiptFlushResult {
        guard let command = try await store.nextReadyReadReceipt(now: now()) else { return .idle }
        do {
            let result = try await transport.recordReadReceipt(roomID: command.roomID, operationID: command.operationID, readThroughRoomSequence: command.readThroughRoomSequence)
            try Task.checkCancellation()
            guard result.roomID == command.roomID,
                  result.readThroughRoomSequence >= command.readThroughRoomSequence,
                  result.readThroughRoomSequence <= UInt64(Int64.max)
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markReadReceiptAcknowledged(operationID: command.operationID, roomSequence: result.readThroughRoomSequence); return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectReadReceipt(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code) }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleReadReceiptRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(command.operationID)
        } catch { try await store.scheduleReadReceiptRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID) }
    }
}

extension V2ReadReceiptOutboxEngine: V2CommandFlushControlling {
    public func suspendCommandFlushing() async { await flushFlight.suspend() }
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
