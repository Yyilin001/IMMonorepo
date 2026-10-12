import Foundation
import Crypto
import IMV2ActorContracts
import SwiftProtobuf

/// Only the durable commit prefix is applied. Elections, barriers and rejected
/// CAS commands advance the applied index without publishing a new placement.
/// Reconstructing stable voting state restores recent exact results and pinned
/// lifecycle proofs. An RPC reply is never the source of truth.
package struct V2PlacementRaftApplication: Sendable {
    package enum Operation: Equatable, Sendable {
        case bootstrap(V2ActorPlacementSnapshot)
        case command(V2ActorPlacementCommand, expected: V2ActorPlacementSnapshot, requestID: UUID, originRevision: UInt64)
        package static func command(_ command: V2ActorPlacementCommand, expected: V2ActorPlacementSnapshot,
                                    requestID: UUID) -> Self {
            .command(command, expected: expected, requestID: requestID, originRevision: expected.revision)
        }
    }
    private struct Key: Hashable, Sendable { let id: UUID; let kind: Int }
    private struct Receipt: Sendable { let command: V2ActorPlacementCommand; let revision: UInt64; let originRevision: UInt64 }
    private enum StoredResult: Sendable {
        case success(UInt64)
        case failure(V2ActorPlacementError)
    }
    package let groupID: UUID
    package private(set) var snapshot: V2ActorPlacementSnapshot?
    package private(set) var appliedIndex: UInt64 = 0
    private var genesis: V2ActorPlacementSnapshot?
    private var bootstrapDigest: Data?
    private var pinnedHistory: [V2PlacementRaftCheckpoint.Record] = []
    private var prefixBase: UInt64 = 0
    private var baseCheckpoint: V2PlacementRaftSnapshot?
    private var prefix: [V2PlacementRaftEntry] = []
    private var receipts: [Key: Receipt] = [:]
    private var history: [V2PlacementRaftCheckpoint.Record] = []
    private var archiveBytes = 0
    private var results: [UInt64: StoredResult] = [:]

    package init(groupID: UUID) { self.groupID = groupID }
    package func archiveUsage() throws -> V2PlacementArchiveCapacity.Usage {
        guard let snapshot else { throw V2ActorPlacementError.unavailable }
        return try V2PlacementArchiveCapacity.usage(snapshot: snapshot, receipts: history.count + pinnedHistory.count, bytes: archiveBytes)
    }
    package func bootstrapReceipt(_ initial: V2ActorPlacementSnapshot) throws -> V2ActorPlacementSnapshot? {
        guard let genesis else { return nil }
        guard try (bootstrapDigest ?? Data(SHA256.hash(data: V2ActorPlacementProtobuf.encode(genesis)))) ==
                Data(SHA256.hash(data: V2ActorPlacementProtobuf.encode(initial))), let snapshot else { throw V2ActorPlacementError.conflictingSnapshot }
        return snapshot
    }
    package func checkpoint() throws -> Data {
        guard let genesis, let snapshot else { throw V2ActorPlacementError.unavailable }
        let checkpoint = V2PlacementRaftCheckpoint(groupID: groupID, appliedIndex: appliedIndex,
                                                   genesis: genesis, receipts: history,
                                                   bootstrapDigest: bootstrapDigest, pinnedReceipts: pinnedHistory)
        guard try checkpoint.replay().snapshot == snapshot else { throw V2PlacementRaftError.invalidState }
        return try checkpoint.encode()
    }
    package func result(at index: UInt64) throws -> Result<V2ActorPlacementSnapshot, V2ActorPlacementError>? {
        guard let result = results[index] else { return nil }
        switch result {
        case .success(let revision): return .success(try historicalSnapshot(at: revision))
        case .failure(let error): return .failure(error)
        }
    }
    private func historicalSnapshot(at revision: UInt64) throws -> V2ActorPlacementSnapshot {
        guard let genesis, let snapshot else { throw V2PlacementRaftError.invalidState }
        if revision == snapshot.revision { return snapshot }
        if revision < genesis.revision {
            // Pinned records certify the still-referenced operation, returning
            // the latest committed state instead of reconstructing expired state.
            return snapshot
        }
        return try V2PlacementRaftCheckpoint(groupID: groupID, appliedIndex: appliedIndex,
            genesis: genesis, receipts: history).snapshot(at: revision)
    }
    package func receipt(for command: V2ActorPlacementCommand, requestID: UUID, originRevision: UInt64? = nil) throws -> V2ActorPlacementSnapshot? {
        guard let prior = receipts[.init(id: requestID, kind: command.logKind)] else { return nil }
        guard prior.command == command, originRevision == nil || originRevision == prior.originRevision else { throw V2ActorPlacementError.invalidTransition }
        return try historicalSnapshot(at: prior.revision)
    }
    package mutating func apply(_ state: V2PlacementRaftPersistentState) throws {
        guard state.groupID == groupID, state.baseIndex >= prefixBase,
              state.baseIndex <= V2PlacementRaftCore.maximumLogIndex,
              state.log.count <= V2PlacementRaftCore.maximumEntries, state.commitIndex >= state.baseIndex,
              state.commitIndex >= appliedIndex, state.commitIndex <= state.lastIndex else { throw V2PlacementRaftError.invalidState }
        // Build a complete candidate before publishing either checkpoint or
        // suffix. Unknown commands and corrupt history cannot partly apply.
        var candidate = self
        if state.baseIndex > prefixBase {
            guard let checkpoint = state.snapshot else { throw V2PlacementRaftError.invalidState }
            let decoded = try V2PlacementRaftCheckpoint.decode(checkpoint.application, groupID: groupID)
            guard decoded.appliedIndex == checkpoint.index else { throw V2PlacementRaftError.invalidState }
            if appliedIndex >= state.baseIndex {
                var historical = state
                historical.snapshot = baseCheckpoint; historical.log = prefix
                historical.commitIndex = state.baseIndex
                var certified = V2PlacementRaftApplication(groupID: groupID)
                try certified.apply(historical)
                guard try certified.checkpoint() == checkpoint.application else { throw V2PlacementRaftError.invalidState }
            }
            let replay = try decoded.replay()
            candidate = .init(groupID: groupID)
            candidate.genesis = decoded.genesis; candidate.snapshot = replay.snapshot
            candidate.bootstrapDigest = try decoded.rootDigest(); candidate.pinnedHistory = decoded.pinnedReceipts
            candidate.appliedIndex = state.baseIndex; candidate.prefixBase = state.baseIndex
            candidate.baseCheckpoint = checkpoint
            candidate.history = decoded.receipts
            candidate.archiveBytes = try V2PlacementArchiveCapacity.headerBytes(decoded.genesis)
            for record in decoded.receipts + decoded.pinnedReceipts {
                candidate.archiveBytes += try V2PlacementArchiveCapacity.recordBytes(record)
                candidate.receipts[.init(id: record.requestID, kind: record.command.logKind)] = .init(command: record.command, revision: record.revision, originRevision: record.originRevision)
            }
        } else {
            guard state.snapshot == baseCheckpoint else { throw V2PlacementRaftError.invalidState }
        }
        let overlap = appliedIndex > state.baseIndex ? Int(appliedIndex - state.baseIndex) : 0
        if overlap > 0 {
            let oldOffset = Int(state.baseIndex - prefixBase)
            guard state.log.prefix(overlap).elementsEqual(prefix.dropFirst(oldOffset).prefix(overlap)) else {
                throw V2PlacementRaftError.invalidState
            }
        }
        for index in candidate.appliedIndex..<state.commitIndex {
            guard let entry = state.entry(at: index + 1) else { throw V2PlacementRaftError.invalidState }
            if !entry.payload.isEmpty {
                let operation = try Self.decode(entry.payload)
                candidate.results[index + 1] = try candidate.execute(operation)
            }
            candidate.prefix.append(entry)
            candidate.appliedIndex = index + 1
            // Every replica prunes at the SAME committed absolute index, not
            // when its local file happens to compact. Otherwise CAS admission
            // could differ between leader and followers.
            if candidate.appliedIndex % 4096 == 0, candidate.genesis != nil {
                try candidate.rollArchive()
            }
        }
        self = candidate
    }
    private mutating func rollArchive() throws {
        guard let genesis else { return }
        let rolled = try V2PlacementRaftCheckpoint(groupID: groupID, appliedIndex: appliedIndex,
            genesis: genesis, receipts: history, bootstrapDigest: bootstrapDigest, pinnedReceipts: pinnedHistory).rolling()
        self.genesis = rolled.genesis; bootstrapDigest = try rolled.rootDigest()
        history = rolled.receipts; pinnedHistory = rolled.pinnedReceipts
        receipts.removeAll(keepingCapacity: true)
        archiveBytes = try V2PlacementArchiveCapacity.headerBytes(rolled.genesis)
        for record in rolled.receipts + rolled.pinnedReceipts {
            archiveBytes += try V2PlacementArchiveCapacity.recordBytes(record)
            receipts[.init(id: record.requestID, kind: record.command.logKind)] = .init(command: record.command,
                revision: record.revision, originRevision: record.originRevision)
        }
    }

    private mutating func execute(_ operation: Operation) throws -> StoredResult {
        switch operation {
        case .bootstrap(let initial):
            guard initial.clusterID == groupID, initial.revision == 1 else { throw V2PlacementRaftError.invalidState }
            if let genesis {
                guard initial == genesis, let snapshot else { return .failure(.conflictingSnapshot) }
                return .success(snapshot.revision)
            }
            let bytes = try V2PlacementArchiveCapacity.headerBytes(initial)
            try V2PlacementArchiveCapacity.usage(snapshot: initial, receipts: 0, bytes: bytes).requireCapacity()
            genesis = initial; snapshot = initial; archiveBytes = bytes
            return .success(initial.revision)
        case .command(let command, let expected, let requestID, let originRevision):
            guard expected.clusterID == groupID else { return .failure(.conflictingSnapshot) }
            do {
                guard originRevision > 0 else { throw V2ActorPlacementError.invalidConfiguration }
                if let prior = receipts[.init(id: requestID, kind: command.logKind)] {
                    guard prior.command == command, prior.originRevision == originRevision else { throw V2ActorPlacementError.invalidTransition }
                    return .success(prior.revision)
                }
                guard let current = snapshot, let genesis else { return .failure(.unavailable) }
                if originRevision < genesis.revision {
                    let admitted: Bool
                    switch command {
                    case .completeTransfer(let partition, let owner, let id), .cancelTransfer(let partition, let owner, let id):
                        admitted = current.slots.indices.contains(partition) && current.slots[partition].owner == owner
                            && current.slots[partition].transfer?.id == id
                            && receipts[.init(id: id, kind: 1)]?.originRevision == originRevision
                    default: admitted = false
                    }
                    guard admitted else { return .failure(.requestExpired) }
                }
                guard originRevision <= expected.revision else { return .failure(.invalidConfiguration) }
                guard expected == current else { return .failure(.staleRevision) }
                guard current.revision < UInt64.max else { return .failure(.epochExhausted) }
                var machine = V2ActorPlacementStateMachine(snapshot: current)
                try machine.apply(command, revision: current.revision + 1)
                let record = V2PlacementRaftCheckpoint.Record(requestID: requestID, command: command,
                    revision: machine.snapshot.revision, originRevision: originRevision)
                let nextBytes = archiveBytes + (try V2PlacementArchiveCapacity.recordBytes(record))
                try V2PlacementArchiveCapacity.usage(snapshot: machine.snapshot,
                    receipts: history.count + pinnedHistory.count + 1, bytes: nextBytes).requireCapacity()
                snapshot = machine.snapshot
                receipts[.init(id: requestID, kind: command.logKind)] = .init(command: command, revision: machine.snapshot.revision, originRevision: originRevision)
                history.append(record)
                archiveBytes = nextBytes
                return .success(machine.snapshot.revision)
            } catch let error as V2ActorPlacementError { return .failure(error) }
        }
    }
    package static func encode(_ operation: Operation) throws -> Data {
        var wire = Im_Actor_V1_PlacementRaftOperation()
        switch operation {
        case .bootstrap(let snapshot): wire.bootstrapSnapshot = try V2ActorPlacementProtobuf.encode(snapshot)
        case .command(let command, let expected, let requestID, let originRevision):
            wire.requestID = V2HotPB.bytes(requestID)
            wire.expectedSnapshot = try V2ActorPlacementProtobuf.encode(expected)
            wire.command = try V2ActorPlacementProtobuf.encode(command)
            guard originRevision > 0 else { throw V2PlacementRaftError.invalidMessage }
            wire.originRevision = originRevision
        }
        let bytes = try wire.serializedData()
        guard bytes.count <= V2PlacementRaftCore.maximumPayloadBytes else { throw V2PlacementRaftError.capacity }
        return bytes
    }
    package static func decode(_ bytes: Data) throws -> Operation {
        guard !bytes.isEmpty, bytes.count <= V2PlacementRaftCore.maximumPayloadBytes else { throw V2PlacementRaftError.invalidMessage }
        let wire = try Im_Actor_V1_PlacementRaftOperation(serializedBytes: bytes)
        try V2HotPB.check(wire)
        if !wire.bootstrapSnapshot.isEmpty {
            guard wire.requestID.isEmpty, wire.expectedSnapshot.isEmpty, wire.command.isEmpty, wire.originRevision == 0 else { throw V2PlacementRaftError.invalidMessage }
            return try .bootstrap(V2ActorPlacementProtobuf.decode(wire.bootstrapSnapshot))
        }
        guard !wire.expectedSnapshot.isEmpty, !wire.command.isEmpty, wire.originRevision > 0 else { throw V2PlacementRaftError.invalidMessage }
        return try .command(V2ActorPlacementProtobuf.decodeCommand(wire.command),
            expected: V2ActorPlacementProtobuf.decode(wire.expectedSnapshot), requestID: V2HotPB.uuid(wire.requestID), originRevision: wire.originRevision)
    }
}
