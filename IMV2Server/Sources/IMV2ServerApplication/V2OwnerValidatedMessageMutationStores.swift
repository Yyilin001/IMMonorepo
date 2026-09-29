import IMV2ServerContracts
import Foundation
import IMV2Core

/// 仅面向运行时使用的归属校验能力。
///
/// 对外的命令服务不感知路由；路由层之后的存储必须原样传入已选定的分片与代次，
/// 事务内据此校验房间归属后才能提交变更。
public protocol V2OwnerValidatedMessageEditStore: Sendable {
    /// 按房间归属应用消息编辑。
    ///
    /// - Parameters:
    ///   - command: 消息编辑命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 编辑结果。
    /// - Throws: 归属已变更、权限不足或持久化失败时抛出。
    func editOwnerValidated(command: V2EditMessageCommand, ownerRoute: V2RoomShardRoute,
        capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageEditOutcome
}

/// 按房间归属执行消息撤回的能力。
public protocol V2OwnerValidatedMessageWithdrawalStore: Sendable {
    /// 按房间归属撤回消息。
    ///
    /// - Parameters:
    ///   - command: 消息撤回命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果。
    /// - Throws: 归属已变更、权限不足或持久化失败时抛出。
    func withdrawOwnerValidated(command: V2WithdrawMessageCommand, ownerRoute: V2RoomShardRoute,
        capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome
}

/// 按房间归属执行消息表情变更的能力。
public protocol V2OwnerValidatedMessageReactionStore: Sendable {
    /// 按房间归属新增或移除消息表情。
    ///
    /// - Parameters:
    ///   - command: 表情变更命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 表情变更结果。
    /// - Throws: 归属已变更、权限不足或持久化失败时抛出。
    func changeOwnerValidated(command: V2ChangeMessageReactionCommand, ownerRoute: V2RoomShardRoute,
        capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageReactionOutcome
}
