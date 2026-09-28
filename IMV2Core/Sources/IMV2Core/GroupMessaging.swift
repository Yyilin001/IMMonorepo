import Foundation

/// 创建时确定的群容量等级；各等级的公共消息均使用房间日志。
public enum V2GroupCapacityClass: String, CaseIterable, Codable, Equatable, Sendable {
    /// 标准群容量等级，最多 5,000 名成员。
    case standard = "standard"
    /// 大群容量等级，最多 100,000 名成员。
    case large = "large"
}

/// 群容量等级的创建规模策略，与工作线程或数据库连接池等瞬时容量配置分开。
public struct V2GroupCapacityPolicy: Equatable, Sendable {
    /// 标准群最大成员总数：5000。
    public static let standardMaximumMembers = 5_000
    /// 大群最大成员总数：100000。
    public static let largeMaximumMembers = 100_000

    /// 创建无状态的群规模策略。
    public init() {}

    /// 返回指定容量等级的成员总数上限，不读取当前群状态。
    public func maximumMembers(for mode: V2GroupCapacityClass) -> Int {
        switch mode {
        case .standard: Self.standardMaximumMembers
        case .large: Self.largeMaximumMembers
        }
    }

    /// 判断正成员总数是否不超过指定模式上限；适用于已确定模式的容量检查，不要求该模式与创建推导一致。
    public func accepts(memberCount: Int, mode: V2GroupCapacityClass) -> Bool {
        memberCount > 0 && memberCount <= maximumMembers(for: mode)
    }

    /// 根据初始成员总数确定模式：1 到 5000 为标准群，5001 到 100000 为大群，其余返回 nil。
    public func capacityClass(forInitialMemberCount memberCount: Int) -> V2GroupCapacityClass? {
        guard memberCount > 0, memberCount <= Self.largeMaximumMembers else { return nil }
        return memberCount <= Self.standardMaximumMembers ? .standard : .large
    }

    /// 要求指定模式与初始成员总数推导结果完全一致，防止客户端自行选择不符合创建规模的模式。
    public func acceptsInitialMemberCount(_ memberCount: Int, mode: V2GroupCapacityClass) -> Bool {
        capacityClass(forInitialMemberCount: memberCount) == mode
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
    /// 群创建时确定的容量等级。
    public let capacityClass: V2GroupCapacityClass
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
    ///   - capacityClass: 群容量等级。
    ///   - memberUserIDs: 本次响应包含的成员标识，可为空或不完整。
    ///   - memberCount: 可选权威总数，省略时取列表长度。
    ///   - createdAt: 群创建时间。
    /// - Throws: 总数非正、小于列表长度或不能表示为 UInt32 时抛出 invalidMemberCount。
    ///
    /// 不校验成员唯一性、群主是否在列表中、模式容量上限或日期；这些应由权威业务路径保证。
    public init(roomID: RoomID, ownerUserID: UserID, title: String, capacityClass: V2GroupCapacityClass, memberUserIDs: [UserID], memberCount: Int? = nil, createdAt: Date) throws {
        let resolvedMemberCount = memberCount ?? memberUserIDs.count
        guard resolvedMemberCount >= memberUserIDs.count, resolvedMemberCount > 0,
              UInt32(exactly: resolvedMemberCount) != nil
        else { throw V2GroupMessagingValidationError.invalidMemberCount }
        self.roomID = roomID
        self.ownerUserID = ownerUserID
        self.title = title
        self.capacityClass = capacityClass
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
