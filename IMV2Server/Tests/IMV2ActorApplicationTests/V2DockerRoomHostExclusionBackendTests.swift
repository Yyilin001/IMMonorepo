import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorApplication

@Suite("Docker exclusion confirmation")
struct V2DockerRoomHostExclusionBackendTests {
    private actor Engine {
        let container: Data
        var daemon = "owned-daemon"
        var present = true
        var confirmDeletion = true
        var deletions = 0
        init(host: V2ActorHostIdentity, id: String, startedAt: String, restartCount: Int = 0) throws {
            container = try JSONSerialization.data(withJSONObject: [
                "Id": id, "RestartCount": restartCount,
                "State": ["Running": false, "Restarting": false, "StartedAt": startedAt],
                "HostConfig": ["RestartPolicy": ["Name": "no"], "Privileged": false, "PidMode": ""],
                "Config": ["Labels": ["com.imv2.actor.host-id": host.hostID.rawValue]]])
        }
        func setDaemon(_ value: String) { daemon = value }
        func retainAfterDelete() { confirmDeletion = false }
        func request(_ method: String, _ path: String) throws -> V2DockerRoomHostExclusionBackend.Response {
            if path == "/info" {
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["ID": daemon]))
            }
            if method == "DELETE" {
                deletions += 1
                if confirmDeletion { present = false }
                return .init(status: 204, body: Data())
            }
            return .init(status: present ? 200 : 404, body: present ? container : Data())
        }
    }

    @Test("Deletion response alone cannot certify exclusion; restart and daemon mismatch fail before mutation")
    func exactInstanceAndConfirmation() async throws {
        let host = V2ActorHostIdentity(hostID: try V2ActorHostID("host-a"), incarnationID: UUID())
        let id = String(repeating: "a", count: 64), started = "2026-10-12T00:00:00.000000001Z"
        let binding = V2DockerRoomHostBinding(host: host, containerID: id, startedAt: started)
        let engine = try Engine(host: host, id: id, startedAt: started)
        let backend = try V2DockerRoomHostExclusionBackend(daemonID: "owned-daemon", bindings: [binding],
            request: { method, path, _ in try await engine.request(method, path) })
        #expect(try await backend.failedHosts(among: [host], deadline: .now + .seconds(1)) == [host])
        let operation = UUID()
        try await backend.exclude(host: host, operationID: operation, deadline: .now + .seconds(1))
        try await backend.exclude(host: host, operationID: operation, deadline: .now + .seconds(1))
        #expect(await engine.deletions == 1)

        let retained = try Engine(host: host, id: id, startedAt: started)
        await retained.retainAfterDelete()
        let uncertain = try V2DockerRoomHostExclusionBackend(daemonID: "owned-daemon", bindings: [binding],
            request: { method, path, _ in try await retained.request(method, path) })
        await #expect(throws: V2DockerRoomHostExclusionError.deletionUnconfirmed) {
            try await uncertain.exclude(host: host, operationID: operation, deadline: .now + .seconds(1))
        }
        await retained.setDaemon("replacement-daemon")
        await #expect(throws: V2DockerRoomHostExclusionError.daemonChanged) {
            try await uncertain.exclude(host: host, operationID: operation, deadline: .now + .seconds(1))
        }
        #expect(await retained.deletions == 1)

        let restarted = try Engine(host: host, id: id, startedAt: started, restartCount: 1)
        let changed = try V2DockerRoomHostExclusionBackend(daemonID: "owned-daemon", bindings: [binding],
            request: { method, path, _ in try await restarted.request(method, path) })
        await #expect(throws: V2DockerRoomHostExclusionError.instanceChanged) {
            try await changed.exclude(host: host, operationID: operation, deadline: .now + .seconds(1))
        }
        #expect(await restarted.deletions == 0)
    }
}
