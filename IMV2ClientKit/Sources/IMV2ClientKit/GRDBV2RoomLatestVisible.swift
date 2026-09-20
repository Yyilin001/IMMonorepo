import Foundation
import GRDB
import IMV2Core

public struct V2RoomLatestVisibleRequest: Sendable {
    let scope: V2RoomRecoveryScope
    let personalGeneration: UInt64
}

extension GRDBV2LocalSyncStore {
    // Date reference seconds avoid losing precision through epoch conversion on repeated commits.
    static let roomLatestVisibleSchemaSQL = """
        CREATE TABLE v2_room_latest_visible (
            room_id TEXT PRIMARY KEY,
            personal_generation INTEGER NOT NULL CHECK (personal_generation >= 0),
            owner_epoch INTEGER NOT NULL CHECK (owner_epoch >= 0),
            membership_revision INTEGER NOT NULL CHECK (membership_revision > 0),
            head INTEGER NOT NULL CHECK (head >= 0),
            message_id TEXT, sender_id TEXT, message_sequence INTEGER, message_revision INTEGER,
            preview TEXT, media_count INTEGER, created_at_reference REAL,
            CHECK ((message_id IS NULL AND sender_id IS NULL AND message_sequence IS NULL
                AND message_revision IS NULL AND preview IS NULL AND media_count IS NULL AND created_at_reference IS NULL)
                OR (message_id IS NOT NULL AND sender_id IS NOT NULL AND message_sequence IS NOT NULL
                AND message_sequence BETWEEN 1 AND head AND message_revision IS NOT NULL AND message_revision > 0
                AND preview IS NOT NULL AND length(CAST(preview AS BLOB)) <= 512
                AND media_count IS NOT NULL AND media_count >= 0 AND created_at_reference IS NOT NULL))
        );
        """

    static let roomLatestVisibleTriggersSQL = """
        CREATE TRIGGER v2_latest_visible_state_insert_invalidate
        AFTER INSERT ON v2_room_sync_states
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id
                AND (head < NEW.head OR owner_epoch <> NEW.owner_epoch OR membership_revision <> NEW.membership_revision);
        END;
        CREATE TRIGGER v2_latest_visible_reset_delete
        AFTER DELETE ON v2_sync_cursor
        BEGIN DELETE FROM v2_room_latest_visible; END;
        CREATE TRIGGER v2_latest_visible_state_invalidate
        AFTER UPDATE ON v2_room_sync_states
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id
                AND (head < NEW.head OR owner_epoch <> NEW.owner_epoch OR membership_revision <> NEW.membership_revision);
        END;
        CREATE TRIGGER v2_latest_visible_member_invalidate
        AFTER INSERT ON v2_room_membership_states
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id
                AND (membership_revision < NEW.membership_revision OR (membership_revision = NEW.membership_revision AND NEW.is_member = 0));
        END;
        CREATE TRIGGER v2_latest_visible_member_update_invalidate
        AFTER UPDATE ON v2_room_membership_states
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id
                AND (membership_revision < NEW.membership_revision OR (membership_revision = NEW.membership_revision AND NEW.is_member = 0));
        END;
        CREATE TRIGGER v2_latest_visible_cursor_invalidate
        AFTER UPDATE ON v2_group_event_cursors
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id AND head < NEW.applied_room_sequence;
        END;
        CREATE TRIGGER v2_latest_visible_cursor_insert_invalidate
        AFTER INSERT ON v2_group_event_cursors
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id AND head < NEW.applied_room_sequence;
        END;
        CREATE TRIGGER v2_latest_visible_message_invalidate
        AFTER INSERT ON v2_message_projections
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id
                AND (head < NEW.room_sequence OR (message_id = NEW.message_id AND (message_revision < NEW.message_revision OR NEW.is_withdrawn = 1)));
        END;
        CREATE TRIGGER v2_latest_visible_message_update_invalidate
        AFTER UPDATE ON v2_message_projections
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = NEW.room_id
                AND (head < NEW.room_sequence OR (message_id = NEW.message_id AND (message_revision < NEW.message_revision OR NEW.is_withdrawn = 1)));
        END;
        CREATE TRIGGER v2_latest_visible_tombstone_invalidate
        AFTER INSERT ON v2_message_tombstones
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE message_id = NEW.message_id;
        END;
        CREATE TRIGGER v2_latest_visible_reset_invalidate
        AFTER UPDATE ON v2_sync_cursor
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE personal_generation <> NEW.generation OR NEW.state <> 'ready';
        END;
        CREATE TRIGGER v2_latest_visible_requeue
        AFTER DELETE ON v2_room_latest_visible
        WHEN EXISTS(SELECT 1 FROM v2_sync_cursor WHERE singleton = 1 AND state = 'ready' AND generation = OLD.personal_generation)
          AND EXISTS(SELECT 1 FROM v2_room_recovery_scan AS scan JOIN v2_local_installation AS account
              ON account.singleton = scan.singleton AND account.binding = scan.installation_binding AND account.user_id = scan.user_id)
          AND EXISTS(SELECT 1 FROM v2_room_sync_states WHERE room_id = OLD.room_id)
          AND NOT EXISTS(SELECT 1 FROM v2_room_membership_states WHERE room_id = OLD.room_id AND is_member = 0)
        BEGIN
            INSERT INTO v2_room_recovery_work
                (room_id, target_head, request_revision, requires_state, requires_summary, priority, enqueued_at, next_attempt_at)
            VALUES (OLD.room_id, OLD.head,
                upper(hex(randomblob(4))) || '-' || upper(hex(randomblob(2))) || '-' || upper(hex(randomblob(2))) || '-' || upper(hex(randomblob(2))) || '-' || upper(hex(randomblob(6))),
                1, 1, 1, unixepoch('now'), 0)
            ON CONFLICT(room_id) DO UPDATE SET requires_summary = 1, requires_state = 1,
                request_revision = excluded.request_revision, target_head = MAX(target_head, excluded.target_head),
                next_attempt_at = MIN(next_attempt_at, excluded.next_attempt_at);
        END;
        CREATE TRIGGER v2_latest_visible_state_delete
        AFTER DELETE ON v2_room_sync_states
        BEGIN
            DELETE FROM v2_room_latest_visible WHERE room_id = OLD.room_id;
        END;
        """

