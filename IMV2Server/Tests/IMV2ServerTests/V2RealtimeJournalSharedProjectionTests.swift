import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import Testing
@testable import IMV2ServerGateway

@Suite("Shared journal projection application")
struct V2RealtimeJournalSharedProjectionTests {
    @Test("filtered skip ranges commit a real checkpoint and room heads only grow")
    func filteredRangeAndSharedHead() throws {
        let fixture = Fixture(), projection = V2RealtimeJournalSharedProjection()
        #expect(projection.requireSnapshot(source: fixture.source, fence: fixture.fence, expectedRooms: [fixture.room], requestedViewers: [fixture.user]))
        let snapshot = fixture.batch(.snapshot(cut: 5, rooms: [fixture.authorization(head: 6)]))
        #expect(projection.apply(snapshot, isCurrent: { _, _ in true }) == .snapshotRequired)
        let installed = projection.installAuthoritativeSnapshot(snapshot, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true })
        guard case .applied(let proof) = installed else { Issue.record("snapshot did not commit"); return }
        #expect(proof.snapshotInstalled && proof.appliedThrough == 5 && proof.batchID == snapshot.batchID)
        let filtered = fixture.batch(.changes(fromExclusive: 5, throughInclusive: 9, entries: []))
        guard case .applied(let skipped) = projection.apply(filtered, isCurrent: { _, _ in true }) else {
            Issue.record("filtered skip coverage did not commit"); return
        }
        #expect(skipped.appliedThrough == 9 && !skipped.snapshotInstalled)
        let head = fixture.batch(.changes(fromExclusive: 9, throughInclusive: 12, entries: [
            .init(sequence: 10, change: .head(roomID: fixture.room, highWatermark: 8, ownerEpoch: 1, permissionVersion: 3)),
            .init(sequence: 12, change: .head(roomID: fixture.room, highWatermark: 7, ownerEpoch: 1, permissionVersion: 3))
        ]))
        guard case .applied(let receipt) = projection.apply(head, isCurrent: { _, _ in true }) else {
            Issue.record("head did not commit"); return
        }
        #expect(receipt.appliedThrough == 12)
        for _ in 0..<1000 {
            #expect(projection.room(fixture.room, isCurrent: { _, _ in true })?.highWatermark == 8)
        }
        // Device fanout reads the same room map; no device grants are allocated.
        #expect(projection.metrics().rooms == 1 && projection.metrics().viewers == 1)
        let independent = fixture.batch(.heads([.init(roomID: fixture.room, highWatermark: 10, ownerEpoch: 1, controlVersion: 3)]))
        guard case .headsApplied(let headProof) = projection.applyHeads(independent, isCurrent: { _, _ in true }) else {
            Issue.record("independent head did not commit"); return
        }
        #expect(headProof.batchID == independent.batchID && headProof.source == fixture.source)
        guard case .applied(let unchangedCut) = projection.apply(
            fixture.batch(.changes(fromExclusive: 12, throughInclusive: 12, entries: [])),
            isCurrent: { _, _ in true }) else { Issue.record("control checkpoint was lost"); return }
        #expect(unchangedCut.appliedThrough == 12)
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true })?.highWatermark == 10)
        let writes = Mutex(0)
        let authorizedWrite1 = projection.withAuthorizedRoom(fixture.room, userID: fixture.user, expectedMemberRevision: 1,
            isCurrent: { _, _ in true }, enqueue: { writes.withLock { $0 += 1 } })
        #expect(authorizedWrite1)
        let authorizedWrite2 = projection.withAuthorizedRoom(fixture.room, userID: fixture.user, expectedMemberRevision: 2,
            isCurrent: { _, _ in true }, enqueue: { writes.withLock { $0 += 1 } })
        #expect(!authorizedWrite2)
        #expect(writes.withLock { $0 } == 1)
        let revoked = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 1,
            permissionVersion: 4, controlVersion: 4, viewerMembershipRevisions: [:], highWatermark: 8)
        let control = fixture.batch(.changes(fromExclusive: 12, throughInclusive: 14, entries: [
            .init(sequence: 13, change: .authorization(revoked)),
            .init(sequence: 14, change: .head(roomID: fixture.room, highWatermark: 9, ownerEpoch: 1, permissionVersion: 4))
        ]))
        #expect(projection.apply(control, isCurrent: { _, _ in true }) == .snapshotRequired)
        let authorizedWrite3 = projection.withAuthorizedRoom(fixture.room, userID: fixture.user,
            isCurrent: { _, _ in true }, enqueue: { writes.withLock { $0 += 1 } })
        #expect(!authorizedWrite3)
        #expect(writes.withLock { $0 } == 1)
        #expect(projection.metrics().viewers == 0)
        let revokedSnapshot = fixture.batch(.snapshot(cut: 14, rooms: [revoked]))
        guard case .applied = projection.installAuthoritativeSnapshot(revokedSnapshot, expectedCut: 14,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) else {
            Issue.record("revoked current-state snapshot did not commit"); return
        }
        let authorizedWrite4 = projection.withAuthorizedRoom(fixture.room, userID: fixture.user,
            isCurrent: { _, _ in true }, enqueue: { writes.withLock { $0 += 1 } })
        #expect(!authorizedWrite4)
        #expect(writes.withLock { $0 } == 1)
    }

    @Test("a control gap blocks content and requires a complete snapshot at or beyond the observed cut")
    func gapAndSnapshotCompleteness() {
        let fixture = Fixture(), projection = V2RealtimeJournalSharedProjection()
        let otherRoom = RoomID(uuid: UUID())
        #expect(projection.requireSnapshot(source: fixture.source, fence: fixture.fence, expectedRooms: [fixture.room, otherRoom], requestedViewers: [fixture.user]))
        let oneRoom = fixture.batch(.snapshot(cut: 5, rooms: [fixture.authorization(head: 6)]))
        #expect(projection.installAuthoritativeSnapshot(oneRoom, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) == .snapshotRequired)
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true }) == nil)
        let other = V2RealtimeJournalRoomAuthorization(roomID: otherRoom, ownerEpoch: 1, permissionVersion: 3, controlVersion: 3,
            viewerMembershipRevisions: [:], highWatermark: 0)
        let full = fixture.batch(.snapshot(cut: 5, rooms: [fixture.authorization(head: 6), other]))
        #expect(projection.installAuthoritativeSnapshot(full, expectedCut: 4,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) == .snapshotRequired)
        guard case .applied = projection.installAuthoritativeSnapshot(full, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) else {
            Issue.record("complete snapshot did not commit"); return
        }
        let gap = fixture.batch(.changes(fromExclusive: 6, throughInclusive: 9, entries: []))
        #expect(projection.apply(gap, isCurrent: { _, _ in true }) == .snapshotRequired)
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true }) == nil)
        let tooOld = fixture.batch(.snapshot(cut: 8, rooms: [fixture.authorization(head: 8), other]))
        #expect(projection.installAuthoritativeSnapshot(tooOld, expectedCut: 8,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) == .snapshotRequired)
        let fresh = fixture.batch(.snapshot(cut: 9, rooms: [fixture.authorization(head: 9), other]))
        #expect(projection.installAuthoritativeSnapshot(fresh, expectedCut: 9,
            authorizesSnapshot: { _ in false }, isCurrent: { _, _ in true }) == .stale)
        guard case .applied = projection.installAuthoritativeSnapshot(fresh, expectedCut: 9,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) else {
            Issue.record("fresh authorized snapshot did not commit"); return
        }
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true })?.highWatermark == 9)
    }

    @Test("old source leases cannot apply even while the routing session stays unchanged")
    func oldSourceLeaseAndBounds() {
        let fixture = Fixture(), projection = V2RealtimeJournalSharedProjection(limits: .init(partitions: 1, rooms: 1, viewers: 1))
        #expect(projection.requireSnapshot(source: fixture.source, fence: fixture.fence, expectedRooms: [fixture.room], requestedViewers: [fixture.user]))
        let changedLease = V2RealtimeJournalProjectionFence(publisherIncarnationID: fixture.fence.publisherIncarnationID,
            sourceLeaseEpoch: fixture.fence.sourceLeaseEpoch + 1, sourceLeaseToken: UUID(),
            sourceLeaseExpiresAt: fixture.fence.sourceLeaseExpiresAt,
            routingPartitionEpoch: fixture.fence.routingPartitionEpoch, routingLeaseToken: fixture.fence.routingLeaseToken,
            sessionID: fixture.fence.sessionID, interestGeneration: fixture.fence.interestGeneration,
            gatewayIncarnationID: fixture.fence.gatewayIncarnationID)
        let snapshot = fixture.batch(.snapshot(cut: 5, rooms: [fixture.authorization(head: 6)]))
        guard case .applied = projection.installAuthoritativeSnapshot(snapshot, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) else {
            Issue.record("snapshot did not commit"); return
        }
        #expect(projection.room(fixture.room, isCurrent: { _, fence in fence.sameGeneration(as: changedLease) }) == nil)
        #expect(projection.requireSnapshot(source: fixture.source, fence: changedLease, expectedRooms: [fixture.room], requestedViewers: [fixture.user]))
        #expect(projection.apply(fixture.batch(.changes(fromExclusive: 5, throughInclusive: 6, entries: [])),
            isCurrent: { _, _ in true }) == .stale)
        #expect(projection.installAuthoritativeSnapshot(snapshot, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) == .stale)
        let tooMany = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 1, permissionVersion: 3, controlVersion: 3,
            viewerMembershipRevisions: [fixture.user: 1, UserID(uuid: UUID()): 1], highWatermark: 6)
        let overLimit = V2RealtimeJournalProjectionBatch(source: fixture.source, fence: changedLease,
            payload: .snapshot(cut: 5, rooms: [tooMany]))
        #expect(projection.installAuthoritativeSnapshot(overLimit, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) == .snapshotRequired)
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true }) == nil)
    }

    @Test("a snapshot ahead of pending controls cannot resurrect a revoked grant")
    func snapshotControlFloorPreventsResurrection() {
        let fixture = Fixture(), projection = V2RealtimeJournalSharedProjection()
        #expect(projection.requireSnapshot(source: fixture.source, fence: fixture.fence,
            expectedRooms: [fixture.room], requestedViewers: [fixture.user]))
        let revoked = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 1,
            permissionVersion: 10, controlVersion: 10, viewerMembershipRevisions: [:], highWatermark: 6)
        let snapshot = fixture.batch(.snapshot(cut: 5, rooms: [revoked]))
        guard case .applied = projection.installAuthoritativeSnapshot(snapshot, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) else {
            Issue.record("ahead current-state snapshot did not commit"); return
        }
        let oldGrant = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 1,
            permissionVersion: 9, controlVersion: 9, viewerMembershipRevisions: [fixture.user: 1], highWatermark: 5)
        let pending = fixture.batch(.changes(fromExclusive: 5, throughInclusive: 7, entries: [
            .init(sequence: 6, change: .authorization(oldGrant)),
            .init(sequence: 7, change: .controlInvalidation(roomID: fixture.room, ownerEpoch: 1, controlVersion: 10))
        ]))
        guard case .applied(let receipt) = projection.apply(pending, isCurrent: { _, _ in true }) else {
            Issue.record("covered pending controls did not advance"); return
        }
        #expect(receipt.appliedThrough == 7)
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true }) == revoked)
        let validHead = fixture.batch(.heads([.init(roomID: fixture.room, highWatermark: 8, ownerEpoch: 1, controlVersion: 10)]))
        guard case .headsApplied(let headReceipt) = projection.applyHeads(validHead, isCurrent: { _, _ in true }) else {
            Issue.record("matching independent head did not merge"); return
        }
        #expect(headReceipt.batchID == validHead.batchID)
        let newControl = fixture.batch(.changes(fromExclusive: 7, throughInclusive: 8, entries: [
            .init(sequence: 8, change: .controlInvalidation(roomID: fixture.room, ownerEpoch: 1, controlVersion: 11))
        ]))
        #expect(projection.apply(newControl, isCurrent: { _, _ in true }) == .snapshotRequired)
        #expect(projection.metrics().rooms == 0 && projection.metrics().viewers == 0)
        let staleSnapshot = fixture.batch(.snapshot(cut: 8, rooms: [revoked]))
        #expect(projection.installAuthoritativeSnapshot(staleSnapshot, expectedCut: 8,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) == .snapshotRequired)
        // Owner generations take priority over control versions: a prior owner
        // cannot replace a newer owner even with a numerically larger version.
        let nextOwner = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 2,
            permissionVersion: 1, controlVersion: 1, viewerMembershipRevisions: [:], highWatermark: 8)
        let nextSnapshot = fixture.batch(.snapshot(cut: 8, rooms: [nextOwner]))
        guard case .applied = projection.installAuthoritativeSnapshot(nextSnapshot, expectedCut: 8,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) else {
            Issue.record("new owner snapshot did not commit"); return
        }
        let previousOwner = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 1,
            permissionVersion: 100, controlVersion: 100, viewerMembershipRevisions: [fixture.user: 1], highWatermark: 8)
        let lateOwner = fixture.batch(.changes(fromExclusive: 8, throughInclusive: 9, entries: [
            .init(sequence: 9, change: .authorization(previousOwner))
        ]))
        guard case .applied = projection.apply(lateOwner, isCurrent: { _, _ in true }) else {
            Issue.record("old owner control should be covered by the floor"); return
        }
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true }) == nextOwner)
        let unknownHead = fixture.batch(.heads([.init(roomID: fixture.room, highWatermark: 9, ownerEpoch: 2, controlVersion: 2)]))
        #expect(projection.applyHeads(unknownHead, isCurrent: { _, _ in true }) == .snapshotRequired)
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true }) == nil)
        projection.remove(source: fixture.source)
        #expect(projection.metrics().partitions == 0 && projection.metrics().rooms == 0 && projection.metrics().viewers == 0)
    }

    @Test("explicit authoritative initial control zero is known and only local requested viewers are retained")
    func initialFloorAndRequestedViewers() {
        let fixture = Fixture(), projection = V2RealtimeJournalSharedProjection()
        #expect(projection.requireSnapshot(source: fixture.source, fence: fixture.fence,
            expectedRooms: [fixture.room], requestedViewers: [fixture.user]))
        let head = fixture.batch(.heads([.init(roomID: fixture.room, highWatermark: 9, ownerEpoch: 0, controlVersion: 0)]))
        #expect(projection.applyHeads(head, isCurrent: { _, _ in true }) == .snapshotRequired)
        let initial = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 0,
            permissionVersion: 0, controlVersion: 0, viewerMembershipRevisions: [fixture.user: 1], highWatermark: 6)
        let initialSnapshot = fixture.batch(.snapshot(cut: 5, rooms: [initial]))
        guard case .applied = projection.installAuthoritativeSnapshot(initialSnapshot, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) else {
            Issue.record("explicit authoritative zero control was rejected"); return
        }
        guard case .headsApplied = projection.applyHeads(head, isCurrent: { _, _ in true }) else {
            Issue.record("known zero-floor head was rejected"); return
        }
        #expect(projection.metrics().rooms == 1 && projection.metrics().viewers == 1)
        let outsider = V2RealtimeJournalRoomAuthorization(roomID: fixture.room, ownerEpoch: 0,
            permissionVersion: 0, controlVersion: 0,
            viewerMembershipRevisions: [fixture.user: 1, UserID(uuid: UUID()): 1], highWatermark: 9)
        let oversizedAudience = fixture.batch(.snapshot(cut: 5, rooms: [outsider]))
        #expect(projection.installAuthoritativeSnapshot(oversizedAudience, expectedCut: 5,
            authorizesSnapshot: { _ in true }, isCurrent: { _, _ in true }) == .snapshotRequired)
        #expect(projection.metrics().rooms == 0 && projection.metrics().viewers == 0)
        #expect(projection.room(fixture.room, isCurrent: { _, _ in true }) == nil)
        let zeroControlMutation = fixture.batch(.changes(fromExclusive: 5, throughInclusive: 6, entries: [
            .init(sequence: 6, change: .authorization(initial))
        ]))
        // An absent current snapshot is unknown even when the field is zero.
        #expect(projection.apply(zeroControlMutation, isCurrent: { _, _ in true }) == .snapshotRequired)
    }

    private struct Fixture {
        let source = V2RealtimeJournalSource(sourceID: "room-db-1", incarnationID: UUID(), partitionID: 7)
        let room = RoomID(uuid: UUID())
        let user = UserID(uuid: UUID())
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 2,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date().addingTimeInterval(30), routingPartitionEpoch: 8,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 4, gatewayIncarnationID: UUID())
        func batch(_ payload: V2RealtimeJournalProjectionPayload) -> V2RealtimeJournalProjectionBatch {
            .init(source: source, fence: fence, payload: payload)
        }
        func authorization(head: UInt64) -> V2RealtimeJournalRoomAuthorization {
            .init(roomID: room, ownerEpoch: 1, permissionVersion: 3, controlVersion: 3,
                  viewerMembershipRevisions: [user: 1], highWatermark: head)
        }
    }
}
