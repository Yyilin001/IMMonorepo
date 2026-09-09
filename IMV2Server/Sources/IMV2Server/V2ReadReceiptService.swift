import Foundation
import IMV2Core

public struct V2AuthenticatedReadReceipt: Sendable {
    public let roomID: RoomID; public let actorUserID: UserID; public let operationID: ReadReceiptOperationID; public let readThroughRoomSequence: UInt64
    public init(roomID: RoomID, actorUserID: UserID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) { self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID; self.readThroughRoomSequence = readThroughRoomSequence }
}

public enum V2ReadReceiptOutcome: Equatable, Sendable { case recorded(V2ReadReceipt), idempotent(V2ReadReceipt), idempotencyConflict }

public enum V2SetReadReceiptPreferencesOutcome: Equatable, Sendable {
    case updated(V2ReadReceiptPreferences)
    case idempotent(V2ReadReceiptPreferences)
    case idempotencyConflict
}

public protocol V2ReadReceiptStore: Sendable {
    func record(command: V2RecordReadReceiptCommand, now: Date) async throws -> V2ReadReceiptOutcome
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) async throws -> V2SetReadReceiptPreferencesOutcome
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage
}

/// Immutable input retained by the process-local receipt micro-batcher.
/// The timestamp is captured when the command crosses the domain boundary,
/// not when a delayed batch happens to reach PostgreSQL.
public struct V2ReadReceiptRecordRequest: Sendable {
    public let command: V2RecordReadReceiptCommand
    public let now: Date

    public init(command: V2RecordReadReceiptCommand, now: Date) {
        self.command = command
        self.now = now
    }
}

/// A domain rejection belongs to one command and must not roll back unrelated
/// receipts in the same physical transaction. Infrastructure failures still
/// throw from the batch call and fail every retained continuation.
public enum V2ReadReceiptRecordResult: Equatable, Sendable {
    case success(V2ReadReceiptOutcome)
    case failure(V2ReadReceiptStoreError)
}

public protocol V2ReadReceiptBatchStore: V2ReadReceiptStore {
    func recordBatch(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2ReadReceiptRecordResult]
}

/// Room-owned subset of read-receipt persistence. Group cursors belong beside
/// the room sequence and membership history they validate; keeping this
/// capability separate prevents a routed store from accidentally moving
/// user-owned preference writes to a room database.
public protocol V2GroupReadReceiptRecordingStore: Sendable {
    func recordGroup(
        command: V2RecordReadReceiptCommand,
        now: Date
    ) async throws -> V2GroupReadReceiptRecordingAttempt
}

public enum V2GroupReadReceiptBatchResult: Equatable, Sendable {
    case success(V2GroupReadReceiptRecordingAttempt)
    case failure(V2ReadReceiptStoreError)
}

public protocol V2GroupReadReceiptBatchRecordingStore:
    V2GroupReadReceiptRecordingStore
{
    func recordGroups(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2GroupReadReceiptBatchResult]
}

public extension V2GroupReadReceiptBatchRecordingStore {
    func recordGroups(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2GroupReadReceiptBatchResult] {
        var results: [V2GroupReadReceiptBatchResult] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            do {
                results.append(.success(try await recordGroup(
                    command: request.command,
                    now: request.now
                )))
            } catch let error as V2ReadReceiptStoreError {
                results.append(.failure(error))
            }
        }
        return results
    }
}

public enum V2GroupReadReceiptRecordingAttempt: Equatable, Sendable {
    case handled(V2ReadReceiptOutcome)
    /// The selected physical owner contains a direct room. The caller must
    /// execute the existing direct-receipt path so reciprocal projection and
    /// both users' privacy preferences remain authoritative.
    case notGroup
}

public struct V2GroupReadReceiptReaderCandidate: Equatable, Sendable {
    public let userID: UserID
    public let readThroughRoomSequence: UInt64

    public init(userID: UserID, readThroughRoomSequence: UInt64) {
        self.userID = userID
        self.readThroughRoomSequence = readThroughRoomSequence
    }
}

public struct V2GroupReadReceiptReaderCandidatePage: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let candidates: [V2GroupReadReceiptReaderCandidate]
    public let nextCursor: String?

    public init(
        roomID: RoomID,
        messageID: MessageID,
        candidates: [V2GroupReadReceiptReaderCandidate],
        nextCursor: String?
    ) {
        self.roomID = roomID
        self.messageID = messageID
        self.candidates = candidates
        self.nextCursor = nextCursor
    }
}

/// Room-local reader candidates contain no global identity or privacy facts.
public protocol V2GroupReadReceiptReaderCandidateStore: Sendable {
    func readerCandidates(
        roomID: RoomID,
        messageID: MessageID,
        actorUserID: UserID,
        cursor: String?,
        pageSize: Int
    ) async throws -> V2GroupReadReceiptReaderCandidatePage
}

/// Resolves disclosure at the authoritative user/control database. Missing,
/// disabled, inactive, or opted-out users are omitted rather than defaulted.
public protocol V2ReadReceiptReaderVisibilityStore: Sendable {
    func visibleReaderIdentities(
        actorUserID: UserID,
        candidateUserIDs: [UserID]
    ) async throws -> [UserID: V2PublicIdentity]
}

public protocol V2GroupReadReceiptOwnerStore:
    V2GroupReadReceiptBatchRecordingStore,
    V2GroupReadReceiptReaderCandidateStore {}

public protocol V2ReadReceiptControlStore:
    V2ReadReceiptStore,
    V2ReadReceiptReaderVisibilityStore {}

public struct V2ReadReceiptService: Sendable {
    private let store: any V2ReadReceiptStore
    private let batcher: (any V2ReadReceiptAdmission)?
    private let now: @Sendable () -> Date

    var managesForegroundWriteAdmission: Bool {
        batcher?.managesForegroundWriteAdmission ?? false
    }

    public init(
        store: any V2ReadReceiptStore,
        batcher: (any V2ReadReceiptAdmission)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.batcher = batcher
        self.now = now
    }
    public func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome {
        let prepared = V2ReadReceiptRecordRequest(
            command: try .init(
                roomID: request.roomID,
                actorUserID: request.actorUserID,
                operationID: request.operationID,
                readThroughRoomSequence: request.readThroughRoomSequence
            ),
            now: now()
        )
        if let batcher { return try await batcher.accept(prepared) }
        return try await store.record(
            command: prepared.command,
            now: prepared.now
        )
    }

    public func setPreferences(actorUserID: UserID, operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2SetReadReceiptPreferencesOutcome {
        try await store.setPreferences(command: .init(actorUserID: actorUserID, operationID: operationID, allowsDirectReadReceipts: allowsDirectReadReceipts, allowsGroupReadReceipts: allowsGroupReadReceipts), now: now())
    }

    public func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        try await store.readers(roomID: roomID, messageID: messageID, actorUserID: actorUserID, cursor: cursor, pageSize: pageSize)
    }
}

public enum V2ReadReceiptStoreError: Error, Equatable, Sendable {
    case ownerChanged
    case roomNotFound
    case messageNotFound
    case actorNotMember
    case roomSequenceNotFound
    case invalidRequest
    case corruptPersistenceState
}
