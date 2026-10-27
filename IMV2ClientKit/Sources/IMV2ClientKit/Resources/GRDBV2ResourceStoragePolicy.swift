import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    static let resourceStoragePolicySchemaSQL = """
        CREATE TABLE v2_resource_storage_policy (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            maximum_cache_bytes INTEGER NOT NULL CHECK(maximum_cache_bytes>0),
            maximum_original_bytes INTEGER NOT NULL CHECK(maximum_original_bytes>0),
            maximum_temporary_bytes INTEGER NOT NULL CHECK(maximum_temporary_bytes>0),
            maximum_managed_bytes INTEGER CHECK(maximum_managed_bytes>0),
            minimum_free_bytes INTEGER NOT NULL CHECK(minimum_free_bytes>=0),
            retained_warning_bytes INTEGER NOT NULL CHECK(retained_warning_bytes>0)
        );
        """
}

extension V2ResourceFileJournal {
    func storagePolicy(defaults: V2ResourceStoragePolicy) throws -> V2ResourceStoragePolicy {
        try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_storage_policy WHERE singleton=1") { return try Self.decodePolicy(row) }
            try Self.writePolicy(defaults, db: db)
            return defaults
        }
    }
    func setStoragePolicy(_ policy: V2ResourceStoragePolicy) throws {
        try databasePool.write { try Self.writePolicy(policy, db: $0) }
    }
    private static func writePolicy(_ value: V2ResourceStoragePolicy, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO v2_resource_storage_policy(singleton,maximum_cache_bytes,maximum_original_bytes,maximum_temporary_bytes,maximum_managed_bytes,minimum_free_bytes,retained_warning_bytes)
            VALUES(1,?,?,?,?,?,?) ON CONFLICT(singleton) DO UPDATE SET
                maximum_cache_bytes=excluded.maximum_cache_bytes,maximum_original_bytes=excluded.maximum_original_bytes,
                maximum_temporary_bytes=excluded.maximum_temporary_bytes,maximum_managed_bytes=excluded.maximum_managed_bytes,
                minimum_free_bytes=excluded.minimum_free_bytes,retained_warning_bytes=excluded.retained_warning_bytes
            """, arguments: [value.maximumCacheBytes,value.maximumOriginalBytes,value.maximumTemporaryBytes,value.maximumManagedBytes,value.minimumFreeBytes,value.retainedWarningBytes])
    }
    private static func decodePolicy(_ row: Row) throws -> V2ResourceStoragePolicy {
        try .init(maximumCacheBytes: row["maximum_cache_bytes"], maximumOriginalBytes: row["maximum_original_bytes"],
                  maximumTemporaryBytes: row["maximum_temporary_bytes"], maximumManagedBytes: row["maximum_managed_bytes"],
                  minimumFreeBytes: row["minimum_free_bytes"], retainedWarningBytes: row["retained_warning_bytes"])
    }
    func quotaSnapshot(policy: V2ResourceStoragePolicy) throws -> V2ResourceQuotaSnapshot {
        try databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT CASE WHEN state='publishing' THEN publication_class ELSE retention END AS category,
                    COALESCE(SUM(MAX(byte_count,allocated_bytes)),0) AS charge FROM v2_resource_files WHERE state<>'missing' GROUP BY category
                """)
            var charges: [String:Int64] = [:]
            for row in rows { charges[row["category"]] = row["charge"] }
            let temporary = try Self.temporaryReservedBytes(db: db)
            return .init(policy: policy, cacheBytes: charges["cache"] ?? 0, originalBytes: charges["original"] ?? 0,
                         retainedBytes: charges["retained"] ?? 0, temporaryReservedBytes: temporary)
        }
    }
}
