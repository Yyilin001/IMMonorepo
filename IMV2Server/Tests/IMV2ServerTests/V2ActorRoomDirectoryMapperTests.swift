@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Room directory domain mapping")
struct V2ActorRoomDirectoryMapperTests {
    @Test("membership identity, actor role, cursor, role baseline and user-room topology survive")
    func fullFields() throws {
        let room = try RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let user = try UserID("user-1")
        let identity = try V2PublicIdentity(userID: user, handle: V2PublicHandle("member_1"),
            displayName: "Member One", accountKind: .regular)
        let member = V2RoomMembershipDirectoryEntry(userID: user, role: .admin,
                                                     publicIdentity: identity)
        let page = V2RoomMembershipDirectoryPage(roomID: room, membershipRevision: 5,
            actorRole: .owner, entries: [member], nextCursor: "next")
        let pageWire = V2ActorMembershipDirectoryPageWire(page)
        #expect(try pageWire.domainValue() == page)
        #expect(try JSONDecoder().decode(V2ActorMembershipDirectoryPageWire.self,
            from: JSONEncoder().encode(pageWire)) == pageWire)
        let baseline = try V2GroupRolePolicyBaseline(roomID: room, permissionRevision: 7,
            membershipRevision: 5, roomSequence: 11,
            adminPermissions: [.sendMessages, .inviteMembers],
            memberPermissions: [.sendMessages])
        let baselineWire = V2ActorRoleBaselineWire(baseline)
        #expect(try baselineWire.domainValue() == baseline)
        #expect(try JSONDecoder().decode(V2ActorRoleBaselineWire.self,
            from: JSONEncoder().encode(baselineWire)) == baselineWire)
        let entry = try V2UserRoomDirectoryEntry(roomID: room, roomKind: .group,
            viewerMembershipRevision: 5, ownerEpoch: 0)
        let coordinatorPage = V2UserRoomDirectoryPage(rooms: [entry],
            nextCursor: "next-topology", topologyGeneration: "generation-1")
        let coordinatorWire = V2ActorUserRoomDirectoryPageWire(coordinatorPage)
        let restored = try coordinatorWire.domainValue()
        #expect(restored.rooms == coordinatorPage.rooms)
        #expect(restored.nextCursor == coordinatorPage.nextCursor)
        #expect(restored.topologyGeneration == coordinatorPage.topologyGeneration)
        let slice = V2UserRoomDirectorySlice(entries: [entry], scannedThrough: room, hasMore: true)
        let sliceWire = V2ActorUserRoomDirectorySliceWire(slice)
        let restoredSlice = try sliceWire.domainValue()
        #expect(restoredSlice.entries == slice.entries)
        #expect(restoredSlice.scannedThrough == room)
        #expect(restoredSlice.hasMore)
    }

    @Test("malformed public identity, duplicate permissions and versions fail safely")
    func invalid() throws {
        let room = try RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let user = try UserID("user-1")
        let other = try UserID("user-2")
        let identity = V2ActorPublicIdentityWire(userID: other, handle: "member_2",
            displayName: "Member", accountKind: .regular)
        let entry = V2ActorMembershipDirectoryEntryWire(userID: user, role: .member,
            publicIdentity: identity)
        #expect(throws: V2ActorRoomDirectoryWireError.invalidIdentity) {
            try entry.domainValue()
        }
        let page = V2ActorMembershipDirectoryPageWire(roomID: room,
            membershipRevision: UInt64(Int64.max) + 1, actorRole: .owner,
            entries: [], nextCursor: nil)
        #expect(throws: V2RoomMembershipDirectoryError.corruptPersistenceState) {
            try page.domainValue()
        }
        let baseline = V2ActorRoleBaselineWire(roomID: room, permissionRevision: 1,
            membershipRevision: 0, roomSequence: 0,
            adminPermissions: [.sendMessages, .sendMessages], memberPermissions: [])
        #expect(throws: V2ActorRoomDirectoryWireError.invalidPage) {
            try baseline.domainValue()
        }
        let invalidEntry = V2ActorUserRoomDirectoryEntryWire(roomID: room, roomKind: .direct,
            viewerMembershipRevision: 0, ownerEpoch: 0)
        #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
            try invalidEntry.domainValue()
        }
        let missingProgress = V2ActorUserRoomDirectorySliceWire(entries: [],
            scannedThrough: nil, hasMore: true)
        #expect(throws: V2ActorRoomDirectoryWireError.invalidPage) {
            try missingProgress.domainValue()
        }
    }
}

@Suite("Room directory error mapping")
struct V2ActorRoomDirectoryErrorMapperTests {
    @Test("revision conflict and membership or baseline failures remain distinct")
    func failures() throws {
        let conflict = V2RoomMembershipDirectoryError.revisionConflict(currentRevision: 7)
        let wire = V2ActorMembershipDirectoryErrorWire(conflict)
        #expect(wire.domainValue() == conflict)
        #expect(try JSONDecoder().decode(V2RoomDirectoryResult.self,
            from: JSONEncoder().encode(V2RoomDirectoryResult.membershipFailure(wire)))
            == .membershipFailure(wire))
        let baseline = V2ActorRoleBaselineErrorWire(V2GroupRolePolicyBaselineError.actorNotMember)
        #expect(baseline.domainValue() == .actorNotMember)
        #expect(try JSONDecoder().decode(V2RoomDirectoryResult.self,
            from: JSONEncoder().encode(V2RoomDirectoryResult.roleBaselineFailure(baseline)))
            == .roleBaselineFailure(baseline))
        let userResult = V2ActorUserRoomDirectoryResultWire.failure(.topologyChanged)
        #expect(try JSONDecoder().decode(V2ActorUserRoomDirectoryResultWire.self,
            from: JSONEncoder().encode(userResult)) == userResult)
    }
}
