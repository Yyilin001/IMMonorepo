import IMV2ServerContracts
import Foundation
import IMV2Core

/// 消息编辑的处理结果。
public enum V2MessageEditOutcome: Equatable, Sendable {
    /// 本次调用实际完成了编辑。
    case edited(V2MessageEdit)
    /// 该操作此前已成功提交，本次为重放，返回相同编辑结果。
    case idempotent(V2MessageEdit)
    /// 同一操作标识提交了与首次不同的载荷。
    case idempotencyConflict
    /// 消息修订与期望不一致；关联值为当前服务端修订。
    case revisionConflict(current: UInt64)
    /// 目标消息已撤回，无法编辑。
    case alreadyWithdrawn
    /// 触发限流；关联值为建议的重试等待秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 房间写入准入暂时不可用。
    case unavailable(V2CommandAdmissionUnavailableReason)
}

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

/// 消息编辑存储的错误分类。
public enum V2MessageEditStoreError: Error, Equatable, Sendable {
    /// 目标房间不存在。
    case roomNotFound
    /// 目标消息不存在。
    case messageNotFound
    /// 发起者不是该消息的作者。
    case actorNotAuthor
    /// 持久化状态与预期不一致。
    case corruptPersistenceState
}
