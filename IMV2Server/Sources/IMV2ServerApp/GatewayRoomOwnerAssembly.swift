import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorApplication
import IMV2Server
import IMV2ServerInfrastructure

/// 将逻辑房间分片映射到物理归属方，复用同址写入 Store 和连接调度资源。
/// 此阶段只构造依赖，不启动房间 Actor 或后台任务。
/// `ownerResources` 按逻辑分片索引；`physicalResources` 按数据库 URL 与 schema 索引。
struct GatewayRoomOwnerAssembly {
    let databaseWorkAdmissions: V2PhysicalDatabaseWorkAdmissions
    let actorConfiguration: V2RoomActorApplicationConfiguration
    let ownerResources: [String: V2RoomServerOwnerResources]
    let physicalResources: [String: V2RoomServerOwnerResources]
    let physicalStoreKeyByShard: [String: String]
    let bootstraps: [String: V2RoomBootstrapDomainExecutor]
    let forwardPairs: [String: V2ActorForwardPairDomainExecutor]

    /// 为每个物理归属位置只创建一套写入与连接调度资源，再映射回逻辑分片。
    /// 转发目标、创建执行器和 Actor 激活工厂随后使用同一映射，避免同址分片重复占用额度。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        actorConfiguration: V2RoomActorApplicationConfiguration,
        topology: GatewayDatabaseTopology,
        userShardProjectionDelivery: V2PostgresUserShardProjectionDelivery,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController,
        directSendPolicyCache: V2DirectSendPolicyCache,
        directRoomLogAppendStageMetrics: V2DirectRoomLogAppendStageMetrics
    ) throws -> Self {
        let database = topology.database
        let roomShardDatabases = topology.roomShardDatabases
        let directSendControlPool = topology.directSendControlPool
        let roomIdentityControlDatabase = topology.roomIdentityControlDatabase
        let ownerAdmissions = V2PhysicalDatabaseWorkAdmissions(primaryKey: configuration.databaseURL,
            primary: databaseWorkAdmission, keys: topology.physicalDatabaseURLs,
            policy: GatewayFrontdoorAssembly.databaseWorkAdmissionPolicy(configuration),
            coverageReservedQueued: Dictionary(uniqueKeysWithValues: topology.physicalDatabaseURLs.map { url in
                (url, GatewayFrontdoorAssembly.coverageReservedQueued(
                    roomShardStorage: configuration.roomShardStorage.filter { $0.databaseURL == url },
                    maximumReadQueued: configuration.interactiveReadDatabaseWorkMaximumQueued))
            }))
        let durableSchedulingConfiguration = configuration.durableSendSchedulingConfiguration()
        var ownerResources: [String: V2RoomServerOwnerResources] = [:]
        var physicalResources: [String: V2RoomServerOwnerResources] = [:]
        var physicalWrites: [String: PostgresV2RoomWriteStore] = [:]
        var physicalStoreKeyByShard: [String: String] = [:]
        var bootstraps: [String: V2RoomBootstrapDomainExecutor] = [:]
        var forwardPairs: [String: V2ActorForwardPairDomainExecutor] = [:]
        let membershipIdentities = V2PostgresMembershipIdentitySnapshotValidator(database: database)
        let invitationIdentities = PostgresV2GroupInvitationIdentityReader(database: database)
        // 逻辑分片分别拥有 bootstrap/转发入口；同址分片共享实际写入者与连接调度资源。
        for storage in configuration.roomShardStorage {
            guard let owner = roomShardDatabases[storage.shardID] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let ownerAdmission = ownerAdmissions.controller(for: storage.databaseURL) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let physicalKey = storage.databaseURL + "\u{0}" + storage.schema
            physicalStoreKeyByShard[storage.shardID] = physicalKey
            let write: PostgresV2RoomWriteStore
            let resourcesForOwner: V2RoomServerOwnerResources
            if let existing = physicalResources[physicalKey], let existingWrite = physicalWrites[physicalKey] {
                resourcesForOwner = existing
                write = existingWrite
            } else {
                write = PostgresV2RoomWriteStore(database: owner,
                    strangerMessagePolicy: configuration.strangerMessagePolicy,
                    contentReviewMode: configuration.contentReviewMode,
                    directSendPolicyCache: directSendPolicyCache,
                    appendStageMetrics: directRoomLogAppendStageMetrics)
                    .usingControlDatabase(directSendControlPool.database)
                resourcesForOwner = try .init(database: owner,
                    sendDatabase: topology.databaseForRole(for: .messageWrite, url: storage.databaseURL), writes: write,
                    membershipIdentities: membershipIdentities, invitationIdentities: invitationIdentities,
                    invitationSecretIssuer: configuration.groupInviteSecretIssuer,
                    receiptProjectionDelivery: userShardProjectionDelivery,
                    capacityProfile: configuration.capacityProfile, messageLimits: configuration.messageLimits,
                    maximumEditBytes: configuration.messageLimits.maxUTF8Bytes,
                    contentReviewMode: configuration.contentReviewMode,
                    queryBatchConfiguration: .init(),
                    receiptBatchConfiguration: .init(maximumBatchSize: configuration.readReceiptBatchSize,
                        maximumDelay: .milliseconds(configuration.readReceiptBatchMaximumDelayMilliseconds),
                        maximumInFlightBatches: configuration.readReceiptBatchMaximumInFlightBatches,
                        maximumPendingRequests: configuration.readReceiptBatchMaximumPendingRequests),
                    databaseWorkAdmission: ownerAdmission,
                    committedMessageObserver: nil,
                    maximumActiveRooms: actorConfiguration.runtime.maximumActiveRooms,
                    maximumRoomSubscriptionBindings: actorConfiguration.runtime.maximumActiveRooms * actorConfiguration.realtimePeers.count,
                    durableSendSchedulingConfiguration: durableSchedulingConfiguration)
                physicalResources[physicalKey] = resourcesForOwner
                physicalWrites[physicalKey] = write
            }
            ownerResources[storage.shardID] = resourcesForOwner
            bootstraps[storage.shardID] = try .init(shardID: storage.shardID,
                direct: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: roomIdentityControlDatabase), projectionDelivery: userShardProjectionDelivery),
                group: PostgresV2GroupMessagingStore(database: owner), capacityProfile: configuration.capacityProfile)
            forwardPairs[storage.shardID] = .init(database: owner, write: write,
                capacityProfile: configuration.capacityProfile, limits: configuration.messageLimits,
                databaseWorkAdmission: ownerAdmission)
        }
        return .init(
            databaseWorkAdmissions: ownerAdmissions,
            actorConfiguration: actorConfiguration,
            ownerResources: ownerResources,
            physicalResources: physicalResources,
            physicalStoreKeyByShard: physicalStoreKeyByShard,
            bootstraps: bootstraps,
            forwardPairs: forwardPairs
        )
    }
}
