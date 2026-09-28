import Foundation
import Testing
@testable import IMV2Core

@Suite("Presentation operation boundaries")
struct PresentationOperationTests {
    @Test("alias fingerprint binds direction, intent, deadline and baseline")
    func aliasBinding() throws {
        let owner = UserID(uuid: UUID()), target = UserID(uuid: UUID()), operation = ContactAliasOperationID(uuid: UUID())
        let a = try V2ContactAliasUpdateCommand(ownerUserID: owner, targetUserID: target, operationID: operation,
            expectedRevision: nil, remarkName: " Friend ", firstSubmissionDeadlineMilliseconds: 1000)
        let same = try V2ContactAliasUpdateCommand(ownerUserID: owner, targetUserID: target, operationID: operation,
            expectedRevision: nil, remarkName: "Friend", firstSubmissionDeadlineMilliseconds: 1000)
        #expect(a == same)
        #expect(try JSONDecoder().decode(V2ContactAliasUpdateCommand.self, from: JSONEncoder().encode(a)) == a)
        let reverse = try V2ContactAliasUpdateCommand(ownerUserID: target, targetUserID: owner, operationID: operation,
            expectedRevision: nil, remarkName: "Friend", firstSubmissionDeadlineMilliseconds: 1000)
        #expect(reverse.identity != a.identity && reverse.fingerprint != a.fingerprint)
        #expect(throws: (any Error).self) {
            try V2ContactAliasUpdateCommand(ownerUserID: owner, targetUserID: owner, operationID: operation,
                expectedRevision: nil, remarkName: nil, firstSubmissionDeadlineMilliseconds: 1000)
        }
    }
    @Test("decoding snapshots rejects noncanonical nested fields and wrong ownership")
    func snapshots() throws {
        let owner = UserID(uuid: UUID()), target = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let alias = try V2ContactAlias(ownerUserID: owner, targetUserID: target, remarkName: "Friend", revision: .init(rawValue: 1)!)
        let snapshot = try V2ContactAliasSnapshot(ownerUserID: owner, targetUserID: target, value: alias)
        let data = try JSONEncoder().encode(snapshot)
        let malformed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "Friend", with: " Friend ").utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ContactAliasSnapshot.self, from: malformed) }
        #expect(throws: (any Error).self) { try V2ContactAliasSnapshot(ownerUserID: target, targetUserID: owner, value: alias) }
        let member = try V2GroupMemberPresentation(roomID: room, userID: owner, groupNickname: "Name", revision: .init(rawValue: 1)!)
        let group = try V2GroupNicknameSnapshot(actorUserID: owner, roomID: room, value: member)
        #expect(try JSONDecoder().decode(V2GroupNicknameSnapshot.self, from: JSONEncoder().encode(group)) == group)
        #expect(throws: (any Error).self) { try V2GroupNicknameSnapshot(actorUserID: target, roomID: room, value: member) }
    }
    @Test("receipts and recovery retain their typed operation binding")
    func receiptBinding() throws {
        let actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let command = try V2GroupNicknameUpdateCommand(actorUserID: actor, roomID: room, operationID: .init(uuid: UUID()),
            expectedRevision: nil, nickname: nil, firstSubmissionDeadlineMilliseconds: 1000)
        let closed = try V2GroupNicknameUpdateReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .closed, resolvedAtMilliseconds: 1000)
        #expect(closed.validates(command))
        let request = try V2GroupNicknameRecoveryRequest(identity: command.identity, fingerprint: command.fingerprint, action: .closeIfAbsent)
        #expect(try JSONDecoder().decode(V2GroupNicknameRecoveryRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(V2GroupNicknameRecoveryResult.unresolved != .receipt(closed))
        #expect(throws: (any Error).self) {
            try V2ContactAliasRecoveryRequest(identity: command.identity, fingerprint: command.fingerprint, action: .query)
        }
    }
}
