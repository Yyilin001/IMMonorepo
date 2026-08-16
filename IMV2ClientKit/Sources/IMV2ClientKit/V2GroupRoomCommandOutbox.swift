import Foundation
import IMV2Core

/// A persisted group-bootstrap intent. The operation ID and initial audience
/// are immutable once recorded, so reconnects cannot accidentally create a
/// second group or silently change who was invited.
public struct V2PendingGroupRoomCreation: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, cancelling, finalizing, cancelled, acknowledged, rejected }

    public let operationID: GroupRoomOperationID
    public let title: String
    public let deliveryMode: V2GroupDeliveryMode
    public let initialMemberUserIDs: [UserID]
    /// Number of canonical audience entries durably acknowledged by the
    /// server-side staging draft. It only advances after the matching bounded
    /// append response, so reconnects resume instead of re-uploading 100k IDs.
    public let uploadedMemberCount: Int
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let createdRoomID: RoomID?
    public let terminalCode: String?

    public init(operationID: GroupRoomOperationID, title: String, deliveryMode: V2GroupDeliveryMode, initialMemberUserIDs: [UserID], uploadedMemberCount: Int = 0, state: State, attemptCount: Int, nextAttemptAt: Date, createdRoomID: RoomID?, terminalCode: String?) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Set(initialMemberUserIDs).count == initialMemberUserIDs.count,
              uploadedMemberCount >= 0,
              uploadedMemberCount <= initialMemberUserIDs.count,
              attemptCount >= 0,
              (state == .acknowledged) == (createdRoomID != nil),
              (state == .rejected) == (terminalCode != nil),
              state != .cancelled || (createdRoomID == nil && terminalCode == nil),
              state != .cancelling || (createdRoomID == nil && terminalCode == nil),
              state != .finalizing || (createdRoomID == nil && terminalCode == nil),
              state != .rejected || createdRoomID == nil,
              state != .acknowledged || terminalCode == nil
        else { throw V2ClientCommandError.commandConflict }
        self.operationID = operationID
        self.title = normalizedTitle
        self.deliveryMode = deliveryMode
        self.initialMemberUserIDs = initialMemberUserIDs.sorted()
        self.uploadedMemberCount = uploadedMemberCount
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.createdRoomID = createdRoomID
        self.terminalCode = terminalCode
    }
}

public protocol V2LocalGroupRoomCommandStore: Sendable {
    func enqueue(_ command: V2PendingGroupRoomCreation) async throws
    /// Reuses an equivalent pending intent atomically. A group creation must
    /// not receive a second operation ID merely because its first response was
    /// lost or the app restarted before reconnecting.
    func enqueueOrReusePendingGroupRoomCreation(_ command: V2PendingGroupRoomCreation) async throws -> V2PendingGroupRoomCreation
    func nextReadyGroupRoomCreation(now: Date) async throws -> V2PendingGroupRoomCreation?
    func markGroupRoomCreationMembersUploaded(operationID: GroupRoomOperationID, uploadedMemberCount: Int) async throws
    /// Used only after Begin proves the server has recreated an empty expired
    /// draft for this immutable operation.
    func resetGroupRoomCreationUploadProgress(operationID: GroupRoomOperationID) async throws
    func markGroupRoomCreationAcknowledged(operationID: GroupRoomOperationID, roomID: RoomID) async throws
    func scheduleGroupRoomCreationRetry(operationID: GroupRoomOperationID, nextAttemptAt: Date) async throws
    func rejectGroupRoomCreation(operationID: GroupRoomOperationID, code: String) async throws
    func beginCancellingGroupRoomCreation(operationID: GroupRoomOperationID, now: Date) async throws
    func nextReadyGroupRoomCreationCancellation(now: Date) async throws -> V2PendingGroupRoomCreation?
    func markGroupRoomCreationCancelled(operationID: GroupRoomOperationID) async throws
    /// The server has already frozen the audience, so cancellation must not
    /// strand the durable creation intent in a retry-only cancelling state.
    func resumeGroupRoomCreationAfterCancellationRefusal(operationID: GroupRoomOperationID, now: Date) async throws
    /// Ordered durable history, including terminal cancellation and rejection
    /// records. This lets a recreated UI restore the outcome of an action
    /// performed while the app was offline.
    func groupRoomCreations() async throws -> [V2PendingGroupRoomCreation]
}

public enum V2GroupRoomCreationFlushResult: Equatable, Sendable {
    case idle
    case acknowledged(GroupRoomOperationID, roomID: RoomID)
    case retryScheduled(GroupRoomOperationID)
    case rejected(GroupRoomOperationID, code: String)
    case cancelled(GroupRoomOperationID)
    case cancellationRefused(GroupRoomOperationID)
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
    private var preparedOperations: Set<GroupRoomOperationID> = []

