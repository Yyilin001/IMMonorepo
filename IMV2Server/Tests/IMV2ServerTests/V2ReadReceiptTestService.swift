import Foundation
import IMV2Core
@testable import IMV2ServerContracts

/// Gateway unit fixtures construct domain commands without a live Actor Host.
/// Production receipts use V2RoomRefReadReceiptClient and its activation executor.
struct V2ReadReceiptTestService: V2GatewayReadReceiptHandling {
    let store: any V2ReadReceiptStore
    let now: @Sendable () -> Date

    init(store: any V2ReadReceiptStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome {
        let command = try V2RecordReadReceiptCommand(roomID: request.roomID,
            actorUserID: request.actorUserID, operationID: request.operationID,
            readThroughRoomSequence: request.readThroughRoomSequence)
        return try await store.record(command: command, now: now())
    }

    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID,
                 cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        try await store.readers(roomID: roomID, messageID: messageID,
            actorUserID: actorUserID, cursor: cursor, pageSize: pageSize)
    }
}
