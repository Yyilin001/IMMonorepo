import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static func applyContactAliasInvalidation(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable {
            let targetUserID: String
            let revision: Int64
            enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id", revision }
        }
        guard let object = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any],
              Set(object.keys) == ["target_user_id", "revision"],
              let value = try? JSONDecoder().decode(Payload.self, from: record.payload),
              let uuid = UUID(uuidString: value.targetUserID), value.revision > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        let user = UserID(uuid: uuid)
        let table = target.table("v2_contact_alias_invalidations")
        try db.execute(sql: """
            INSERT INTO \(table)(target_user_id,revision) VALUES(?,?)
            ON CONFLICT(target_user_id) DO UPDATE SET revision=MAX(revision,excluded.revision)
            """, arguments: [user.rawValue, value.revision])
    }
    public func contactAliasRevisions(keys: Set<V2ProfileViewLookupKey>) throws -> [V2ProfileViewLookupKey: UInt64] {
        guard keys.count <= 2_064 else { throw V2ClientProjectionError.invalidMessagePayload }
        if keys.isEmpty { return [:] }
        let ordered = Array(keys)
        let users = ordered.map { $0.userID.rawValue }
        let json = String(decoding: try JSONEncoder().encode(users), as: UTF8.self)
        return try databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(request.key AS INTEGER) AS position, COALESCE(state.revision,0) AS revision
                FROM json_each(?) request LEFT JOIN v2_contact_alias_invalidations state ON state.target_user_id=request.value
                """, arguments: [json])
            var values: [V2ProfileViewLookupKey: UInt64] = [:]
            for row in rows {
                let position: Int = row["position"]
                guard ordered.indices.contains(position), values[ordered[position]] == nil else { throw V2ClientProjectionError.invalidMessagePayload }
                values[ordered[position]] = try Self.storageUnsigned(row, column: "revision")
            }
            guard values.count == keys.count else { throw V2ClientProjectionError.invalidMessagePayload }
            return values
        }
    }
    static func preserveContactAliasInvalidations(db: Database) throws {
        let table = ProjectionTableTarget.snapshotShadow.table("v2_contact_alias_invalidations")
        try db.execute(sql: """
            INSERT INTO \(table)(target_user_id,revision)
            SELECT target_user_id,revision FROM v2_contact_alias_invalidations WHERE 1
            ON CONFLICT(target_user_id) DO UPDATE SET revision=MAX(revision,excluded.revision)
            """)
    }
}
