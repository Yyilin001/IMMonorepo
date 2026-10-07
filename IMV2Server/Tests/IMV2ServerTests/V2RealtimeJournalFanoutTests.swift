import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication

@Suite("Journal fanout actual recipient commits")
struct V2RealtimeJournalFanoutTests {
    @Test func memberChangePreservesTargetWithoutRoomInterest() async throws {
        let user = UUID(), room = UUID()
        let fixture = FanoutFixture(user: user)
        let receiver = FanoutReceiver()
        let fanout = try fixture.makeFanout(receiver)
        let initial = V2RealtimeJournalEntry(partitionID: 2, sequence: 1, sourceEventID: UUID(),
            topicKind: "userSync", topicID: user.uuidString.lowercased(), changeKind: "membership.changed",
            userControlVersion: 1, membershipRoomID: room)
        _ = try await fanout.apply(sourceID: "membership", lease: fixture.lease,
            batch: .init(partitionID: 2, publishedThrough: 1, trimmedThrough: 0, requiresSnapshot: false, entries: [initial]))
        let changed = V2RealtimeJournalEntry(partitionID: 2, sequence: 2, sourceEventID: UUID(),
            topicKind: "userSync", topicID: user.uuidString.lowercased(), changeKind: "membership.changed",
            userControlVersion: 2, membershipRoomID: room)
        let unrelated = V2RealtimeJournalEntry(partitionID: 2, sequence: 3, sourceEventID: UUID(),
            topicKind: "userSync", topicID: UUID().uuidString.lowercased(), changeKind: "membership.changed",
            userControlVersion: 1, membershipRoomID: UUID())
        _ = try await fanout.apply(sourceID: "membership", lease: fixture.lease,
            batch: .init(partitionID: 2, publishedThrough: 3, trimmedThrough: 0, requiresSnapshot: false, entries: [changed, unrelated]))
        let batch = try #require(await receiver.batches.first)
        #expect(batch.payload == .changes(fromExclusive: 1, throughInclusive: 3, entries: [
            .init(sequence: 2, change: .userControlInvalidation(userID: UserID(uuid: user),
                controlVersion: 2, deviceID: nil, membershipRoomID: RoomID(uuid: room)))]))
        await fanout.close()
    }

    @Test func filteredRangesRetainSkippedSequenceCoverageAndExactRevision() async throws {
        let fixture = FanoutFixture()
        let receiver = FanoutReceiver()
        let fanout = try fixture.makeFanout(receiver)
        _ = try await fanout.apply(sourceID: "room", lease: fixture.lease, batch: fixture.batch(through: 3))
        let entries = [fixture.entry(sequence: 4, room: fixture.room), fixture.entry(sequence: 5, room: UUID())]
        _ = try await fanout.apply(sourceID: "room", lease: fixture.lease,
            batch: .init(partitionID: 2, publishedThrough: 5, trimmedThrough: 0, requiresSnapshot: false, entries: entries))
        let batches = await receiver.batches
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.fence.interestGeneration == 7)
        guard case .changes(let from, let through, let filtered) = batch.payload else { Issue.record("expected ordered range"); return }
        #expect(from == 3 && through == 5)
        #expect(filtered.map(\.sequence) == [4])
        await fanout.close()
    }

    @Test func failedPeerDoesNotDiscardOtherPeerCheckpoint() async throws {
        let fixture = FanoutFixture(twoPeers: true)
        let receiver = FanoutReceiver(failSlowOnce: true)
        let fanout = try fixture.makeFanout(receiver)
        _ = try await fanout.apply(sourceID: "room", lease: fixture.lease, batch: fixture.batch(through: 3))
        let next = fixture.batch(through: 4)
        await #expect(throws: V2RealtimeJournalError.leaseLost) {
            _ = try await fanout.apply(sourceID: "room", lease: fixture.lease, batch: next)
        }
        _ = try await fanout.apply(sourceID: "room", lease: fixture.lease, batch: next)
        #expect(await receiver.fastCalls == 1)
        #expect(await receiver.slowCalls == 2)
        await fanout.close()
    }

    @Test func unknownControlsCannotBeConsumed() async throws {
        let fixture = FanoutFixture()
        let receiver = FanoutReceiver()
        let fanout = try fixture.makeFanout(receiver)
        let entry = V2RealtimeJournalEntry(partitionID: 2, sequence: 1, sourceEventID: UUID(),
            topicKind: "unknownControl", topicID: UUID().uuidString, changeKind: "user.changed", userControlVersion: 1)
        await #expect(throws: V2RealtimeJournalError.invalidInput) {
            _ = try await fanout.apply(sourceID: "user", lease: fixture.lease,
                batch: .init(partitionID: 2, publishedThrough: 1, trimmedThrough: 0, requiresSnapshot: false, entries: [entry]))
        }
        #expect(await receiver.batches.isEmpty)
        await fanout.close()
    }
}

