import Foundation
@testable import IMV2Core
import Testing

@Suite("Versioned latest visible snapshots")
struct RoomLatestVisibleTests {
    @Test func rejectsCandidateBeyondObservedHead() throws {
        let message = try V2RoomLatestVisible.Message(id: .init(uuid: UUID()), senderID: .init(uuid: UUID()),
            sequence: 8, revision: 2, preview: "edited", mediaCount: 0, createdAt: .now)
        #expect(throws: V2RoomSynchronizationError.invalidState) {
            try V2RoomLatestVisible(roomID: .init(uuid: UUID()), ownerEpoch: 1, membershipRevision: 1, head: 7, latest: message)
        }
        let empty = try V2RoomLatestVisible(roomID: .init(uuid: UUID()), ownerEpoch: 1, membershipRevision: 1, head: 8, latest: nil)
        #expect(empty.latest == nil && empty.head == 8)
    }

    @Test(arguments: [0, 1, 2, 3])
    func rejectsInvalidCandidate(field: Int) {
        #expect(throws: V2RoomSynchronizationError.invalidState) {
            try V2RoomLatestVisible.Message(id: .init(uuid: UUID()), senderID: .init(uuid: UUID()),
                sequence: field == 0 ? 0 : 1, revision: field == 1 ? 0 : 1,
                preview: field == 2 ? String(repeating: "😀", count: 129) : "preview",
                mediaCount: field == 3 ? -1 : 0, createdAt: .now)
        }
    }
}
