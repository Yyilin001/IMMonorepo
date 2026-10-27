import Foundation
import GRDB
import IMV2Core

public struct V2ResourceDirectoryScan: Equatable, Sendable {
    public let id: UUID
    public let roomID: RoomID
    public let query: V2RoomResourceQuery
    public let hasPage: Bool
    public let snapshotUpperRoomSequence: UInt64?
    let accessGeneration: Data
}

extension GRDBV2LocalSyncStore {
    static let resourceQueryCheckpointSchemaSQL = """
        CREATE TABLE v2_resource_access_generation(singleton INTEGER PRIMARY KEY CHECK(singleton=1),token BLOB NOT NULL CHECK(length(token)=16));
        INSERT INTO v2_resource_access_generation VALUES(1,randomblob(16));
        CREATE TABLE v2_resource_room_denials(room_id TEXT PRIMARY KEY);
        CREATE TABLE v2_resource_query_checkpoints(
            room_id TEXT NOT NULL, category TEXT NOT NULL,
            before_date INTEGER NOT NULL, after_date INTEGER NOT NULL,
            scan_id TEXT NOT NULL UNIQUE, page_limit INTEGER NOT NULL CHECK(page_limit BETWEEN 1 AND 100),
            has_page INTEGER NOT NULL CHECK(has_page IN (0,1)),
            access_generation BLOB NOT NULL CHECK(length(access_generation)=16),
            snapshot_upper INTEGER CHECK(snapshot_upper>=0), next_cursor TEXT,
            CHECK((has_page=0 AND snapshot_upper IS NULL) OR (has_page=1 AND snapshot_upper IS NOT NULL)),
            PRIMARY KEY(room_id,category,before_date,after_date)
        );
        \(resourceAccessGenerationTriggersSQL)
        """

    /// Only live tables carry these triggers. Snapshot shadows remain invisible
    /// until v2_snapshots flips; that one row rotates the request generation.
    private static let resourceAccessGenerationTriggersSQL: String = {
        let tables = ["v2_room_membership_states", "v2_room_event_authorizations", "v2_message_tombstones", "v2_user_block_projections", "v2_snapshots"]
        var statements = tables.flatMap { table in
            ["INSERT","UPDATE","DELETE"].map { operation in
                "CREATE TRIGGER resource_access_\(table)_\(operation.lowercased()) AFTER \(operation) ON \(table) BEGIN UPDATE v2_resource_access_generation SET token=randomblob(16) WHERE singleton=1; END;"
            }
        }
        statements.append("""
            CREATE TRIGGER resource_access_message_revision AFTER UPDATE OF message_revision,is_withdrawn,media_ids ON v2_message_projections
            WHEN NEW.message_revision<>OLD.message_revision OR NEW.is_withdrawn<>OLD.is_withdrawn OR NEW.media_ids<>OLD.media_ids
            BEGIN UPDATE v2_resource_access_generation SET token=randomblob(16) WHERE singleton=1; END;
            """)
        return statements.joined(separator: "\n")
    }()

    public func beginResourceDirectoryScan(roomID: RoomID, query: V2RoomResourceQuery) throws -> V2ResourceDirectoryScan {
        guard query.cursor == nil else { throw V2ResourceStorageError.invalidRecord }
        let id = UUID()
        return try databasePool.write { db in
            guard let access = try Data.fetchOne(db, sql: "SELECT token FROM v2_resource_access_generation WHERE singleton=1") else { throw V2ResourceStorageError.invalidRecord }
            try db.execute(sql: """
                INSERT INTO v2_resource_query_checkpoints(room_id,category,before_date,after_date,scan_id,page_limit,has_page,snapshot_upper,next_cursor,access_generation)
                VALUES(?,?,?,?,?,?,0,NULL,NULL,?) ON CONFLICT(room_id,category,before_date,after_date) DO UPDATE SET
                    scan_id=excluded.scan_id,page_limit=excluded.page_limit,has_page=0,snapshot_upper=NULL,next_cursor=NULL,access_generation=excluded.access_generation
                """, arguments: [roomID.rawValue,query.category.rawValue,query.before ?? -1,query.after ?? -1,id.uuidString,query.limit,access])
            return .init(id: id, roomID: roomID, query: query, hasPage: false, snapshotUpperRoomSequence: nil, accessGeneration: access)
        }
    }

