import FluentKit
import Foundation
import IMV2ActorApplication
import IMV2Server

/// 将逻辑房间分片映射到物理归属方，复用同址写入 Store 和批处理器。
/// 此阶段只构造依赖，不启动房间 Actor 或后台任务。
/// `ownerResources` 按逻辑分片索引；`physicalResources` 按数据库 URL 与 schema 索引。
struct GatewayRoomOwnerAssembly {
    let actorConfiguration: V2RoomActorApplicationConfiguration
    let committedHybridGroupEvents: V2CommittedHybridGroupEventObserver
    let groupEventWakeStore: any V2GroupEventWakeStore
    let ownerResources: [String: V2RoomServerOwnerResources]
    let physicalResources: [String: V2RoomServerOwnerResources]
    let ownerBatchers: [String: any V2ActorGrantedSendBatching & V2SendMessageBatchMetricsReading]
    let forwardTargetWritesByShard: [String: PostgresV2RoomWriteStore]
    let physicalStoreKeyByShard: [String: String]
    let bootstraps: [String: V2RoomBootstrapDomainExecutor]
    let forwardPairs: [String: V2ActorForwardPairDomainExecutor]
    let shardAdmissionCredits: V2ShardAdmissionCommandCreditPool?
    let roomAdmissionCredits: V2RoomAdmissionCommandCreditPool?

