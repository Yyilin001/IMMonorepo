import Foundation
import IMV2ActorContracts
import SwiftProtobuf

package enum V2PlacementRaftReadCodec {
    package struct Request: Equatable, Sendable {
        let groupID: UUID
        let includeArchiveUsage: Bool
    }
    package enum Reply: Equatable, Sendable {
        case ready(V2ActorPlacementSnapshot), retry(V2ActorHostID?)
        case inspected(V2ActorPlacementSnapshot, V2PlacementArchiveCapacity.Usage)
    }
    package static func request(groupID: UUID, shard: String, includeArchiveUsage: Bool = false) throws -> V2PlacementRaftWire {
        var pb = Im_Actor_V1_PlacementRaftReadRequest(); pb.groupID = V2HotPB.bytes(groupID)
        pb.includeArchiveUsage = includeArchiveUsage
        return .init(shardID: shard, payload: try pb.serializedData())
    }
    package static func decodeRequest(_ wire: V2PlacementRaftWire) throws -> Request {
        guard wire.isBounded else { throw V2PlacementRaftError.invalidMessage }
        let pb = try Im_Actor_V1_PlacementRaftReadRequest(serializedBytes: wire.payload)
        try V2HotPB.check(pb)
        return try .init(groupID: V2HotPB.uuid(pb.groupID), includeArchiveUsage: pb.includeArchiveUsage)
    }
    package static func encode(_ reply: Reply, shard: String, groupID: UUID) throws -> V2PlacementRaftWire {
        var pb = Im_Actor_V1_PlacementRaftReadReply(); pb.groupID = V2HotPB.bytes(groupID)
        switch reply {
        case .ready(let snapshot):
            guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
            pb.snapshot = try V2ActorPlacementProtobuf.encode(snapshot)
        case .inspected(let snapshot, let usage):
            guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
            try validate(usage, snapshot: snapshot)
            pb.snapshot = try V2ActorPlacementProtobuf.encode(snapshot)
            pb.archiveUsage.receipts = UInt64(usage.receipts)
            pb.archiveUsage.bytes = UInt64(usage.bytes)
            pb.archiveUsage.reservedReceipts = UInt64(usage.reservedReceipts)
            pb.archiveUsage.reservedBytes = UInt64(usage.reservedBytes)
        case .retry(let hint): pb.leaderHint = hint?.rawValue ?? ""
        }
        let wire = V2PlacementRaftWire(shardID: shard, payload: try pb.serializedData())
        guard wire.isBounded else { throw V2PlacementRaftError.invalidMessage }
        return wire
    }
    package static func decode(_ wire: V2PlacementRaftWire, shard: String, groupID: UUID) throws -> Reply {
        guard wire.isBounded, wire.shardID == shard else { throw V2PlacementRaftError.invalidMessage }
        let pb = try Im_Actor_V1_PlacementRaftReadReply(serializedBytes: wire.payload)
        try V2HotPB.check(pb)
        guard try V2HotPB.uuid(pb.groupID) == groupID else { throw V2PlacementRaftError.wrongGroup }
        if !pb.snapshot.isEmpty {
            guard pb.leaderHint.isEmpty else { throw V2PlacementRaftError.invalidMessage }
            let snapshot = try V2ActorPlacementProtobuf.decode(pb.snapshot)
            guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
            if pb.hasArchiveUsage {
                try V2HotPB.check(pb.archiveUsage)
                let values = [pb.archiveUsage.receipts, pb.archiveUsage.bytes,
                              pb.archiveUsage.reservedReceipts, pb.archiveUsage.reservedBytes]
                guard values.allSatisfy({ $0 <= UInt64(Int.max) }) else { throw V2PlacementRaftError.invalidMessage }
                let usage = V2PlacementArchiveCapacity.Usage(receipts: Int(values[0]), bytes: Int(values[1]),
                    reservedReceipts: Int(values[2]), reservedBytes: Int(values[3]))
                try validate(usage, snapshot: snapshot)
                return .inspected(snapshot, usage)
            }
            return .ready(snapshot)
        }
        guard !pb.hasArchiveUsage else { throw V2PlacementRaftError.invalidMessage }
        return try .retry(pb.leaderHint.isEmpty ? nil : V2ActorHostID(pb.leaderHint))
    }
    private static func validate(_ usage: V2PlacementArchiveCapacity.Usage,
                                 snapshot: V2ActorPlacementSnapshot) throws {
        try usage.requireCapacity()
        let expected = try V2PlacementArchiveCapacity.usage(snapshot: snapshot,
            receipts: usage.receipts, bytes: usage.bytes)
        guard usage.bytes > 0, usage == expected else { throw V2PlacementRaftError.invalidMessage }
    }
}
package protocol V2PlacementRaftReadTransport: Sendable {
    func read(groupID: UUID, includeArchiveUsage: Bool, from peer: V2ActorHostID,
              deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftReadCodec.Reply
}
extension V2PlacementRaftClusterTransport: V2PlacementRaftReadTransport {
    package func read(groupID: UUID, includeArchiveUsage: Bool, from peer: V2ActorHostID,
                      deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftReadCodec.Reply {
        let request = try V2PlacementRaftReadCodec.request(groupID: groupID, shard: shardID, includeArchiveUsage: includeArchiveUsage)
        let host = try await resolve(peer, deadline)
        guard host.hostID == peer else { throw V2PlacementRaftError.unauthorizedVoter }
        let response = try await client.readPlacement(request, on: host, deadline: deadline)
        return try V2PlacementRaftReadCodec.decode(response, shard: shardID, groupID: groupID)
    }
}

/// Read-only gateways/accounts do not create a voter or open voting storage.
/// Hints prioritize one of the configured three peers but never certify a read.
/// Only the authenticated leader's fresh quorum-checked reply supplies state.
package actor V2PlacementRaftReader {
    private let groupID: UUID
    private let peers: Set<V2ActorHostID>
    private let transport: any V2PlacementRaftReadTransport
    private var preferred: V2ActorHostID?
    package init(groupID: UUID, peers: Set<V2ActorHostID>, transport: any V2PlacementRaftReadTransport) throws {
        guard peers.count == 3 else { throw V2PlacementRaftError.invalidConfiguration }
        self.groupID = groupID; self.peers = peers; self.transport = transport
    }
    package func load(deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementSnapshot {
        guard case .ready(let snapshot) = try await read(deadline: deadline, includeArchiveUsage: false) else {
            throw V2PlacementRaftError.invalidMessage
        }
        return snapshot
    }
    package func inspect(deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementInspection {
        guard case .inspected(let snapshot, let usage) = try await read(deadline: deadline, includeArchiveUsage: true) else {
            throw V2PlacementRaftError.invalidMessage
        }
        return .init(snapshot: snapshot, archiveUsage: usage)
    }
    private func read(deadline: ContinuousClock.Instant, includeArchiveUsage: Bool) async throws -> V2PlacementRaftReadCodec.Reply {
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var pending = peers.sorted { $0.rawValue < $1.rawValue }
            if let preferred { pending.removeAll { $0 == preferred }; pending.insert(preferred, at: 0) }
            var visited = Set<V2ActorHostID>()
            while !pending.isEmpty && ContinuousClock.now < deadline {
                let peer = pending.removeFirst()
                guard visited.insert(peer).inserted else { continue }
                let reply: V2PlacementRaftReadCodec.Reply
                // A slow first voter must not consume the whole remaining
                // attempt and prevent contacting a healthy majority.
                let now = ContinuousClock.now
                let budget = min(.seconds(1), max(.zero, now.duration(to: deadline)) / (pending.count + 1))
                do { reply = try await transport.read(groupID: groupID, includeArchiveUsage: includeArchiveUsage,
                    from: peer, deadline: min(deadline, now + budget)) }
                catch {
                    try Task.checkCancellation()
                    continue
                }
                switch reply {
                case .ready(let snapshot):
                    guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
                    guard !includeArchiveUsage else { throw V2PlacementRaftError.invalidMessage }
                    preferred = peer
                    return reply
                case .inspected(let snapshot, let usage):
                    guard snapshot.clusterID == groupID else { throw V2PlacementRaftError.wrongGroup }
                    guard includeArchiveUsage else { throw V2PlacementRaftError.invalidMessage }
                    try usage.requireCapacity()
                    preferred = peer
                    return reply
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
