import Foundation

/// 单个资料事实的服务端版本，范围为正 Int64。
///
/// 只有同一事实作用域的版本才可比较，不应将多个来源的版本做算术合并。RawRepresentable 的 Codable 解码复用失败构造器范围检查。
public struct V2ProfileRevision: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    /// 经过正 Int64 范围校验的版本值。
    public let rawValue: UInt64
    /// 安全转换为持久化使用的 Int64。
    public var signedValue: Int64 { Int64(rawValue) }

    /// 要求版本位于 1 到 Int64.max，不满足返回 nil。
    public init?(rawValue: UInt64) {
        guard rawValue > 0, rawValue <= UInt64(Int64.max) else { return nil }
        self.rawValue = rawValue
    }

    /// 比较原始版本数值；调用者负责确保双方属于同一事实作用域。
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 不可变头像媒体引用，更换头像应使用新的媒体身份；签名下载地址不进入资料投影。
public struct V2AvatarReference: Codable, Hashable, Sendable {
    /// 头像媒体对象身份。
    public let mediaID: MediaID

    /// 构造资料领域值。
    ///
    /// - Parameters:
    ///   - mediaID: 头像媒体对象身份。
    ///
    /// 保存媒体身份，不校验对象状态、格式或权限。
    public init(mediaID: MediaID) {
        self.mediaID = mediaID
    }
}

/// 面向观察者的资料状态，非活动状态不应披露公开资料与头像。
public enum V2ProfileState: String, Codable, CaseIterable, Sendable {
    /// 可展示的活动资料。
    case active
    /// 用户已注销。
    case deleted
    /// 用户受限。
    case suspended
    /// 对当前观察者不可展示。
    case hidden
}

/// 当前观察者获准读取的全局公开资料视图。
///
/// 可见性变化独立推进 visibilityRevision，即使目标公开资料版本不变。合成 Codable 解码不调用普通构造器的状态组合校验。
public struct V2ProfileView: Codable, Equatable, Sendable {
    /// 目标用户。
    public let userID: UserID
    /// 活动状态必需的同用户公开身份。
    public let publicIdentity: V2PublicIdentity?
    /// 可选头像，非活动状态必须为空。
    public let avatar: V2AvatarReference?
    /// 当前观察者可见的资料状态。
    public let state: V2ProfileState
    /// 目标资料本身的版本。
    public let revision: V2ProfileRevision
    /// 面向当前观察者的可见性版本。
    public let visibilityRevision: V2ProfileRevision

    /// 构造资料领域值。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - publicIdentity: 活动状态必需的同用户公开身份。
    ///   - avatar: 可选头像，非活动状态必须为空。
    ///   - state: 当前观察者可见的资料状态。
    ///   - revision: 目标资料本身的版本。
    ///   - visibilityRevision: 面向当前观察者的可见性版本。
    ///
    /// active 要求 publicIdentity 存在且 userID 一致；deleted、suspended、hidden 要求公开身份与头像均为 nil，否则抛出 invalidProfileView。
    public init(
        userID: UserID,
        publicIdentity: V2PublicIdentity?,
        avatar: V2AvatarReference?,
        state: V2ProfileState,
        revision: V2ProfileRevision,
        visibilityRevision: V2ProfileRevision
    ) throws {
        switch state {
        case .active:
            guard let publicIdentity, publicIdentity.userID == userID else {
                throw V2ProfilePresentationValidationError.invalidProfileView
            }
        case .deleted, .suspended, .hidden:
            guard publicIdentity == nil, avatar == nil else {
                throw V2ProfilePresentationValidationError.invalidProfileView
            }
        }
        self.userID = userID
        self.publicIdentity = publicIdentity
        self.avatar = avatar
        self.state = state
        self.revision = revision
        self.visibilityRevision = visibilityRevision
    }
}

/// 提示重新读取资料的持久失效事件，不包含展示数据，可通过接收者同步日志重放。
public struct V2ProfileInvalidation: Codable, Equatable, Sendable {
    /// 需重新读取的用户。
    public let userID: UserID
    /// 期望至少取得的资料版本。
    public let minimumRevision: V2ProfileRevision

    /// 构造资料领域值。
    ///
    /// - Parameters:
    ///   - userID: 需重新读取的用户。
    ///   - minimumRevision: 期望至少取得的资料版本。
    ///
    /// 保存失效提示，不主动获取资料或修改本地缓存。
    public init(userID: UserID, minimumRevision: V2ProfileRevision) {
        self.userID = userID
        self.minimumRevision = minimumRevision
    }
}

