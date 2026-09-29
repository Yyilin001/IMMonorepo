import IMV2ServerContracts
import Foundation
import IMV2Core

/// 一次通用推送唤醒。
public struct V2GenericPushWake: Equatable, Sendable {
    /// 本次推送派发标识。
    public let dispatchID: UUID
    /// 目标设备。
    public let deviceID: DeviceID
    /// 本次派发所属的活动标识。
    public let campaignID: V2PushCampaignID

    /// 保存推送唤醒内容。
    ///
    /// - Parameters:
    ///   - dispatchID: 派发标识。
    ///   - deviceID: 目标设备。
    ///   - campaignID: 活动标识。
    public init(dispatchID: UUID, deviceID: DeviceID, campaignID: V2PushCampaignID) {
        self.dispatchID = dispatchID
        self.deviceID = deviceID
        self.campaignID = campaignID
    }
}

/// 推送唤醒任务租约。
public struct V2PushWakeLease: Equatable, Sendable {
    /// 本次唤醒内容。
    public let wake: V2GenericPushWake
    /// 本次租约的认领令牌。
    public let claimToken: UUID

    /// 保存唤醒租约。
    ///
    /// - Parameters:
    ///   - wake: 唤醒内容。
    ///   - claimToken: 认领令牌。
    public init(wake: V2GenericPushWake, claimToken: UUID) {
        self.wake = wake
        self.claimToken = claimToken
    }
}

/// 推送提供方边界。
///
/// 存储会在调用提供方之前完成活动与预算准入，因此提供方适配器只会为已经准入的
/// 通用唤醒解析设备密钥材料。
public protocol V2PushWakeProvider: Sendable {
    /// 发送一次推送唤醒。
    ///
    /// - Parameter wake: 已准入的唤醒内容。
    /// - Returns: 提供方结果。
    /// - Throws: 瞬时发送失败时抛出，调用方将释放本次租约以便重试。
    func send(_ wake: V2GenericPushWake) async throws -> V2PushWakeProviderOutcome
}

/// 提供方发送结果。
///
/// 终态抑制与瞬时提供方失败不同：前者会被记录且不再重试，后者只释放推送租约。
/// 两条路径都不参与持久化用户同步的正确性判定。
public enum V2PushWakeProviderOutcome: Equatable, Sendable {
    /// 已成功送达提供方。
    case sent
    /// 提供方判定不再投递，附抑制原因。
    case suppressed(V2PushSuppressionReason)
}

/// 推送唤醒任务的持久化能力。
public protocol V2PushWakeStore: Sendable {
    /// 认领一批已准入的推送唤醒。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 认领到的唤醒租约。
    /// - Throws: 持久化失败时抛出。
    func claimAdmitted(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2PushWakeLease]

    /// 标记已发送。
    ///
    /// - Parameters:
    ///   - lease: 本次唤醒租约。
    ///   - now: 完成时刻。
    /// - Throws: 持久化失败时抛出。
    func markSent(_ lease: V2PushWakeLease, now: Date) async throws

    /// 记录终态抑制。
    ///
    /// - Parameters:
    ///   - lease: 本次唤醒租约。
    ///   - reason: 抑制原因。
    /// - Throws: 持久化失败时抛出。
    func suppress(_ lease: V2PushWakeLease, reason: V2PushSuppressionReason) async throws

    /// 释放租约以便后续重试。
    ///
    /// - Parameter lease: 本次唤醒租约。
    /// - Throws: 持久化失败时抛出。
    func release(_ lease: V2PushWakeLease) async throws
}

/// 单轮推送唤醒统计。
public struct V2PushWakeReport: Equatable, Sendable {
    /// 本轮认领数量。
    public let admittedCount: Int
    /// 成功发送数量。
    public let sentCount: Int
    /// 因提供方失败而释放的数量。
    public let releasedCount: Int

    /// 保存统计结果。
    ///
    /// - Parameters:
    ///   - admittedCount: 认领数量。
    ///   - sentCount: 发送数量。
    ///   - releasedCount: 释放数量。
    public init(admittedCount: Int, sentCount: Int, releasedCount: Int) {
        self.admittedCount = admittedCount
        self.sentCount = sentCount
        self.releasedCount = releasedCount
    }
}

