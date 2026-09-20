import Foundation

/// 时间窗口容量快照，不负责计时或自动重置。
public struct CapacityWindow: Equatable, Sendable {
    /// 非负总额度。
    public let limit: Int
    /// 非负已用额度，允许超过总额以表示耗尽状态。
    public let used: Int

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - limit: 非负总额度。
    ///   - used: 非负已用额度，允许超过总额以表示耗尽状态。
    ///
    /// 要求额度与已用量均非负，否则抛出 invalidNonNegativeValue；不要求 used 小于 limit。
    public init(limit: Int, used: Int = 0) throws {
        guard limit >= 0, used >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.limit = limit
        self.used = used
    }

    /// 判断非负增量是否可容纳，先比较 used 不超过 limit，再用减法比较剩余额度，避免加法溢出。
    public func canReserve(_ amount: Int) -> Bool {
        amount >= 0 && used <= limit && amount <= limit - used
    }

    /// 返回增加使用量的新窗口，无法容纳时抛出 capacityExceeded，不改变原值。
    public func reserving(_ amount: Int) throws -> CapacityWindow {
        guard canReserve(amount) else {
            throw V2CommandAdmissionMutationError.capacityExceeded
        }
        return try CapacityWindow(limit: limit, used: used + amount)
    }
}

/// 房间命令容量配置。
public struct RoomCapacityProfile: Equatable, Sendable {
    public let maxEligibleMembers: Int
    public let maxCommandsPerWindow: Int
    public let retryAfterSeconds: Int

    public init(maxEligibleMembers: Int, maxCommandsPerWindow: Int, retryAfterSeconds: Int) throws {
        guard maxEligibleMembers >= 0, maxCommandsPerWindow >= 0, retryAfterSeconds >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.maxEligibleMembers = maxEligibleMembers
        self.maxCommandsPerWindow = maxCommandsPerWindow
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// 房间成员容量与命令窗口的不可变快照。
public struct RoomAdmissionState: Equatable, Sendable {
    public let eligibleMemberCount: Int
    public let commandWindow: CapacityWindow

    public init(eligibleMemberCount: Int, commandWindow: CapacityWindow) throws {
        guard eligibleMemberCount >= 0 else { throw V2CoreError.invalidNonNegativeValue }
        self.eligibleMemberCount = eligibleMemberCount
        self.commandWindow = commandWindow
    }
}

/// 分片命令预算的租约栅栏。
public struct ShardAdmissionLease: Equatable, Sendable {
    public let id: ShardAdmissionLeaseID
    public let generation: UInt64
    public let validUntil: Date
    public let commandWindow: CapacityWindow

    public init(id: ShardAdmissionLeaseID, generation: UInt64, validUntil: Date, commandWindow: CapacityWindow) throws {
        guard generation > 0 else { throw V2CoreError.invalidGeneration }
        self.id = id
        self.generation = generation
        self.validUntil = validUntil
        self.commandWindow = commandWindow
    }

    public func isValid(at instant: Date) -> Bool { validUntil > instant }
}

/// 缺失租约时由准入入口明确拒绝。
public struct ShardAdmissionState: Equatable, Sendable {
    public let lease: ShardAdmissionLease?
    public init(lease: ShardAdmissionLease?) throws { self.lease = lease }
}

/// 命令接受时的分片租约绑定，供事务提交和审计关联。
public struct V2CommandAdmissionReservation: Equatable, Sendable {
    /// 预留所用租约身份。
    public let shardLeaseID: ShardAdmissionLeaseID
    /// 预留所用租约代际。
    public let shardLeaseGeneration: UInt64

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - shardLeaseID: 预留所用租约身份。
    ///   - shardLeaseGeneration: 预留所用租约代际。
    ///
    /// 保存租约元数据；有效性由准入入口检查。
    public init(shardLeaseID: ShardAdmissionLeaseID, shardLeaseGeneration: UInt64) {
        self.shardLeaseID = shardLeaseID
        self.shardLeaseGeneration = shardLeaseGeneration
    }
}

/// 无法执行准入的分片租约状态。
public enum V2CommandAdmissionUnavailableReason: Equatable, Sendable {
    /// 分片没有租约。
    case missingShardLease
    /// 分片租约未通过当前时间有效性判断。
    case expiredShardLease
}

/// 纯准入结果，接受结果仍需调用者持久化。
public enum V2CommandAdmissionResult: Equatable, Sendable {
    /// 返回租约绑定及两个更新后的状态；必须与源事件在同一事务中保存。
    case accepted(
        reservation: V2CommandAdmissionReservation,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState
    )
    /// 容量或配置一致性检查失败，返回建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 租约不可用，携带明确原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
}

/// 命令窗口预留错误。
public enum V2CommandAdmissionMutationError: Error, Equatable, Sendable {
    /// 窗口无法容纳指定增量。
    case capacityExceeded
}

/// 所有房间命令共用的准入路径。
///
/// 每条命令在房间和分片窗口各预留一项；公共内容由房间日志提供可靠读取。
public enum V2CommandAdmissionEvaluator {
    /// 检查租约有效、房间成员上限及窗口配置一致后，仅为房间和分片命令窗口各预留一项；不按成员数收取投递成本。
    public static func reserve(
        profile: RoomCapacityProfile,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState,
        now: Date
    ) throws -> V2CommandAdmissionResult {
        guard let lease = shardState.lease else { return .unavailable(.missingShardLease) }
        guard lease.isValid(at: now) else { return .unavailable(.expiredShardLease) }
        guard roomState.eligibleMemberCount <= profile.maxEligibleMembers,
              roomState.commandWindow.limit == profile.maxCommandsPerWindow,
              roomState.commandWindow.canReserve(1),
              lease.commandWindow.canReserve(1)
        else { return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds) }

        let nextRoom = try RoomAdmissionState(
            eligibleMemberCount: roomState.eligibleMemberCount,
            commandWindow: roomState.commandWindow.reserving(1))
        let nextLease = try ShardAdmissionLease(
            id: lease.id,
            generation: lease.generation,
            validUntil: lease.validUntil,
            commandWindow: lease.commandWindow.reserving(1))
        let nextShard = try ShardAdmissionState(
            lease: nextLease)
        return .accepted(
            reservation: .init(shardLeaseID: lease.id, shardLeaseGeneration: lease.generation),
            roomState: nextRoom,
            shardState: nextShard
        )
    }
}

