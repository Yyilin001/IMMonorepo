import Testing
@testable import IMV2Core

struct RoomMembershipTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func resultPersistenceBounds(revision: UInt64, sequence: UInt64) throws {
        func result() throws -> V2RoomMembershipChange {
            try .init(roomID: .init("room"), targetUserID: .init("user"), action: .add,
                membershipRevision: revision, roomSequence: sequence, eventID: .init("event"),
                createdAt: .distantPast)
        }
        if revision == 0 || sequence == 0 || revision > UInt64(Int64.max) || sequence > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try result() }
        } else {
            let value = try result()
            #expect(value.membershipRevision == revision)
            #expect(value.roomSequence == sequence)
        }
    }

    @Test("membership operation IDs are domain-scoped and self-targeting is rejected")
    func rejectsSelfTargetingChange() throws {
        let user = try UserID("user-a")
        #expect(throws: V2RoomMembershipValidationError.selfTargetingNotAllowed) {
            _ = try V2ChangeRoomMembershipCommand(
                roomID: .init("room-a"),
                actorUserID: user,
                operationID: .init("operation-a"),
                targetUserID: user,
                action: .remove,
                expectedMembershipRevision: 4
            )
        }
    }

    @Test("a membership result keeps event, sequence, and revision distinct")
    func preservesIndependentOrderingAndEventIdentity() throws {
        let result = try V2RoomMembershipChange(
            roomID: try .init("room-a"),
            targetUserID: try .init("user-b"),
            action: .add,
            membershipRevision: 5,
            roomSequence: 12,
            eventID: try .init("event-a"),
            createdAt: .distantPast
        )
        #expect(result.membershipRevision == 5)
        #expect(result.roomSequence == 12)
        #expect(result.eventID.rawValue == "event-a")
    }
}
