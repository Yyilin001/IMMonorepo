import IMV2Core
import Testing

@Suite("V2 group room creation contract")
struct GroupMessagingTests {
    @Test("group capacity boundaries are deterministic and inclusive")
    func capacityClassBoundary() {
        let policy = V2GroupCapacityPolicy()
        #expect(V2GroupCapacityClass(rawValue: "standard") == .standard)
        #expect(V2GroupCapacityClass(rawValue: "large") == .large)
        #expect(V2GroupCapacityClass(rawValue: "standard_fanout") == nil)
        #expect(V2GroupCapacityClass(rawValue: "large_group_hybrid") == nil)
        #expect(policy.capacityClass(forInitialMemberCount: 0) == nil)
        #expect(policy.capacityClass(forInitialMemberCount: 100_000) == .large)
        #expect(policy.capacityClass(forInitialMemberCount: 100_001) == nil)
        #expect(policy.capacityClass(forInitialMemberCount: 5_000) == .standard)
        #expect(policy.capacityClass(forInitialMemberCount: 5_001) == .large)
        #expect(policy.acceptsInitialMemberCount(5_000, mode: .standard))
        #expect(!policy.acceptsInitialMemberCount(5_000, mode: .large))
        #expect(!policy.acceptsInitialMemberCount(5_001, mode: .standard))
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
            capacityClass: .standard,
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
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: " \n", capacityClass: .standard, initialMemberUserIDs: [])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidTitle) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: String(repeating: "a", count: 121), capacityClass: .standard, initialMemberUserIDs: [])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidInitialMembers) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: "群", capacityClass: .standard, initialMemberUserIDs: [other, other])
        }
        #expect(throws: V2GroupMessagingValidationError.invalidInitialMembers) {
            try V2CreateGroupRoomCommand(actorUserID: actor, operationID: operation, title: "群", capacityClass: .standard, initialMemberUserIDs: [actor])
        }
    }
}
