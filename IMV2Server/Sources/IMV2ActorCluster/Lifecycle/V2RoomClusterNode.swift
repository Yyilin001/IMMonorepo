import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import NIOSSL

/// 只由拥有此精确入站 Actor 和物理端点的节点创建。
/// 接待组件匹配或共享 ClusterSystem 都不构成权限。
struct V2RoomLocalPort: Sendable {
    let identity: V2ActorHostIdentity
    let endpointID: ClusterSystem.ActorID
    let generation: UUID
    let inbound: V2RoomClusterInboundService

    fileprivate init(identity: V2ActorHostIdentity, endpointID: ClusterSystem.ActorID,
                     generation: UUID, inbound: V2RoomClusterInboundService) {
        self.identity = identity
        self.endpointID = endpointID
        self.generation = generation
        self.inbound = inbound
    }
}

public struct V2RoomClusterNodeConfiguration: Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let tls: TLSConfiguration
    public let threadPoolSize: Int
    public let allowedShards: Set<String>
    public let serviceShardAccess: [V2ActorServiceID: Set<String>]

    /// 即使本地调用方在自己的 ClusterSystem 中解析端点，
    /// 仍须提供 TLS 材料和私有信任根。
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

/// 持有 ClusterSystem 及其单独分配的传输线程。
/// 绝不借用应用的 EventLoopGroup；关闭时先等待房间排空。
public actor V2RoomClusterNode {
    private let configuration: V2RoomClusterNodeConfiguration
    private let identity: V2ActorHostIdentity
    private let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    private let signer: V2ActorSigningIdentity
    private let trust: V2ActorTrustStore
    private let authenticationLimits: V2ActorAuthenticationLimits
    private let runtimeConfiguration: V2RoomRuntimeConfiguration
    private var starting = false
    private var realtime: V2RealtimeTransportHandle?
    private var realtimeShards: V2RealtimeShardTransportHandle?
    private var system: ClusterSystem?
    private var inbound: V2RoomClusterInboundService?
    private var endpoint: V2RoomHostEndpoint?
    private var discoveryBeacon: V2RoomDiscoveryBeacon?
    private var discoveryPublisherState: V2RoomDiscoveryPublisherState?
    private var discoveries: [V2RoomClusterDiscovery] = []
    private var discoveryClientIDs: Set<ObjectIdentifier> = []
    private var acceptingDiscoveries = true
    private var clients: [V2RoomClusterClient] = []
    private var localGeneration: UUID?
    private let policyRevocations: (any V2RoomPolicyRevocationServing)?
    private let policyMutations: (any V2PolicyMutationServing)?
    private let policyOwnership: (any V2PolicyOwnershipServing)?
    private let forwardPairs: (any V2RoomForwardPairServing)?

    public init(configuration: V2RoomClusterNodeConfiguration, identity: V2ActorHostIdentity,
                host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
                signer: V2ActorSigningIdentity, trust: V2ActorTrustStore,
                authenticationLimits: V2ActorAuthenticationLimits,
                runtimeConfiguration: V2RoomRuntimeConfiguration,
                policyRevocations: (any V2RoomPolicyRevocationServing)? = nil,
                policyOwnership: (any V2PolicyOwnershipServing)? = nil,
                policyMutations: (any V2PolicyMutationServing)? = nil,
                forwardPairs: (any V2RoomForwardPairServing)? = nil) {
        self.configuration = configuration
        self.identity = identity
        self.host = host
        self.signer = signer
        self.trust = trust
        self.authenticationLimits = authenticationLimits
        self.runtimeConfiguration = runtimeConfiguration
        self.policyRevocations = policyRevocations
        self.policyOwnership = policyOwnership
        self.policyMutations = policyMutations
        self.forwardPairs = forwardPairs
    }

    public func start() async throws -> V2RoomClusterHostDescriptor {
        guard system == nil, !starting, acceptingDiscoveries else { throw V2ActorAuthenticationError.invalidConfiguration }
        starting = true
        defer { starting = false }
        var settings = ClusterSystemSettings(name: configuration.name, host: configuration.host,
                                             port: configuration.port, tls: configuration.tls)
        settings.threadPoolSize = configuration.threadPoolSize
        settings.serialization.binaryDistributedInvocations =
            ProcessInfo.processInfo.environment["IM_V2_ACTOR_BINARY_INVOCATIONS_ENABLED"] == "true"
        // 集群成员关系只用于发现。对等节点超时不能让本进程
        // 放弃或认领受数据库围栏保护的房间激活。
        settings.downingStrategy = .none
        settings.onDownAction = .none
        // 分布式 Codable 序列化器会再次对 SignedPacket.body 进行 base64 编码。
        // 将签名消息体上限翻倍，可为这次膨胀、ActorID、调用元数据
        // 和 protobuf 分帧留出有界空间。
        settings.maximumInboundFrameBytes = try ClusterInboundFrameLimit(
            bytes: max(authenticationLimits.maximumRequestBytes,
                       authenticationLimits.maximumReplyBytes) * 2 + 65_536
        )
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        let system = await ClusterSystem(configuration.name, settings: settings)
        self.system = system
        guard acceptingDiscoveries else {
            try await system.shutdown().wait()
            self.system = nil
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        let auth = V2ActorSessionAuthenticator(host: identity, trust: trust,
                                                limits: authenticationLimits)
        let generation = UUID()
        let inbound = try V2RoomClusterInboundService(
            identity: identity, host: host, authenticator: auth, signer: signer,
            limits: authenticationLimits, allowedShards: configuration.allowedShards,
            serviceShardAccess: configuration.serviceShardAccess,
            maximumInboundRequests: runtimeConfiguration.maximumActivationWaitersPerHost,
            localGeneration: generation,
            actorSystem: system, policyRevocations: policyRevocations, policyOwnership: policyOwnership, policyMutations: policyMutations,
            forwardPairs: forwardPairs
        )
        self.inbound = inbound
        self.localGeneration = generation
        let endpoint = V2RoomHostEndpoint(actorSystem: system, service: inbound)
        self.endpoint = endpoint
        await host.start()
        await inbound.startWatching()
        let descriptor = try V2RoomClusterHostDescriptor(
            identity: identity, endpointID: endpoint.id,
            address: configuration.host, port: configuration.port,
            accessibleShardIDs: configuration.allowedShards,
            availableRooms: runtimeConfiguration.maximumActiveRooms, isHealthy: true
        )
        let publisherState = V2RoomDiscoveryPublisherState()
        discoveryPublisherState = publisherState
        let beacon = V2RoomDiscoveryBeacon(actorSystem: system, descriptor: descriptor,
                                            signer: signer, state: publisherState)
        discoveryBeacon = beacon
        await system.receptionist.checkIn(beacon, with: V2RoomDiscoveryBeacon.key(for: identity.hostID))
        return descriptor
    }

    public func makeClient(signer: V2ActorSigningIdentity,
                           trust: V2ActorTrustStore,
                           limits: V2ActorAuthenticationLimits) throws -> V2RoomClusterClient {
        guard let system, let inbound, let endpoint, let generation = localGeneration,
              acceptingDiscoveries else {
            throw V2RoomCallFailure.notAccepted(.notReady)
        }
        guard clients.count < 64 else { throw V2RoomCallFailure.notAccepted(.overloaded) }
        let client = V2RoomClusterClient(system: system, signer: signer, trust: trust,
                                         limits: limits, configuration: runtimeConfiguration,
                                         localPort: .init(identity: identity, endpointID: endpoint.id,
                                                          generation: generation, inbound: inbound))
        clients.append(client)
        return client
    }

    /// 为配置的物理宿主启动有界且经签名的观察器。
    /// 调用方传入此节点创建的客户端，并将逻辑 RoomDirectory
    /// 与发现状态分开保留。
    public func startDiscovery(client: V2RoomClusterClient,
                               configuration: V2RoomDiscoveryConfiguration) async throws -> V2RoomClusterDiscovery {
        let clientID = ObjectIdentifier(client)
        guard let system, discoveryBeacon != nil, acceptingDiscoveries,
              clients.contains(where: { $0 === client }),
              !discoveryClientIDs.contains(clientID), discoveries.count < 64 else {
            throw V2RoomCallFailure.notAccepted(.notReady)
        }
        let discovery = V2RoomClusterDiscovery(system: system, client: client,
                                                trust: trust, configuration: configuration)
        discoveries.append(discovery)
        discoveryClientIDs.insert(clientID)
        await discovery.start()
        if !acceptingDiscoveries { await discovery.stop() }
        return discovery
    }

    /// Owns one callback endpoint on the existing mTLS cluster, including caller-only nodes.
    public func makeRealtimeShardTransport(identity: V2GatewayRealtimeIdentity,
        serving: any V2RealtimeShardServing,
        serviceOwnerAccess: [V2ActorServiceID: Set<String>],
        discoveryPeers: [V2RealtimeShardDiscoveryPeer],
        limits: V2RealtimeTransportLimits = .init(),
        serviceQualification: V2ActorServiceQualification? = nil) async throws -> V2RealtimeShardTransportHandle {
        guard let system, realtimeShards == nil, acceptingDiscoveries else { throw V2ActorAuthenticationError.invalidConfiguration }
        let handle = try buildRealtimeShardTransport(system: system, identity: identity,
            address: configuration.host, port: configuration.port, signer: signer, trust: trust,
            serving: serving, serviceOwnerAccess: serviceOwnerAccess, discoveryPeers: discoveryPeers, limits: limits, serviceQualification: serviceQualification)
        realtimeShards = handle
        await handle.start()
        if !acceptingDiscoveries { _ = await handle.stop(deadline: .now + .seconds(2)); throw V2ActorAuthenticationError.overloaded }
        return handle
    }

    public func makeRealtimeTransport(identity: V2GatewayRealtimeIdentity,
                                      ingress: any V2RealtimeIngress,
                                      serviceOwnerAccess: [V2ActorServiceID: Set<String>],
                                      limits: V2RealtimeTransportLimits = .init()) throws -> V2RealtimeTransportHandle {
        guard let system, realtime == nil, acceptingDiscoveries else { throw V2ActorAuthenticationError.invalidConfiguration }
        let handle = try buildRealtimeTransport(system: system, identity: identity,
            address: configuration.host, port: configuration.port, signer: signer, trust: trust,
            ingress: ingress, serviceOwnerAccess: serviceOwnerAccess, limits: limits)
        realtime = handle
        return handle
    }

    public func readiness() async -> Bool {
        guard system != nil, inbound != nil, endpoint != nil, discoveryBeacon != nil else { return false }
        return await host.snapshot().accepting
    }

    public func drain(deadline: ContinuousClock.Instant) async -> V2RoomActivationDrainResult {
        acceptingDiscoveries = false
        for discovery in discoveries { await discovery.stop() }
        await discoveryPublisherState?.beginDrain()
        await host.beginDrain()
        for client in clients { await client.stop() }
        return await host.drain(deadline: deadline)
    }

    /// 排空未完成时保留 Cluster 和数据库访问。
    /// 正在执行的 SQL 或恢复操作实际结束后，调用方可重试停止。
    public func stop(deadline: ContinuousClock.Instant) async throws -> V2RoomActivationDrainResult {
        acceptingDiscoveries = false
        while starting && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        guard !starting else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        guard await realtimeShards?.stop(deadline: deadline) ?? true else {
            throw V2ActorAuthenticationError.overloaded
        }
        guard await realtime?.stop(deadline: deadline) ?? true else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        let result = await drain(deadline: deadline)
        guard result.completed else { return result }
        for discovery in discoveries {
            guard await discovery.quiesce(deadline: deadline) else {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
        }
        guard await inbound?.quiesce(deadline: deadline) ?? true else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        for client in clients {
            guard await client.quiesce(deadline: deadline) else {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
        }
        realtime = nil
        realtimeShards = nil
        clients.removeAll()
        discoveries.removeAll()
        discoveryClientIDs.removeAll()
        await inbound?.stop()
        inbound = nil
        localGeneration = nil
        endpoint = nil
        discoveryBeacon = nil
        discoveryPublisherState = nil
        if let system { try await system.shutdown().wait() }
        system = nil
        return result
    }

    public func hostedActorCount() async -> Int { await inbound?.actorCount() ?? 0 }
}
