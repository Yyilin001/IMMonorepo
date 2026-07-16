import Foundation
import SQLKit

struct ConversationListJoinedReader {
    let database: any SQLDatabase

    func listConversations(
        for userID: UUID,
        cursor: IMConversationSummaryProjectionService.PageCursor?,
        limit: Int,
        kind: IMConversationKind?,
        memberUserIDsLimit: Int = 0
    ) async throws -> JoinedConversationListPage {
        let memberUserIDsLimit = max(0, memberUserIDsLimit)
        let kindPredicate: SQLQueryString
        if let kind {
            kindPredicate = "AND \(ident: "summary").\(ident: "kind") = \(bind: kind.rawValue)"
        } else {
            kindPredicate = ""
        }

        let cursorPredicate: SQLQueryString
        if let cursor {
            let pinnedCursorActivityAt = cursor.lastActivityAt
            let pinnedCursorPinnedAt = cursor.pinnedAt ?? cursor.lastActivityAt
            if cursor.isPinned {
                cursorPredicate = """
                    AND (
                        (
                            \(ident: "rows").\(ident: "summary_is_pinned") = \(bind: true)
                            AND (
                                \(ident: "rows").\(ident: "effective_pinned_at") < \(bind: pinnedCursorPinnedAt)
                                OR (
                                    \(ident: "rows").\(ident: "effective_pinned_at") = \(bind: pinnedCursorPinnedAt)
                                    AND \(ident: "rows").\(ident: "effective_last_activity_at") < \(bind: pinnedCursorActivityAt)
                                )
                                OR (
                                    \(ident: "rows").\(ident: "effective_pinned_at") = \(bind: pinnedCursorPinnedAt)
                                    AND \(ident: "rows").\(ident: "effective_last_activity_at") = \(bind: pinnedCursorActivityAt)
                                    AND \(ident: "rows").\(ident: "summary_id") < \(bind: cursor.recordID)
                                )
                            )
                        )
                        OR \(ident: "rows").\(ident: "summary_is_pinned") = \(bind: false)
                    )
                    """
            } else {
                cursorPredicate = """
                    AND \(ident: "rows").\(ident: "summary_is_pinned") = \(bind: false)
                    AND (
                        \(ident: "rows").\(ident: "effective_last_activity_at") < \(bind: cursor.lastActivityAt)
                        OR (
                            \(ident: "rows").\(ident: "effective_last_activity_at") = \(bind: cursor.lastActivityAt)
                            AND \(ident: "rows").\(ident: "summary_id") < \(bind: cursor.recordID)
                        )
                    )
                    """
            }
        } else {
            cursorPredicate = ""
        }

        let rows = try await database.raw("""
            WITH \(ident: "rows") AS (
                SELECT
                    \(ident: "summary").\(ident: "id") AS \(ident: "summary_id"),
                    \(ident: "summary").\(ident: "conversation_id") AS \(ident: "summary_conversation_id"),
                    \(ident: "summary").\(ident: "title") AS \(ident: "summary_title"),
                    \(ident: "summary").\(ident: "kind") AS \(ident: "summary_kind"),
                    \(ident: "summary").\(ident: "direct_messaging_state") AS \(ident: "summary_direct_messaging_state"),
                    \(ident: "summary").\(ident: "group_lifecycle_state") AS \(ident: "summary_group_lifecycle_state"),
                    \(ident: "summary").\(ident: "direct_peer_user_id") AS \(ident: "summary_direct_peer_user_id"),
                    \(ident: "summary").\(ident: "direct_peer_email") AS \(ident: "summary_direct_peer_email"),
                    \(ident: "summary").\(ident: "direct_peer_display_name") AS \(ident: "summary_direct_peer_display_name"),
                    \(ident: "summary").\(ident: "direct_peer_avatar_preset") AS \(ident: "summary_direct_peer_avatar_preset"),
                    \(ident: "summary").\(ident: "notice") AS \(ident: "summary_notice"),
                    \(ident: "summary").\(ident: "avatar_preset") AS \(ident: "summary_avatar_preset"),
                    \(ident: "summary").\(ident: "mute_all") AS \(ident: "summary_mute_all"),
                    \(ident: "summary").\(ident: "member_count") AS \(ident: "summary_member_count"),
                    CASE
                        WHEN \(bind: memberUserIDsLimit) > \(bind: 0)
                         AND \(ident: "summary").\(ident: "member_count") > \(bind: memberUserIDsLimit)
                        THEN \(bind: "[]")
                        ELSE \(ident: "summary").\(ident: "member_user_ids_json")
                    END AS \(ident: "summary_member_user_ids_json"),
                    \(ident: "summary").\(ident: "last_message_json") AS \(ident: "summary_last_message_json"),
                    \(ident: "summary").\(ident: "last_read_sequence") AS \(ident: "summary_last_read_sequence"),
                    \(ident: "summary").\(ident: "unread_count") AS \(ident: "summary_unread_count"),
                    \(ident: "summary").\(ident: "is_pinned") AS \(ident: "summary_is_pinned"),
                    \(ident: "summary").\(ident: "pinned_at") AS \(ident: "summary_pinned_at"),
                    \(ident: "summary").\(ident: "is_muted") AS \(ident: "summary_is_muted"),
                    \(ident: "summary").\(ident: "last_activity_at") AS \(ident: "summary_last_activity_at"),
                    \(ident: "activity").\(ident: "last_message_json") AS \(ident: "activity_last_message_json"),
                    \(ident: "activity").\(ident: "last_message_server_sequence") AS \(ident: "activity_last_message_server_sequence"),
                    \(ident: "activity").\(ident: "last_activity_at") AS \(ident: "activity_last_activity_at"),
                    CASE
                        WHEN \(ident: "activity").\(ident: "last_activity_at") IS NOT NULL
                         AND \(ident: "activity").\(ident: "last_activity_at") > \(ident: "summary").\(ident: "last_activity_at")
                        THEN \(ident: "activity").\(ident: "last_activity_at")
                        ELSE \(ident: "summary").\(ident: "last_activity_at")
                    END AS \(ident: "effective_last_activity_at"),
                    CASE
                        WHEN \(ident: "summary").\(ident: "is_pinned") = \(bind: true)
                        THEN COALESCE(
                            \(ident: "summary").\(ident: "pinned_at"),
                            CASE
                                WHEN \(ident: "activity").\(ident: "last_activity_at") IS NOT NULL
                                 AND \(ident: "activity").\(ident: "last_activity_at") > \(ident: "summary").\(ident: "last_activity_at")
                                THEN \(ident: "activity").\(ident: "last_activity_at")
                                ELSE \(ident: "summary").\(ident: "last_activity_at")
                            END
                        )
                        ELSE NULL
                    END AS \(ident: "effective_pinned_at")
                FROM \(ident: ConversationUserSummary.schema) AS \(ident: "summary")
                LEFT JOIN \(ident: ConversationActivitySummary.schema) AS \(ident: "activity")
                    ON \(ident: "activity").\(ident: "conversation_id") = \(ident: "summary").\(ident: "conversation_id")
                WHERE \(ident: "summary").\(ident: "owner_user_id") = \(bind: userID)
                    AND \(ident: "summary").\(ident: "is_removed") = \(bind: false)
                    \(kindPredicate)
            )
            SELECT * FROM \(ident: "rows")
            WHERE 1 = 1
                \(cursorPredicate)
            ORDER BY
                \(ident: "summary_is_pinned") DESC,
                \(ident: "effective_pinned_at") DESC,
                \(ident: "effective_last_activity_at") DESC,
                \(ident: "summary_id") DESC
            LIMIT \(bind: limit + 1)
            """).all(decoding: JoinedConversationSummaryRow.self)

        let hasMore = rows.count > limit
        return JoinedConversationListPage(
            rows: Array(rows.prefix(limit)),
            hasMore: hasMore
        )
    }
}

