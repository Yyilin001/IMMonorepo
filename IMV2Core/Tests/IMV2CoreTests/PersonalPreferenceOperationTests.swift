import Foundation
import IMV2Core
import Testing

struct PersonalPreferenceOperationTests {
    @Test func fingerprintFreezesRevisionAndDeadline() throws {
        let actor = try UserID("actor")
        let room = try RoomID("room")
        let operation = try ConversationPreferenceOperationID("operation")
        let a = try V2ConversationStateCommand(
            operationID: operation, roomID: room, isPinned: true, isArchived: false, muteUntil: nil,
            expectedRevision: .initial, firstSubmissionDeadlineMilliseconds: 1000)
        let b = try V2ConversationStateCommand(
            operationID: operation, roomID: room, isPinned: true, isArchived: false, muteUntil: nil,
            expectedRevision: .init(rawValue: 1)!, firstSubmissionDeadlineMilliseconds: 1000)
        #expect(try a.identity(actorUserID: actor) == b.identity(actorUserID: actor))
        #expect(try a.fingerprint(actorUserID: actor) != b.fingerprint(actorUserID: actor))
        let decoded = try JSONDecoder().decode(V2ConversationStateCommand.self, from: JSONEncoder().encode(a))
        #expect(decoded == a)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2PersonalPreferenceRevision.self, from: Data("18446744073709551615".utf8))
        }
        let wrong = try V2OperationIdentity(
            accountID: actor, scope: .account(actor), operation: .profileUpdate(.init("profile")))
        #expect(throws: V2PersonalPreferenceOperationError.invalidScope) {
            try V2PersonalPreferenceRecoveryRequest(
                identity: wrong, fingerprint: a.fingerprint(actorUserID: actor), action: .query)
        }
    }
    @Test func receiptValidatesCommittedEntity() throws {
        let actor = try UserID("actor")
        let room = try RoomID("room")
        let other = try RoomID("other")
        let command = try V2MessageFavoriteCommand(
            operationID: .init("operation"), roomID: room, messageID: .init("message"), isFavorited: true,
            expectedRevision: .initial, firstSubmissionDeadlineMilliseconds: 1000)
        let value = V2MessageFavorite(
            roomID: other, messageID: command.messageID, isFavorited: true, updatedAt: Date(),
            revision: .init(rawValue: 1)!)
        #expect(throws: V2PersonalPreferenceOperationError.invalidReceipt) {
            try V2PersonalPreferenceReceipt(
                identity: command.identity(actorUserID: actor), fingerprint: command.fingerprint(actorUserID: actor),
                outcome: .committed(.messageFavorite(value)), resolvedAtMilliseconds: 1)
        }
    }
}
