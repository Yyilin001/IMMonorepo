import Foundation
import IMV2Core

/// 通过认证的审核命令。
///
/// 网关已完成发起者认证。该边界刻意不接受调用方自报的角色或安全服务身份：
/// 这些信息由权威存储或单独的特权接口推导。
public struct V2AuthenticatedModeration: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起审核的用户。
    public let actorUserID: UserID
    /// 本次审核的幂等操作标识。
    public let operationID: ModerationOperationID
    /// 审核动作。
    public let action: V2ModerationAction
    /// 目标用户；仅部分动作需要。
    public let targetUserID: UserID?
    /// 目标消息；仅部分动作需要。
    public let messageID: MessageID?
    /// 禁言到期时刻；仅禁言动作需要。
    public let muteUntil: Date?
    /// 审核原因码。
    public let reasonCode: V2ModerationReasonCode

    /// 保存已认证的审核命令。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起审核的用户。
    ///   - operationID: 幂等操作标识。
    ///   - action: 审核动作。
    ///   - targetUserID: 目标用户。
    ///   - messageID: 目标消息。
    ///   - muteUntil: 禁言到期时刻。
    ///   - reasonCode: 审核原因码。
    public init(roomID: RoomID, actorUserID: UserID, operationID: ModerationOperationID, action: V2ModerationAction, targetUserID: UserID? = nil, messageID: MessageID? = nil, muteUntil: Date? = nil, reasonCode: V2ModerationReasonCode) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.action = action
        self.targetUserID = targetUserID
        self.messageID = messageID
        self.muteUntil = muteUntil
        self.reasonCode = reasonCode
    }
}

/// 审核结果。
///
/// 结果不携带举报文本或消息正文：这些内容保留在权威审计存储中，
/// 绝不会成为通用的房间同步载荷。
public struct V2ModerationResult: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 本次审核的幂等操作标识。
    public let operationID: ModerationOperationID
    /// 审核动作。
    public let action: V2ModerationAction
    /// 目标用户。
    public let targetUserID: UserID?
    /// 目标消息。
    public let messageID: MessageID?
    /// 审核后的消息修订。
    public let messageRevision: UInt64?
    /// 成员修订。
    ///
    /// 仅在审计级移除成员时存在；它会随审核操作一同持久化，使重试返回原始的成员栅栏，
    /// 而不是读取可能已经变化的房间状态。
    public let membershipRevision: UInt64?
    /// 禁言到期时刻。
    public let muteUntil: Date?
    /// 审核事件在房间日志中的序号。
    public let roomSequence: UInt64
    /// 审核事件标识。
    public let eventID: EventID
    /// 审核事件创建时刻。
    public let createdAt: Date

    /// 校验并保存审核结果。
    ///
    /// 房间序号需大于零且可写入 `Int64`；消息修订与成员修订若存在，也必须为正且可写入 `Int64`。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 幂等操作标识。
    ///   - action: 审核动作。
    ///   - targetUserID: 目标用户。
    ///   - messageID: 目标消息。
    ///   - messageRevision: 审核后的消息修订。
    ///   - membershipRevision: 成员修订。
    ///   - muteUntil: 禁言到期时刻。
    ///   - roomSequence: 房间日志序号。
    ///   - eventID: 审核事件标识。
    ///   - createdAt: 事件创建时刻。
    /// - Throws: 任一修订或序号超出可编码范围时抛出
    ///   ``V2RevisionValidationError/outOfRange``。
    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction, targetUserID: UserID?, messageID: MessageID?, messageRevision: UInt64? = nil, membershipRevision: UInt64? = nil, muteUntil: Date?, roomSequence: UInt64, eventID: EventID, createdAt: Date) throws {
        guard roomSequence > 0, roomSequence <= UInt64(Int64.max),
              messageRevision.map({ $0 > 0 && $0 <= UInt64(Int64.max) }) ?? true,
              membershipRevision.map({ $0 > 0 && $0 <= UInt64(Int64.max) }) ?? true
        else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.operationID = operationID
        self.action = action
        self.targetUserID = targetUserID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.membershipRevision = membershipRevision
        self.muteUntil = muteUntil
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.createdAt = createdAt
    }
}

