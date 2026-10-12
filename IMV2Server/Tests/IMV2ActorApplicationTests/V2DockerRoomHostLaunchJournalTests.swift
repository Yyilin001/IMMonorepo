import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import NIOPosix
import Testing
@testable import IMV2ActorApplication

@Suite("Durable Docker launch intent")
struct V2DockerRoomHostLaunchJournalTests {
    @Test("Creation and binding survive restart without changing token, request or container")
    func launchRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-launch-intent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start()
        let scope = V2DockerRoomHostLaunchJournal.Scope(supervisorID: try V2ActorServiceID("supervisor"),
            daemonID: "owned-daemon", socketPath: "/private/docker.sock", hostID: try V2ActorHostID("host-a"),
            serviceID: try V2ActorServiceID("gateway-a"), gateDirectory: directory.path)
        let path = directory.appendingPathComponent("intent.pb")
        var current: V2DockerRoomHostLaunchJournal?
        do {
            let journal = try await V2DockerRoomHostLaunchJournal.provision(at: path, scope: scope, pool: pool) { token in
                try JSONSerialization.data(withJSONObject: [
                    "Image": "imv2@sha256:" + String(repeating: "a", count: 64),
                    "Env": ["IMV2_ROOM_ACTOR_STARTUP_GATE_DIRECTORY=/imv2-startup",
                        "IMV2_ROOM_ACTOR_STARTUP_GATE_TOKEN=" + token.uuidString.lowercased(),
                        "IMV2_ROOM_ACTOR_STARTUP_SUPERVISOR_ID=supervisor"],
                    "Labels": ["com.imv2.actor.host-id": scope.hostID.rawValue,
                        "com.imv2.actor.launch-token": token.uuidString.lowercased()],
                    "HostConfig": ["RestartPolicy": ["Name": "no"], "Privileged": false, "PidMode": "",
                        "AutoRemove": false, "Mounts": [["Type": "bind", "Source": scope.gateDirectory,
                            "Target": "/imv2-startup", "ReadOnly": false]]]
                ], options: [.sortedKeys])
            }; current = journal
            let initial = try await journal.intent()
            #expect(initial.containerID == nil && initial.binding == nil && !initial.released)
            let id = String(repeating: "b", count: 64)
            try await journal.recordCreated(containerID: id)
            try await journal.recordCreated(containerID: id)
            await #expect(throws: V2DockerRoomHostLaunchError.conflictingInstance) {
                try await journal.recordCreated(containerID: String(repeating: "c", count: 64))
            }
            let binding = V2DockerRoomHostBinding(host: .init(hostID: scope.hostID, incarnationID: UUID()),
                containerID: id, startedAt: "2026-10-12T00:00:00.000000001Z")
            await #expect(throws: V2DockerRoomHostLaunchError.conflictingInstance) { try await journal.recordReleased(binding) }
            try await journal.recordBound(binding)
            try await journal.close(); current = nil
            let reopened = try await V2DockerRoomHostLaunchJournal.open(at: path, scope: scope, pool: pool); current = reopened
            let restored = try await reopened.intent()
            #expect(restored.token == initial.token && restored.createRequest == initial.createRequest)
            #expect(restored.containerName == initial.containerName && restored.binding?.host == binding.host && !restored.released)
            await #expect(throws: V2DockerRoomHostLaunchError.conflictingInstance) {
                try await reopened.recordBound(.init(host: .init(hostID: scope.hostID, incarnationID: UUID()),
                    containerID: id, startedAt: binding.startedAt))
            }
            try await reopened.recordReleased(binding)
            try await reopened.recordReleased(binding)
            try await reopened.close(); current = nil
            let final = try await V2DockerRoomHostLaunchJournal.open(at: path, scope: scope, pool: pool); current = final
            #expect(try await final.intent().released)
            #expect(try await final.intent().binding?.containerID == id)
            try await final.close(); current = nil
            var bytes = try Data(contentsOf: path); bytes[bytes.count - 1] ^= 1; try bytes.write(to: path)
            await #expect(throws: (any Error).self) {
                _ = try await V2DockerRoomHostLaunchJournal.open(at: path, scope: scope, pool: pool)
            }
            try FileManager.default.removeItem(at: path)
            await #expect(throws: (any Error).self) {
                _ = try await V2DockerRoomHostLaunchJournal.open(at: path, scope: scope, pool: pool)
            }
            try await pool.shutdownGracefully(); try FileManager.default.removeItem(at: directory)
        } catch {
            try? await current?.close(); try? await pool.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }
}
