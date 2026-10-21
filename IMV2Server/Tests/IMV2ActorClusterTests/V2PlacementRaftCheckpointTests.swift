import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Placement checkpoint retains exact successful command history")
struct V2PlacementRaftCheckpointTests {
    @Test("Pending host admission survives archive rolling until incarnation registration replaces it")
    func pendingHostAdmission() throws {
        var active = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let newcomer = V2ActorHostID(uuid: UUID()), admissionID = UUID()
        let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: active, epoch: 1), transfer: nil)])
        var model = V2ActorPlacementStateMachine(snapshot: initial)
        var records: [V2PlacementRaftCheckpoint.Record] = []
        func append(_ command: V2ActorPlacementCommand, id: UUID = UUID()) throws {
            let revision = model.snapshot.revision + 1
            try model.apply(command, revision: revision)
            records.append(.init(requestID: id, command: command, revision: revision))
        }
        let memberA = V2RealtimeShardDiscoveryPeer(nodeID: "a", serviceID: "a", address: "a.test", port: 7337)
        let memberB = V2RealtimeShardDiscoveryPeer(nodeID: "b", serviceID: "b", address: "b.test", port: 7337)
        let stable = try V2ActorServiceMembershipRecord(revision: 1, current: ["a"], peers: [memberA])
        let joint = try V2ActorServiceMembershipRecord(revision: 2, current: ["a"], next: ["a", "b"], peers: [memberA, memberB])
        let membershipRequest = UUID()
        try append(.installServiceMembership(stable))
        try append(.installServiceMembership(joint), id: membershipRequest)
        let capacity = try V2PlacementArchiveCapacity.usage(snapshot: model.snapshot, receipts: 0, bytes: 0)
        #expect(capacity.reservedReceipts == 2) // Active host retirement plus final membership.
        try append(.admitHost(newcomer), id: admissionID)
        for _ in 0..<(V2PlacementRaftCheckpoint.retainedReceipts / 2 + 1) {
            let successor = V2ActorHostIdentity(hostID: active.hostID, incarnationID: UUID())
            try append(.retireHost(active))
            try append(.registerHost(previous: active, successor: successor))
            active = successor
        }
        let archive = V2PlacementRaftCheckpoint(groupID: initial.clusterID,
            appliedIndex: model.snapshot.revision, genesis: initial, receipts: records)
        let rolled = try archive.rolling()
        let restored = try V2PlacementRaftCheckpoint.decode(rolled.encode(), groupID: initial.clusterID)
        #expect(restored.genesis.revision > 2)
        #expect(restored.pinnedReceipts.contains { $0.requestID == admissionID })
        #expect(restored.pinnedReceipts.contains { $0.requestID == membershipRequest })
        #expect(try restored.replay().snapshot.serviceMembership == joint)
        #expect(try restored.replay().snapshot == model.snapshot)
        let successor = V2ActorHostIdentity(hostID: newcomer, incarnationID: UUID())
        try append(.registerHost(previous: V2ActorPlacementHostRegistration.reserved(newcomer).host, successor: successor))
        let updated = V2PlacementRaftCheckpoint(groupID: initial.clusterID,
            appliedIndex: model.snapshot.revision, genesis: restored.genesis,
            receipts: restored.receipts + [try #require(records.last)],
            bootstrapDigest: restored.bootstrapDigest, pinnedReceipts: restored.pinnedReceipts)
        let registered = try updated.rolling()
        #expect(!registered.pinnedReceipts.contains { $0.requestID == admissionID })
        #expect(try registered.replay().snapshot == model.snapshot)
    }

    @Test("Rolling archive is independent of local compaction timing and preserves live operation proofs")
    func rollingArchive() throws {
        let a = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let reserved = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let b = V2ActorHostIdentity(hostID: reserved.hostID, incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: (0..<2).map { _ in .init(owner: .init(host: a, epoch: 1), transfer: nil) },
            hosts: [.init(host: a, retired: false), .init(host: reserved, retired: true)])
        let voters: Set<V2ActorHostID> = [a.hostID, b.hostID, .init(uuid: UUID())]
        var stable = V2PlacementRaftPersistentState(groupID: initial.clusterID, voterID: a.hostID,
            voters: voters, term: 1, log: [try .init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial)))], commitIndex: 1)
        var model = V2ActorPlacementStateMachine(snapshot: initial)
        func append(_ command: V2ActorPlacementCommand, id: UUID, origin: UInt64) throws {
            stable.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
                .command(command, expected: model.snapshot, requestID: id, originRevision: origin))))
            try model.apply(command, revision: model.snapshot.revision + 1)
        }
        let registerID = UUID(), registration = V2ActorPlacementCommand.registerHost(previous: reserved, successor: b)
        try append(registration, id: registerID, origin: 1)
        let pendingID = UUID(), pendingOrigin = model.snapshot.revision
        try append(.beginTransfer(partition: 0, expected: model.snapshot.slots[0].owner,
            transfer: .init(id: pendingID, successor: b)), id: pendingID, origin: pendingOrigin)
        let expiredID = UUID(), expiredOrigin = model.snapshot.revision
        let expired = V2ActorPlacementCommand.beginTransfer(partition: 1, expected: model.snapshot.slots[1].owner,
            transfer: .init(id: expiredID, successor: b))
        for index in 0..<2100 {
            let id = index == 0 ? expiredID : UUID(), origin = model.snapshot.revision
            try append(.beginTransfer(partition: 1, expected: model.snapshot.slots[1].owner,
                transfer: .init(id: id, successor: b)), id: id, origin: origin)
            try append(.cancelTransfer(partition: 1, expected: model.snapshot.slots[1].owner, transferID: id), id: id, origin: origin)
        }
        stable.commitIndex = stable.lastIndex
        var eager = V2PlacementRaftApplication(groupID: initial.clusterID)
        var partial = stable; partial.commitIndex = 4100
        try eager.apply(partial)
        let checkpointAt4100 = try eager.checkpoint()
        var compacted = stable
        compacted.snapshot = .init(index: 4100, term: 1, application: checkpointAt4100)
        compacted.log = Array(stable.log.dropFirst(4100))
        try eager.apply(compacted)
        var lazy = V2PlacementRaftApplication(groupID: initial.clusterID)
        try lazy.apply(stable)
        #expect(try eager.checkpoint() == lazy.checkpoint())
        let rolled = try V2PlacementRaftCheckpoint.decode(lazy.checkpoint(), groupID: initial.clusterID)
        #expect(rolled.genesis.revision > expiredOrigin)
        #expect(rolled.pinnedReceipts.contains { $0.requestID == registerID })
        #expect(rolled.pinnedReceipts.contains { $0.requestID == pendingID })
        #expect(try lazy.receipt(for: registration, requestID: registerID, originRevision: 1) == model.snapshot)
        #expect(try lazy.archiveUsage().receipts <= V2PlacementRaftCheckpoint.retainedReceipts + 4095 + 8)
        #expect(try lazy.bootstrapReceipt(initial) == model.snapshot)
        // The original admitted transfer can finish after its origin ages out.
        let complete = V2ActorPlacementCommand.completeTransfer(partition: 0,
            expected: model.snapshot.slots[0].owner, transferID: pendingID)
        try append(complete, id: pendingID, origin: pendingOrigin)
        stable.commitIndex = stable.lastIndex; try lazy.apply(stable)
        #expect(lazy.snapshot == model.snapshot && lazy.snapshot?.slots[0].owner.host == b)
        let beforeExpired = model.snapshot
        stable.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
            .command(expired, expected: beforeExpired, requestID: expiredID, originRevision: expiredOrigin))))
        stable.commitIndex = stable.lastIndex; try lazy.apply(stable)
        #expect(try lazy.result(at: stable.lastIndex) == .failure(.requestExpired))
        #expect(lazy.snapshot == beforeExpired)
        var restoredState = stable
        restoredState.snapshot = .init(index: stable.lastIndex, term: 1, application: try lazy.checkpoint())
        restoredState.log = []
        var restored = V2PlacementRaftApplication(groupID: initial.clusterID)
        try restored.apply(restoredState)
        #expect(restored.snapshot == beforeExpired)
        #expect(try restored.receipt(for: registration, requestID: registerID, originRevision: 1) == beforeExpired)
    }

    @Test("Archive exhaustion reports capacity so automatic compaction preserves the durable log")
    func archiveCapacity() throws {
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let group = UUID()
        let genesis = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let record = V2PlacementRaftCheckpoint.Record(requestID: UUID(), command: .retireHost(host), revision: 2)
        let count = V2PlacementRaftCheckpoint.maximumReceipts + 1
        let archive = V2PlacementRaftCheckpoint(groupID: group, appliedIndex: UInt64(count + 1),
            genesis: genesis, receipts: Array(repeating: record, count: count))
        #expect(throws: V2PlacementRaftError.capacity) { try archive.replay() }
        #expect(throws: V2PlacementRaftError.capacity) { try archive.encode() }
        let malformed = V2PlacementRaftCheckpoint(groupID: UUID(), appliedIndex: archive.appliedIndex,
            genesis: genesis, receipts: archive.receipts)
        #expect(throws: V2PlacementRaftError.invalidState) { try malformed.replay() }
    }

    @Test("Historical success results survive compact encoding; rejected CAS and barriers do not enter history")
    func historicalReceipts() throws {
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let group = UUID(), initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: (0..<128).map { _ in .init(owner: .init(host: host, epoch: 1), transfer: nil) })
        var state = try V2PlacementRaftPersistentState(groupID: group, voterID: host.hostID,
            voters: [host.hostID, .init(uuid: UUID()), .init(uuid: UUID())], term: 1,
            log: [.init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial)))], commitIndex: 1)
        var application = V2PlacementRaftApplication(groupID: group)
        try application.apply(state)
        var expected = initial, current = host
        var records: [(UUID, V2ActorPlacementCommand, V2ActorPlacementSnapshot)] = []
        for _ in 0..<16 {
            let successor = V2ActorHostIdentity(hostID: host.hostID, incarnationID: UUID())
            for command in [V2ActorPlacementCommand.retireHost(current), .registerHost(previous: current, successor: successor)] {
                let id = UUID()
                state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(command, expected: expected, requestID: id))))
                state.commitIndex = UInt64(state.log.count); try application.apply(state)
                expected = try #require(application.snapshot)
                records.append((id, command, expected))
            }
            current = successor
        }
        let rejected = V2ActorPlacementCommand.retireHost(current)
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(rejected, expected: initial, requestID: UUID()))))
        state.log.append(.init(term: 1, payload: Data()))
        state.commitIndex = UInt64(state.log.count); try application.apply(state)
        let bytes = try application.checkpoint()
        let checkpoint = try V2PlacementRaftCheckpoint.decode(bytes, groupID: group), replay = try checkpoint.replay()
        #expect(checkpoint.appliedIndex == state.commitIndex && checkpoint.receipts.count == records.count)
        #expect(replay.snapshot == expected)
        for (offset, record) in records.enumerated() {
            #expect(checkpoint.receipts[offset].requestID == record.0 && checkpoint.receipts[offset].command == record.1)
            #expect(try checkpoint.snapshot(at: record.2.revision) == record.2)
            #expect(try application.receipt(for: record.1, requestID: record.0) == record.2)
        }
        var compacted = state
        compacted.snapshot = .init(index: state.commitIndex, term: 1, application: bytes)
        compacted.log = []
        var restored = V2PlacementRaftApplication(groupID: group); try restored.apply(compacted)
        for record in records {
            #expect(try restored.receipt(for: record.1, requestID: record.0) == record.2)
        }
        // A replay in the new suffix returns the original version, even though
        // the current placement has advanced many revisions since then.
        let first = try #require(records.first)
        compacted.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
            .command(first.1, expected: initial, requestID: first.0))))
        compacted.commitIndex += 1; try restored.apply(compacted)
        #expect(try restored.result(at: compacted.commitIndex)?.get() == first.2)
        #expect(restored.snapshot == expected)
        // This measures encoded control history, not CPU or message throughput.
        #expect(bytes.count * 8 < state.log.reduce(0) { $0 + $1.payload.count })
        #expect(throws: V2PlacementRaftError.wrongGroup) { try V2PlacementRaftCheckpoint.decode(bytes, groupID: UUID()) }
    }

    @Test("Duplicate success identities, missing revisions and impossible transitions cannot restore a checkpoint")
    func malformedHistory() throws {
        let group = UUID(), host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let id = UUID(), retire = V2ActorPlacementCommand.retireHost(host)
        let duplicate = V2PlacementRaftCheckpoint(groupID: group, appliedIndex: 3, genesis: initial,
            receipts: [.init(requestID: id, command: retire, revision: 2), .init(requestID: id, command: retire, revision: 3)])
        #expect(throws: V2PlacementRaftError.invalidState) { try duplicate.encode() }
        let gap = V2PlacementRaftCheckpoint(groupID: group, appliedIndex: 4, genesis: initial,
            receipts: [.init(requestID: id, command: retire, revision: 3)])
        #expect(throws: V2PlacementRaftError.invalidState) { try gap.encode() }
        let impossible = V2PlacementRaftCheckpoint(groupID: group, appliedIndex: 2, genesis: initial,
            receipts: [.init(requestID: id, command: .retireHost(.init(hostID: .init(uuid: UUID()), incarnationID: UUID())), revision: 2)])
        #expect(throws: V2ActorPlacementError.staleOwner) { try impossible.encode() }
    }
}
