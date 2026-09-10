import Foundation
import IMV2Core

/// 单个共享分片级准入池的身份。
///
/// 容量档位标识不可变：修改任一上限都必须启用新的档位标识并执行显式房间迁移，
/// 绝不允许就地静默改写租约。
public struct V2ShardAdmissionPoolKey: Equatable, Hashable, Sendable {
    /// 逻辑房间分片标识，已去除首尾空白。
    public let roomShardID: String
    /// 容量档位标识，已去除首尾空白。
    public let capacityProfileID: String

    /// 规范化并校验准入池身份。
    ///
    /// - Parameters:
    ///   - roomShardID: 逻辑分片标识，去除首尾空白后需非空。
    ///   - capacityProfileID: 容量档位标识，去除首尾空白后需非空。
    /// - Throws: 任一标识为空白时抛出
    ///   ``V2ShardAdmissionLeaseControlError/invalidPoolKey``。
    public init(roomShardID: String, capacityProfileID: String) throws {
        let shard = roomShardID.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = capacityProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shard.isEmpty, !profile.isEmpty else {
            throw V2ShardAdmissionLeaseControlError.invalidPoolKey
        }
        self.roomShardID = shard
        self.capacityProfileID = profile
    }
}

/// 租约持有者续租时必须提供的最小栅栏值。
public struct V2ShardAdmissionLeaseFence: Equatable, Sendable {
    /// 租约标识。
    public let id: ShardAdmissionLeaseID
    /// 租约代次。
    public let generation: UInt64

    /// 保存栅栏值。
    ///
    /// - Parameters:
    ///   - id: 租约标识。
    ///   - generation: 租约代次。
    public init(id: ShardAdmissionLeaseID, generation: UInt64) {
        self.id = id
        self.generation = generation
    }
}

public extension ShardAdmissionLease {
    /// 该租约对应的栅栏值。
    ///
    /// 租约构造过程已拒绝零代次，因此此处可安全地直接取值。
    var v2Fence: V2ShardAdmissionLeaseFence {
        // The lease initializer already rejects zero generations.
        .init(id: id, generation: generation)
    }
}

/// 分片准入租约控制错误。
public enum V2ShardAdmissionLeaseControlError: Error, Equatable, Sendable {
    /// 准入池身份中的标识为空白。
    case invalidPoolKey
    /// 租约时长非正或无法编码为持久化时间戳。
    case invalidLifetime
    /// 请求的容量档位与既有准入池不一致。
    case capacityProfileDoesNotMatchPool
    /// 同一档位标识下的容量上限已被改写。
    case capacityProfileLimitsChanged
    /// 该准入池已存在。
    case poolAlreadyExists
    /// 该准入池不存在。
    case poolNotFound
    /// 提供的租约栅栏与当前值不匹配。
    case fenceMismatch
    /// 租约已过期。
    case leaseExpired
    /// 只有已过期的租约才可以被替换。
    case replacementRequiresExpiredLease
    /// 租约代次已达上限，无法继续递增。
    case generationOverflow
}

