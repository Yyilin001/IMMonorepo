import Foundation
import Crypto
import IMV2ActorContracts
import SwiftProtobuf

/// A rolling base plus recent exact results and bounded lifecycle proofs.
/// The original bootstrap digest survives every roll. Pruning happens at fixed
/// committed log indices; local file compaction cannot change admission.
package struct V2PlacementRaftCheckpoint: Sendable {
    package struct Record: Sendable {
        package let requestID: UUID
        package let command: V2ActorPlacementCommand
        package let revision: UInt64
        package let originRevision: UInt64
        package init(requestID: UUID, command: V2ActorPlacementCommand, revision: UInt64, originRevision: UInt64? = nil) {
            self.requestID = requestID; self.command = command; self.revision = revision
            self.originRevision = originRevision ?? (revision > 0 ? revision - 1 : 0)
        }
    }
    package let groupID: UUID
    package let appliedIndex: UInt64
    package let genesis: V2ActorPlacementSnapshot
    package let receipts: [Record]
    package let bootstrapDigest: Data?
    package let pinnedReceipts: [Record]
    package static let retainedReceipts = 2048
    package init(groupID: UUID, appliedIndex: UInt64, genesis: V2ActorPlacementSnapshot,
                 receipts: [Record], bootstrapDigest: Data? = nil, pinnedReceipts: [Record] = []) {
        self.groupID = groupID; self.appliedIndex = appliedIndex; self.genesis = genesis
        self.receipts = receipts; self.bootstrapDigest = bootstrapDigest; self.pinnedReceipts = pinnedReceipts
    }
    package func rootDigest() throws -> Data {
        if let bootstrapDigest {
            guard bootstrapDigest.count == 32 else { throw V2PlacementRaftError.invalidState }
            if genesis.revision == 1 {
                guard bootstrapDigest == Data(SHA256.hash(data: try V2ActorPlacementProtobuf.encode(genesis))) else {
                    throw V2PlacementRaftError.invalidState
                }
            }
            return bootstrapDigest
        }
        guard genesis.revision == 1 else { throw V2PlacementRaftError.invalidState }
        return Data(SHA256.hash(data: try V2ActorPlacementProtobuf.encode(genesis)))
    }

    /// Keep the last exact-result window plus only proofs still referenced by
    /// the current Host roster or partition lifecycle. No time-based deletion.
    package func rolling() throws -> Self {
        let current = try replay().snapshot
        let drop = max(0, receipts.count - Self.retainedReceipts)
        let base = try snapshot(at: genesis.revision + UInt64(drop))
        let pins = Self.referenced(pinnedReceipts + receipts, by: current)
            .filter { $0.revision <= base.revision }.sorted { $0.revision < $1.revision }
        return .init(groupID: groupID, appliedIndex: appliedIndex, genesis: base,
            receipts: Array(receipts.dropFirst(drop)), bootstrapDigest: try rootDigest(), pinnedReceipts: pins)
    }
    private static func referenced(_ records: [Record], by snapshot: V2ActorPlacementSnapshot) -> [Record] {
        var kept: [Record] = [], terminals: [Int: Record] = [:]
        for record in records {
            switch record.command {
            case .installServiceMembership(let membership):
                if snapshot.serviceMembership == membership { kept.append(record) }
            case .admitHost(let hostID):
                if snapshot.registration(for: hostID) == .reserved(hostID) { kept.append(record) }
            case .registerHost(_, let successor):
                if snapshot.registration(for: successor.hostID)?.host == successor { kept.append(record) }
            case .retireHost(let host):
                if snapshot.registration(for: host.hostID) == .init(host: host, retired: true) { kept.append(record) }
            case .beginTransfer(let partition, let expected, let transfer):
                if snapshot.slots.indices.contains(partition), snapshot.slots[partition].owner == expected,
                   snapshot.slots[partition].transfer == transfer { kept.append(record) }
            case .completeTransfer(let partition, let expected, _):
                if snapshot.slots.indices.contains(partition), expected.epoch < UInt64.max,
                   snapshot.slots[partition].owner.epoch == expected.epoch + 1,
                   terminals[partition].map({ $0.revision < record.revision }) ?? true { terminals[partition] = record }
            case .cancelTransfer(let partition, let expected, _):
                if snapshot.slots.indices.contains(partition), snapshot.slots[partition].owner == expected,
                   terminals[partition].map({ $0.revision < record.revision }) ?? true { terminals[partition] = record }
            }
        }
        kept.append(contentsOf: terminals.values)
        return kept
    }
    package static let maximumBytes = 16 * 1024 * 1024
    package static let maximumReceipts = 65_536
    package struct Replay: Sendable {
        package let snapshot: V2ActorPlacementSnapshot
    }
    private struct ReceiptKey: Hashable { let id: UUID; let kind: Int }

    /// Reconstruct only the requested historical result. The archive retains
    /// commands/revisions, never one full partition array per success.
    package func snapshot(at revision: UInt64) throws -> V2ActorPlacementSnapshot {
        guard revision >= genesis.revision, revision - genesis.revision <= UInt64(receipts.count) else {
            throw V2PlacementRaftError.invalidState
        }
        var machine = V2ActorPlacementStateMachine(snapshot: genesis)
        for record in receipts.prefix(Int(revision - genesis.revision)) {
            try machine.apply(record.command, revision: record.revision)
        }
        guard machine.snapshot.revision == revision else { throw V2PlacementRaftError.invalidState }
        return machine.snapshot
    }
    package func replay() throws -> Replay {
        guard genesis.clusterID == groupID, genesis.revision > 0, appliedIndex > 0,
              UInt64(receipts.count) < appliedIndex else {
            throw V2PlacementRaftError.invalidState
        }
        // Local archives can outgrow the bounded snapshot transport without
        // being corrupt. The voter keeps its durable suffix on capacity and
        // must not fail its election driver or discard successful receipts.
        guard receipts.count + pinnedReceipts.count <= Self.maximumReceipts else { throw V2PlacementRaftError.capacity }
        _ = try rootDigest()
        guard pinnedReceipts.count <= genesis.slots.count * 2 + genesis.hosts.count * 2 else {
            throw V2PlacementRaftError.invalidState
        }
        var machine = V2ActorPlacementStateMachine(snapshot: genesis)
        var keys = Set<ReceiptKey>()
        var lastPinnedRevision: UInt64 = 0
        for record in pinnedReceipts {
            guard record.revision > lastPinnedRevision, record.revision <= genesis.revision,
                  record.originRevision > 0, record.originRevision < record.revision,
                  keys.insert(.init(id: record.requestID, kind: record.command.logKind)).inserted else {
                throw V2PlacementRaftError.invalidState
            }
            lastPinnedRevision = record.revision
        }
        for record in receipts {
            guard keys.insert(.init(id: record.requestID, kind: record.command.logKind)).inserted,
                  record.originRevision > 0, record.originRevision < record.revision,
                  machine.snapshot.revision < UInt64.max, record.revision == machine.snapshot.revision + 1 else {
                throw V2PlacementRaftError.invalidState
            }
            try machine.apply(record.command, revision: record.revision)
        }
        guard machine.snapshot.revision <= appliedIndex else {
            throw V2PlacementRaftError.invalidState
        }
        return .init(snapshot: machine.snapshot)
    }
    package func encode() throws -> Data {
        _ = try replay()
        var wire = Im_Actor_V1_PlacementRaftApplicationCheckpoint()
        wire.groupID = V2HotPB.bytes(groupID); wire.appliedIndex = appliedIndex
        wire.genesisSnapshot = try V2ActorPlacementProtobuf.encode(genesis)
        wire.bootstrapDigest = try rootDigest()
        func encode(_ record: Record) throws -> Im_Actor_V1_PlacementRaftCheckpointReceipt {
            var value = Im_Actor_V1_PlacementRaftCheckpointReceipt()
            value.requestID = V2HotPB.bytes(record.requestID); value.command = try V2ActorPlacementProtobuf.encode(record.command)
            value.revision = record.revision; value.originRevision = record.originRevision
            return value
        }
        wire.receipts = try receipts.map(encode)
        wire.pinnedReceipts = try pinnedReceipts.map(encode)
        let bytes = try wire.serializedData()
        guard bytes.count <= Self.maximumBytes else { throw V2PlacementRaftError.capacity }
        return bytes
    }
    package static func decode(_ bytes: Data, groupID: UUID) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw V2PlacementRaftError.invalidMessage }
        let wire = try Im_Actor_V1_PlacementRaftApplicationCheckpoint(serializedBytes: bytes)
        try V2HotPB.check(wire, wire.receipts.count + wire.pinnedReceipts.count <= maximumReceipts && wire.bootstrapDigest.count == 32)
        guard try V2HotPB.uuid(wire.groupID) == groupID else { throw V2PlacementRaftError.wrongGroup }
        func record(_ wire: Im_Actor_V1_PlacementRaftCheckpointReceipt) throws -> Record {
            try V2HotPB.check(wire)
            return try .init(requestID: V2HotPB.uuid(wire.requestID),
                command: V2ActorPlacementProtobuf.decodeCommand(wire.command), revision: wire.revision,
                originRevision: wire.originRevision)
        }
        let value = try Self(groupID: groupID, appliedIndex: wire.appliedIndex,
            genesis: V2ActorPlacementProtobuf.decode(wire.genesisSnapshot), receipts: wire.receipts.map(record),
            bootstrapDigest: wire.bootstrapDigest, pinnedReceipts: wire.pinnedReceipts.map(record))
        _ = try value.replay()
        return value
    }
}
