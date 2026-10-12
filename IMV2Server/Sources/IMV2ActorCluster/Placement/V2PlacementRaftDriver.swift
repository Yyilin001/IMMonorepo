import Foundation
import IMV2ActorContracts

package protocol V2PlacementRaftElectionTransport: V2PlacementRaftTransport {
    func vote(_ request: V2PlacementRaftVoteRequest, to peer: V2ActorHostID,
              deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftVoteReply
}

/// The owning service runs this within its lifecycle and cancels/awaits it
/// before stopping the voter or storage. No detached tasks or timeout ownership
/// claims occur: timers start elections; only persisted quorum advances Raft.
package actor V2PlacementRaftDriver {
    private let voter: V2PlacementRaftVoter
    private let transport: any V2PlacementRaftElectionTransport
    private let peers: Set<V2ActorHostID>
    private let heartbeat: Duration
    private let election: ClosedRange<Int64>
    private let tick: Duration
    private var running = false

    package init(voter: V2PlacementRaftVoter, id: V2ActorHostID, voters: Set<V2ActorHostID>,
                 transport: any V2PlacementRaftElectionTransport,
                 heartbeatMilliseconds: Int64 = 100,
                 electionMilliseconds: ClosedRange<Int64> = 700...1300,
                 tickMilliseconds: Int64 = 10) throws {
        guard voters.count == 3, voters.contains(id), heartbeatMilliseconds >= 10,
              heartbeatMilliseconds <= 1000, electionMilliseconds.lowerBound >= heartbeatMilliseconds * 3,
              electionMilliseconds.upperBound > electionMilliseconds.lowerBound,
              electionMilliseconds.upperBound <= 30_000, tickMilliseconds > 0,
              tickMilliseconds <= heartbeatMilliseconds else { throw V2PlacementRaftError.invalidConfiguration }
        self.voter = voter; self.transport = transport; self.peers = voters.subtracting([id])
        self.heartbeat = .milliseconds(heartbeatMilliseconds); self.election = electionMilliseconds
        self.tick = .milliseconds(tickMilliseconds)
    }
    package func run() async throws {
        guard !running else { throw V2PlacementRaftError.invalidConfiguration }
        running = true
        defer { running = false }
        var observed = await voter.inspection()
        var electionDue = ContinuousClock.now + randomizedElection()
        var heartbeatDue = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let current = await voter.inspection()
            guard current.accepting else { return }
            guard !current.failed else { throw V2PlacementRaftError.storageUnavailable }
            if current.activity != observed.activity || current.state.term != observed.state.term {
                electionDue = ContinuousClock.now + randomizedElection()
            }
            observed = current
            if !current.busy {
                do {
                    if current.role == .leader {
                        if ContinuousClock.now >= heartbeatDue {
                            heartbeatDue = ContinuousClock.now + heartbeat
                            try await replicate(deadline: ContinuousClock.now + heartbeat)
                            try await voter.compactIfNeeded()
                        }
                    } else if ContinuousClock.now >= electionDue {
                        electionDue = ContinuousClock.now + randomizedElection()
                        try await campaign(deadline: ContinuousClock.now + heartbeat)
                        heartbeatDue = ContinuousClock.now
                    }
                } catch V2PlacementRaftError.notLeader {
                    // A higher term can arrive while a network round is in
                    // flight. The voter already persisted its step-down.
                }
            }
            try await Task.sleep(for: tick)
        }
    }
    private func randomizedElection() -> Duration { .milliseconds(Int64.random(in: election)) }
    private func campaign(deadline: ContinuousClock.Instant) async throws {
        let request = try await voter.campaign()
        try await withThrowingTaskGroup(of: (V2ActorHostID, V2PlacementRaftVoteReply?).self) { group in
            for peer in peers {
                group.addTask { [transport] in (peer, try? await transport.vote(request, to: peer, deadline: deadline)) }
            }
            for try await (peer, reply) in group {
                if let reply { try await voter.receivedVote(reply, from: peer) }
                if await voter.inspection().role == .leader { group.cancelAll(); break }
            }
        }
    }
    private func replicate(deadline: ContinuousClock.Instant) async throws {
        var requests: [(V2ActorHostID, V2PlacementRaftReplication)] = []
        for peer in peers { requests.append((peer, try await voter.replication(to: peer))) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (peer, request) in requests {
                group.addTask { [transport, voter] in
                    try await V2PlacementRaftReplicationRound.run(request, to: peer, voter: voter, transport: transport, deadline: deadline)
                }
            }
            for try await _ in group {}
        }
    }
}
