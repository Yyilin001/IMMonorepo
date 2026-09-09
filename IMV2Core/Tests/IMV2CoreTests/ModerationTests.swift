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

    @Test("redaction expected revision fits persistence without changing optional semantics", arguments: [nil, UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max] as [UInt64?])
    func expectedRevisionPersistenceBounds(revision: UInt64?) throws {
        func command() throws -> V2ModerationCommand {
            try .init(roomID: roomID, actorUserID: actorID, operationID: operationID,
                      action: .redactMessage, messageID: .init("message"),
                      expectedMessageRevision: revision, reasonCode: .init("policy"))
        }
        if let revision, revision == 0 || revision > UInt64(Int64.max) {
            #expect(throws: V2ModerationValidationError.invalidActionShape) { _ = try command() }
        } else {
            #expect(try command().expectedMessageRevision == revision)
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

    @Test("mute authorization rejects nonfinite clocks and expiry", arguments: [Double.nan, -.infinity, .infinity, -1, 0, 1], [Double.nan, -.infinity, .infinity, -1, 0, 1])
    func muteClockBounds(nowSeconds: Double, expirySeconds: Double) throws {
        let now = Date(timeIntervalSince1970: nowSeconds)
        let command = try V2ModerationCommand(
            roomID: roomID, actorUserID: actorID, operationID: operationID,
            action: .muteMember, targetUserID: targetID,
            muteUntil: Date(timeIntervalSince1970: expirySeconds), reasonCode: .init("policy")
        )
        if nowSeconds.isFinite && expirySeconds.isFinite && expirySeconds > nowSeconds {
            try V2ModerationAuthorization.authorize(actorRole: .owner, action: .muteMember, now: now, command: command)
        } else {
            #expect(throws: V2ModerationValidationError.invalidMuteExpiry) {
                try V2ModerationAuthorization.authorize(actorRole: .owner, action: .muteMember, now: now, command: command)
            }
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
