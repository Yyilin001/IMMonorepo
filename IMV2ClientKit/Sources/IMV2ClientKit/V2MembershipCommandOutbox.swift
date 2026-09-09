import Foundation
import IMV2Core

/// A durable, non-message command. Its operation ID is generated once when
/// intent is recorded and is reused until the server records a terminal result.
public struct V2PendingMembershipCommand: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }

    public let roomID: RoomID
    public let operationID: MembershipOperationID
    public let targetUserID: UserID
    public let action: V2RoomMembershipAction
    public let expectedMembershipRevision: UInt64
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let resultingMembershipRevision: UInt64?
    public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
    public let terminalCurrentRevision: UInt64?

    public init(
        roomID: RoomID,
        operationID: MembershipOperationID,
        targetUserID: UserID,
        action: V2RoomMembershipAction,
        expectedMembershipRevision: UInt64,
        state: State,
        attemptCount: Int,
        nextAttemptAt: Date,
        resultingMembershipRevision: UInt64?,
        resultingRoomSequence: UInt64?,
        terminalCode: String?,
        terminalCurrentRevision: UInt64?
    ) {
        self.roomID = roomID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
        self.expectedMembershipRevision = expectedMembershipRevision
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.resultingMembershipRevision = resultingMembershipRevision
        self.resultingRoomSequence = resultingRoomSequence
        self.terminalCode = terminalCode
        self.terminalCurrentRevision = terminalCurrentRevision
    }
}

public protocol V2LocalMembershipCommandStore: Sendable {
    func enqueue(_ command: V2PendingMembershipCommand) async throws
    /// A retry of the same target/action/revision must retain its original
    /// operation ID. The local store makes that reuse atomic across restarts.
    func enqueueOrReusePendingMembershipCommand(_ command: V2PendingMembershipCommand) async throws -> V2PendingMembershipCommand
    func nextReadyMembershipCommand(now: Date) async throws -> V2PendingMembershipCommand?
    func markMembershipAcknowledged(operationID: MembershipOperationID, membershipRevision: UInt64, roomSequence: UInt64) async throws
    func scheduleMembershipRetry(operationID: MembershipOperationID, nextAttemptAt: Date) async throws
    func rejectMembership(operationID: MembershipOperationID, code: String, currentRevision: UInt64?) async throws
}

public enum V2MembershipCommandFlushResult: Equatable, Sendable {
    case idle
    case acknowledged(MembershipOperationID)
    case retryScheduled(MembershipOperationID)
    case rejected(MembershipOperationID, code: String)
}

/// Serializes membership mutations separately from message sends. A revision
/// conflict is terminal because replaying the same stale intent cannot become
/// valid; callers must refresh membership state and explicitly create a new
/// operation.
public actor V2MembershipCommandOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2MembershipCommandFlushResult>()

    private let store: any V2LocalMembershipCommandStore
    private let transport: any V2ClientMembershipTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(
        store: any V2LocalMembershipCommandStore,
        transport: any V2ClientMembershipTransport,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelay: TimeInterval = 1
    ) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
    }

    @discardableResult
    public func enqueueMembershipChange(
        roomID: RoomID,
        targetUserID: UserID,
        action: V2RoomMembershipAction,
        expectedMembershipRevision: UInt64
    ) async throws -> V2PendingMembershipCommand {
        let command = try V2PendingMembershipCommand(
            roomID: roomID,
            operationID: .init(makeUUID().uuidString),
            targetUserID: targetUserID,
            action: action,
            expectedMembershipRevision: expectedMembershipRevision,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: now(),
            resultingMembershipRevision: nil,
            resultingRoomSequence: nil,
            terminalCode: nil,
            terminalCurrentRevision: nil
        )
        return try await store.enqueueOrReusePendingMembershipCommand(command)
    }

    public func flushOnce() async throws -> V2MembershipCommandFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    private func flushNextReadyCommand() async throws -> V2MembershipCommandFlushResult {
        guard let command = try await store.nextReadyMembershipCommand(now: now()) else { return .idle }
        do {
            let changed = try await transport.changeMembership(
                roomID: command.roomID,
                operationID: command.operationID,
                targetUserID: command.targetUserID,
                action: command.action,
                expectedMembershipRevision: command.expectedMembershipRevision
            )
            try Task.checkCancellation()
            guard changed.roomID == command.roomID,
                  changed.targetUserID == command.targetUserID,
                  changed.action == command.action
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMembershipAcknowledged(
                operationID: command.operationID,
                membershipRevision: changed.membershipRevision,
                roomSequence: changed.roomSequence
            )
            return .acknowledged(command.operationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            switch error {
            case .server(let code, let retryable, let retryAfter, let currentRevision):
                if retryable {
                    try await store.scheduleMembershipRetry(
                        operationID: command.operationID,
                        nextAttemptAt: try v2CommandRetryDate(now: now(), delay: TimeInterval(max(retryAfter, 1)))
                    )
                    return .retryScheduled(command.operationID)
                }
                try await store.rejectMembership(operationID: command.operationID, code: code, currentRevision: currentRevision)
                return .rejected(command.operationID, code: code)
            default:
                try await store.scheduleMembershipRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
                return .retryScheduled(command.operationID)
            }
        } catch {
            try await store.scheduleMembershipRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}

extension V2MembershipCommandOutboxEngine: V2CommandFlushControlling {
    public func suspendCommandFlushing() async { await flushFlight.suspend() }
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
