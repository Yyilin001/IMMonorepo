import Crypto
import Foundation
import IMV2Core
import Synchronization

/// 由传输边缘确认 actor 身份后的发送输入。
///
/// 公开协议解码不得直接提供可信 sender。该类型可被进程内代码构造，
/// 因此调用方必须先完成认证，类型名称本身不构成授权证明。
public struct V2AuthenticatedSendMessage: Sendable {
    /// 目标房间标识。
    public let roomID: RoomID
    /// 传输边缘认证所得的发送者身份，不能直接信任客户端载荷。
    public let actorUserID: UserID
    /// 客户端生成并在重试间保持不变的消息操作标识。
    public let clientMessageID: ClientMessageID
    /// 待发送文本，实际限制由领域命令构造检查。
    public let text: String
    /// 有序媒体引用，默认无附件。
    public let media: [V2MediaReference]
    /// 消息提及目标，默认无提及。
    public let mentions: [V2MentionTarget]
    /// 文本实体及其范围，默认无实体。
    public let entities: [V2MessageEntity]
    /// 可选回复目标，由存储进一步检查有效性。
    public let replyTo: V2MessageReplyReference?

    /// 保存已认证发送输入，不在此处执行领域校验或认证。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 边缘认证所得用户。
    ///   - clientMessageID: 重试间稳定的客户端操作标识。
    ///   - text: 消息文本。
    ///   - media: 有序媒体引用。
    ///   - mentions: 提及目标。
    ///   - entities: 文本实体。
    ///   - replyTo: 可选回复目标。
    public init(roomID: RoomID, actorUserID: UserID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}

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
    /// 扇出准入当前不可用，附带容量或状态原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
    /// 已为本次操作持久化私有活动与输入能力状态，但没有创建消息、房间事件或扇出计划。
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

    /// 兼容旧调用点的未细分回退原因；新增调用点应使用带具体原因的初始化方法。
    public static let unsupportedRequestShape = Self(reason: .unspecified)

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

/// 消息持久化之前的进程内准入边界。
///
/// 实现可以使用单个批处理 actor 或按房间稳定分配的多个执行通道，必须保持同一房间的有序写入合同。
public protocol V2SendMessageAdmission: Sendable {
    /// 是否由准入实现围绕实际数据库工作管理前台写入许可，以避免等待批次的请求重复占用许可。
    var managesForegroundWriteAdmission: Bool { get }
    /// 是否在有序提交后、恢复请求等待者之前发布已接受的 Hybrid 群事件。
    ///
    /// 为 `true` 时 Gateway 应避免再次发布同一事件。此提示不替代持久化房间日志的恢复能力。
    var publishesCommittedGroupEvents: Bool { get }

    /// 提交不可变写入请求并等待该请求的独立结果。
    ///
    /// - Parameter request: 带固定标识与时间的接受输入。
    /// - Returns: 对应此请求的业务接受结果。
    /// - Throws: 准入、取消或存储执行错误，具体行为由实现定义。
    func accept(
        _ request: consuming V2RoomWriteRequest
    ) async throws -> V2SendMessageOutcome

    /// 读取准入队列与处理状态的观测快照，不构成持久化提交证明。
    func snapshot() async -> V2SendMessageAdmissionBatcher.Snapshot
}

extension V2SendMessageAdmission {
    /// 默认不负责发布提交后的群事件，交给调用边缘处理。
    public var publishesCommittedGroupEvents: Bool { false }
}

/// 生成消息接受标识时发现的输入错误。
public enum V2AcceptanceIdentifierError: Error, Equatable, Sendable {
    /// 时间不能表示为非负、48 位 Unix 毫秒值，包括非有限值或越界时间。
    case invalidTimestamp
}

/// 为一次消息接受生成消息和事件两个标识，支持生产生成器与测试注入。
public struct V2AcceptanceIDFactory: Sendable {
    /// 实际标识生成闭包，生产路径使用接受时间，测试路径可忽略时间。
    private let makeIdentifiers: @Sendable (Date) throws -> V2AcceptanceIdentifiers