    /// Cached observations override local windows, including an explicitly empty observation.
    static func effectiveListActivitySQL(room: String) -> String {
        let fallback = """
            (SELECT created_at FROM v2_room_profile_projections WHERE room_id = \(room)),
            (SELECT room_created_at FROM v2_direct_room_profile_projections WHERE room_id = \(room)),
            (SELECT room_created_at FROM v2_direct_room_identities WHERE room_id = \(room)), 0
            """
        return """
            CASE WHEN EXISTS(SELECT 1 FROM v2_room_latest_visible WHERE room_id = \(room))
            THEN COALESCE((SELECT created_at_reference + 978307200.0 FROM v2_room_latest_visible WHERE room_id = \(room)), \(fallback))
            ELSE COALESCE((SELECT message.server_created_at FROM v2_conversation_summaries AS summary
                JOIN v2_message_projections AS message ON message.message_id = summary.message_id
                WHERE summary.room_id = \(room)), \(fallback)) END
            """
    }

    static var roomLatestVisibleListTriggersSQL: String {
        let newActivity = effectiveListActivitySQL(room: "NEW.room_id")
        let oldActivity = effectiveListActivitySQL(room: "OLD.room_id")
        let upsert = """
            INSERT INTO v2_conversation_list_entries(room_id, last_activity, is_pinned, is_archived, mute_until)
            VALUES (NEW.room_id, \(newActivity),
                COALESCE((SELECT is_pinned FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                COALESCE((SELECT is_archived FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                COALESCE((SELECT mute_until FROM v2_conversation_states WHERE room_id = NEW.room_id), 0))
            ON CONFLICT(room_id) DO UPDATE SET last_activity = excluded.last_activity;
            """
        return """
            CREATE TRIGGER v2_latest_visible_list_insert AFTER INSERT ON v2_room_latest_visible
            BEGIN \(upsert) END;
            CREATE TRIGGER v2_latest_visible_list_update AFTER UPDATE ON v2_room_latest_visible
            BEGIN \(upsert) END;
            CREATE TRIGGER v2_latest_visible_list_delete AFTER DELETE ON v2_room_latest_visible
            BEGIN
                UPDATE v2_conversation_list_entries SET last_activity = \(oldActivity) WHERE room_id = OLD.room_id;
                DELETE FROM v2_conversation_list_entries WHERE room_id = OLD.room_id
                  AND NOT EXISTS(SELECT 1 FROM v2_conversation_summaries WHERE room_id = OLD.room_id)
                  AND NOT EXISTS(SELECT 1 FROM v2_room_profile_projections WHERE room_id = OLD.room_id)
                  AND NOT EXISTS(SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = OLD.room_id)
                  AND NOT EXISTS(SELECT 1 FROM v2_direct_room_identities WHERE room_id = OLD.room_id);
            END;
            CREATE TRIGGER v2_latest_visible_list_preserve_insert AFTER INSERT ON v2_conversation_list_entries
            WHEN EXISTS(SELECT 1 FROM v2_room_latest_visible WHERE room_id = NEW.room_id)
                AND NEW.last_activity <> (\(newActivity))
            BEGIN UPDATE v2_conversation_list_entries SET last_activity = \(newActivity) WHERE room_id = NEW.room_id; END;
            CREATE TRIGGER v2_latest_visible_list_preserve_update AFTER UPDATE OF last_activity ON v2_conversation_list_entries
            WHEN EXISTS(SELECT 1 FROM v2_room_latest_visible WHERE room_id = NEW.room_id)
                AND NEW.last_activity <> (\(newActivity))
            BEGIN UPDATE v2_conversation_list_entries SET last_activity = \(newActivity) WHERE room_id = NEW.room_id; END;
            """
    }

