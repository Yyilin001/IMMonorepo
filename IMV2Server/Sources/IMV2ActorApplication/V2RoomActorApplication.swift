import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Server
import IMV2ServerInfrastructure

public enum V2RoomActorApplicationError: Error, Sendable {
    case invalidRole
    case incompleteShutdown
}

/// Gateway Host 与 Account/Operator 调用方共用的启动和停机组合入口。
/// 领域服务接收 RoomDirectory；集群 ActorID 仅保留在此边界内。
public actor V2RoomActorApplication: V2RoomRuntimeMetricsReading {
    public nonisolated let directory: V2RoomDirectory
    public nonisolated let reservations: V2RoomReservationCoordinator
    public nonisolated let configuration: V2RoomRuntimeConfiguration
    private let node: Node
    private let metrics: @Sendable () async -> V2RoomRuntimeMetricsSnapshot

    private enum Node: Sendable {
        case host(V2RoomClusterNode)
        case caller(V2RoomClusterClientNode)
    }

    private init(directory: V2RoomDirectory, reservations: V2RoomReservationCoordinator,
                 configuration: V2RoomRuntimeConfiguration, node: Node,
                 metrics: @escaping @Sendable () async -> V2RoomRuntimeMetricsSnapshot) {
        self.directory = directory
        self.reservations = reservations
        self.configuration = configuration
        self.node = node
        self.metrics = metrics
    }

    public static func start(configuration: V2RoomActorApplicationConfiguration,
                             ownerRouter: any V2RoomShardRouting,
                             roomDatabases: [String: any Database],
                             factory: V2RoomServerActivationFactory? = nil) async throws -> V2RoomActorApplication {
        let leases = try V2RoomServerLeaseStore(databases: roomDatabases)
        let client: V2RoomClusterClient
        let node: Node
        let runtimeHost: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>?
        let runtimeBudget: V2RoomCommandBudget?
        if let identity = configuration.hostIdentity {
            guard let factory,
                  configuration.allowedShards.isSubset(of: Set(roomDatabases.keys)) else {
                throw V2RoomActorApplicationError.invalidRole
            }
            let runtime = configuration.runtime
            let budget = V2RoomCommandBudget(configuration: runtime)
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
                leaseStore: leases, configuration: runtime, budget: budget,
                classify: { $0.turnSchedulingClass }, factory: factory.runtimeFactory())
            runtimeHost = host
            runtimeBudget = budget
            let hostNode = V2RoomClusterNode(configuration: try .init(name: configuration.name,
                host: configuration.address, port: configuration.port, tls: configuration.tls,
                threadPoolSize: configuration.threadPoolSize, allowedShards: configuration.allowedShards,
                serviceShardAccess: configuration.serviceShardAccess), identity: identity, host: host,
                signer: configuration.signer, trust: configuration.trust,
                authenticationLimits: configuration.authentication, runtimeConfiguration: runtime)
            do {
                _ = try await hostNode.start()
                client = try await hostNode.makeClient(signer: configuration.signer,
                    trust: configuration.trust, limits: configuration.authentication)
                _ = try await hostNode.startDiscovery(client: client, configuration: configuration.discovery)
                node = .host(hostNode)
            } catch {
                guard try await hostNode.stop(deadline: .now + runtime.drainTimeout.duration).completed else {
                    throw V2RoomActorApplicationError.incompleteShutdown
                }
                throw error
            }
        } else {
            runtimeHost = nil
            runtimeBudget = nil
            guard factory == nil else { throw V2RoomActorApplicationError.invalidRole }
            let caller = V2RoomClusterClientNode(configuration: try .init(name: configuration.name,
                host: configuration.address, port: configuration.port, tls: configuration.tls,
                threadPoolSize: configuration.threadPoolSize), signer: configuration.signer,
                trust: configuration.trust, authenticationLimits: configuration.authentication,
                runtimeConfiguration: configuration.runtime)
            do {
                client = try await caller.start(discovery: configuration.discovery)
                node = .caller(caller)
            } catch {
                guard try await caller.stop(deadline: .now + configuration.runtime.drainTimeout.duration) else {
                    throw V2RoomActorApplicationError.incompleteShutdown
                }
                throw error
            }
        }
        let directory = V2RoomDirectory(owners: V2RoomServerOwnerResolver(router: ownerRouter),
            leases: leases, hosts: client, transport: client, configuration: configuration.runtime)
        let reservations = V2RoomReservationCoordinator(operations: await directory.reservationOperations(),
            configuration: configuration.runtime)
        return .init(directory: directory, reservations: reservations,
                     configuration: configuration.runtime, node: node, metrics: {
                         let location = await directory.snapshot()
                         return await .init(host: runtimeHost?.snapshot(), commands: runtimeBudget?.snapshot(),
                             cachedLocations: location.cached, pendingResolutions: location.pending,
                             activeResolutions: location.active, resolutionWaiters: location.waiters)
                     })
    }

    public func roomRuntimeMetricsSnapshot() async -> V2RoomRuntimeMetricsSnapshot {
        await metrics()
    }

    public func readiness() async -> Bool {
        switch node {
        case .host(let host): await host.readiness()
        case .caller(let caller): await caller.readiness()
        }
    }

    /// 返回 false 表示共享数据库和传输资源仍须保持存活。
    /// 实际操作结束后，调用方可用更晚的期限重试。
    public func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        await directory.drain()
        async let directoryStopped = directory.quiesce(deadline: deadline)
        let nodeStopped: Bool
        do {
            switch node {
            case .host(let host): nodeStopped = try await host.stop(deadline: deadline).completed
            case .caller(let caller): nodeStopped = try await caller.stop(deadline: deadline)
            }
        } catch {
            _ = await directoryStopped
            throw error
        }
        let resolutionsStopped = await directoryStopped
        return nodeStopped && resolutionsStopped
    }
}