    /// 使用进程共享生成器生成带时间前缀的接受标识。
    ///
    /// 生成器用进程密钥和计数器进行 HMAC 扩展，给两个标识分配不同字节段；毫秒前缀在进程内防回退。
    /// 接受时间仍以请求中的日期为准，有序标识的前缀在时钟回拨后可能保持在较早观察到的最大时间。
    public init() {
        let generator = V2SecureProcessUUIDGenerator.shared
        makeIdentifiers = { acceptedAt in
            let identifiers = try generator.makeOrderedPair(at: acceptedAt)
            return V2AcceptanceIdentifiers(
                messageID: MessageID(uuid: identifiers.0),
                eventID: EventID(uuid: identifiers.1)
            )
        }
    }

    /// 使用可注入的 UUID 来源，便于确定性领域测试。
    ///
    /// - Parameter makeUUID: 每次调用依次生成消息和事件标识；调用方负责唯一性。此路径不使用接受时间生成有序前缀。
    public init(makeUUID: @escaping @Sendable () -> UUID) {
        makeIdentifiers = { _ in
            try V2AcceptanceIdentifiers(
                messageID: MessageID(makeUUID().uuidString),
                eventID: EventID(makeUUID().uuidString)
            )
        }
    }

    /// 生成同一次接受操作使用的两个标识。
    ///
    /// - Parameter acceptedAt: 接受时间，生产路径用于生成毫秒前缀。
    /// - Returns: 消息和事件标识；事务重试应复用返回值。
    /// - Throws: 生产路径遇到不可表示时间时抛出 `V2AcceptanceIdentifierError.invalidTimestamp`，或传播注入生成路径的错误。
    public func make(at acceptedAt: Date) throws -> V2AcceptanceIdentifiers {
        try makeIdentifiers(acceptedAt)
    }
}

/// 为消息接受生成进程内伪随机标识，并为连接与跟踪生成轻量标识。
///
/// 接受标识使用 256 位进程密钥与递增计数器的 HMAC 扩展；三个互不重叠的十字节片段分别提供有序 UUID 的随机部分。
/// 每次进程重启重新生成密钥。`@unchecked Sendable` 依赖密钥模板只读、所有可变计数器使用原子操作。
/// 轻量标识不能当作授权凭据，采用独立计数器与进程随机前缀。
final class V2SecureProcessUUIDGenerator: @unchecked Sendable {
    /// 进程共享生成器，使同一进程的接受请求复用密钥与计数空间。
    static let shared = V2SecureProcessUUIDGenerator()

    /// 只读 HMAC 初始模板，每次生成时复制后写入独立计数值，避免重复构造密钥散列状态。
    private let authenticationTemplate: HMAC<SHA256>
    /// 接受标识的原子计数器；回绕至零时触发前置条件失败。
    private let authenticationCounter = Atomic<UInt64>(0)
    /// 连接与跟踪标识使用的七字节进程随机前缀，不用于授权。
    private let localIdentifierPrefix: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    /// 轻量标识的独立原子计数器。
    private let localIdentifierCounter = Atomic<UInt64>(0)
    /// 已发布的最大毫秒前缀，用于钳制进程内的时钟回拨。
    private let lastOrderedUnixMilliseconds = Atomic<UInt64>(0)

    /// 生成进程密钥并初始化只读 HMAC 模板与轻量标识前缀。
    init() {
        let key = SymmetricKey(size: .bits256)
        authenticationTemplate = HMAC(key: key)
        localIdentifierPrefix = key.withUnsafeBytes { bytes in
            (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6])
        }
    }

    /// 生成连接或跟踪使用的轻量 UUID 形式标识。
    ///
    /// - Returns: 由进程随机前缀与递增计数器组成的标识；不能将其作为不可预测的访问凭据。
    ///
    /// 计数器空间耗尽会触发前置条件失败，进程间唯一性依赖随机前缀。
    func makeOne() -> UUID {
        let increment = localIdentifierCounter.wrappingAdd(1, ordering: .relaxed)
        precondition(increment.newValue != 0, "process-local identifier space exhausted")
        let value = increment.newValue
        return UUID(uuid: (
            localIdentifierPrefix.0,
            localIdentifierPrefix.1,
            localIdentifierPrefix.2,
            localIdentifierPrefix.3,
            localIdentifierPrefix.4,
            localIdentifierPrefix.5,
            0x40 | UInt8(truncatingIfNeeded: value >> 60),
            UInt8(truncatingIfNeeded: value >> 52),
            0x80 | UInt8(truncatingIfNeeded: value >> 46) & 0x3f,
            UInt8(truncatingIfNeeded: value >> 38),
            UInt8(truncatingIfNeeded: value >> 30),
            UInt8(truncatingIfNeeded: value >> 22),
            UInt8(truncatingIfNeeded: value >> 14),
            UInt8(truncatingIfNeeded: value >> 6),
            UInt8(truncatingIfNeeded: value) & 0x3f,
            localIdentifierPrefix.6
        ))
    }

