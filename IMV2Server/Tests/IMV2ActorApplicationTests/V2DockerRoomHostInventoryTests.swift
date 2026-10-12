import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import NIOPosix
import Testing
@testable import IMV2ActorApplication

@Suite("Docker launch inventory on actual disk")
struct V2DockerRoomHostInventoryTests {
    @Test("Restart retains exact binding and refuses overwritten, mismatched or corrupt inventory")
    func inventoryRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-docker-inventory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("launch.pb")
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start()
        let hostID = try V2ActorHostID("host-a"), supervisor = try V2ActorServiceID("supervisor")
        let host = V2ActorHostIdentity(hostID: hostID, incarnationID: UUID())
        let scope = V2DockerRoomHostInventory.Scope(supervisorID: supervisor, daemonID: "owned-daemon",
            socketPath: "/private/owned/docker.sock", hostIDs: [hostID])
        let binding = V2DockerRoomHostBinding(host: host, containerID: String(repeating: "b", count: 64),
            startedAt: "2026-10-12T00:00:00.000000001Z")
        var current: V2DockerRoomHostInventory?
        do {
            let inventory = try await V2DockerRoomHostInventory.provision(at: path, scope: scope,
                bindings: [binding], pool: pool); current = inventory
            await #expect(throws: (any Error).self) {
                _ = try await V2DockerRoomHostInventory.open(at: path, scope: scope, pool: pool)
            }
            try await inventory.close(); current = nil
            await #expect(throws: (any Error).self) {
                _ = try await V2DockerRoomHostInventory.provision(at: path, scope: scope, bindings: [binding], pool: pool)
            }
            let other = V2DockerRoomHostInventory.Scope(supervisorID: supervisor, daemonID: "replacement",
                socketPath: scope.socketPath, hostIDs: [hostID])
            await #expect(throws: (any Error).self) {
                _ = try await V2DockerRoomHostInventory.open(at: path, scope: other, pool: pool)
            }
            let reopened = try await V2DockerRoomHostInventory.open(at: path, scope: scope, pool: pool); current = reopened
            let bindings = try await reopened.bindings()
            #expect(bindings.count == 1 && bindings[0].host == host)
            #expect(bindings[0].containerID == binding.containerID && bindings[0].startedAt == binding.startedAt)
            try await reopened.close(); current = nil
            var bytes = try Data(contentsOf: path); bytes[bytes.count - 1] ^= 1; try bytes.write(to: path)
            await #expect(throws: (any Error).self) {
                _ = try await V2DockerRoomHostInventory.open(at: path, scope: scope, pool: pool)
            }
            try FileManager.default.removeItem(at: path)
            await #expect(throws: (any Error).self) {
                _ = try await V2DockerRoomHostInventory.open(at: path, scope: scope, pool: pool)
            }
            #expect(!FileManager.default.fileExists(atPath: path.path))
            try await pool.shutdownGracefully(); try FileManager.default.removeItem(at: directory)
        } catch {
            try? await current?.close(); try? await pool.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
