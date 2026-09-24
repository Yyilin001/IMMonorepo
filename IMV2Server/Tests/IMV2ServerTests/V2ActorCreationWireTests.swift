import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
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

    @Test func fullRoomOutcomesAndCoordinatorCommands() throws {
        let direct = V2ActorOpenDirectRoomWire(actorUserID: actor, operationID: try DirectRoomOperationID("direct-op"), targetUserID: member)
        #expect(try roundTrip(V2ActorRoomCreationCommand.openDirect(direct)).stableOperationIdentity == .direct(direct.operationID))
        #expect(try direct.toDomain().targetUserID == member)
        let directRoom = V2DirectRoom(roomID: roomID, actorUserID: actor, targetUserID: member, createdAt: now)
        #expect(try roundTrip(V2ActorOpenDirectRoomOutcomeWire(domain: .idempotent(directRoom))).toDomain() == .idempotent(directRoom))
        let group = V2ActorCreateGroupRoomWire(actorUserID: actor, operationID: operationID, title: "Team", initialMemberUserIDs: [member])
        let domain = try group.toDomain(capacityClass: .standard)
        #expect(try roundTrip(group).toDomain(capacityClass: .standard) == domain)
        let groupRoom = try V2GroupRoom(roomID: roomID, ownerUserID: actor, title: "Team", capacityClass: .standard,
                                        memberUserIDs: [actor, member], memberCount: 7, createdAt: now)
        #expect(try roundTrip(V2ActorCreateGroupRoomOutcomeWire(domain: .created(groupRoom))).toDomain() == .created(groupRoom))
        let audience = try V2GroupAudienceImport(actorUserID: actor, operationID: operationID,
                                                   title: "Team", memberUserIDs: [member])
        #expect(try roundTrip(V2ActorGroupAudienceImportWire(domain: audience)).toDomain() == audience)
        let append = V2ActorStagedGroupAppendWire(actorUserID: actor, operationID: operationID, memberUserIDs: [member])
        #expect(try roundTrip(append).validatedMemberUserIDs() == [member])
        #expect(throws: V2GroupAudienceImportError.invalidInput) {
            try V2ActorStagedGroupAppendWire(actorUserID: actor, operationID: operationID, memberUserIDs: []).validatedMemberUserIDs()
        }
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