/// 审核执行结果。
public enum V2ModerationOutcome: Equatable, Sendable {
    /// 本次调用实际应用了审核。
    case applied(V2ModerationResult)
    /// 同一操作已应用过，返回其原有结果。
    case idempotent(V2ModerationResult)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 目标用户不是房间成员。
    case targetNotMember
    /// 消息此前已被屏蔽。
    case messageAlreadyRedacted
    /// 房间已处于动作要求的状态。
    case actionAlreadyInDesiredState
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入当前不可用，附带不可用原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
}

/// 审核命令的持久化能力。
///
/// 单个 PostgreSQL 事务必须完成：推导发起者角色、校验动作合法性、写入权威状态、
/// 追加房间事件与审计行、预留扇出计划、写入发件箱工作并持久化幂等结果。
public protocol V2ModerationStore: Sendable {
    /// 应用一次审核命令。
    ///
    /// - Parameters:
    ///   - command: 审核命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 审核结果。
    /// - Throws: 房间或消息不存在、无权限、动作不受支持或持久化失败时抛出。
    func apply(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome
}

/// 单独认证的安全服务房间控制命令。
///
/// 该命令刻意不接受调用方自报的发起者身份：服务实例使用部署时配置的受信审计主体，
/// 且无法通过 TCP 网关触达。
public struct V2TrustedSafetyRoomControl: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 本次控制的幂等操作标识。
    public let operationID: ModerationOperationID
    /// 控制动作，仅支持冻结与解冻。
    public let action: V2ModerationAction
    /// 控制原因码。
    public let reasonCode: V2ModerationReasonCode

    /// 校验并保存房间控制命令。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 幂等操作标识。
    ///   - action: 控制动作，仅接受冻结房间或解冻房间。
    ///   - reasonCode: 控制原因码。
    /// - Throws: 动作不是冻结或解冻时抛出
    ///   ``V2ModerationValidationError/invalidActionShape``。
    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction, reasonCode: V2ModerationReasonCode) throws {
        guard action == .freezeRoom || action == .unfreezeRoom else {
            throw V2ModerationValidationError.invalidActionShape
        }
        self.roomID = roomID
        self.operationID = operationID
        self.action = action
        self.reasonCode = reasonCode
    }
}

/// 特权安全审核命令。
///
/// 这些命令在服务进程内部构造，而不是从网关帧解码。屏蔽动作也包含在内，
/// 使延迟到达的内容审核结论与人工审核走同一条带审计的墓碑路径，
/// 且无需让服务账号成为房间成员。
public struct V2TrustedSafetyModeration: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 本次审核的幂等操作标识。
    public let operationID: ModerationOperationID
    /// 审核动作。
    public let action: V2ModerationAction
    /// 目标消息；仅屏蔽消息时存在。
    public let messageID: MessageID?
    /// 期望的消息修订；仅屏蔽消息时可以给出。
    public let expectedMessageRevision: UInt64?
    /// 审核原因码。
    public let reasonCode: V2ModerationReasonCode

    /// 校验并保存特权安全审核命令。
    ///
    /// 动作仅限冻结房间、解冻房间或屏蔽消息；屏蔽消息必须给出消息标识，
    /// 非屏蔽动作不得给出期望修订。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 幂等操作标识。
    ///   - action: 审核动作。
    ///   - messageID: 目标消息。
    ///   - expectedMessageRevision: 期望的消息修订。
    ///   - reasonCode: 审核原因码。
    /// - Throws: 动作与字段组合不匹配时抛出
    ///   ``V2ModerationValidationError/invalidActionShape``。
    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction, messageID: MessageID? = nil, expectedMessageRevision: UInt64? = nil, reasonCode: V2ModerationReasonCode) throws {
        guard action == .freezeRoom || action == .unfreezeRoom || action == .redactMessage else {
            throw V2ModerationValidationError.invalidActionShape
        }
        guard (action == .redactMessage) == (messageID != nil) else {
            throw V2ModerationValidationError.invalidActionShape
        }
        guard action == .redactMessage || expectedMessageRevision == nil else {
            throw V2ModerationValidationError.invalidActionShape
        }
        self.roomID = roomID
        self.operationID = operationID
        self.action = action
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
        self.reasonCode = reasonCode
    }
}

/// 特权安全审核的持久化能力。
public protocol V2TrustedSafetyModerationStore: Sendable {
    /// 应用一次特权安全审核命令。
    ///
    /// - Parameters:
    ///   - command: 审核命令，发起者由服务配置的受信主体提供。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 审核结果。
    /// - Throws: 房间或消息不存在、动作不受支持或持久化失败时抛出。
    func applyTrustedSafety(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome
}

/// 审核命令的事件与扇出标识生成器。
public struct V2ModerationIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    /// 注入 UUID 来源。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成一个事件标识。
    ///
    /// - Returns: 本次命令使用的标识组合。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> EventID {
        try .init(makeUUID().uuidString)
    }
}

