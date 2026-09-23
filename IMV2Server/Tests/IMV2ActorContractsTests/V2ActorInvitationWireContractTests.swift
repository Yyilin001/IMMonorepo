import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("V2 actor invitation wire contract")
struct V2ActorInvitationWireContractTests {
    @Test func secretNeverAppearsInDescriptionAndCancellationHasNoReplayID() throws {
        let secret = V2ActorInviteSecretWire(rawValue: String(repeating: "x", count: 43))
        #expect(!secret.description.contains(secret.rawValue))
        let command = V2RoomInvitationCommand.cancel(.init(roomID: try RoomID("room-a"),
            requestID: try GroupJoinRequestID("request-b"), applicantUserID: try UserID("actor-c")))
        #expect(try JSONDecoder().decode(V2RoomInvitationCommand.self, from: JSONEncoder().encode(command)) == command)
        #expect(command.stableOperationIdentity == nil)
        #expect(command.retryPolicy == .noAutomaticRetry)
    }
}
