import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Server
import IMV2ServerInfrastructure
import Logging

/// 为各房间分片构造转发导入端点与投递 Worker；此阶段不启动轮询。
/// `backgroundDatabases` 保留各分片的投递库句柄，供后台维护阶段使用。
struct GatewayForwardDeliveryAssembly {
    let runtime: V2ForwardDeliveryRuntime
    let backgroundDatabases: [String: any Database]

    /// 以分片的投递连接池创建导入端点和重试 Worker，并统一接入 Actor 命令端口。
    /// 可选本地媒体提供者仅在配置存在时构造；文件暂存清理由账号边缘负责。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        localMediaConfiguration: V2LocalFilesystemMediaRuntimeConfiguration?,
        prepared: GatewayPreparedAssembly,
        roomServices: GatewayRoomServicesAssembly,
        logger: Logger
    ) async throws -> Self {
        let topology = prepared.topology
        let forwardPort = roomServices.forwardPort
        let callTimeout = roomServices.callTimeout
        var storageValues: [V2StorageBinding: V2LocalResourceStorage] = [:]
        let registry: V2ResourceStorageRegistry?
        let transformer: V2LocalResourceTransformer?
        if let localMediaConfiguration {
            let backends = try V2ResourceBackendConfiguration(environment: ProcessRuntimeEnvironment(),
                defaultDirectory: localMediaConfiguration.rootDirectory)
            for entry in backends.entries {
                let binding = try entry.binding
                storageValues[binding] = try .init(root: URL(fileURLWithPath: entry.directory, isDirectory: true)
                    .appendingPathComponent("sealed-resources"), binding: binding)
            }
            registry = try .init(storages: Array(storageValues.values), defaultBinding: backends.defaultBinding)
            let path = ProcessInfo.processInfo.environment["IMV2_RESOURCE_IMAGE_WORKER"]
                ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                    .appendingPathComponent("IMV2ResourceImageWorker").path
            if FileManager.default.isExecutableFile(atPath: path) {
                transformer = try .init(executable: URL(fileURLWithPath: path),
                    temporaryDirectory: localMediaConfiguration.rootDirectory.appendingPathComponent("forward-processing"))
                try await transformer?.verifyReadiness()
            } else { transformer = nil }
        } else { registry = nil; transformer = nil }
        let storages = storageValues
        var forwardTargetEndpoints: [String: any V2ForwardExportDelivering] = [:]
        var forwardBackgroundDatabases: [String: any Database] = [:]
        for storage in configuration.roomShardStorage {
            guard let ownerDatabase = topology.databaseForRole(for: .delivery, url: storage.databaseURL)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            forwardBackgroundDatabases[storage.shardID] = ownerDatabase
        }
        for storage in configuration.roomShardStorage {
            guard let ownerDatabase = forwardBackgroundDatabases[storage.shardID]
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let mediaWorker: V2ForwardMediaImportWorker?
            if let localMediaConfiguration, let registry {
                try await V2ResourceStorageReadiness.verify(database: ownerDatabase, registry: registry)
                let store = try PostgresV2ForwardMediaImportStore(database: ownerDatabase)
                let allocate: @Sendable (V2StorageBinding) throws -> V2StoredObjectReference = { binding in
                    guard let storage = storages[binding] else { throw V2ResourceProviderError.configurationInvalid }
                    return try storage.allocate()
                }
                let variants = transformer.map {
                    V2ResourceVariantProcessor(database: ownerDatabase, registry: registry, transformer: $0, allocate: allocate)
                }
                mediaWorker = try .init(store: store,
                    copier: V2ResourceForwardMediaCopier(sources: forwardBackgroundDatabases, target: store,
                        registry: registry, maximumBytes: localMediaConfiguration.maximumBytes, allocate: allocate),
                    scanner: V2PlacementMediaScanner(database: ownerDatabase, registry: registry,
                        scanner: V2LocalResourceScanner(),
                        variants: variants))
            } else { mediaWorker = nil }
            forwardTargetEndpoints[storage.shardID] = V2ActorForwardImportEndpoint(
                inbox: PostgresV2ForwardInboxStore(database: ownerDatabase), media: mediaWorker,
                roomCommand: { try await forwardPort.execute($0, deadline: $1) },
                deadline: { .now + callTimeout.duration })
        }
        let forwardTransport = try V2ConfiguredForwardExportDelivery(targets: forwardTargetEndpoints)
        let forwardWorkers = try Dictionary(uniqueKeysWithValues: forwardBackgroundDatabases.map { shardID, ownerDatabase in
            (shardID, try V2ForwardDeliveryWorker(store: .init(database: ownerDatabase), receipts: .init(database: ownerDatabase), target: forwardTransport,
                sourceCommand: { try await forwardPort.execute($0, deadline: $1) },
                deadline: { .now + callTimeout.duration }))
        })
        let forwardRuntime = try V2ForwardDeliveryRuntime(workers: forwardWorkers,
            minimumPollMilliseconds: configuration.workerPollIntervalMilliseconds,
            onFailure: { _ in logger.error("IM V2 forward delivery worker failed; retrying") })
        return .init(runtime: forwardRuntime, backgroundDatabases: forwardBackgroundDatabases)
    }
}
