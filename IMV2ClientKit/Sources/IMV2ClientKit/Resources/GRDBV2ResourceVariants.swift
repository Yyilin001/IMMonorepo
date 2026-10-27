import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let resourceVariantSchemaSQL = """
        CREATE TABLE v2_resource_variants (
            home_kind TEXT NOT NULL CHECK(home_kind IN ('account','room')), home_id TEXT NOT NULL, media_id TEXT NOT NULL,
            variant_kind TEXT NOT NULL CHECK(variant_kind IN ('original','derived')), variant_id TEXT NOT NULL,
            version INTEGER NOT NULL CHECK(version>0), checksum TEXT NOT NULL CHECK(length(checksum)=64),
            byte_count INTEGER NOT NULL CHECK(byte_count>0),
            file_id TEXT REFERENCES v2_resource_files(file_id) ON DELETE SET NULL,
            CHECK((variant_kind='original' AND variant_id='' AND version=1) OR (variant_kind='derived' AND length(variant_id)>0)),
            PRIMARY KEY(home_kind,home_id,media_id,variant_kind,variant_id,version)
        );
        CREATE INDEX v2_resource_variants_file ON v2_resource_variants(file_id);
        CREATE INDEX v2_resource_variants_bytes ON v2_resource_variants(checksum,byte_count);
        CREATE TABLE v2_resource_retention_intents (
            home_kind TEXT NOT NULL,home_id TEXT NOT NULL,media_id TEXT NOT NULL,
            variant_kind TEXT NOT NULL,variant_id TEXT NOT NULL,version INTEGER NOT NULL,intent_id TEXT NOT NULL CHECK(length(intent_id)=36),retained_at REAL NOT NULL CHECK(retained_at>=0),
            PRIMARY KEY(home_kind,home_id,media_id,variant_kind,variant_id,version),
            FOREIGN KEY(home_kind,home_id,media_id,variant_kind,variant_id,version)
                REFERENCES v2_resource_variants(home_kind,home_id,media_id,variant_kind,variant_id,version)
        );
        """

    static func indexResourceVariant(_ descriptor: V2ResourceVariantDescriptor, db: Database) throws {
        if let existing = try V2ResourceFileJournal.variant(descriptor.key, db: db) {
            guard existing.descriptor == descriptor else { throw V2ResourceStorageError.conflict }
            return
        }
        var arguments = V2ResourceFileJournal.variantArguments(descriptor.key)
        arguments += [descriptor.checksum.value, descriptor.byteCount]
        try db.execute(sql: """
            INSERT INTO v2_resource_variants(home_kind,home_id,media_id,variant_kind,variant_id,version,checksum,byte_count)
            VALUES(?,?,?,?,?,?,?,?)
            """, arguments: arguments)
    }

    static func bindResourceVariant(_ descriptor: V2ResourceVariantDescriptor, fileID: V2LocalResourceFileID, db: Database) throws {
        try indexResourceVariant(descriptor, db: db)
        guard try Bool.fetchOne(db, sql: "SELECT state='published' AND checksum=? AND byte_count=? FROM v2_resource_files WHERE file_id=?",
            arguments: [descriptor.checksum.value,descriptor.byteCount,fileID.value.uuidString]) == true else { throw V2ResourceStorageError.unavailable }
        let previous = try V2ResourceFileJournal.variant(descriptor.key, db: db)?.fileID
        var arguments: StatementArguments = [fileID.value.uuidString]
        arguments += V2ResourceFileJournal.variantArguments(descriptor.key)
        try db.execute(sql: "UPDATE v2_resource_variants SET file_id=? WHERE \(V2ResourceFileJournal.variantPredicate)", arguments: arguments)
        if let previous, previous != fileID { try V2ResourceFileJournal.refreshRetention(previous, db: db) }
        try V2ResourceFileJournal.refreshRetention(fileID, db: db)
    }

    func resourceIsVisible(_ key: V2ResourceKey) throws -> Bool {
        try databasePool.read { try Self.resourceIsVisible(key, db: $0) }
    }

    static func resourceIsVisible(_ key: V2ResourceKey, db: Database) throws -> Bool {
        let home = Self.resourceHomeColumns(key.home)
        return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM v2_resource_references r WHERE r.home_kind=? AND r.home_id=? AND r.media_id=?
                    AND \(Self.visibleResourceMessageReferenceSQL))
                """, arguments: [home.kind,home.id,key.mediaID.rawValue]) ?? false
    }
}

extension V2ResourceFileJournal {
    func unavailableRetentionSelections() throws -> (values: [V2ResourceRetentionSelection], hasMore: Bool) {
        try databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT v.*, 1 AS is_retained, p.intent_id FROM v2_resource_retention_intents p
                JOIN v2_resource_variants v USING(home_kind,home_id,media_id,variant_kind,variant_id,version)
                WHERE NOT EXISTS(SELECT 1 FROM v2_resource_references r
                    WHERE r.home_kind=v.home_kind AND r.home_id=v.home_id AND r.media_id=v.media_id
                    AND \(GRDBV2LocalSyncStore.visibleResourceMessageReferenceSQL))
                ORDER BY p.retained_at,p.home_kind,p.home_id,p.media_id,p.variant_kind,p.variant_id,p.version LIMIT 101
                """)
            return (try rows.prefix(100).map { row in
                guard let intent = UUID(uuidString: row["intent_id"]) else { throw V2ResourceStorageError.invalidRecord }
                return V2ResourceRetentionSelection(key: try Self.decodeVariant(row).descriptor.key, intentID: intent)
            }, rows.count > 100)
        }
    }

    func releaseUnavailableRetention(_ selections: [V2ResourceRetentionSelection]) throws -> V2ResourceUnavailableRetentionResult {
        try databasePool.write { db in
            var released = 0
            for selection in selections {
                try Task.checkCancellation()
                // Authorization, unchanged user intent and removal share the
                // same writer transaction. A newly accessible source wins.
                guard try !GRDBV2LocalSyncStore.resourceIsVisible(selection.key.resource, db: db),
                      let record = try Self.variant(selection.key, db: db) else { continue }
                var arguments = Self.variantArguments(selection.key)
                arguments += [selection.intentID.uuidString]
                try db.execute(sql: "DELETE FROM v2_resource_retention_intents WHERE \(Self.variantPredicate) AND intent_id=?", arguments: arguments)
                if db.changesCount > 0 {
                    released += 1
                    if let file = record.fileID { try Self.refreshRetention(file, db: db) }
                }
            }
            return .init(releasedCount: released, skippedCount: selections.count - released)
        }
    }

    private static let retainedBytesPredicate = """
        v.checksum=? AND v.byte_count=? AND EXISTS(SELECT 1 FROM v2_resource_retention_intents p
            WHERE (p.home_kind,p.home_id,p.media_id,p.variant_kind,p.variant_id,p.version)
                =(v.home_kind,v.home_id,v.media_id,v.variant_kind,v.variant_id,v.version))
        """

    func hasRetainedBytes(checksum: V2ResourceChecksum, byteCount: Int64) throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_variants v WHERE \(Self.retainedBytesPredicate))", arguments: [checksum.value,byteCount]) ?? false
        }
    }

    /// This establishes byte availability for existing immutable facts, never
    /// an access grant or a server-side resource import. Every reader still
    /// authorizes its own home/context before obtaining a file lease.
    func bindRetainedBytes(fileID: V2LocalResourceFileID, checksum: V2ResourceChecksum, byteCount: Int64) throws {
        try databasePool.write { try Self.bindRetainedBytes(fileID: fileID, checksum: checksum, byteCount: byteCount, db: $0) }
    }

    static func bindRetainedBytes(fileID: V2LocalResourceFileID, checksum: V2ResourceChecksum, byteCount: Int64, db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT state='published' AND checksum=? AND byte_count=? FROM v2_resource_files WHERE file_id=?",
            arguments: [checksum.value,byteCount,fileID.value.uuidString]) == true else { throw V2ResourceStorageError.unavailable }
        let previous = try String.fetchAll(db, sql: "SELECT DISTINCT file_id FROM v2_resource_variants v WHERE file_id IS NOT NULL AND \(Self.retainedBytesPredicate)", arguments: [checksum.value,byteCount])
        try db.execute(sql: "UPDATE v2_resource_variants AS v SET file_id=? WHERE \(Self.retainedBytesPredicate)", arguments: [fileID.value.uuidString,checksum.value,byteCount])
        for raw in previous {
            guard let id = UUID(uuidString: raw) else { throw V2ResourceStorageError.invalidRecord }
            if id != fileID.value { try Self.refreshRetention(.init(id), db: db) }
        }
        try Self.refreshRetention(fileID, db: db)
    }

    static let variantPredicate = "home_kind=? AND home_id=? AND media_id=? AND variant_kind=? AND variant_id=? AND version=?"
    private static let variantSelect = """
        SELECT v.*,EXISTS(SELECT 1 FROM v2_resource_retention_intents p
            WHERE (p.home_kind,p.home_id,p.media_id,p.variant_kind,p.variant_id,p.version)
                =(v.home_kind,v.home_id,v.media_id,v.variant_kind,v.variant_id,v.version)) AS is_retained
        FROM v2_resource_variants v
        """

    static func variantArguments(_ key: V2ResourceVariantKey) -> StatementArguments {
        let home = GRDBV2LocalSyncStore.resourceHomeColumns(key.resource.home)
        switch key.rendition {
        case .original: return [home.kind,home.id,key.resource.mediaID.rawValue,"original","",1]
        case .derived(let id, let version): return [home.kind,home.id,key.resource.mediaID.rawValue,"derived",id.rawValue,version.value]
        }
    }

    static func variant(_ key: V2ResourceVariantKey, db: Database) throws -> V2ResourceVariantRecord? {
        try Row.fetchOne(db, sql: variantSelect + " WHERE " + variantPredicate, arguments: variantArguments(key)).map(decodeVariant)
    }

    func variant(_ key: V2ResourceVariantKey) throws -> V2ResourceVariantRecord? {
        try databasePool.read { try Self.variant(key, db: $0) }
    }

    /// Cleanup must cover all indexed versions, not the bounded detail page.
    func cleanupFileIDs(for resource: V2ResourceKey) throws -> [V2LocalResourceFileID] {
        let home = GRDBV2LocalSyncStore.resourceHomeColumns(resource.home)
        return try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT file_id FROM v2_resource_variants WHERE home_kind=? AND home_id=? AND media_id=? AND file_id IS NOT NULL",
                arguments: [home.kind, home.id, resource.mediaID.rawValue]).map { raw in
                    guard let id = UUID(uuidString: raw) else { throw V2ResourceStorageError.invalidRecord }
                    return V2LocalResourceFileID(id)
                }
        }
    }

    func variants(for resource: V2ResourceKey) throws -> [V2ResourceVariantRecord] {
        let home = GRDBV2LocalSyncStore.resourceHomeColumns(resource.home)
        return try databasePool.read { db in
            try Row.fetchAll(db, sql: Self.variantSelect + " WHERE home_kind=? AND home_id=? AND media_id=? ORDER BY CASE WHEN variant_kind='original' THEN 0 ELSE 1 END,variant_id,version DESC LIMIT 128",
                arguments: [home.kind,home.id,resource.mediaID.rawValue]).map(Self.decodeVariant)
        }
    }

    func setVariantRetained(_ retained: Bool, key: V2ResourceVariantKey, now: Date, binding: V2LocalResourceFileID? = nil) throws {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw V2ResourceStorageError.invalidRecord }
        try databasePool.write { db in
            guard let record = try Self.variant(key, db: db) else { throw V2ResourceStorageError.unavailable }
            // The center's preflight may precede a queued FileStore mutation.
            // New retention must share the authority check's write transaction;
            // releasing an existing intent remains valid after revocation.
            if retained, try !GRDBV2LocalSyncStore.resourceIsVisible(key.resource, db: db) {
                throw V2ResourceStorageError.unavailable
            }
            var arguments = Self.variantArguments(key)
            if retained {
                arguments += [UUID().uuidString, now.timeIntervalSince1970]
                try db.execute(sql: "INSERT OR IGNORE INTO v2_resource_retention_intents(home_kind,home_id,media_id,variant_kind,variant_id,version,intent_id,retained_at) VALUES(?,?,?,?,?,?,?,?)", arguments: arguments)
            } else {
                try db.execute(sql: "DELETE FROM v2_resource_retention_intents WHERE \(Self.variantPredicate)", arguments: arguments)
            }
            if let file = record.fileID { try Self.refreshRetention(file, db: db) }
            if retained, let binding {
                try Self.bindRetainedBytes(fileID: binding, checksum: record.descriptor.checksum,
                    byteCount: record.descriptor.byteCount, db: db)
            }
        }
    }

    private static func decodeVariant(_ row: Row) throws -> V2ResourceVariantRecord {
        let home: V2ResourceHome
        switch row["home_kind"] as String {
        case "account": home = .account(try .init(row["home_id"]))
        case "room": home = .room(try .init(row["home_id"]))
        default: throw V2ResourceStorageError.invalidRecord
        }
        let rendition: V2ResourceVariantKey.Rendition
        switch row["variant_kind"] as String {
        case "original":
            guard row["variant_id"] as String == "", row["version"] as Int64 == 1 else { throw V2ResourceStorageError.invalidRecord }
            rendition = .original
        case "derived": rendition = try .derived(id: .init(row["variant_id"]), version: .init(row["version"]))
        default: throw V2ResourceStorageError.invalidRecord
        }
        let file: V2LocalResourceFileID?
        if let raw: String = row["file_id"] {
            guard let id = UUID(uuidString: raw) else { throw V2ResourceStorageError.invalidRecord }
            file = .init(id)
        } else { file = nil }
        return try .init(descriptor: .init(key: .init(resource: .init(home: home, mediaID: .init(row["media_id"])), rendition: rendition),
            checksum: .init(value: row["checksum"]), byteCount: row["byte_count"]), fileID: file, isRetained: row["is_retained"])
    }
}
