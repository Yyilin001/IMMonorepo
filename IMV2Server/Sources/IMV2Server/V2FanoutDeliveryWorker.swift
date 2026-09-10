import Foundation
import IMV2Core

/// 扇出投递租约。
///
/// 「已投递」的含义是完成了一次持久化且幂等的用户同步投影；
/// 套接字或推送唤醒都只是下游提示，不能决定某个扇出目标是否算已投递。
public struct V2FanoutDeliveryLease: Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 目标用户。
    public let targetUserID: UserID
    /// 投影类型标识。
    public let projectionKind: String
    /// 所属完成单元。
    public let completionUnitID: CompletionUnitID
    /// 认领时观察到的用户归属路由。
    public let observedRoute: V2UserShardRoute
    /// 本次租约的认领令牌。
    public let claimToken: UUID
    /// 本次是第几次尝试。
    public let attempt: Int
    /// 不可变来源事件载荷的进程内副本。
    ///
    /// 只有跨库认领路径会填充它，以避免在目标投影之前再次访问控制库。
    /// 持久化租约栅栏仍是认领令牌；该值绝不会作为租约状态被持久化，
    /// 未携带它的调用方会改为在栅栏保护下读取控制面存储。
    public let eventPayloadJSON: String?

    /// 校验并保存投递租约。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - targetUserID: 目标用户。
    ///   - projectionKind: 投影类型标识。
    ///   - completionUnitID: 所属完成单元。
    ///   - observedRoute: 认领时观察到的用户归属。
    ///   - claimToken: 认领令牌。
    ///   - attempt: 尝试次数，需大于零。
    ///   - eventPayloadJSON: 可选的进程内载荷副本。
    ///
    /// 尝试次数非正时直接失败，避免重试退避从非法状态开始。
    public init(sourceEventID: EventID, targetUserID: UserID, projectionKind: String, completionUnitID: CompletionUnitID, observedRoute: V2UserShardRoute, claimToken: UUID, attempt: Int = 1, eventPayloadJSON: String? = nil) {
        precondition(attempt > 0)
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
        self.completionUnitID = completionUnitID
        self.observedRoute = observedRoute
        self.claimToken = claimToken
        self.attempt = attempt
        self.eventPayloadJSON = eventPayloadJSON
    }
}

/// 一次投递终结的结果。
public enum V2FanoutDeliveryCommit: Equatable, Sendable {
    /// 租约已失效，本次终结未生效。
    case staleLease
    /// 投递行已被迁移到新的归属。
    ///
    /// 目标投影可能已在旧的物理归属上提交，但控制面路由栅栏在终结之前观察到了更新的写入归属；
    /// 同一持久化投递行已被移动到新归属并释放，以便幂等重放。
    case rerouted(V2UserShardRoute)
    /// 已提交，并给出版本序号与容量释放情况。
    case committed(userSyncSequence: UInt64, releasedCompletionUnit: Bool, closedPlan: Bool)
}

/// 持久化投递工作的互斥类别。
///
/// 保持类别分离可以让热路径使用只针对全新工作的索引，
/// 同时不削弱重试、租约过期恢复与认领令牌栅栏的语义。
public enum V2FanoutDeliveryClaimLane: Sendable, Equatable {
    /// 从未被认领，也从未安排过重试。
    case fresh
    /// 失败后被显式释放，现已到下一次尝试时间。
    case retryDue
    /// 先前的工作器停止推进，其租约已过期。
    case expiredLease
}

/// 单次并发认领中的一份稳定份额。
///
/// 所有投递通道都会把同一目标用户分配到同一分区，使工作器不会在该用户的单调同步序号行上争用。
/// 即使之后进程并发度或副本数量变化，持久化行锁与咨询锁仍能保证正确性。
public struct V2FanoutDeliveryClaimPartition: Sendable, Equatable {
    public let index: Int
    public let count: Int

    public init(index: Int, count: Int) {
        precondition(count > 0 && index >= 0 && index < count)
        self.index = index
        self.count = count
    }
}

