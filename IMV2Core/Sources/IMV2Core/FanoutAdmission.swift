import Foundation

/// 命令接受时使用的不可变目标计费规则。
public enum FanoutTargetRule: Equatable, Sendable {
    /// 普通房间消息按每位符合条件成员一个用户投影计费。
    case eligibleMemberCount
    /// 按接受时已确定的目标数计费，合法性由成本构造检查。
    case exactTargetCount(Int)
}

/// 不可变扇出成本，以需要处理的目标数量计量。
public struct FanoutCost: Equatable, Sendable {
    /// 非负目标数量，允许零。
    public let targetCount: Int

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - targetCount: 非负目标数量，允许零。
    ///
    /// 要求目标数非负，否则抛出 invalidNonNegativeValue。
    public init(targetCount: Int) throws {
        guard targetCount >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.targetCount = targetCount
    }
}

/// 纯目标成本计算，不枚举成员或改变预算。
public enum FanoutCostCalculator {
    /// 先要求成员数非负，再按规则使用成员数或明确目标数；负输入抛出 invalidNonNegativeValue，即使规则不使用成员数也要求该参数合法。
    public static func cost(
        for targetRule: FanoutTargetRule,
        eligibleMemberCount: Int
    ) throws -> FanoutCost {
        guard eligibleMemberCount >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }

        switch targetRule {
        case .eligibleMemberCount:
            return try FanoutCost(targetCount: eligibleMemberCount)
        case .exactTargetCount(let targetCount):
            return try FanoutCost(targetCount: targetCount)
        }
    }
}

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
            throw FanoutAdmissionMutationError.capacityExceeded
        }
        return try CapacityWindow(limit: limit, used: used + amount)
    }
}

