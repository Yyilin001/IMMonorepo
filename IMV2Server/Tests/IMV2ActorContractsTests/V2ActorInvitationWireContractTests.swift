import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("V2 actor invitation wire contract")
struct V2ActorInvitationWireContractTests {
    @Test func secretNeverAppearsInDescriptionAndBaselineKeepsActor() throws {
        let secret = V2ActorInviteSecretWire(rawValue: String(repeating: "x", count: 43))
        #expect(!secret.description.contains(secret.rawValue))
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID())
        let query = V2GroupInvitationOperationBaselineQuery(roomID: room, actorUserID: actor)
        let decoded = try JSONDecoder().decode(V2GroupInvitationOperationBaselineQuery.self, from: JSONEncoder().encode(query))
        #expect(decoded == query)
        #expect(secret.debugDescription == secret.description)
    }
}