/// 扇出投递的持久化能力。
public protocol V2FanoutDeliveryStore: Sendable {
    /// 认领一批待投递工作。
    ///
    /// - Parameters:
    ///   - bucket: 可选的物理桶过滤。
    ///   - lane: 工作类别。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 认领到的投递租约。
    /// - Throws: 持久化失败时抛出。
    func claimPending(bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease]

    /// 终结单条租约。
    ///
    /// - Parameters:
    ///   - lease: 本次投递租约。
    ///   - now: 终结时刻。
    /// - Returns: 终结结果。
    /// - Throws: 持久化失败时抛出。
    func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit

    /// 终结一个有界的租约分组。
    ///
    /// 若实现拥有全部受影响记录所在的数据库，可以把整批放在一个事务内；
    /// 跨存储实现可以保留逐条终结，因为它无法在物理数据库之间凭空创造原子性。
    ///
    /// - Parameters:
    ///   - leases: 本批租约。
    ///   - now: 终结时刻。
    /// - Returns: 与输入顺序对应的终结结果。
    /// - Throws: 持久化失败时抛出。
    func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) async throws -> [V2FanoutDeliveryCommit]

    /// 把已认领但尚未投影的投递移交给路由当前的逻辑写入桶。
    ///
    /// 实现必须用租约令牌为这次更新加栅栏；它只是同一个持久化收件箱效果的移交，
    /// 绝不构成第二次投递，也不构成终态跳过。
    ///
    /// - Parameters:
    ///   - lease: 本次投递租约。
    ///   - route: 目标用户归属。
    /// - Throws: 栅栏不匹配或持久化失败时抛出。
    func handoff(_ lease: V2FanoutDeliveryLease, to route: V2UserShardRoute) async throws

    /// 释放租约以便重试。
    ///
    /// - Parameter lease: 本次投递租约。
    /// - Throws: 持久化失败时抛出。
    func release(_ lease: V2FanoutDeliveryLease) async throws
    func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// 可选的认领能力，使并发投递工作器的处理范围互不相交。
///
/// 各通道按目标用户分区，因此同一用户单调同步序号的所有写入者都落在同一通道。
/// 其他存储仍保留原有的带栅栏 `SKIP LOCKED` 认领语义。
public protocol V2PartitionedFanoutDeliveryStore: V2FanoutDeliveryStore {
    /// 在指定分区内认领一批投递。
    ///
    /// - Parameters:
    ///   - bucket: 可选的物理桶过滤。
    ///   - lane: 工作类别。
    ///   - partition: 本工作器负责的分区。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 认领到的投递租约。
    /// - Throws: 持久化失败时抛出。
    func claimPending(
        bucket: String?, lane: V2FanoutDeliveryClaimLane,
        partition: V2FanoutDeliveryClaimPartition,
        now: Date, leaseDuration: TimeInterval, limit: Int
    ) async throws -> [V2FanoutDeliveryLease]
}

/// 面向全新私聊消息工作的可选同库快速路径。
///
/// 存储会在单个事务内完成加锁、投影与终结，而不先持久化租约更新。
/// 重试类与租约过期类行仍走普通认领令牌协议，因此故障恢复保持相同的持久化语义。
public protocol V2FreshDirectFanoutDeliveryStore: V2FanoutDeliveryStore {
    /// 直接处理一批已预规划的全新私聊投递。
    ///
    /// - Parameters:
    ///   - bucket: 可选的物理桶过滤。
    ///   - partition: 可选的分区。
    ///   - now: 本次处理时刻。
    ///   - limit: 本次最多处理的数量。
    /// - Returns: 本批处理结果。
    /// - Throws: 事务失败时抛出。
    func commitFreshDirectPreplanned(
        bucket: String?, partition: V2FanoutDeliveryClaimPartition?,
        now: Date, limit: Int
    ) async throws -> [V2FreshDirectFanoutDeliveryCommit]
    /// 把快速路径中失败的无租约行转换为普通持久化租约。
    ///
    /// 只有原子快速路径抛出异常之后才会调用；因此常规的通用全新工作扫描可以把私聊行排除在外，
    /// 使用其用户通道部分索引，而不会让问题工作项永久滞留。
    ///
    /// - Parameters:
    ///   - bucket: 可选的物理桶过滤。
    ///   - partition: 可选的分区。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 转换后的普通租约。
    /// - Throws: 持久化失败时抛出。
    func claimFreshDirectPreplannedForRecovery(
        bucket: String?, partition: V2FanoutDeliveryClaimPartition?,
        now: Date, leaseDuration: TimeInterval, limit: Int
    ) async throws -> [V2FanoutDeliveryLease]
}

