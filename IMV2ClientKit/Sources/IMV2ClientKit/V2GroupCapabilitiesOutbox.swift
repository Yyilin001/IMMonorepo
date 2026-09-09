import Foundation
import IMV2Core

/// A single durable lane for all ordered group-control mutations. Each row
/// owns an operation ID permanently, so a reconnect retries server intent
/// rather than creating a second pin, announcement revision, or role change.
public struct V2PendingGroupCapabilityCommand: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case pin, announcement, rolePermissions, memberRole }
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let kind: Kind; public let operationID: String; public let roomID: RoomID
    public let messageID: MessageID?; public let isPinned: Bool?; public let body: String?
    public let role: V2RoomMembershipRole?; public let permissions: Set<V2GroupPermission>; public let targetUserID: UserID?
    public let expectedRevision: UInt64; public let state: State; public let attemptCount: Int; public let nextAttemptAt: Date; public let terminalCode: String?
}

public protocol V2LocalGroupCapabilitiesStore: Sendable {
    func enqueueOrReuseGroupCapability(_ command: V2PendingGroupCapabilityCommand) async throws -> V2PendingGroupCapabilityCommand
    func nextReadyGroupCapability(now: Date) async throws -> V2PendingGroupCapabilityCommand?
    func markGroupCapabilityAcknowledged(operationID: String) async throws
    func scheduleGroupCapabilityRetry(operationID: String, nextAttemptAt: Date) async throws
    func rejectGroupCapability(operationID: String, code: String) async throws
}

public enum V2GroupCapabilitiesFlushResult: Equatable, Sendable { case idle, acknowledged(String), retryScheduled(String), rejected(String, code: String) }

public actor V2GroupCapabilitiesOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2GroupCapabilitiesFlushResult>()

    private let store: any V2LocalGroupCapabilitiesStore; private let transport: any V2ClientGroupCapabilitiesTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    public init(store: any V2LocalGroupCapabilitiesStore, transport: any V2ClientGroupCapabilitiesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }
    public func enqueuePin(roomID: RoomID, messageID: MessageID, isPinned: Bool) async throws -> V2PendingGroupCapabilityCommand { try await enqueue(.init(kind: .pin, operationID: makeUUID().uuidString, roomID: roomID, messageID: messageID, isPinned: isPinned, body: nil, role: nil, permissions: [], targetUserID: nil, expectedRevision: 0, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }
    public func enqueueAnnouncement(roomID: RoomID, body: String, expectedRevision: UInt64) async throws -> V2PendingGroupCapabilityCommand { let operationID = makeUUID().uuidString; _ = try V2GroupAnnouncementCommand(operationID: .init(operationID), roomID: roomID, body: body, expectedRevision: expectedRevision); return try await enqueue(.init(kind: .announcement, operationID: operationID, roomID: roomID, messageID: nil, isPinned: nil, body: body, role: nil, permissions: [], targetUserID: nil, expectedRevision: expectedRevision, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }
    public func enqueueRolePermissions(roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, expectedRevision: UInt64) async throws -> V2PendingGroupCapabilityCommand { guard role != .owner else { throw V2GroupPermissionValidationError.ownerPolicyIsImmutable }; return try await enqueue(.init(kind: .rolePermissions, operationID: makeUUID().uuidString, roomID: roomID, messageID: nil, isPinned: nil, body: nil, role: role, permissions: permissions, targetUserID: nil, expectedRevision: expectedRevision, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }
    public func enqueueMemberRole(roomID: RoomID, targetUserID: UserID, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64) async throws -> V2PendingGroupCapabilityCommand { guard role != .owner else { throw V2GroupPermissionValidationError.memberRoleCannotBeOwner }; return try await enqueue(.init(kind: .memberRole, operationID: makeUUID().uuidString, roomID: roomID, messageID: nil, isPinned: nil, body: nil, role: role, permissions: [], targetUserID: targetUserID, expectedRevision: expectedMembershipRevision, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }
    private func enqueue(_ command: V2PendingGroupCapabilityCommand) async throws -> V2PendingGroupCapabilityCommand { try await store.enqueueOrReuseGroupCapability(command) }
    public func flushOnce() async throws -> V2GroupCapabilitiesFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    private func flushNextReadyCommand() async throws -> V2GroupCapabilitiesFlushResult {
        guard let pending = try await store.nextReadyGroupCapability(now: now()) else { return .idle }
        do {
            switch pending.kind {
            case .pin: _ = try await transport.setPinnedMessage(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, messageID: pending.messageID!, isPinned: pending.isPinned!))
            case .announcement: _ = try await transport.setGroupAnnouncement(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, body: pending.body!, expectedRevision: pending.expectedRevision))
            case .rolePermissions: _ = try await transport.setGroupRolePermissions(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, role: pending.role!, permissions: pending.permissions, expectedRevision: pending.expectedRevision))
            case .memberRole: _ = try await transport.changeGroupMemberRole(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, targetUserID: pending.targetUserID!, role: pending.role!, expectedMembershipRevision: pending.expectedRevision))
            }
            try Task.checkCancellation(); try await store.markGroupCapabilityAcknowledged(operationID: pending.operationID); return .acknowledged(pending.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError { if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectGroupCapability(operationID: pending.operationID, code: code); return .rejected(pending.operationID, code: code) }; let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }(); try await store.scheduleGroupCapabilityRetry(operationID: pending.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(pending.operationID) }
        catch { try await store.scheduleGroupCapabilityRetry(operationID: pending.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(pending.operationID) }
    }
}

extension V2GroupCapabilitiesOutboxEngine: V2CommandFlushControlling {
    public func suspendCommandFlushing() async { await flushFlight.suspend() }
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
