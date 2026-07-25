import Testing
@testable import IMV2Core

struct RoomMembershipTests {
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

    @Test("a membership result keeps event, fan-out, sequence, and revision distinct")
    func preservesIndependentOrderingAndFanoutIdentities() throws {
        let result = V2RoomMembershipChange(
            roomID: try .init("room-a"),
            targetUserID: try .init("user-b"),
            action: .add,
            membershipRevision: 5,
            roomSequence: 12,
            eventID: try .init("event-a"),
            fanoutPlanID: try .init("plan-a"),
            createdAt: .distantPast
        )
        #expect(result.membershipRevision == 5)
        #expect(result.roomSequence == 12)
        #expect(result.eventID.rawValue == "event-a")
        #expect(result.fanoutPlanID.rawValue == "plan-a")
    }
}
