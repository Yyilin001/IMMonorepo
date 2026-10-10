import Foundation
import IMV2Core

/// 消息接受边界返回的业务结果。
///
/// 接受与幂等重放携带原始接受回执；容量拒绝、限流和策略拒绝不等于消息已写入。存储执行失败通过抛出错误报告。
public enum V2SendMessageOutcome: Equatable, Sendable {
    /// 本次操作新接受的消息，由存储完成相应持久化合同后返回。
    case accepted(V2AcceptedMessage)
    /// 同一客户端操作的等价重试，返回已持久化的原始回执。
    case idempotent(V2MessageAcceptanceReceipt)
    /// 同一幂等操作标识对应不同请求内容，不能作为原操作重放。
    case idempotencyConflict
    /// 准入限流及建议重试等待秒数；调用者负责转换为传输层响应。
    case rateLimited(retryAfterSeconds: Int)
    /// 房间写入准入当前不可用，附带容量或状态原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
    /// 已为本次操作持久化私有活动与输入能力状态，但没有创建消息或房间事件。
    case denied(V2DirectMessageDenied)

    /// 提取新接受或幂等重放的回执；其余业务结果返回 `nil`。
    public var acceptanceReceipt: V2MessageAcceptanceReceipt? {
        switch self {
        case .accepted(let message): message.receipt
        case .idempotent(let receipt): receipt
        case .idempotencyConflict, .rateLimited, .unavailable, .denied: nil
        }
    }
}

/// 私聊发送被拒绝后可呈现给发起者的私有时间线活动。
public struct V2DirectMessageDenied: Equatable, Sendable {
    /// 对外可呈现的私聊拒绝原因，避免暴露具体关系策略细节。
    public enum Reason: String, Equatable, Sendable {
        /// 通用私聊策略拒绝。
        case generic
        /// 目标为只读系统账户。
        case systemAccountReadOnly = "system_account_read_only"
    }

    /// 产生私有活动的房间。
    public let roomID: RoomID
    /// 私有活动的源事件身份。
    public let sourceEventID: EventID
    /// 私有时间线顺序号，必须大于零。
    public let timelineSequence: UInt64
    /// 活动创建时间。
    public let createdAt: Date
    /// 面向发起者的拒绝原因。
    public let reason: Reason

    /// 创建私聊拒绝活动。
    ///
    /// - Parameters:
    ///   - roomID: 对应房间。
    ///   - sourceEventID: 活动源事件标识。
    ///   - timelineSequence: 大于零的时间线序号；违反时触发前置条件失败。
    ///   - createdAt: 活动创建时间。
    ///   - reason: 拒绝原因，默认通用原因。
    public init(roomID: RoomID, sourceEventID: EventID, timelineSequence: UInt64, createdAt: Date, reason: Reason = .generic) {
        precondition(timelineSequence > 0)
        self.roomID = roomID
        self.sourceEventID = sourceEventID
        self.timelineSequence = timelineSequence
        self.createdAt = createdAt
        self.reason = reason
    }
}

/// 把运行时容量限制绑定到持久化房间的容量配置标识。
///
/// 存储接受请求时应核对房间配置，不能仅按进程默认配置选择策略。
public struct V2CapacityProfile: Equatable, Sendable {
    /// 已清理首尾空白的容量配置标识。
    public let id: String
    /// 该配置对应的容量限制。
    public let limits: RoomCapacityProfile

    /// 创建带标识的容量配置。
    ///
    /// - Parameters:
    ///   - id: 配置标识，保存前移除首尾空白与换行。
    ///   - limits: 对应的房间容量限制。
    /// - Throws: 标识清理后为空时抛出 `V2CapacityProfileError.invalidIdentifier`。
    public init(id: String, limits: RoomCapacityProfile) throws {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw V2CapacityProfileError.invalidIdentifier }
        self.id = normalized
        self.limits = limits
    }
}

/// 容量配置错误；`invalidIdentifier` 表示标识清理后为空。
public enum V2CapacityProfileError: Error, Equatable, Sendable { case invalidIdentifier }

