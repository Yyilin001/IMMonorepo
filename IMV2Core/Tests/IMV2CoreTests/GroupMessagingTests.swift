import IMV2Core
import Testing

@Suite("V2 group room creation contract")
struct GroupMessagingTests {
    @Test("the group delivery boundary is deterministic and inclusive")
    func deliveryModeBoundary() {
        let policy = V2GroupDeliveryPolicy()
        #expect(policy.deliveryMode(forInitialMemberCount: 5_000) == .standardFanout)
        #expect(policy.deliveryMode(forInitialMemberCount: 5_001) == .largeGroupHybrid)
        #expect(policy.acceptsInitialMemberCount(5_000, mode: .standardFanout))
        #expect(!policy.acceptsInitialMemberCount(5_000, mode: .largeGroupHybrid))
        #expect(!policy.acceptsInitialMemberCount(5_001, mode: .standardFanout))
    }

    @Test("canonicalizes the initial membership order")
    func canonicalizesMembers() throws {
        let actor = try UserID("00000000-0000-0000-0000-000000000901")
        let later = try UserID("00000000-0000-0000-0000-000000000903")
        let earlier = try UserID("00000000-0000-0000-0000-000000000902")
        let command = try V2CreateGroupRoomCommand(
            actorUserID: actor,
            operationID: .init("00000000-0000-0000-0000-000000000904"),
            title: "  项目群  ",
            deliveryMode: .standardFanout,
            initialMemberUserIDs: [later, earlier]
        )

        #expect(command.title == "项目群")
        #expect(command.initialMemberUserIDs == [earlier, later])
        #expect(command.allMemberUserIDs == [actor, earlier, later])
    }

    @Test("rejects blank, oversized, duplicate, and owner initial members")
    func rejectsInvalidInput() throws {
        let actor = try UserID("00000000-0000-0000-0000-000000000905")
        let other = try UserID("00000000-0000-0000-0000-000000000906")
        let operation = try GroupRoomOperationID("00000000-0000-0000-0000-000000000907")

        #expect(throws: V2GroupMessagingValidationError.invalidTitle) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: " \n", deliveryMode: .standardFanout, initialMemberUserIDs: [])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidTitle) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: String(repeating: "a", count: 121), deliveryMode: .standardFanout, initialMemberUserIDs: [])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidInitialMembers) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: "群", deliveryMode: .standardFanout, initialMemberUserIDs: [other, other])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidInitialMembers) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: "群", deliveryMode: .standardFanout, initialMemberUserIDs: [actor])
        }
    }
}
