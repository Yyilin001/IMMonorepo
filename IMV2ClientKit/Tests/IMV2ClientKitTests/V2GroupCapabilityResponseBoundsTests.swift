import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2GroupCapabilityResponseBoundsTests {
    @Test(arguments: ["pinSequence", "announcementRevision", "announcementSequence", "permissionsRevision", "permissionsSequence", "roleRevision", "roleSequence"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func responseBounds(kind: String, value: UInt64) throws {
        let command = try command(kind: kind, expected: 1)
        let revision = kind.hasSuffix("Revision") ? value : 2
        let sequence = kind.hasSuffix("Sequence") ? value : 2
        func receipt() throws -> V2GroupCapabilityReceipt {
            try .init(identity: command.identity, fingerprint: command.fingerprint,
                outcome: .applied(result(command: command, revision: revision, sequence: sequence)), resolvedAtMilliseconds: 100)
        }
        if (value == 0 && kind != "roleRevision") || value > UInt64(Int64.max) {
            #expect(throws: (any Error).self) { try receipt() }
        } else { _ = try JSONDecoder().decode(V2GroupCapabilityReceipt.self, from: JSONEncoder().encode(receipt())) }
    }
    @Test(arguments: ["announcementRevision", "permissionsRevision", "roleRevision"],
          [UInt64(1), UInt64(Int64.max) - 2, UInt64(Int64.max) - 1])
    func committedRevision(kind: String, expected: UInt64) throws {
        let command = try command(kind: kind, expected: expected)
        for returned in [expected - 1, expected, expected + 1, expected + 2] {
            if (returned == 0 && kind != "roleRevision") || returned > UInt64(Int64.max) {
                #expect(throws: (any Error).self) { try V2GroupCapabilityReceipt(identity: command.identity, fingerprint: command.fingerprint,
                    outcome: .applied(result(command: command, revision: returned, sequence: 1)), resolvedAtMilliseconds: 100) }
            } else {
                let receipt = try V2GroupCapabilityReceipt(identity: command.identity, fingerprint: command.fingerprint,
                    outcome: .applied(result(command: command, revision: returned, sequence: 1)), resolvedAtMilliseconds: 100)
                #expect(receipt.validates(command: command) == (returned == expected + 1))
            }
        }
    }
    private func command(kind: String, expected: UInt64) throws -> V2GroupCapabilityCommand {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), message = MessageID(uuid: UUID())
        let action: V2GroupCapabilityAction, operation: V2OperationReference, scope: V2OperationScope
        if kind.hasPrefix("pin") {
            action = .pin(messageID: message, isPinned: true, expectedRoomSequence: expected); operation = .pinnedMessage(.init(uuid: UUID())); scope = .message(room, message)
        } else if kind.hasPrefix("announcement") {
            action = .announcement(body: "notice", expectedRevision: expected); operation = .groupAnnouncement(.init(uuid: UUID())); scope = .room(room)
        } else if kind.hasPrefix("permissions") {
            action = .rolePermissions(role: .member, permissions: [], expectedRevision: expected); operation = .groupPermission(.init(uuid: UUID())); scope = .room(room)
        } else {
            action = .memberRole(targetUserID: .init(uuid: UUID()), role: .admin, expectedMembershipRevision: expected); operation = .groupRole(.init(uuid: UUID())); scope = .room(room)
        }
        let intent = try V2GroupCapabilityIntent(identity: .init(accountID: actor, scope: scope, operation: operation), action: action, confirmedUntilMilliseconds: 1000)
        let admission = try V2GroupCapabilityAdmission(id: .init(uuid: UUID()), identity: intent.identity, intentFingerprint: intent.fingerprint,
            issuedAtMilliseconds: 1, expiresAtMilliseconds: 1000, targetJoinedRevision: kind.hasPrefix("role") ? 0 : nil)
        return try .init(intent: intent, admission: admission)
    }
    private func result(command: V2GroupCapabilityCommand, revision: UInt64, sequence: UInt64) -> V2GroupCapabilityValue {
        switch command.intent.action {
        case .pin(let message, let pinned, _): .pinned(messageID: message, isPinned: pinned, roomSequence: sequence)
        case .announcement(let body, _): .announcement(body: body, revision: revision, roomSequence: sequence)
        case .rolePermissions(let role, let permissions, _): .rolePermissions(role: role, permissions: permissions, revision: revision, roomSequence: sequence)
        case .memberRole(let target, let role, _): .memberRole(targetUserID: target, role: role, membershipRevision: revision, roomSequence: sequence)
        }
    }
}
