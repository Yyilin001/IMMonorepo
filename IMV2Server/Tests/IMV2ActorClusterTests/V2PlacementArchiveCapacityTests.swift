import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Control archive reserves physical lifecycle completion")
struct V2PlacementArchiveCapacityTests {
    @Test("A withdrawal cannot consume capacity required for completion and both Host retirements")
    func terminalCapacity() throws {
        let a = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let b = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: a, epoch: 1), transfer: nil),
                    .init(owner: .init(host: b, epoch: 1), transfer: nil)])
        var machine = V2ActorPlacementStateMachine(snapshot: initial)
        var bytes = try V2PlacementArchiveCapacity.headerBytes(initial)
        var records: [V2PlacementRaftCheckpoint.Record] = []
        func usage(_ snapshot: V2ActorPlacementSnapshot) throws -> V2PlacementArchiveCapacity.Usage {
            try V2PlacementArchiveCapacity.usage(snapshot: snapshot, receipts: records.count, bytes: bytes)
        }
        let id = UUID(), expected = initial.slots[0].owner
        let commands: [V2ActorPlacementCommand] = [
            .beginTransfer(partition: 0, expected: expected, transfer: .init(id: id, successor: b)),
            .completeTransfer(partition: 0, expected: expected, transferID: id), .retireHost(a), .retireHost(b)
        ]
        var firstReservation: V2PlacementArchiveCapacity.Usage?
        for (offset, command) in commands.enumerated() {
            try machine.apply(command, revision: UInt64(offset + 2))
            let record = V2PlacementRaftCheckpoint.Record(requestID: UUID(), command: command,
                revision: machine.snapshot.revision)
            records.append(record); bytes += try V2PlacementArchiveCapacity.recordBytes(record)
            let current = try usage(machine.snapshot)
            try current.requireCapacity(maximumReceipts: 4)
            if offset == 0 {
                #expect(current.reservedReceipts == 3)
                firstReservation = current
                var extra = machine
                try extra.apply(.beginTransfer(partition: 1, expected: initial.slots[1].owner,
                    transfer: .init(id: UUID(), successor: a)), revision: 3)
                let insufficient = try V2PlacementArchiveCapacity.usage(snapshot: extra.snapshot,
                    receipts: 2, bytes: bytes)
                #expect(throws: V2ActorPlacementError.archiveCapacity) {
                    try insufficient.requireCapacity(maximumReceipts: 4)
                }
            }
        }
        let final = try usage(machine.snapshot)
        #expect(final.receipts == 4 && final.reservedReceipts == 0 && final.reservedBytes == 0)
        let first = try #require(firstReservation)
        #expect(final.bytes <= first.bytes + first.reservedBytes)
        let checkpoint = V2PlacementRaftCheckpoint(groupID: initial.clusterID, appliedIndex: 5,
            genesis: initial, receipts: records)
        #expect(try checkpoint.encode().count <= final.bytes)
        #expect(try checkpoint.replay().snapshot == machine.snapshot)
        #expect(throws: V2ActorPlacementError.archiveCapacity) {
            try first.requireCapacity(maximumBytes: first.bytes + first.reservedBytes - 1)
        }
        try first.requireCapacity(maximumBytes: first.bytes + first.reservedBytes)
    }

    @Test("Reserved retirements and replay survive archive exhaustion and deterministic rollover")
    func productionBoundary() throws {
        let a = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let b = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let group = UUID(), voters: Set<V2ActorHostID> = [a.hostID, b.hostID, .init(uuid: UUID())]
        let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: a, epoch: 1), transfer: nil)],
            hosts: [.init(host: a, retired: false), .init(host: b, retired: false)])
        var machine = V2ActorPlacementStateMachine(snapshot: initial)
        var records: [V2PlacementRaftCheckpoint.Record] = []
        var current = a
        let available = V2PlacementRaftCheckpoint.maximumReceipts - 2
        for _ in 0..<(available / 2) {
            let next = V2ActorHostIdentity(hostID: a.hostID, incarnationID: UUID())
            for command in [V2ActorPlacementCommand.retireHost(current), .registerHost(previous: current, successor: next)] {
                try machine.apply(command, revision: machine.snapshot.revision + 1)
                records.append(.init(requestID: UUID(), command: command, revision: machine.snapshot.revision))
            }
            current = next
        }
        let archivedIndex = UInt64(records.count + 1)
        let checkpoint = V2PlacementRaftCheckpoint(groupID: group, appliedIndex: archivedIndex,
            genesis: initial, receipts: records)
        var state = V2PlacementRaftPersistentState(groupID: group, voterID: a.hostID, voters: voters,
            term: 1, commitIndex: archivedIndex, snapshot: .init(index: archivedIndex, term: 1,
                application: try checkpoint.encode()))
        var application = V2PlacementRaftApplication(groupID: group)
        try application.apply(state)
        #expect(try application.archiveUsage().receipts == available)
        let before = machine.snapshot
        let attempted = V2ActorPlacementCommand.beginTransfer(partition: 0, expected: before.slots[0].owner,
            transfer: .init(id: UUID(), successor: b))
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
            .command(attempted, expected: before, requestID: UUID()))))
        state.commitIndex += 1
        try application.apply(state)
        #expect(try application.result(at: state.commitIndex) == .failure(.archiveCapacity))
        #expect(application.snapshot == before)
        let id = UUID(), retire = V2ActorPlacementCommand.retireHost(current)
        for (command, requestID) in [(retire, id), (.retireHost(b), UUID())] {
            let expected = try #require(application.snapshot)
            state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
                .command(command, expected: expected, requestID: requestID))))
            state.commitIndex += 1
            try application.apply(state)
        }
        #expect(try application.archiveUsage().receipts == V2PlacementRaftCheckpoint.retainedReceipts + 2)
        #expect(try application.archiveUsage().reservedReceipts == 0)
        let original = try #require(try application.receipt(for: retire, requestID: id))
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
            .command(retire, expected: before, requestID: id))))
        state.commitIndex += 1
        try application.apply(state)
        #expect(try application.result(at: state.commitIndex) == .success(original))
        _ = try application.checkpoint()
    }

    @Test("Restore rebuilds the same encoded byte budget and preserves exact successful replay")
    func restoredBudget() throws {
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let group = UUID(), voters: Set<V2ActorHostID> = [host.hostID, .init(uuid: UUID()), .init(uuid: UUID())]
        let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let command = V2ActorPlacementCommand.retireHost(host), id = UUID()
        let state = V2PlacementRaftPersistentState(groupID: group, voterID: host.hostID, voters: voters,
            term: 1, log: [try .init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial))),
                try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(command, expected: initial, requestID: id)))],
            commitIndex: 2)
        var application = V2PlacementRaftApplication(groupID: group)
        try application.apply(state)
        var core = try V2PlacementRaftCore(id: host.hostID, groupID: group, voters: voters, persisted: state)
        try core.compact(application.checkpoint(), through: 2)
        var restored = V2PlacementRaftApplication(groupID: group)
        try restored.apply(core.state)
        #expect(try restored.archiveUsage() == application.archiveUsage())
        #expect(try restored.receipt(for: command, requestID: id) == application.snapshot)
        let wire = try V2PlacementRaftWriteCodec.encode(.rejected(.archiveCapacity), groupID: group, shard: "room-a")
        #expect(try V2PlacementRaftWriteCodec.decode(wire, groupID: group, shard: "room-a") == .rejected(.archiveCapacity))
    }
}
