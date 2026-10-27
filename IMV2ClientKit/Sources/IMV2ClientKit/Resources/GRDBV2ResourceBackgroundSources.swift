import Foundation
import GRDB
import IMV2Core

struct V2ResourceBackgroundSourceRecord: Sendable {
    enum State: String, Sendable { case preparing, ready, deleting }
    let id: UUID, sessionID: UUID
    let bytes: Int64, allocatedBytes: Int64
    let state: State
    let checksum: V2ResourceChecksum?
    /// The source and a conservative system upload copy remain charged until
    /// actual system-task drain. System allocation itself is not observable.
    var reservedBytes: Int64 { max(bytes, allocatedBytes) + bytes }
}

extension GRDBV2LocalSyncStore {
    static let resourceBackgroundSourcesSchemaSQL = """
        CREATE TABLE v2_resource_background_upload_sources (
            source_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            byte_count INTEGER NOT NULL CHECK(byte_count>0 AND byte_count<=268435456),
            allocated_bytes INTEGER NOT NULL CHECK(allocated_bytes>=0),
            state TEXT NOT NULL CHECK(state IN ('preparing','ready','deleting')),
            checksum TEXT CHECK(length(checksum)=64),
            CHECK(state<>'ready' OR checksum IS NOT NULL)
        );
        CREATE INDEX v2_resource_background_sources_session ON v2_resource_background_upload_sources(session_id,source_id);
        """
}

extension V2ResourceFileJournal {
    func backgroundSources() throws -> [V2ResourceBackgroundSourceRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_resource_background_upload_sources ORDER BY session_id,source_id").map { row in
                let bytes: Int64 = row["byte_count"], allocated: Int64 = row["allocated_bytes"]
                guard let id = UUID(uuidString: row["source_id"]), let session = UUID(uuidString: row["session_id"]),
                      let state = V2ResourceBackgroundSourceRecord.State(rawValue: row["state"]),
                      bytes > 0, bytes <= 256 * 1024 * 1024, allocated >= 0, allocated <= Int64.max / 8 else { throw V2ResourceStorageError.invalidRecord }
                let raw: String? = row["checksum"]
                return .init(id: id, sessionID: session, bytes: bytes, allocatedBytes: allocated, state: state,
                    checksum: try raw.map { try .init(value: $0) })
            }
        }
    }
    func beginBackgroundSource(id: UUID, session: UUID, bytes: Int64) throws {
        try databasePool.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_background_upload_sources") ?? 0 < 128 else { throw V2ResourceStorageError.capacityExceeded }
            try db.execute(sql: "INSERT INTO v2_resource_background_upload_sources(source_id,session_id,byte_count,allocated_bytes,state) VALUES(?,?,?,0,'preparing')",
                arguments: [id.uuidString,session.uuidString,bytes])
        }
    }
    func finishBackgroundSource(id: UUID, checksum: V2ResourceChecksum, allocatedBytes: Int64) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_background_upload_sources SET state='ready',checksum=?,allocated_bytes=? WHERE source_id=? AND state='preparing'",
                arguments: [checksum.value,allocatedBytes,id.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceStorageError.conflict }
        }
    }
    func deleteBackgroundSource(_ id: UUID, finished: Bool) throws {
        try databasePool.write { db in
            try db.execute(sql: finished ? "DELETE FROM v2_resource_background_upload_sources WHERE source_id=? AND state='deleting'"
                : "UPDATE v2_resource_background_upload_sources SET state='deleting' WHERE source_id=?", arguments: [id.uuidString])
        }
    }
    static func temporaryReservedBytes(db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            SELECT (SELECT COALESCE(SUM(byte_count+publication_bytes),0) FROM v2_resource_transfer_staging)
              + (SELECT COALESCE(SUM(MAX(byte_count,allocated_bytes)+byte_count),0) FROM v2_resource_background_upload_sources)
            """) ?? 0
    }
}
