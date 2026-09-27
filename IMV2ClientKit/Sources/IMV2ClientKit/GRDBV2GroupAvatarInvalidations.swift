import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static func applyGroupAvatarInvalidation(_ effect: V2LocalGroupAvatarEffect,
                                             target: ProjectionTableTarget = .live, db: Database) throws {
        let receipts = target.table("v2_group_avatar_effects")
        let state = target.table("v2_group_avatar_invalidations")
        let claims = try Row.fetchAll(db, sql: """
            SELECT * FROM \(receipts) WHERE room_id=? AND
                (source_event_id=? OR revision=? OR room_sequence=?)
            """, arguments: [effect.roomID.rawValue, effect.sourceEventID.rawValue, effect.revision, effect.roomSequence])
        for claim in claims {
            let previous = try groupAvatarEffect(claim)
            guard previous.sourceEventID == effect.sourceEventID, previous.digest == effect.digest else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
        }
        if claims.isEmpty {
            try db.execute(sql: """
                INSERT INTO \(receipts)(source_event_id,room_id,revision,room_sequence,updated_at_ms,canonical_digest)
                VALUES(?,?,?,?,?,?)
                """, arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.revision,
                    effect.roomSequence, effect.updatedAtMilliseconds, effect.digest])
        }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM \(state) WHERE room_id=?", arguments: [effect.roomID.rawValue]) {
            let current = try groupAvatarEffect(row)
            if current.revision == effect.revision {
                guard current.sourceEventID == effect.sourceEventID, current.digest == effect.digest else {
                    throw V2ClientProjectionError.invalidMessagePayload
                }
                return
            }
            if current.revision > effect.revision {
                guard current.roomSequence > effect.roomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
            guard current.roomSequence < effect.roomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
        }
        try db.execute(sql: """
            INSERT INTO \(state)(room_id,revision,room_sequence,updated_at_ms,source_event_id,canonical_digest)
            VALUES(?,?,?,?,?,?) ON CONFLICT(room_id) DO UPDATE SET revision=excluded.revision,
                room_sequence=excluded.room_sequence,updated_at_ms=excluded.updated_at_ms,
                source_event_id=excluded.source_event_id,canonical_digest=excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.revision, effect.roomSequence, effect.updatedAtMilliseconds,
                effect.sourceEventID.rawValue, effect.digest])
    }

    static func preserveGroupAvatarInvalidations(authorizedRoomsSQL: String, db: Database) throws {
        // A personal snapshot cannot roll back already applied room-log invalidations.
        // Only retained, authorized rooms may carry their history into the next bank.
        let states = try Row.fetchCursor(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL)) SELECT live.* FROM v2_group_avatar_invalidations live
            JOIN authorized room ON room.room_id=live.room_id
            """)
        while let row = try states.next() {
            let state = try groupAvatarEffect(row)
            guard let receipt = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_avatar_effects WHERE room_id=? AND source_event_id=?",
                arguments: [state.roomID.rawValue, state.sourceEventID.rawValue]),
                try groupAvatarEffect(receipt).digest == state.digest else { throw V2ClientProjectionError.invalidMessagePayload }
        }
        let receipts = try Row.fetchCursor(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL)) SELECT live.* FROM v2_group_avatar_effects live
            JOIN authorized room ON room.room_id=live.room_id
            ORDER BY live.room_id,live.revision
            """)
        while let row = try receipts.next() {
            try applyGroupAvatarInvalidation(groupAvatarEffect(row), target: .snapshotShadow, db: db)
        }
    }

    private static func groupAvatarEffect(_ row: Row) throws -> V2LocalGroupAvatarEffect {
        func string(_ key: String) throws -> String {
            let value: DatabaseValue = row[key]
            guard case .string(let text) = value.storage else { throw V2ClientProjectionError.invalidMessagePayload }
            return text
        }
        func integer(_ key: String) throws -> Int64 {
            let value: DatabaseValue = row[key]
            guard case .int64(let integer) = value.storage else { throw V2ClientProjectionError.invalidMessagePayload }
            return integer
        }
        let effect = try V2LocalGroupAvatarEffect(sourceEventID: .init(string("source_event_id")),
            roomID: .init(string("room_id")), revision: integer("revision"), roomSequence: integer("room_sequence"),
            updatedAtMilliseconds: integer("updated_at_ms"))
        let digest: DatabaseValue = row["canonical_digest"]
        guard case .blob(let bytes) = digest.storage, bytes == effect.digest else { throw V2ClientProjectionError.invalidMessagePayload }
        return effect
    }
}
