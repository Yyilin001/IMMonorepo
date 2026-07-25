import IMV2Core
import Testing

@Suite("V2 group room creation contract")
struct GroupMessagingTests {
    @Test("canonicalizes the initial membership order")
    func canonicalizesMembers() throws {
        let actor = try UserID("00000000-0000-0000-0000-000000000901")
        let later = try UserID("00000000-0000-0000-0000-000000000903")
        let earlier = try UserID("00000000-0000-0000-0000-000000000902")
        let command = try V2CreateGroupRoomCommand(
            actorUserID: actor,
            operationID: .init("00000000-0000-0000-0000-000000000904"),
            title: "  项目群  ",
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
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: " \n", initialMemberUserIDs: [])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidTitle) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: String(repeating: "a", count: 121), initialMemberUserIDs: [])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidInitialMembers) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: "群", initialMemberUserIDs: [other, other])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidInitialMembers) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: "群", initialMemberUserIDs: [actor])
        }
    }
}