public extension V2FreshDirectFanoutDeliveryStore {
    /// 默认不提供恢复转换能力，返回空结果。
    ///
    /// - Returns: 空数组。
    func claimFreshDirectPreplannedForRecovery(
        bucket _: String?, partition _: V2FanoutDeliveryClaimPartition?,
        now _: Date, leaseDuration _: TimeInterval, limit _: Int
    ) async throws -> [V2FanoutDeliveryLease] {
        []
    }
}

/// 全新私聊投递的直接处理结果。
public struct V2FreshDirectFanoutDeliveryCommit: Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 目标用户。
    public let targetUserID: UserID
    /// 写入的用户同步序号。
    public let userSyncSequence: UInt64

    /// 保存处理结果。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - targetUserID: 目标用户。
    ///   - userSyncSequence: 用户同步序号，需大于零。
    ///
    /// 序号非正时直接失败，避免产生无效的同步位置。
    public init(
        sourceEventID: EventID, targetUserID: UserID,
        userSyncSequence: UInt64
    ) {
        precondition(userSyncSequence > 0)
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.userSyncSequence = userSyncSequence
    }
}

/// 面向单个逻辑桶并发认领的可选拓扑上限。
///
/// 流水线的全局投递并发是容量上限，并不代表可以在单个物理目标库内制造争用。
/// 未声明上限的存储使用全局上限。
public protocol V2FanoutDeliveryBucketConcurrencyControlling: Sendable {
    /// 单逻辑桶允许的最大并发认领数。
    var maximumConcurrentClaimsPerBucket: Int { get }
}

/// 为单个逻辑目标桶分配认领轮次的调度器。
///
/// 默认在七次快速路径轮次之后安排一次恢复优先轮次。若首选通道为空，
/// 工作器会立即穿透到其他通道；若其繁忙，每轮仍只认领一个通道，
/// 从而保持有界事务与其全有或全无的租约更新。
public actor V2FanoutDeliveryClaimScheduler {
    private let freshBurstPasses: Int
    private var freshPassesSinceRecovery = 0
    private var nextRecoveryLane: V2FanoutDeliveryClaimLane = .retryDue

    /// 组合快速路径轮次数量。
    ///
    /// - Parameter freshBurstPasses: 快速路径连续轮次，需大于零，默认 7。
    ///
    /// 取值非正时直接失败，避免调度器出现无界偏好。
    public init(freshBurstPasses: Int = 7) {
        precondition(freshBurstPasses > 0)
        self.freshBurstPasses = freshBurstPasses
    }

    /// 给出下一轮认领的通道顺序。
    ///
    /// - Returns: 依次尝试的通道列表，首选为空时会穿透到后续通道。
    public func lanesForNextClaim() -> [V2FanoutDeliveryClaimLane] {
        if freshPassesSinceRecovery < freshBurstPasses {
            freshPassesSinceRecovery += 1
            return [.fresh, nextRecoveryLane, alternateRecoveryLane]
        }

        freshPassesSinceRecovery = 0
        let recoveryLane = nextRecoveryLane
        let otherRecoveryLane = alternateRecoveryLane
        nextRecoveryLane = otherRecoveryLane
        return [recoveryLane, otherRecoveryLane, .fresh]
    }

    private var alternateRecoveryLane: V2FanoutDeliveryClaimLane {
        nextRecoveryLane == .retryDue ? .expiredLease : .retryDue
    }
}

public protocol V2LiveSyncNotifier: Sendable {
    func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) async
}

