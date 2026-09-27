import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// Bounded local lookup; notifications never require loading a whole group roster.
    public func groupNicknameRevisions(keys: Set<V2ProfileViewLookupKey>) throws -> [V2ProfileViewLookupKey: UInt64] {
        guard keys.count <= 2_064 else { throw V2ClientProjectionError.invalidMessagePayload }
        guard !keys.isEmpty else { return [:] }
        struct Lookup: Encodable { let index: Int; let room: String?; let user: String }
        let ordered = Array(keys)
        let lookups = ordered.enumerated().map { index, key -> Lookup in
            let room: String? = if case .room(let value) = key.context { value.rawValue } else { nil }
            return .init(index: index, room: room, user: key.userID.rawValue)
        }
        let json = String(decoding: try JSONEncoder().encode(lookups), as: UTF8.self)
        return try databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT json_extract(request.value,'$.index') AS position, COALESCE(state.revision,0) AS revision
                FROM json_each(?) request LEFT JOIN v2_group_nickname_invalidations state
                  ON state.room_id=json_extract(request.value,'$.room') AND state.user_id=json_extract(request.value,'$.user')
                """, arguments: [json])
            var result: [V2ProfileViewLookupKey: UInt64] = [:]
            for row in rows {
                let index: Int = row["position"]
                guard ordered.indices.contains(index), result[ordered[index]] == nil else { throw V2ClientProjectionError.invalidMessagePayload }
                result[ordered[index]] = try Self.storageUnsigned(row, column: "revision")
            }
            guard result.count == keys.count else { throw V2ClientProjectionError.invalidMessagePayload }
            return result
        }
    }

    static func applyGroupNicknameInvalidation(_ effect: V2LocalGroupNicknameEffect,
                                             target: ProjectionTableTarget = .live, db: Database) throws {
        let receipts = target.table("v2_group_nickname_effects")
        let state = target.table("v2_group_nickname_invalidations")
        let claims = try Row.fetchAll(db, sql: """
            SELECT * FROM \(receipts) WHERE room_id=? AND
                (source_event_id=? OR (user_id=? AND revision=?) OR room_sequence=?)
            """, arguments: [effect.roomID.rawValue, effect.sourceEventID.rawValue, effect.userID.rawValue, effect.revision, effect.roomSequence])
        for claim in claims {
            let previous = try groupNicknameEffect(claim)
            guard previous.sourceEventID == effect.sourceEventID, previous.digest == effect.digest else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
        }
        if claims.isEmpty {
            try db.execute(sql: """
                INSERT INTO \(receipts)(source_event_id,room_id,user_id,revision,room_sequence,updated_at_ms,canonical_digest)
                VALUES(?,?,?,?,?,?,?)
                """, arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.userID.rawValue, effect.revision,
                    effect.roomSequence, effect.updatedAtMilliseconds, effect.digest])
        }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM \(state) WHERE room_id=? AND user_id=?", arguments: [effect.roomID.rawValue, effect.userID.rawValue]) {
            let current = try groupNicknameEffect(row)
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
            INSERT INTO \(state)(room_id,user_id,revision,room_sequence,updated_at_ms,source_event_id,canonical_digest)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(room_id,user_id) DO UPDATE SET revision=excluded.revision,
                room_sequence=excluded.room_sequence,updated_at_ms=excluded.updated_at_ms,
                source_event_id=excluded.source_event_id,canonical_digest=excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.userID.rawValue, effect.revision, effect.roomSequence, effect.updatedAtMilliseconds,
                effect.sourceEventID.rawValue, effect.digest])
    }

    static func preserveGroupNicknameInvalidations(authorizedRoomsSQL: String, db: Database) throws {
        // A personal snapshot cannot roll back already applied room-log invalidations.
        // Only retained, authorized rooms may carry their history into the next bank.
        let states = try Row.fetchCursor(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL)) SELECT live.* FROM v2_group_nickname_invalidations live
            JOIN authorized room ON room.room_id=live.room_id
            """)
        while let row = try states.next() {
            let state = try groupNicknameEffect(row)
            guard let receipt = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_nickname_effects WHERE room_id=? AND source_event_id=?",
                arguments: [state.roomID.rawValue, state.sourceEventID.rawValue]),
                try groupNicknameEffect(receipt).digest == state.digest else { throw V2ClientProjectionError.invalidMessagePayload }
        }
        let receipts = try Row.fetchCursor(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL)) SELECT live.* FROM v2_group_nickname_effects live
            JOIN authorized room ON room.room_id=live.room_id
            ORDER BY live.room_id,live.user_id,live.revision
            """)
        while let row = try receipts.next() {
            try applyGroupNicknameInvalidation(groupNicknameEffect(row), target: .snapshotShadow, db: db)
        }
    }

    private static func groupNicknameEffect(_ row: Row) throws -> V2LocalGroupNicknameEffect {
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
        let effect = try V2LocalGroupNicknameEffect(sourceEventID: .init(string("source_event_id")),
            roomID: .init(string("room_id")), userID: .init(string("user_id")), revision: integer("revision"), roomSequence: integer("room_sequence"),
            updatedAtMilliseconds: integer("updated_at_ms"))
        let digest: DatabaseValue = row["canonical_digest"]
        guard case .blob(let bytes) = digest.storage, bytes == effect.digest else { throw V2ClientProjectionError.invalidMessagePayload }
        return effect
    }
}
