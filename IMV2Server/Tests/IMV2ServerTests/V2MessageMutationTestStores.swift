import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure

/// 消息编辑的持久化边界。
public protocol V2MessageEditStore: Sendable {
    /// 在权威存储中执行一次消息编辑。
    ///
    /// - Parameters:
    ///   - command: 待执行的编辑命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 本次编辑的来源事件标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 编辑处理结果。
    /// - Throws: 房间/消息不存在、发起者非作者或持久化失败时抛出。
    func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageEditOutcome
}

/// 消息撤回的持久化能力。
///
/// 行锁、授权、准入预留、消息墓碑、事件与发件箱创建以及持久化操作重放，
/// 全部由存储在同一个房间分片事务内完成，调用方不能把它们拆到多个事务。
public protocol V2MessageWithdrawalStore: Sendable {
    /// 执行一次消息撤回。
    ///
    /// - Parameters:
    ///   - command: 撤回命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果。
    /// - Throws: 房间或消息不存在、发起者非作者、持久化失败时抛出。
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome
}

/// 消息表态的持久化边界。
public protocol V2MessageReactionStore: Sendable {
    /// 在权威存储中执行一次表态变更。
    ///
    /// - Parameters:
    ///   - command: 待执行的表态命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 本次变更的来源事件标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 表态处理结果。
    /// - Throws: 房间/消息不存在、非成员、消息已撤回或持久化失败时抛出。
    func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageReactionOutcome
}
