import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import NIOPosix
import Testing
@testable import IMV2ActorApplication

@Suite("Docker launch outcome reconciliation")
struct V2DockerRoomHostLauncherTests {
    private enum Failure: Error { case unknownCreate }
    private actor Engine {
        let scope: V2DockerRoomHostLaunchJournal.Scope
        let intent: V2DockerRoomHostLaunchJournal.Intent
        let gate: V2RoomHostStartupGate
        let id = String(repeating: "c", count: 64)
        var created = false, running = false
        var creates = 0, starts = 0
        var hostTask: Task<Void, any Error>?
        init(scope: V2DockerRoomHostLaunchJournal.Scope, intent: V2DockerRoomHostLaunchJournal.Intent, gate: V2RoomHostStartupGate) {
            self.scope = scope; self.intent = intent; self.gate = gate
        }
        func request(_ method: String, _ path: String, _ body: Data?) throws -> V2DockerRoomHostExclusionBackend.Response {
            if path == "/info" { return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["ID": scope.daemonID])) }
            if path.hasPrefix("/containers/create?") {
                #expect(body == intent.createRequest)
                creates += 1; created = true
                throw Failure.unknownCreate // Engine created it; its reply was lost.
            }
            if path.hasSuffix("/start") {
                starts += 1; running = true
                hostTask = Task { try await gate.wait(deadline: .now + .seconds(5)) }
                return .init(status: 204, body: Data())
            }
            if !created { return .init(status: 404, body: Data()) }
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: [
                "Id": id, "Name": "/" + intent.containerName, "RestartCount": 0,
                "State": ["Running": running, "Restarting": false, "Status": running ? "running" : "created",
                    "StartedAt": running ? "2026-10-12T00:00:00.000000001Z" : "0001-01-01T00:00:00Z"],
                "Config": ["Labels": ["com.imv2.actor.host-id": scope.hostID.rawValue,
                    "com.imv2.actor.launch-token": intent.token.uuidString.lowercased()]],
                "HostConfig": ["RestartPolicy": ["Name": "no"], "Privileged": false, "PidMode": "", "AutoRemove": false]
            ]))
        }
        func wait() async throws { try await hostTask?.value }
        func stop() async { hostTask?.cancel(); _ = try? await hostTask?.value }
    }

    @Test("Lost create reply resumes one owned container and durable handshake")
    func createReplyLost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-launch-reconcile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start()
        let scope = V2DockerRoomHostLaunchJournal.Scope(supervisorID: try V2ActorServiceID("supervisor"),
            daemonID: "owned-daemon", socketPath: "/private/docker.sock", hostID: try V2ActorHostID("host-a"),
            serviceID: try V2ActorServiceID("gateway-a"), gateDirectory: directory.path)
        var journal: V2DockerRoomHostLaunchJournal?, inventory: V2DockerRoomHostInventory?, engine: Engine?
        do {
            let opened = try await V2DockerRoomHostLaunchJournal.provision(at: directory.appendingPathComponent("launch.pb"),
                scope: scope, pool: pool) { token in
                try JSONSerialization.data(withJSONObject: [
                    "Image": "imv2@sha256:" + String(repeating: "a", count: 64),
                    "Env": ["IMV2_ROOM_ACTOR_STARTUP_GATE_DIRECTORY=/imv2-startup",
                        "IMV2_ROOM_ACTOR_STARTUP_GATE_TOKEN=" + token.uuidString.lowercased(),
                        "IMV2_ROOM_ACTOR_STARTUP_SUPERVISOR_ID=supervisor"],
                    "Labels": ["com.imv2.actor.host-id": scope.hostID.rawValue,
                        "com.imv2.actor.launch-token": token.uuidString.lowercased()],
                    "HostConfig": ["RestartPolicy": ["Name": "no"], "Privileged": false, "PidMode": "", "AutoRemove": false,
                        "Mounts": [["Type": "bind", "Source": scope.gateDirectory, "Target": "/imv2-startup", "ReadOnly": false]]]
                ], options: [.sortedKeys])
            }; journal = opened
            let intent = try await opened.intent()
            let host = V2ActorHostIdentity(hostID: scope.hostID, incarnationID: UUID())
            let gate = try V2RoomHostStartupGate(directory: directory, host: host,
                serviceID: scope.serviceID, supervisorID: scope.supervisorID, launchToken: intent.token)
            let fixture = Engine(scope: scope, intent: intent, gate: gate); engine = fixture
            let launcher = try V2DockerRoomHostLauncher(scope: scope, journal: opened, pool: pool,
                request: { method, path, body, _ in try await fixture.request(method, path, body) })
            let inventoryPath = directory.appendingPathComponent("inventory.pb")
            await #expect(throws: Failure.unknownCreate) {
                try await launcher.launch(inventoryPath: inventoryPath, deadline: .now + .seconds(5))
            }
            #expect(try await opened.intent().containerID == nil)
            let result = try await launcher.launch(inventoryPath: inventoryPath, deadline: .now + .seconds(5))
            inventory = result.inventory
            try await fixture.wait()
            #expect(result.binding.host == host)
            #expect(try await opened.intent().released)
            try await result.inventory.close(); inventory = nil
            let repeated = try await launcher.launch(inventoryPath: inventoryPath, deadline: .now + .seconds(5))
            inventory = repeated.inventory
            #expect(repeated.binding.host == host && repeated.binding.containerID == result.binding.containerID)
            #expect(await fixture.creates == 1)
            #expect(await fixture.starts == 1)
            try await repeated.inventory.close(); inventory = nil
            try await opened.close(); journal = nil
            try await pool.shutdownGracefully(); try FileManager.default.removeItem(at: directory)
        } catch {
            await engine?.stop(); try? await inventory?.close(); try? await journal?.close()
            try? await pool.shutdownGracefully(); try? FileManager.default.removeItem(at: directory); throw error
        }
    }
}
