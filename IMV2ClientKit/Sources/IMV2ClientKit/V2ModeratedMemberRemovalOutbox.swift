import Foundation
import IMV2Core

/// Durable client intent for the audit-level removal protocol.  It is kept
/// separate from the ordinary membership outbox because its reason code is
/// part of the immutable server audit record.
public struct V2PendingModeratedMemberRemoval: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let targetUserID: UserID
    public let reasonCode: V2ModerationReasonCode
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let resultingMembershipRevision: UInt64?
    public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
}

public protocol V2LocalModeratedMemberRemovalStore: Sendable {
    func enqueue(_ command: V2PendingModeratedMemberRemoval) async throws
    /// Equivalent pending audit removals retain their operation ID across
    /// retries and restarts.
    func enqueueOrReusePendingModeratedMemberRemoval(_ command: V2PendingModeratedMemberRemoval) async throws -> V2PendingModeratedMemberRemoval
    func nextReadyModeratedMemberRemoval(now: Date) async throws -> V2PendingModeratedMemberRemoval?
    func markModeratedMemberRemovalAcknowledged(operationID: ModerationOperationID, membershipRevision: UInt64, roomSequence: UInt64) async throws
    func scheduleModeratedMemberRemovalRetry(operationID: ModerationOperationID, nextAttemptAt: Date) async throws
    func rejectModeratedMemberRemoval(operationID: ModerationOperationID, code: String) async throws
}

public enum V2ModeratedMemberRemovalFlushResult: Equatable, Sendable { case idle, acknowledged(ModerationOperationID), retryScheduled(ModerationOperationID), rejected(ModerationOperationID, code: String) }

public actor V2ModeratedMemberRemovalOutboxEngine {
    private let store: any V2LocalModeratedMemberRemovalStore
    private let transport: any V2ClientModeratedMemberRemovalTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalModeratedMemberRemovalStore, transport: any V2ClientModeratedMemberRemovalTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    public func enqueueRemoval(roomID: RoomID, targetUserID: UserID, reasonCode: V2ModerationReasonCode) async throws -> V2PendingModeratedMemberRemoval {
        let command = try V2PendingModeratedMemberRemoval(roomID: roomID, operationID: .init(makeUUID().uuidString), targetUserID: targetUserID, reasonCode: reasonCode, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingMembershipRevision: nil, resultingRoomSequence: nil, terminalCode: nil)
        return try await store.enqueueOrReusePendingModeratedMemberRemoval(command)
    }

    public func flushOnce() async throws -> V2ModeratedMemberRemovalFlushResult {
        guard let command = try await store.nextReadyModeratedMemberRemoval(now: now()) else { return .idle }
        do {
            let result = try await transport.removeMemberByModerator(roomID: command.roomID, operationID: command.operationID, targetUserID: command.targetUserID, reasonCode: command.reasonCode)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.targetUserID == command.targetUserID, result.membershipRevision > 0, result.roomSequence > 0 else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markModeratedMemberRemovalAcknowledged(operationID: command.operationID, membershipRevision: result.membershipRevision, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, let retryAfter, _) = error {
                if retryable {
                    try await store.scheduleModeratedMemberRemovalRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(TimeInterval(max(retryAfter, 1))))
                    return .retryScheduled(command.operationID)
                }
                try await store.rejectModeratedMemberRemoval(operationID: command.operationID, code: code)
                return .rejected(command.operationID, code: code)
            }
            try await store.scheduleModeratedMemberRemovalRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
            return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleModeratedMemberRemovalRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}
