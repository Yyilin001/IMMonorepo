import IMV2Core

/// A bounded projection window. The anchor is resolved in the same SQLite
/// snapshot as its neighbors; the caller may restore this ID after publishing.
public struct V2ClientConversationListWindow: Sendable {
    public let page: V2ClientConversationListPage
    public let anchor: V2ClientConversationListCursor?
    public let hasEarlier: Bool
}

public struct V2ClientRelationshipWindow: Sendable {
    public let page: V2ClientRelationshipPage
    public let anchor: V2ClientRelationshipCursor?
    public let hasEarlier: Bool
}