/// 完整目标可变资料状态，预期版本防止旧编辑表单覆盖较新资料，稳定操作身份支持响应丢失重试。
public struct V2ProfileUpdateCommand: Sendable {
    /// 修改资料的用户。
    public let actorUserID: UserID
    /// 稳定资料更新操作身份。
    public let operationID: ProfileUpdateOperationID
    /// 编辑者观察到的资料版本。
    public let expectedRevision: V2ProfileRevision
    /// 按公开显示名规则规范化的名称。
    public let displayName: String
    /// 期望头像引用，nil 表示目标状态不含头像。
    public let avatar: V2AvatarReference?

    /// 构造资料领域值。
    ///
    /// - Parameters:
    ///   - actorUserID: 修改资料的用户。
    ///   - operationID: 稳定资料更新操作身份。
    ///   - expectedRevision: 编辑者观察到的资料版本。
    ///   - displayName: 按公开显示名规则规范化的名称。
    ///   - avatar: 期望头像引用，nil 表示目标状态不含头像。
    ///
    /// 复用 V2PublicIdentity 规范化与验证显示名，相关错误直接传播；内部占位 handle 仅用于复用校验，不修改真实公开账号。头像权限与预期版本比较由服务端执行。
    public init(
        actorUserID: UserID,
        operationID: ProfileUpdateOperationID,
        expectedRevision: V2ProfileRevision,
        displayName: String,
        avatar: V2AvatarReference?
    ) throws {
        // Reuse the established public-name validation and normalization.
        let identity = try V2PublicIdentity(userID: actorUserID, handle: .init("profile_update"), displayName: displayName, accountKind: .regular)
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.displayName = identity.displayName
        self.avatar = avatar
    }
}

/// 资料查询的授权上下文，服务端必须逐项验证，不能将内部用户 ID 查询当成无条件目录。
public enum V2ProfileViewContext: Hashable, Sendable {
    /// 双方私聊关系上下文，具体可见性由服务端确认。
    case directConversation
    /// 现有待处理或已接受关系支持受限名片读取，无须为展示联系人而创建私聊房间。
    case relationship
    /// 指定房间成员上下文。
    case room(RoomID)
}

/// 用户与授权上下文的组合查询键，同一用户在不同上下文中不能直接视为同一授权查询。
public struct V2ProfileViewLookupKey: Hashable, Sendable {
    /// 待查询用户。
    public let userID: UserID
    /// 需要服务端验证的访问上下文。
    public let context: V2ProfileViewContext

    /// 构造资料领域值。
    ///
    /// - Parameters:
    ///   - userID: 待查询用户。
    ///   - context: 需要服务端验证的访问上下文。
    ///
    /// 保存查询身份和上下文，不验证成员或关系资格。
    public init(userID: UserID, context: V2ProfileViewContext) {
        self.userID = userID
        self.context = context
    }
}

/// 资料批量查询的容量常量，由请求边界执行。
public enum V2ProfileViewLookupLimits {
    /// 一次查询最多 100 个用户与上下文组合。
    public static let maximumKeys = 100
}

/// 单个上下文查询的资料或统一不可用结果。
public enum V2ProfileViewLookupResult: Equatable, Sendable {
    /// 该查询键对应的授权资料，枚举本身不校验键与资料身份一致。
    case profile(key: V2ProfileViewLookupKey, view: V2ProfileView)
    /// 统一表示不存在、被阻止或无权访问，不披露具体原因。
    case unavailable(key: V2ProfileViewLookupKey)

    /// 从成功或不可用结果提取原查询键。
    public var key: V2ProfileViewLookupKey {
        switch self {
        case .profile(let key, _), .unavailable(let key): key
        }
    }
}

/// 单个账户拥有的私有备注，不进入对方公开资料或群成员名册。
///
/// 合成 Codable 解码不执行普通构造器的名称规范化，调用边界需保证数据合法。
public struct V2ContactAlias: Codable, Equatable, Sendable {
    /// 私有备注所有者。
    public let ownerUserID: UserID
    /// 被备注的用户。
    public let targetUserID: UserID
    /// 可选规范化备注名，nil 表示未设置。
    public let remarkName: String?
    /// 该私有事实的独立版本。
    public let revision: V2ProfileRevision

