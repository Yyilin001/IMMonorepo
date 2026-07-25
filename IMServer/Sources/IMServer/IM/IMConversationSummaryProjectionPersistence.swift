import Fluent
import Foundation
import SQLKit
import Vapor

extension IMConversationSummaryProjectionService {
    func upsertConversationActivity(
        conversationID: UUID,
        messageServerSequence: Int,
        messagePreview: IMMessagePreviewResponse,
        messageCreatedAt: Date?,
        updatedAt: Date,
        on database: any Database
    ) async throws {
        let lastMessageJSON = try ConversationActivitySummary.encodeLastMessageForStorage(messagePreview)
        let lastActivityAt = messageCreatedAt ?? updatedAt
        guard let sql = database as? any SQLDatabase else {
            let existing = try await ConversationActivitySummary.find(conversationID, on: database)
            if let existing {
                guard messageServerSequence >= existing.lastMessageServerSequence else {
                    return
                }
                existing.lastMessage = messagePreview
                existing.lastMessageServerSequence = messageServerSequence
                existing.lastActivityAt = lastActivityAt
                existing.updatedAt = updatedAt
                try await existing.update(on: database)
            } else {
                try await ConversationActivitySummary(
                    conversationID: conversationID,
                    lastMessage: messagePreview,
                    lastMessageServerSequence: messageServerSequence,
                    lastActivityAt: lastActivityAt,
                    updatedAt: updatedAt
                ).create(on: database)
            }
            return
        }

        try await sql.raw("""
            INSERT INTO \(ident: ConversationActivitySummary.schema) (
                \(ident: "conversation_id"),
                \(ident: "last_message_json"),
                \(ident: "last_message_server_sequence"),
                \(ident: "last_activity_at"),
                \(ident: "updated_at")
            )
            VALUES (
                \(bind: conversationID),
                \(bind: lastMessageJSON),
                \(bind: messageServerSequence),
                \(bind: lastActivityAt),
                \(bind: updatedAt)
            )
            ON CONFLICT (\(ident: "conversation_id")) DO UPDATE SET
                \(ident: "last_message_json") = CASE
                    WHEN \(ident: "excluded").\(ident: "last_message_server_sequence")
                       >= \(ident: ConversationActivitySummary.schema).\(ident: "last_message_server_sequence")
                    THEN \(ident: "excluded").\(ident: "last_message_json")
                    ELSE \(ident: ConversationActivitySummary.schema).\(ident: "last_message_json")
                END,
                \(ident: "last_message_server_sequence") = CASE
                    WHEN \(ident: "excluded").\(ident: "last_message_server_sequence")
                       >= \(ident: ConversationActivitySummary.schema).\(ident: "last_message_server_sequence")
                    THEN \(ident: "excluded").\(ident: "last_message_server_sequence")
                    ELSE \(ident: ConversationActivitySummary.schema).\(ident: "last_message_server_sequence")
                END,
                \(ident: "last_activity_at") = CASE
                    WHEN \(ident: "excluded").\(ident: "last_message_server_sequence")
                       >= \(ident: ConversationActivitySummary.schema).\(ident: "last_message_server_sequence")
                    THEN \(ident: "excluded").\(ident: "last_activity_at")
                    ELSE \(ident: ConversationActivitySummary.schema).\(ident: "last_activity_at")
                END,
                \(ident: "updated_at") = CASE
                    WHEN \(ident: "excluded").\(ident: "last_message_server_sequence")
                       >= \(ident: ConversationActivitySummary.schema).\(ident: "last_message_server_sequence")
                    THEN \(ident: "excluded").\(ident: "updated_at")
                    ELSE \(ident: ConversationActivitySummary.schema).\(ident: "updated_at")
                END
            """).run()
    }

    func applyMessageCreatedExistingSummariesSQL(
        conversationID: UUID,
        messageServerSequence: Int,
        messagePreview: IMMessagePreviewResponse,
        messageCreatedAt: Date?,
        updatedAt: Date,
        recipientUserIDs: [UUID],
        on database: any Database
    ) async throws -> MessageCreatedSummarySQLProjectionResult? {
        guard !recipientUserIDs.isEmpty,
              let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return nil
        }

        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        let summaryLookup = try await existingMessageCreatedSummaryOwnersSQL(
            conversationID: conversationID,
            recipientUserIDs: uniqueUserIDs,
            sql: sql
        )
        let existingUserIDs = summaryLookup.existingUserIDs
        let missingUserIDs = summaryLookup.missingUserIDs
        guard !existingUserIDs.isEmpty else {
            return MessageCreatedSummarySQLProjectionResult(
                missingUserIDs: missingUserIDs,
                changeLogRows: []
            )
        }

