import Foundation
import IMV2Core

public struct V2AuthenticatedReadReceipt: Sendable {
    public let roomID: RoomID; public let actorUserID: UserID; public let operationID: ReadReceiptOperationID; public let readThroughRoomSequence: UInt64
    public init(roomID: RoomID, actorUserID: UserID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) { self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID; self.readThroughRoomSequence = readThroughRoomSequence }
}

public enum V2ReadReceiptOutcome: Equatable, Sendable { case recorded(V2ReadReceipt), idempotent(V2ReadReceipt), idempotencyConflict }

public protocol V2ReadReceiptStore: Sendable {
    func record(command: V2RecordReadReceiptCommand, now: Date) async throws -> V2ReadReceiptOutcome
}

public struct V2ReadReceiptService: Sendable {
    private let store: any V2ReadReceiptStore; private let now: @Sendable () -> Date
    public init(store: any V2ReadReceiptStore, now: @escaping @Sendable () -> Date = Date.init) { self.store = store; self.now = now }
    public func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome {
        try await store.record(command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, readThroughRoomSequence: request.readThroughRoomSequence), now: now())
    }
}

public enum V2ReadReceiptStoreError: Error, Equatable, Sendable { case roomNotFound, actorNotMember, roomSequenceNotFound, corruptPersistenceState }
