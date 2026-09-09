import Foundation
import IMV2Core
import Testing

@Suite("V2 group capabilities")
struct GroupCapabilitiesTests {
    private let roomID = try! RoomID("00000000-0000-0000-0000-000000000801")

    @Test("role policy is version-fenced and cannot mutate owner authority")
    func rolePolicyValidation() throws {
        let operation = try GroupPermissionOperationID("00000000-0000-0000-0000-000000000802")
        #expect(throws: V2GroupPermissionValidationError.ownerPolicyIsImmutable) {
            _ = try V2GroupRolePermissionsCommand(operationID: operation, roomID: roomID, role: .owner, permissions: [], expectedRevision: 1)
        }
        #expect(throws: V2CoreError.invalidPositiveValue) {
            _ = try V2GroupRolePermissionsCommand(operationID: operation, roomID: roomID, role: .admin, permissions: [], expectedRevision: 0)
        }
    }

    @Test("announcement and role changes reject unsafe shapes")
    func commandValidation() throws {
        let announcement = try GroupAnnouncementOperationID("00000000-0000-0000-0000-000000000803")
        #expect(throws: V2GroupPermissionValidationError.emptyAnnouncement) {
            _ = try V2GroupAnnouncementCommand(operationID: announcement, roomID: roomID, body: " \n ", expectedRevision: 0)
        }
        #expect(throws: V2GroupPermissionValidationError.announcementTooLarge) {
            _ = try V2GroupAnnouncementCommand(operationID: announcement, roomID: roomID, body: String(repeating: "a", count: 4_097), expectedRevision: 0)
        }
        #expect(throws: V2GroupPermissionValidationError.memberRoleCannotBeOwner) {
            _ = try V2GroupMemberRoleCommand(operationID: .init("00000000-0000-0000-0000-000000000804"), roomID: roomID, targetUserID: .init("00000000-0000-0000-0000-000000000805"), role: .owner, expectedMembershipRevision: 1)
        }
    }

    @Test("multi-forward remains bounded and preserves per-pair intent")
    func multiForwardLimits() throws {
        let operation = try MessageForwardOperationID("00000000-0000-0000-0000-000000000806")
        let source = try MessageID("00000000-0000-0000-0000-000000000807")
        let target = try RoomID("00000000-0000-0000-0000-000000000808")
        let command = try V2ForwardMessagesCommand(operationID: operation, sources: [.init(roomID: target, messageID: source, revision: .init(1))], targetRoomIDs: [target])
        #expect(command.sourceMessageIDs == [source])
        #expect(command.targetRoomIDs == [target])
        #expect(throws: V2CoreError.invalidPositiveValue) {
            try V2ForwardMessagesCommand(operationID: operation, sources: [], targetRoomIDs: [target])
        }
        let sources = try (0 ... V2ForwardMessagesCommand.maximumSourceMessages).map {
            try MessageID(String(format: "00000000-0000-0000-0000-%012d", $0 + 900))
        }
        #expect(throws: V2CoreError.invalidPositiveValue) {
            try V2ForwardMessagesCommand(operationID: operation, sources: sources.map { .init(roomID: target, messageID: $0, revision: try .init(1)) }, targetRoomIDs: [target])
        }
    }
}

@Suite("Selected forward source references")
struct ForwardReferenceTests {
    @Test("JSON preserves exact rooms and versions and rejects missing or out-of-range context")
    func referenceCodable() throws {
        let source = V2ForwardMessageReference(roomID: try .init("room-a"), messageID: try .init("message-a"), revision: try .init(17))
        #expect(try JSONDecoder().decode(V2ForwardMessageReference.self, from: JSONEncoder().encode(source)) == source)
        for revision in ["0", "-1", "9223372036854775808", "18446744073709551615", "null"] {
            let json = Data("{\"roomID\":\"room-a\",\"messageID\":\"message-a\",\"revision\":\(revision)}".utf8)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ForwardMessageReference.self, from: json) }
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ForwardMessageReference.self, from: Data("{\"messageID\":\"message-a\"}".utf8)) }
    }

    @Test("two room or version claims cannot alias the same source identity")
    func duplicateIdentityRejected() throws {
        let id = try MessageID("message-a")
        let sources = try [V2ForwardMessageReference(roomID: .init("room-a"), messageID: id, revision: .init(1)), V2ForwardMessageReference(roomID: .init("room-b"), messageID: id, revision: .init(2))]
        #expect(throws: V2CoreError.invalidPositiveValue) {
            try V2ForwardMessagesCommand(operationID: .init("operation-a"), sources: sources, targetRoomIDs: [.init("target")])
        }
    }
}
