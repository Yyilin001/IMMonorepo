import Foundation

/// 网关背后待处理持久化工作的私有聚合视图。
///
/// 它刻意不包含任何标识、分片标签、提供方名称或由载荷派生的字段，
/// 因此可以安全地从仅回环可达的 Prometheus 监听端点输出。
public protocol V2DurableWorkMetricsSource: Sendable {
    /// 读取当前持久化工作指标快照。
    ///
    /// - Returns: 聚合后的指标快照。
    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot
}

/// 持久化工作指标快照。
public struct V2DurableWorkMetricsSnapshot: Equatable, Sendable {
    /// 本次快照是否由数据源成功产出。
    public private(set) var isAvailable: Bool
    /// 本次快照是否来自上一次成功的完整结果。
    ///
    /// 刷新失败或超时时可以安全地暴露上一次完整的全局快照，
    /// 但绝不能把这些数据当作当前值呈现。
    public private(set) var servedFromLastKnownGood: Bool
    /// 距上次成功刷新经过的秒数。
    public private(set) var lastSuccessfulRefreshAgeSeconds: Int
    /// 处于待处理状态的个人事件队列行数。
    public let readyUserStateEventRows: Int
    /// 已被认领的个人事件队列行数。
    public let leasedUserStateEventRows: Int
    /// 已安排重试的个人事件队列行数。
    public let scheduledUserStateEventRows: Int
    /// 已暂停的个人事件队列行数。
    public let pausedUserStateEventRows: Int
    /// 仍未完成的个人事件队列行中最长的存在秒数。
    ///
    /// 瞬时失败不再进入暂停，因此"暂停行数为零"不能证明投递正在推进；持续重试但永不
    /// 成功的工作只能由该年龄发现。
    public let oldestUnfinishedUserStateEventAgeSeconds: Int
    /// 待处理的资料安全失效数量。
    public let readyProfileSecurityInvalidations: Int
    /// 已被认领的资料安全失效数量。
    public let leasedProfileSecurityInvalidations: Int
    /// 待处理的已读回执偏好传播数量。
    public let readyReadReceiptPreferencePropagations: Int
    /// 已被认领的已读回执偏好传播数量。
    public let leasedReadReceiptPreferencePropagations: Int
    /// 已安排重试的已读回执偏好传播数量。
    public let scheduledReadReceiptPreferencePropagations: Int
    /// 已暂停的已读回执偏好传播数量。
    public let pausedReadReceiptPreferencePropagations: Int
    /// 待处理的内容审核任务数量。
    public let readyContentReviews: Int
    /// 已被认领的内容审核任务数量。
    public let leasedContentReviews: Int
    /// 已安排重试的内容审核任务数量。
    public let scheduledContentReviews: Int
    /// 已暂停的内容审核任务数量。
    public let pausedContentReviews: Int
    /// 待处理的媒体扫描任务数量。
    public let readyMediaScans: Int
    /// 已被认领的媒体扫描任务数量。
    public let leasedMediaScans: Int
    /// 已安排重试的媒体扫描任务数量。
    public let scheduledMediaScans: Int
    /// 已暂停的媒体扫描任务数量。
    public let pausedMediaScans: Int
    /// 待处理的媒体清理任务数量。
    public let readyMediaPurges: Int
    /// 已被认领的媒体清理任务数量。
    public let leasedMediaPurges: Int
    /// 已安排重试的媒体清理任务数量。
    public let scheduledMediaPurges: Int
    /// 已暂停的媒体清理任务数量。
    public let pausedMediaPurges: Int
    /// 用户同步日志行数的 PostgreSQL 规划器估算值。
    ///
    /// 使用估算可避免在每次 Prometheus 抓取时对高写入的保留同步日志执行精确 `COUNT(*)` 扫描。
    public let userSyncLogEstimatedRows: Int
    /// 用户同步日志保留的堆、索引与 TOAST 总字节数。
    ///
    /// 与行数估算不同，这是一次精确的关系大小查询，而不是全表扫描。
    public let userSyncLogRelationBytes: Int
    /// 稳定的控制面投影幂等结果行数估算。
    ///
    /// 这些记录与可压缩的有序日志刻意分开保存，容量规划时必须与承载同一语义重试的
    /// 操作台账一并考虑。
    public let userProjectionEffectsEstimatedRows: Int
    /// 控制面投影幂等结果占用的关系字节数。
    public let userProjectionEffectsRelationBytes: Int
    /// 待处理的用户投影数量。
    public let readyUserProjections: Int
    /// 已安排重试的用户投影数量。
    public let scheduledUserProjections: Int
    /// 已暂停的用户投影数量。
    public let pausedUserProjections: Int
    /// 当前最大的用户投影滞后量。
    public let maximumUserProjectionLag: Int
    /// 正在构建的快照产物数量。
    public let buildingSnapshotArtifacts: Int
    /// 构建失败的快照产物数量。
    public let failedSnapshotArtifacts: Int
    /// 构建中快照产物的最长存在秒数。
    public let oldestBuildingSnapshotAgeSeconds: Int
    /// 投影版本回收的待处理行数估算。
    public let projectionVersionGCBacklogEstimatedRows: Int
    /// 消息投影状态行数估算；使用规划器估算可避免抓取时扫描最大的表。
    public let messageProjectionStatesEstimatedRows: Int
    /// 消息投影状态占用的关系字节数。
    public let messageProjectionStatesRelationBytes: Int
    /// 仍可被同库不可变房间事件精确引用替换的修订 1 已接受状态正文行数估算。
    public let messageProjectionStateInlineBodyEstimatedRows: Int
    /// 尚未压缩的投影记录数量。
    public let uncompactedProjectedRecords: Int
    /// 全部设备上仍未确认的同步记录数量。
    public let pendingSyncRecordsAcrossDevices: Int
    /// 处于重置待处理状态的设备数量。
    public let resetPendingDevices: Int
    /// 待发送的推送唤醒数量。
    public let readyPushWakes: Int
    /// 已被认领的推送唤醒数量。
    public let leasedPushWakes: Int
    /// 已被终态抑制的推送唤醒数量。
    public let suppressedPushWakes: Int
    /// 服务本次私有抓取的网关节点上尚未处理的账号与设备吊销事件数量。
    ///
    /// 该指标刻意不带节点、设备或用户标签，因此抓取结果不会泄漏拓扑或身份信息。
    public let pendingDeviceRevocationEvents: Int
    /// 集群级的存储清理积压。
    ///
    /// 它与套接字关闭分开统计：远端分片不可用只会延迟存储回收，不会延迟连接关闭。
    public let pendingRevokedDeviceProjectionCleanupEvents: Int