    /// 构造资料领域值。
    ///
    /// - Parameters:
    ///   - ownerUserID: 私有备注所有者。
    ///   - targetUserID: 被备注的用户。
    ///   - remarkName: 可选规范化备注名，nil 表示未设置。
    ///   - revision: 该私有事实的独立版本。
    ///
    /// nil 备注直接接受，非 nil 经规范化后无效则抛出 invalidDisplayName；不禁止所有者与目标相同。
    public init(ownerUserID: UserID, targetUserID: UserID, remarkName: String?, revision: V2ProfileRevision) throws {
        let normalized = Self.normalizedName(remarkName)
        guard normalized != nil || remarkName == nil else {
            throw V2ProfilePresentationValidationError.invalidDisplayName
        }
        self.ownerUserID = ownerUserID
        self.targetUserID = targetUserID
        self.remarkName = normalized
        self.revision = revision
    }

    /// 对备注或群昵称做 Unicode 规范组合并裁剪首尾空白，要求非空、最多 80 字节且无控制字符；nil 输入或非法文本均返回 nil，内部非控制空白未被额外禁止。
    fileprivate static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 80,
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return normalized
    }
}

/// 群作用域内的成员展示资料，不复制全局名称和头像，避免公开资料变化引起所有群写入。
///
/// 合成 Codable 解码不执行普通构造器的昵称校验。
public struct V2GroupMemberPresentation: Codable, Equatable, Sendable {
    /// 群作用域。
    public let roomID: RoomID
    /// 成员用户。
    public let userID: UserID
    /// 可选规范化群昵称。
    public let groupNickname: String?
    /// 该群成员展示事实的独立版本。
    public let revision: V2ProfileRevision

    /// 构造资料领域值。
    ///
    /// - Parameters:
    ///   - roomID: 群作用域。
    ///   - userID: 成员用户。
    ///   - groupNickname: 可选规范化群昵称。
    ///   - revision: 该群成员展示事实的独立版本。
    ///
    /// 复用私有备注的名称规范化；nil 允许，非 nil 无效时抛出 invalidDisplayName，不校验当前成员资格。
    public init(roomID: RoomID, userID: UserID, groupNickname: String?, revision: V2ProfileRevision) throws {
        let normalized = V2ContactAlias.normalizedName(groupNickname)
        guard normalized != nil || groupNickname == nil else {
            throw V2ProfilePresentationValidationError.invalidDisplayName
        }
        self.roomID = roomID
        self.userID = userID
        self.groupNickname = normalized
        self.revision = revision
    }
}

/// 名称解析使用的展示场景，群场景显式选择是否允许私有备注。
public enum V2ProfileDisplaySurface: Sendable {
    /// 私聊展示，允许私有备注，不使用群昵称。
    case directConversation
    /// 群消息展示，允许群昵称，私有备注由关联开关控制。
    case groupMessage(allowsPrivateAlias: Bool)
    /// 群成员列表展示，允许群昵称，私有备注由关联开关控制。
    case groupMemberList(allowsPrivateAlias: Bool)
}

/// 展示结果的完整版本依赖向量，可比较相等并用作缓存键，不定义跨来源大小关系。
public struct V2ResolvedProfileDependency: Hashable, Sendable {
    /// 公开资料版本。
    public let profileRevision: V2ProfileRevision?
    /// 私有备注版本。
    public let aliasRevision: V2ProfileRevision?
    /// 群成员展示资料版本。
    public let groupMemberRevision: V2ProfileRevision?
    /// 面向当前观察者的可见性版本。
    public let visibilityRevision: V2ProfileRevision?

    /// 保存解析字段，不进行网络访问、权限验证或跨来源版本合并。
    public init(profileRevision: V2ProfileRevision?, aliasRevision: V2ProfileRevision?, groupMemberRevision: V2ProfileRevision?, visibilityRevision: V2ProfileRevision?) {
        self.profileRevision = profileRevision
        self.aliasRevision = aliasRevision
        self.groupMemberRevision = groupMemberRevision
        self.visibilityRevision = visibilityRevision
    }
}

/// 解析后的展示快照，包含名称、可选头像、状态及刷新依赖，不重新验证授权。
public struct V2ResolvedProfile: Equatable, Sendable {
    /// 展示目标用户。
    public let userID: UserID
    /// 按场景优先级选出的名称。
    public let displayName: String
    /// 仅在允许展示的活动资料状态下使用的头像引用。
    public let avatar: V2AvatarReference?
    /// 公开资料状态，缺失时解析为 hidden。
    public let state: V2ProfileState
    /// 用于判断展示输入变化的版本向量。
    public let dependency: V2ResolvedProfileDependency

