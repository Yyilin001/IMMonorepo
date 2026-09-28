import Foundation
import Testing
@testable import IMV2Core

@Suite("Reaction own-key execution") struct MessageReactionOperationTests {
    @Test func frozenBindingAndBaselineValidation() throws {
        let room=RoomID(uuid:UUID()),actor=UserID(uuid:UUID()),message=MessageID(uuid:UUID()),operation=MessageReactionOperationID(uuid:UUID())
        let domain=try V2ChangeMessageReactionCommand(roomID:room,actorUserID:actor,operationID:operation,messageID:message,reaction:"e\u{301}",action:.add)
        let frozen=try V2MessageReactionOperationCommand(command:domain,expectedReactionRevision:0,firstSubmissionDeadlineMilliseconds:1000)
        let newer=try V2MessageReactionOperationCommand(command:domain,expectedReactionRevision:1,firstSubmissionDeadlineMilliseconds:1000)
        #expect(try frozen.identity==newer.identity)
        #expect(try frozen.fingerprint != newer.fingerprint)
        #expect(frozen.reaction=="é" && frozen.targetState == .present)
        #expect(try JSONDecoder().decode(V2MessageReactionOperationCommand.self,from:JSONEncoder().encode(frozen))==frozen)
        #expect(throws:V2MessageOperationValidationError.self) { _ = try V2MessageReactionSnapshot(roomID:room,actorUserID:actor,messageID:message,reaction:"👍",targetState:.present,revision:0) }
        let receipt=try V2MessageReactionReceipt(identity:frozen.identity,fingerprint:frozen.fingerprint,outcome:.committed(.init(targetState:.present,revision:1,event:nil)),resolvedAtMilliseconds:1000)
        #expect(try receipt.validates(identity:frozen.identity,fingerprint:frozen.fingerprint))
        #expect(try JSONDecoder().decode(V2MessageReactionReceipt.self,from:JSONEncoder().encode(receipt))==receipt)
        let hint=try V2MessageOperationRetryHint(identity:frozen.identity,fingerprint:frozen.fingerprint,reason:.rateLimited,retryAfterMilliseconds:1000)
        #expect(try hint.validates(identity:frozen.identity,fingerprint:frozen.fingerprint))
    }
}
