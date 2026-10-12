import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix
import Testing
@testable import IMV2ActorApplication

@Suite("Supervisor generation retention")
struct V2RoomHostGenerationRetentionTests {
    private func fixture(_ directory: URL) throws -> (URL, V2RoomHostSupervisorDocument) {
        let path = directory.appendingPathComponent("supervisor.json")
        let launches = ["old", "new"].map { name in
            ["hostID": "host-a", "serviceID": "gateway-a", "gateDirectory": directory.appendingPathComponent(name + "-gate").path,
             "journalPath": directory.appendingPathComponent(name + "-launch.pb").path,
             "inventoryPath": directory.appendingPathComponent(name + "-inventory.pb").path]
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "actorConfigurationFile": directory.appendingPathComponent("actor.json").path,
            "shardIDs": ["room-a"], "daemonID": "daemon", "socketPath": "/private/docker.sock",
            "recoveryJournalPath": directory.appendingPathComponent("recovery.pb").path,
            "launches": launches, "retiredLaunches": [], "databases": ["owner": "private"],
            "shardDatabaseTargets": ["room-a": "owner"]])
        try bytes.write(to: path)
        return (path, try JSONDecoder().decode(V2RoomHostSupervisorDocument.self, from: bytes))
    }

    @Test("Restart resumes partial deletion without restoring a live launch")
    func partialDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-generation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start()
        var current: V2RoomHostSupervisorDocumentStore?
        do {
            let (path, document) = try fixture(directory), old = document.launches[0]
            let gate = URL(fileURLWithPath: old.gateDirectory)
            try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in [old.journalPath, old.inventoryPath, gate.appendingPathComponent("hello.pb").path,
                         gate.appendingPathComponent("release.pb").path] { try Data([1]).write(to: URL(fileURLWithPath: file)) }
            let binding = V2DockerRoomHostBinding(host: .init(hostID: try V2ActorHostID("host-a"), incarnationID: UUID()),
                containerID: String(repeating: "a", count: 64), startedAt: "2026-10-12T00:00:00Z")
            let retired = try V2RoomHostSupervisorDocument.Retired(launch: old, binding: binding)
            let store = try await V2RoomHostSupervisorDocumentStore.open(at: path.path, pool: pool); current = store
            try await store.enqueue(retired)
            try await store.enqueue(retired)
            #expect(try await store.load().launches == [document.launches[1]])
            var corrupted = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            var queue = try #require(corrupted["retiredLaunches"] as? [[String: Any]])
            queue[0]["containerID"] = String(repeating: "b", count: 64)
            corrupted["retiredLaunches"] = queue
            let corruptDocument = try JSONDecoder().decode(V2RoomHostSupervisorDocument.self,
                from: JSONSerialization.data(withJSONObject: corrupted))
            #expect(throws: V2DockerRoomHostLaunchError.invalidIntent) {
                try corruptDocument.validatePaths(configurationPath: path.path)
            }
            try await store.close(); current = nil
            // Crash after just one unlink, before removing the durable intent.
            try FileManager.default.removeItem(atPath: old.journalPath)
            let reopened = try await V2RoomHostSupervisorDocumentStore.open(at: path.path, pool: pool); current = reopened
            let pending = try #require(try await reopened.load().retiredLaunches.first)
            #expect(pending.operationID == retired.operationID && pending.incarnationID == binding.host.incarnationID)
            #expect(try await reopened.load().launches.count == 1)
            try await V2ActorDurableFileStorage.removeGeneration(journal: URL(fileURLWithPath: old.journalPath),
                inventory: URL(fileURLWithPath: old.inventoryPath), gate: gate, pool: pool)
            // Crash after deletion but before finish: exact deletion is idempotent.
            try await V2ActorDurableFileStorage.removeGeneration(journal: URL(fileURLWithPath: old.journalPath),
                inventory: URL(fileURLWithPath: old.inventoryPath), gate: gate, pool: pool)
            #expect(!FileManager.default.fileExists(atPath: old.inventoryPath))
            #expect(!FileManager.default.fileExists(atPath: gate.path))
            try await reopened.finish(operationID: pending.operationID)
            #expect(try await reopened.load().retiredLaunches.isEmpty)
            await #expect(throws: V2DockerRoomHostLaunchError.invalidIntent) {
                let newest = try V2RoomHostSupervisorDocument.Retired(launch: document.launches[1], binding: binding)
                try await reopened.enqueue(newest)
            }
            try await reopened.close(); current = nil
            try await pool.shutdownGracefully()
        } catch {
            try? await current?.close(); try? await pool.shutdownGracefully(); throw error
        }
    }

    @Test("Deleting a gate fails closed for unexpected files and live file owners")
    func guardedDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-generation-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start()
        var current: V2ActorDurableFileStorage?
        do {
            let (_, document) = try fixture(directory), old = document.launches[0]
            let gate = URL(fileURLWithPath: old.gateDirectory), journal = URL(fileURLWithPath: old.journalPath)
            try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let foreign = gate.appendingPathComponent("unowned")
            try Data([1]).write(to: foreign)
            await #expect(throws: V2PlacementRaftError.invalidState) {
                try await V2ActorDurableFileStorage.removeGeneration(journal: journal,
                    inventory: URL(fileURLWithPath: old.inventoryPath), gate: gate, pool: pool)
            }
            #expect(FileManager.default.fileExists(atPath: foreign.path))
            try FileManager.default.removeItem(at: foreign)
            let file = try await V2ActorDurableFileStorage.provision(at: journal, initial: Data([1]), maximumBytes: 8,
                pool: pool, validate: { _ in }); current = file
            await #expect(throws: POSIXError.self) {
                try await V2ActorDurableFileStorage.removeGeneration(journal: journal,
                    inventory: URL(fileURLWithPath: old.inventoryPath), gate: gate, pool: pool)
            }
            #expect(try await file.load() == Data([1]))
            try await file.close(); current = nil
            try await pool.shutdownGracefully()
        } catch {
            try? await current?.close(); try? await pool.shutdownGracefully(); throw error
        }
    }
}
