import Foundation
import Testing
@testable import IMV2Core

struct ProfilePresentationBatchSelectionTests {
    @Test func contextsArePartitionedWithoutDroppingKeys() throws {
        let user = UserID(uuid: UUID())
        let roomKeys = (0..<16).flatMap { _ -> [V2ProfileViewLookupKey] in
            let room = RoomID(uuid: UUID())
            return [.init(userID: user, context: .room(room)), .init(userID: user, context: .groupJoinReview(room))]
        }
        let direct = (0..<64).map { _ in V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .directConversation) }
        let relationships = (0..<32).map { _ in V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship) }
        let all = roomKeys + direct + relationships
        var pending = all, delivered = Set<V2ProfileViewLookupKey>()
        while !pending.isEmpty {
            let selected = V2ProfilePresentationBatchRequest.selectKeys(from: pending, maximumKeys: 16)
            #expect(!selected.isEmpty)
            let request = try V2ProfilePresentationBatchRequest(keys: selected)
            #expect(request.keys.count <= 16)
            #expect(delivered.isDisjoint(with: selected))
            delivered.formUnion(selected)
            pending.removeAll { delivered.contains($0) }
        }
        #expect(delivered == Set(all))
        #expect(delivered.count == 128)
    }

    @Test func saturatedContextsStillAdmitRelationsAndEarlierRoomMembers() throws {
        let rooms = (0..<8).map { _ in RoomID(uuid: UUID()) }
        let first = rooms.map { V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .room($0)) }
        let blocked = V2ProfileViewLookupKey(userID: first[0].userID, context: .groupJoinReview(rooms[0]))
        let relation = V2ProfileViewLookupKey(userID: first[0].userID, context: .relationship)
        let member = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .room(rooms[0]))
        let selected = V2ProfilePresentationBatchRequest.selectKeys(from: first + [blocked, relation, member, first[0]])
        #expect(selected == first + [relation, member])
        _ = try V2ProfilePresentationBatchRequest(keys: selected)
        #expect(throws: V2ResourceValidationError.self) {
            try V2ProfilePresentationBatchRequest(keys: selected + [blocked])
        }
    }

    @Test func keyLimitAndEmptySelection() throws {
        let keys = (0..<128).map { _ in V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship) }
        #expect(V2ProfilePresentationBatchRequest.selectKeys(from: keys, maximumKeys: 0).isEmpty)
        #expect(V2ProfilePresentationBatchRequest.selectKeys(from: keys, maximumKeys: -1).isEmpty)
        #expect(V2ProfilePresentationBatchRequest.selectKeys(from: []).isEmpty)
        #expect(V2ProfilePresentationBatchRequest.selectKeys(from: keys, maximumKeys: 1) == Array(keys.prefix(1)))
        let selected = V2ProfilePresentationBatchRequest.selectKeys(from: keys, maximumKeys: Int.max)
        #expect(selected == Array(keys.prefix(100)))
        _ = try V2ProfilePresentationBatchRequest(keys: selected)
    }
}