    public init(store: any V2LocalGroupRoomCommandStore, transport: any V2ClientGroupMessagingTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    @discardableResult
    public func enqueueCreation(title: String, deliveryMode: V2GroupDeliveryMode, initialMemberUserIDs: [UserID]) async throws -> V2PendingGroupRoomCreation {
        let command = try V2PendingGroupRoomCreation(
            operationID: .init(makeUUID().uuidString), title: title,
            deliveryMode: deliveryMode,
            initialMemberUserIDs: initialMemberUserIDs, state: .pending,
            attemptCount: 0, nextAttemptAt: now(), createdRoomID: nil, terminalCode: nil
        )
        return try await store.enqueueOrReusePendingGroupRoomCreation(command)
    }

    /// The local transition happens before any network request. A restart or
    /// failed cancellation therefore cannot resurrect the creation intent.
    public func requestCancellation(operationID: GroupRoomOperationID) async throws {
        try await store.beginCancellingGroupRoomCreation(operationID: operationID, now: now())
        preparedOperations.remove(operationID)
    }

    public func latestCreation() async throws -> V2PendingGroupRoomCreation? {
        try await store.groupRoomCreations().last
    }

    public func flushOnce() async throws -> V2GroupRoomCreationFlushResult {
        if let cancellation = try await store.nextReadyGroupRoomCreationCancellation(now: now()) {
            do {
                try await transport.cancelGroupRoomCreation(operationID: cancellation.operationID)
                try await store.markGroupRoomCreationCancelled(operationID: cancellation.operationID)
                preparedOperations.remove(cancellation.operationID)
                return .cancelled(cancellation.operationID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as V2RealtimeTransportError {
                if case .server(let code, let retryable, _, _) = error,
                   code == "GROUP_CREATION_FROZEN", !retryable {
                    // A stable protocol code distinguishes this immutable
                    // audience race from an actual idempotency conflict.
                    // Resume the original create under the same operation ID
                    // rather than endlessly retrying an impossible cancel.
                    try await store.resumeGroupRoomCreationAfterCancellationRefusal(operationID: cancellation.operationID, now: now())
                    preparedOperations.remove(cancellation.operationID)
                    return .cancellationRefused(cancellation.operationID)
                }
                try await store.scheduleGroupRoomCreationRetry(operationID: cancellation.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
                return .retryScheduled(cancellation.operationID)
            } catch {
                try await store.scheduleGroupRoomCreationRetry(operationID: cancellation.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay))
                return .retryScheduled(cancellation.operationID)
            }
        }
        guard let command = try await store.nextReadyGroupRoomCreation(now: now()) else { return .idle }
        do {
            if !preparedOperations.contains(command.operationID) {
                let draft = try await transport.beginGroupRoomCreation(operationID: command.operationID, title: command.title)
                guard draft.operationID == command.operationID, draft.title == command.title else { throw V2RealtimeTransportError.unexpectedResponse }
                // Server drafts have a finite lease. When a device resumes after
                // expiry, Begin recreates the empty draft under the immutable
                // operation ID and the durable client cursor is reset before any
                // page is sent. Other mismatches would risk silently changing the
                // audience and are rejected.
                if draft.stagedMemberCount == command.uploadedMemberCount {
                    preparedOperations.insert(command.operationID)
                } else if draft.stagedMemberCount == 0, command.uploadedMemberCount > 0 {
                    try await store.resetGroupRoomCreationUploadProgress(operationID: command.operationID)
                    preparedOperations.insert(command.operationID)
                } else { throw V2RealtimeTransportError.unexpectedResponse }
                return .retryScheduled(command.operationID)
            }
            let uploadedMemberCount = command.uploadedMemberCount
            if uploadedMemberCount < command.initialMemberUserIDs.count {
                let end = min(uploadedMemberCount + V2GroupAudienceImportLimits.maximumMembersPerAppend, command.initialMemberUserIDs.count)
                let appended = try await transport.appendGroupRoomCreationMembers(
                    operationID: command.operationID,
                    memberUserIDs: Array(command.initialMemberUserIDs[uploadedMemberCount ..< end])
                )
                guard appended.operationID == command.operationID, appended.stagedMemberCount == end else {
                    throw V2RealtimeTransportError.unexpectedResponse
                }
                try await store.markGroupRoomCreationMembersUploaded(operationID: command.operationID, uploadedMemberCount: end)
                return .retryScheduled(command.operationID)
            }
            let created = try await transport.finalizeGroupRoomCreation(operationID: command.operationID)
            try Task.checkCancellation()
            guard created.title == command.title,
                  created.deliveryMode == command.deliveryMode,
                  created.memberCount >= command.initialMemberUserIDs.count + 1,
                  created.memberUserIDs.isEmpty
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markGroupRoomCreationAcknowledged(operationID: command.operationID, roomID: created.roomID)
            preparedOperations.remove(command.operationID)
            return .acknowledged(command.operationID, roomID: created.roomID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            preparedOperations.remove(command.operationID)
            if case .server(let code, _, _, _) = error, code == "NOT_FOUND" {
                try await store.scheduleGroupRoomCreationRetry(operationID: command.operationID, nextAttemptAt: now())
                return .retryScheduled(command.operationID)
            }
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