    /// 生成共享毫秒前缀、使用不同伪随机字节段的两个有序标识。
    ///
    /// - Parameter date: 本次接受时间。
    /// - Returns: 依次用于消息和事件的标识。
    /// - Throws: 时间不在可表示范围内时抛出无效时间错误。
    func makeOrderedPair(at date: Date) throws -> (UUID, UUID) {
        let unixMilliseconds = try orderedUnixMilliseconds(for: date)
        let authenticationCode = nextAuthenticationCode()
        return authenticationCode.withUnsafeBytes { bytes in
            (
                v2UUIDv7(bytes, offset: 0, unixMilliseconds: unixMilliseconds),
                v2UUIDv7(bytes, offset: 10, unixMilliseconds: unixMilliseconds)
            )
        }
    }

    /// 把日期向下取整为 Unix 毫秒，并在进程内保持前缀不回退。
    ///
    /// - Parameter date: 待转换日期。
    /// - Returns: 当前候选时间与进程已观察最大时间中的较大值。
    /// - Throws: 负数、非有限值或超出 48 位毫秒范围时抛出无效时间错误。
    ///
    /// 此操作只维护前缀顺序，标识唯一性仍来自计数器驱动的 HMAC。并发调用的返回先后不保证等同于前缀递增顺序。
    private func orderedUnixMilliseconds(for date: Date) throws -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds >= 0,
              let candidate = UInt64(exactly: milliseconds.rounded(.down)),
              candidate <= 0x0000_ffff_ffff_ffff else {
            throw V2AcceptanceIdentifierError.invalidTimestamp
        }
        var observed = lastOrderedUnixMilliseconds.load(ordering: .relaxed)
        while observed < candidate {
            let exchanged = lastOrderedUnixMilliseconds.compareExchange(
                expected: observed,
                desired: candidate,
                ordering: .relaxed
            )
            if exchanged.exchanged { return candidate }
            observed = exchanged.original
        }
        return observed
    }

    /// 把递增计数器按大端序输入复制的 HMAC 模板，生成下一段伪随机字节；计数器回绕时触发前置条件失败。
    private func nextAuthenticationCode() -> HMAC<SHA256>.MAC {
        let increment = authenticationCounter.wrappingAdd(1, ordering: .relaxed)
        precondition(increment.newValue != 0, "acceptance identifier space exhausted")
        var input = increment.newValue.bigEndian
        return withUnsafeBytes(of: &input) { bytes in
            var authenticator = authenticationTemplate
            authenticator.update(data: Data(bytes))
            return authenticator.finalize()
        }
    }
}

/// 从连续十六字节构造设置了版本与变体位的 UUID。
///
/// 调用方必须提供从零起始、覆盖指定偏移的整数索引集合；可用字节不足时触发前置条件失败。
private func v2UUIDv4<Bytes: RandomAccessCollection>(
    _ bytes: Bytes,
    offset: Int
) -> UUID where Bytes.Element == UInt8, Bytes.Index == Int {
    precondition(offset >= 0 && bytes.count >= offset + 16)
    let version = (bytes[offset + 6] & 0x0f) | 0x40
    let variant = (bytes[offset + 8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
        bytes[offset + 4], bytes[offset + 5], version, bytes[offset + 7],
        variant, bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
        bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15]
    ))
}

