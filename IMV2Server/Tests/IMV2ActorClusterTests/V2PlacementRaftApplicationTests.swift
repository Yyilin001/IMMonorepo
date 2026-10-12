import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Placement applies only certified Raft history")
struct V2PlacementRaftApplicationTests {
    private func initial(successor: V2ActorHostIdentity? = nil) throws -> V2ActorPlacementSnapshot {
        let owner = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        return try .init(clusterID: UUID(), revision: 1, slots: [.init(owner: .init(host: owner, epoch: 1), transfer: nil)],
            hosts: [.init(host: owner, retired: false)] + (successor.map { [.init(host: $0, retired: false)] } ?? []))
    }
    private func state(_ snapshot: V2ActorPlacementSnapshot) throws -> V2PlacementRaftPersistentState {
        let voter = snapshot.slots[0].owner.host.hostID
        return try .init(groupID: snapshot.clusterID, voterID: voter,
            voters: [voter, .init(uuid: UUID()), .init(uuid: UUID())], term: 1,
            log: [.init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(snapshot)))], commitIndex: 1)
    }

    @Test("An uncommitted suffix cannot publish ownership; restart restores exact successful request receipts")
    func committedAndReplay() throws {
        let successor = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let initial = try initial(successor: successor), owner = initial.slots[0].owner, id = UUID()
        let begin = V2ActorPlacementCommand.beginTransfer(partition: 0, expected: owner, transfer: .init(id: id, successor: successor))
        var state = try state(initial)
        var machine = V2PlacementRaftApplication(groupID: initial.clusterID)
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(begin, expected: initial, requestID: id))))
        try machine.apply(state)
        #expect(machine.snapshot == initial)
        #expect(try machine.result(at: 2) == nil)
        state.commitIndex = 2; try machine.apply(state)
        let withdrawn = try #require(machine.snapshot)
        #expect(withdrawn.revision == 2 && withdrawn.slots[0].transfer?.id == id)
        let complete = V2ActorPlacementCommand.completeTransfer(partition: 0, expected: owner, transferID: id)
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(complete, expected: withdrawn, requestID: id))))
        state.commitIndex = 3; try machine.apply(state)
        let final = try #require(machine.snapshot)
        #expect(final.slots[0].owner.host == successor && final.slots[0].owner.epoch == 2)
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(complete, expected: initial, requestID: id, originRevision: withdrawn.revision))))
        state.commitIndex = 4; try machine.apply(state)
        #expect(machine.snapshot == final)
        #expect(try machine.result(at: 4)?.get() == final)
        var restarted = V2PlacementRaftApplication(groupID: initial.clusterID)
        try restarted.apply(state)
        #expect(restarted.snapshot == final)
        #expect(try restarted.receipt(for: begin, requestID: id) == withdrawn)
        #expect(try restarted.receipt(for: complete, requestID: id) == final)
    }

    @Test("A refreshed CAS cannot rebind a committed request to a new origin version")
    func immutableOrigin() throws {
        let initial = try initial(), command = V2ActorPlacementCommand.retireHost(initial.slots[0].owner.host), id = UUID()
        var stable = try state(initial), machine = V2PlacementRaftApplication(groupID: initial.clusterID)
        stable.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
            .command(command, expected: initial, requestID: id, originRevision: initial.revision))))
        stable.commitIndex = 2
        try machine.apply(stable)
        let current = try #require(machine.snapshot)
        let validReplay = V2PlacementRaftApplication.Operation.command(command, expected: current,
            requestID: id, originRevision: initial.revision)
        stable.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(validReplay)))
        stable.commitIndex = 3; try machine.apply(stable)
        #expect(try machine.result(at: 3)?.get() == current)
        stable.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(
            .command(command, expected: current, requestID: id, originRevision: current.revision))))
        stable.commitIndex = 4; try machine.apply(stable)
        #expect(throws: V2ActorPlacementError.invalidTransition) { try machine.result(at: 4)?.get() }
        let checkpoint = try machine.checkpoint()
        stable.snapshot = .init(index: 4, term: 1, application: checkpoint); stable.log = []
        var reopened = V2PlacementRaftApplication(groupID: initial.clusterID)
        try reopened.apply(stable)
        #expect(try reopened.receipt(for: command, requestID: id, originRevision: initial.revision) == current)
        #expect(throws: V2ActorPlacementError.invalidTransition) {
            try reopened.receipt(for: command, requestID: id, originRevision: current.revision)
        }
        var missing = Im_Actor_V1_PlacementRaftOperation()
        missing.requestID = V2HotPB.bytes(id); missing.expectedSnapshot = try V2ActorPlacementProtobuf.encode(current)
        missing.command = try V2ActorPlacementProtobuf.encode(command)
        #expect(throws: V2PlacementRaftError.invalidMessage) {
            try V2PlacementRaftApplication.decode(missing.serializedData())
        }
    }

    @Test("Concurrent stale CAS and reused request ID reject without changing the committed placement")
    func rejectedCAS() throws {
        let initial = try initial(), owner = initial.slots[0].owner, id = UUID()
        let command = V2ActorPlacementCommand.retireHost(owner.host)
        var state = try state(initial), machine = V2PlacementRaftApplication(groupID: initial.clusterID)
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(command, expected: initial, requestID: id))))
        state.commitIndex = 2; try machine.apply(state)
        let retired = try #require(machine.snapshot)
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(command, expected: initial, requestID: UUID()))))
        state.commitIndex = 3; try machine.apply(state)
        #expect(throws: V2ActorPlacementError.staleRevision) { try machine.result(at: 3)?.get() }
        let different = V2ActorPlacementCommand.retireHost(.init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
        state.log.append(try .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(different, expected: retired, requestID: id))))
        state.commitIndex = 4; try machine.apply(state)
        #expect(throws: V2ActorPlacementError.invalidTransition) { try machine.result(at: 4)?.get() }
        #expect(machine.snapshot == retired && machine.appliedIndex == 4)
    }

    @Test("Changed committed prefix and malformed PB cannot partially advance the application")
    func corruptPrefix() throws {
        let initial = try initial()
        var state = try state(initial), machine = V2PlacementRaftApplication(groupID: initial.clusterID)
        try machine.apply(state)
        state.log.append(.init(term: 1, payload: Data()))
        state.log.append(.init(term: 1, payload: Data([0xff])))
        state.commitIndex = 3
        #expect(throws: (any Error).self) { try machine.apply(state) }
        #expect(machine.appliedIndex == 1 && machine.snapshot == initial)
        state.log[0] = .init(term: 1, payload: Data())
        #expect(throws: V2PlacementRaftError.invalidState) { try machine.apply(state) }
        #expect(machine.appliedIndex == 1)
    }
}
