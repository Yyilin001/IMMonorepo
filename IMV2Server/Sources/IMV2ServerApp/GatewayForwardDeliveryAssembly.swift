import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Server
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
    ) throws -> Self {
        let topology = prepared.topology
        let roomOwners = prepared.roomOwners
        let forwardPort = roomServices.forwardPort
        let callTimeout = roomServices.callTimeout
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