/// 用 48 位 Unix 毫秒前缀和十字节随机片段构造有序 UUID。
///
/// - Parameters:
///   - bytes: 从零起始、采用整数索引的随机字节集合。
///   - offset: 十字节片段的起始位置。
///   - unixMilliseconds: 可由 48 位表示的毫秒前缀。
/// - Returns: 设置了版本与变体位的 UUID。
///
/// 调用方必须保证片段存在且时间不越界，否则触发前置条件失败。
private func v2UUIDv7<Bytes: RandomAccessCollection>(
    _ bytes: Bytes,
    offset: Int,
    unixMilliseconds: UInt64
) -> UUID where Bytes.Element == UInt8, Bytes.Index == Int {
    precondition(offset >= 0 && bytes.count >= offset + 10)
    precondition(unixMilliseconds <= 0x0000_ffff_ffff_ffff)
    let versionAndRandom = (bytes[offset] & 0x0f) | 0x70
    let variantAndRandom = (bytes[offset + 2] & 0x3f) | 0x80
    return UUID(uuid: (
        UInt8(truncatingIfNeeded: unixMilliseconds >> 40),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 32),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 24),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 16),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 8),
        UInt8(truncatingIfNeeded: unixMilliseconds),
        versionAndRandom, bytes[offset + 1],
        variantAndRandom, bytes[offset + 3], bytes[offset + 4], bytes[offset + 5],
        bytes[offset + 6], bytes[offset + 7], bytes[offset + 8], bytes[offset + 9]
    ))
}

/// 把已认证发送输入转换为领域命令，并交给准入或存储完成接受。
///
/// 本层执行命令构造校验，为一次调用固定时间与标识；房间权限、幂等竞争和原子提交由存储边界负责。
/// 配置批处理器时走其准入路径，否则直接调用单命令存储。
public struct V2SendMessageService: Sendable {
    /// 直接接受单命令的持久化实现。
    private let store: any V2RoomWriteStore
    /// 可选的有序准入实现。
    private let batcher: (any V2SendMessageAdmission)?
    /// 本服务采用的房间容量配置。
    private let capacityProfile: V2CapacityProfile
    /// 领域命令构造时使用的内容限制。
    private let limits: V2MessageCommandLimits
    /// 为接受请求生成稳定标识的工厂。
    private let idFactory: V2AcceptanceIDFactory
    /// 每次发送读取一次的可注入时间来源。
    private let now: @Sendable () -> Date

    /// 报告批处理器是否管理数据库工作所需的前台写入许可。
    ///
    /// 启用后 Gateway 不应为每个排队消息重复保留许可，避免尚未开始的批次耗尽前台通道。
    var managesForegroundWriteAdmission: Bool {
        batcher?.managesForegroundWriteAdmission ?? false
    }

    /// 报告批处理器是否已负责提交后群事件发布；未配置批处理器时为 `false`。
    var publishesCommittedGroupEvents: Bool {
        batcher?.publishesCommittedGroupEvents ?? false
    }

    /// 配置发送服务及其可注入依赖。
    ///
    /// - Parameters:
    ///   - store: 单命令持久化边界。
    ///   - capacityProfile: 与房间持久化配置核对的容量策略。
    ///   - limits: 消息命令校验限制。
    ///   - idFactory: 接受标识生成器，默认使用进程共享生产生成器。
    ///   - batcher: 可选的有序准入实现；存在时发送通过它执行。
    ///   - now: 接受时间来源，每次发送读取一次。
    public init(
        store: any V2RoomWriteStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        idFactory: V2AcceptanceIDFactory = .init(),
        batcher: (any V2SendMessageAdmission)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.batcher = batcher
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.idFactory = idFactory
        self.now = now
    }

    /// 校验发送内容，准备不可变写入请求并等待接受结果。
    ///
    /// - Parameter request: 已由传输边缘绑定可信用户身份的发送输入；本方法不验证认证凭证。
    /// - Returns: 新接受、原回执重放、冲突、限流、不可用或私聊策略拒绝结果。
    /// - Throws: 命令校验、标识生成、准入或持久化执行的错误。
    ///
    /// 时间仅读取一次，生成的标识随请求交给批处理器；同一批次内部重试不得重新生成。
    public func send(_ request: V2AuthenticatedSendMessage) async throws -> V2SendMessageOutcome {
        let command = try V2SendMessageCommand(
            roomID: request.roomID,
            senderUserID: request.actorUserID,
            clientMessageID: request.clientMessageID,
            text: request.text,
            media: request.media,
            mentions: request.mentions,
            entities: request.entities,
            replyTo: request.replyTo,
            limits: limits
        )
        let acceptedAt = now()
        let prepared = V2RoomWriteRequest(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: try idFactory.make(at: acceptedAt),
            now: acceptedAt
        )
        if let batcher {
            return try await batcher.accept(prepared)
        }
        return try await store.accept(
            command: prepared.command,
            capacityProfile: prepared.capacityProfile,
            identifiers: prepared.identifiers,
            now: prepared.now
        )
    }
}
