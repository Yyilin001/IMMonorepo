import IMV2Core

/// 会话列表的有界投影窗口。
///
/// 锚点与其相邻记录在同一次 SQLite 快照中解析；发布之后调用方可以按该标识恢复位置。
public struct V2ClientConversationListWindow: Sendable {
    /// 本窗口返回的会话分页。
    public let page: V2ClientConversationListPage
    /// 窗口锚点游标；为空表示没有可恢复的锚点。
    public let anchor: V2ClientConversationListCursor?
    /// 锚点之前是否还有更早的数据。
    public let hasEarlier: Bool
}

/// 关系列表的有界投影窗口。
///
/// 锚点与其相邻记录在同一次 SQLite 快照中解析；发布之后调用方可以按该标识恢复位置。
public struct V2ClientRelationshipWindow: Sendable {
    /// 本窗口返回的关系分页。
    public let page: V2ClientRelationshipPage
    /// 窗口锚点游标；为空表示没有可恢复的锚点。
    public let anchor: V2ClientRelationshipCursor?
    /// 锚点之前是否还有更早的数据。
    public let hasEarlier: Bool
}
