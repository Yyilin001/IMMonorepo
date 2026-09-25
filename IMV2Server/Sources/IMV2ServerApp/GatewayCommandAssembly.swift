import Foundation
import IMV2ActorApplication
import IMV2Server

/// 装配登录后命令处理器及可选内容审核 Worker。
/// 账号房间变更服务由组合根先登记，避免此阶段抛错时遗漏关闭。
struct GatewayCommandAssembly {
    let handler: V2GatewayDomainCommandHandler
    let contentReviewWorker: V2RoutedContentReviewWorker?

    /// 把房间、社交、同步与在线活动服务接入统一命令处理器。
    /// 此阶段还将在线状态能力接入连接注册表；错误由组合根回滚 Actor 与辅助服务。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        prepared: GatewayPreparedAssembly,
        roomServices: GatewayRoomServicesAssembly,
        realtime: GatewayRealtimeAssembly,
        roomRecovery: V2RoomRecoveryCommandService,
        actors: V2RoomActorApplication
    ) async throws -> Self {
        let topology = prepared.topology
        let projection = prepared.projection
        let frontdoor = prepared.frontdoor
        let ownerMaintenance = prepared.ownerMaintenance
        let socialRelationships = V2SocialRelationshipService(
            store: PostgresV2SocialRelationshipStore(database: topology.database, projectionDelivery: projection.userShardProjectionDelivery, authorizationCoordinator: prepared.authorization)
        )
        // 仅配置了审核模式和安全执行身份时才创建各归属库的审核 Worker。
        let contentReviewWorker: V2RoutedContentReviewWorker?
        if configuration.contentReviewMode == .enabled,
           configuration.contentReviewSafetyActorUserID != nil {
            let reviewer = V2ConfiguredContentReviewer(
                violatingTerms: configuration.contentReviewViolationTerms,
                reviewTerms: configuration.contentReviewEscalationTerms
            )
            let trustedModeration = V2RoomContentReviewSafetyApplicator(callTimeout: roomServices.callTimeout.duration) {
                request, deadline in
                try await actors.directory.room(request.roomID).call(request, principal: .service, deadline: deadline)
            }
            let reviewWorkers = try ownerMaintenance.roomOwnerDatabaseURLs.map { ownerURL in
                guard let ownerMaintenanceDatabase = topology.databaseForRole(
                    for: .maintenance,
                    url: ownerURL
                ) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try V2ContentReviewWorker(
                    store: PostgresV2ContentReviewStore(
                        database: ownerMaintenanceDatabase
                    ),
                    reviewer: reviewer,
                    moderation: trustedModeration,
                    retryPolicy: configuration.durableRetryPolicy
                )
            }
            contentReviewWorker = try V2RoutedContentReviewWorker(
                workers: reviewWorkers
            )
        } else {
            contentReviewWorker = nil
        }
        let conversationCapabilities = V2ConversationCapabilitiesService(
            store: PostgresV2ConversationCapabilitiesStore(database: topology.database, projectionDelivery: projection.userShardProjectionDelivery)
        )
        let liveActivityStore = try PostgresV2LiveActivityStore(database: topology.database)
        let liveActivity = V2LiveActivityService(store: liveActivityStore)
        await frontdoor.connectionRegistry.configureLivePresenceLeases(liveActivityStore)
        await frontdoor.connectionRegistry.configureLiveActivityObservationAuthorizer(liveActivity)
        let handler = V2GatewayDomainCommandHandler(
            roomActors: roomServices.roomActorServices,
            roomCreation: roomServices.roomCreationServices,
            liveActivity: liveActivity,
            foregroundGroupEventHints: realtime.foregroundGroupEventHints,
            roomRecovery: roomRecovery,
            accountChanges: frontdoor.connectionRegistry,
            socialRelationships: socialRelationships,
            conversationCapabilities: conversationCapabilities,
            forwardMessages: roomServices.forwardMessages,
            sync: .init(store: V2RoutedSyncStore(
                registry: topology.syncUserShardStorage, routeFence: projection.syncUserShardRouter,
                coLocatedControlBuckets: prepared.coLocatedControlBuckets,
                capabilityProfile: configuration.capabilityProfile,
                // 为 envelope、不透明令牌、回执、代次、能力配置及 protobuf
                // 长度前缀预留有界空间；记录本身的大小按实际值精确计算。
                maximumEncodedRecordsBytes: max(
                    1,
                    configuration.frameLimits.maximumPayloadBytes - 4_096
                )
            )),
            telemetry: ownerMaintenance.telemetry,
            databaseWorkAdmission: configuration.databaseWorkAdmissionEnabled
                ? frontdoor.databaseWorkAdmission
                : nil,
            controlWriteAdmissionEnabled:
                configuration.foregroundControlWriteDatabaseWorkLimit > 0,
            maximumGroupEventPagePayloadBytes: max(
                1,
                configuration.frameLimits.maximumPayloadBytes - 4_096
            )
        )
        return .init(handler: handler, contentReviewWorker: contentReviewWorker)
    }
}
