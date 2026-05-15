import Fluent
import Foundation
import SQLKit
import Vapor

extension IMConversationSummaryProjectionService {
    func applyMessageCreated(
        conversationID: UUID,
        messageID: UUID,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws {
        let database = database ?? sourceDB
        let readModelDatabase = readModelDB
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        guard let message = try await ConversationMessage.find(messageID, on: database),
              message.$conversation.id == conversationID
        else {
            return
        }

        let messagePreview = try makePreview(from: message)
        let updatedAt = Date()
        let summaryRecordIDs = uniqueUserIDs.map {
            ConversationUserSummary.recordID(ownerUserID: $0, conversationID: conversationID)
        }
        let existingSummaries = try await ConversationUserSummary.query(on: readModelDatabase)
            .filter(\.$id ~~ summaryRecordIDs)
            .all()
        let existingSummariesByID = Dictionary(uniqueKeysWithValues: existingSummaries.compactMap { summary in
            summary.id.map { ($0, summary) }
        })
        let existingUserIDs = uniqueUserIDs.filter { recipientUserID in
            existingSummariesByID[
                ConversationUserSummary.recordID(ownerUserID: recipientUserID, conversationID: conversationID)
            ] != nil
        }
        let missingUserIDs = uniqueUserIDs.filter { recipientUserID in
            existingSummariesByID[
                ConversationUserSummary.recordID(ownerUserID: recipientUserID, conversationID: conversationID)
            ] == nil
        }

        if !missingUserIDs.isEmpty {
            try await refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: missingUserIDs,
                on: database,
                writeChangeLog: writeChangeLog,
                preferredMessage: message
            )
        }

        guard !existingUserIDs.isEmpty else {
            return
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id ~~ existingUserIDs)
            .all()
        guard !memberships.isEmpty else {
            return
        }

        let membershipsByUserID = Dictionary(uniqueKeysWithValues: memberships.map { ($0.$user.id, $0) })
        var summariesToUpdate: [ConversationUserSummary] = []
        summariesToUpdate.reserveCapacity(existingUserIDs.count)
        var changeLogRows: [ConversationChangeLogBatchWriter.Row] = []
        changeLogRows.reserveCapacity(existingUserIDs.count)

        for recipientUserID in existingUserIDs {
            guard let membership = membershipsByUserID[recipientUserID],
                  message.serverSequence >= membership.visibleFromSequence
            else {
                continue
            }

            let recordID = ConversationUserSummary.recordID(ownerUserID: recipientUserID, conversationID: conversationID)
            guard let summary = existingSummariesByID[recordID] else {
                continue
            }

            let currentLastSequence = summary.lastMessage?.serverSequence ?? 0
            if message.serverSequence >= currentLastSequence {
                summary.lastMessage = messagePreview
                summary.lastActivityAt = message.createdAt ?? updatedAt
            }

            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            let latestVisibleSequence = max(
                message.serverSequence,
                currentLastSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            summary.lastReadSequence = effectiveLastReadSequence
            summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
            summary.updatedAt = updatedAt
            summary.isRemoved = false
            summariesToUpdate.append(summary)
            if writeChangeLog {
                changeLogRows.append(
                    ConversationChangeLogBatchWriter.Row(
                    ownerUserID: recipientUserID,
                    conversationID: conversationID,
                    summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                        ownerUserID: recipientUserID,
                        conversationID: conversationID
                    ),
                    updatedAt: updatedAt,
                        isRemoved: false
                    )
                )
            }
        }

        try await updateMessageCreatedDynamicSummaries(summariesToUpdate, on: readModelDatabase)
        try await ConversationChangeLogBatchWriter(database: readModelDatabase).upsert(changeLogRows)
    }