struct JoinedConversationListPage {
    let rows: [JoinedConversationSummaryRow]
    let hasMore: Bool
}

struct JoinedConversationSummaryRow: Decodable {
    let summaryID: String
    let summaryConversationID: UUID
    let summaryTitle: String?
    let summaryKind: String
    let summaryDirectMessagingState: String?
    let summaryGroupLifecycleState: String
    let summaryDirectPeerUserID: UUID?
    let summaryDirectPeerEmail: String?
    let summaryDirectPeerDisplayName: String?
    let summaryDirectPeerAvatarPreset: String?
    let summaryNotice: String?
    let summaryAvatarPreset: String?
    let summaryMuteAll: Bool
    let summaryMemberCount: Int
    let summaryMemberUserIDsJSON: String
    let summaryLastMessageJSON: String?
    let summaryLastReadSequence: Int
    let summaryUnreadCount: Int
    let summaryIsPinned: Bool
    let summaryPinnedAt: Date?
    let summaryIsMuted: Bool
    let summaryLastActivityAt: Date
    let activityLastMessageJSON: String?
    let activityLastMessageServerSequence: Int?
    let activityLastActivityAt: Date?
    let effectiveLastActivityAt: Date

    enum CodingKeys: String, CodingKey {
        case summaryID = "summary_id"
        case summaryConversationID = "summary_conversation_id"
        case summaryTitle = "summary_title"
        case summaryKind = "summary_kind"
        case summaryDirectMessagingState = "summary_direct_messaging_state"
        case summaryGroupLifecycleState = "summary_group_lifecycle_state"
        case summaryDirectPeerUserID = "summary_direct_peer_user_id"
        case summaryDirectPeerEmail = "summary_direct_peer_email"
        case summaryDirectPeerDisplayName = "summary_direct_peer_display_name"
        case summaryDirectPeerAvatarPreset = "summary_direct_peer_avatar_preset"
        case summaryNotice = "summary_notice"
        case summaryAvatarPreset = "summary_avatar_preset"
        case summaryMuteAll = "summary_mute_all"
        case summaryMemberCount = "summary_member_count"
        case summaryMemberUserIDsJSON = "summary_member_user_ids_json"
        case summaryLastMessageJSON = "summary_last_message_json"
        case summaryLastReadSequence = "summary_last_read_sequence"
        case summaryUnreadCount = "summary_unread_count"
        case summaryIsPinned = "summary_is_pinned"
        case summaryPinnedAt = "summary_pinned_at"
        case summaryIsMuted = "summary_is_muted"
        case summaryLastActivityAt = "summary_last_activity_at"
        case activityLastMessageJSON = "activity_last_message_json"
        case activityLastMessageServerSequence = "activity_last_message_server_sequence"
        case activityLastActivityAt = "activity_last_activity_at"
        case effectiveLastActivityAt = "effective_last_activity_at"
    }

