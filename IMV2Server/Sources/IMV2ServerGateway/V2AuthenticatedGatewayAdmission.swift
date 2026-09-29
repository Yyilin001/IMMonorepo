import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 已认证网关命令的限流准入能力。
public protocol V2AuthenticatedGatewayCommandAdmitting: Sendable {
    /// 以指定代价准入一条命令。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - cost: 本次消耗的额度。
    ///   - now: 判定时刻。
    /// - Returns: 允许通过时为 `true`。
    func admit(identity: V2AuthenticatedConnection, cost: Int, now: Date) async -> Bool
}

public extension V2AuthenticatedGatewayCommandAdmitting {
    /// 以单份额度准入一条命令。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - now: 判定时刻。
    /// - Returns: 允许通过时为 `true`。
    func admit(identity: V2AuthenticatedConnection, now: Date) async -> Bool {
        await admit(identity: identity, cost: 1, now: now)
    }
}

/// 网关命令的令牌桶限流策略。
public struct V2GatewayCommandRateLimitPolicy: Equatable, Sendable {
    /// 单设备每秒命令数。
    public let deviceCommandsPerSecond: Double
    /// 单设备突发容量。
    public let deviceBurst: Int
    /// 单用户每秒命令数。
    public let userCommandsPerSecond: Double
    /// 单用户突发容量。
    public let userBurst: Int
    /// 可追踪身份数量上限。
    public let maximumTrackedIdentities: Int

    /// 校验并保存限流策略。
    ///
    /// - Parameters:
    ///   - deviceCommandsPerSecond: 单设备每秒命令数，需大于零。
    ///   - deviceBurst: 单设备突发容量，需大于零。
    ///   - userCommandsPerSecond: 单用户每秒命令数，需大于零。
    ///   - userBurst: 单用户突发容量，需不小于设备突发容量。
    ///   - maximumTrackedIdentities: 可追踪身份数量，需不小于 2。
    ///
    /// 参数不满足上述关系时直接失败，避免用户突发小于设备突发的矛盾配置。
    public init(
        deviceCommandsPerSecond: Int,
        deviceBurst: Int,
        userCommandsPerSecond: Int,
        userBurst: Int,
        maximumTrackedIdentities: Int
    ) {
        precondition(
            deviceCommandsPerSecond > 0 && deviceBurst > 0 &&
            userCommandsPerSecond > 0 && userBurst >= deviceBurst &&
            maximumTrackedIdentities >= 2
        )
        self.deviceCommandsPerSecond = Double(deviceCommandsPerSecond)
        self.deviceBurst = deviceBurst
        self.userCommandsPerSecond = Double(userCommandsPerSecond)
        self.userBurst = userBurst
        self.maximumTrackedIdentities = maximumTrackedIdentities
    }
}

/// 进程过载边界，而不是产品风控或滥用配额。
///
/// 用户会被分配到稳定且相互独立的通道，使无关连接不会在同一个全局 actor 上串行。
/// 同一已认证用户的所有设备进入同一通道，从而保持「设备 + 用户」计费的原子性；
/// 各通道的最近最少使用预算精确划分配置的进程级身份上限。
public final class V2AuthenticatedGatewayCommandRateLimiter: V2AuthenticatedGatewayCommandAdmitting, Sendable {
    private let shards: [V2AuthenticatedGatewayCommandRateLimiterShard]

    /// 组合限流策略与通道数量。
    ///
    /// 通道数会按追踪容量收敛：小规模策略与刻意精简的部署仍只保留一条通道，
    /// 生产规模则获得并行度，同时不会产生「装不下一个用户与其设备」的过小通道。
    /// 总容量按商与余数精确分配，各通道容量之和等于配置上限。
    ///
    /// - Parameters:
    ///   - policy: 令牌桶限流策略。
    ///   - shardCount: 期望通道数量，需大于零，默认 16。
    ///   - monotonicNow: 可注入的单调时钟读取函数。
    ///
    /// 通道数量非正时直接失败，避免出现空通道数组。
    public init(
        policy: V2GatewayCommandRateLimitPolicy,
        shardCount: Int = 16,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        precondition(shardCount > 0)
        // 小型策略测试配置和刻意缩小的部署保留单通道。
        // 生产规模的映射可获得并行性，同时不会创建预算不足以
        // 原子容纳一个用户和一台设备的分片。
        let effectiveShardCount = min(
            shardCount,
            max(1, policy.maximumTrackedIdentities / 1_024)
        )
        let base = policy.maximumTrackedIdentities / effectiveShardCount
        let remainder = policy.maximumTrackedIdentities % effectiveShardCount
        shards = (0..<effectiveShardCount).map { index in
            let capacity = base + (index < remainder ? 1 : 0)
            return .init(policy: policy, identityCapacity: capacity, monotonicNow: monotonicNow)
        }
    }

