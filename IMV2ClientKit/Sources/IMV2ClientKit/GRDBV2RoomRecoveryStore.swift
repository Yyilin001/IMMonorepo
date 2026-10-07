import Foundation
import GRDB
import IMV2Core

public enum V2RoomRecoveryPersistenceError: Error, Equatable, Sendable {
    case staleScope, stalePage, topologyChanged, invalidWork, staleMembership
}

public struct V2RoomRecoveryScope: Equatable, Sendable {
    public let scanID: UUID
    public let userID: UserID
    let installationBinding: String
}

public struct V2RoomRecoveryScan: Equatable, Sendable {
    let directoryRound: String
    let personalGeneration: UInt64?
    public let scope: V2RoomRecoveryScope
    public let cursor: String?
    public let topologyGeneration: String?
    public let directoryComplete: Bool
}

extension GRDBV2LocalSyncStore {
    static let roomRecoverySchemaSQL = """
        CREATE TABLE v2_room_sync_states (
            room_id TEXT PRIMARY KEY,
            owner_epoch INTEGER NOT NULL CHECK (owner_epoch >= 0),
            membership_revision INTEGER NOT NULL CHECK (membership_revision >= 0),
            head INTEGER NOT NULL CHECK (head >= 0),
            trimmed_through INTEGER NOT NULL CHECK (trimmed_through BETWEEN 0 AND head),
            read_through INTEGER NOT NULL CHECK (read_through BETWEEN 0 AND head),
            latest_own_sequence INTEGER NOT NULL CHECK (latest_own_sequence BETWEEN 0 AND head),
            checked_at REAL NOT NULL
        );
        CREATE TABLE v2_room_recovery_work (
            room_id TEXT PRIMARY KEY,
            target_head INTEGER NOT NULL CHECK (target_head >= 0),
            request_revision TEXT NOT NULL,
            requires_state INTEGER NOT NULL CHECK (requires_state IN (0, 1)),
            requires_summary INTEGER NOT NULL DEFAULT 0 CHECK (requires_summary IN (0, 1)),
            priority INTEGER NOT NULL CHECK (priority BETWEEN 0 AND 2),
            enqueued_at REAL NOT NULL, next_attempt_at REAL NOT NULL,
            last_served_order INTEGER NOT NULL DEFAULT 0 CHECK (last_served_order >= 0),
            directory_membership_revision INTEGER NULL CHECK (directory_membership_revision >= 0),
            directory_owner_epoch INTEGER NULL CHECK (directory_owner_epoch >= 0),
            room_kind TEXT NULL CHECK (room_kind IN ('direct', 'group'))
        );
        CREATE INDEX v2_room_recovery_work_due_idx
            ON v2_room_recovery_work(next_attempt_at, enqueued_at, room_id);
        CREATE INDEX v2_room_recovery_work_fair_idx
            ON v2_room_recovery_work(last_served_order, enqueued_at, room_id);
        CREATE INDEX v2_room_recovery_work_priority_idx
            ON v2_room_recovery_work(priority DESC, last_served_order, enqueued_at, room_id);
        CREATE TABLE v2_room_recovery_scan (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            scan_id TEXT NOT NULL, user_id TEXT NOT NULL, installation_binding TEXT NOT NULL,
            directory_round TEXT NOT NULL,
            cursor TEXT NULL, topology_generation TEXT NULL,
            directory_complete INTEGER NOT NULL CHECK (directory_complete IN (0, 1)),
            service_sequence INTEGER NOT NULL DEFAULT 0 CHECK (service_sequence >= 0)
        );
        """

