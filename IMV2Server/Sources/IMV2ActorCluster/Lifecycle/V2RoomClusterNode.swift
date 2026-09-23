import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import NIOSSL

public struct V2RoomClusterNodeConfiguration: Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let tls: TLSConfiguration
    public let threadPoolSize: Int
    public let allowedShards: Set<String>
    public let serviceShardAccess: [V2ActorServiceID: Set<String>]

    /// TLS materials and a private trust root are required even when a local
    /// caller resolves the endpoint in its own ClusterSystem.
    public init(name: String, host: String, port: Int, tls: TLSConfiguration,
                threadPoolSize: Int, allowedShards: Set<String>,
                serviceShardAccess: [V2ActorServiceID: Set<String>]) throws {
        guard !name.isEmpty, !host.isEmpty, (1...65_535).contains(port),
              (1...64).contains(threadPoolSize), !allowedShards.isEmpty,
              !serviceShardAccess.isEmpty,
              tls.minimumTLSVersion == .tlsv13,
              tls.maximumTLSVersion == .tlsv13,
              tls.certificateVerification == .fullVerification,
              tls.trustRoots != nil,
              !tls.certificateChain.isEmpty, tls.privateKey != nil,
              serviceShardAccess.values.allSatisfy({ !$0.isEmpty && $0.isSubset(of: allowedShards) })
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.name = name
        self.host = host
        self.port = port
        self.tls = tls
        self.threadPoolSize = threadPoolSize
        self.allowedShards = allowedShards
        self.serviceShardAccess = serviceShardAccess
    }
}

/// Owns a ClusterSystem and its separately allocated transport threads. App
/// EventLoopGroups are never borrowed; shutdown waits for room drain first.
public actor V2RoomClusterNode {
    private let configuration: V2RoomClusterNodeConfiguration
    private let identity: V2ActorHostIdentity
    private let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let authenticationLimits: V2ActorAuthenticationLimits
    private let runtimeConfiguration: V2RoomRuntimeConfiguration
    private var system: ClusterSystem?
    private var inbound: V2RoomClusterInboundService?
    private var endpoint: V2RoomHostEndpoint?
    private var clients: [V2RoomClusterClient] = []

    public init(configuration: V2RoomClusterNodeConfiguration, identity: V2ActorHostIdentity,
                host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
                signer: V2ActorSigningIdentity, trust: V2ActorTrustStore,
                authenticationLimits: V2ActorAuthenticationLimits,
                runtimeConfiguration: V2RoomRuntimeConfiguration) {
        self.configuration = configuration
        self.identity = identity
        self.host = host
        self.signer = signer
        self.trust = trust
        self.authenticationLimits = authenticationLimits
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func start() async throws -> V2RoomClusterHostDescriptor {
        guard system == nil else { throw V2ActorAuthenticationError.invalidConfiguration }
        var settings = ClusterSystemSettings(name: configuration.name, host: configuration.host,
                                             port: configuration.port, tls: configuration.tls)
        settings.threadPoolSize = configuration.threadPoolSize
        // The distributed Codable serializer base64-encodes SignedPacket.body
        // again. Twice the signed-body ceiling leaves bounded room for that
        // expansion, ActorID/call metadata and protobuf framing.
        settings.maximumInboundFrameBytes = try ClusterInboundFrameLimit(
            bytes: max(authenticationLimits.maximumRequestBytes,
                       authenticationLimits.maximumReplyBytes) * 2 + 65_536
        )
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        let system = await ClusterSystem(configuration.name, settings: settings)
        self.system = system
        let auth = V2ActorSessionAuthenticator(host: identity, trust: trust,
                                                limits: authenticationLimits)
        let inbound = try V2RoomClusterInboundService(
            identity: identity, host: host, authenticator: auth, signer: signer,
            limits: authenticationLimits, allowedShards: configuration.allowedShards,
            serviceShardAccess: configuration.serviceShardAccess, actorSystem: system
        )
        self.inbound = inbound
        let endpoint = V2RoomHostEndpoint(actorSystem: system, service: inbound)
        self.endpoint = endpoint
        await host.start()
        await inbound.startWatching()
        return try V2RoomClusterHostDescriptor(
            identity: identity, endpointID: endpoint.id,
            address: configuration.host, port: configuration.port,
            accessibleShardIDs: configuration.allowedShards,
            availableRooms: runtimeConfiguration.maximumActiveRooms, isHealthy: true
        )
    }

    public func makeClient(signer: V2ActorSigningIdentity,
                           trust: V2ActorTrustStore,
                           limits: V2ActorAuthenticationLimits) throws -> V2RoomClusterClient {
        guard let system else { throw V2RoomCallFailure.notAccepted(.notReady) }
        let client = V2RoomClusterClient(system: system, signer: signer, trust: trust,
                                         limits: limits, configuration: runtimeConfiguration)
        clients.append(client)
        return client
    }

    public func readiness() async -> Bool {
        guard system != nil, inbound != nil, endpoint != nil else { return false }
        return await host.snapshot().accepting
    }

    public func drain(deadline: ContinuousClock.Instant) async -> V2RoomActivationDrainResult {
        await host.drain(deadline: deadline)
    }

    /// An incomplete drain leaves Cluster and DB access alive. The caller may
    /// retry stop after the executing SQL/restore has actually finished.
    public func stop(deadline: ContinuousClock.Instant) async throws -> V2RoomActivationDrainResult {
        let result = await host.drain(deadline: deadline)
        guard result.completed else { return result }
        guard await inbound?.quiesce(deadline: deadline) ?? true else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        for client in clients { await client.stop() }
        clients.removeAll()
        await inbound?.stop()
        inbound = nil
        endpoint = nil
        if let system { try await system.shutdown().wait() }
        system = nil
        return result
    }

    public func hostedActorCount() async -> Int { await inbound?.actorCount() ?? 0 }
}
