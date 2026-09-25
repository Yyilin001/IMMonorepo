import Foundation
import IMV2Server

/// 将前台唤醒接到本地或 NATS，并把提示观察者安装到提交后事件流。
/// 本阶段不执行可抛出操作；调用方持有返回的 Broker，负责失败回滚和最终关闭。
struct GatewayRealtimeAssembly {
    let groupEventWakePublisher: any V2GroupEventWakePublishing
    let foregroundGroupEventHints: V2ForegroundGroupEventHintDispatcher
    let natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
    let sharedGroupWakeInterests: V2SharedGroupEventWakeInterests?
    let natsLiveActivityBroker: V2NATSLiveActivityBroker?

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        prepared: GatewayPreparedAssembly,
        roomServices: GatewayRoomServicesAssembly
    ) async -> Self {
        let connectionRegistry = prepared.frontdoor.connectionRegistry
        let groupEventLog = roomServices.groupEventLog
        let transportMetrics = prepared.frontdoor.transportMetrics
        let committedHybridGroupEvents = prepared.roomOwners.committedHybridGroupEvents
        var natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
        var sharedGroupWakeInterests: V2SharedGroupEventWakeInterests?
        var natsLiveActivityBroker: V2NATSLiveActivityBroker?
        // 前台可用性仅作为尽力而为的提示。
        // 同一个 Broker 适配器也服务于持久 Hybrid 唤醒 outbox，
        // 但两者在命令处理器边界仍遵循不同合同。
        let groupEventWakePublisher: any V2GroupEventWakePublishing
        let foregroundGroupEventHintPublisher: any V2ForegroundGroupEventHintPublishing
        switch configuration.groupEventWake {
        case .localOnly:
            let publisher = V2LocalGroupEventWakePublisher(registry: connectionRegistry)
            groupEventWakePublisher = publisher
            foregroundGroupEventHintPublisher = publisher
        case .nats(let nats):
            let broker = V2NATSGroupEventWakeBroker(
                configuration: nats,
                recordRecoveryNotification: { notification in
                    switch notification {
                    case .wake:
                        break
                    case .directEvent(let event):
                        groupEventLog.recordRelayedForegroundEvents([event])
                    case .groupEvents(let events):
                        groupEventLog.recordRelayedForegroundEvents(events)
                    }
                },
                metrics: transportMetrics,
                coverageLost: { [weak connectionRegistry] in
                    await connectionRegistry?.invalidateAccountRoomCoverage()
                },
                receiveWake: { [weak connectionRegistry] notification in
                    switch notification {
                    case .wake(let wake):
                        await connectionRegistry?.notifyForegroundGroupAvailable(
                            roomID: wake.roomID,
                            highWatermark: wake.highWatermark
                        )
                    case .directEvent(let event):
                        await connectionRegistry?.notifyForegroundDirectEvent(event)
                    case .groupEvents(let events):
                        await connectionRegistry?.notifyForegroundGroupEvents(events)
                    }
                }
            )
            natsGroupWakeBroker = broker
            let interests = V2SharedGroupEventWakeInterests(underlying: broker)
            sharedGroupWakeInterests = interests
            await connectionRegistry.configureForegroundGroupInterestManager(interests.manager(for: .foreground))
            let liveActivityBroker = V2NATSLiveActivityBroker(
                configuration: nats,
                receivePresence: { [weak connectionRegistry] userID, isOnline, expiresAt in
                    await connectionRegistry?.receivePresence(
                        targetUserID: userID,
                        isOnline: isOnline,
                        expiresAt: expiresAt
                    )
                },
                receiveTyping: { [weak connectionRegistry] state in
                    await connectionRegistry?.receiveTyping(state)
                }
            )
            natsLiveActivityBroker = liveActivityBroker
            await connectionRegistry.configureLiveActivityBroker(liveActivityBroker)
            groupEventWakePublisher = broker
            foregroundGroupEventHintPublisher = broker
        }
        let foregroundGroupEventHints = V2ForegroundGroupEventHintDispatcher(
            publisher: foregroundGroupEventHintPublisher,
            maximumGroupEventsPerBatch:
                configuration.foregroundGroupBatchMaximumEvents,
            maximumPendingGroupEventsPerRoom:
                configuration.foregroundGroupPendingMaximumEventsPerRoom,
            groupBatchDelay: .milliseconds(
                configuration.foregroundGroupBatchDelayMilliseconds
            ),
            groupBatchExtensionDelay: .milliseconds(
                configuration.foregroundGroupBatchExtensionDelayMilliseconds
            ),
            groupBatchExtensionMinimumEvents:
                configuration.foregroundGroupBatchExtensionMinimumEvents,
            metrics: transportMetrics
        )
        committedHybridGroupEvents.install(sink: foregroundGroupEventHints)
        return .init(
            groupEventWakePublisher: groupEventWakePublisher,
            foregroundGroupEventHints: foregroundGroupEventHints,
            natsGroupWakeBroker: natsGroupWakeBroker,
            sharedGroupWakeInterests: sharedGroupWakeInterests,
            natsLiveActivityBroker: natsLiveActivityBroker
        )
    }
}
