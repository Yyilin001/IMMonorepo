import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix
import SwiftProtobuf

package enum V2RoomHostRecoveryJournalError: Error, Equatable {
    case invalidState, conflictingOperation, pendingIncarnation
}

/// Stable recovery intent across retries/restarts. This file never certifies
/// exclusion: every retry still invokes the trusted backend and SQL settlement.
/// A deployment supplies the exact current incarnation from quorum state.
package final class V2RoomHostRecoveryJournal: Sendable {
    private let file: V2ActorDurableFileStorage
    private let supervisorID: V2ActorServiceID
    private let hostIDs: Set<V2ActorHostID>
    private static let maximumBytes = 128 * 1024
    private static let maximumHosts = 256

    private init(file: V2ActorDurableFileStorage, supervisorID: V2ActorServiceID, hostIDs: Set<V2ActorHostID>) {
        self.file = file; self.supervisorID = supervisorID; self.hostIDs = hostIDs
    }
    package static func provision(at path: URL, supervisorID: V2ActorServiceID,
                                  hostIDs: Set<V2ActorHostID>, pool: NIOThreadPool) async throws -> V2RoomHostRecoveryJournal {
        guard !hostIDs.isEmpty, hostIDs.count <= maximumHosts else { throw V2RoomHostRecoveryJournalError.invalidState }
        var journal = Im_Actor_V1_RoomHostRecoveryJournal()
        journal.version = 1; journal.supervisorID = supervisorID.rawValue
        journal.hostIds = hostIDs.map(\.rawValue).sorted()
        let file = try await V2ActorDurableFileStorage.provision(at: path, initial: encode(journal),
            maximumBytes: maximumBytes, pool: pool,
            validate: { _ = try decode($0, supervisorID: supervisorID, hostIDs: hostIDs) })
        return .init(file: file, supervisorID: supervisorID, hostIDs: hostIDs)
    }
    package static func open(at path: URL, supervisorID: V2ActorServiceID,
                             hostIDs: Set<V2ActorHostID>, pool: NIOThreadPool) async throws -> V2RoomHostRecoveryJournal {
        let file = try await V2ActorDurableFileStorage.open(at: path, maximumBytes: maximumBytes, pool: pool,
            validate: { _ = try decode($0, supervisorID: supervisorID, hostIDs: hostIDs) })
        return .init(file: file, supervisorID: supervisorID, hostIDs: hostIDs)
    }
    package func existingOperation(for host: V2ActorHostIdentity) async throws -> UUID? {
        try await file.update { [supervisorID, hostIDs] bytes in
            guard hostIDs.contains(host.hostID) else { throw V2RoomHostRecoveryJournalError.invalidState }
            let journal = try Self.decode(bytes, supervisorID: supervisorID, hostIDs: hostIDs)
            guard let record = journal.operations.first(where: { $0.hostID == host.hostID.rawValue }),
                  try V2HotPB.uuid(record.incarnationID) == host.incarnationID else { return (nil, nil) }
            return (nil, try V2HotPB.uuid(record.operationID))
        }
    }
    /// Restart recovery uses durable intent, never the latest registration as
    /// a substitute for the incarnation whose exclusion was started.
    package func pendingHosts() async throws -> [V2ActorHostIdentity] {
        try await file.update { [supervisorID, hostIDs] bytes in
            let journal = try Self.decode(bytes, supervisorID: supervisorID, hostIDs: hostIDs)
            let hosts = try journal.operations.filter { !$0.completed }.sorted { $0.hostID < $1.hostID }.map {
                V2ActorHostIdentity(hostID: try V2ActorHostID($0.hostID),
                    incarnationID: try V2HotPB.uuid($0.incarnationID))
            }
            return (nil, hosts)
        }
    }
    package func operation(for host: V2ActorHostIdentity) async throws -> UUID {
        try await file.update { [supervisorID, hostIDs] bytes in
            guard hostIDs.contains(host.hostID) else { throw V2RoomHostRecoveryJournalError.invalidState }
            var journal = try Self.decode(bytes, supervisorID: supervisorID, hostIDs: hostIDs)
            let key = host.hostID.rawValue
            let index = journal.operations.firstIndex { $0.hostID == key }
            if let index {
                let prior = journal.operations[index]
                if try V2HotPB.uuid(prior.incarnationID) == host.incarnationID {
                    return (nil, try V2HotPB.uuid(prior.operationID))
                }
                guard prior.completed else { throw V2RoomHostRecoveryJournalError.pendingIncarnation }
            }
            var record = Im_Actor_V1_RoomHostRecoveryOperation()
            let id = UUID()
            record.hostID = key; record.incarnationID = V2HotPB.bytes(host.incarnationID); record.operationID = V2HotPB.bytes(id)
            if let index { journal.operations[index] = record } else { journal.operations.append(record) }
            return (try Self.encode(journal), id)
        }
    }
    package func complete(host: V2ActorHostIdentity, operationID: UUID) async throws {
        try await file.update { [supervisorID, hostIDs] bytes in
            var journal = try Self.decode(bytes, supervisorID: supervisorID, hostIDs: hostIDs)
            let key = host.hostID.rawValue
            guard let index = journal.operations.firstIndex(where: { $0.hostID == key }),
                  try V2HotPB.uuid(journal.operations[index].incarnationID) == host.incarnationID,
                  try V2HotPB.uuid(journal.operations[index].operationID) == operationID else {
                throw V2RoomHostRecoveryJournalError.conflictingOperation
            }
            if journal.operations[index].completed { return (nil, ()) }
            journal.operations[index].completed = true
            return (try Self.encode(journal), ())
        }
    }
    package func close() async throws { try await file.close() }

    package func requireScope(supervisorID: V2ActorServiceID, hostIDs: Set<V2ActorHostID>) throws {
        guard supervisorID == self.supervisorID, hostIDs == self.hostIDs else {
            throw V2RoomHostRecoveryJournalError.invalidState
        }
    }

    private static func encode(_ journal: Im_Actor_V1_RoomHostRecoveryJournal) throws -> Data {
        let bytes = try journal.serializedData()
        var file = Im_Actor_V1_RoomHostRecoveryJournalFile()
        file.journal = bytes; file.sha256 = Data(SHA256.hash(data: bytes))
        let encoded = try file.serializedData()
        guard encoded.count <= maximumBytes else { throw V2RoomHostRecoveryJournalError.invalidState }
        return encoded
    }
    private static func decode(_ bytes: Data, supervisorID: V2ActorServiceID,
                               hostIDs: Set<V2ActorHostID>) throws -> Im_Actor_V1_RoomHostRecoveryJournal {
        guard !bytes.isEmpty, bytes.count <= maximumBytes, !hostIDs.isEmpty, hostIDs.count <= maximumHosts else {
            throw V2RoomHostRecoveryJournalError.invalidState
        }
        let file = try Im_Actor_V1_RoomHostRecoveryJournalFile(serializedBytes: bytes)
        try V2HotPB.check(file)
        guard !file.journal.isEmpty, file.sha256.count == 32, file.sha256 == Data(SHA256.hash(data: file.journal)) else {
            throw V2RoomHostRecoveryJournalError.invalidState
        }
        let journal = try Im_Actor_V1_RoomHostRecoveryJournal(serializedBytes: file.journal)
        try V2HotPB.check(journal)
        guard journal.version == 1, journal.supervisorID == supervisorID.rawValue,
              journal.hostIds == hostIDs.map(\.rawValue).sorted(), journal.operations.count <= hostIDs.count else {
            throw V2RoomHostRecoveryJournalError.invalidState
        }
        var seen = Set<V2ActorHostID>(), operations = Set<UUID>()
        for record in journal.operations {
            try V2HotPB.check(record)
            let host = try V2ActorHostID(record.hostID)
            guard record.hostID == host.rawValue, hostIDs.contains(host), seen.insert(host).inserted,
                  operations.insert(try V2HotPB.uuid(record.operationID)).inserted else {
                throw V2RoomHostRecoveryJournalError.invalidState
            }
            _ = try V2HotPB.uuid(record.incarnationID)
        }
        return journal
    }
}
