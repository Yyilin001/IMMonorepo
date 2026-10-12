import Foundation
import IMV2ActorContracts

package protocol V2PlacementRaftWriteTransport: Sendable {
    func write(_ request: V2PlacementRaftWriteCodec.Request, to peer: V2ActorHostID,
               deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWriteCodec.Reply
}

extension V2PlacementRaftClusterTransport: V2PlacementRaftWriteTransport {
    package func write(_ request: V2PlacementRaftWriteCodec.Request, to peer: V2ActorHostID,
                       deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWriteCodec.Reply {
        let wire = try V2PlacementRaftWriteCodec.request(request, shard: shardID)
        let host = try await resolve(peer, deadline)
        guard host.hostID == peer else { throw V2PlacementRaftError.unauthorizedVoter }
        let response = try await client.writePlacement(wire, on: host, deadline: deadline)
        return try V2PlacementRaftWriteCodec.decode(response, groupID: request.expected.clusterID, shard: shardID)
    }
}

/// Hosts submit typed control commands, never arbitrary Raft log entries.
/// A retry retains both the original CAS snapshot and durable request identity.
/// Drain certificates are made only from native Host capabilities; the leader
/// independently verifies them before committing a first terminal operation.
package actor V2PlacementRaftRemoteLog: V2ActorPlacementLog {
    private let groupID: UUID
    private let shardID: String
    private let peers: Set<V2ActorHostID>
    private let reader: V2PlacementRaftReader
    private let transport: any V2PlacementRaftWriteTransport
    private let signer: V2ActorSigningIdentity
    private let timeout: Duration
    private var preferred: V2ActorHostID?

    package init(groupID: UUID, shardID: String, peers: Set<V2ActorHostID>,
                 reader: V2PlacementRaftReader, transport: any V2PlacementRaftWriteTransport,
                 signer: V2ActorSigningIdentity, timeout: Duration = .seconds(5)) throws {
        guard peers.count == 3, !shardID.isEmpty, shardID.utf8.count <= 256, timeout > .zero, timeout <= .seconds(30) else {
            throw V2PlacementRaftError.invalidConfiguration
        }
        self.groupID = groupID; self.shardID = shardID; self.peers = peers
        self.reader = reader; self.transport = transport; self.signer = signer; self.timeout = timeout
    }

    package func load() async throws -> V2ActorPlacementSnapshot {
        try await reader.load(deadline: .now + timeout)
    }

    package func append(_ command: V2ActorPlacementCommand, evidence: V2ActorPlacementCommandEvidence,
                        expected: V2ActorPlacementSnapshot, requestID: UUID, originRevision: UInt64) async throws -> V2ActorPlacementSnapshot {
        guard expected.clusterID == groupID, originRevision > 0 else { throw V2PlacementRaftError.wrongGroup }
        let certificate: V2ActorSignedPacket?
        switch evidence {
        case .none: certificate = nil
        case .partition(let receipt):
            guard receipt.clusterID == groupID,
                  case .completeTransfer(let partition, let owner, let transferID) = command,
                  partition == receipt.partition, owner == receipt.owner, transferID == receipt.transferID,
                  let packet = receipt.certificate else { throw V2ActorAuthenticationError.forbidden }
            certificate = packet
        case .host(let proof, let previous, let registrationRequestID):
            guard case .retireHost(let host) = command, host == proof.host else {
                throw V2ActorAuthenticationError.forbidden
            }
            certificate = try V2PlacementDrainCertificate.signHost(proof, shard: shardID, groupID: groupID,
                previous: previous, registrationRequestID: registrationRequestID, signer: signer)
        case .excludedHost(let proof):
            guard case .retireHost(let host) = command, host == proof.host,
                  requestID == proof.operationID else { throw V2ActorAuthenticationError.forbidden }
            certificate = try V2PlacementDrainCertificate.signExclusion(proof, shard: shardID,
                groupID: groupID, signer: signer)
        }
        let request = V2PlacementRaftWriteCodec.Request(command: command, expected: expected,
                                                       requestID: requestID, certificate: certificate, originRevision: originRevision)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var pending = peers.sorted { $0.rawValue < $1.rawValue }
            if let preferred { pending.removeAll { $0 == preferred }; pending.insert(preferred, at: 0) }
            var visited = Set<V2ActorHostID>()
            while !pending.isEmpty && ContinuousClock.now < deadline {
                let peer = pending.removeFirst()
                guard visited.insert(peer).inserted else { continue }
                let reply: V2PlacementRaftWriteCodec.Reply
                do { reply = try await transport.write(request, to: peer, deadline: min(deadline, .now + .seconds(1))) }
                catch {
                    try Task.checkCancellation()
                    continue
                }
                switch reply {
                case .ready(let snapshot):
                    guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
                    preferred = peer
                    return snapshot
                case .rejected(let error): throw error
                case .retry(let hint):
                    if let hint {
                        guard peers.contains(hint) else { throw V2PlacementRaftError.unauthorizedVoter }
                        preferred = hint
                        if !visited.contains(hint) { pending.removeAll { $0 == hint }; pending.insert(hint, at: 0) }
                    }
                }
            }
            try await Task.sleep(for: min(.milliseconds(20), max(.zero, ContinuousClock.now.duration(to: deadline))))
        }
        throw V2ActorPlacementError.unavailable
    }
}

extension V2PlacementRaftRemoteLog: V2ActorPlacementInspectableLog {
    package func inspect(deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementInspection {
        try await reader.inspect(deadline: min(deadline, .now + timeout))
    }
}
