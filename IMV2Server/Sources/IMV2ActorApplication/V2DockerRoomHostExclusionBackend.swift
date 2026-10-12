import AsyncHTTPClient
import Foundation
import IMV2ActorContracts

package enum V2DockerRoomHostExclusionError: Error {
    case invalidBinding, daemonChanged, instanceChanged, unavailable, deletionUnconfirmed
}

/// Trusted launch inventory must persist this binding before allowing the Host
/// to serve. Names, live quorum observations, or remote caller input cannot
/// establish the association between a process incarnation and a container.
package struct V2DockerRoomHostBinding: Sendable {
    package let host: V2ActorHostIdentity
    package let containerID: String
    package let startedAt: String
}

/// A managed, non-restarting Docker deployment. The launch owner must never
/// restart a bound container or relaunch an excluded incarnation. Removal of
/// the full immutable ID prevents that container being started again.
/// Engine API errors/timeouts never certify exclusion. SQL settlement follows
/// separately in V2RoomHostRecoveryCoordinator.
package struct V2DockerRoomHostExclusionBackend: V2RoomHostExclusionBackend, V2RoomHostFailureObserver {
    package struct Response: Sendable {
        package let status: Int
        package let body: Data
    }
    private let daemonID: String
    private let bindings: [V2ActorHostIdentity: V2DockerRoomHostBinding]
    private let request: @Sendable (String, String, ContinuousClock.Instant) async throws -> Response

    /// The caller owns HTTPClient and shuts it down only after monitor drain.
    package init(socketPath: String, daemonID: String, bindings: [V2DockerRoomHostBinding],
                 client: HTTPClient) throws {
        let engine = try V2DockerEngineConnection(socketPath: socketPath, client: client)
        try self.init(daemonID: daemonID, bindings: bindings, request: { method, path, deadline in
            try await engine.request(method, path, deadline: deadline)
        })
    }

    /// Package-only I/O seam; production uses the Unix-socket adapter above.
    package init(daemonID: String, bindings: [V2DockerRoomHostBinding],
                 request: @escaping @Sendable (String, String, ContinuousClock.Instant) async throws -> Response) throws {
        self.bindings = try Self.validateBindings(daemonID: daemonID, bindings: bindings)
        self.daemonID = daemonID; self.request = request
    }

    package static func validateBindings(daemonID: String, bindings: [V2DockerRoomHostBinding]) throws
        -> [V2ActorHostIdentity: V2DockerRoomHostBinding] {
        guard !daemonID.isEmpty, daemonID.utf8.count <= 256, !bindings.isEmpty, bindings.count <= 256 else {
            throw V2DockerRoomHostExclusionError.invalidBinding
        }
        var inventory: [V2ActorHostIdentity: V2DockerRoomHostBinding] = [:]
        var containers = Set<String>()
        var incarnations = Set<UUID>()
        for binding in bindings {
            guard binding.containerID.utf8.count == 64,
                  binding.containerID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !binding.startedAt.isEmpty, !binding.startedAt.hasPrefix("0001-"),
                  inventory.updateValue(binding, forKey: binding.host) == nil,
                  incarnations.insert(binding.host.incarnationID).inserted,
                  containers.insert(binding.containerID).inserted else {
                throw V2DockerRoomHostExclusionError.invalidBinding
            }
        }
        return inventory
    }

    package func failedHosts(among hosts: Set<V2ActorHostIdentity>, deadline: ContinuousClock.Instant)
        async throws -> Set<V2ActorHostIdentity> {
        try await checkDaemon(deadline)
        var failed = Set<V2ActorHostIdentity>()
        for host in hosts.sorted(by: { $0.hostID.rawValue < $1.hostID.rawValue }) {
            guard let binding = bindings[host] else { throw V2DockerRoomHostExclusionError.invalidBinding }
            if let state = try await inspect(binding, deadline: deadline) {
                if !state.State.Running { failed.insert(host) }
            } else { failed.insert(host) }
        }
        return failed
    }

    package func exclude(host: V2ActorHostIdentity, operationID: UUID, deadline: ContinuousClock.Instant) async throws {
        guard let binding = bindings[host] else { throw V2DockerRoomHostExclusionError.invalidBinding }
        try await checkDaemon(deadline)
        if try await inspect(binding, deadline: deadline) != nil {
            // DELETE is idempotent by immutable ID, not by a reusable name.
            let response = try await send("DELETE", "/containers/" + binding.containerID + "?force=true", deadline)
            guard response.status == 204 || response.status == 404 else {
                throw V2DockerRoomHostExclusionError.unavailable
            }
        }
        try await checkDaemon(deadline)
        guard try await inspect(binding, deadline: deadline) == nil else {
            throw V2DockerRoomHostExclusionError.deletionUnconfirmed
        }
    }

    private func send(_ method: String, _ path: String, _ deadline: ContinuousClock.Instant) async throws -> Response {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomHostRecoveryError.deadlineExceeded }
        let response = try await request(method, path, deadline)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomHostRecoveryError.deadlineExceeded }
        return response
    }
    private struct Daemon: Decodable { let ID: String }
    private struct Container: Decodable {
        let Id: String
        let RestartCount: Int
        let State: StateValue
        let HostConfig: HostConfiguration
        let Config: Configuration
        struct StateValue: Decodable { let Running: Bool; let Restarting: Bool; let StartedAt: String }
        struct HostConfiguration: Decodable { let RestartPolicy: Restart; let Privileged: Bool; let PidMode: String }
        struct Restart: Decodable { let Name: String }
        struct Configuration: Decodable { let Labels: [String: String] }
    }
    private func checkDaemon(_ deadline: ContinuousClock.Instant) async throws {
        let response = try await send("GET", "/info", deadline)
        guard response.status == 200 else { throw V2DockerRoomHostExclusionError.unavailable }
        guard try JSONDecoder().decode(Daemon.self, from: response.body).ID == daemonID else {
            throw V2DockerRoomHostExclusionError.daemonChanged
        }
    }
    private func inspect(_ binding: V2DockerRoomHostBinding, deadline: ContinuousClock.Instant) async throws -> Container? {
        let response = try await send("GET", "/containers/" + binding.containerID + "/json", deadline)
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw V2DockerRoomHostExclusionError.unavailable }
        let container = try JSONDecoder().decode(Container.self, from: response.body)
        guard container.Id == binding.containerID, container.RestartCount == 0,
              container.State.StartedAt == binding.startedAt, !container.State.Restarting,
              container.HostConfig.RestartPolicy.Name == "no", !container.HostConfig.Privileged,
              container.HostConfig.PidMode != "host",
              container.Config.Labels["com.imv2.actor.host-id"] == binding.host.hostID.rawValue else {
            throw V2DockerRoomHostExclusionError.instanceChanged
        }
        return container
    }
}