    /// 为每个物理归属位置只创建一套写入与批处理资源，再映射回逻辑分片。
    /// 转发目标、创建执行器和 Actor 激活工厂随后使用同一映射，避免同址分片重复占用额度。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        topology: GatewayDatabaseTopology,
        userShardProjectionDelivery: V2PostgresUserShardProjectionDelivery,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController,
        directSendPolicyCache: V2DirectSendPolicyCache,
        directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache,
        directRoomLogAppendStageMetrics: V2DirectRoomLogAppendStageMetrics,
        directRoomLogEventCache: V2DirectRoomLogEventCache?
    ) throws -> Self {
        let database = topology.database
        let roomShardDatabases = topology.roomShardDatabases
        let directSendControlPool = topology.directSendControlPool
        let authorizationControlDatabase = topology.authorizationControlDatabase
        func databaseForRole(
            for role: V2PostgresWorkloadPoolBudget.Role, url: String
        ) -> (any Database)? {
            topology.databaseForRole(for: role, url: url)
        }
        // 分隔符避免不同 URL/schema 组合拼接后发生键碰撞。
        let roomPhysicalLocationKeys = Set(configuration.roomShardStorage.map {
            $0.databaseURL + "\u{0}" + $0.schema
        })
        let singleRoomOwnerIsControlDatabase =
            roomPhysicalLocationKeys.count == 1
            && configuration.roomShardStorage.allSatisfy {
                $0.databaseURL == configuration.databaseURL
                    && $0.schema == "im_v2"
            }
        // 只有同址快速路径与运行时指标、特殊账号命令共用一个准入额度 Actor。
        // 远端单一归属方必须走下面的路由路径；若将这些 Actor 绑定到控制库，
        // 就会在错误的事务域中预留额度。
        let directRoomLogShardAdmissionCredits:
            V2ShardAdmissionCommandCreditPool? =
            singleRoomOwnerIsControlDatabase
                && configuration.directRoomLogShardAdmissionCreditBatchSize > 0
            ? .init(
                database: database,
                batchSize: configuration.directRoomLogShardAdmissionCreditBatchSize
            )
            : nil
        let directRoomLogRoomAdmissionCredits:
            V2RoomAdmissionCommandCreditPool? =
            singleRoomOwnerIsControlDatabase
                && configuration.directRoomLogRoomAdmissionCreditBatchSize > 0
            ? .init(
                database: database,
                batchSize: configuration.directRoomLogRoomAdmissionCreditBatchSize
            )
            : nil
        var groupEventWakeStoresByPhysicalLocation:
            [String: any V2GroupEventWakeStore] = [:]
        // 唤醒 outbox 按物理位置去重；多归属方时交给路由 Store 分发。
        for storage in configuration.roomShardStorage {
            let physicalLocationKey = storage.databaseURL + "\u{0}" + storage.schema
            guard groupEventWakeStoresByPhysicalLocation[physicalLocationKey] == nil
            else { continue }
            guard let ownerDeliveryDatabase = databaseForRole(
                for: .delivery,
                url: storage.databaseURL
            ) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            groupEventWakeStoresByPhysicalLocation[physicalLocationKey] =
                PostgresV2GroupEventWakeStore(database: ownerDeliveryDatabase)
        }
        let groupEventWakeStore: any V2GroupEventWakeStore
        if groupEventWakeStoresByPhysicalLocation.count == 1,
           let onlyStore = groupEventWakeStoresByPhysicalLocation.values.first {
            groupEventWakeStore = onlyStore
        } else {
            groupEventWakeStore = try V2RoutedGroupEventWakeStore(
                ownerStores: groupEventWakeStoresByPhysicalLocation
            )
        }
        let actorConfiguration = try V2RoomActorApplicationConfiguration(
            environment: ProcessRuntimeEnvironment(), hostsRooms: nil,
            configuredShardIDs: Set(configuration.roomShardStorage.map(\.shardID)),
            batchWaitMilliseconds: Int64(max(
                configuration.directRoomLogAppendBatchMaximumDelayMilliseconds,
                configuration.directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds ?? 0,
                configuration.readReceiptBatchMaximumDelayMilliseconds)))
        let committedHybridGroupEvents = V2CommittedHybridGroupEventObserver(
            directRoomLogEventCache: directRoomLogEventCache)
        let actorBatchConfiguration = V2SendMessageAdmissionBatcher.Configuration(
            maximumBatchSize: max(1, configuration.directRoomLogAppendBatchSize),
            maximumDelay: .milliseconds(max(1, configuration.directRoomLogAppendBatchMaximumDelayMilliseconds)),
            adaptiveDelayPolicy: {
                guard configuration.directRoomLogAppendBatchSize > 0,
                      let delay = configuration.directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds,
                      let minimumRequests = configuration.directRoomLogAppendBatchHighActivityMinimumRequests,
                      let window = configuration.directRoomLogAppendBatchHighActivityWindowMilliseconds
                else { return nil }
                return .init(highActivityMaximumDelay: .milliseconds(delay),
                    minimumRequestsInWindow: minimumRequests, observationWindow: .milliseconds(window))
            }(),
            maximumInFlightBatches: configuration.directRoomLogAppendBatchMaximumInFlightBatches,
            maximumPendingRequests: configuration.directRoomLogAppendMaximumPendingRequests,
            maximumTrackedActivations: actorConfiguration.runtime.maximumActiveRooms)
        var ownerResources: [String: V2RoomServerOwnerResources] = [:]
        var physicalResources: [String: V2RoomServerOwnerResources] = [:]
        var ownerBatchers: [String: any V2ActorGrantedSendBatching & V2SendMessageBatchMetricsReading] = [:]
        var forwardTargetWritesByShard: [String: PostgresV2RoomWriteStore] = [:]
        var physicalWrites: [String: PostgresV2RoomWriteStore] = [:]
        var physicalStoreKeyByShard: [String: String] = [:]
        var bootstraps: [String: V2RoomBootstrapDomainExecutor] = [:]
        var forwardPairs: [String: V2ActorForwardPairDomainExecutor] = [:]
        let membershipIdentities = V2PostgresMembershipIdentitySnapshotValidator(database: database)
        let invitationIdentities = PostgresV2GroupInvitationIdentityReader(database: database)
        // 逻辑分片分别拥有 bootstrap/转发入口；同址分片共享实际写入者与批处理器。
        for storage in configuration.roomShardStorage {
            guard let owner = roomShardDatabases[storage.shardID] else {
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
                let shardCredits = singleRoomOwnerIsControlDatabase
                    ? directRoomLogShardAdmissionCredits
                    : configuration.directRoomLogShardAdmissionCreditBatchSize > 0
                        ? V2ShardAdmissionCommandCreditPool(database: owner,
                            batchSize: configuration.directRoomLogShardAdmissionCreditBatchSize) : nil
                let roomCredits = singleRoomOwnerIsControlDatabase
                    ? directRoomLogRoomAdmissionCredits
                    : configuration.directRoomLogRoomAdmissionCreditBatchSize > 0
                        ? V2RoomAdmissionCommandCreditPool(database: owner,
                            batchSize: configuration.directRoomLogRoomAdmissionCreditBatchSize) : nil
                write = PostgresV2RoomWriteStore(database: owner,
                    strangerMessagePolicy: configuration.strangerMessagePolicy,
                    contentReviewMode: configuration.contentReviewMode,
                    directSendPolicyCache: directSendPolicyCache,
                    directRoomLogFastAppendCache: directRoomLogFastAppendCache,
                    shardAdmissionCommandCreditPool: shardCredits,
                    roomAdmissionCommandCreditPool: roomCredits,
                    appendStageMetrics: directRoomLogAppendStageMetrics)
                    .usingControlDatabase(directSendControlPool.database,
                        authorizationResolutionDatabase: authorizationControlDatabase)
                let batcher: any V2ActorGrantedSendBatching & V2SendMessageBatchMetricsReading
                let appendAdmission = configuration.databaseWorkAdmissionEnabled ? databaseWorkAdmission : nil
                if configuration.directRoomLogAppendBatchSize > 0,
                   configuration.directRoomLogAppendLaneCount > 1 {
                    batcher = V2ShardedSendMessageAdmissionBatcher(store: write,
                        configuration: actorBatchConfiguration,
                        laneCount: configuration.directRoomLogAppendLaneCount,
                        databaseWorkAdmission: appendAdmission,
                        committedMessageObserver: committedHybridGroupEvents, actorGrantedStore: write)
                } else {
                    batcher = V2SendMessageAdmissionBatcher(store: write,
                        configuration: actorBatchConfiguration, databaseWorkAdmission: appendAdmission,
                        committedMessageObserver: committedHybridGroupEvents, actorGrantedStore: write)
                }
                resourcesForOwner = try .init(database: owner, writes: write, sendBatcher: batcher,
                    membershipIdentities: membershipIdentities, invitationIdentities: invitationIdentities,
                    receiptProjectionDelivery: userShardProjectionDelivery,
                    capacityProfile: configuration.capacityProfile, messageLimits: configuration.messageLimits,
                    maximumEditBytes: configuration.messageLimits.maxUTF8Bytes,
                    contentReviewMode: configuration.contentReviewMode,
                    queryBatchConfiguration: .init(),
                    receiptBatchConfiguration: .init(maximumBatchSize: configuration.readReceiptBatchSize,
                        maximumDelay: .milliseconds(configuration.readReceiptBatchMaximumDelayMilliseconds),
                        maximumInFlightBatches: configuration.readReceiptBatchMaximumInFlightBatches,
                        maximumPendingRequests: configuration.readReceiptBatchMaximumPendingRequests),
                    databaseWorkAdmission: databaseWorkAdmission)
                physicalResources[physicalKey] = resourcesForOwner
                physicalWrites[physicalKey] = write
                ownerBatchers[physicalKey] = batcher
            }
            ownerResources[storage.shardID] = resourcesForOwner
            forwardTargetWritesByShard[storage.shardID] = write
            bootstraps[storage.shardID] = try .init(shardID: storage.shardID,
                direct: PostgresV2DirectMessagingStore(database: owner, projectionDelivery: userShardProjectionDelivery),
                group: PostgresV2GroupMessagingStore(database: owner), capacityProfile: configuration.capacityProfile)
            forwardPairs[storage.shardID] = .init(database: owner, write: write,
                capacityProfile: configuration.capacityProfile, limits: configuration.messageLimits,
                databaseWorkAdmission: databaseWorkAdmission)
        }
        return .init(
            actorConfiguration: actorConfiguration,
            committedHybridGroupEvents: committedHybridGroupEvents,
            groupEventWakeStore: groupEventWakeStore,
            ownerResources: ownerResources,
            physicalResources: physicalResources,
            ownerBatchers: ownerBatchers,
            forwardTargetWritesByShard: forwardTargetWritesByShard,
            physicalStoreKeyByShard: physicalStoreKeyByShard,
            bootstraps: bootstraps,
            forwardPairs: forwardPairs,
            shardAdmissionCredits: directRoomLogShardAdmissionCredits,
            roomAdmissionCredits: directRoomLogRoomAdmissionCredits
        )
    }
}
