import Foundation
import SQLKit

struct ConversationChangesJoinedReader {
    let database: any SQLDatabase

    func listConversationChanges(
        for userID: UUID,
        afterToken: IMConversationSummaryProjectionService.ChangeToken,
        pageCursor: IMConversationSummaryProjectionService.ChangeToken?,
        limit: Int
    ) async throws -> JoinedConversationChangesPage {
        let cursorPredicate: SQLQueryString
        if let pageCursor {
            cursorPredicate = """
                AND (
                    \(ident: "log").\(ident: "updated_at") > \(bind: pageCursor.updatedAt)
                    OR (
                        \(ident: "log").\(ident: "updated_at") = \(bind: pageCursor.updatedAt)
                        AND \(ident: "log").\(ident: "id") > \(bind: pageCursor.recordID)
                    )
                )
                """
        } else {
            cursorPredicate = ""
        }

        let rows = try await database.raw("""
            SELECT
                \(ident: "log").\(ident: "id") AS \(ident: "change_id"),
                \(ident: "log").\(ident: "conversation_id") AS \(ident: "change_conversation_id"),
                \(ident: "log").\(ident: "summary_record_id") AS \(ident: "change_summary_record_id"),
                \(ident: "log").\(ident: "updated_at") AS \(ident: "change_updated_at"),
                \(ident: "log").\(ident: "is_removed") AS \(ident: "change_is_removed"),
                \(ident: "summary").\(ident: "conversation_id") AS \(ident: "summary_conversation_id"),
                \(ident: "summary").\(ident: "title") AS \(ident: "summary_title"),
                \(ident: "summary").\(ident: "kind") AS \(ident: "summary_kind"),
                \(ident: "summary").\(ident: "direct_messaging_state") AS \(ident: "summary_direct_messaging_state"),
                \(ident: "summary").\(ident: "direct_peer_user_id") AS \(ident: "summary_direct_peer_user_id"),
                \(ident: "summary").\(ident: "direct_peer_email") AS \(ident: "summary_direct_peer_email"),
                \(ident: "summary").\(ident: "direct_peer_display_name") AS \(ident: "summary_direct_peer_display_name"),
                \(ident: "summary").\(ident: "direct_peer_avatar_preset") AS \(ident: "summary_direct_peer_avatar_preset"),
                \(ident: "summary").\(ident: "notice") AS \(ident: "summary_notice"),
                \(ident: "summary").\(ident: "avatar_preset") AS \(ident: "summary_avatar_preset"),
                \(ident: "summary").\(ident: "mute_all") AS \(ident: "summary_mute_all"),
                \(ident: "summary").\(ident: "member_count") AS \(ident: "summary_member_count"),
                \(ident: "summary").\(ident: "member_user_ids_json") AS \(ident: "summary_member_user_ids_json"),
                \(ident: "summary").\(ident: "last_message_json") AS \(ident: "summary_last_message_json"),
                \(ident: "summary").\(ident: "last_read_sequence") AS \(ident: "summary_last_read_sequence"),
                \(ident: "summary").\(ident: "unread_count") AS \(ident: "summary_unread_count"),
                \(ident: "summary").\(ident: "is_pinned") AS \(ident: "summary_is_pinned"),
                \(ident: "summary").\(ident: "pinned_at") AS \(ident: "summary_pinned_at"),
                \(ident: "summary").\(ident: "is_muted") AS \(ident: "summary_is_muted"),
                \(ident: "summary").\(ident: "last_activity_at") AS \(ident: "summary_last_activity_at")
            FROM \(ident: ConversationChangesLogEntry.schema) AS \(ident: "log")
            LEFT JOIN \(ident: ConversationUserSummary.schema) AS \(ident: "summary")
                ON \(ident: "summary").\(ident: "id") = \(ident: "log").\(ident: "summary_record_id")
            WHERE \(ident: "log").\(ident: "owner_user_id") = \(bind: userID)
                AND (
                    \(ident: "log").\(ident: "updated_at") > \(bind: afterToken.updatedAt)
                    OR (
                        \(ident: "log").\(ident: "updated_at") = \(bind: afterToken.updatedAt)
                        AND \(ident: "log").\(ident: "id") > \(bind: afterToken.recordID)
                    )
                )
                \(cursorPredicate)
            ORDER BY \(ident: "log").\(ident: "updated_at") ASC, \(ident: "log").\(ident: "id") ASC
            LIMIT \(bind: limit + 1)
            """).all(decoding: JoinedConversationChangeRow.self)

        let hasMore = rows.count > limit
        return JoinedConversationChangesPage(
            rows: Array(rows.prefix(limit)),
            hasMore: hasMore
        )
    }
}

struct JoinedConversationChangesPage {
    let rows: [JoinedConversationChangeRow]
    let hasMore: Bool
}

struct JoinedConversationChangeRow: Decodable {
    let changeID: String
    let changeConversationID: UUID
    let changeSummaryRecordID: String
    let changeUpdatedAt: Date
    let changeIsRemoved: Bool
    let summaryConversationID: UUID?
    let summaryTitle: String?
    let summaryKind: String?
    let summaryDirectMessagingState: String?
    let summaryDirectPeerUserID: UUID?
    let summaryDirectPeerEmail: String?
    let summaryDirectPeerDisplayName: String?
    let summaryDirectPeerAvatarPreset: String?
    let summaryNotice: String?
    let summaryAvatarPreset: String?
    let summaryMuteAll: Bool?
    let summaryMemberCount: Int?
    let summaryMemberUserIDsJSON: String?
    let summaryLastMessageJSON: String?
    let summaryLastReadSequence: Int?
    let summaryUnreadCount: Int?
    let summaryIsPinned: Bool?
    let summaryPinnedAt: Date?
    let summaryIsMuted: Bool?
    let summaryLastActivityAt: Date?

    enum CodingKeys: String, CodingKey {
        case changeID = "change_id"
        case changeConversationID = "change_conversation_id"
        case changeSummaryRecordID = "change_summary_record_id"
        case changeUpdatedAt = "change_updated_at"
        case changeIsRemoved = "change_is_removed"
        case summaryConversationID = "summary_conversation_id"
        case summaryTitle = "summary_title"
        case summaryKind = "summary_kind"
        case summaryDirectMessagingState = "summary_direct_messaging_state"
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
    }

    var response: IMConversationResponse? {
        guard !changeIsRemoved,
              let conversationID = summaryConversationID,
              let kind = summaryKind,
              let memberCount = summaryMemberCount,
              let memberUserIDsJSON = summaryMemberUserIDsJSON,
              let lastReadSequence = summaryLastReadSequence,
              let unreadCount = summaryUnreadCount,
              let isPinned = summaryIsPinned,
              let isMuted = summaryIsMuted,
              let lastActivityAt = summaryLastActivityAt,
              let memberUserIDs = try? Self.decodeUUIDs(memberUserIDsJSON),
              let lastMessage = try? Self.decodeLastMessage(summaryLastMessageJSON)
        else {
            return nil
        }

        return IMConversationResponse(
            id: conversationID,
            title: summaryTitle,
            kind: kind,
            directMessagingState: summaryDirectMessagingState,
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
            muteAll: summaryMuteAll ?? false,
            memberCount: memberCount,
            memberUserIDs: memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            lastMessage: lastMessage,
            lastReadSequence: lastReadSequence,
            unreadCount: unreadCount,
            isPinned: isPinned,
            pinnedAt: summaryPinnedAt,
            isMuted: isMuted,
            createdAt: nil,
            updatedAt: lastActivityAt
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
