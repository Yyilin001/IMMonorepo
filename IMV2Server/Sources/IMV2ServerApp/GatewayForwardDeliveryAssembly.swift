import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Server
import Logging

/// 为各房间分片构造转发导入端点与投递 Worker；此阶段不启动轮询。
struct GatewayForwardDeliveryAssembly {
    let runtime: V2ForwardDeliveryRuntime
    let backgroundDatabases: [String: any Database]

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        localMediaConfiguration: V2LocalFilesystemMediaRuntimeConfiguration?,
        topology: GatewayDatabaseTopology,
        roomOwners: GatewayRoomOwnerAssembly,
        forwardPort: V2RoomRefForwardPort,
        callTimeout: V2ActorMilliseconds,
        logger: Logger
    ) throws -> Self {
        // 仅供本地使用的字节适配器：账号边缘与 Gateway 必须共享配置的对象根目录。
        // 此处不调用 prepare()；活动上传暂存文件由账号边缘在启动时清理。
        let forwardMediaProvider: V2LocalFilesystemMediaProvider?
        if let localMediaConfiguration {
            forwardMediaProvider = try .init(rootDirectory: localMediaConfiguration.rootDirectory,
                targetBaseURL: localMediaConfiguration.publicBaseURL, signingKey: localMediaConfiguration.signingKey)
        } else { forwardMediaProvider = nil }
        var forwardTargetEndpoints: [String: any V2ForwardExportDelivering] = [:]
        var forwardBackgroundDatabases: [String: any Database] = [:]
        for storage in configuration.roomShardStorage {
            guard let ownerDatabase = topology.databaseForRole(for: .delivery, url: storage.databaseURL)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            forwardBackgroundDatabases[storage.shardID] = ownerDatabase
            let mediaWorker: V2ForwardMediaImportWorker?
            if let forwardMediaProvider, let localMediaConfiguration {
                let sources = Dictionary(uniqueKeysWithValues: roomOwners.forwardTargetWritesByShard.keys.map { ($0, forwardMediaProvider) })
                mediaWorker = try .init(store: .init(database: ownerDatabase),
                    copier: V2LocalFilesystemForwardMediaCopier(sources: sources, target: forwardMediaProvider, maximumBytes: localMediaConfiguration.maximumBytes),
                    scanner: V2LocalEICARMediaScanner(provider: forwardMediaProvider))
            } else { mediaWorker = nil }
            forwardTargetEndpoints[storage.shardID] = V2ActorForwardImportEndpoint(
                inbox: .init(database: ownerDatabase), media: mediaWorker,
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
