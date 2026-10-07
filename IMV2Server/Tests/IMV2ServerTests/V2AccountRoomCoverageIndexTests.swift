@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Shared account room coverage")
struct V2AccountRoomCoverageIndexTests {
    @Test("revocation history refuses overflow and rejoin releases its slot")
    func boundedRevocationHistory() throws {
        let index = V2AccountRoomCoverageIndex(maximumRevokedRoomsPerAccount: 1)
        let user = UserID(uuid: UUID()), first = RoomID(uuid: UUID()), second = RoomID(uuid: UUID())
        let ticket = try index.begin(userID: user, connectionID: UUID())
        let old = V2AccountRoomCoverageIndex.Entry(roomID: first, viewerMembershipRevision: 0, ownerEpoch: 0)
        try index.install([old, .init(roomID: second, viewerMembershipRevision: 0, ownerEpoch: 0)], ticket: ticket)
        try index.revoke(userID: user, roomID: first, revision: 0)
        try index.revoke(userID: user, roomID: first, revision: 0)
        #expect(throws: V2AccountRoomCoverageIndex.Failure.revocationHistoryFull) {
            try index.revoke(userID: user, roomID: second, revision: 0)
        }
        try index.install([old], ticket: ticket)
        #expect(index.candidate(roomID: first, userID: user) == nil)
        #expect(index.candidate(roomID: second, userID: user) != nil)
        try index.install([V2AccountRoomCoverageIndex.Entry(roomID: first, viewerMembershipRevision: 1, ownerEpoch: 0)], ticket: ticket)
        try index.revoke(userID: user, roomID: second, revision: 0)
        try index.install([old], ticket: ticket)
        #expect(index.candidate(roomID: first, userID: user)?.membershipRevision == 1)
        index.end(ticket)
        let fresh = try index.begin(userID: user, connectionID: UUID())
        try index.install([old], ticket: fresh)
        #expect(index.candidate(roomID: first, userID: user)?.membershipRevision == 0)
    }
    @Test("initial revision zero is authorized until an explicit removal fence exists")
    func initialZeroMembership() throws {
        let index = V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let ticket = try index.begin(userID: user, connectionID: UUID())
        let initial = try V2UserRoomDirectoryEntry(roomID: room, roomKind: .group,
            viewerMembershipRevision: 0, ownerEpoch: 0)
        try index.install([initial], ticket: ticket)
        #expect(index.candidates(roomID: room).first?.membershipRevision == 0)
        try index.revoke(userID: user, roomID: room, revision: 0)
        try index.install([initial], ticket: ticket)
        #expect(index.candidates(roomID: room).isEmpty)
        let rejoined = try V2UserRoomDirectoryEntry(roomID: room, roomKind: .group,
            viewerMembershipRevision: 1, ownerEpoch: 0)
        try index.install([rejoined], ticket: ticket)
        #expect(index.candidates(roomID: room).first?.membershipRevision == 1)
    }
    @Test("room memberships are shared across connections without a 128 room ceiling", arguments: [1000, 10000])
    func sharedMemberships(count: Int) async throws {
        let index = V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID())
        let first = try index.begin(userID: user, connectionID: UUID())
        let second = try index.begin(userID: user, connectionID: UUID())
        let rooms = try (0..<count).map { _ in try entry() }
        for start in stride(from: 0, to: rooms.count, by: 100) {
            try index.install(Array(rooms[start..<start + 100]), ticket: first)
        }
        let metrics = index.metrics()
        #expect(metrics.accounts == 1 && metrics.connections == 2 && metrics.memberships == count)
        #expect(rooms.allSatisfy { index.candidates(roomID: $0.roomID).count == 1 })
        #expect(index.next(ticket: first) == nil && index.next(ticket: second) == nil)
        index.end(first)
        #expect(index.metrics().memberships == count)
        #expect(rooms.allSatisfy { !index.candidates(roomID: $0.roomID).isEmpty })
        index.end(second)
        #expect(rooms.allSatisfy { index.candidates(roomID: $0.roomID).isEmpty })
        #expect(index.metrics().memberships == 0)
    }

    @Test("revocation fences late directory responses and preserves a newer membership")
    func revocation() async throws {
        let index = V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID()), room = try entry()
        let ticket = try index.begin(userID: user, connectionID: UUID())
        try index.install([room], ticket: ticket)
        try index.revoke(userID: user, roomID: room.roomID, revision: 2)
        try index.install([room], ticket: ticket)
        #expect(index.candidates(roomID: room.roomID).isEmpty)
        #expect(index.next(ticket: ticket) == nil)
        let rejoined = try V2UserRoomDirectoryEntry(roomID: room.roomID, roomKind: room.roomKind,
            viewerMembershipRevision: 3, ownerEpoch: room.ownerEpoch)
        try index.install([rejoined], ticket: ticket)
        let fresh = try #require(index.candidates(roomID: room.roomID).first)
        try index.revoke(userID: user, roomID: room.roomID, revision: 2)
        #expect(index.candidates(roomID: room.roomID).first == fresh)
        #expect(fresh.membershipRevision == 3)
        #expect(index.next(ticket: ticket) == nil)
    }

    @Test("old connection cleanup cannot affect a replacement account lifecycle")
    func replacement() async throws {
        let index = V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID()), connection = UUID(), room = try entry()
        let old = try index.begin(userID: user, connectionID: connection)
        try index.install([room], ticket: old)
        index.end(old)
        let current = try index.begin(userID: user, connectionID: connection)
        try index.install([room], ticket: current)
        index.end(old)
        #expect(index.isCurrent(current))
        #expect(index.next(ticket: current) == nil)
    }

    @Test("coverage invalidation emits one boundary per device and cannot repeat")
    func recoveryBoundary() throws {
        let index = V2AccountRoomCoverageIndex(), user = UserID(uuid: UUID())
        let first = try index.begin(userID: user, connectionID: UUID())
        let second = try index.begin(userID: user, connectionID: UUID())
        #expect(!index.hasPending(ticket: first))
        index.invalidate(userID: user)
        index.invalidate(userID: user)
        for ticket in [first, second] {
            #expect(index.hasPending(ticket: ticket))
            let notification = try #require(index.next(ticket: ticket))
            #expect(notification == .resyncRequired(epoch: ticket.epoch))
            #expect(notification.envelope().accountRoomResyncRequired.connectionEpoch == ticket.epoch.uuidString.lowercased())
            #expect(!index.hasPending(ticket: ticket))
            index.invalidate(userID: user)
            #expect(index.next(ticket: ticket) == nil)
        }
    }

    private func entry() throws -> V2UserRoomDirectoryEntry {
        try .init(roomID: .init(uuid: UUID()), roomKind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)
    }
}
