import Foundation
import GRDB
import IMV2Core

public struct V2RoomRecoveryWork: Equatable, Sendable {
    public let scope: V2RoomRecoveryScope
    public let roomID: RoomID
    public let requestRevision: UUID
    public let targetHead: UInt64
    public let requiresState: Bool
    public let requiresSummary: Bool
    public let priority: Int
    public let enqueuedAt: Date
    let personalGeneration: UInt64?
    let membershipFence: V2RoomRecoveryMembershipFence?
    let stateFence: V2RoomSynchronizationState?
}

struct V2RoomRecoveryMembershipFence: Equatable, Sendable {
    let revision: Int64
    let source: String
    let isMember: Bool
}

extension GRDBV2LocalSyncStore {
    /// The engine alternates priority batches with oldest-first batches. Both
    /// queries retain a stable room tie-breaker and exclude retry-delayed work.
    public func roomRecoveryWork(scope: V2RoomRecoveryScope, limit: Int, oldestFirst: Bool,
                                  now: Date) async throws -> [V2RoomRecoveryWork] {
        guard (1...100).contains(limit), now.timeIntervalSince1970.isFinite else {
            throw V2RoomRecoveryPersistenceError.invalidWork
        }
        return try await databasePool.read { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            let personalGeneration = try Self.readCursor(db)?.generation
            let order = oldestFirst ? "last_served_order, enqueued_at, room_id" : "priority DESC, last_served_order, enqueued_at, room_id"
            return try Row.fetchAll(db, sql: "SELECT * FROM v2_room_recovery_work WHERE next_attempt_at <= ? ORDER BY \(order) LIMIT ?",
                arguments: [now.timeIntervalSince1970, limit]).map { row in
                    try Self.validateRecoveryWorkValues(row)
                    guard let revision = UUID(uuidString: row["request_revision"]) else { throw V2RoomRecoveryPersistenceError.invalidWork }
                    let room = try RoomID(row["room_id"] as String)
                    return .init(scope: scope, roomID: room, requestRevision: revision,
                        targetHead: UInt64(try Self.recoveryInteger(row, "target_head")), requiresState: row["requires_state"], requiresSummary: row["requires_summary"],
                        priority: row["priority"], enqueuedAt: .init(timeIntervalSince1970: row["enqueued_at"]),
                        personalGeneration: personalGeneration,
                        membershipFence: try Self.readRecoveryMembershipFence(roomID: room, db: db),
                        stateFence: try Self.readRoomSynchronizationState(roomID: room, db: db))
                }
        }
    }

    public func roomSynchronizationState(roomID: RoomID, scope: V2RoomRecoveryScope) async throws -> V2RoomSynchronizationState? {
        try await databasePool.read { db in
            _ = try Self.requireRoomRecoveryScope(scope, db: db)
            guard let state = try Self.readRoomSynchronizationState(roomID: roomID, db: db),
                  try Self.roomRecoveryMembershipAllows(state, db: db) else { return nil }
            return state
        }
    }

