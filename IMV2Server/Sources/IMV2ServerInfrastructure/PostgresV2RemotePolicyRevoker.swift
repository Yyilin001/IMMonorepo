import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication

/// Server-owned route resolution. Discovery identifies transport hosts, while
/// the trust map and authenticated reply establish their response authority.
package struct PostgresV2RemotePolicyRevoker: Sendable {
    private let clientProvider: @Sendable () async throws -> V2RoomClusterClient
    private let resolve: @Sendable (String) async throws -> V2ActorHostIdentity
    private let timeout: Duration

    /// Production routing accepts only pinned stable hosts and physical aliases.
    /// Discovery supplies the current incarnation, never a replacement host.
    package init(client: V2RoomClusterClient, roomHosts: [UUID: Set<String>], timeout: Duration = .seconds(5)) {
        self.init(clientProvider: { client }, roomHosts: roomHosts, timeout: timeout)
    }

    package init(clientProvider: @escaping @Sendable () async throws -> V2RoomClusterClient,
        roomHosts: [UUID: Set<String>], timeout: Duration = .seconds(5)) {
        self.init(clientProvider: clientProvider, timeout: timeout, resolve: { endpoint in
            let locator = try V2RoomPolicyEndpointLocator(encoded: endpoint)
            guard roomHosts[locator.hostID]?.contains(locator.shardID) == true else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            let client = try await clientProvider()
            return try await client.resolvePolicyHost(hostID: .init(uuid: locator.hostID), endpoint: locator.shardID)
        })
    }

    package init(client: V2RoomClusterClient, timeout: Duration = .seconds(5),
        resolve: @escaping @Sendable (String) async throws -> V2ActorHostIdentity) {
        precondition(timeout > .zero && timeout <= .seconds(60))
        self.clientProvider = { client }; self.timeout = timeout; self.resolve = resolve
    }

    package init(clientProvider: @escaping @Sendable () async throws -> V2RoomClusterClient,
        timeout: Duration = .seconds(5), resolve: @escaping @Sendable (String) async throws -> V2ActorHostIdentity) {
        precondition(timeout > .zero && timeout <= .seconds(60))
        self.clientProvider = clientProvider; self.timeout = timeout; self.resolve = resolve
    }

    package func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        let deadline = ContinuousClock.now + timeout
        let client = try await clientProvider()
        let host = try await resolve(holder.endpoint)
        let target = try V2RoomPolicyRevocationWire(registrationID: holder.registrationID, roomID: .init(uuid: holder.roomID),
            activationID: holder.activationID, roomOwnerEpoch: holder.roomOwnerEpoch,
            generation: holder.generation, endpoint: holder.endpoint, validUntil: holder.validUntil)
        let verified = try await client.revokePolicyAuthorization(target, on: host, deadline: deadline)
        let proof = V2PolicyAuthorizationRevocationProof(verifiedRemote: verified)
        guard proof.holder == holder else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        return proof
    }
}