/// 房间准入与后台执行的容量配置，字段允许零以表达关闭或无容量。
public struct RoomCapacityProfile: Equatable, Sendable {
    /// 最多符合投递条件的成员数。
    public let maxEligibleMembers: Int
    /// 每窗口命令额度。
    public let maxCommandsPerWindow: Int
    /// 每窗口目标工作额度。
    public let maxFanoutUnitsPerWindow: Int
    /// 最大未完成目标工作量。
    public let maxOutstandingFanoutUnits: Int
    /// 最大未完成计划数。
    public let maxOutstandingPlans: Int
    /// 枚举目标分页上限，由执行路径使用。
    public let maxEnumerationPageSize: Int
    /// 规划并发上限，由执行路径使用。
    public let maxPlannerConcurrency: Int
    /// 投递并发上限，由执行路径使用。
    public let maxDeliveryConcurrency: Int
    /// 限流建议等待秒数。
    public let retryAfterSeconds: Int

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - maxEligibleMembers: 最多符合投递条件的成员数。
    ///   - maxCommandsPerWindow: 每窗口命令额度。
    ///   - maxFanoutUnitsPerWindow: 每窗口目标工作额度。
    ///   - maxOutstandingFanoutUnits: 最大未完成目标工作量。
    ///   - maxOutstandingPlans: 最大未完成计划数。
    ///   - maxEnumerationPageSize: 枚举目标分页上限，由执行路径使用。
    ///   - maxPlannerConcurrency: 规划并发上限，由执行路径使用。
    ///   - maxDeliveryConcurrency: 投递并发上限，由执行路径使用。
    ///   - retryAfterSeconds: 限流建议等待秒数。
    ///
    /// 要求全部配置非负，否则抛出 invalidNonNegativeValue；不验证配置之间的关系。
    public init(
        maxEligibleMembers: Int,
        maxCommandsPerWindow: Int,
        maxFanoutUnitsPerWindow: Int,
        maxOutstandingFanoutUnits: Int,
        maxOutstandingPlans: Int,
        maxEnumerationPageSize: Int,
        maxPlannerConcurrency: Int,
        maxDeliveryConcurrency: Int,
        retryAfterSeconds: Int
    ) throws {
        let values = [
            maxEligibleMembers,
            maxCommandsPerWindow,
            maxFanoutUnitsPerWindow,
            maxOutstandingFanoutUnits,
            maxOutstandingPlans,
            maxEnumerationPageSize,
            maxPlannerConcurrency,
            maxDeliveryConcurrency,
            retryAfterSeconds,
        ]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.maxEligibleMembers = maxEligibleMembers
        self.maxCommandsPerWindow = maxCommandsPerWindow
        self.maxFanoutUnitsPerWindow = maxFanoutUnitsPerWindow
        self.maxOutstandingFanoutUnits = maxOutstandingFanoutUnits
        self.maxOutstandingPlans = maxOutstandingPlans
        self.maxEnumerationPageSize = maxEnumerationPageSize
        self.maxPlannerConcurrency = maxPlannerConcurrency
        self.maxDeliveryConcurrency = maxDeliveryConcurrency
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// 房间当前窗口和未完成预留状态的不可变快照。
public struct RoomAdmissionState: Equatable, Sendable {
    /// 符合投递条件的成员数。
    public let eligibleMemberCount: Int
    /// 命令窗口快照。
    public let commandWindow: CapacityWindow
    /// 扇出工作窗口快照。
    public let fanoutWindow: CapacityWindow
    /// 尚未释放的目标工作量。
    public let outstandingFanoutUnits: Int
    /// 尚未关闭的源计划数。
    public let outstandingPlans: Int

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - eligibleMemberCount: 符合投递条件的成员数。
    ///   - commandWindow: 命令窗口快照。
    ///   - fanoutWindow: 扇出工作窗口快照。
    ///   - outstandingFanoutUnits: 尚未释放的目标工作量。
    ///   - outstandingPlans: 尚未关闭的源计划数。
    ///
    /// 要求成员数和两项未完成计数非负，否则抛出 invalidNonNegativeValue；不与容量配置比较。
    public init(
        eligibleMemberCount: Int,
        commandWindow: CapacityWindow,
        fanoutWindow: CapacityWindow,
        outstandingFanoutUnits: Int,
        outstandingPlans: Int
    ) throws {
        guard eligibleMemberCount >= 0,
              outstandingFanoutUnits >= 0,
              outstandingPlans >= 0
        else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.eligibleMemberCount = eligibleMemberCount
        self.commandWindow = commandWindow
        self.fanoutWindow = fanoutWindow
        self.outstandingFanoutUnits = outstandingFanoutUnits
        self.outstandingPlans = outstandingPlans
    }

    /// 预留一个命令、目标成本及一个计划，返回新快照；内部调用要求外层已检查计数增长可表示且符合容量。
    func reserving(cost: FanoutCost) throws -> RoomAdmissionState {
        try RoomAdmissionState(
            eligibleMemberCount: eligibleMemberCount,
            commandWindow: commandWindow.reserving(1),
            fanoutWindow: fanoutWindow.reserving(cost.targetCount),
            outstandingFanoutUnits: outstandingFanoutUnits + cost.targetCount,
            outstandingPlans: outstandingPlans + 1
        )
    }

    /// 仅减少已完成目标成本，保留窗口使用量及计划数；释放超过未完成量时抛出 releaseExceedsReservation。
    public func releasing(completedUnitCost: FanoutCost) throws -> RoomAdmissionState {
        guard completedUnitCost.targetCount <= outstandingFanoutUnits else {
            throw FanoutAdmissionMutationError.releaseExceedsReservation
        }
        return try RoomAdmissionState(
            eligibleMemberCount: eligibleMemberCount,
            commandWindow: commandWindow,
            fanoutWindow: fanoutWindow,
            outstandingFanoutUnits: outstandingFanoutUnits - completedUnitCost.targetCount,
            outstandingPlans: outstandingPlans
        )
    }
}

/// 分片准入租约及其窗口预算，身份与代际用于持久化预留关联。
public struct ShardAdmissionLease: Equatable, Sendable {
    /// 分片租约身份。
    public let id: ShardAdmissionLeaseID
    /// 正租约代际，此构造器不限制到 Int64.max。
    public let generation: UInt64
    /// 租约排他截止时间，构造器不校验有限性。
    public let validUntil: Date
    /// 租约命令窗口。
    public let commandWindow: CapacityWindow
    /// 租约扇出工作窗口。
    public let fanoutWindow: CapacityWindow
    /// 分片未完成工作上限。
    public let maxOutstandingFanoutUnits: Int
    /// 分片未完成计划上限。
    public let maxOutstandingPlans: Int

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - id: 分片租约身份。
    ///   - generation: 正租约代际，此构造器不限制到 Int64.max。
    ///   - validUntil: 租约排他截止时间，构造器不校验有限性。
    ///   - commandWindow: 租约命令窗口。
    ///   - fanoutWindow: 租约扇出工作窗口。
    ///   - maxOutstandingFanoutUnits: 分片未完成工作上限。
    ///   - maxOutstandingPlans: 分片未完成计划上限。
    ///
    /// 要求代际为正、两项未完成上限非负，否则抛出 invalidGeneration 或 invalidNonNegativeValue；不判断当前是否过期。
    public init(
        id: ShardAdmissionLeaseID,
        generation: UInt64,
        validUntil: Date,
        commandWindow: CapacityWindow,
        fanoutWindow: CapacityWindow,
        maxOutstandingFanoutUnits: Int,
        maxOutstandingPlans: Int
    ) throws {
        guard generation > 0 else {
            throw V2CoreError.invalidGeneration
        }
        guard maxOutstandingFanoutUnits >= 0, maxOutstandingPlans >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.id = id
        self.generation = generation
        self.validUntil = validUntil
        self.commandWindow = commandWindow
        self.fanoutWindow = fanoutWindow
        self.maxOutstandingFanoutUnits = maxOutstandingFanoutUnits
        self.maxOutstandingPlans = maxOutstandingPlans
    }

    /// 仅当截止时间严格晚于判断时间才有效，恰好相等视为过期；不执行额外有限值校验。
    public func isValid(at instant: Date) -> Bool {
        validUntil > instant
    }
}

/// 分片租约与未完成计数快照，允许缺失租约并由准入入口明确拒绝。
public struct ShardAdmissionState: Equatable, Sendable {
    /// 当前可选租约。
    public let lease: ShardAdmissionLease?
    /// 分片未完成目标工作量。
    public let outstandingFanoutUnits: Int
    /// 分片未完成源计划数。
    public let outstandingPlans: Int

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - lease: 当前可选租约。
    ///   - outstandingFanoutUnits: 分片未完成目标工作量。
    ///   - outstandingPlans: 分片未完成源计划数。
    ///
    /// 校验两项未完成计数非负，不要求租约存在或有效。
    public init(
        lease: ShardAdmissionLease?,
        outstandingFanoutUnits: Int,
        outstandingPlans: Int
    ) throws {
        guard outstandingFanoutUnits >= 0, outstandingPlans >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.lease = lease
        self.outstandingFanoutUnits = outstandingFanoutUnits
        self.outstandingPlans = outstandingPlans
    }

    /// 预留一个命令、目标成本及一个计划，返回新快照；内部调用要求外层已检查计数增长可表示且符合容量。
    func reserving(cost: FanoutCost) throws -> ShardAdmissionState {
        guard let lease else {
            throw FanoutAdmissionMutationError.missingLease
        }
        return try ShardAdmissionState(
            lease: try ShardAdmissionLease(
                id: lease.id,
                generation: lease.generation,
                validUntil: lease.validUntil,
                commandWindow: lease.commandWindow.reserving(1),
                fanoutWindow: lease.fanoutWindow.reserving(cost.targetCount),
                maxOutstandingFanoutUnits: lease.maxOutstandingFanoutUnits,
                maxOutstandingPlans: lease.maxOutstandingPlans
            ),
            outstandingFanoutUnits: outstandingFanoutUnits + cost.targetCount,
            outstandingPlans: outstandingPlans + 1
        )
    }

    /// 仅减少已完成目标成本，保留窗口使用量及计划数；释放超过未完成量时抛出 releaseExceedsReservation。
    public func releasing(completedUnitCost: FanoutCost) throws -> ShardAdmissionState {
        guard completedUnitCost.targetCount <= outstandingFanoutUnits else {
            throw FanoutAdmissionMutationError.releaseExceedsReservation
        }
        return try ShardAdmissionState(
            lease: lease,
            outstandingFanoutUnits: outstandingFanoutUnits - completedUnitCost.targetCount,
            outstandingPlans: outstandingPlans
        )
    }
}

/// 一次命令的目标成本计算规则。
public struct FanoutAdmissionRequest: Equatable, Sendable {
    /// 按符合条件成员数或明确目标数计费。
    public let targetRule: FanoutTargetRule

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - targetRule: 按符合条件成员数或明确目标数计费。
    ///
    /// 保存规则，不计算成本或校验关联目标。
    public init(targetRule: FanoutTargetRule) {
        self.targetRule = targetRule
    }
}

/// 接受结果携带的成本与分片租约绑定，供后续释放和审计关联。
public struct FanoutAdmissionReservation: Equatable, Sendable {
    /// 本次预留的目标成本。
    public let cost: FanoutCost
    /// 预留所用租约身份。
    public let shardLeaseID: ShardAdmissionLeaseID
    /// 预留所用租约代际。
    public let shardLeaseGeneration: UInt64

    /// 构造容量领域快照。
    ///
    /// - Parameters:
    ///   - cost: 本次预留的目标成本。
    ///   - shardLeaseID: 预留所用租约身份。
    ///   - shardLeaseGeneration: 预留所用租约代际。
    ///
    /// 保存预留元数据，不校验租约代际、有效性或持久化状态。
    public init(cost: FanoutCost, shardLeaseID: ShardAdmissionLeaseID, shardLeaseGeneration: UInt64) {
        self.cost = cost
        self.shardLeaseID = shardLeaseID
        self.shardLeaseGeneration = shardLeaseGeneration
    }
}

/// 无法执行准入的分片租约状态。
public enum FanoutAdmissionUnavailableReason: Equatable, Sendable {
    /// 分片没有租约。
    case missingShardLease
    /// 分片租约未通过当前时间有效性判断。
    case expiredShardLease
}

/// 纯准入结果，接受结果仍需调用者持久化。
public enum FanoutAdmissionResult: Equatable, Sendable {
    /// 返回成本及两个更新后的状态；必须与源事件、发件箱或计划在同一事务中保存。
    case accepted(
        reservation: FanoutAdmissionReservation,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState
    )
    /// 容量或配置一致性检查失败，返回建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 租约不可用，携带明确原因。
    case unavailable(FanoutAdmissionUnavailableReason)
}

/// 容量预留与释放状态错误。
public enum FanoutAdmissionMutationError: Error, Equatable, Sendable {
    /// 窗口无法容纳指定增量。
    case capacityExceeded
    /// 变更分片预留时没有租约。
    case missingLease
    /// 释放成本超过未完成量，或关闭计划时没有可释放计划计数。
    case releaseExceedsReservation
}

/// 同时计算房间与分片的扇出预留和完成释放，不执行事务或并发互斥。
public enum FanoutAdmissionEvaluator {
    /// 先检查分片租约，再计算成本并同时检查房间和分片容量。
    ///
    /// 要求房间窗口上限与配置一致、两个命令窗口可加一、扇出窗口与未完成计数可容纳成本及新计划。
    /// 通过后返回两个新快照及租约绑定；不修改输入，不检查后台并发配置。
    /// 未完成计数使用普通 Int 加法，调用方必须保证加法可表示；构造器的非负校验本身不防止极大输入溢出。
    public static func reserve(
        request: FanoutAdmissionRequest,
        profile: RoomCapacityProfile,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState,
        now: Date
    ) throws -> FanoutAdmissionResult {
        guard let lease = shardState.lease else {
            return .unavailable(.missingShardLease)
        }
        guard lease.isValid(at: now) else {
            return .unavailable(.expiredShardLease)
        }

        let cost = try FanoutCostCalculator.cost(
            for: request.targetRule,
            eligibleMemberCount: roomState.eligibleMemberCount
        )
        guard roomState.eligibleMemberCount <= profile.maxEligibleMembers,
              roomState.commandWindow.limit == profile.maxCommandsPerWindow,
              roomState.fanoutWindow.limit == profile.maxFanoutUnitsPerWindow,
              roomState.commandWindow.canReserve(1),
              roomState.fanoutWindow.canReserve(cost.targetCount),
              roomState.outstandingFanoutUnits + cost.targetCount <= profile.maxOutstandingFanoutUnits,
              roomState.outstandingPlans + 1 <= profile.maxOutstandingPlans,
              lease.commandWindow.canReserve(1),
              lease.fanoutWindow.canReserve(cost.targetCount),
              shardState.outstandingFanoutUnits + cost.targetCount <= lease.maxOutstandingFanoutUnits,
              shardState.outstandingPlans + 1 <= lease.maxOutstandingPlans
        else {
            return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds)
        }

        let reservedRoomState = try roomState.reserving(cost: cost)
        let reservedShardState = try shardState.reserving(cost: cost)
        return .accepted(
            reservation: FanoutAdmissionReservation(
                cost: cost,
                shardLeaseID: lease.id,
                shardLeaseGeneration: lease.generation
            ),
            roomState: reservedRoomState,
            shardState: reservedShardState
        )
    }

    /// 释放一个不可变完成单元的目标成本，按需关闭对应计划。
    ///
    /// - Parameters:
    ///   - completedUnit: 本次完成的目标成本。
    ///   - roomState: 房间当前预留状态。
    ///   - shardState: 分片当前预留状态。
    ///   - closesPlan: 仅该源计划最后一个释放单元应为 true。
    /// - Returns: 同步减少工作量，且按需各减少一个计划的新状态。
    /// - Throws: 任一释放超量或关闭时计划数为零，抛出 releaseExceedsReservation。
    ///
    /// 不退回速率窗口使用量，也不检查单元是否已持久释放；调用方负责同事务与幂等保护。
    public static func release(
        completedUnit: FanoutCost,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState,
        closesPlan: Bool
    ) throws -> (roomState: RoomAdmissionState, shardState: ShardAdmissionState) {
        let releasedRoom = try roomState.releasing(completedUnitCost: completedUnit)
        let releasedShard = try shardState.releasing(completedUnitCost: completedUnit)
        guard closesPlan else { return (releasedRoom, releasedShard) }
        guard releasedRoom.outstandingPlans > 0, releasedShard.outstandingPlans > 0 else {
            throw FanoutAdmissionMutationError.releaseExceedsReservation
        }
        return (
            try RoomAdmissionState(
                eligibleMemberCount: releasedRoom.eligibleMemberCount,
                commandWindow: releasedRoom.commandWindow,
                fanoutWindow: releasedRoom.fanoutWindow,
                outstandingFanoutUnits: releasedRoom.outstandingFanoutUnits,
                outstandingPlans: releasedRoom.outstandingPlans - 1
            ),
            try ShardAdmissionState(
                lease: releasedShard.lease,
                outstandingFanoutUnits: releasedShard.outstandingFanoutUnits,
                outstandingPlans: releasedShard.outstandingPlans - 1
            )
        )
    }
}

/// 仅预留命令速率的大群混合投递准入路径。
///
/// 房间日志承担可靠读取，不按成员创建投递单元；此路径不增加扇出窗口、未完成目标量或计划数。
public enum V2CommandOnlyAdmissionEvaluator {
    /// 检查租约有效、房间成员上限及窗口配置一致后，仅为房间和分片命令窗口各预留一项，返回零目标成本；不检查或增加未完成扇出预算。
    public static func reserve(
        profile: RoomCapacityProfile,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState,
        now: Date
    ) throws -> FanoutAdmissionResult {
        guard let lease = shardState.lease else { return .unavailable(.missingShardLease) }
        guard lease.isValid(at: now) else { return .unavailable(.expiredShardLease) }
        guard roomState.eligibleMemberCount <= profile.maxEligibleMembers,
              roomState.commandWindow.limit == profile.maxCommandsPerWindow,
              roomState.fanoutWindow.limit == profile.maxFanoutUnitsPerWindow,
              roomState.commandWindow.canReserve(1),
              lease.commandWindow.canReserve(1)
        else { return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds) }

