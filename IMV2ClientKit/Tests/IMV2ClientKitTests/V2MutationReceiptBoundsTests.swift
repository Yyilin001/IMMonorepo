import Foundation
import IMV2Core
import IMV2ClientKit
import Testing

struct V2MutationReceiptBoundsTests {
    @Test(arguments: ["acceptance.sequence", "membership.sequence", "membership.revision", "withdrawal.sequence", "withdrawal.revision", "redaction.sequence", "redaction.revision", "edit.sequence", "edit.revision", "receipt.sequence", "reaction.sequence"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func persistedReceiptBounds(field: String, value: UInt64) throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), user = UserID(uuid: UUID())
        let now = Date(timeIntervalSince1970: 1000)
        let sequence = field.hasSuffix(".sequence") ? value : 1
        let revision = field.hasSuffix(".revision") ? value : 1
        func construct() throws -> (sequence: UInt64, revision: UInt64?) {
            switch field.split(separator: ".")[0] {
            case "acceptance": let result = try V2ClientMessageAcceptance(messageID: message, roomID: room, roomSequence: sequence, createdAt: now); return (result.roomSequence, nil)
            case "membership": let result = try V2MembershipApplied(membershipRevision:revision,roomSequence:sequence,eventID:.init(uuid:UUID()));return (result.roomSequence,result.membershipRevision)
            case "withdrawal": let result = try V2ClientMessageWithdrawal(roomID: room, messageID: message, messageRevision: revision, roomSequence: sequence, createdAt: now); return (result.roomSequence, result.messageRevision)
            case "redaction":
                let identity=try V2OperationIdentity(accountID:user,scope:.room(room),operation:.moderation(.init(uuid:UUID())))
                _ = try V2MessageModerationReceipt(identity:identity,fingerprint:.init(kind:.moderation,fields:[.init("bounds",.text("receipt"))]),outcome:.redacted(messageID:message,messageRevision:revision,roomSequence:sequence,eventID:.init(uuid:UUID())),resolvedAtMilliseconds:1000)
                return (sequence,revision)
            case "edit": let result = try V2ClientMessageEdit(roomID: room, messageID: message, text: "edit", messageRevision: revision, roomSequence: sequence, createdAt: now); return (result.roomSequence, result.messageRevision)
            case "receipt": let result = try V2ClientReadReceipt(roomID: room, userID: user, readThroughRoomSequence: sequence, recordedAt: now); return (result.readThroughRoomSequence, nil)
            case "reaction": let result = try V2ClientMessageReactionChange(roomID: room, messageID: message, actorUserID: user, reaction: "👍", action: .add, roomSequence: sequence, createdAt: now); return (result.roomSequence, nil)
            default: throw V2RevisionValidationError.outOfRange
            }
        }
        if value == 0 || value > UInt64(Int64.max) {
            if field.hasPrefix("membership.") { #expect(throws:V2MembershipOperationValidationError.invalidReceipt) { try construct() } }
            else if field.hasPrefix("redaction.") { #expect(throws:V2MessageModerationValidationError.invalidReceipt) { try construct() } }
            else { #expect(throws: V2RevisionValidationError.outOfRange) { try construct() } }
        } else {
            let result = try construct()
            #expect(result.sequence == sequence)
            if let actual = result.revision { #expect(actual == revision) }
        }
    }
}