/// 消息接受的持久化边界，拥有行锁与数据库事务。
///
/// 成功必须遵守整个接受事务的合同，包括消息、逻辑事件、原结果和对应投递工件；
/// 不能仅写入消息行就返回成功。不同优化路径仍须保持相同授权与幂等语义。
public protocol V2RoomWriteStore: Sendable {
    /// 在权威锁与事务保护下接受单条消息。
    ///
    /// - Parameters:
    ///   - command: 已验证结构的领域命令，仍需在事务内检查权限及幂等状态。
    ///   - capacityProfile: 必须与持久化房间配置匹配的容量限制。
    ///   - identifiers: 本次操作预先生成的标识。
    ///   - now: 本次接受固定使用的时间。
    /// - Returns: 已完成持久化合同的接受结果，或可报告的业务拒绝结果。
    /// - Throws: 存储、授权或一致性错误；不能在只写入部分接受工件后报告成功。
    func accept(
        command: consuming V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome
}

/// 领域层准备好的不可变消息接受请求。
///
/// 标识与接受时间随请求保存。批次重试数据库事务时必须复用它们，避免为同一客户端操作重新生成消息、事件或计划身份。
public struct V2RoomWriteRequest: Sendable {
    /// 已通过构造校验的发送命令。
    public let command: V2SendMessageCommand
    /// 接受事务必须核对的容量配置。
    public let capacityProfile: V2CapacityProfile
    /// 本次接受预先生成的稳定标识。
    public let identifiers: V2AcceptanceIdentifiers
    /// 本次接受固定使用的时间。
    public let now: Date

    /// 保存一次接受所需的稳定输入，不执行数据库写入。
    ///
    /// - Parameters:
    ///   - command: 已构造的领域命令。
    ///   - capacityProfile: 房间容量配置。
    ///   - identifiers: 跨事务重试复用的标识。
    ///   - now: 跨事务重试复用的接受时间。
    public init(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) {
        self.command = command
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }
}

/// 支持将兼容的有序请求子集放入同一事务持久化的存储能力。
///
/// 批次分类属于优化提示，不是授权判断；不兼容请求仍通过普通单命令路径执行。
/// 每个请求必须保留独立结果，共享事务不得削弱锁、幂等或持久化合同。
public protocol V2AtomicRoomWriteBatchStore: V2RoomWriteStore {
    /// 返回各请求能否尝试共享事务的进程内提示。
    ///
    /// - Parameter requests: 保持原始输入顺序的待处理请求。
    /// - Returns: 与输入一一对应的布尔值；`false` 只要求走普通路径，不是权限拒绝。
    ///
    /// 真正执行时仍需获取权威锁并重新检查持久化状态，分类后状态变化可以使原子尝试回退。
    func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool]

    /// 按共享事务兼容类别为请求分组。
    ///
    /// - Parameter requests: 待分类的有序请求。
    /// - Returns: 对应每项输入的兼容类别；相同非空类别可尝试共用事务，`nil` 使用单命令路径。
    func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?]

    /// 查询同一兼容类别能否在有序事务内多次推进同一房间。
    ///
    /// - Parameter partition: 待查询的存储兼容类别。
    /// - Returns: 仅当实现能保存所有中间消息并正确归并最终房间状态时返回 `true`，默认 `false`。
    func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) async -> Bool

    /// 在共享事务内持久化一组兼容的有序请求。
    ///
    /// - Parameter requests: 保持处理顺序、时间和标识稳定的输入。
    /// - Returns: 与每个输入对应的接受结果。
    /// - Throws: 无法保持单命令语义时抛出批次回退错误，或传播存储执行错误。
    ///
    /// 返回成功前必须完成整个共享事务；回退不能携带已部分提交的成功承诺。
    func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome]
}

public extension V2AtomicRoomWriteBatchStore {
    /// 默认将所有输入标记为可尝试，由实际原子事务决定能否处理。
    ///
    /// - Parameter requests: 待分类输入。
    /// - Returns: 与输入等长、全部为 `true` 的数组；此默认值不证明权限或兼容性。
    func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        Array(repeating: true, count: requests.count)
    }

    /// 将默认资格判断转换为普通批次类别。
    ///
    /// - Parameter requests: 待分类输入。
    /// - Returns: 可尝试项对应普通类别，其余为 `nil`；资格数组长度不匹配时全部回退单命令路径。
    func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?] {
        let eligibility = await atomicBatchEligibility(requests: requests)
        guard eligibility.count == requests.count else {
            return Array(repeating: nil, count: requests.count)
        }
        return eligibility.map { $0 ? .standard : nil }
    }

    /// 默认不支持同一原子批次重复推进同一房间，具体存储可在保证语义后覆盖。
    func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) async -> Bool {
        false
    }
}

/// 存储定义的批次兼容类别；类别相同只表示可以尝试共用事务，不代表已通过授权或容量检查。
public struct V2AtomicRoomWriteBatchPartition: Hashable, Sendable {
    /// 普通原子批次类别。
    public static let standard = Self(rawValue: 0)
    /// 存储实现提供的加速批次类别。
    public static let accelerated = Self(rawValue: 1)
    /// 采用房间日志的大群纯文本、无提及消息类别，避免与私聊策略事务图混合。
    public static let large = Self(rawValue: 2)

