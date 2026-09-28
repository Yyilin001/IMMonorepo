import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("D1 messaging mapper")
struct V2ActorMessagingMapperTests {
    private func ids() throws -> (RoomID, UserID, MessageID, ClientMessageID, EventID, MediaID) {
        (try RoomID("room-1"), try UserID("user-1"), try MessageID("message-1"),
         try ClientMessageID("client-1"), try EventID("event-1"), try MediaID("media-1"))
    }

    @Test("accepted, content-free replay and denied preserve every distinct domain value")
    func sendOutcomes() throws {
        let (room, user, message, client, event, mediaID) = try ids()
        let media = [V2MediaReference(mediaID: mediaID)]
        let presentations = [try V2MediaPresentation(mediaID: mediaID, kind: .image,
                                                      contentType: "image/png", byteCount: 73)]
        let entity = try V2MessageEntity(offsetUTF16: 0, lengthUTF16: 5, kind: .bold)
        let reply = V2MessageReplyReference(messageID: message)
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let accepted = V2AcceptedMessage(messageID: message, roomID: room, roomSequence: 13,
            timelineSequence: 17, senderUserID: user, clientMessageID: client, text: "hello",
            media: media, mediaPresentations: presentations, mentions: [.user(user), .everyone],
            entities: [entity], replyTo: reply, groupCapacityClass: .standard,
            sourceEventID: event, acceptedMembershipRevision: 19, directRecipientUserID: user,
            projectionCreatedAtUnixMilliseconds: 1_700_000_000_123, createdAt: time)
        let outcomes: [V2SendMessageOutcome] = [
            .accepted(accepted), .idempotent(accepted.receipt),
            .denied(.init(roomID: room, sourceEventID: event, timelineSequence: 23,
                          createdAt: time, reason: .systemAccountReadOnly)),
            .idempotencyConflict, .rateLimited(retryAfterSeconds: 5),
            .unavailable(.expiredShardLease),
        ]
        for outcome in outcomes {
            let wire = V2ActorSendMessageResultWire(outcome)
            let decoded = try JSONDecoder().decode(V2ActorSendMessageResultWire.self,
                                                   from: JSONEncoder().encode(wire))
            #expect(try decoded.toDomain() == outcome)
        }
        let wire = V2ActorAcceptedMessageWire(accepted)
        #expect(wire.mediaPresentations == presentations)
        #expect(wire.projectionCreatedAtUnixMilliseconds == 1_700_000_000_123)
        #expect(wire.sourceEventID == event)
        #expect(wire.acceptedMembershipRevision == 19)
        #expect(wire.replyTo == reply)
        #expect(wire.entities == [entity])
    }

    @Test("all four authenticated inputs map without changing caller-owned intent")
    func inputs() throws {
        let (room, user, message, client, _, _) = try ids()
        let limits = try V2MessageCommandLimits(maxUTF8Bytes: 100)
        let send = V2AuthenticatedSendMessage(roomID: room, actorUserID: user,
            clientMessageID: client, text: "hello", mentions: [.everyone, .user(user)],
            entities: [try V2MessageEntity(offsetUTF16: 0, lengthUTF16: 5, kind: .bold)],
            replyTo: .init(messageID: message))
        let returnedSend = try V2ActorSendMessageWire(send).toAuthenticated(limits: limits)
        #expect(returnedSend.mentions == send.mentions)
        #expect(returnedSend.entities == send.entities)
        #expect(returnedSend.replyTo == send.replyTo)
        let edit = try V2MessageEditOperationCommand(command: .init(roomID: room, actorUserID: user,
            operationID: .init("edit-1"), messageID: message, expectedMessageRevision: 2,
            text: "replacement", maximumUTF8Bytes: 100), firstSubmissionDeadlineMilliseconds: 1_700_000_600_000)
        let returnedEdit = try JSONDecoder().decode(V2MessageEditOperationCommand.self, from: JSONEncoder().encode(edit))
        #expect(try returnedEdit.domainCommand(maximumUTF8Bytes: 100).text == edit.text)
        let withdrawal = try V2MessageWithdrawalOperationCommand(command: .init(roomID: room, actorUserID: user,
            operationID: .init("withdraw-1"), messageID: message, expectedMessageRevision: 3),
            firstSubmissionDeadlineMilliseconds: 1_700_000_600_000)
        let returnedWithdrawal = try JSONDecoder().decode(V2MessageWithdrawalOperationCommand.self, from: JSONEncoder().encode(withdrawal))
        #expect(try returnedWithdrawal.domainCommand().expectedMessageRevision == 3)
        let reaction = try V2MessageReactionOperationCommand(command: .init(roomID: room, actorUserID: user,
            operationID: .init("reaction-1"), messageID: message, reaction: "👍", action: .add),
            expectedReactionRevision: 0, firstSubmissionDeadlineMilliseconds: 1_700_000_600_000)
        let returnedReaction = try JSONDecoder().decode(V2MessageReactionOperationCommand.self, from: JSONEncoder().encode(reaction))
        #expect(try returnedReaction.domainCommand().reaction == "👍")
    }

