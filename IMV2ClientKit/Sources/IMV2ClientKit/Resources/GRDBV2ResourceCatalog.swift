import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let resourceCatalogSchemaSQL = """
        CREATE TABLE v2_resource_files (
            file_id TEXT PRIMARY KEY,
            checksum TEXT NOT NULL CHECK(length(checksum)=64),
            byte_count INTEGER NOT NULL CHECK(byte_count>0),
            allocated_bytes INTEGER NOT NULL CHECK(allocated_bytes>=0),
            retention TEXT NOT NULL CHECK(retention IN ('cache','retained','original')),
            publication_class TEXT CHECK(publication_class IN ('cache','retained','original')),
            storage TEXT NOT NULL DEFAULT 'persistent' CHECK(storage IN ('persistent','cache')),
            state TEXT NOT NULL CHECK(state IN ('publishing','published','retiring','missing','invalid')),
            last_access_at REAL NOT NULL CHECK(last_access_at>=0),
            CHECK(state<>'publishing' OR publication_class IS NOT NULL)
        );
        CREATE INDEX v2_resource_files_eviction ON v2_resource_files(last_access_at,file_id)
            WHERE retention='cache' AND state='published';
        CREATE INDEX v2_resource_files_content ON v2_resource_files(checksum,byte_count);
        CREATE INDEX v2_resource_files_placement ON v2_resource_files(file_id)
            WHERE state='published' AND ((retention='cache' AND storage='persistent') OR (retention<>'cache' AND storage='cache'));
        CREATE TABLE v2_resource_file_consumers (
            consumer_id TEXT NOT NULL, file_id TEXT NOT NULL REFERENCES v2_resource_files(file_id),
            kind TEXT NOT NULL CHECK(kind IN ('hold','selection','upload','profileIntent','manualOriginal')),
            PRIMARY KEY(kind,consumer_id,file_id)
        );
        CREATE INDEX v2_resource_file_consumers_file ON v2_resource_file_consumers(file_id);
        CREATE TABLE v2_resource_file_pins (
            file_id TEXT PRIMARY KEY REFERENCES v2_resource_files(file_id) ON DELETE CASCADE
        );
        CREATE TABLE v2_resource_file_operations (
            file_id TEXT PRIMARY KEY REFERENCES v2_resource_files(file_id),
            kind TEXT NOT NULL CHECK(kind IN ('publish','delete','relocate')),
            source_storage TEXT CHECK(source_storage IN ('persistent','cache')),
            target_storage TEXT CHECK(target_storage IN ('persistent','cache')),
            CHECK((kind='relocate' AND source_storage IS NOT NULL AND target_storage IS NOT NULL AND source_storage<>target_storage)
                OR (kind<>'relocate' AND source_storage IS NULL AND target_storage IS NULL))
        );
        CREATE TABLE v2_resource_cached_versions(
            identity TEXT PRIMARY KEY,family TEXT NOT NULL,media_id TEXT NOT NULL,
            file_id TEXT NOT NULL REFERENCES v2_resource_files(file_id) ON DELETE CASCADE
        );
        CREATE INDEX v2_resource_cached_versions_media ON v2_resource_cached_versions(media_id,file_id);
        CREATE TABLE v2_resource_transfer_staging(
            staging_id TEXT PRIMARY KEY,identity TEXT NOT NULL UNIQUE,
            byte_count INTEGER NOT NULL CHECK(byte_count>0 AND byte_count<=\(Int64.max / 8)),
            publication_bytes INTEGER NOT NULL CHECK(publication_bytes=0 OR publication_bytes=byte_count),
            location TEXT NOT NULL CHECK(location IN ('foreground','backgroundDownload')),
            session_id TEXT, mapping_id TEXT UNIQUE,
            updated_at REAL NOT NULL,
            CHECK((location='foreground' AND session_id IS NULL AND mapping_id IS NULL)
                OR (location='backgroundDownload' AND session_id IS NOT NULL AND mapping_id IS NOT NULL))
        );
        """

    /// Shares the account writer and transaction domain, never a second database.
    public func resourceFileJournal() -> V2ResourceFileJournal {
        V2ResourceFileJournal(databasePool: databasePool)
    }
}

/// Synchronous journal calls execute on the file-owner actor. No file I/O occurs
/// inside SQLite transactions, and runtime borrow counts never enter the database.
public struct V2ResourceFileJournal: Sendable {
    let databasePool: DatabasePool