    /// 保存解析字段，不进行网络访问、权限验证或跨来源版本合并。
    public init(userID: UserID, displayName: String, avatar: V2AvatarReference?, state: V2ProfileState, dependency: V2ResolvedProfileDependency) {
        self.userID = userID
        self.displayName = displayName
        self.avatar = avatar
        self.state = state
        self.dependency = dependency
    }
}

/// 多个展示场景共用的纯资料解析器，不执行网络、持久化或界面观察。
///
/// 输入选择与权限上下文由调用者负责，相同输入得到相同展示结果。
public enum V2ProfileResolver {
    /// 按展示场景组合公开资料、私有备注与群昵称，返回包含依赖版本的展示结果。
    ///
    /// - Parameters:
    ///   - userID: 要展示的用户。
    ///   - profile: 可选已授权公开资料，只使用 userID 匹配项。
    ///   - alias: 可选私有备注，只比较 targetUserID，调用方还须保证备注所属当前账户。
    ///   - groupMember: 可选群资料，只比较 userID，调用方须保证房间上下文正确。
    ///   - surface: 展示场景，决定是否允许私有备注与群昵称。
    /// - Returns: 名称、头像、状态及完整依赖版本组合。
    ///
    /// 已知非 active 资料优先显示状态占位名；否则按允许的私有备注、群昵称、公开名、占位名依次选择。
    /// 私聊不使用群昵称。没有公开资料时状态为 hidden，但仍可采用允许的备注或群昵称；头像仅在 active 时保留。
    /// 依赖向量保留所有匹配输入的版本，即使某项没有最终参与名称选择。
    public static func resolve(
        userID: UserID,
        profile: V2ProfileView?,
        alias: V2ContactAlias?,
        groupMember: V2GroupMemberPresentation?,
        surface: V2ProfileDisplaySurface
    ) -> V2ResolvedProfile {
        let matchingProfile = profile?.userID == userID ? profile : nil
        let matchingAlias = alias?.targetUserID == userID ? alias : nil
        let matchingGroupMember = groupMember?.userID == userID ? groupMember : nil
        let privateAliasAllowed: Bool
        let groupNameAllowed: Bool
        switch surface {
        case .directConversation:
            privateAliasAllowed = true
            groupNameAllowed = false
        case .groupMessage(let allowsPrivateAlias), .groupMemberList(let allowsPrivateAlias):
            privateAliasAllowed = allowsPrivateAlias
            groupNameAllowed = true
        }

        let state = matchingProfile?.state ?? .hidden
        let publicName = matchingProfile?.publicIdentity?.displayName
        let displayName: String
        if state != .active, matchingProfile != nil {
            displayName = fallbackName(for: state)
        } else if privateAliasAllowed, let remark = matchingAlias?.remarkName {
            displayName = remark
        } else if groupNameAllowed, let groupNickname = matchingGroupMember?.groupNickname {
            displayName = groupNickname
        } else if let publicName {
            displayName = publicName
        } else {
            displayName = fallbackName(for: matchingProfile?.state)
        }

        let avatar = state == .active ? matchingProfile?.avatar : nil
        return .init(
            userID: userID,
            displayName: displayName,
            avatar: avatar,
            state: state,
            dependency: .init(
                profileRevision: matchingProfile?.revision,
                aliasRevision: matchingAlias?.revision,
                groupMemberRevision: matchingGroupMember?.revision,
                visibilityRevision: matchingProfile?.visibilityRevision
            )
        )
    }

    /// 将已注销、受限或不可用状态映射为固定中文占位名，缺失或 active 但无名称时也返回资料暂不可用。
    private static func fallbackName(for state: V2ProfileState?) -> String {
        switch state {
        case .deleted: "已注销用户"
        case .suspended: "受限用户"
        case .hidden, .none: "资料暂不可用"
        case .active: "资料暂不可用"
        }
    }
}

/// 资料状态组合或展示名称校验错误。
public enum V2ProfilePresentationValidationError: Error, Equatable, Sendable {
    /// 活动资料缺少匹配公开身份，或非活动资料仍携带公开身份或头像。
    case invalidProfileView
    /// 备注、昵称或显示名不符合相应校验规则。
    case invalidDisplayName
}
