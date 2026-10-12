import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Placement voter persists promises before replies")
struct V2PlacementRaftVoterTests {
    private let a = V2ActorHostID(uuid: UUID()), b = V2ActorHostID(uuid: UUID()), c = V2ActorHostID(uuid: UUID())
    private let group = UUID()
    private var roster: Set<V2ActorHostID> { [a, b, c] }
    private func open(_ storage: RaftTestStorage) async throws -> V2PlacementRaftVoter {
        try await .open(id: c, groupID: group, voters: roster, storage: storage)
    }
    private func vote(_ candidate: V2ActorHostID) -> V2PlacementRaftVoteRequest {
        .init(groupID: group, candidate: candidate, term: 1, lastIndex: 0, lastTerm: 0)
    }
    private func wait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw V2PlacementRaftError.notReady }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("Payload compaction preserves replies below the entry-count threshold")
    func byteCompaction() async throws {
        let host = V2ActorHostIdentity(hostID: a, incarnationID: UUID())
        let initial = try V2ActorPlacementSnapshot(clusterID: group, revision: 1,
            slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
        let log = [V2PlacementRaftEntry(term: 1, payload: try V2PlacementRaftApplication.encode(.bootstrap(initial)))]
        let storage = RaftTestStorage(.init(groupID: group, voterID: a, voters: roster, term: 1, log: log, commitIndex: 1))
        let voter = try await V2PlacementRaftVoter.open(id: a, groupID: group, voters: roster, storage: storage)
        var follower = try V2PlacementRaftCore(id: b, groupID: group, voters: roster,
            persisted: .init(groupID: group, voterID: b, voters: roster, term: 1, log: log, commitIndex: 1))
        let campaign = try await voter.campaign()
        try await voter.receivedVote(follower.vote(campaign, from: a), from: b)
        var request = try await voter.appendRequest(to: b)
        try await voter.receivedAppend(follower.append(request, from: a), from: b, for: request)
        let requestID = UUID(), command = V2ActorPlacementCommand.retireHost(host)
        let index = try await voter.proposeForReply(V2PlacementRaftApplication.encode(.command(command,
            expected: initial, requestID: requestID)))
        request = try await voter.appendRequest(to: b)
        try await voter.receivedAppend(follower.append(request, from: a), from: b, for: request)
        try await voter.compactIfNeeded(minimumCommittedPayloadBytes: 1)
        #expect(await storage.load().baseIndex == 0) // physical reply still owned
        await voter.finishReply(at: index)
        try await voter.compactIfNeeded()
        #expect(await storage.load().baseIndex == 0) // count and bytes both below production thresholds
        try await voter.compactIfNeeded(minimumCommittedPayloadBytes: 1)
        let compacted = await storage.load()
        #expect(compacted.baseIndex == index && compacted.log.isEmpty)
        var restored = V2PlacementRaftApplication(groupID: group)
        try restored.apply(compacted)
        #expect(try restored.receipt(for: command, requestID: requestID)?.hosts.first?.retired == true)
        await voter.stop()
    }

    @Test("A storage await cannot allow a competing candidate to observe the old promise")
    func serialPromises() async throws {
        let storage = RaftTestStorage(.init(groupID: group, voterID: c, voters: roster))
        let voter = try await open(storage), finished = RaftFinished()
        await storage.block()
        let first = Task { let reply = try await voter.vote(vote(a), from: a); await finished.mark(); return reply }
        try await storage.waitForWrite()
        let second = Task { try await voter.vote(vote(b), from: b) }
        try await wait { await voter.inspection().queued == 1 }
        #expect(await finished.value == false)
        #expect(await voter.inspection().state.term == 0)
        #expect(await voter.inspection().busy)
        await storage.unblock()
        #expect(try await first.value.granted)
        #expect(try await !second.value.granted)
        #expect(await storage.load().votedFor == a)
        #expect(await storage.writes == 1)
        await voter.stop()
    }

    @Test("Cancellation and shutdown retain a promise until its actual write finishes")
    func cancellationAndStop() async throws {
        let storage = RaftTestStorage(.init(groupID: group, voterID: c, voters: roster))
        let voter = try await open(storage), stopped = RaftFinished()
        await storage.block()
        let request = Task { try await voter.vote(vote(a), from: a) }
        try await storage.waitForWrite()
        request.cancel()
        let shutdown = Task { await voter.stop(); await stopped.mark() }
        try await wait { await !voter.inspection().accepting }
        #expect(await voter.inspection().busy)
        #expect(await stopped.value == false)
        await storage.unblock()
        #expect(try await request.value.granted)
        await shutdown.value
        #expect(await stopped.value)
        #expect(await storage.load().votedFor == a)
        await #expect(throws: V2PlacementRaftError.closed) { try await voter.campaign() }
    }

    @Test("An uncertain storage reply poisons older memory; restart preserves the committed vote")
    func lostPersistAck() async throws {
        let storage = RaftTestStorage(.init(groupID: group, voterID: c, voters: roster))
        let voter = try await open(storage)
        await storage.loseNextReply()
        await #expect(throws: V2PlacementRaftError.storageUnavailable) { try await voter.vote(vote(a), from: a) }
        #expect(await storage.load().votedFor == a)
        #expect(await voter.inspection().failed)
        await #expect(throws: V2PlacementRaftError.storageUnavailable) { try await voter.vote(vote(b), from: b) }
        let reopened = try await open(storage)
        #expect(try await !reopened.vote(vote(b), from: b).granted)
        await voter.stop(); await reopened.stop()
    }

    @Test("Storage CAS prevents two local controllers from acknowledging different votes")
    func duplicateController() async throws {
        let storage = RaftTestStorage(.init(groupID: group, voterID: c, voters: roster))
        let first = try await open(storage), second = try await open(storage)
        let outcomes = await withTaskGroup(of: Result<V2PlacementRaftVoteReply, any Error>.self) { tasks in
            tasks.addTask { do { return .success(try await first.vote(vote(a), from: a)) } catch { return .failure(error) } }
            tasks.addTask { do { return .success(try await second.vote(vote(b), from: b)) } catch { return .failure(error) } }
            var result: [Result<V2PlacementRaftVoteReply, any Error>] = []
            for await value in tasks { result.append(value) }
            return result
        }
        #expect(outcomes.filter { if case .success(let reply) = $0 { reply.granted } else { false } }.count == 1)
        #expect(outcomes.filter { if case .failure(let error) = $0 { error as? V2PlacementRaftError == .storageUnavailable } else { false } }.count == 1)
        #expect(await storage.writes == 1)
        await first.stop(); await second.stop()
    }
}

private actor RaftFinished { var value = false; func mark() { value = true } }
actor RaftTestStorage: V2PlacementRaftStorage {
    private var state: V2PlacementRaftPersistentState
    private var blocked = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loseReply = false
    var writes = 0
    init(_ state: V2PlacementRaftPersistentState) { self.state = state }
    func load() -> V2PlacementRaftPersistentState { state }
    func block() { blocked = true }
    func loseNextReply() { loseReply = true }
    func unblock() {
        blocked = false
        let pending = waiters; waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func waitForWrite() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !started {
            guard ContinuousClock.now < deadline else { throw V2PlacementRaftError.notReady }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func persist(_ candidate: V2PlacementRaftPersistentState, replacing expected: V2PlacementRaftPersistentState) async throws {
        started = true
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        guard state == expected else { throw V2PlacementRaftError.invalidState }
        state = candidate; writes += 1
        if loseReply { loseReply = false; throw V2PlacementRaftError.storageUnavailable }
    }
}
