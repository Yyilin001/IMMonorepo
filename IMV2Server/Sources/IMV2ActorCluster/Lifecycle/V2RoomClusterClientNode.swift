import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import NIOSSL

/// 调用方进程持有自己的 Cluster 传输。
/// 绝不构造虚假的房间宿主、租约存储或激活执行器。
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
    private var acceptingRealtime = true
    private var starting = false
    private var realtime: V2RealtimeTransportHandle?
    private var realtimeShards: V2RealtimeShardTransportHandle?
    private var system: ClusterSystem?
    private var client: V2RoomClusterClient?
    private var discovery: V2RoomClusterDiscovery?

    private let callerIncarnation: UUID

    public init(configuration: V2RoomClusterClientNodeConfiguration,
                signer: V2ActorSigningIdentity, trust: V2ActorTrustStore,
                authenticationLimits: V2ActorAuthenticationLimits,
                runtimeConfiguration: V2RoomRuntimeConfiguration, callerIncarnation: UUID = UUID()) {
        self.callerIncarnation = callerIncarnation
        self.configuration = configuration
        self.signer = signer
        self.trust = trust
        self.authenticationLimits = authenticationLimits
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func start(discovery discoveryConfiguration: V2RoomDiscoveryConfiguration? = nil) async throws -> V2RoomClusterClient {
        guard system == nil, !starting, acceptingRealtime else { throw V2ActorAuthenticationError.invalidConfiguration }
        starting = true
        defer { starting = false }
        var settings = ClusterSystemSettings(name: configuration.name,
                                             host: configuration.host, port: configuration.port,
                                             tls: configuration.tls)
        settings.threadPoolSize = configuration.threadPoolSize
        settings.serialization.binaryDistributedInvocations = true
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
        guard acceptingRealtime else {
            try await system.shutdown().wait()
            self.system = nil
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        let client = V2RoomClusterClient(system: system, signer: signer, trust: trust,
                                         limits: authenticationLimits,
                                         configuration: runtimeConfiguration, callerIncarnation: callerIncarnation)
        self.client = client
        if let discoveryConfiguration {
            let discovery = V2RoomClusterDiscovery(system: system, client: client,
                                                    trust: trust, configuration: discoveryConfiguration)
            self.discovery = discovery
            await discovery.start()
        }
        return client
    }

    /// 传输就绪与当前宿主数量是两个不同状态。
    /// 缺失的宿主继续不可用，不会因此获得写入权限。
    /// Owns one callback endpoint on the existing mTLS cluster, including caller-only nodes.
    public func makeRealtimeShardTransport(identity: V2GatewayRealtimeIdentity,
        serving: any V2RealtimeShardServing,
        serviceOwnerAccess: [V2ActorServiceID: Set<String>],
        discoveryPeers: [V2RealtimeShardDiscoveryPeer],
        limits: V2RealtimeTransportLimits = .init(),
        serviceQualification: V2ActorServiceQualification? = nil) async throws -> V2RealtimeShardTransportHandle {
        guard let system, realtimeShards == nil, acceptingRealtime else { throw V2ActorAuthenticationError.invalidConfiguration }
        let handle = try buildRealtimeShardTransport(system: system, identity: identity,
            address: configuration.host, port: configuration.port, signer: signer, trust: trust,
            serving: serving, serviceOwnerAccess: serviceOwnerAccess, discoveryPeers: discoveryPeers, limits: limits, serviceQualification: serviceQualification)
        realtimeShards = handle
        await handle.start()
        if !acceptingRealtime { _ = await handle.stop(deadline: .now + .seconds(2)); throw V2ActorAuthenticationError.overloaded }
        return handle
    }

    public func makeRealtimeTransport(identity: V2GatewayRealtimeIdentity,
                                      ingress: any V2RealtimeIngress,
                                      serviceOwnerAccess: [V2ActorServiceID: Set<String>],
                                      limits: V2RealtimeTransportLimits = .init()) throws -> V2RealtimeTransportHandle {
        guard let system, realtime == nil, acceptingRealtime else { throw V2ActorAuthenticationError.invalidConfiguration }
        let handle = try buildRealtimeTransport(system: system, identity: identity,
            address: configuration.host, port: configuration.port, signer: signer, trust: trust,
            ingress: ingress, serviceOwnerAccess: serviceOwnerAccess, limits: limits)
        realtime = handle
        return handle
    }

    public func readiness() async -> Bool {
        guard system != nil else { return false }
        guard let discovery else { return true }
        return await discovery.snapshot().completedPolls > 0
    }

    public func discoverySnapshot() async -> V2RoomDiscoverySnapshot? {
        await discovery?.snapshot()
    }

    /// 不配合取消的原生或远程 RPC 仍在运行时返回 false。
    /// 此节点继续持有 ClusterSystem，供之后重试停止操作。
    public func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        acceptingRealtime = false
        while starting && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        guard !starting else { return false }
        guard let system else { return true }
        guard await realtimeShards?.stop(deadline: deadline) ?? true else {
            throw V2ActorAuthenticationError.overloaded
        }
        guard await realtime?.stop(deadline: deadline) ?? true else { return false }
        await discovery?.stop()
        await client?.stop()
        guard await discovery?.quiesce(deadline: deadline) ?? true,
              await client?.quiesce(deadline: deadline) ?? true else { return false }
        realtime = nil
        realtimeShards = nil
        discovery = nil
        client = nil
        try await system.shutdown().wait()
        self.system = nil
        return true
    }
}