/// 有界推送唤醒工作器。
///
/// 提供方失败刻意只释放本次推送派发以便重试，既不会回滚也不会推迟用户同步投影。
public struct V2PushWakeWorker: Sendable {
    private let store: any V2PushWakeStore
    private let provider: any V2PushWakeProvider
    private let leaseDuration: TimeInterval
    private let sendTimeout: TimeInterval
    private let maximumConcurrency: Int
    private let now: @Sendable () -> Date

    /// 组合推送存储、提供方与并发参数。
    ///
    /// - Parameters:
    ///   - store: 推送任务的持久化存储。
    ///   - provider: 实际发送推送的提供方。
    ///   - leaseDuration: 租约时长秒数，需大于发送超时且为有限值。
    ///   - sendTimeout: 单次发送超时秒数，需为正的有限值。
    ///   - maximumConcurrency: 并发上限，需大于零。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 参数不满足上述关系时直接失败，避免租约早于发送超时到期。
    public init(
        store: any V2PushWakeStore,
        provider: any V2PushWakeProvider,
        leaseDuration: TimeInterval = 30,
        sendTimeout: TimeInterval = 10,
        maximumConcurrency: Int = 8,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(
            leaseDuration.isFinite && sendTimeout.isFinite &&
            leaseDuration > sendTimeout && sendTimeout > 0 && maximumConcurrency > 0
        )
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.sendTimeout = sendTimeout
        self.maximumConcurrency = maximumConcurrency
        self.now = now
    }

    /// 执行一轮有界推送。
    ///
    /// 认领到的租约按并发上限流水线处理：每当一个任务结束就补充下一个，
    /// 使受抑制的任务立即让出并发额度。
    ///
    /// - Parameter limit: 本轮最多认领的唤醒数，需大于零。
    /// - Returns: 本轮统计结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；其余错误来自存储实现。
    public func runOnce(limit: Int) async throws -> V2PushWakeReport {
        precondition(limit > 0)
        let leases = try await store.claimAdmitted(now: now(), leaseDuration: leaseDuration, limit: limit)
        let counts = try await withThrowingTaskGroup(
            of: PushProcessingResult.self,
            returning: (sent: Int, released: Int).self
        ) { group in
            var nextIndex = 0
            let initialCount = min(maximumConcurrency, leases.count)
            for _ in 0..<initialCount {
                let lease = leases[nextIndex]
                nextIndex += 1
                group.addTask { try await process(lease) }
            }
            var sent = 0
            var released = 0
            while let result = try await group.next() {
                switch result {
                case .sent: sent += 1
                case .suppressed: break
                case .released: released += 1
                }
                if nextIndex < leases.count {
                    let lease = leases[nextIndex]
                    nextIndex += 1
                    group.addTask { try await process(lease) }
                }
            }
            return (sent, released)
        }
        return .init(admittedCount: leases.count, sentCount: counts.sent, releasedCount: counts.released)
    }

    /// 处理单个唤醒租约，失败时释放租约以便重试。
    ///
    /// 发送与超时任务同组竞速，先结束的一方会取消另一方。
    ///
    /// - Parameter lease: 本次唤醒租约。
    /// - Returns: 处理结果分类。
    /// - Throws: 任务取消时释放租约后继续抛出 `CancellationError`。
    private func process(_ lease: V2PushWakeLease) async throws -> PushProcessingResult {
        do {
            try Task.checkCancellation()
            let outcome = try await withThrowingTaskGroup(of: V2PushWakeProviderOutcome.self) { group in
                group.addTask { try await provider.send(lease.wake) }
                group.addTask {
                    try await v2Sleep(for: .seconds(sendTimeout))
                    throw V2PushWakeWorkerError.sendTimedOut
                }
                guard let result = try await group.next() else { throw V2PushWakeWorkerError.sendTimedOut }
                group.cancelAll()
                return result
            }
            switch outcome {
            case .sent:
                try await store.markSent(lease, now: now())
                return .sent
            case .suppressed(let reason):
                try await store.suppress(lease, reason: reason)
                return .suppressed
            }
        } catch is CancellationError {
            try? await store.release(lease)
            throw CancellationError()
        } catch {
            try await store.release(lease)
            return .released
        }
    }
}

/// 推送唤醒工作器内部错误。
private enum V2PushWakeWorkerError: Error, Sendable { case sendTimedOut }

/// 单个唤醒的处理结果分类。
private enum PushProcessingResult: Sendable {
    case sent
    case suppressed
    case released
}
