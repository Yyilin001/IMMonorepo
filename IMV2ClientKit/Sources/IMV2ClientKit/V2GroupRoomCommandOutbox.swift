import Foundation
import IMV2Core

/// A persisted group-bootstrap intent. The operation ID and initial audience
/// are immutable once recorded, so reconnects cannot accidentally create a
/// second group or silently change who was invited.
public struct V2PendingGroupRoomCreation: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }

    public let operationID: GroupRoomOperationID
    public let title: String
    public let initialMemberUserIDs: [UserID]
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let createdRoomID: RoomID?
    public let terminalCode: String?

    public init(operationID: GroupRoomOperationID, title: String, initialMemberUserIDs: [UserID], state: State, attemptCount: Int, nextAttemptAt: Date, createdRoomID: RoomID?, terminalCode: String?) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Set(initialMemberUserIDs).count == initialMemberUserIDs.count,
              attemptCount >= 0,
              (state == .acknowledged) == (createdRoomID != nil),
              (state == .rejected) == (terminalCode != nil),
              state != .rejected || createdRoomID == nil,
              state != .acknowledged || terminalCode == nil
        else { throw V2ClientCommandError.commandConflict }
        self.operationID = operationID
        self.title = normalizedTitle
        self.initialMemberUserIDs = initialMemberUserIDs.sorted()
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.createdRoomID = createdRoomID
        self.terminalCode = terminalCode
    }
}

public protocol V2LocalGroupRoomCommandStore: Sendable {
    func enqueue(_ command: V2PendingGroupRoomCreation) async throws
    func nextReadyGroupRoomCreation(now: Date) async throws -> V2PendingGroupRoomCreation?
    func markGroupRoomCreationAcknowledged(operationID: GroupRoomOperationID, roomID: RoomID) async throws
    func scheduleGroupRoomCreationRetry(operationID: GroupRoomOperationID, nextAttemptAt: Date) async throws
    func rejectGroupRoomCreation(operationID: GroupRoomOperationID, code: String) async throws
}

public enum V2GroupRoomCreationFlushResult: Equatable, Sendable {
    case idle
    case acknowledged(GroupRoomOperationID, roomID: RoomID)
    case retryScheduled(GroupRoomOperationID)
    case rejected(GroupRoomOperationID, code: String)
}

/// Dedicated durable boundary for group creation. It is deliberately separate
/// from membership mutations because there is no existing room revision to
/// fence during the atomic bootstrap transaction.
public actor V2GroupRoomCommandOutboxEngine {
    private let store: any V2LocalGroupRoomCommandStore
    private let transport: any V2ClientGroupMessagingTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalGroupRoomCommandStore, transport: any V2ClientGroupMessagingTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    @discardableResult
    public func enqueueCreation(title: String, initialMemberUserIDs: [UserID]) async throws -> V2PendingGroupRoomCreation {
        let command = try V2PendingGroupRoomCreation(
            operationID: .init(makeUUID().uuidString), title: title,
            initialMemberUserIDs: initialMemberUserIDs, state: .pending,
            attemptCount: 0, nextAttemptAt: now(), createdRoomID: nil, terminalCode: nil
        )
        try await store.enqueue(command)
        return command
    }

    public func flushOnce() async throws -> V2GroupRoomCreationFlushResult {
        guard let command = try await store.nextReadyGroupRoomCreation(now: now()) else { return .idle }
        do {
            let created = try await transport.createGroupRoom(operationID: command.operationID, title: command.title, initialMemberUserIDs: command.initialMemberUserIDs)
            guard created.title == command.title,
                  Set(command.initialMemberUserIDs).isSubset(of: Set(created.memberUserIDs))
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markGroupRoomCreationAcknowledged(operationID: command.operationID, roomID: created.roomID)
            return .acknowledged(command.operationID, roomID: created.roomID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable {
                try await store.rejectGroupRoomCreation(operationID: command.operationID, code: code)
                return .rejected(command.operationID, code: code)
            }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleGroupRoomCreationRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(delay))
            return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleGroupRoomCreationRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}
