import Foundation
import GRDB
import IMV2Core

public struct V2ClientFavoriteMessageCursor: Equatable, Sendable {
    public let updatedAt: Date
    public let messageID: MessageID

    public init(updatedAt: Date, messageID: MessageID) {
        self.updatedAt = updatedAt
        self.messageID = messageID
    }
}

public struct V2ClientFavoriteMessagePage: Equatable, Sendable {
    public let messages: [V2ClientMessageProjection]
    public let nextCursor: V2ClientFavoriteMessageCursor?

    public init(messages: [V2ClientMessageProjection], nextCursor: V2ClientFavoriteMessageCursor?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public struct V2ClientConversationListCursor: Equatable, Sendable {
    public let isPinned: Bool
    public let lastActivity: Date
    public let roomID: RoomID

    public init(isPinned: Bool, lastActivity: Date, roomID: RoomID) {
        self.isPinned = isPinned
        self.lastActivity = lastActivity
        self.roomID = roomID
    }
}

/// One bounded conversation-list row assembled from a single SQLite read
/// snapshot. Mutable profile presentation remains separate from the durable
/// room identity, while every value needed by the visible page is captured
/// without a follow-up query per room.
public struct V2ClientConversationListEntry: Equatable, Sendable {
    public let roomID: RoomID
    public let lastMessage: V2ClientMessageProjection?
    public let roomProfile: V2ClientRoomProfileProjection?
    public let directIdentity: V2ClientDirectRoomIdentity?
    public let directProfileView: V2ProfileView?
    public let lastActivity: Date
    public let isPinned: Bool
    public let isArchived: Bool
    public let muteUntil: Date?

    public init(
        roomID: RoomID,
        lastMessage: V2ClientMessageProjection?,
        roomProfile: V2ClientRoomProfileProjection?,
        directIdentity: V2ClientDirectRoomIdentity?,
        directProfileView: V2ProfileView?,
        lastActivity: Date,
        isPinned: Bool,
        isArchived: Bool,
        muteUntil: Date?
    ) {
        precondition(lastMessage == nil || lastMessage?.roomID == roomID)
        precondition(roomProfile == nil || roomProfile?.roomID == roomID)
        precondition(directIdentity == nil || directIdentity?.roomID == roomID)
        self.roomID = roomID
        self.lastMessage = lastMessage
        self.roomProfile = roomProfile
        self.directIdentity = directIdentity
        self.directProfileView = directProfileView
        self.lastActivity = lastActivity
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.muteUntil = muteUntil
    }
}

public struct V2ClientConversationListPage: Equatable, Sendable {
    public let entries: [V2ClientConversationListEntry]
    public let nextCursor: V2ClientConversationListCursor?

    public init(entries: [V2ClientConversationListEntry], nextCursor: V2ClientConversationListCursor?) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// The local database is the authoritative device projection. It applies sync
/// records incrementally in one SQLite transaction.
public actor GRDBV2LocalSyncStore: V2LocalSyncStore, V2LocalCommandStore, V2LocalMembershipCommandStore, V2LocalMessageWithdrawalStore, V2LocalMessageRedactionStore, V2LocalMemberMuteStore, V2LocalModeratedMemberRemovalStore, V2LocalMessageReactionStore, V2LocalMessageEditStore, V2LocalReadReceiptStore, V2LocalConversationCapabilitiesStore, V2LocalGroupCapabilitiesStore, V2LocalForwardMessagesStore, V2BulkForwardMessagesStore, V2LocalSocialCommandStore, V2LocalGroupRoomCommandStore, V2LocalGroupEventStore, V2LocalForegroundGroupEventPreviewStore, V2ClientProfileProjectionStore {
    /// All local command repositories share this actor-owned pool. Extensions
    /// preserve the actor boundary while keeping each durable queue in its
    /// own source file.
    let databasePool: DatabasePool
    let projectionChangeHub = V2ProjectionChangeHub()
    /// Search is intentionally a separately-writable derived database. This
    /// prevents FTS maintenance from competing with the authoritative sync
    /// projection writer in `databasePool`.
    let messageSearchDatabasePool: DatabasePool
    let databaseURL: URL
    let messageSearchDatabaseURL: URL

    init(databaseURL: URL, installationBinding: V2LocalInstallationBinding, userID: UserID? = nil) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: directory)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            db.add(function: Self.contactSearchUnigramsFunction)
            db.add(function: Self.contactSearchBigramsFunction)
        }
        databasePool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        messageSearchDatabaseURL = V2LocalDatabaseArtifacts(primary: databaseURL).search
        var openedSearchPool: DatabasePool?
        do {
            try databasePool.write { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
            try Self.migrator.migrate(databasePool)
            let searchPool = try DatabasePool(path: messageSearchDatabaseURL.path, configuration: configuration)
            openedSearchPool = searchPool
            try searchPool.write { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
            try Self.messageSearchMigrator.migrate(searchPool)
            try databasePool.write { db in
                try Self.establishInstallationBinding(installationBinding, userID: userID, db: db)
            }
            try Self.applyBackupExclusion(databaseURL: databaseURL)
            try Self.applyBackupExclusion(databaseURL: messageSearchDatabaseURL)
            messageSearchDatabasePool = searchPool
            let hub = projectionChangeHub
            try databasePool.write { db in
                db.add(transactionObserver: V2ProjectionTransactionObserver(hub: hub), extent: .databaseLifetime)
            }
        } catch {
            // Bootstrap may erase an untrusted installation after this throws.
            // Explicitly close both handles before allowing that fallback.
            try openedSearchPool?.close()
            try databasePool.close()
            throw error
        }
    }

    /// Actor-isolated and off MainActor. GRDB close drains current accesses and
    /// rejects future accesses, including late work retaining this store.
    /// An error must prevent any caller from unlinking the database files.
    deinit { projectionChangeHub.finish() }

    public func close() throws {
        try databasePool.close()
        projectionChangeHub.finish()
        try messageSearchDatabasePool.close()
    }

    /// Reasserts and verifies the device-only backup policy after database
    /// reopen. The managed directory, SQLite file, WAL, and SHM are all scoped
    /// out of device backup and therefore cannot restore unsent V2 commands.
    public func refreshBackupExclusion() throws {
        try Self.applyBackupExclusion(databaseURL: databaseURL)
        try Self.applyBackupExclusion(databaseURL: messageSearchDatabaseURL)
    }

    private static func applyBackupExclusion(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try V2LocalBackupExclusion.apply(to: directory)
        for artifact in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] where FileManager.default.fileExists(atPath: artifact.path) {
            try V2LocalBackupExclusion.apply(to: artifact)
        }
    }

    private static let contactSearchUnigramsFunction = DatabaseFunction(
        "v2_contact_search_unigrams",
        argumentCount: 1,
        pure: true
    ) { values in
        guard let value = String.fromDatabaseValue(values[0]) else { return "" }
        return V2CharacterGramTokenizer().tokenize(value).unigrams.joined(separator: " ")
    }

    private static let contactSearchBigramsFunction = DatabaseFunction(
        "v2_contact_search_bigrams",
        argumentCount: 1,
        pure: true
    ) { values in
        guard let value = String.fromDatabaseValue(values[0]) else { return "" }
        return V2CharacterGramTokenizer().tokenize(value).bigrams.joined(separator: " ")
    }

    public func boundAccountID() throws -> UserID? {
        try databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton = 1").map(UserID.init)
        }
    }

    public func cursor() throws -> V2LocalSyncCursor? {
        try databasePool.read { db in try Self.readCursor(db) }
    }