    /// Persist the whole version vector. Updating the task uses its captured
    /// revision, so a notification received during this read remains pending.
    public func commitRoomRecoveryState(_ state: V2RoomSynchronizationState, work: V2RoomRecoveryWork,
                                          now: Date) async throws -> V2RoomStateDisposition {
        guard state.roomID == work.roomID, now.timeIntervalSince1970.isFinite else { throw V2RoomRecoveryPersistenceError.invalidWork }
        return try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryWorkScope(work, db: db)
            try Self.requireProjectionWritesUnfenced(db: db)
            try Self.validateStoredRecoveryWork(roomID: work.roomID, db: db)
            guard try Self.roomRecoveryMembershipAllows(state, db: db) else { throw V2RoomRecoveryPersistenceError.staleMembership }
            let previous = try Self.readRoomSynchronizationState(roomID: state.roomID, db: db)
            let disposition = try previous.map { try state.disposition(replacing: $0) } ?? .advance
            guard disposition == .advance || disposition == .unchanged else {
                try db.execute(sql: "UPDATE v2_room_recovery_work SET requires_state = 1 WHERE room_id = ? AND request_revision = ?",
                    arguments: [work.roomID.rawValue, work.requestRevision.uuidString])
                try Self.recordRoomRecoveryService(work, db: db)
                return disposition
            }
            try db.execute(sql: """
                INSERT INTO v2_room_sync_states VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_id) DO UPDATE SET owner_epoch = excluded.owner_epoch,
                    membership_revision = excluded.membership_revision, head = excluded.head,
                    trimmed_through = excluded.trimmed_through, read_through = excluded.read_through,
                    latest_own_sequence = excluded.latest_own_sequence, checked_at = excluded.checked_at
                """, arguments: [state.roomID.rawValue, Int64(state.ownerEpoch), Int64(state.viewerMembershipRevision),
                    Int64(state.head), Int64(state.trimmedThrough), Int64(state.readThrough), Int64(state.latestOwnMessageSequence), now.timeIntervalSince1970])
            try db.execute(sql: """
                UPDATE v2_room_recovery_work SET target_head = MAX(target_head, ?),
                    requires_state = CASE WHEN target_head <= ?
                        AND COALESCE(directory_membership_revision, 0) <= ?
                        AND COALESCE(directory_owner_epoch, 0) <= ? THEN 0 ELSE 1 END
                WHERE room_id = ? AND request_revision = ?
                """, arguments: [Int64(state.head), Int64(state.head), Int64(state.viewerMembershipRevision),
                    Int64(state.ownerEpoch), work.roomID.rawValue, work.requestRevision.uuidString])
            return disposition
        }
    }

    /// An explicit unavailable result may end this request, but not a newer
    /// request or a membership/state observation committed while it was in flight.
    public func commitRoomRecoveryUnavailable(_ work: V2RoomRecoveryWork) async throws -> Bool {
        try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryWorkScope(work, db: db)
            try Self.requireProjectionWritesUnfenced(db: db)
            guard try Self.readRecoveryMembershipFence(roomID: work.roomID, db: db) == work.membershipFence,
                  try Self.readRoomSynchronizationState(roomID: work.roomID, db: db) == work.stateFence else { return false }
            try db.execute(sql: "DELETE FROM v2_room_recovery_work WHERE room_id = ? AND request_revision = ?",
                arguments: [work.roomID.rawValue, work.requestRevision.uuidString])
            guard db.changesCount == 1 else { return false }
            try db.execute(sql: "DELETE FROM v2_room_sync_states WHERE room_id = ?", arguments: [work.roomID.rawValue])
            try Self.markRoomEventUnauthorized(roomID: work.roomID, db: db)
            return true
        }
    }

    private static func readRecoveryMembershipFence(roomID: RoomID, db: Database) throws -> V2RoomRecoveryMembershipFence? {
        guard let row = try Row.fetchOne(db, sql: "SELECT membership_revision, source_event_id, is_member FROM v2_room_membership_states WHERE room_id = ?",
            arguments: [roomID.rawValue]) else { return nil }
        return .init(revision: try recoveryInteger(row, "membership_revision"), source: row["source_event_id"], isMember: row["is_member"])
    }

    public func retryRoomRecoveryWork(_ work: V2RoomRecoveryWork, at date: Date) async throws {
        guard date.timeIntervalSince1970.isFinite else { throw V2RoomRecoveryPersistenceError.invalidWork }
        try await databasePool.write { db in
            _ = try Self.requireRoomRecoveryWorkScope(work, db: db)
            // Validate the matching request before overwriting its retry time.
            // A stale request still leaves a newer pending request untouched.
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_recovery_work WHERE room_id = ? AND request_revision = ?",
                arguments: [work.roomID.rawValue, work.requestRevision.uuidString]) {
                try Self.validateRecoveryWorkValues(row)
            }
            try db.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = ? WHERE room_id = ? AND request_revision = ?",
                arguments: [date.timeIntervalSince1970, work.roomID.rawValue, work.requestRevision.uuidString])
            if db.changesCount == 1 { try Self.recordRoomRecoveryService(work, db: db) }
        }
    }

    /// This helper is also used inside the room-page transaction. A summary or
    /// state response never advances the content cursor to satisfy completion.
    static func finishRoomRecoveryWork(_ work: V2RoomRecoveryWork, db: Database) throws -> Bool {
        _ = try requireRoomRecoveryWorkScope(work, db: db)
        guard let state = try readRoomSynchronizationState(roomID: work.roomID, db: db),
              try roomRecoveryMembershipAllows(state, db: db) else { return false }
        try validateStoredRecoveryWork(roomID: work.roomID, db: db)
        if let cursor = try Row.fetchOne(db, sql: "SELECT applied_room_sequence FROM v2_group_event_cursors WHERE room_id = ?", arguments: [work.roomID.rawValue]) {
            _ = try recoveryInteger(cursor, "applied_room_sequence")
        }
        try db.execute(sql: """
            DELETE FROM v2_room_recovery_work WHERE room_id = ? AND request_revision = ? AND requires_state = 0 AND requires_summary = 0
                AND target_head <= COALESCE((SELECT applied_room_sequence FROM v2_group_event_cursors WHERE room_id = ?), 0)
            """, arguments: [work.roomID.rawValue, work.requestRevision.uuidString, work.roomID.rawValue])
        return db.changesCount == 1
    }

    public func finishRoomRecoveryWork(_ work: V2RoomRecoveryWork) async throws -> Bool {
        try await databasePool.write { try Self.finishRoomRecoveryWork(work, db: $0) }
    }

    /// Scheduling progress is independent of acknowledgment. A new target for
    /// the same room retains its turn history, even if it arrived during I/O.
    static func recordRoomRecoveryService(_ work: V2RoomRecoveryWork, db: Database) throws {
        let scan = try requireRoomRecoveryWorkScope(work, db: db)
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_room_recovery_work WHERE room_id = ?)",
            arguments: [work.roomID.rawValue]) == true else { return }
        try validateStoredRecoveryWork(roomID: work.roomID, db: db)
        let sequence = try recoveryInteger(scan, "service_sequence")
        guard sequence < Int64.max else { throw V2RoomRecoveryPersistenceError.invalidWork }
        try db.execute(sql: "UPDATE v2_room_recovery_scan SET service_sequence = ? WHERE singleton = 1", arguments: [sequence + 1])
        try db.execute(sql: "UPDATE v2_room_recovery_work SET last_served_order = ? WHERE room_id = ?",
            arguments: [sequence + 1, work.roomID.rawValue])
    }

    /// Every result belongs to the personal-stream generation that issued it.
    /// Keep this check in the same transaction as the resulting mutation.
    static func requireRoomRecoveryWorkScope(_ work: V2RoomRecoveryWork, db: Database) throws -> Row {
        let scan = try requireRoomRecoveryScope(work.scope, db: db)
        guard try readCursor(db)?.generation == work.personalGeneration else {
            throw V2RoomRecoveryPersistenceError.staleScope
        }
        return scan
    }

    static func requireRoomRecoveryPageAuthorization(_ work: V2RoomRecoveryWork, db: Database) throws {
        _ = try requireRoomRecoveryWorkScope(work, db: db)
        // Body responses belong to the authorization observed before their
        // request. A newly joined membership or owner must not authorize an
        // older response. Head/read progress may advance within that identity.
        guard let captured = work.stateFence,
              let state = try readRoomSynchronizationState(roomID: work.roomID, db: db),
              captured.ownerEpoch == state.ownerEpoch,
              captured.viewerMembershipRevision == state.viewerMembershipRevision,
              try readRecoveryMembershipFence(roomID: work.roomID, db: db) == work.membershipFence,
              try roomRecoveryMembershipAllows(state, db: db) else { throw V2RoomRecoveryPersistenceError.staleMembership }
    }

    private static func roomRecoveryMembershipAllows(_ state: V2RoomSynchronizationState, db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT membership_revision, is_member FROM v2_room_membership_states WHERE room_id = ?",
            arguments: [state.roomID.rawValue]) else { return true }
        let revision = try recoveryInteger(row, "membership_revision")
        return revision < Int64(state.viewerMembershipRevision)
            || (revision == Int64(state.viewerMembershipRevision) && (row["is_member"] as Bool))
    }

    // SQLite affinity and CHECK(value >= 0) do not guarantee integer storage.
    // Reject malformed persisted values before converting or incrementing them.
    static func validateRecoveryWorkValues(_ row: Row) throws {
        for column in ["enqueued_at", "next_attempt_at"] {
            _ = try recoveryTimestamp(row, column)
        }
        _ = try recoveryInteger(row, "target_head")
        _ = try recoveryInteger(row, "last_served_order")
        guard try recoveryInteger(row, "priority") <= 2 else { throw V2RoomRecoveryPersistenceError.invalidWork }
        for column in ["directory_membership_revision", "directory_owner_epoch"] {
            let value: DatabaseValue = row[column]
            if value.isNull { continue }
            let integer = try recoveryInteger(row, column)
            if column == "directory_membership_revision", integer == 0 { throw V2RoomRecoveryPersistenceError.invalidWork }
        }
    }

    static func validateStoredRecoveryWork(roomID: RoomID, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_recovery_work WHERE room_id = ?", arguments: [roomID.rawValue]) {
            try validateRecoveryWorkValues(row)
        }
    }

    static func recoveryTimestamp(_ row: Row, _ column: String) throws -> Double {
        let value: DatabaseValue = row[column]
        switch value.storage {
        case .int64(let seconds): return Double(seconds)
        case .double(let seconds) where seconds.isFinite: return seconds
        default: throw V2RoomRecoveryPersistenceError.invalidWork
        }
    }

    static func recoveryInteger(_ row: Row, _ column: String) throws -> Int64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage, integer >= 0 else {
            throw V2RoomRecoveryPersistenceError.invalidWork
        }
        return integer
    }

    private static func readRoomSynchronizationState(roomID: RoomID, db: Database) throws -> V2RoomSynchronizationState? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_sync_states WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
        return try .init(roomID: roomID, ownerEpoch: UInt64(try recoveryInteger(row, "owner_epoch")),
            viewerMembershipRevision: UInt64(try recoveryInteger(row, "membership_revision")), head: UInt64(try recoveryInteger(row, "head")),
            trimmedThrough: UInt64(try recoveryInteger(row, "trimmed_through")), readThrough: UInt64(try recoveryInteger(row, "read_through")),
            latestOwnMessageSequence: UInt64(try recoveryInteger(row, "latest_own_sequence")))
    }
}
