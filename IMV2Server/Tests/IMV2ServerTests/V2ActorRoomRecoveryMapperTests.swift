@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Room recovery domain mapping")
struct V2ActorRoomRecoveryMapperTests {
    @Test("full room state and latest-visible snapshots preserve zero epoch and each sequence")
    func fullFields() throws {
        let room = try RoomID("room-1")
        let unavailable = try RoomID("room-2")
        let retry = try RoomID("room-3")
        let ids = [room, unavailable, retry]
        let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 0,
            viewerMembershipRevision: 3, head: 21, trimmedThrough: 2,
            readThrough: 7, latestOwnMessageSequence: 11)
        let states: [RoomID: V2RoomStateReadResult] = [
            room: .state(state), unavailable: .unavailable, retry: .retry,
        ]
        let stateWire = try V2ActorRoomStateBatchWire(states, requestedRoomIDs: ids)
        let stateDecoded = try JSONDecoder().decode(V2ActorRoomStateBatchWire.self,
            from: JSONEncoder().encode(stateWire))
        #expect(try stateDecoded.domainValue(expectedRoomIDs: ids) == states)
        #expect(state.unreadCount == 10)

        let message = try V2RoomLatestVisible.Message(id: MessageID("message-1"),
            senderID: UserID("user-1"), sequence: 19, revision: 4,
            preview: "preview", mediaCount: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let latest = try V2RoomLatestVisible(roomID: room, ownerEpoch: 0,
            membershipRevision: 3, head: 21, latest: message)
        let values: [RoomID: V2RoomLatestVisibleResult] = [
            room: .snapshot(latest), unavailable: .unavailable, retry: .retry,
        ]
        let wire = try V2ActorRoomLatestVisibleBatchWire(values, requestedRoomIDs: ids)
        let decoded = try JSONDecoder().decode(V2ActorRoomLatestVisibleBatchWire.self,
            from: JSONEncoder().encode(wire))
        #expect(try decoded.domainValue(expectedRoomIDs: ids) == values)
    }

    @Test("per-room result identity and domain guards reject malicious snapshots")
    func invalid() throws {
        let room = try RoomID("room-1")
        let other = try RoomID("room-2")
        let mismatched = V2ActorRoomStateBatchWire(items: [
            .init(roomID: room, result: .state(.init(roomID: other, ownerEpoch: 0,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0,
                readThrough: 0, latestOwnMessageSequence: 0)))])
        #expect(throws: V2ActorRoomRecoveryWireError.invalidResult) {
            try mismatched.domainValue(expectedRoomIDs: [room])
        }
        let missing = V2ActorRoomStateBatchWire(items: [.init(roomID: room, result: .unavailable)])
        #expect(throws: V2ActorRoomRecoveryWireError.invalidResult) {
            try missing.domainValue(expectedRoomIDs: [room, other])
        }
        let badState = V2ActorRoomSynchronizationStateWire(roomID: room, ownerEpoch: 0,
            viewerMembershipRevision: 1, head: 2, trimmedThrough: 3,
            readThrough: 0, latestOwnMessageSequence: 0)
        #expect(throws: V2RoomSynchronizationError.invalidState) { try badState.domainValue() }
        let badLatest = V2ActorRoomLatestVisibleWire(roomID: room, ownerEpoch: 0,
            membershipRevision: 1, head: 1,
            latest: .init(id: try MessageID("message-1"), senderID: try UserID("user-1"),
                          sequence: 2, revision: 1, preview: "x", mediaCount: 0,
                          createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(throws: V2RoomSynchronizationError.invalidState) { try badLatest.domainValue() }
        let overEpoch = V2ActorRoomSynchronizationStateWire(roomID: room,
            ownerEpoch: UInt64(Int64.max) + 1, viewerMembershipRevision: 1,
            head: 0, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        #expect(throws: V2RoomSynchronizationError.invalidState) { try overEpoch.domainValue() }
    }
}

@Suite("Room recovery error mapping")
struct V2ActorRoomRecoveryErrorMapperTests {
    @Test("cursor and topology failures retain their exact domain reason")
    func failures() throws {
        for error in [V2RoomRecoveryReadError.invalidRequest, .corruptPersistence,
                      .invalidCursor, .topologyChanged] {
            let wire = V2ActorRoomRecoveryReadErrorWire(error)
            #expect(wire.domainValue() == error)
            #expect(try JSONDecoder().decode(V2RoomRecoveryResult.self,
                from: JSONEncoder().encode(V2RoomRecoveryResult.failure(wire))) == .failure(wire))
        }
    }
}
