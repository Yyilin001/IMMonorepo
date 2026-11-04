import Foundation

enum Schema {
    static let version: Int64 = 4
    static func open(_ db: SQLiteConnection, configuration c: SearchConfiguration) throws {
        let version = try db.integer("PRAGMA user_version")
        guard version == 0 || version == Self.version else { throw SearchIndexError.incompatibleIndex }
        if version == 0 {
            guard try db.integer("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
                throw SearchIndexError.incompatibleIndex
            }
            try db.transaction {
                try db.execute("""
                    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE documents(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, group_id TEXT NOT NULL,
                      version INTEGER NOT NULL, timestamp INTEGER NOT NULL, kind TEXT NOT NULL, coverage TEXT NOT NULL,
                      hash BLOB NOT NULL);
                    CREATE INDEX document_group ON documents(group_id,version);
                    CREATE INDEX document_coverage ON documents(coverage);
                    CREATE INDEX document_order ON documents(timestamp DESC,id DESC);
                    CREATE TABLE fields(pk INTEGER PRIMARY KEY, document INTEGER NOT NULL REFERENCES documents(pk),
                      id TEXT NOT NULL, body TEXT NOT NULL, UNIQUE(document,id));
                    CREATE TABLE chunks(pk INTEGER PRIMARY KEY, field INTEGER NOT NULL REFERENCES fields(pk),
                      generation INTEGER NOT NULL, byte_start INTEGER NOT NULL, byte_count INTEGER NOT NULL, mode TEXT NOT NULL);
                    CREATE INDEX chunk_field ON chunks(field,generation);
                    CREATE INDEX chunk_generation ON chunks(generation,pk);
                    CREATE VIEW chunk_content AS SELECT c.pk,
                      search_tokens(f.body,c.byte_start,c.byte_count,c.mode) AS tokens
                      FROM chunks c JOIN fields f ON f.pk=c.field;
                    CREATE VIRTUAL TABLE chunk_fts USING fts5(tokens, content='chunk_content', content_rowid='pk',
                      tokenize='ascii', detail=full, columnsize=0);
                    CREATE TABLE tombstones(id TEXT PRIMARY KEY, version INTEGER NOT NULL);
                    CREATE TABLE group_epochs(id TEXT PRIMARY KEY, version INTEGER NOT NULL);
                    CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, hash BLOB NOT NULL,
                      bytes INTEGER NOT NULL, state INTEGER NOT NULL DEFAULT 0,
                      accepted REAL NOT NULL, error TEXT NOT NULL DEFAULT '');
                    CREATE INDEX events_pending ON events(state,seq);
                    CREATE TABLE event_payloads(seq INTEGER PRIMARY KEY REFERENCES events(seq), payload TEXT NOT NULL);
                    CREATE TABLE checkpoints(seq INTEGER PRIMARY KEY, cursor TEXT NOT NULL);
                    PRAGMA user_version=4;
                    """)
                for (key, value) in ["scope": c.scopeID, "epoch": c.sourceEpoch, "store": UUID().uuidString,
                    "mode": c.mode.rawValue, "tokenizer": CharacterTokenizer.version, "generation": "1",
                    "building": "0", "buildingMode": c.mode.rawValue, "rebuildCursor": "0", "indexed": "0", "acceptedCursor": "", "indexedCursor": "",
                    "chunk": String(c.chunkCharacters), "queryLimit": String(c.maximumQueryCharacters),
                    "visibleDocuments": "0", "previewDocuments": "0", "sourceCoverage": ""] {
                    try db.setMeta(key, value)
                }
            }
        }
        guard try db.meta("scope") == c.scopeID, try db.meta("epoch") == c.sourceEpoch,
              try (c.useStoredTextMode || db.meta("mode") == c.mode.rawValue), try db.meta("tokenizer") == CharacterTokenizer.version,
              try db.meta("chunk") == String(c.chunkCharacters), try db.meta("queryLimit") == String(c.maximumQueryCharacters) else {
            throw SearchIndexError.incompatibleIndex
        }
        guard try db.string("PRAGMA journal_mode=WAL") == "wal" else { throw SearchIndexError.unsupportedCapability("WAL") }
        try db.execute("PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=1000")
        // 不依赖 compile_options 猜测能力：在实际链接的 SQLite 上执行位置匹配探针。
        try db.execute("CREATE VIRTUAL TABLE temp.capability_probe USING fts5(tokens,tokenize='ascii',detail=full)")
        defer { try? db.execute("DROP TABLE temp.capability_probe") }
        try db.run("INSERT INTO temp.capability_probe VALUES(?)", [.text("x61 x62 x63")])
        guard try db.integer("SELECT count(*) FROM temp.capability_probe WHERE capability_probe MATCH ?", [.text("\"x62 x63\"")]) == 1 else {
            throw SearchIndexError.unsupportedCapability("FTS5 phrase positions")
        }
    }
}

func readStatus(_ db: SQLiteConnection, path: String) throws -> IndexStatus {
    let pending = try db.integer("SELECT count(*) FROM events WHERE state=0")
    let age = try db.string("SELECT CAST(min(accepted) AS TEXT) FROM events WHERE state=0")
    func bytes(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    let coverageJSON = try db.meta("sourceCoverage")
    let sourceCoverage: SourceCoverage = coverageJSON.isEmpty ? .unknown : try JSONDecoder().decode(SourceCoverage.self, from: Data(coverageJSON.utf8))
    guard let mode = SearchTextMode(rawValue: try db.meta("mode")) else { throw SearchIndexError.incompatibleIndex }
    return try IndexStatus(sourceCoverage: sourceCoverage, textMode: mode, documentCount: Int64(db.meta("visibleDocuments")) ?? 0,
        previewOnlyCount: Int64(db.meta("previewDocuments")) ?? 0,
        pendingCount: pending, pendingBytes: db.integer("SELECT coalesce(sum(bytes),0) FROM events WHERE state IN (0,2)"),
        failedCount: db.integer("SELECT count(*) FROM events WHERE state=2"),
        oldestPendingSeconds: Double(age).map { max(0, Date().timeIntervalSince1970 - $0) } ?? 0,
        acceptedSequence: db.integer("SELECT coalesce(max(seq),0) FROM events"),
        indexedSequence: Int64(db.meta("indexed")) ?? 0, acceptedSourceCheckpoint: db.meta("acceptedCursor"),
        indexedSourceCheckpoint: db.meta("indexedCursor"), generation: Int64(db.meta("generation")) ?? 1,
        rebuilding: db.meta("building") != "0", databaseBytes: bytes(path), walBytes: bytes(path + "-wal"))
}
