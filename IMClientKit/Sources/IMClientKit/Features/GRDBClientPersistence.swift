import Foundation
import GRDB

public final class GRDBIMConversationCache: IMConversationCaching, @unchecked Sendable {
    private let databasePool: DatabasePool

    public init(databaseURL: URL) throws {
        self.databasePool = try GRDBClientDatabase.openPool(databaseURL: databaseURL)
    }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> IMConversationCacheSnapshot {
        let owner = ownerUserID.uuidString
        return try await databasePool.read { db in
            let metadata = try Row.fetchOne(
                db,
                sql: """
                SELECT selected_conversation_id, last_summary_refresh_at, summary_sync_token,
                       summary_next_cursor, has_more_conversation_summaries
                FROM cache_metadata
                WHERE owner_user_id = ?
                """,
                arguments: [owner]
            )
            let conversationRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM cached_conversations
                WHERE owner_user_id = ?
                """,
                arguments: [owner]
            )
            let messageRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM cached_messages
                WHERE owner_user_id = ?
                ORDER BY conversation_id, server_sequence IS NULL, server_sequence, created_at, message_id
                """,
                arguments: [owner]
            )
            let cursorRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM cached_message_cursors
                WHERE owner_user_id = ?
                """,
                arguments: [owner]
            )
            let transferRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM cached_transfer_snapshots
                WHERE owner_user_id = ?
                ORDER BY task_session_identifier, task_identifier
                """,
                arguments: [owner]
            )
            let domainEventStateRow = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM cached_domain_event_state
                WHERE owner_user_id = ?
                """,
                arguments: [owner]
            )

            var diagnostics = IMCacheRestoreDiagnostics()
            let decodedMessages = messageRows.compactMap { row -> IMCachedMessageState? in
                switch GRDBClientPersistence.decodeMessage(row: row) {
                case .success(let message):
                    return message
                case .failure(let conversationID, let messageID, let reason):
                    diagnostics.recordDroppedCanonicalMessage(
                        conversationID: conversationID,
                        messageID: messageID,
                        reason: reason
                    )
                    return nil
                }
            }
            let messagesByConversationID = Dictionary(grouping: decodedMessages, by: \.conversationID)
            let cursors = cursorRows.map(GRDBClientPersistence.decodeCursor(row:))
            let cursorsByConversationID = Dictionary(uniqueKeysWithValues: cursors.map { ($0.conversationID, $0) })
            let conversations = conversationRows.map { row in
                let conversationID: String = row["conversation_id"]
                let cachedMessages = messagesByConversationID[conversationID] ?? []
                let cursor = cursorsByConversationID[conversationID]
                return GRDBClientPersistence.decodeConversation(
                    row: row,
                    messages: cachedMessages,
                    cursor: cursor,
                    diagnostics: &diagnostics
                )
            }
            .sorted(by: GRDBClientPersistence.conversationComparator)

            return IMConversationCacheSnapshot(
                metadata: IMCacheMetadataState(
                    selectedConversationID: metadata?["selected_conversation_id"],
                    lastSummaryRefreshAt: GRDBClientPersistence.date(from: metadata?["last_summary_refresh_at"]),
                    summarySyncToken: metadata?["summary_sync_token"],
                    summaryNextCursor: metadata?["summary_next_cursor"],
                    hasMoreConversationSummaries: GRDBClientPersistence.bool(
                        from: metadata?["has_more_conversation_summaries"]
                    )
                ),
                conversations: conversations,
                cursors: cursors,
                transferSnapshots: transferRows.compactMap(GRDBClientPersistence.decodeTransferSnapshot(row:)),
                domainEventState: GRDBClientPersistence.decodeDomainEventState(row: domainEventStateRow),
                diagnostics: diagnostics
            )
        }
    }

    public func saveSnapshot(_ snapshot: IMConversationCacheSnapshot, for ownerUserID: UUID) async throws {
        let owner = ownerUserID.uuidString
        try await databasePool.write { db in
            try GRDBClientPersistence.deleteIMSnapshot(ownerUserID: owner, db: db)
            try GRDBClientPersistence.insertIMMetadata(snapshot.metadata, ownerUserID: owner, db: db)
            let cursorsByConversationID = Dictionary(
                uniqueKeysWithValues: snapshot.cursors.map { ($0.conversationID, $0) }
            )

            for conversation in snapshot.conversations {
                try GRDBClientPersistence.insertConversation(conversation, ownerUserID: owner, db: db)
                let cursor = cursorsByConversationID[conversation.id]
                try GRDBClientPersistence.insertCursor(
                    cursor,
                    fallback: conversation,
                    ownerUserID: owner,
                    db: db
                )
                for message in conversation.messages {
                    try GRDBClientPersistence.insertMessage(message, ownerUserID: owner, db: db)
                }
            }

            for transferSnapshot in snapshot.transferSnapshots {
                try GRDBClientPersistence.insertTransferSnapshot(
                    transferSnapshot,
                    ownerUserID: owner,
                    db: db
                )
            }
            try GRDBClientPersistence.insertDomainEventState(
                snapshot.domainEventState,
                ownerUserID: owner,
                db: db
            )
        }
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        let owner = ownerUserID.uuidString
        try await databasePool.write { db in
            try GRDBClientPersistence.deleteIMSnapshot(ownerUserID: owner, db: db)
        }
    }

    public func clearAll() async throws {
        try await databasePool.write { db in
            try db.execute(sql: "DELETE FROM cached_transfer_snapshots")
            try db.execute(sql: "DELETE FROM cached_domain_event_state")
            try db.execute(sql: "DELETE FROM cached_messages")
            try db.execute(sql: "DELETE FROM cached_message_cursors")
            try db.execute(sql: "DELETE FROM cached_conversations")
            try db.execute(sql: "DELETE FROM cache_metadata")
        }
    }
}

public final class GRDBContactStateCache: ContactStateCaching, @unchecked Sendable {
    private let databasePool: DatabasePool

    public init(databaseURL: URL) throws {
        self.databasePool = try GRDBClientDatabase.openPool(databaseURL: databaseURL)
    }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        let owner = ownerUserID.uuidString
        return try await databasePool.read { db in
            let metadata = try Row.fetchOne(
                db,
                sql: """
                SELECT last_refresh_at, last_seen_incoming_contact_request_at
                FROM contact_cache_metadata
                WHERE owner_user_id = ?
                """,
                arguments: [owner]
            )
            let contactRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM cached_contacts
                WHERE owner_user_id = ?
                ORDER BY email, contact_user_id
                """,
                arguments: [owner]
            )
            let requestRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM cached_contact_requests
                WHERE owner_user_id = ?
                """,
                arguments: [owner]
            )
            let requests = requestRows.compactMap(GRDBClientPersistence.decodeContactRequest(row:))
            let incoming = requests
                .filter { $0.bucket == .incoming }
                .map(\.request)
                .sorted(by: GRDBClientPersistence.pendingContactRequestComparator)
            let outgoing = requests
                .filter { $0.bucket == .outgoing }
                .map(\.request)
                .sorted(by: GRDBClientPersistence.pendingContactRequestComparator)
            let resolved = requests
                .filter { $0.bucket == .resolved }
                .map(\.request)
                .sorted(by: GRDBClientPersistence.resolvedContactRequestComparator)

            return ContactStateCacheSnapshot(
                contacts: contactRows.compactMap(GRDBClientPersistence.decodeContact(row:)),
                incomingRequests: incoming,
                outgoingRequests: outgoing,
                resolvedRequests: resolved,
                lastRefreshAt: GRDBClientPersistence.date(from: metadata?["last_refresh_at"]),
                lastSeenIncomingContactRequestAt: GRDBClientPersistence.date(
                    from: metadata?["last_seen_incoming_contact_request_at"]
                )
            )
        }
    }

    public func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws {
        let owner = ownerUserID.uuidString
        try await databasePool.write { db in
            try GRDBClientPersistence.deleteContactSnapshot(ownerUserID: owner, db: db)
            try GRDBClientPersistence.insertContactMetadata(snapshot, ownerUserID: owner, db: db)
            for contact in snapshot.contacts {
                try GRDBClientPersistence.insertContact(contact, ownerUserID: owner, db: db)
            }
            for request in snapshot.incomingRequests {
                try GRDBClientPersistence.insertContactRequest(request, bucket: .incoming, ownerUserID: owner, db: db)
            }
            for request in snapshot.outgoingRequests {
                try GRDBClientPersistence.insertContactRequest(request, bucket: .outgoing, ownerUserID: owner, db: db)
            }
            for request in snapshot.resolvedRequests {
                try GRDBClientPersistence.insertContactRequest(request, bucket: .resolved, ownerUserID: owner, db: db)
            }
        }
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        let owner = ownerUserID.uuidString
        try await databasePool.write { db in
            try GRDBClientPersistence.deleteContactSnapshot(ownerUserID: owner, db: db)
        }
    }

    public func clearAll() async throws {
        try await databasePool.write { db in
            try db.execute(sql: "DELETE FROM cached_contact_requests")
            try db.execute(sql: "DELETE FROM cached_contacts")
            try db.execute(sql: "DELETE FROM contact_cache_metadata")
        }
    }
}

enum GRDBClientDatabase {
    static func openPool(databaseURL: URL) throws -> DatabasePool {
        let fileManager = FileManager.default
        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try pool.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try migrator.migrate(pool)
        return pool
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createClientCacheV1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS cache_metadata (
                owner_user_id TEXT PRIMARY KEY NOT NULL,
                selected_conversation_id TEXT,
                last_summary_refresh_at REAL,
                summary_sync_token TEXT,
                summary_next_cursor TEXT,
                has_more_conversation_summaries INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS cached_conversations (
                owner_user_id TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                title TEXT NOT NULL,
                kind_raw_value TEXT NOT NULL,
                direct_messaging_state_raw_value TEXT,
                direct_peer_user_id TEXT,
                direct_peer_email TEXT,
                direct_peer_display_name TEXT,
                direct_peer_avatar_preset_raw_value TEXT,
                notice TEXT,
                avatar_preset_raw_value TEXT,
                member_count INTEGER NOT NULL,
                member_user_ids_blob TEXT NOT NULL,
                last_message_preview_text TEXT NOT NULL,
                updated_at REAL NOT NULL,
                server_last_read_sequence INTEGER NOT NULL,
                server_unread_count INTEGER NOT NULL,
                is_pinned INTEGER NOT NULL,
                pinned_at REAL,
                is_muted INTEGER NOT NULL,
                draft_text TEXT NOT NULL,
                draft_updated_at REAL,
                PRIMARY KEY (owner_user_id, conversation_id)
            );

            CREATE TABLE IF NOT EXISTS cached_message_cursors (
                owner_user_id TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                has_loaded_messages INTEGER NOT NULL,
                latest_synced_server_sequence INTEGER,
                oldest_loaded_server_sequence INTEGER,
                PRIMARY KEY (owner_user_id, conversation_id)
            );

            CREATE TABLE IF NOT EXISTS cached_messages (
                owner_user_id TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                client_message_id TEXT,
                sender_user_id TEXT,
                server_sequence INTEGER,
                kind TEXT NOT NULL,
                text_preview TEXT NOT NULL,
                content_json TEXT,
                direction_raw_value TEXT NOT NULL,
                created_at REAL NOT NULL,
                delivery_state_raw_value TEXT NOT NULL,
                delivery_failure_message TEXT,
                transfer_task_session_identifier TEXT,
                transfer_task_identifier INTEGER,
                derived_state_json TEXT,
                local_transfer_state_json TEXT,
                local_download_state_json TEXT,
                PRIMARY KEY (owner_user_id, conversation_id, message_id)
            );

            CREATE TABLE IF NOT EXISTS cached_transfer_snapshots (
                owner_user_id TEXT NOT NULL,
                task_session_identifier TEXT NOT NULL,
                task_identifier INTEGER NOT NULL,
                snapshot_json TEXT NOT NULL,
                PRIMARY KEY (owner_user_id, task_session_identifier, task_identifier)
            );

            CREATE TABLE IF NOT EXISTS cached_domain_event_state (
                owner_user_id TEXT PRIMARY KEY NOT NULL,
                cursor INTEGER NOT NULL,
                applied_event_ids_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS contact_cache_metadata (
                owner_user_id TEXT PRIMARY KEY NOT NULL,
                last_refresh_at REAL,
                last_seen_incoming_contact_request_at REAL
            );

            CREATE TABLE IF NOT EXISTS cached_contacts (
                owner_user_id TEXT NOT NULL,
                contact_user_id TEXT NOT NULL,
                email TEXT NOT NULL,
                display_name TEXT,
                avatar_preset_raw_value TEXT,
                remark TEXT,
                created_at REAL,
                PRIMARY KEY (owner_user_id, contact_user_id)
            );

            CREATE TABLE IF NOT EXISTS cached_contact_requests (
                owner_user_id TEXT NOT NULL,
                request_id TEXT NOT NULL,
                bucket_raw_value TEXT NOT NULL,
                requester_user_id TEXT NOT NULL,
                requester_email TEXT NOT NULL,
                requester_display_name TEXT,
                requester_avatar_preset_raw_value TEXT,
                addressee_user_id TEXT NOT NULL,
                addressee_email TEXT NOT NULL,
                addressee_display_name TEXT,
                addressee_avatar_preset_raw_value TEXT,
                status_raw_value TEXT NOT NULL,
                message TEXT,
                requester_remark TEXT,
                addressee_remark TEXT,
                created_at REAL,
                updated_at REAL,
                responded_at REAL,
                PRIMARY KEY (owner_user_id, bucket_raw_value, request_id)
            );

            CREATE INDEX IF NOT EXISTS idx_cached_conversations_owner_updated
            ON cached_conversations(owner_user_id, is_pinned, pinned_at, updated_at, conversation_id);
            CREATE INDEX IF NOT EXISTS idx_cached_messages_owner_conversation_sequence
            ON cached_messages(owner_user_id, conversation_id, server_sequence, created_at, message_id);
            CREATE INDEX IF NOT EXISTS idx_cached_contacts_owner_email
            ON cached_contacts(owner_user_id, email, contact_user_id);
            CREATE INDEX IF NOT EXISTS idx_cached_contact_requests_owner_bucket_time
            ON cached_contact_requests(owner_user_id, bucket_raw_value, created_at, responded_at, updated_at);
            """)
        }
        migrator.registerMigration("createClientDomainEventStateV1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS cached_domain_event_state (
                owner_user_id TEXT PRIMARY KEY NOT NULL,
                cursor INTEGER NOT NULL,
                applied_event_ids_json TEXT NOT NULL
            )
            """)
        }
        migrator.registerMigration("addCachedDeferredDomainEventsV1") { db in
            try db.execute(sql: """
            ALTER TABLE cached_domain_event_state
            ADD COLUMN deferred_event_pb_base64_json TEXT NOT NULL DEFAULT '[]'
            """)
        }
        migrator.registerMigration("addCachedOwnerAggregateHighWatermarksV1") { db in
            try db.execute(sql: """
            ALTER TABLE cached_domain_event_state
            ADD COLUMN owner_aggregate_high_watermarks_json TEXT NOT NULL DEFAULT '[]'
            """)
        }
        migrator.registerMigration("addCachedMessageTimelineSequenceV1") { db in
            try db.execute(sql: """
            ALTER TABLE cached_messages
            ADD COLUMN timeline_sequence INTEGER
            """)
        }
        migrator.registerMigration("addCachedTimelineNoticesV1") { db in
            try db.execute(sql: """
            ALTER TABLE cached_conversations
            ADD COLUMN notices_json TEXT NOT NULL DEFAULT '[]'
            """)
        }
        migrator.registerMigration("addCachedPendingMessagesV1") { db in
            try db.execute(sql: """
            ALTER TABLE cached_conversations
            ADD COLUMN pending_messages_json TEXT NOT NULL DEFAULT '[]'
            """)
        }
        migrator.registerMigration("addCachedDomainEventFullRefreshV1") { db in
            try db.execute(sql: """
            ALTER TABLE cached_domain_event_state
            ADD COLUMN full_refresh_conversation_ids_json TEXT NOT NULL DEFAULT '[]'
            """)
        }
        return migrator
    }
}

private enum ContactRequestCacheBucket: String {
    case incoming
    case outgoing
    case resolved
}

private enum GRDBClientPersistence {
    enum PersistenceError: Error {
        case invalidSequenceOverflow
    }

    enum CachedMessageDecodeResult {
        case success(IMCachedMessageState)
        case failure(conversationID: String, messageID: String, reason: String)
    }

    static func deleteIMSnapshot(ownerUserID: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM cached_transfer_snapshots WHERE owner_user_id = ?", arguments: [ownerUserID])
        try db.execute(sql: "DELETE FROM cached_domain_event_state WHERE owner_user_id = ?", arguments: [ownerUserID])
        try db.execute(sql: "DELETE FROM cached_messages WHERE owner_user_id = ?", arguments: [ownerUserID])
        try db.execute(sql: "DELETE FROM cached_message_cursors WHERE owner_user_id = ?", arguments: [ownerUserID])
        try db.execute(sql: "DELETE FROM cached_conversations WHERE owner_user_id = ?", arguments: [ownerUserID])
        try db.execute(sql: "DELETE FROM cache_metadata WHERE owner_user_id = ?", arguments: [ownerUserID])
    }

    static func insertIMMetadata(_ metadata: IMCacheMetadataState, ownerUserID: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO cache_metadata (
                owner_user_id, selected_conversation_id, last_summary_refresh_at, summary_sync_token,
                summary_next_cursor, has_more_conversation_summaries
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                metadata.selectedConversationID,
                timestamp(from: metadata.lastSummaryRefreshAt),
                metadata.summarySyncToken,
                metadata.summaryNextCursor,
                int(from: metadata.hasMoreConversationSummaries),
            ]
        )
    }

    static func insertConversation(_ conversation: IMCachedConversationState, ownerUserID: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO cached_conversations (
                owner_user_id, conversation_id, title, kind_raw_value, direct_messaging_state_raw_value,
                direct_peer_user_id, direct_peer_email, direct_peer_display_name, direct_peer_avatar_preset_raw_value,
                notice, notices_json, pending_messages_json, avatar_preset_raw_value, member_count, member_user_ids_blob, last_message_preview_text,
                updated_at, server_last_read_sequence, server_unread_count, is_pinned, pinned_at, is_muted,
                draft_text, draft_updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                conversation.id,
                conversation.title,
                conversation.kind.rawValue,
                conversation.directMessagingState?.rawValue,
                conversation.directPeer?.id.uuidString,
                conversation.directPeer?.email,
                conversation.directPeer?.displayName,
                conversation.directPeer?.avatarPreset?.rawValue,
                conversation.notice,
                jsonString(conversation.notices),
                jsonString(conversation.pendingMessages),
                conversation.avatarPreset?.rawValue,
                conversation.memberCount,
                encodeUUIDs(conversation.memberUserIDs),
                conversation.lastMessagePreviewText,
                conversation.updatedAt.timeIntervalSince1970,
                try int64Value(from: conversation.serverLastReadSequence),
                max(0, conversation.serverUnreadCount),
                int(from: conversation.isPinned),
                timestamp(from: conversation.pinnedAt),
                int(from: conversation.isMuted),
                conversation.draftText,
                timestamp(from: conversation.draftUpdatedAt),
            ]
        )
    }

    static func insertCursor(
        _ cursor: IMSyncCursorState?,
        fallback conversation: IMCachedConversationState,
        ownerUserID: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cached_message_cursors (
                owner_user_id, conversation_id, has_loaded_messages,
                latest_synced_server_sequence, oldest_loaded_server_sequence
            ) VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                conversation.id,
                int(from: cursor?.hasLoadedMessages ?? conversation.hasLoadedMessages),
                try int64(from: cursor?.latestLoadedTimelineSequence ?? conversation.latestLoadedTimelineSequence),
                try int64(from: cursor?.oldestLoadedTimelineSequence ?? conversation.oldestLoadedTimelineSequence),
            ]
        )
    }

    static func insertMessage(_ message: IMCachedMessageState, ownerUserID: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO cached_messages (
                owner_user_id, conversation_id, message_id, client_message_id, sender_user_id,
                server_sequence, timeline_sequence, kind, text_preview, content_json, direction_raw_value, created_at,
                delivery_state_raw_value, delivery_failure_message, transfer_task_session_identifier,
                transfer_task_identifier, derived_state_json, local_transfer_state_json, local_download_state_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                message.conversationID,
                message.id,
                message.clientMessageID,
                message.senderUserID.uuidString,
                try int64Value(from: message.serverSequence),
                try int64Value(from: message.timelineSequence),
                message.content.type.rawValue,
                message.content.presentation(derivedState: message.derivedState).previewText,
                jsonString(message.content),
                message.direction.rawValue,
                message.createdAt.timeIntervalSince1970,
                deliveryStateRawValue(from: message.deliveryState),
                deliveryFailureMessage(from: message.deliveryState),
                message.transferTaskID?.sessionIdentifier
                    ?? message.localTransferState?.taskID?.sessionIdentifier
                    ?? message.localDownloadState?.taskID?.sessionIdentifier,
                message.transferTaskID?.taskIdentifier
                    ?? message.localTransferState?.taskID?.taskIdentifier
                    ?? message.localDownloadState?.taskID?.taskIdentifier,
                jsonString(message.derivedState),
                jsonString(message.localTransferState),
                jsonString(message.localDownloadState),
            ]
        )
    }

    static func insertTransferSnapshot(_ snapshot: IMTransferSnapshot, ownerUserID: String, db: Database) throws {
        guard let snapshotJSON = jsonString(snapshot, configure: { $0.dateEncodingStrategy = .iso8601 }) else {
            return
        }
        try db.execute(
            sql: """
            INSERT INTO cached_transfer_snapshots (
                owner_user_id, task_session_identifier, task_identifier, snapshot_json
            ) VALUES (?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                snapshot.taskID.sessionIdentifier,
                snapshot.taskID.taskIdentifier,
                snapshotJSON,
            ]
        )
    }

    static func insertDomainEventState(
        _ state: IMDomainEventCacheState,
        ownerUserID: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cached_domain_event_state (
                owner_user_id, cursor, applied_event_ids_json, owner_aggregate_high_watermarks_json,
                deferred_event_pb_base64_json, full_refresh_conversation_ids_json
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                try int64Value(from: state.cursor),
                jsonString(state.appliedEventIDs.map(\.uuidString)),
                jsonString(state.ownerAggregateHighWatermarks),
                jsonString(state.deferredEvents),
                jsonString(state.fullRefreshConversationIDs),
            ]
        )
    }

    static func decodeConversation(
        row: Row,
        messages: [IMCachedMessageState],
        cursor: IMSyncCursorState?,
        diagnostics: inout IMCacheRestoreDiagnostics
    ) -> IMCachedConversationState {
        let hasLoadedMessages = cursor?.hasLoadedMessages ?? false
        let conversationID: String = row["conversation_id"]
        let notices: [IMCachedTimelineNoticeState]
        if let rawNoticesJSON = row["notices_json"] as String?,
           !rawNoticesJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                notices = try JSONDecoder().decode([IMCachedTimelineNoticeState].self, from: Data(rawNoticesJSON.utf8))
            } catch {
                diagnostics.recordDroppedTimelineNotice(
                    conversationID: conversationID,
                    noticeID: "notices_json",
                    reason: String(describing: error)
                )
                notices = []
            }
        } else {
            diagnostics.recordDroppedTimelineNotice(
                conversationID: conversationID,
                noticeID: "notices_json",
                reason: "missing notices_json"
            )
            notices = []
        }
        let pendingMessages = (decodeJSON(row["pending_messages_json"]) as [IMCachedPendingMessageState]?) ?? []
        let timelineSequences = messages.map(\.timelineSequence) + notices.map(\.timelineSequence)
        return IMCachedConversationState(
            id: conversationID,
            title: row["title"],
            kind: IMConversationKind(rawValue: row["kind_raw_value"]) ?? .group,
            directMessagingState: (row["direct_messaging_state_raw_value"] as String?)
                .flatMap(IMDirectMessagingState.init(rawValue:)),
            directPeer: directPeer(
                userID: row["direct_peer_user_id"],
                email: row["direct_peer_email"],
                displayName: row["direct_peer_display_name"],
                avatarPresetRawValue: row["direct_peer_avatar_preset_raw_value"]
            ),
            notice: row["notice"],
            avatarPreset: (row["avatar_preset_raw_value"] as String?)
                .flatMap(IMConversationAvatarPreset.init(rawValue:)),
            memberCount: row["member_count"],
            memberUserIDs: decodeUUIDs(from: row["member_user_ids_blob"]),
            messages: messages.sorted(by: messageComparator),
            pendingMessages: pendingMessages,
            notices: notices,
            hasLoadedMessages: hasLoadedMessages,
            lastMessagePreviewText: row["last_message_preview_text"],
            hasMoreHistory: hasLoadedMessages && (cursor?.oldestLoadedTimelineSequence ?? 0) > 1,
            latestLoadedTimelineSequence: cursor?.latestLoadedTimelineSequence
                ?? timelineSequences.max(),
            oldestLoadedTimelineSequence: hasLoadedMessages
                ? cursor?.oldestLoadedTimelineSequence ?? timelineSequences.min()
                : nil,
            serverLastReadSequence: uint64(from: row["server_last_read_sequence"]),
            serverUnreadCount: max(0, row["server_unread_count"] as Int),
            isPinned: bool(from: row["is_pinned"]),
            pinnedAt: date(from: row["pinned_at"]),
            isMuted: bool(from: row["is_muted"]),
            draftText: row["draft_text"],
            draftUpdatedAt: date(from: row["draft_updated_at"]),
            updatedAt: date(from: row["updated_at"]) ?? .distantPast
        )
    }

    static func decodeMessage(row: Row) -> CachedMessageDecodeResult {
        let conversationID: String = row["conversation_id"] ?? "unknown"
        let messageID: String = row["message_id"] ?? "unknown"
        guard let senderUserID = (row["sender_user_id"] as String?).flatMap(UUID.init(uuidString:)),
              let serverSequence = uint64Optional(from: row["server_sequence"]),
              let timelineSequence = uint64Optional(from: row["timeline_sequence"]),
              serverSequence > 0,
              timelineSequence > 0
        else {
            return .failure(
                conversationID: conversationID,
                messageID: messageID,
                reason: "canonical message is missing sender or positive sequence"
            )
        }

        do {
            return .success(try IMCachedMessageState(
                id: messageID,
                conversationID: conversationID,
                clientMessageID: row["client_message_id"],
                serverMessageID: messageID,
                senderUserID: senderUserID,
                serverSequence: serverSequence,
                timelineSequence: timelineSequence,
                content: decodeMessageContent(
                    kind: row["kind"],
                    textPreview: row["text_preview"],
                    contentJSON: row["content_json"]
                ),
                derivedState: decodeJSON(row["derived_state_json"]) ?? MessageDerivedState(),
                direction: IMMessageDirection(rawValue: row["direction_raw_value"]) ?? .incoming,
                createdAt: date(from: row["created_at"]) ?? .distantPast,
                deliveryState: deliveryState(
                    rawValue: row["delivery_state_raw_value"],
                    failureMessage: row["delivery_failure_message"]
                ),
                transferTaskID: transferTaskID(
                    sessionIdentifier: row["transfer_task_session_identifier"],
                    taskIdentifier: row["transfer_task_identifier"]
                ),
                localTransferState: decodeJSON(row["local_transfer_state_json"]),
                localDownloadState: decodeJSON(row["local_download_state_json"])
            ))
        } catch {
            return .failure(
                conversationID: conversationID,
                messageID: messageID,
                reason: String(describing: error)
            )
        }
    }

    static func decodeCursor(row: Row) -> IMSyncCursorState {
        let hasLoadedMessages = bool(from: row["has_loaded_messages"])
        return IMSyncCursorState(
            conversationID: row["conversation_id"],
            hasLoadedMessages: hasLoadedMessages,
            latestLoadedTimelineSequence: uint64Optional(from: row["latest_synced_server_sequence"]),
            oldestLoadedTimelineSequence: hasLoadedMessages
                ? uint64Optional(from: row["oldest_loaded_server_sequence"])
                : nil
        )
    }

    static func decodeTransferSnapshot(row: Row) -> IMTransferSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decodeJSON(row["snapshot_json"], decoder: decoder)
    }

    static func decodeDomainEventState(row: Row?) -> IMDomainEventCacheState {
        guard let row else {
            return IMDomainEventCacheState()
        }
        let ids: [String] = decodeJSON(row["applied_event_ids_json"]) ?? []
        let appliedEventIDs = ids.map(UUID.init(uuidString:))
        return IMDomainEventCacheState(
            cursor: uint64(from: row["cursor"] ?? 0),
            appliedEventIDs: appliedEventIDs.allSatisfy { $0 != nil } ? appliedEventIDs.compactMap { $0 } : [],
            ownerAggregateHighWatermarks: decodeJSON(row["owner_aggregate_high_watermarks_json"]) ?? [],
            deferredEvents: decodeJSON(row["deferred_event_pb_base64_json"]) ?? [],
            fullRefreshConversationIDs: decodeJSON(row["full_refresh_conversation_ids_json"]) ?? []
        )
    }

    static func deleteContactSnapshot(ownerUserID: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM cached_contact_requests WHERE owner_user_id = ?", arguments: [ownerUserID])
        try db.execute(sql: "DELETE FROM cached_contacts WHERE owner_user_id = ?", arguments: [ownerUserID])
        try db.execute(sql: "DELETE FROM contact_cache_metadata WHERE owner_user_id = ?", arguments: [ownerUserID])
    }

    static func insertContactMetadata(_ snapshot: ContactStateCacheSnapshot, ownerUserID: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO contact_cache_metadata (
                owner_user_id, last_refresh_at, last_seen_incoming_contact_request_at
            ) VALUES (?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                timestamp(from: snapshot.lastRefreshAt),
                timestamp(from: snapshot.lastSeenIncomingContactRequestAt),
            ]
        )
    }

    static func insertContact(_ contact: CachedContactState, ownerUserID: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO cached_contacts (
                owner_user_id, contact_user_id, email, display_name,
                avatar_preset_raw_value, remark, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                contact.id.uuidString,
                contact.email,
                contact.displayName,
                contact.avatarPreset?.rawValue,
                contact.remark,
                timestamp(from: contact.createdAt),
            ]
        )
    }

    static func insertContactRequest(
        _ request: CachedContactRequestState,
        bucket: ContactRequestCacheBucket,
        ownerUserID: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cached_contact_requests (
                owner_user_id, request_id, bucket_raw_value, requester_user_id, requester_email,
                requester_display_name, requester_avatar_preset_raw_value, addressee_user_id,
                addressee_email, addressee_display_name, addressee_avatar_preset_raw_value,
                status_raw_value, message, requester_remark, addressee_remark,
                created_at, updated_at, responded_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                ownerUserID,
                request.id.uuidString,
                bucket.rawValue,
                request.requester.id.uuidString,
                request.requester.email,
                request.requester.displayName,
                request.requester.avatarPreset?.rawValue,
                request.addressee.id.uuidString,
                request.addressee.email,
                request.addressee.displayName,
                request.addressee.avatarPreset?.rawValue,
                request.status.rawValue,
                request.message,
                request.requesterRemark,
                request.addresseeRemark,
                timestamp(from: request.createdAt),
                timestamp(from: request.updatedAt),
                timestamp(from: request.respondedAt),
            ]
        )
    }

    static func decodeContact(row: Row) -> CachedContactState? {
        guard let id = UUID(uuidString: row["contact_user_id"]) else {
            return nil
        }
        return CachedContactState(
            id: id,
            email: row["email"],
            displayName: row["display_name"],
            avatarPreset: (row["avatar_preset_raw_value"] as String?).flatMap(UserAvatarPreset.init(rawValue:)),
            remark: row["remark"],
            createdAt: date(from: row["created_at"])
        )
    }

    static func decodeContactRequest(row: Row) -> (bucket: ContactRequestCacheBucket, request: CachedContactRequestState)? {
        guard let bucket = ContactRequestCacheBucket(rawValue: row["bucket_raw_value"]),
              let requestID = UUID(uuidString: row["request_id"]),
              let requesterID = UUID(uuidString: row["requester_user_id"]),
              let addresseeID = UUID(uuidString: row["addressee_user_id"]),
              let status = ContactRequestStatus(rawValue: row["status_raw_value"])
        else {
            return nil
        }
        return (
            bucket,
            CachedContactRequestState(
                id: requestID,
                requester: AuthUser(
                    id: requesterID,
                    email: row["requester_email"],
                    displayName: row["requester_display_name"],
                    avatarPreset: (row["requester_avatar_preset_raw_value"] as String?)
                        .flatMap(UserAvatarPreset.init(rawValue:))
                ),
                addressee: AuthUser(
                    id: addresseeID,
                    email: row["addressee_email"],
                    displayName: row["addressee_display_name"],
                    avatarPreset: (row["addressee_avatar_preset_raw_value"] as String?)
                        .flatMap(UserAvatarPreset.init(rawValue:))
                ),
                status: status,
                message: row["message"],
                requesterRemark: row["requester_remark"],
                addresseeRemark: row["addressee_remark"],
                createdAt: date(from: row["created_at"]),
                updatedAt: date(from: row["updated_at"]),
                respondedAt: date(from: row["responded_at"])
            )
        )
    }

    static func conversationComparator(_ left: IMCachedConversationState, _ right: IMCachedConversationState) -> Bool {
        if left.isPinned != right.isPinned {
            return left.isPinned && !right.isPinned
        }
        if left.isPinned && right.isPinned, left.pinnedAt != right.pinnedAt {
            return (left.pinnedAt ?? .distantPast) > (right.pinnedAt ?? .distantPast)
        }
        if left.updatedAt == right.updatedAt {
            return left.id < right.id
        }
        return left.updatedAt > right.updatedAt
    }

    static func pendingContactRequestComparator(
        _ left: CachedContactRequestState,
        _ right: CachedContactRequestState
    ) -> Bool {
        switch (left.createdAt, right.createdAt) {
        case let (leftDate?, rightDate?):
            return leftDate > rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return left.id.uuidString > right.id.uuidString
        }
    }

    static func resolvedContactRequestComparator(
        _ left: CachedContactRequestState,
        _ right: CachedContactRequestState
    ) -> Bool {
        switch (left.respondedAt, right.respondedAt) {
        case let (leftDate?, rightDate?):
            if leftDate != rightDate {
                return leftDate > rightDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        switch (left.updatedAt, right.updatedAt) {
        case let (leftDate?, rightDate?):
            if leftDate != rightDate {
                return leftDate > rightDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return left.id.uuidString > right.id.uuidString
    }

    private static func messageComparator(_ left: IMCachedMessageState, _ right: IMCachedMessageState) -> Bool {
        if left.serverSequence == right.serverSequence {
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
        return left.serverSequence < right.serverSequence
    }

    private static func decodeMessageContent(
        kind: String,
        textPreview: String,
        contentJSON: String?
    ) -> IMMessageContent {
        if let decoded: IMMessageContent = decodeJSON(contentJSON) {
            return decoded
        }

        switch IMMessageContentType(rawValue: kind) ?? .richText {
        case .richText:
            return .richText(.plain(textPreview))
        case .reply:
            return .reply(
                reference: IMReplyReference(messageID: "", senderUserID: nil, previewText: ""),
                body: .plain(textPreview)
            )
        case .image:
            return .image(IMMediaAsset(assetID: "", kind: .image, mimeType: "image/*", byteSize: 0, filename: textPreview))
        case .audio:
            return .audio(IMMediaAsset(assetID: "", kind: .audio, mimeType: "audio/*", byteSize: 0, filename: textPreview))
        case .file:
            return .file(
                IMMediaAsset(assetID: "", kind: .file, mimeType: "application/octet-stream", byteSize: 0, filename: textPreview)
            )
        }
    }

    private static func directPeer(
        userID: String?,
        email: String?,
        displayName: String?,
        avatarPresetRawValue: String?
    ) -> IMDirectPeer? {
        guard let userID,
              let id = UUID(uuidString: userID),
              let email,
              !email.isEmpty
        else {
            return nil
        }
        return IMDirectPeer(
            id: id,
            email: email,
            displayName: displayName,
            avatarPreset: avatarPresetRawValue.flatMap(UserAvatarPreset.init(rawValue:))
        )
    }

    private static func transferTaskID(sessionIdentifier: String?, taskIdentifier: Int?) -> TransferTaskID? {
        guard let sessionIdentifier, let taskIdentifier else {
            return nil
        }
        return TransferTaskID(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier)
    }

    private static func deliveryStateRawValue(from state: IMMessageDeliveryState) -> String {
        switch state {
        case .preparing:
            return "preparing"
        case .uploading:
            return "uploading"
        case .uploaded:
            return "uploaded"
        case .queued:
            return "queued"
        case .sending:
            return "sending"
        case .sent:
            return "sent"
        case .received:
            return "received"
        case .unknown:
            return "unknown"
        case .failed:
            return "failed"
        }
    }

    private static func deliveryFailureMessage(from state: IMMessageDeliveryState) -> String? {
        switch state {
        case .preparing(let message), .uploading(let message), .queued(let message), .failed(let message), .unknown(let message):
            return message
        case .uploaded, .sending, .sent, .received:
            return nil
        }
    }

    private static func deliveryState(rawValue: String, failureMessage: String?) -> IMMessageDeliveryState {
        switch rawValue {
        case "preparing":
            return .preparing(message: failureMessage ?? "正在准备上传附件。")
        case "uploading":
            return .uploading(message: failureMessage ?? "正在上传附件。")
        case "uploaded":
            return .uploaded
        case "queued":
            return .queued(message: failureMessage ?? "等待 IM 长连接恢复后发送。")
        case "sending":
            return .unknown(message: failureMessage ?? "发送状态未确认，请重试。")
        case "sent":
            return .sent
        case "received":
            return .received
        case "unknown":
            return .unknown(message: failureMessage ?? "发送状态未确认，请重试。")
        case "failed":
            return .failed(message: failureMessage ?? "unknown")
        default:
            return .received
        }
    }

    static func bool(from rawValue: Int64?) -> Bool {
        (rawValue ?? 0) != 0
    }

    static func int(from bool: Bool) -> Int {
        bool ? 1 : 0
    }

    static func date(from timestamp: Double?) -> Date? {
        timestamp.map(Date.init(timeIntervalSince1970:))
    }

    static func timestamp(from date: Date?) -> Double? {
        date?.timeIntervalSince1970
    }

    private static func int64(from value: UInt64?) throws -> Int64? {
        guard let value else { return nil }
        return try int64Value(from: value)
    }

    private static func int64Value(from value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else {
            throw PersistenceError.invalidSequenceOverflow
        }
        return Int64(value)
    }

    private static func uint64(from value: Int64) -> UInt64 {
        UInt64(max(0, value))
    }

    private static func uint64Optional(from value: Int64?) -> UInt64? {
        guard let value, value > 0 else {
            return nil
        }
        return UInt64(value)
    }

    private static func encodeUUIDs(_ uuids: [UUID]) -> String {
        uuids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private static func decodeUUIDs(from blob: String) -> [UUID] {
        blob.split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private static func jsonString<Value: Encodable>(
        _ value: Value?,
        configure: ((JSONEncoder) -> Void)? = nil
    ) -> String? {
        guard let value else {
            return nil
        }
        let encoder = JSONEncoder()
        configure?(encoder)
        guard let data = try? encoder.encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeJSON<Value: Decodable>(_ json: String?, decoder: JSONDecoder = JSONDecoder()) -> Value? {
        guard let json, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(Value.self, from: data)
    }
}