    /// A new connection must reinstall coverage from the beginning. Durable
    /// content work survives; a prior connection's directory cursor proves no
    /// coverage on the replacement gateway.
    public func beginRoomRecoveryScan(userID: UserID) async throws -> V2RoomRecoveryScope {
        try await databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1"),
                  (row["user_id"] as String?) == userID.rawValue else { throw V2RoomRecoveryPersistenceError.staleScope }
            let scope = V2RoomRecoveryScope(scanID: UUID(), userID: userID, installationBinding: row["binding"])
            if let previous = try Row.fetchOne(db, sql: "SELECT user_id, installation_binding FROM v2_room_recovery_scan WHERE singleton = 1"),
               (previous["user_id"] as String) != userID.rawValue || (previous["installation_binding"] as String) != scope.installationBinding {
                try db.execute(sql: "DELETE FROM v2_room_recovery_work; DELETE FROM v2_room_latest_visible; DELETE FROM v2_room_sync_states")
                // Fairness history belongs to the same account/binding as its work.
                // Recreate the scan so a former account's exhausted counter cannot block this one.
                try db.execute(sql: "DELETE FROM v2_room_recovery_scan WHERE singleton = 1")
            }
            try db.execute(sql: """
                INSERT INTO v2_room_recovery_scan
                    (singleton, scan_id, user_id, installation_binding, directory_round, cursor, topology_generation, directory_complete)
                VALUES (1, ?, ?, ?, ?, NULL, NULL, 0)
                ON CONFLICT(singleton) DO UPDATE SET scan_id = excluded.scan_id,
                    user_id = excluded.user_id, installation_binding = excluded.installation_binding,
                    directory_round = excluded.directory_round,
                    cursor = NULL, topology_generation = NULL, directory_complete = 0
                """, arguments: [scope.scanID.uuidString, userID.rawValue, scope.installationBinding, UUID().uuidString])
            return scope
        }
    }

    /// A rejected topology cursor restarts discovery on the existing listener;
    /// already durable room work and fairness history remain intact.
    public func restartRoomRecoveryDirectory(scope: V2RoomRecoveryScope) async throws {
        try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            try db.execute(sql: "UPDATE v2_room_recovery_scan SET cursor = NULL, topology_generation = NULL, directory_complete = 0, directory_round = ? WHERE singleton = 1", arguments: [UUID().uuidString])
        }
    }

    public func roomRecoveryScan(scope: V2RoomRecoveryScope) async throws -> V2RoomRecoveryScan {
        try await databasePool.read { db in
            let row = try Self.requireRoomRecoveryScope(scope, db: db)
            return .init(directoryRound: row["directory_round"], personalGeneration: try Self.readCursor(db)?.generation,
                scope: scope, cursor: row["cursor"], topologyGeneration: row["topology_generation"],
                directoryComplete: row["directory_complete"])
        }
    }

    /// Page discovery, durable work and cursor advancement share one commit.
    /// Empty filtered pages still advance their server-issued continuation.
    public func commitRoomRecoveryDirectoryPage(_ page: V2ClientUserRoomPage, expectedCursor: String?,
                                                request: V2RoomRecoveryScan, now: Date) async throws {
        guard now.timeIntervalSince1970.isFinite else { throw V2RoomRecoveryPersistenceError.invalidWork }
        try await databasePool.write { db in
            let scan = try Self.requireRoomRecoveryScope(request.scope, db: db)
            guard (scan["directory_round"] as String) == request.directoryRound,
                  try Self.readCursor(db)?.generation == request.personalGeneration,
                  request.cursor == expectedCursor else { throw V2RoomRecoveryPersistenceError.stalePage }
            guard !(scan["directory_complete"] as Bool), (scan["cursor"] as String?) == expectedCursor,
                  page.nextCursor == nil || page.nextCursor != expectedCursor else { throw V2RoomRecoveryPersistenceError.stalePage }
            if let generation: String = scan["topology_generation"], generation != page.topologyGeneration {
                throw V2RoomRecoveryPersistenceError.topologyChanged
            }
            for entry in page.rooms {
                try Self.enqueueRoomRecovery(roomID: entry.roomID, head: 0, priority: 0, now: now, db: db)
                if let summary = try Row.fetchOne(db, sql: "SELECT personal_generation, membership_revision, owner_epoch FROM v2_room_latest_visible WHERE room_id = ?", arguments: [entry.roomID.rawValue]) {
                    _ = try Self.recoveryInteger(summary, "personal_generation")
                    _ = try Self.recoveryInteger(summary, "owner_epoch")
                    guard try Self.recoveryInteger(summary, "membership_revision") >= 0 else { throw V2RoomRecoveryPersistenceError.invalidWork }
                }
                try db.execute(sql: """
                    UPDATE v2_room_recovery_work SET
                        requires_summary = CASE WHEN EXISTS (
                            SELECT 1 FROM v2_room_latest_visible AS summary
                            JOIN v2_sync_cursor AS personal ON personal.singleton = 1
                                AND personal.state = 'ready' AND personal.generation = summary.personal_generation
                            WHERE summary.room_id = v2_room_recovery_work.room_id
                                AND summary.membership_revision >= ? AND summary.owner_epoch = ?
                        ) THEN requires_summary ELSE 1 END,
                        directory_membership_revision = MAX(COALESCE(directory_membership_revision, 0), ?),
                        directory_owner_epoch = MAX(COALESCE(directory_owner_epoch, 0), ?), room_kind = ?
                    WHERE room_id = ?
                    """, arguments: [Int64(entry.viewerMembershipRevision), Int64(entry.ownerEpoch),
                        Int64(entry.viewerMembershipRevision), Int64(entry.ownerEpoch), entry.kind.rawValue, entry.roomID.rawValue])
            }
            try db.execute(sql: """
                UPDATE v2_room_recovery_scan SET cursor = ?, topology_generation = ?, directory_complete = ? WHERE singleton = 1
                """, arguments: [page.nextCursor, page.topologyGeneration, page.nextCursor == nil])
        }
    }

    /// Online hints retain work before the connection's directory scan starts.
    /// They grant no access; the recovery driver still reads authoritative state.
    func retainOnlineRoomHead(roomID: RoomID, targetHead: UInt64, userID: UserID, now: Date) async throws {
        try await databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton = 1") == userID.rawValue else {
                throw V2RoomRecoveryPersistenceError.staleScope
            }
            try Self.enqueueRoomRecovery(roomID: roomID, head: targetHead, priority: 1, now: now, db: db)
        }
    }

    public func enqueueRoomRecovery(roomID: RoomID, targetHead: UInt64, priority: Int,
                                    scope: V2RoomRecoveryScope, now: Date) async throws {
        try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            try Self.enqueueRoomRecovery(roomID: roomID, head: targetHead, priority: priority, now: now, db: db)
        }
    }

    public func enqueueRoomLatestVisible(roomID: RoomID, scope: V2RoomRecoveryScope, now: Date) async throws {
        try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            try Self.enqueueRoomRecovery(roomID: roomID, head: 0, priority: 2, now: now, db: db)
            try db.execute(sql: "UPDATE v2_room_recovery_work SET requires_summary = 1 WHERE room_id = ?", arguments: [roomID.rawValue])
        }
    }

    /// Repeated display demand joins an existing request without invalidating
    /// its response or bypassing retry backoff. New facts use the enqueue path.
    public func ensureRoomLatestVisible(roomID: RoomID, scope: V2RoomRecoveryScope, now: Date) async throws {
        try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            try Self.validateStoredRecoveryWork(roomID: roomID, db: db)
            let pending = try Bool.fetchOne(db, sql: "SELECT requires_summary FROM v2_room_recovery_work WHERE room_id = ?",
                arguments: [roomID.rawValue]) ?? false
            if pending {
                try db.execute(sql: "UPDATE v2_room_recovery_work SET priority = MAX(priority, 2) WHERE room_id = ?",
                    arguments: [roomID.rawValue])
                return
            }
            try Self.enqueueRoomRecovery(roomID: roomID, head: 0, priority: 2, now: now, db: db)
            try db.execute(sql: "UPDATE v2_room_recovery_work SET requires_summary = 1 WHERE room_id = ?", arguments: [roomID.rawValue])
        }
    }

    /// A new personal membership grant is itself durable discovery, including
    /// grants behind a completed directory cursor. Do not wait for another hint.
    static func enqueueGrantedRoomRecovery(roomID: RoomID, db: Database) throws {
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM v2_room_recovery_scan AS scan
                JOIN v2_local_installation AS account ON account.singleton = scan.singleton
                    AND account.binding = scan.installation_binding AND account.user_id = scan.user_id)
            """) == true else { return }
        try enqueueRoomRecovery(roomID: roomID, head: 0, priority: 1, now: .now, db: db)
        try db.execute(sql: "UPDATE v2_room_recovery_work SET requires_summary = 1 WHERE room_id = ?",
            arguments: [roomID.rawValue])
    }

    static func requireRoomRecoveryScope(_ scope: V2RoomRecoveryScope, db: Database) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT scan.* FROM v2_room_recovery_scan AS scan
            JOIN v2_local_installation AS account ON account.singleton = scan.singleton
                AND account.binding = scan.installation_binding AND account.user_id = scan.user_id
            WHERE scan.singleton = 1 AND scan.scan_id = ? AND scan.user_id = ? AND scan.installation_binding = ?
            """, arguments: [scope.scanID.uuidString, scope.userID.rawValue, scope.installationBinding]) else {
            throw V2RoomRecoveryPersistenceError.staleScope
        }
        return row
    }

    private static func enqueueRoomRecovery(roomID: RoomID, head: UInt64, priority: Int, now: Date, db: Database) throws {
        guard roomID.uuidValue != nil, head <= UInt64(Int64.max), (0...2).contains(priority),
              now.timeIntervalSince1970.isFinite else { throw V2RoomRecoveryPersistenceError.invalidWork }
        try validateStoredRecoveryWork(roomID: roomID, db: db)
        // Ordinary watermarks add responsibility only beyond durable C. Keep
        // discovery (H=0), directory/summary reads and unknown authority intact.
        // Do not touch an existing newer work revision when ignoring an old H.
        if priority == 1, head > 0, try groupEventAccess(roomID: roomID, db: db)?.isAuthorized == true,
           let cursor = try Row.fetchOne(db,
                sql: "SELECT applied_room_sequence FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [roomID.rawValue]),
           try storageUnsigned(cursor, column: "applied_room_sequence") >= head { return }
        try db.execute(sql: """
            INSERT INTO v2_room_recovery_work
                (room_id, target_head, request_revision, requires_state, priority, enqueued_at, next_attempt_at)
            VALUES (?, ?, ?, 1, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET target_head = MAX(target_head, excluded.target_head),
                request_revision = excluded.request_revision, requires_state = 1,
                priority = MAX(priority, excluded.priority), next_attempt_at = MIN(next_attempt_at, excluded.next_attempt_at)
            """, arguments: [roomID.rawValue, Int64(head), UUID().uuidString, priority,
                now.timeIntervalSince1970, now.timeIntervalSince1970])
    }
}
