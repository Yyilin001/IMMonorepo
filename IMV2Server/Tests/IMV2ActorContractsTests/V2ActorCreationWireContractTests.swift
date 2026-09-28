import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("V2 actor creation wire contract")
struct V2ActorCreationWireContractTests {
    @Test func coordinatorAndOwnerLanesKeepStableIdentity() throws {
        let actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let operation = GroupRoomOperationID(uuid: UUID())
        let identity = try V2OperationIdentity(accountID: actor, scope: .account(actor), operation: .groupRoom(operation))
        let intent = try V2GroupCreationIntent(identity: identity, title: "Team", capacityClass: .standard,
            initialMemberCount: 0, audienceDigest: V2GroupCreationAudience.digest([]), firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
        let placement = V2ActorGroupCreationIntentWire(actorUserID: actor, operationID: operation, roomID: room,
            eventID: EventID(uuid: UUID()), roomShardID: "room-a", routeEpoch: 0,
            requestFingerprint: try intent.fingerprint.digest, audienceMemberCount: 1, state: .prepared)
        let create = V2ActorRoomBootstrapCommand.provenGroup(.init(intent: intent, placement: placement))
        let decoded = try JSONDecoder().decode(V2ActorRoomBootstrapCommand.self, from: JSONEncoder().encode(create))
        #expect(decoded == create)
        #expect(decoded.roomID == room)
        #expect(decoded.retryPolicy == .durableIdempotent)
    }
}
