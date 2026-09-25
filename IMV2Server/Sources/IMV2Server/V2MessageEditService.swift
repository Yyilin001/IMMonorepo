import Foundation
import IMV2Core

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

/// 消息编辑服务。
///
/// 它把已认证请求转换为编辑命令，并在此处注入正文长度上限，
/// 使长度校验在持久化之前就以部署策略为准。
public struct V2MessageEditService: Sendable {
    private let store: any V2MessageEditStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageEditIDFactory
    private let now: @Sendable () -> Date
    private let maximumTextUTF8Bytes: Int

    /// 创建编辑服务。
    ///
    /// - Parameters:
    ///   - store: 编辑持久化边界。
    ///   - capacityProfile: 本次部署使用的容量档位。
    ///   - maximumTextUTF8Bytes: 编辑后正文允许的最大 UTF-8 字节数。
    ///   - identifiers: 标识工厂，默认使用随机 UUID。
    ///   - now: 服务端时钟，默认取当前时间。
    public init(store: any V2MessageEditStore, capacityProfile: V2CapacityProfile, maximumTextUTF8Bytes: Int, identifiers: V2MessageEditIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.capacityProfile = capacityProfile; self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.identifiers = identifiers; self.now = now
    }

    /// 执行一次消息编辑。
    ///
    /// - Parameter request: 已认证的编辑请求。
    /// - Returns: 编辑处理结果。
    /// - Throws: 存储拒绝或持久化失败时抛出。
    public func edit(_ request: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome {
        let eventID = try identifiers.make()
        return try await store.edit(
            command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, expectedMessageRevision: request.expectedMessageRevision, text: request.text, maximumUTF8Bytes: maximumTextUTF8Bytes),
            capacityProfile: capacityProfile, eventID: eventID, now: now()
        )
    }
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