    var response: IMConversationResponse? {
        guard let memberUserIDs = try? Self.decodeUUIDs(summaryMemberUserIDsJSON) else {
            return nil
        }

        let summaryLastMessage = try? Self.decodeLastMessage(summaryLastMessageJSON)
        let activityLastMessage = try? Self.decodeLastMessage(activityLastMessageJSON)
        let summaryLastSequence = summaryLastMessage?.serverSequence ?? 0
        let activityLastSequence = activityLastMessageServerSequence.flatMap { UInt64($0) } ?? 0
        let useActivityMessage = activityLastMessage != nil && activityLastSequence >= summaryLastSequence
        let lastMessage = useActivityMessage ? activityLastMessage : summaryLastMessage
        let lastActivityAt = useActivityMessage
            ? (activityLastActivityAt ?? effectiveLastActivityAt)
            : effectiveLastActivityAt
        let activityUnreadCount: UInt64
        if activityLastSequence > UInt64(summaryLastReadSequence) {
            activityUnreadCount = activityLastSequence - UInt64(summaryLastReadSequence)
        } else {
            activityUnreadCount = 0
        }
        let unreadCount = max(summaryUnreadCount, Int(clamping: activityUnreadCount))

        return IMConversationResponse(
            id: summaryConversationID,
            title: summaryTitle,
            kind: summaryKind,
            directMessagingState: summaryDirectMessagingState,
            groupLifecycleState: summaryKind == IMConversationKind.group.rawValue
                ? (IMGroupLifecycleState(rawValue: summaryGroupLifecycleState) ?? .active).rawValue
                : nil,
            directPeer: summaryDirectPeerUserID.map {
                IMDirectPeerResponse(
                    id: $0,
                    email: summaryDirectPeerEmail ?? "",
                    displayName: summaryDirectPeerDisplayName,
                    avatarPreset: summaryDirectPeerAvatarPreset.flatMap(UserAvatarPreset.init(rawValue:))
                )
            },
            notice: summaryNotice,
            avatarPreset: summaryAvatarPreset.flatMap(IMConversationAvatarPreset.init(rawValue:)),
            muteAll: summaryMuteAll,
            memberCount: summaryMemberCount,
            memberUserIDs: memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            lastMessage: lastMessage,
            lastReadSequence: UInt64(summaryLastReadSequence),
            unreadCount: unreadCount,
            isPinned: summaryIsPinned,
            pinnedAt: summaryPinnedAt,
            isMuted: summaryIsMuted,
            createdAt: nil,
            updatedAt: lastActivityAt
        )
    }

    var pageCursor: IMConversationSummaryProjectionService.PageCursor {
        IMConversationSummaryProjectionService.PageCursor(
            isPinned: summaryIsPinned,
            pinnedAt: summaryPinnedAt,
            lastActivityAt: effectiveLastActivityAt,
            recordID: summaryID
        )
    }

    private static func decodeUUIDs(_ json: String) throws -> [UUID] {
        try JSONDecoder().decode([UUID].self, from: Data(json.utf8))
    }

    private static func decodeLastMessage(_ json: String?) throws -> IMMessagePreviewResponse? {
        guard let json else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IMMessagePreviewResponse.self, from: Data(json.utf8))
    }
}
