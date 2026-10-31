import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let localResourceAssetSchemaSQL = """
        CREATE TABLE v2_resource_local_assets(
            asset_id TEXT PRIMARY KEY,planned_file_id TEXT NOT NULL UNIQUE,
            file_id TEXT REFERENCES v2_resource_files(file_id) ON DELETE SET NULL,
            display_name TEXT NOT NULL,content_type TEXT NOT NULL,
            byte_count INTEGER NOT NULL CHECK(byte_count>0),checksum TEXT NOT NULL CHECK(length(checksum)=64),
            purpose TEXT NOT NULL CHECK(purpose IN ('messageDraft','personalAvatar','groupAvatar')),room_id TEXT,
            state TEXT NOT NULL CHECK(state IN ('importing','published','unavailable')),
            selection_active INTEGER NOT NULL CHECK(selection_active IN (0,1)),created_at REAL NOT NULL CHECK(created_at>=0),
            pixel_width INTEGER,pixel_height INTEGER,
            CHECK ((pixel_width IS NULL AND pixel_height IS NULL) OR
                   (pixel_width BETWEEN 1 AND 16384 AND pixel_height BETWEEN 1 AND 16384
                    AND pixel_width IS NOT NULL AND pixel_height IS NOT NULL
                    AND pixel_width * pixel_height <= 40000000)),
            CHECK((purpose='personalAvatar' AND room_id IS NULL) OR (purpose<>'personalAvatar' AND room_id IS NOT NULL))
        );
        CREATE INDEX v2_resource_local_assets_selection ON v2_resource_local_assets(purpose,room_id,created_at,asset_id) WHERE selection_active=1;
        CREATE INDEX v2_resource_local_assets_file ON v2_resource_local_assets(file_id);
        """

    /// Integrates into the caller's send/avatar transaction. A source cannot be
    /// admitted after its draft was discarded or its physical file retired.
    static func bindLocalResourceAsset(_ id: V2LocalResourceAssetID, consumer: V2LocalResourceOriginalConsumer,
                                      adoptingFrom origin: V2LocalResourceOriginalConsumer? = nil, relinquishSelection: Bool, db: Database) throws -> V2LocalResourceFileID {
        guard let asset = try V2ResourceFileJournal.readAsset(id, db: db), asset.availability == .local,
              let file = asset.fileID else { throw V2ResourceStorageError.unavailable }
        let alreadyBound = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_file_consumers WHERE consumer_id=? AND file_id=? AND kind=?)",
            arguments: [consumer.id.uuidString,file.value.uuidString,consumer.kind]) == true
        let inherited: Bool
        if let origin {
            inherited = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_file_consumers WHERE consumer_id=? AND file_id=? AND kind=?)",
                arguments: [origin.id.uuidString,file.value.uuidString,origin.kind]) == true
        } else { inherited = false }
        guard asset.selectionActive || alreadyBound || inherited else { throw V2ResourceStorageError.unavailable }
        try db.execute(sql: "INSERT OR IGNORE INTO v2_resource_file_consumers(consumer_id,file_id,kind) VALUES(?,?,?)",
            arguments: [consumer.id.uuidString,file.value.uuidString,consumer.kind])
        if relinquishSelection {
            try V2ResourceFileJournal.releaseAssetSelection(id, db: db)
        }
        try V2ResourceFileJournal.refreshRetention(file, db: db)
        return file
    }

    static func releaseLocalResourceAssetConsumer(_ id: V2LocalResourceAssetID, consumer: V2LocalResourceOriginalConsumer, db: Database) throws {
        guard let asset = try V2ResourceFileJournal.readAsset(id, db: db), let file = asset.fileID else { return }
        try db.execute(sql: "DELETE FROM v2_resource_file_consumers WHERE consumer_id=? AND file_id=? AND kind=?",
            arguments: [consumer.id.uuidString,file.value.uuidString,consumer.kind])
        try V2ResourceFileJournal.refreshRetention(file, db: db)
    }
}