        let lastMessageJSON = try ConversationUserSummary.encodeLastMessageForStorage(messagePreview)
        let lastActivityAt = messageCreatedAt ?? updatedAt
        let values = existingUserIDs.map { ownerUserID in
            """
            (
                \(bind: ownerUserID),
                \(bind: ConversationUserSummary.recordID(ownerUserID: ownerUserID, conversationID: conversationID))
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        let rows = try await sql.raw("""
            WITH \(ident: "input")(
                \(ident: "owner_user_id"),
                \(ident: "summary_record_id")
            ) AS (
                VALUES \(values)
            ),
            \(ident: "updated_summaries") AS (
                UPDATE \(ident: ConversationUserSummary.schema) AS \(ident: "summary")
                SET
                    \(ident: "last_message_json") = CASE
                        WHEN \(bind: messageServerSequence) >= COALESCE(
                            (\(ident: "summary").\(ident: "last_message_json")::jsonb ->> 'serverSequence')::integer,
                            0
                        )
                        THEN \(bind: lastMessageJSON)
                        ELSE \(ident: "summary").\(ident: "last_message_json")
                    END,
                    \(ident: "last_read_sequence") = GREATEST(
                        \(ident: "member").\(ident: "last_read_sequence"),
                        GREATEST(0, \(ident: "member").\(ident: "visible_from_sequence") - 1)
                    ),
                    \(ident: "unread_count") = GREATEST(
                        GREATEST(
                            \(bind: messageServerSequence),
                            COALESCE(
                                (\(ident: "summary").\(ident: "last_message_json")::jsonb ->> 'serverSequence')::integer,
                                0
                            ),
                            GREATEST(0, \(ident: "member").\(ident: "visible_from_sequence") - 1)
                        ) - GREATEST(
                            \(ident: "member").\(ident: "last_read_sequence"),
                            GREATEST(0, \(ident: "member").\(ident: "visible_from_sequence") - 1)
                        ),
                        0
                    ),
                    \(ident: "last_activity_at") = CASE
                        WHEN \(bind: messageServerSequence) >= COALESCE(
                            (\(ident: "summary").\(ident: "last_message_json")::jsonb ->> 'serverSequence')::integer,
                            0
                        )
                        THEN \(bind: lastActivityAt)
                        ELSE \(ident: "summary").\(ident: "last_activity_at")
                    END,
                    \(ident: "updated_at") = \(bind: updatedAt),
                    \(ident: "is_removed") = FALSE
                FROM \(ident: "input")
                JOIN \(ident: ConversationMember.schema) AS \(ident: "member")
                    ON \(ident: "member").\(ident: "conversation_id") = \(bind: conversationID)
                   AND \(ident: "member").\(ident: "user_id") = \(ident: "input").\(ident: "owner_user_id")
                WHERE \(ident: "summary").\(ident: "id") = \(ident: "input").\(ident: "summary_record_id")
                  AND \(ident: "summary").\(ident: "conversation_id") = \(bind: conversationID)
                  AND \(bind: messageServerSequence) >= \(ident: "member").\(ident: "visible_from_sequence")
                RETURNING
                    \(ident: "summary").\(ident: "owner_user_id") AS \(ident: "owner_user_id"),
                    \(ident: "summary").\(ident: "conversation_id") AS \(ident: "conversation_id"),
                    \(ident: "summary").\(ident: "id") AS \(ident: "summary_record_id"),
                    \(ident: "summary").\(ident: "updated_at") AS \(ident: "updated_at"),
                    \(ident: "summary").\(ident: "is_removed") AS \(ident: "is_removed")
            )
            SELECT
                \(ident: "owner_user_id"),
                \(ident: "conversation_id"),
                \(ident: "summary_record_id"),
                \(ident: "updated_at"),
                \(ident: "is_removed")
            FROM \(ident: "updated_summaries")
            """).all(decoding: MessageCreatedSummarySQLUpdateRow.self)

        return MessageCreatedSummarySQLProjectionResult(
            missingUserIDs: missingUserIDs,
            changeLogRows: rows.map(\.changeLogRow)
        )
    }

    func existingMessageCreatedSummaryOwnersSQL(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        sql: any SQLDatabase
    ) async throws -> (existingUserIDs: [UUID], missingUserIDs: [UUID]) {
        guard !recipientUserIDs.isEmpty else {
            return ([], [])
        }

        let values = recipientUserIDs.map { ownerUserID in
            """
            (
                \(bind: ownerUserID),
                \(bind: ConversationUserSummary.recordID(ownerUserID: ownerUserID, conversationID: conversationID))
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        let rows = try await sql.raw("""
            WITH \(ident: "input")(
                \(ident: "owner_user_id"),
                \(ident: "summary_record_id")
            ) AS (
                VALUES \(values)
            )
            SELECT
                \(ident: "input").\(ident: "owner_user_id") AS \(ident: "owner_user_id"),
                CASE
                    WHEN \(ident: "summary").\(ident: "id") IS NULL THEN FALSE
                    ELSE TRUE
                END AS \(ident: "exists")
            FROM \(ident: "input")
            LEFT JOIN \(ident: ConversationUserSummary.schema) AS \(ident: "summary")
                ON \(ident: "summary").\(ident: "id") = \(ident: "input").\(ident: "summary_record_id")
            """).all(decoding: MessageCreatedSummaryExistenceRow.self)

        let existingUserIDs = rows
            .filter(\.exists)
            .map(\.ownerUserID)
        let missingUserIDs = rows
            .filter { !$0.exists }
            .map(\.ownerUserID)
        return (existingUserIDs, missingUserIDs)
    }

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

        // Each row binds 26 values. Keep Postgres extended-protocol statements
        // comfortably below its 65,535 parameter limit for large groups.
        let maxRowsPerStatement = 500
        if summaries.count > maxRowsPerStatement {
            for start in stride(from: 0, to: summaries.count, by: maxRowsPerStatement) {
                let end = min(start + maxRowsPerStatement, summaries.count)
                try await upsertMessageCreatedSummaries(
                    Array(summaries[start..<end]),
                    on: database
                )
            }
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
                \(bind: row.groupLifecycleState),
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
                \(ident: "group_lifecycle_state"),
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
                \(ident: "group_lifecycle_state") = \(ident: "excluded").\(ident: "group_lifecycle_state"),
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
                \(ident: "is_pinned") = \(ident: "excluded").\(ident: "is_pinned"),
                \(ident: "pinned_at") = \(ident: "excluded").\(ident: "pinned_at"),
                \(ident: "is_muted") = \(ident: "excluded").\(ident: "is_muted"),
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
            groupLifecycleState: summary.groupLifecycleState,
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
    let groupLifecycleState: String
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

struct MessageCreatedSummarySQLProjectionResult {
    let missingUserIDs: [UUID]
    let changeLogRows: [ConversationChangeLogBatchWriter.Row]
}

struct MessageCreatedSummaryExistenceRow: Decodable {
    let ownerUserID: UUID
    let exists: Bool

    enum CodingKeys: String, CodingKey {
        case ownerUserID = "owner_user_id"
        case exists
    }
}

struct MessageCreatedSummarySQLUpdateRow: Decodable {
    let ownerUserID: UUID
    let conversationID: UUID
    let summaryRecordID: String
    let updatedAt: Date
    let isRemoved: Bool

    enum CodingKeys: String, CodingKey {
        case ownerUserID = "owner_user_id"
        case conversationID = "conversation_id"
        case summaryRecordID = "summary_record_id"
        case updatedAt = "updated_at"
        case isRemoved = "is_removed"
    }

    var changeLogRow: ConversationChangeLogBatchWriter.Row {
        ConversationChangeLogBatchWriter.Row(
            ownerUserID: ownerUserID,
            conversationID: conversationID,
            summaryRecordID: summaryRecordID,
            updatedAt: updatedAt,
            isRemoved: isRemoved
        )
    }
}