    public func beginRoomLatestVisibleRequest(scope: V2RoomRecoveryScope) async throws -> V2RoomLatestVisibleRequest {
        try await databasePool.read { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            guard let cursor = try Self.readCursor(db), cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            return .init(scope: scope, personalGeneration: cursor.generation)
        }
    }

    /// Display-only commit. It neither acknowledges content nor completes recovery work.
    public func commitRoomLatestVisible(_ snapshot: V2RoomLatestVisible, request: V2RoomLatestVisibleRequest, work: V2RoomRecoveryWork? = nil) async throws -> Bool {
        try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryScope(request.scope, db: db)
            if let work {
                guard work.scope == request.scope, work.roomID == snapshot.roomID else { throw V2RoomRecoveryPersistenceError.invalidWork }
                _ = try Self.requireRoomRecoveryWorkScope(work, db: db)
                try Self.validateStoredRecoveryWork(roomID: work.roomID, db: db)
            }
            try Self.requireProjectionWritesUnfenced(db: db)
            guard let cursor = try Self.readCursor(db), cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            guard cursor.generation == request.personalGeneration else { return false }
            guard try Self.latestVisibleIsCurrent(snapshot, db: db) else { return false }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_latest_visible WHERE room_id = ?", arguments: [snapshot.roomID.rawValue]),
               (try Self.recoveryInteger(row, "personal_generation")) == Int64(cursor.generation) {
                let existing = try Self.decodeLatestVisible(row)
                guard snapshot.ownerEpoch >= existing.ownerEpoch, snapshot.membershipRevision >= existing.membershipRevision,
                      snapshot.head >= existing.head else { return false }
                if snapshot.head == existing.head && snapshot.ownerEpoch == existing.ownerEpoch
                    && snapshot.membershipRevision == existing.membershipRevision {
                    // Equal observation identity must describe the same visible state.
                    guard snapshot == existing else { return false }
                }
            }
            let message = snapshot.latest
            try db.execute(sql: """
                INSERT INTO v2_room_latest_visible
                    (room_id, personal_generation, owner_epoch, membership_revision, head,
                     message_id, sender_id, message_sequence, message_revision, preview, media_count, created_at_reference)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_id) DO UPDATE SET
                    personal_generation = excluded.personal_generation, owner_epoch = excluded.owner_epoch,
                    membership_revision = excluded.membership_revision, head = excluded.head,
                    message_id = excluded.message_id, sender_id = excluded.sender_id,
                    message_sequence = excluded.message_sequence, message_revision = excluded.message_revision,
                    preview = excluded.preview, media_count = excluded.media_count, created_at_reference = excluded.created_at_reference
                """, arguments: [snapshot.roomID.rawValue, Int64(cursor.generation), Int64(snapshot.ownerEpoch),
                    Int64(snapshot.membershipRevision), Int64(snapshot.head), message?.id.rawValue, message?.senderID.rawValue,
                    message.map { Int64($0.sequence) }, message.map { Int64($0.revision) }, message?.preview,
                    message?.mediaCount, message?.createdAt.timeIntervalSinceReferenceDate])
            if let work, snapshot.head >= work.targetHead {
                try db.execute(sql: """
                    UPDATE v2_room_recovery_work SET requires_summary = 0, target_head = MAX(target_head, ?),
                        requires_state = CASE WHEN COALESCE((SELECT head FROM v2_room_sync_states WHERE room_id = ?), 0) < ?
                            THEN 1 ELSE requires_state END
                    WHERE room_id = ? AND request_revision = ?
                    """, arguments: [Int64(snapshot.head), work.roomID.rawValue, Int64(snapshot.head),
                        work.roomID.rawValue, work.requestRevision.uuidString])
            }
            return true
        }
    }

    public func roomLatestVisible(roomID: RoomID, scope: V2RoomRecoveryScope) async throws -> V2RoomLatestVisible? {
        try await databasePool.read { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            guard let cursor = try Self.readCursor(db), cursor.state == .ready,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_latest_visible WHERE room_id = ? AND personal_generation = ?",
                    arguments: [roomID.rawValue, Int64(cursor.generation)]) else { return nil }
            let snapshot = try Self.decodeLatestVisible(row)
            return try Self.latestVisibleIsCurrent(snapshot, db: db) ? snapshot : nil
        }
    }

    static func latestVisibleIsCurrent(_ snapshot: V2RoomLatestVisible, db: GRDB.Database) throws -> Bool {
        let id = snapshot.roomID.rawValue
        if let member = try Row.fetchOne(db, sql: "SELECT membership_revision, is_member FROM v2_room_membership_states WHERE room_id = ?", arguments: [id]) {
            let revision = try recoveryInteger(member, "membership_revision")
            if revision > Int64(snapshot.membershipRevision) || (revision == Int64(snapshot.membershipRevision) && !(member["is_member"] as Bool)) { return false }
        }
        if let state = try Row.fetchOne(db, sql: "SELECT owner_epoch, membership_revision, head FROM v2_room_sync_states WHERE room_id = ?", arguments: [id]) {
            guard (try recoveryInteger(state, "owner_epoch")) == Int64(snapshot.ownerEpoch),
                  (try recoveryInteger(state, "membership_revision")) == Int64(snapshot.membershipRevision),
                  (try recoveryInteger(state, "head")) <= Int64(snapshot.head) else { return false }
        }
        let appliedRow = try Row.fetchOne(db, sql: "SELECT applied_room_sequence AS value FROM v2_group_event_cursors WHERE room_id = ?", arguments: [id])
        let applied = try appliedRow.map { try recoveryInteger($0, "value") } ?? 0
        // Probe the sparse invalid-sequence index before MAX can hide bad rows.
        // Selecting message_id avoids preferring the room/sequence covering index.
        let newestRow = try Row.fetchOne(db, sql: """
            SELECT CASE WHEN EXISTS (
                SELECT message_id FROM v2_message_projections WHERE room_id = ?
                  AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
            ) THEN -1 ELSE (
                SELECT COALESCE(MAX(room_sequence), 0) FROM v2_message_projections WHERE room_id = ?
            ) END AS value
            """, arguments: [id, id])
        let newest = try newestRow.map { row -> Int64 in
            let value: DatabaseValue = row["value"]
            return value.isNull ? 0 : try recoveryInteger(row, "value")
        } ?? 0
        guard max(applied, newest) <= Int64(snapshot.head) else { return false }
        if let message = snapshot.latest {
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_message_tombstones WHERE message_id = ?)", arguments: [message.id.rawValue]) == true { return false }
            if let local = try Row.fetchOne(db, sql: "SELECT room_id, message_revision, is_withdrawn FROM v2_message_projections WHERE message_id = ?", arguments: [message.id.rawValue]) {
                guard (local["room_id"] as String) == id, !(local["is_withdrawn"] as Bool),
                      (try recoveryInteger(local, "message_revision")) <= Int64(message.revision) else { return false }
            }
        }
        return true
    }

    static func decodeLatestVisible(_ row: Row) throws -> V2RoomLatestVisible {
        let message: V2RoomLatestVisible.Message?
        if let id: String = row["message_id"] {
            message = try .init(id: .init(id), senderID: .init(row["sender_id"] as String),
                sequence: UInt64(try recoveryInteger(row, "message_sequence")), revision: UInt64(try recoveryInteger(row, "message_revision")),
                preview: row["preview"], mediaCount: Int(try recoveryInteger(row, "media_count")), createdAt: .init(timeIntervalSinceReferenceDate: row["created_at_reference"]))
        } else { message = nil }
        return try .init(roomID: .init(row["room_id"] as String), ownerEpoch: UInt64(try recoveryInteger(row, "owner_epoch")),
            membershipRevision: UInt64(try recoveryInteger(row, "membership_revision")), head: UInt64(try recoveryInteger(row, "head")), latest: message)
    }
}