extension V2ResourceFileJournal {
    func original(for context: V2LocalResourceReadContext) throws -> V2LocalResourceAsset {
        try databasePool.read { db in
            let assetID: V2LocalResourceAssetID
            let consumer: V2LocalResourceOriginalConsumer?
            switch context {
            case .selection(let id): assetID = id; consumer = nil
            case .upload(let id):
                guard let job = try GRDBV2LocalSyncStore.readResourceTransfer(id, db: db),
                      try Bool.fetchOne(db, sql: "SELECT source_released=0 FROM v2_resource_transfer_jobs WHERE job_id=?", arguments: [id.uuidString]) == true else { throw V2ResourceStorageError.unavailable }
                assetID = job.localAssetID; consumer = .upload(id)
            case .profileIntent(let id):
                guard let raw = try String.fetchOne(db, sql: "SELECT local_asset_id FROM v2_profile_intents WHERE intent_id=? AND source_released=0", arguments: [id.uuidString]),
                      let uuid = UUID(uuidString: raw) else { throw V2ResourceStorageError.unavailable }
                assetID = .init(uuid); consumer = .profileIntent(id)
            }
            guard let asset = try Self.readAsset(assetID, db: db), asset.availability == .local, let file = asset.fileID else { throw V2ResourceStorageError.unavailable }
            if let consumer {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_file_consumers WHERE consumer_id=? AND file_id=? AND kind=?)",
                    arguments: [consumer.id.uuidString,file.value.uuidString,consumer.kind]) == true else { throw V2ResourceStorageError.unavailable }
            } else { guard asset.selectionActive else { throw V2ResourceStorageError.unavailable } }
            return asset
        }
    }

    func localAsset(_ id: V2LocalResourceAssetID) throws -> V2LocalResourceAsset? {
        try databasePool.read { try Self.readAsset(id, db: $0) }
    }

    func selectedAssets(purpose: V2LocalResourceAssetPurpose) throws -> [V2LocalResourceAsset] {
        let context = Self.assetContext(purpose)
        return try databasePool.read { db in
            try Row.fetchAll(db, sql: Self.assetSelectSQL + " WHERE a.selection_active=1 AND a.purpose=? AND a.room_id IS ? ORDER BY a.created_at,a.asset_id",
                arguments: [context.kind,context.room]).map(Self.decodeAsset)
        }
    }

    func importingAssets() throws -> [V2LocalResourceAsset] {
        try databasePool.read { try Row.fetchAll($0, sql: Self.assetSelectSQL + " WHERE a.state='importing' ORDER BY a.created_at,a.asset_id").map(Self.decodeAsset) }
    }

    func beginAssetImport(id: V2LocalResourceAssetID, plannedFile: V2LocalResourceFileID, name: V2ResourceDisplayName,
                          contentType: V2ResourceContentType, bytes: Int64, checksum: V2ResourceChecksum,
                          purpose: V2LocalResourceAssetPurpose, imageDimensions: V2LocalResourceImageDimensions? = nil, maximumSelections: Int, now: Date) throws {
        guard bytes > 0, (1...256).contains(maximumSelections), now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw V2ResourceStorageError.invalidRecord }
        let context = Self.assetContext(purpose)
        try databasePool.write { db in
            if let existing = try Self.readAsset(id, db: db) {
                guard existing.displayName == name, existing.contentType == contentType, existing.byteCount == bytes,
                      existing.checksum == checksum, existing.purpose == purpose, existing.imageDimensions == imageDimensions, existing.selectionActive,
                      existing.availability != .unavailable else { throw V2ResourceStorageError.conflict }
                return
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_resource_local_assets WHERE selection_active=1") ?? 0
            guard count < maximumSelections else { throw V2ResourceStorageError.capacityExceeded }
            try db.execute(sql: """
                INSERT INTO v2_resource_local_assets(asset_id,planned_file_id,display_name,content_type,byte_count,checksum,purpose,room_id,state,selection_active,created_at,pixel_width,pixel_height)
                VALUES(?,?,?,?,?,?,?,?,'importing',1,?,?,?)
                """, arguments: [id.value.uuidString,plannedFile.value.uuidString,name.value,contentType.value,bytes,checksum.value,context.kind,context.room,now.timeIntervalSince1970,imageDimensions?.width,imageDimensions?.height])
        }
    }

    func finishAssetImport(_ id: V2LocalResourceAssetID, fileID: V2LocalResourceFileID) throws {
        try databasePool.write { db in
            guard let asset = try Self.readAsset(id, db: db),
                  try Bool.fetchOne(db, sql: "SELECT state='published' AND checksum=? AND byte_count=? FROM v2_resource_files WHERE file_id=?",
                    arguments: [asset.checksum.value,asset.byteCount,fileID.value.uuidString]) == true else { throw V2ResourceStorageError.unavailable }
            if asset.availability == .local {
                guard asset.fileID == fileID else { throw V2ResourceStorageError.conflict }
                return
            }
            try db.execute(sql: "UPDATE v2_resource_local_assets SET state='published',file_id=? WHERE asset_id=? AND state='importing'",
                arguments: [fileID.value.uuidString,id.value.uuidString])
            guard db.changesCount == 1 else { throw V2ResourceStorageError.conflict }
            if asset.selectionActive {
                try db.execute(sql: "INSERT OR IGNORE INTO v2_resource_file_consumers(consumer_id,file_id,kind) VALUES(?,?,'selection')",
                    arguments: [id.value.uuidString,fileID.value.uuidString])
            }
            try Self.refreshRetention(fileID, db: db)
        }
    }

    func releaseAssetSelection(_ id: V2LocalResourceAssetID) throws {
        try databasePool.write { try Self.releaseAssetSelection(id, db: $0) }
    }

    static func releaseAssetSelection(_ id: V2LocalResourceAssetID, db: Database) throws {
        guard let asset = try readAsset(id, db: db) else { return }
        try db.execute(sql: "UPDATE v2_resource_local_assets SET selection_active=0 WHERE asset_id=?", arguments: [id.value.uuidString])
        if let file = asset.fileID {
            try db.execute(sql: "DELETE FROM v2_resource_file_consumers WHERE consumer_id=? AND file_id=? AND kind=?",
                arguments: [id.value.uuidString,file.value.uuidString,"selection"])
            try refreshRetention(file, db: db)
        }
    }

    func markAssetUnavailable(_ id: V2LocalResourceAssetID) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_local_assets SET state='unavailable' WHERE asset_id=? AND state='importing'", arguments: [id.value.uuidString])
        }
    }

    static func readAsset(_ id: V2LocalResourceAssetID, db: Database) throws -> V2LocalResourceAsset? {
        try Row.fetchOne(db, sql: assetSelectSQL + " WHERE a.asset_id=?", arguments: [id.value.uuidString]).map(decodeAsset)
    }

    private static let assetSelectSQL = "SELECT a.*,f.state AS file_state FROM v2_resource_local_assets a LEFT JOIN v2_resource_files f USING(file_id)"

    private static func decodeAsset(_ row: Row) throws -> V2LocalResourceAsset {
        guard let id = UUID(uuidString: row["asset_id"]), let planned = UUID(uuidString: row["planned_file_id"]) else { throw V2ResourceStorageError.invalidRecord }
        let file: V2LocalResourceFileID?
        if let value: String = row["file_id"] {
            guard let uuid = UUID(uuidString: value) else { throw V2ResourceStorageError.invalidRecord }; file = .init(uuid)
        } else { file = nil }
        let purpose: V2LocalResourceAssetPurpose
        switch row["purpose"] as String {
        case "messageDraft": purpose = .messageDraft(try .init(row["room_id"]))
        case "groupAvatar": purpose = .groupAvatar(try .init(row["room_id"]))
        case "personalAvatar": purpose = .personalAvatar
        default: throw V2ResourceStorageError.invalidRecord
        }
        let state: String = row["state"], fileState: String? = row["file_state"]
        let availability: V2LocalResourceAsset.Availability
        if state == "importing" { availability = .importing }
        else if state == "published", file != nil, fileState == "published" { availability = .local }
        else { availability = .unavailable }
        return .init(id: .init(id), displayName: try .init(row["display_name"]), contentType: try .init(row["content_type"]),
            byteCount: row["byte_count"], checksum: try .init(value: row["checksum"]), purpose: purpose,
            availability: availability, selectionActive: row["selection_active"], createdAt: Date(timeIntervalSince1970: row["created_at"]),
            imageDimensions: try (row["pixel_width"] as Int?).map { try .init(width: $0, height: row["pixel_height"]) },
            fileID: file, plannedFileID: .init(planned))
    }

    private static func assetContext(_ purpose: V2LocalResourceAssetPurpose) -> (kind: String, room: String?) {
        switch purpose {
        case .messageDraft(let room): ("messageDraft",room.rawValue)
        case .groupAvatar(let room): ("groupAvatar",room.rawValue)
        case .personalAvatar: ("personalAvatar",nil)
        }
    }
}
