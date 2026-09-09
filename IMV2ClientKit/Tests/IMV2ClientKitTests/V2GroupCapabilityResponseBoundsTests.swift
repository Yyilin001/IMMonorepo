import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2GroupCapabilityResponseBoundsTests {
    @Test(arguments: ["pinSequence", "announcementRevision", "announcementSequence", "permissionsRevision", "permissionsSequence", "roleRevision", "roleSequence"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func responseBounds(kind: String, value: UInt64) async throws {
        let transport = V2ProtobufSyncTransport(wire: CapabilityBoundsWire(kind: kind, value: value), protocolVersion: 1)
        let room = RoomID(uuid: UUID())
        let expected: UInt64 = kind.hasSuffix("Revision") && value > 1 && value <= UInt64(Int64.max) ? value - 1 : 1
        func resultValue() async throws -> UInt64 {
            switch kind {
            case "pinSequence":
                return try await transport.setPinnedMessage(command: .init(operationID: .init(uuid: UUID()), roomID: room, messageID: .init(uuid: UUID()), isPinned: true)).roomSequence
            case "announcementRevision", "announcementSequence":
                let result = try await transport.setGroupAnnouncement(command: .init(operationID: .init(uuid: UUID()), roomID: room, body: "notice", expectedRevision: kind == "announcementRevision" && value == 1 ? 0 : expected))
                return kind.hasSuffix("Revision") ? result.revision : result.roomSequence
            case "permissionsRevision", "permissionsSequence":
                let result = try await transport.setGroupRolePermissions(command: .init(operationID: .init(uuid: UUID()), roomID: room, role: .member, permissions: [], expectedRevision: expected))
                return kind.hasSuffix("Revision") ? result.revision : result.roomSequence
            default:
                let result = try await transport.changeGroupMemberRole(command: .init(operationID: .init(uuid: UUID()), roomID: room, targetUserID: .init(uuid: UUID()), role: .admin, expectedMembershipRevision: expected))
                return kind.hasSuffix("Revision") ? result.membershipRevision : result.roomSequence
            }
        }
        if value == 0 || value > UInt64(Int64.max) || (value == 1 && ["permissionsRevision", "roleRevision"].contains(kind)) {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { _ = try await resultValue() }
        } else {
            #expect(try await resultValue() == value)
        }
    }

    @Test(arguments: ["announcementRevision", "permissionsRevision", "roleRevision"],
          [UInt64(1), UInt64(Int64.max) - 1, UInt64(Int64.max)])
    func committedRevision(kind: String, expected: UInt64) async throws {
        let room = RoomID(uuid: UUID())
        for returned in [expected - 1, expected, expected + 1, expected + 2] {
            let transport = V2ProtobufSyncTransport(wire: CapabilityBoundsWire(kind: kind, value: returned), protocolVersion: 1)
            func result() async throws -> UInt64 {
                switch kind {
                case "announcementRevision":
                    return try await transport.setGroupAnnouncement(command: .init(operationID: .init(uuid: UUID()), roomID: room, body: "notice", expectedRevision: expected)).revision
                case "permissionsRevision":
                    return try await transport.setGroupRolePermissions(command: .init(operationID: .init(uuid: UUID()), roomID: room, role: .member, permissions: [], expectedRevision: expected)).revision
                default:
                    return try await transport.changeGroupMemberRole(command: .init(operationID: .init(uuid: UUID()), roomID: room, targetUserID: .init(uuid: UUID()), role: .admin, expectedMembershipRevision: expected)).membershipRevision
                }
            }
            if returned == expected + 1 && returned <= UInt64(Int64.max) {
                #expect(try await result() == returned)
            } else {
                await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { _ = try await result() }
            }
        }
    }
}

private actor CapabilityBoundsWire: V2AuthenticatedFrameTransport {
    let kind: String
    let value: UInt64
    init(kind: String, value: UInt64) { self.kind = kind; self.value = value }
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        let revision: UInt64 = kind.hasSuffix("Revision") ? value : 2
        let sequence: UInt64 = kind.hasSuffix("Sequence") ? value : 2
        var response = IMV2Envelope()
        response.protocolVersion = 1
        response.requestID = frame.requestID
        switch request.body {
        case .setPinnedMessage(let request):
            response.pinnedMessageChanged.roomID = request.roomID; response.pinnedMessageChanged.messageID = request.messageID
            response.pinnedMessageChanged.isPinned = request.isPinned; response.pinnedMessageChanged.roomSequence = sequence; response.pinnedMessageChanged.updatedAtMs = 1_000
        case .setGroupAnnouncement(let request):
            response.groupAnnouncementChanged.roomID = request.roomID; response.groupAnnouncementChanged.body = request.body
            response.groupAnnouncementChanged.revision = revision; response.groupAnnouncementChanged.roomSequence = sequence; response.groupAnnouncementChanged.updatedAtMs = 1_000
        case .setGroupRolePermissions(let request):
            response.groupRolePermissionsChanged.roomID = request.roomID; response.groupRolePermissionsChanged.role = request.role
            response.groupRolePermissionsChanged.permissions = request.permissions; response.groupRolePermissionsChanged.revision = revision; response.groupRolePermissionsChanged.roomSequence = sequence
        case .changeGroupMemberRole(let request):
            response.groupMemberRoleChanged.roomID = request.roomID; response.groupMemberRoleChanged.userID = request.userID; response.groupMemberRoleChanged.role = request.role
            response.groupMemberRoleChanged.membershipRevision = revision; response.groupMemberRoleChanged.roomSequence = sequence
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}
