import Fluent
import Foundation
import SQLKit
import Vapor

extension IMConversationSummaryProjectionService {
    func latestVisibleMessagesByThreshold(
        conversationID: UUID,
        memberships: [ConversationMember],
        preferredMessage: ConversationMessage?,
        on database: any Database
    ) async throws -> [Int: ConversationMessage] {
        let visibleFromSequences = Array(Set(memberships.map(\.visibleFromSequence))).sorted()
        guard !visibleFromSequences.isEmpty else {
            return [:]
        }

        if let preferredMessage,
           preferredMessage.$conversation.id == conversationID
        {
            return Dictionary(uniqueKeysWithValues: visibleFromSequences.compactMap { visibleFromSequence in
                guard preferredMessage.serverSequence >= visibleFromSequence else {
                    return nil
                }
                return (visibleFromSequence, preferredMessage)
            })
        }

        if let sql = database as? any SQLDatabase,
           let latestMessages = try await latestVisibleMessagesByThresholdSQL(
            conversationID: conversationID,
            visibleFromSequences: visibleFromSequences,
            sql: sql,
            database: database
           ) {
            return latestMessages
        }

        var latestMessages: [Int: ConversationMessage] = [:]
        latestMessages.reserveCapacity(visibleFromSequences.count)
        for visibleFromSequence in visibleFromSequences {
            if let latest = try await ConversationMessage.query(on: database)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= visibleFromSequence)
                .sort(\.$serverSequence, .descending)
                .first()
            {
                latestMessages[visibleFromSequence] = latest
            }
        }
        return latestMessages
    }

    func latestVisibleMessagesByThresholdSQL(
        conversationID: UUID,
        visibleFromSequences: [Int],
        sql: any SQLDatabase,
        database: any Database
    ) async throws -> [Int: ConversationMessage]? {
        guard sql.dialect.name == "postgresql" || sql.dialect.name == "sqlite" else {
            return nil
        }

        struct LatestMessageRow: Decodable {
            let visibleFromSequence: Int
            let messageID: UUID?

            enum CodingKeys: String, CodingKey {
                case visibleFromSequence = "visible_from_sequence"
                case messageID = "message_id"
            }
        }

        let values = visibleFromSequences.map {
            "(\(bind: $0))" as SQLQueryString
        }.joined(separator: ", ")
        let rows = try await sql.raw("""
            WITH \(ident: "thresholds")(\(ident: "visible_from_sequence")) AS (
                VALUES \(values)
            )
            SELECT
                \(ident: "thresholds").\(ident: "visible_from_sequence"),
                (
                    SELECT \(ident: "message").\(ident: "id")
                    FROM \(ident: ConversationMessage.schema) AS \(ident: "message")
                    WHERE \(ident: "message").\(ident: "conversation_id") = \(bind: conversationID)
                      AND \(ident: "message").\(ident: "server_sequence") >= \(ident: "thresholds").\(ident: "visible_from_sequence")
                    ORDER BY \(ident: "message").\(ident: "server_sequence") DESC
                    LIMIT 1
                ) AS \(ident: "message_id")
            FROM \(ident: "thresholds")
            """).all(decoding: LatestMessageRow.self)

        let messageIDs = Array(Set(rows.compactMap(\.messageID)))
        guard !messageIDs.isEmpty else {
            return [:]
        }

        let messages = try await ConversationMessage.query(on: database)
            .filter(\.$id ~~ messageIDs)
            .all()
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
            message.id.map { ($0, message) }
        })
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let messageID = row.messageID,
                  let message = messagesByID[messageID]
            else {
                return nil
            }
            return (row.visibleFromSequence, message)
        })
    }

    func updateMessageCreatedDynamicSummaries(
        _ summaries: [ConversationUserSummary],
        on database: any Database
    ) async throws {
        guard !summaries.isEmpty else {
            return
        }

        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            for summary in summaries {
                try await summary.update(on: database)
            }
            return
        }

        let rows = try summaries.map { try summaryDynamicUpdateRow(for: $0) }
        let values = rows.map { row in
            """
            (
                \(bind: row.id),
                \(bind: row.lastMessageJSON),
                \(bind: row.lastReadSequence),
                \(bind: row.unreadCount),
                \(bind: row.lastActivityAt),
                \(bind: row.updatedAt),
                \(bind: row.isRemoved)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        try await sql.raw("""
            UPDATE \(ident: ConversationUserSummary.schema) AS \(ident: "summary")
            SET
                \(ident: "last_message_json") = \(ident: "updates").\(ident: "last_message_json"),
                \(ident: "last_read_sequence") = \(ident: "updates").\(ident: "last_read_sequence"),
                \(ident: "unread_count") = \(ident: "updates").\(ident: "unread_count"),
                \(ident: "last_activity_at") = \(ident: "updates").\(ident: "last_activity_at"),
                \(ident: "updated_at") = \(ident: "updates").\(ident: "updated_at"),
                \(ident: "is_removed") = \(ident: "updates").\(ident: "is_removed")
            FROM (
                VALUES \(values)
            ) AS \(ident: "updates")(
                \(ident: "id"),
                \(ident: "last_message_json"),
                \(ident: "last_read_sequence"),
                \(ident: "unread_count"),
                \(ident: "last_activity_at"),
                \(ident: "updated_at"),
                \(ident: "is_removed")
            )
            WHERE \(ident: "summary").\(ident: "id") = \(ident: "updates").\(ident: "id")
            """).run()
    }

    func upsertMessageCreatedSummaries(
        _ summaries: [(summary: ConversationUserSummary, exists: Bool)],
        on database: any Database
    ) async throws {
        guard !summaries.isEmpty else {
            return
        }

        guard let sql = database as? any SQLDatabase else {
            for item in summaries {
                if item.exists {
                    try await item.summary.update(on: database)
                } else {
                    try await item.summary.create(on: database)
                }
            }
            return
        }

        let rows = try summaries.map { try summaryUpsertRow(for: $0.summary) }
        let values = rows.map { row in
            """
            (
                \(bind: row.id),
                \(bind: row.ownerUserID),
                \(bind: row.conversationID),
                \(bind: row.title),
                \(bind: row.kind),
                \(bind: row.directMessagingState),
                \(bind: row.directPeerUserID),
                \(bind: row.directPeerEmail),
                \(bind: row.directPeerDisplayName),
                \(bind: row.directPeerAvatarPreset),
                \(bind: row.notice),
                \(bind: row.avatarPreset),
                \(bind: row.muteAll),
                \(bind: row.memberCount),
                \(bind: row.membershipRevision),
                \(bind: row.memberUserIDsJSON),
                \(bind: row.lastMessageJSON),
                \(bind: row.lastReadSequence),
                \(bind: row.unreadCount),
                \(bind: row.isPinned),
                \(bind: row.pinnedAt),
                \(bind: row.isMuted),
                \(bind: row.lastActivityAt),
                \(bind: row.updatedAt),
                \(bind: row.isRemoved)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        try await sql.raw("""
            INSERT INTO \(ident: ConversationUserSummary.schema) (
                \(ident: "id"),
                \(ident: "owner_user_id"),
                \(ident: "conversation_id"),
                \(ident: "title"),
                \(ident: "kind"),
                \(ident: "direct_messaging_state"),
                \(ident: "direct_peer_user_id"),
                \(ident: "direct_peer_email"),
                \(ident: "direct_peer_display_name"),
                \(ident: "direct_peer_avatar_preset"),
                \(ident: "notice"),
                \(ident: "avatar_preset"),
                \(ident: "mute_all"),
                \(ident: "member_count"),
                \(ident: "membership_revision"),
                \(ident: "member_user_ids_json"),
                \(ident: "last_message_json"),
                \(ident: "last_read_sequence"),
                \(ident: "unread_count"),
                \(ident: "is_pinned"),
                \(ident: "pinned_at"),
                \(ident: "is_muted"),
                \(ident: "last_activity_at"),
                \(ident: "updated_at"),
                \(ident: "is_removed")
            )
            VALUES \(values)
            ON CONFLICT (\(ident: "id")) DO UPDATE SET
                \(ident: "owner_user_id") = \(ident: "excluded").\(ident: "owner_user_id"),
                \(ident: "conversation_id") = \(ident: "excluded").\(ident: "conversation_id"),
                \(ident: "title") = \(ident: "excluded").\(ident: "title"),
                \(ident: "kind") = \(ident: "excluded").\(ident: "kind"),
                \(ident: "direct_messaging_state") = \(ident: "excluded").\(ident: "direct_messaging_state"),
                \(ident: "direct_peer_user_id") = \(ident: "excluded").\(ident: "direct_peer_user_id"),
                \(ident: "direct_peer_email") = \(ident: "excluded").\(ident: "direct_peer_email"),
                \(ident: "direct_peer_display_name") = \(ident: "excluded").\(ident: "direct_peer_display_name"),
                \(ident: "direct_peer_avatar_preset") = \(ident: "excluded").\(ident: "direct_peer_avatar_preset"),
                \(ident: "notice") = \(ident: "excluded").\(ident: "notice"),
                \(ident: "avatar_preset") = \(ident: "excluded").\(ident: "avatar_preset"),
                \(ident: "mute_all") = \(ident: "excluded").\(ident: "mute_all"),
                \(ident: "member_count") = \(ident: "excluded").\(ident: "member_count"),
                \(ident: "membership_revision") = \(ident: "excluded").\(ident: "membership_revision"),
                \(ident: "member_user_ids_json") = \(ident: "excluded").\(ident: "member_user_ids_json"),
                \(ident: "last_message_json") = \(ident: "excluded").\(ident: "last_message_json"),
                \(ident: "last_read_sequence") = \(ident: "excluded").\(ident: "last_read_sequence"),
                \(ident: "unread_count") = \(ident: "excluded").\(ident: "unread_count"),
                \(ident: "last_activity_at") = \(ident: "excluded").\(ident: "last_activity_at"),
                \(ident: "updated_at") = \(ident: "excluded").\(ident: "updated_at"),
                \(ident: "is_removed") = \(ident: "excluded").\(ident: "is_removed")
            """).run()
    }

    func summaryUpsertRow(for summary: ConversationUserSummary) throws -> MessageCreatedSummaryUpsertRow {
        MessageCreatedSummaryUpsertRow(
            id: summary.id ?? ConversationUserSummary.recordID(
                ownerUserID: summary.ownerUserID,
                conversationID: summary.conversationID
            ),
            ownerUserID: summary.ownerUserID,
            conversationID: summary.conversationID,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeerUserID: summary.directPeerUserID,
            directPeerEmail: summary.directPeerEmail,
            directPeerDisplayName: summary.directPeerDisplayName,
            directPeerAvatarPreset: summary.directPeerAvatarPreset,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            muteAll: summary.muteAll,
            memberCount: summary.memberCount,
            membershipRevision: summary.membershipRevision,
            memberUserIDsJSON: try ConversationUserSummary.encodeMemberUserIDsForStorage(summary.memberUserIDs),
            lastMessageJSON: try ConversationUserSummary.encodeLastMessageForStorage(summary.lastMessage),
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            lastActivityAt: summary.lastActivityAt,
            updatedAt: summary.updatedAt,
            isRemoved: summary.isRemoved
        )
    }

    func summaryDynamicUpdateRow(for summary: ConversationUserSummary) throws -> MessageCreatedSummaryDynamicUpdateRow {
        MessageCreatedSummaryDynamicUpdateRow(
            id: summary.id ?? ConversationUserSummary.recordID(
                ownerUserID: summary.ownerUserID,
                conversationID: summary.conversationID
            ),
            lastMessageJSON: try ConversationUserSummary.encodeLastMessageForStorage(summary.lastMessage),
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            lastActivityAt: summary.lastActivityAt,
            updatedAt: summary.updatedAt,
            isRemoved: summary.isRemoved
        )
    }
}

struct MessageCreatedSummaryUpsertRow {
    let id: String
    let ownerUserID: UUID
    let conversationID: UUID
    let title: String?
    let kind: String
    let directMessagingState: String?
    let directPeerUserID: UUID?
    let directPeerEmail: String?
    let directPeerDisplayName: String?
    let directPeerAvatarPreset: String?
    let notice: String?
    let avatarPreset: String?
    let muteAll: Bool
    let memberCount: Int
    let membershipRevision: Date?
    let memberUserIDsJSON: String
    let lastMessageJSON: String?
    let lastReadSequence: Int
    let unreadCount: Int
    let isPinned: Bool
    let pinnedAt: Date?
    let isMuted: Bool
    let lastActivityAt: Date
    let updatedAt: Date
    let isRemoved: Bool
}

struct MessageCreatedSummaryDynamicUpdateRow {
    let id: String
    let lastMessageJSON: String?
    let lastReadSequence: Int
    let unreadCount: Int
    let lastActivityAt: Date
    let updatedAt: Date
    let isRemoved: Bool
}