    /// 进程内兼容类别值，由存储实现解释。
    public let rawValue: UInt8

    /// 保存存储自定义的兼容类别值，不限制为预定义的三个类别。
    public init(rawValue: UInt8) { self.rawValue = rawValue }
}

/// 共享事务无法保持普通命令语义时返回的内部回退信号。
///
/// 批处理器使用原始不可变请求重试普通路径，不把此错误直接返回客户端，也不能确认部分批次已成功。
/// 原因只包含低基数分类，不能加入房间、用户、操作或策略标识。
public struct V2AtomicRoomWriteBatchError: Error, Equatable, Sendable {
    /// 共享事务回退的固定原因分类，用于统计而不携带业务身份。
    public enum Reason: String, CaseIterable, Hashable, Sendable {
        /// 未细分原因。
        case unspecified
        /// 运行配置不兼容原子路径。
        case incompatibleConfiguration = "incompatible_configuration"
        /// 请求内容结构不支持此路径。
        case requestShape = "request_shape"
        /// 批内存在重复操作。
        case duplicateOperation = "duplicate_operation"
        /// 批内房间重复而此路径不支持重复推进。
        case duplicateRoom = "duplicate_room"
        /// 预检结果与执行时状态不一致。
        case preflightMismatch = "preflight_mismatch"
        /// 权限状态要求重新按普通路径处理。
        case authorizationState = "authorization_state"
        /// 房间类型不匹配兼容类别。
        case roomKindMismatch = "room_kind_mismatch"
        /// 容量配置不匹配。
        case capacityProfileMismatch = "capacity_profile_mismatch"
        /// 房间冻结状态不支持此原子路径。
        case roomFrozen = "room_frozen"
        /// 房间额度模式不匹配。
        case roomCreditModeMismatch = "room_credit_mode_mismatch"
        /// 准入状态不支持原子处理。
        case admissionState = "admission_state"
        /// 条件写入结果未满足预期。
        case conditionalWriteMismatch = "conditional_write_mismatch"
    }

    /// 固定的回退原因分类。
    public let reason: Reason
    /// 相对本批输入、可单独隔离的不兼容请求下标。
    ///
    /// 批处理器使用前负责校验下标；剩余已回滚请求仍可重试原子路径。此数组不携带业务标识。
    public let isolatedRequestIndices: [Int]

    /// 创建批次回退信号。
    ///
    /// - Parameters:
    ///   - reason: 用于运行观测的固定原因分类。
    ///   - isolatedRequestIndices: 可隔离请求的输入下标，默认为不指定；此初始化方法不检查范围。
    public init(reason: Reason, isolatedRequestIndices: [Int] = []) {
        self.reason = reason
        self.isolatedRequestIndices = isolatedRequestIndices
    }
}

/// 消息接受存储的领域与持久化一致性错误，由传输边缘映射为协议响应。
public enum V2RoomWriteStoreError: Error, Equatable, Sendable {
    /// 原操作已被 owner 永久关闭，迟到重试不得被接受。
    case messageOperationClosed
    /// 目标房间不存在。
    case roomNotFound
    /// 发送者不具备当前房间写入资格。
    case actorNotEligible
    /// 发送者当前被禁言。
    case actorMuted
    /// 房间当前冻结，不接受写入。
    case roomFrozen
    /// 请求容量配置与房间持久化配置不匹配。
    case capacityProfileMismatch
    /// 持久化状态不满足接受事务的一致性要求。
    case corruptPersistenceState
    /// 私聊关系策略阻止发送。
    case directMessageBlocked
    /// 陌生人消息权限不允许发送。
    case strangerMessagePermissionDenied
    /// 陌生人消息额度已达到上限。
    case strangerMessageLimitReached
    /// 回复目标不存在或不能作为有效引用。
    case replyTargetNotFound
}

/// 只暴露准入指标；消费方不能据此接受消息。
public protocol V2SendMessageBatchMetricsReading: Sendable {
    /// 读取准入队列与处理状态的观测快照，不构成持久化提交证明。
    func snapshot() async -> V2SendMessageBatchMetricsSnapshot
}

/// 生成消息接受标识时发现的输入错误。
public enum V2AcceptanceIdentifierError: Error, Equatable, Sendable {
    /// 时间不能表示为非负、48 位 Unix 毫秒值，包括非有限值或越界时间。
    case invalidTimestamp
}
