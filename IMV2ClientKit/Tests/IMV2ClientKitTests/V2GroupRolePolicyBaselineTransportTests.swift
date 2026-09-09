import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 group policy baseline wire")
struct V2GroupRolePolicyBaselineTransportTests {
    private let room = try! RoomID("00000000-0000-0000-0000-000000ABCDEF")

    @Test("complete roles retain empty permissions and initial membership fence")
    func completeBaseline() async throws {
        let wire = PolicyBaselineWire(scenario: "valid")
        let client = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let value = try await client.fetchRolePolicyBaseline(roomID: room)
        #expect(value.roomID == room)
        #expect(value.permissionRevision == 4)
        #expect(value.membershipRevision == 0)
        #expect(value.roomSequence == 9)
        #expect(value.adminPermissions == [.inviteMembers])
        #expect(value.memberPermissions.isEmpty)
        #expect(await wire.requestedRooms() == [room.rawValue])
    }

    @Test("partial, conflicting, unbounded and uncorrelated baseline replies are rejected", arguments: ["missing", "duplicateRole", "owner", "unknownPermission", "duplicatePermission", "zeroVersion", "overflowVersion", "overflowMembership", "overflowSequence", "wrongRoom", "wrongCorrelation", "wrongVersion", "wrongBody"])
    func malformedBaseline(scenario: String) async throws {
        let client = V2ProtobufSyncTransport(wire: PolicyBaselineWire(scenario: scenario), protocolVersion: UInt8(IMV2ProtocolVersion.current))
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { try await client.fetchRolePolicyBaseline(roomID: room) }
    }

    @Test("owner-change retry metadata survives the wire and invalid requests do not send")
    func errors() async throws {
        let wire = PolicyBaselineWire(scenario: "ownerChanged")
        let client = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        await #expect(throws: V2RealtimeTransportError.server(code: "ROOM_OWNER_CHANGED", retryable: true, retryAfterSeconds: 1, currentRevision: nil)) {
            try await client.fetchRolePolicyBaseline(roomID: room)
        }
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { try await client.fetchRolePolicyBaseline(roomID: .init("invalid")) }
        #expect(await wire.requestedRooms() == [room.rawValue])
    }
}

private actor PolicyBaselineWire: V2AuthenticatedFrameTransport {
    let scenario: String
    private var rooms: [String] = []
    init(scenario: String) { self.scenario = scenario }
    func requestedRooms() -> [String] { rooms }
    func request(_ frame: V2Frame) throws -> V2Frame {
        #expect(frame.command == .getGroupRolePolicyBaseline)
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .getGroupRolePolicyBaseline(let input)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        #expect(request.protocolVersion == IMV2ProtocolVersion.current)
        rooms.append(input.roomID)
        var result = IMV2Envelope()
        result.requestID = request.requestID
        result.protocolVersion = request.protocolVersion
        result.groupRolePolicyBaseline.roomID = input.roomID.lowercased()
        result.groupRolePolicyBaseline.permissionRevision = 4
        result.groupRolePolicyBaseline.membershipRevision = 0
        result.groupRolePolicyBaseline.roomSequence = 9
        var admin = IMV2GroupRolePolicy(); admin.role = "admin"
        var permission = IMV2GroupRolePermission(); permission.permission = "invite_members"
        admin.permissions = [permission]
        var member = IMV2GroupRolePolicy(); member.role = "member"
        result.groupRolePolicyBaseline.policies = [admin, member]
        switch scenario {
        case "missing": result.groupRolePolicyBaseline.policies = [admin]
        case "duplicateRole": result.groupRolePolicyBaseline.policies = [admin, admin]
        case "owner": result.groupRolePolicyBaseline.policies[1].role = "owner"
        case "unknownPermission": result.groupRolePolicyBaseline.policies[0].permissions[0].permission = "unknown"
        case "duplicatePermission": result.groupRolePolicyBaseline.policies[0].permissions = [permission, permission]
        case "zeroVersion": result.groupRolePolicyBaseline.permissionRevision = 0
        case "overflowVersion": result.groupRolePolicyBaseline.permissionRevision = .max
        case "overflowMembership": result.groupRolePolicyBaseline.membershipRevision = .max
        case "overflowSequence": result.groupRolePolicyBaseline.roomSequence = .max
        case "wrongRoom": result.groupRolePolicyBaseline.roomID = "00000000-0000-0000-0000-000000000001"
        case "wrongCorrelation": result.requestID += 1
        case "wrongVersion": result.protocolVersion -= 1
        case "wrongBody": result.acknowledged = .init()
        case "ownerChanged": result.error.code = "ROOM_OWNER_CHANGED"; result.error.retryable = true; result.error.retryAfterSeconds = 1
        default: break
        }
        let encoded = try V2ProtobufFrameCodec.encode(result, frameVersion: scenario == "wrongVersion" ? frame.version - 1 : frame.version)
        if scenario == "valid" { #expect(encoded.command == .groupRolePolicyBaseline) }
        return encoded
    }
}
