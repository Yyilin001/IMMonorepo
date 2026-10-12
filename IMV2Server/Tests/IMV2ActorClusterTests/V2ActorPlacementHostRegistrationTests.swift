import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Host registration survives transfer of its last partition")
struct V2ActorPlacementHostRegistrationTests {
    @Test("Recovered ownership and pending transfers must match the complete Host roster")
    func snapshotRegistrationIntegrity() throws {
        let owner = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let successor = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let mismatched = V2ActorHostIdentity(hostID: owner.hostID, incarnationID: UUID())
        let slot = V2ActorPlacementSlot(owner: .init(host: owner, epoch: 1), transfer: nil)
        for hosts: [V2ActorPlacementHostRegistration] in [
            [.init(host: successor, retired: false)],
            [.init(host: mismatched, retired: false)],
            [.init(host: owner, retired: true)]
        ] {
            #expect(throws: V2ActorPlacementError.invalidConfiguration) {
                try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1, slots: [slot], hosts: hosts)
            }
        }
        let pending = V2ActorPlacementSlot(owner: slot.owner,
            transfer: .init(id: UUID(), successor: successor))
        #expect(throws: V2ActorPlacementError.invalidConfiguration) {
            try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1, slots: [pending],
                hosts: [.init(host: owner, retired: false)])
        }
        let retiredPending = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: slot.owner, transfer: pending.transfer, retired: true)],
            hosts: [.init(host: owner, retired: true), .init(host: successor, retired: true)])
        var machine = V2ActorPlacementStateMachine(snapshot: retiredPending)
        try machine.apply(.cancelTransfer(partition: 0, expected: slot.owner,
            transferID: pending.transfer!.id), revision: 2)
        #expect(machine.snapshot.slots[0].retired)
        #expect(machine.snapshot.slots[0].transfer == nil)
    }

    @Test("An absent or mismatched Host registration cannot withdraw ownership")
    func successorRegistrationRequired() throws {
        let owner = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let successor = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        for registration: V2ActorPlacementHostRegistration? in [nil,
            .init(host: .init(hostID: successor.hostID, incarnationID: UUID()), retired: false),
            .init(host: successor, retired: true)] {
            let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
                slots: [.init(owner: .init(host: owner, epoch: 1), transfer: nil)],
                hosts: [.init(host: owner, retired: false)] + (registration.map { [$0] } ?? []))
            var machine = V2ActorPlacementStateMachine(snapshot: initial)
            #expect(throws: V2ActorPlacementError.staleOwner) {
                try machine.apply(.beginTransfer(partition: 0, expected: initial.slots[0].owner,
                    transfer: .init(id: UUID(), successor: successor)), revision: 2)
            }
            #expect(machine.snapshot == initial)
        }
    }

    @Test("Retiring a pending successor prevents publication and incarnation replacement until cancellation")
    func pendingSuccessorRetirement() throws {
        let owner = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let successor = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let replacement = V2ActorHostIdentity(hostID: successor.hostID, incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: owner, epoch: 1), transfer: nil)],
            hosts: [.init(host: owner, retired: false), .init(host: successor, retired: false)])
        var machine = V2ActorPlacementStateMachine(snapshot: initial)
        let id = UUID()
        try machine.apply(.beginTransfer(partition: 0, expected: initial.slots[0].owner,
            transfer: .init(id: id, successor: successor)), revision: 2)
        try machine.apply(.retireHost(successor), revision: 3)
        let retired = machine.snapshot
        #expect(throws: V2ActorPlacementError.staleOwner) {
            try machine.apply(.completeTransfer(partition: 0, expected: initial.slots[0].owner,
                transferID: id), revision: 4)
        }
        #expect(throws: V2ActorPlacementError.staleOwner) {
            try machine.apply(.registerHost(previous: successor, successor: replacement), revision: 4)
        }
        #expect(machine.snapshot == retired)
        try machine.apply(.cancelTransfer(partition: 0, expected: initial.slots[0].owner,
            transferID: id), revision: 4)
        try machine.apply(.registerHost(previous: successor, successor: replacement), revision: 5)
        #expect(machine.snapshot.slots[0].owner == initial.slots[0].owner)
        #expect(machine.snapshot.registration(for: replacement.hostID)?.host == replacement)
    }

    @Test("Moving the last partition does not retire a live process or erase its durable receipts")
    func lastPartition() throws {
        let a = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let b = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let successor = V2ActorHostIdentity(hostID: a.hostID, incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: UUID(), revision: 1,
            slots: [.init(owner: .init(host: a, epoch: 1), transfer: nil),
                    .init(owner: .init(host: b, epoch: 1), transfer: nil)])
        let transfer = UUID(), owner = initial.slots[0].owner
        var machine = V2ActorPlacementStateMachine(snapshot: initial)
        var entries = [try V2PlacementRaftEntry(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(initial)))]
        let commands: [V2ActorPlacementCommand] = [
            .beginTransfer(partition: 0, expected: owner, transfer: .init(id: transfer, successor: b)),
            .completeTransfer(partition: 0, expected: owner, transferID: transfer),
            .retireHost(a), .registerHost(previous: a, successor: successor)
        ]
        let ids = commands.map { _ in UUID() }
        var moved: V2ActorPlacementSnapshot?
        for (offset, command) in commands.enumerated() {
            entries.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
                .command(command, expected: machine.snapshot, requestID: ids[offset]))))
            try machine.apply(command, revision: UInt64(offset + 2))
            if offset == 1 {
                moved = machine.snapshot
                #expect(machine.snapshot.slots.allSatisfy { $0.owner.host == b })
                #expect(machine.snapshot.registration(for: a.hostID) == .init(host: a, retired: false))
                #expect(throws: V2ActorPlacementError.staleOwner) {
                    try machine.apply(.registerHost(previous: a, successor: successor), revision: 4)
                }
            }
        }
        #expect(machine.snapshot.slots == moved?.slots)
        #expect(machine.snapshot.registration(for: a.hostID) == .init(host: successor, retired: false))
        let voter = a.hostID, roster: Set<V2ActorHostID> = [voter, b.hostID, .init(uuid: UUID())]
        let state = V2PlacementRaftPersistentState(groupID: initial.clusterID, voterID: voter, voters: roster,
            term: 1, log: entries, commitIndex: 5)
        var application = V2PlacementRaftApplication(groupID: initial.clusterID)
        try application.apply(state)
        var core = try V2PlacementRaftCore(id: voter, groupID: initial.clusterID, voters: roster, persisted: state)
        try core.compact(application.checkpoint(), through: 5)
        var reopened = V2PlacementRaftApplication(groupID: initial.clusterID)
        try reopened.apply(V2PlacementRaftProtobuf.decodeFile(V2PlacementRaftProtobuf.encodeFile(core.state)))
        #expect(reopened.snapshot == machine.snapshot)
        #expect(try reopened.receipt(for: commands[1], requestID: ids[1]) == moved)
    }
}
