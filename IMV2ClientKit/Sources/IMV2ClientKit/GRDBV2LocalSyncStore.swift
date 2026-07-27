import Foundation
import GRDB
import IMV2Core

/// V2's local database is intentionally separate from the V1 conversation
/// cache. It applies sync records incrementally in one SQLite transaction.
public actor GRDBV2LocalSyncStore: V2LocalSyncStore, V2LocalCommandStore, V2LocalMembershipCommandStore, V2LocalMessageWithdrawalStore, V2LocalMessageRedactionStore, V2LocalMemberMuteStore, V2LocalModeratedMemberRemovalStore, V2LocalMessageReactionStore, V2LocalMessageEditStore, V2LocalReadReceiptStore, V2LocalSocialCommandStore, V2LocalGroupRoomCommandStore {
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
                } else if record.projectionKind == "room" || record.projectionKind == "membership" {
                    try Self.persist(V2ClientRoomProfileProjection(record: record), db: db)
                } else if record.projectionKind == "direct_room_profile" {
                    try Self.persist(V2ClientDirectRoomProfileProjection(record: record), db: db)
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
            let snapshotModerationActions = snapshotPages.flatMap(\.moderationActions)
            let snapshotRoomControls = snapshotPages.flatMap(\.roomControls)
            let snapshotRoomProfiles = snapshotPages.flatMap(\.roomProfiles)
            let snapshotDirectRoomProfiles = snapshotPages.flatMap(\.directRoomProfiles)
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
                  snapshotPreferences.count <= 1
            else { throw V2ClientSocialProjectionError.invalidPayload }
            try db.execute(sql: "DELETE FROM v2_sync_events")
            try db.execute(sql: "DELETE FROM v2_message_projections")
            try db.execute(sql: "DELETE FROM v2_message_tombstones")
            try db.execute(sql: "DELETE FROM v2_message_reactions")
            try db.execute(sql: "DELETE FROM v2_moderation_projections")
            try db.execute(sql: "DELETE FROM v2_room_control_projections")
            try db.execute(sql: "DELETE FROM v2_room_profile_projections")
            try db.execute(sql: "DELETE FROM v2_direct_room_profile_projections")
            try db.execute(sql: "DELETE FROM v2_relationship_projections")
            try db.execute(sql: "DELETE FROM v2_user_block_projections")
            try db.execute(sql: "DELETE FROM v2_stranger_message_preference")
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
            for userBlock in snapshotUserBlocks { try Self.persist(userBlock, db: db) }
            if let preference = snapshotPreferences.first { try Self.persist(preference, db: db) }
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
            try Row.fetchAll(db, sql: "SELECT * FROM v2_message_projections WHERE room_id = ? ORDER BY room_sequence, message_id", arguments: [roomID.rawValue]).map(Self.decodeMessageProjection)
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
            guard let row = try Row.fetchOne(db, sql: "SELECT source_event_id, room_id, title, owner_user_id, membership_revision, created_at FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try Self.decodeRoomProfileProjection(row)
        }
    }

    public func roomProfiles() throws -> [V2ClientRoomProfileProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_event_id, room_id, title, owner_user_id, membership_revision, created_at FROM v2_room_profile_projections ORDER BY created_at DESC, room_id").map(Self.decodeRoomProfileProjection)
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
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, text, media_ids, mention_targets FROM v2_pending_message_commands WHERE client_message_id = ?", arguments: [command.clientMessageID.rawValue]) {
                let roomID: String = existing["room_id"]
                let text: String = existing["text"]
                let existingMedia: String = existing["media_ids"]
                let existingMentions: String = existing["mention_targets"]
                guard roomID == command.roomID.rawValue, text == command.text, existingMedia == mediaIDs, existingMentions == mentionTargets else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_commands
                    (client_message_id, room_id, text, media_ids, mention_targets, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [command.clientMessageID.rawValue, command.roomID.rawValue, command.text, mediaIDs, mentionTargets, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970]
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

    public func enqueue(_ command: V2PendingSocialCommand) throws {
        try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT command_kind, target_user_id, relationship_action, block_action, stranger_permission FROM v2_pending_social_commands WHERE operation_id = ?", arguments: [command.operationID]) {
                let kind: String = row["command_kind"]
                let target: String? = row["target_user_id"]
                let relationship: String? = row["relationship_action"]
                let block: String? = row["block_action"]
                let permission: String? = row["stranger_permission"]
                guard kind == command.kind.rawValue, target == command.targetUserID?.rawValue, relationship == command.relationshipAction?.rawValue, block == command.blockAction?.rawValue, permission == command.strangerPermission?.rawValue else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_social_commands (operation_id, command_kind, target_user_id, relationship_action, block_action, stranger_permission, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID, command.kind.rawValue, command.targetUserID?.rawValue, command.relationshipAction?.rawValue, command.blockAction?.rawValue, command.strangerPermission?.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
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
                ]
            ) {
                return try Self.decodePendingSocialCommand(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_social_commands
                (operation_id, command_kind, target_user_id, relationship_action,
                 block_action, stranger_permission, state, attempt_count,
                 next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID,
                    command.kind.rawValue,
                    command.targetUserID?.rawValue,
                    command.relationshipAction?.rawValue,
                    command.blockAction?.rawValue,
                    command.strangerPermission?.rawValue,
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
            if let existing = try Row.fetchOne(db, sql: "SELECT title, initial_member_user_ids FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let title: String = existing["title"]
                let existingMembers: String = existing["initial_member_user_ids"]
                guard title == command.title, existingMembers == members else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_group_room_creations (operation_id, title, initial_member_user_ids, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.title, members, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
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
                      decoded.initialMemberUserIDs == command.initialMemberUserIDs,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_group_room_creations
                WHERE title = ? AND initial_member_user_ids = ? AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [command.title, members]
            ) {
                return try Self.decodePendingGroupRoomCreation(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_group_room_creations
                (operation_id, title, initial_member_user_ids, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.title,
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
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_room_creations WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingGroupRoomCreation(row)
        }
    }

    public func markGroupRoomCreationAcknowledged(operationID: GroupRoomOperationID, roomID: RoomID) throws {
        try databasePool.write { db in
            try Self.requirePendingGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'acknowledged', created_room_id = ?, terminal_code = NULL WHERE operation_id = ?", arguments: [roomID.rawValue, operationID.rawValue])
        }
    }

    public func scheduleGroupRoomCreationRetry(operationID: GroupRoomOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectGroupRoomCreation(operationID: GroupRoomOperationID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue])
        }
    }

    public func pendingGroupRoomCreations() throws -> [V2PendingGroupRoomCreation] {
        try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_group_room_creations ORDER BY created_at, operation_id").map(Self.decodePendingGroupRoomCreation) }
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

    private static func persist(_ projection: V2ClientMessageProjection, db: Database) throws {
        if let existing = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let decoded = try decodeMessageProjection(existing)
            guard decoded.sourceEventID == projection.sourceEventID, decoded.messageID == projection.messageID,
                  decoded.roomID == projection.roomID, decoded.roomSequence == projection.roomSequence,
                  decoded.messageRevision == projection.messageRevision, decoded.senderUserID == projection.senderUserID,
                  decoded.text == projection.text, decoded.media == projection.media, decoded.mentions == projection.mentions, decoded.createdAt == projection.createdAt,
                  decoded.isWithdrawn == projection.isWithdrawn
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(
            sql: """
            INSERT INTO v2_message_projections
                (message_id, source_event_id, room_id, room_sequence, message_revision, sender_user_id, text_body, media_ids, mention_targets, server_created_at, is_withdrawn)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [projection.messageID.rawValue, projection.sourceEventID.rawValue, projection.roomID.rawValue,
                        try storageInteger(projection.roomSequence), try storageInteger(projection.messageRevision), projection.senderUserID.rawValue, projection.text, try encodeMedia(projection.media), try encodeMentions(projection.mentions),
                        projection.createdAt.timeIntervalSince1970, projection.isWithdrawn]
        )
        if let tombstone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let roomID: String = tombstone["room_id"]
            let revision: Int64 = tombstone["message_revision"]
            guard roomID == projection.roomID.rawValue, revision > (try storageInteger(projection.messageRevision)) else { throw V2ClientProjectionError.invalidMessagePayload }
            try db.execute(sql: "UPDATE v2_message_projections SET message_revision = ?, is_withdrawn = 1 WHERE message_id = ?", arguments: [revision, projection.messageID.rawValue])
        }
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
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, title, owner_user_id, membership_revision, created_at FROM v2_room_profile_projections WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
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
            try db.execute(sql: "UPDATE v2_room_profile_projections SET source_event_id = ?, membership_revision = ? WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, incomingRevision, projection.roomID.rawValue])
            return
        }
        try db.execute(sql: "INSERT INTO v2_room_profile_projections (room_id, source_event_id, title, owner_user_id, membership_revision, created_at) VALUES (?, ?, ?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.title, projection.ownerUserID.rawValue, try storageInteger(projection.membershipRevision), projection.createdAt.timeIntervalSince1970])
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
                return
            }
            try db.execute(sql: "UPDATE v2_direct_room_profile_projections SET source_event_id = ?, target_user_id = ?, public_handle = ?, display_name = ?, revision = ?, updated_at = ? WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, incomingRevision, projection.updatedAt.timeIntervalSince1970, projection.roomID.rawValue])
            return
        }
        try db.execute(sql: "INSERT INTO v2_direct_room_profile_projections (room_id, source_event_id, target_user_id, public_handle, display_name, revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, try storageInteger(projection.revision), projection.updatedAt.timeIntervalSince1970])
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
        try db.execute(sql: "UPDATE v2_message_projections SET text_body = ?, message_revision = ? WHERE message_id = ?", arguments: [edit.text, try storageInteger(edit.messageRevision), edit.messageID.rawValue])
    }

    private static func persist(_ reaction: V2ClientMessageReaction, action: V2MessageReactionAction, db: Database) throws {
        if action == .add {
            try db.execute(sql: "INSERT INTO v2_message_reactions (message_id, room_id, actor_user_id, reaction) VALUES (?, ?, ?, ?) ON CONFLICT(message_id, actor_user_id, reaction) DO NOTHING", arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction])
        } else {
            try db.execute(sql: "DELETE FROM v2_message_reactions WHERE message_id = ? AND room_id = ? AND actor_user_id = ? AND reaction = ?", arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction])
        }
    }

    private static func decodeMessageProjection(_ row: Row) throws -> V2ClientMessageProjection {
        try .init(
            sourceEventID: .init(row["source_event_id"] as String),
            messageID: .init(row["message_id"] as String),
            roomID: .init(row["room_id"] as String),
            roomSequence: UInt64(row["room_sequence"] as Int64),
            messageRevision: UInt64(row["message_revision"] as Int64),
            senderUserID: .init(row["sender_user_id"] as String),
            text: row["text_body"],
            media: try decodeMedia(row["media_ids"]),
            mentions: try decodeMentions(row["mention_targets"]),
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
    private static func requirePendingMessageEdit(_ operationID: MessageEditOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_message_edits WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingMessageEdit.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingReadReceipt(_ operationID: ReadReceiptOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_read_receipts WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingReadReceipt.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingSocialCommand(_ operationID: String, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_social_commands WHERE operation_id = ?", arguments: [operationID])?["state"], state == V2PendingSocialCommand.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }
    private static func requirePendingGroupRoomCreation(_ operationID: GroupRoomOperationID, db: Database) throws { guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == V2PendingGroupRoomCreation.State.pending.rawValue else { throw V2ClientCommandError.commandNotPending } }

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
        return .init(snapshotProjection: snapshot)
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
    private static func decodePendingMessageEdit(_ row: Row) throws -> V2PendingMessageEdit {
        guard let state = V2PendingMessageEdit.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), messageID: .init(row["message_id"] as String), expectedMessageRevision: UInt64(row["expected_message_revision"] as Int64), text: row["text_body"], state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingMessageRevision: (row["resulting_message_revision"] as Int64?).map(UInt64.init), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"], terminalCurrentRevision: (row["terminal_current_revision"] as Int64?).map(UInt64.init))
    }
    private static func decodePendingReadReceipt(_ row: Row) throws -> V2PendingReadReceipt { guard let state = V2PendingReadReceipt.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }; return try .init(roomID: .init(row["room_id"] as String), operationID: .init(row["operation_id"] as String), readThroughRoomSequence: UInt64(row["read_through_room_sequence"] as Int64), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), resultingRoomSequence: (row["resulting_room_sequence"] as Int64?).map(UInt64.init), terminalCode: row["terminal_code"]) }
    private static func decodePendingSocialCommand(_ row: Row) throws -> V2PendingSocialCommand {
        guard let kind = V2PendingSocialCommandKind(rawValue: row["command_kind"] as String), let state = V2PendingSocialCommand.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(operationID: row["operation_id"], kind: kind, targetUserID: try (row["target_user_id"] as String?).map(UserID.init), relationshipAction: (row["relationship_action"] as String?).flatMap(V2RelationshipAction.init), blockAction: (row["block_action"] as String?).flatMap(V2UserBlockAction.init), strangerPermission: (row["stranger_permission"] as String?).flatMap(V2StrangerMessagePermission.init), state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), terminalCode: row["terminal_code"])
    }
    private static func encodeGroupMemberUserIDs(_ members: [UserID]) throws -> String {
        guard let encoded = String(data: try JSONEncoder().encode(members.map(\.rawValue)), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }
    private static func decodePendingGroupRoomCreation(_ row: Row) throws -> V2PendingGroupRoomCreation {
        let membersData = Data((row["initial_member_user_ids"] as String).utf8)
        let members = try JSONDecoder().decode([String].self, from: membersData).map(UserID.init)
        guard let state = V2PendingGroupRoomCreation.State(rawValue: row["state"] as String) else { throw V2ClientCommandError.commandConflict }
        return try .init(operationID: .init(row["operation_id"] as String), title: row["title"], initialMemberUserIDs: members, state: state, attemptCount: Int(row["attempt_count"] as Int64), nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"] as Double), createdRoomID: try (row["created_room_id"] as String?).map(RoomID.init), terminalCode: row["terminal_code"])
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
                    operation_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    initial_member_user_ids TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                    attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                    next_attempt_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    created_room_id TEXT,
                    terminal_code TEXT,
                    CHECK ((state = 'pending' AND created_room_id IS NULL AND terminal_code IS NULL)
                        OR (state = 'acknowledged' AND created_room_id IS NOT NULL AND terminal_code IS NULL)
                        OR (state = 'rejected' AND created_room_id IS NULL AND terminal_code IS NOT NULL))
                );
                CREATE INDEX v2_pending_group_room_creations_ready_idx
                    ON v2_pending_group_room_creations (state, next_attempt_at, created_at)
                    WHERE state = 'pending';
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
        return migrator
    }()
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
