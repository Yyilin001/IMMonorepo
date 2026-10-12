import Foundation
import Crypto
import IMV2ActorContracts

/// One bounded packet. Partial bytes are transient; only the verified complete
/// checkpoint becomes a durable Raft snapshot, before installed is returned.
package struct V2PlacementRaftSnapshotChunk: Equatable, Sendable {
    package static let maximumChunkBytes = 524_288
    package let groupID: UUID
    package let leader: V2ActorHostID
    package let term: UInt64
    package let transferID: UUID
    package let snapshotIndex: UInt64
    package let snapshotTerm: UInt64
    package let digest: Data
    package let totalBytes: Int
    package let offset: Int
    package let chunk: Data
}
package struct V2PlacementRaftSnapshotReply: Equatable, Sendable {
    package let groupID: UUID
    package let term: UInt64
    package let transferID: UUID
    package let snapshotIndex: UInt64
    package let accepted: Bool
    package let nextOffset: Int
    package let installed: Bool
}

/// Captured from a leader's serialized voter. A newer leader/term invalidates
/// replies; no per-packet full-checkpoint copy or digest calculation is needed.
package struct V2PlacementRaftSnapshotTransfer: Sendable {
    package let groupID: UUID
    package let leader: V2ActorHostID
    package let term: UInt64
    package let transferID: UUID
    package let snapshot: V2PlacementRaftSnapshot
    package let digest: Data
    package init(groupID: UUID, leader: V2ActorHostID, term: UInt64, snapshot: V2PlacementRaftSnapshot) {
        self.groupID = groupID; self.leader = leader; self.term = term; self.snapshot = snapshot
        self.transferID = UUID(); self.digest = Data(SHA256.hash(data: snapshot.application))
    }
    package func chunk(at offset: Int) throws -> V2PlacementRaftSnapshotChunk {
        guard offset >= 0, offset < snapshot.application.count else { throw V2PlacementRaftError.invalidMessage }
        let end = min(offset + V2PlacementRaftSnapshotChunk.maximumChunkBytes, snapshot.application.count)
        return .init(groupID: groupID, leader: leader, term: term, transferID: transferID,
            snapshotIndex: snapshot.index, snapshotTerm: snapshot.term, digest: digest,
            totalBytes: snapshot.application.count, offset: offset, chunk: snapshot.application.subdata(in: offset..<end))
    }
}

package enum V2PlacementRaftReplication: Sendable {
    case append(V2PlacementRaftAppendRequest)
    case snapshot(V2PlacementRaftSnapshotChunk)
}

/// Both the lifecycle heartbeat and foreground quorum rounds use the same
/// catch-up operation. Installing a snapshot is not a ReadIndex confirmation;
/// the next append round establishes current-term read authority normally.
package enum V2PlacementRaftReplicationRound {
    package static func run(_ request: V2PlacementRaftReplication, to peer: V2ActorHostID,
                            voter: V2PlacementRaftVoter, transport: any V2PlacementRaftTransport,
                            deadline: ContinuousClock.Instant) async throws {
        switch request {
        case .append(let value):
            if let reply = try? await transport.append(value, to: peer, deadline: deadline) {
                try await voter.receivedAppend(reply, from: peer, for: value)
            }
        case .snapshot(let chunk):
            if let reply = try? await transport.snapshot(chunk, to: peer, deadline: deadline) {
                try await voter.receivedSnapshot(reply, from: peer, for: chunk)
            }
        }
    }
}
