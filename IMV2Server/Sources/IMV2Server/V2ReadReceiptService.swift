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

/// The original receipt-store seam remains useful for focused watermark
/// tests. Production storage implements these v10 operations; old in-memory
/// fakes fail closed if a caller attempts the richer surface.
public extension V2ReadReceiptStore {
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) async throws -> V2SetReadReceiptPreferencesOutcome {
        _ = command; _ = now
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }

    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        _ = roomID; _ = messageID; _ = actorUserID; _ = cursor; _ = pageSize
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }
}

public struct V2ReadReceiptService: Sendable {
    private let store: any V2ReadReceiptStore; private let now: @Sendable () -> Date
    public init(store: any V2ReadReceiptStore, now: @escaping @Sendable () -> Date = Date.init) { self.store = store; self.now = now }
    public func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome {
        try await store.record(command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, readThroughRoomSequence: request.readThroughRoomSequence), now: now())
    }

    public func setPreferences(actorUserID: UserID, operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2SetReadReceiptPreferencesOutcome {
        try await store.setPreferences(command: .init(actorUserID: actorUserID, operationID: operationID, allowsDirectReadReceipts: allowsDirectReadReceipts, allowsGroupReadReceipts: allowsGroupReadReceipts), now: now())
    }

    public func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        try await store.readers(roomID: roomID, messageID: messageID, actorUserID: actorUserID, cursor: cursor, pageSize: pageSize)
    }
}

public enum V2ReadReceiptStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotMember
    case membershipRevisionConflict(currentRevision: UInt64)
    case roomSequenceNotFound
    case invalidRequest
    case corruptPersistenceState
}