/// 单轮扇出投递统计。
public struct V2FanoutDeliveryReport: Equatable, Sendable {
    /// 本轮认领数量。
    public let claimedCount: Int
    /// 已提交数量。
    public let committedCount: Int
    /// 因租约失效而放弃的数量。
    public let staleCount: Int
    /// 因归属迁移而重新路由的数量。
    public let staleRouteCount: Int
    /// 安排重试的数量。
    public let releasedCount: Int
    /// 暂停等待运维处理的数量。
    public let pausedCount: Int

    /// 保存投递统计。
    ///
    /// - Parameters:
    ///   - claimedCount: 认领数量。
    ///   - committedCount: 提交数量。
    ///   - staleCount: 失效数量。
    ///   - staleRouteCount: 重新路由数量，默认零。
    ///   - releasedCount: 安排重试数量。
    ///   - pausedCount: 暂停数量，默认零。
    public init(claimedCount: Int, committedCount: Int, staleCount: Int, staleRouteCount: Int = 0, releasedCount: Int, pausedCount: Int = 0) {
        self.claimedCount = claimedCount
        self.committedCount = committedCount
        self.staleCount = staleCount
        self.staleRouteCount = staleRouteCount
        self.releasedCount = releasedCount
        self.pausedCount = pausedCount
    }
}

/// 用户归属解析能力。
///
/// 投递前需要把租约中观察到的归属与路由当前结果比对，用于判断是否需要移交。
protocol V2FanoutDeliveryRouteResolving: Sendable {
    /// 解析一批租约对应的当前用户归属。
    ///
    /// - Parameter leases: 本批投递租约。
    /// - Returns: 与输入顺序对应的用户归属。
    /// - Throws: 路由解析失败时抛出。
    func routes(for leases: [V2FanoutDeliveryLease]) async throws -> [V2UserShardRoute]
}

private struct V2UserShardFanoutDeliveryRouteResolver: V2FanoutDeliveryRouteResolving {
    let router: any V2UserShardRouter

    func routes(for leases: [V2FanoutDeliveryLease]) async throws -> [V2UserShardRoute] {
        try await router.routes(for: leases.map(\.targetUserID))
    }
}

/// 有界、由调用方调度的投递工作器。
///
/// 它刻意按顺序处理：数据库租约争用就是背压边界，部署方通过桶归属与工作器副本数量
/// 来控制并行度。批处理失败隔离阈值用于在成员达到指定尝试次数后二分拆解批次，
/// 从而在保留瞬时故障原有重试单位的同时隔离确定性毒点记录。
public struct V2FanoutDeliveryWorker: Sendable {
    private let store: any V2FanoutDeliveryStore
    private let bucket: String?
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let liveNotifier: (any V2LiveSyncNotifier)?
    private let routeResolver: any V2FanoutDeliveryRouteResolving
    private let retryPolicy: V2DurableRetryPolicy
    private let claimScheduler: V2FanoutDeliveryClaimScheduler
    private let commitBatchSize: Int
    /// 触发批次失败隔离的尝试次数。
    ///
    /// 一旦任一成员达到该尝试次数，原子批次失败就会被二分，
    /// 直到健康子批次可以提交、并隔离出一条确定性的毒丸记录。
    /// 更早的失败仍保留原本的整批重试单元，
    /// 使瞬时数据库错误不会立刻放大事务数量。
    private let batchFailureIsolationAttempt: Int
    /// 单个桶允许的并发提交批次数，通常为一。
    ///
    /// 持久批次的完整目标/控制协议保持串行，除非远端拓扑启用了实测过的两批重叠。
    /// 结果处理仍按来源批次顺序进行，每个失败批次保留其原有的全有或全无重试单元。
    private let maximumConcurrentCommitBatches: Int

    var maximumConcurrentClaimsPerBucket: Int {
        guard let control = store as? any V2FanoutDeliveryBucketConcurrencyControlling else {
            return .max
        }
        return max(1, control.maximumConcurrentClaimsPerBucket)
    }