        let nextRoom = try RoomAdmissionState(
            eligibleMemberCount: roomState.eligibleMemberCount,
            commandWindow: roomState.commandWindow.reserving(1),
            fanoutWindow: roomState.fanoutWindow,
            outstandingFanoutUnits: roomState.outstandingFanoutUnits,
            outstandingPlans: roomState.outstandingPlans
        )
        let nextLease = try ShardAdmissionLease(
            id: lease.id,
            generation: lease.generation,
            validUntil: lease.validUntil,
            commandWindow: lease.commandWindow.reserving(1),
            fanoutWindow: lease.fanoutWindow,
            maxOutstandingFanoutUnits: lease.maxOutstandingFanoutUnits,
            maxOutstandingPlans: lease.maxOutstandingPlans
        )
        let nextShard = try ShardAdmissionState(
            lease: nextLease,
            outstandingFanoutUnits: shardState.outstandingFanoutUnits,
            outstandingPlans: shardState.outstandingPlans
        )
        return .accepted(
            reservation: .init(cost: try .init(targetCount: 0), shardLeaseID: lease.id, shardLeaseGeneration: lease.generation),
            roomState: nextRoom,
            shardState: nextShard
        )
    }
}

/// 完成单元从收集进度、终结到释放预留的状态。
public enum CompletionUnitState: Equatable, Sendable {
    /// 仍在记录提交或策略跳过进度。
    case pending
    /// 所有目标都有终结结果，等待释放预留。
    case terminal
    /// 预留已由该值实例释放。
    case released
}

