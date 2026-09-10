import Foundation
import IMV2Core

/// 好友关系的设备内读模型。
///
/// 这些模型只由持久化用户同步记录派生，并且刻意不解释其他用户为何处于拉黑状态。
public struct V2ClientRelationshipProjection: Equatable, Sendable {
    /// 关系对端用户。
    public let targetUserID: UserID
    /// 当前关系状态。
    public let state: V2RelationshipState
    /// 发起请求的用户；不适用时为空。
    public let requestedByUserID: UserID?
    /// 最近更新时刻。
    public let updatedAt: Date

    /// 保存关系读模型。
    ///
    /// - Parameters:
    ///   - targetUserID: 关系对端用户。
    ///   - state: 当前关系状态。
    ///   - requestedByUserID: 发起请求的用户。
    ///   - updatedAt: 最近更新时刻。
    public init(targetUserID: UserID, state: V2RelationshipState, requestedByUserID: UserID?, updatedAt: Date) { self.targetUserID = targetUserID; self.state = state; self.requestedByUserID = requestedByUserID; self.updatedAt = updatedAt }
}

/// 关系分页的作用域。
public enum V2ClientRelationshipPageScope: Equatable, Sendable {
    /// 已建立的好友关系。
    case accepted
    /// 收到的待处理请求。
    case incomingRequests(currentUserID: UserID)
    /// 发出的待处理请求。
    case outgoingRequests(currentUserID: UserID)
}

/// 关系分页游标。
public struct V2ClientRelationshipCursor: Equatable, Sendable {
    /// 上一条记录的更新时刻。
    public let updatedAt: Date
    /// 上一条记录的对端用户。
    public let targetUserID: UserID

    /// 保存游标。
    ///
    /// - Parameters:
    ///   - updatedAt: 上一条记录的更新时刻。
    ///   - targetUserID: 上一条记录的对端用户。
    public init(updatedAt: Date, targetUserID: UserID) {
        self.updatedAt = updatedAt
        self.targetUserID = targetUserID
    }
}

/// 关系分页结果。
public struct V2ClientRelationshipPage: Equatable, Sendable {
    /// 本页关系记录。
    public let relationships: [V2ClientRelationshipProjection]
    /// 下一页游标；为空表示已到末尾。
    public let nextCursor: V2ClientRelationshipCursor?
    /// 该作用域下的记录总数；未知时为空。
    public let totalCount: Int?

    /// 保存关系分页。
    ///
    /// - Parameters:
    ///   - relationships: 本页记录。
    ///   - nextCursor: 下一页游标。
    ///   - totalCount: 记录总数。
    public init(
        relationships: [V2ClientRelationshipProjection],
        nextCursor: V2ClientRelationshipCursor?,
        totalCount: Int?
    ) {
        self.relationships = relationships
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}

/// 用户拉黑状态的设备内读模型。
public struct V2ClientUserBlockProjection: Equatable, Sendable {
    /// 目标用户。
    public let targetUserID: UserID
    /// 当前用户是否已拉黑对方。
    public let isBlocked: Bool
    /// 最近更新时刻。
    public let updatedAt: Date

    /// 保存拉黑读模型。
    ///
    /// - Parameters:
    ///   - targetUserID: 目标用户。
    ///   - isBlocked: 是否已拉黑。
    ///   - updatedAt: 最近更新时刻。
    public init(targetUserID: UserID, isBlocked: Bool, updatedAt: Date) { self.targetUserID = targetUserID; self.isBlocked = isBlocked; self.updatedAt = updatedAt }
}

/// 陌生人消息偏好的设备内读模型。
public struct V2ClientStrangerMessagePreference: Equatable, Sendable {
    /// 是否允许陌生人发消息。
    public let allowsStrangerMessages: Bool
    /// 最近更新时刻。
    public let updatedAt: Date

    /// 保存偏好读模型。
    ///
    /// - Parameters:
    ///   - allowsStrangerMessages: 是否允许陌生人发消息。
    ///   - updatedAt: 最近更新时刻。
    public init(allowsStrangerMessages: Bool, updatedAt: Date) { self.allowsStrangerMessages = allowsStrangerMessages; self.updatedAt = updatedAt }
}

/// 被添加好友偏好的设备内读模型。
public struct V2ClientUserAddPreference: Equatable, Sendable {
    /// 是否允许被添加为好友。
    public let allowsBeingAdded: Bool
    /// 最近更新时刻。
    public let updatedAt: Date

    /// 保存偏好读模型。
    ///
    /// - Parameters:
    ///   - allowsBeingAdded: 是否允许被添加。
    ///   - updatedAt: 最近更新时刻。
    public init(allowsBeingAdded: Bool, updatedAt: Date) { self.allowsBeingAdded = allowsBeingAdded; self.updatedAt = updatedAt }
}

/// 社交投影错误。
public enum V2ClientSocialProjectionError: Error, Equatable, Sendable { case invalidPayload }
