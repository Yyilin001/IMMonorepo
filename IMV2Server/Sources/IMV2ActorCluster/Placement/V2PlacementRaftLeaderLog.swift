import Foundation
import IMV2ActorContracts

/// Production transport must authenticate both voter identities, bind replies
/// to this exact request/group, enforce the supplied monotonic deadline, and
/// promptly cancel the local network wait without discarding remote durability.
package protocol V2PlacementRaftTransport: Sendable {
    func append(_ request: V2PlacementRaftAppendRequest, to peer: V2ActorHostID,
                deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftAppendReply
    func snapshot(_ request: V2PlacementRaftSnapshotChunk, to peer: V2ActorHostID,
                  deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftSnapshotReply
}

/// Leader-side adapter for the existing placement coordination API. A follower
/// must forward to the leader through authenticated control transport; reading
/// its local committed prefix directly is not a linearizable load operation.
package actor V2PlacementRaftLeaderLog: V2ActorPlacementInspectableLog {
    package nonisolated let groupID: UUID
    package nonisolated let localID: V2ActorHostID
    package nonisolated let voter: V2PlacementRaftVoter
    private let transport: any V2PlacementRaftTransport
    private let peers: Set<V2ActorHostID>
    private let timeout: Duration
    private var application: V2PlacementRaftApplication

    package init(voter: V2PlacementRaftVoter, id: V2ActorHostID, groupID: UUID,
                 voters: Set<V2ActorHostID>, transport: any V2PlacementRaftTransport,
                 timeout: Duration = .seconds(5)) throws {
        guard voters.count == 3, voters.contains(id), timeout > .zero, timeout <= .seconds(30) else {
            throw V2PlacementRaftError.invalidConfiguration
        }
        self.voter = voter; self.transport = transport; self.peers = voters.subtracting([id]); self.timeout = timeout
        self.application = .init(groupID: groupID)
        self.groupID = groupID; self.localID = id
    }

    package func load() async throws -> V2ActorPlacementSnapshot {
        try await load(deadline: ContinuousClock.now + timeout)
    }
    package func load(deadline requestedDeadline: ContinuousClock.Instant) async throws -> V2ActorPlacementSnapshot {
        let deadline = min(requestedDeadline, ContinuousClock.now + timeout)
        guard let result = try await readApplicationSnapshot(deadline: deadline) else { throw V2ActorPlacementError.unavailable }
        return result
    }
    package func inspect(deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementInspection {
        _ = try await load(deadline: deadline)
        // Capture both values without suspension. Reentrant callers can only
        // have advanced this application through another durable commit.
        guard let snapshot = application.snapshot else { throw V2ActorPlacementError.unavailable }
        return try .init(snapshot: snapshot, archiveUsage: application.archiveUsage())
    }
    private func readApplicationSnapshot(deadline: ContinuousClock.Instant, originRevision: UInt64? = nil) async throws -> V2ActorPlacementSnapshot? {
        let read = try await voter.beginRead()
        do {
            while true {
                try check(deadline)
                try await replicate(readID: read, target: nil, deadline: deadline)
                if let index = try await voter.confirmedRead(read) {
                    try await apply(through: index)
                    let result = application.snapshot
                    try await voter.finishRead(read)
                    return result
                }
                // A higher-term reply must fail the read rather than extending
                // an old leader's wait until its timeout.
                _ = try await voter.replication(to: peers.first!, readID: read)
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            try? await voter.finishRead(read)
            throw error
        }
    }

    package func bootstrap(_ initial: V2ActorPlacementSnapshot) async throws -> V2ActorPlacementSnapshot {
        try await ensureBootstrap(initial, requireMatchingGenesis: true)
    }

    /// Deployment startup may have a different host roster from genesis.
    /// Existing ownership always comes from a fresh quorum read; the supplied
    /// affinity is used only when the certified application is still empty.
    package func open(_ initial: V2ActorPlacementSnapshot) async throws -> V2ActorPlacementSnapshot {
        try await ensureBootstrap(initial, requireMatchingGenesis: false)
    }

    private func ensureBootstrap(_ initial: V2ActorPlacementSnapshot, requireMatchingGenesis: Bool) async throws -> V2ActorPlacementSnapshot {
        guard initial.clusterID == application.groupID, initial.revision == 1 else {
            throw V2ActorPlacementError.conflictingSnapshot
        }
        // Startup does not append another genesis to an existing history.
        // Only a fresh majority read can certify the existing application.
        let deadline = ContinuousClock.now + timeout
        while true {
            try check(deadline)
            do {
                if let current = try await readApplicationSnapshot(deadline: deadline) {
                    if !requireMatchingGenesis { return current }
                    guard let result = try application.bootstrapReceipt(initial) else { throw V2PlacementRaftError.invalidState }
                    return result
                }
                return try await submit(.bootstrap(initial), deadline: deadline)
            } catch V2PlacementRaftError.notReady {
                // A newly elected leader must commit its barrier first. This
                // also works without a concurrent lifecycle heartbeat driver.
                let state = try await voter.committedState()
                try await replicate(readID: nil, target: state.lastIndex, deadline: deadline)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    package func append(_ command: V2ActorPlacementCommand, evidence: V2ActorPlacementCommandEvidence, expected: V2ActorPlacementSnapshot,
                        requestID: UUID, originRevision: UInt64) async throws -> V2ActorPlacementSnapshot {
        try await append(command, expected: expected, requestID: requestID, deadline: .now + timeout,
            originRevision: originRevision)
    }
    package func certifiedReceipt(_ command: V2ActorPlacementCommand, requestID: UUID,
                                  deadline: ContinuousClock.Instant, originRevision: UInt64? = nil) async throws -> V2ActorPlacementSnapshot? {
        _ = try await load(deadline: deadline)
        return try application.receipt(for: command, requestID: requestID, originRevision: originRevision)
    }
    package func append(_ command: V2ActorPlacementCommand, expected: V2ActorPlacementSnapshot,
                        requestID: UUID, deadline: ContinuousClock.Instant, originRevision requestedOrigin: UInt64? = nil) async throws -> V2ActorPlacementSnapshot {
        let originRevision = requestedOrigin ?? expected.revision
        guard expected.clusterID == application.groupID else { throw V2ActorPlacementError.conflictingSnapshot }
        // Check current authority and committed history before replaying an old
        // receipt. A partitioned old leader cannot answer from local memory.
        _ = try await load(deadline: deadline)
        if let prior = try application.receipt(for: command, requestID: requestID, originRevision: originRevision) { return prior }
        return try await submit(.command(command, expected: expected, requestID: requestID, originRevision: originRevision), deadline: deadline)
    }
    private func submit(_ operation: V2PlacementRaftApplication.Operation, deadline requestedDeadline: ContinuousClock.Instant? = nil) async throws -> V2ActorPlacementSnapshot {
        let deadline = min(requestedDeadline ?? .now + timeout, .now + timeout)
        try check(deadline)
        let payload = try V2PlacementRaftApplication.encode(operation)
        let index = try await voter.proposeForReply(payload)
        do {
            let result = try await waitForProposal(payload: payload, index: index, deadline: deadline)
            await voter.finishReply(at: index)
            return result
        } catch {
            await voter.finishReply(at: index)
            throw error
        }
    }
    private func waitForProposal(payload: Data, index: UInt64, deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementSnapshot {
        while true {
            try check(deadline)
            try await replicate(readID: nil, target: index, deadline: deadline)
            let state = try await voter.committedState()
            if state.commitIndex >= index {
                guard state.entry(at: index)?.payload == payload else { throw V2PlacementRaftError.notLeader }
                try install(state)
                guard let result = try application.result(at: index) else { throw V2PlacementRaftError.invalidState }
                return try result.get()
            }
            _ = try await voter.replication(to: peers.first!)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func apply(through index: UInt64) async throws {
        let state = try await voter.committedState()
        guard state.commitIndex >= index else { throw V2PlacementRaftError.notReady }
        try install(state)
        guard application.appliedIndex >= index else { throw V2PlacementRaftError.notReady }
    }
    private func install(_ state: V2PlacementRaftPersistentState) throws {
        // Another call may have applied a newer authoritative prefix while
        // this call awaited the voter's FIFO. Never roll the application back.
        if state.commitIndex < application.appliedIndex { return }
        try application.apply(state)
    }
    private func replicate(readID: UUID?, target: UInt64?, deadline: ContinuousClock.Instant) async throws {
        var requests: [(V2ActorHostID, V2PlacementRaftReplication)] = []
        for peer in peers { requests.append((peer, try await voter.replication(to: peer, readID: readID))) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (peer, request) in requests {
                group.addTask { [transport, voter] in
                    try await V2PlacementRaftReplicationRound.run(request, to: peer, voter: voter, transport: transport, deadline: deadline)
                }
            }
            for try await _ in group {
                let readReady: Bool
                if let readID { readReady = try await voter.confirmedRead(readID) != nil } else { readReady = false }
                let committed: Bool
                if let target { committed = try await voter.committedState().commitIndex >= target } else { committed = false }
                if readReady || committed {
                    // Raft requires a majority, not the slowest third voter.
                    // Future heartbeat rounds continue replicating that peer.
                    group.cancelAll()
                    break
                }
            }
        }
    }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
    }
}