/// 有界目标范围的进度与单次释放状态机，目标范围本身由持久化层记录。
///
/// 值语义只约束当前实例；复制或重新加载后仍需事务和幂等比较防止重复释放。
public struct FanoutCompletionUnit: Equatable, Sendable {
    /// 持久完成单元身份。
    public let id: CompletionUnitID
    /// 固定非负目标数。
    public let targetCount: Int
    /// 已提交目标累计数。
    public private(set) var committedTargetCount: Int
    /// 策略跳过目标累计数。
    public private(set) var policySkippedTargetCount: Int
    /// 当前进度与释放状态。
    public private(set) var state: CompletionUnitState

    /// 以固定非负目标数创建 pending 单元，两个进度计数为零；负数抛出 invalidNonNegativeValue。
    public init(id: CompletionUnitID, targetCount: Int) throws {
        guard targetCount >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.id = id
        self.targetCount = targetCount
        self.committedTargetCount = 0
        self.policySkippedTargetCount = 0
        self.state = .pending
    }

    /// 已提交与策略跳过目标数之和，不包含仍待处理的目标。
    public var terminalTargetCount: Int {
        committedTargetCount + policySkippedTargetCount
    }

    /// 累计已提交目标，要求 pending、增量非负且总进度不超过目标数，否则抛出 invalidProgress。
    public mutating func recordCommittedTargets(_ count: Int) throws {
        try recordTerminalTargets(count, asPolicySkipped: false)
    }