    func refreshConversationSummaries(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true,
        preferredMessage: ConversationMessage? = nil
    ) async throws {
        let database = database ?? sourceDB
        let readModelDatabase = readModelDB
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            return
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .with(\.$user)
            .all()
        guard !memberships.isEmpty else {
            return
        }

        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        let membershipsByUserID = Dictionary(uniqueKeysWithValues: memberships.map { ($0.$user.id, $0) })
        let latestMessageByVisibleFrom = try await latestVisibleMessagesByThreshold(
            conversationID: conversationID,
            memberships: memberships,
            preferredMessage: preferredMessage,
            on: database
        )
        let summaryRecordIDs = uniqueUserIDs.map {
            ConversationUserSummary.recordID(ownerUserID: $0, conversationID: conversationID)
        }
        let existingSummaries = try await ConversationUserSummary.query(on: readModelDatabase)
            .filter(\.$id ~~ summaryRecordIDs)
            .all()
        let existingSummariesByID = Dictionary(uniqueKeysWithValues: existingSummaries.compactMap { summary in
            summary.id.map { ($0, summary) }
        })
        let updatedAt = Date()
        var changeLogRows: [ConversationChangeLogBatchWriter.Row] = []
        changeLogRows.reserveCapacity(uniqueUserIDs.count)
        var summariesToUpsert: [(summary: ConversationUserSummary, exists: Bool)] = []
        summariesToUpsert.reserveCapacity(uniqueUserIDs.count)

        for recipientUserID in uniqueUserIDs {
            guard let membership = membershipsByUserID[recipientUserID] else {
                continue
            }

            let directPeer = directPeer(from: memberships, currentUserID: recipientUserID)
            let lastVisibleMessage = latestMessageByVisibleFrom[membership.visibleFromSequence] ?? nil
            let preview = try lastVisibleMessage.map(makePreview)
            let latestVisibleSequence = max(
                lastVisibleMessage?.serverSequence ?? 0,
                max(0, membership.visibleFromSequence - 1)
            )
            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            let recordID = ConversationUserSummary.recordID(
                ownerUserID: recipientUserID,
                conversationID: conversationID
            )
            let existing = existingSummariesByID[recordID]
            let summary = try existing ?? ConversationUserSummary(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                title: conversation.title,
                kind: conversation.kind,
                directMessagingState: conversation.conversationKind == .direct ? conversation.directMessagingState : nil,
                directPeerUserID: directPeer?.id,
                directPeerEmail: directPeer?.email,
                directPeerDisplayName: directPeer?.displayName,
                directPeerAvatarPreset: directPeer?.avatarPreset,
                notice: conversation.notice,
                avatarPreset: conversation.avatarPresetEnum,
                muteAll: conversation.muteAll,
                memberUserIDs: memberUserIDs,
                lastMessage: preview,
                lastReadSequence: effectiveLastReadSequence,
                unreadCount: max(0, latestVisibleSequence - effectiveLastReadSequence),
                lastActivityAt: preview?.createdAt ?? conversation.updatedAt,
                updatedAt: updatedAt,
                isRemoved: false,
                membershipRevision: conversation.membershipRevision
            )
            summary.ownerUserID = recipientUserID
            summary.conversationID = conversationID
            summary.title = conversation.title
            summary.kind = conversation.kind
            summary.directMessagingState = conversation.conversationKind == .direct ? conversation.directMessagingState : nil
            summary.directPeerUserID = directPeer?.id
            summary.directPeerEmail = directPeer?.email
            summary.directPeerDisplayName = directPeer?.displayName
            summary.directPeerAvatarPresetEnum = directPeer?.avatarPreset
            summary.notice = conversation.notice
            summary.avatarPresetEnum = conversation.avatarPresetEnum
            summary.muteAll = conversation.muteAll
            summary.memberUserIDs = memberUserIDs
            summary.membershipRevision = conversation.membershipRevision
            summary.lastMessage = preview
            summary.lastReadSequence = effectiveLastReadSequence
            summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
            summary.lastActivityAt = preview?.createdAt ?? conversation.updatedAt
            summary.updatedAt = updatedAt
            summary.isRemoved = false
            summariesToUpsert.append((summary: summary, exists: existing != nil))
            if writeChangeLog {
                changeLogRows.append(
                    ConversationChangeLogBatchWriter.Row(
                        ownerUserID: recipientUserID,
                        conversationID: conversationID,
                        summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                            ownerUserID: recipientUserID,
                            conversationID: conversationID
                        ),
                        updatedAt: updatedAt,
                        isRemoved: false
                    )
                )
            }
        }
        try await upsertMessageCreatedSummaries(summariesToUpsert, on: readModelDatabase)
        try await ConversationChangeLogBatchWriter(database: readModelDatabase).upsert(changeLogRows)
    }

    @discardableResult
    func applyReadAdvanced(
        conversationID: UUID,
        recipientUserID: UUID,
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws -> Bool {
        let database = database ?? sourceDB
        let readModelDatabase = readModelDB
        let recordID = ConversationUserSummary.recordID(
            ownerUserID: recipientUserID,
            conversationID: conversationID
        )
        guard let summary = try await ConversationUserSummary.find(recordID, on: readModelDatabase) else {
            try await refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [recipientUserID],
                on: database,
                writeChangeLog: writeChangeLog
            )
            return false
        }
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == recipientUserID)
            .first()
        else {
            try await markConversationRemoved(
                conversationID: conversationID,
                recipientUserID: recipientUserID,
                on: database,
                writeChangeLog: writeChangeLog
            )
            return false
        }

        let latestVisibleSequence = max(
            summary.lastMessage?.serverSequence ?? 0,
            max(0, membership.visibleFromSequence - 1)
        )
        let effectiveLastReadSequence = max(
            membership.lastReadSequence,
            max(0, membership.visibleFromSequence - 1)
        )
        let updatedAt = Date()
        summary.lastReadSequence = effectiveLastReadSequence
        summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
        summary.updatedAt = updatedAt
        summary.isRemoved = false
        try await save(summary, on: readModelDatabase)
        if writeChangeLog {
            try await upsertChangeLog(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                summaryRecordID: recordID,
                updatedAt: updatedAt,
                isRemoved: false,
                on: readModelDatabase
            )
        }
        return true
    }

    func markConversationRemoved(
        conversationID: UUID,
        recipientUserID: UUID,
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws {
        _ = database ?? sourceDB
        let readModelDatabase = readModelDB
        let summary = try await findOrCreateSummary(
            ownerUserID: recipientUserID,
            conversationID: conversationID,
            on: readModelDatabase
        )
        summary.ownerUserID = recipientUserID
        summary.conversationID = conversationID
        summary.isRemoved = true
        summary.updatedAt = Date()
        try await save(summary, on: readModelDatabase)
        if writeChangeLog {
            try await upsertChangeLog(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                    ownerUserID: recipientUserID,
                    conversationID: conversationID
                ),
                updatedAt: summary.updatedAt,
                isRemoved: true,
                on: readModelDatabase
            )
        }
    }

    func refreshDirectPeerProfiles(for userID: UUID) async throws -> [UUID: [UUID]] {
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$directPeerUserID == userID)
            .all()
        guard !summaries.isEmpty else {
            return [:]
        }

        guard let user = try await User.find(userID, on: sourceDB) else {
            return [:]
        }

        var recipientUserIDsByConversationID: [UUID: [UUID]] = [:]
        for summary in summaries {
            summary.directPeerEmail = user.email
            summary.directPeerDisplayName = user.displayName
            summary.directPeerAvatarPresetEnum = user.avatarPresetEnum
            summary.updatedAt = Date()
            try await save(summary, on: readModelDB)
            try await upsertChangeLog(
                ownerUserID: summary.ownerUserID,
                conversationID: summary.conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                    ownerUserID: summary.ownerUserID,
                    conversationID: summary.conversationID
                ),
                updatedAt: summary.updatedAt,
                isRemoved: summary.isRemoved,
                on: readModelDB
            )
            recipientUserIDsByConversationID[summary.conversationID, default: []].append(summary.ownerUserID)
        }

        return recipientUserIDsByConversationID.mapValues { ownerUserIDs in
            Array(Set(ownerUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }
}

private extension IMConversationSummaryProjectionService {
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

private struct MessageCreatedSummaryUpsertRow {
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

private struct MessageCreatedSummaryDynamicUpdateRow {
    let id: String
    let lastMessageJSON: String?
    let lastReadSequence: Int
    let unreadCount: Int
    let lastActivityAt: Date
    let updatedAt: Date
    let isRemoved: Bool
}
