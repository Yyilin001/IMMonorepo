import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let accountRoomHeadSchemaSQL = """
        CREATE TABLE v2_account_room_heads (
            room_id TEXT PRIMARY KEY,
            room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
            membership_revision INTEGER NOT NULL CHECK (membership_revision >= 0)
        );
        """

    static func validateCurrentAccountRoomHeadSchema(_ db: Database) throws {
        func normalized(_ sql: String) -> String {
            sql.replacingOccurrences(of: "\"", with: "")
                .filter { !$0.isWhitespace && $0 != ";" }
        }
        guard let actual = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type='table' AND name='v2_account_room_heads'"),
              normalized(actual) == normalized(accountRoomHeadSchemaSQL) else {
            throw V2ClientLocalStorageError.unsupportedAccountRecoverySchema
        }
    }

    /// Retaining recovery responsibility and advancing the personal cursor occur
    /// in the caller's one SQLite transaction. This never grants room access.
    static func applyAccountRoomHead(_ record: V2ClientSyncRecord,
                                    target: ProjectionTableTarget = .live, db: Database) throws {
        let head = try JSONDecoder().decode(V2AccountRoomHead.self, from: record.payload)
        let table = target.table("v2_account_room_heads")
        if let prior = try Row.fetchOne(db, sql: "SELECT room_sequence, membership_revision FROM \(table) WHERE room_id = ?",
                                       arguments: [head.roomID.rawValue]) {
            let sequence = try storageInteger(prior, column: "room_sequence")
            let revision = try storageInteger(prior, column: "membership_revision")
            guard sequence > 0, revision >= 0 else { throw V2ClientProjectionError.invalidMessagePayload }
            if head.roomSequence < UInt64(sequence) { return }
            if head.roomSequence == UInt64(sequence) {
                guard head.membershipRevision == UInt64(revision) else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
            guard head.membershipRevision >= UInt64(revision) else { throw V2ClientProjectionError.invalidMessagePayload }
        }
        try db.execute(sql: """
            INSERT INTO \(table)(room_id, room_sequence, membership_revision) VALUES (?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET room_sequence = excluded.room_sequence,
                membership_revision = excluded.membership_revision
            """, arguments: [head.roomID.rawValue, Int64(head.roomSequence), Int64(head.membershipRevision)])
        if case .live = target {
            try enqueueRoomRecovery(roomID: head.roomID, head: head.roomSequence, priority: 1, now: .now, db: db)
        }
        // A snapshot remains invisible until ACK. Activation restarts bounded
        // directory reconciliation, which reads authoritative current room state.
    }
}