    @Test("edit, withdrawal and reaction outcomes preserve committed event details")
    func mutations() throws {
        let (room, user, message, _, event, _) = try ids()
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let edit = try V2MessageEdit(roomID: room, messageID: message, text: "new",
                                     messageRevision: 2, roomSequence: 3,
                                     eventID: event, createdAt: time)
        let withdrawal = try V2MessageWithdrawal(roomID: room, messageID: message,
                                                  messageRevision: 3, roomSequence: 4,
                                                  eventID: event, createdAt: time)
        let reaction = try V2MessageReactionChange(roomID: room, messageID: message,
            actorUserID: user, reaction: "👍", action: .add, roomSequence: 5,
            eventID: event, createdAt: time)
        // Projection leaves remain current even though unbound outcome envelopes retired.
        #expect(try V2ActorMessageEditWire(edit).toDomain() == edit)
        #expect(try V2ActorMessageWithdrawalWire(withdrawal).toDomain() == withdrawal)
        #expect(try V2ActorMessageReactionChangeWire(reaction).toDomain() == reaction)
    }

    @Test("decoded malformed leaves and precondition inputs throw instead of trapping")
    func malformedWire() throws {
        let (room, user, message, client, event, mediaID) = try ids()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let media = [V2MediaReference(mediaID: mediaID)]
        let otherMedia = try MediaID("media-2")
        let presentation = try V2MediaPresentation(mediaID: otherMedia, kind: .file,
                                                   contentType: "application/pdf", byteCount: 5)
        let mismatched = V2ActorAcceptedMessageWire(messageID: message, roomID: room,
            roomSequence: 1, timelineSequence: 1, senderUserID: user, clientMessageID: client,
            text: "hello", media: media, mediaPresentations: [presentation], mentions: [],
            entities: [], replyTo: nil, groupCapacityClass: nil, sourceEventID: event,
            acceptedMembershipRevision: nil, directRecipientUserID: nil,
            projectionCreatedAtUnixMilliseconds: nil, createdAt: date)
        #expect(throws: V2ActorMessagingMappingError.invalidMediaPresentationIdentity) {
            try mismatched.toDomain()
        }
        let decodedBadPresentation = try JSONDecoder().decode(V2MediaPresentation.self,
            from: Data(#"{"mediaID":{"rawValue":"media-1"},"kind":"image","contentType":" IMAGE/PNG ","byteCount":-1}"#.utf8))
        let badPresentation = V2ActorAcceptedMessageWire(messageID: message, roomID: room,
            roomSequence: 1, timelineSequence: 1, senderUserID: user, clientMessageID: client,
            text: "hello", media: media, mediaPresentations: [decodedBadPresentation], mentions: [],
            entities: [], replyTo: nil, groupCapacityClass: nil, sourceEventID: nil,
            acceptedMembershipRevision: nil, directRecipientUserID: nil,
            projectionCreatedAtUnixMilliseconds: nil, createdAt: date)
        #expect(throws: V2MediaValidationError.invalidPresentation) {
            try badPresentation.toDomain()
        }
        let invalidEntity = try JSONDecoder().decode(V2MessageEntity.self,
            from: Data(#"{"offsetUTF16":0,"lengthUTF16":100,"kind":"bold","linkURL":null}"#.utf8))
        let badEntity = V2ActorAcceptedMessageWire(messageID: message, roomID: room,
            roomSequence: 1, timelineSequence: 1, senderUserID: user, clientMessageID: client,
            text: "hello", media: [], mediaPresentations: [], mentions: [],
            entities: [invalidEntity], replyTo: nil, groupCapacityClass: nil, sourceEventID: nil,
            acceptedMembershipRevision: nil, directRecipientUserID: nil,
            projectionCreatedAtUnixMilliseconds: nil, createdAt: date)
        #expect(throws: V2RichMessageContentError.invalidEntity) { try badEntity.toDomain() }
        #expect(throws: V2ActorMessagingMappingError.invalidSequence) {
            try V2ActorDirectMessageDeniedWire(roomID: room, sourceEventID: event,
                timelineSequence: 0, createdAt: date, reason: .generic).toDomain()
        }
        #expect(throws: V2ActorMessagingMappingError.invalidRetryDelay) {
            try V2ActorSendMessageResultWire.rateLimited(retryAfterSeconds: -1).toDomain()
        }
        #expect(throws: (any Error).self) {
            try V2ActorMessageEditWire(roomID: room, messageID: message, text: "new",
                messageRevision: 0, roomSequence: 1, eventID: event, createdAt: date).toDomain()
        }

    }
}

