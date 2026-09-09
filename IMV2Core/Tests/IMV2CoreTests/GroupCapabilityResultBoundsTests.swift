import IMV2Core
import Testing

struct GroupCapabilityResultBoundsTests {
    @Test(arguments: ["pinSequence", "announcementRevision", "announcementSequence", "permissionsRevision", "permissionsSequence", "roleRevision", "roleSequence"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func persistenceBounds(field: String, value: UInt64) throws {
        let revision: UInt64 = field.hasSuffix("Revision") ? value : 1
        let sequence: UInt64 = field.hasSuffix("Sequence") ? value : 1
        func resultValue() throws -> UInt64 {
            switch field {
            case "pinSequence":
                return try V2PinnedMessage(roomID: .init("room"), messageID: .init("message"), isPinned: true, roomSequence: sequence, updatedAt: .distantPast).roomSequence
            case "announcementRevision", "announcementSequence":
                let result = try V2GroupAnnouncement(roomID: .init("room"), body: "notice", revision: revision, roomSequence: sequence, updatedAt: .distantPast)
                return field.hasSuffix("Revision") ? result.revision : result.roomSequence
            case "permissionsRevision", "permissionsSequence":
                let result = try V2GroupRolePermissionsChange(roomID: .init("room"), role: .member, permissions: [], revision: revision, roomSequence: sequence)
                return field.hasSuffix("Revision") ? result.revision : result.roomSequence
            default:
                let result = try V2GroupMemberRoleChange(roomID: .init("room"), targetUserID: .init("user"), role: .admin, membershipRevision: revision, roomSequence: sequence)
                return field.hasSuffix("Revision") ? result.membershipRevision : result.roomSequence
            }
        }
        if value == 0 || value > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try resultValue() }
        } else {
            #expect(try resultValue() == value)
        }
    }
}
