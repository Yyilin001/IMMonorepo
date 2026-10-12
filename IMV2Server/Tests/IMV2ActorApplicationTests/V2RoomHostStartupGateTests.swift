import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import NIOPosix
import Testing
@testable import IMV2ActorApplication

@Suite("Managed Host startup barrier")
struct V2RoomHostStartupGateTests {
    @Test("Actual handshake waits for matching durable inventory; wrong token and incarnation cannot release it")
    func durableBindingBeforeRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-host-startup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start()
        let hostID = try V2ActorHostID("host-a"), service = try V2ActorServiceID("gateway-a")
        let supervisor = try V2ActorServiceID("supervisor"), token = UUID()
        let host = V2ActorHostIdentity(hostID: hostID, incarnationID: UUID())
        let gate = try V2RoomHostStartupGate(directory: directory, host: host, serviceID: service,
            supervisorID: supervisor, launchToken: token)
        await #expect(throws: POSIXError.self) {
            try await V2RoomHostStartupGate.readHello(directory: directory, pool: pool)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("hello.pb.lock").path))
        let deadline = ContinuousClock.now + .seconds(5)
        let startup = Task { try await gate.wait(deadline: deadline) }
        var opened: [V2DockerRoomHostInventory] = []
        do {
            let hello: Data
            while true {
                guard ContinuousClock.now < deadline else { throw V2RoomHostRecoveryError.deadlineExceeded }
                do { hello = try await V2RoomHostStartupGate.readHello(directory: directory, pool: pool); break }
                catch let error as POSIXError where error.code == .ENOENT || error.code == .EWOULDBLOCK || error.code == .EAGAIN {
                    try await ContinuousClock().sleep(for: .milliseconds(10))
                }
            }
            let observed = try V2RoomHostStartupGate.inspectHello(hello, hostID: hostID, serviceID: service,
                supervisorID: supervisor, launchToken: token)
            #expect(try V2HotPB.uuid(observed.incarnationID) == host.incarnationID)
            #expect(throws: V2RoomHostStartupGateError.invalidHandshake) {
                try V2RoomHostStartupGate.inspectHello(hello, hostID: hostID, serviceID: service,
                    supervisorID: supervisor, launchToken: UUID())
            }
            let scope = V2DockerRoomHostInventory.Scope(supervisorID: supervisor, daemonID: "daemon-a",
                socketPath: "/private/docker.sock", hostIDs: [hostID])
            let wrong = try await V2DockerRoomHostInventory.provision(at: directory.appendingPathComponent("wrong.pb"),
                scope: scope, bindings: [.init(host: .init(hostID: hostID, incarnationID: UUID()),
                    containerID: String(repeating: "a", count: 64), startedAt: "2026-10-12T00:00:00.000000001Z")], pool: pool)
            opened.append(wrong)
            await #expect(throws: V2RoomHostStartupGateError.invalidHandshake) {
                try await V2RoomHostStartupGate.release(directory: directory, hello: hello, inventory: wrong, pool: pool)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("release.pb").path))
            let inventory = try await V2DockerRoomHostInventory.provision(at: directory.appendingPathComponent("launch.pb"),
                scope: scope, bindings: [.init(host: host, containerID: String(repeating: "b", count: 64),
                    startedAt: "2026-10-12T00:00:00.000000001Z")], pool: pool)
            opened.append(inventory)
            try await V2RoomHostStartupGate.release(directory: directory, hello: hello, inventory: inventory, pool: pool)
            try await startup.value
            // Same in-process configuration passes the barrier only once.
            try await gate.wait(deadline: .now + .seconds(1))
            try await V2RoomHostStartupGate.release(directory: directory, hello: hello, inventory: inventory, pool: pool)
            for inventory in opened { try await inventory.close() }; opened.removeAll()
            try await pool.shutdownGracefully(); try FileManager.default.removeItem(at: directory)
        } catch {
            startup.cancel(); _ = try? await startup.value
            for inventory in opened { try? await inventory.close() }
            try? await pool.shutdownGracefully(); try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
