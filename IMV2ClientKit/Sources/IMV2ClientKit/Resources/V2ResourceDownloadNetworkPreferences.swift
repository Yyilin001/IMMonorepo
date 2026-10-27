import Foundation
import GRDB
import IMV2Core

public enum V2ResourceAutomaticDownloadError: Error, Equatable, Sendable { case policyRestricted }

public struct V2ResourceAutomaticDownloadPolicy: Equatable, Sendable {
    public let categories: Set<V2ResourceCategory>
    public let maximumByteCount: Int64
    public static let standard = Self(validated: [], bytes: 10 * 1024 * 1024)
    public init(categories: Set<V2ResourceCategory>, maximumByteCount: Int64) throws {
        guard !categories.contains(.all), maximumByteCount > 0, maximumByteCount <= 512 * 1024 * 1024 else {
            throw V2ResourceStorageError.invalidRecord
        }
        self.init(validated: categories, bytes: maximumByteCount)
    }
    private init(validated: Set<V2ResourceCategory>, bytes: Int64) { categories = validated; maximumByteCount = bytes }
    public func allows(contentType: String, byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= maximumByteCount && categories.contains { $0.includes(contentType: contentType) }
    }
}

/// Account-local transport policy. Changing this affects new requests and
/// retries; it does not pretend to reconfigure an already-running OS task.
public struct V2ResourceDownloadNetworkPreferences: Equatable, Sendable {
    public var allowsCellular: Bool
    public var allowsConstrained: Bool
    public var automaticDownloads: V2ResourceAutomaticDownloadPolicy
    public init(allowsCellular: Bool = true, allowsConstrained: Bool = false, automaticDownloads: V2ResourceAutomaticDownloadPolicy = .standard) {
        self.allowsCellular = allowsCellular; self.allowsConstrained = allowsConstrained; self.automaticDownloads = automaticDownloads
    }
    public func constraints(automatic: Bool) -> V2ResourceDownloadNetworkConstraints {
        .init(allowsCellular: allowsCellular && !automatic,
              allowsExpensive: !automatic, allowsConstrained: allowsConstrained && !automatic)
    }
}

public struct V2ResourceDownloadNetworkConstraints: Equatable, Sendable {
    public let allowsCellular: Bool
    public let allowsExpensive: Bool
    public let allowsConstrained: Bool
    public static let unrestricted = Self(allowsCellular: true, allowsExpensive: true, allowsConstrained: true)
    public init(allowsCellular: Bool, allowsExpensive: Bool, allowsConstrained: Bool) {
        self.allowsCellular = allowsCellular; self.allowsExpensive = allowsExpensive; self.allowsConstrained = allowsConstrained
    }
    func intersecting(_ other: Self) -> Self {
        .init(allowsCellular: allowsCellular && other.allowsCellular,
              allowsExpensive: allowsExpensive && other.allowsExpensive,
              allowsConstrained: allowsConstrained && other.allowsConstrained)
    }
    func apply(to request: inout URLRequest) {
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsExpensive
        request.allowsConstrainedNetworkAccess = allowsConstrained
    }
}

extension GRDBV2LocalSyncStore {
    static let resourceDownloadNetworkSchemaSQL = """
        CREATE TABLE v2_resource_download_network_preferences (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            allows_cellular INTEGER NOT NULL CHECK(allows_cellular IN (0,1)),
            allows_constrained INTEGER NOT NULL CHECK(allows_constrained IN (0,1)),
            automatic_images INTEGER NOT NULL CHECK(automatic_images IN (0,1)),
            automatic_videos INTEGER NOT NULL CHECK(automatic_videos IN (0,1)),
            automatic_audio INTEGER NOT NULL CHECK(automatic_audio IN (0,1)),
            automatic_files INTEGER NOT NULL CHECK(automatic_files IN (0,1)),
            automatic_maximum_bytes INTEGER NOT NULL CHECK(automatic_maximum_bytes BETWEEN 1 AND 536870912)
        );
        """
}

extension V2ResourceFileJournal {
    func downloadNetworkPreferences() throws -> V2ResourceDownloadNetworkPreferences {
        try databasePool.read { try Self.readDownloadNetworkPreferences(db: $0) }
    }
    static func readDownloadNetworkPreferences(db: Database) throws -> V2ResourceDownloadNetworkPreferences {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_download_network_preferences WHERE singleton=1") else { return .init() }
        let categories: Set<V2ResourceCategory> = Set([(V2ResourceCategory.image, row["automatic_images"] as Bool),
            (.video, row["automatic_videos"] as Bool), (.audio, row["automatic_audio"] as Bool), (.file, row["automatic_files"] as Bool)].compactMap { $0.1 ? $0.0 : nil })
        return try .init(allowsCellular: row["allows_cellular"], allowsConstrained: row["allows_constrained"],
            automaticDownloads: .init(categories: categories, maximumByteCount: row["automatic_maximum_bytes"]))
    }
    func requireAutomaticDownloadAllowed(mediaID: MediaID, message: V2MediaMessageLocation?, target: V2ClientMediaTransferTarget) throws {
        let policy = try downloadNetworkPreferences().automaticDownloads
        guard let message else { throw V2ResourceAutomaticDownloadError.policyRestricted }
        let permitted = try databasePool.read { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT e.content_type,e.byte_count,e.checksum FROM v2_resource_entries e JOIN v2_resource_references r USING(home_kind,home_id,media_id) WHERE r.home_id=? AND r.context_id=? AND r.media_id=? AND e.state='ready' AND " + GRDBV2LocalSyncStore.visibleResourceMessageReferenceSQL + " LIMIT 1", arguments: [message.roomID.rawValue,message.messageID.rawValue,mediaID.rawValue]) else { return false }
            return row["byte_count"] as Int64 == target.expectedByteCount && row["checksum"] as String? == target.checksum.value
                && policy.allows(contentType: row["content_type"], byteCount: target.expectedByteCount)
        }
        guard permitted else { throw V2ResourceAutomaticDownloadError.policyRestricted }
    }

    func setDownloadNetworkPreferences(_ value: V2ResourceDownloadNetworkPreferences) throws {
        try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO v2_resource_download_network_preferences(singleton,allows_cellular,allows_constrained,automatic_images,automatic_videos,automatic_audio,automatic_files,automatic_maximum_bytes)
                VALUES(1,?,?,?,?,?,?,?) ON CONFLICT(singleton) DO UPDATE SET
                allows_cellular=excluded.allows_cellular,allows_constrained=excluded.allows_constrained,
                automatic_images=excluded.automatic_images,automatic_videos=excluded.automatic_videos,
                automatic_audio=excluded.automatic_audio,automatic_files=excluded.automatic_files,
                automatic_maximum_bytes=excluded.automatic_maximum_bytes
                """, arguments: [value.allowsCellular,value.allowsConstrained,value.automaticDownloads.categories.contains(.image),
                    value.automaticDownloads.categories.contains(.video),value.automaticDownloads.categories.contains(.audio),
                    value.automaticDownloads.categories.contains(.file),value.automaticDownloads.maximumByteCount])
        }
    }
}