    /// Persists recovery intent without erasing the live bank or any outbox.
    public func requestSnapshotRebuild() throws {
        try databasePool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO v2_sync_rebuild_requests (singleton) VALUES (1)")
        }
    }

    public func requiresSnapshotRebuild() throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_sync_rebuild_requests)") == true
        }
    }

    public func discardSyncCapabilities(generation: UInt64) throws {
        try databasePool.write { db in
            guard let cursor = try Self.readCursor(db), cursor.state == .ready else {
                throw V2ClientSyncError.resetPending
            }
            guard cursor.generation == generation else {
                throw V2ClientSyncError.generationMismatch
            }
            try Self.writeCursor(try .init(
                state: .ready,
                generation: generation,
                appliedSequence: cursor.appliedSequence,
                serverAcknowledgedSequence: cursor.serverAcknowledgedSequence,
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            ), db: db)
        }
    }

    public func groupEventCursor(roomID: RoomID) throws -> UInt64 {
        try databasePool.read { db in
            let sequence: Int64 = try Row.fetchOne(
                db,
                sql: "SELECT applied_room_sequence FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [roomID.rawValue]
            )?["applied_room_sequence"] ?? 0
            return try Self.storageUnsigned(sequence)
        }
    }

    public func knownRoomLogRoomIDs(after roomID: RoomID?, limit: Int) throws -> [RoomID] {
        try roomLogRoomIDs(after: roomID, limit: limit, descending: false)
    }

    public func lastKnownRoomLogRoomID() throws -> RoomID? {
        try roomLogRoomIDs(after: nil, limit: 1, descending: true).first
    }

    private func roomLogRoomIDs(after roomID: RoomID?, limit: Int, descending: Bool) throws -> [RoomID] {
        precondition(limit > 0 && limit <= 10_001)
        return try databasePool.read { db in
            let rawRoomIDs = try String.fetchAll(
                db,
                sql: """
                    WITH room_log_rooms AS (
                        SELECT room_id
                        FROM v2_room_profile_projections
                        WHERE delivery_mode = ? AND is_group_event_authorized = 1
                        UNION
                        SELECT direct.room_id
                        FROM (
                            SELECT room_id FROM v2_direct_room_profile_projections
                            UNION
                            SELECT room_id FROM v2_direct_room_identities
                        ) AS direct
                        LEFT JOIN v2_room_event_authorizations AS authorization
                          ON authorization.room_id = direct.room_id
                        WHERE COALESCE(authorization.is_authorized, 1) = 1
                    )
                    SELECT room_id
                    FROM room_log_rooms
                    WHERE (? IS NULL OR room_id > ?)
                    ORDER BY room_id \(descending ? "DESC" : "ASC")
                    LIMIT ?
                    """,
                arguments: [V2GroupDeliveryMode.largeGroupHybrid.rawValue, roomID?.rawValue, roomID?.rawValue, limit]
            )
            return try rawRoomIDs.map(RoomID.init)
        }
    }

    public func hybridGroupBackgroundCursor() throws -> RoomID? {
        try databasePool.read { db in
            guard let rawValue = try String.fetchOne(
                db,
                sql: "SELECT after_room_id FROM v2_hybrid_group_background_state WHERE singleton = 1"
            ) else { return nil }
            return try RoomID(rawValue)
        }
    }

    public func setHybridGroupBackgroundCursor(_ roomID: RoomID?) throws {
        try databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO v2_hybrid_group_background_state (singleton, after_room_id)
                    VALUES (1, ?)
                    ON CONFLICT(singleton) DO UPDATE SET after_room_id = excluded.after_room_id
                    """,
                arguments: [roomID?.rawValue]
            )
        }
    }

    public func isKnownRoomLogRoom(roomID: RoomID) throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM v2_room_profile_projections
                        WHERE room_id = ? AND delivery_mode = ? AND is_group_event_authorized = 1
                        UNION ALL
                        SELECT 1
                        FROM (
                            SELECT room_id FROM v2_direct_room_profile_projections
                            UNION
                            SELECT room_id FROM v2_direct_room_identities
                        ) AS direct
                        LEFT JOIN v2_room_event_authorizations AS authorization
                          ON authorization.room_id = direct.room_id
                        WHERE direct.room_id = ? AND COALESCE(authorization.is_authorized, 1) = 1
                    )
                    """,
                arguments: [roomID.rawValue, V2GroupDeliveryMode.largeGroupHybrid.rawValue, roomID.rawValue]
            ) ?? false
        }
    }

    public func groupEventAccess(roomID: RoomID) throws -> V2ClientGroupEventAccess? {
        try databasePool.read { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT delivery_mode, is_group_event_authorized FROM v2_room_profile_projections WHERE room_id = ?",
                arguments: [roomID.rawValue]
            ) {
                guard let deliveryMode = V2GroupDeliveryMode(rawValue: row["delivery_mode"] as String) else {
                    throw V2ClientProjectionError.invalidMessagePayload
                }
                return .init(
                    delivery: deliveryMode == .largeGroupHybrid ? .durableRoomLog : .foregroundPreview,
                    isAuthorized: row["is_group_event_authorized"] as Bool
                )
            }
            let directKnown = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = ? UNION ALL SELECT 1 FROM v2_direct_room_identities WHERE room_id = ?)",
                arguments: [roomID.rawValue, roomID.rawValue]
            ) ?? false
            guard directKnown else { return nil }
            let authorized = try Bool.fetchOne(
                db,
                sql: "SELECT COALESCE((SELECT is_authorized FROM v2_room_event_authorizations WHERE room_id = ?), 1)",
                arguments: [roomID.rawValue]
            ) ?? true
            return .init(delivery: .durableRoomLog, isAuthorized: authorized)
        }
    }

    public func foregroundGroupEventPreviewStartSequence(roomID: RoomID) throws -> UInt64 {
        try databasePool.read { db in
            let sequence: Int64 = try Row.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(room_sequence), 0) AS room_sequence FROM v2_message_projections WHERE room_id = ?",
                arguments: [roomID.rawValue]
            )?["room_sequence"] ?? 0
            return try Self.storageUnsigned(sequence)
        }
    }

    public func markRoomEventUnauthorized(roomID: RoomID) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue])
            try db.execute(sql: "DELETE FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [roomID.rawValue])
            try db.execute(
                sql: "UPDATE v2_room_profile_projections SET is_group_event_authorized = 0 WHERE room_id = ?",
                arguments: [roomID.rawValue]
            )
            try db.execute(
                sql: """
                    INSERT INTO v2_room_event_authorizations (room_id, is_authorized)
                    SELECT ?, 0
                    WHERE EXISTS (
                        SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = ?
                        UNION ALL
                        SELECT 1 FROM v2_direct_room_identities WHERE room_id = ?
                    )
                    ON CONFLICT(room_id) DO UPDATE SET is_authorized = excluded.is_authorized
                    """,
                arguments: [roomID.rawValue, roomID.rawValue, roomID.rawValue]
            )
        }
    }

    public func applyGroupEventPage(_ page: V2ClientGroupEventPage) throws -> UInt64 {
        try applyGroupEventPageReportingChanges(page).appliedThrough
    }

    public func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) throws -> V2GroupEventPageCommit {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            let current: Int64 = try Row.fetchOne(
                db,
                sql: "SELECT applied_room_sequence FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [page.roomID.rawValue]
            )?["applied_room_sequence"] ?? 0
            let cursor = try Self.storageUnsigned(current)
            guard page.nextRoomSequence >= cursor,
                  zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
                  (page.events.last?.roomSequence ?? cursor) <= page.nextRoomSequence,
                  !page.hasMore || page.nextRoomSequence > cursor
            else { throw V2ClientSyncError.invalidRecordOrdering }
            var insertedEvents = 0
            for event in page.events {
                if event.roomSequence <= cursor {
                    guard let existing = try Row.fetchOne(
                        db,
                        sql: "SELECT source_event_id, projection_kind, payload FROM v2_group_events WHERE room_id = ? AND room_sequence = ?",
                        arguments: [page.roomID.rawValue, try Self.storageInteger(event.roomSequence)]
                    ) else { throw V2ClientSyncError.invalidRecordOrdering }
                    let sourceEventID: String = existing["source_event_id"]
                    let projectionKind: String = existing["projection_kind"]
                    let payload: Data = existing["payload"]
                    guard sourceEventID == event.sourceEventID.rawValue, projectionKind == event.projectionKind, payload == event.payload else {
                        throw V2ClientSyncError.invalidRecordOrdering
                    }
                    continue
                }
                let record = try V2ClientSyncRecord(sequence: event.roomSequence, sourceEventID: event.sourceEventID, projectionKind: event.projectionKind, payload: event.payload)
                try Self.applyRoomEventProjection(record, roomID: page.roomID, db: db)
                try db.execute(
                    sql: "INSERT INTO v2_group_events (room_id, room_sequence, source_event_id, projection_kind, payload) VALUES (?, ?, ?, ?, ?)",
                    arguments: [page.roomID.rawValue, try Self.storageInteger(event.roomSequence), event.sourceEventID.rawValue, event.projectionKind, event.payload]
                )
                insertedEvents += 1
            }
            try db.execute(
                sql: "INSERT INTO v2_group_event_cursors (room_id, applied_room_sequence) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET applied_room_sequence = excluded.applied_room_sequence",
                arguments: [page.roomID.rawValue, try Self.storageInteger(page.nextRoomSequence)]
            )
            return try .init(appliedThrough: page.nextRoomSequence, insertedEventCount: insertedEvents)
        }
    }

    public func applyForegroundGroupEventPreviewPage(_ page: V2ClientGroupEventPage) throws -> UInt64 {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            guard zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
                  (page.events.last?.roomSequence ?? page.nextRoomSequence) <= page.nextRoomSequence
            else { throw V2ClientSyncError.invalidRecordOrdering }
            for event in page.events {
                try Self.applyRoomEventProjection(
                    .init(
                        sequence: event.roomSequence,
                        sourceEventID: event.sourceEventID,
                        projectionKind: event.projectionKind,
                        payload: event.payload
                    ),
                    roomID: page.roomID,
                    db: db
                )
            }
            // This is deliberately not a durable cursor or ACK. The normal
            // per-user sync stream remains the standard group's recovery
            // authority after a process restart or a missed foreground hint.
            return page.nextRoomSequence
        }
    }

    public func apply(_ batch: V2ClientSyncBatch) throws -> V2LocalSyncCursor {
        try databasePool.write { db in
            try Self.validatePersistable(batch)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_sync_rebuild_requests)") == false else { throw V2ClientSyncError.snapshotRebuildRequired }
            var cursor = try Self.readCursor(db) ?? .init(
                state: .ready,
                generation: batch.generation,
                appliedSequence: 0,
                serverAcknowledgedSequence: 0,
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            guard cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            guard cursor.generation == batch.generation else { throw V2ClientSyncError.generationMismatch }
            try Self.validateOrdering(batch.records)
            var applied = cursor.appliedSequence
            for record in batch.records {
                if record.sequence <= applied {
                    guard try Self.matchesExisting(record, db: db) else { throw V2ClientSyncError.invalidRecordOrdering }
                    continue
                }
                guard record.sequence == applied + 1 else { throw V2ClientSyncError.invalidRecordOrdering }
                if record.projectionKind == "message" {
                    try Self.applyMessage(record, db: db)
                } else if record.projectionKind == "message_reaction" {
                    try Self.applyReaction(record, db: db)
                } else if record.projectionKind == "moderation" {
                    try Self.applyModeration(record, db: db)
                } else if record.projectionKind == "relationship" {
                    try Self.applyRelationship(record, db: db)
                } else if record.projectionKind == "user_block" {
                    try Self.applyUserBlock(record, db: db)
                } else if record.projectionKind == "stranger_message_permission" {
                    try Self.applyStrangerMessagePermission(record, db: db)
                } else if record.projectionKind == "user_add_permission" {
                    try Self.applyUserAddPermission(record, db: db)
                } else if record.projectionKind == "direct_read_receipt" {
                    try Self.applyDirectReadReceipt(record, db: db)
                } else if record.projectionKind == "read_receipt_preferences" {
                    try Self.applyReadReceiptPreference(record, db: db)
                } else if record.projectionKind == "conversation_state" {
                    try Self.persist(V2ClientConversationState(record: record), db: db)
                } else if record.projectionKind == "message_favorite" {
                    try Self.persist(V2ClientMessageFavorite(record: record), db: db)
                } else if record.projectionKind == "group_capability" {
                    try Self.applyGroupCapability(record, db: db)
                } else if record.projectionKind == "room" || record.projectionKind == "membership" {
                    try Self.applyMembershipAwareRoomProjection(record, db: db)
                } else if record.projectionKind == "direct_room_profile" {
                    try Self.persist(V2ClientDirectRoomProfileProjection(record: record), db: db)
                } else if record.projectionKind == "timeline_activity" {
                    try Self.persist(V2ClientTimelineActivityProjection(record: record), db: db)
                } else if record.projectionKind == "direct_sending_capability" {
                    try Self.persist(V2ClientDirectSendingCapability(record: record), db: db)
                } else if record.projectionKind == "profile_invalidation" {
                    try Self.persist(V2ClientProfileInvalidation(record: record), db: db)
                }
                try db.execute(
                    sql: """
                    INSERT INTO v2_sync_events (sequence, source_event_id, projection_kind, payload)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [try Self.storageInteger(record.sequence), record.sourceEventID.rawValue, record.projectionKind, record.payload]
                )
                applied = record.sequence
            }
            // During ordinary delivery this is the new applied watermark. It
            // can be lower than `applied` only after a terminal reset rollback
            // cleared expired capabilities and the server is replaying facts
            // already present locally in bounded pages.
            let acknowledgementSequence = batch.records.last?.sequence ??
                cursor.pendingAcknowledgementSequence
            let needsAcknowledgement = acknowledgementSequence.map {
                $0 > cursor.serverAcknowledgedSequence
            } ?? false
            cursor = try .init(
                state: .ready,
                generation: cursor.generation,
                appliedSequence: applied,
                serverAcknowledgedSequence: cursor.serverAcknowledgedSequence,
                syncToken: batch.nextSyncToken,
                pendingAcknowledgementReceipt: needsAcknowledgement ? batch.receipt : nil,
                pendingAcknowledgementSequence: needsAcknowledgement ? acknowledgementSequence : nil,
                pendingReset: nil
            )
            try Self.writeCursor(cursor, db: db)
            return cursor
        }
    }

    public func markServerAcknowledged(generation: UInt64, sequence: UInt64, receipt: V2SyncReceipt) throws {
        try databasePool.write { db in
            guard let cursor = try Self.readCursor(db), cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            guard cursor.generation == generation,
                  sequence == cursor.pendingAcknowledgementSequence,
                  receipt == cursor.pendingAcknowledgementReceipt
            else { throw V2ClientSyncError.acknowledgementReceiptMismatch }
            let updated = try V2LocalSyncCursor(
                state: .ready,
                generation: generation,
                appliedSequence: cursor.appliedSequence,
                serverAcknowledgedSequence: max(cursor.serverAcknowledgedSequence, sequence),
                syncToken: cursor.syncToken,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            try Self.writeCursor(updated, db: db)
        }
    }

    public func beginReset(_ reset: V2ClientResetRequired) throws {
        try databasePool.write { db in
            let current = try Self.readCursor(db)
            if let current, current.state == .resetPending {
                guard current.pendingReset == reset else { throw V2ClientSyncError.resetFenceMismatch }
                return
            }
            let previous = try current ?? .init(
                state: .ready,
                generation: reset.generation.subtractingReportingOverflow(1).partialValue,
                appliedSequence: 0,
                serverAcknowledgedSequence: 0,
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            let nextGeneration = previous.generation.addingReportingOverflow(1)
            let rebuilding = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_sync_rebuild_requests)") == true
            guard !nextGeneration.overflow,
                  nextGeneration.partialValue == reset.generation || (rebuilding && reset.generation > previous.generation) else {
                throw V2ClientSyncError.generationMismatch
            }
            try db.execute(
                sql: """
                INSERT INTO v2_reset_rollback
                    (singleton, generation, applied_sequence, server_acknowledged_sequence)
                VALUES (1, ?, ?, ?)
                """,
                arguments: [
                    try Self.storageInteger(previous.generation),
                    try Self.storageInteger(previous.appliedSequence),
                    try Self.storageInteger(previous.serverAcknowledgedSequence),
                ]
            )
            try Self.writeCursor(try .init(
                state: .resetPending,
                generation: reset.generation,
                appliedSequence: previous.appliedSequence,
                serverAcknowledgedSequence: previous.serverAcknowledgedSequence,
                syncToken: previous.syncToken,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: reset
            ), db: db)
        }
    }

    public func cancelReset(_ reset: V2ClientResetRequired) throws {
        try databasePool.write { db in
            guard let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == reset,
                  let rollback = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM v2_reset_rollback WHERE singleton = 1"
                  )
            else { throw V2ClientSyncError.resetFenceMismatch }
            let restored = try V2LocalSyncCursor(
                state: .ready,
                generation: try Self.storageUnsigned(rollback["generation"] as Int64),
                appliedSequence: try Self.storageUnsigned(rollback["applied_sequence"] as Int64),
                serverAcknowledgedSequence: try Self.storageUnsigned(rollback["server_acknowledged_sequence"] as Int64),
                // A reset can expire after the capabilities that preceded it.
                // Pull without either old capability and acknowledge bounded
                // duplicate pages until the server cursor catches up.
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            try Self.dropSnapshotShadowTables(db: db)
            try db.execute(sql: "DELETE FROM v2_snapshot_import")
            try db.execute(sql: "DELETE FROM v2_reset_rollback WHERE singleton = 1")
            try Self.writeCursor(restored, db: db)
        }
    }

    public func importedSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest? {
        try databasePool.read { db in
            guard let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == reset
            else { throw V2ClientSyncError.resetFenceMismatch }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT snapshot_id, generation, base_sequence, root_digest,
                       next_sync_token, receipt, capability_profile, page_count,
                       total_items, total_bytes
                FROM v2_snapshot_import
                WHERE snapshot_id = ?
                """,
                arguments: [reset.snapshotID.rawValue]
            ) else { return nil }
            guard (row["generation"] as Int64) == (try Self.storageInteger(reset.generation)),
                  (row["base_sequence"] as Int64) == (try Self.storageInteger(reset.baseSequence)),
                  let pageCount = Int(exactly: row["page_count"] as Int64)
            else { throw V2ClientSyncError.snapshotMismatch }
            return try .init(
                reset: reset,
                rootDigest: row["root_digest"],
                pageCount: pageCount,
                totalItems: Self.storageUnsigned(row["total_items"] as Int64),
                totalBytes: Self.storageUnsigned(row["total_bytes"] as Int64),
                nextSyncToken: .init(row["next_sync_token"] as String),
                receipt: .init(row["receipt"] as String),
                capabilityProfile: row["capability_profile"]
            )
        }
    }

    public func beginSnapshotImport(_ manifest: V2ClientSnapshotManifest, initialDigest: String) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard initialDigest == V2SnapshotV3Digest.initial(
                    baseSequence: manifest.reset.baseSequence,
                    capabilityProfile: manifest.capabilityProfile
                  ),
                  let cursor = try Self.readCursor(db),
                  cursor.pendingReset == manifest.reset,
                  cursor.state == .resetPending
            else { throw V2ClientSyncError.resetFenceMismatch }

            if try Self.matchesSnapshotImport(manifest, db: db) {
                guard try Self.snapshotShadowTablesExist(db: db) else {
                    throw V2ClientSyncError.snapshotProjectionConflict
                }
                return
            }
            guard cursor.state == .resetPending,
                  try Row.fetchOne(db, sql: "SELECT 1 FROM v2_snapshot_import LIMIT 1") == nil
            else { throw V2ClientSyncError.snapshotMismatch }

            try Self.dropSnapshotShadowTables(db: db)
            try Self.dropRetiredSnapshotTables(db: db)
            try Self.createSnapshotShadowTables(db: db)
            try db.execute(
                sql: """
                INSERT INTO v2_snapshot_import
                    (snapshot_id, generation, base_sequence, root_digest,
                     next_sync_token, receipt, capability_profile, page_count,
                     total_items, total_bytes, rolling_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    manifest.reset.snapshotID.rawValue,
                    try Self.storageInteger(manifest.reset.generation),
                    try Self.storageInteger(manifest.reset.baseSequence),
                    manifest.rootDigest,
                    manifest.nextSyncToken.rawValue,
                    manifest.receipt.rawValue,
                    manifest.capabilityProfile,
                    manifest.pageCount,
                    try Self.storageInteger(manifest.totalItems),
                    try Self.storageInteger(manifest.totalBytes),
                    initialDigest,
                ]
            )
        }
    }

    public func nextSnapshotPageIndex(for manifest: V2ClientSnapshotManifest) throws -> Int {
        try databasePool.read { db in
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.pendingReset == manifest.reset,
                  cursor.state == .resetPending,
                  let index: Int = try Row.fetchOne(
                    db,
                    sql: "SELECT next_page_index FROM v2_snapshot_import WHERE snapshot_id = ?",
                    arguments: [manifest.reset.snapshotID.rawValue]
                  )?["next_page_index"],
                  (0 ... manifest.pageCount).contains(index)
            else { throw V2ClientSyncError.snapshotMismatch }
            return index
        }
    }

    public func applySnapshotPage(_ page: V2ClientSnapshotPage, for manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == manifest.reset,
                  let state = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT next_page_index, rolling_digest, last_projection_kind,
                           last_entity_key, applied_items, applied_bytes
                    FROM v2_snapshot_import
                    WHERE snapshot_id = ?
                    """,
                    arguments: [manifest.reset.snapshotID.rawValue]
                  )
            else { throw V2ClientSyncError.snapshotMismatch }

            let expectedIndex: Int = state["next_page_index"]
            let previousDigest: String = state["rolling_digest"]
            let lastKind: String? = state["last_projection_kind"]
            let lastEntity: String? = state["last_entity_key"]
            let appliedItems: Int64 = state["applied_items"]
            let appliedBytes: Int64 = state["applied_bytes"]
            guard expectedIndex >= 0, appliedItems >= 0, appliedBytes >= 0,
                  page.index == expectedIndex,
                  page.index < manifest.pageCount,
                  V2SnapshotV3Digest.page(page.payload) == page.digest
            else { throw V2ClientSyncError.snapshotMismatch }

            let decoded: V2SnapshotProjectionV3Page
            do { decoded = try V2SnapshotProjectionV3Codec.decode(page.payload) }
            catch { throw V2ClientSyncError.snapshotProjectionConflict }
            let followsPreviousPage: Bool
            switch (lastKind, lastEntity) {
            case (nil, nil):
                followsPreviousPage = true
            case let (.some(kind), .some(entity)):
                followsPreviousPage = try V2SnapshotProjectionKey(
                    projectionKind: kind,
                    entityKey: entity
                ) < decoded.firstKey
            default:
                followsPreviousPage = false
            }
            guard decoded.items.count == page.itemCount,
                  decoded.firstKey == page.firstKey,
                  decoded.lastKey == page.lastKey,
                  followsPreviousPage
            else { throw V2ClientSyncError.snapshotProjectionConflict }
            for item in decoded.items {
                guard item.sequence <= manifest.reset.baseSequence else {
                    throw V2ClientSyncError.snapshotProjectionConflict
                }
            }

            let nextDigest = V2SnapshotV3Digest.next(
                previous: previousDigest,
                pageIndex: UInt32(page.index),
                pageDigest: page.digest,
                firstKey: page.firstKey,
                lastKey: page.lastKey,
                itemCount: UInt32(page.itemCount)
            )
            guard let nextItemCount = Int64(exactly: decoded.items.count).flatMap({ appliedItems.addingReportingOverflow($0).overflow ? nil : appliedItems + $0 }),
                  let pageByteCount = Int64(exactly: page.payload.count),
                  !appliedBytes.addingReportingOverflow(pageByteCount).overflow
            else { throw V2ClientSyncError.storageRangeExceeded }
            let nextByteCount = appliedBytes + pageByteCount
            guard UInt64(nextItemCount) <= manifest.totalItems,
                  UInt64(nextByteCount) <= manifest.totalBytes
            else { throw V2ClientSyncError.snapshotProjectionConflict }

            for item in decoded.items {
                try Self.applySnapshotItem(item, db: db)
            }

            try db.execute(
                sql: """
                UPDATE v2_snapshot_import
                SET next_page_index = ?, rolling_digest = ?,
                    last_projection_kind = ?, last_entity_key = ?,
                    applied_items = ?, applied_bytes = ?
                WHERE snapshot_id = ? AND next_page_index = ?
                """,
                arguments: [
                    expectedIndex + 1,
                    nextDigest,
                    page.lastKey.projectionKind,
                    page.lastKey.entityKey,
                    nextItemCount,
                    nextByteCount,
                    manifest.reset.snapshotID.rawValue,
                    expectedIndex,
                ]
            )
            guard db.changesCount == 1 else { throw V2ClientSyncError.snapshotMismatch }
        }
    }

    public func activateAcknowledgedSnapshot(_ manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == manifest.reset,
                  try Row.fetchOne(db, sql: "SELECT 1 FROM v2_reset_rollback WHERE singleton = 1") != nil,
                  try Bool.fetchOne(
                    db,
                    sql: "SELECT activation_prepared FROM v2_snapshot_import WHERE snapshot_id = ?",
                    arguments: [manifest.reset.snapshotID.rawValue]
                  ) == true
            else { throw V2ClientSyncError.snapshotMismatch }

            guard let state = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT next_page_index, rolling_digest, applied_items, applied_bytes
                    FROM v2_snapshot_import WHERE snapshot_id = ?
                    """,
                    arguments: [manifest.reset.snapshotID.rawValue]
                  ),
                  (state["next_page_index"] as Int) == manifest.pageCount,
                  (state["rolling_digest"] as String) == manifest.rootDigest,
                  UInt64(exactly: state["applied_items"] as Int64) == manifest.totalItems,
                  UInt64(exactly: state["applied_bytes"] as Int64) == manifest.totalBytes
            else { throw V2ClientSyncError.snapshotMismatch }

            // Every data-proportional copy, filter, derived-table rebuild and
            // index build completed before the server ACK. This transaction
            // performs a fixed number of schema renames plus the generation
            // fence; it does not scan projection rows or amplify them into WAL.
            let triggers = try Self.suspendApplicationTriggers(db: db)
            for table in Self.snapshotOrdinaryBankTables {
                try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(Self.snapshotRetiredTable(for: table))")
                try db.execute(sql: "ALTER TABLE \(Self.snapshotShadowTable(for: table)) RENAME TO \(table)")
            }
            try db.execute(
                sql: "ALTER TABLE v2_contact_profile_search RENAME TO \(Self.snapshotRetiredTable(for: "v2_contact_profile_search"))"
            )
            try db.execute(
                sql: "ALTER TABLE \(Self.snapshotShadowTable(for: "v2_contact_profile_search")) RENAME TO v2_contact_profile_search"
            )
            try Self.restoreApplicationTriggers(triggers, db: db)

            try db.execute(
                sql: """
                INSERT INTO v2_snapshots
                    (singleton, snapshot_id, generation, base_sequence,
                     root_digest, next_sync_token, acknowledgement_receipt)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    snapshot_id = excluded.snapshot_id,
                    generation = excluded.generation,
                    base_sequence = excluded.base_sequence,
                    root_digest = excluded.root_digest,
                    next_sync_token = excluded.next_sync_token,
                    acknowledgement_receipt = excluded.acknowledgement_receipt
                """,
                arguments: [
                    manifest.reset.snapshotID.rawValue,
                    try Self.storageInteger(manifest.reset.generation),
                    try Self.storageInteger(manifest.reset.baseSequence),
                    manifest.rootDigest,
                    manifest.nextSyncToken.rawValue,
                    manifest.receipt.rawValue,
                ]
            )
            try Self.writeCursor(try .init(
                state: .ready,
                generation: manifest.reset.generation,
                appliedSequence: manifest.reset.baseSequence,
                serverAcknowledgedSequence: manifest.reset.baseSequence,
                syncToken: manifest.nextSyncToken,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            ), db: db)
            try db.execute(sql: "DELETE FROM v2_sync_rebuild_requests")
            try db.execute(sql: "DELETE FROM v2_snapshot_import WHERE snapshot_id = ?", arguments: [manifest.reset.snapshotID.rawValue])
            try db.execute(sql: "DELETE FROM v2_reset_rollback WHERE singleton = 1")
        }
    }

    public func prepareSnapshotActivation(_ manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == manifest.reset,
                  let state = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT next_page_index, rolling_digest, applied_items,
                           applied_bytes, activation_prepared
                    FROM v2_snapshot_import WHERE snapshot_id = ?
                    """,
                    arguments: [manifest.reset.snapshotID.rawValue]
                  ),
                  (state["next_page_index"] as Int) == manifest.pageCount,
                  (state["rolling_digest"] as String) == manifest.rootDigest,
                  UInt64(exactly: state["applied_items"] as Int64) == manifest.totalItems,
                  UInt64(exactly: state["applied_bytes"] as Int64) == manifest.totalBytes
            else { throw V2ClientSyncError.snapshotMismatch }
            if state["activation_prepared"] as Bool { return }

            try Self.prepareDeviceOwnedIdentityShadow(db: db)
            // Direct-room eligibility is represented by the device identity
            // shadow, so it must be prepared (and invalidations applied)
            // before deciding which independent room-log cursors survive.
            try Self.preserveRoomLogProjection(inSnapshotShadows: db)
            try Self.rebuildConversationSummaries(
                messages: Self.snapshotShadowTable(for: "v2_message_projections"),
                summaries: Self.snapshotShadowTable(for: "v2_conversation_summaries"),
                db: db
            )
            try Self.rebuildConversationListEntries(
                messages: Self.snapshotShadowTable(for: "v2_message_projections"),
                summaries: Self.snapshotShadowTable(for: "v2_conversation_summaries"),
                roomProfiles: Self.snapshotShadowTable(for: "v2_room_profile_projections"),
                directProfiles: Self.snapshotShadowTable(for: "v2_direct_room_profile_projections"),
                directIdentities: Self.snapshotShadowTable(for: "v2_direct_room_identities"),
                conversationStates: Self.snapshotShadowTable(for: "v2_conversation_states"),
                entries: Self.snapshotShadowTable(for: "v2_conversation_list_entries"),
                db: db
            )
            try Self.prepareContactSearchShadow(db: db)
            try Self.prepareMessageSearchControlShadow(db: db)
            try Self.createSnapshotShadowIndexes(db: db)
            try db.execute(
                sql: "UPDATE v2_snapshot_import SET activation_prepared = 1 WHERE snapshot_id = ?",
                arguments: [manifest.reset.snapshotID.rawValue]
            )
            guard db.changesCount == 1 else { throw V2ClientSyncError.snapshotMismatch }
        }
    }

    public func cleanupRetiredSnapshotTables() throws {
        try databasePool.write { db in
            guard try Self.readCursor(db)?.state == .ready else { return }
            try Self.dropRetiredSnapshotTables(db: db)
        }
    }

    private static let snapshotProjectionTables = [
        "v2_message_projections",
        "v2_message_tombstones",
        "v2_message_effects",
        "v2_message_reactions",
        "v2_reaction_versions",
        "v2_reaction_effects",
        "v2_moderation_projections",
        "v2_room_control_projections",
        "v2_room_profile_projections",
        "v2_direct_room_profile_projections",
        "v2_direct_read_receipt_projections",
        "v2_read_receipt_preference",
        "v2_profile_views",
        "v2_profile_invalidations",
        "v2_relationship_projections",
        "v2_user_block_projections",
        "v2_stranger_message_preference",
        "v2_user_add_preference",
        "v2_conversation_states",
        "v2_message_favorites",
        "v2_timeline_activity_projections",
        "v2_direct_sending_capabilities",
        "v2_group_pinned_messages",
        "v2_pin_effects",
        "v2_group_announcements",
        "v2_announcement_effects",
        "v2_group_role_policies",
        "v2_group_role_policy_baselines",
        "v2_role_policy_effects",
        "v2_group_member_roles",
        "v2_group_permission_revisions",
    ]

    /// These tables form one atomically swappable local projection bank. The
    /// device-owned identity cache is copied with authoritative invalidations
    /// applied, while sync events and search jobs intentionally start empty.
    private static let snapshotOrdinaryBankTables = snapshotProjectionTables + [
        "v2_group_events",
        "v2_group_event_cursors",
        "v2_conversation_summaries",
        "v2_conversation_list_entries",
        "v2_direct_room_identities",
        "v2_sync_events",
        "v2_message_search_jobs",
        "v2_message_search_state",
    ]

    private static let snapshotVirtualBankTables = ["v2_contact_profile_search"]

    /// A Snapshot V3 artifact is the canonical baseline for the per-user sync
    /// stream. Room-log history has its own durable cursor, so replacing its
    /// rows would leave the cursor ahead of visible projections. Preserve only
    /// room-log rooms that remain represented in the incoming baseline; a
    /// removed group membership or a revoked direct identity therefore drops
    /// its local event history instead of granting it new read authority.
    private static func preserveRoomLogProjection(inSnapshotShadows db: Database) throws {
        let shadowRooms = snapshotShadowTable(for: "v2_room_profile_projections")
        let shadowDirectProfiles = snapshotShadowTable(for: "v2_direct_room_profile_projections")
        let shadowDirectIdentities = snapshotShadowTable(for: "v2_direct_room_identities")
        let shadowMessages = snapshotShadowTable(for: "v2_message_projections")
        let shadowTombstones = snapshotShadowTable(for: "v2_message_tombstones")
        let shadowReactions = snapshotShadowTable(for: "v2_message_reactions")
        let shadowModeration = snapshotShadowTable(for: "v2_moderation_projections")
        let shadowRoomControl = snapshotShadowTable(for: "v2_room_control_projections")
        let shadowTimeline = snapshotShadowTable(for: "v2_timeline_activity_projections")
        let shadowAnnouncements = snapshotShadowTable(for: "v2_group_announcements")
        let shadowRolePolicies = snapshotShadowTable(for: "v2_group_role_policies")
        let shadowMemberRoles = snapshotShadowTable(for: "v2_group_member_roles")
        let shadowPermissionRevisions = snapshotShadowTable(for: "v2_group_permission_revisions")
        let hybridMode = V2GroupDeliveryMode.largeGroupHybrid.rawValue

        func copyRoomRows(table: String, shadow: String) throws {
            try db.execute(sql: """
                WITH room_log_rooms AS (
                    SELECT room_id
                    FROM \(shadowRooms)
                    WHERE delivery_mode = ? AND is_group_event_authorized = 1
                    UNION
                    SELECT direct.room_id
                    FROM (
                        SELECT room_id FROM \(shadowDirectProfiles)
                        UNION
                        SELECT room_id FROM \(shadowDirectIdentities)
                    ) AS direct
                    LEFT JOIN v2_room_event_authorizations AS authorization
                      ON authorization.room_id = direct.room_id
                    WHERE COALESCE(authorization.is_authorized, 1) = 1
                )
                INSERT INTO \(shadow)
                SELECT live.*
                FROM \(table) AS live
                JOIN room_log_rooms AS room ON room.room_id = live.room_id
                ON CONFLICT DO NOTHING
                """, arguments: [hybridMode])
        }

        try copyRoomRows(table: "v2_message_projections", shadow: shadowMessages)
        try db.execute(sql: """
            INSERT INTO \(shadowTombstones)
            SELECT tombstone.*
            FROM v2_message_tombstones AS tombstone
            JOIN \(shadowMessages) AS message ON message.message_id = tombstone.message_id
            ON CONFLICT DO NOTHING
            """)
        try preserveMessageEffectsInSnapshot(db: db)
        try copyRoomRows(table: "v2_message_reactions", shadow: shadowReactions)
        try copyRoomRows(table: "v2_reaction_versions", shadow: snapshotShadowTable(for: "v2_reaction_versions"))
        try preserveReactionEffectsInSnapshot(db: db)
        try copyRoomRows(table: "v2_moderation_projections", shadow: shadowModeration)
        try copyRoomRows(table: "v2_room_control_projections", shadow: shadowRoomControl)
        try copyRoomRows(table: "v2_timeline_activity_projections", shadow: shadowTimeline)
        try preservePinnedMessagesInSnapshot(db: db)
        try copyRoomRows(table: "v2_group_announcements", shadow: shadowAnnouncements)
        try db.execute(sql: """
            INSERT INTO \(snapshotShadowTable(for: "v2_announcement_effects"))
            SELECT effect.* FROM v2_announcement_effects AS effect
            JOIN \(shadowAnnouncements) AS state ON state.room_id = effect.room_id
            WHERE effect.revision <= state.revision
              AND (effect.revision < state.revision OR
                   (effect.source_event_id = state.source_event_id AND effect.canonical_digest = state.canonical_digest))
            ON CONFLICT DO NOTHING
            """)
        let shadowPolicyBaselines = snapshotShadowTable(for: "v2_group_role_policy_baselines")
        try db.execute(sql: """
            INSERT INTO \(shadowPolicyBaselines)
            SELECT baseline.* FROM v2_group_role_policy_baselines AS baseline
            JOIN v2_room_profile_projections AS live ON live.room_id = baseline.room_id
            JOIN \(shadowRooms) AS incoming ON incoming.room_id = baseline.room_id
            WHERE live.is_group_event_authorized = 1 AND incoming.is_group_event_authorized = 1
              AND live.membership_revision = incoming.membership_revision AND live.source_event_id = incoming.source_event_id
              AND baseline.membership_revision <= incoming.membership_revision
            ON CONFLICT DO NOTHING
            """)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM \(shadowRolePolicies) AS policy JOIN \(shadowPolicyBaselines) AS baseline ON baseline.room_id = policy.room_id
                WHERE policy.revision = baseline.permission_revision AND policy.permissions <>
                    CASE policy.role WHEN 'admin' THEN baseline.admin_permissions ELSE baseline.member_permissions END
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try preserveRolePoliciesInSnapshot(db: db)
        let shadowPolicyEffects = snapshotShadowTable(for: "v2_role_policy_effects")
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM v2_role_policy_effects AS live
                LEFT JOIN \(shadowRolePolicies) AS state ON state.room_id = live.room_id AND state.role = live.role
                LEFT JOIN \(shadowPolicyBaselines) AS baseline ON baseline.room_id = live.room_id
                JOIN \(shadowPolicyEffects) AS incoming ON incoming.source_event_id = live.source_event_id AND incoming.room_id = live.room_id
                WHERE live.revision <= MAX(COALESCE(state.revision, 0), COALESCE(baseline.permission_revision, 0)) AND (
                    live.role <> incoming.role OR live.revision <> incoming.revision OR live.canonical_digest <> incoming.canonical_digest
                    OR (live.room_sequence IS NOT NULL AND incoming.room_sequence IS NOT NULL AND live.room_sequence <> incoming.room_sequence)
                )
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(shadowPolicyEffects)
            SELECT effect.* FROM v2_role_policy_effects AS effect
            LEFT JOIN \(shadowRolePolicies) AS state ON state.room_id = effect.room_id AND state.role = effect.role
            LEFT JOIN \(shadowPolicyBaselines) AS baseline ON baseline.room_id = effect.room_id
            WHERE effect.revision <= MAX(COALESCE(state.revision, 0), COALESCE(baseline.permission_revision, 0))
              AND (effect.revision <= COALESCE(baseline.permission_revision, 0) OR effect.revision < state.revision OR
                   (effect.source_event_id = state.source_event_id AND effect.canonical_digest = state.canonical_digest))
            ON CONFLICT(source_event_id, room_id) DO UPDATE SET room_sequence = COALESCE(\(shadowPolicyEffects).room_sequence, excluded.room_sequence)
            """)
        try copyRoomRows(table: "v2_group_member_roles", shadow: shadowMemberRoles)
        try copyRoomRows(table: "v2_group_permission_revisions", shadow: shadowPermissionRevisions)

        let shadowEvents = snapshotShadowTable(for: "v2_group_events")
        let shadowCursors = snapshotShadowTable(for: "v2_group_event_cursors")
        try db.execute(sql: """
            WITH room_log_rooms AS (
                SELECT room_id
                FROM \(shadowRooms)
                WHERE delivery_mode = ? AND is_group_event_authorized = 1
                UNION
                SELECT direct.room_id
                FROM (
                    SELECT room_id FROM \(shadowDirectProfiles)
                    UNION
                    SELECT room_id FROM \(shadowDirectIdentities)
                ) AS direct
                LEFT JOIN v2_room_event_authorizations AS authorization
                  ON authorization.room_id = direct.room_id
                WHERE COALESCE(authorization.is_authorized, 1) = 1
            )
            INSERT INTO \(shadowEvents)
            SELECT event.*
            FROM v2_group_events AS event
            JOIN room_log_rooms AS room ON room.room_id = event.room_id
            """, arguments: [hybridMode])
        try db.execute(sql: """
            WITH room_log_rooms AS (
                SELECT room_id
                FROM \(shadowRooms)
                WHERE delivery_mode = ? AND is_group_event_authorized = 1
                UNION
                SELECT direct.room_id
                FROM (
                    SELECT room_id FROM \(shadowDirectProfiles)
                    UNION
                    SELECT room_id FROM \(shadowDirectIdentities)
                ) AS direct
                LEFT JOIN v2_room_event_authorizations AS authorization
                  ON authorization.room_id = direct.room_id
                WHERE COALESCE(authorization.is_authorized, 1) = 1
            )
            INSERT INTO \(shadowCursors)
            SELECT cursor.*
            FROM v2_group_event_cursors AS cursor
            JOIN room_log_rooms AS room ON room.room_id = cursor.room_id
            """, arguments: [hybridMode])
    }

    private static func preserveMessageEffectsInSnapshot(db: Database) throws {
        // Keep only receipts represented by the new authoritative baseline.
        // Future effects must replay if this reset installs an older revision;
        // removed rooms must not retain claims that suppress a later rebuild.
        try db.execute(sql: """
            INSERT INTO \(snapshotShadowTable(for: "v2_message_effects"))
            SELECT effect.* FROM v2_message_effects AS effect
            JOIN \(snapshotShadowTable(for: "v2_message_projections")) AS message ON message.message_id = effect.entity_key
              AND message.room_id = effect.room_id
              AND message.message_revision >= effect.message_revision
            ON CONFLICT DO NOTHING
            """)
    }

    private static func snapshotShadowTable(for table: String) -> String {
        "v2_snapshot_shadow_" + table.dropFirst("v2_".count)
    }

    private static func snapshotRetiredTable(for table: String) -> String {
        "v2_snapshot_retired_" + table.dropFirst("v2_".count)
    }

    private static func createSnapshotShadowTable(for table: String, db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ), let createSQL: String = row["sql"] else {
            throw V2ClientSyncError.snapshotProjectionConflict
        }
        let plainPrefix = "CREATE TABLE \(table)"
        let quotedPrefix = "CREATE TABLE \"\(table)\""
        let prefix: String
        if createSQL.hasPrefix(plainPrefix) {
            prefix = plainPrefix
        } else if createSQL.hasPrefix(quotedPrefix) {
            prefix = quotedPrefix
        } else {
            throw V2ClientSyncError.snapshotProjectionConflict
        }
        let shadowSQL = "CREATE TABLE \(snapshotShadowTable(for: table))" + createSQL.dropFirst(prefix.count)
        try db.execute(sql: shadowSQL)
    }

    private static func createSnapshotShadowTables(db: Database) throws {
        for table in snapshotOrdinaryBankTables {
            try createSnapshotShadowTable(for: table, db: db)
        }
        try db.execute(sql: """
            CREATE VIRTUAL TABLE \(snapshotShadowTable(for: "v2_contact_profile_search")) USING fts5(
                display_unigrams,
                display_bigrams,
                handle_unigrams,
                handle_bigrams,
                tokenize = 'ascii',
                detail = full,
                columnsize = 0
            )
            """)
    }

    private static func dropSnapshotShadowTables(db: Database) throws {
        for table in snapshotVirtualBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotShadowTable(for: table))")
        }
        for table in snapshotOrdinaryBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotShadowTable(for: table))")
        }
    }

    private static func dropRetiredSnapshotTables(db: Database) throws {
        for table in snapshotVirtualBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotRetiredTable(for: table))")
        }
        for table in snapshotOrdinaryBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotRetiredTable(for: table))")
        }
    }

    private static func snapshotShadowTablesExist(db: Database) throws -> Bool {
        for table in snapshotOrdinaryBankTables + snapshotVirtualBankTables {
            guard try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [snapshotShadowTable(for: table)]
            ) != nil else { return false }
        }
        return true
    }

    private static func prepareDeviceOwnedIdentityShadow(db: Database) throws {
        let identities = snapshotShadowTable(for: "v2_direct_room_identities")
        let invalidations = snapshotShadowTable(for: "v2_profile_invalidations")
        try db.execute(sql: """
            INSERT INTO \(identities)
            SELECT identity.*
            FROM v2_direct_room_identities AS identity
            WHERE NOT EXISTS (
                SELECT 1 FROM \(invalidations) AS invalidation
                WHERE invalidation.user_id = identity.target_user_id
                  AND invalidation.profile_state <> ?
            )
            """, arguments: [V2ProfileState.active.rawValue])
    }

    private static func prepareContactSearchShadow(db: Database) throws {
        let search = snapshotShadowTable(for: "v2_contact_profile_search")
        let profiles = snapshotShadowTable(for: "v2_profile_views")
        try db.execute(sql: """
            INSERT INTO \(search)
                (rowid, display_unigrams, display_bigrams, handle_unigrams, handle_bigrams)
            SELECT rowid,
                   v2_contact_search_unigrams(display_name),
                   v2_contact_search_bigrams(display_name),
                   v2_contact_search_unigrams(public_handle),
                   v2_contact_search_bigrams(public_handle)
            FROM \(profiles)
            WHERE public_handle IS NOT NULL
            """)
    }

    private static func prepareMessageSearchControlShadow(db: Database) throws {
        let state = snapshotShadowTable(for: "v2_message_search_state")
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT index_version, generation FROM v2_message_search_state WHERE singleton = 1"
        ) else { throw V2ClientSyncError.snapshotProjectionConflict }
        let generation: Int64 = row["generation"]
        guard generation > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        guard generation < Int64.max else { throw V2ClientSyncError.storageRangeExceeded }
        try db.execute(
            sql: "INSERT INTO \(state) (singleton, index_version, state, generation) VALUES (1, ?, 'building', ?)",
            arguments: [row["index_version"] as Int64, generation + 1]
        )
    }

    private static func createSnapshotShadowIndexes(db: Database) throws {
        guard let snapshotID: String = try Row.fetchOne(
            db,
            sql: "SELECT snapshot_id FROM v2_snapshot_import LIMIT 1"
        )?["snapshot_id"] else { throw V2ClientSyncError.snapshotMismatch }
        let suffix = snapshotID.replacingOccurrences(of: "-", with: "")
        for table in snapshotOrdinaryBankTables {
            let shadow = snapshotShadowTable(for: table)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT name, sql FROM sqlite_master
                WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL
                ORDER BY name
                """,
                arguments: [table]
            )
            for (offset, row) in rows.enumerated() {
                let name: String = row["name"]
                let createSQL: String = row["sql"]
                let tableComponent = table.dropFirst("v2_".count)
                let shadowName = "v2_snapshot_\(suffix)_\(tableComponent)_\(offset)_idx"
                let indexToken = "INDEX \(name)"
                let plainTableToken = " ON \(table)"
                let quotedTableToken = " ON \"\(table)\""
                guard let indexRange = createSQL.range(of: indexToken, options: .caseInsensitive),
                      let tableRange = createSQL.range(of: plainTableToken, options: .caseInsensitive)
                        ?? createSQL.range(of: quotedTableToken, options: .caseInsensitive)
                else { throw V2ClientSyncError.snapshotProjectionConflict }
                var rewritten = createSQL.replacingCharacters(in: tableRange, with: " ON \(shadow)")
                guard let rewrittenIndexRange = rewritten.range(of: indexToken, options: .caseInsensitive) else {
                    throw V2ClientSyncError.snapshotProjectionConflict
                }
                rewritten.replaceSubrange(rewrittenIndexRange, with: "INDEX \(shadowName)")
                // Confirm the original range was meaningful before executing
                // dynamically reconstructed schema SQL.
                _ = indexRange
                try db.execute(sql: rewritten)
            }
        }
    }

    private static func suspendApplicationTriggers(db: Database) throws -> [(name: String, sql: String)] {
        let triggers: [(name: String, sql: String)] = try Row.fetchAll(
            db,
            sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL ORDER BY name"
        ).map { ($0["name"] as String, $0["sql"] as String) }
        for trigger in triggers {
            try db.execute(sql: "DROP TRIGGER \(trigger.name)")
        }
        return triggers
    }

    private static func restoreApplicationTriggers(
        _ triggers: [(name: String, sql: String)],
        db: Database
    ) throws {
        for trigger in triggers { try db.execute(sql: trigger.sql) }
    }

    static func requireProjectionWritesUnfenced(db: Database) throws {
        let prepared = try Bool.fetchOne(
            db,
            sql: "SELECT activation_prepared FROM v2_snapshot_import LIMIT 1"
        ) ?? false
        guard !prepared else { throw V2ClientSyncError.resetPending }
    }

    /// Explicit table routing keeps every snapshot page on ordinary DML. It
    /// avoids schema rewrites and schema-lock invalidations while the live
    /// projection remains readable throughout a resumable import.
    private enum ProjectionTableTarget {
        case live
        case snapshotShadow

        func table(_ liveName: String) -> String {
            switch self {
            case .live: liveName
            case .snapshotShadow: GRDBV2LocalSyncStore.snapshotShadowTable(for: liveName)
            }
        }
    }

    private static func applySnapshotItem(_ item: V2SnapshotProjectionItem, db: Database) throws {
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: item.payload) as? [String: Any] else {
                throw V2ClientSyncError.snapshotProjectionConflict
            }
            object = value
        } catch {
            throw V2ClientSyncError.snapshotProjectionConflict
        }
        let payloadKey = try snapshotEntityKey(kind: item.key.projectionKind, sourceEventID: item.sourceEventID, object: object)
        if payloadKey != item.key.entityKey {
            guard item.key.projectionKind == "group_capability",
                  let expected = canonicalGroupCapabilitySnapshotKey(payloadKey),
                  expected == canonicalGroupCapabilitySnapshotKey(item.key.entityKey)
            else { throw V2ClientSyncError.snapshotProjectionConflict }
        }
        let eventType = object["event_type"] as? String
        let recordKind = item.key.projectionKind == "room" && eventType == "membership_changed"
            ? "membership"
            : item.key.projectionKind
        let record = try V2ClientSyncRecord(
            sequence: item.sequence,
            sourceEventID: item.sourceEventID,
            projectionKind: recordKind,
            payload: item.payload
        )
        switch item.key.projectionKind {
        case "message": try applySnapshotMessage(record, entityKey: item.key.entityKey, db: db)
        case "message_reaction":
            try applyReaction(record, target: .snapshotShadow, db: db)
        case "moderation": try applyModeration(record, target: .snapshotShadow, db: db)
        case "relationship": try applyRelationship(record, target: .snapshotShadow, db: db)
        case "user_block": try applyUserBlock(record, target: .snapshotShadow, db: db)
        case "stranger_message_permission": try applyStrangerMessagePermission(record, target: .snapshotShadow, db: db)
        case "user_add_permission": try applyUserAddPermission(record, target: .snapshotShadow, db: db)
        case "direct_read_receipt": try applyDirectReadReceipt(record, target: .snapshotShadow, db: db)
        case "read_receipt_preferences": try applyReadReceiptPreference(record, target: .snapshotShadow, db: db)
        case "conversation_state": try persist(V2ClientConversationState(record: record), target: .snapshotShadow, db: db)
        case "message_favorite": try persist(V2ClientMessageFavorite(record: record), target: .snapshotShadow, db: db)
        case "group_capability": try applyGroupCapability(record, target: .snapshotShadow, db: db)
        case "room": try persist(V2ClientRoomProfileProjection(record: record), target: .snapshotShadow, db: db)
        case "direct_room_profile": try persist(V2ClientDirectRoomProfileProjection(record: record), target: .snapshotShadow, db: db)
        case "timeline_activity": try persist(V2ClientTimelineActivityProjection(record: record), target: .snapshotShadow, db: db)
        case "direct_sending_capability": try persist(V2ClientDirectSendingCapability(record: record), target: .snapshotShadow, db: db)
        case "profile_invalidation": try persist(V2ClientProfileInvalidation(record: record), target: .snapshotShadow, db: db)
        default: throw V2ClientSyncError.snapshotProjectionConflict
        }
    }

    private static func applySnapshotMessage(
        _ record: V2ClientSyncRecord,
        entityKey: String,
        db: Database
    ) throws {
        struct Envelope: Decodable {
            let isWithdrawn: Bool?
            enum CodingKeys: String, CodingKey {
                case isWithdrawn = "is_withdrawn"
            }
        }
        let base = try V2ClientMessageProjection(record: record)
        guard base.messageID.rawValue == entityKey,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: record.payload)
        else { throw V2ClientSyncError.snapshotProjectionConflict }
        let withdrawn = envelope.isWithdrawn ?? false
        guard !withdrawn || (
            base.messageRevision > 1
            && base.text == "[removed]"
            && base.media.isEmpty
            && base.mediaPresentations.isEmpty
            && base.mentions.isEmpty
            && base.entities.isEmpty
            && base.replyTo == nil
            && base.forwardedFrom == nil
        ) else { throw V2ClientSyncError.snapshotProjectionConflict }

        let projection = V2ClientMessageProjection(
            sourceEventID: base.sourceEventID,
            messageID: base.messageID,
            roomID: base.roomID,
            roomSequence: base.roomSequence,
            timelineSequence: base.timelineSequence,
            messageRevision: base.messageRevision,
            senderUserID: base.senderUserID,
            text: base.text,
            media: base.media,
            mediaPresentations: base.mediaPresentations,
            mentions: base.mentions,
            entities: base.entities,
            replyTo: base.replyTo,
            forwardedFrom: base.forwardedFrom,
            createdAt: base.createdAt,
            isWithdrawn: withdrawn
        )
        try persist(
            projection, updateConversationSummary: false,
            enqueueSearchIndex: false, target: .snapshotShadow, db: db
        )
        if withdrawn {
            let tombstones = ProjectionTableTarget.snapshotShadow.table("v2_message_tombstones")
            try db.execute(
                sql: """
                INSERT INTO \(tombstones)
                    (message_id, source_event_id, room_id, message_revision)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    base.messageID.rawValue,
                    base.sourceEventID.rawValue,
                    base.roomID.rawValue,
                    try storageInteger(base.messageRevision),
                ]
            )
            return
        }
    }

    /// PostgreSQL and Foundation may spell the same UUID differently. Only
    /// identity segments are normalized; kind and role names remain exact.
    private static func canonicalGroupCapabilitySnapshotKey(_ value: String) -> String? {
        var parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let identityIndices: [Int]
        switch parts.first {
        case "announcement" where parts.count == 2: identityIndices = [1]
        case "permissions" where parts.count == 3: identityIndices = [1]
        case "pin", "member-role":
            guard parts.count == 3 else { return nil }
            identityIndices = [1, 2]
        default: return nil
        }
        for index in identityIndices {
            guard let id = UUID(uuidString: parts[index]) else { return nil }
            parts[index] = id.uuidString
        }
        return parts.joined(separator: ":")
    }

    private static func snapshotEntityKey(
        kind: String,
        sourceEventID: EventID,
        object: [String: Any]
    ) throws -> String {
        func string(_ name: String) throws -> String {
            guard let value = object[name] as? String, !value.isEmpty else {
                throw V2ClientSyncError.snapshotProjectionConflict
            }
            return value
        }
        let eventType = object["event_type"] as? String
        switch kind {
        case "message": return try string("message_id")
        case "message_reaction":
            return try string("message_id") + ":" + string("actor_user_id") + ":" + string("reaction")
        case "room": return try string("room_id")
        case "moderation":
            let room = try string("room_id")
            return eventType == "room.frozen" || eventType == "room.unfrozen"
                ? room
                : room + ":" + (try string("target_user_id"))
        case "relationship", "user_block": return try string("target_user_id")
        case "stranger_message_permission", "user_add_permission", "read_receipt_preferences": return "singleton"
        case "direct_room_profile", "direct_read_receipt", "conversation_state", "direct_sending_capability":
            return try string("room_id")
        case "message_favorite": return try string("message_id")
        case "timeline_activity": return sourceEventID.rawValue
        case "profile_invalidation": return try string("user_id")
        case "group_capability":
            let room = try string("room_id")
            switch eventType {
            case "message.pinned_changed": return "pin:\(room):\(try string("message_id"))"
            case "group.announcement_changed": return "announcement:\(room)"
            case "group.role_permissions_changed": return "permissions:\(room):\(try string("role"))"
            case "group.member_role_changed": return "member-role:\(room):\(try string("target_user_id"))"
            default: throw V2ClientSyncError.snapshotProjectionConflict
            }
        default: throw V2ClientSyncError.snapshotProjectionConflict
        }
    }

    private static func rebuildConversationListEntries(
        messages: String = "v2_message_projections",
        summaries: String = "v2_conversation_summaries",
        roomProfiles: String = "v2_room_profile_projections",
        directProfiles: String = "v2_direct_room_profile_projections",
        directIdentities: String = "v2_direct_room_identities",
        conversationStates: String = "v2_conversation_states",
        entries: String = "v2_conversation_list_entries",
        db: Database
    ) throws {
        try db.execute(sql: """
            DELETE FROM \(entries);
            WITH all_rooms AS (
                SELECT room_id FROM \(summaries)
                UNION SELECT room_id FROM \(roomProfiles)
                UNION SELECT room_id FROM \(directProfiles)
                UNION SELECT room_id FROM \(directIdentities)
            )
            INSERT INTO \(entries)
                (room_id, last_activity, is_pinned, is_archived, mute_until)
            SELECT all_rooms.room_id,
                   COALESCE(
                       (SELECT message.server_created_at
                        FROM \(summaries) AS summary
                        JOIN \(messages) AS message
                          ON message.message_id = summary.message_id
                        WHERE summary.room_id = all_rooms.room_id),
                       (SELECT created_at FROM \(roomProfiles)
                        WHERE room_id = all_rooms.room_id),
                       (SELECT updated_at FROM \(directProfiles)
                        WHERE room_id = all_rooms.room_id),
                       (SELECT updated_at FROM \(directIdentities)
                        WHERE room_id = all_rooms.room_id)
                   ),
                   COALESCE(state.is_pinned, 0),
                   COALESCE(state.is_archived, 0),
                   COALESCE(state.mute_until, 0)
            FROM all_rooms
            LEFT JOIN \(conversationStates) AS state
              ON state.room_id = all_rooms.room_id
            """)
    }

    public func events() throws -> [V2ClientSyncRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT sequence, source_event_id, projection_kind, payload FROM v2_sync_events ORDER BY sequence").map(Self.decodeEvent)
        }
    }

    /// UI/repository code reads this durable projection rather than scanning
    /// opaque sync-event bytes on the main actor.
    public func messages(in roomID: RoomID) throws -> [V2ClientMessageProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_message_projections WHERE room_id = ? ORDER BY timeline_sequence, message_id", arguments: [roomID.rawValue]).map(Self.decodeMessageProjection)
        }
    }

    /// Reads one bounded page, including decorations, from a single snapshot.
    public func conversationTimelinePage(
        in roomID: RoomID,
        before cursor: V2ClientTimelineCursor? = nil,
        limit: Int
    ) throws -> V2ClientConversationTimelinePage {
        guard (1 ... 10_000).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try databasePool.read { db in
            let candidates = try Self.timelineCandidates(db: db, roomID: roomID, cursor: cursor, newer: false, limit: limit + 1)
            return try Self.timelinePage(db: db, roomID: roomID, selected: Array(candidates.prefix(limit).reversed()), hasOlder: candidates.count > limit)
        }
    }

    /// Message ID lookup plus two index seeks: cost and retained payload do
    /// not grow with the target's depth in room history. No OFFSET or scan of
    /// all prior pages. Account, target and decorations share one read snapshot.
    public func conversationTimelineWindow(
        in roomID: RoomID,
        for userID: UserID,
        around messageID: MessageID,
        before: Int,
        after: Int
    ) throws -> V2ClientTimelineLocation {
        guard (0..<800).contains(before), (0..<800).contains(after), before + after + 1 <= 800 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try databasePool.read { db in
            guard let storedUser = try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton = 1"),
                  storedUser == userID.rawValue || (userID.uuidValue != nil && UUID(uuidString: storedUser) == userID.uuidValue),
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ? AND room_id = ?", arguments: [messageID.rawValue, roomID.rawValue])
            else { return .unavailable }
            let revoked = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM v2_room_profile_projections WHERE room_id = ? AND is_group_event_authorized = 0
                    UNION ALL
                    SELECT 1 FROM v2_room_event_authorizations WHERE room_id = ? AND is_authorized = 0
                )
                """, arguments: [roomID.rawValue, roomID.rawValue]) ?? false
            guard !revoked else { return .unavailable }
            let target = try Self.decodeMessageProjection(row)
            guard !target.isWithdrawn else { return .withdrawn }
            let anchor = TimelinePageCandidate.message(target)
            let older = try Self.timelineCandidates(db: db, roomID: roomID, cursor: anchor.cursor, newer: false, limit: before + 1)
            let newer = try Self.timelineCandidates(db: db, roomID: roomID, cursor: anchor.cursor, newer: true, limit: after + 1)
            let selected = Array(older.prefix(before).reversed()) + [anchor] + Array(newer.prefix(after))
            let page = try Self.timelinePage(db: db, roomID: roomID, selected: selected, hasOlder: older.count > before)
            return .found(.init(page: page, newerBoundary: newer.count > after ? newer[after].cursor : nil))
        }
    }

    private static func timelineCandidates(db: Database, roomID: RoomID, cursor: V2ClientTimelineCursor?, newer: Bool, limit: Int) throws -> [TimelinePageCandidate] {
        let order = newer ? "ASC" : "DESC"
        func rows(table: String, id: String, kind: V2ClientTimelineItemKind, columns: String) throws -> [Row] {
            var predicate = ""
            var arguments: StatementArguments = [roomID.rawValue]
            if let cursor {
                // Kind is the final tie breaker when a message and a private
                // activity happen to share both their sequence and opaque ID.
                let inclusive = newer ? kind.rawValue > cursor.kind.rawValue : kind.rawValue < cursor.kind.rawValue
                let comparison = (newer ? ">" : "<") + (inclusive ? "=" : "")
                predicate = " AND (timeline_sequence, \(id)) \(comparison) (?, ?)"
                arguments += [try storageInteger(cursor.timelineSequence), cursor.itemID]
            }
            arguments += [limit]
            return try Row.fetchAll(db, sql: "SELECT \(columns) FROM \(table) WHERE room_id = ?\(predicate) ORDER BY timeline_sequence \(order), \(id) \(order) LIMIT ?", arguments: arguments)
        }
        let messages = try rows(table: "v2_message_projections", id: "message_id", kind: .message, columns: "*").map(decodeMessageProjection).map(TimelinePageCandidate.message)
        let activities = try rows(table: "v2_timeline_activity_projections", id: "source_event_id", kind: .activity, columns: "source_event_id, room_id, timeline_sequence, event_type, server_created_at").map(decodeTimelineActivity).map(TimelinePageCandidate.activity)
        return Array((messages + activities).sorted(by: newer ? TimelinePageCandidate.olderFirst : TimelinePageCandidate.newerFirst).prefix(limit))
    }

    private static func timelinePage(db: Database, roomID: RoomID, selected: [TimelinePageCandidate], hasOlder: Bool) throws -> V2ClientConversationTimelinePage {
        let messages = selected.compactMap(\.message)
        let activities = selected.compactMap(\.activity)
        let messageIDs = messages.map(\.messageID)

        let reactions: [V2ClientMessageReaction]
        let pinnedMessageIDs: Set<MessageID>
        let favoritedMessageIDs: Set<MessageID>
        if messageIDs.isEmpty {
            reactions = []
            pinnedMessageIDs = []
            favoritedMessageIDs = []
        } else {
            let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
            let messageArguments = StatementArguments(messageIDs.map(\.rawValue))
            reactions = try Row.fetchAll(
                db,
                sql: "SELECT room_id, message_id, actor_user_id, reaction FROM v2_message_reactions WHERE message_id IN (\(placeholders)) ORDER BY message_id, reaction, actor_user_id",
                arguments: messageArguments
            ).map { row in
                try .init(
                    roomID: .init(row["room_id"] as String),
                    messageID: .init(row["message_id"] as String),
                    actorUserID: .init(row["actor_user_id"] as String),
                    reaction: row["reaction"]
                )
            }
            pinnedMessageIDs = try Set(String.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_group_pinned_messages WHERE room_id = ? AND is_pinned = 1 AND message_id IN (\(placeholders))",
                arguments: StatementArguments([roomID.rawValue]) + messageArguments
            ).map(MessageID.init))
            favoritedMessageIDs = try Set(String.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_message_favorites WHERE is_favorited = 1 AND message_id IN (\(placeholders))",
                arguments: messageArguments
            ).map(MessageID.init))
        }

        let directReadReceipt: V2DirectReadReceiptProjection?
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT room_id, reader_user_id, read_through_room_sequence, recorded_at FROM v2_direct_read_receipt_projections WHERE room_id = ?",
            arguments: [roomID.rawValue]
        ) {
            directReadReceipt = try .init(
                roomID: .init(row["room_id"] as String),
                readerUserID: .init(row["reader_user_id"] as String),
                readThroughRoomSequence: Self.storageUnsigned(row["read_through_room_sequence"] as Int64),
                recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double),
                isVisible: true
            )
        } else {
            directReadReceipt = nil
        }

        let olderCursor = hasOlder ? selected.first.map(\.cursor) : nil
        return .init(
            messages: messages,
            activities: activities,
            reactions: reactions,
            pinnedMessageIDs: pinnedMessageIDs,
            favoritedMessageIDs: favoritedMessageIDs,
            directReadReceipt: directReadReceipt,
            olderCursor: olderCursor
        )
    }

    public func timelineActivities(in roomID: RoomID) throws -> [V2ClientTimelineActivityProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_event_id, room_id, timeline_sequence, event_type, server_created_at FROM v2_timeline_activity_projections WHERE room_id = ? ORDER BY timeline_sequence, source_event_id", arguments: [roomID.rawValue]).map(Self.decodeTimelineActivity)
        }
    }

    public func directSendingCapability(roomID: RoomID) throws -> V2ClientDirectSendingCapability? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT room_id, can_send, updated_at FROM v2_direct_sending_capabilities WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return .init(roomID: try .init(row["room_id"] as String), canSend: row["can_send"], updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
        }
    }

    public func conversationState(roomID: RoomID) throws -> V2ClientConversationState? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT room_id, is_pinned, is_archived, mute_until, updated_at FROM v2_conversation_states WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try Self.decodeConversationState(row)
        }
    }

    /// Test/diagnostic batch read. Production list rendering uses the bounded
    /// materialized conversation page below.
    func conversationStates() throws -> [RoomID: V2ClientConversationState] {
        try databasePool.read { db in
            let states = try Row.fetchAll(
                db,
                sql: "SELECT room_id, is_pinned, is_archived, mute_until, updated_at FROM v2_conversation_states"
            ).map(Self.decodeConversationState)
            return Dictionary(uniqueKeysWithValues: states.map { ($0.roomID, $0) })
        }
    }

    public func isMessageFavorited(_ messageID: MessageID) throws -> Bool {
        try databasePool.read { db in (try Bool.fetchOne(db, sql: "SELECT is_favorited FROM v2_message_favorites WHERE message_id = ?", arguments: [messageID.rawValue])) ?? false }
    }

    /// Reads the room's favorite membership in one query for timeline
    /// decoration instead of querying once for every visible message.
    public func favoritedMessageIDs(in roomID: RoomID) throws -> Set<MessageID> {
        try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_message_favorites WHERE room_id = ? AND is_favorited = 1",
                arguments: [roomID.rawValue]
            )
            return try Set(rows.map { try MessageID($0["message_id"] as String) })
        }
    }

    /// A personal collection view over already-authorized local messages.
    /// Favorites are projections, not a second message cache, so withdrawal
    /// and reset behavior stays identical to the ordinary timeline.
    public func favoritedMessages(
        before cursor: V2ClientFavoriteMessageCursor? = nil,
        limit: Int = 50
    ) throws -> V2ClientFavoriteMessagePage {
        guard (1 ... 100).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try databasePool.read { db -> V2ClientFavoriteMessagePage in
            let predicate: String
            var arguments: StatementArguments
            if let cursor {
                predicate = "AND (favorite.updated_at < ? OR (favorite.updated_at = ? AND message.message_id < ?))"
                arguments = [cursor.updatedAt.timeIntervalSince1970, cursor.updatedAt.timeIntervalSince1970, cursor.messageID.rawValue, limit + 1]
            } else {
                predicate = ""
                arguments = [limit + 1]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT message.*
                     , favorite.updated_at AS favorite_updated_at
                FROM v2_message_favorites AS favorite
                INNER JOIN v2_message_projections AS message
                    ON message.message_id = favorite.message_id
                WHERE favorite.is_favorited = 1 AND message.is_withdrawn = 0
                \(predicate)
                ORDER BY favorite.updated_at DESC, message.message_id DESC
                LIMIT ?
                """,
                arguments: arguments
            )
            let pageRows = rows.prefix(limit)
            let messages = try pageRows.map(Self.decodeMessageProjection)
            let nextCursor: V2ClientFavoriteMessageCursor? = rows.count > limit ? try pageRows.last.map { row in
                V2ClientFavoriteMessageCursor(
                    updatedAt: Date(timeIntervalSince1970: row["favorite_updated_at"] as Double),
                    messageID: try .init(row["message_id"] as String)
                )
            } : nil
            return V2ClientFavoriteMessagePage(messages: messages, nextCursor: nextCursor)
        }
    }

    /// Resolves titles only for one bounded UI page. Group projection wins for
    /// a group room; the synchronized direct profile wins over its older
    /// discovery cache for a direct room.
    public func conversationTitles(for roomIDs: [RoomID]) throws -> [RoomID: String] {
        guard roomIDs.count <= 100 else { throw V2ClientProjectionError.invalidMessagePayload }
        let unique = Array(Set(roomIDs)).sorted()
        guard !unique.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let arguments = StatementArguments(unique.map(\.rawValue))
        return try databasePool.read { db in
            var titles: [RoomID: String] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT room_id, display_name FROM v2_direct_room_identities WHERE room_id IN (\(placeholders))",
                arguments: arguments
            ) {
                titles[try .init(row["room_id"] as String)] = row["display_name"]
            }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT room_id, display_name FROM v2_direct_room_profile_projections WHERE room_id IN (\(placeholders))",
                arguments: arguments
            ) {
                titles[try .init(row["room_id"] as String)] = row["display_name"]
            }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT room_id, title FROM v2_room_profile_projections WHERE room_id IN (\(placeholders))",
                arguments: arguments
            ) {
                titles[try .init(row["room_id"] as String)] = row["title"]
            }
            return titles
        }
    }

    /// The latest room-scoped announcement is a materialized sync projection,
    /// not a cached response from the command that happened to create it.
    public func groupAnnouncement(roomID: RoomID) throws -> V2ClientGroupAnnouncement? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT room_id, body, revision, updated_at FROM v2_group_announcements WHERE room_id = ?",
                arguments: [roomID.rawValue]
            ) else { return nil }
            return try .init(
                roomID: .init(row["room_id"] as String),
                body: row["body"],
                revision: try Self.storageUnsigned(row["revision"] as Int64),
                updatedAt: .init(timeIntervalSince1970: row["updated_at"] as Double)
            )
        }
    }

    public func pinnedMessageIDs(roomID: RoomID) throws -> Set<MessageID> {
        try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_group_pinned_messages WHERE room_id = ? AND is_pinned = 1",
                arguments: [roomID.rawValue]
            )
            return try Set(rows.map { try MessageID($0["message_id"] as String) })
        }
    }

    /// Records a retryable intent without modifying messages, cursors or outbox.
    public func requestRolePolicyBaseline(roomID: RoomID) throws -> V2RolePolicyRecoveryRequest {
        try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            return try Self.enqueueRolePolicyRecovery(roomID: roomID, db: db)
        }
    }

    /// Bounded discovery for the recovery runner. Already queued, current
    /// requests are excluded so subsequent pages can reach the other rooms.
    public func enqueueMissingRolePolicyBaselines(limit: Int = 32) throws -> Int {
        guard (1 ... 100).contains(limit) else { throw V2RolePolicyRecoveryError.invalidLimit }
        return try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            guard try Self.boundRolePolicyRecoveryAccount(db: db) != nil else { throw V2RolePolicyRecoveryError.accountUnavailable }
            try db.execute(sql: """
                DELETE FROM v2_role_policy_recovery_requests WHERE room_id IN (
                    SELECT request.room_id FROM v2_role_policy_recovery_requests AS request
                    LEFT JOIN v2_room_profile_projections AS room ON room.room_id = request.room_id AND room.is_group_event_authorized = 1
                    WHERE room.room_id IS NULL ORDER BY request.room_id LIMIT ?
                )
                """, arguments: [limit])
            let rooms = try String.fetchAll(db, sql: """
                SELECT room.room_id FROM v2_room_profile_projections AS room
                LEFT JOIN v2_group_role_policy_baselines AS baseline ON baseline.room_id = room.room_id
                LEFT JOIN v2_role_policy_recovery_requests AS request ON request.room_id = room.room_id
                JOIN v2_local_installation AS account ON account.singleton = 1
                WHERE room.is_group_event_authorized = 1
                  AND ((baseline.room_id IS NULL AND request.room_id IS NULL) OR request.membership_revision <> room.membership_revision
                       OR request.membership_source_event_id <> room.source_event_id
                       OR request.generation <> COALESCE((SELECT generation FROM v2_sync_cursor WHERE singleton = 1), 1)
                       OR request.installation_binding <> account.binding OR request.user_id <> account.user_id)
                ORDER BY room.room_id LIMIT ?
                """, arguments: [limit])
            for room in rooms { _ = try Self.enqueueRolePolicyRecovery(roomID: .init(room), db: db) }
            return rooms.count
        }
    }

    public func pendingRolePolicyBaselineRequests(limit: Int = 32) throws -> [V2RolePolicyRecoveryRequest] {
        guard (1 ... 100).contains(limit) else { throw V2RolePolicyRecoveryError.invalidLimit }
        return try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_role_policy_recovery_requests ORDER BY room_id LIMIT ?", arguments: [limit]).map(Self.decodeRolePolicyRecoveryRequest)
        }
    }

    public func dueRolePolicyBaselineRequests(at date: Date, limit: Int = 32) throws -> [V2RolePolicyRecoveryRequest] {
        guard (1 ... 100).contains(limit), date.timeIntervalSince1970.isFinite else { throw V2RolePolicyRecoveryError.invalidLimit }
        return try databasePool.read { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            return try Row.fetchAll(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY next_attempt_at, room_id LIMIT ?", arguments: [date.timeIntervalSince1970, limit]).map(Self.decodeRolePolicyRecoveryRequest)
        }
    }

    public func resumeRolePolicyBaseline(roomID: RoomID) throws -> V2RolePolicyRecoveryRequest {
        try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue])
            return try Self.enqueueRolePolicyRecovery(roomID: roomID, db: db)
        }
    }

    @discardableResult
    public func recordRolePolicyRecoveryFailure(_ disposition: V2RolePolicyRecoveryDisposition, for request: V2RolePolicyRecoveryRequest) throws -> Bool {
        try Task.checkCancellation()
        return try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            guard try Self.matchesRolePolicyRecoveryRequest(request, db: db) else { return false }
            switch disposition {
            case .unauthorized:
                try db.execute(sql: "UPDATE v2_room_profile_projections SET is_group_event_authorized = 0 WHERE room_id = ?", arguments: [request.roomID.rawValue])
                try db.execute(sql: "DELETE FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [request.roomID.rawValue])
                try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [request.roomID.rawValue])
            case .pause:
                try db.execute(sql: "UPDATE v2_role_policy_recovery_requests SET state = 'paused', attempt_count = MIN(attempt_count + 1, 2147483647) WHERE room_id = ?", arguments: [request.roomID.rawValue])
            case .retry(let date):
                guard date.timeIntervalSince1970.isFinite else { throw V2RolePolicyRecoveryError.invalidBaseline }
                try db.execute(sql: "UPDATE v2_role_policy_recovery_requests SET next_attempt_at = ?, attempt_count = MIN(attempt_count + 1, 2147483647) WHERE room_id = ?", arguments: [date.timeIntervalSince1970, request.roomID.rawValue])
            }
            return true
        }
    }

    /// False means the request was superseded or its local fences changed.
    /// No state is then changed; a runner can discover a fresh request.
    @discardableResult
    public func completeRolePolicyBaseline(_ baseline: V2GroupRolePolicyBaseline, for request: V2RolePolicyRecoveryRequest) throws -> Bool {
        try Task.checkCancellation()
        return try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            guard try Self.matchesRolePolicyRecoveryRequest(request, db: db) else { return false }
            guard baseline.roomID == request.roomID, baseline.membershipRevision >= UInt64(request.membershipRevision) else { throw V2RolePolicyRecoveryError.invalidBaseline }
            let admin = try Self.encodeRolePolicyPermissions(baseline.adminPermissions)
            let member = try Self.encodeRolePolicyPermissions(baseline.memberPermissions)
            let revision = Int64(baseline.permissionRevision)
            let previous = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [request.roomID.rawValue])
            if let previous, (previous["permission_revision"] as Int64) == revision {
                guard (previous["admin_permissions"] as Data) == admin, (previous["member_permissions"] as Data) == member else { throw V2RolePolicyRecoveryError.invalidBaseline }
            }
            let previousRevision = (previous?["permission_revision"] as Int64?) ?? 0
            guard previousRevision <= revision else { return false }
            var replaceObservation = true
            if let previous, replaceObservation {
                let previousMembership: Int64 = previous["membership_revision"]
                let previousSequence: Int64 = previous["room_sequence"]
                let membership = Int64(baseline.membershipRevision)
                let sequence = Int64(baseline.roomSequence)
                if previousRevision == revision, membership <= previousMembership, sequence <= previousSequence {
                    replaceObservation = false
                } else {
                    guard membership >= previousMembership, sequence >= previousSequence else { throw V2RolePolicyRecoveryError.invalidBaseline }
                }
            }
            if replaceObservation {
                for (role, permissions) in [("admin", admin), ("member", member)] {
                    if let observed = try Data.fetchOne(db, sql: "SELECT permissions FROM v2_group_role_policies WHERE room_id = ? AND role = ? AND revision = ?", arguments: [request.roomID.rawValue, role, revision]), observed != permissions {
                        throw V2RolePolicyRecoveryError.invalidBaseline
                    }
                }
                try db.execute(sql: """
                    INSERT INTO v2_group_role_policy_baselines (room_id, permission_revision, membership_revision, room_sequence, admin_permissions, member_permissions)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(room_id) DO UPDATE SET permission_revision = excluded.permission_revision,
                        membership_revision = excluded.membership_revision,
                        room_sequence = excluded.room_sequence,
                        admin_permissions = excluded.admin_permissions, member_permissions = excluded.member_permissions
                    """, arguments: [request.roomID.rawValue, revision, Int64(baseline.membershipRevision), Int64(baseline.roomSequence), admin, member])
            }
            try db.execute(sql: "INSERT INTO v2_group_permission_revisions (room_id, revision) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET revision = MAX(v2_group_permission_revisions.revision, excluded.revision)", arguments: [request.roomID.rawValue, revision])
            try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ? AND request_id = ?", arguments: [request.roomID.rawValue, request.requestID.uuidString])
            return true
        }
    }

    private static func matchesRolePolicyRecoveryRequest(_ request: V2RolePolicyRecoveryRequest, db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [request.roomID.rawValue]),
                  try Self.decodeRolePolicyRecoveryRequest(row) == request,
                  let account = try Self.boundRolePolicyRecoveryAccount(db: db),
                  account.binding == request.installationBinding, account.user == request.userID,
                  let room = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_profile_projections WHERE room_id = ? AND is_group_event_authorized = 1", arguments: [request.roomID.rawValue]),
                  (room["membership_revision"] as Int64) == request.membershipRevision,
                  (room["source_event_id"] as String) == request.membershipSourceEventID,
                  (try Self.readCursor(db)?.generation ?? 1) == UInt64(request.generation)
            else { return false }
        return true
    }

    private static func requireRolePolicyRecoveryReady(db: Database) throws {
        try requireProjectionWritesUnfenced(db: db)
        if let cursor = try readCursor(db), cursor.state != .ready { throw V2ClientSyncError.resetPending }
    }

    private static func boundRolePolicyRecoveryAccount(db: Database) throws -> (binding: String, user: UserID)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1"),
              let user: String = row["user_id"] else { return nil }
        return (row["binding"], try UserID(user))
    }

    private static func enqueueRolePolicyRecovery(roomID: RoomID, db: Database) throws -> V2RolePolicyRecoveryRequest {
        guard let account = try boundRolePolicyRecoveryAccount(db: db) else { throw V2RolePolicyRecoveryError.accountUnavailable }
        guard let room = try Row.fetchOne(db, sql: "SELECT membership_revision, source_event_id FROM v2_room_profile_projections WHERE room_id = ? AND is_group_event_authorized = 1", arguments: [roomID.rawValue]) else { throw V2RolePolicyRecoveryError.roomUnauthorized }
        let generation = try storageInteger(readCursor(db)?.generation ?? 1)
        let membership: Int64 = room["membership_revision"]
        let source: String = room["source_event_id"]
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue]) {
            let previous = try decodeRolePolicyRecoveryRequest(row)
            if previous.installationBinding == account.binding, previous.userID == account.user,
               previous.membershipRevision == membership, previous.membershipSourceEventID == source, previous.generation == generation { return previous }
        }
        let request = V2RolePolicyRecoveryRequest(roomID: roomID, requestID: UUID(), installationBinding: account.binding, userID: account.user, membershipRevision: membership, membershipSourceEventID: source, generation: generation, attemptCount: 0)
        try db.execute(sql: """
            INSERT INTO v2_role_policy_recovery_requests (room_id, request_id, installation_binding, user_id, membership_revision, membership_source_event_id, generation)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET request_id = excluded.request_id, installation_binding = excluded.installation_binding,
                user_id = excluded.user_id, membership_revision = excluded.membership_revision,
                membership_source_event_id = excluded.membership_source_event_id, generation = excluded.generation, attempt_count = 0, next_attempt_at = 0, state = 'pending'
            """, arguments: [roomID.rawValue, request.requestID.uuidString, account.binding, account.user.rawValue, membership, source, generation])
        return request
    }

    private static func decodeRolePolicyRecoveryRequest(_ row: Row) throws -> V2RolePolicyRecoveryRequest {
        let attemptValue: DatabaseValue = row["attempt_count"]
        let membershipValue: DatabaseValue = row["membership_revision"]
        let generationValue: DatabaseValue = row["generation"]
        guard case .int64(let attemptCount) = attemptValue.storage,
              case .int64(let membershipRevision) = membershipValue.storage,
              case .int64(let generation) = generationValue.storage,
              membershipRevision > 0, generation > 0,
              (0...Int64(Int32.max)).contains(attemptCount),
              let id = UUID(uuidString: row["request_id"] as String) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try .init(roomID: .init(row["room_id"] as String), requestID: id, installationBinding: row["installation_binding"], userID: .init(row["user_id"] as String), membershipRevision: membershipRevision, membershipSourceEventID: row["membership_source_event_id"], generation: generation, attemptCount: Int(attemptCount))
    }

    private static func encodeRolePolicyPermissions(_ permissions: Set<V2GroupPermission>) throws -> Data {
        try JSONEncoder().encode(permissions.map(\.rawValue).sorted())
    }

    /// Missing roles remain unknown until an event or a complete owner
    /// observation establishes their value. Baselines do not invent events.
    public func groupRolePolicies(roomID: RoomID) throws -> [V2ClientGroupRolePolicy] {
        try databasePool.read { try Self.readGroupRolePolicies(roomID: roomID, db: $0) }
    }

    public func groupRolePolicyState(roomID: RoomID) throws -> V2ClientGroupRolePolicyState {
        try databasePool.read { db in
            guard try Self.boundRolePolicyRecoveryAccount(db: db) != nil,
                  try Bool.fetchOne(db, sql: "SELECT is_group_event_authorized FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) == true
            else { return .init(policies: [], recovery: .unavailable) }
            let policies = try Self.readGroupRolePolicies(roomID: roomID, db: db)
            if let cursor = try Self.readCursor(db), cursor.state != .ready {
                return .init(policies: policies, recovery: .waitingForSynchronization)
            }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue]) {
                let request = try Self.decodeRolePolicyRecoveryRequest(row)
                guard try Self.matchesRolePolicyRecoveryRequest(request, db: db) else { return .init(policies: policies, recovery: .needed) }
                switch row["state"] as String {
                case "paused": return .init(policies: policies, recovery: .paused)
                case "pending": return .init(policies: policies, recovery: .pending(nextAttemptAt: .init(timeIntervalSince1970: row["next_attempt_at"] as Double)))
                default: throw V2ClientProjectionError.invalidMessagePayload
                }
            }
            let hasBaseline = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_group_role_policy_baselines WHERE room_id = ?)", arguments: [roomID.rawValue]) == true
            return .init(policies: policies, recovery: hasBaseline ? .ready : .needed)
        }
    }

    private static func readGroupRolePolicies(roomID: RoomID, db: Database) throws -> [V2ClientGroupRolePolicy] {
        if try Bool.fetchOne(db, sql: "SELECT is_group_event_authorized FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) == false { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM v2_group_role_policies WHERE room_id = ? ORDER BY role", arguments: [roomID.rawValue])
        let baseline = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [roomID.rawValue])
        func positiveRevision(_ row: Row, column: String) throws -> Int64 {
            let value: DatabaseValue = row[column]
            guard case .int64(let revision) = value.storage, revision > 0
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return revision
        }
        let storedBaselineRevision = try baseline.map { try positiveRevision($0, column: "permission_revision") }
        let revisionRow = try Row.fetchOne(db, sql: "SELECT revision FROM v2_group_permission_revisions WHERE room_id = ?", arguments: [roomID.rawValue])
        let storedRevision = try revisionRow.map { try positiveRevision($0, column: "revision") }
        for row in rows { _ = try positiveRevision(row, column: "revision") }
        let baselineRevision = storedBaselineRevision ?? 0
        let revision = try Self.storageUnsigned(max(storedRevision ?? 1, baselineRevision))
        var observed = Dictionary(uniqueKeysWithValues: rows.map { ($0["role"] as String, $0) })
        var result: [V2ClientGroupRolePolicy] = []
        for role in [V2RoomMembershipRole.admin, .member] {
            let row = observed.removeValue(forKey: role.rawValue)
            let data: Data
            if let baseline, (try row.map { try positiveRevision($0, column: "revision") } ?? 0) <= baselineRevision {
                data = baseline[role == .admin ? "admin_permissions" : "member_permissions"]
            } else if let row { data = row["permissions"] }
            else { continue }
            let names = try JSONDecoder().decode([String].self, from: data)
            let permissions = Set(names.compactMap(V2GroupPermission.init(rawValue:)))
            guard permissions.count == names.count else { throw V2ClientProjectionError.invalidMessagePayload }
            result.append(.init(roomID: roomID, role: role, permissions: permissions, revision: revision))
        }
        guard observed.isEmpty else { throw V2ClientProjectionError.invalidMessagePayload }
        return result
    }

    /// Rebuilds the derived character index in bounded transactions. The
    /// durable message projection remains readable while this runs; callers
    /// should expose `.building` instead of treating a partial index as an
    /// empty search result.

    /// Reads one inbox or archive page through the materialized ordering
    /// index. The keyset predicate matches the index order exactly, and all
    /// page details are hydrated inside the same read transaction.
    public func conversationListPage(
        isArchived: Bool,
        before cursor: V2ClientConversationListCursor? = nil,
        limit: Int = 50
    ) throws -> V2ClientConversationListPage {
        guard (1 ... 100).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try databasePool.read { db in
            let predicate: String
            let arguments: StatementArguments
            if let cursor {
                predicate = """
                    AND (
                        is_pinned < ?
                        OR (is_pinned = ? AND last_activity < ?)
                        OR (is_pinned = ? AND last_activity = ? AND room_id > ?)
                    )
                    """
                arguments = [
                    isArchived,
                    cursor.isPinned,
                    cursor.isPinned,
                    cursor.lastActivity.timeIntervalSince1970,
                    cursor.isPinned,
                    cursor.lastActivity.timeIntervalSince1970,
                    cursor.roomID.rawValue,
                    limit + 1,
                ]
            } else {
                predicate = ""
                arguments = [isArchived, limit + 1]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT room_id, last_activity, is_pinned, is_archived, mute_until
                FROM v2_conversation_list_entries
                WHERE is_archived = ?
                \(predicate)
                ORDER BY is_pinned DESC, last_activity DESC, room_id ASC
                LIMIT ?
                """,
                arguments: arguments
            )
            let pageRows = Array(rows.prefix(limit))
            guard !pageRows.isEmpty else { return .init(entries: [], nextCursor: nil) }

            let entries = try Self.conversationListEntries(pageRows, db: db)
            let nextCursor: V2ClientConversationListCursor? = rows.count > limit ? try pageRows.last.map { row in
                try .init(
                    isPinned: row["is_pinned"],
                    lastActivity: Date(timeIntervalSince1970: row["last_activity"] as Double),
                    roomID: .init(row["room_id"] as String)
                )
            } : nil
            return .init(entries: entries, nextCursor: nextCursor)
        }
    }

    public func reactions(for messageID: MessageID) throws -> [V2ClientMessageReaction] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT room_id, message_id, actor_user_id, reaction FROM v2_message_reactions WHERE message_id = ? ORDER BY reaction, actor_user_id", arguments: [messageID.rawValue]).map { row in
                try .init(roomID: .init(row["room_id"] as String), messageID: .init(row["message_id"] as String), actorUserID: .init(row["actor_user_id"] as String), reaction: row["reaction"])
            }
        }
    }

    /// Reads every reaction needed by one visible conversation in one query.
    /// Callers can group these value projections without an N+1 database read
    /// for each rendered message.
    public func reactions(in roomID: RoomID) throws -> [V2ClientMessageReaction] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT room_id, message_id, actor_user_id, reaction FROM v2_message_reactions WHERE room_id = ? ORDER BY message_id, reaction, actor_user_id", arguments: [roomID.rawValue]).map { row in
                try .init(roomID: .init(row["room_id"] as String), messageID: .init(row["message_id"] as String), actorUserID: .init(row["actor_user_id"] as String), reaction: row["reaction"])
            }
        }
    }

    /// Test/diagnostic batch read. Production contacts use the bounded page
    /// API so a large relationship graph is never materialized on refresh.
    func relationships() throws -> [V2ClientRelationshipProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT target_user_id, state, requested_by_user_id, updated_at FROM v2_relationship_projections ORDER BY target_user_id").map(Self.decodeRelationshipProjection)
        }
    }

    public func relationshipPage(
        scope: V2ClientRelationshipPageScope,
        matching query: String? = nil,
        before cursor: V2ClientRelationshipCursor? = nil,
        limit: Int = 50,
        includeTotalCount: Bool = false
    ) throws -> V2ClientRelationshipPage {
        guard (1 ... 100).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        let selection = try Self.relationshipListSelection(scope: scope, matching: query)
        var clauses = selection.clauses
        var arguments = selection.arguments
        let countClauses = includeTotalCount ? clauses : []
        let countArguments = includeTotalCount ? arguments : []
        if let cursor {
            clauses.append("(relationship.updated_at < ? OR (relationship.updated_at = ? AND relationship.target_user_id > ?))")
            arguments += [cursor.updatedAt.timeIntervalSince1970, cursor.updatedAt.timeIntervalSince1970, cursor.targetUserID.rawValue]
        }
        let whereClause = clauses.joined(separator: " AND ")
        let searchJoin = selection.searchJoin
        return try databasePool.read { db in
            var pageArguments = arguments
            pageArguments += [limit + 1]
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT relationship.target_user_id, relationship.state,
                       relationship.requested_by_user_id, relationship.updated_at
                FROM v2_relationship_projections AS relationship
                \(searchJoin)
                WHERE \(whereClause)
                ORDER BY relationship.updated_at DESC, relationship.target_user_id ASC
                LIMIT ?
                """,
                arguments: pageArguments
            )
            let pageRows = Array(rows.prefix(limit))
            let relationships = try pageRows.map(Self.decodeRelationshipProjection)
            let nextCursor: V2ClientRelationshipCursor? = rows.count > limit ? try pageRows.last.map { row in
                try .init(
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double),
                    targetUserID: .init(row["target_user_id"] as String)
                )
            } : nil

            // Exact counts are opt-in because an index COUNT is still linear
            // work. The contacts UI requests it only for the first incoming-
            // request page that owns the badge.
            let totalCount: Int? = if includeTotalCount {
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*)
                    FROM v2_relationship_projections AS relationship
                    \(searchJoin)
                    WHERE \(countClauses.joined(separator: " AND "))
                    """,
                    arguments: countArguments
                ) ?? 0
            } else {
                nil
            }
            return .init(relationships: relationships, nextCursor: nextCursor, totalCount: totalCount)
        }
    }

    public func blocks() throws -> [V2ClientUserBlockProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT target_user_id, is_blocked, updated_at FROM v2_user_block_projections WHERE is_blocked = 1 ORDER BY target_user_id").map(Self.decodeBlockProjection)
        }
    }

    public func strangerMessagePreference() throws -> V2ClientStrangerMessagePreference? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT allows_stranger_messages, updated_at FROM v2_stranger_message_preference WHERE singleton = 1") else { return nil }
            return .init(allowsStrangerMessages: row["allows_stranger_messages"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    public func userAddPreference() throws -> V2ClientUserAddPreference? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT allows_being_added, updated_at FROM v2_user_add_preference WHERE singleton = 1") else { return nil }
            return .init(allowsBeingAdded: row["allows_being_added"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    public func directReadReceipt(roomID: RoomID) throws -> V2DirectReadReceiptProjection? {
        try databasePool.read { db -> V2DirectReadReceiptProjection? in
            guard let row = try Row.fetchOne(db, sql: "SELECT room_id, reader_user_id, read_through_room_sequence, recorded_at FROM v2_direct_read_receipt_projections WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try .init(roomID: .init(row["room_id"] as String), readerUserID: .init(row["reader_user_id"] as String), readThroughRoomSequence: try Self.storageUnsigned(row["read_through_room_sequence"] as Int64), recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double), isVisible: true)
        }
    }
    public func readReceiptPreference() throws -> V2ReadReceiptPreferences? {
        try databasePool.read { db -> V2ReadReceiptPreferences? in
            guard let row = try Row.fetchOne(db, sql: "SELECT allows_direct_read_receipts, allows_group_read_receipts, updated_at FROM v2_read_receipt_preference WHERE singleton = 1") else { return nil }
            return .init(allowsDirectReadReceipts: row["allows_direct_read_receipts"], allowsGroupReadReceipts: row["allows_group_read_receipts"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    public func moderationActions() throws -> [V2ClientModerationProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_event_id, room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at FROM v2_moderation_projections ORDER BY server_created_at, source_event_id").map(Self.decodeModerationProjection)
        }
    }

    public func roomControl(roomID: RoomID) throws -> V2ClientRoomControlProjection? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT source_event_id, room_id, room_sequence, actor_user_id, is_frozen, server_created_at FROM v2_room_control_projections WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try Self.decodeRoomControlProjection(row)
        }
    }

    public func roomProfile(roomID: RoomID) throws -> V2ClientRoomProfileProjection? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT source_event_id, room_id, title, owner_user_id, delivery_mode, membership_revision, created_at FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try Self.decodeRoomProfileProjection(row)
        }
    }

    func roomProfiles() throws -> [V2ClientRoomProfileProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_event_id, room_id, title, owner_user_id, delivery_mode, membership_revision, created_at FROM v2_room_profile_projections ORDER BY created_at DESC, room_id").map(Self.decodeRoomProfileProjection)
        }
    }

    /// Persists an identity that the current user explicitly resolved before
    /// opening a direct room. It deliberately survives a sync reset: the
    /// server has not made this cache a sync projection yet, and deleting it
    /// would regress an already-authorized, still-active direct room to a
    /// UUID title after recovery.
    public func cacheDirectRoomIdentity(roomID: RoomID, publicIdentity: V2PublicIdentity, updatedAt: Date = Date()) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            if let existing = try Row.fetchOne(db, sql: "SELECT target_user_id FROM v2_direct_room_identities WHERE room_id = ?", arguments: [roomID.rawValue]) {
                let targetUserID: String = existing["target_user_id"]
                guard targetUserID == publicIdentity.userID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            try db.execute(
                sql: """
                INSERT INTO v2_direct_room_identities
                    (room_id, target_user_id, public_handle, display_name, account_kind, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_id) DO UPDATE SET
                    public_handle = excluded.public_handle,
                    display_name = excluded.display_name,
                    account_kind = excluded.account_kind,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    roomID.rawValue,
                    publicIdentity.userID.rawValue,
                    publicIdentity.handle.rawValue,
                    publicIdentity.displayName,
                    publicIdentity.accountKind.rawValue,
                    updatedAt.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: "INSERT INTO v2_room_event_authorizations (room_id, is_authorized) VALUES (?, 1) ON CONFLICT(room_id) DO UPDATE SET is_authorized = excluded.is_authorized",
                arguments: [roomID.rawValue]
            )
        }
    }

    func directRoomIdentities() throws -> [V2ClientDirectRoomIdentity] {
        try databasePool.read { db in
            let cached = try Row.fetchAll(
                db,
                sql: "SELECT room_id, target_user_id, public_handle, display_name, account_kind, updated_at FROM v2_direct_room_identities ORDER BY updated_at DESC, room_id"
            ).map(Self.decodeDirectRoomIdentity)
            let projected = try Row.fetchAll(
                db,
                sql: "SELECT room_id, target_user_id, public_handle, display_name, account_kind, updated_at FROM v2_direct_room_profile_projections ORDER BY updated_at DESC, room_id"
            ).map(Self.decodeDirectRoomIdentity)
            return Dictionary(projected.map { ($0.roomID, $0) }, uniquingKeysWith: { _, incoming in incoming })
                .merging(Dictionary(cached.map { ($0.roomID, $0) }, uniquingKeysWith: { _, incoming in incoming }), uniquingKeysWith: { projected, _ in projected })
                .values
                .sorted { $0.updatedAt == $1.updatedAt ? $0.roomID.rawValue < $1.roomID.rawValue : $0.updatedAt > $1.updatedAt }
        }
    }

    /// Reads the last authorized profile representation. Callers must resolve
    /// it through `V2ProfileResolver`; they must not copy its dynamic display
    /// data into message or conversation structures.
    public func profileView(userID: UserID) throws -> V2ProfileView? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id = ?",
                arguments: [userID.rawValue]
            ) else { return nil }
            return try Self.decodeProfileView(row)
        }
    }

    public func profileViews(userIDs: [UserID]) throws -> [UserID: V2ProfileView] {
        let uniqueIDs = Array(Set(userIDs)).sorted()
        guard !uniqueIDs.isEmpty else { return [:] }
        return try databasePool.read { db in
            let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id IN (\(placeholders))",
                arguments: StatementArguments(uniqueIDs.map(\.rawValue))
            )
            return try Dictionary(uniqueKeysWithValues: rows.map { row in
                let view = try Self.decodeProfileView(row)
                return (view.userID, view)
            })
        }
    }

    /// Called only with a fully authorized server response. The write and
    /// invalidation cleanup share one transaction, so UI never observes a
    /// fresh profile alongside a pending older refresh requirement.
    public func saveProfileView(_ profile: V2ProfileView) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            try Self.persist(profile, db: db)
        }
    }

    /// Deletes an inaccessible view instead of retaining old profile data in
    /// the local account projection. The image cache observes the same signal
    /// at a higher media boundary and must evict any protected avatar bytes.
    public func markProfileUnavailable(userID: UserID) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            try db.execute(sql: "DELETE FROM v2_profile_views WHERE user_id = ?", arguments: [userID.rawValue])
            try db.execute(sql: "DELETE FROM v2_profile_invalidations WHERE user_id = ?", arguments: [userID.rawValue])
        }
    }

    /// Applies one server-authorized batch in one SQLite transaction. A crash
    /// can therefore expose either the previous profile generation or the
    /// complete new response, never a partially hydrated contact page.
    public func applyProfileViewResults(_ results: [V2ProfileViewLookupResult]) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            let batch = V2ProfileViewResultBatch(results)
            for profile in batch.profiles.values {
                try Self.persist(profile, db: db)
            }
            for userID in batch.unavailableUserIDs.subtracting(batch.profiles.keys) {
                try db.execute(sql: "DELETE FROM v2_profile_views WHERE user_id = ?", arguments: [userID.rawValue])
                try db.execute(sql: "DELETE FROM v2_profile_invalidations WHERE user_id = ?", arguments: [userID.rawValue])
            }
        }
    }

    public func pendingProfileInvalidations(limit: Int) throws -> [V2ProfileInvalidation] {
        guard limit > 0 else { return [] }
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT user_id, minimum_revision FROM v2_profile_invalidations ORDER BY updated_at, user_id LIMIT ?",
                arguments: [limit]
            ).map { row in
                guard let revision = V2ProfileRevision(rawValue: try Self.storageUnsigned(row["minimum_revision"] as Int64)) else {
                    throw V2ClientProjectionError.invalidMessagePayload
                }
                return try .init(userID: .init(row["user_id"] as String), minimumRevision: revision)
            }
        }
    }


    private static func validateOrdering(_ records: [V2ClientSyncRecord]) throws {
        for pair in zip(records, records.dropFirst()) where pair.1.sequence <= pair.0.sequence {
            throw V2ClientSyncError.invalidRecordOrdering
        }
    }

    /// PostgreSQL's `BIGINT` and SQLite's `INTEGER` are signed. Keep the
    /// protocol's wider `uint64` domain at the transport boundary and fail
    /// closed before any value enters durable local state.
    static func storageInteger(_ value: UInt64) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw V2ClientSyncError.storageRangeExceeded
        }
        return result
    }

    private static func storageUnsigned(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else { throw V2ClientSyncError.storageRangeExceeded }
        return UInt64(value)
    }

    static func commandStorageInteger(_ value: UInt64) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw V2ClientCommandError.commandConflict
        }
        return result
    }

    static func commandStorageUnsigned(_ value: Int64) throws -> UInt64 {
        guard let result = UInt64(exactly: value) else { throw V2ClientCommandError.commandConflict }
        return result
    }

    private static func projectionStorageUnsigned(_ value: Int64) throws -> UInt64 {
        guard let result = UInt64(exactly: value) else { throw V2ClientProjectionError.invalidMessagePayload }
        return result
    }

    private static func validatePersistable(_ batch: V2ClientSyncBatch) throws {
        _ = try storageInteger(batch.generation)
        for record in batch.records {
            _ = try storageInteger(record.sequence)
        }
    }

    private static func validatePersistable(_ manifest: V2ClientSnapshotManifest) throws {
        _ = try storageInteger(manifest.reset.generation)
        _ = try storageInteger(manifest.reset.baseSequence)
    }

    private static func matchesExisting(_ record: V2ClientSyncRecord, db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT source_event_id, projection_kind, payload FROM v2_sync_events WHERE sequence = ?", arguments: [try storageInteger(record.sequence)]) else { return false }
        let eventID: String = row["source_event_id"]
        let kind: String = row["projection_kind"]
        let payload: Data = row["payload"]
        return eventID == record.sourceEventID.rawValue && kind == record.projectionKind && payload == record.payload
    }

    private static func establishInstallationBinding(_ binding: V2LocalInstallationBinding, userID: UserID?, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1") {
            let stored: String = row["binding"]
            let storedUserID: String? = row["user_id"]
            guard stored == binding.value.uuidString,
                  userID == nil || storedUserID == nil || storedUserID == userID?.rawValue
            else { throw V2ClientLocalStorageError.installationBindingMismatch }
            if storedUserID == nil, let userID {
                try db.execute(sql: "UPDATE v2_local_installation SET user_id = ? WHERE singleton = 1", arguments: [userID.rawValue])
            }
            return
        }
        try db.execute(sql: "INSERT INTO v2_local_installation (singleton, binding, user_id) VALUES (1, ?, ?)", arguments: [binding.value.uuidString, userID?.rawValue])
    }

    private static func matchesSnapshotImport(_ manifest: V2ClientSnapshotManifest, db: Database) throws -> Bool {
        try validatePersistable(manifest)
        guard let row = try Row.fetchOne(db, sql: "SELECT snapshot_id, generation, base_sequence, root_digest, next_sync_token, receipt, capability_profile, page_count, total_items, total_bytes FROM v2_snapshot_import LIMIT 1") else {
            return false
        }
        let snapshotID: String = row["snapshot_id"]
        let generation: Int64 = row["generation"]
        let baseSequence: Int64 = row["base_sequence"]
        let digest: String = row["root_digest"]
        let token: String = row["next_sync_token"]
        let receipt: String = row["receipt"]
        let profile: String = row["capability_profile"]
        let pageCount: Int64 = row["page_count"]
        let totalItems: Int64 = row["total_items"]
        let totalBytes: Int64 = row["total_bytes"]
        let expectedGeneration = try storageInteger(manifest.reset.generation)
        let expectedBaseSequence = try storageInteger(manifest.reset.baseSequence)
        let expectedTotalItems = try storageInteger(manifest.totalItems)
        let expectedTotalBytes = try storageInteger(manifest.totalBytes)
        return snapshotID == manifest.reset.snapshotID.rawValue &&
            generation == expectedGeneration &&
            baseSequence == expectedBaseSequence &&
            digest == manifest.rootDigest &&
            token == manifest.nextSyncToken.rawValue &&
            receipt == manifest.receipt.rawValue &&
            profile == manifest.capabilityProfile &&
            pageCount == Int64(manifest.pageCount) &&
            totalItems == expectedTotalItems &&
            totalBytes == expectedTotalBytes
    }

    private static func readCursor(_ db: Database) throws -> V2LocalSyncCursor? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_sync_cursor WHERE singleton = 1") else { return nil }
        let state = try V2LocalSyncCursor.State(rawValue: row["state"] as String).unwrap(or: V2ClientSyncError.generationMismatch)
        let generation = try storedCursorSequence(row["generation"])
        let applied = try storedCursorSequence(row["applied_sequence"])
        let acknowledged = try storedCursorSequence(row["server_acknowledged_sequence"])
        let token = try (row["sync_token"] as String?).map(V2SyncToken.init)
        let pendingReceipt = try (row["pending_ack_receipt"] as String?).map(V2SyncReceipt.init)
        let pendingValue: DatabaseValue = row["pending_ack_sequence"]
        let pendingSequence = try pendingValue.isNull ? nil : storedCursorSequence(pendingValue)
        if state == .ready {
            return try .init(
                state: state,
                generation: generation,
                appliedSequence: applied,
                serverAcknowledgedSequence: acknowledged,
                syncToken: token,
                pendingAcknowledgementReceipt: pendingReceipt,
                pendingAcknowledgementSequence: pendingSequence,
                pendingReset: nil
            )
        }
        guard let snapshotRaw: String = row["pending_snapshot_id"],
              !(row["pending_base_sequence"] as DatabaseValue).isNull,
              let expires: Double = row["pending_expires_at"]
        else { throw V2ClientSyncError.resetFenceMismatch }
        return try .init(
            state: state,
            generation: generation,
            appliedSequence: applied,
            serverAcknowledgedSequence: acknowledged,
            syncToken: token,
            pendingAcknowledgementReceipt: nil,
            pendingAcknowledgementSequence: nil,
            pendingReset: .init(snapshotID: .init(snapshotRaw), generation: generation, baseSequence: try storedCursorSequence(row["pending_base_sequence"]), expiresAt: Date(timeIntervalSince1970: expires))
        )
    }

    private static func storedCursorSequence(_ value: DatabaseValue) throws -> UInt64 {
        guard case .int64(let stored) = value.storage else { throw V2ClientSyncError.storageRangeExceeded }
        return try storageUnsigned(stored)
    }

    private static func writeCursor(_ cursor: V2LocalSyncCursor, db: Database) throws {
        let reset = cursor.pendingReset
        try db.execute(
            sql: """
            INSERT INTO v2_sync_cursor
                (singleton, state, generation, applied_sequence, server_acknowledged_sequence,
                 sync_token, pending_ack_receipt, pending_ack_sequence,
                 pending_snapshot_id, pending_base_sequence, pending_expires_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET state = excluded.state, generation = excluded.generation,
                applied_sequence = excluded.applied_sequence, server_acknowledged_sequence = excluded.server_acknowledged_sequence,
                sync_token = excluded.sync_token, pending_ack_receipt = excluded.pending_ack_receipt,
                pending_ack_sequence = excluded.pending_ack_sequence,
                pending_snapshot_id = excluded.pending_snapshot_id, pending_base_sequence = excluded.pending_base_sequence,
                pending_expires_at = excluded.pending_expires_at
            """,
            arguments: [cursor.state.rawValue, try storageInteger(cursor.generation), try storageInteger(cursor.appliedSequence), try storageInteger(cursor.serverAcknowledgedSequence), cursor.syncToken?.rawValue, cursor.pendingAcknowledgementReceipt?.rawValue, try cursor.pendingAcknowledgementSequence.map(storageInteger), reset?.snapshotID.rawValue, try reset.map { try storageInteger($0.baseSequence) }, reset?.expiresAt.timeIntervalSince1970]
        )
    }

    private static func decodeEvent(_ row: Row) throws -> V2ClientSyncRecord {
        try .init(sequence: storageUnsigned(row["sequence"] as Int64), sourceEventID: .init(row["source_event_id"] as String), projectionKind: row["projection_kind"], payload: row["payload"])
    }

    private static func decodeConversationState(_ row: Row) throws -> V2ClientConversationState {
        let muteUntil: Double = row["mute_until"]
        return try .init(
            roomID: .init(row["room_id"] as String),
            isPinned: row["is_pinned"],
            isArchived: row["is_archived"],
            muteUntil: muteUntil == 0 ? nil : Date(timeIntervalSince1970: muteUntil),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double)
        )
    }

    static func decodeProfileView(_ row: Row) throws -> V2ProfileView {
        let userID = try UserID(row["user_id"] as String)
        guard let state = V2ProfileState(rawValue: row["state"] as String),
              let revision = V2ProfileRevision(rawValue: try storageUnsigned(row["revision"] as Int64)),
              let visibilityRevision = V2ProfileRevision(rawValue: try storageUnsigned(row["visibility_revision"] as Int64))
        else { throw V2ClientProjectionError.invalidMessagePayload }
        let handle: String? = row["public_handle"]
        let displayName: String? = row["display_name"]
        let accountKindRaw: String? = row["account_kind"]
        let accountKind = accountKindRaw.flatMap(V2AccountKind.init)
        guard accountKindRaw == nil || accountKind != nil else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let avatarMediaID: String? = row["avatar_media_id"]
        let identity: V2PublicIdentity?
        switch (handle, displayName, accountKind) {
        case (.none, .none, .none): identity = nil
        case let (.some(handle), .some(displayName), .some(accountKind)):
            identity = try .init(userID: userID, handle: .init(handle), displayName: displayName, accountKind: accountKind)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
        let avatar = try avatarMediaID.map { try V2AvatarReference(mediaID: .init($0)) }
        return try .init(
            userID: userID,
            publicIdentity: identity,
            avatar: avatar,
            state: state,
            revision: revision,
            visibilityRevision: visibilityRevision
        )
    }

    static func decodeRelationshipProjection(_ row: Row) throws -> V2ClientRelationshipProjection {
        guard let state = V2RelationshipState(rawValue: row["state"] as String) else { throw V2ClientSocialProjectionError.invalidPayload }
        let requestedBy = try (row["requested_by_user_id"] as String?).map(UserID.init)
        guard (state == .pending) == (requestedBy != nil) else { throw V2ClientSocialProjectionError.invalidPayload }
        return try .init(targetUserID: .init(row["target_user_id"] as String), state: state, requestedByUserID: requestedBy, updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
    }

    private static func decodeBlockProjection(_ row: Row) throws -> V2ClientUserBlockProjection {
        try .init(targetUserID: .init(row["target_user_id"] as String), isBlocked: row["is_blocked"], updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
    }

    private static func applyMessage(_ record: V2ClientSyncRecord, expectedRoomID: RoomID? = nil, expectedRoomSequence: UInt64? = nil, db: Database) throws {
        let effect = try V2LocalMessageEffect(record: record)
        if let expectedRoomID, effect.roomID != expectedRoomID { throw V2ClientProjectionError.invalidMessagePayload }
        if let expectedRoomSequence, case .edited(let edit) = effect,
           case .complete(let replacement) = edit.content, replacement.mutationRoomSequence != expectedRoomSequence {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        guard try claimMessageEffect(effect, sourceEventID: record.sourceEventID, db: db) else { return }
        switch effect {
        case .accepted(let value): try persist(value, db: db)
        case .edited(let value): try persist(value, db: db)
        case .withdrawn(let value), .redacted(let value): try persist(value, db: db)
        }
    }

    /// The account-bound database is the effect's account scope. This claim,
    /// projection mutation, FTS job and consuming feed cursor share one write
    /// transaction. Failed application cannot leave a committed claim behind.
    private static func claimMessageEffect(_ effect: V2LocalMessageEffect, sourceEventID: EventID, db: Database) throws -> Bool {
        let digest = try effect.digest()
        let revision = try storageInteger(effect.revision)
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, message_revision, canonical_digest FROM v2_message_effects WHERE source_event_id = ? AND projection_kind = 'message' AND entity_key = ?", arguments: [sourceEventID.rawValue, effect.messageID.rawValue]) {
            guard (row["room_id"] as String) == effect.roomID.rawValue,
                  (row["message_revision"] as Int64) == revision,
                  (row["canonical_digest"] as Data) == digest
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return false
        }
        try db.execute(sql: "INSERT INTO v2_message_effects (source_event_id, projection_kind, entity_key, room_id, message_revision, canonical_digest) VALUES (?, 'message', ?, ?, ?, ?)", arguments: [sourceEventID.rawValue, effect.messageID.rawValue, effect.roomID.rawValue, revision, digest])
        return true
    }

    private static func applyRoomEventProjection(_ record: V2ClientSyncRecord, roomID: RoomID, db: Database) throws {
        switch record.projectionKind {
        case "message": try applyMessage(record, expectedRoomID: roomID, expectedRoomSequence: record.sequence, db: db)
        case "message_reaction":
            try applyReaction(record, expectedRoomSequence: record.sequence, db: db)
        case "moderation": try applyModeration(record, db: db)
        case "room", "membership": try applyMembershipAwareRoomProjection(record, db: db)
        case "group_capability": try applyGroupCapability(record, expectedRoomSequence: record.sequence, expectedRoomID: roomID, db: db)
        case "timeline_activity": try persist(V2ClientTimelineActivityProjection(record: record), db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func applyMembershipAwareRoomProjection(_ record: V2ClientSyncRecord, db: Database) throws {
        guard record.projectionKind == "membership" else {
            try persist(V2ClientRoomProfileProjection(record: record), db: db)
            return
        }
        struct MembershipHeader: Decodable {
            let roomID: String
            let targetUserID: String
            let action: String
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id", targetUserID = "target_user_id", action
            }
        }
        let header: MembershipHeader
        do { header = try JSONDecoder().decode(MembershipHeader.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        let roomID = try RoomID(header.roomID); let targetUserID = try UserID(header.targetUserID)
        guard header.action == "add" || header.action == "remove" else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let currentUserID: String? = try Row.fetchOne(
            db,
            sql: "SELECT user_id FROM v2_local_installation WHERE singleton = 1"
        )?["user_id"]
        if header.action == "remove", currentUserID == targetUserID.rawValue {
            try purgeRoomProjection(roomID: roomID.rawValue, db: db)
            return
        }
        try persist(V2ClientRoomProfileProjection(record: record), db: db)
        if header.action == "remove" {
            try db.execute(
                sql: "DELETE FROM v2_group_member_roles WHERE room_id = ? AND user_id = ?",
                arguments: [roomID.rawValue, targetUserID.rawValue]
            )
        }
    }

    private static func purgeRoomProjection(roomID: String, db: Database) throws {
        let messageIDs = try String.fetchAll(
            db,
            sql: "SELECT message_id FROM v2_message_projections WHERE room_id = ?",
            arguments: [roomID]
        )
        for messageID in messageIDs {
            try enqueueMessageSearchDeletionJob(messageID: messageID, db: db)
        }
        for table in [
            "v2_message_reactions", "v2_reaction_versions", "v2_reaction_effects", "v2_message_effects", "v2_message_tombstones", "v2_message_projections",
            "v2_moderation_projections", "v2_room_control_projections", "v2_room_profile_projections",
            "v2_conversation_states", "v2_message_favorites", "v2_timeline_activity_projections",
            "v2_group_pinned_messages", "v2_pin_effects", "v2_group_announcements", "v2_announcement_effects", "v2_group_role_policies", "v2_role_policy_effects", "v2_group_role_policy_baselines", "v2_role_policy_recovery_requests",
            "v2_group_member_roles", "v2_group_permission_revisions", "v2_group_events",
            "v2_group_event_cursors", "v2_conversation_summaries", "v2_conversation_list_entries",
        ] {
            try db.execute(sql: "DELETE FROM \(table) WHERE room_id = ?", arguments: [roomID])
        }
    }

    private static func pinShouldReplace(
        _ current: Row, source: String?, sequence: Int64?, digest: Data?,
        isPinned: Bool, updatedAt: Double, allowUnknownReplacement: Bool
    ) throws -> Bool {
        let oldSource: String? = current["source_event_id"]
        let oldSequence: Int64? = current["room_sequence"]
        if let source, source == oldSource {
            guard (current["canonical_digest"] as Data?) == digest,
                  (current["is_pinned"] as Bool) == isPinned,
                  (current["updated_at"] as Double) == updatedAt,
                  sequence == nil || oldSequence == nil || sequence == oldSequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return oldSequence == nil && sequence != nil
        }
        switch (oldSequence, sequence) {
        case let (.some(old), .some(new)):
            guard old != new else { throw V2ClientProjectionError.invalidMessagePayload }
            return new > old
        case (.some, .none): return false
        case (.none, .some): return true
        case (.none, .none): return allowUnknownReplacement
        }
    }

    private static func applyPinnedMessage(
        _ effect: V2LocalPinnedMessageEffect,
        target: ProjectionTableTarget = .live,
        preserveUnknownValue: Bool = false,
        db: Database
    ) throws {
        let receipts = target.table("v2_pin_effects")
        let pins = target.table("v2_group_pinned_messages")
        var sequence = effect.roomSequence
        let receipt = try Row.fetchOne(db, sql: "SELECT * FROM \(receipts) WHERE source_event_id = ? AND room_id = ?", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue])
        if let receipt {
            let oldSequence: Int64? = receipt["room_sequence"]
            guard (receipt["message_id"] as String) == effect.messageID.rawValue,
                  (receipt["canonical_digest"] as Data) == effect.digest,
                  oldSequence == nil || sequence == nil || oldSequence == sequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            sequence = sequence ?? oldSequence
            if oldSequence == nil, let sequence {
                try db.execute(sql: "UPDATE \(receipts) SET room_sequence = ? WHERE source_event_id = ? AND room_id = ?", arguments: [sequence, effect.sourceEventID.rawValue, effect.roomID.rawValue])
            }
        } else {
            try db.execute(sql: "INSERT INTO \(receipts) (source_event_id, room_id, message_id, room_sequence, canonical_digest) VALUES (?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.messageID.rawValue, sequence, effect.digest])
        }
        let updatedAt = Double(effect.updatedAtMilliseconds) / 1_000
        if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(pins) WHERE room_id = ? AND message_id = ?", arguments: [effect.roomID.rawValue, effect.messageID.rawValue]) {
            if preserveUnknownValue, sequence == nil,
               (current["is_pinned"] as Bool) != effect.isPinned || (current["updated_at"] as Double) != updatedAt {
                return
            }
            // A duplicate whose missing source order has now been supplied
            // must be reconsidered: its first unversioned observation might
            // have been ignored while another object state was current.
            guard try pinShouldReplace(current, source: effect.sourceEventID.rawValue,
                sequence: sequence, digest: effect.digest, isPinned: effect.isPinned,
                updatedAt: updatedAt, allowUnknownReplacement: receipt == nil)
            else { return }
        }
        try db.execute(sql: """
            INSERT INTO \(pins) (room_id, message_id, is_pinned, room_sequence, updated_at, source_event_id, canonical_digest)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id, message_id) DO UPDATE SET is_pinned = excluded.is_pinned,
                room_sequence = excluded.room_sequence, updated_at = excluded.updated_at,
                source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.messageID.rawValue, effect.isPinned, sequence, updatedAt, effect.sourceEventID.rawValue, effect.digest])
    }

    private static func migratePinnedMessageEffects(db: Database) throws {
        if try !db.columns(in: "v2_group_pinned_messages").contains(where: { $0.name == "source_event_id" }) {
            try db.execute(sql: "ALTER TABLE v2_group_pinned_messages RENAME TO v2_legacy_pinned_messages")
            try db.execute(sql: pinnedMessageProjectionSchemaSQL)
            let rows = try Row.fetchCursor(db, sql: "SELECT * FROM v2_legacy_pinned_messages")
            while let row = try rows.next() {
                guard let room = UUID(uuidString: row["room_id"] as String), let message = UUID(uuidString: row["message_id"] as String) else { throw V2ClientProjectionError.invalidMessagePayload }
                if let existing = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_pinned_messages WHERE room_id = ? AND message_id = ?", arguments: [room.uuidString, message.uuidString]) {
                    guard (existing["is_pinned"] as Bool) == (row["is_pinned"] as Bool), (existing["updated_at"] as Double) == (row["updated_at"] as Double) else { throw V2ClientProjectionError.invalidMessagePayload }
                } else {
                    // The old column may contain a personal cursor. Preserve
                    // the observed value but never promote that number to proof.
                    try db.execute(sql: "INSERT INTO v2_group_pinned_messages (room_id, message_id, is_pinned, updated_at) VALUES (?, ?, ?, ?)", arguments: [room.uuidString, message.uuidString, row["is_pinned"] as Bool, row["updated_at"] as Double])
                }
            }
            try db.execute(sql: "DROP TABLE v2_legacy_pinned_messages")
            try db.execute(sql: "CREATE INDEX v2_group_pinned_messages_room_idx ON v2_group_pinned_messages (room_id, is_pinned DESC, updated_at DESC)")
        }
        if try !db.tableExists("v2_pin_effects") { try db.execute(sql: pinnedMessageEffectsSchemaSQL) }
        for table in ["v2_sync_events", "v2_group_events"] {
            let columns = table == "v2_group_events" ? "room_sequence AS source_sequence, room_id AS source_room" : "NULL AS source_sequence, NULL AS source_room"
            let rows = try Row.fetchCursor(db, sql: "SELECT source_event_id, payload, \(columns) FROM \(table) WHERE projection_kind = 'group_capability'")
            while let row = try rows.next() {
                let payload: Data = row["payload"]
                guard try V2ClientGroupCapabilityProjection.header(payload).eventType == "message.pinned_changed" else { continue }
                let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: try .init(row["source_event_id"] as String), projectionKind: "group_capability", payload: payload)
                let sequence: Int64? = row["source_sequence"]
                let room: String? = row["source_room"]
                let effect = try V2LocalPinnedMessageEffect(record: record, expectedRoomSequence: sequence.map(storageUnsigned), expectedRoomID: room.map(RoomID.init))
                // Retained logs must not resurrect a removed room or a pin
                // projection that no longer exists after authorization purge.
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_group_pinned_messages WHERE room_id = ? AND message_id = ?)", arguments: [effect.roomID.rawValue, effect.messageID.rawValue]) == true else { continue }
                try applyPinnedMessage(effect, preserveUnknownValue: true, db: db)
            }
        }
        if try db.tableExists(snapshotShadowTable(for: "v2_message_projections")) {
            try dropSnapshotShadowTables(db: db)
            try db.execute(sql: "DELETE FROM v2_snapshot_import")
        }
    }

    private static func preservePinnedMessagesInSnapshot(db: Database) throws {
        let pins = snapshotShadowTable(for: "v2_group_pinned_messages")
        let rooms = snapshotShadowTable(for: "v2_room_profile_projections")
        let receipts = snapshotShadowTable(for: "v2_pin_effects")
        let rows = try Row.fetchCursor(db, sql: """
            SELECT live.* FROM v2_group_pinned_messages AS live
            JOIN \(rooms) AS room ON room.room_id = live.room_id
            WHERE room.delivery_mode = ? AND room.is_group_event_authorized = 1
            """, arguments: [V2GroupDeliveryMode.largeGroupHybrid.rawValue])
        while let live = try rows.next() {
            let room: String = live["room_id"], message: String = live["message_id"]
            if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(pins) WHERE room_id = ? AND message_id = ?", arguments: [room, message]) {
                guard try pinShouldReplace(current, source: live["source_event_id"], sequence: live["room_sequence"], digest: live["canonical_digest"], isPinned: live["is_pinned"], updatedAt: live["updated_at"], allowUnknownReplacement: false) else { continue }
            }
            try db.execute(sql: """
                INSERT INTO \(pins) (room_id, message_id, is_pinned, room_sequence, updated_at, source_event_id, canonical_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_id, message_id) DO UPDATE SET is_pinned = excluded.is_pinned,
                    room_sequence = excluded.room_sequence, updated_at = excluded.updated_at,
                    source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
                """, arguments: [room, message, live["is_pinned"] as Bool, live["room_sequence"] as Int64?, live["updated_at"] as Double, live["source_event_id"] as String?, live["canonical_digest"] as Data?])
        }
        // Only keep receipts covered by retained state. Removed rooms/items do
        // not carry independent historical proof into a new snapshot bank.
        let covered = "(live.source_event_id = state.source_event_id OR (live.room_sequence IS NOT NULL AND state.room_sequence IS NOT NULL AND live.room_sequence <= state.room_sequence))"
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM v2_pin_effects AS live
                JOIN \(receipts) AS incoming ON incoming.source_event_id = live.source_event_id AND incoming.room_id = live.room_id
                WHERE (live.message_id <> incoming.message_id OR live.canonical_digest <> incoming.canonical_digest
                    OR (live.room_sequence IS NOT NULL AND incoming.room_sequence IS NOT NULL AND live.room_sequence <> incoming.room_sequence))
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(receipts)
            SELECT live.* FROM v2_pin_effects AS live
            JOIN \(pins) AS state ON state.room_id = live.room_id AND state.message_id = live.message_id
            WHERE \(covered)
            ON CONFLICT(source_event_id, room_id) DO UPDATE SET room_sequence = COALESCE(\(receipts).room_sequence, excluded.room_sequence)
            """)
        try db.execute(sql: """
            UPDATE \(pins) SET room_sequence = (
                SELECT effect.room_sequence FROM \(receipts) AS effect
                WHERE effect.source_event_id = \(pins).source_event_id AND effect.room_id = \(pins).room_id
            ) WHERE room_sequence IS NULL AND source_event_id IS NOT NULL
            """)
    }

    private static func applyAnnouncement(
        _ effect: V2LocalAnnouncementEffect,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let receipts = target.table("v2_announcement_effects")
        let announcements = target.table("v2_group_announcements")
        if let receipt = try Row.fetchOne(db, sql: "SELECT * FROM \(receipts) WHERE source_event_id = ? AND room_id = ?", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue]) {
            let sequence: Int64? = receipt["room_sequence"]
            guard (receipt["revision"] as Int64) == effect.revision,
                  (receipt["canonical_digest"] as Data) == effect.digest,
                  sequence == nil || effect.roomSequence == nil || sequence == effect.roomSequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            // Retain subsequently supplied source metadata without weakening
            // the claim if the same legacy fact arrives without it again.
            if sequence == nil, let sequence = effect.roomSequence {
                try db.execute(sql: "UPDATE \(receipts) SET room_sequence = ? WHERE source_event_id = ? AND room_id = ?", arguments: [sequence, effect.sourceEventID.rawValue, effect.roomID.rawValue])
                try db.execute(sql: "UPDATE \(announcements) SET room_sequence = ? WHERE room_id = ? AND source_event_id = ? AND room_sequence IS NULL", arguments: [sequence, effect.roomID.rawValue, effect.sourceEventID.rawValue])
            }
            return
        }
        try db.execute(sql: "INSERT INTO \(receipts) (source_event_id, room_id, revision, room_sequence, canonical_digest) VALUES (?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.revision, effect.roomSequence, effect.digest])
        var sequence = effect.roomSequence
        if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(announcements) WHERE room_id = ?", arguments: [effect.roomID.rawValue]) {
            let revision: Int64 = current["revision"]
            if revision > effect.revision { return }
            if revision == effect.revision {
                let source: String? = current["source_event_id"]
                let currentSequence: Int64? = current["room_sequence"]
                guard (current["body"] as String) == effect.body,
                      (current["updated_at"] as Double) == Double(effect.updatedAtMilliseconds) / 1_000,
                      source == nil || (source == effect.sourceEventID.rawValue && (current["canonical_digest"] as Data?) == effect.digest),
                      currentSequence == nil || sequence == nil || currentSequence == sequence
                else { throw V2ClientProjectionError.invalidMessagePayload }
                sequence = sequence ?? currentSequence
            }
        }
        try db.execute(sql: """
            INSERT INTO \(announcements) (room_id, body, revision, room_sequence, updated_at, source_event_id, canonical_digest)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET body = excluded.body, revision = excluded.revision,
                room_sequence = excluded.room_sequence, updated_at = excluded.updated_at,
                source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.body, effect.revision, sequence, Double(effect.updatedAtMilliseconds) / 1_000, effect.sourceEventID.rawValue, effect.digest])
    }

    private static func migrateAnnouncementEffects(db: Database) throws {
        if try !db.columns(in: "v2_group_announcements").contains(where: { $0.name == "source_event_id" }) {
            try db.execute(sql: "ALTER TABLE v2_group_announcements RENAME TO v2_legacy_announcements")
            try db.execute(sql: announcementProjectionSchemaSQL)
            let rows = try Row.fetchCursor(db, sql: "SELECT * FROM v2_legacy_announcements ORDER BY revision")
            while let row = try rows.next() {
                let room = try RoomID(row["room_id"] as String)
                let revision: Int64 = row["revision"]
                if let current = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_announcements WHERE room_id = ? AND revision = ?", arguments: [room.rawValue, revision]) {
                    guard (current["body"] as String) == (row["body"] as String), (current["updated_at"] as Double) == (row["updated_at"] as Double) else { throw V2ClientProjectionError.invalidMessagePayload }
                }
                // Old room_sequence may be a personal cursor. Visible revision
                // and value survive, but the missing source proof stays NULL.
                try db.execute(sql: """
                    INSERT INTO v2_group_announcements (room_id, body, revision, room_sequence, updated_at)
                    VALUES (?, ?, ?, NULL, ?)
                    ON CONFLICT(room_id) DO UPDATE SET body = excluded.body, revision = excluded.revision, updated_at = excluded.updated_at
                    """, arguments: [room.rawValue, row["body"] as String, revision, row["updated_at"] as Double])
            }
            try db.execute(sql: "DROP TABLE v2_legacy_announcements")
        }
        if try !db.tableExists("v2_announcement_effects") { try db.execute(sql: announcementEffectsSchemaSQL) }
        for table in ["v2_sync_events", "v2_group_events"] {
            let sourceColumns = table == "v2_group_events" ? "room_sequence AS source_sequence, room_id AS source_room" : "NULL AS source_sequence, NULL AS source_room"
            let rows = try Row.fetchCursor(db, sql: "SELECT source_event_id, payload, \(sourceColumns) FROM \(table) WHERE projection_kind = 'group_capability'")
            while let row = try rows.next() {
                let payload: Data = row["payload"]
                guard try V2ClientGroupCapabilityProjection.header(payload).eventType == "group.announcement_changed" else { continue }
                let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: try .init(row["source_event_id"] as String), projectionKind: "group_capability", payload: payload)
                let sequence: Int64? = row["source_sequence"]
                let room: String? = row["source_room"]
                let effect = try V2LocalAnnouncementEffect(record: record, expectedRoomSequence: sequence.map(storageUnsigned), expectedRoomID: room.map(RoomID.init))
                // Personal logs can outlive a revoked room's visible state.
                // Backfill proof only for surviving announcements, never
                // resurrect a projection removed by membership authorization.
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_group_announcements WHERE room_id = ?)", arguments: [effect.roomID.rawValue]) == true else { continue }
                try applyAnnouncement(effect, db: db)
            }
        }
        if try db.tableExists(snapshotShadowTable(for: "v2_group_announcements")) {
            // The old shadow has no source proof. Resume the durable reset by
            // reimporting its immutable artifact; live rows/outboxes stay put.
            try dropSnapshotShadowTables(db: db)
            try db.execute(sql: "DELETE FROM v2_snapshot_import")
        }
    }

    private static func preserveRolePoliciesInSnapshot(db: Database) throws {
        let policies = snapshotShadowTable(for: "v2_group_role_policies")
        let rooms = snapshotShadowTable(for: "v2_room_profile_projections")
        let revisions = snapshotShadowTable(for: "v2_group_permission_revisions")
        let rows = try Row.fetchAll(db, sql: """
            SELECT live.* FROM v2_group_role_policies AS live JOIN \(rooms) AS room ON room.room_id = live.room_id
            WHERE room.delivery_mode = ? AND room.is_group_event_authorized = 1
            """, arguments: [V2GroupDeliveryMode.largeGroupHybrid.rawValue])
        for live in rows {
            let room: String = live["room_id"]
            let role: String = live["role"]
            let revision: Int64 = live["revision"]
            var sequence: Int64? = live["room_sequence"]
            var source: String? = live["source_event_id"]
            var digest: Data? = live["canonical_digest"]
            if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(policies) WHERE room_id = ? AND role = ?", arguments: [room, role]) {
                let currentRevision: Int64 = current["revision"]
                if currentRevision > revision { continue }
                if currentRevision == revision {
                    let currentSource: String? = current["source_event_id"]
                    let currentSequence: Int64? = current["room_sequence"]
                    guard (current["permissions"] as Data) == (live["permissions"] as Data),
                          currentSource == nil || source == nil || (currentSource == source && (current["canonical_digest"] as Data?) == digest),
                          sequence == nil || currentSequence == nil || sequence == currentSequence
                    else { throw V2ClientProjectionError.invalidMessagePayload }
                    source = source ?? currentSource
                    digest = digest ?? current["canonical_digest"]
                    sequence = sequence ?? currentSequence
                }
            }
            try db.execute(sql: """
                INSERT INTO \(policies) (room_id, role, permissions, revision, room_sequence, source_event_id, canonical_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_id, role) DO UPDATE SET permissions = excluded.permissions, revision = excluded.revision,
                    room_sequence = excluded.room_sequence, source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
                """, arguments: [room, role, live["permissions"] as Data, revision, sequence, source, digest])
        }
        // A role's independent ordering never lowers the global revision used
        // by commands, including when the other role is not locally known.
        try db.execute(sql: """
            INSERT INTO \(revisions) (room_id, revision)
            SELECT live.room_id, live.revision FROM v2_group_permission_revisions AS live
            JOIN \(rooms) AS room ON room.room_id = live.room_id
            WHERE room.delivery_mode = ? AND room.is_group_event_authorized = 1
            ON CONFLICT(room_id) DO UPDATE SET revision = MAX(\(revisions).revision, excluded.revision)
            """, arguments: [V2GroupDeliveryMode.largeGroupHybrid.rawValue])
    }

    private static func applyRolePolicy(
        _ effect: V2LocalRolePolicyEffect,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let receipts = target.table("v2_role_policy_effects")
        let policies = target.table("v2_group_role_policies")
        let revisions = target.table("v2_group_permission_revisions")
        if let receipt = try Row.fetchOne(db, sql: "SELECT * FROM \(receipts) WHERE source_event_id = ? AND room_id = ?", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue]) {
            let sequence: Int64? = receipt["room_sequence"]
            guard (receipt["role"] as String) == effect.role.rawValue,
                  (receipt["revision"] as Int64) == effect.revision,
                  (receipt["canonical_digest"] as Data) == effect.digest,
                  sequence == nil || effect.roomSequence == nil || sequence == effect.roomSequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if sequence == nil, let sequence = effect.roomSequence {
                try db.execute(sql: "UPDATE \(receipts) SET room_sequence = ? WHERE source_event_id = ? AND room_id = ?", arguments: [sequence, effect.sourceEventID.rawValue, effect.roomID.rawValue])
                try db.execute(sql: "UPDATE \(policies) SET room_sequence = ? WHERE room_id = ? AND source_event_id = ? AND room_sequence IS NULL", arguments: [sequence, effect.roomID.rawValue, effect.sourceEventID.rawValue])
            }
            return
        }
        try db.execute(sql: "INSERT INTO \(receipts) (source_event_id, room_id, role, revision, room_sequence, canonical_digest) VALUES (?, ?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.role.rawValue, effect.revision, effect.roomSequence, effect.digest])
        if let baseline = try Row.fetchOne(db, sql: "SELECT * FROM \(target.table("v2_group_role_policy_baselines")) WHERE room_id = ?", arguments: [effect.roomID.rawValue]), (baseline["permission_revision"] as Int64) >= effect.revision {
            if (baseline["permission_revision"] as Int64) == effect.revision {
                let column = effect.role == .admin ? "admin_permissions" : "member_permissions"
                guard (baseline[column] as Data) == effect.encodedPermissions else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            return
        }
        var sequence = effect.roomSequence
        if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(policies) WHERE room_id = ? AND role = ?", arguments: [effect.roomID.rawValue, effect.role.rawValue]) {
            let revision: Int64 = current["revision"]
            if revision > effect.revision { return }
            if revision == effect.revision {
                let source: String? = current["source_event_id"]
                let currentSequence: Int64? = current["room_sequence"]
                guard (current["permissions"] as Data) == effect.encodedPermissions,
                      source == nil || (source == effect.sourceEventID.rawValue && (current["canonical_digest"] as Data?) == effect.digest),
                      currentSequence == nil || sequence == nil || currentSequence == sequence
                else { throw V2ClientProjectionError.invalidMessagePayload }
                sequence = sequence ?? currentSequence
            }
        }
        try db.execute(sql: """
            INSERT INTO \(policies) (room_id, role, permissions, revision, room_sequence, source_event_id, canonical_digest)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id, role) DO UPDATE SET permissions = excluded.permissions, revision = excluded.revision,
                room_sequence = excluded.room_sequence, source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.role.rawValue, effect.encodedPermissions, effect.revision, sequence, effect.sourceEventID.rawValue, effect.digest])
        try db.execute(sql: "INSERT INTO \(revisions) (room_id, revision) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET revision = MAX(\(revisions).revision, excluded.revision)", arguments: [effect.roomID.rawValue, effect.revision])
    }

    private static func migrateRolePolicyEffects(db: Database) throws {
        if try !db.tableExists("v2_group_role_policies") { try db.execute(sql: rolePolicyProjectionSchemaSQL) }
        if try !db.tableExists("v2_role_policy_effects") { try db.execute(sql: rolePolicyEffectsSchemaSQL) }
        if try db.tableExists("v2_group_role_permissions") {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM v2_group_role_permissions ORDER BY room_id, role, permission")
            let byRoom = Dictionary(grouping: rows, by: { $0["room_id"] as String })
            for (rawRoom, roomRows) in byRoom {
                guard UUID(uuidString: rawRoom) != nil else { throw V2ClientProjectionError.invalidMessagePayload }
                let room = try RoomID(rawRoom)
                for (role, roleRows) in Dictionary(grouping: roomRows, by: { $0["role"] as String }) {
                    guard let parsedRole = V2RoomMembershipRole(rawValue: role), parsedRole != .owner,
                          let first = roleRows.first else { throw V2ClientProjectionError.invalidMessagePayload }
                    let revision: Int64 = first["revision"]
                    let permissions = roleRows.compactMap { V2GroupPermission(rawValue: $0["permission"] as String) }
                    guard revision > 0, Set(permissions).count == roleRows.count,
                          roleRows.allSatisfy({ ($0["revision"] as Int64) == revision }) else { throw V2ClientProjectionError.invalidMessagePayload }
                    let encoded = try JSONEncoder().encode(permissions.map(\.rawValue).sorted())
                    if let current = try Row.fetchOne(db, sql: "SELECT revision, permissions FROM v2_group_role_policies WHERE room_id = ? AND role = ?", arguments: [room.rawValue, role]) {
                        let currentRevision: Int64 = current["revision"]
                        if currentRevision > revision { continue }
                        if currentRevision == revision, (current["permissions"] as Data) != encoded { throw V2ClientProjectionError.invalidMessagePayload }
                    }
                    // Preserve an observed nonempty value, but never assign its
                    // personal cursor as source sequence or invent an event ID.
                    try db.execute(sql: "INSERT INTO v2_group_role_policies (room_id, role, permissions, revision) VALUES (?, ?, ?, ?) ON CONFLICT(room_id, role) DO UPDATE SET permissions = excluded.permissions, revision = excluded.revision", arguments: [room.rawValue, role, encoded, revision])
                }
            }
            try db.execute(sql: "DROP TABLE v2_group_role_permissions")
        }
        // Empty legacy roles have no rows. Neither a room-wide revision nor
        // absence of a retained event proves that the role uses defaults.
        // They stay absent until a source fact or a complete baseline arrives.
        let revisions = try Row.fetchAll(db, sql: "SELECT room_id, revision FROM v2_group_permission_revisions")
        try db.execute(sql: "DELETE FROM v2_group_permission_revisions")
        for row in revisions {
            let room = try RoomID(row["room_id"] as String)
            try db.execute(sql: "INSERT INTO v2_group_permission_revisions (room_id, revision) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET revision = MAX(v2_group_permission_revisions.revision, excluded.revision)", arguments: [room.rawValue, row["revision"] as Int64])
        }
        if try db.tableExists(snapshotShadowTable(for: "v2_message_projections")) {
            try dropSnapshotShadowTables(db: db)
            try db.execute(sql: "DELETE FROM v2_snapshot_import")
        }
        try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotShadowTable(for: "v2_group_role_permissions"))")
    }

    private static func applyGroupCapability(
        _ record: V2ClientSyncRecord,
        target: ProjectionTableTarget = .live,
        expectedRoomSequence: UInt64? = nil,
        expectedRoomID: RoomID? = nil,
        db: Database
    ) throws {
        let memberRoles = target.table("v2_group_member_roles")
        let header = try V2ClientGroupCapabilityProjection.header(record.payload)
        switch header.eventType {
        case "message.pinned_changed":
            try applyPinnedMessage(V2LocalPinnedMessageEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.announcement_changed":
            try applyAnnouncement(V2LocalAnnouncementEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.role_permissions_changed":
            try applyRolePolicy(V2LocalRolePolicyEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.member_role_changed":
            let value = try JSONDecoder().decode(V2ClientGroupCapabilityProjection.MemberRole.self, from: record.payload)
            _ = try RoomID(value.roomID); _ = try UserID(value.targetUserID)
            guard let role = V2RoomMembershipRole(rawValue: value.role) else { throw V2ClientProjectionError.invalidMessagePayload }
            try db.execute(sql: "INSERT INTO \(memberRoles) (room_id, user_id, role, membership_revision, room_sequence) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id, user_id) DO UPDATE SET role = excluded.role, membership_revision = excluded.membership_revision, room_sequence = excluded.room_sequence WHERE excluded.membership_revision >= \(memberRoles).membership_revision", arguments: [value.roomID, value.targetUserID, role.rawValue, try storageInteger(value.membershipRevision), try storageInteger(record.sequence)])
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func applyRelationship(_ record: V2ClientSyncRecord, target tableTarget: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let targetUserID: String; let state: String; let requestedByUserID: String?; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case state; case requestedByUserID = "requested_by_user_id"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard let state = V2RelationshipState(rawValue: payload.state) else { throw V2ClientSocialProjectionError.invalidPayload }
        let target: UserID; let requester: UserID?
        do { target = try .init(payload.targetUserID); requester = try payload.requestedByUserID.map(UserID.init) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard (state == .pending) == (requester != nil) else { throw V2ClientSocialProjectionError.invalidPayload }
        let table = tableTarget.table("v2_relationship_projections")
        try db.execute(sql: "INSERT INTO \(table) (target_user_id, state, requested_by_user_id, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(target_user_id) DO UPDATE SET state = excluded.state, requested_by_user_id = excluded.requested_by_user_id, updated_at = excluded.updated_at", arguments: [target.rawValue, state.rawValue, requester?.rawValue, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyUserBlock(_ record: V2ClientSyncRecord, target tableTarget: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let targetUserID: String; let isBlocked: Bool; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case isBlocked = "is_blocked"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let target: UserID
        do { target = try .init(payload.targetUserID) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let table = tableTarget.table("v2_user_block_projections")
        try db.execute(sql: "INSERT INTO \(table) (target_user_id, is_blocked, updated_at) VALUES (?, ?, ?) ON CONFLICT(target_user_id) DO UPDATE SET is_blocked = excluded.is_blocked, updated_at = excluded.updated_at", arguments: [target.rawValue, payload.isBlocked, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyStrangerMessagePermission(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let allowsStrangerMessages: Bool; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case allowsStrangerMessages = "allows_stranger_messages"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let table = target.table("v2_stranger_message_preference")
        try db.execute(sql: "INSERT INTO \(table) (singleton, allows_stranger_messages, updated_at) VALUES (1, ?, ?) ON CONFLICT(singleton) DO UPDATE SET allows_stranger_messages = excluded.allows_stranger_messages, updated_at = excluded.updated_at", arguments: [payload.allowsStrangerMessages, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyUserAddPermission(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let allowsBeingAdded: Bool; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case allowsBeingAdded = "allows_being_added"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let table = target.table("v2_user_add_preference")
        try db.execute(sql: "INSERT INTO \(table) (singleton, allows_being_added, updated_at) VALUES (1, ?, ?) ON CONFLICT(singleton) DO UPDATE SET allows_being_added = excluded.allows_being_added, updated_at = excluded.updated_at", arguments: [payload.allowsBeingAdded, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyDirectReadReceipt(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let roomID: String; let readerUserID: String; let readThroughRoomSequence: UInt64; let recordedAtMilliseconds: Int64; let isVisible: Bool; enum CodingKeys: String, CodingKey { case roomID = "room_id", readerUserID = "reader_user_id", readThroughRoomSequence = "read_through_room_sequence", recordedAtMilliseconds = "recorded_at_ms", isVisible = "is_visible" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let roomID: RoomID; let readerID: UserID
        do { roomID = try .init(payload.roomID); readerID = try .init(payload.readerUserID) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard payload.readThroughRoomSequence > 0, payload.readThroughRoomSequence <= UInt64(Int64.max), payload.recordedAtMilliseconds >= 0 else { throw V2ClientSocialProjectionError.invalidPayload }
        let table = target.table("v2_direct_read_receipt_projections")
        if payload.isVisible {
            try db.execute(sql: "INSERT INTO \(table) (room_id, reader_user_id, read_through_room_sequence, recorded_at) VALUES (?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET reader_user_id = excluded.reader_user_id, read_through_room_sequence = MAX(\(table).read_through_room_sequence, excluded.read_through_room_sequence), recorded_at = CASE WHEN excluded.read_through_room_sequence >= \(table).read_through_room_sequence THEN excluded.recorded_at ELSE \(table).recorded_at END", arguments: [roomID.rawValue, readerID.rawValue, try Self.storageInteger(payload.readThroughRoomSequence), Double(payload.recordedAtMilliseconds) / 1_000])
        } else {
            try db.execute(sql: "DELETE FROM \(table) WHERE room_id = ? AND reader_user_id = ?", arguments: [roomID.rawValue, readerID.rawValue])
        }
    }
    private static func applyReadReceiptPreference(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let allowsDirect: Bool; let allowsGroup: Bool; let updatedAt: Int64; enum CodingKeys: String, CodingKey { case allowsDirect = "allows_direct_read_receipts", allowsGroup = "allows_group_read_receipts", updatedAt = "updated_at_ms" } }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: record.payload), payload.updatedAt >= 0 else { throw V2ClientSocialProjectionError.invalidPayload }
        let table = target.table("v2_read_receipt_preference")
        try db.execute(sql: "INSERT INTO \(table) (singleton, allows_direct_read_receipts, allows_group_read_receipts, updated_at) VALUES (1, ?, ?, ?) ON CONFLICT(singleton) DO UPDATE SET allows_direct_read_receipts = excluded.allows_direct_read_receipts, allows_group_read_receipts = excluded.allows_group_read_receipts, updated_at = excluded.updated_at", arguments: [payload.allowsDirect, payload.allowsGroup, Double(payload.updatedAt) / 1_000])
    }
    private static func persist(_ projection: V2ClientConversationState, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_conversation_states")
        try db.execute(sql: "INSERT INTO \(table) (room_id, is_pinned, is_archived, mute_until, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET is_pinned = excluded.is_pinned, is_archived = excluded.is_archived, mute_until = excluded.mute_until, updated_at = excluded.updated_at", arguments: [projection.roomID.rawValue, projection.isPinned, projection.isArchived, projection.muteUntil?.timeIntervalSince1970 ?? 0, projection.updatedAt.timeIntervalSince1970])
    }
    private static func persist(_ projection: V2ClientMessageFavorite, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_message_favorites")
        try db.execute(sql: "INSERT INTO \(table) (message_id, room_id, is_favorited, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(message_id) DO UPDATE SET room_id = excluded.room_id, is_favorited = excluded.is_favorited, updated_at = excluded.updated_at", arguments: [projection.messageID.rawValue, projection.roomID.rawValue, projection.isFavorited, projection.updatedAt.timeIntervalSince1970])
    }

    private static func applyModeration(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Header: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        switch header.eventType {
        case "member.muted": try persist(V2ClientModerationProjection(record: record), target: target, db: db)
        case "room.frozen", "room.unfrozen": try persist(V2ClientRoomControlProjection(record: record), target: target, db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func persist(
        _ projection: V2ClientMessageProjection,
        updateConversationSummary: Bool = true,
        enqueueSearchIndex: Bool = true,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let messages = target.table("v2_message_projections")
        let tombstones = target.table("v2_message_tombstones")
        if let existing = try Row.fetchOne(db, sql: "SELECT * FROM \(messages) WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let decoded = try decodeMessageProjection(existing)
            if projection.messageRevision < decoded.messageRevision {
                guard decoded.hasSameAcceptance(as: projection) else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
            guard decoded.sourceEventID == projection.sourceEventID, decoded.messageID == projection.messageID,
                  decoded.roomID == projection.roomID, decoded.roomSequence == projection.roomSequence, decoded.timelineSequence == projection.timelineSequence,
                  decoded.messageRevision == projection.messageRevision, decoded.senderUserID == projection.senderUserID,
                  decoded.text == projection.text, decoded.media == projection.media, decoded.mediaPresentations == projection.mediaPresentations,
                  decoded.mentions == projection.mentions, decoded.entities == projection.entities, decoded.replyTo == projection.replyTo, decoded.forwardedFrom == projection.forwardedFrom, decoded.createdAt == projection.createdAt,
                  decoded.isWithdrawn == projection.isWithdrawn
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(
            sql: """
            INSERT INTO \(messages)
                (message_id, source_event_id, room_id, room_sequence, timeline_sequence, message_revision, sender_user_id, text_body, media_ids, media_presentations, mention_targets, entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, server_created_at, is_withdrawn)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [projection.messageID.rawValue, projection.sourceEventID.rawValue, projection.roomID.rawValue,
                        try storageInteger(projection.roomSequence), try storageInteger(projection.timelineSequence), try storageInteger(projection.messageRevision), projection.senderUserID.rawValue, projection.text, try encodeMedia(projection.media), try encodeMediaPresentations(projection.mediaPresentations), try encodeMentions(projection.mentions), try encodeEntities(projection.entities, text: projection.text), projection.replyTo?.messageID.rawValue, projection.forwardedFrom?.messageID.rawValue, projection.forwardedFrom?.senderUserID.rawValue,
                        projection.createdAt.timeIntervalSince1970, projection.isWithdrawn]
        )
        if let tombstone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM \(tombstones) WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let roomID: String = tombstone["room_id"]
            let revision: Int64 = tombstone["message_revision"]
            guard roomID == projection.roomID.rawValue, revision > (try storageInteger(projection.messageRevision)) else { throw V2ClientProjectionError.invalidMessagePayload }
            try redactLocalMessageProjection(messageID: projection.messageID, revision: revision, target: target, db: db)
        }
        if updateConversationSummary {
            try upsertConversationSummary(for: projection, db: db)
        }
        if enqueueSearchIndex {
            try enqueueMessageSearchIndexJob(messageID: projection.messageID, db: db)
        }
    }

    private static func upsertConversationSummary(
        for projection: V2ClientMessageProjection,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO v2_conversation_summaries (room_id, message_id)
            VALUES (?, ?)
            ON CONFLICT(room_id) DO UPDATE SET message_id = excluded.message_id
            WHERE ? > (
                SELECT existing.room_sequence
                FROM v2_message_projections AS existing
                WHERE existing.message_id = v2_conversation_summaries.message_id
            )
            """,
            arguments: [projection.roomID.rawValue, projection.messageID.rawValue, try storageInteger(projection.roomSequence)]
        )
    }

    private static func rebuildConversationSummaries(
        messages: String = "v2_message_projections",
        summaries: String = "v2_conversation_summaries",
        db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO \(summaries) (room_id, message_id)
            SELECT room_id, message_id
            FROM (
                SELECT room_id, message_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY room_id
                           ORDER BY room_sequence DESC, message_id DESC
                       ) AS room_rank
                FROM \(messages)
            )
            WHERE room_rank = 1
            """)
    }

    private static func persist(_ projection: V2ClientTimelineActivityProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let timelineSequence = try storageInteger(projection.timelineSequence)
        let table = target.table("v2_timeline_activity_projections")
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, timeline_sequence, event_type, server_created_at FROM \(table) WHERE source_event_id = ?", arguments: [projection.sourceEventID.rawValue]) {
            guard (row["room_id"] as String) == projection.roomID.rawValue,
                  (row["timeline_sequence"] as Int64) == timelineSequence,
                  (row["event_type"] as String) == projection.kind.rawValue,
                  (row["server_created_at"] as Double) == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (source_event_id, room_id, timeline_sequence, event_type, server_created_at) VALUES (?, ?, ?, ?, ?)", arguments: [projection.sourceEventID.rawValue, projection.roomID.rawValue, timelineSequence, projection.kind.rawValue, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientDirectSendingCapability, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_direct_sending_capabilities")
        if let row = try Row.fetchOne(db, sql: "SELECT can_send, updated_at FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let existingTime = row["updated_at"] as Double
            guard existingTime <= projection.updatedAt.timeIntervalSince1970 else { throw V2ClientProjectionError.invalidMessagePayload }
            if existingTime == projection.updatedAt.timeIntervalSince1970 {
                guard (row["can_send"] as Bool) == projection.canSend else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, can_send, updated_at) VALUES (?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET can_send = excluded.can_send, updated_at = excluded.updated_at", arguments: [projection.roomID.rawValue, projection.canSend, projection.updatedAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientModerationProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_moderation_projections")
        if let existing = try Row.fetchOne(db, sql: "SELECT room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at FROM \(table) WHERE source_event_id = ?", arguments: [projection.sourceEventID.rawValue]) {
            let roomID: String = existing["room_id"]
            let sequence: Int64 = existing["room_sequence"]
            let actorUserID: String = existing["actor_user_id"]
            let targetUserID: String = existing["target_user_id"]
            let muteUntil: Double = existing["mute_until"]
            let createdAt: Double = existing["server_created_at"]
            guard roomID == projection.roomID.rawValue, sequence == (try storageInteger(projection.roomSequence)),
                  actorUserID == projection.actorUserID.rawValue, targetUserID == projection.targetUserID.rawValue,
                  muteUntil == projection.muteUntil.timeIntervalSince1970, createdAt == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (source_event_id, room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [projection.sourceEventID.rawValue, projection.roomID.rawValue, try storageInteger(projection.roomSequence), projection.actorUserID.rawValue, projection.targetUserID.rawValue, projection.muteUntil.timeIntervalSince1970, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientRoomControlProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_room_control_projections")
        if let existing = try Row.fetchOne(db, sql: "SELECT room_sequence FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let sequence: Int64 = existing["room_sequence"]
            let projectionSequence = try storageInteger(projection.roomSequence)
            guard sequence < projectionSequence else {
                if sequence == projectionSequence { return }
                throw V2ClientProjectionError.invalidMessagePayload
            }
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, source_event_id, room_sequence, actor_user_id, is_frozen, server_created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET source_event_id = excluded.source_event_id, room_sequence = excluded.room_sequence, actor_user_id = excluded.actor_user_id, is_frozen = excluded.is_frozen, server_created_at = excluded.server_created_at", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, try storageInteger(projection.roomSequence), projection.actorUserID.rawValue, projection.isFrozen, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientRoomProfileProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_room_profile_projections")
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, title, owner_user_id, delivery_mode, membership_revision, created_at FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let sourceEventID: String = existing["source_event_id"]; let title: String = existing["title"]
            let ownerUserID: String = existing["owner_user_id"]; let deliveryMode: String = existing["delivery_mode"]
            let membershipRevision: Int64 = existing["membership_revision"]; let createdAt: Double = existing["created_at"]
            let incomingRevision = try storageInteger(projection.membershipRevision)
            guard title == projection.title, ownerUserID == projection.ownerUserID.rawValue,
                  deliveryMode == projection.deliveryMode.rawValue,
                  createdAt == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            guard membershipRevision <= incomingRevision else { throw V2ClientProjectionError.invalidMessagePayload }
            if membershipRevision == incomingRevision {
                guard sourceEventID == projection.sourceEventID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
            try db.execute(sql: "UPDATE \(table) SET source_event_id = ?, membership_revision = ?, is_group_event_authorized = 1 WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, incomingRevision, projection.roomID.rawValue])
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, source_event_id, title, owner_user_id, delivery_mode, membership_revision, is_group_event_authorized, created_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.title, projection.ownerUserID.rawValue, projection.deliveryMode.rawValue, try storageInteger(projection.membershipRevision), projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientDirectRoomProfileProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_direct_room_profile_projections")
        func grantRoomEventAccessIfLive() throws {
            guard case .live = target else { return }
            try db.execute(
                sql: "INSERT INTO v2_room_event_authorizations (room_id, is_authorized) VALUES (?, 1) ON CONFLICT(room_id) DO UPDATE SET is_authorized = excluded.is_authorized",
                arguments: [projection.roomID.rawValue]
            )
        }
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, target_user_id, public_handle, display_name, account_kind, revision FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let existingRevision: Int64 = existing["revision"]
            let incomingRevision = try storageInteger(projection.revision)
            guard existingRevision <= incomingRevision else { throw V2ClientProjectionError.invalidMessagePayload }
            if existingRevision == incomingRevision {
                guard (existing["source_event_id"] as String) == projection.sourceEventID.rawValue,
                      (existing["target_user_id"] as String) == projection.publicIdentity.userID.rawValue,
                      (existing["public_handle"] as String) == projection.publicIdentity.handle.rawValue,
                      (existing["display_name"] as String) == projection.publicIdentity.displayName,
                      (existing["account_kind"] as String) == projection.publicIdentity.accountKind.rawValue
                else { throw V2ClientProjectionError.invalidMessagePayload }
                try persist(profileView(from: projection), target: target, db: db)
                return
            }
            try db.execute(sql: "UPDATE \(table) SET source_event_id = ?, target_user_id = ?, public_handle = ?, display_name = ?, account_kind = ?, revision = ?, updated_at = ? WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, projection.publicIdentity.accountKind.rawValue, incomingRevision, projection.updatedAt.timeIntervalSince1970, projection.roomID.rawValue])
            try persist(profileView(from: projection), target: target, db: db)
            try grantRoomEventAccessIfLive()
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, source_event_id, target_user_id, public_handle, display_name, account_kind, revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, projection.publicIdentity.accountKind.rawValue, try storageInteger(projection.revision), projection.updatedAt.timeIntervalSince1970])
        try persist(profileView(from: projection), target: target, db: db)
        try grantRoomEventAccessIfLive()
    }

    private static func profileView(from projection: V2ClientDirectRoomProfileProjection) throws -> V2ProfileView {
        guard let revision = V2ProfileRevision(rawValue: projection.revision) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try .init(
            userID: projection.publicIdentity.userID,
            publicIdentity: projection.publicIdentity,
            avatar: nil,
            state: .active,
            revision: revision,
            visibilityRevision: revision
        )
    }

    private static func persist(_ profile: V2ProfileView, target: ProjectionTableTarget = .live, db: Database) throws {
        let incomingRevision = try storageInteger(profile.revision.rawValue)
        let incomingVisibilityRevision = try storageInteger(profile.visibilityRevision.rawValue)
        let table = target.table("v2_profile_views")
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM \(table) WHERE user_id = ?",
            arguments: [profile.userID.rawValue]
        ) {
            let existingRevision: Int64 = existing["revision"]
            let existingVisibilityRevision: Int64 = existing["visibility_revision"]
            guard existingRevision <= incomingRevision, existingVisibilityRevision <= incomingVisibilityRevision else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            if existingRevision == incomingRevision, existingVisibilityRevision == incomingVisibilityRevision {
                guard (existing["public_handle"] as String?) == profile.publicIdentity?.handle.rawValue,
                      (existing["display_name"] as String?) == profile.publicIdentity?.displayName,
                      (existing["account_kind"] as String?) == profile.publicIdentity?.accountKind.rawValue,
                      (existing["avatar_media_id"] as String?) == profile.avatar?.mediaID.rawValue,
                      (existing["state"] as String) == profile.state.rawValue
                else { throw V2ClientProjectionError.invalidMessagePayload }
                try clearSatisfiedInvalidation(for: profile, target: target, db: db)
                return
            }
            try db.execute(
                sql: "UPDATE \(table) SET public_handle = ?, display_name = ?, account_kind = ?, avatar_media_id = ?, state = ?, revision = ?, visibility_revision = ?, updated_at = ? WHERE user_id = ?",
                arguments: [profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.publicIdentity?.accountKind.rawValue, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970, profile.userID.rawValue]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO \(table) (user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [profile.userID.rawValue, profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.publicIdentity?.accountKind.rawValue, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970]
            )
        }
        try clearSatisfiedInvalidation(for: profile, target: target, db: db)
    }

    private static func persist(_ invalidation: V2ClientProfileInvalidation, target: ProjectionTableTarget = .live, db: Database) throws {
        let revision = try storageInteger(invalidation.minimumRevision.rawValue)
        let profileViews = target.table("v2_profile_views")
        let invalidations = target.table("v2_profile_invalidations")
        let directProfiles = target.table("v2_direct_room_profile_projections")
        if invalidation.state != .active {
            // A suspended/hidden/deleted identity must disappear from the
            // direct-room identity projection in the same sync transaction;
            // waiting for a later profile fetch would briefly re-expose it.
            try db.execute(
                sql: "DELETE FROM \(directProfiles) WHERE target_user_id = ?",
                arguments: [invalidation.userID.rawValue]
            )
            if case .live = target {
                try db.execute(
                    sql: "DELETE FROM v2_direct_room_identities WHERE target_user_id = ?",
                    arguments: [invalidation.userID.rawValue]
                )
            }
        }
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT revision FROM \(profileViews) WHERE user_id = ?",
            arguments: [invalidation.userID.rawValue]
        ) {
            let existingRevision: Int64 = existing["revision"]
            if existingRevision >= revision { return }
        }
        try db.execute(
            sql: """
            INSERT INTO \(invalidations) (user_id, minimum_revision, profile_state, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                minimum_revision = MAX(\(invalidations).minimum_revision, excluded.minimum_revision),
                profile_state = CASE
                    WHEN excluded.minimum_revision >= \(invalidations).minimum_revision
                    THEN excluded.profile_state
                    ELSE \(invalidations).profile_state
                END,
                updated_at = excluded.updated_at
            """,
            arguments: [invalidation.userID.rawValue, revision, invalidation.state.rawValue, Date().timeIntervalSince1970]
        )
    }

    private static func clearSatisfiedInvalidation(for profile: V2ProfileView, target: ProjectionTableTarget = .live, db: Database) throws {
        let invalidations = target.table("v2_profile_invalidations")
        try db.execute(
            sql: "DELETE FROM \(invalidations) WHERE user_id = ? AND minimum_revision <= ?",
            arguments: [profile.userID.rawValue, try storageInteger(profile.revision.rawValue)]
        )
    }

    private static func persist(_ tombstone: V2ClientMessageTombstone, db: Database) throws {
        let tombstoneRevision = try storageInteger(tombstone.messageRevision)
        if let existing = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [tombstone.messageID.rawValue]) {
            let roomID: String = existing["room_id"]
            let revision: Int64 = existing["message_revision"]
            guard roomID == tombstone.roomID.rawValue, revision == tombstoneRevision else { throw V2ClientProjectionError.invalidMessagePayload }
        } else {
            try db.execute(sql: "INSERT INTO v2_message_tombstones (message_id, source_event_id, room_id, message_revision) VALUES (?, ?, ?, ?)", arguments: [tombstone.messageID.rawValue, tombstone.sourceEventID.rawValue, tombstone.roomID.rawValue, try storageInteger(tombstone.messageRevision)])
        }
        try db.execute(
            sql: "DELETE FROM v2_message_reactions WHERE message_id = ?",
            arguments: [tombstone.messageID.rawValue]
        )
        if let projection = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ?", arguments: [tombstone.messageID.rawValue]) {
            let roomID: String = projection["room_id"]
            let revision: Int64 = projection["message_revision"]
            guard roomID == tombstone.roomID.rawValue, revision <= tombstoneRevision else { throw V2ClientProjectionError.invalidMessagePayload }
            if revision == tombstoneRevision {
                // Snapshot activation may have installed this terminal value
                // without the source-event effect claim. Validate materialized
                // content, then consume the late event without another FTS job.
                let current = try decodeMessageProjection(projection)
                guard current.isWithdrawn, current.text == "[removed]",
                      current.media.isEmpty, current.mediaPresentations.isEmpty,
                      current.mentions.isEmpty, current.entities.isEmpty,
                      current.forwardedFrom == nil
                else { throw V2ClientProjectionError.invalidMessagePayload }
                if current.replyTo != nil {
                    try db.execute(sql: "UPDATE v2_message_projections SET reply_to_message_id = NULL WHERE message_id = ?", arguments: [tombstone.messageID.rawValue])
                }
                return
            }
            try redactLocalMessageProjection(messageID: tombstone.messageID, revision: try storageInteger(tombstone.messageRevision), db: db)
            try enqueueMessageSearchIndexJob(messageID: tombstone.messageID, db: db)
        }
    }

    /// Tombstones are durable permission revocations, not merely a rendering
    /// flag. Remove content-bearing local columns before the search-index job
    /// runs so a crash cannot leave text, media references, entities or
    /// mention targets available through another local feature.
    private static func redactLocalMessageProjection(
        messageID: MessageID,
        revision: Int64,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let messages = target.table("v2_message_projections")
        try db.execute(
            sql: """
            UPDATE \(messages)
            SET message_revision = ?, is_withdrawn = 1, text_body = '[removed]',
                media_ids = '[]', media_presentations = '[]',
                mention_targets = '[]', entities = '[]',
                reply_to_message_id = NULL, forwarded_from_message_id = NULL, forwarded_from_user_id = NULL
            WHERE message_id = ?
            """,
            arguments: [revision, messageID.rawValue]
        )
    }

    private static func persistReplacement(_ replacement: V2ClientMessageReplacement, db: Database) throws {
        let value = replacement.projection
        let incoming = try storageInteger(value.messageRevision)
        if let stone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [value.messageID.rawValue]) {
            guard (stone["room_id"] as String) == value.roomID.rawValue, incoming < (stone["message_revision"] as Int64)
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ?", arguments: [value.messageID.rawValue]) else {
            try persist(value, db: db)
            return
        }
        let current = try decodeMessageProjection(row)
        guard current.hasSameAcceptance(as: value) else { throw V2ClientProjectionError.invalidMessagePayload }
        if current.messageRevision > value.messageRevision { return }
        guard !current.isWithdrawn else { throw V2ClientProjectionError.invalidMessagePayload }
        if current.messageRevision == value.messageRevision {
            guard current == value else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "UPDATE v2_message_projections SET message_revision = ?, text_body = ?, media_ids = ?, media_presentations = ?, mention_targets = ?, entities = ?, reply_to_message_id = ?, forwarded_from_message_id = ?, forwarded_from_user_id = ? WHERE message_id = ?",
            arguments: [incoming, value.text, try encodeMedia(value.media), try encodeMediaPresentations(value.mediaPresentations), try encodeMentions(value.mentions), try encodeEntities(value.entities, text: value.text), value.replyTo?.messageID.rawValue, value.forwardedFrom?.messageID.rawValue, value.forwardedFrom?.senderUserID.rawValue, value.messageID.rawValue])
        try enqueueMessageSearchIndexJob(messageID: value.messageID, db: db)
    }

    private static func persist(_ edit: V2ClientMessageEditProjection, db: Database) throws {
        if case .complete(let replacement) = edit.content {
            try persistReplacement(replacement, db: db)
            return
        }
        let incoming = try storageInteger(edit.messageRevision)
        if let tombstone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [edit.messageID.rawValue]) {
            guard (tombstone["room_id"] as String) == edit.roomID.rawValue,
                  incoming < (tombstone["message_revision"] as Int64)
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        guard let row = try Row.fetchOne(db, sql: "SELECT room_id, message_revision, is_withdrawn, text_body, entities FROM v2_message_projections WHERE message_id = ?", arguments: [edit.messageID.rawValue]) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let roomID: String = row["room_id"]
        let revision: Int64 = row["message_revision"]
        let isWithdrawn: Bool = row["is_withdrawn"]
        guard roomID == edit.roomID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
        // A newer applied revision or an authoritative snapshot already
        // contains this historical effect. Never restore older text.
        if incoming < revision { return }
        guard !isWithdrawn else { throw V2ClientProjectionError.invalidMessagePayload }
        if incoming == revision {
            guard (row["text_body"] as String) == edit.text,
                  (row["entities"] as String) == "[]"
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        guard revision < Int64.max, incoming == revision + 1 else { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: "UPDATE v2_message_projections SET text_body = ?, entities = '[]', message_revision = ? WHERE message_id = ?", arguments: [edit.text, incoming, edit.messageID.rawValue])
        try enqueueMessageSearchIndexJob(messageID: edit.messageID, db: db)
    }

    private static func applyReaction(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, expectedRoomSequence: UInt64? = nil, db: Database) throws {
        let effect = try V2LocalReactionEffect(record: record)
        if let expectedRoomSequence, UInt64(effect.roomSequence) != expectedRoomSequence { throw V2ClientProjectionError.invalidMessagePayload }
        let reaction = effect.reaction
        let receipts = target.table("v2_reaction_effects"), versions = target.table("v2_reaction_versions")
        let key: StatementArguments = [reaction.messageID.rawValue, reaction.actorUserID.rawValue, reaction.reaction]
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, canonical_digest FROM \(receipts) WHERE source_event_id = ? AND message_id = ? AND actor_user_id = ? AND reaction = ?", arguments: [effect.sourceEventID.rawValue, reaction.messageID.rawValue, reaction.actorUserID.rawValue, reaction.reaction]) {
            guard (row["room_id"] as String) == reaction.roomID.rawValue, (row["canonical_digest"] as Data) == effect.digest else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(receipts) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction, effect.roomSequence, effect.digest])
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, room_sequence, source_event_id, canonical_digest FROM \(versions) WHERE message_id = ? AND actor_user_id = ? AND reaction = ?", arguments: key) {
            guard (row["room_id"] as String) == reaction.roomID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
            let current: Int64 = row["room_sequence"]
            if current > effect.roomSequence { return }
            if current == effect.roomSequence {
                guard (row["source_event_id"] as String) == effect.sourceEventID.rawValue, (row["canonical_digest"] as Data) == effect.digest else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
        }
        try db.execute(sql: """
            INSERT INTO \(versions) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id, actor_user_id, reaction) DO UPDATE SET room_sequence = excluded.room_sequence,
                source_event_id = excluded.source_event_id, action = excluded.action, canonical_digest = excluded.canonical_digest
            """, arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction, effect.roomSequence, effect.sourceEventID.rawValue, effect.action.rawValue, effect.digest])
        let withdrawn = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(target.table("v2_message_tombstones")) WHERE message_id = ?) OR EXISTS(SELECT 1 FROM \(target.table("v2_message_projections")) WHERE message_id = ? AND is_withdrawn = 1)", arguments: [reaction.messageID.rawValue, reaction.messageID.rawValue]) == true
        let table = target.table("v2_message_reactions")
        if effect.action == .add && !withdrawn {
            try db.execute(sql: "INSERT INTO \(table) (message_id, room_id, actor_user_id, reaction) VALUES (?, ?, ?, ?) ON CONFLICT(message_id, actor_user_id, reaction) DO NOTHING", arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction])
        } else {
            try db.execute(sql: "DELETE FROM \(table) WHERE message_id = ? AND actor_user_id = ? AND reaction = ?", arguments: key)
        }
    }

    private static func preserveReactionEffectsInSnapshot(db: Database) throws {
        try db.execute(sql: """
            INSERT INTO \(snapshotShadowTable(for: "v2_reaction_effects"))
            SELECT effect.* FROM v2_reaction_effects AS effect
            JOIN \(snapshotShadowTable(for: "v2_reaction_versions")) AS state
              ON state.message_id = effect.message_id AND state.room_id = effect.room_id
             AND state.actor_user_id = effect.actor_user_id AND state.reaction = effect.reaction
             AND state.room_sequence >= effect.room_sequence
            ON CONFLICT DO NOTHING
            """)
    }

    static func decodeMessageProjection(_ row: Row) throws -> V2ClientMessageProjection {
        let sourceEventID = try EventID(row["source_event_id"] as String)
        let messageID = try MessageID(row["message_id"] as String)
        let roomID = try RoomID(row["room_id"] as String)
        let senderUserID = try UserID(row["sender_user_id"] as String)
        let text: String = row["text_body"]
        let roomSequence = try projectionStorageUnsigned(row["room_sequence"] as Int64)
        let timelineSequence = try projectionStorageUnsigned(row["timeline_sequence"] as Int64)
        let messageRevision = try projectionStorageUnsigned(row["message_revision"] as Int64)
        let media = try decodeMedia(row["media_ids"])
        let mediaPresentations = try decodeMediaPresentations(row["media_presentations"])
        let mentions = try decodeMentions(row["mention_targets"])
        let entities = try decodeEntities(row["entities"], text: text)
        let replyTo = try (row["reply_to_message_id"] as String?).map { try V2MessageReplyReference(messageID: .init($0)) }
        let forwardedFromMessageID: String? = row["forwarded_from_message_id"]
        let forwardedFromUserID: String? = row["forwarded_from_user_id"]
        let forwardedFrom: V2ForwardedMessageAttribution?
        switch (forwardedFromMessageID, forwardedFromUserID) {
        case (nil, nil):
            forwardedFrom = nil
        case let (.some(messageID), .some(userID)) where !messageID.isEmpty && !userID.isEmpty:
            forwardedFrom = try .init(messageID: .init(messageID), senderUserID: .init(userID))
        default:
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return .init(
            sourceEventID: sourceEventID,
            messageID: messageID,
            roomID: roomID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            messageRevision: messageRevision,
            senderUserID: senderUserID,
            text: text,
            media: media,
            mediaPresentations: mediaPresentations,
            mentions: mentions,
            entities: entities,
            replyTo: replyTo,
            forwardedFrom: forwardedFrom,
            createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double),
            isWithdrawn: (row["is_withdrawn"] as Int64) != 0
        )
    }

    private static func decodeTimelineActivity(_ row: Row) throws -> V2ClientTimelineActivityProjection {
        guard let kind = V2ClientTimelineActivityProjection.Kind(rawValue: row["event_type"] as String) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try .init(
            sourceEventID: .init(row["source_event_id"] as String),
            roomID: .init(row["room_id"] as String),
            timelineSequence: projectionStorageUnsigned(row["timeline_sequence"] as Int64),
            kind: kind,
            createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double)
        )
    }

    private static func decodeModerationProjection(_ row: Row) throws -> V2ClientModerationProjection {
        guard let sequence = UInt64(exactly: row["room_sequence"] as Int64) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try .init(
            sourceEventID: .init(row["source_event_id"] as String),
            roomID: .init(row["room_id"] as String), roomSequence: sequence,
            actorUserID: .init(row["actor_user_id"] as String),
            targetUserID: .init(row["target_user_id"] as String),
            muteUntil: Date(timeIntervalSince1970: row["mute_until"] as Double),
            createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double)
        )
    }

    static func requirePendingCommand(_ clientMessageID: ClientMessageID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_commands WHERE client_message_id = ?", arguments: [clientMessageID.rawValue])?["state"], state == V2PendingMessageCommand.State.pending.rawValue else {
            throw V2ClientCommandError.commandNotPending
        }
    }

    static func requirePendingMembershipCommand(_ operationID: MembershipOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_membership_commands WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMembershipCommand.State.pending.rawValue else {
            throw V2ClientCommandError.commandNotPending
        }
    }

    static func requirePendingMessageWithdrawal(_ operationID: MessageWithdrawalOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_withdrawals WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageWithdrawal.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending }
    }
    static func requirePendingMessageRedaction(_ operationID: ModerationOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_redactions WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageRedaction.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending }
    }
    static func requirePendingMemberMute(_ operationID: ModerationOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_member_mutes WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMemberMute.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingModeratedMemberRemoval(_ operationID: ModerationOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_moderated_member_removals WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingModeratedMemberRemoval.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingMessageReaction(_ operationID: MessageReactionOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_reactions WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageReaction.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending }
    }
    static func requirePendingConversationState(_ operationID: ConversationPreferenceOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_conversation_states WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingConversationStateCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingMessageFavorite(_ operationID: MessageFavoriteOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_favorites WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageFavoriteCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingForwardMessages(_ operationID: MessageForwardOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_forward_messages WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingForwardMessagesCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingMessageEdit(_ operationID: MessageEditOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_edits WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageEdit.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingReadReceipt(_ operationID: ReadReceiptOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_read_receipts WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingReadReceipt.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingSocialCommand(_ operationID: String, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_social_commands WHERE operation_id = ?", arguments: [operationID])?["state"], state == V2PendingSocialCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requirePendingGroupRoomCreation(_ operationID: GroupRoomOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingGroupRoomCreation.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    static func requireActiveGroupRoomCreation(_ operationID: GroupRoomOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingGroupRoomCreation.State.pending.rawValue || state == V2PendingGroupRoomCreation.State.finalizing.rawValue else {
            throw V2ClientCommandError.commandNotPending
        }
    }

    static func decodePendingCommand(_ row: Row) throws -> V2PendingMessageCommand {
        guard let state = V2PendingMessageCommand.State(rawValue: row["state"] as String) else {
            throw V2ClientCommandError.commandConflict
        }
        let acceptedRaw: String? = row["accepted_message_id"]
        let acceptedRoomSequence = try (row["accepted_room_sequence"] as Int64?).map(commandStorageUnsigned)
        return try .init(
            roomID: .init(row["room_id"] as String),
            clientMessageID: .init(row["client_message_id"] as String),
            text: row["text"],
            media: try decodeMedia(row["media_ids"]),
            mentions: try decodeMentions(row["mention_targets"]),
            entities: try decodeEntities(row["entities"], text: row["text"]),
            replyTo: try (row["reply_to_message_id"] as String?).map { try V2MessageReplyReference(messageID: .init($0)) },
            state: state,
            attemptCount: try commandAttemptCount(row),
            nextAttemptAt: try commandRetryDate(row),
            acceptedMessageID: try acceptedRaw.map(MessageID.init),
            acceptedRoomSequence: acceptedRoomSequence,
            terminalCode: row["terminal_code"]
        )
    }

    static func encodeMedia(_ media: [V2MediaReference]) throws -> String {
        guard media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count,
              let encoded = String(data: try JSONEncoder().encode(media.map { $0.mediaID.rawValue }), encoding: .utf8)
        else { throw V2ClientCommandError.commandConflict }
        return encoded
    }

    static func decodeMedia(_ encoded: String) throws -> [V2MediaReference] {
        let rawIDs: [String]
        do { rawIDs = try JSONDecoder().decode([String].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        let media = try rawIDs.map { try V2MediaReference(mediaID: .init($0)) }
        guard media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count
        else { throw V2ClientCommandError.commandConflict }
        return media
    }

    private struct MediaPresentationWire: Codable {
        let mediaID: String
        let kind: V2MediaPresentation.Kind
        let contentType: String
        let byteCount: Int64

        init(_ presentation: V2MediaPresentation) {
            mediaID = presentation.mediaID.rawValue
            kind = presentation.kind
            contentType = presentation.contentType
            byteCount = presentation.byteCount
        }

        func presentation() throws -> V2MediaPresentation {
            try .init(mediaID: .init(mediaID), kind: kind, contentType: contentType, byteCount: byteCount)
        }

        enum CodingKeys: String, CodingKey {
            case mediaID = "media_id"
            case kind
            case contentType = "content_type"
            case byteCount = "byte_count"
        }
    }

    static func encodeMediaPresentations(_ presentations: [V2MediaPresentation]) throws -> String {
        guard let encoded = String(data: try JSONEncoder().encode(presentations.map(MediaPresentationWire.init)), encoding: .utf8) else {
            throw V2ClientCommandError.commandConflict
        }
        return encoded
    }

    static func decodeMediaPresentations(_ encoded: String) throws -> [V2MediaPresentation] {
        let wire: [MediaPresentationWire]
        do { wire = try JSONDecoder().decode([MediaPresentationWire].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        return try wire.map { try $0.presentation() }
    }

    private struct MentionWire: Codable { let kind: String; let userID: String?; enum CodingKeys: String, CodingKey { case kind; case userID = "user_id" } }
    static func encodeMentions(_ mentions: [V2MentionTarget]) throws -> String {
        guard mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2ClientCommandError.commandConflict }
        let wire = mentions.map { target -> MentionWire in
            switch target { case .user(let userID): .init(kind: "user", userID: userID.rawValue); case .everyone: .init(kind: "everyone", userID: nil) }
        }
        guard let encoded = String(data: try JSONEncoder().encode(wire), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }
    static func decodeMentions(_ encoded: String) throws -> [V2MentionTarget] {
        let wire: [MentionWire]
        do { wire = try JSONDecoder().decode([MentionWire].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        let mentions = try wire.map { value -> V2MentionTarget in
            switch value.kind { case "user": guard let userID = value.userID else { throw V2ClientCommandError.commandConflict }; return .user(try .init(userID)); case "everyone": guard value.userID == nil else { throw V2ClientCommandError.commandConflict }; return .everyone; default: throw V2ClientCommandError.commandConflict }
        }
        guard mentions.count <= V2MessageCommandLimits.maxMentions, Set(mentions).count == mentions.count else { throw V2ClientCommandError.commandConflict }
        return mentions
    }

    static func encodeEntities(_ entities: [V2MessageEntity], text: String) throws -> String {
        try V2RichMessageContent.validate(text: text, entities: entities)
        guard let encoded = String(data: try JSONEncoder().encode(entities), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }

    static func decodeEntities(_ encoded: String, text: String) throws -> [V2MessageEntity] {
        let entities: [V2MessageEntity]
        do { entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        try V2RichMessageContent.validate(text: text, entities: entities)
        return entities
    }

    static func decodePendingMembershipCommand(_ row: Row) throws -> V2PendingMembershipCommand {
        guard let state = V2PendingMembershipCommand.State(rawValue: row["state"] as String),
              let action = V2RoomMembershipAction(rawValue: row["action"] as String)
        else { throw V2ClientCommandError.commandConflict }
        let revision = try (row["resulting_membership_revision"] as Int64?).map(commandStorageUnsigned)
        let roomSequence = try (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned)
        let terminalCurrentRevision = try (row["terminal_current_revision"] as Int64?).map(commandStorageUnsigned)
        return try .init(
            roomID: .init(row["room_id"] as String),
            operationID: .init(row["operation_id"] as String),
            targetUserID: .init(row["target_user_id"] as String),
            action: action,
            expectedMembershipRevision: try commandStorageUnsigned(row["expected_membership_revision"] as Int64),
            state: state,
            attemptCount: try commandAttemptCount(row),
            nextAttemptAt: try commandRetryDate(row),
            resultingMembershipRevision: revision,
            resultingRoomSequence: roomSequence,
            terminalCode: row["terminal_code"],
            terminalCurrentRevision: terminalCurrentRevision
        )
    }

    static func decodePendingMessageWithdrawal(_ row: Row) throws -> V2PendingMessageWithdrawal {
        guard let state = V2PendingMessageWithdrawal.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(
            roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String),
            expectedMessageRevision: try commandStorageUnsigned(row["expected_message_revision"] as Int64), state: state,
            attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row),
            resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(commandStorageUnsigned),
            resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned),
            terminalCode: row["terminal_code"], terminalCurrentRevision: (row["terminal_current_revision"] as Int64?).map(commandStorageUnsigned)
        )
    }

    static func decodePendingMessageRedaction(_ row: Row) throws -> V2PendingMessageRedaction {
        guard let state = V2PendingMessageRedaction.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(
            roomID: .init(row["room_id"] as String),
            operationID: .init(row["operation_id"] as String),
            messageID: .init(row["message_id"] as String),
            reasonCode: .init(row["reason_code"] as String),
            state: state,
            attemptCount: try commandAttemptCount(row),
            nextAttemptAt: try commandRetryDate(row),
            resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(commandStorageUnsigned),
            resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned),
            terminalCode: row["terminal_code"]
        )
    }
    static func decodePendingMemberMute(_ row: Row) throws -> V2PendingMemberMute { guard let state = V2PendingMemberMute.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), targetUserID: .init(row["target_user_id"] as String), muteUntil: Date(timeIntervalSince1970: row["mute_until"] as Double), reasonCode: .init(row["reason_code"] as String), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned), terminalCode: row["terminal_code"]) }
    static func decodePendingModeratedMemberRemoval(_ row: Row) throws -> V2PendingModeratedMemberRemoval { guard let state = V2PendingModeratedMemberRemoval.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), targetUserID: .init(row["target_user_id"] as String), reasonCode: .init(row["reason_code"] as String), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), resultingMembershipRevision: (row["resulting_membership_revision"] as Int64?).map(commandStorageUnsigned), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned), terminalCode: row["terminal_code"]) }

    static func decodeRoomControlProjection(_ row: Row) throws -> V2ClientRoomControlProjection {
        let sourceEventID: EventID = try .init(row["source_event_id"] as String)
        let roomID: RoomID = try .init(row["room_id"] as String)
        let actorUserID: UserID = try .init(row["actor_user_id"] as String)
        let sequence = try projectionStorageUnsigned(row["room_sequence"] as Int64)
        guard sequence > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        return try .init(sourceEventID: sourceEventID, roomID: roomID, roomSequence: sequence, actorUserID: actorUserID, isFrozen: row["is_frozen"], createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double))
    }

    static func decodeRoomProfileProjection(_ row: Row) throws -> V2ClientRoomProfileProjection {
        guard let deliveryMode = V2GroupDeliveryMode(rawValue: row["delivery_mode"] as String) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try .init(
            sourceEventID: .init(row["source_event_id"] as String),
            roomID: .init(row["room_id"] as String),
            title: row["title"],
            ownerUserID: .init(row["owner_user_id"] as String),
            deliveryMode: deliveryMode,
            membershipRevision: storageUnsigned(row["membership_revision"] as Int64),
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
        )
    }

    static func decodeDirectRoomIdentity(_ row: Row) throws -> V2ClientDirectRoomIdentity {
        guard let accountKind = V2AccountKind(rawValue: row["account_kind"] as String) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let identity = try V2PublicIdentity(
            userID: .init(row["target_user_id"] as String),
            handle: .init(row["public_handle"] as String),
            displayName: row["display_name"] as String,
            accountKind: accountKind
        )
        return try .init(
            roomID: .init(row["room_id"] as String),
            publicIdentity: identity,
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double)
        )
    }

    static func decodePendingMessageReaction(_ row: Row) throws -> V2PendingMessageReaction {
        guard let state = V2PendingMessageReaction.State(rawValue: row["state"] as String), let action = V2MessageReactionAction(rawValue: row["action"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String), reaction: row["reaction"], action: action, state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned), terminalCode: row["terminal_code"])
    }
    static func decodePendingConversationState(_ row: Row) throws -> V2PendingConversationStateCommand {
        guard let state = V2PendingConversationStateCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let muteUntil = (row["mute_until"] as Double) == 0 ? nil : Date(timeIntervalSince1970: row["mute_until"] as Double)
        return try .init(command: .init(operationID: .init(row["operation_id"] as String), roomID: .init(row["room_id"] as String), isPinned: row["is_pinned"], isArchived: row["is_archived"], muteUntil: muteUntil), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), terminalCode: row["terminal_code"])
    }
    static func decodePendingMessageFavorite(_ row: Row) throws -> V2PendingMessageFavoriteCommand {
        guard let state = V2PendingMessageFavoriteCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(command: .init(operationID: .init(row["operation_id"] as String), roomID: .init(row["room_id"] as String), messageID: .init(row["message_id"] as String), isFavorited: row["is_favorited"]), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), terminalCode: row["terminal_code"])
    }
    static func decodePendingGroupCapability(_ row: Row) throws -> V2PendingGroupCapabilityCommand {
        guard let kind = V2PendingGroupCapabilityCommand.Kind(rawValue: row["kind"] as String), let state = V2PendingGroupCapabilityCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let role = (row["role"] as String?).flatMap(V2RoomMembershipRole.init(rawValue:))
        let rawPermissions = try JSONDecoder().decode([String].self, from: Data((row["permissions"] as String).utf8))
        let permissions = Set(rawPermissions.compactMap(V2GroupPermission.init(rawValue:)))
        guard permissions.count == rawPermissions.count else { throw V2ClientCommandError.commandConflict }
        return try .init(kind: kind, operationID: row["operation_id"], roomID: .init(row["room_id"] as String), messageID: try (row["message_id"] as String?).map(MessageID.init), isPinned: row["is_pinned"], body: row["body"], role: role, permissions: permissions, targetUserID: try (row["target_user_id"] as String?).map(UserID.init), expectedRevision: try storageUnsigned(row["expected_revision"] as Int64), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), terminalCode: row["terminal_code"])
    }
    static func decodeForwardSourceReferences(_ row: Row) throws -> [V2ForwardMessageReference] {
        guard let json: String = row["source_references"] else { throw V2ClientCommandError.commandConflict }
        let sources = try JSONDecoder().decode([V2ForwardMessageReference].self, from: Data(json.utf8))
        let ids = try JSONDecoder().decode([String].self, from: Data((row["source_message_ids"] as String).utf8))
        guard !sources.isEmpty, sources.map({ $0.messageID.rawValue }) == ids,
              Set(sources.map(\.messageID)).count == sources.count
        else { throw V2ClientCommandError.commandConflict }
        return sources
    }
    static func decodePendingForwardMessages(_ row: Row) throws -> V2PendingForwardMessagesCommand {
        guard let state = V2PendingForwardMessagesCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let sources = try decodeForwardSourceReferences(row)
        let targets = try JSONDecoder().decode([String].self, from: Data((row["target_room_ids"] as String).utf8)).map(RoomID.init)
        return try .init(command: .init(operationID: .init(row["operation_id"] as String), sources: sources, targetRoomIDs: targets), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), terminalCode: row["terminal_code"])
    }
    static func decodeForwardMessagesPlan(_ row: Row) throws -> V2ForwardMessagesPlan {
        guard let state = V2ForwardMessagesPlan.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let sources = try JSONDecoder().decode([String].self, from: Data((row["source_message_ids"] as String).utf8))
        let targets = try JSONDecoder().decode([String].self, from: Data((row["target_room_ids"] as String).utf8))
        let progress = try validatedForwardChunkProgress(row, sourceCount: sources.count, targetCount: targets.count)
        guard !targets.isEmpty, sources.count <= Int.max / targets.count else { throw V2ClientCommandError.commandConflict }
        let total = sources.count * targets.count
        let succeededValue: DatabaseValue = row["succeeded_count"]
        let failedValue: DatabaseValue = row["failed_count"]
        guard case .int64(let storedSucceeded) = succeededValue.storage,
              case .int64(let storedFailed) = failedValue.storage,
              let succeeded = Int(exactly: storedSucceeded), let failed = Int(exactly: storedFailed),
              succeeded >= 0, failed >= 0, succeeded <= total, failed <= total - succeeded
        else { throw V2ClientCommandError.commandConflict }
        let completedResults: Int
        if progress.index == progress.total {
            completedResults = total
        } else {
            let index = Int(progress.index)
            let pageSize = V2BulkForwardMessagesOutboxEngine.sourceMessagesPerChunk
            let sourceStart = (index / targets.count) * pageSize
            let chunkSize = min(pageSize, sources.count - sourceStart)
            completedResults = sourceStart * targets.count + (index % targets.count) * chunkSize
        }
        guard succeeded + failed == completedResults else { throw V2ClientCommandError.commandConflict }
        return .init(operationID: try .init(row["plan_id"] as String), sourceMessageCount: sources.count, targetRoomCount: targets.count, totalForwardCount: total, succeededCount: succeeded, failedCount: failed, state: state, terminalCode: row["terminal_code"])
    }
    static func validatedForwardChunkProgress(_ row: Row, sourceCount: Int, targetCount: Int) throws -> (index: Int64, total: Int64) {
        guard sourceCount > 0, targetCount > 0 else { throw V2ClientCommandError.commandConflict }
        let pageSize = V2BulkForwardMessagesOutboxEngine.sourceMessagesPerChunk
        let pages = sourceCount / pageSize + (sourceCount % pageSize == 0 ? 0 : 1)
        let (expected, overflow) = pages.multipliedReportingOverflow(by: targetCount)
        let indexValue: DatabaseValue = row["next_chunk_index"]
        let totalValue: DatabaseValue = row["total_chunk_count"]
        guard !overflow, let expectedCount = Int64(exactly: expected),
              case .int64(let index) = indexValue.storage,
              case .int64(let total) = totalValue.storage,
              total == expectedCount, index >= 0, index <= total
        else { throw V2ClientCommandError.commandConflict }
        return (index, total)
    }
    static func decodeForwardPlanChunk(_ row: Row) throws -> V2PendingForwardMessagesCommand {
        guard let state = V2PendingForwardMessagesCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let sources = try decodeForwardSourceReferences(row)
        let target = try RoomID(row["target_room_id"] as String)
        return try .init(command: .init(operationID: try .init(row["operation_id"] as String), sources: sources, targetRoomIDs: [target]), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), terminalCode: row["terminal_code"])
    }

    static func advanceForwardPlan(planID: String, completedChunkIndex: Int64, succeeded: Int, failed: Int, now: Date, db: Database) throws {
        guard succeeded >= 0, failed >= 0,
              let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_forward_message_plans WHERE plan_id = ?", arguments: [planID]),
              let state = V2ForwardMessagesPlan.State(rawValue: row["state"] as String), state == .active
        else { throw V2ClientCommandError.commandConflict }
        let plan = try decodeForwardMessagesPlan(row)
        let remaining = plan.totalForwardCount - plan.succeededCount - plan.failedCount
        guard succeeded <= remaining, failed <= remaining - succeeded else { throw V2ClientCommandError.commandConflict }
        let nextChunkIndex: Int64 = row["next_chunk_index"]
        let totalChunkCount: Int64 = row["total_chunk_count"]
        guard nextChunkIndex == completedChunkIndex, completedChunkIndex >= 0,
              completedChunkIndex < totalChunkCount else { throw V2ClientCommandError.commandConflict }
        let next = completedChunkIndex + 1
        try db.execute(
            sql: "UPDATE v2_forward_message_plans SET next_chunk_index = ?, succeeded_count = ?, failed_count = ?, state = ?, updated_at = ? WHERE plan_id = ?",
            arguments: [next, plan.succeededCount + succeeded, plan.failedCount + failed, next == totalChunkCount ? V2ForwardMessagesPlan.State.completed.rawValue : V2ForwardMessagesPlan.State.active.rawValue, try Self.commandRetryTimestamp(now), planID]
        )
    }
    static func decodePendingMessageEdit(_ row: Row) throws -> V2PendingMessageEdit {
        guard let state = V2PendingMessageEdit.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String), expectedMessageRevision: try commandStorageUnsigned(row["expected_message_revision"] as Int64), text: row["text_body"], state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(commandStorageUnsigned), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned), terminalCode: row["terminal_code"], terminalCurrentRevision: (row["terminal_current_revision"] as Int64?).map(commandStorageUnsigned))
    }
    static func decodePendingReadReceipt(_ row: Row) throws -> V2PendingReadReceipt { guard let state = V2PendingReadReceipt.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), readThroughRoomSequence: try commandStorageUnsigned(row["read_through_room_sequence"] as Int64), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(commandStorageUnsigned), terminalCode: row["terminal_code"]) }
    static func decodePendingSocialCommand(_ row: Row) throws -> V2PendingSocialCommand {
        guard let kind = V2PendingSocialCommandKind(rawValue: row["command_kind"] as String), let state = V2PendingSocialCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(operationID: row["operation_id"], kind: kind, targetUserID: try (row["target_user_id"] as String?).map(UserID.init), relationshipAction: (row["relationship_action"] as String?).flatMap(V2RelationshipAction.init), blockAction: (row["block_action"] as String?).flatMap(V2UserBlockAction.init), strangerPermission: (row["stranger_permission"] as String?).flatMap(V2StrangerMessagePermission.init), userAddPermission: (row["user_add_permission"] as String?).flatMap(V2UserAddPermission.init), allowsDirectReadReceipts: row["allows_direct_read_receipts"], allowsGroupReadReceipts: row["allows_group_read_receipts"], state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), terminalCode: row["terminal_code"])
    }
    static func encodeGroupMemberUserIDs(_ members: [UserID]) throws -> String {
        guard let encoded = String(data: try JSONEncoder().encode(members.map(\.rawValue)), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }
    static func decodeGroupMemberUserIDs(_ encoded: String) throws -> [UserID] {
        try JSONDecoder().decode([String].self, from: Data(encoded.utf8)).map(UserID.init)
    }
    static func decodePendingGroupRoomCreation(_ row: Row) throws -> V2PendingGroupRoomCreation {
        let membersData = Data((row["initial_member_user_ids"] as String).utf8)
        let members = try JSONDecoder().decode([String].self, from: membersData).map(UserID.init)
        guard let state = V2PendingGroupRoomCreation.State(rawValue: row["state"] as String),
              let deliveryMode = V2GroupDeliveryMode(rawValue: row["delivery_mode"] as String)
        else { throw V2ClientCommandError.commandConflict }
        return try .init(operationID: .init(row["operation_id"] as String), title: row["title"], deliveryMode: deliveryMode, initialMemberUserIDs: members, uploadedMemberCount: commandNonnegativeInteger(row["uploaded_member_count"]), state: state, attemptCount: try commandAttemptCount(row), nextAttemptAt: try commandRetryDate(row), createdRoomID: try (row["created_room_id"] as String?).map(RoomID.init), terminalCode: row["terminal_code"])
    }

    enum V2MessageSearchRebuildOutcome {
        case advanced(Int64)
        case finished
        case restartRequired
    }


    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCurrentV2Schema") { db in
            try db.execute(sql: currentSchemaSQL)
        }
        // Preserve existing account outboxes. Older completed chunks have no
        // recoverable result: leave their digest nil and reject unverifiable
        // replays instead of fabricating a receipt or incrementing counts.
        migrator.registerMigration("addForwardChunkCompletionDigest") { db in
            if try !db.columns(in: "v2_forward_message_chunks").contains(where: { $0.name == "completion_digest" }) {
                try db.execute(sql: "ALTER TABLE v2_forward_message_chunks ADD COLUMN completion_digest TEXT")
            }
        }
        migrator.registerMigration("bindForwardSourceReferences") { db in
            for table in ["v2_pending_forward_messages", "v2_forward_message_plans", "v2_forward_message_chunks"] {
                if try !db.columns(in: table).contains(where: { $0.name == "source_references" }) {
                    try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN source_references TEXT")
                }
            }
            if try !db.columns(in: "v2_forward_message_plans").contains(where: { $0.name == "terminal_code" }) {
                try db.execute(sql: "ALTER TABLE v2_forward_message_plans ADD COLUMN terminal_code TEXT")
            }
            // The old queue never recorded the selected version. A current
            // projection cannot recover that intent, even if its room is known.
            // Preserve completed counts/receipts and terminalize only work that
            // cannot be replayed safely. The user must explicitly select again.
            try db.execute(sql: "UPDATE v2_pending_forward_messages SET state = 'rejected', terminal_code = 'SOURCE_RESELECTION_REQUIRED' WHERE state = 'pending' AND source_references IS NULL")
            try db.execute(sql: "UPDATE v2_forward_message_chunks SET state = 'cancelled', terminal_code = 'SOURCE_RESELECTION_REQUIRED' WHERE state = 'pending' AND (source_references IS NULL OR plan_id IN (SELECT plan_id FROM v2_forward_message_plans WHERE state = 'active' AND source_references IS NULL))")
            try db.execute(sql: "UPDATE v2_forward_message_plans SET state = 'cancelled', terminal_code = 'SOURCE_RESELECTION_REQUIRED', updated_at = unixepoch('now') WHERE state = 'active' AND source_references IS NULL")
        }
        migrator.registerMigration("useUUIDForwardChunkIdentities") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT operation_id, plan_id, chunk_index FROM v2_forward_message_chunks WHERE state = 'pending'")
            for row in rows {
                let operation: String = row["operation_id"]
                // Valid UUIDs may already have been accepted. Never re-key
                // them, or terminal chunks, during an upgrade.
                if UUID(uuidString: operation) != nil { continue }
                let plan: String = row["plan_id"]
                let index: Int64 = row["chunk_index"]
                guard operation == "\(plan)-f\(index)", UUID(uuidString: plan) != nil, index >= 0 else {
                    try db.execute(sql: "UPDATE v2_forward_message_chunks SET state = 'cancelled', terminal_code = 'SOURCE_RESELECTION_REQUIRED' WHERE plan_id = ? AND state = 'pending'", arguments: [plan])
                    try db.execute(sql: "UPDATE v2_forward_message_plans SET state = 'cancelled', terminal_code = 'SOURCE_RESELECTION_REQUIRED', updated_at = unixepoch('now') WHERE plan_id = ? AND state = 'active'", arguments: [plan])
                    continue
                }
                // This exact legacy spelling could never pass the server's
                // UUID parser, so no accepted server identity is changed.
                let id = try V2ForwardChunkIdentity.operationID(planID: .init(plan), chunkIndex: UInt64(index))
                try db.execute(sql: "UPDATE v2_forward_message_chunks SET operation_id = ? WHERE operation_id = ? AND state = 'pending'", arguments: [id.rawValue, operation])
            }
        }
        migrator.registerMigration("recordSharedMessageEffects") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS v2_message_effects (
                    source_event_id TEXT NOT NULL,
                    projection_kind TEXT NOT NULL CHECK (projection_kind = 'message'),
                    entity_key TEXT NOT NULL,
                    room_id TEXT NOT NULL,
                    message_revision INTEGER NOT NULL CHECK (message_revision > 0),
                    canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
                    PRIMARY KEY (source_event_id, projection_kind, entity_key)
                )
                """)
            // Existing durable feeds already prove application. Streaming the
            // records backfills hashes without retaining a second message body.
            for table in ["v2_sync_events", "v2_group_events"] {
                let rows = try Row.fetchCursor(db, sql: "SELECT source_event_id, payload FROM \(table) WHERE projection_kind = 'message'")
                while let row = try rows.next() {
                    let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: try .init(row["source_event_id"] as String), projectionKind: "message", payload: row["payload"])
                    _ = try claimMessageEffect(V2LocalMessageEffect(record: record), sourceEventID: record.sourceEventID, db: db)
                }
            }
            if try db.tableExists(snapshotShadowTable(for: "v2_message_projections")),
               try !db.tableExists(snapshotShadowTable(for: "v2_message_effects")) {
                try createSnapshotShadowTable(for: "v2_message_effects", db: db)
                if try Bool.fetchOne(db, sql: "SELECT activation_prepared FROM v2_snapshot_import LIMIT 1") == true {
                    try preserveMessageEffectsInSnapshot(db: db)
                }
            }
        }
        migrator.registerMigration("orderReactionEffects") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS v2_reaction_versions (
                message_id TEXT NOT NULL, room_id TEXT NOT NULL, actor_user_id TEXT NOT NULL,
                reaction TEXT NOT NULL, room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                source_event_id TEXT NOT NULL, action TEXT NOT NULL CHECK (action IN ('add','remove')),
                canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
                PRIMARY KEY (message_id, actor_user_id, reaction)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS v2_reaction_effects (
                source_event_id TEXT NOT NULL, message_id TEXT NOT NULL, room_id TEXT NOT NULL,
                actor_user_id TEXT NOT NULL, reaction TEXT NOT NULL,
                room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
                PRIMARY KEY (source_event_id, message_id, actor_user_id, reaction)
                )
                """)
            for table in ["v2_sync_events", "v2_group_events"] {
                let rows = try Row.fetchCursor(db, sql: "SELECT source_event_id, payload FROM \(table) WHERE projection_kind = 'message_reaction'")
                while let row = try rows.next() {
                    try applyReaction(.init(sequence: 1, sourceEventID: try .init(row["source_event_id"] as String), projectionKind: "message_reaction", payload: row["payload"]), db: db)
                }
            }
            if try db.tableExists(snapshotShadowTable(for: "v2_message_projections")) {
                // Older staged reaction rows discarded their source version.
                // Keep the live bank and pending reset, but fetch the immutable
                // snapshot again instead of activating an unversioned shadow.
                try dropSnapshotShadowTables(db: db)
                try db.execute(sql: "DELETE FROM v2_snapshot_import")
            }
        }
        migrator.registerMigration("recordSnapshotRebuildIntent") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS v2_sync_rebuild_requests (singleton INTEGER PRIMARY KEY CHECK (singleton = 1))")
        }
        migrator.registerMigration("orderAnnouncementEffects") { db in
            try migrateAnnouncementEffects(db: db)
        }
        migrator.registerMigration("orderRolePolicyEffects") { db in
            try migrateRolePolicyEffects(db: db)
        }
        migrator.registerMigration("recordRolePolicyRecovery") { db in
            if try !db.tableExists("v2_group_role_policy_baselines") { try db.execute(sql: rolePolicyBaselineSchemaSQL) }
            if try !db.tableExists("v2_role_policy_recovery_requests") { try db.execute(sql: rolePolicyRecoverySchemaSQL) }
            if try db.tableExists(snapshotShadowTable(for: "v2_message_projections")) {
                try dropSnapshotShadowTables(db: db)
                try db.execute(sql: "DELETE FROM v2_snapshot_import")
            }
        }
        migrator.registerMigration("scheduleRolePolicyRecovery") { db in
            if try !db.columns(in: "v2_role_policy_recovery_requests").contains(where: { $0.name == "attempt_count" }) {
                try db.execute(sql: "ALTER TABLE v2_role_policy_recovery_requests ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0 AND attempt_count <= 2147483647)")
                try db.execute(sql: "ALTER TABLE v2_role_policy_recovery_requests ADD COLUMN next_attempt_at REAL NOT NULL DEFAULT 0")
                try db.execute(sql: "ALTER TABLE v2_role_policy_recovery_requests ADD COLUMN state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'paused'))")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS v2_role_policy_recovery_due_idx ON v2_role_policy_recovery_requests (next_attempt_at, room_id) WHERE state = 'pending'")
        }
        migrator.registerMigration("orderPinnedMessageEffects") { db in
            try migratePinnedMessageEffects(db: db)
        }
        migrator.registerMigration("recordPushIntent") { db in
            if try !db.tableExists("v2_push_intent") { try db.execute(sql: pushIntentSchemaSQL) }
        }
        return migrator
    }()

    static let messageSearchMigrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCurrentV2MessageSearchSchema") { db in
            try db.execute(sql: """
                CREATE TABLE v2_search_documents (
                    message_id TEXT PRIMARY KEY,
                    message_revision INTEGER NOT NULL CHECK (message_revision > 0),
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    room_id TEXT NOT NULL,
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                    sender_user_id TEXT NOT NULL,
                    text_body TEXT NOT NULL,
                    media_presentations TEXT NOT NULL,
                    server_created_at REAL NOT NULL
                );
                CREATE INDEX v2_search_documents_room_order_idx
                    ON v2_search_documents (room_id, room_sequence DESC, message_id DESC);
                CREATE INDEX v2_search_documents_global_order_idx
                    ON v2_search_documents (server_created_at DESC, message_id DESC);
                CREATE INDEX v2_search_documents_sender_order_idx
                    ON v2_search_documents (sender_user_id, server_created_at DESC, message_id DESC);
                CREATE VIRTUAL TABLE v2_message_char_fts USING fts5(
                    room_scope,
                    sender_scope,
                    unigrams,
                    bigrams,
                    tokenize = 'ascii',
                    detail = full,
                    columnsize = 0
                );
            """)
        }
        return migrator
    }()

    static let terminalCommandTables = [
        "v2_pending_message_commands",
        "v2_pending_membership_commands",
        "v2_pending_message_withdrawals",
        "v2_pending_message_redactions",
        "v2_pending_member_mutes",
        "v2_pending_moderated_member_removals",
        "v2_pending_message_edits",
        "v2_pending_read_receipts",
        "v2_pending_message_reactions",
        "v2_pending_conversation_states",
        "v2_pending_message_favorites",
        "v2_pending_group_capabilities",
        "v2_pending_forward_messages",
        "v2_pending_social_commands",
        "v2_pending_group_room_creations"
    ]
}

