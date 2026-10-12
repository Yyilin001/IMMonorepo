import Foundation
import IMV2ActorContracts
import SwiftProtobuf

/// The authenticated transport carries fixed PB bytes. The declared voter in
/// those bytes is checked against the authenticated service's configured role.
public struct V2PlacementRaftWire: Codable, Equatable, Sendable {
    public let shardID: String
    public let payload: Data
    public init(shardID: String, payload: Data) { self.shardID = shardID; self.payload = payload }
    package var isBounded: Bool {
        !shardID.isEmpty && shardID.utf8.count <= 256 && !payload.isEmpty && payload.count <= 786_432
    }
}
public protocol V2PlacementRaftServing: Sendable {
    func exchangeRaft(_ request: V2PlacementRaftWire, serviceID: V2ActorServiceID,
                      callerIncarnation: UUID, deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWire
}

package enum V2PlacementRaftWireCodec {
    package enum Request: Equatable, Sendable {
        case vote(V2PlacementRaftVoteRequest), append(V2PlacementRaftAppendRequest), snapshot(V2PlacementRaftSnapshotChunk)
    }
    package enum Reply: Equatable, Sendable {
        case vote(V2PlacementRaftVoteReply), append(V2PlacementRaftAppendReply), snapshot(V2PlacementRaftSnapshotReply)
    }
    package static func encode(_ request: Request, shard: String) throws -> V2PlacementRaftWire {
        var wire = Im_Actor_V1_PlacementRaftRequest()
        switch request {
        case .vote(let value):
            var pb = Im_Actor_V1_PlacementRaftVoteRequest()
            pb.groupID = V2HotPB.bytes(value.groupID); pb.candidate = value.candidate.rawValue
            pb.term = value.term; pb.lastIndex = value.lastIndex; pb.lastTerm = value.lastTerm
            wire.body = .vote(pb)
        case .append(let value):
            var pb = Im_Actor_V1_PlacementRaftAppendRequest()
            pb.groupID = V2HotPB.bytes(value.groupID); pb.leader = value.leader.rawValue
            pb.term = value.term; pb.previousIndex = value.previousIndex; pb.previousTerm = value.previousTerm
            pb.leaderCommit = value.leaderCommit
            if let read = value.readID { pb.readID = V2HotPB.bytes(read) }
            pb.entries = value.entries.map { entry in
                var pb = Im_Actor_V1_PlacementRaftEntry(); pb.term = entry.term; pb.payload = entry.payload; return pb
            }
            wire.body = .append(pb)
        case .snapshot(let value):
            guard value.totalBytes > 0, value.totalBytes <= V2PlacementRaftCheckpoint.maximumBytes,
                  value.offset >= 0, value.offset < value.totalBytes,
                  !value.chunk.isEmpty, value.chunk.count <= V2PlacementRaftSnapshotChunk.maximumChunkBytes,
                  value.chunk.count <= value.totalBytes - value.offset, value.digest.count == 32 else {
                throw V2PlacementRaftError.invalidMessage
            }
            var pb = Im_Actor_V1_PlacementRaftSnapshotChunk()
            pb.groupID = V2HotPB.bytes(value.groupID); pb.leader = value.leader.rawValue; pb.term = value.term
            pb.transferID = V2HotPB.bytes(value.transferID); pb.snapshotIndex = value.snapshotIndex; pb.snapshotTerm = value.snapshotTerm
            pb.digest = value.digest; pb.totalBytes = UInt32(value.totalBytes); pb.offset = UInt32(value.offset); pb.chunk = value.chunk
            wire.body = .snapshot(pb)
        }
        return try bounded(shard: shard, payload: wire.serializedData())
    }
    package static func decodeRequest(_ wire: V2PlacementRaftWire) throws -> Request {
        guard wire.isBounded else { throw V2PlacementRaftError.invalidMessage }
        let pb = try Im_Actor_V1_PlacementRaftRequest(serializedBytes: wire.payload)
        try V2HotPB.check(pb)
        switch pb.body {
        case .vote(let value):
            try V2HotPB.check(value)
            return try .vote(.init(groupID: V2HotPB.uuid(value.groupID), candidate: V2ActorHostID(value.candidate),
                term: value.term, lastIndex: value.lastIndex, lastTerm: value.lastTerm))
        case .append(let value):
            try V2HotPB.check(value, value.entries.count <= 16)
            return try .append(.init(groupID: V2HotPB.uuid(value.groupID), leader: V2ActorHostID(value.leader),
                term: value.term, previousIndex: value.previousIndex, previousTerm: value.previousTerm,
                entries: value.entries.map { entry in
                    try V2HotPB.check(entry, entry.payload.count <= V2PlacementRaftCore.maximumPayloadBytes)
                    return .init(term: entry.term, payload: entry.payload)
                }, leaderCommit: value.leaderCommit, readID: optionalID(value.readID)))
        case .snapshot(let value):
            try V2HotPB.check(value, value.totalBytes > 0 && value.totalBytes <= V2PlacementRaftCheckpoint.maximumBytes &&
                value.offset < value.totalBytes && !value.chunk.isEmpty && value.digest.count == 32 &&
                value.chunk.count <= V2PlacementRaftSnapshotChunk.maximumChunkBytes &&
                value.chunk.count <= Int(value.totalBytes - value.offset))
            return try .snapshot(.init(groupID: V2HotPB.uuid(value.groupID), leader: V2ActorHostID(value.leader),
                term: value.term, transferID: V2HotPB.uuid(value.transferID), snapshotIndex: value.snapshotIndex,
                snapshotTerm: value.snapshotTerm, digest: value.digest, totalBytes: Int(value.totalBytes),
                offset: Int(value.offset), chunk: value.chunk))
        case nil: throw V2PlacementRaftError.invalidMessage
        }
    }
    package static func encode(_ reply: Reply, shard: String) throws -> V2PlacementRaftWire {
        var wire = Im_Actor_V1_PlacementRaftReply()
        switch reply {
        case .vote(let value):
            var pb = Im_Actor_V1_PlacementRaftVoteReply()
            pb.groupID = V2HotPB.bytes(value.groupID); pb.term = value.term; pb.granted = value.granted
            wire.body = .vote(pb)
        case .append(let value):
            var pb = Im_Actor_V1_PlacementRaftAppendReply()
            pb.groupID = V2HotPB.bytes(value.groupID); pb.term = value.term; pb.accepted = value.accepted
            pb.matchedIndex = value.matchedIndex
            if let read = value.readID { pb.readID = V2HotPB.bytes(read) }
            wire.body = .append(pb)
        case .snapshot(let value):
            guard value.nextOffset >= 0, value.nextOffset <= V2PlacementRaftCheckpoint.maximumBytes else {
                throw V2PlacementRaftError.invalidMessage
            }
            var pb = Im_Actor_V1_PlacementRaftSnapshotReply()
            pb.groupID = V2HotPB.bytes(value.groupID); pb.term = value.term; pb.transferID = V2HotPB.bytes(value.transferID)
            pb.snapshotIndex = value.snapshotIndex; pb.accepted = value.accepted; pb.nextOffset = UInt32(value.nextOffset)
            pb.installed = value.installed; wire.body = .snapshot(pb)
        }
        return try bounded(shard: shard, payload: wire.serializedData())
    }
    package static func decodeReply(_ wire: V2PlacementRaftWire, shard: String) throws -> Reply {
        guard wire.isBounded, wire.shardID == shard else { throw V2PlacementRaftError.invalidMessage }
        let pb = try Im_Actor_V1_PlacementRaftReply(serializedBytes: wire.payload)
        try V2HotPB.check(pb)
        switch pb.body {
        case .vote(let value):
            try V2HotPB.check(value)
            return try .vote(.init(groupID: V2HotPB.uuid(value.groupID), term: value.term, granted: value.granted))
        case .append(let value):
            try V2HotPB.check(value)
            return try .append(.init(groupID: V2HotPB.uuid(value.groupID), term: value.term, accepted: value.accepted,
                matchedIndex: value.matchedIndex, readID: optionalID(value.readID)))
        case .snapshot(let value):
            try V2HotPB.check(value, value.nextOffset <= V2PlacementRaftCheckpoint.maximumBytes && (!value.installed || value.accepted))
            return try .snapshot(.init(groupID: V2HotPB.uuid(value.groupID), term: value.term,
                transferID: V2HotPB.uuid(value.transferID), snapshotIndex: value.snapshotIndex,
                accepted: value.accepted, nextOffset: Int(value.nextOffset), installed: value.installed))
        case nil: throw V2PlacementRaftError.invalidMessage
        }
    }
    private static func optionalID(_ bytes: Data) throws -> UUID? { bytes.isEmpty ? nil : try V2HotPB.uuid(bytes) }
    private static func bounded(shard: String, payload: Data) throws -> V2PlacementRaftWire {
        let wire = V2PlacementRaftWire(shardID: shard, payload: payload)
        guard wire.isBounded else { throw V2PlacementRaftError.invalidMessage }
        return wire
    }
}
