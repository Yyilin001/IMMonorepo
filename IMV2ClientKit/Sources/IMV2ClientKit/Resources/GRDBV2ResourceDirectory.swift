import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let resourceDirectorySchemaSQL = """
        CREATE TABLE v2_resource_entries (
            home_kind TEXT NOT NULL CHECK(home_kind IN ('account','room')),
            home_id TEXT NOT NULL, media_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision>0), display_name TEXT NOT NULL,
            content_type TEXT NOT NULL, kind TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count>0),
            checksum TEXT, state TEXT NOT NULL, automatic_download_admitted INTEGER NOT NULL DEFAULT 0 CHECK(automatic_download_admitted IN (0,1)), pixel_width INTEGER, pixel_height INTEGER, duration_ms INTEGER,
            indexed_at REAL NOT NULL CHECK(indexed_at>=0),
            PRIMARY KEY(home_kind,home_id,media_id)
        );
        CREATE INDEX v2_resource_entries_directory ON v2_resource_entries(indexed_at DESC,home_kind DESC,home_id DESC,media_id DESC);
        CREATE INDEX v2_resource_entries_room_directory ON v2_resource_entries(home_kind,home_id,indexed_at DESC,media_id DESC);
        CREATE INDEX v2_resource_entries_type ON v2_resource_entries(kind,indexed_at DESC,home_kind DESC,home_id DESC,media_id DESC);
        CREATE TABLE v2_resource_references (
            context_kind TEXT NOT NULL CHECK(context_kind IN ('message','userAvatar','groupAvatar')),
            context_id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0),
            home_kind TEXT NOT NULL, home_id TEXT NOT NULL, media_id TEXT,
            business_revision INTEGER NOT NULL CHECK(business_revision>0),
            validated_snapshot_id TEXT,
            is_revoked INTEGER NOT NULL DEFAULT 0 CHECK(is_revoked IN (0,1)),
            CHECK(is_revoked=1 OR media_id IS NOT NULL),
            PRIMARY KEY(context_kind,context_id,ordinal),
            FOREIGN KEY(home_kind,home_id,media_id) REFERENCES v2_resource_entries(home_kind,home_id,media_id)
        );
        CREATE INDEX v2_resource_references_resource ON v2_resource_references(home_kind,home_id,media_id);
        CREATE TABLE v2_resource_projection_index_jobs (
            message_id TEXT PRIMARY KEY,room_id TEXT NOT NULL,queued_revision INTEGER NOT NULL CHECK(queued_revision>0)
        );
        CREATE INDEX v2_resource_projection_index_room ON v2_resource_projection_index_jobs(room_id,message_id);
        """

    /// Descriptor and its business binding are accepted in one transaction.
    /// Replaying an older descriptor cannot downgrade metadata or resurrect an
    /// older binding. Equal revisions with different values are a conflict.
    public func indexResource(_ descriptor: V2ResourceDescriptor, reference: V2ResourceReferenceContext,
                              businessRevision: Int64, now: Date = Date()) throws {
        try databasePool.write { db in
            try Self.indexResource(descriptor, reference: reference, businessRevision: businessRevision, now: now, db: db)
        }
    }

    static func indexResource(_ descriptor: V2ResourceDescriptor, reference: V2ResourceReferenceContext,
                              businessRevision: Int64, now: Date, db: Database) throws {
        guard businessRevision > 0, now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else {
            throw V2ResourceStorageError.invalidRecord
        }
        let home = Self.resourceHomeColumns(descriptor.key.home)
        let context = try Self.resourceReferenceColumns(reference, home: descriptor.key.home)
        if case .room(let room) = descriptor.key.home,
           try Self.resourceRoomIsDenied(room, db: db) { return }
        if case .message(let location, _) = reference {
            // A delayed page or send receipt cannot undo a locally observed
            // withdrawal, even if no resource binding existed at that time.
            if let revision = try Int64.fetchOne(db, sql: "SELECT message_revision FROM v2_message_tombstones WHERE message_id=? AND room_id=?",
                arguments: [location.messageID.rawValue,location.roomID.rawValue]), revision >= businessRevision { return }
            if let message = try Row.fetchOne(db, sql: "SELECT is_withdrawn,message_revision,media_ids FROM v2_message_projections WHERE message_id=? AND room_id=?",
                arguments: [location.messageID.rawValue,location.roomID.rawValue]) {
                if message["is_withdrawn"] as Bool { return }
                if (message["message_revision"] as Int64) >= businessRevision {
                    let current = try Self.decodeMedia(message["media_ids"])
                    guard current.indices.contains(context.ordinal), current[context.ordinal].mediaID == descriptor.key.mediaID else { return }
                }
            }
        }
        if let previous = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_references WHERE context_kind=? AND context_id=? AND ordinal=?",
            arguments: [context.kind,context.id,context.ordinal]) {
            let revision: Int64 = previous["business_revision"]
            if revision > businessRevision { return }
            if revision == businessRevision, previous["is_revoked"] as Bool { return }
            if revision == businessRevision {
                guard (previous["home_kind"] as String) == home.kind, (previous["home_id"] as String) == home.id,
                      (previous["media_id"] as String) == descriptor.key.mediaID.rawValue else { throw V2ResourceStorageError.conflict }
            }
        }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_entries WHERE home_kind=? AND home_id=? AND media_id=?",
            arguments: [home.kind,home.id,descriptor.key.mediaID.rawValue]) {
            let existing = try Self.decodeResourceDescriptor(row)
            if existing.revision == descriptor.revision, existing != descriptor { throw V2ResourceStorageError.conflict }
            guard existing.byteCount == descriptor.byteCount,
                  existing.checksum == nil || existing.checksum == descriptor.checksum else {
                throw V2ResourceStorageError.conflict
            }
        }
        try db.execute(sql: """
            INSERT INTO v2_resource_entries(home_kind,home_id,media_id,revision,display_name,content_type,kind,byte_count,checksum,state,pixel_width,pixel_height,duration_ms,indexed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(home_kind,home_id,media_id) DO UPDATE SET
                revision=excluded.revision,display_name=excluded.display_name,content_type=excluded.content_type,kind=excluded.kind,
                byte_count=excluded.byte_count,checksum=excluded.checksum,state=excluded.state,pixel_width=excluded.pixel_width,
                pixel_height=excluded.pixel_height,duration_ms=excluded.duration_ms
            WHERE excluded.revision>v2_resource_entries.revision
            """, arguments: [home.kind,home.id,descriptor.key.mediaID.rawValue,descriptor.revision,descriptor.displayName.value,
                descriptor.contentType,descriptor.kind.rawValue,descriptor.byteCount,descriptor.checksum?.value,descriptor.state.rawValue,
                descriptor.pixelWidth,descriptor.pixelHeight,descriptor.durationMilliseconds,now.timeIntervalSince1970])
        if descriptor.state == .ready, let checksum = descriptor.checksum {
            try Self.indexResourceVariant(.init(key: .init(resource: descriptor.key), checksum: checksum, byteCount: descriptor.byteCount), db: db)
        }
        try db.execute(sql: """
            INSERT INTO v2_resource_references(context_kind,context_id,ordinal,home_kind,home_id,media_id,business_revision,validated_snapshot_id)
            VALUES(?,?,?,?,?,?,?,(SELECT snapshot_id FROM v2_snapshots WHERE singleton=1)) ON CONFLICT(context_kind,context_id,ordinal) DO UPDATE SET
                home_kind=excluded.home_kind,home_id=excluded.home_id,media_id=excluded.media_id,business_revision=excluded.business_revision,is_revoked=0,validated_snapshot_id=excluded.validated_snapshot_id
            WHERE excluded.business_revision>v2_resource_references.business_revision
                OR (excluded.business_revision=v2_resource_references.business_revision
                    AND excluded.validated_snapshot_id IS NOT v2_resource_references.validated_snapshot_id)
            """, arguments: [context.kind,context.id,context.ordinal,home.kind,home.id,descriptor.key.mediaID.rawValue,businessRevision])
    }

    /// A durable version floor also handles revocation arriving before content.
    public func revokeResourceReference(_ reference: V2ResourceReferenceContext, businessRevision: Int64) throws {
        guard businessRevision > 0 else { throw V2ResourceStorageError.invalidRecord }
        let resourceHome: V2ResourceHome
        switch reference {
        case .message(let location, _): resourceHome = .room(location.roomID)
        case .userAvatar(let id): resourceHome = .account(id)
        case .groupAvatar(let id): resourceHome = .room(id)
        }
        let home = Self.resourceHomeColumns(resourceHome)
        let context = try Self.resourceReferenceColumns(reference, home: resourceHome)
        try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO v2_resource_references(context_kind,context_id,ordinal,home_kind,home_id,media_id,business_revision,is_revoked)
                VALUES(?,?,?,?,?,NULL,?,1) ON CONFLICT(context_kind,context_id,ordinal) DO UPDATE SET
                    business_revision=excluded.business_revision,is_revoked=1
                WHERE excluded.business_revision>=v2_resource_references.business_revision
                """, arguments: [context.kind,context.id,context.ordinal,home.kind,home.id,businessRevision])
        }
    }

    public func resourceDirectory(roomID: RoomID? = nil, kind: V2MediaPresentation.Kind? = nil, category: V2ResourceCategory = .all,
                                  search: String = "", retainedOnly: Bool = false, before cursor: V2ResourceDirectoryCursor? = nil,
                                  limit: Int = 50) throws -> V2ResourceDirectoryPage {
        guard (1...100).contains(limit), search.utf8.count <= 255 else { throw V2ResourceStorageError.invalidRecord }
        if let cursor {
            guard cursor.indexedAt.timeIntervalSince1970.isFinite, cursor.indexedAt.timeIntervalSince1970 >= 0 else {
                throw V2ResourceStorageError.invalidRecord
            }
        }
        return try databasePool.read { db in
            var predicates = ["EXISTS(SELECT 1 FROM v2_resource_references r WHERE r.home_kind=e.home_kind AND r.home_id=e.home_id AND r.media_id=e.media_id AND \(Self.visibleResourceMessageReferenceSQL))"]
            var arguments = StatementArguments()
            if let roomID {
                predicates.append("e.home_kind='room' AND e.home_id=?")
                arguments += [roomID.rawValue]
            }
            if let kind { predicates.append("e.kind=?"); arguments += [kind.rawValue] }
            switch category {
            case .all: break
            case .image: predicates.append("e.kind IN ('image','animated_image')")
            case .video: predicates.append("e.kind='video'")
            case .audio: predicates.append("e.kind='audio'")
            case .file: predicates.append("e.kind='file'")
            }
            if retainedOnly { predicates.append(Self.originalRetentionPredicate) }
            if !search.isEmpty {
                let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                predicates.append("e.display_name LIKE ? ESCAPE '\\'"); arguments += ["%\(escaped)%"]
            }
            if let cursor {
                let home = Self.resourceHomeColumns(cursor.key.home)
                predicates.append("(e.indexed_at,e.home_kind,e.home_id,e.media_id)<(?,?,?,?)")
                arguments += [cursor.indexedAt.timeIntervalSince1970,home.kind,home.id,cursor.key.mediaID.rawValue]
            }
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.*,\(Self.originalRetentionPredicate) AS is_retained,
                    COALESCE((SELECT CASE f.state WHEN 'published' THEN 'available' WHEN 'invalid' THEN 'invalid' ELSE 'needsDownload' END
                        FROM v2_resource_variants v JOIN v2_resource_files f ON f.file_id=v.file_id
                        WHERE v.home_kind=e.home_kind AND v.home_id=e.home_id AND v.media_id=e.media_id
                            AND v.variant_kind='original' AND v.variant_id='' AND v.version=1), 'needsDownload') AS local_state,
                    (SELECT COUNT(*) FROM v2_resource_references r WHERE r.home_kind=e.home_kind AND r.home_id=e.home_id AND r.media_id=e.media_id AND \(Self.visibleResourceMessageReferenceSQL)) AS reference_count
                FROM v2_resource_entries e WHERE \(predicates.joined(separator: " AND "))
                ORDER BY e.indexed_at DESC,e.home_kind DESC,e.home_id DESC,e.media_id DESC LIMIT ?
                """, arguments: arguments)
            let entries = try rows.prefix(limit).map { row in
                V2ResourceDirectoryEntry(descriptor: try Self.decodeResourceDescriptor(row), indexedAt: Date(timeIntervalSince1970: row["indexed_at"]), referenceCount: row["reference_count"], isRetained: row["is_retained"], localState: try Self.decodeDirectoryLocalState(row["local_state"]))
            }
            let next = rows.count > limit ? entries.last.map { V2ResourceDirectoryCursor(indexedAt: $0.indexedAt, key: $0.descriptor.key) } : nil
            let indexing: Bool
            if let roomID {
                indexing = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_projection_index_jobs WHERE room_id=?)", arguments: [roomID.rawValue]) ?? false
            } else { indexing = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_projection_index_jobs)") ?? false }
            return .init(entries: entries, nextCursor: next, isIndexing: indexing)
        }
    }

    private static let originalRetentionPredicate = """
        EXISTS(SELECT 1 FROM v2_resource_retention_intents p WHERE p.home_kind=e.home_kind AND p.home_id=e.home_id AND p.media_id=e.media_id
            AND p.variant_kind='original' AND p.variant_id='' AND p.version=1)
        """

    private static func decodeDirectoryLocalState(_ raw: String) throws -> V2ResourceDirectoryEntry.LocalState {
        guard let state = V2ResourceDirectoryEntry.LocalState(rawValue: raw) else { throw V2ResourceStorageError.invalidRecord }
        return state
    }

    /// Metadata follows the same live projection bank as the visible account.
    /// A cached filename is content too; opening the bytes is not the first gate.
    static let visibleResourceMessageReferenceSQL = """
        r.context_kind='message' AND r.is_revoked=0 AND r.home_kind='room'
        AND (r.validated_snapshot_id IS (SELECT snapshot_id FROM v2_snapshots WHERE singleton=1)
            OR EXISTS(SELECT 1 FROM v2_message_projections verified_message
                WHERE verified_message.message_id=r.context_id AND verified_message.room_id=r.home_id
                    AND verified_message.is_withdrawn=0 AND verified_message.message_revision>=r.business_revision
                    AND EXISTS(SELECT 1 FROM json_each(verified_message.media_ids) attachment
                        WHERE CAST(attachment.key AS INTEGER)=r.ordinal AND attachment.value=r.media_id)))
        AND NOT EXISTS(SELECT 1 FROM v2_resource_room_denials d WHERE d.room_id=r.home_id)
        AND NOT EXISTS(SELECT 1 FROM v2_room_membership_states member WHERE member.room_id=r.home_id AND member.is_member=0)
        AND NOT EXISTS(SELECT 1 FROM v2_room_event_authorizations a WHERE a.room_id=r.home_id AND a.is_authorized=0)
        AND NOT EXISTS(SELECT 1 FROM v2_message_tombstones t WHERE t.message_id=r.context_id AND t.room_id=r.home_id AND t.message_revision>=r.business_revision)
        AND NOT EXISTS(SELECT 1 FROM v2_message_projections m WHERE m.message_id=r.context_id AND m.room_id=r.home_id
            AND (m.is_withdrawn=1 OR (m.message_revision>=r.business_revision
                AND NOT EXISTS(SELECT 1 FROM json_each(m.media_ids) attachment WHERE CAST(attachment.key AS INTEGER)=r.ordinal AND attachment.value=r.media_id))))
        """

    static func resourceRoomIsDenied(_ room: RoomID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM v2_resource_room_denials WHERE room_id=?)
                OR EXISTS(SELECT 1 FROM v2_room_membership_states WHERE room_id=? AND is_member=0)
                OR EXISTS(SELECT 1 FROM v2_room_event_authorizations WHERE room_id=? AND is_authorized=0)
            """, arguments: [room.rawValue,room.rawValue,room.rawValue]) ?? true
    }

    static func resourceHomeColumns(_ home: V2ResourceHome) -> (kind: String, id: String) {
        switch home {
        case .account(let id): ("account",id.rawValue)
        case .room(let id): ("room",id.rawValue)
        }
    }

    private static func resourceReferenceColumns(_ reference: V2ResourceReferenceContext, home: V2ResourceHome) throws -> (kind: String, id: String, ordinal: Int) {
        switch reference {
        case .message(let location, let ordinal):
            guard home == .room(location.roomID), (0..<V2MessageCommandLimits.maxMediaAttachments).contains(ordinal) else { throw V2ResourceStorageError.invalidRecord }
            return ("message",location.messageID.rawValue,ordinal)
        case .userAvatar(let id):
            guard home == .account(id) else { throw V2ResourceStorageError.invalidRecord }
            return ("userAvatar",id.rawValue,0)
        case .groupAvatar(let id):
            guard home == .room(id) else { throw V2ResourceStorageError.invalidRecord }
            return ("groupAvatar",id.rawValue,0)
        }
    }

    static func decodeResourceDescriptor(_ row: Row) throws -> V2ResourceDescriptor {
        let home: V2ResourceHome
        switch row["home_kind"] as String {
        case "account": home = .account(try .init(row["home_id"]))
        case "room": home = .room(try .init(row["home_id"]))
        default: throw V2ResourceStorageError.invalidRecord
        }
        guard let state = V2ResourceState(rawValue: row["state"]) else { throw V2ResourceStorageError.invalidRecord }
        let checksum: String? = row["checksum"]
        return try .init(key: .init(home: home, mediaID: .init(row["media_id"])), revision: row["revision"],
            displayName: .init(row["display_name"]), contentType: row["content_type"], byteCount: row["byte_count"],
            checksum: checksum.map { try .init(value: $0) }, state: state, pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"], durationMilliseconds: row["duration_ms"])
    }
}
