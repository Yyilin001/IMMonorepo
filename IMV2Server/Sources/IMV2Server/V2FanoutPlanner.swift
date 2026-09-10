import Foundation
import IMV2Core

/// 单次扇出规划的统计结果。
public struct V2FanoutPlanningResult: Equatable, Sendable {
    /// 本次新建的完成单元数量。
    public let createdCompletionUnits: Int
    /// 本次新建的投递任务数量。
    public let createdDeliveries: Int
    /// 该触发此前已完成规划，本次未重复创建。
    public let wasAlreadyPlanned: Bool

    /// 保存规划结果。
    ///
    /// - Parameters:
    ///   - createdCompletionUnits: 新建完成单元数量。
    ///   - createdDeliveries: 新建投递任务数量。
    ///   - wasAlreadyPlanned: 是否已规划过。
    public init(createdCompletionUnits: Int, createdDeliveries: Int, wasAlreadyPlanned: Bool) {
        self.createdCompletionUnits = createdCompletionUnits
        self.createdDeliveries = createdDeliveries
        self.wasAlreadyPlanned = wasAlreadyPlanned
    }
}

/// 扇出规划的持久化能力。
public protocol V2FanoutPlanStore: Sendable {
    /// 规划一个扇出触发。
    ///
    /// - Parameters:
    ///   - trigger: 待规划的触发来源。
    ///   - pageSize: 成员枚举分页大小。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 本次规划结果。
    /// - Throws: 准入不足、成员修订失效或持久化失败时抛出。
    func plan(_ trigger: V2FanoutPlanTrigger, pageSize: Int, now: Date) async throws -> V2FanoutPlanningResult

    /// 批量规划多个扇出触发。
    ///
    /// - Parameters:
    ///   - triggers: 待规划的触发列表。
    ///   - pageSize: 成员枚举分页大小。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 与输入顺序对应的规划结果。
    /// - Throws: 任一触发规划失败时抛出。
    func planBatch(_ triggers: [V2FanoutPlanTrigger], pageSize: Int, now: Date) async throws -> [V2FanoutPlanningResult]
}

public extension V2FanoutPlanStore {
    /// 默认批量规划实现。
    ///
    /// 不具备集合式批处理能力的存储会退化为逐条规划，语义与单条调用完全一致；
    /// PostgreSQL 实现覆盖该方法，使一次中继认领按受众分页计费，而不是每个来源事件一个事务。
    ///
    /// - Parameters:
    ///   - triggers: 待规划的触发列表。
    ///   - pageSize: 成员枚举分页大小。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 与输入顺序对应的规划结果。
    /// - Throws: 任一触发规划失败时抛出，错误直接传播不做部分吞并。
    func planBatch(
        _ triggers: [V2FanoutPlanTrigger],
        pageSize: Int,
        now: Date
    ) async throws -> [V2FanoutPlanningResult] {
        var results: [V2FanoutPlanningResult] = []
        results.reserveCapacity(triggers.count)
        for trigger in triggers {
            results.append(try await plan(trigger, pageSize: pageSize, now: now))
        }
        return results
    }
}

/// 扇出规划服务。
///
/// 规划过程负责枚举不可变的成员修订，并把投递工作拆成有界完成单元；
/// 因此来源房间容量按完成单元释放，而不是按每个接收者回调释放。
public struct V2FanoutPlanner: Sendable {
    private let store: any V2FanoutPlanStore
    private let pageSize: Int
    private let now: @Sendable () -> Date

    /// 组合规划存储与分页大小。
    ///
    /// - Parameters:
    ///   - store: 实际执行规划的存储实现。
    ///   - pageSize: 成员枚举分页大小，需大于零。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 分页大小非正时直接失败，避免运行期出现无界枚举。
    public init(
        store: any V2FanoutPlanStore,
        pageSize: Int,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(pageSize > 0)
        self.store = store
        self.pageSize = pageSize
        self.now = now
    }

    /// 规划单个扇出触发。
    ///
    /// - Parameter trigger: 待规划的触发来源。
    /// - Returns: 本次规划结果。
    /// - Throws: 存储实现抛出的错误。
    public func plan(_ trigger: V2FanoutPlanTrigger) async throws -> V2FanoutPlanningResult {
        try await store.plan(trigger, pageSize: pageSize, now: now())
    }

    /// 批量规划扇出触发，空输入直接返回空结果。
    ///
    /// - Parameter triggers: 待规划的触发列表。
    /// - Returns: 与输入顺序对应的规划结果。
    /// - Throws: 存储实现抛出的错误。
    public func planBatch(_ triggers: [V2FanoutPlanTrigger]) async throws -> [V2FanoutPlanningResult] {
        guard !triggers.isEmpty else { return [] }
        return try await store.planBatch(triggers, pageSize: pageSize, now: now())
    }
}