    /// 累计因策略不再需要投递的目标，与提交进度共同决定是否完成。
    public mutating func recordPolicySkippedTargets(_ count: Int) throws {
        try recordTerminalTargets(count, asPolicySkipped: true)
    }

    /// 仅当仍为 pending 且总终结数等于目标数时转为 terminal，否则抛出 cannotBecomeTerminal；零目标单元可立即终结。
    public mutating func markTerminal() throws {
        guard state == .pending, terminalTargetCount == targetCount else {
            throw CompletionUnitMutationError.cannotBecomeTerminal
        }
        state = .terminal
    }

    /// 仅从 terminal 转为 released 并返回完整成本，否则抛出 cannotRelease；调用者需把状态与房间、分片释放在同一源房间事务中保存。
    public mutating func releaseReservation() throws -> FanoutCost {
        guard state == .terminal else {
            throw CompletionUnitMutationError.cannotRelease
        }
        state = .released
        return try FanoutCost(targetCount: targetCount)
    }

    /// 按提交或策略跳过类别累计进度；调用方必须保证加法可表示为 Int，当前实现没有溢出报告分支。
    private mutating func recordTerminalTargets(_ count: Int, asPolicySkipped: Bool) throws {
        guard state == .pending, count >= 0, terminalTargetCount + count <= targetCount else {
            throw CompletionUnitMutationError.invalidProgress
        }
        if asPolicySkipped {
            policySkippedTargetCount += count
        } else {
            committedTargetCount += count
        }
    }
}

/// 完成单元进度或状态转换错误。
public enum CompletionUnitMutationError: Error, Equatable, Sendable {
    /// 非 pending、负增量或累计进度超过目标数量。
    case invalidProgress
    /// 状态或进度不允许终结。
    case cannotBecomeTerminal
    /// 不是 terminal 状态，不能释放或重复释放。
    case cannotRelease
}