    public func resourceDirectoryScan(roomID: RoomID, category: V2ResourceCategory = .all,
                                       before: Int64? = nil, after: Int64? = nil) throws -> V2ResourceDirectoryScan? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_query_checkpoints WHERE room_id=? AND category=? AND before_date=? AND after_date=? AND access_generation=(SELECT token FROM v2_resource_access_generation WHERE singleton=1)",
                arguments: [roomID.rawValue,category.rawValue,before ?? -1,after ?? -1]) else { return nil }
            return try Self.decodeResourceScan(row)
        }
    }

    /// A late page cannot overwrite a newer scan or a page already consumed.
    /// Metadata, bindings and continuation advance in the same account commit.
    public func applyResourceDirectoryPage(_ page: V2RoomResourcePage, to scan: V2ResourceDirectoryScan) throws {
        try Task.checkCancellation()
        guard page.items.count <= scan.query.limit,
              page.nextCursor.map({ $0 != scan.query.cursor }) ?? true,
              scan.snapshotUpperRoomSequence.map({ $0 == page.snapshotUpperRoomSequence }) ?? true,
              page.items.allSatisfy({ item in
                  item.descriptor.key.home == .room(scan.roomID) && item.descriptor.state == .ready
                  && scan.query.category.includes(contentType: item.descriptor.contentType)
                  && (scan.query.before.map({ item.createdAt < $0 }) ?? true)
                  && (scan.query.after.map({ item.createdAt > $0 }) ?? true)
              }) else { throw V2ResourceStorageError.invalidRecord }
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_query_checkpoints WHERE scan_id=? AND access_generation=(SELECT token FROM v2_resource_access_generation WHERE singleton=1)", arguments: [scan.id.uuidString]),
                  try Self.decodeResourceScan(row) == scan else { throw V2ResourceStorageError.conflict }
            guard !scan.hasPage || scan.query.cursor != nil else { throw V2ResourceStorageError.conflict }
            try db.execute(sql: "DELETE FROM v2_resource_room_denials WHERE room_id=?", arguments: [scan.roomID.rawValue])
            for item in page.items {
                try Self.indexResource(item.descriptor, reference: .message(.init(roomID: scan.roomID, messageID: item.messageID), ordinal: item.position.ordinal),
                    businessRevision: Int64(item.messageRevision), now: Date(timeIntervalSince1970: Double(item.createdAt)/1000), db: db)
            }
            try db.execute(sql: "UPDATE v2_resource_query_checkpoints SET has_page=1,snapshot_upper=?,next_cursor=? WHERE scan_id=?",
                arguments: [Int64(page.snapshotUpperRoomSequence),page.nextCursor,scan.id.uuidString])
        }
    }

    func denyResourceDirectory(scan: V2ResourceDirectoryScan) throws {
        try Task.checkCancellation()
        try databasePool.write { db in
            guard try Data.fetchOne(db, sql: "SELECT token FROM v2_resource_access_generation WHERE singleton=1") == scan.accessGeneration,
                  try String.fetchOne(db, sql: "SELECT scan_id FROM v2_resource_query_checkpoints WHERE room_id=? AND category=? AND before_date=? AND after_date=?",
                    arguments: [scan.roomID.rawValue,scan.query.category.rawValue,scan.query.before ?? -1,scan.query.after ?? -1]) == scan.id.uuidString else { throw V2ResourceStorageError.conflict }
            try db.execute(sql: "INSERT OR IGNORE INTO v2_resource_room_denials(room_id) VALUES(?)", arguments: [scan.roomID.rawValue])
            // All pre-denial responses lose admission, including other filters.
            try db.execute(sql: "UPDATE v2_resource_access_generation SET token=randomblob(16) WHERE singleton=1")
        }
    }

    private static func decodeResourceScan(_ row: Row) throws -> V2ResourceDirectoryScan {
        guard let id = UUID(uuidString: row["scan_id"]), let category = V2ResourceCategory(rawValue: row["category"]) else { throw V2ResourceStorageError.invalidRecord }
        let before: Int64 = row["before_date"], after: Int64 = row["after_date"], upper: Int64? = row["snapshot_upper"]
        return try .init(id: id, roomID: .init(row["room_id"]),
            query: .init(category: category, limit: row["page_limit"], cursor: row["next_cursor"], before: before == -1 ? nil : before, after: after == -1 ? nil : after),
            hasPage: row["has_page"], snapshotUpperRoomSequence: upper.map(UInt64.init), accessGeneration: row["access_generation"])
    }
}
