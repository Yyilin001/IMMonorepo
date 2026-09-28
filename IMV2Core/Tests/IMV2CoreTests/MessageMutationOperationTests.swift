import Foundation
import Testing
@testable import IMV2Core

@Suite("Frozen message mutations") struct MessageMutationOperationTests {
    @Test func bindingAndValidatedDecoding() throws {
        let room=RoomID(uuid:UUID()),actor=UserID(uuid:UUID()),message=MessageID(uuid:UUID()),operation=MessageEditOperationID(uuid:UUID())
        let domain=try V2EditMessageCommand(roomID:room,actorUserID:actor,operationID:operation,messageID:message,expectedMessageRevision:1,text:"Exact é",maximumUTF8Bytes:64)
        let a=try V2MessageEditOperationCommand(command:domain,firstSubmissionDeadlineMilliseconds:1000)
        let b=try V2MessageEditOperationCommand(command:domain,firstSubmissionDeadlineMilliseconds:1001)
        #expect(try a.identity==b.identity && a.fingerprint != b.fingerprint)
        #expect(try JSONDecoder().decode(V2MessageEditOperationCommand.self,from:JSONEncoder().encode(a))==a)
        #expect(throws:V2MessageOperationValidationError.invalidDeadline) { try V2MessageEditOperationCommand(command:domain,firstSubmissionDeadlineMilliseconds:0) }
        let commit=try V2MessageMutationCommit(messageID:message,messageRevision:2,roomSequence:3,eventID:.init(uuid:UUID()))
        let receipt=try V2MessageMutationReceipt(identity:a.identity,fingerprint:a.fingerprint,outcome:.committed(commit),resolvedAtMilliseconds:1000)
        #expect(try JSONDecoder().decode(V2MessageMutationReceipt.self,from:JSONEncoder().encode(receipt))==receipt)
        #expect(try !receipt.validates(identity:b.identity,fingerprint:b.fingerprint))
        #expect(throws:V2MessageOperationValidationError.invalidReceipt) { try V2MessageMutationCommit(messageID:message,messageRevision:0,roomSequence:3,eventID:.init(uuid:UUID())) }
    }
}

@Suite("Frozen sends preserve domain fingerprint") struct MessageSendOperationTests {
    @Test func executionEnvelopeBinding() throws {
        let domain=try V2SendMessageCommand(roomID:.init(uuid:UUID()),senderUserID:.init(uuid:UUID()),clientMessageID:.init(uuid:UUID()),text:"Original",limits:.init(maxUTF8Bytes:64))
        let a=try V2MessageSendOperationCommand(command:domain,firstSubmissionDeadlineMilliseconds:1000)
        let b=try V2MessageSendOperationCommand(command:domain,firstSubmissionDeadlineMilliseconds:1001)
        #expect(a.command.fingerprint==b.command.fingerprint && domain.fingerprint.version==3)
        #expect(try a.fingerprint.version==1 && a.fingerprint != b.fingerprint)
        #expect(try JSONDecoder().decode(V2MessageSendOperationCommand.self,from:JSONEncoder().encode(a))==a)
        let hint=try V2MessageOperationRetryHint(identity:a.identity,fingerprint:a.fingerprint,reason:.rateLimited,retryAfterMilliseconds:2000)
        #expect(try JSONDecoder().decode(V2MessageOperationRetryHint.self,from:JSONEncoder().encode(hint))==hint)
        #expect(throws:V2MessageOperationValidationError.invalidReceipt) { try V2MessageOperationRetryHint(identity:a.identity,fingerprint:a.fingerprint,reason:.rateLimited,retryAfterMilliseconds:0) }
        let acceptance=try V2MessageOperationAcceptance(messageID:.init(uuid:UUID()),roomSequence:1)
        let receipt=try V2MessageSendOperationReceipt(identity:a.identity,fingerprint:a.fingerprint,outcome:.accepted(acceptance),resolvedAtMilliseconds:1000)
        #expect(try JSONDecoder().decode(V2MessageSendOperationReceipt.self,from:JSONEncoder().encode(receipt))==receipt)
        #expect(try !receipt.validates(identity:b.identity,fingerprint:b.fingerprint))
    }
}
