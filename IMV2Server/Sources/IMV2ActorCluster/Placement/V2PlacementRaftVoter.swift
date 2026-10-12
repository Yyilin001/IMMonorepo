import Foundation
import IMV2ActorContracts

/// A persist success means stable storage has atomically installed the full
/// promised term/vote/log/commit prefix. CAS excludes a second local controller.
/// Cancellation must not return before the actual write has settled.
package protocol V2PlacementRaftStorage: Sendable {
    func load() async throws -> V2PlacementRaftPersistentState
    func persist(_ candidate: V2PlacementRaftPersistentState,
                 replacing expected: V2PlacementRaftPersistentState) async throws
}

/// The actor's explicit FIFO owns a transition across the storage await.
/// Reentrancy cannot publish a vote, old leader action or commit before fsync.
package actor V2PlacementRaftVoter {
    private var core: V2PlacementRaftCore
    private let storage: any V2PlacementRaftStorage
    private var busy = false
    private var accepting = true
    private var failed = false
    private var waiting: [CheckedContinuation<Void, any Error>] = []
    private var stopping: [CheckedContinuation<Void, Never>] = []
    private var pendingReplies: Set<UInt64> = []

    private init(core: V2PlacementRaftCore, storage: any V2PlacementRaftStorage) {
        self.core = core; self.storage = storage
    }
    package static func open(id: V2ActorHostID, groupID: UUID, voters: Set<V2ActorHostID>,
                             storage: any V2PlacementRaftStorage) async throws -> V2PlacementRaftVoter {
        let persisted = try await storage.load()
        return try .init(core: .init(id: id, groupID: groupID, voters: voters, persisted: persisted), storage: storage)
    }
    package func campaign() async throws -> V2PlacementRaftVoteRequest { try await step { try $0.campaign() } }
    package func vote(_ request: V2PlacementRaftVoteRequest, from peer: V2ActorHostID)
        async throws -> V2PlacementRaftVoteReply { try await step { try $0.vote(request, from: peer) } }
    package func receivedVote(_ reply: V2PlacementRaftVoteReply, from peer: V2ActorHostID) async throws {
        try await step { try $0.receivedVote(reply, from: peer) }
    }
    package func propose(_ payload: Data) async throws -> UInt64 { try await step { try $0.propose(payload) } }
    /// The local reply owner pins all committed results until its request has
    /// actually settled. Automatic compaction cannot erase rejected results
    /// or a just-committed proposal while its caller is still awaiting it.
    package func proposeForReply(_ payload: Data) async throws -> UInt64 {
        try await step { core in
            let index = try core.propose(payload)
            pendingReplies.insert(index)
            return index
        }
    }
    package func finishReply(at index: UInt64) { pendingReplies.remove(index) }
    package func compactIfNeeded(minimumCommittedEntries: Int = 4096,
                                 minimumCommittedPayloadBytes: Int = 8 * 1024 * 1024) async throws {
        guard (1...V2PlacementRaftCore.maximumEntries).contains(minimumCommittedEntries),
              (1...V2PlacementRaftProtobuf.maximumFileBytes / 2).contains(minimumCommittedPayloadBytes) else {
            throw V2PlacementRaftError.invalidConfiguration
        }
        try await step { core in
            guard core.role == .leader, pendingReplies.isEmpty else { return }
            let committed = Int(core.state.commitIndex - core.state.baseIndex)
            // CAS requests contain a full expected snapshot. A large topology
            // can exhaust the physical file long before 4096 entries. Local
            // byte-driven compaction does not change deterministic archive GC.
            let payloadBytes = core.state.log.prefix(committed).reduce(0) { $0 + $1.payload.count }
            guard committed >= minimumCommittedEntries || payloadBytes >= minimumCommittedPayloadBytes else { return }
            var application = V2PlacementRaftApplication(groupID: core.state.groupID)
            try application.apply(core.state)
            guard application.snapshot != nil else { return }
            let checkpoint: Data
            do { checkpoint = try application.checkpoint() }
            catch V2PlacementRaftError.capacity {
                // The success-receipt archive has an independent bound. Do
                // not discard receipts or stop the election driver to trim it.
                return
            }
            try core.compact(checkpoint, through: core.state.commitIndex)
        }
    }
    package func appendRequest(to peer: V2ActorHostID, maximumEntries: Int = 16, readID: UUID? = nil)
        async throws -> V2PlacementRaftAppendRequest {
        try await step { try $0.appendRequest(to: peer, maximumEntries: maximumEntries, readID: readID) }
    }
    package func append(_ request: V2PlacementRaftAppendRequest, from peer: V2ActorHostID)
        async throws -> V2PlacementRaftAppendReply { try await step { try $0.append(request, from: peer) } }
    package func receivedAppend(_ reply: V2PlacementRaftAppendReply, from peer: V2ActorHostID,
                                for request: V2PlacementRaftAppendRequest) async throws {
        try await step { try $0.receivedAppend(reply, from: peer, for: request) }
    }
    package func replication(to peer: V2ActorHostID, readID: UUID? = nil) async throws -> V2PlacementRaftReplication {
        try await step { try $0.replication(to: peer, readID: readID) }
    }
    package func snapshot(_ request: V2PlacementRaftSnapshotChunk, from peer: V2ActorHostID) async throws -> V2PlacementRaftSnapshotReply {
        try await step { try $0.snapshot(request, from: peer) }
    }
    package func receivedSnapshot(_ reply: V2PlacementRaftSnapshotReply, from peer: V2ActorHostID,
                                  for request: V2PlacementRaftSnapshotChunk) async throws {
        try await step { try $0.receivedSnapshot(reply, from: peer, for: request) }
    }
    package func compact(_ checkpoint: Data, through index: UInt64) async throws {
        try await step { try $0.compact(checkpoint, through: index) }
    }
    package func beginRead() async throws -> UUID { try await step { try $0.beginRead() } }
    package func confirmedRead(_ id: UUID) async throws -> UInt64? { try await step { $0.confirmedRead(id) } }
    package func finishRead(_ id: UUID) async throws { try await step { $0.finishRead(id) } }
    package func committedState() async throws -> V2PlacementRaftPersistentState { try await step { $0.state } }

    /// Diagnostic only. Consensus actions always enter the FIFO above.
    package func inspection() -> (state: V2PlacementRaftPersistentState, role: V2PlacementRaftCore.Role, leader: V2ActorHostID?, activity: UInt64, busy: Bool, failed: Bool, accepting: Bool, queued: Int) {
        (core.state, core.role, core.leader, core.electionActivity, busy, failed, accepting, waiting.count)
    }
    package func stop() async {
        accepting = false
        let pending = waiting; waiting.removeAll()
        for continuation in pending { continuation.resume(throwing: V2PlacementRaftError.closed) }
        if busy { await withCheckedContinuation { stopping.append($0) } }
    }

    private func step<Value: Sendable>(_ transition: (inout V2PlacementRaftCore) throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        var candidate = core
        let result = try transition(&candidate)
        if candidate.state != core.state {
            do { try await storage.persist(candidate.state, replacing: core.state) }
            catch {
                // An uncertain write may already have advanced the durable
                // promise. This process cannot answer from its older memory.
                failed = true
                throw V2PlacementRaftError.storageUnavailable
            }
        }
        core = candidate
        return result
    }
    private func acquire() async throws {
        guard accepting else { throw V2PlacementRaftError.closed }
        guard !failed else { throw V2PlacementRaftError.storageUnavailable }
        if !busy { busy = true; return }
        guard waiting.count < 128 else { throw V2PlacementRaftError.capacity }
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    private func release() {
        if accepting && !failed && !waiting.isEmpty {
            waiting.removeFirst().resume(); return
        }
        busy = false
        let pending = waiting; waiting.removeAll()
        for continuation in pending {
            continuation.resume(throwing: failed ? V2PlacementRaftError.storageUnavailable : V2PlacementRaftError.closed)
        }
        let stops = stopping; stopping.removeAll()
        for continuation in stops { continuation.resume() }
    }
}
