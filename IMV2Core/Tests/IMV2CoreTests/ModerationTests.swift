import Foundation
import Testing
@testable import IMV2Core

@Suite("V2 moderation command contract")
struct ModerationTests {
    private let roomID = try! RoomID("00000000-0000-0000-0000-000000000801")
    private let actorID = try! UserID("00000000-0000-0000-0000-000000000802")
    private let targetID = try! UserID("00000000-0000-0000-0000-000000000803")
    private let operationID = try! ModerationOperationID("00000000-0000-0000-0000-000000000804")

    @Test("action shapes forbid accidental target/message/expiry combinations")
    func actionShapesAreExclusive() throws {
        let reason = try V2ModerationReasonCode("abuse_spam")
        #expect(throws: V2ModerationValidationError.invalidActionShape) {
            try V2ModerationCommand(roomID: roomID, actorUserID: actorID, operationID: operationID, action: .redactMessage, targetUserID: targetID, messageID: .init("00000000-0000-0000-0000-000000000805"), reasonCode: reason)
        }
        #expect(throws: V2ModerationValidationError.invalidActionShape) {
            try V2ModerationCommand(roomID: roomID, actorUserID: actorID, operationID: operationID, action: .muteMember, targetUserID: targetID, reasonCode: reason)
        }
        #expect(throws: V2ModerationValidationError.invalidActionShape) {
            try V2ModerationCommand(roomID: roomID, actorUserID: actorID, operationID: operationID, action: .removeMember, targetUserID: actorID, reasonCode: reason)
        }
    }

    @Test("only a message redaction can carry a positive expected content revision")
    func expectedMessageRevisionIsFencedToRedaction() throws {
        let reason = try V2ModerationReasonCode("content_policy_violation")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000805")
        let redaction = try V2ModerationCommand(
            roomID: roomID,
            actorUserID: actorID,
            operationID: operationID,
            action: .redactMessage,
            messageID: messageID,
            expectedMessageRevision: 3,
            reasonCode: reason
        )
        #expect(redaction.expectedMessageRevision == 3)

        #expect(throws: V2ModerationValidationError.invalidActionShape) {
            try V2ModerationCommand(
                roomID: roomID,
                actorUserID: actorID,
                operationID: operationID,
                action: .redactMessage,
                messageID: messageID,
                expectedMessageRevision: 0,
                reasonCode: reason
            )
        }
        #expect(throws: V2ModerationValidationError.invalidActionShape) {
            try V2ModerationCommand(
                roomID: roomID,
                actorUserID: actorID,
                operationID: operationID,
                action: .muteMember,
                targetUserID: targetID,
                expectedMessageRevision: 3,
                muteUntil: Date(timeIntervalSince1970: 1_750_000_060),
                reasonCode: reason
            )
        }
    }

    @Test("only room owner or admin can moderate and mute expiry must be future")
    func authorizationAndExpiryAreFenced() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let reason = try V2ModerationReasonCode("abuse_spam")
        let mute = try V2ModerationCommand(roomID: roomID, actorUserID: actorID, operationID: operationID, action: .muteMember, targetUserID: targetID, muteUntil: now.addingTimeInterval(60), reasonCode: reason)
        #expect(throws: V2ModerationAuthorizationError.notAuthorized) {
            try V2ModerationAuthorization.authorize(actorRole: .member, action: mute.action, now: now, command: mute)
        }
        #expect(throws: V2ModerationValidationError.invalidMuteExpiry) {
            let expired = try V2ModerationCommand(roomID: roomID, actorUserID: actorID, operationID: operationID, action: .muteMember, targetUserID: targetID, muteUntil: now, reasonCode: reason)
            try V2ModerationAuthorization.authorize(actorRole: .admin, action: expired.action, now: now, command: expired)
        }
        try V2ModerationAuthorization.authorize(actorRole: .owner, action: mute.action, now: now, command: mute)

        let freeze = try V2ModerationCommand(roomID: roomID, actorUserID: actorID, operationID: operationID, action: .freezeRoom, reasonCode: reason)
        #expect(throws: V2ModerationAuthorizationError.notAuthorized) {
            try V2ModerationAuthorization.authorize(actorRole: .owner, action: freeze.action, now: now, command: freeze)
        }
    }

    @Test("configured group capability can narrow an administrator without narrowing the owner")
    func configuredCapabilities() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let reason = try V2ModerationReasonCode("policy")
        let command = try V2ModerationCommand(
            roomID: roomID, actorUserID: actorID, operationID: operationID,
            action: .redactMessage, messageID: .init("00000000-0000-0000-0000-000000000805"), reasonCode: reason
        )
        #expect(throws: V2ModerationAuthorizationError.notAuthorized) {
            try V2ModerationAuthorization.authorize(actorRole: .admin, configuredPermissions: [.sendMessages], action: command.action, now: now, command: command)
        }
        try V2ModerationAuthorization.authorize(actorRole: .owner, configuredPermissions: [], action: command.action, now: now, command: command)
    }

    @Test("reason codes are bounded opaque labels")
    func reasonCodeIsPrivacySafe() {
        #expect(throws: V2ModerationValidationError.invalidReasonCode) { try V2ModerationReasonCode("free form reason leaks content") }
        #expect(throws: V2ModerationValidationError.invalidReasonCode) { try V2ModerationReasonCode("") }
    }
}
