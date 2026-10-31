import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// Creation and admission use the same DDL, including indexes, foreign keys
    /// and checks. There is deliberately no legacy schema repair or fallback.
    static let resourceSchemaStatements = [
        resourceJournalSchemaSQL, resourceImportSchemaSQL, resourceCatalogSchemaSQL,
        resourceBackgroundSourcesSchemaSQL, resourceStoragePolicySchemaSQL,
        resourceDownloadNetworkSchemaSQL, resourceVariantSchemaSQL,
        localResourceAssetSchemaSQL, resourceDirectorySchemaSQL,
        resourceQueryCheckpointSchemaSQL, resourceDownloadSchemaSQL
    ]

    static func validateCurrentResourceSchema(_ db: Database) throws {
        let expected = try resourceSchemaReference.get()
        let names = Set(expected.map(\.name))
        let snapshot: String? = try String.fetchOne(db, sql: "SELECT snapshot_id FROM v2_snapshots WHERE singleton=1")
        let activeIndex = snapshot.map {
            "v2_snapshot_\($0.replacingOccurrences(of: "-", with: ""))_resource_projection_index_jobs_0_idx"
        }
        let actual = try resourceSchemaObjects(db).compactMap { object -> ResourceSchemaObject? in
            // The current snapshot protocol swaps projection banks atomically.
            // Its old index remains on the retired bank until bounded cleanup.
            if snapshot != nil, object.name == projectionIndex, object.table == "v2_snapshot_retired_resource_projection_index_jobs" { return nil }
            return normalizeProjectionBank(object, activeIndex: activeIndex)
        }.filter {
            names.contains($0.name) || $0.name.hasPrefix("v2_resource_") ||
                $0.name.hasPrefix("v2_background_transfer_") || $0.name.hasPrefix("resource_access_") || $0.name == activeIndex
        }.sorted {
            $0.type == $1.type ? $0.name < $1.name : $0.type < $1.type
        }
        guard actual == expected else { throw V2ClientLocalStorageError.unsupportedResourceSchema }
    }

    private static let projectionQueue = "v2_resource_projection_index_jobs"
    private static let projectionIndex = "v2_resource_projection_index_room"

    private static func normalizeProjectionBank(_ object: ResourceSchemaObject, activeIndex: String?) -> ResourceSchemaObject {
        guard object.table == projectionQueue else { return object }
        if object.type == "table", object.name == projectionQueue {
            let sql = object.sql.replacingOccurrences(of: "CREATE TABLE \"\(projectionQueue)\"",
                with: "CREATE TABLE \(projectionQueue)", options: .anchored)
            return .init(type: object.type, name: object.name, table: object.table, sql: sql)
        }
        guard object.type == "index", object.name == projectionIndex || object.name == activeIndex else { return object }
        let prefix = "CREATE INDEX \(object.name) ON "
        guard object.sql.hasPrefix(prefix) else { return object }
        let definition = String(object.sql.dropFirst(prefix.count)).replacingOccurrences(of: "\"\(projectionQueue)\"",
            with: projectionQueue, options: .anchored)
        return .init(type: object.type, name: projectionIndex, table: object.table,
            sql: "CREATE INDEX \(projectionIndex) ON " + definition)
    }

    private struct ResourceSchemaObject: Equatable, Sendable {
        let type: String
        let name: String
        let table: String
        let sql: String
    }

    /// Compile trusted current DDL once in memory, using this process's SQLite
    /// normalization. Never execute SQL read from the account's sqlite_schema.
    private static let resourceSchemaReference: Result<[ResourceSchemaObject], any Error> = Result {
        let reference = try DatabaseQueue()
        defer { try? reference.close() }
        return try reference.write { db in
            // Resource authorization triggers attach to account projection
            // tables. Build their real prerequisites, not empty stand-in tables.
            try db.execute(sql: currentSchemaSQL)
            let accountObjects = Set(try resourceSchemaObjects(db).map(\.name))
            for statement in resourceSchemaStatements { try db.execute(sql: statement) }
            return try resourceSchemaObjects(db).filter { !accountObjects.contains($0.name) }
        }
    }

    private static func resourceSchemaObjects(_ db: Database) throws -> [ResourceSchemaObject] {
        try Row.fetchAll(db, sql: """
            SELECT type,name,tbl_name,sql FROM sqlite_schema
            WHERE sql IS NOT NULL AND type IN ('table','index','trigger','view')
            ORDER BY type,name
            """).map { row in
                ResourceSchemaObject(type: row["type"], name: row["name"], table: row["tbl_name"], sql: row["sql"])
            }
    }
}
