import Foundation
import IMV2Core

public struct V2PendingMemberMute: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let targetUserID: UserID
    public let muteUntil: Date
    public let reasonCode: V2ModerationReasonCode
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
}

public protocol V2LocalMemberMuteStore: Sendable {
    func enqueue(_ command: V2PendingMemberMute) async throws
    func nextReadyMemberMute(now: Date) async throws -> V2PendingMemberMute?
    func markMemberMuteAcknowledged(operationID: ModerationOperationID, roomSequence: UInt64) async throws
    func scheduleMemberMuteRetry(operationID: ModerationOperationID, nextAttemptAt: Date) async throws
    func rejectMemberMute(operationID: ModerationOperationID, code: String) async throws
}

public enum V2MemberMuteFlushResult: Equatable, Sendable { case idle, acknowledged(ModerationOperationID), retryScheduled(ModerationOperationID), rejected(ModerationOperationID, code: String) }

public actor V2MemberMuteOutboxEngine {
    private let store: any V2LocalMemberMuteStore
    private let transport: any V2ClientMemberMuteTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalMemberMuteStore, transport: any V2ClientMemberMuteTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0); self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    public func enqueueMute(roomID: RoomID, targetUserID: UserID, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2PendingMemberMute {
        // The wire protocol carries milliseconds. Persist the canonical value
        // too, otherwise a sub-millisecond Date can never exactly match the
        // acknowledgement returned by the server.
        let milliseconds = Int64(muteUntil.timeIntervalSince1970 * 1_000)
        let normalizedMuteUntil = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        let commandTime = now()
        guard normalizedMuteUntil > commandTime else { throw V2ModerationValidationError.invalidMuteExpiry }
        let command = try V2PendingMemberMute(roomID: roomID, operationID: .init(makeUUID().uuidString), targetUserID: targetUserID, muteUntil: normalizedMuteUntil, reasonCode: reasonCode, state: .pending, attemptCount: 0, nextAttemptAt: commandTime, resultingRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(command); return command
    }

    public func flushOnce() async throws -> V2MemberMuteFlushResult {
        guard let command = try await store.nextReadyMemberMute(now: now()) else { return .idle }
        guard command.muteUntil > now() else {
            try await store.rejectMemberMute(operationID: command.operationID, code: "MUTE_EXPIRED")
            return .rejected(command.operationID, code: "MUTE_EXPIRED")
        }
        do {
            let result = try await transport.muteMember(roomID: command.roomID, operationID: command.operationID, targetUserID: command.targetUserID, muteUntil: command.muteUntil, reasonCode: command.reasonCode)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.targetUserID == command.targetUserID, result.muteUntil == command.muteUntil, result.roomSequence > 0 else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMemberMuteAcknowledged(operationID: command.operationID, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, let retryAfter, _) = error {
                if retryable { try await store.scheduleMemberMuteRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(TimeInterval(max(retryAfter, 1)))); return .retryScheduled(command.operationID) }
                try await store.rejectMemberMute(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code)
            }
            try await store.scheduleMemberMuteRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay)); return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleMemberMuteRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay)); return .retryScheduled(command.operationID)
        }
    }
}