private enum TimelinePageCandidate {
    case message(V2ClientMessageProjection)
    case activity(V2ClientTimelineActivityProjection)

    var timelineSequence: UInt64 {
        switch self {
        case .message(let message): message.timelineSequence
        case .activity(let activity): activity.timelineSequence
        }
    }

    var itemID: String {
        switch self {
        case .message(let message): message.messageID.rawValue
        case .activity(let activity): activity.sourceEventID.rawValue
        }
    }

    var cursor: V2ClientTimelineCursor {
        .init(timelineSequence: timelineSequence, itemID: itemID, kind: kind)
    }

    var kind: V2ClientTimelineItemKind {
        switch self { case .message: .message; case .activity: .activity }
    }

    var message: V2ClientMessageProjection? {
        guard case .message(let message) = self else { return nil }
        return message
    }

    var activity: V2ClientTimelineActivityProjection? {
        guard case .activity(let activity) = self else { return nil }
        return activity
    }

    static func newerFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        olderFirst(rhs, lhs)
    }

    static func olderFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timelineSequence != rhs.timelineSequence { return lhs.timelineSequence < rhs.timelineSequence }
        if lhs.itemID != rhs.itemID { return lhs.itemID < rhs.itemID }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

public enum V2LocalBackupExclusion {
    public static func apply(to url: URL) throws {
        // The exclusion bit is an Apple backup-service guarantee. Linux has
        // no equivalent resource value, so asserting it there would turn a
        // portable SQLite regression into a false failure. Linux callers are
        // intentionally not told the database is backup-safe.
        #if canImport(Darwin)
        do {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
            let verified = try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            guard verified == true else { throw V2ClientLocalStorageError.backupExclusionVerificationFailed }
        } catch {
            // XCTest uses the process temporary directory, which is already
            // excluded from device backup but does not consistently support
            // NSURLIsExcludedFromBackupKey (notably APFS temp volumes return
            // writErr).  Do not weaken the production storage invariant: the
            // exception is confined to FileManager's ephemeral temp root.
            guard isEphemeralTemporaryPath(url) else { throw error }
        }
        #else
        _ = url
        #endif
    }

    #if canImport(Darwin)
    private static func isEphemeralTemporaryPath(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return candidate == temporaryRoot || candidate.hasPrefix(temporaryRoot + "/")
    }
    #endif
}

public enum V2ClientLocalStorageError: Error, Equatable, Sendable {
    case backupExclusionVerificationFailed
    case installationBindingMismatch
}

private extension Optional where Wrapped == V2LocalSyncCursor.State {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
