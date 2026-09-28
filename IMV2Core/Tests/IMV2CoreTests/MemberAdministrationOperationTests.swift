import Foundation
import Testing
@testable import IMV2Core

struct MemberAdministrationOperationTests {
    @Test func originalConfirmationAndMembershipAreFrozen() throws {
        let actor=UserID(uuid:UUID()),target=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),operation=ModerationOperationID(uuid:UUID())
        let intent=try V2MemberAdministrationIntent(roomID:room,actorUserID:actor,operationID:operation,targetUserID:target,action:.mute(untilMilliseconds:300_000),reasonCode:.init("spam"),expectedMembershipRevision:12,confirmedUntilMilliseconds:120_000)
        let admission=try V2MemberAdministrationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:12,targetJoinedRevision:9,issuedAtMilliseconds:10_000,expiresAtMilliseconds:120_000)
        let command=try V2MemberAdministrationCommand(intent:intent,admission:admission)
        #expect(try JSONDecoder().decode(V2MemberAdministrationCommand.self,from:JSONEncoder().encode(command))==command)
        #expect(intent.kind == .memberMute)
        let newConfirmation=try V2MemberAdministrationIntent(roomID:room,actorUserID:actor,operationID:operation,targetUserID:target,action:intent.action,reasonCode:intent.reasonCode,expectedMembershipRevision:12,confirmedUntilMilliseconds:130_000)
        #expect(try newConfirmation.fingerprint != intent.fingerprint)
        #expect(!admission.validates(intent:newConfirmation))
        let newMembership=try V2MemberAdministrationIntent(roomID:room,actorUserID:actor,operationID:operation,targetUserID:target,action:intent.action,reasonCode:intent.reasonCode,expectedMembershipRevision:13,confirmedUntilMilliseconds:120_000)
        #expect(!admission.validates(intent:newMembership))
        #expect(throws:V2MemberAdministrationValidationError.invalidAdmission) {
            try V2MemberAdministrationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:12,targetJoinedRevision:13,issuedAtMilliseconds:1,expiresAtMilliseconds:100)
        }
        #expect(throws:V2MemberAdministrationValidationError.invalidAdmission) {
            try V2MemberAdministrationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:12,targetJoinedRevision:9,issuedAtMilliseconds:1,expiresAtMilliseconds:120_002)
        }
        #expect(throws:V2MemberAdministrationValidationError.invalidIntent) {
            try V2MemberAdministrationIntent(roomID:room,actorUserID:actor,operationID:operation,targetUserID:actor,action:.remove,reasonCode:.init("spam"),expectedMembershipRevision:12,confirmedUntilMilliseconds:120_000)
        }
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(intent)) as! [String:Any]
        json["reasonCode"]=["rawValue":"unsafe reason"]
        let invalid=try JSONSerialization.data(withJSONObject:json)
        #expect(throws:(any Error).self) { try JSONDecoder().decode(V2MemberAdministrationIntent.self,from:invalid) }
    }
    @Test func immutableReceiptBindsActionAndResultRevision() throws {
        let actor=UserID(uuid:UUID()),target=UserID(uuid:UUID()),room=RoomID(uuid:UUID())
        let intent=try V2MemberAdministrationIntent(roomID:room,actorUserID:actor,operationID:.init(uuid:UUID()),targetUserID:target,action:.remove,reasonCode:.init("spam"),expectedMembershipRevision:12,confirmedUntilMilliseconds:120_000)
        let admission=try V2MemberAdministrationAdmission(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:12,targetJoinedRevision:9,issuedAtMilliseconds:10_000,expiresAtMilliseconds:120_000)
        let command=try V2MemberAdministrationCommand(intent:intent,admission:admission)
        let receipt=try V2MemberAdministrationReceipt(identity:command.identity,fingerprint:command.fingerprint,outcome:.applied(.removed(membershipRevision:13,roomSequence:20,eventID:.init(uuid:UUID()))),resolvedAtMilliseconds:20_000)
        #expect(receipt.validates(command:command))
        #expect(try JSONDecoder().decode(V2MemberAdministrationReceipt.self,from:JSONEncoder().encode(receipt))==receipt)
        let stale=try V2MemberAdministrationReceipt(identity:command.identity,fingerprint:command.fingerprint,outcome:.applied(.removed(membershipRevision:14,roomSequence:20,eventID:.init(uuid:UUID()))),resolvedAtMilliseconds:20_000)
        #expect(!stale.validates(command:command))
        #expect(throws:V2MemberAdministrationValidationError.invalidReceipt) {
            try V2MemberAdministrationReceipt(identity:command.identity,fingerprint:command.fingerprint,outcome:.applied(.muted(untilMilliseconds:300_000,membershipRevision:12,roomSequence:20,eventID:.init(uuid:UUID()))),resolvedAtMilliseconds:20_000)
        }
        for kind in [V2OperationKind.memberMute,.moderatedMemberRemoval] {
            #expect(V2CommandPolicy.registered(for:kind).firstSubmissionWindowMilliseconds==120_000)
            #expect(V2CommandPolicy.registered(for:kind).maximumAutomaticAttempts==5)
        }
    }
}