    func records() throws -> [V2ResourceFileRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: Self.fileSelectSQL + " ORDER BY last_access_at,file_id").map(Self.decode)
        }
    }

    func record(_ id: V2LocalResourceFileID) throws -> V2ResourceFileRecord? {
        try databasePool.read { db in
            try Row.fetchOne(db, sql: Self.fileSelectSQL + " WHERE file_id=?", arguments: [id.value.uuidString]).map(Self.decode)
        }
    }

    func placementCandidates() throws -> [V2ResourceFileRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: Self.fileSelectSQL + " " + """
                WHERE state='published' AND ((retention='cache' AND storage='persistent') OR (retention<>'cache' AND storage='cache'))
                ORDER BY file_id LIMIT 128
                """).map(Self.decode)
        }
    }

    func relocations() throws -> [V2ResourceFileRelocation] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_resource_file_operations WHERE kind='relocate' ORDER BY file_id LIMIT 128").map { row in
                guard let id = UUID(uuidString: row["file_id"]),
                      let source = V2ResourceFileStorage(rawValue: row["source_storage"]),
                      let target = V2ResourceFileStorage(rawValue: row["target_storage"]) else { throw V2ResourceStorageError.invalidRecord }
                return .init(fileID: .init(id), source: source, target: target)
            }
        }
    }

    func beginRelocation(_ operation: V2ResourceFileRelocation) throws {
        try databasePool.write { db in
            guard operation.source != operation.target,
                  try String.fetchOne(db, sql: "SELECT storage FROM v2_resource_files WHERE file_id=? AND state='published'", arguments: [operation.fileID.value.uuidString]) == operation.source.rawValue else {
                throw V2ResourceStorageError.conflict
            }
            try db.execute(sql: """
                INSERT INTO v2_resource_file_operations(file_id,kind,source_storage,target_storage) VALUES(?,'relocate',?,?)
                ON CONFLICT(file_id) DO UPDATE SET kind='relocate',source_storage=excluded.source_storage,target_storage=excluded.target_storage
                """, arguments: [operation.fileID.value.uuidString,operation.source.rawValue,operation.target.rawValue])
        }
    }

    func commitRelocation(_ operation: V2ResourceFileRelocation) throws {
        try databasePool.write { db in
            try db.execute(sql: """
                UPDATE v2_resource_files SET storage=? WHERE file_id=? AND state='published' AND storage IN (?,?)
                  AND EXISTS(SELECT 1 FROM v2_resource_file_operations WHERE file_id=? AND kind='relocate' AND source_storage=? AND target_storage=?)
                """, arguments: [operation.target.rawValue,operation.fileID.value.uuidString,operation.source.rawValue,operation.target.rawValue,
                    operation.fileID.value.uuidString,operation.source.rawValue,operation.target.rawValue])
            guard db.changesCount == 1 else { throw V2ResourceStorageError.conflict }
        }
    }

    func finishRelocation(_ operation: V2ResourceFileRelocation) throws {
        try databasePool.write { db in
            try db.execute(sql: "DELETE FROM v2_resource_file_operations WHERE file_id=? AND kind='relocate' AND source_storage=? AND target_storage=?",
                arguments: [operation.fileID.value.uuidString,operation.source.rawValue,operation.target.rawValue])
        }
    }

    func matchingFile(checksum: V2ResourceChecksum, byteCount: Int64) throws -> V2ResourceFileRecord? {
        try databasePool.read { db in
            try Row.fetchOne(db, sql: Self.fileSelectSQL + " WHERE checksum=? AND byte_count=? AND state='published' ORDER BY file_id LIMIT 1",
                arguments: [checksum.value,byteCount]).map(Self.decode)
        }
    }

    func stagingReservations() throws -> [V2ResourceTemporaryReservationRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_resource_transfer_staging ORDER BY updated_at,staging_id").map { row in
                let bytes: Int64 = row["byte_count"], publication: Int64 = row["publication_bytes"]
                guard let id = UUID(uuidString: row["staging_id"]), bytes > 0, bytes <= Int64.max / 8,
                      publication == 0 || publication == bytes else { throw V2ResourceStorageError.invalidRecord }
                let location: V2ResourceTemporaryReservationRecord.Location
                if row["location"] as String == "foreground" { location = .foreground }
                else {
                    guard let session = UUID(uuidString: row["session_id"]), let mapping = UUID(uuidString: row["mapping_id"]) else { throw V2ResourceStorageError.invalidRecord }
                    location = .backgroundDownload(session: session, mapping: mapping)
                }
                return .init(id: id, identity: row["identity"], bytes: bytes, publicationBytes: publication, location: location)
            }
        }
    }

    func addStaging(id: UUID, identity: String, bytes: Int64, publicationBytes: Int64,
                    location: V2ResourceTemporaryReservationRecord.Location = .foreground, now: Date) throws {
        try databasePool.write { db in
            let session: String?, mapping: String?, kind: String
            switch location {
            case .foreground: kind = "foreground"; session = nil; mapping = nil
            case .backgroundDownload(let value, let id): kind = "backgroundDownload"; session = value.uuidString; mapping = id.uuidString
            }
            try db.execute(sql: "INSERT INTO v2_resource_transfer_staging(staging_id,identity,byte_count,publication_bytes,location,session_id,mapping_id,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                arguments: [id.uuidString,identity,bytes,publicationBytes,kind,session,mapping,now.timeIntervalSince1970])
        }
    }

    func updatePublicationReservation(_ id: UUID, bytes: Int64) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_transfer_staging SET publication_bytes=? WHERE staging_id=?", arguments: [bytes,id.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceStorageError.conflict }
        }
    }

    func publicationCredit(_ id: UUID, bytes: Int64) throws -> Int64 {
        try databasePool.read { db in try Self.publicationCredit(id, bytes: bytes, db: db) }
    }

    private static func publicationCredit(_ id: UUID, bytes: Int64, db: Database) throws -> Int64 {
        guard let credit = try Int64.fetchOne(db, sql: "SELECT publication_bytes FROM v2_resource_transfer_staging WHERE staging_id=? AND byte_count=?",
            arguments: [id.uuidString,bytes]), credit == bytes else { throw V2ResourceStorageError.conflict }
        return credit
    }

    func removeStaging(_ id: UUID) throws {
        try databasePool.write { try $0.execute(sql: "DELETE FROM v2_resource_transfer_staging WHERE staging_id=?", arguments: [id.uuidString]) }
    }

    func cacheFile(identity: String) throws -> V2LocalResourceFileID? {
        try databasePool.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT file_id FROM v2_resource_cached_versions WHERE identity=?", arguments: [identity]),
                  let uuid = UUID(uuidString: value) else { return nil }
            return .init(uuid)
        }
    }

    func bindCache(identity: String, family: String, mediaID: MediaID, fileID: V2LocalResourceFileID,
                   variant: V2ResourceVariantDescriptor? = nil) throws -> [V2LocalResourceFileID] {
        guard !identity.isEmpty, identity.utf8.count <= 1024 else { throw V2ResourceStorageError.invalidRecord }
        return try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM v2_resource_files WHERE file_id=?", arguments: [fileID.value.uuidString]) == "published" else { throw V2ResourceStorageError.unavailable }
            if let variant { try GRDBV2LocalSyncStore.bindResourceVariant(variant, fileID: fileID, db: db) }
            let previous = try String.fetchAll(db, sql: "SELECT DISTINCT file_id FROM v2_resource_cached_versions WHERE family=? AND identity<>?", arguments: [family,identity])
            try db.execute(sql: "DELETE FROM v2_resource_cached_versions WHERE family=? AND identity<>?", arguments: [family,identity])
            try db.execute(sql: "INSERT INTO v2_resource_cached_versions(identity,family,media_id,file_id) VALUES(?,?,?,?) ON CONFLICT(identity) DO UPDATE SET family=excluded.family,media_id=excluded.media_id,file_id=excluded.file_id",
                arguments: [identity,family,mediaID.rawValue,fileID.value.uuidString])
            return try previous.map {
                guard let uuid = UUID(uuidString: $0) else { throw V2ResourceStorageError.invalidRecord }
                return V2LocalResourceFileID(uuid)
            }
        }
    }

    func cachedFiles(mediaID: MediaID) throws -> [V2LocalResourceFileID] {
        try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT file_id FROM v2_resource_cached_versions WHERE media_id=?", arguments: [mediaID.rawValue]).map {
                guard let id = UUID(uuidString: $0) else { throw V2ResourceStorageError.invalidRecord }
                return .init(id)
            }
        }
    }

    /// Classify physical payloads once. A file shared with any non-avatar
    /// consumer stays in the ordinary cache category, never both categories.
    func avatarOnlyCacheFiles() throws -> Set<V2LocalResourceFileID> {
        try databasePool.read { db in
            try Set(String.fetchAll(db, sql: """
                SELECT file_id FROM v2_resource_cached_versions GROUP BY file_id
                HAVING SUM(CASE WHEN substr(family,1,7)='avatar:' THEN 0 ELSE 1 END)=0
                """).map {
                    guard let id = UUID(uuidString: $0) else { throw V2ResourceStorageError.invalidRecord }
                    return V2LocalResourceFileID(id)
                })
        }
    }

    func removeCacheBindings(mediaID: MediaID) throws {
        try databasePool.write { try $0.execute(sql: "DELETE FROM v2_resource_cached_versions WHERE media_id=?", arguments: [mediaID.rawValue]) }
    }

    func hasCacheBindings(fileID: V2LocalResourceFileID) throws -> Bool {
        try databasePool.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_cached_versions WHERE file_id=?)", arguments: [fileID.value.uuidString]) ?? false }
    }

    func currentAccessGeneration() throws -> Data {
        try databasePool.read { db in
            guard let token = try Data.fetchOne(db, sql: "SELECT token FROM v2_resource_access_generation WHERE singleton=1"), token.count == 16 else { throw V2ResourceStorageError.invalidRecord }
            return token
        }
    }

    func requireMessageAccess(_ message: V2MediaMessageLocation?, mediaID: MediaID) throws {
        guard let message else { return }
        try databasePool.read { db in
            guard try !GRDBV2LocalSyncStore.resourceRoomIsDenied(message.roomID, db: db),
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_message_tombstones WHERE room_id=? AND message_id=?)",
                    arguments: [message.roomID.rawValue,message.messageID.rawValue]) != true else { throw V2ResourceStorageError.unavailable }
            if let row = try Row.fetchOne(db, sql: "SELECT is_withdrawn,media_ids FROM v2_message_projections WHERE room_id=? AND message_id=?", arguments: [message.roomID.rawValue,message.messageID.rawValue]) {
                guard row["is_withdrawn"] as Bool == false,
                      try GRDBV2LocalSyncStore.decodeMedia(row["media_ids"]).contains(where: { $0.mediaID == mediaID }) else { throw V2ResourceStorageError.unavailable }
            }
        }
    }

    func beginPublication(id: V2LocalResourceFileID, checksum: V2ResourceChecksum, bytes: Int64,
                          retention: V2ResourceFileRetention, storage: V2ResourceFileStorage = .persistent,
                          publicationClass: V2ResourceFileRetention, policy: V2ResourceStoragePolicy,
                          reservation: UUID? = nil, now: Date) throws {
        guard bytes > 0, now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else {
            throw V2ResourceStorageError.invalidRecord
        }
        try databasePool.write { db in
            let reserved = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(MAX(byte_count,allocated_bytes)),0) FROM v2_resource_files WHERE state<>'missing'") ?? 0
            let credit = try reservation.map { try Self.publicationCredit($0, bytes: bytes, db: db) } ?? 0
            let temporary = try Self.temporaryReservedBytes(db: db)
            let addition = bytes - credit
            if addition > 0, let maximum = policy.maximumManagedBytes {
                guard addition <= maximum, temporary <= maximum - addition, reserved <= maximum - addition - temporary else { throw V2ResourceStorageError.capacityExceeded }
            }
            let category = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(MAX(byte_count,allocated_bytes)),0) FROM v2_resource_files WHERE state<>'missing' AND CASE WHEN state='publishing' THEN publication_class ELSE retention END=?", arguments: [publicationClass.rawValue]) ?? 0
            let limit: Int64?
            switch publicationClass { case .cache: limit = policy.maximumCacheBytes; case .original: limit = policy.maximumOriginalBytes; case .retained: limit = nil }
            if let limit { guard bytes <= limit, category <= limit - bytes else { throw V2ResourceStorageError.capacityExceeded } }
            if let reservation {
                // Transfer the held future-copy credit to the file row in the
                // same transaction. No gap and no double charging the peak.
                try db.execute(sql: "UPDATE v2_resource_transfer_staging SET publication_bytes=0 WHERE staging_id=?", arguments: [reservation.uuidString])
            }
            try db.execute(sql: """
                INSERT INTO v2_resource_files(file_id,checksum,byte_count,allocated_bytes,retention,publication_class,storage,state,last_access_at)
                VALUES(?,?,?,0,?,?,?,'publishing',?)
                """, arguments: [id.value.uuidString, checksum.value, bytes, retention.rawValue, publicationClass.rawValue, storage.rawValue, now.timeIntervalSince1970])
            try db.execute(sql: "INSERT INTO v2_resource_file_operations(file_id,kind) VALUES(?,'publish')", arguments: [id.value.uuidString])
        }
    }

    func finishPublication(_ id: V2LocalResourceFileID, allocatedBytes: Int64) throws {
        guard allocatedBytes >= 0 else { throw V2ResourceStorageError.invalidRecord }
        try databasePool.write { db in
            let publication = try Row.fetchOne(db, sql: "SELECT publication_class,checksum,byte_count FROM v2_resource_files WHERE file_id=? AND state='publishing'", arguments: [id.value.uuidString])
            // Adopt verified bytes even if allocation rounding or a lower new
            // policy creates an overage. Recovery must not strand the only good
            // original; subsequent admissions account for the measured debt.
            try db.execute(sql: "UPDATE v2_resource_files SET state='published',allocated_bytes=?,publication_class=NULL WHERE file_id=? AND state='publishing'", arguments: [allocatedBytes,id.value.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceStorageError.conflict }
            try db.execute(sql: "DELETE FROM v2_resource_file_operations WHERE file_id=? AND kind='publish'", arguments: [id.value.uuidString])
            switch try String.fetchOne(db, sql: "SELECT retention FROM v2_resource_files WHERE file_id=?", arguments: [id.value.uuidString]) {
            case "original":
                try db.execute(sql: "INSERT INTO v2_resource_file_consumers(consumer_id,file_id,kind) VALUES(?,?,'manualOriginal')",
                    arguments: [id.value.uuidString,id.value.uuidString])
            case "retained":
                try db.execute(sql: "INSERT INTO v2_resource_file_pins(file_id) VALUES(?)", arguments: [id.value.uuidString])
            default: break
            }
            if let publication, publication["publication_class"] as String? == "retained" {
                // Recovery performs the same logical handoff as a live
                // download. Never expose retained publication as disposable
                // cache between finalization and variant binding.
                try Self.bindRetainedBytes(fileID: id, checksum: .init(value: publication["checksum"]),
                    byteCount: publication["byte_count"], db: db)
            }
        }
    }

    func accountID() throws -> UserID {
        try databasePool.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") else {
                throw V2ResourceStorageError.invalidRecord
            }
            return try UserID(value)
        }
    }

    func discardUnpublished(_ id: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM v2_resource_files WHERE file_id=?", arguments: [id.value.uuidString]) == "publishing" else {
                throw V2ResourceStorageError.conflict
            }
            try db.execute(sql: "DELETE FROM v2_resource_file_operations WHERE file_id=?", arguments: [id.value.uuidString])
            try db.execute(sql: "DELETE FROM v2_resource_files WHERE file_id=?", arguments: [id.value.uuidString])
        }
    }

    public func addConsumer(_ consumerID: UUID, fileID: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM v2_resource_files WHERE file_id=?", arguments: [fileID.value.uuidString]) == "published" else {
                throw V2ResourceStorageError.unavailable
            }
            try db.execute(sql: "INSERT OR IGNORE INTO v2_resource_file_consumers(consumer_id,file_id,kind) VALUES(?,?,'hold')", arguments: [consumerID.uuidString,fileID.value.uuidString])
        }
    }

    public func removeConsumer(_ consumerID: UUID, fileID: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            try db.execute(sql: "DELETE FROM v2_resource_file_consumers WHERE consumer_id=? AND file_id=? AND kind='hold'", arguments: [consumerID.uuidString,fileID.value.uuidString])
        }
    }

    func hasConsumers(_ id: V2LocalResourceFileID) throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_file_consumers WHERE file_id=?)", arguments: [id.value.uuidString]) ?? false
        }
    }

    func beginDeletion(_ id: V2LocalResourceFileID) throws -> Bool {
        try databasePool.write { db in
            try db.execute(sql: """
                UPDATE v2_resource_files SET state='retiring' WHERE file_id=? AND state IN ('published','invalid','missing') AND retention='cache'
                AND NOT EXISTS(SELECT 1 FROM v2_resource_file_consumers WHERE file_id=?)
                """, arguments: [id.value.uuidString,id.value.uuidString])
            guard db.changesCount == 1 else { return false }
            try db.execute(sql: "INSERT INTO v2_resource_file_operations(file_id,kind) VALUES(?,'delete') ON CONFLICT(file_id) DO UPDATE SET kind='delete',source_storage=NULL,target_storage=NULL", arguments: [id.value.uuidString])
            return true
        }
    }

    func finishDeletion(_ id: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM v2_resource_files WHERE file_id=?", arguments: [id.value.uuidString]) == "retiring" else {
                throw V2ResourceStorageError.conflict
            }
            try db.execute(sql: "DELETE FROM v2_resource_file_operations WHERE file_id=?", arguments: [id.value.uuidString])
            try db.execute(sql: "DELETE FROM v2_resource_files WHERE file_id=?", arguments: [id.value.uuidString])
        }
    }

    func setRetention(_ retention: V2ResourceFileRetention, id: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT state IN ('published','invalid','missing') FROM v2_resource_files WHERE file_id=?", arguments: [id.value.uuidString]) == true else { throw V2ResourceStorageError.unavailable }
            switch retention {
            case .original:
                try db.execute(sql: "INSERT OR IGNORE INTO v2_resource_file_consumers(consumer_id,file_id,kind) VALUES(?,?,'manualOriginal')", arguments: [id.value.uuidString,id.value.uuidString])
            case .retained:
                try db.execute(sql: "INSERT OR IGNORE INTO v2_resource_file_pins(file_id) VALUES(?)", arguments: [id.value.uuidString])
            case .cache:
                try db.execute(sql: "DELETE FROM v2_resource_file_pins WHERE file_id=?", arguments: [id.value.uuidString])
            }
            try Self.refreshRetention(id, db: db)
        }
    }

    static func refreshRetention(_ id: V2LocalResourceFileID, db: Database) throws {
        try db.execute(sql: """
            UPDATE v2_resource_files SET retention=CASE
                WHEN EXISTS(SELECT 1 FROM v2_resource_file_consumers WHERE file_id=? AND kind<>'hold') THEN 'original'
                WHEN EXISTS(SELECT 1 FROM v2_resource_file_pins WHERE file_id=?) OR EXISTS(
                    SELECT 1 FROM v2_resource_variants v JOIN v2_resource_retention_intents p
                    USING(home_kind,home_id,media_id,variant_kind,variant_id,version) WHERE v.file_id=?) THEN 'retained' ELSE 'cache' END
            WHERE file_id=?
            """, arguments: [id.value.uuidString,id.value.uuidString,id.value.uuidString,id.value.uuidString])
    }

    func touch(_ id: V2LocalResourceFileID, now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw V2ResourceStorageError.invalidRecord }
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_files SET last_access_at=? WHERE file_id=? AND state='published'", arguments: [now.timeIntervalSince1970,id.value.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceStorageError.unavailable }
        }
    }

    func markMissing(_ id: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_files SET state='missing',allocated_bytes=0 WHERE file_id=? AND state='published'", arguments: [id.value.uuidString])
        }
    }

    func markInvalid(_ id: V2LocalResourceFileID, allocatedBytes: Int64) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_files SET state='invalid',allocated_bytes=? WHERE file_id=? AND state IN ('published','publishing')",
                arguments: [allocatedBytes,id.value.uuidString])
            try db.execute(sql: "DELETE FROM v2_resource_file_operations WHERE file_id=? AND kind='publish'", arguments: [id.value.uuidString])
        }
    }

    private static let fileSelectSQL = """
        SELECT f.*,(EXISTS(SELECT 1 FROM v2_resource_file_pins p WHERE p.file_id=f.file_id) OR EXISTS(
            SELECT 1 FROM v2_resource_variants v JOIN v2_resource_retention_intents p
            USING(home_kind,home_id,media_id,variant_kind,variant_id,version) WHERE v.file_id=f.file_id)) AS is_pinned
        FROM v2_resource_files f
        """

    private static func decode(_ row: Row) throws -> V2ResourceFileRecord {
        guard let uuid = UUID(uuidString: row["file_id"]),
              let retention = V2ResourceFileRetention(rawValue: row["retention"]),
              let storage = V2ResourceFileStorage(rawValue: row["storage"]),
              let state = V2ResourceFileState(rawValue: row["state"]) else { throw V2ResourceStorageError.invalidRecord }
        return .init(id: .init(uuid), checksum: try .init(value: row["checksum"]), byteCount: row["byte_count"],
                     allocatedBytes: row["allocated_bytes"], retention: retention, storage: storage, isPinned: row["is_pinned"], state: state,
                     lastAccessAt: Date(timeIntervalSince1970: row["last_access_at"]))
    }
}
