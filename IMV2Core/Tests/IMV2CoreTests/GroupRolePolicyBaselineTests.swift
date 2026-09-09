import IMV2Core
import Testing

@Suite("V2 group role policy baseline")
struct GroupRolePolicyBaselineTests {
    @Test("complete effective policies preserve explicit empty sets and zero room sequence")
    func emptyPolicy() throws {
        let baseline = try V2GroupRolePolicyBaseline(roomID: .init("00000000-0000-0000-0000-000000ABCDEF"), permissionRevision: 1, membershipRevision: 0, roomSequence: 0, adminPermissions: [.inviteMembers], memberPermissions: [])
        #expect(baseline.memberPermissions.isEmpty)
        #expect(baseline.adminPermissions == [.inviteMembers])
        #expect(baseline.roomSequence == 0)
        #expect(baseline.membershipRevision == 0)
    }

    @Test("baseline fences fit persistence and identify a real room")
    func versionBounds() throws {
        let room = try RoomID("00000000-0000-0000-0000-000000ABCDEF")
        let invalid: [(UInt64, UInt64, UInt64, V2CoreError)] = [(0, 0, 0, .invalidPositiveValue), (.max, 0, 0, .invalidPositiveValue), (1, .max, 0, .invalidNonNegativeValue), (1, 0, .max, .invalidNonNegativeValue)]
        for (permission, membership, sequence, error) in invalid {
            #expect(throws: error) {
                try V2GroupRolePolicyBaseline(roomID: room, permissionRevision: permission, membershipRevision: membership, roomSequence: sequence, adminPermissions: [], memberPermissions: [])
            }
        }
        #expect(throws: V2CoreError.invalidIdentifier) {
            try V2GroupRolePolicyBaseline(roomID: .init("invalid"), permissionRevision: 1, membershipRevision: 1, roomSequence: 0, adminPermissions: [], memberPermissions: [])
        }
    }
}
