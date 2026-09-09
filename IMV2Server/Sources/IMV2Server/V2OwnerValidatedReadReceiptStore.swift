import Foundation
import IMV2Core

/// Each row retains its route even when a batch shares one physical owner.
public struct V2OwnerValidatedReadReceiptRequest: Sendable {
    public let request: V2ReadReceiptRecordRequest
    public let ownerRoute: V2RoomShardRoute
    public init(request: V2ReadReceiptRecordRequest, ownerRoute: V2RoomShardRoute) {
        self.request = request; self.ownerRoute = ownerRoute
    }
}

public protocol V2OwnerValidatedReadReceiptStore: Sendable {
    func recordGroupOwnerValidated(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute, now: Date) async throws -> V2GroupReadReceiptRecordingAttempt
    func recordGroupsOwnerValidated(_ requests: [V2OwnerValidatedReadReceiptRequest]) async throws -> [V2GroupReadReceiptBatchResult]
    func readerCandidatesOwnerValidated(roomID: RoomID, messageID: MessageID, actorUserID: UserID, ownerRoute: V2RoomShardRoute, cursor: String?, pageSize: Int) async throws -> V2GroupReadReceiptReaderCandidatePage
}
