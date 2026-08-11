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

/// A parent plan permits a user to forward more than the wire command's
/// bounded payload. Chunks are generated lazily and have deterministic IDs,
/// so a crash cannot produce a duplicate server-side forward.
public struct V2ForwardMessagesPlan: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable { case active, completed, cancelled }

    public let operationID: MessageForwardOperationID
    public let sourceMessageCount: Int
    public let targetRoomCount: Int
    public let totalForwardCount: Int
    public let succeededCount: Int
    public let failedCount: Int
    public let state: State

    public var id: MessageForwardOperationID { operationID }
}

public protocol V2BulkForwardMessagesStore: Sendable {
    func enqueueForwardPlan(_ plan: V2ForwardMessagesPlan, sourceMessageIDs: [MessageID], targetRoomIDs: [RoomID], now: Date) async throws -> V2ForwardMessagesPlan
    func nextReadyForwardPlanChunk(now: Date) async throws -> V2PendingForwardMessagesCommand?
    func markForwardPlanChunkAcknowledged(operationID: MessageForwardOperationID, results: [V2ForwardMessageResult], now: Date) async throws -> MessageForwardOperationID?
    func scheduleForwardPlanChunkRetry(operationID: MessageForwardOperationID, nextAttemptAt: Date) async throws
    func rejectForwardPlanChunk(operationID: MessageForwardOperationID, code: String, now: Date) async throws -> MessageForwardOperationID?
    func cancelForwardPlan(operationID: MessageForwardOperationID, now: Date) async throws
    func forwardPlan(operationID: MessageForwardOperationID) async throws -> V2ForwardMessagesPlan?
}

public enum V2BulkForwardMessagesFlushResult: Equatable, Sendable {
    case idle
    case chunkAcknowledged(planID: MessageForwardOperationID, operationID: MessageForwardOperationID, results: [V2ForwardMessageResult])
    case retryScheduled(MessageForwardOperationID)
    case chunkRejected(planID: MessageForwardOperationID, operationID: MessageForwardOperationID, code: String)
}

public actor V2BulkForwardMessagesOutboxEngine {
    public static let sourceMessagesPerChunk = 20

    private let store: any V2BulkForwardMessagesStore
    private let transport: any V2ClientForwardMessagesTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2BulkForwardMessagesStore, transport: any V2ClientForwardMessagesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
    }

    public func enqueue(sourceMessageIDs: [MessageID], targetRoomIDs: [RoomID]) async throws -> V2ForwardMessagesPlan {
        guard !sourceMessageIDs.isEmpty, !targetRoomIDs.isEmpty,
              Set(sourceMessageIDs).count == sourceMessageIDs.count,
              Set(targetRoomIDs).count == targetRoomIDs.count,
              sourceMessageIDs.count <= 10_000,
              targetRoomIDs.count <= 100,
              sourceMessageIDs.count <= Int.max / targetRoomIDs.count
        else { throw V2CoreError.invalidPositiveValue }
        let total = sourceMessageIDs.count * targetRoomIDs.count
        let plan = V2ForwardMessagesPlan(
            operationID: try .init(makeUUID().uuidString),
            sourceMessageCount: sourceMessageIDs.count,
            targetRoomCount: targetRoomIDs.count,
            totalForwardCount: total,
            succeededCount: 0,
            failedCount: 0,
            state: .active
        )
        return try await store.enqueueForwardPlan(plan, sourceMessageIDs: sourceMessageIDs, targetRoomIDs: targetRoomIDs, now: now())
    }

    public func flushOnce() async throws -> V2BulkForwardMessagesFlushResult {
        guard let pending = try await store.nextReadyForwardPlanChunk(now: now()) else { return .idle }
        do {
            let results = try await transport.forwardMessages(command: pending.command)
            try Task.checkCancellation()
            guard let planID = try await store.markForwardPlanChunkAcknowledged(operationID: pending.command.operationID, results: results, now: now()) else {
                throw V2ClientCommandError.commandConflict
            }
            return .chunkAcknowledged(planID: planID, operationID: pending.command.operationID, results: results)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable {
                guard let planID = try await store.rejectForwardPlanChunk(operationID: pending.command.operationID, code: code, now: now()) else {
                    throw V2ClientCommandError.commandConflict
                }
                return .chunkRejected(planID: planID, operationID: pending.command.operationID, code: code)
            }
            let delay: TimeInterval = {
                if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }
                return retryDelay
            }()
            try await store.scheduleForwardPlanChunkRetry(operationID: pending.command.operationID, nextAttemptAt: now().addingTimeInterval(delay))
            return .retryScheduled(pending.command.operationID)
        } catch {
            try await store.scheduleForwardPlanChunkRetry(operationID: pending.command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
            return .retryScheduled(pending.command.operationID)
        }
    }

    public func cancel(operationID: MessageForwardOperationID) async throws {
        try await store.cancelForwardPlan(operationID: operationID, now: now())
    }

    public func plan(operationID: MessageForwardOperationID) async throws -> V2ForwardMessagesPlan? {
        try await store.forwardPlan(operationID: operationID)
    }
}
