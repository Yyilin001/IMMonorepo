import IMV2ServerContracts
import Foundation
import IMV2Core

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

/// 消息表态的处理结果。
public enum V2MessageReactionOutcome: Equatable, Sendable {
    /// 本次调用实际改变了表态状态。
    case changed(V2MessageReactionChange)
    /// 该操作此前已成功提交，本次为重放，返回相同变更。
    case idempotent(V2MessageReactionChange)
    /// 同一操作标识提交了与首次不同的载荷。
    case idempotencyConflict
    /// 目标状态与请求一致，无需改动。
    case alreadyInDesiredState
    /// 触发限流；关联值为建议的重试等待秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 房间写入准入暂时不可用。
    case unavailable(V2CommandAdmissionUnavailableReason)
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

/// 消息表态服务。
///
/// 它把已认证请求转换为存储命令，并为每次调用分配稳定的来源事件标识。
public struct V2MessageReactionService: Sendable {
    private let store: any V2MessageReactionStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageReactionIDFactory
    private let now: @Sendable () -> Date

    /// 创建表态服务。
    ///
    /// - Parameters:
    ///   - store: 表态持久化边界。
    ///   - capacityProfile: 本次部署使用的容量档位。
    ///   - identifiers: 标识工厂，默认使用随机 UUID。
    ///   - now: 服务端时钟，默认取当前时间。
    public init(store: any V2MessageReactionStore, capacityProfile: V2CapacityProfile, identifiers: V2MessageReactionIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.capacityProfile = capacityProfile; self.identifiers = identifiers; self.now = now
    }

    /// 执行一次消息表态变更。
    ///
    /// - Parameter request: 已认证的表态请求。
    /// - Returns: 表态处理结果。
    /// - Throws: 存储拒绝或持久化失败时抛出。
    public func change(_ request: V2AuthenticatedMessageReaction) async throws -> V2MessageReactionOutcome {
        let eventID = try identifiers.make()
        return try await store.change(command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, reaction: request.reaction, action: request.action), capacityProfile: capacityProfile, eventID: eventID, now: now())
    }
}

/// 消息表态存储的错误分类。
public enum V2MessageReactionStoreError: Error, Equatable, Sendable {
    /// 目标房间不存在。
    case roomNotFound
    /// 目标消息不存在。
    case messageNotFound
    /// 发起者不是房间成员。
    case actorNotMember
    /// 目标消息已撤回。
    case messageWithdrawn
    /// 该消息的表态数量已达上限。
    case reactionLimitReached
    /// 持久化状态与预期不一致。
    case corruptPersistenceState
}
