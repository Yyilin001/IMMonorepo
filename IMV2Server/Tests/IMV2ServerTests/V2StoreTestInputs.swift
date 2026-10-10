import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication

// Inputs and identifier factories used by direct-store regression fixtures.
// Runtime commands use their durable operation contracts.

/// A send is prepared once before the host batcher merges room turns.
public struct V2PreparedActorSend: Sendable {
    public let token: V2RoomActivationToken
    public let request: V2RoomWriteRequest
}

/// 一次已认证的消息编辑请求。
///
/// 适配器在完成身份与权限校验后构造该值；服务层只负责补齐事件标识并转交存储边界。
public struct V2AuthenticatedMessageEdit: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起编辑的已认证用户，必须是消息作者。
    public let actorUserID: UserID
    /// 该次编辑操作的稳定标识，用于幂等重试。
    public let operationID: MessageEditOperationID
    /// 被编辑的消息。
    public let messageID: MessageID
    /// 期望的消息修订，用于乐观并发校验。
    public let expectedMessageRevision: UInt64
    /// 编辑后的新正文。
    public let text: String

    /// 创建编辑请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起编辑的已认证用户。
    ///   - operationID: 该次编辑操作的稳定标识。
    ///   - messageID: 被编辑的消息。
    ///   - expectedMessageRevision: 期望的消息修订。
    ///   - text: 编辑后的新正文。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.messageID = messageID; self.expectedMessageRevision = expectedMessageRevision; self.text = text
    }
}

/// 为一次消息编辑生成来源事件标识。
public struct V2MessageEditIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    /// 创建标识工厂。
    ///
    /// - Parameter makeUUID: UUID 生成器，默认使用 `UUID.init`。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    /// 生成一个全新的来源事件标识。
    ///
    /// - Returns: 来源事件标识。
    /// - Throws: UUID 生成失败时抛出。
    public func make() throws -> EventID { try .init(makeUUID().uuidString) }
}

/// 通过认证的消息撤回请求。
public struct V2AuthenticatedMessageWithdrawal: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起撤回的用户。
    public let actorUserID: UserID
    /// 本次撤回的幂等操作标识。
    public let operationID: MessageWithdrawalOperationID
    /// 需要撤回的消息。
    public let messageID: MessageID
    /// 客户端观察到的消息修订，用于防止撤回他人在此期间的编辑结果。
    public let expectedMessageRevision: UInt64

    /// 保存已认证的撤回请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起撤回的用户。
    ///   - operationID: 幂等操作标识。
    ///   - messageID: 需要撤回的消息。
    ///   - expectedMessageRevision: 期望的消息修订。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
    }
}

/// 撤回命令的事件标识生成器。
public struct V2MessageWithdrawalIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    /// 注入 UUID 来源，默认使用系统实现。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包，测试可注入确定性实现。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成一个事件标识。
    ///
    /// - Returns: 本次命令使用的事件标识。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> EventID {
        try .init(makeUUID().uuidString)
    }
}

/// 一次已认证的消息表态请求。
///
/// HTTP/领域适配器在完成身份与权限校验后构造该值；
/// 服务层只负责补齐事件标识并转交存储边界。
public struct V2AuthenticatedMessageReaction: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起表态的已认证用户。
    public let actorUserID: UserID
    /// 该次表态操作的稳定标识，用于幂等重试。
    public let operationID: MessageReactionOperationID
    /// 被表态的消息。
    public let messageID: MessageID
    /// 表态内容（例如表情标识）。
    public let reaction: String
    /// 本次要执行的动作（添加或移除）。
    public let action: V2MessageReactionAction

    /// 创建表态请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起表态的已认证用户。
    ///   - operationID: 该次表态操作的稳定标识。
    ///   - messageID: 被表态的消息。
    ///   - reaction: 表态内容。
    ///   - action: 要执行的动作。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.messageID = messageID; self.reaction = reaction; self.action = action
    }
}

/// 为一次表态变更生成来源事件标识。
public struct V2MessageReactionIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    /// 创建标识工厂。
    ///
    /// - Parameter makeUUID: UUID 生成器，默认使用 `UUID.init`。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    /// 生成一对全新的来源事件标识。
    ///
    /// - Returns: 来源事件标识。
    /// - Throws: UUID 生成失败时抛出。
    public func make() throws -> EventID {
        try .init(makeUUID().uuidString)
    }
}

/// 群能力命令的事件标识生成器。
public struct V2GroupCapabilitiesIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    /// 注入 UUID 来源，默认使用系统实现。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包，测试可注入确定性实现。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成本次命令的事件标识。
    ///
    /// - Returns: 本次命令使用的事件标识。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> EventID { try .init(makeUUID().uuidString) }
}

/// 设置实时状态偏好后的结果。
public enum V2SetLiveActivityPreferencesOutcome: Equatable, Sendable {
    /// 本次调用实际更新了偏好。
    case updated(V2LiveActivityPreferences)
    /// 同一操作已提交过，返回其原有偏好。
    case idempotent(V2LiveActivityPreferences)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
}

/// 已读回执偏好变更结果。
public enum V2SetReadReceiptPreferencesOutcome: Equatable, Sendable {
    /// 本次调用实际更新了偏好。
    case updated(V2ReadReceiptPreferences)
    /// 同一操作已提交过，返回其原有偏好。
    case idempotent(V2ReadReceiptPreferences)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
}
