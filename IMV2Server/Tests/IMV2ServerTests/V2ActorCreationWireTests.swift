@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 actor creation wire")
struct V2ActorCreationWireTests {
    private let actor = try! UserID("actor-a")
    private let member = try! UserID("member-b")
    private let roomID = try! RoomID("room-c")
    private let eventID = try! EventID("event-d")
    private let operationID = try! GroupRoomOperationID("group-op")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func frozenIntentAndManifestVerifyDigest() throws {
        let intent = try V2GroupRoomCreationIntent(actorUserID: actor, operationID: operationID, roomID: roomID,
                                                    eventID: eventID, roomShardID: "shard-a", routeEpoch: 0,
                                                    requestFingerprint: Data(repeating: 3, count: 32), audienceMemberCount: 2)
        #expect(try roundTrip(V2ActorGroupCreationIntentWire(domain: intent)).toDomain() == intent)
        let page = try V2GroupRoomCreationManifestPage(pageNumber: 0, memberUserIDs: [actor, member], isFinal: true)
        #expect(try roundTrip(V2ActorGroupCreationManifestPageWire(domain: page)).toDomain() == page)
        #expect(throws: V2GroupRoomCreationIntentStoreError.invalidIntent) {
            try V2ActorGroupCreationManifestPageWire(pageNumber: 0, memberUserIDs: page.memberUserIDs,
                                                       isFinal: true, digest: Data(repeating: 0, count: 32)).toDomain()
        }
        #expect(throws: V2GroupRoomCreationIntentStoreError.invalidIntent) {
            try V2ActorGroupCreationIntentWire(actorUserID: actor, operationID: operationID, roomID: roomID,
                                                eventID: eventID, roomShardID: "shard-a", routeEpoch: -1,
                                                requestFingerprint: Data(repeating: 3, count: 32), audienceMemberCount: 2,
                                                state: .prepared).toDomain()
        }
    }
}
