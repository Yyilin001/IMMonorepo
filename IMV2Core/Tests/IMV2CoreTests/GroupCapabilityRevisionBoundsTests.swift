import IMV2Core
import Testing

struct GroupCapabilityRevisionBoundsTests {
    @Test(arguments: [UInt64(Int64.max) + 1, UInt64.max])
    func rejectsUnpersistableRevision(_ revision: UInt64) throws {
        #expect(throws: V2RevisionValidationError.outOfRange) {
            try V2GroupAnnouncementCommand(operationID: .init("announcement"), roomID: .init("room"),
                body: "Announcement", expectedRevision: revision)
        }
        #expect(throws: V2RevisionValidationError.outOfRange) {
            try V2GroupRolePermissionsCommand(operationID: .init("permissions"), roomID: .init("room"),
                role: .member, permissions: [], expectedRevision: revision)
        }
        #expect(throws: V2RevisionValidationError.outOfRange) {
            try V2GroupMemberRoleCommand(operationID: .init("role"), roomID: .init("room"),
                targetUserID: .init("member"), role: .admin, expectedMembershipRevision: revision)
        }
    }

    @Test(arguments: [UInt64(1), UInt64(Int64.max)])
    func preservesPositiveRevision(_ revision: UInt64) throws {
        #expect(try V2GroupAnnouncementCommand(operationID: .init("announcement"), roomID: .init("room"),
            body: "Announcement", expectedRevision: revision).expectedRevision == revision)
        #expect(try V2GroupRolePermissionsCommand(operationID: .init("permissions"), roomID: .init("room"),
            role: .member, permissions: [], expectedRevision: revision).expectedRevision == revision)
        #expect(try V2GroupMemberRoleCommand(operationID: .init("role"), roomID: .init("room"),
            targetUserID: .init("member"), role: .admin, expectedMembershipRevision: revision).expectedMembershipRevision == revision)
    }

    @Test("zero retains its distinct announcement and role fence semantics")
    func preservesZeroRevisionRules() throws {
        #expect(try V2GroupAnnouncementCommand(operationID: .init("announcement"), roomID: .init("room"),
            body: "First announcement", expectedRevision: 0).expectedRevision == 0)
        #expect(throws: V2CoreError.invalidPositiveValue) {
            try V2GroupRolePermissionsCommand(operationID: .init("permissions"), roomID: .init("room"),
                role: .member, permissions: [], expectedRevision: 0)
        }
        #expect(throws: V2CoreError.invalidPositiveValue) {
            try V2GroupMemberRoleCommand(operationID: .init("role"), roomID: .init("room"),
                targetUserID: .init("member"), role: .admin, expectedMembershipRevision: 0)
        }
    }
}
