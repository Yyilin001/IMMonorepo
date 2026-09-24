import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("V2 actor creation wire contract")
struct V2ActorCreationWireContractTests {
    @Test func coordinatorAndOwnerLanesKeepStableIdentity() throws {
        let actor = try UserID("actor-a")
        let operation = try GroupRoomOperationID("group-op")
        let create = V2ActorRoomCreationCommand.createGroup(.init(actorUserID: actor,
            operationID: operation, title: "Team", initialMemberUserIDs: []))
        let decoded = try JSONDecoder().decode(V2ActorRoomCreationCommand.self, from: JSONEncoder().encode(create))
        #expect(decoded == create)
        #expect(decoded.stableOperationIdentity == .group(operation))
        #expect(decoded.retryPolicy == .durableIdempotent)
    }
}