private struct FanoutFixture: Sendable {
    let room = UUID()
    let sourceIncarnation = UUID()
    let lease: V2RealtimePartitionLease
    let recipients: [V2RealtimeJournalRecipient]
    init(twoPeers: Bool = false, user: UUID? = nil) {
        let host = V2GatewayRealtimeIdentity(nodeID: "publisher", serviceID: "publisher", incarnationID: UUID())
        lease = .init(partitionID: 2, identity: host, epoch: 8, token: UUID(), remainingLeaseSeconds: 15)
        let routing = V2RealtimeShardToken(partitionID: 2, host: host, epoch: 3, leaseToken: UUID())
        let roomKey = V2RealtimeTopicKey(kind: .roomEvents, id: room.uuidString.lowercased())
        recipients = (twoPeers ? ["fast", "slow"] : ["fast"]).map { name in
            let gateway = V2GatewayRealtimeIdentity(nodeID: name, serviceID: name, incarnationID: UUID())
            return .init(token: routing, session: .init(gateway: .init(identity: gateway, endpointReference: Data(),
                address: "127.0.0.1", port: 9999), sessionID: UUID(), sessionGeneration: 1),
                interestGeneration: 7, interests: [user.map { V2RealtimeTopicKey(kind: .userSync, id: $0.uuidString.lowercased()) } ?? roomKey: 42])
        }
    }
    func entry(sequence: Int64, room: UUID) -> V2RealtimeJournalEntry {
        .init(partitionID: 2, sequence: sequence, sourceEventID: UUID(), topicKind: "roomEvents",
            topicID: room.uuidString.lowercased(), changeKind: "room.changed", ownerEpoch: 0, roomControlVersion: max(1, sequence))
    }
    func batch(through: Int64) -> V2RealtimeJournalBatch {
        .init(partitionID: 2, publishedThrough: through, trimmedThrough: 0, requiresSnapshot: false,
            entries: [entry(sequence: through, room: room)])
    }
    func makeFanout(_ receiver: FanoutReceiver) throws -> V2RealtimeJournalFanout {
        let incarnation = sourceIncarnation, selected = recipients
        return try .init(sourceIdentity: { _ in .init(sourceID: UUID(), databaseIncarnation: incarnation) },
            recipients: { _ in selected }, isCurrent: { selected.contains($0) },
            requestColdSnapshot: { _, source, fence, cut in
                .init(batchID: UUID(), source: source, fence: fence, appliedThrough: cut, snapshotInstalled: true)
            }, send: { gateway, batch in try await receiver.send(gateway, batch) })
    }
}
private actor FanoutReceiver {
    var batches: [V2RealtimeJournalProjectionBatch] = []
    var fastCalls = 0
    var slowCalls = 0
    var failSlowOnce: Bool
    init(failSlowOnce: Bool = false) { self.failSlowOnce = failSlowOnce }
    func send(_ gateway: V2GatewayRealtimeDescriptor, _ batch: V2RealtimeJournalProjectionBatch) throws -> V2RealtimeJournalProjectionResult {
        batches.append(batch)
        if gateway.identity.nodeID == "slow" {
            slowCalls += 1
            if failSlowOnce { failSlowOnce = false; throw V2RealtimeJournalError.leaseLost }
        } else { fastCalls += 1 }
        switch batch.payload {
        case .changes(_, let through, _):
            return .applied(.init(batchID: batch.batchID, source: batch.source, fence: batch.fence,
                appliedThrough: through, snapshotInstalled: false))
        case .snapshot(let cut, _), .baseline(let cut):
            return .applied(.init(batchID: batch.batchID, source: batch.source, fence: batch.fence,
                appliedThrough: cut, snapshotInstalled: true))
        case .heads:
            return .headsApplied(.init(batchID: batch.batchID, source: batch.source, fence: batch.fence))
        }
    }
}