    /// 以指定代价准入一条命令。
    ///
    /// 命令按其身份稳定映射到某条通道，在同一通道内以原子方式同时扣减设备与用户额度，
    /// 因此不会出现只扣一侧的中间状态。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - cost: 本次消耗的额度。
    ///   - now: 判定时刻。
    /// - Returns: 允许通过时为 `true`。
    public func admit(identity: V2AuthenticatedConnection, cost: Int, now: Date) async -> Bool {
        guard cost >= 0 else { return false }
        guard cost > 0 else { return true }
        // 扣减限流桶或修改 LRU 状态前，先满足会话的时钟契约；
        // 这与单调补充时钟相互独立。
        guard (try? v2GatewayMilliseconds(now)) != nil else { return false }
        return await shards[shardIndex(for: identity.userID)].admit(
            identity: identity,
            cost: cost
        )
    }

    func trackedIdentityCount() async -> Int {
        var total = 0
        for shard in shards { total += await shard.trackedIdentityCount() }
        return total
    }

    private func shardIndex(for userID: UserID) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in userID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(shards.count))
    }
}

private actor V2AuthenticatedGatewayCommandRateLimiterShard {
    private enum TrackedIdentity: Hashable, Sendable {
        case device(DeviceID)
        case user(UserID)
    }

    private struct Bucket: Sendable {
        var tokens: Double
        var refilledAt: ContinuousClock.Instant
    }

    private struct LRUNode: Sendable {
        var previous: TrackedIdentity?
        var next: TrackedIdentity?
    }

    private let policy: V2GatewayCommandRateLimitPolicy
    private let identityCapacity: Int
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private var devices: [DeviceID: Bucket] = [:]
    private var users: [UserID: Bucket] = [:]
    private var lruNodes: [TrackedIdentity: LRUNode] = [:]
    private var leastRecentlyUsed: TrackedIdentity?
    private var mostRecentlyUsed: TrackedIdentity?
    /// 惰性构建最近最少使用链表的说明。
    ///
    /// 在有界映射真正需要淘汰之前，访问新旧顺序没有可观察效果：若为每条命令都创建并更新两个
    /// 侵入式链表节点，会让容量充裕的常规路径多付四次字典写入。这里把精确的最后使用时间
    /// 记在令牌桶中，并在首次可能发生淘汰之前一次性物化链表；此后每次访问都恢复精确追踪。
    private var recencyTrackingEnabled = false

    init(
        policy: V2GatewayCommandRateLimitPolicy,
        identityCapacity: Int,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        // 补充速率已用 Double 表示。若经由 Int 重建策略，
        // 对 Int.max 等已接受的值可能崩溃，因为转换为 Double 时会向上舍入。
        self.policy = policy
        self.identityCapacity = identityCapacity
        self.monotonicNow = monotonicNow
    }

    func admit(identity: V2AuthenticatedConnection, cost: Int) -> Bool {
        // 在通道内采样，使已排队请求遵循 Actor 执行顺序。
        // 墙上时钟调整既不能提前补充额度，
        // 也不能让正常补充停滞直到时间重新到达旧时间戳。
        let now = monotonicNow()
        var device = refilled(
            devices[identity.deviceID],
            capacity: policy.deviceBurst,
            rate: policy.deviceCommandsPerSecond,
            now: now
        )
        var user = refilled(
            users[identity.userID],
            capacity: policy.userBurst,
            rate: policy.userCommandsPerSecond,
            now: now
        )
        let required = Double(cost)
        guard device.tokens >= required, user.tokens >= required else {
            ensureCapacity(deviceID: identity.deviceID, userID: identity.userID)
            devices[identity.deviceID] = device
            users[identity.userID] = user
            if recencyTrackingEnabled {
                touch(.device(identity.deviceID))
                touch(.user(identity.userID))
            }
            return false
        }
        device.tokens -= required
        user.tokens -= required
        ensureCapacity(deviceID: identity.deviceID, userID: identity.userID)
        devices[identity.deviceID] = device
        users[identity.userID] = user
        if recencyTrackingEnabled {
            touch(.device(identity.deviceID))
            touch(.user(identity.userID))
        }
        return true
    }

    private func refilled(
        _ existing: Bucket?,
        capacity: Int,
        rate: Double,
        now: ContinuousClock.Instant
    ) -> Bucket {
        guard var bucket = existing else {
            return .init(tokens: Double(capacity), refilledAt: now)
        }
        let elapsed = bucket.refilledAt.duration(to: now)
        if elapsed > .zero {
            let components = elapsed.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            bucket.tokens = min(Double(capacity), bucket.tokens + seconds * rate)
            bucket.refilledAt = now
        }
        return bucket
    }

    private func ensureCapacity(deviceID: DeviceID, userID: UserID) {
        let additions = (devices[deviceID] == nil ? 1 : 0) + (users[userID] == nil ? 1 : 0)
        if devices.count + users.count + additions > identityCapacity,
           !recencyTrackingEnabled {
            enableRecencyTracking()
        }
        while devices.count + users.count + additions > identityCapacity {
            precondition(evictLeastRecentlyUsed(excluding: deviceID, userID: userID))
        }
    }

    /// 由令牌桶的最后补充时间重建精确访问顺序。
    ///
    /// 每次耗时为正的访问都会推进 `refilledAt`，因此该转换不会丢弃或刷新任何限流状态。
    /// 时间戳相同时仅使用稳定的身份键排序，使淘汰与测试结果可复现；
    /// 两种排序在配额语义上完全等价。
    private func enableRecencyTracking() {
        precondition(!recencyTrackingEnabled)
        var identities: [(identity: TrackedIdentity, lastUsedAt: ContinuousClock.Instant)] = []
        identities.reserveCapacity(devices.count + users.count)
        identities.append(contentsOf: devices.map {
            (.device($0.key), $0.value.refilledAt)
        })
        identities.append(contentsOf: users.map {
            (.user($0.key), $0.value.refilledAt)
        })
        identities.sort {
            if $0.lastUsedAt != $1.lastUsedAt {
                return $0.lastUsedAt < $1.lastUsedAt
            }
            return stableIdentityKey($0.identity) < stableIdentityKey($1.identity)
        }
        lruNodes.removeAll(keepingCapacity: true)
        leastRecentlyUsed = nil
        mostRecentlyUsed = nil
        for item in identities { touch(item.identity) }
        recencyTrackingEnabled = true
    }

    private func stableIdentityKey(_ identity: TrackedIdentity) -> String {
        switch identity {
        case .device(let deviceID): "device:" + deviceID.rawValue
        case .user(let userID): "user:" + userID.rawValue
        }
    }

    private func evictLeastRecentlyUsed(excluding deviceID: DeviceID, userID: UserID) -> Bool {
        let excludedDevice = TrackedIdentity.device(deviceID)
        let excludedUser = TrackedIdentity.user(userID)
        var candidate = leastRecentlyUsed
        while candidate == excludedDevice || candidate == excludedUser {
            candidate = candidate.flatMap { lruNodes[$0]?.next }
        }
        guard let candidate else { return false }
        removeLRUNode(candidate)
        switch candidate {
        case .device(let deviceID): devices.removeValue(forKey: deviceID)
        case .user(let userID): users.removeValue(forKey: userID)
        }
        return true
    }

    private func touch(_ identity: TrackedIdentity) {
        if lruNodes[identity] != nil {
            removeLRUNode(identity)
        }
        lruNodes[identity] = .init(previous: mostRecentlyUsed, next: nil)
        if let mostRecentlyUsed {
            lruNodes[mostRecentlyUsed]?.next = identity
        } else {
            leastRecentlyUsed = identity
        }
        mostRecentlyUsed = identity
    }

    private func removeLRUNode(_ identity: TrackedIdentity) {
        guard let node = lruNodes.removeValue(forKey: identity) else { return }
        if let previous = node.previous {
            lruNodes[previous]?.next = node.next
        } else {
            leastRecentlyUsed = node.next
        }
        if let next = node.next {
            lruNodes[next]?.previous = node.previous
        } else {
            mostRecentlyUsed = node.previous
        }
    }

    func trackedIdentityCount() -> Int { devices.count + users.count }
}
