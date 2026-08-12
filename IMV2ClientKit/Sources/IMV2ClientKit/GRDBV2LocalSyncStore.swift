import Foundation
import GRDB
import IMV2Core

/// V2's local database is intentionally separate from the V1 conversation
/// cache. It applies sync records incrementally in one SQLite transaction.
public actor GRDBV2LocalSyncStore: V2LocalSyncStore, V2LocalCommandStore, V2LocalMembershipCommandStore, V2LocalMessageWithdrawalStore, V2LocalMessageRedactionStore, V2LocalMemberMuteStore, V2LocalModeratedMemberRemovalStore, V2LocalMessageReactionStore, V2LocalMessageEditStore, V2LocalReadReceiptStore, V2LocalConversationCapabilitiesStore, V2LocalGroupCapabilitiesStore, V2LocalForwardMessagesStore, V2BulkForwardMessagesStore, V2LocalSocialCommandStore, V2LocalGroupRoomCommandStore, V2LocalGroupEventStore, V2LocalForegroundGroupEventPreviewStore, V2ClientProfileProjectionStore {
    /// All local command repositories share this actor-owned pool. Extensions
    /// preserve the actor boundary while keeping each durable queue in its
    /// own source file.
    let databasePool: DatabasePool
    /// Search is intentionally a separately-writable derived database. This
    /// prevents FTS maintenance from competing with the authoritative sync
    /// projection writer in `databasePool`.
    let messageSearchDatabasePool: DatabasePool
    let databaseURL: URL
    let messageSearchDatabaseURL: URL

    init(databaseURL: URL, installationBinding: V2LocalInstallationBinding) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: directory)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        databasePool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try databasePool.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try Self.migrator.migrate(databasePool)

        messageSearchDatabaseURL = Self.messageSearchDatabaseURL(for: databaseURL)
        messageSearchDatabasePool = try DatabasePool(path: messageSearchDatabaseURL.path, configuration: configuration)
        try messageSearchDatabasePool.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try Self.messageSearchMigrator.migrate(messageSearchDatabasePool)
        try databasePool.write { db in
            try Self.establishInstallationBinding(installationBinding, db: db)
        }
        try Self.applyBackupExclusion(databaseURL: databaseURL)
        try Self.applyBackupExclusion(databaseURL: messageSearchDatabaseURL)
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

    private static func messageSearchDatabaseURL(for primaryDatabaseURL: URL) -> URL {
        let directory = primaryDatabaseURL.deletingLastPathComponent()
        // Production's V2.sqlite gets the stable, human-readable companion
        // name requested by the storage design. Tests and alternate stores
        // retain a per-primary database to prevent cross-account leakage.
        if primaryDatabaseURL.lastPathComponent == "V2.sqlite" {
            return directory.appending(path: "V2Search.sqlite")
        }
        return directory.appending(path: primaryDatabaseURL.deletingPathExtension().lastPathComponent + ".search.sqlite")
    }

    public func cursor() throws -> V2LocalSyncCursor? {
        try databasePool.read { db in try Self.readCursor(db) }
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

    public func knownHybridGroupRoomIDs() throws -> [RoomID] {
        try databasePool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT room_id FROM v2_room_profile_projections WHERE delivery_mode = ? ORDER BY room_id",
                arguments: [V2GroupDeliveryMode.largeGroupHybrid.rawValue]
            ).map(RoomID.init)
        }
    }

    public func isKnownHybridGroupRoom(roomID: RoomID) throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = ? AND delivery_mode = ?)",
                arguments: [roomID.rawValue, V2GroupDeliveryMode.largeGroupHybrid.rawValue]
            ) ?? false
        }
    }

    public func groupDeliveryMode(roomID: RoomID) throws -> V2GroupDeliveryMode? {
        try databasePool.read { db in
            guard let raw: String = try Row.fetchOne(
                db,
                sql: "SELECT delivery_mode FROM v2_room_profile_projections WHERE room_id = ?",
                arguments: [roomID.rawValue]
            )?["delivery_mode"]
            else { return nil }
            return V2GroupDeliveryMode(rawValue: raw)
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

    public func deactivateHybridGroupRoom(roomID: RoomID) throws {
        try databasePool.write { db in
            try db.execute(
                sql: "UPDATE v2_room_profile_projections SET delivery_mode = NULL WHERE room_id = ? AND delivery_mode = ?",
                arguments: [roomID.rawValue, V2GroupDeliveryMode.largeGroupHybrid.rawValue]
            )
        }
    }

    public func applyGroupEventPage(_ page: V2ClientGroupEventPage) throws -> UInt64 {
        try databasePool.write { db in
            let current: Int64 = try Row.fetchOne(
                db,
                sql: "SELECT applied_room_sequence FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [page.roomID.rawValue]
            )?["applied_room_sequence"] ?? 0
            let cursor = try Self.storageUnsigned(current)
            guard page.nextRoomSequence >= cursor,
                  zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
                  (page.events.last?.roomSequence ?? cursor) == page.nextRoomSequence
            else { throw V2ClientSyncError.invalidRecordOrdering }
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
                let record = V2ClientSyncRecord(sequence: event.roomSequence, sourceEventID: event.sourceEventID, projectionKind: event.projectionKind, payload: event.payload)
                try Self.applyRoomEventProjection(record, db: db)
                try db.execute(
                    sql: "INSERT INTO v2_group_events (room_id, room_sequence, source_event_id, projection_kind, payload) VALUES (?, ?, ?, ?, ?)",
                    arguments: [page.roomID.rawValue, try Self.storageInteger(event.roomSequence), event.sourceEventID.rawValue, event.projectionKind, event.payload]
                )
            }
            try db.execute(
                sql: "INSERT INTO v2_group_event_cursors (room_id, applied_room_sequence) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET applied_room_sequence = excluded.applied_room_sequence",
                arguments: [page.roomID.rawValue, try Self.storageInteger(page.nextRoomSequence)]
            )
            return page.nextRoomSequence
        }
    }

    public func applyForegroundGroupEventPreviewPage(_ page: V2ClientGroupEventPage) throws -> UInt64 {
        try databasePool.write { db in
            guard zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
                  (page.events.last?.roomSequence ?? page.nextRoomSequence) == page.nextRoomSequence
            else { throw V2ClientSyncError.invalidRecordOrdering }
            for event in page.events {
                try Self.applyRoomEventProjection(
                    .init(
                        sequence: event.roomSequence,
                        sourceEventID: event.sourceEventID,
                        projectionKind: event.projectionKind,
                        payload: event.payload
                    ),
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
                    try Self.persist(V2ClientRoomProfileProjection(record: record), db: db)
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
            let needsAcknowledgement = applied > cursor.serverAcknowledgedSequence
            cursor = try .init(
                state: .ready,
                generation: cursor.generation,
                appliedSequence: applied,
                serverAcknowledgedSequence: cursor.serverAcknowledgedSequence,
                syncToken: batch.nextSyncToken,
                pendingAcknowledgementReceipt: needsAcknowledgement ? batch.receipt : nil,
                pendingAcknowledgementSequence: needsAcknowledgement ? applied : nil,
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
            if let current, reset.generation <= current.generation { throw V2ClientSyncError.generationMismatch }
            try Self.writeCursor(try .init(
                state: .resetPending,
                generation: reset.generation,
                appliedSequence: current?.appliedSequence ?? 0,
                serverAcknowledgedSequence: current?.serverAcknowledgedSequence ?? 0,
                syncToken: current?.syncToken,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: reset
            ), db: db)
        }
    }

    public func beginSnapshotStaging(_ manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard let cursor = try Self.readCursor(db), cursor.state == .resetPending, cursor.pendingReset == manifest.reset else {
                throw V2ClientSyncError.resetFenceMismatch
            }
            if try Row.fetchOne(db, sql: "SELECT 1 FROM v2_snapshot_staging LIMIT 1") != nil {
                guard try Self.matchesStaging(manifest, db: db) else { throw V2ClientSyncError.snapshotMismatch }
                return
            }
            try db.execute(
                sql: """
                INSERT INTO v2_snapshot_staging
                    (snapshot_id, generation, base_sequence, manifest_digest, next_sync_token, receipt, capability_profile, page_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [manifest.reset.snapshotID.rawValue, try Self.storageInteger(manifest.reset.generation), try Self.storageInteger(manifest.reset.baseSequence), manifest.reset.manifestDigest, manifest.nextSyncToken.rawValue, manifest.receipt.rawValue, manifest.capabilityProfile, manifest.pageDigests.count]
            )
        }
    }

    public func stagedSnapshotPageIndexes(for manifest: V2ClientSnapshotManifest) throws -> Set<Int> {
        try databasePool.read { db in
            guard try Self.matchesStaging(manifest, db: db) else { throw V2ClientSyncError.snapshotMismatch }
            return Set(try Int.fetchAll(db, sql: "SELECT page_index FROM v2_snapshot_staging_pages ORDER BY page_index"))
        }
    }

    public func stageSnapshotPage(_ page: V2ClientSnapshotPage, for manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            guard try Self.matchesStaging(manifest, db: db),
                  manifest.pageDigests.indices.contains(page.index),
                  manifest.pageDigests[page.index] == page.digest
            else { throw V2ClientSyncError.snapshotMismatch }
            if let existing = try Row.fetchOne(db, sql: "SELECT page_digest, payload FROM v2_snapshot_staging_pages WHERE page_index = ?", arguments: [page.index]) {
                let digest: String = existing["page_digest"]
                let payload: Data = existing["payload"]
                guard digest == page.digest, payload == page.payload else { throw V2ClientSyncError.snapshotMismatch }
                return
            }
            try db.execute(sql: "INSERT INTO v2_snapshot_staging_pages (page_index, page_digest, payload) VALUES (?, ?, ?)", arguments: [page.index, page.digest, page.payload])
        }
    }

    public func commitStagedSnapshot(_ manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard try Self.matchesStaging(manifest, db: db) else { throw V2ClientSyncError.snapshotMismatch }
            let pages = try Row.fetchAll(db, sql: "SELECT page_index, page_digest FROM v2_snapshot_staging_pages ORDER BY page_index")
            guard pages.count == manifest.pageDigests.count else { throw V2ClientSyncError.snapshotMismatch }
            for (index, row) in pages.enumerated() {
                let pageIndex: Int = row["page_index"]
                let digest: String = row["page_digest"]
                guard pageIndex == index, digest == manifest.pageDigests[index] else { throw V2ClientSyncError.snapshotMismatch }
            }
            let snapshotPages = try pages.map { row -> V2SnapshotProjectionPage in
                guard let index: Int = row["page_index"],
                      let payload: Data = try Data.fetchOne(db, sql: "SELECT payload FROM v2_snapshot_staging_pages WHERE page_index = ?", arguments: [index])
                else { throw V2ClientSyncError.snapshotMismatch }
                return try V2SnapshotProjectionCodec.decodePage(payload)
            }
            let snapshotMessages = snapshotPages.flatMap(\.messages)
            let snapshotRelationships = snapshotPages.flatMap(\.relationships)
            let snapshotUserBlocks = snapshotPages.flatMap(\.userBlocks)
            let snapshotPreferences = snapshotPages.compactMap(\.strangerMessagePreference)
            let snapshotUserAddPreferences = snapshotPages.compactMap(\.userAddPreference)
            let snapshotModerationActions = snapshotPages.flatMap(\.moderationActions)
            let snapshotRoomControls = snapshotPages.flatMap(\.roomControls)
            let snapshotRoomProfiles = snapshotPages.flatMap(\.roomProfiles)
            let snapshotDirectRoomProfiles = snapshotPages.flatMap(\.directRoomProfiles)
            let snapshotDirectReadReceipts = snapshotPages.flatMap(\.directReadReceipts)
            let snapshotReadReceiptPreferences = snapshotPages.compactMap(\.readReceiptPreference)
            let snapshotConversationStates = snapshotPages.flatMap(\.conversationStates)
            let snapshotMessageFavorites = snapshotPages.flatMap(\.messageFavorites)
            let snapshotTimelineActivities = snapshotPages.flatMap(\.timelineActivities)
            let snapshotDirectSendingCapabilities = snapshotPages.flatMap(\.directSendingCapabilities)
            var seenMessageIDs = Set<MessageID>()
            var seenRoomPositions = Set<String>()
            var seenSourceEventIDs = Set<EventID>()
            for message in snapshotMessages {
                guard seenMessageIDs.insert(message.messageID).inserted,
                      seenRoomPositions.insert("\(message.roomID.rawValue):\(message.timelineSequence)").inserted,
                      seenSourceEventIDs.insert(message.sourceEventID).inserted
                else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            for action in snapshotModerationActions {
                guard seenRoomPositions.insert("\(action.roomID.rawValue):\(action.roomSequence)").inserted,
                      seenSourceEventIDs.insert(action.sourceEventID).inserted
                else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            for control in snapshotRoomControls {
                guard seenRoomPositions.insert("\(control.roomID.rawValue):\(control.roomSequence)").inserted,
                      seenSourceEventIDs.insert(control.sourceEventID).inserted
                else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            for activity in snapshotTimelineActivities {
                guard seenRoomPositions.insert("\(activity.roomID.rawValue):\(activity.timelineSequence)").inserted,
                      seenSourceEventIDs.insert(activity.sourceEventID).inserted
                else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            for profile in snapshotRoomProfiles {
                guard seenSourceEventIDs.insert(profile.sourceEventID).inserted else {
                    throw V2ClientProjectionError.invalidMessagePayload
                }
            }
            for profile in snapshotDirectRoomProfiles {
                guard seenSourceEventIDs.insert(profile.sourceEventID).inserted else {
                    throw V2ClientProjectionError.invalidMessagePayload
                }
            }
            guard Set(snapshotRoomControls.map(\.roomID)).count == snapshotRoomControls.count else { throw V2ClientProjectionError.invalidMessagePayload }
            guard Set(snapshotRoomProfiles.map(\.roomID)).count == snapshotRoomProfiles.count else { throw V2ClientProjectionError.invalidMessagePayload }
            guard Set(snapshotDirectRoomProfiles.map(\.roomID)).count == snapshotDirectRoomProfiles.count else { throw V2ClientProjectionError.invalidMessagePayload }
            guard Set(snapshotRelationships.map(\.targetUserID)).count == snapshotRelationships.count,
                  Set(snapshotUserBlocks.map(\.targetUserID)).count == snapshotUserBlocks.count,
                  snapshotPreferences.count <= 1,
                  snapshotUserAddPreferences.count <= 1, snapshotReadReceiptPreferences.count <= 1,
                  Set(snapshotDirectReadReceipts.map(\.roomID)).count == snapshotDirectReadReceipts.count,
                  Set(snapshotConversationStates.map(\.roomID)).count == snapshotConversationStates.count,
                  Set(snapshotMessageFavorites.map(\.messageID)).count == snapshotMessageFavorites.count
                  , Set(snapshotDirectSendingCapabilities.map(\.roomID)).count == snapshotDirectSendingCapabilities.count
            else { throw V2ClientSocialProjectionError.invalidPayload }
            try Self.resetMessageSearchIndex(db: db)
            try db.execute(sql: "DELETE FROM v2_sync_events")
            try db.execute(sql: "DELETE FROM v2_message_projections")
            try db.execute(sql: "DELETE FROM v2_message_tombstones")
            try db.execute(sql: "DELETE FROM v2_message_reactions")
            try db.execute(sql: "DELETE FROM v2_moderation_projections")
            try db.execute(sql: "DELETE FROM v2_room_control_projections")
            try db.execute(sql: "DELETE FROM v2_room_profile_projections")
            try db.execute(sql: "DELETE FROM v2_direct_room_profile_projections")
            try db.execute(sql: "DELETE FROM v2_direct_read_receipt_projections")
            try db.execute(sql: "DELETE FROM v2_read_receipt_preference")
            try db.execute(sql: "DELETE FROM v2_profile_views")
            try db.execute(sql: "DELETE FROM v2_profile_invalidations")
            try db.execute(sql: "DELETE FROM v2_relationship_projections")
            try db.execute(sql: "DELETE FROM v2_user_block_projections")
            try db.execute(sql: "DELETE FROM v2_stranger_message_preference")
            try db.execute(sql: "DELETE FROM v2_user_add_preference")
            try db.execute(sql: "DELETE FROM v2_conversation_states")
            try db.execute(sql: "DELETE FROM v2_message_favorites")
            try db.execute(sql: "DELETE FROM v2_timeline_activity_projections")
            try db.execute(sql: "DELETE FROM v2_direct_sending_capabilities")
            for message in snapshotMessages {
                let projection = V2ClientMessageProjection(snapshotProjection: message)
                try Self.persist(projection, db: db)
                for reaction in message.reactions {
                    try Self.persist(.init(roomID: message.roomID, messageID: message.messageID, actorUserID: reaction.actorUserID, reaction: reaction.reaction), action: .add, db: db)
                }
            }
            for relationship in snapshotRelationships { try Self.persist(relationship, db: db) }
            for profile in snapshotRoomProfiles { try Self.persist(V2ClientRoomProfileProjection(snapshotProjection: profile), db: db) }
            for profile in snapshotDirectRoomProfiles { try Self.persist(V2ClientDirectRoomProfileProjection(snapshotProjection: profile), db: db) }
            for receipt in snapshotDirectReadReceipts { try Self.persist(receipt, db: db) }
            for state in snapshotConversationStates { try Self.persist(.init(roomID: state.roomID, isPinned: state.isPinned, isArchived: state.isArchived, muteUntil: state.muteUntil, updatedAt: state.updatedAt), db: db) }
            for favorite in snapshotMessageFavorites { try Self.persist(.init(roomID: favorite.roomID, messageID: favorite.messageID, isFavorited: favorite.isFavorited, updatedAt: favorite.updatedAt), db: db) }
            for activity in snapshotTimelineActivities {
                try Self.persist(.init(sourceEventID: activity.sourceEventID, roomID: activity.roomID, timelineSequence: activity.timelineSequence, kind: .init(rawValue: activity.kind.rawValue)!, createdAt: activity.createdAt), db: db)
            }
            for capability in snapshotDirectSendingCapabilities { try Self.persist(.init(roomID: capability.roomID, canSend: capability.canSend, updatedAt: capability.updatedAt), db: db) }
            for userBlock in snapshotUserBlocks { try Self.persist(userBlock, db: db) }
            if let preference = snapshotPreferences.first { try Self.persist(preference, db: db) }
            if let preference = snapshotUserAddPreferences.first { try Self.persist(preference, db: db) }
            if let preference = snapshotReadReceiptPreferences.first { try Self.persist(preference, db: db) }
            for action in snapshotModerationActions { try Self.persist(.init(snapshotProjection: action), db: db) }
            for control in snapshotRoomControls { try Self.persist(.init(snapshotProjection: control), db: db) }
            try db.execute(sql: "DELETE FROM v2_snapshot_pages")
            try db.execute(
                sql: """
                INSERT INTO v2_snapshots (singleton, snapshot_id, generation, base_sequence, manifest_digest, next_sync_token)
                VALUES (1, ?, ?, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET snapshot_id = excluded.snapshot_id, generation = excluded.generation,
                    base_sequence = excluded.base_sequence, manifest_digest = excluded.manifest_digest,
                    next_sync_token = excluded.next_sync_token, acknowledgement_receipt = NULL
                """,
                arguments: [manifest.reset.snapshotID.rawValue, try Self.storageInteger(manifest.reset.generation), try Self.storageInteger(manifest.reset.baseSequence), manifest.reset.manifestDigest, manifest.nextSyncToken.rawValue]
            )
            try db.execute(sql: "INSERT INTO v2_snapshot_pages (snapshot_id, page_index, page_digest, payload) SELECT ?, page_index, page_digest, payload FROM v2_snapshot_staging_pages ORDER BY page_index", arguments: [manifest.reset.snapshotID.rawValue])
            try db.execute(sql: "DELETE FROM v2_snapshot_staging_pages")
            try db.execute(sql: "DELETE FROM v2_snapshot_staging")
        }
    }

    public func markSnapshotAcknowledged(snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt) throws {
        try databasePool.write { db in
            guard let cursor = try Self.readCursor(db), let reset = cursor.pendingReset, cursor.state == .resetPending else {
                throw V2ClientSyncError.noResetPending
            }
            guard reset.snapshotID == snapshotID, reset.generation == generation, reset.baseSequence == baseSequence else {
                throw V2ClientSyncError.resetFenceMismatch
            }
            guard let snapshot = try Row.fetchOne(db, sql: "SELECT next_sync_token, acknowledgement_receipt FROM v2_snapshots WHERE singleton = 1"),
                  let tokenRaw: String = snapshot["next_sync_token"]
            else { throw V2ClientSyncError.snapshotMismatch }
            let ready = try V2LocalSyncCursor(
                state: .ready,
                generation: generation,
                appliedSequence: baseSequence,
                serverAcknowledgedSequence: baseSequence,
                syncToken: .init(tokenRaw),
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            try Self.writeCursor(ready, db: db)
            try db.execute(sql: "UPDATE v2_snapshots SET acknowledgement_receipt = ? WHERE singleton = 1", arguments: [receipt.rawValue])
        }
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
            let storedRoomID: String = row["room_id"]
            let isPinned: Bool = row["is_pinned"]
            let isArchived: Bool = row["is_archived"]
            let muteUntil: Double = row["mute_until"]
            let updatedAt: Double = row["updated_at"]
            let payload = try JSONSerialization.data(withJSONObject: ["room_id": storedRoomID, "is_pinned": isPinned, "is_archived": isArchived, "mute_until_ms": Int64(muteUntil * 1_000), "updated_at_ms": Int64(updatedAt * 1_000)])
            return try .init(record: .init(sequence: 1, sourceEventID: .init("local-conversation-state"), projectionKind: "conversation_state", payload: payload))
        }
    }

    public func isMessageFavorited(_ messageID: MessageID) throws -> Bool {
        try databasePool.read { db in (try Bool.fetchOne(db, sql: "SELECT is_favorited FROM v2_message_favorites WHERE message_id = ?", arguments: [messageID.rawValue])) ?? false }
    }

    /// A personal collection view over already-authorized local messages.
    /// Favorites are projections, not a second message cache, so withdrawal
    /// and reset behavior stays identical to the ordinary timeline.
    public func favoritedMessages() throws -> [V2ClientMessageProjection] {
        try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT message.*
                FROM v2_message_favorites AS favorite
                INNER JOIN v2_message_projections AS message
                    ON message.message_id = favorite.message_id
                WHERE favorite.is_favorited = 1 AND message.is_withdrawn = 0
                ORDER BY favorite.updated_at DESC, message.message_id DESC
                """
            ).map(Self.decodeMessageProjection)
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

    public func groupRolePolicies(roomID: RoomID) throws -> [V2ClientGroupRolePolicy] {
        try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT role, permission FROM v2_group_role_permissions WHERE room_id = ? ORDER BY role, permission",
                arguments: [roomID.rawValue]
            )
            let permissionsByRole = Dictionary(grouping: rows, by: { $0["role"] as String })
                .mapValues { rows in Set(rows.compactMap { V2GroupPermission(rawValue: $0["permission"] as String) }) }
            let revision = try Self.storageUnsigned(
                (try Int64.fetchOne(db, sql: "SELECT revision FROM v2_group_permission_revisions WHERE room_id = ?", arguments: [roomID.rawValue])) ?? 1
            )
            return [.admin, .member].map { role in
                .init(
                    roomID: roomID,
                    role: role,
                    permissions: permissionsByRole[role.rawValue] ?? V2GroupPermissionDefaults.permissions(for: role),
                    revision: revision
                )
            }
        }
    }

    /// Rebuilds the derived character index in bounded transactions. The
    /// durable message projection remains readable while this runs; callers
    /// should expose `.building` instead of treating a partial index as an
    /// empty search result.

    /// Returns one stable list row per room using only the durable message
    /// projection. A sync transaction completes before this query can observe
    /// it, so a UI never receives a summary whose last message is absent from
    /// the corresponding detail query.
    public func conversationSummaries() throws -> [V2ClientConversationSummary] {
        try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM (
                    SELECT p.*,
                           ROW_NUMBER() OVER (
                               PARTITION BY room_id
                               ORDER BY room_sequence DESC, message_id DESC
                           ) AS room_rank
                    FROM v2_message_projections p
                )
                WHERE room_rank = 1
                ORDER BY server_created_at DESC, room_id ASC
                """
            ).map { row in
                let message = try Self.decodeMessageProjection(row)
                return .init(roomID: message.roomID, lastMessage: message)
            }
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

    public func relationships() throws -> [V2ClientRelationshipProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT target_user_id, state, requested_by_user_id, updated_at FROM v2_relationship_projections ORDER BY target_user_id").map(Self.decodeRelationshipProjection)
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

    public func roomProfiles() throws -> [V2ClientRoomProfileProjection] {
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
        }
    }

    public func directRoomIdentities() throws -> [V2ClientDirectRoomIdentity] {
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
            try Self.persist(profile, db: db)
        }
    }

    /// Deletes an inaccessible view instead of retaining old profile data in
    /// the local account projection. The image cache observes the same signal
    /// at a higher media boundary and must evict any protected avatar bytes.
    public func markProfileUnavailable(userID: UserID) throws {
        try databasePool.write { db in
            try db.execute(sql: "DELETE FROM v2_profile_views WHERE user_id = ?", arguments: [userID.rawValue])
            try db.execute(sql: "DELETE FROM v2_profile_invalidations WHERE user_id = ?", arguments: [userID.rawValue])
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

    private static func establishInstallationBinding(_ binding: V2LocalInstallationBinding, db: Database) throws {
        if let stored: String = try String.fetchOne(db, sql: "SELECT binding FROM v2_local_installation WHERE singleton = 1") {
            guard stored == binding.value.uuidString else { throw V2ClientLocalStorageError.installationBindingMismatch }
            return
        }
        try db.execute(sql: "INSERT INTO v2_local_installation (singleton, binding) VALUES (1, ?)", arguments: [binding.value.uuidString])
    }

    private static func matchesStaging(_ manifest: V2ClientSnapshotManifest, db: Database) throws -> Bool {
        try validatePersistable(manifest)
        guard let row = try Row.fetchOne(db, sql: "SELECT snapshot_id, generation, base_sequence, manifest_digest, next_sync_token, receipt, capability_profile, page_count FROM v2_snapshot_staging LIMIT 1") else {
            return false
        }
        let snapshotID: String = row["snapshot_id"]
        let generation: Int64 = row["generation"]
        let baseSequence: Int64 = row["base_sequence"]
        let digest: String = row["manifest_digest"]
        let token: String = row["next_sync_token"]
        let receipt: String = row["receipt"]
        let profile: String = row["capability_profile"]
        let pageCount: Int64 = row["page_count"]
        let expectedGeneration = try storageInteger(manifest.reset.generation)
        let expectedBaseSequence = try storageInteger(manifest.reset.baseSequence)
        return snapshotID == manifest.reset.snapshotID.rawValue &&
            generation == expectedGeneration &&
            baseSequence == expectedBaseSequence &&
            digest == manifest.reset.manifestDigest &&
            token == manifest.nextSyncToken.rawValue &&
            receipt == manifest.receipt.rawValue &&
            profile == manifest.capabilityProfile &&
            pageCount == Int64(manifest.pageDigests.count)
    }

    private static func readCursor(_ db: Database) throws -> V2LocalSyncCursor? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_sync_cursor WHERE singleton = 1") else { return nil }
        let state = try V2LocalSyncCursor.State(rawValue: row["state"] as String).unwrap(or: V2ClientSyncError.generationMismatch)
        let generation = UInt64(row["generation"] as Int64)
        let applied = UInt64(row["applied_sequence"] as Int64)
        let acknowledged = UInt64(row["server_acknowledged_sequence"] as Int64)
        let token = try (row["sync_token"] as String?).map(V2SyncToken.init)
        let pendingReceipt = try (row["pending_ack_receipt"] as String?).map(V2SyncReceipt.init)
        let pendingSequence = (row["pending_ack_sequence"] as Int64?).map(UInt64.init)
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
              let base: Int64 = row["pending_base_sequence"],
              let digest: String = row["pending_manifest_digest"],
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
            pendingReset: .init(snapshotID: .init(snapshotRaw), generation: generation, baseSequence: UInt64(base), manifestDigest: digest, expiresAt: Date(timeIntervalSince1970: expires))
        )
    }

    private static func writeCursor(_ cursor: V2LocalSyncCursor, db: Database) throws {
        let reset = cursor.pendingReset
        try db.execute(
            sql: """
            INSERT INTO v2_sync_cursor
                (singleton, state, generation, applied_sequence, server_acknowledged_sequence,
                 sync_token, pending_ack_receipt, pending_ack_sequence,
                 pending_snapshot_id, pending_base_sequence, pending_manifest_digest, pending_expires_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET state = excluded.state, generation = excluded.generation,
                applied_sequence = excluded.applied_sequence, server_acknowledged_sequence = excluded.server_acknowledged_sequence,
                sync_token = excluded.sync_token, pending_ack_receipt = excluded.pending_ack_receipt,
                pending_ack_sequence = excluded.pending_ack_sequence,
                pending_snapshot_id = excluded.pending_snapshot_id, pending_base_sequence = excluded.pending_base_sequence,
                pending_manifest_digest = excluded.pending_manifest_digest, pending_expires_at = excluded.pending_expires_at
            """,
            arguments: [cursor.state.rawValue, try storageInteger(cursor.generation), try storageInteger(cursor.appliedSequence), try storageInteger(cursor.serverAcknowledgedSequence), cursor.syncToken?.rawValue, cursor.pendingAcknowledgementReceipt?.rawValue, try cursor.pendingAcknowledgementSequence.map(storageInteger), reset?.snapshotID.rawValue, try reset.map { try storageInteger($0.baseSequence) }, reset?.manifestDigest, reset?.expiresAt.timeIntervalSince1970]
        )
    }

    private static func decodeEvent(_ row: Row) throws -> V2ClientSyncRecord {
        try .init(sequence: UInt64(row["sequence"] as Int64), sourceEventID: .init(row["source_event_id"] as String), projectionKind: row["projection_kind"], payload: row["payload"])
    }

    private static func decodeProfileView(_ row: Row) throws -> V2ProfileView {
        let userID = try UserID(row["user_id"] as String)
        guard let state = V2ProfileState(rawValue: row["state"] as String),
              let revision = V2ProfileRevision(rawValue: try storageUnsigned(row["revision"] as Int64)),
              let visibilityRevision = V2ProfileRevision(rawValue: try storageUnsigned(row["visibility_revision"] as Int64))
        else { throw V2ClientProjectionError.invalidMessagePayload }
        let handle: String? = row["public_handle"]
        let displayName: String? = row["display_name"]
        let accountKind = (row["account_kind"] as String?).flatMap(V2AccountKind.init) ?? .regular
        let avatarMediaID: String? = row["avatar_media_id"]
        let identity: V2PublicIdentity?
        switch (handle, displayName) {
        case (.none, .none): identity = nil
        case let (.some(handle), .some(displayName)):
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

    private static func decodeRelationshipProjection(_ row: Row) throws -> V2ClientRelationshipProjection {
        guard let state = V2RelationshipState(rawValue: row["state"] as String) else { throw V2ClientSocialProjectionError.invalidPayload }
        let requestedBy = try (row["requested_by_user_id"] as String?).map(UserID.init)
        guard (state == .pending) == (requestedBy != nil) else { throw V2ClientSocialProjectionError.invalidPayload }
        return try .init(targetUserID: .init(row["target_user_id"] as String), state: state, requestedByUserID: requestedBy, updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
    }

    private static func decodeBlockProjection(_ row: Row) throws -> V2ClientUserBlockProjection {
        try .init(targetUserID: .init(row["target_user_id"] as String), isBlocked: row["is_blocked"], updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
    }

    private static func applyMessage(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Header: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        switch header.eventType {
        case "message.accepted": try persist(V2ClientMessageProjection(record: record), db: db)
        case "message.edited": try persist(V2ClientMessageEditProjection(record: record), db: db)
        case "message.withdrawn", "message.redacted":
            // A moderator redaction is the same client-visible tombstone
            // shape as an author withdrawal. The server intentionally keeps
            // the audit reason out of this projection, but the message must
            // still become terminal before the sync cursor advances.
            try persist(V2ClientMessageTombstone(record: record), db: db)
        case "message.reaction_changed":
            let reaction = try V2ClientMessageReaction(record: record)
            try persist(reaction, action: try reaction.action(record: record), db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func applyRoomEventProjection(_ record: V2ClientSyncRecord, db: Database) throws {
        switch record.projectionKind {
        case "message": try applyMessage(record, db: db)
        case "moderation": try applyModeration(record, db: db)
        case "room", "membership": try persist(V2ClientRoomProfileProjection(record: record), db: db)
        case "group_capability": try applyGroupCapability(record, db: db)
        case "timeline_activity": try persist(V2ClientTimelineActivityProjection(record: record), db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func applyGroupCapability(_ record: V2ClientSyncRecord, db: Database) throws {
        let header = try V2ClientGroupCapabilityProjection.header(record.payload)
        switch header.eventType {
        case "message.pinned_changed":
            let value = try JSONDecoder().decode(V2ClientGroupCapabilityProjection.Pin.self, from: record.payload)
            _ = try RoomID(value.roomID); _ = try MessageID(value.messageID)
            try db.execute(sql: "INSERT INTO v2_group_pinned_messages (room_id, message_id, is_pinned, room_sequence, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id, message_id) DO UPDATE SET is_pinned = excluded.is_pinned, room_sequence = excluded.room_sequence, updated_at = excluded.updated_at", arguments: [value.roomID, value.messageID, value.isPinned, try storageInteger(record.sequence), Double(value.serverCreatedAtMilliseconds) / 1_000])
        case "group.announcement_changed":
            let value = try JSONDecoder().decode(V2ClientGroupCapabilityProjection.Announcement.self, from: record.payload)
            _ = try RoomID(value.roomID)
            try db.execute(sql: "INSERT INTO v2_group_announcements (room_id, body, revision, room_sequence, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET body = excluded.body, revision = excluded.revision, room_sequence = excluded.room_sequence, updated_at = excluded.updated_at WHERE excluded.revision >= v2_group_announcements.revision", arguments: [value.roomID, value.body, try storageInteger(value.revision), try storageInteger(record.sequence), Double(value.serverCreatedAtMilliseconds) / 1_000])
        case "group.role_permissions_changed":
            let value = try JSONDecoder().decode(V2ClientGroupCapabilityProjection.Permissions.self, from: record.payload)
            guard let role = V2RoomMembershipRole(rawValue: value.role), role != .owner, Set(value.permissions).count == value.permissions.count else { throw V2ClientProjectionError.invalidMessagePayload }
            let permissions = value.permissions.compactMap(V2GroupPermission.init(rawValue:))
            guard permissions.count == value.permissions.count else { throw V2ClientProjectionError.invalidMessagePayload }
            try db.execute(sql: "DELETE FROM v2_group_role_permissions WHERE room_id = ? AND role = ?", arguments: [value.roomID, value.role])
            for permission in permissions { try db.execute(sql: "INSERT INTO v2_group_role_permissions (room_id, role, permission, revision, room_sequence) VALUES (?, ?, ?, ?, ?)", arguments: [value.roomID, value.role, permission.rawValue, try storageInteger(value.revision), try storageInteger(record.sequence)]) }
            try db.execute(sql: "INSERT INTO v2_group_permission_revisions (room_id, revision) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET revision = MAX(v2_group_permission_revisions.revision, excluded.revision)", arguments: [value.roomID, try storageInteger(value.revision)])
        case "group.member_role_changed":
            let value = try JSONDecoder().decode(V2ClientGroupCapabilityProjection.MemberRole.self, from: record.payload)
            _ = try RoomID(value.roomID); _ = try UserID(value.targetUserID)
            guard let role = V2RoomMembershipRole(rawValue: value.role) else { throw V2ClientProjectionError.invalidMessagePayload }
            try db.execute(sql: "INSERT INTO v2_group_member_roles (room_id, user_id, role, membership_revision, room_sequence) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id, user_id) DO UPDATE SET role = excluded.role, membership_revision = excluded.membership_revision, room_sequence = excluded.room_sequence WHERE excluded.membership_revision >= v2_group_member_roles.membership_revision", arguments: [value.roomID, value.targetUserID, role.rawValue, try storageInteger(value.membershipRevision), try storageInteger(record.sequence)])
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func applyRelationship(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Payload: Decodable { let targetUserID: String; let state: String; let requestedByUserID: String?; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case state; case requestedByUserID = "requested_by_user_id"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard let state = V2RelationshipState(rawValue: payload.state) else { throw V2ClientSocialProjectionError.invalidPayload }
        let target: UserID; let requester: UserID?
        do { target = try .init(payload.targetUserID); requester = try payload.requestedByUserID.map(UserID.init) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard (state == .pending) == (requester != nil) else { throw V2ClientSocialProjectionError.invalidPayload }
        try db.execute(sql: "INSERT INTO v2_relationship_projections (target_user_id, state, requested_by_user_id, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(target_user_id) DO UPDATE SET state = excluded.state, requested_by_user_id = excluded.requested_by_user_id, updated_at = excluded.updated_at", arguments: [target.rawValue, state.rawValue, requester?.rawValue, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyUserBlock(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Payload: Decodable { let targetUserID: String; let isBlocked: Bool; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case isBlocked = "is_blocked"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let target: UserID
        do { target = try .init(payload.targetUserID) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        try db.execute(sql: "INSERT INTO v2_user_block_projections (target_user_id, is_blocked, updated_at) VALUES (?, ?, ?) ON CONFLICT(target_user_id) DO UPDATE SET is_blocked = excluded.is_blocked, updated_at = excluded.updated_at", arguments: [target.rawValue, payload.isBlocked, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyStrangerMessagePermission(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Payload: Decodable { let allowsStrangerMessages: Bool; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case allowsStrangerMessages = "allows_stranger_messages"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        try db.execute(sql: "INSERT INTO v2_stranger_message_preference (singleton, allows_stranger_messages, updated_at) VALUES (1, ?, ?) ON CONFLICT(singleton) DO UPDATE SET allows_stranger_messages = excluded.allows_stranger_messages, updated_at = excluded.updated_at", arguments: [payload.allowsStrangerMessages, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyUserAddPermission(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Payload: Decodable { let allowsBeingAdded: Bool; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case allowsBeingAdded = "allows_being_added"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        try db.execute(sql: "INSERT INTO v2_user_add_preference (singleton, allows_being_added, updated_at) VALUES (1, ?, ?) ON CONFLICT(singleton) DO UPDATE SET allows_being_added = excluded.allows_being_added, updated_at = excluded.updated_at", arguments: [payload.allowsBeingAdded, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyDirectReadReceipt(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Payload: Decodable { let roomID: String; let readerUserID: String; let readThroughRoomSequence: UInt64; let recordedAtMilliseconds: Int64; let isVisible: Bool; enum CodingKeys: String, CodingKey { case roomID = "room_id", readerUserID = "reader_user_id", readThroughRoomSequence = "read_through_room_sequence", recordedAtMilliseconds = "recorded_at_ms", isVisible = "is_visible" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let roomID: RoomID; let readerID: UserID
        do { roomID = try .init(payload.roomID); readerID = try .init(payload.readerUserID) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard payload.readThroughRoomSequence > 0, payload.readThroughRoomSequence <= UInt64(Int64.max), payload.recordedAtMilliseconds >= 0 else { throw V2ClientSocialProjectionError.invalidPayload }
        if payload.isVisible {
            try db.execute(sql: "INSERT INTO v2_direct_read_receipt_projections (room_id, reader_user_id, read_through_room_sequence, recorded_at) VALUES (?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET reader_user_id = excluded.reader_user_id, read_through_room_sequence = MAX(v2_direct_read_receipt_projections.read_through_room_sequence, excluded.read_through_room_sequence), recorded_at = CASE WHEN excluded.read_through_room_sequence >= v2_direct_read_receipt_projections.read_through_room_sequence THEN excluded.recorded_at ELSE v2_direct_read_receipt_projections.recorded_at END", arguments: [roomID.rawValue, readerID.rawValue, try Self.storageInteger(payload.readThroughRoomSequence), Double(payload.recordedAtMilliseconds) / 1_000])
        } else {
            try db.execute(sql: "DELETE FROM v2_direct_read_receipt_projections WHERE room_id = ? AND reader_user_id = ?", arguments: [roomID.rawValue, readerID.rawValue])
        }
    }
    private static func applyReadReceiptPreference(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Payload: Decodable { let allowsDirect: Bool; let allowsGroup: Bool; let updatedAt: Int64; enum CodingKeys: String, CodingKey { case allowsDirect = "allows_direct_read_receipts", allowsGroup = "allows_group_read_receipts", updatedAt = "updated_at_ms" } }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: record.payload), payload.updatedAt >= 0 else { throw V2ClientSocialProjectionError.invalidPayload }
        try db.execute(sql: "INSERT INTO v2_read_receipt_preference (singleton, allows_direct_read_receipts, allows_group_read_receipts, updated_at) VALUES (1, ?, ?, ?) ON CONFLICT(singleton) DO UPDATE SET allows_direct_read_receipts = excluded.allows_direct_read_receipts, allows_group_read_receipts = excluded.allows_group_read_receipts, updated_at = excluded.updated_at", arguments: [payload.allowsDirect, payload.allowsGroup, Double(payload.updatedAt) / 1_000])
    }
    private static func persist(_ projection: V2ClientConversationState, db: Database) throws {
        try db.execute(sql: "INSERT INTO v2_conversation_states (room_id, is_pinned, is_archived, mute_until, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET is_pinned = excluded.is_pinned, is_archived = excluded.is_archived, mute_until = excluded.mute_until, updated_at = excluded.updated_at", arguments: [projection.roomID.rawValue, projection.isPinned, projection.isArchived, projection.muteUntil?.timeIntervalSince1970 ?? 0, projection.updatedAt.timeIntervalSince1970])
    }
    private static func persist(_ projection: V2ClientMessageFavorite, db: Database) throws {
        try db.execute(sql: "INSERT INTO v2_message_favorites (message_id, room_id, is_favorited, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(message_id) DO UPDATE SET room_id = excluded.room_id, is_favorited = excluded.is_favorited, updated_at = excluded.updated_at", arguments: [projection.messageID.rawValue, projection.roomID.rawValue, projection.isFavorited, projection.updatedAt.timeIntervalSince1970])
    }

    private static func applyModeration(_ record: V2ClientSyncRecord, db: Database) throws {
        struct Header: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        switch header.eventType {
        case "member.muted": try persist(V2ClientModerationProjection(record: record), db: db)
        case "room.frozen", "room.unfrozen": try persist(V2ClientRoomControlProjection(record: record), db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func persist(_ projection: V2SnapshotRelationshipProjection, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO v2_relationship_projections (target_user_id, state, requested_by_user_id, updated_at) VALUES (?, ?, ?, ?)",
            arguments: [projection.targetUserID.rawValue, projection.state.rawValue, projection.requestedByUserID?.rawValue, projection.updatedAt.timeIntervalSince1970]
        )
    }

    private static func persist(_ projection: V2SnapshotUserBlockProjection, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO v2_user_block_projections (target_user_id, is_blocked, updated_at) VALUES (?, ?, ?)",
            arguments: [projection.targetUserID.rawValue, projection.isBlocked, projection.updatedAt.timeIntervalSince1970]
        )
    }

    private static func persist(_ projection: V2SnapshotStrangerMessagePreference, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO v2_stranger_message_preference (singleton, allows_stranger_messages, updated_at) VALUES (1, ?, ?)",
            arguments: [projection.allowsStrangerMessages, projection.updatedAt.timeIntervalSince1970]
        )
    }

    private static func persist(_ projection: V2SnapshotUserAddPreference, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO v2_user_add_preference (singleton, allows_being_added, updated_at) VALUES (1, ?, ?)",
            arguments: [projection.allowsBeingAdded, projection.updatedAt.timeIntervalSince1970]
        )
    }

    private static func persist(_ projection: V2SnapshotDirectReadReceiptProjection, db: Database) throws {
        try db.execute(sql: "INSERT INTO v2_direct_read_receipt_projections (room_id, reader_user_id, read_through_room_sequence, recorded_at) VALUES (?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.readerUserID.rawValue, try Self.storageInteger(projection.readThroughRoomSequence), projection.recordedAt.timeIntervalSince1970])
    }
    private static func persist(_ projection: V2SnapshotReadReceiptPreference, db: Database) throws { try db.execute(sql: "INSERT INTO v2_read_receipt_preference (singleton, allows_direct_read_receipts, allows_group_read_receipts, updated_at) VALUES (1, ?, ?, ?)", arguments: [projection.allowsDirectReadReceipts, projection.allowsGroupReadReceipts, projection.updatedAt.timeIntervalSince1970]) }

    private static func persist(_ projection: V2ClientMessageProjection, db: Database) throws {
        if let existing = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let decoded = try decodeMessageProjection(existing)
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
            INSERT INTO v2_message_projections
                (message_id, source_event_id, room_id, room_sequence, timeline_sequence, message_revision, sender_user_id, text_body, media_ids, media_presentations, mention_targets, entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, server_created_at, is_withdrawn)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [projection.messageID.rawValue, projection.sourceEventID.rawValue, projection.roomID.rawValue,
                        try storageInteger(projection.roomSequence), try storageInteger(projection.timelineSequence), try storageInteger(projection.messageRevision), projection.senderUserID.rawValue, projection.text, try encodeMedia(projection.media), try encodeMediaPresentations(projection.mediaPresentations), try encodeMentions(projection.mentions), try encodeEntities(projection.entities, text: projection.text), projection.replyTo?.messageID.rawValue, projection.forwardedFrom?.messageID.rawValue, projection.forwardedFrom?.senderUserID.rawValue,
                        projection.createdAt.timeIntervalSince1970, projection.isWithdrawn]
        )
        if let tombstone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let roomID: String = tombstone["room_id"]
            let revision: Int64 = tombstone["message_revision"]
            guard roomID == projection.roomID.rawValue, revision > (try storageInteger(projection.messageRevision)) else { throw V2ClientProjectionError.invalidMessagePayload }
            try redactLocalMessageProjection(messageID: projection.messageID, revision: revision, db: db)
        }
        try enqueueMessageSearchIndexJob(messageID: projection.messageID, db: db)
    }

    private static func persist(_ projection: V2ClientTimelineActivityProjection, db: Database) throws {
        let timelineSequence = try storageInteger(projection.timelineSequence)
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, timeline_sequence, event_type, server_created_at FROM v2_timeline_activity_projections WHERE source_event_id = ?", arguments: [projection.sourceEventID.rawValue]) {
            guard (row["room_id"] as String) == projection.roomID.rawValue,
                  (row["timeline_sequence"] as Int64) == timelineSequence,
                  (row["event_type"] as String) == projection.kind.rawValue,
                  (row["server_created_at"] as Double) == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO v2_timeline_activity_projections (source_event_id, room_id, timeline_sequence, event_type, server_created_at) VALUES (?, ?, ?, ?, ?)", arguments: [projection.sourceEventID.rawValue, projection.roomID.rawValue, timelineSequence, projection.kind.rawValue, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientDirectSendingCapability, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT can_send, updated_at FROM v2_direct_sending_capabilities WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let existingTime = row["updated_at"] as Double
            guard existingTime <= projection.updatedAt.timeIntervalSince1970 else { throw V2ClientProjectionError.invalidMessagePayload }
            if existingTime == projection.updatedAt.timeIntervalSince1970 {
                guard (row["can_send"] as Bool) == projection.canSend else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
        }
        try db.execute(sql: "INSERT INTO v2_direct_sending_capabilities (room_id, can_send, updated_at) VALUES (?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET can_send = excluded.can_send, updated_at = excluded.updated_at", arguments: [projection.roomID.rawValue, projection.canSend, projection.updatedAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientModerationProjection, db: Database) throws {
        if let existing = try Row.fetchOne(db, sql: "SELECT room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at FROM v2_moderation_projections WHERE source_event_id = ?", arguments: [projection.sourceEventID.rawValue]) {
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
        try db.execute(sql: "INSERT INTO v2_moderation_projections (source_event_id, room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [projection.sourceEventID.rawValue, projection.roomID.rawValue, try storageInteger(projection.roomSequence), projection.actorUserID.rawValue, projection.targetUserID.rawValue, projection.muteUntil.timeIntervalSince1970, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientRoomControlProjection, db: Database) throws {
        if let existing = try Row.fetchOne(db, sql: "SELECT room_sequence FROM v2_room_control_projections WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let sequence: Int64 = existing["room_sequence"]
            let projectionSequence = try storageInteger(projection.roomSequence)
            guard sequence < projectionSequence else {
                if sequence == projectionSequence { return }
                throw V2ClientProjectionError.invalidMessagePayload
            }
        }
        try db.execute(sql: "INSERT INTO v2_room_control_projections (room_id, source_event_id, room_sequence, actor_user_id, is_frozen, server_created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET source_event_id = excluded.source_event_id, room_sequence = excluded.room_sequence, actor_user_id = excluded.actor_user_id, is_frozen = excluded.is_frozen, server_created_at = excluded.server_created_at", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, try storageInteger(projection.roomSequence), projection.actorUserID.rawValue, projection.isFrozen, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientRoomProfileProjection, db: Database) throws {
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, title, owner_user_id, delivery_mode, membership_revision, created_at FROM v2_room_profile_projections WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let sourceEventID: String = existing["source_event_id"]; let title: String = existing["title"]
            let ownerUserID: String = existing["owner_user_id"]; let membershipRevision: Int64 = existing["membership_revision"]; let createdAt: Double = existing["created_at"]
            let incomingRevision = try storageInteger(projection.membershipRevision)
            guard title == projection.title, ownerUserID == projection.ownerUserID.rawValue,
                  createdAt == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            guard membershipRevision <= incomingRevision else { throw V2ClientProjectionError.invalidMessagePayload }
            if membershipRevision == incomingRevision {
                guard sourceEventID == projection.sourceEventID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
            try db.execute(sql: "UPDATE v2_room_profile_projections SET source_event_id = ?, delivery_mode = COALESCE(?, delivery_mode), membership_revision = ? WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, projection.deliveryMode?.rawValue, incomingRevision, projection.roomID.rawValue])
            return
        }
        try db.execute(sql: "INSERT INTO v2_room_profile_projections (room_id, source_event_id, title, owner_user_id, delivery_mode, membership_revision, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.title, projection.ownerUserID.rawValue, projection.deliveryMode?.rawValue, try storageInteger(projection.membershipRevision), projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientDirectRoomProfileProjection, db: Database) throws {
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, target_user_id, public_handle, display_name, account_kind, revision FROM v2_direct_room_profile_projections WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
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
                try persist(profileView(from: projection), db: db)
                return
            }
            try db.execute(sql: "UPDATE v2_direct_room_profile_projections SET source_event_id = ?, target_user_id = ?, public_handle = ?, display_name = ?, account_kind = ?, revision = ?, updated_at = ? WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, projection.publicIdentity.accountKind.rawValue, incomingRevision, projection.updatedAt.timeIntervalSince1970, projection.roomID.rawValue])
            try persist(profileView(from: projection), db: db)
            return
        }
        try db.execute(sql: "INSERT INTO v2_direct_room_profile_projections (room_id, source_event_id, target_user_id, public_handle, display_name, account_kind, revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, projection.publicIdentity.accountKind.rawValue, try storageInteger(projection.revision), projection.updatedAt.timeIntervalSince1970])
        try persist(profileView(from: projection), db: db)
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

    private static func persist(_ profile: V2ProfileView, db: Database) throws {
        let incomingRevision = try storageInteger(profile.revision.rawValue)
        let incomingVisibilityRevision = try storageInteger(profile.visibilityRevision.rawValue)
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id = ?",
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
                try clearSatisfiedInvalidation(for: profile, db: db)
                return
            }
            try db.execute(
                sql: "UPDATE v2_profile_views SET public_handle = ?, display_name = ?, account_kind = ?, avatar_media_id = ?, state = ?, revision = ?, visibility_revision = ?, updated_at = ? WHERE user_id = ?",
                arguments: [profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.publicIdentity?.accountKind.rawValue, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970, profile.userID.rawValue]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO v2_profile_views (user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [profile.userID.rawValue, profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.publicIdentity?.accountKind.rawValue, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970]
            )
        }
        try clearSatisfiedInvalidation(for: profile, db: db)
    }

    private static func persist(_ invalidation: V2ClientProfileInvalidation, db: Database) throws {
        let revision = try storageInteger(invalidation.minimumRevision.rawValue)
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT revision FROM v2_profile_views WHERE user_id = ?",
            arguments: [invalidation.userID.rawValue]
        ) {
            let existingRevision: Int64 = existing["revision"]
            if existingRevision >= revision { return }
        }
        try db.execute(
            sql: """
            INSERT INTO v2_profile_invalidations (user_id, minimum_revision, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                minimum_revision = MAX(v2_profile_invalidations.minimum_revision, excluded.minimum_revision),
                updated_at = excluded.updated_at
            """,
            arguments: [invalidation.userID.rawValue, revision, Date().timeIntervalSince1970]
        )
    }

    private static func clearSatisfiedInvalidation(for profile: V2ProfileView, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM v2_profile_invalidations WHERE user_id = ? AND minimum_revision <= ?",
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
        if let projection = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_projections WHERE message_id = ?", arguments: [tombstone.messageID.rawValue]) {
            let roomID: String = projection["room_id"]
            let revision: Int64 = projection["message_revision"]
            guard roomID == tombstone.roomID.rawValue, revision < tombstoneRevision else { throw V2ClientProjectionError.invalidMessagePayload }
            try redactLocalMessageProjection(messageID: tombstone.messageID, revision: try storageInteger(tombstone.messageRevision), db: db)
            try enqueueMessageSearchIndexJob(messageID: tombstone.messageID, db: db)
        }
    }

    /// Tombstones are durable permission revocations, not merely a rendering
    /// flag. Remove content-bearing local columns before the search-index job
    /// runs so a crash cannot leave text, media references, entities or
    /// mention targets available through another local feature.
    private static func redactLocalMessageProjection(messageID: MessageID, revision: Int64, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE v2_message_projections
            SET message_revision = ?, is_withdrawn = 1, text_body = '[removed]',
                media_ids = '[]', media_presentations = '[]',
                mention_targets = '[]', entities = '[]',
                forwarded_from_message_id = NULL, forwarded_from_user_id = NULL
            WHERE message_id = ?
            """,
            arguments: [revision, messageID.rawValue]
        )
    }

    private static func persist(_ edit: V2ClientMessageEditProjection, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT room_id, message_revision, is_withdrawn FROM v2_message_projections WHERE message_id = ?", arguments: [edit.messageID.rawValue]) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let roomID: String = row["room_id"]
        let revision: Int64 = row["message_revision"]
        let isWithdrawn: Bool = row["is_withdrawn"]
        guard roomID == edit.roomID.rawValue, !isWithdrawn,
              revision < Int64.max,
              edit.messageRevision == UInt64(revision + 1)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: "UPDATE v2_message_projections SET text_body = ?, entities = '[]', message_revision = ? WHERE message_id = ?", arguments: [edit.text, try storageInteger(edit.messageRevision), edit.messageID.rawValue])
        try enqueueMessageSearchIndexJob(messageID: edit.messageID, db: db)
    }

    private static func persist(_ reaction: V2ClientMessageReaction, action: V2MessageReactionAction, db: Database) throws {
        if action == .add {
            try db.execute(sql: "INSERT INTO v2_message_reactions (message_id, room_id, actor_user_id, reaction) VALUES (?, ?, ?, ?) ON CONFLICT(message_id, actor_user_id, reaction) DO NOTHING", arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction])
        } else {
            try db.execute(sql: "DELETE FROM v2_message_reactions WHERE message_id = ? AND room_id = ? AND actor_user_id = ? AND reaction = ?", arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction])
        }
    }

    private static func decodeMessageProjection(_ row: Row) throws -> V2ClientMessageProjection {
        let sourceEventID = try EventID(row["source_event_id"] as String)
        let messageID = try MessageID(row["message_id"] as String)
        let roomID = try RoomID(row["room_id"] as String)
        let senderUserID = try UserID(row["sender_user_id"] as String)
        let text: String = row["text_body"]
        let roomSequence = UInt64(row["room_sequence"] as Int64)
        let timelineSequence = UInt64(row["timeline_sequence"] as Int64)
        let messageRevision = UInt64(row["message_revision"] as Int64)
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
            timelineSequence: UInt64(row["timeline_sequence"] as Int64),
            kind: kind,
            createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double)
        )
    }

    private static func decodeModerationProjection(_ row: Row) throws -> V2ClientModerationProjection {
        let payload: [String: Any] = [
            "event_type": "member.muted",
            "room_id": row["room_id"] as String,
            "room_sequence": UInt64(row["room_sequence"] as Int64),
            "actor_user_id": row["actor_user_id"] as String,
            "target_user_id": row["target_user_id"] as String,
            "mute_until_ms": Int64((row["mute_until"] as Double) * 1_000),
            "server_created_at_ms": Int64((row["server_created_at"] as Double) * 1_000)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try .init(record: .init(sequence: 1, sourceEventID: try .init(row["source_event_id"] as String), projectionKind: "moderation", payload: data))
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
        let acceptedRoomSequence = (row["accepted_room_sequence"] as Int64?).map(UInt64.init)
        return try .init(
            roomID: .init(row["room_id"] as String),
            clientMessageID: .init(row["client_message_id"] as String),
            text: row["text"],
            media: try decodeMedia(row["media_ids"]),
            mentions: try decodeMentions(row["mention_targets"]),
            entities: try decodeEntities(row["entities"], text: row["text"]),
            replyTo: try (row["reply_to_message_id"] as String?).map { try V2MessageReplyReference(messageID: .init($0)) },
            state: state,
            attemptCount: Int(row["attempt_count"] as Int64),
            nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double),
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
        let revision = (row["resulting_membership_revision"] as Int64?).map(UInt64.init)
        let roomSequence = (row["resulting_room_sequence"] as Int64?).map(UInt64.init)
        let terminalCurrentRevision = (row["terminal_current_revision"] as Int64?).map(UInt64.init)
        return try .init(
            roomID: .init(row["room_id"] as String),
            operationID: .init(row["operation_id"] as String),
            targetUserID: .init(row["target_user_id"] as String),
            action: action,
            expectedMembershipRevision: UInt64(row["expected_membership_revision"] as Int64),
            state: state,
            attemptCount: Int(row["attempt_count"] as Int64),
            nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double),
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
            expectedMessageRevision: UInt64(row["expected_message_revision"] as Int64), state: state,
            attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double),
            resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(UInt64.init),
            resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init),
            terminalCode: row["terminal_code"], terminalCurrentRevision: (row["terminal_current_revision"] as Int64?).map(UInt64.init)
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
            attemptCount: Int(row["attempt_count"] as Int64),
            nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double),
            resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(UInt64.init),
            resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init),
            terminalCode: row["terminal_code"]
        )
    }
    static func decodePendingMemberMute(_ row: Row) throws -> V2PendingMemberMute { guard let state = V2PendingMemberMute.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), targetUserID: .init(row["target_user_id"] as String), muteUntil: Date(timeIntervalSince1970: row["mute_until"] as Double), reasonCode: .init(row["reason_code"] as String), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"]) }
    static func decodePendingModeratedMemberRemoval(_ row: Row) throws -> V2PendingModeratedMemberRemoval { guard let state = V2PendingModeratedMemberRemoval.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), targetUserID: .init(row["target_user_id"] as String), reasonCode: .init(row["reason_code"] as String), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingMembershipRevision: (row["resulting_membership_revision"] as Int64?).map(UInt64.init), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"]) }

    static func decodeRoomControlProjection(_ row: Row) throws -> V2ClientRoomControlProjection {
        let sourceEventID: EventID = try .init(row["source_event_id"] as String)
        let roomID: RoomID = try .init(row["room_id"] as String)
        let actorUserID: UserID = try .init(row["actor_user_id"] as String)
        let sequence = UInt64(row["room_sequence"] as Int64)
        guard sequence > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        return try .init(sourceEventID: sourceEventID, roomID: roomID, roomSequence: sequence, actorUserID: actorUserID, isFrozen: row["is_frozen"], createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double))
    }

    static func decodeRoomProfileProjection(_ row: Row) throws -> V2ClientRoomProfileProjection {
        let revision = UInt64(row["membership_revision"] as Int64)
        let snapshot = try V2SnapshotRoomProfileProjection(sourceEventID: .init(row["source_event_id"] as String), roomID: .init(row["room_id"] as String), title: row["title"], ownerUserID: .init(row["owner_user_id"] as String), membershipRevision: revision, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
        let deliveryMode = (row["delivery_mode"] as String?).flatMap(V2GroupDeliveryMode.init)
        return .init(snapshotProjection: snapshot, deliveryMode: deliveryMode)
    }

    static func decodeDirectRoomIdentity(_ row: Row) throws -> V2ClientDirectRoomIdentity {
        let identity = try V2PublicIdentity(
            userID: .init(row["target_user_id"] as String),
            handle: .init(row["public_handle"] as String),
            displayName: row["display_name"] as String,
            accountKind: (row["account_kind"] as String?).flatMap(V2AccountKind.init) ?? .regular
        )
        return try .init(
            roomID: .init(row["room_id"] as String),
            publicIdentity: identity,
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double)
        )
    }

    static func decodePendingMessageReaction(_ row: Row) throws -> V2PendingMessageReaction {
        guard let state = V2PendingMessageReaction.State(rawValue: row["state"] as String), let action = V2MessageReactionAction(rawValue: row["action"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String), reaction: row["reaction"], action: action, state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"])
    }
    static func decodePendingConversationState(_ row: Row) throws -> V2PendingConversationStateCommand {
        guard let state = V2PendingConversationStateCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let muteUntil = (row["mute_until"] as Double) == 0 ? nil : Date(timeIntervalSince1970: row["mute_until"] as Double)
        return try .init(command: .init(operationID: .init(row["operation_id"] as String), roomID: .init(row["room_id"] as String), isPinned: row["is_pinned"], isArchived: row["is_archived"], muteUntil: muteUntil), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    static func decodePendingMessageFavorite(_ row: Row) throws -> V2PendingMessageFavoriteCommand {
        guard let state = V2PendingMessageFavoriteCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(command: .init(operationID: .init(row["operation_id"] as String), roomID: .init(row["room_id"] as String), messageID: .init(row["message_id"] as String), isFavorited: row["is_favorited"]), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    static func decodePendingGroupCapability(_ row: Row) throws -> V2PendingGroupCapabilityCommand {
        guard let kind = V2PendingGroupCapabilityCommand.Kind(rawValue: row["kind"] as String), let state = V2PendingGroupCapabilityCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let role = (row["role"] as String?).flatMap(V2RoomMembershipRole.init(rawValue:))
        let rawPermissions = try JSONDecoder().decode([String].self, from: Data((row["permissions"] as String).utf8))
        let permissions = Set(rawPermissions.compactMap(V2GroupPermission.init(rawValue:)))
        guard permissions.count == rawPermissions.count else { throw V2ClientCommandError.commandConflict }
        return try .init(kind: kind, operationID: row["operation_id"], roomID: .init(row["room_id"] as String), messageID: try (row["message_id"] as String?).map(MessageID.init), isPinned: row["is_pinned"], body: row["body"], role: role, permissions: permissions, targetUserID: try (row["target_user_id"] as String?).map(UserID.init), expectedRevision: try storageUnsigned(row["expected_revision"] as Int64), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    static func decodePendingForwardMessages(_ row: Row) throws -> V2PendingForwardMessagesCommand { guard let state = V2PendingForwardMessagesCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; let sources = try JSONDecoder().decode([String].self, from: Data((row["source_message_ids"] as String).utf8)).map(MessageID.init); let targets = try JSONDecoder().decode([String].self, from: Data((row["target_room_ids"] as String).utf8)).map(RoomID.init); return try .init(command: .init(operationID: .init(row["operation_id"] as String), sourceMessageIDs: sources, targetRoomIDs: targets), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"]) }
    static func decodeForwardMessagesPlan(_ row: Row) throws -> V2ForwardMessagesPlan {
        guard let state = V2ForwardMessagesPlan.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let sources = try JSONDecoder().decode([String].self, from: Data((row["source_message_ids"] as String).utf8))
        let targets = try JSONDecoder().decode([String].self, from: Data((row["target_room_ids"] as String).utf8))
        guard !targets.isEmpty, sources.count <= Int.max / targets.count else { throw V2ClientCommandError.commandConflict }
        let total = sources.count * targets.count
        return .init(operationID: try .init(row["plan_id"] as String), sourceMessageCount: sources.count, targetRoomCount: targets.count, totalForwardCount: total, succeededCount: Int(row["succeeded_count"] as Int64), failedCount: Int(row["failed_count"] as Int64), state: state)
    }
    static func decodeForwardPlanChunk(_ row: Row) throws -> V2PendingForwardMessagesCommand {
        guard let state = V2PendingForwardMessagesCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let sources = try JSONDecoder().decode([String].self, from: Data((row["source_message_ids"] as String).utf8)).map(MessageID.init)
        let target = try RoomID(row["target_room_id"] as String)
        return try .init(command: .init(operationID: try .init(row["operation_id"] as String), sourceMessageIDs: sources, targetRoomIDs: [target]), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }

    static func advanceForwardPlan(planID: String, completedChunkIndex: Int64, succeeded: Int, failed: Int, now: Date, db: Database) throws {
        guard succeeded >= 0, failed >= 0,
              let row = try Row.fetchOne(db, sql: "SELECT next_chunk_index, total_chunk_count, state FROM v2_forward_message_plans WHERE plan_id = ?", arguments: [planID]),
              let state = V2ForwardMessagesPlan.State(rawValue: row["state"] as String), state == .active
        else { return }
        let nextChunkIndex: Int64 = row["next_chunk_index"]
        let totalChunkCount: Int64 = row["total_chunk_count"]
        guard nextChunkIndex == completedChunkIndex else { throw V2ClientCommandError.commandConflict }
        let next = completedChunkIndex + 1
        try db.execute(
            sql: "UPDATE v2_forward_message_plans SET next_chunk_index = ?, succeeded_count = succeeded_count + ?, failed_count = failed_count + ?, state = ?, updated_at = ? WHERE plan_id = ?",
            arguments: [next, succeeded, failed, next == totalChunkCount ? V2ForwardMessagesPlan.State.completed.rawValue : V2ForwardMessagesPlan.State.active.rawValue, now.timeIntervalSince1970, planID]
        )
    }
    static func decodePendingMessageEdit(_ row: Row) throws -> V2PendingMessageEdit {
        guard let state = V2PendingMessageEdit.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String), expectedMessageRevision: UInt64(row["expected_message_revision"] as Int64), text: row["text_body"], state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(UInt64.init), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"], terminalCurrentRevision: (row["terminal_current_revision"] as Int64?).map(UInt64.init))
    }
    static func decodePendingReadReceipt(_ row: Row) throws -> V2PendingReadReceipt { guard let state = V2PendingReadReceipt.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), readThroughRoomSequence: UInt64(row["read_through_room_sequence"] as Int64), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"]) }
    static func decodePendingSocialCommand(_ row: Row) throws -> V2PendingSocialCommand {
        guard let kind = V2PendingSocialCommandKind(rawValue: row["command_kind"] as String), let state = V2PendingSocialCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(operationID: row["operation_id"], kind: kind, targetUserID: try (row["target_user_id"] as String?).map(UserID.init), relationshipAction: (row["relationship_action"] as String?).flatMap(V2RelationshipAction.init), blockAction: (row["block_action"] as String?).flatMap(V2UserBlockAction.init), strangerPermission: (row["stranger_permission"] as String?).flatMap(V2StrangerMessagePermission.init), userAddPermission: (row["user_add_permission"] as String?).flatMap(V2UserAddPermission.init), allowsDirectReadReceipts: row["allows_direct_read_receipts"], allowsGroupReadReceipts: row["allows_group_read_receipts"], state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
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
        return try .init(operationID: .init(row["operation_id"] as String), title: row["title"], deliveryMode: deliveryMode, initialMemberUserIDs: members, uploadedMemberCount: row["uploaded_member_count"] as Int, state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), createdRoomID: try (row["created_room_id"] as String?).map(RoomID.init), terminalCode: row["terminal_code"])
    }

    enum V2MessageSearchRebuildOutcome {
        case advanced(Int64)
        case finished
        case restartRequired
    }


    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createV2SyncStore") { db in
            try db.execute(sql: """
                CREATE TABLE v2_local_installation (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    binding TEXT NOT NULL
                );
                CREATE TABLE v2_sync_cursor (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    state TEXT NOT NULL CHECK (state IN ('ready', 'resetPending')),
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    applied_sequence INTEGER NOT NULL CHECK (applied_sequence >= 0),
                    server_acknowledged_sequence INTEGER NOT NULL CHECK (server_acknowledged_sequence >= 0),
                    sync_token TEXT,
                    pending_ack_receipt TEXT,
                    pending_ack_sequence INTEGER,
                    pending_snapshot_id TEXT,
                    pending_base_sequence INTEGER,
                    pending_manifest_digest TEXT,
                    pending_expires_at REAL,
                    CHECK ((pending_ack_receipt IS NULL AND pending_ack_sequence IS NULL) OR (pending_ack_receipt IS NOT NULL AND pending_ack_sequence = applied_sequence))
                );
                CREATE TABLE v2_sync_events (
                    sequence INTEGER PRIMARY KEY CHECK (sequence > 0),
                    source_event_id TEXT NOT NULL,
                    projection_kind TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    UNIQUE (source_event_id, projection_kind)
                );
                CREATE TABLE v2_message_projections (
                    message_id TEXT PRIMARY KEY,
                    source_event_id TEXT NOT NULL UNIQUE,
                    room_id TEXT NOT NULL,
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                    message_revision INTEGER NOT NULL CHECK (message_revision > 0),
                    sender_user_id TEXT NOT NULL,
                    text_body TEXT NOT NULL CHECK (length(text_body) > 0),
                    server_created_at REAL NOT NULL,
                    is_withdrawn INTEGER NOT NULL DEFAULT 0 CHECK (is_withdrawn IN (0, 1)),
                    UNIQUE (room_id, room_sequence)
                );
                CREATE INDEX v2_message_projections_room_order_idx
                    ON v2_message_projections (room_id, room_sequence, message_id);
                CREATE TABLE v2_message_tombstones (
                    message_id TEXT PRIMARY KEY,
                    source_event_id TEXT NOT NULL UNIQUE,
                    room_id TEXT NOT NULL,
                    message_revision INTEGER NOT NULL CHECK (message_revision > 1)
                );
                CREATE TABLE v2_message_reactions (
                    message_id TEXT NOT NULL,
                    room_id TEXT NOT NULL,
                    actor_user_id TEXT NOT NULL,
                    reaction TEXT NOT NULL CHECK (length(reaction) > 0 AND length(reaction) <= 64),
                    PRIMARY KEY (message_id, actor_user_id, reaction)
                );
                CREATE INDEX v2_message_reactions_message_idx
                    ON v2_message_reactions (message_id, reaction, actor_user_id);
                CREATE TABLE v2_snapshots (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    snapshot_id TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    base_sequence INTEGER NOT NULL,
                    manifest_digest TEXT NOT NULL,
                    next_sync_token TEXT NOT NULL,
                    acknowledgement_receipt TEXT
                );
                CREATE TABLE v2_snapshot_pages (
                    snapshot_id TEXT NOT NULL,
                    page_index INTEGER NOT NULL CHECK (page_index >= 0),
                    page_digest TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (snapshot_id, page_index)
                );
                CREATE TABLE v2_snapshot_staging (
                    snapshot_id TEXT PRIMARY KEY,
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    base_sequence INTEGER NOT NULL CHECK (base_sequence >= 0),
                    manifest_digest TEXT NOT NULL,
                    next_sync_token TEXT NOT NULL,
                    receipt TEXT NOT NULL,
                    capability_profile TEXT NOT NULL,
                    page_count INTEGER NOT NULL CHECK (page_count > 0)
                );
                CREATE TABLE v2_snapshot_staging_pages (
                    page_index INTEGER PRIMARY KEY CHECK (page_index >= 0),
                    page_digest TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE v2_pending_message_commands (
                    client_message_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    text TEXT NOT NULL CHECK (length(text) > 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'accepted', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    accepted_message_id TEXT,
                    accepted_room_sequence INTEGER,
                    terminal_code TEXT,
                    CHECK (
                        (state = 'pending' AND accepted_message_id IS NULL AND accepted_room_sequence IS NULL AND terminal_code IS NULL)
                        OR (state = 'accepted' AND accepted_message_id IS NOT NULL AND accepted_room_sequence IS NOT NULL AND accepted_room_sequence > 0 AND terminal_code IS NULL)
                        OR (state = 'rejected' AND accepted_message_id IS NULL AND accepted_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                CREATE INDEX v2_pending_message_ready_idx
                    ON v2_pending_message_commands (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                CREATE TABLE v2_pending_membership_commands (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    target_user_id TEXT NOT NULL,
                    action TEXT NOT NULL CHECK (action IN ('add', 'remove')),
                    expected_membership_revision INTEGER NOT NULL CHECK (expected_membership_revision >= 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    resulting_membership_revision INTEGER,
                    resulting_room_sequence INTEGER,
                    terminal_code TEXT,
                    terminal_current_revision INTEGER CHECK (terminal_current_revision IS NULL OR terminal_current_revision >= 0),
                    CHECK (
                        (state = 'pending' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                        OR (state = 'acknowledged' AND resulting_membership_revision IS NOT NULL AND resulting_room_sequence IS NOT NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                        OR (state = 'rejected' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                CREATE INDEX v2_pending_membership_ready_idx
                    ON v2_pending_membership_commands (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                CREATE TABLE v2_pending_message_withdrawals (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    expected_message_revision INTEGER NOT NULL CHECK (expected_message_revision > 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    resulting_message_revision INTEGER,
                    resulting_room_sequence INTEGER,
                    terminal_code TEXT,
                    terminal_current_revision INTEGER,
                    CHECK (
                        (state = 'pending' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                        OR (state = 'acknowledged' AND resulting_message_revision IS NOT NULL AND resulting_room_sequence IS NOT NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                        OR (state = 'rejected' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                CREATE INDEX v2_pending_message_withdrawals_ready_idx
                    ON v2_pending_message_withdrawals (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                CREATE TABLE v2_pending_message_edits (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    expected_message_revision INTEGER NOT NULL CHECK (expected_message_revision > 0),
                    text_body TEXT NOT NULL CHECK (length(text_body) > 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    resulting_message_revision INTEGER,
                    resulting_room_sequence INTEGER,
                    terminal_code TEXT,
                    terminal_current_revision INTEGER,
                    CHECK (
                        (state = 'pending' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                        OR (state = 'acknowledged' AND resulting_message_revision IS NOT NULL AND resulting_room_sequence IS NOT NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                        OR (state = 'rejected' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                CREATE INDEX v2_pending_message_edits_ready_idx
                    ON v2_pending_message_edits (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                CREATE TABLE v2_pending_read_receipts (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    read_through_room_sequence INTEGER NOT NULL CHECK (read_through_room_sequence > 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    resulting_room_sequence INTEGER,
                    terminal_code TEXT,
                    CHECK (
                        (state = 'pending' AND resulting_room_sequence IS NULL AND terminal_code IS NULL)
                        OR (state = 'acknowledged' AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL)
                        OR (state = 'rejected' AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                CREATE INDEX v2_pending_read_receipts_ready_idx
                    ON v2_pending_read_receipts (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                CREATE TABLE v2_pending_message_reactions (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    reaction TEXT NOT NULL CHECK (length(reaction) > 0 AND length(reaction) <= 64),
                    action TEXT NOT NULL CHECK (action IN ('add', 'remove')),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    resulting_room_sequence INTEGER,
                    terminal_code TEXT,
                    CHECK (
                        (state = 'pending' AND resulting_room_sequence IS NULL AND terminal_code IS NULL)
                        OR (state = 'acknowledged' AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL)
                        OR (state = 'rejected' AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                CREATE INDEX v2_pending_message_reactions_ready_idx
                    ON v2_pending_message_reactions (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
            """)
        }
        migrator.registerMigration("addV2SocialProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_relationship_projections (
                    target_user_id TEXT PRIMARY KEY,
                    state TEXT NOT NULL CHECK (state IN ('none', 'pending', 'accepted')),
                    requested_by_user_id TEXT,
                    updated_at REAL NOT NULL,
                    CHECK ((state = 'pending' AND requested_by_user_id IS NOT NULL) OR (state <> 'pending' AND requested_by_user_id IS NULL))
                );
                CREATE TABLE v2_user_block_projections (
                    target_user_id TEXT PRIMARY KEY,
                    is_blocked INTEGER NOT NULL CHECK (is_blocked IN (0, 1)),
                    updated_at REAL NOT NULL
                );
                CREATE TABLE v2_stranger_message_preference (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    allows_stranger_messages INTEGER NOT NULL CHECK (allows_stranger_messages IN (0, 1)),
                    updated_at REAL NOT NULL
                );
                CREATE TABLE v2_pending_social_commands (
                    operation_id TEXT PRIMARY KEY,
                    command_kind TEXT NOT NULL CHECK (command_kind IN ('relationship', 'userBlock', 'strangerMessagePreference')),
                    target_user_id TEXT,
                    relationship_action TEXT CHECK (relationship_action IN ('request', 'accept', 'reject', 'remove')),
                    block_action TEXT CHECK (block_action IN ('block', 'unblock')),
                    stranger_permission TEXT CHECK (stranger_permission IN ('allow', 'deny')),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    terminal_code TEXT,
                    CHECK (
                        (command_kind = 'relationship' AND target_user_id IS NOT NULL AND relationship_action IS NOT NULL AND block_action IS NULL AND stranger_permission IS NULL)
                        OR (command_kind = 'userBlock' AND target_user_id IS NOT NULL AND relationship_action IS NULL AND block_action IS NOT NULL AND stranger_permission IS NULL)
                        OR (command_kind = 'strangerMessagePreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IS NOT NULL)
                    ),
                    CHECK ((state IN ('pending', 'acknowledged') AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_social_ready_idx
                    ON v2_pending_social_commands (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
            """)
        }
        migrator.registerMigration("addV2UserAddPreferences") { db in
            try db.execute(sql: """
                CREATE TABLE v2_user_add_preference (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    allows_being_added INTEGER NOT NULL CHECK (allows_being_added IN (0, 1)),
                    updated_at REAL NOT NULL
                );
                CREATE TABLE v2_pending_social_commands_new (
                    operation_id TEXT PRIMARY KEY,
                    command_kind TEXT NOT NULL CHECK (command_kind IN ('relationship', 'userBlock', 'strangerMessagePreference', 'userAddPreference')),
                    target_user_id TEXT,
                    relationship_action TEXT CHECK (relationship_action IN ('request', 'accept', 'reject', 'remove')),
                    block_action TEXT CHECK (block_action IN ('block', 'unblock')),
                    stranger_permission TEXT CHECK (stranger_permission IN ('allow', 'deny')),
                    user_add_permission TEXT CHECK (user_add_permission IN ('allow', 'deny')),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    terminal_code TEXT,
                    CHECK (
                        (command_kind = 'relationship' AND target_user_id IS NOT NULL AND relationship_action IS NOT NULL AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IS NULL)
                        OR (command_kind = 'userBlock' AND target_user_id IS NOT NULL AND relationship_action IS NULL AND block_action IS NOT NULL AND stranger_permission IS NULL AND user_add_permission IS NULL)
                        OR (command_kind = 'strangerMessagePreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IS NOT NULL AND user_add_permission IS NULL)
                        OR (command_kind = 'userAddPreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IS NOT NULL)
                    ),
                    CHECK ((state IN ('pending', 'acknowledged') AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
                );
                INSERT INTO v2_pending_social_commands_new
                    (operation_id, command_kind, target_user_id, relationship_action, block_action, stranger_permission, state, attempt_count, next_attempt_at, created_at, terminal_code)
                SELECT operation_id, command_kind, target_user_id, relationship_action, block_action, stranger_permission, state, attempt_count, next_attempt_at, created_at, terminal_code
                FROM v2_pending_social_commands;
                DROP TABLE v2_pending_social_commands;
                ALTER TABLE v2_pending_social_commands_new RENAME TO v2_pending_social_commands;
                CREATE INDEX v2_pending_social_ready_idx
                    ON v2_pending_social_commands (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                """)
        }
        migrator.registerMigration("addV2DirectReadReceiptProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_direct_read_receipt_projections (
                    room_id TEXT PRIMARY KEY,
                    reader_user_id TEXT NOT NULL,
                    read_through_room_sequence INTEGER NOT NULL CHECK (read_through_room_sequence > 0),
                    recorded_at REAL NOT NULL
                );
            """)
        }
        migrator.registerMigration("addV2ReadReceiptPreferenceOutbox") { db in
            try db.execute(sql: """
                CREATE TABLE v2_pending_social_commands_new (
                    operation_id TEXT PRIMARY KEY,
                    command_kind TEXT NOT NULL CHECK (command_kind IN ('relationship', 'userBlock', 'strangerMessagePreference', 'userAddPreference', 'readReceiptPreference')),
                    target_user_id TEXT, relationship_action TEXT, block_action TEXT,
                    stranger_permission TEXT, user_add_permission TEXT,
                    allows_direct_read_receipts INTEGER CHECK (allows_direct_read_receipts IN (0, 1)),
                    allows_group_read_receipts INTEGER CHECK (allows_group_read_receipts IN (0, 1)),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL, terminal_code TEXT,
                    CHECK (
                        (command_kind = 'relationship' AND target_user_id IS NOT NULL AND relationship_action IN ('request', 'accept', 'reject', 'remove') AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IS NULL AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                        OR (command_kind = 'userBlock' AND target_user_id IS NOT NULL AND relationship_action IS NULL AND block_action IN ('block', 'unblock') AND stranger_permission IS NULL AND user_add_permission IS NULL AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                        OR (command_kind = 'strangerMessagePreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IN ('allow', 'deny') AND user_add_permission IS NULL AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                        OR (command_kind = 'userAddPreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IN ('allow', 'deny') AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                        OR (command_kind = 'readReceiptPreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IS NULL AND allows_direct_read_receipts IS NOT NULL AND allows_group_read_receipts IS NOT NULL)
                    ),
                    CHECK ((state IN ('pending', 'acknowledged') AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
                );
                INSERT INTO v2_pending_social_commands_new (operation_id, command_kind, target_user_id, relationship_action, block_action, stranger_permission, user_add_permission, state, attempt_count, next_attempt_at, created_at, terminal_code)
                SELECT operation_id, command_kind, target_user_id, relationship_action, block_action, stranger_permission, user_add_permission, state, attempt_count, next_attempt_at, created_at, terminal_code FROM v2_pending_social_commands;
                DROP TABLE v2_pending_social_commands;
                ALTER TABLE v2_pending_social_commands_new RENAME TO v2_pending_social_commands;
                CREATE INDEX v2_pending_social_ready_idx ON v2_pending_social_commands (state, next_attempt_at, created_at) WHERE state = 'pending';
            """)
        }
        migrator.registerMigration("addV2ReadReceiptPreferenceProjection") { db in
            try db.execute(sql: "CREATE TABLE v2_read_receipt_preference (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), allows_direct_read_receipts INTEGER NOT NULL CHECK (allows_direct_read_receipts IN (0, 1)), allows_group_read_receipts INTEGER NOT NULL CHECK (allows_group_read_receipts IN (0, 1)), updated_at REAL NOT NULL);")
        }
        migrator.registerMigration("addV2MessageMediaReferences") { db in
            try db.execute(sql: """
                CREATE TABLE v2_message_projections_new (
                    message_id TEXT PRIMARY KEY,
                    source_event_id TEXT NOT NULL UNIQUE,
                    room_id TEXT NOT NULL,
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                    message_revision INTEGER NOT NULL CHECK (message_revision > 0),
                    sender_user_id TEXT NOT NULL,
                    text_body TEXT NOT NULL,
                    media_ids TEXT NOT NULL DEFAULT '[]',
                    server_created_at REAL NOT NULL,
                    is_withdrawn INTEGER NOT NULL DEFAULT 0 CHECK (is_withdrawn IN (0, 1)),
                    UNIQUE (room_id, room_sequence)
                );
                INSERT INTO v2_message_projections_new
                    (message_id, source_event_id, room_id, room_sequence, message_revision, sender_user_id, text_body, media_ids, server_created_at, is_withdrawn)
                SELECT message_id, source_event_id, room_id, room_sequence, message_revision, sender_user_id, text_body, '[]', server_created_at, is_withdrawn
                FROM v2_message_projections;
                DROP TABLE v2_message_projections;
                ALTER TABLE v2_message_projections_new RENAME TO v2_message_projections;
                CREATE INDEX v2_message_projections_room_order_idx
                    ON v2_message_projections (room_id, room_sequence, message_id);

                CREATE TABLE v2_pending_message_commands_new (
                    client_message_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    text TEXT NOT NULL,
                    media_ids TEXT NOT NULL DEFAULT '[]',
                    state TEXT NOT NULL CHECK (state IN ('pending', 'accepted', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    accepted_message_id TEXT,
                    accepted_room_sequence INTEGER,
                    terminal_code TEXT,
                    CHECK (
                        (state = 'pending' AND accepted_message_id IS NULL AND accepted_room_sequence IS NULL AND terminal_code IS NULL)
                        OR (state = 'accepted' AND accepted_message_id IS NOT NULL AND accepted_room_sequence IS NOT NULL AND accepted_room_sequence > 0 AND terminal_code IS NULL)
                        OR (state = 'rejected' AND accepted_message_id IS NULL AND accepted_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                INSERT INTO v2_pending_message_commands_new
                    (client_message_id, room_id, text, media_ids, state, attempt_count, next_attempt_at, created_at, accepted_message_id, accepted_room_sequence, terminal_code)
                SELECT client_message_id, room_id, text, '[]', state, attempt_count, next_attempt_at, created_at, accepted_message_id, accepted_room_sequence, terminal_code
                FROM v2_pending_message_commands;
                DROP TABLE v2_pending_message_commands;
                ALTER TABLE v2_pending_message_commands_new RENAME TO v2_pending_message_commands;
                CREATE INDEX v2_pending_message_ready_idx
                    ON v2_pending_message_commands (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                """)
        }
        migrator.registerMigration("addV2PendingMessageMentions") { db in
            try db.execute(sql: "ALTER TABLE v2_pending_message_commands ADD COLUMN mention_targets TEXT NOT NULL DEFAULT '[]'")
        }
        migrator.registerMigration("addV2MessageProjectionMentions") { db in
            try db.execute(sql: "ALTER TABLE v2_message_projections ADD COLUMN mention_targets TEXT NOT NULL DEFAULT '[]'")
        }
        migrator.registerMigration("addV2MessageMediaPresentations") { db in
            try db.execute(sql: "ALTER TABLE v2_message_projections ADD COLUMN media_presentations TEXT NOT NULL DEFAULT '[]'")
        }
        migrator.registerMigration("addV2RichMessageContent") { db in
            try db.execute(sql: "ALTER TABLE v2_message_projections ADD COLUMN entities TEXT NOT NULL DEFAULT '[]'")
            try db.execute(sql: "ALTER TABLE v2_message_projections ADD COLUMN reply_to_message_id TEXT")
            try db.execute(sql: "ALTER TABLE v2_pending_message_commands ADD COLUMN entities TEXT NOT NULL DEFAULT '[]'")
            try db.execute(sql: "ALTER TABLE v2_pending_message_commands ADD COLUMN reply_to_message_id TEXT")
        }
        migrator.registerMigration("addV2PendingMessageRedactions") { db in
            try db.execute(sql: """
                CREATE TABLE v2_pending_message_redactions (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    reason_code TEXT NOT NULL CHECK (length(reason_code) > 0 AND length(reason_code) <= 64),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    resulting_message_revision INTEGER,
                    resulting_room_sequence INTEGER,
                    terminal_code TEXT,
                    CHECK (
                        (state = 'pending' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL)
                        OR (state = 'acknowledged' AND resulting_message_revision IS NOT NULL AND resulting_message_revision > 1 AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL)
                        OR (state = 'rejected' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                    )
                );
                CREATE INDEX v2_pending_message_redactions_ready_idx
                    ON v2_pending_message_redactions (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
                """)
        }
        migrator.registerMigration("addV2ModerationProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_moderation_projections (
                    source_event_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                    actor_user_id TEXT NOT NULL,
                    target_user_id TEXT NOT NULL,
                    mute_until REAL NOT NULL,
                    server_created_at REAL NOT NULL,
                    CHECK (mute_until > server_created_at)
                );
                CREATE INDEX v2_moderation_projections_room_idx
                    ON v2_moderation_projections (room_id, server_created_at, source_event_id);
                """)
        }
        migrator.registerMigration("addV2PendingMemberMutes") { db in
            try db.execute(sql: """
                CREATE TABLE v2_pending_member_mutes (
                    operation_id TEXT PRIMARY KEY, room_id TEXT NOT NULL, target_user_id TEXT NOT NULL,
                    mute_until REAL NOT NULL, reason_code TEXT NOT NULL CHECK (length(reason_code) BETWEEN 1 AND 64),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
                    resulting_room_sequence INTEGER, terminal_code TEXT,
                    CHECK ((state = 'pending' AND resulting_room_sequence IS NULL AND terminal_code IS NULL) OR (state = 'acknowledged' AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL) OR (state = 'rejected' AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_member_mutes_ready_idx ON v2_pending_member_mutes (state, next_attempt_at, created_at) WHERE state = 'pending';
                """)
        }
        migrator.registerMigration("addV2PendingModeratedMemberRemovals") { db in
            try db.execute(sql: """
                CREATE TABLE v2_pending_moderated_member_removals (
                    operation_id TEXT PRIMARY KEY, room_id TEXT NOT NULL, target_user_id TEXT NOT NULL,
                    reason_code TEXT NOT NULL CHECK (length(reason_code) BETWEEN 1 AND 64),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
                    resulting_membership_revision INTEGER, resulting_room_sequence INTEGER, terminal_code TEXT,
                    CHECK ((state = 'pending' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL) OR (state = 'acknowledged' AND resulting_membership_revision IS NOT NULL AND resulting_membership_revision > 0 AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL) OR (state = 'rejected' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_moderated_member_removals_ready_idx ON v2_pending_moderated_member_removals (state, next_attempt_at, created_at) WHERE state = 'pending';
                """)
        }
        migrator.registerMigration("addV2RoomControlProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_room_control_projections (
                    room_id TEXT PRIMARY KEY,
                    source_event_id TEXT NOT NULL UNIQUE,
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                    actor_user_id TEXT NOT NULL,
                    is_frozen INTEGER NOT NULL CHECK (is_frozen IN (0, 1)),
                    server_created_at REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("addV2PendingGroupRoomCreations") { db in
            try db.execute(sql: """
                CREATE TABLE v2_pending_group_room_creations (
                    operation_id TEXT PRIMARY KEY, title TEXT NOT NULL,
                    initial_member_user_ids TEXT NOT NULL,
                    delivery_mode TEXT NOT NULL CHECK (delivery_mode IN ('standard_fanout', 'large_group_hybrid')),
                    uploaded_member_count INTEGER NOT NULL DEFAULT 0 CHECK (uploaded_member_count >= 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'cancelling', 'finalizing', 'cancelled', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
                    created_room_id TEXT,
                    terminal_code TEXT,
                    CHECK ((state IN ('pending', 'cancelling', 'finalizing', 'cancelled') AND created_room_id IS NULL AND terminal_code IS NULL)
                        OR (state = 'acknowledged' AND created_room_id IS NOT NULL AND terminal_code IS NULL)
                        OR (state = 'rejected' AND created_room_id IS NULL AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_group_room_creations_ready_idx
                    ON v2_pending_group_room_creations (state, next_attempt_at, created_at)
                    WHERE state IN ('pending', 'finalizing', 'cancelling');
            """)
        }
        migrator.registerMigration("addV2RoomProfileProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_room_profile_projections (
                    room_id TEXT PRIMARY KEY,
                    source_event_id TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    owner_user_id TEXT NOT NULL,
                    membership_revision INTEGER NOT NULL DEFAULT 1 CHECK (membership_revision > 0),
                    delivery_mode TEXT CHECK (delivery_mode IS NULL OR delivery_mode IN ('standard_fanout', 'large_group_hybrid')),
                    created_at REAL NOT NULL
                );
            """)
        }
        migrator.registerMigration("addV2RoomProfileMembershipRevision") { db in
            // The V2 baseline already contains this column. Keep the named
            // migration only for a database interrupted between the old table
            // creation and this follow-up migration; SQLite 3.37 rejects the
            // prior ADD COLUMN ... CHECK form on this path.
            if try !db.columns(in: "v2_room_profile_projections").contains(where: { $0.name == "membership_revision" }) {
                try db.execute(sql: "ALTER TABLE v2_room_profile_projections ADD COLUMN membership_revision INTEGER NOT NULL DEFAULT 1")
            }
        }
        migrator.registerMigration("addV2RoomProfileDeliveryMode") { db in
            if try !db.columns(in: "v2_room_profile_projections").contains(where: { $0.name == "delivery_mode" }) {
                try db.execute(sql: "ALTER TABLE v2_room_profile_projections ADD COLUMN delivery_mode TEXT CHECK (delivery_mode IS NULL OR delivery_mode IN ('standard_fanout', 'large_group_hybrid'))")
            }
        }
        migrator.registerMigration("addV2DirectRoomIdentityCache") { db in
            try db.execute(sql: """
                CREATE TABLE v2_direct_room_identities (
                    room_id TEXT PRIMARY KEY,
                    target_user_id TEXT NOT NULL,
                    public_handle TEXT NOT NULL CHECK (length(public_handle) BETWEEN 3 AND 32),
                    display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
                    updated_at REAL NOT NULL
                );
                CREATE UNIQUE INDEX v2_direct_room_identities_target_idx
                    ON v2_direct_room_identities (target_user_id);
                """)
        }
        migrator.registerMigration("addV2DirectRoomProfileProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_direct_room_profile_projections (
                    room_id TEXT PRIMARY KEY,
                    source_event_id TEXT NOT NULL UNIQUE,
                    target_user_id TEXT NOT NULL,
                    public_handle TEXT NOT NULL CHECK (length(public_handle) BETWEEN 3 AND 32),
                    display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
                    revision INTEGER NOT NULL CHECK (revision > 0),
                    updated_at REAL NOT NULL
                );
                """)
        }
        // Terminal command rows are retained locally for retry diagnostics.
        // Keep semantic pending-intent lookups scoped to the small pending
        // subset rather than scanning the growing terminal history.
        migrator.registerMigration("addV2PendingIntentReuseIndexes") { db in
            try db.execute(sql: """
                CREATE INDEX v2_pending_membership_intent_idx
                    ON v2_pending_membership_commands
                    (room_id, target_user_id, action, expected_membership_revision, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_message_withdrawals_intent_idx
                    ON v2_pending_message_withdrawals
                    (room_id, message_id, expected_message_revision, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_message_redactions_intent_idx
                    ON v2_pending_message_redactions
                    (room_id, message_id, reason_code, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_member_mutes_intent_idx
                    ON v2_pending_member_mutes
                    (room_id, target_user_id, mute_until, reason_code, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_moderated_member_removals_intent_idx
                    ON v2_pending_moderated_member_removals
                    (room_id, target_user_id, reason_code, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_message_edits_intent_idx
                    ON v2_pending_message_edits
                    (room_id, message_id, expected_message_revision, text_body, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_message_reactions_intent_idx
                    ON v2_pending_message_reactions
                    (room_id, message_id, reaction, action, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_social_commands_intent_idx
                    ON v2_pending_social_commands
                    (command_kind, target_user_id, relationship_action, block_action, stranger_permission, created_at, operation_id)
                    WHERE state = 'pending';
                CREATE INDEX v2_pending_group_room_creations_intent_with_delivery_mode_idx
                    ON v2_pending_group_room_creations
                    (title, delivery_mode, initial_member_user_ids, created_at, operation_id)
                    WHERE state IN ('pending', 'finalizing');
            """)
        }
        migrator.registerMigration("addV2ProfileViews") { db in
            try db.execute(sql: """
                CREATE TABLE v2_profile_views (
                    user_id TEXT PRIMARY KEY,
                    public_handle TEXT NULL CHECK (public_handle IS NULL OR length(public_handle) BETWEEN 3 AND 32),
                    display_name TEXT NULL CHECK (display_name IS NULL OR length(display_name) BETWEEN 1 AND 80),
                    avatar_media_id TEXT NULL,
                    state TEXT NOT NULL CHECK (state IN ('active', 'deleted', 'suspended', 'hidden')),
                    revision INTEGER NOT NULL CHECK (revision > 0),
                    visibility_revision INTEGER NOT NULL CHECK (visibility_revision > 0),
                    updated_at REAL NOT NULL,
                    CHECK ((public_handle IS NULL) = (display_name IS NULL)),
                    CHECK ((state = 'active') OR (public_handle IS NULL AND avatar_media_id IS NULL))
                );
                CREATE TABLE v2_profile_invalidations (
                    user_id TEXT PRIMARY KEY,
                    minimum_revision INTEGER NOT NULL CHECK (minimum_revision > 0),
                    updated_at REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("addV2HybridGroupEventCursors") { db in
            try db.execute(sql: """
                CREATE TABLE v2_group_event_cursors (
                    room_id TEXT PRIMARY KEY,
                    applied_room_sequence INTEGER NOT NULL CHECK (applied_room_sequence >= 0)
                );
                CREATE TABLE v2_group_events (
                    room_id TEXT NOT NULL,
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                    source_event_id TEXT NOT NULL UNIQUE,
                    projection_kind TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (room_id, room_sequence)
                );
            """)
        }
        migrator.registerMigration("addV2TerminalCommandRetentionIndexes") { db in
            try db.execute(sql: """
                CREATE INDEX v2_pending_message_commands_terminal_retention_idx
                    ON v2_pending_message_commands (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_membership_commands_terminal_retention_idx
                    ON v2_pending_membership_commands (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_message_withdrawals_terminal_retention_idx
                    ON v2_pending_message_withdrawals (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_message_redactions_terminal_retention_idx
                    ON v2_pending_message_redactions (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_member_mutes_terminal_retention_idx
                    ON v2_pending_member_mutes (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_moderated_member_removals_terminal_retention_idx
                    ON v2_pending_moderated_member_removals (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_message_edits_terminal_retention_idx
                    ON v2_pending_message_edits (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_read_receipts_terminal_retention_idx
                    ON v2_pending_read_receipts (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_message_reactions_terminal_retention_idx
                    ON v2_pending_message_reactions (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_social_commands_terminal_retention_idx
                    ON v2_pending_social_commands (created_at)
                    WHERE state <> 'pending';
                CREATE INDEX v2_pending_group_room_creations_terminal_retention_idx
                    ON v2_pending_group_room_creations (created_at)
                    WHERE state <> 'pending';
                """)
        }
        migrator.registerMigration("addV2MessageCharacterSearch") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE v2_message_char_fts USING fts5(
                    room_scope,
                    sender_scope,
                    unigrams,
                    bigrams,
                    tokenize = 'ascii',
                    detail = full,
                    columnsize = 0
                );
                CREATE TABLE v2_message_search_state (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    index_version INTEGER NOT NULL CHECK (index_version > 0),
                    state TEXT NOT NULL CHECK (state IN ('building', 'ready', 'failed')),
                    generation INTEGER NOT NULL CHECK (generation > 0)
                );
                INSERT INTO v2_message_search_state
                    (singleton, index_version, state, generation)
                VALUES (1, 1, 'building', 1);
                """)
        }
        migrator.registerMigration("addV2ConversationCapabilityProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_conversation_states (
                    room_id TEXT PRIMARY KEY,
                    is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    mute_until REAL NOT NULL CHECK (mute_until >= 0),
                    updated_at REAL NOT NULL
                );
                CREATE INDEX v2_conversation_states_list_idx ON v2_conversation_states (is_archived, is_pinned DESC, updated_at DESC);
                CREATE TABLE v2_message_favorites (
                    message_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    is_favorited INTEGER NOT NULL CHECK (is_favorited IN (0, 1)),
                    updated_at REAL NOT NULL
                );
                CREATE INDEX v2_message_favorites_room_idx ON v2_message_favorites (room_id, is_favorited, updated_at DESC);
                """)
        }
        migrator.registerMigration("addV2ConversationCapabilityOutbox") { db in
            try db.execute(sql: """
                CREATE TABLE v2_pending_conversation_states (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    mute_until REAL NOT NULL CHECK (mute_until >= 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    terminal_code TEXT,
                    CHECK ((state = 'pending' AND terminal_code IS NULL) OR (state = 'acknowledged' AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_conversation_states_ready_idx ON v2_pending_conversation_states (state, next_attempt_at, created_at) WHERE state = 'pending';
                CREATE INDEX v2_pending_conversation_states_terminal_idx ON v2_pending_conversation_states (created_at) WHERE state <> 'pending';
                CREATE TABLE v2_pending_message_favorites (
                    operation_id TEXT PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    is_favorited INTEGER NOT NULL CHECK (is_favorited IN (0, 1)),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    terminal_code TEXT,
                    CHECK ((state = 'pending' AND terminal_code IS NULL) OR (state = 'acknowledged' AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_message_favorites_ready_idx ON v2_pending_message_favorites (state, next_attempt_at, created_at) WHERE state = 'pending';
                CREATE INDEX v2_pending_message_favorites_terminal_idx ON v2_pending_message_favorites (created_at) WHERE state <> 'pending';
            """)
        }
        migrator.registerMigration("addV2GroupCapabilityProjections") { db in
            try db.execute(sql: """
                CREATE TABLE v2_group_pinned_messages (
                    room_id TEXT NOT NULL, message_id TEXT NOT NULL,
                    is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0), updated_at REAL NOT NULL,
                    PRIMARY KEY (room_id, message_id)
                );
                CREATE INDEX v2_group_pinned_messages_room_idx ON v2_group_pinned_messages (room_id, is_pinned DESC, updated_at DESC);
                CREATE TABLE v2_group_announcements (
                    room_id TEXT PRIMARY KEY, body TEXT NOT NULL, revision INTEGER NOT NULL CHECK (revision > 0),
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0), updated_at REAL NOT NULL
                );
                CREATE TABLE v2_group_role_permissions (
                    room_id TEXT NOT NULL, role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
                    permission TEXT NOT NULL, revision INTEGER NOT NULL CHECK (revision > 0),
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0), PRIMARY KEY (room_id, role, permission)
                );
                CREATE TABLE v2_group_member_roles (
                    room_id TEXT NOT NULL, user_id TEXT NOT NULL,
                    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
                    membership_revision INTEGER NOT NULL CHECK (membership_revision > 0),
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0), PRIMARY KEY (room_id, user_id)
                );
            """)
        }
        migrator.registerMigration("addV2GroupCapabilityOutbox") { db in
            try db.execute(sql: """
                CREATE TABLE v2_pending_group_capabilities (
                    operation_id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('pin', 'announcement', 'rolePermissions', 'memberRole')),
                    room_id TEXT NOT NULL, message_id TEXT, is_pinned INTEGER CHECK (is_pinned IN (0, 1)), body TEXT,
                    role TEXT CHECK (role IN ('owner', 'admin', 'member')), permissions TEXT NOT NULL,
                    target_user_id TEXT, expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
                    terminal_code TEXT,
                    CHECK ((state = 'pending' AND terminal_code IS NULL) OR (state = 'acknowledged' AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_group_capabilities_ready_idx ON v2_pending_group_capabilities (state, next_attempt_at, created_at) WHERE state = 'pending';
                CREATE INDEX v2_pending_group_capabilities_terminal_idx ON v2_pending_group_capabilities (created_at) WHERE state <> 'pending';
            """)
        }
        migrator.registerMigration("addV2ForwardMessagesOutbox") { db in
            try db.execute(sql: "CREATE TABLE v2_pending_forward_messages (operation_id TEXT PRIMARY KEY, source_message_ids TEXT NOT NULL, target_room_ids TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('pending','acknowledged','rejected')), attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL, terminal_code TEXT); CREATE INDEX v2_pending_forward_messages_ready_idx ON v2_pending_forward_messages (state, next_attempt_at, created_at) WHERE state = 'pending';")
        }
        migrator.registerMigration("addV2GroupPermissionRevisions") { db in
            try db.execute(sql: "CREATE TABLE v2_group_permission_revisions (room_id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK (revision > 0)); INSERT INTO v2_group_permission_revisions (room_id, revision) SELECT room_id, MAX(revision) FROM v2_group_role_permissions GROUP BY room_id;")
        }
        migrator.registerMigration("addV2MessageForwardAttribution") { db in
            try db.execute(sql: "ALTER TABLE v2_message_projections ADD COLUMN forwarded_from_message_id TEXT; ALTER TABLE v2_message_projections ADD COLUMN forwarded_from_user_id TEXT;")
        }
        migrator.registerMigration("separateV2MessageSearchIndex") { db in
            try db.execute(sql: """
                CREATE TABLE v2_message_search_jobs (
                    message_id TEXT PRIMARY KEY,
                    expected_message_revision INTEGER NOT NULL CHECK (expected_message_revision > 0),
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    enqueued_at REAL NOT NULL
                );
                CREATE INDEX v2_message_search_jobs_generation_idx
                    ON v2_message_search_jobs (generation, enqueued_at, message_id);
                UPDATE v2_message_search_state
                SET state = 'building', generation = generation + 1
                WHERE singleton = 1 AND generation < 9223372036854775807;
            """)
        }
        migrator.registerMigration("addV2BulkForwardPlans") { db in
            try db.execute(sql: """
                CREATE TABLE v2_forward_message_plans (
                    plan_id TEXT PRIMARY KEY,
                    source_message_ids TEXT NOT NULL,
                    target_room_ids TEXT NOT NULL,
                    next_chunk_index INTEGER NOT NULL CHECK (next_chunk_index >= 0),
                    total_chunk_count INTEGER NOT NULL CHECK (total_chunk_count > 0),
                    succeeded_count INTEGER NOT NULL DEFAULT 0 CHECK (succeeded_count >= 0),
                    failed_count INTEGER NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
                    state TEXT NOT NULL CHECK (state IN ('active','completed','cancelled')),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX v2_forward_message_plans_active_idx
                    ON v2_forward_message_plans (created_at, plan_id) WHERE state = 'active';
                CREATE TABLE v2_forward_message_chunks (
                    operation_id TEXT PRIMARY KEY,
                    plan_id TEXT NOT NULL REFERENCES v2_forward_message_plans(plan_id),
                    chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
                    source_message_ids TEXT NOT NULL,
                    target_room_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending','acknowledged','rejected','cancelled')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    terminal_code TEXT,
                    created_at REAL NOT NULL,
                    UNIQUE (plan_id, chunk_index)
                );
                CREATE INDEX v2_forward_message_chunks_ready_idx
                    ON v2_forward_message_chunks (state, next_attempt_at, created_at) WHERE state = 'pending';
            """)
        }
        migrator.registerMigration("addV2PrivateTimelineActivities") { db in
            // Existing messages predate the unified presentation sequence;
            // preserving their message sequence keeps historical order stable.
            try db.execute(sql: "ALTER TABLE v2_message_projections ADD COLUMN timeline_sequence INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE v2_message_projections SET timeline_sequence = room_sequence WHERE timeline_sequence = 0")
            try db.execute(sql: "CREATE UNIQUE INDEX v2_message_projections_room_timeline_idx ON v2_message_projections (room_id, timeline_sequence)")
            try db.execute(sql: "CREATE TABLE v2_timeline_activity_projections (source_event_id TEXT PRIMARY KEY, room_id TEXT NOT NULL, timeline_sequence INTEGER NOT NULL CHECK (timeline_sequence > 0), event_type TEXT NOT NULL CHECK (event_type IN ('direct_message_restricted', 'system_account_read_only')), server_created_at REAL NOT NULL, UNIQUE (room_id, timeline_sequence)); CREATE INDEX v2_timeline_activity_room_order_idx ON v2_timeline_activity_projections (room_id, timeline_sequence, source_event_id); CREATE TABLE v2_direct_sending_capabilities (room_id TEXT PRIMARY KEY, can_send INTEGER NOT NULL CHECK (can_send IN (0, 1)), updated_at REAL NOT NULL)")
        }
        migrator.registerMigration("addV2SpecialAccountKinds") { db in
            if try !db.columns(in: "v2_direct_room_identities").contains(where: { $0.name == "account_kind" }) {
                try db.execute(sql: "ALTER TABLE v2_direct_room_identities ADD COLUMN account_kind TEXT NOT NULL DEFAULT 'regular' CHECK (account_kind IN ('regular', 'system', 'customer_support'))")
            }
            if try !db.columns(in: "v2_direct_room_profile_projections").contains(where: { $0.name == "account_kind" }) {
                try db.execute(sql: "ALTER TABLE v2_direct_room_profile_projections ADD COLUMN account_kind TEXT NOT NULL DEFAULT 'regular' CHECK (account_kind IN ('regular', 'system', 'customer_support'))")
            }
            if try !db.columns(in: "v2_profile_views").contains(where: { $0.name == "account_kind" }) {
                try db.execute(sql: "ALTER TABLE v2_profile_views ADD COLUMN account_kind TEXT NULL CHECK (account_kind IS NULL OR account_kind IN ('regular', 'system', 'customer_support'))")
            }
        }
        migrator.registerMigration("allowV2SystemAccountTimelineActivity") { db in
            try db.execute(sql: "ALTER TABLE v2_timeline_activity_projections RENAME TO v2_timeline_activity_projections_old; CREATE TABLE v2_timeline_activity_projections (source_event_id TEXT PRIMARY KEY, room_id TEXT NOT NULL, timeline_sequence INTEGER NOT NULL CHECK (timeline_sequence > 0), event_type TEXT NOT NULL CHECK (event_type IN ('direct_message_restricted', 'system_account_read_only')), server_created_at REAL NOT NULL, UNIQUE (room_id, timeline_sequence)); INSERT INTO v2_timeline_activity_projections SELECT source_event_id, room_id, timeline_sequence, event_type, server_created_at FROM v2_timeline_activity_projections_old; DROP TABLE v2_timeline_activity_projections_old; CREATE INDEX v2_timeline_activity_room_order_idx ON v2_timeline_activity_projections (room_id, timeline_sequence, source_event_id)")
        }
        return migrator
    }()

    /// This database never contains sync cursors, commands, or authoritative
    /// message projections. It may always be discarded and rebuilt from the
    /// primary V2 database.
    static let messageSearchMigrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createV2DerivedMessageSearchIndex") { db in
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
