import Foundation
import IMV2Core

/// 发件箱发布的最小载荷。
///
/// 规划器会重新从 PostgreSQL 读取全部持久化扇出细节；传输层的提示从不构成权威数据。
public struct V2FanoutPlanTrigger: Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 扇出计划标识。
    public let planID: FanoutPlanID

    /// 保存扇出触发。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - planID: 扇出计划标识。
    public init(sourceEventID: EventID, planID: FanoutPlanID) {
        self.sourceEventID = sourceEventID
        self.planID = planID
    }
}

/// 一条发件箱租约。
public struct V2OutboxLease: Equatable, Sendable {
    /// 本次待处理的扇出触发。
    public let trigger: V2FanoutPlanTrigger
    /// 本次租约的认领令牌。
    public let claimToken: UUID
    /// 本次是第几次尝试。
    public let attempt: Int

    /// 构造发件箱租约。
    ///
    /// - Parameters:
    ///   - trigger: 扇出触发。
    ///   - claimToken: 认领令牌。
    ///   - attempt: 尝试次数，需大于零。
    ///
    /// 尝试次数非正时直接失败，避免重试退避从非法状态开始。
    public init(trigger: V2FanoutPlanTrigger, claimToken: UUID, attempt: Int = 1) {
        precondition(attempt > 0)
        self.trigger = trigger
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

/// 房间发件箱的持久化能力。
public protocol V2RoomOutboxStore: Sendable {
    /// 认领一批待发布的发件箱条目。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的条数。
    /// - Returns: 认领到的租约。
    /// - Throws: 持久化失败时抛出。
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2OutboxLease]

    /// 标记单条租约已发布。
    ///
    /// - Parameter lease: 本次租约。
    /// - Throws: 持久化失败时抛出。
    func markPublished(_ lease: V2OutboxLease) async throws

    /// 立即释放租约以便重试。
    ///
    /// - Parameter lease: 本次租约。
    /// - Throws: 持久化失败时抛出。
    func release(_ lease: V2OutboxLease) async throws

    /// 按处置结果安排重试或暂停。
    ///
    /// - Parameters:
    ///   - lease: 本次租约。
    ///   - disposition: 下一步处置。
    ///   - now: 记录时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleRetry(_ lease: V2OutboxLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// 可选的持久化特化能力，用于所有租约都能被单条集合语句栅栏并终结的场景。
///
/// 标量协议仍是其他存储实现的兼容与恢复边界。
public protocol V2BatchRoomOutboxStore: V2RoomOutboxStore {
    /// 在一批租约上执行集合式标记发布。
    ///
    /// - Parameter leases: 本批租约。
    /// - Throws: 持久化失败时抛出。
    func markPublished(_ leases: [V2OutboxLease]) async throws
}

/// 扇出计划发布能力。
///
/// NATS 只是其中一种实现；保留协议形式使「至少一次」契约可被测试，也便于提供本地确定性适配器。
public protocol V2FanoutPlanPublisher: Sendable {
    /// 发布一个扇出触发。
    ///
    /// - Parameter trigger: 待发布的触发。
    /// - Throws: 发布失败时抛出。
    func publish(_ trigger: V2FanoutPlanTrigger) async throws
}

/// 面向同库部署规划器的可选批量发布能力。
///
/// 一批发布要么全部提交页面，要么抛出错误，因此中继可以重试全部被栅栏的租约，
/// 而不需要引入「部分确认」状态。
public protocol V2BatchFanoutPlanPublisher: V2FanoutPlanPublisher {
    /// 批量发布扇出触发。
    ///
    /// - Parameter triggers: 本批触发。
    /// - Throws: 任一触发发布失败时抛出，整批视为未成功。
    func publishBatch(_ triggers: [V2FanoutPlanTrigger]) async throws
}

/// 单轮发件箱中继统计。
public struct V2OutboxRelayReport: Equatable, Sendable {
    /// 本轮认领数量。
    public let claimedCount: Int
    /// 成功发布数量。
    public let publishedCount: Int
    /// 安排重试的数量。
    public let releasedCount: Int
    /// 暂停等待运维重放的数量。
    public let pausedCount: Int

    /// 保存中继统计。
    ///
    /// - Parameters:
    ///   - claimedCount: 认领数量。
    ///   - publishedCount: 发布数量。
    ///   - releasedCount: 安排重试数量。
    ///   - pausedCount: 暂停数量，默认零。
    public init(claimedCount: Int, publishedCount: Int, releasedCount: Int, pausedCount: Int = 0) {
        self.claimedCount = claimedCount
        self.publishedCount = publishedCount
        self.releasedCount = releasedCount
        self.pausedCount = pausedCount
    }
}

/// 有界、由调用方调度的中继工作器。
///
/// 它不创建游离任务，也不会在等待消息代理期间持有数据库事务。
public struct V2OutboxRelay: Sendable {
    private let store: any V2RoomOutboxStore
    private let publisher: any V2FanoutPlanPublisher
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let retryPolicy: V2DurableRetryPolicy

    /// 组合发件箱存储、发布器与重试策略。
    ///
    /// - Parameters:
    ///   - store: 发件箱持久化存储。
    ///   - publisher: 扇出计划发布器。
    ///   - leaseDuration: 租约时长秒数，需大于零。
    ///   - retryPolicy: 失败退避策略。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 租约时长非正时直接失败，避免租约早于一次发布完成。
    public init(
        store: any V2RoomOutboxStore,
        publisher: any V2FanoutPlanPublisher,
        leaseDuration: TimeInterval = 30,
        retryPolicy: V2DurableRetryPolicy = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.store = store
        self.publisher = publisher
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.now = now
    }

    /// 执行一轮有界中继。
    ///
    /// 认领数量大于一且发布器支持批量时走批量路径；否则逐条发布。
    /// 逐条路径中，代理发布成功但进程随后崩溃的条目会被刻意重试，消费方必须按事件去重。
    ///
    /// - Parameter limit: 本轮最多认领的条数，需大于零。
    /// - Returns: 本轮统计结果。
    /// - Throws: 重试时刻不晚于当前时刻时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；其余错误来自存储实现。
    public func runOnce(limit: Int) async throws -> V2OutboxRelayReport {
        precondition(limit > 0)
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        if leases.count > 1, let batchPublisher = publisher as? any V2BatchFanoutPlanPublisher {
            return try await publishBatch(leases, with: batchPublisher)
        }
        var published = 0
        var released = 0
        var paused = 0
        for lease in leases {
            do {
                try await publisher.publish(lease.trigger)
                try await store.markPublished(lease)
                published += 1
            } catch {
                // A successful broker publish followed by a process crash is
                // intentionally retried. Consumers must deduplicate by event.
                let failureTime = now()
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
        }
        return .init(claimedCount: leases.count, publishedCount: published, releasedCount: released, pausedCount: paused)
    }

    /// 以集合语句发布整批租约。
    ///
    /// 批量发布成功后会优先使用集合式标记；失败时为每条租约分别按退避策略安排重试，
    /// 保证不产生部分确认状态。
    ///
    /// - Parameters:
    ///   - leases: 本批租约。
    ///   - publisher: 支持批量发布的发布器。
    /// - Returns: 本轮统计结果。
    /// - Throws: 重试时刻不晚于当前时刻时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；其余错误来自存储实现。
    private func publishBatch(
        _ leases: [V2OutboxLease],
        with publisher: any V2BatchFanoutPlanPublisher
    ) async throws -> V2OutboxRelayReport {
        do {
            try await publisher.publishBatch(leases.map(\.trigger))
            if let batchStore = store as? any V2BatchRoomOutboxStore {
                try await batchStore.markPublished(leases)
            } else {
                for lease in leases { try await store.markPublished(lease) }
            }
            return .init(
                claimedCount: leases.count,
                publishedCount: leases.count,
                releasedCount: 0
            )
        } catch {
            var released = 0
            var paused = 0
            for lease in leases {
                let failureTime = now()
                let disposition = retryPolicy.disposition(
                    attempt: lease.attempt,
                    claimToken: lease.claimToken,
                    now: failureTime
                )
                if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failureTime, retryAt) {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                switch disposition {
                case .retry: released += 1
                case .pause: paused += 1
                }
            }
            return .init(
                claimedCount: leases.count,
                publishedCount: 0,
                releasedCount: released,
                pausedCount: paused
            )
        }
    }
}
