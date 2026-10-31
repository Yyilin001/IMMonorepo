import Foundation
import IMV2Core

/// Request-local hints from the exact display snapshots already written to the
/// recipient. Snapshot authority is never reused as profile authorization.
struct V2AuthorPresentationLatestVisibleAuthors: Sendable {
    let values: [(roomID: RoomID, userID: UserID)]

    init?(request: IMV2RoomLatestVisibleBatch, response: IMV2RoomLatestVisibleBatchResult,
          selectedRooms: Set<RoomID>) {
        guard (1...100).contains(request.roomIds.count), response.rooms.count == request.roomIds.count,
              selectedRooms.count <= V2AuthorPresentationStart.maximumMessageRooms else { return nil }
        let requested = request.roomIds.compactMap(UUID.init(uuidString:))
        let returned = response.rooms.compactMap { UUID(uuidString: $0.roomID) }
        guard requested.count == request.roomIds.count, returned.count == response.rooms.count,
              Set(requested).count == requested.count, Set(returned).count == returned.count,
              Set(requested) == Set(returned) else { return nil }
        var values: [(roomID: RoomID, userID: UserID)] = []
        for (item, id) in zip(response.rooms, returned) {
            let room = RoomID(uuid: id)
            guard selectedRooms.contains(room), case .snapshot(let wire) = item.result, wire.hasLatest,
                  let messageID = UUID(uuidString: wire.latest.messageID),
                  let senderID = UUID(uuidString: wire.latest.senderUserID),
                  let message = try? V2RoomLatestVisible.Message(id: .init(uuid: messageID), senderID: .init(uuid: senderID),
                    sequence: wire.latest.roomSequence, revision: wire.latest.messageRevision,
                    preview: wire.latest.preview, mediaCount: Int(wire.latest.mediaCount),
                    createdAt: Date(timeIntervalSince1970: Double(wire.latest.createdAtMs) / 1_000)),
                  (try? V2RoomLatestVisible(roomID: room, ownerEpoch: wire.ownerEpoch,
                    membershipRevision: wire.viewerMembershipRevision, head: wire.head, latest: message)) != nil
            else { continue }
            values.append((room, message.senderID))
        }
        self.values = values
    }
}
