import Crypto
import Foundation
import IMV2ActorContracts
import SwiftProtobuf

/// Fixed-field PB with a checksum; no Codable/Value tree enters durable voting.
package enum V2PlacementRaftProtobuf {
    package static let maximumFileBytes = 64 * 1024 * 1024
    package static func encodeFile(_ state: V2PlacementRaftPersistentState) throws -> Data {
        try validate(state)
        var wire = Im_Actor_V1_PlacementRaftState()
        wire.localVoterID = state.voterID.rawValue
        wire.groupID = V2HotPB.bytes(state.groupID)
        wire.voterIds = state.voters.map(\.rawValue).sorted()
        wire.currentTerm = state.term
        if let vote = state.votedFor { wire.votedFor = vote.rawValue }
        wire.entries = state.log.map { entry in
            var value = Im_Actor_V1_PlacementRaftEntry(); value.term = entry.term; value.payload = entry.payload; return value
        }
        wire.commitIndex = state.commitIndex
        if let snapshot = state.snapshot {
            wire.snapshotIndex = snapshot.index; wire.snapshotTerm = snapshot.term; wire.applicationCheckpoint = snapshot.application
        }
        let bytes = try wire.serializedData()
        var file = Im_Actor_V1_PlacementRaftFile()
        file.format = 1; file.state = bytes; file.digest = Data(SHA256.hash(data: bytes))
        let encoded = try file.serializedData()
        guard encoded.count <= maximumFileBytes else { throw V2PlacementRaftError.capacity }
        return encoded
    }
    package static func decodeFile(_ bytes: Data) throws -> V2PlacementRaftPersistentState {
        guard !bytes.isEmpty, bytes.count <= maximumFileBytes else { throw V2PlacementRaftError.invalidState }
        let file = try Im_Actor_V1_PlacementRaftFile(serializedBytes: bytes)
        try V2HotPB.check(file, file.format == 1 && !file.state.isEmpty && file.digest.count == 32)
        guard Data(SHA256.hash(data: file.state)) == file.digest else { throw V2PlacementRaftError.invalidState }
        let wire = try Im_Actor_V1_PlacementRaftState(serializedBytes: file.state)
        try V2HotPB.check(wire, wire.voterIds.count == 3 && wire.entries.count <= V2PlacementRaftCore.maximumEntries)
        let voters = try Set(wire.voterIds.map { try V2ActorHostID($0) })
        guard voters.count == 3 else { throw V2PlacementRaftError.invalidState }
        let snapshot: V2PlacementRaftSnapshot?
        if wire.snapshotIndex > 0 {
            snapshot = .init(index: wire.snapshotIndex, term: wire.snapshotTerm, application: wire.applicationCheckpoint)
        } else {
            guard wire.snapshotTerm == 0, wire.applicationCheckpoint.isEmpty else { throw V2PlacementRaftError.invalidState }
            snapshot = nil
        }
        let state = try V2PlacementRaftPersistentState(groupID: V2HotPB.uuid(wire.groupID), voterID: V2ActorHostID(wire.localVoterID), voters: voters,
            term: wire.currentTerm, votedFor: wire.hasVotedFor ? V2ActorHostID(wire.votedFor) : nil,
            log: wire.entries.map { entry in
                try V2HotPB.check(entry, entry.term > 0 && entry.payload.count <= V2PlacementRaftCore.maximumPayloadBytes)
                return .init(term: entry.term, payload: entry.payload)
            }, commitIndex: wire.commitIndex, snapshot: snapshot)
        try validate(state)
        return state
    }
    private static func validate(_ state: V2PlacementRaftPersistentState) throws {
        _ = try V2PlacementRaftCore(id: state.voterID, groupID: state.groupID, voters: state.voters, persisted: state)
    }
}
