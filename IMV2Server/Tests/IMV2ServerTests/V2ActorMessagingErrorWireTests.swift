@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2ActorMessagingErrorWireTests {
    @Test("closed domain errors survive the response and facade boundary")
    func roundTrip() throws {
        let errors: [V2ActorMessagingErrorWire] =
            V2ActorMessagingSendStoreErrorWire.allCases.map { .sendStore($0) }
            + V2ActorMessagingEditStoreErrorWire.allCases.map { .editStore($0) }
            + V2ActorMessagingWithdrawalStoreErrorWire.allCases.map { .withdrawalStore($0) }
            + V2ActorMessagingReactionStoreErrorWire.allCases.map { .reactionStore($0) }
            + V2ActorMessagingSendValidationErrorWire.allCases.map { .sendValidation($0) }
            + V2ActorMessagingEditValidationErrorWire.allCases.map { .editValidation($0) }
            + V2ActorMessagingReactionValidationErrorWire.allCases.map { .reactionValidation($0) }
            + V2ActorMessagingRevisionErrorWire.allCases.map { .revision($0) }
            + V2ActorMessagingContentErrorWire.allCases.map { .content($0) }
            + V2ActorMessagingMentionErrorWire.allCases.map { .mention($0) }
            + V2ActorMessagingMediaErrorWire.allCases.map { .media($0) }
            + V2ActorMessagingCoreErrorWire.allCases.map { .core($0) }
            + V2ActorMessagingMappingErrorWire.allCases.map { .mapping($0) }
        for failure in errors {
            let response = V2RoomResponse.messaging(.failure(failure))
            #expect(try JSONDecoder().decode(V2RoomResponse.self,
                from: JSONEncoder().encode(response)) == response)
            #expect(V2ActorMessagingErrorWire(domainError: failure.domainError()) == failure)
        }
    }

    @Test("unknown COMMIT, lease failures and cancellation never become domain results")
    func infrastructureIsNotDomain() {
        #expect(V2ActorMessagingErrorWire(domainError: V2RoomTransactionOutcomeUnknown()) == nil)
        #expect(V2ActorMessagingErrorWire(domainError: V2RoomActivationLeaseError.leaseExpired) == nil)
        #expect(V2ActorMessagingErrorWire(domainError: V2RoomCallFailure.outcomeUnknown) == nil)
        #expect(V2ActorMessagingErrorWire(domainError: CancellationError()) == nil)
    }
}
