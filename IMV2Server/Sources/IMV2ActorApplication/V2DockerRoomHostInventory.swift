import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix

/// Immutable launch-generation inventory. A trusted launcher supplies bindings
/// from its own created containers and authenticated startup handshakes, before
/// releasing their startup gates. It never derives binding from quorum alone.
/// Replacing containers requires a new inventory generation, not overwriting
/// the old identity while a recovery operation can still need it.
package final class V2DockerRoomHostInventory: Sendable {
    private let file: V2ActorDurableFileStorage
    private let scope: Scope
    private static let maximumBytes = 256 * 1024
    package struct Scope: Sendable {
        package let supervisorID: V2ActorServiceID
        package let daemonID: String
        package let socketPath: String
        package let hostIDs: Set<V2ActorHostID>
    }
    private init(file: V2ActorDurableFileStorage, scope: Scope) { self.file = file; self.scope = scope }

    package static func provision(at path: URL, scope: Scope, bindings: [V2DockerRoomHostBinding],
                                  pool: NIOThreadPool) async throws -> V2DockerRoomHostInventory {
        var inventory = Im_Actor_V1_DockerRoomHostInventory()
        inventory.version = 1; inventory.supervisorID = scope.supervisorID.rawValue
        inventory.daemonID = scope.daemonID; inventory.socketPath = scope.socketPath
        inventory.hostIds = scope.hostIDs.map(\.rawValue).sorted()
        inventory.bindings = bindings.sorted { $0.host.hostID.rawValue < $1.host.hostID.rawValue }.map {
            var record = Im_Actor_V1_DockerRoomHostBinding()
            record.hostID = $0.host.hostID.rawValue; record.incarnationID = V2HotPB.bytes($0.host.incarnationID)
            record.containerID = $0.containerID; record.startedAt = $0.startedAt
            return record
        }
        let bytes = try inventory.serializedData()
        var envelope = Im_Actor_V1_DockerRoomHostInventoryFile()
        envelope.inventory = bytes; envelope.sha256 = Data(SHA256.hash(data: bytes))
        let file = try await V2ActorDurableFileStorage.provision(at: path, initial: envelope.serializedData(),
            maximumBytes: maximumBytes, pool: pool, validate: { _ = try decode($0, scope: scope) })
        return .init(file: file, scope: scope)
    }
    package static func open(at path: URL, scope: Scope, pool: NIOThreadPool) async throws -> V2DockerRoomHostInventory {
        let file = try await V2ActorDurableFileStorage.open(at: path, maximumBytes: maximumBytes,
            pool: pool, validate: { _ = try decode($0, scope: scope) })
        return .init(file: file, scope: scope)
    }
    package func bindings() async throws -> [V2DockerRoomHostBinding] {
        try Self.decode(await file.load(), scope: scope)
    }
    package func requireSupervisor(_ supervisor: V2ActorServiceID) throws {
        guard supervisor == scope.supervisorID else { throw V2DockerRoomHostExclusionError.invalidBinding }
    }
    package func close() async throws { try await file.close() }

    private static func decode(_ bytes: Data, scope: Scope) throws -> [V2DockerRoomHostBinding] {
        guard !bytes.isEmpty, bytes.count <= maximumBytes, !scope.hostIDs.isEmpty, scope.hostIDs.count <= 256,
              scope.socketPath.hasPrefix("/"), !scope.socketPath.contains("\0"), scope.socketPath.utf8.count <= 4096 else {
            throw V2DockerRoomHostExclusionError.invalidBinding
        }
        let envelope = try Im_Actor_V1_DockerRoomHostInventoryFile(serializedBytes: bytes)
        try V2HotPB.check(envelope)
        guard !envelope.inventory.isEmpty, envelope.sha256.count == 32,
              envelope.sha256 == Data(SHA256.hash(data: envelope.inventory)) else {
            throw V2DockerRoomHostExclusionError.invalidBinding
        }
        let inventory = try Im_Actor_V1_DockerRoomHostInventory(serializedBytes: envelope.inventory)
        try V2HotPB.check(inventory)
        guard inventory.version == 1, inventory.supervisorID == scope.supervisorID.rawValue,
              inventory.daemonID == scope.daemonID, inventory.socketPath == scope.socketPath,
              inventory.hostIds == scope.hostIDs.map(\.rawValue).sorted() else {
            throw V2DockerRoomHostExclusionError.invalidBinding
        }
        let bindings = try inventory.bindings.map { record in
            try V2HotPB.check(record)
            let hostID = try V2ActorHostID(record.hostID)
            guard hostID.rawValue == record.hostID else { throw V2DockerRoomHostExclusionError.invalidBinding }
            return V2DockerRoomHostBinding(host: .init(hostID: hostID, incarnationID: try V2HotPB.uuid(record.incarnationID)),
                containerID: record.containerID, startedAt: record.startedAt)
        }
        _ = try V2DockerRoomHostExclusionBackend.validateBindings(daemonID: scope.daemonID, bindings: bindings)
        // Exactly one created container per configured Host in this generation.
        guard bindings.count == scope.hostIDs.count, Set(bindings.map(\.host.hostID)) == scope.hostIDs else {
            throw V2DockerRoomHostExclusionError.invalidBinding
        }
        return bindings
    }
}