/// 面向普通审核者的审核服务。
public struct V2ModerationService: Sendable {
    private let store: any V2ModerationStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2ModerationIDFactory
    private let now: @Sendable () -> Date

    /// 组合审核存储与运行参数。
    ///
    /// - Parameters:
    ///   - store: 执行审核的存储实现。
    ///   - capacityProfile: 固定的容量档位。
    ///   - identifiers: 事件与扇出标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2ModerationStore, capacityProfile: V2CapacityProfile, identifiers: V2ModerationIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    /// 应用一次已认证的审核命令。
    ///
    /// - Parameter request: 已认证的审核命令。
    /// - Returns: 审核结果；标识与授时由本方法补齐。
    /// - Throws: 命令构造失败、标识生成失败或存储判定失败时抛出。
    public func apply(_ request: V2AuthenticatedModeration) async throws -> V2ModerationOutcome {
        let eventID = try identifiers.make()
        let command = try V2ModerationCommand(
            roomID: request.roomID,
            actorUserID: request.actorUserID,
            operationID: request.operationID,
            action: request.action,
            targetUserID: request.targetUserID,
            messageID: request.messageID,
            muteUntil: request.muteUntil,
            reasonCode: request.reasonCode
        )
        return try await store.apply(command: command, capacityProfile: capacityProfile, eventID: eventID, now: now())
    }
}

/// 与 ``V2ModerationService`` 对应的特权版本。
///
/// 能否构造该对象是一个部署期的信任决定：只有已认证的安全服务或管理集成才会获得它
/// 及其配置的审计主体。
public struct V2TrustedSafetyModerationService: Sendable {
    private let store: any V2TrustedSafetyModerationStore
    private let safetyActorUserID: UserID
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2ModerationIDFactory
    private let now: @Sendable () -> Date

    /// 组合审核存储与固定的安全主体。
    ///
    /// - Parameters:
    ///   - store: 执行特权审核的存储实现。
    ///   - safetyActorUserID: 服务配置的受信审计主体。
    ///   - capacityProfile: 固定的容量档位。
    ///   - identifiers: 事件与扇出标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2TrustedSafetyModerationStore, safetyActorUserID: UserID, capacityProfile: V2CapacityProfile, identifiers: V2ModerationIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.safetyActorUserID = safetyActorUserID
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    /// 应用一次房间冻结或解冻控制。
    ///
    /// - Parameter request: 已认证的房间控制命令。
    /// - Returns: 审核结果。
    /// - Throws: 命令构造失败或存储判定失败时抛出。
    public func apply(_ request: V2TrustedSafetyRoomControl) async throws -> V2ModerationOutcome {
        try await apply(V2TrustedSafetyModeration(
            roomID: request.roomID,
            operationID: request.operationID,
            action: request.action,
            reasonCode: request.reasonCode
        ))
    }

    /// 应用一次特权安全审核命令。
    ///
    /// 命令中的发起者固定为部署时配置的安全主体，不接受调用方传入。
    ///
    /// - Parameter request: 特权安全审核命令。
    /// - Returns: 审核结果。
    /// - Throws: 命令构造失败、标识生成失败或存储判定失败时抛出。
    public func apply(_ request: V2TrustedSafetyModeration) async throws -> V2ModerationOutcome {
        let eventID = try identifiers.make()
        let command = try V2ModerationCommand(
            roomID: request.roomID,
            actorUserID: safetyActorUserID,
            operationID: request.operationID,
            action: request.action,
            messageID: request.messageID,
            expectedMessageRevision: request.expectedMessageRevision,
            reasonCode: request.reasonCode
        )
        return try await store.applyTrustedSafety(command: command, capacityProfile: capacityProfile, eventID: eventID, now: now())
    }
}

/// 审核存储错误。
public enum V2ModerationStoreError: Error, Equatable, Sendable {
    /// 房间不存在。
    case roomNotFound
    /// 消息不存在。
    case messageNotFound
    /// 发起者不具备执行该动作的权限。
    case actorNotAuthorized
    /// 该入口不支持请求的动作。
    case unsupportedAction
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
