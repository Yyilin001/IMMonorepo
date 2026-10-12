import AsyncHTTPClient
import Foundation
import IMV2ActorContracts

/// Includes old launch generations needed by pending recovery, as well as the
/// current ones. A node-local supervisor observes only its own managed Hosts.
package struct V2DockerRoomHostDeploymentBackend: V2RoomHostExclusionBackend, V2RoomHostFailureObserver {
    private let backend: V2DockerRoomHostExclusionBackend
    private let managedHostIDs: Set<V2ActorHostID>
    package init(socketPath: String, daemonID: String, bindings: [V2DockerRoomHostBinding],
                 managedHostIDs: Set<V2ActorHostID>, client: HTTPClient) throws {
        guard !managedHostIDs.isEmpty, bindings.allSatisfy({ managedHostIDs.contains($0.host.hostID) }) else {
            throw V2DockerRoomHostExclusionError.invalidBinding
        }
        backend = try .init(socketPath: socketPath, daemonID: daemonID, bindings: bindings, client: client)
        self.managedHostIDs = managedHostIDs
    }
    package func failedHosts(among hosts: Set<V2ActorHostIdentity>, deadline: ContinuousClock.Instant)
        async throws -> Set<V2ActorHostIdentity> {
        try await backend.failedHosts(among: Set(hosts.filter { managedHostIDs.contains($0.hostID) }), deadline: deadline)
    }
    package func exclude(host: V2ActorHostIdentity, operationID: UUID, deadline: ContinuousClock.Instant) async throws {
        guard managedHostIDs.contains(host.hostID) else { throw V2DockerRoomHostExclusionError.invalidBinding }
        try await backend.exclude(host: host, operationID: operationID, deadline: deadline)
    }
}