/// 隔离控制面所需的持久化比较并交换操作。
///
/// 实现必须保证同一准入池身份下的这些操作彼此串行。
public protocol V2ShardAdmissionLeaseStore: Sendable {
    /// 为一个新的准入池签发租约。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - capacityProfile: 本次签发的容量档位。
    ///   - leaseID: 新租约标识。
    ///   - validUntil: 租约到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 已签发的租约。
    /// - Throws: 准入池已存在、档位不一致或持久化失败时抛出。
    func issue(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        leaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease

    /// 按栅栏值续租。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - expectedFence: 期望的当前租约栅栏。
    ///   - validUntil: 新的到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 续租后的租约。
    /// - Throws: 栅栏不匹配、租约已过期或持久化失败时抛出。
    func renew(
        key: V2ShardAdmissionPoolKey,
        expectedFence: V2ShardAdmissionLeaseFence,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease

    /// 在既有租约确已过期后签发替代租约。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - capacityProfile: 替代租约使用的容量档位。
    ///   - replacementLeaseID: 替代租约标识。
    ///   - validUntil: 替代租约到期时刻。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 替代租约。
    /// - Throws: 原租约尚未过期、档位不一致或持久化失败时抛出。
    func replaceExpired(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        replacementLeaseID: ShardAdmissionLeaseID,
        validUntil: Date,
        now: Date
    ) async throws -> ShardAdmissionLease
}

/// 分片准入租约的签发、续租与安全接管用例，自身不持有状态。
///
/// 调用方需自行负责对该内部控制面接口的访问授权；公网实时服务可执行文件刻意不暴露它。
public struct V2ShardAdmissionLeaseService: Sendable {
    private let store: any V2ShardAdmissionLeaseStore
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// 组合租约存储、标识生成与授时来源。
    ///
    /// - Parameters:
    ///   - store: 执行比较并交换的持久化存储。
    ///   - makeUUID: 租约标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        store: any V2ShardAdmissionLeaseStore,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 为容量档位签发一个新的准入池租约。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - capacityProfile: 本次签发的容量档位。
    ///   - lifetime: 租约时长秒数。
    /// - Returns: 已签发的租约。
    /// - Throws: 时长不可用时抛出
    ///   ``V2ShardAdmissionLeaseControlError/invalidLifetime``；其余错误来自存储实现。
    public func issue(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        lifetime: TimeInterval
    ) async throws -> ShardAdmissionLease {
        let instant = now()
        let validUntil = try expiry(after: lifetime, from: instant)
        return try await store.issue(
            key: key,
            capacityProfile: capacityProfile,
            leaseID: try .init(makeUUID().uuidString),
            validUntil: validUntil,
            now: instant
        )
    }

    /// 按栅栏值续租。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - expectedFence: 期望的当前租约栅栏。
    ///   - lifetime: 新的租约时长秒数。
    /// - Returns: 续租后的租约。
    /// - Throws: 时长不可用时抛出
    ///   ``V2ShardAdmissionLeaseControlError/invalidLifetime``；其余错误来自存储实现。
    public func renew(
        key: V2ShardAdmissionPoolKey,
        expectedFence: V2ShardAdmissionLeaseFence,
        lifetime: TimeInterval
    ) async throws -> ShardAdmissionLease {
        let instant = now()
        return try await store.renew(
            key: key,
            expectedFence: expectedFence,
            validUntil: try expiry(after: lifetime, from: instant),
            now: instant
        )
    }

    /// 在既有租约确已过期后签发替代租约。
    ///
    /// - Parameters:
    ///   - key: 准入池身份。
    ///   - capacityProfile: 替代租约使用的容量档位。
    ///   - lifetime: 替代租约时长秒数。
    /// - Returns: 替代租约。
    /// - Throws: 时长不可用时抛出
    ///   ``V2ShardAdmissionLeaseControlError/invalidLifetime``；其余错误来自存储实现。
    public func replaceExpired(
        key: V2ShardAdmissionPoolKey,
        capacityProfile: V2CapacityProfile,
        lifetime: TimeInterval
    ) async throws -> ShardAdmissionLease {
        let instant = now()
        return try await store.replaceExpired(
            key: key,
            capacityProfile: capacityProfile,
            replacementLeaseID: try .init(makeUUID().uuidString),
            validUntil: try expiry(after: lifetime, from: instant),
            now: instant
        )
    }

    /// 计算租约到期时刻。
    ///
    /// - Parameters:
    ///   - lifetime: 租约时长秒数。
    ///   - instant: 起始时刻。
    /// - Returns: 可持久化的到期时刻。
    /// - Throws: 时长非正、非有限或超过可编码范围时抛出
    ///   ``V2ShardAdmissionLeaseControlError/invalidLifetime``。
    private func expiry(after lifetime: TimeInterval, from instant: Date) throws -> Date {
        guard let expiry = v2PostgresFutureTimestamp(now: instant, interval: lifetime) else {
            throw V2ShardAdmissionLeaseControlError.invalidLifetime
        }
        return expiry
    }
}

/// 判断租约携带的上限是否与容量档位完全一致。
///
/// 命令窗口、扇出窗口、未完成扇出量与未完成计划数四项都必须相等。
///
/// - Parameters:
///   - lease: 待比较的租约。
///   - profile: 期望的容量档位配置。
/// - Returns: 四项上限全部一致时为 `true`。
func v2ShardLeaseMatchesProfile(_ lease: ShardAdmissionLease, _ profile: RoomCapacityProfile) -> Bool {
    lease.commandWindow.limit == profile.maxCommandsPerWindow
        && lease.fanoutWindow.limit == profile.maxFanoutUnitsPerWindow
        && lease.maxOutstandingFanoutUnits == profile.maxOutstandingFanoutUnits
        && lease.maxOutstandingPlans == profile.maxOutstandingPlans
}
