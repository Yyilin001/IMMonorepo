import Foundation

/// 创建群时确定且随后保持不变的投递合同，使房间消息在整个生命周期内使用一致的可靠同步来源。
public enum V2GroupDeliveryMode: String, CaseIterable, Codable, Equatable, Sendable {
    /// 标准成员扇出模式，协议原始值为 standard_fanout。
    case standardFanout = "standard_fanout"
    /// 大群混合投递模式，协议原始值为 large_group_hybrid。
    case largeGroupHybrid = "large_group_hybrid"
}

/// 群投递模式的创建规模策略，与工作线程或数据库连接池等瞬时容量配置分开。
public struct V2GroupDeliveryPolicy: Equatable, Sendable {
    /// 标准扇出群最大成员总数：5000。
    public static let standardFanoutMaximumMembers = 5_000
    /// 大群混合模式最大成员总数：100000。
    public static let largeGroupHybridMaximumMembers = 100_000

    /// 创建无状态的群规模策略。
    public init() {}

    /// 返回指定投递模式的成员总数上限，不读取当前群状态。
    public func maximumMembers(for mode: V2GroupDeliveryMode) -> Int {
        switch mode {
        case .standardFanout: Self.standardFanoutMaximumMembers
        case .largeGroupHybrid: Self.largeGroupHybridMaximumMembers
        }
    }

    /// 判断正成员总数是否不超过指定模式上限；适用于已确定模式的容量检查，不要求该模式与创建推导一致。
    public func accepts(memberCount: Int, mode: V2GroupDeliveryMode) -> Bool {
        memberCount > 0 && memberCount <= maximumMembers(for: mode)
    }

    /// 根据初始成员总数确定模式：1 到 5000 为标准扇出，5001 到 100000 为混合模式，其余返回 nil。
    public func deliveryMode(forInitialMemberCount memberCount: Int) -> V2GroupDeliveryMode? {
        guard memberCount > 0, memberCount <= Self.largeGroupHybridMaximumMembers else { return nil }
        return memberCount <= Self.standardFanoutMaximumMembers ? .standardFanout : .largeGroupHybrid
    }

    /// 要求指定模式与初始成员总数推导结果完全一致，防止客户端自行选择不符合创建规模的模式。
    public func acceptsInitialMemberCount(_ memberCount: Int, mode: V2GroupDeliveryMode) -> Bool {
        deliveryMode(forInitialMemberCount: memberCount) == mode
    }
}

/// 持久创建操作的不可变初始成员与群资料输入，后续成员变更使用带版本的独立命令。
public struct V2CreateGroupRoomCommand: Equatable, Sendable {
    /// 裁剪后群标题的最大 UTF-8 字节数：120。
    public static let maximumTitleUTF8Bytes = 120

    /// 创建者及初始群主。
    public let actorUserID: UserID
    /// 本次群创建的稳定幂等身份。
    public let operationID: GroupRoomOperationID
    /// 移除首尾空白与换行后的群标题。
    public let title: String
    /// 调用方提供的投递模式，构造器不检查与成员规模是否一致。
    public let deliveryMode: V2GroupDeliveryMode
    /// 不含群主且无重复的初始成员，构造时排序以使等价输入顺序得到一致意图。
    public let initialMemberUserIDs: [UserID]

    /// 构造群创建意图，裁剪标题并校验字节长度、控制字符与成员唯一性。
    ///
    /// - Parameters:
    ///   - actorUserID: 创建者，不能再次出现在初始成员列表中。
    ///   - operationID: 稳定创建操作身份。
    ///   - title: 裁剪后非空、最多 120 字节且无控制字符的标题。
    ///   - deliveryMode: 创建时选定的投递模式，需由业务层核对规模策略。
    ///   - initialMemberUserIDs: 无重复的非群主初始成员，允许空列表。
    /// - Throws: 标题或初始成员不满足条件时抛出对应校验错误。
    ///
    /// 保存排序后的成员，不执行成员资格、规模或模式一致性授权。
    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        deliveryMode: V2GroupDeliveryMode,
        initialMemberUserIDs: [UserID]
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= Self.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw V2GroupMessagingValidationError.invalidTitle }

        guard !initialMemberUserIDs.contains(actorUserID),
              Set(initialMemberUserIDs).count == initialMemberUserIDs.count
        else { throw V2GroupMessagingValidationError.invalidInitialMembers }

        self.actorUserID = actorUserID
        self.operationID = operationID
        self.title = normalizedTitle
        self.deliveryMode = deliveryMode
        self.initialMemberUserIDs = initialMemberUserIDs.sorted()
    }

    /// 将群主与初始成员合并并排序，返回完整创建受众。
    public var allMemberUserIDs: [UserID] {
        ([actorUserID] + initialMemberUserIDs).sorted()
    }
}

/// 群创建或查询结果，分别携带权威成员总数与本次返回的成员标识列表。
public struct V2GroupRoom: Equatable, Sendable {
    /// 群房间身份。
    public let roomID: RoomID
    /// 群主用户身份。
    public let ownerUserID: UserID
    /// 返回的群标题，此构造器不重复校验标题约束。
    public let title: String
    /// 群创建时确定的投递模式。
    public let deliveryMode: V2GroupDeliveryMode
    /// 权威成员总数，可大于本次返回的标识数量，避免大群响应为报告总数而展开所有成员。
    public let memberCount: Int
    /// 本次返回的成员标识，构造时排序但不去重，不保证是完整成员集。
    public let memberUserIDs: [UserID]
    /// 群创建时间，构造器不校验日期。
    public let createdAt: Date

    /// 保存群结果并校验权威成员总数，排序本次返回的成员列表。
    ///
    /// - Parameters:
    ///   - roomID: 群房间身份。
    ///   - ownerUserID: 群主身份。
    ///   - title: 群标题。
    ///   - deliveryMode: 群投递模式。
    ///   - memberUserIDs: 本次响应包含的成员标识，可为空或不完整。
    ///   - memberCount: 可选权威总数，省略时取列表长度。
    ///   - createdAt: 群创建时间。
    /// - Throws: 总数非正、小于列表长度或不能表示为 UInt32 时抛出 invalidMemberCount。
    ///
    /// 不校验成员唯一性、群主是否在列表中、模式容量上限或日期；这些应由权威业务路径保证。
    public init(roomID: RoomID, ownerUserID: UserID, title: String, deliveryMode: V2GroupDeliveryMode, memberUserIDs: [UserID], memberCount: Int? = nil, createdAt: Date) throws {
        let resolvedMemberCount = memberCount ?? memberUserIDs.count
        guard resolvedMemberCount >= memberUserIDs.count, resolvedMemberCount > 0,
              UInt32(exactly: resolvedMemberCount) != nil
        else { throw V2GroupMessagingValidationError.invalidMemberCount }
        self.roomID = roomID
        self.ownerUserID = ownerUserID
        self.title = title
        self.deliveryMode = deliveryMode
        self.memberCount = resolvedMemberCount
        self.memberUserIDs = memberUserIDs.sorted()
        self.createdAt = createdAt
    }
}

/// 群标题、初始成员或成员总数校验错误。
public enum V2GroupMessagingValidationError: Error, Equatable, Sendable {
    /// 裁剪后的标题为空、超出字节上限或含控制字符。
    case invalidTitle
    /// 初始成员包含创建者或重复用户。
    case invalidInitialMembers
    /// 总人数非正、小于返回列表长度或不能表示为 UInt32。
    case invalidMemberCount
}
