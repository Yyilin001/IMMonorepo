import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix

/// The private deployment descriptor is also the durable deletion journal.
/// Moving a generation out of launches and into retiredLaunches is one atomic
/// replacement, so a restart cannot try to reopen an already deleted launch.
package struct V2RoomHostSupervisorDocument: Codable, Sendable, Equatable {
    package struct Launch: Codable, Sendable, Equatable {
        package let hostID: String
        package let serviceID: String
        package let gateDirectory: String
        package let journalPath: String
        package let inventoryPath: String
        package let createTemplatePath: String?
    }
    package struct Retired: Codable, Sendable, Equatable {
        package let launch: Launch
        package let incarnationID: UUID
        package let containerID: String
        package let startedAt: String
        package let operationID: UUID
        private var sha256: Data
        package init(launch: Launch, binding: V2DockerRoomHostBinding) throws {
            guard try V2ActorHostID(launch.hostID) == binding.host.hostID else {
                throw V2DockerRoomHostLaunchError.conflictingInstance
            }
            self.launch = launch; incarnationID = binding.host.incarnationID
            containerID = binding.containerID; startedAt = binding.startedAt; operationID = UUID()
            sha256 = Data()
            sha256 = Data(SHA256.hash(data: try content()))
        }
        package var binding: V2DockerRoomHostBinding {
            get throws {
                guard sha256.count == 32, sha256 == Data(SHA256.hash(data: try content())) else {
                    throw V2DockerRoomHostLaunchError.invalidIntent
                }
                return .init(host: .init(hostID: try V2ActorHostID(launch.hostID), incarnationID: incarnationID),
                    containerID: containerID, startedAt: startedAt)
            }
        }
        private func content() throws -> Data {
            var canonical = self; canonical.sha256 = Data()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(canonical)
        }
    }
    package let actorConfigurationFile: String
    package let shardIDs: [String]
    package let daemonID: String
    package let socketPath: String
    package let recoveryJournalPath: String
    package var launches: [Launch]
    // Required on the wire: no historical configuration compatibility mode.
    package var retiredLaunches: [Retired]
    package let databases: [String: String]
    package let shardDatabaseTargets: [String: String]

    package func validatePaths(configurationPath: String) throws {
        guard !launches.isEmpty, launches.count + retiredLaunches.count <= 256 else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
        let all = launches + retiredLaunches.map(\.launch)
        let files = [configurationPath, configurationPath + ".lock", actorConfigurationFile, recoveryJournalPath,
                     recoveryJournalPath + ".lock"] + all.flatMap {
            [$0.journalPath, $0.journalPath + ".lock", $0.inventoryPath, $0.inventoryPath + ".lock"]
        }
        let templates = all.compactMap(\.createTemplatePath)
        let gates = all.map(\.gateDirectory)
        let paths = files + templates + gates
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096
            && $0 != "/" && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 }),
              Set(files + gates).count == files.count + gates.count,
              Set(files + gates).isDisjoint(with: Set(templates)),
              gates.allSatisfy({ gate in
                  !(files + templates + gates.filter { $0 != gate }).contains { $0.hasPrefix(gate + "/") }
              }) else { throw V2DockerRoomHostLaunchError.invalidIntent }
        for item in retiredLaunches {
            _ = try V2ActorServiceID(item.launch.serviceID)
            _ = try V2DockerRoomHostExclusionBackend.validateBindings(daemonID: daemonID, bindings: [item.binding])
            // Keep a current generation of the same logical Host until deletion finishes.
            guard launches.contains(where: { $0.hostID == item.launch.hostID }) else {
                throw V2DockerRoomHostLaunchError.invalidIntent
            }
        }
    }
}

package final class V2RoomHostSupervisorDocumentStore: Sendable {
    private let file: V2ActorDurableFileStorage
    private let path: String
    private init(file: V2ActorDurableFileStorage, path: String) { self.file = file; self.path = path }
    package static func open(at path: String, pool: NIOThreadPool) async throws -> V2RoomHostSupervisorDocumentStore {
        let file = try await V2ActorDurableFileStorage.open(at: URL(fileURLWithPath: path),
            maximumBytes: 1_048_576, pool: pool, validate: { bytes in
                try JSONDecoder().decode(V2RoomHostSupervisorDocument.self, from: bytes).validatePaths(configurationPath: path)
            })
        return .init(file: file, path: path)
    }
    package func load() async throws -> V2RoomHostSupervisorDocument {
        try JSONDecoder().decode(V2RoomHostSupervisorDocument.self, from: await file.load())
    }
    package func enqueue(_ retired: V2RoomHostSupervisorDocument.Retired) async throws {
        try await file.update { [path] bytes in
            var document = try JSONDecoder().decode(V2RoomHostSupervisorDocument.self, from: bytes)
            if document.retiredLaunches.contains(where: { $0.operationID == retired.operationID }) { return (nil, ()) }
            guard let index = document.launches.firstIndex(of: retired.launch),
                  document.launches.dropFirst(index + 1).contains(where: { $0.hostID == retired.launch.hostID }) else {
                throw V2DockerRoomHostLaunchError.invalidIntent
            }
            document.launches.remove(at: index); document.retiredLaunches.append(retired)
            try document.validatePaths(configurationPath: path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (try encoder.encode(document), ())
        }
    }
    package func finish(operationID: UUID) async throws {
        try await file.update { [path] bytes in
            var document = try JSONDecoder().decode(V2RoomHostSupervisorDocument.self, from: bytes)
            guard document.retiredLaunches.contains(where: { $0.operationID == operationID }) else { return (nil, ()) }
            document.retiredLaunches.removeAll { $0.operationID == operationID }
            try document.validatePaths(configurationPath: path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (try encoder.encode(document), ())
        }
    }
    package func close() async throws { try await file.close() }
}
