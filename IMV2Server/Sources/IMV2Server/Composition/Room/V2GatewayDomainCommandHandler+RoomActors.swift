import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ServerGateway

/// 生产网关所需的 RoomRef 能力在组装层聚合，命令处理器仅接收业务接口。
extension V2GatewayDomainCommandHandler {
    /// 生产环境中现有房间调用和创建房间前操作的组合入口。
    /// 用户服务与控制服务保持显式依赖，避免房间能力意外成为用户自有操作的授权依据。
    public init(roomActors: V2GatewayRoomActorServices,
                messageLimits: V2MessageCommandLimits = try! .init(maxUTF8Bytes: 65_536),
                liveActivity: V2LiveActivityService,
                foregroundGroupEventHints: any V2ForegroundGroupEventHintSubmitting,
                roomRecovery: any V2RoomRecoveryCommandHandling,
                accountChanges: any V2AccountRoomChangesStarting,
                conversationCapabilities: any V2GatewayConversationCapabilitiesHandling,
                sync: V2SyncService,
                telemetry: any V2TelemetrySink,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
                databaseFailureIsTransient: @escaping @Sendable (any Error) -> Bool = { _ in false },
                maximumGroupEventPagePayloadBytes: Int = 48 * 1_024,
                now: @escaping @Sendable () -> Date = Date.init,
                monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.init(readReceiptHandler: roomActors.receipts,
                  messageSendOperations: roomActors.messaging,
                  messageLimits: messageLimits,
                  liveActivityHandler: liveActivity,
                  groupEventLogHandler: roomActors.eventLog,
                  foregroundGroupEventHints: foregroundGroupEventHints,
                  membershipDirectoryHandler: roomActors.queries,
                  roomRecovery: roomRecovery,
                  accountChanges: accountChanges,
                  conversationCapabilitiesHandler: conversationCapabilities,
                  groupRolePolicyBaseline: roomActors.queries,
                  sync: sync, telemetry: telemetry,
                  databaseWorkAdmission: databaseWorkAdmission,
                  databaseFailureIsTransient: databaseFailureIsTransient,
                  roomCommandsHostAdmitted: true,
                  maximumGroupEventPagePayloadBytes: maximumGroupEventPagePayloadBytes,
                  now: now, monotonicNow: monotonicNow)
    }

}
