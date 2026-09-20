import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Shared account room coverage")
struct V2AccountRoomCoverageIndexTests {
    @Test("room memberships are shared across connections without a 128 room ceiling", arguments: [1000, 10000])
    func sharedMemberships(count: Int) async throws {
        let index = try V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID())
        let first = try index.begin(userID: user, connectionID: UUID())
        let second = try index.begin(userID: user, connectionID: UUID())
        let rooms = try (0..<count).map { _ in try entry() }
        for start in stride(from: 0, to: rooms.count, by: 100) {
            _ = try index.install(Array(rooms[start..<start + 100]), ticket: first)
        }
        let metrics = index.metrics()
        #expect(metrics.accounts == 1 && metrics.connections == 2 && metrics.memberships == count)
        let room = rooms[count - 1]
        let candidate = try #require(index.candidates(roomID: room.roomID).first)
        try index.enqueueAuthorized(state(room), candidate: candidate)
        #expect(index.next(ticket: first) == .changed(epoch: first.epoch, sequence: 1, roomID: room.roomID, highWatermark: 8))
        #expect(index.next(ticket: second) == .changed(epoch: second.epoch, sequence: 1, roomID: room.roomID, highWatermark: 8))
        // Drain each bounded batch before offering the next. A large directory
        // must not be confused with the connection's unsent notification limit.
        var sequence: UInt64 = 1
        for start in stride(from: 0, to: rooms.count, by: 100) {
            let batch = Array(rooms[start..<start + 100])
            for room in batch {
                let candidate = try #require(index.candidates(roomID: room.roomID).first)
                try index.enqueueAuthorized(state(room), candidate: candidate)
            }
            for room in batch {
                sequence += 1
                for ticket in [first, second] {
                    #expect(index.next(ticket: ticket) == .changed(epoch: ticket.epoch,
                        sequence: sequence, roomID: room.roomID, highWatermark: 8))
                }
            }
        }
        #expect(index.next(ticket: first) == nil && index.next(ticket: second) == nil)
        #expect(index.end(first).isEmpty)
        #expect(index.end(second).count == count)
        #expect(index.metrics().memberships == 0)
    }

    @Test("revocation drops queued metadata and fences late directory and authorization responses")
    func revocation() async throws {
        let index = try V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID()), room = try entry()
        let ticket = try index.begin(userID: user, connectionID: UUID())
        _ = try index.install([room], ticket: ticket)
        let candidate = try #require(index.candidates(roomID: room.roomID).first)
        try index.enqueueAuthorized(state(room), candidate: candidate)
        try index.revoke(userID: user, roomID: room.roomID, revision: 2)
        _ = try index.install([room], ticket: ticket)
        try index.enqueueAuthorized(state(room), candidate: candidate)
        #expect(index.candidates(roomID: room.roomID).isEmpty)
        #expect(index.next(ticket: ticket) == nil)
        let rejoined = try V2UserRoomDirectoryEntry(roomID: room.roomID, roomKind: room.roomKind,
            viewerMembershipRevision: 3, ownerEpoch: room.ownerEpoch)
        _ = try index.install([rejoined], ticket: ticket)
        let fresh = try #require(index.candidates(roomID: room.roomID).first)
        try index.revoke(userID: user, roomID: room.roomID, revision: 2)
        try index.enqueueAuthorized(state(rejoined), candidate: fresh)
        #expect(index.next(ticket: ticket) == .changed(epoch: ticket.epoch, sequence: 1,
            roomID: room.roomID, highWatermark: 8))
    }

    @Test("old connection cleanup and authorization cannot affect a replacement account lifecycle")
    func replacement() async throws {
        let index = try V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID()), connection = UUID(), room = try entry()
        let old = try index.begin(userID: user, connectionID: connection)
        _ = try index.install([room], ticket: old)
        let candidate = try #require(index.candidates(roomID: room.roomID).first)
        _ = index.end(old)
        let current = try index.begin(userID: user, connectionID: connection)
        _ = try index.install([room], ticket: current)
        _ = index.end(old)
        try index.enqueueAuthorized(state(room), candidate: candidate)
        #expect(index.isCurrent(current))
        #expect(index.next(ticket: current) == nil)
    }

    @Test("an owner mismatch emits recovery instead of unverified metadata")
    func mismatch() async throws {
        let index = try V2AccountRoomCoverageIndex()
        let user = UserID(uuid: UUID()), room = try entry()
        let ticket = try index.begin(userID: user, connectionID: UUID())
        _ = try index.install([room], ticket: ticket)
        let candidate = try #require(index.candidates(roomID: room.roomID).first)
        let moved = try V2RoomSynchronizationState(roomID: room.roomID, ownerEpoch: 2,
            viewerMembershipRevision: 1, head: 8, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        try index.enqueueAuthorized(moved, candidate: candidate)
        #expect(index.next(ticket: ticket) == .resyncRequired(epoch: ticket.epoch))
    }

    private func entry() throws -> V2UserRoomDirectoryEntry {
        try .init(roomID: .init(uuid: UUID()), roomKind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)
    }
    private func state(_ entry: V2UserRoomDirectoryEntry) throws -> V2RoomSynchronizationState {
        try .init(roomID: entry.roomID, ownerEpoch: entry.ownerEpoch,
            viewerMembershipRevision: entry.viewerMembershipRevision, head: 8,
            trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
    }
}
