import Foundation
import GRDB
import IMV2Core

/// V2's local database is intentionally separate from the V1 conversation
/// cache. It applies sync records incrementally in one SQLite transaction.
public actor GRDBV2LocalSyncStore: V2LocalSyncStore, V2LocalCommandStore, V2LocalMembershipCommandStore, V2LocalMessageWithdrawalStore, V2LocalMessageRedactionStore, V2LocalMemberMuteStore, V2LocalModeratedMemberRemovalStore, V2LocalMessageReactionStore, V2LocalMessageEditStore, V2LocalReadReceiptStore, V2LocalConversationCapabilitiesStore, V2LocalGroupCapabilitiesStore, V2LocalForwardMessagesStore, V2LocalSocialCommandStore, V2LocalGroupRoomCommandStore, V2LocalGroupEventStore, V2LocalForegroundGroupEventPreviewStore, V2ClientProfileProjectionStore {
    private let databasePool: DatabasePool
    private let databaseURL: URL

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
        try databasePool.write { db in
            try Self.establishInstallationBinding(installationBinding, db: db)
        }
        try Self.applyBackupExclusion(databaseURL: databaseURL)
    }

    /// Reasserts and verifies the device-only backup policy after database
    /// reopen. The managed directory, SQLite file, WAL, and SHM are all scoped
    /// out of device backup and therefore cannot restore unsent V2 commands.
    public func refreshBackupExclusion() throws {
        try Self.applyBackupExclusion(databaseURL: databaseURL)
    }

    private static func applyBackupExclusion(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try V2LocalBackupExclusion.apply(to: directory)
        for artifact in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] where FileManager.default.fileExists(atPath: artifact.path) {
            try V2LocalBackupExclusion.apply(to: artifact)
        }
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
            var seenMessageIDs = Set<MessageID>()
            var seenRoomPositions = Set<String>()
            var seenSourceEventIDs = Set<EventID>()
            for message in snapshotMessages {
                guard seenMessageIDs.insert(message.messageID).inserted,
                      seenRoomPositions.insert("\(message.roomID.rawValue):\(message.roomSequence)").inserted,
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
            for userBlock in snapshotUserBlocks { try Self.persist(userBlock, db: db) }
            if let preference = snapshotPreferences.first { try Self.persist(preference, db: db) }
            if let preference = snapshotUserAddPreferences.first { try Self.persist(preference, db: db) }
            if let preference = snapshotReadReceiptPreferences.first { try Self.persist(preference, db: db) }
            for action in snapshotModerationActions { try Self.persist(.init(snapshotProjection: action), db: db) }
            for control in snapshotRoomControls { try Self.persist(.init(snapshotProjection: control), db: db) }
            try Self.finishMessageSearchIndexRebuild(
                generation: try Self.messageSearchIndexGeneration(db: db),
                db: db
            )
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
            try Row.fetchAll(db, sql: "SELECT * FROM v2_message_projections WHERE room_id = ? ORDER BY room_sequence, message_id", arguments: [roomID.rawValue]).map(Self.decodeMessageProjection)
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
    public func rebuildMessageSearchIndex() async throws {
        while !Task.isCancelled {
            let generation = try await databasePool.write { db in
                try Self.beginMessageSearchIndexRebuild(db: db)
            }
            var lastRowID: Int64 = 0

            while !Task.isCancelled {
                let pageStart = lastRowID
                let outcome = try await databasePool.write { db -> V2MessageSearchRebuildOutcome in
                    guard try Self.messageSearchIndexGeneration(db: db) == generation else {
                        return .restartRequired
                    }
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT rowid, message_id, room_id, room_sequence, sender_user_id,
                               text_body, server_created_at, is_withdrawn
                        FROM v2_message_projections
                        WHERE rowid > ?
                        ORDER BY rowid
                        LIMIT 250
                        """,
                        arguments: [pageStart]
                    )
                    guard let last = rows.last else {
                        try Self.finishMessageSearchIndexRebuild(generation: generation, db: db)
                        return .finished
                    }
                    for row in rows {
                        try Self.writeMessageSearchIndex(row: row, db: db)
                    }
                    let nextRowID: Int64 = last["rowid"]
                    return .advanced(nextRowID)
                }
                switch outcome {
                case .advanced(let nextRowID):
                    lastRowID = nextRowID
                    await Task.yield()
                case .finished:
                    return
                case .restartRequired:
                    // A snapshot commit fully rebuilt the derived index inside
                    // its own transaction. Do not discard that fresh index and
                    // start a redundant second pass.
                    if try messageSearchIndexState() == .ready {
                        return
                    }
                    break
                }
                if case .restartRequired = outcome { break }
            }
            try Task.checkCancellation()
        }
        throw CancellationError()
    }

    /// Ensures the derived index is available without needlessly rebuilding a
    /// valid index on every authenticated session activation.
    public func prepareMessageSearchIndex() async throws {
        guard try messageSearchIndexState() != .ready else { return }
        do {
            try await rebuildMessageSearchIndex()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await databasePool.write { db in
                try db.execute(sql: "UPDATE v2_message_search_state SET state = 'failed' WHERE singleton = 1")
            }
            throw error
        }
    }

    public func messageSearchIndexState() throws -> V2MessageSearchIndexState {
        try databasePool.read { db in try Self.readMessageSearchIndexState(db: db) }
    }

    /// FTS is a candidate index; the normalized Swift substring check is the
    /// final semantic authority for every returned hit.
    public func searchMessages(_ request: V2MessageSearchRequest) throws -> V2MessageSearchPage {
        guard (1 ... 100).contains(request.limit) else { throw V2MessageSearchError.invalidPageSize }
        let tokenizer = V2CharacterGramTokenizer()
        let query = tokenizer.tokenize(request.query)
        // Media-category search is useful even before a text term is entered.
        // Keep an unbounded all-message browse impossible on large histories.
        guard !query.unigrams.isEmpty || request.contentFilter != .all else {
            throw V2MessageSearchError.emptyQuery
        }
        return try databasePool.read { db in
            let state = try Self.readMessageSearchIndexState(db: db)
            guard state == .ready else { throw V2MessageSearchError.indexUnavailable(state) }
            return try Self.searchMessages(request, query: query, db: db)
        }
    }

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
                    (room_id, target_user_id, public_handle, display_name, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(room_id) DO UPDATE SET
                    public_handle = excluded.public_handle,
                    display_name = excluded.display_name,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    roomID.rawValue,
                    publicIdentity.userID.rawValue,
                    publicIdentity.handle.rawValue,
                    publicIdentity.displayName,
                    updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    public func directRoomIdentities() throws -> [V2ClientDirectRoomIdentity] {
        try databasePool.read { db in
            let cached = try Row.fetchAll(
                db,
                sql: "SELECT room_id, target_user_id, public_handle, display_name, updated_at FROM v2_direct_room_identities ORDER BY updated_at DESC, room_id"
            ).map(Self.decodeDirectRoomIdentity)
            let projected = try Row.fetchAll(
                db,
                sql: "SELECT room_id, target_user_id, public_handle, display_name, updated_at FROM v2_direct_room_profile_projections ORDER BY updated_at DESC, room_id"
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
                sql: "SELECT user_id, public_handle, display_name, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id = ?",
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
                sql: "SELECT user_id, public_handle, display_name, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id IN (\(placeholders))",
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

    public func enqueue(_ command: V2PendingMessageCommand) throws {
        try databasePool.write { db in
            guard (!command.text.isEmpty || !command.media.isEmpty),
                  command.media.count <= V2MessageCommandLimits.maxMediaAttachments,
                  Set(command.media).count == command.media.count,
                  command.mentions.count <= V2MessageCommandLimits.maxMentions,
                  Set(command.mentions).count == command.mentions.count,
                  command.state == .pending, command.attemptCount == 0,
                  command.acceptedMessageID == nil, command.acceptedRoomSequence == nil, command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            let mediaIDs = try Self.encodeMedia(command.media)
            let mentionTargets = try Self.encodeMentions(command.mentions)
            let entities = try Self.encodeEntities(command.entities, text: command.text)
            let replyToMessageID = command.replyTo?.messageID.rawValue
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, text, media_ids, mention_targets, entities, reply_to_message_id FROM v2_pending_message_commands WHERE client_message_id = ?", arguments: [command.clientMessageID.rawValue]) {
                let roomID: String = existing["room_id"]
                let text: String = existing["text"]
                let existingMedia: String = existing["media_ids"]
                let existingMentions: String = existing["mention_targets"]
                let existingEntities: String = existing["entities"]
                let existingReplyToMessageID: String? = existing["reply_to_message_id"]
                guard roomID == command.roomID.rawValue, text == command.text, existingMedia == mediaIDs, existingMentions == mentionTargets, existingEntities == entities, existingReplyToMessageID == replyToMessageID else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_commands
                    (client_message_id, room_id, text, media_ids, mention_targets, entities, reply_to_message_id, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [command.clientMessageID.rawValue, command.roomID.rawValue, command.text, mediaIDs, mentionTargets, entities, replyToMessageID, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970]
            )
        }
    }

    public func nextReadyMessage(now: Date) throws -> V2PendingMessageCommand? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM v2_pending_message_commands
                WHERE state = 'pending' AND next_attempt_at <= ?
                ORDER BY created_at, client_message_id LIMIT 1
                """, arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingCommand(row)
        }
    }

    public func markMessageAccepted(clientMessageID: ClientMessageID, messageID: MessageID, roomSequence: UInt64) throws {
        guard roomSequence > 0 else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingCommand(clientMessageID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_message_commands
                SET state = 'accepted', accepted_message_id = ?, accepted_room_sequence = ?, terminal_code = NULL
                WHERE client_message_id = ?
                """, arguments: [messageID.rawValue, try Self.commandStorageInteger(roomSequence), clientMessageID.rawValue])
        }
    }

    public func scheduleMessageRetry(clientMessageID: ClientMessageID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingCommand(clientMessageID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_message_commands
                SET attempt_count = attempt_count + 1, next_attempt_at = ?
                WHERE client_message_id = ?
                """, arguments: [nextAttemptAt.timeIntervalSince1970, clientMessageID.rawValue])
        }
    }

    public func rejectMessage(clientMessageID: ClientMessageID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingCommand(clientMessageID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_message_commands
                SET state = 'rejected', terminal_code = ?
                WHERE client_message_id = ?
                """, arguments: [code, clientMessageID.rawValue])
        }
    }

    public func pendingMessageCommands() throws -> [V2PendingMessageCommand] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_commands ORDER BY created_at, client_message_id").map(Self.decodePendingCommand)
        }
    }

    /// Discards completed commands after their short local diagnostic window.
    /// Pending records are the durable source for retries and are never
    /// eligible for this cleanup.
    public func pruneTerminalCommands(olderThan cutoff: Date) throws {
        try databasePool.write { db in
            for table in Self.terminalCommandTables {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE state <> 'pending' AND created_at <= ?",
                    arguments: [cutoff.timeIntervalSince1970]
                )
            }
        }
    }

    public func enqueue(_ command: V2PendingMembershipCommand) throws {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMembershipRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, target_user_id, action, expected_membership_revision FROM v2_pending_membership_commands WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let roomID: String = existing["room_id"]
                let targetUserID: String = existing["target_user_id"]
                let action: String = existing["action"]
                let expectedRevision: Int64 = existing["expected_membership_revision"]
                guard roomID == command.roomID.rawValue,
                      targetUserID == command.targetUserID.rawValue,
                      action == command.action.rawValue,
                      expectedRevision == (try Self.commandStorageInteger(command.expectedMembershipRevision))
                else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_membership_commands
                    (operation_id, room_id, target_user_id, action, expected_membership_revision,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [command.operationID.rawValue, command.roomID.rawValue, command.targetUserID.rawValue,
                            command.action.rawValue, try Self.commandStorageInteger(command.expectedMembershipRevision),
                            command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970]
            )
        }
    }

    public func enqueueOrReusePendingMembershipCommand(
        _ command: V2PendingMembershipCommand
    ) throws -> V2PendingMembershipCommand {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMembershipRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            let expectedRevision = try Self.commandStorageInteger(command.expectedMembershipRevision)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_membership_commands WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMembershipCommand(existing)
                guard decoded.roomID == command.roomID,
                      decoded.targetUserID == command.targetUserID,
                      decoded.action == command.action,
                      decoded.expectedMembershipRevision == command.expectedMembershipRevision,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_membership_commands
                WHERE room_id = ? AND target_user_id = ? AND action = ?
                  AND expected_membership_revision = ? AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.action.rawValue,
                    expectedRevision
                ]
            ) {
                return try Self.decodePendingMembershipCommand(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_membership_commands
                    (operation_id, room_id, target_user_id, action, expected_membership_revision,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.action.rawValue,
                    expectedRevision,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMembershipCommand(now: Date) throws -> V2PendingMembershipCommand? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM v2_pending_membership_commands
                WHERE state = 'pending' AND next_attempt_at <= ?
                ORDER BY created_at, operation_id LIMIT 1
                """, arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingMembershipCommand(row)
        }
    }

    public func markMembershipAcknowledged(operationID: MembershipOperationID, membershipRevision: UInt64, roomSequence: UInt64) throws {
        try databasePool.write { db in
            try Self.requirePendingMembershipCommand(operationID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_membership_commands
                SET state = 'acknowledged', resulting_membership_revision = ?, resulting_room_sequence = ?, terminal_code = NULL
                WHERE operation_id = ?
                """, arguments: [try Self.commandStorageInteger(membershipRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue])
        }
    }

    public func scheduleMembershipRetry(operationID: MembershipOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingMembershipCommand(operationID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_membership_commands
                SET attempt_count = attempt_count + 1, next_attempt_at = ?
                WHERE operation_id = ?
                """, arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectMembership(operationID: MembershipOperationID, code: String, currentRevision: UInt64?) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMembershipCommand(operationID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_membership_commands
                SET state = 'rejected', terminal_code = ?, terminal_current_revision = ?
                WHERE operation_id = ?
                """, arguments: [code, try currentRevision.map(Self.commandStorageInteger), operationID.rawValue])
        }
    }

    public func pendingMembershipCommands() throws -> [V2PendingMembershipCommand] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_membership_commands ORDER BY created_at, operation_id").map(Self.decodePendingMembershipCommand)
        }
    }

    public func enqueue(_ command: V2PendingMessageWithdrawal) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0,
                  command.resultingMessageRevision == nil, command.resultingRoomSequence == nil,
                  command.terminalCode == nil, command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, message_id, expected_message_revision FROM v2_pending_message_withdrawals WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let roomID: String = existing["room_id"]; let messageID: String = existing["message_id"]; let revision: Int64 = existing["expected_message_revision"]
                guard roomID == command.roomID.rawValue, messageID == command.messageID.rawValue, revision == (try Self.commandStorageInteger(command.expectedMessageRevision)) else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: """
                INSERT INTO v2_pending_message_withdrawals
                    (operation_id, room_id, message_id, expected_message_revision, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """, arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, try Self.commandStorageInteger(command.expectedMessageRevision), command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageWithdrawal(
        _ command: V2PendingMessageWithdrawal
    ) throws -> V2PendingMessageWithdrawal {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMessageRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            let expectedRevision = try Self.commandStorageInteger(command.expectedMessageRevision)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_withdrawals WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageWithdrawal(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.expectedMessageRevision == command.expectedMessageRevision,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_withdrawals
                WHERE room_id = ? AND message_id = ?
                  AND expected_message_revision = ? AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [command.roomID.rawValue, command.messageID.rawValue, expectedRevision]
            ) {
                return try Self.decodePendingMessageWithdrawal(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_withdrawals
                    (operation_id, room_id, message_id, expected_message_revision,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    expectedRevision,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMessageWithdrawal(now: Date) throws -> V2PendingMessageWithdrawal? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_withdrawals WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingMessageWithdrawal(row)
        }
    }

    public func markMessageWithdrawalAcknowledged(operationID: MessageWithdrawalOperationID, messageRevision: UInt64, roomSequence: UInt64) throws {
        try databasePool.write { db in
            try Self.requirePendingMessageWithdrawal(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_withdrawals SET state = 'acknowledged', resulting_message_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(messageRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue])
        }
    }

    public func scheduleMessageWithdrawalRetry(operationID: MessageWithdrawalOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingMessageWithdrawal(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_withdrawals SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectMessageWithdrawal(operationID: MessageWithdrawalOperationID, code: String, currentRevision: UInt64?) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMessageWithdrawal(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_withdrawals SET state = 'rejected', terminal_code = ?, terminal_current_revision = ? WHERE operation_id = ?", arguments: [code, try currentRevision.map(Self.commandStorageInteger), operationID.rawValue])
        }
    }

    public func pendingMessageWithdrawals() throws -> [V2PendingMessageWithdrawal] {
        try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_withdrawals ORDER BY created_at, operation_id").map(Self.decodePendingMessageWithdrawal) }
    }

    public func enqueue(_ command: V2PendingMessageRedaction) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0,
                  command.resultingMessageRevision == nil, command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, message_id, reason_code FROM v2_pending_message_redactions WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let roomID: String = existing["room_id"]
                let messageID: String = existing["message_id"]
                let reasonCode: String = existing["reason_code"]
                guard roomID == command.roomID.rawValue, messageID == command.messageID.rawValue,
                      reasonCode == command.reasonCode.rawValue
                else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_message_redactions (operation_id, room_id, message_id, reason_code, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, command.reasonCode.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageRedaction(
        _ command: V2PendingMessageRedaction
    ) throws -> V2PendingMessageRedaction {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMessageRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_redactions WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageRedaction(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.reasonCode == command.reasonCode,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_redactions
                WHERE room_id = ? AND message_id = ? AND reason_code = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reasonCode.rawValue
                ]
            ) {
                return try Self.decodePendingMessageRedaction(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_redactions
                    (operation_id, room_id, message_id, reason_code,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reasonCode.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMessageRedaction(now: Date) throws -> V2PendingMessageRedaction? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_redactions WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingMessageRedaction(row)
        }
    }

    public func markMessageRedactionAcknowledged(operationID: ModerationOperationID, messageRevision: UInt64, roomSequence: UInt64) throws {
        guard messageRevision > 1, roomSequence > 0 else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMessageRedaction(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_redactions SET state = 'acknowledged', resulting_message_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(messageRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue])
        }
    }

    public func scheduleMessageRedactionRetry(operationID: ModerationOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingMessageRedaction(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_redactions SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectMessageRedaction(operationID: ModerationOperationID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMessageRedaction(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_redactions SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue])
        }
    }

    public func pendingMessageRedactions() throws -> [V2PendingMessageRedaction] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_redactions ORDER BY created_at, operation_id").map(Self.decodePendingMessageRedaction)
        }
    }

    public func enqueue(_ command: V2PendingMemberMute) throws { try databasePool.write { db in
        guard command.muteUntil > command.nextAttemptAt, command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, target_user_id, mute_until, reason_code FROM v2_pending_member_mutes WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let room: String = row["room_id"], target: String = row["target_user_id"], until: Double = row["mute_until"], reason: String = row["reason_code"]; guard room == command.roomID.rawValue, target == command.targetUserID.rawValue, until == command.muteUntil.timeIntervalSince1970, reason == command.reasonCode.rawValue else { throw V2ClientCommandError.commandConflict }; return }
        try db.execute(sql: "INSERT INTO v2_pending_member_mutes (operation_id, room_id, target_user_id, mute_until, reason_code, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.targetUserID.rawValue, command.muteUntil.timeIntervalSince1970, command.reasonCode.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
    } }

    public func enqueueOrReusePendingMemberMute(
        _ command: V2PendingMemberMute
    ) throws -> V2PendingMemberMute {
        try databasePool.write { db in
            guard command.muteUntil > command.nextAttemptAt,
                  command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_member_mutes WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMemberMute(existing)
                guard decoded.roomID == command.roomID,
                      decoded.targetUserID == command.targetUserID,
                      decoded.muteUntil == command.muteUntil,
                      decoded.reasonCode == command.reasonCode,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_member_mutes
                WHERE room_id = ? AND target_user_id = ? AND mute_until = ?
                  AND reason_code = ? AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.muteUntil.timeIntervalSince1970,
                    command.reasonCode.rawValue
                ]
            ) {
                return try Self.decodePendingMemberMute(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_member_mutes
                    (operation_id, room_id, target_user_id, mute_until, reason_code,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.muteUntil.timeIntervalSince1970,
                    command.reasonCode.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }
    public func nextReadyMemberMute(now: Date) throws -> V2PendingMemberMute? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_member_mutes WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMemberMute(row) } }
    public func markMemberMuteAcknowledged(operationID: ModerationOperationID, roomSequence: UInt64) throws { guard roomSequence > 0 else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMemberMute(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_member_mutes SET state = 'acknowledged', resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(roomSequence), operationID.rawValue]) } }
    public func scheduleMemberMuteRetry(operationID: ModerationOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingMemberMute(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_member_mutes SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectMemberMute(operationID: ModerationOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMemberMute(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_member_mutes SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func pendingMemberMutes() throws -> [V2PendingMemberMute] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_member_mutes ORDER BY created_at, operation_id").map(Self.decodePendingMemberMute)
        }
    }

    public func enqueue(_ command: V2PendingModeratedMemberRemoval) throws { try databasePool.write { db in
        guard command.state == .pending, command.attemptCount == 0, command.resultingMembershipRevision == nil, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, target_user_id, reason_code FROM v2_pending_moderated_member_removals WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let room: String = row["room_id"], target: String = row["target_user_id"], reason: String = row["reason_code"]; guard room == command.roomID.rawValue, target == command.targetUserID.rawValue, reason == command.reasonCode.rawValue else { throw V2ClientCommandError.commandConflict }; return }
        try db.execute(sql: "INSERT INTO v2_pending_moderated_member_removals (operation_id, room_id, target_user_id, reason_code, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.targetUserID.rawValue, command.reasonCode.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
    } }

    public func enqueueOrReusePendingModeratedMemberRemoval(
        _ command: V2PendingModeratedMemberRemoval
    ) throws -> V2PendingModeratedMemberRemoval {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMembershipRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_moderated_member_removals WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingModeratedMemberRemoval(existing)
                guard decoded.roomID == command.roomID,
                      decoded.targetUserID == command.targetUserID,
                      decoded.reasonCode == command.reasonCode,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_moderated_member_removals
                WHERE room_id = ? AND target_user_id = ? AND reason_code = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.reasonCode.rawValue
                ]
            ) {
                return try Self.decodePendingModeratedMemberRemoval(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_moderated_member_removals
                    (operation_id, room_id, target_user_id, reason_code,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.reasonCode.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }
    public func nextReadyModeratedMemberRemoval(now: Date) throws -> V2PendingModeratedMemberRemoval? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_moderated_member_removals WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingModeratedMemberRemoval(row) } }
    public func markModeratedMemberRemovalAcknowledged(operationID: ModerationOperationID, membershipRevision: UInt64, roomSequence: UInt64) throws { guard membershipRevision > 0, roomSequence > 0 else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingModeratedMemberRemoval(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_moderated_member_removals SET state = 'acknowledged', resulting_membership_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(membershipRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue]) } }
    public func scheduleModeratedMemberRemovalRetry(operationID: ModerationOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingModeratedMemberRemoval(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_moderated_member_removals SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectModeratedMemberRemoval(operationID: ModerationOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingModeratedMemberRemoval(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_moderated_member_removals SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }
    public func pendingModeratedMemberRemovals() throws -> [V2PendingModeratedMemberRemoval] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_moderated_member_removals ORDER BY created_at, operation_id").map(Self.decodePendingModeratedMemberRemoval) } }

    public func enqueue(_ command: V2PendingMessageEdit) throws {
        try databasePool.write { db in
            guard !command.text.isEmpty, command.state == .pending, command.attemptCount == 0, command.resultingMessageRevision == nil, command.resultingRoomSequence == nil, command.terminalCode == nil, command.terminalCurrentRevision == nil else { throw V2ClientCommandError.commandConflict }
            if let row = try Row.fetchOne(db, sql: "SELECT room_id, message_id, expected_message_revision, text_body FROM v2_pending_message_edits WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let room: String = row["room_id"], message: String = row["message_id"], revision: Int64 = row["expected_message_revision"], text: String = row["text_body"]
                guard room == command.roomID.rawValue, message == command.messageID.rawValue, revision == (try Self.commandStorageInteger(command.expectedMessageRevision)), text == command.text else { throw V2ClientCommandError.commandConflict }; return
            }
            try db.execute(sql: "INSERT INTO v2_pending_message_edits (operation_id, room_id, message_id, expected_message_revision, text_body, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, try Self.commandStorageInteger(command.expectedMessageRevision), command.text, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageEdit(
        _ command: V2PendingMessageEdit
    ) throws -> V2PendingMessageEdit {
        try databasePool.write { db in
            guard !command.text.isEmpty,
                  command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMessageRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            let expectedRevision = try Self.commandStorageInteger(command.expectedMessageRevision)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_edits WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageEdit(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.expectedMessageRevision == command.expectedMessageRevision,
                      decoded.text == command.text,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_edits
                WHERE room_id = ? AND message_id = ?
                  AND expected_message_revision = ? AND text_body = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    expectedRevision,
                    command.text
                ]
            ) {
                return try Self.decodePendingMessageEdit(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_edits
                    (operation_id, room_id, message_id, expected_message_revision,
                     text_body, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    expectedRevision,
                    command.text,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }
    public func nextReadyMessageEdit(now: Date) throws -> V2PendingMessageEdit? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_edits WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMessageEdit(row) } }
    public func markMessageEditAcknowledged(operationID: MessageEditOperationID, messageRevision: UInt64, roomSequence: UInt64) throws { guard messageRevision > 0, roomSequence > 0 else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMessageEdit(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_edits SET state = 'acknowledged', resulting_message_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(messageRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue]) } }
    public func scheduleMessageEditRetry(operationID: MessageEditOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingMessageEdit(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_edits SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectMessageEdit(operationID: MessageEditOperationID, code: String, currentRevision: UInt64?) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMessageEdit(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_edits SET state = 'rejected', terminal_code = ?, terminal_current_revision = ? WHERE operation_id = ?", arguments: [code, try currentRevision.map(Self.commandStorageInteger), operationID.rawValue]) } }
    public func pendingMessageEdits() throws -> [V2PendingMessageEdit] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_edits ORDER BY created_at, operation_id").map(Self.decodePendingMessageEdit) } }

    public func enqueue(_ command: V2PendingReadReceipt) throws { try databasePool.write { db in
        guard command.readThroughRoomSequence > 0, command.readThroughRoomSequence <= UInt64(Int64.max), command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let requestedSequence = Int64(command.readThroughRoomSequence)
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, read_through_room_sequence FROM v2_pending_read_receipts WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let room: String = row["room_id"], sequence: Int64 = row["read_through_room_sequence"]; guard room == command.roomID.rawValue, sequence == requestedSequence else { throw V2ClientCommandError.commandConflict }; return }
        try db.execute(sql: "INSERT INTO v2_pending_read_receipts (operation_id, room_id, read_through_room_sequence, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, requestedSequence, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
    } }
    public func enqueueIfReadReceiptAdvances(_ command: V2PendingReadReceipt) throws -> Bool { try databasePool.write { db in
        guard command.readThroughRoomSequence > 0, command.readThroughRoomSequence <= UInt64(Int64.max), command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let requestedSequence = Int64(command.readThroughRoomSequence)
        let currentHighWater: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(CASE WHEN state = 'acknowledged' THEN resulting_room_sequence ELSE read_through_room_sequence END), 0) FROM v2_pending_read_receipts WHERE room_id = ? AND state IN ('pending', 'acknowledged')",
            arguments: [command.roomID.rawValue]
        ) ?? 0
        guard requestedSequence > currentHighWater else { return false }
        try db.execute(sql: "INSERT INTO v2_pending_read_receipts (operation_id, room_id, read_through_room_sequence, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, requestedSequence, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        return true
    } }
    public func nextReadyReadReceipt(now: Date) throws -> V2PendingReadReceipt? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_read_receipts WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingReadReceipt(row) } }
    public func markReadReceiptAcknowledged(operationID: ReadReceiptOperationID, roomSequence: UInt64) throws { guard roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingReadReceipt(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_read_receipts SET state = 'acknowledged', resulting_room_sequence = ? WHERE operation_id = ?", arguments: [Int64(roomSequence), operationID.rawValue]) } }
    public func scheduleReadReceiptRetry(operationID: ReadReceiptOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingReadReceipt(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_read_receipts SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectReadReceipt(operationID: ReadReceiptOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingReadReceipt(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_read_receipts SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }
    public func pendingReadReceipts() throws -> [V2PendingReadReceipt] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_read_receipts ORDER BY created_at, operation_id").map(Self.decodePendingReadReceipt) } }

    public func enqueue(_ command: V2PendingMessageReaction) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
            if let row = try Row.fetchOne(db, sql: "SELECT room_id, message_id, reaction, action FROM v2_pending_message_reactions WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let room: String = row["room_id"], message: String = row["message_id"], reaction: String = row["reaction"], action: String = row["action"]
                guard room == command.roomID.rawValue, message == command.messageID.rawValue, reaction == command.reaction, action == command.action.rawValue else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_message_reactions (operation_id, room_id, message_id, reaction, action, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, command.reaction, command.action.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageReaction(
        _ command: V2PendingMessageReaction
    ) throws -> V2PendingMessageReaction {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_reactions WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageReaction(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.reaction == command.reaction,
                      decoded.action == command.action,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_reactions
                WHERE room_id = ? AND message_id = ? AND reaction = ? AND action = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reaction,
                    command.action.rawValue
                ]
            ) {
                return try Self.decodePendingMessageReaction(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_reactions
                    (operation_id, room_id, message_id, reaction, action,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reaction,
                    command.action.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMessageReaction(now: Date) throws -> V2PendingMessageReaction? {
        try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_reactions WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMessageReaction(row) }
    }
    public func markMessageReactionAcknowledged(operationID: MessageReactionOperationID, roomSequence: UInt64) throws {
        guard roomSequence > 0 else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in try Self.requirePendingMessageReaction(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_reactions SET state = 'acknowledged', resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(roomSequence), operationID.rawValue]) }
    }
    public func scheduleMessageReactionRetry(operationID: MessageReactionOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in try Self.requirePendingMessageReaction(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_reactions SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) }
    }
    public func rejectMessageReaction(operationID: MessageReactionOperationID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in try Self.requirePendingMessageReaction(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_reactions SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) }
    }

    public func pendingMessageReactions() throws -> [V2PendingMessageReaction] {
        try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_reactions ORDER BY created_at, operation_id").map(Self.decodePendingMessageReaction) }
    }

    public func enqueueOrReuseConversationState(_ pending: V2PendingConversationStateCommand) throws -> V2PendingConversationStateCommand { try databasePool.write { db in
        guard pending.state == .pending, pending.attemptCount == 0, pending.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let command = pending.command
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_conversation_states WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
            let existing = try Self.decodePendingConversationState(row)
            guard existing.command == command, existing.state == .pending else { throw V2ClientCommandError.commandConflict }; return existing
        }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_conversation_states WHERE room_id = ? AND is_pinned = ? AND is_archived = ? AND mute_until = ? AND state = 'pending' ORDER BY created_at, operation_id LIMIT 1", arguments: [command.roomID.rawValue, command.isPinned, command.isArchived, command.muteUntil?.timeIntervalSince1970 ?? 0]) { return try Self.decodePendingConversationState(row) }
        try db.execute(sql: "INSERT INTO v2_pending_conversation_states (operation_id, room_id, is_pinned, is_archived, mute_until, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.isPinned, command.isArchived, command.muteUntil?.timeIntervalSince1970 ?? 0, pending.nextAttemptAt.timeIntervalSince1970, pending.nextAttemptAt.timeIntervalSince1970])
        return pending
    } }
    public func nextReadyConversationState(now: Date) throws -> V2PendingConversationStateCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_conversation_states WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingConversationState(row) } }
    public func markConversationStateAcknowledged(operationID: ConversationPreferenceOperationID) throws { try databasePool.write { db in try Self.requirePendingConversationState(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_conversation_states SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID.rawValue]) } }
    public func scheduleConversationStateRetry(operationID: ConversationPreferenceOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingConversationState(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_conversation_states SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectConversationState(operationID: ConversationPreferenceOperationID, code: String) throws { guard !code.isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingConversationState(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_conversation_states SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func enqueueOrReuseMessageFavorite(_ pending: V2PendingMessageFavoriteCommand) throws -> V2PendingMessageFavoriteCommand { try databasePool.write { db in
        guard pending.state == .pending, pending.attemptCount == 0, pending.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let command = pending.command
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_favorites WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let existing = try Self.decodePendingMessageFavorite(row); guard existing.command == command, existing.state == .pending else { throw V2ClientCommandError.commandConflict }; return existing }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_favorites WHERE room_id = ? AND message_id = ? AND is_favorited = ? AND state = 'pending' ORDER BY created_at, operation_id LIMIT 1", arguments: [command.roomID.rawValue, command.messageID.rawValue, command.isFavorited]) { return try Self.decodePendingMessageFavorite(row) }
        try db.execute(sql: "INSERT INTO v2_pending_message_favorites (operation_id, room_id, message_id, is_favorited, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, command.isFavorited, pending.nextAttemptAt.timeIntervalSince1970, pending.nextAttemptAt.timeIntervalSince1970]); return pending
    } }
    public func nextReadyMessageFavorite(now: Date) throws -> V2PendingMessageFavoriteCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_favorites WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMessageFavorite(row) } }
    public func markMessageFavoriteAcknowledged(operationID: MessageFavoriteOperationID) throws { try databasePool.write { db in try Self.requirePendingMessageFavorite(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_favorites SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID.rawValue]) } }
    public func scheduleMessageFavoriteRetry(operationID: MessageFavoriteOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingMessageFavorite(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_favorites SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectMessageFavorite(operationID: MessageFavoriteOperationID, code: String) throws { guard !code.isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMessageFavorite(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_favorites SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func enqueueOrReuseGroupCapability(_ command: V2PendingGroupCapabilityCommand) throws -> V2PendingGroupCapabilityCommand { try databasePool.write { db in
        guard command.state == .pending, command.attemptCount == 0, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_capabilities WHERE operation_id = ?", arguments: [command.operationID]) { let existing = try Self.decodePendingGroupCapability(row); guard existing == command else { throw V2ClientCommandError.commandConflict }; return existing }
        let permissions = String(decoding: try JSONEncoder().encode(command.permissions.map(\.rawValue).sorted()), as: UTF8.self)
        try db.execute(sql: "INSERT INTO v2_pending_group_capabilities (operation_id, kind, room_id, message_id, is_pinned, body, role, permissions, target_user_id, expected_revision, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID, command.kind.rawValue, command.roomID.rawValue, command.messageID?.rawValue, command.isPinned, command.body, command.role?.rawValue, permissions, command.targetUserID?.rawValue, try Self.storageInteger(command.expectedRevision), command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        return command
    } }
    public func nextReadyGroupCapability(now: Date) throws -> V2PendingGroupCapabilityCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_capabilities WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingGroupCapability(row) } }
    public func markGroupCapabilityAcknowledged(operationID: String) throws { try databasePool.write { db in guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_pending_group_capabilities WHERE operation_id = ? AND state = 'pending')", arguments: [operationID]) == true else { throw V2ClientCommandError.commandConflict }; try db.execute(sql: "UPDATE v2_pending_group_capabilities SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID]) } }
    public func scheduleGroupCapabilityRetry(operationID: String, nextAttemptAt: Date) throws { try databasePool.write { db in guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_pending_group_capabilities WHERE operation_id = ? AND state = 'pending')", arguments: [operationID]) == true else { throw V2ClientCommandError.commandConflict }; try db.execute(sql: "UPDATE v2_pending_group_capabilities SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID]) } }
    public func rejectGroupCapability(operationID: String, code: String) throws { guard !code.isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_pending_group_capabilities WHERE operation_id = ? AND state = 'pending')", arguments: [operationID]) == true else { throw V2ClientCommandError.commandConflict }; try db.execute(sql: "UPDATE v2_pending_group_capabilities SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID]) } }

    public func enqueueOrReuseForwardMessages(_ pending: V2PendingForwardMessagesCommand) throws -> V2PendingForwardMessagesCommand { try databasePool.write { db in let command = pending.command; if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_forward_messages WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let existing = try Self.decodePendingForwardMessages(row); guard existing.command == command else { throw V2ClientCommandError.commandConflict }; return existing }; let sources = String(decoding: try JSONEncoder().encode(command.sourceMessageIDs.map(\.rawValue)), as: UTF8.self); let targets = String(decoding: try JSONEncoder().encode(command.targetRoomIDs.map(\.rawValue)), as: UTF8.self); try db.execute(sql: "INSERT INTO v2_pending_forward_messages (operation_id, source_message_ids, target_room_ids, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, sources, targets, pending.nextAttemptAt.timeIntervalSince1970, pending.nextAttemptAt.timeIntervalSince1970]); return pending } }
    public func nextReadyForwardMessages(now: Date) throws -> V2PendingForwardMessagesCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_forward_messages WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingForwardMessages(row) } }
    public func markForwardMessagesAcknowledged(operationID: MessageForwardOperationID) throws { try databasePool.write { db in try Self.requirePendingForwardMessages(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_forward_messages SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID.rawValue]) } }
    public func scheduleForwardMessagesRetry(operationID: MessageForwardOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingForwardMessages(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_forward_messages SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectForwardMessages(operationID: MessageForwardOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingForwardMessages(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_forward_messages SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func enqueue(_ command: V2PendingSocialCommand) throws {
        try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT command_kind, target_user_id, relationship_action, block_action, stranger_permission, user_add_permission, allows_direct_read_receipts, allows_group_read_receipts FROM v2_pending_social_commands WHERE operation_id = ?", arguments: [command.operationID]) {
                let kind: String = row["command_kind"]
                let target: String? = row["target_user_id"]
                let relationship: String? = row["relationship_action"]
                let block: String? = row["block_action"]
                let permission: String? = row["stranger_permission"]
                let addPermission: String? = row["user_add_permission"]
                let direct: Bool? = row["allows_direct_read_receipts"], group: Bool? = row["allows_group_read_receipts"]
                guard kind == command.kind.rawValue, target == command.targetUserID?.rawValue, relationship == command.relationshipAction?.rawValue, block == command.blockAction?.rawValue, permission == command.strangerPermission?.rawValue, addPermission == command.userAddPermission?.rawValue, direct == command.allowsDirectReadReceipts, group == command.allowsGroupReadReceipts else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_social_commands (operation_id, command_kind, target_user_id, relationship_action, block_action, stranger_permission, user_add_permission, allows_direct_read_receipts, allows_group_read_receipts, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID, command.kind.rawValue, command.targetUserID?.rawValue, command.relationshipAction?.rawValue, command.blockAction?.rawValue, command.strangerPermission?.rawValue, command.userAddPermission?.rawValue, command.allowsDirectReadReceipts, command.allowsGroupReadReceipts, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingSocialCommand(
        _ command: V2PendingSocialCommand
    ) throws -> V2PendingSocialCommand {
        try databasePool.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_social_commands WHERE operation_id = ?",
                arguments: [command.operationID]
            ) {
                let decoded = try Self.decodePendingSocialCommand(existing)
                guard decoded.kind == command.kind,
                      decoded.targetUserID == command.targetUserID,
                      decoded.relationshipAction == command.relationshipAction,
                      decoded.blockAction == command.blockAction,
                      decoded.strangerPermission == command.strangerPermission,
                      decoded.userAddPermission == command.userAddPermission,
                      decoded.allowsDirectReadReceipts == command.allowsDirectReadReceipts,
                      decoded.allowsGroupReadReceipts == command.allowsGroupReadReceipts,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_social_commands
                WHERE command_kind = ?
                  AND target_user_id IS ?
                  AND relationship_action IS ?
                  AND block_action IS ?
                  AND stranger_permission IS ?
                  AND user_add_permission IS ?
                  AND allows_direct_read_receipts IS ?
                  AND allows_group_read_receipts IS ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.kind.rawValue,
                    command.targetUserID?.rawValue,
                    command.relationshipAction?.rawValue,
                    command.blockAction?.rawValue,
                    command.strangerPermission?.rawValue
                    , command.userAddPermission?.rawValue, command.allowsDirectReadReceipts, command.allowsGroupReadReceipts
                ]
            ) {
                return try Self.decodePendingSocialCommand(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_social_commands
                (operation_id, command_kind, target_user_id, relationship_action,
                 block_action, stranger_permission, user_add_permission, allows_direct_read_receipts, allows_group_read_receipts, state, attempt_count,
                 next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID,
                    command.kind.rawValue,
                    command.targetUserID?.rawValue,
                    command.relationshipAction?.rawValue,
                    command.blockAction?.rawValue,
                    command.strangerPermission?.rawValue,
                    command.userAddPermission?.rawValue,
                    command.allowsDirectReadReceipts, command.allowsGroupReadReceipts,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadySocialCommand(now: Date) throws -> V2PendingSocialCommand? {
        try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_social_commands WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingSocialCommand(row) }
    }
    public func markSocialCommandAcknowledged(operationID: String) throws { try databasePool.write { db in try Self.requirePendingSocialCommand(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_social_commands SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID]) } }
    public func scheduleSocialCommandRetry(operationID: String, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingSocialCommand(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_social_commands SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID]) } }
    public func rejectSocialCommand(operationID: String, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingSocialCommand(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_social_commands SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID]) } }
    public func pendingSocialCommands() throws -> [V2PendingSocialCommand] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_social_commands ORDER BY created_at, operation_id").map(Self.decodePendingSocialCommand) } }

    public func enqueue(_ command: V2PendingGroupRoomCreation) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0, command.createdRoomID == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
            let members = try Self.encodeGroupMemberUserIDs(command.initialMemberUserIDs)
            if let existing = try Row.fetchOne(db, sql: "SELECT title, delivery_mode, initial_member_user_ids FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let title: String = existing["title"]
                let deliveryMode: String = existing["delivery_mode"]
                let existingMembers: String = existing["initial_member_user_ids"]
                guard title == command.title, deliveryMode == command.deliveryMode.rawValue, existingMembers == members else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_group_room_creations (operation_id, title, delivery_mode, initial_member_user_ids, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.title, command.deliveryMode.rawValue, members, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingGroupRoomCreation(
        _ command: V2PendingGroupRoomCreation
    ) throws -> V2PendingGroupRoomCreation {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.createdRoomID == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            let members = try Self.encodeGroupMemberUserIDs(command.initialMemberUserIDs)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_group_room_creations WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingGroupRoomCreation(existing)
                guard decoded.title == command.title,
                      decoded.deliveryMode == command.deliveryMode,
                      decoded.initialMemberUserIDs == command.initialMemberUserIDs,
                      decoded.state == .pending || decoded.state == .finalizing
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_group_room_creations
                WHERE title = ? AND delivery_mode = ? AND initial_member_user_ids = ? AND state IN ('pending', 'finalizing')
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [command.title, command.deliveryMode.rawValue, members]
            ) {
                return try Self.decodePendingGroupRoomCreation(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_group_room_creations
                (operation_id, title, delivery_mode, initial_member_user_ids, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.title,
                    command.deliveryMode.rawValue,
                    members,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyGroupRoomCreation(now: Date) throws -> V2PendingGroupRoomCreation? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_room_creations WHERE state IN ('pending', 'finalizing') AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingGroupRoomCreation(row)
        }
    }

    public func markGroupRoomCreationMembersUploaded(operationID: GroupRoomOperationID, uploadedMemberCount: Int) throws {
        try databasePool.write { db in
            guard uploadedMemberCount >= 0,
                  let row = try Row.fetchOne(
                    db,
                    sql: "SELECT initial_member_user_ids, uploaded_member_count FROM v2_pending_group_room_creations WHERE operation_id = ? AND state IN ('pending', 'finalizing')",
                    arguments: [operationID.rawValue]
                  )
            else { throw V2ClientCommandError.commandNotPending }
            let memberIDs = try Self.decodeGroupMemberUserIDs(row["initial_member_user_ids"] as String)
            let current = Int(row["uploaded_member_count"] as Int64)
            guard uploadedMemberCount >= current, uploadedMemberCount <= memberIDs.count else {
                throw V2ClientCommandError.commandConflict
            }
            try db.execute(
                sql: "UPDATE v2_pending_group_room_creations SET uploaded_member_count = ? WHERE operation_id = ?",
                arguments: [uploadedMemberCount, operationID.rawValue]
            )
        }
    }

    public func resetGroupRoomCreationUploadProgress(operationID: GroupRoomOperationID) throws {
        try databasePool.write { db in
            try Self.requireActiveGroupRoomCreation(operationID, db: db)
            try db.execute(
                sql: "UPDATE v2_pending_group_room_creations SET uploaded_member_count = 0 WHERE operation_id = ?",
                arguments: [operationID.rawValue]
            )
        }
    }

    public func markGroupRoomCreationAcknowledged(operationID: GroupRoomOperationID, roomID: RoomID) throws {
        try databasePool.write { db in
            try Self.requireActiveGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'acknowledged', created_room_id = ?, terminal_code = NULL WHERE operation_id = ?", arguments: [roomID.rawValue, operationID.rawValue])
        }
    }

    public func scheduleGroupRoomCreationRetry(operationID: GroupRoomOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == "pending" || state == "finalizing" || state == "cancelling" else { throw V2ClientCommandError.commandNotPending }
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func beginCancellingGroupRoomCreation(operationID: GroupRoomOperationID, now: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'cancelling', next_attempt_at = ? WHERE operation_id = ?", arguments: [now.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func nextReadyGroupRoomCreationCancellation(now: Date) throws -> V2PendingGroupRoomCreation? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_room_creations WHERE state = 'cancelling' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingGroupRoomCreation(row)
        }
    }

    public func markGroupRoomCreationCancelled(operationID: GroupRoomOperationID) throws {
        try databasePool.write { db in
            guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == "cancelling" else { throw V2ClientCommandError.commandNotPending }
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'cancelled', terminal_code = NULL WHERE operation_id = ?", arguments: [operationID.rawValue])
        }
    }

    public func resumeGroupRoomCreationAfterCancellationRefusal(operationID: GroupRoomOperationID, now: Date) throws {
        try databasePool.write { db in
            guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == "cancelling" else { throw V2ClientCommandError.commandNotPending }
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'finalizing', next_attempt_at = ? WHERE operation_id = ?", arguments: [now.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectGroupRoomCreation(operationID: GroupRoomOperationID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requireActiveGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue])
        }
    }

    public func pendingGroupRoomCreations() throws -> [V2PendingGroupRoomCreation] {
        try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_group_room_creations ORDER BY created_at, operation_id").map(Self.decodePendingGroupRoomCreation) }
    }

    public func groupRoomCreations() throws -> [V2PendingGroupRoomCreation] {
        try pendingGroupRoomCreations()
    }

    private static func validateOrdering(_ records: [V2ClientSyncRecord]) throws {
        for pair in zip(records, records.dropFirst()) where pair.1.sequence <= pair.0.sequence {
            throw V2ClientSyncError.invalidRecordOrdering
        }
    }

    /// PostgreSQL's `BIGINT` and SQLite's `INTEGER` are signed. Keep the
    /// protocol's wider `uint64` domain at the transport boundary and fail
    /// closed before any value enters durable local state.
    private static func storageInteger(_ value: UInt64) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw V2ClientSyncError.storageRangeExceeded
        }
        return result
    }

    private static func storageUnsigned(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else { throw V2ClientSyncError.storageRangeExceeded }
        return UInt64(value)
    }

    private static func commandStorageInteger(_ value: UInt64) throws -> Int64 {
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
        let avatarMediaID: String? = row["avatar_media_id"]
        let identity: V2PublicIdentity?
        switch (handle, displayName) {
        case (.none, .none): identity = nil
        case let (.some(handle), .some(displayName)):
            identity = try .init(userID: userID, handle: .init(handle), displayName: displayName)
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
                  decoded.roomID == projection.roomID, decoded.roomSequence == projection.roomSequence,
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
                (message_id, source_event_id, room_id, room_sequence, message_revision, sender_user_id, text_body, media_ids, media_presentations, mention_targets, entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, server_created_at, is_withdrawn)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [projection.messageID.rawValue, projection.sourceEventID.rawValue, projection.roomID.rawValue,
                        try storageInteger(projection.roomSequence), try storageInteger(projection.messageRevision), projection.senderUserID.rawValue, projection.text, try encodeMedia(projection.media), try encodeMediaPresentations(projection.mediaPresentations), try encodeMentions(projection.mentions), try encodeEntities(projection.entities, text: projection.text), projection.replyTo?.messageID.rawValue, projection.forwardedFrom?.messageID.rawValue, projection.forwardedFrom?.senderUserID.rawValue,
                        projection.createdAt.timeIntervalSince1970, projection.isWithdrawn]
        )
        if let tombstone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let roomID: String = tombstone["room_id"]
            let revision: Int64 = tombstone["message_revision"]
            guard roomID == projection.roomID.rawValue, revision > (try storageInteger(projection.messageRevision)) else { throw V2ClientProjectionError.invalidMessagePayload }
            try db.execute(sql: "UPDATE v2_message_projections SET message_revision = ?, is_withdrawn = 1 WHERE message_id = ?", arguments: [revision, projection.messageID.rawValue])
        }
        try refreshMessageSearchIndex(messageID: projection.messageID, db: db)
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
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, target_user_id, public_handle, display_name, revision FROM v2_direct_room_profile_projections WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let existingRevision: Int64 = existing["revision"]
            let incomingRevision = try storageInteger(projection.revision)
            guard existingRevision <= incomingRevision else { throw V2ClientProjectionError.invalidMessagePayload }
            if existingRevision == incomingRevision {
                guard (existing["source_event_id"] as String) == projection.sourceEventID.rawValue,
                      (existing["target_user_id"] as String) == projection.publicIdentity.userID.rawValue,
                      (existing["public_handle"] as String) == projection.publicIdentity.handle.rawValue,
                      (existing["display_name"] as String) == projection.publicIdentity.displayName
                else { throw V2ClientProjectionError.invalidMessagePayload }
                try persist(profileView(from: projection), db: db)
                return
            }
            try db.execute(sql: "UPDATE v2_direct_room_profile_projections SET source_event_id = ?, target_user_id = ?, public_handle = ?, display_name = ?, revision = ?, updated_at = ? WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, incomingRevision, projection.updatedAt.timeIntervalSince1970, projection.roomID.rawValue])
            try persist(profileView(from: projection), db: db)
            return
        }
        try db.execute(sql: "INSERT INTO v2_direct_room_profile_projections (room_id, source_event_id, target_user_id, public_handle, display_name, revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, try storageInteger(projection.revision), projection.updatedAt.timeIntervalSince1970])
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
            sql: "SELECT public_handle, display_name, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id = ?",
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
                      (existing["avatar_media_id"] as String?) == profile.avatar?.mediaID.rawValue,
                      (existing["state"] as String) == profile.state.rawValue
                else { throw V2ClientProjectionError.invalidMessagePayload }
                try clearSatisfiedInvalidation(for: profile, db: db)
                return
            }
            try db.execute(
                sql: "UPDATE v2_profile_views SET public_handle = ?, display_name = ?, avatar_media_id = ?, state = ?, revision = ?, visibility_revision = ?, updated_at = ? WHERE user_id = ?",
                arguments: [profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970, profile.userID.rawValue]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO v2_profile_views (user_id, public_handle, display_name, avatar_media_id, state, revision, visibility_revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [profile.userID.rawValue, profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970]
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
            try db.execute(sql: "UPDATE v2_message_projections SET message_revision = ?, is_withdrawn = 1 WHERE message_id = ?", arguments: [try storageInteger(tombstone.messageRevision), tombstone.messageID.rawValue])
            try refreshMessageSearchIndex(messageID: tombstone.messageID, db: db)
        }
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
        try refreshMessageSearchIndex(messageID: edit.messageID, db: db)
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

    private static func requirePendingCommand(_ clientMessageID: ClientMessageID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_commands WHERE client_message_id = ?", arguments: [clientMessageID.rawValue])?["state"], state == V2PendingMessageCommand.State.pending.rawValue else {
            throw V2ClientCommandError.commandNotPending
        }
    }

    private static func requirePendingMembershipCommand(_ operationID: MembershipOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_membership_commands WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMembershipCommand.State.pending.rawValue else {
            throw V2ClientCommandError.commandNotPending
        }
    }

    private static func requirePendingMessageWithdrawal(_ operationID: MessageWithdrawalOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_withdrawals WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageWithdrawal.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending }
    }
    private static func requirePendingMessageRedaction(_ operationID: ModerationOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_redactions WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageRedaction.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending }
    }
    private static func requirePendingMemberMute(_ operationID: ModerationOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_member_mutes WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMemberMute.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingModeratedMemberRemoval(_ operationID: ModerationOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_moderated_member_removals WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingModeratedMemberRemoval.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingMessageReaction(_ operationID: MessageReactionOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_reactions WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageReaction.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending }
    }
    private static func requirePendingConversationState(_ operationID: ConversationPreferenceOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_conversation_states WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingConversationStateCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingMessageFavorite(_ operationID: MessageFavoriteOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_favorites WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageFavoriteCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingForwardMessages(_ operationID: MessageForwardOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_forward_messages WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingForwardMessagesCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingMessageEdit(_ operationID: MessageEditOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_edits WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageEdit.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingReadReceipt(_ operationID: ReadReceiptOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_read_receipts WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingReadReceipt.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingSocialCommand(_ operationID: String, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_social_commands WHERE operation_id = ?", arguments: [operationID])?["state"], state == V2PendingSocialCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingGroupRoomCreation(_ operationID: GroupRoomOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingGroupRoomCreation.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requireActiveGroupRoomCreation(_ operationID: GroupRoomOperationID, db: Database) throws {
        guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingGroupRoomCreation.State.pending.rawValue || state == V2PendingGroupRoomCreation.State.finalizing.rawValue else {
            throw V2ClientCommandError.commandNotPending
        }
    }

    private static func decodePendingCommand(_ row: Row) throws -> V2PendingMessageCommand {
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

    private static func encodeMedia(_ media: [V2MediaReference]) throws -> String {
        guard media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count,
              let encoded = String(data: try JSONEncoder().encode(media.map { $0.mediaID.rawValue }), encoding: .utf8)
        else { throw V2ClientCommandError.commandConflict }
        return encoded
    }

    private static func decodeMedia(_ encoded: String) throws -> [V2MediaReference] {
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

    private static func encodeMediaPresentations(_ presentations: [V2MediaPresentation]) throws -> String {
        guard let encoded = String(data: try JSONEncoder().encode(presentations.map(MediaPresentationWire.init)), encoding: .utf8) else {
            throw V2ClientCommandError.commandConflict
        }
        return encoded
    }

    private static func decodeMediaPresentations(_ encoded: String) throws -> [V2MediaPresentation] {
        let wire: [MediaPresentationWire]
        do { wire = try JSONDecoder().decode([MediaPresentationWire].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        return try wire.map { try $0.presentation() }
    }

    private struct MentionWire: Codable { let kind: String; let userID: String?; enum CodingKeys: String, CodingKey { case kind; case userID = "user_id" } }
    private static func encodeMentions(_ mentions: [V2MentionTarget]) throws -> String {
        guard mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2ClientCommandError.commandConflict }
        let wire = mentions.map { target -> MentionWire in
            switch target { case .user(let userID): .init(kind: "user", userID: userID.rawValue); case .everyone: .init(kind: "everyone", userID: nil) }
        }
        guard let encoded = String(data: try JSONEncoder().encode(wire), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }
    private static func decodeMentions(_ encoded: String) throws -> [V2MentionTarget] {
        let wire: [MentionWire]
        do { wire = try JSONDecoder().decode([MentionWire].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        let mentions = try wire.map { value -> V2MentionTarget in
            switch value.kind { case "user": guard let userID = value.userID else { throw V2ClientCommandError.commandConflict }; return .user(try .init(userID)); case "everyone": guard value.userID == nil else { throw V2ClientCommandError.commandConflict }; return .everyone; default: throw V2ClientCommandError.commandConflict }
        }
        guard mentions.count <= V2MessageCommandLimits.maxMentions, Set(mentions).count == mentions.count else { throw V2ClientCommandError.commandConflict }
        return mentions
    }

    private static func encodeEntities(_ entities: [V2MessageEntity], text: String) throws -> String {
        try V2RichMessageContent.validate(text: text, entities: entities)
        guard let encoded = String(data: try JSONEncoder().encode(entities), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }

    private static func decodeEntities(_ encoded: String, text: String) throws -> [V2MessageEntity] {
        let entities: [V2MessageEntity]
        do { entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        try V2RichMessageContent.validate(text: text, entities: entities)
        return entities
    }

    private static func decodePendingMembershipCommand(_ row: Row) throws -> V2PendingMembershipCommand {
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

    private static func decodePendingMessageWithdrawal(_ row: Row) throws -> V2PendingMessageWithdrawal {
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

    private static func decodePendingMessageRedaction(_ row: Row) throws -> V2PendingMessageRedaction {
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
    private static func decodePendingMemberMute(_ row: Row) throws -> V2PendingMemberMute { guard let state = V2PendingMemberMute.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), targetUserID: .init(row["target_user_id"] as String), muteUntil: Date(timeIntervalSince1970: row["mute_until"] as Double), reasonCode: .init(row["reason_code"] as String), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"]) }
    private static func decodePendingModeratedMemberRemoval(_ row: Row) throws -> V2PendingModeratedMemberRemoval { guard let state = V2PendingModeratedMemberRemoval.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), targetUserID: .init(row["target_user_id"] as String), reasonCode: .init(row["reason_code"] as String), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingMembershipRevision: (row["resulting_membership_revision"] as Int64?).map(UInt64.init), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"]) }

    private static func decodeRoomControlProjection(_ row: Row) throws -> V2ClientRoomControlProjection {
        let sourceEventID: EventID = try .init(row["source_event_id"] as String)
        let roomID: RoomID = try .init(row["room_id"] as String)
        let actorUserID: UserID = try .init(row["actor_user_id"] as String)
        let sequence = UInt64(row["room_sequence"] as Int64)
        guard sequence > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        return try .init(sourceEventID: sourceEventID, roomID: roomID, roomSequence: sequence, actorUserID: actorUserID, isFrozen: row["is_frozen"], createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double))
    }

    private static func decodeRoomProfileProjection(_ row: Row) throws -> V2ClientRoomProfileProjection {
        let revision = UInt64(row["membership_revision"] as Int64)
        let snapshot = try V2SnapshotRoomProfileProjection(sourceEventID: .init(row["source_event_id"] as String), roomID: .init(row["room_id"] as String), title: row["title"], ownerUserID: .init(row["owner_user_id"] as String), membershipRevision: revision, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
        let deliveryMode = (row["delivery_mode"] as String?).flatMap(V2GroupDeliveryMode.init)
        return .init(snapshotProjection: snapshot, deliveryMode: deliveryMode)
    }

    private static func decodeDirectRoomIdentity(_ row: Row) throws -> V2ClientDirectRoomIdentity {
        let identity = try V2PublicIdentity(
            userID: .init(row["target_user_id"] as String),
            handle: .init(row["public_handle"] as String),
            displayName: row["display_name"] as String
        )
        return try .init(
            roomID: .init(row["room_id"] as String),
            publicIdentity: identity,
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double)
        )
    }

    private static func decodePendingMessageReaction(_ row: Row) throws -> V2PendingMessageReaction {
        guard let state = V2PendingMessageReaction.State(rawValue: row["state"] as String), let action = V2MessageReactionAction(rawValue: row["action"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String), reaction: row["reaction"], action: action, state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"])
    }
    private static func decodePendingConversationState(_ row: Row) throws -> V2PendingConversationStateCommand {
        guard let state = V2PendingConversationStateCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let muteUntil = (row["mute_until"] as Double) == 0 ? nil : Date(timeIntervalSince1970: row["mute_until"] as Double)
        return try .init(command: .init(operationID: .init(row["operation_id"] as String), roomID: .init(row["room_id"] as String), isPinned: row["is_pinned"], isArchived: row["is_archived"], muteUntil: muteUntil), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    private static func decodePendingMessageFavorite(_ row: Row) throws -> V2PendingMessageFavoriteCommand {
        guard let state = V2PendingMessageFavoriteCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(command: .init(operationID: .init(row["operation_id"] as String), roomID: .init(row["room_id"] as String), messageID: .init(row["message_id"] as String), isFavorited: row["is_favorited"]), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    private static func decodePendingGroupCapability(_ row: Row) throws -> V2PendingGroupCapabilityCommand {
        guard let kind = V2PendingGroupCapabilityCommand.Kind(rawValue: row["kind"] as String), let state = V2PendingGroupCapabilityCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        let role = (row["role"] as String?).flatMap(V2RoomMembershipRole.init(rawValue:))
        let rawPermissions = try JSONDecoder().decode([String].self, from: Data((row["permissions"] as String).utf8))
        let permissions = Set(rawPermissions.compactMap(V2GroupPermission.init(rawValue:)))
        guard permissions.count == rawPermissions.count else { throw V2ClientCommandError.commandConflict }
        return try .init(kind: kind, operationID: row["operation_id"], roomID: .init(row["room_id"] as String), messageID: try (row["message_id"] as String?).map(MessageID.init), isPinned: row["is_pinned"], body: row["body"], role: role, permissions: permissions, targetUserID: try (row["target_user_id"] as String?).map(UserID.init), expectedRevision: try storageUnsigned(row["expected_revision"] as Int64), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    private static func decodePendingForwardMessages(_ row: Row) throws -> V2PendingForwardMessagesCommand { guard let state = V2PendingForwardMessagesCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; let sources = try JSONDecoder().decode([String].self, from: Data((row["source_message_ids"] as String).utf8)).map(MessageID.init); let targets = try JSONDecoder().decode([String].self, from: Data((row["target_room_ids"] as String).utf8)).map(RoomID.init); return try .init(command: .init(operationID: .init(row["operation_id"] as String), sourceMessageIDs: sources, targetRoomIDs: targets), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"]) }
    private static func decodePendingMessageEdit(_ row: Row) throws -> V2PendingMessageEdit {
        guard let state = V2PendingMessageEdit.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String), expectedMessageRevision: UInt64(row["expected_message_revision"] as Int64), text: row["text_body"], state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(UInt64.init), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"], terminalCurrentRevision: (row["terminal_current_revision"] as Int64?).map(UInt64.init))
    }
    private static func decodePendingReadReceipt(_ row: Row) throws -> V2PendingReadReceipt { guard let state = V2PendingReadReceipt.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), readThroughRoomSequence: UInt64(row["read_through_room_sequence"] as Int64), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"]) }
    private static func decodePendingSocialCommand(_ row: Row) throws -> V2PendingSocialCommand {
        guard let kind = V2PendingSocialCommandKind(rawValue: row["command_kind"] as String), let state = V2PendingSocialCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(operationID: row["operation_id"], kind: kind, targetUserID: try (row["target_user_id"] as String?).map(UserID.init), relationshipAction: (row["relationship_action"] as String?).flatMap(V2RelationshipAction.init), blockAction: (row["block_action"] as String?).flatMap(V2UserBlockAction.init), strangerPermission: (row["stranger_permission"] as String?).flatMap(V2StrangerMessagePermission.init), userAddPermission: (row["user_add_permission"] as String?).flatMap(V2UserAddPermission.init), allowsDirectReadReceipts: row["allows_direct_read_receipts"], allowsGroupReadReceipts: row["allows_group_read_receipts"], state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    private static func encodeGroupMemberUserIDs(_ members: [UserID]) throws -> String {
        guard let encoded = String(data: try JSONEncoder().encode(members.map(\.rawValue)), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }
    private static func decodeGroupMemberUserIDs(_ encoded: String) throws -> [UserID] {
        try JSONDecoder().decode([String].self, from: Data(encoded.utf8)).map(UserID.init)
    }
    private static func decodePendingGroupRoomCreation(_ row: Row) throws -> V2PendingGroupRoomCreation {
        let membersData = Data((row["initial_member_user_ids"] as String).utf8)
        let members = try JSONDecoder().decode([String].self, from: membersData).map(UserID.init)
        guard let state = V2PendingGroupRoomCreation.State(rawValue: row["state"] as String),
              let deliveryMode = V2GroupDeliveryMode(rawValue: row["delivery_mode"] as String)
        else { throw V2ClientCommandError.commandConflict }
        return try .init(operationID: .init(row["operation_id"] as String), title: row["title"], deliveryMode: deliveryMode, initialMemberUserIDs: members, uploadedMemberCount: row["uploaded_member_count"] as Int, state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), createdRoomID: try (row["created_room_id"] as String?).map(RoomID.init), terminalCode: row["terminal_code"])
    }

    private enum V2MessageSearchRebuildOutcome {
        case advanced(Int64)
        case finished
        case restartRequired
    }

    private static func readMessageSearchIndexState(db: Database) throws -> V2MessageSearchIndexState {
        guard let row = try Row.fetchOne(db, sql: "SELECT index_version, state FROM v2_message_search_state WHERE singleton = 1"),
              let version: Int = row["index_version"],
              let raw: String = row["state"],
              let state = V2MessageSearchIndexState(storageValue: raw)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return version == V2CharacterGramTokenizer.version ? state : .building
    }

    private static func messageSearchIndexGeneration(db: Database) throws -> Int64 {
        guard let generation: Int64 = try Row.fetchOne(db, sql: "SELECT generation FROM v2_message_search_state WHERE singleton = 1")?["generation"]
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return generation
    }

    @discardableResult
    private static func beginMessageSearchIndexRebuild(db: Database) throws -> Int64 {
        let generation = try messageSearchIndexGeneration(db: db)
        guard generation < Int64.max else { throw V2ClientProjectionError.invalidMessagePayload }
        let nextGeneration = generation + 1
        try db.execute(sql: "DELETE FROM v2_message_char_fts")
        try db.execute(
            sql: "UPDATE v2_message_search_state SET index_version = ?, state = 'building', generation = ? WHERE singleton = 1",
            arguments: [V2CharacterGramTokenizer.version, nextGeneration]
        )
        return nextGeneration
    }

    private static func resetMessageSearchIndex(db: Database) throws {
        _ = try beginMessageSearchIndexRebuild(db: db)
    }

    private static func finishMessageSearchIndexRebuild(generation: Int64, db: Database) throws {
        guard try messageSearchIndexGeneration(db: db) == generation else { return }
        try db.execute(sql: "UPDATE v2_message_search_state SET state = 'ready' WHERE singleton = 1")
    }

    private static func refreshMessageSearchIndex(messageID: MessageID, db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT rowid, message_id, room_id, room_sequence, sender_user_id, text_body, server_created_at, is_withdrawn FROM v2_message_projections WHERE message_id = ?",
            arguments: [messageID.rawValue]
        ) else { return }
        try writeMessageSearchIndex(row: row, db: db)
    }

    private static func writeMessageSearchIndex(row: Row, db: Database) throws {
        let rowID: Int64 = row["rowid"]
        try db.execute(sql: "DELETE FROM v2_message_char_fts WHERE rowid = ?", arguments: [rowID])
        let isWithdrawn: Bool = row["is_withdrawn"]
        let text: String = row["text_body"]
        guard !isWithdrawn, !text.isEmpty else { return }
        let tokens = V2CharacterGramTokenizer().tokenize(text)
        guard !tokens.unigrams.isEmpty else { return }
        let roomID: String = row["room_id"]
        let senderUserID: String = row["sender_user_id"]
        try db.execute(
            sql: "INSERT INTO v2_message_char_fts (rowid, room_scope, sender_scope, unigrams, bigrams) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                rowID,
                V2CharacterGramTokenizer.scopeToken(prefix: "r", identifier: roomID),
                V2CharacterGramTokenizer.scopeToken(prefix: "s", identifier: senderUserID),
                tokens.unigrams.joined(separator: " "),
                tokens.bigrams.joined(separator: " ")
            ]
        )
    }

    private static func searchMessages(_ request: V2MessageSearchRequest, query: V2CharacterGramTokenizer.Tokens, db: Database) throws -> V2MessageSearchPage {
        let match = messageSearchMatch(scope: request.scope, query: query)
        let filterFingerprint = searchFilterFingerprint(request)
        var cursor = try validatedSearchCursor(request.cursor, for: request.scope, filterFingerprint: filterFingerprint)
        var scanCursor = cursor
        var hits: [V2MessageSearchHit] = []
        let batchSize = max(128, request.limit * 2)
        while true {
            let rows = try searchCandidateRows(match: match, request: request, cursor: scanCursor, limit: batchSize, db: db)
            guard !rows.isEmpty else { return .init(hits: hits, nextCursor: nil) }
            for row in rows {
                let candidate = try searchCandidate(row)
                let candidateCursor = searchCursor(for: candidate, scope: request.scope, filterFingerprint: filterFingerprint)
                scanCursor = candidateCursor
                guard query.characterCount == 0 || V2CharacterGramTokenizer.normalize(candidate.text).range(of: query.normalized) != nil else { continue }
                if hits.count == request.limit {
                    // The query has at least one further verified result, so
                    // the cursor after the final included hit is meaningful.
                    return .init(hits: hits, nextCursor: cursor)
                }
                hits.append(candidate)
                cursor = candidateCursor
            }
            if rows.count < batchSize { return .init(hits: hits, nextCursor: nil) }
        }
    }

    private static func messageSearchMatch(scope: V2MessageSearchScope, query: V2CharacterGramTokenizer.Tokens) -> String? {
        var clauses: [String] = []
        switch scope {
        case .room(let roomID):
            clauses.append("room_scope : " + V2CharacterGramTokenizer.scopeToken(prefix: "r", identifier: roomID.rawValue))
        case .allMessages:
            break
        case .sender(let userID):
            clauses.append("sender_scope : " + V2CharacterGramTokenizer.scopeToken(prefix: "s", identifier: userID.rawValue))
        }
        if query.characterCount == 0 {
            // Room and sender constraints are applied to the projection SQL.
            // Do not join FTS here: media-only messages intentionally have no
            // text token and consequently no FTS row.
            return nil
        } else if query.characterCount == 1 {
            clauses.append("unigrams : " + query.unigrams[0])
        } else {
            clauses.append("bigrams : \"" + query.bigrams.joined(separator: " ") + "\"")
        }
        return clauses.joined(separator: " AND ")
    }

    private static func validatedSearchCursor(_ cursor: V2MessageSearchCursor?, for scope: V2MessageSearchScope, filterFingerprint: String) throws -> V2MessageSearchCursor? {
        guard let cursor else { return nil }
        guard cursor.filterFingerprint == filterFingerprint else { throw V2MessageSearchError.cursorDoesNotMatchScope }
        switch (scope, cursor.storage) {
        case (.room(let scopeRoomID), .room(let cursorRoomID, _, _)) where scopeRoomID == cursorRoomID:
            return cursor
        case (.room, _), (.allMessages, .room), (.sender, .room):
            throw V2MessageSearchError.cursorDoesNotMatchScope
        case (.allMessages, .global), (.sender, .global):
            return cursor
        }
    }

    private static func searchCandidateRows(match: String?, request: V2MessageSearchRequest, cursor: V2MessageSearchCursor?, limit: Int, db: Database) throws -> [Row] {
        var clauses = ["p.is_withdrawn = 0"]
        var arguments: [DatabaseValueConvertible] = []
        let from: String
        if let match {
            from = "v2_message_char_fts JOIN v2_message_projections p ON p.rowid = v2_message_char_fts.rowid"
            clauses.append("v2_message_char_fts MATCH ?")
            arguments.append(match)
        } else {
            from = "v2_message_projections p"
        }
        switch request.scope {
        case .room(let roomID): clauses.append("p.room_id = ?"); arguments.append(roomID.rawValue)
        case .allMessages: break
        case .sender(let userID): clauses.append("p.sender_user_id = ?"); arguments.append(userID.rawValue)
        }
        if let senderUserID = request.senderUserID {
            clauses.append("p.sender_user_id = ?")
            arguments.append(senderUserID.rawValue)
        }
        switch request.contentFilter {
        case .all: break
        case .media: clauses.append("json_array_length(p.media_ids) > 0")
        case .image, .video, .file, .audio:
            clauses.append("EXISTS (SELECT 1 FROM json_each(p.media_presentations) WHERE json_extract(json_each.value, '$.kind') = ?)")
            arguments.append(request.contentFilter.rawValue)
        }
        let base = "SELECT p.message_id, p.room_id, p.room_sequence, p.sender_user_id, p.text_body, p.server_created_at FROM \(from) WHERE \(clauses.joined(separator: " AND "))"
        switch (request.scope, cursor?.storage) {
        case (.room, nil):
            arguments.append(limit)
            return try Row.fetchAll(db, sql: base + " ORDER BY p.room_sequence DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.room, .room(_, let sequence, let messageID)):
            arguments += [try storageInteger(sequence), try storageInteger(sequence), messageID.rawValue, limit]
            return try Row.fetchAll(db, sql: base + " AND (p.room_sequence < ? OR (p.room_sequence = ? AND p.message_id < ?)) ORDER BY p.room_sequence DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.allMessages, nil), (.sender, nil):
            arguments.append(limit)
            return try Row.fetchAll(db, sql: base + " ORDER BY p.server_created_at DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.allMessages, .global(let createdAt, let messageID)), (.sender, .global(let createdAt, let messageID)):
            arguments += [createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, messageID.rawValue, limit]
            return try Row.fetchAll(db, sql: base + " AND (p.server_created_at < ? OR (p.server_created_at = ? AND p.message_id < ?)) ORDER BY p.server_created_at DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        default:
            throw V2MessageSearchError.cursorDoesNotMatchScope
        }
    }

    private static func searchCandidate(_ row: Row) throws -> V2MessageSearchHit {
        try .init(messageID: .init(row["message_id"] as String), roomID: .init(row["room_id"] as String), roomSequence: UInt64(row["room_sequence"] as Int64), senderUserID: .init(row["sender_user_id"] as String), text: row["text_body"], createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double))
    }

    private static func searchCursor(for hit: V2MessageSearchHit, scope: V2MessageSearchScope, filterFingerprint: String) -> V2MessageSearchCursor {
        switch scope {
        case .room:
            .init(storage: .room(roomID: hit.roomID, roomSequence: hit.roomSequence, messageID: hit.messageID), filterFingerprint: filterFingerprint)
        case .allMessages, .sender:
            .init(storage: .global(createdAt: hit.createdAt, messageID: hit.messageID), filterFingerprint: filterFingerprint)
        }
    }

    private static func searchFilterFingerprint(_ request: V2MessageSearchRequest) -> String {
        let scope: String = switch request.scope {
        case .room(let roomID): "room:\(roomID.rawValue)"
        case .allMessages: "all"
        case .sender(let userID): "sender:\(userID.rawValue)"
        }
        return "\(scope)|\(request.contentFilter.rawValue)|\(request.senderUserID?.rawValue ?? "")"
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
                    created_at REAL NOT NULL
                );
            """)
        }
        migrator.registerMigration("addV2RoomProfileMembershipRevision") { db in
            try db.execute(sql: "ALTER TABLE v2_room_profile_projections ADD COLUMN membership_revision INTEGER NOT NULL DEFAULT 1 CHECK (membership_revision > 0)")
        }
        migrator.registerMigration("addV2RoomProfileDeliveryMode") { db in
            try db.execute(sql: "ALTER TABLE v2_room_profile_projections ADD COLUMN delivery_mode TEXT CHECK (delivery_mode IS NULL OR delivery_mode IN ('standard_fanout', 'large_group_hybrid'))")
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
        return migrator
    }()

    private static let terminalCommandTables = [
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
