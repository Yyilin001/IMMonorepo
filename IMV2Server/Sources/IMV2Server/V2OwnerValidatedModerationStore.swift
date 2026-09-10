import Foundation
import IMV2Core

/// 面向运行时的房间归属执行能力，与普通授权和可信安全授权是并行的两条入口。
///
/// 与 `V2ModerationStore`、`V2TrustedSafetyModerationStore` 的差别在于：两个入口都必须携带
/// 路由层已选定的房间归属，事务内据此校验归属，避免命令落到错误的逻辑分片上。
public protocol V2OwnerValidatedModerationStore: Sendable {
    /// 按房间归属执行普通审核命令。
    ///
    /// - Parameters:
    ///   - command: 待应用的审核命令，动作范围由实现决定。
    ///   - ownerRoute: 已选定的房间归属；与房间当前记录不一致时事务拒绝提交。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识，重放同标识命令不得产生第二次效果。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻，用于审计与留存计算。
    /// - Returns: 审核结果。
    /// - Throws: 归属已变更、权限不足或持久化失败时抛出。
    func applyOwnerValidated(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2ModerationOutcome

    /// 按房间归属执行可信安全审核命令。
    ///
    /// - Parameters:
    ///   - command: 待应用的可信安全审核命令，可覆盖普通入口不支持的动作。
    ///   - ownerRoute: 已选定的房间归属；与房间当前记录不一致时事务拒绝提交。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识，重放同标识命令不得产生第二次效果。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻，用于审计与留存计算。
    /// - Returns: 审核结果。
    /// - Throws: 归属已变更、命令动作不受可信安全入口支持或持久化失败时抛出。
    func applyTrustedSafetyOwnerValidated(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2ModerationOutcome
}