@Suite("D1 special-account room audit mapping")
struct V2ActorMessagingSpecialAccountAuditTests {
    @Test("trusted request, resolved account and accepted receipt survive room audit wire")
    func audit() throws {
        let room = try RoomID("room-1")
        let customer = try UserID("customer-1")
        let special = try UserID("special-1")
        let client = try ClientMessageID("client-1")
        let request = try V2TrustedSpecialAccountMessage(
            stableAccountKey: "support_bot", servicePrincipal: "service-principal",
            operatorID: "operator-1", operationID: client,
            requestFingerprint: "0123456789abcdef", firstSubmissionDeadlineMilliseconds: 1_700_000_600_000, customerUserID: customer,
            text: "Hello", mentions: [.user(customer)],
            entities: [try V2MessageEntity(offsetUTF16: 0, lengthUTF16: 5, kind: .bold)])
        let account = V2ResolvedSpecialAccount(userID: special, stableKey: "support_bot",
                                               kind: .system)
        let receipt = V2MessageAcceptanceReceipt(messageID: try MessageID("message-1"),
            roomID: room, roomSequence: 1, timelineSequence: 2, senderUserID: special,
            clientMessageID: client, groupCapacityClass: nil,
            sourceEventID: try EventID("event-1"), acceptedMembershipRevision: nil,
            directRecipientUserID: customer, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let wire = V2ActorSpecialAccountAuditWire(request: request, account: account,
                                                   roomID: room, outcome: .idempotent(receipt))
        let decoded = try JSONDecoder().decode(V2ActorSpecialAccountAuditWire.self,
                                                from: JSONEncoder().encode(wire))
        let restored = try decoded.toDomain()
        #expect(restored.request.stableAccountKey == request.stableAccountKey)
        #expect(restored.request.requestFingerprint == request.requestFingerprint)
        #expect(restored.request.firstSubmissionDeadlineMilliseconds == request.firstSubmissionDeadlineMilliseconds)
        #expect(restored.request.entities == request.entities)
        #expect(restored.request.mentions == request.mentions)
        #expect(restored.account == account)
        #expect(restored.roomID == room)
        #expect(restored.outcome == .idempotent(receipt))
        #expect(decoded.retryPolicy == .durableIdempotent)
    }
}
