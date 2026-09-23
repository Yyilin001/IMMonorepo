import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import NIOSSL

/// A calling process owns its own Cluster transport. It never constructs a
/// dummy room host, lease store, or activation executor.
public struct V2RoomClusterClientNodeConfiguration: Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let tls: TLSConfiguration
    public let threadPoolSize: Int

    public init(name: String, host: String, port: Int, tls: TLSConfiguration,
                threadPoolSize: Int) throws {
        guard !name.isEmpty, !host.isEmpty, (1...65_535).contains(port),
              (1...64).contains(threadPoolSize),
              tls.minimumTLSVersion == .tlsv13,
              tls.maximumTLSVersion == .tlsv13,
              tls.certificateVerification == .fullVerification,
              tls.trustRoots != nil,
              !tls.certificateChain.isEmpty, tls.privateKey != nil
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.name = name
        self.host = host
        self.port = port
        self.tls = tls
        self.threadPoolSize = threadPoolSize
    }
}

public actor V2RoomClusterClientNode {
    private let configuration: V2RoomClusterClientNodeConfiguration
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let authenticationLimits: V2ActorAuthenticationLimits
    private let runtimeConfiguration: V2RoomRuntimeConfiguration
    private var system: ClusterSystem?
    private var client: V2RoomClusterClient?
    private var discovery: V2RoomClusterDiscovery?

    public init(configuration: V2RoomClusterClientNodeConfiguration,
                signer: V2ActorSigningIdentity, trust: V2ActorTrustStore,
                authenticationLimits: V2ActorAuthenticationLimits,
                runtimeConfiguration: V2RoomRuntimeConfiguration) {
        self.configuration = configuration
        self.signer = signer
        self.trust = trust
        self.authenticationLimits = authenticationLimits
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func start(discovery discoveryConfiguration: V2RoomDiscoveryConfiguration) async throws -> V2RoomClusterClient {
        guard system == nil else { throw V2ActorAuthenticationError.invalidConfiguration }
        var settings = ClusterSystemSettings(name: configuration.name,
                                             host: configuration.host, port: configuration.port,
                                             tls: configuration.tls)
        settings.threadPoolSize = configuration.threadPoolSize
        settings.downingStrategy = .none
        settings.onDownAction = .none
        settings.maximumInboundFrameBytes = try ClusterInboundFrameLimit(
            bytes: max(authenticationLimits.maximumRequestBytes,
                       authenticationLimits.maximumReplyBytes) * 2 + 65_536
        )
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance =
            .custom(allowedTypes: [V2ActorAuthenticationError.self])
        let system = await ClusterSystem(configuration.name, settings: settings)
        self.system = system
        let client = V2RoomClusterClient(system: system, signer: signer, trust: trust,
                                         limits: authenticationLimits,
                                         configuration: runtimeConfiguration)
        self.client = client
        let discovery = V2RoomClusterDiscovery(system: system, client: client,
                                                trust: trust, configuration: discoveryConfiguration)
        self.discovery = discovery
        await discovery.start()
        return client
    }

    /// Transport readiness is distinct from the current number of hosts.
    /// Missing hosts remain unavailable without becoming write authority.
    public func readiness() async -> Bool {
        guard system != nil, let discovery else { return false }
        return await discovery.snapshot().completedPolls > 0
    }

    public func discoverySnapshot() async -> V2RoomDiscoverySnapshot? {
        await discovery?.snapshot()
    }

    /// Returns false while an uncooperative native/remote RPC is still live.
    /// The ClusterSystem remains owned by this node for a later stop retry.
    public func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        guard let system else { return true }
        await discovery?.stop()
        await client?.stop()
        guard await discovery?.quiesce(deadline: deadline) ?? true,
              await client?.quiesce(deadline: deadline) ?? true else { return false }
        discovery = nil
        client = nil
        try await system.shutdown().wait()
        self.system = nil
        return true
    }
}