    public init(
        isAvailable: Bool,
        servedFromLastKnownGood: Bool = false,
        lastSuccessfulRefreshAgeSeconds: Int = 0,
        readyUserStateEventRows: Int = 0,
        leasedUserStateEventRows: Int = 0,
        scheduledUserStateEventRows: Int = 0,
        pausedUserStateEventRows: Int = 0,
        oldestUnfinishedUserStateEventAgeSeconds: Int = 0,
        readyProfileSecurityInvalidations: Int = 0,
        leasedProfileSecurityInvalidations: Int = 0,
        readyReadReceiptPreferencePropagations: Int = 0,
        leasedReadReceiptPreferencePropagations: Int = 0,
        scheduledReadReceiptPreferencePropagations: Int = 0,
        pausedReadReceiptPreferencePropagations: Int = 0,
        readyContentReviews: Int = 0,
        leasedContentReviews: Int = 0,
        scheduledContentReviews: Int = 0,
        pausedContentReviews: Int = 0,
        readyMediaScans: Int = 0,
        leasedMediaScans: Int = 0,
        scheduledMediaScans: Int = 0,
        pausedMediaScans: Int = 0,
        readyMediaPurges: Int = 0,
        leasedMediaPurges: Int = 0,
        scheduledMediaPurges: Int = 0,
        pausedMediaPurges: Int = 0,
        userSyncLogEstimatedRows: Int = 0,
        userSyncLogRelationBytes: Int = 0,
        userProjectionEffectsEstimatedRows: Int = 0,
        userProjectionEffectsRelationBytes: Int = 0,
        readyUserProjections: Int = 0,
        scheduledUserProjections: Int = 0,
        pausedUserProjections: Int = 0,
        maximumUserProjectionLag: Int = 0,
        buildingSnapshotArtifacts: Int = 0,
        failedSnapshotArtifacts: Int = 0,
        oldestBuildingSnapshotAgeSeconds: Int = 0,
        projectionVersionGCBacklogEstimatedRows: Int = 0,
        messageProjectionStatesEstimatedRows: Int = 0,
        messageProjectionStatesRelationBytes: Int = 0,
        messageProjectionStateInlineBodyEstimatedRows: Int = 0,
        uncompactedProjectedRecords: Int = 0,
        pendingSyncRecordsAcrossDevices: Int = 0,
        resetPendingDevices: Int = 0,
        readyPushWakes: Int = 0,
        leasedPushWakes: Int = 0,
        suppressedPushWakes: Int = 0,
        pendingDeviceRevocationEvents: Int = 0,
        pendingRevokedDeviceProjectionCleanupEvents: Int = 0
    ) {
        self.isAvailable = isAvailable
        self.servedFromLastKnownGood = servedFromLastKnownGood
        self.lastSuccessfulRefreshAgeSeconds = max(0, lastSuccessfulRefreshAgeSeconds)
        self.readyUserStateEventRows = max(0, readyUserStateEventRows)
        self.leasedUserStateEventRows = max(0, leasedUserStateEventRows)
        self.scheduledUserStateEventRows = max(0, scheduledUserStateEventRows)
        self.pausedUserStateEventRows = max(0, pausedUserStateEventRows)
        self.readyProfileSecurityInvalidations = max(0, readyProfileSecurityInvalidations)
        self.leasedProfileSecurityInvalidations = max(0, leasedProfileSecurityInvalidations)
        self.readyReadReceiptPreferencePropagations = max(0, readyReadReceiptPreferencePropagations)
        self.leasedReadReceiptPreferencePropagations = max(0, leasedReadReceiptPreferencePropagations)
        self.scheduledReadReceiptPreferencePropagations = max(0, scheduledReadReceiptPreferencePropagations)
        self.pausedReadReceiptPreferencePropagations = max(0, pausedReadReceiptPreferencePropagations)
        self.oldestUnfinishedUserStateEventAgeSeconds = max(
            0, oldestUnfinishedUserStateEventAgeSeconds
        )
        self.readyContentReviews = max(0, readyContentReviews)
        self.leasedContentReviews = max(0, leasedContentReviews)
        self.scheduledContentReviews = max(0, scheduledContentReviews)
        self.pausedContentReviews = max(0, pausedContentReviews)
        self.readyMediaScans = max(0, readyMediaScans)
        self.leasedMediaScans = max(0, leasedMediaScans)
        self.scheduledMediaScans = max(0, scheduledMediaScans)
        self.pausedMediaScans = max(0, pausedMediaScans)
        self.readyMediaPurges = max(0, readyMediaPurges)
        self.leasedMediaPurges = max(0, leasedMediaPurges)
        self.scheduledMediaPurges = max(0, scheduledMediaPurges)
        self.pausedMediaPurges = max(0, pausedMediaPurges)
        self.userSyncLogEstimatedRows = max(0, userSyncLogEstimatedRows)
        self.userSyncLogRelationBytes = max(0, userSyncLogRelationBytes)
        self.userProjectionEffectsEstimatedRows = max(0, userProjectionEffectsEstimatedRows)
        self.userProjectionEffectsRelationBytes = max(0, userProjectionEffectsRelationBytes)
        self.readyUserProjections = max(0, readyUserProjections)
        self.scheduledUserProjections = max(0, scheduledUserProjections)
        self.pausedUserProjections = max(0, pausedUserProjections)
        self.maximumUserProjectionLag = max(0, maximumUserProjectionLag)
        self.buildingSnapshotArtifacts = max(0, buildingSnapshotArtifacts)
        self.failedSnapshotArtifacts = max(0, failedSnapshotArtifacts)
        self.oldestBuildingSnapshotAgeSeconds = max(0, oldestBuildingSnapshotAgeSeconds)
        self.projectionVersionGCBacklogEstimatedRows = max(0, projectionVersionGCBacklogEstimatedRows)
        self.messageProjectionStatesEstimatedRows = max(0, messageProjectionStatesEstimatedRows)
        self.messageProjectionStatesRelationBytes = max(0, messageProjectionStatesRelationBytes)
        self.messageProjectionStateInlineBodyEstimatedRows = max(
            0, messageProjectionStateInlineBodyEstimatedRows
        )
        self.uncompactedProjectedRecords = max(0, uncompactedProjectedRecords)
        self.pendingSyncRecordsAcrossDevices = max(0, pendingSyncRecordsAcrossDevices)
        self.resetPendingDevices = max(0, resetPendingDevices)
        self.readyPushWakes = max(0, readyPushWakes)
        self.leasedPushWakes = max(0, leasedPushWakes)
        self.suppressedPushWakes = max(0, suppressedPushWakes)
        self.pendingDeviceRevocationEvents = max(0, pendingDeviceRevocationEvents)
        self.pendingRevokedDeviceProjectionCleanupEvents = max(
            0,
            pendingRevokedDeviceProjectionCleanupEvents
        )
    }

    public static let unavailable = Self(isAvailable: false)

    package func reportingUnavailable(lastSuccessfulRefreshAgeSeconds: Int?) -> Self {
        var copy = self
        copy.isAvailable = false
        copy.servedFromLastKnownGood = lastSuccessfulRefreshAgeSeconds != nil
        copy.lastSuccessfulRefreshAgeSeconds = max(0, lastSuccessfulRefreshAgeSeconds ?? 0)
        return copy
    }
}
