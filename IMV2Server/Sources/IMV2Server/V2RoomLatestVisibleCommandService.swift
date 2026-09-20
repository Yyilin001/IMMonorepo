import Foundation
import IMV2Core
import SwiftProtobuf

/// Bounds the serialized envelope, including explicit deferred results.
public struct V2RoomLatestVisibleCommandService: Sendable {
    private let reader: any V2RoomLatestVisibleReading
    private let maximumResponseBytes: Int

    public init(reader: any V2RoomLatestVisibleReading, maximumResponseBytes: Int = 48 * 1024) throws {
        guard (8192...(48 * 1024)).contains(maximumResponseBytes) else { throw V2RoomRecoveryReadError.invalidRequest }
        self.reader = reader; self.maximumResponseBytes = maximumResponseBytes
    }

    public func batch(_ request: IMV2RoomLatestVisibleBatch, actorUserID: UserID) async throws -> IMV2Envelope {
        guard actorUserID.uuidValue != nil, !request.roomIds.isEmpty, request.roomIds.count <= 100 else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        let ids = try request.roomIds.map { raw -> RoomID in
            guard let uuid = UUID(uuidString: raw) else { throw V2RoomRecoveryReadError.invalidRequest }
            return .init(uuid: uuid)
        }
        guard Set(ids).count == ids.count else { throw V2RoomRecoveryReadError.invalidRequest }
        let values = try await reader.latestVisible(roomIDs: ids, actorUserID: actorUserID)
        try Task.checkCancellation()
        guard Set(values.keys) == Set(ids) else { throw V2RoomRecoveryReadError.corruptPersistence }
        var response = IMV2Envelope()
        response.roomLatestVisibleBatchResult.rooms = ids.map { id in
            var item = IMV2RoomLatestVisibleResult()
            item.roomID = id.rawValue; item.retry.retryAfterSeconds = 1
            return item
        }
        guard try response.serializedData().count <= maximumResponseBytes else { throw V2RoomRecoveryReadError.invalidRequest }
        for (index, id) in ids.enumerated() {
            try Task.checkCancellation()
            var item = response.roomLatestVisibleBatchResult.rooms[index]
            switch values[id]! {
            case .retry: continue
            case .unavailable: item.unavailable = .init()
            case .snapshot(let snapshot):
                guard snapshot.roomID == id else { throw V2RoomRecoveryReadError.corruptPersistence }
                var wire = IMV2RoomLatestVisibleSnapshot()
                wire.ownerEpoch = snapshot.ownerEpoch; wire.viewerMembershipRevision = snapshot.membershipRevision
                wire.head = snapshot.head
                if let message = snapshot.latest {
                    let milliseconds = (message.createdAt.timeIntervalSince1970 * 1000).rounded(.down)
                    guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max),
                          message.mediaCount <= Int(UInt32.max) else { throw V2RoomRecoveryReadError.corruptPersistence }
                    wire.latest.messageID = message.id.rawValue; wire.latest.senderUserID = message.senderID.rawValue
                    wire.latest.roomSequence = message.sequence; wire.latest.messageRevision = message.revision
                    wire.latest.preview = message.preview; wire.latest.mediaCount = UInt32(message.mediaCount)
                    wire.latest.createdAtMs = Int64(milliseconds)
                }
                item.snapshot = wire
            }
            let previous = response.roomLatestVisibleBatchResult.rooms[index]
            response.roomLatestVisibleBatchResult.rooms[index] = item
            if try response.serializedData().count > maximumResponseBytes {
                response.roomLatestVisibleBatchResult.rooms[index] = previous
            }
        }
        return response
    }
}