    public init(
        store: any V2FanoutDeliveryStore,
        bucket: String? = nil,
        leaseDuration: TimeInterval = 30,
        liveNotifier: (any V2LiveSyncNotifier)? = nil,
        router: any V2UserShardRouter,
        retryPolicy: V2DurableRetryPolicy = .standard,
        claimScheduler: V2FanoutDeliveryClaimScheduler = .init(),
        commitBatchSize: Int = 128,
        batchFailureIsolationAttempt: Int = 2,
        maximumConcurrentCommitBatches: Int = 1,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            store: store,
            bucket: bucket,
            leaseDuration: leaseDuration,
            liveNotifier: liveNotifier,
            routeResolver: V2UserShardFanoutDeliveryRouteResolver(router: router),
            retryPolicy: retryPolicy,
            claimScheduler: claimScheduler,
            commitBatchSize: commitBatchSize,
            batchFailureIsolationAttempt: batchFailureIsolationAttempt,
            maximumConcurrentCommitBatches: maximumConcurrentCommitBatches,
            now: now
        )
    }

    init(
        store: any V2FanoutDeliveryStore,
        bucket: String? = nil,
        leaseDuration: TimeInterval = 30,
        liveNotifier: (any V2LiveSyncNotifier)? = nil,
        routeResolver: any V2FanoutDeliveryRouteResolving,
        retryPolicy: V2DurableRetryPolicy = .standard,
        claimScheduler: V2FanoutDeliveryClaimScheduler = .init(),
        commitBatchSize: Int = 128,
        batchFailureIsolationAttempt: Int = 2,
        maximumConcurrentCommitBatches: Int = 1,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(
            leaseDuration > 0 && commitBatchSize > 0 &&
                batchFailureIsolationAttempt > 0 &&
                (1...2).contains(maximumConcurrentCommitBatches)
        )
        self.store = store
        self.bucket = bucket
        self.leaseDuration = leaseDuration
        self.liveNotifier = liveNotifier
        self.routeResolver = routeResolver
        self.retryPolicy = retryPolicy
        self.claimScheduler = claimScheduler
        self.commitBatchSize = commitBatchSize
        self.batchFailureIsolationAttempt = batchFailureIsolationAttempt
        self.maximumConcurrentCommitBatches = maximumConcurrentCommitBatches
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2FanoutDeliveryReport {
        try await runOnce(limit: limit, claimPartition: nil)
    }

    func runOnce(
        limit: Int,
        claimPartition: V2FanoutDeliveryClaimPartition
    ) async throws -> V2FanoutDeliveryReport {
        try await runOnce(limit: limit, claimPartition: Optional(claimPartition))
    }

    private func runOnce(
        limit: Int,
        claimPartition: V2FanoutDeliveryClaimPartition?
    ) async throws -> V2FanoutDeliveryReport {
        precondition(limit > 0)
        try Task.checkCancellation()
        let claimTime = now()
        let scheduledLanes = await claimScheduler.lanesForNextClaim()
        var freshDirectError: (any Error)?
        var leases: [V2FanoutDeliveryLease] = []
        for lane in scheduledLanes {
            try Task.checkCancellation()
            if lane == .fresh,
               let freshDirectStore = store as? any V2FreshDirectFanoutDeliveryStore {
                do {
                    let commits = try await freshDirectStore.commitFreshDirectPreplanned(
                        bucket: bucket, partition: claimPartition,
                        // Keep the lock/WAL/rollback boundary identical to a
                        // co-located generic commit batch. The claim limit is
                        // allowed to be larger because generic work splits it
                        // below; the one-transaction fast path must not
                        // silently bypass that deployment safety bound.
                        now: claimTime, limit: min(limit, commitBatchSize)
                    )
                    if !commits.isEmpty {
                        for commit in commits {
                            try Task.checkCancellation()
                            await liveNotifier?.notifySyncAvailable(
                                userID: commit.targetUserID,
                                eventID: commit.userSyncSequence,
                                highWatermark: commit.userSyncSequence
                            )
                        }
                        return .init(
                            claimedCount: commits.count,
                            committedCount: commits.count,
                            staleCount: 0,
                            releasedCount: 0
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Fall through to the lease-fenced path. A deterministic
                    // bad row then consumes retry policy and eventually pauses
                    // instead of becoming an unmetered fast-path poison loop.
                    freshDirectError = error
                    do {
                        leases = try await freshDirectStore
                            .claimFreshDirectPreplannedForRecovery(
                                bucket: bucket, partition: claimPartition,
                                now: claimTime, leaseDuration: leaseDuration,
                                limit: limit
                        )
                        if !leases.isEmpty { break }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        freshDirectError = error
                    }
                }
            }
            if let claimPartition,
               let partitionedStore = store as? any V2PartitionedFanoutDeliveryStore {
                leases = try await partitionedStore.claimPending(
                    bucket: bucket, lane: lane, partition: claimPartition,
                    now: claimTime, leaseDuration: leaseDuration, limit: limit
                )
            } else {
                leases = try await store.claimPending(
                    bucket: bucket, lane: lane, now: claimTime,
                    leaseDuration: leaseDuration, limit: limit
                )
            }
            if !leases.isEmpty { break }
        }
        if leases.isEmpty, let freshDirectError { throw freshDirectError }
        var committed = 0
        var stale = 0
        var staleRoute = 0
        var released = 0
        var paused = 0
        var committableLeases: [V2FanoutDeliveryLease] = []
        if !leases.isEmpty {
            do {
                // Route the complete bounded claim together. This preserves
                // the exact epoch check per lease while replacing an N+1
                // control-plane read with one ordered batch lookup.
                let routes = try await routeResolver.routes(for: leases)
                guard routes.count == leases.count else { throw V2UserShardRouterError.resultCountMismatch }
                for (lease, route) in zip(leases, routes) {
                    guard route.writeIdentity != lease.observedRoute.writeIdentity else {
                        committableLeases.append(lease)
                        continue
                    }
                    // Do not write an inbox effect through a route created
                    // under a stale router epoch. Persist one fenced handoff
                    // to the current logical write owner; the new bucket then
                    // claims the same delivery and its inbox uniqueness key
                    // remains unchanged.
                    do {
                        try await store.handoff(lease, to: route)
                        staleRoute += 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A handoff is a per-lease durable update. Keep the
                        // other leases on the already acquired route snapshot
                        // and retry only this fenced row on a later claim.
                        let outcome = try await scheduleRetry(for: [lease])
                        released += outcome.released
                        paused += outcome.paused
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed route lookup yields no trustworthy snapshot, so
                // retry the complete bounded claim instead of using a mixed
                // generation of routing facts.
                let outcome = try await scheduleRetry(for: leases)
                released += outcome.released
                paused += outcome.paused
            }
        }
        let batches = committableLeases.chunked(into: commitBatchSize)
        for windowStart in stride(from: 0, to: batches.count, by: maximumConcurrentCommitBatches) {
            try Task.checkCancellation()
            let windowEnd = Swift.min(windowStart + maximumConcurrentCommitBatches, batches.count)
            let attempts = try await withThrowingTaskGroup(of: V2FanoutBatchCommitAttempt.self, returning: [V2FanoutBatchCommitAttempt].self) { group in
                for index in windowStart..<windowEnd {
                    let batch = batches[index]
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            let commits = try await self.store.commitBatch(batch, now: self.now())
                            guard commits.count == batch.count else {
                                return .init(index: index, commits: nil)
                            }
                            return .init(index: index, commits: commits)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try Task.checkCancellation()
                            return .init(index: index, commits: nil)
                        }
                    }
                }
                var collected: [V2FanoutBatchCommitAttempt] = []
                for try await attempt in group { collected.append(attempt) }
                return collected
            }
            for attempt in attempts.sorted(by: { $0.index < $1.index }) {
                let batch = batches[attempt.index]
                guard let commits = attempt.commits else {
                    if shouldIsolateFailedBatch(batch) {
                        // The complete batch has already failed in this pass;
                        // start with its halves instead of immediately issuing
                        // the same known-failing transaction again.
                        let resolutions = try await splitOrFail(batch)
                        for resolution in resolutions {
                            guard let isolatedCommits = resolution.commits else {
                                let outcome = try await scheduleRetry(for: resolution.leases)
                                released += outcome.released
                                paused += outcome.paused
                                continue
                            }
                            for (lease, commit) in zip(resolution.leases, isolatedCommits) {
                                try Task.checkCancellation()
                                switch commit {
                                case .staleLease: stale += 1
                                case .rerouted: staleRoute += 1
                                case .committed(let sequence, _, _):
                                    committed += 1
                                    await liveNotifier?.notifySyncAvailable(
                                        userID: lease.targetUserID,
                                        eventID: sequence,
                                        highWatermark: sequence
                                    )
                                }
                            }
                        }
                    } else {
                        // A native batch transaction has rolled every member
                        // back. Preserve that unit on an early/transient
                        // failure; the inbox uniqueness key remains the final
                        // idempotency fence for a cross-store fallback that
                        // may already have projected a target.
                        let outcome = try await scheduleRetry(for: batch)
                        released += outcome.released
                        paused += outcome.paused
                    }
                    continue
                }
                for (lease, commit) in zip(batch, commits) {
                    try Task.checkCancellation()
                    switch commit {
                    case .staleLease: stale += 1
                    case .rerouted:
                        staleRoute += 1
                    case .committed(let sequence, _, _):
                        committed += 1
                        await liveNotifier?.notifySyncAvailable(userID: lease.targetUserID, eventID: sequence, highWatermark: sequence)
                    }
                }
            }
        }
        return .init(claimedCount: leases.count, committedCount: committed, staleCount: stale, staleRouteCount: staleRoute, releasedCount: released, pausedCount: paused)
    }

    private func scheduleRetry(for leases: [V2FanoutDeliveryLease]) async throws -> (released: Int, paused: Int) {
        try Task.checkCancellation()
        var released = 0
        var paused = 0
        let failureTime = now()
        for lease in leases {
            try Task.checkCancellation()
            let disposition = retryPolicy.disposition(attempt: lease.attempt, claimToken: lease.claimToken, now: failureTime)
            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failureTime, retryAt) {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
            switch disposition {
            case .retry: released += 1
            case .pause: paused += 1
            }
        }
        return (released, paused)
    }

    private func shouldIsolateFailedBatch(_ leases: [V2FanoutDeliveryLease]) -> Bool {
        leases.count > 1 && leases.contains { $0.attempt >= batchFailureIsolationAttempt }
    }

    /// 隔离失败的原子批次。
    ///
    /// 调用方只有在原始原子批次失败后才会来到这里。因此每个成功的子批次都可以安全终结；
    /// 失败的单条记录仍沿用普通的持久重试/暂停策略。
    /// 跨存储实现同样安全，因为投影与收件箱写入都由既有的投递身份幂等地围栏保护。
    ///
    /// - Parameter leases: 原始批次中待隔离的投递租约。
    /// - Returns: 各子批次对应的提交结论。
    /// - Throws: 取消或持久化失败时抛出。
    private func isolateFailedBatch(
        _ leases: [V2FanoutDeliveryLease]
    ) async throws -> [V2FanoutBatchCommitResolution] {
        try Task.checkCancellation()
        do {
            let commits = try await store.commitBatch(leases, now: now())
            guard commits.count == leases.count else {
                return try await splitOrFail(leases)
            }
            return [.init(leases: leases, commits: commits)]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await splitOrFail(leases)
        }
    }

    private func splitOrFail(
        _ leases: [V2FanoutDeliveryLease]
    ) async throws -> [V2FanoutBatchCommitResolution] {
        guard leases.count > 1 else {
            return [.init(leases: leases, commits: nil)]
        }
        let splitIndex = leases.count / 2
        let left = Array(leases[..<splitIndex])
        let right = Array(leases[splitIndex...])
        let leftResults = try await isolateFailedBatch(left)
        let rightResults = try await isolateFailedBatch(right)
        return leftResults + rightResults
    }
}

private struct V2FanoutBatchCommitAttempt: Sendable {
    let index: Int
    let commits: [V2FanoutDeliveryCommit]?
}

private struct V2FanoutBatchCommitResolution: Sendable {
    let leases: [V2FanoutDeliveryLease]
    let commits: [V2FanoutDeliveryCommit]?
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}
