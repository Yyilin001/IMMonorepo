import Foundation
import Crypto

/// Stable ordering identity for one current user-visible projection. Snapshot
/// pages use this key for keyset pagination and cross-page duplicate checks.
public struct V2SnapshotProjectionKey: Equatable, Hashable, Comparable, Sendable, Codable {
    public let projectionKind: String
    public let entityKey: String

    public init(projectionKind: String, entityKey: String) throws {
        guard !projectionKind.isEmpty, projectionKind.utf8.count <= 64,
              !entityKey.isEmpty, entityKey.utf8.count <= 512
        else { throw V2SnapshotProjectionV3Error.invalidKey }
        self.projectionKind = projectionKind
        self.entityKey = entityKey
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.projectionKind, lhs.entityKey) < (rhs.projectionKind, rhs.entityKey)
    }

    private enum CodingKeys: String, CodingKey {
        case projectionKind = "projection_kind"
        case entityKey = "entity_key"
    }
}

/// One normalized current-state entry. `payload` intentionally keeps the same
/// JSON projection vocabulary as incremental sync, so the client has one
/// validation/apply path for reset and normal delivery.
public struct V2SnapshotProjectionItem: Equatable, Sendable {
    public let key: V2SnapshotProjectionKey
    public let sourceEventID: EventID
    public let sequence: UInt64
    public let payload: Data

    public init(key: V2SnapshotProjectionKey, sourceEventID: EventID, sequence: UInt64, payload: Data) throws {
        guard sequence > 0, !payload.isEmpty,
              payload.count <= V2SnapshotProjectionV3Codec.maximumItemBytes
        else { throw V2SnapshotProjectionV3Error.invalidItem }
        self.key = key
        self.sourceEventID = sourceEventID
        self.sequence = sequence
        self.payload = payload
    }
}

/// Snapshot V3 pages are self-contained and bounded. Global uniqueness follows
/// from strictly increasing keys and database constraints, not an O(total)
/// in-memory Set on either endpoint.
public struct V2SnapshotProjectionV3Page: Equatable, Sendable {
    public let items: [V2SnapshotProjectionItem]

    public init(items: [V2SnapshotProjectionItem]) throws {
        guard !items.isEmpty, items.count <= V2SnapshotProjectionV3Codec.maximumPageItems else {
            throw V2SnapshotProjectionV3Error.invalidPage
        }
        for pair in zip(items, items.dropFirst()) where pair.0.key >= pair.1.key {
            throw V2SnapshotProjectionV3Error.invalidPage
        }
        self.items = items
    }

    public var firstKey: V2SnapshotProjectionKey { items[0].key }
    public var lastKey: V2SnapshotProjectionKey { items[items.count - 1].key }
}

public enum V2SnapshotProjectionV3Codec {
    public static let schemaVersion: UInt32 = 31
    public static let maximumPageItems = 500
    // Item bytes are JSON-embedded as base64 inside a page. Keeping the raw
    // payload below 44 KiB guarantees one valid item can always fit in the
    // 60 KiB page/frame budget with its ordering and identity metadata.
    public static let maximumItemBytes = 44 * 1_024
    // Leaves headroom for the protobuf envelope inside the protocol's current
    // 64 KiB frame limit.
    public static let maximumPageBytes = 60 * 1_024
    /// Whole-artifact limits are part of the protocol contract. Per-page
    /// bounds alone still permit a server to make a client reserve hundreds
    /// of megabytes of SQLite/WAL space during one reset.
    public static let maximumPageCount = 4_096
    public static let maximumTotalItems: UInt64 = 1_000_000
    public static let maximumTotalBytes: UInt64 = 256 * 1_024 * 1_024

    public static func encode(_ page: V2SnapshotProjectionV3Page) throws -> Data {
        let wire = Page(
            schemaVersion: schemaVersion,
            items: page.items.map(Item.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= maximumPageBytes else { throw V2SnapshotProjectionV3Error.pageTooLarge }
        return data
    }

    public static func decode(_ payload: Data) throws -> V2SnapshotProjectionV3Page {
        guard !payload.isEmpty, payload.count <= maximumPageBytes else {
            throw V2SnapshotProjectionV3Error.pageTooLarge
        }
        let wire: Page
        do { wire = try JSONDecoder().decode(Page.self, from: payload) }
        catch { throw V2SnapshotProjectionV3Error.invalidPage }
        guard wire.schemaVersion == schemaVersion else {
            throw V2SnapshotProjectionV3Error.unsupportedSchemaVersion
        }
        do { return try .init(items: wire.items.map { try $0.value() }) }
        catch let error as V2SnapshotProjectionV3Error { throw error }
        catch { throw V2SnapshotProjectionV3Error.invalidPage }
    }

    private struct Page: Codable {
        let schemaVersion: UInt32
        let items: [Item]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case items
        }
    }

    private struct Item: Codable {
        let projectionKind: String
        let entityKey: String
        let sourceEventID: String
        let sequence: UInt64
        let payload: Data

        init(_ value: V2SnapshotProjectionItem) {
            projectionKind = value.key.projectionKind
            entityKey = value.key.entityKey
            sourceEventID = value.sourceEventID.rawValue
            sequence = value.sequence
            payload = value.payload
        }

        func value() throws -> V2SnapshotProjectionItem {
            try .init(
                key: .init(projectionKind: projectionKind, entityKey: entityKey),
                sourceEventID: .init(sourceEventID),
                sequence: sequence,
                payload: payload
            )
        }

        enum CodingKeys: String, CodingKey {
            case projectionKind = "projection_kind"
            case entityKey = "entity_key"
            case sourceEventID = "source_event_id"
            case sequence
            case payload
        }
    }
}

public enum V2SnapshotProjectionV3Error: Error, Equatable, Sendable {
    case invalidKey
    case invalidItem
    case invalidPage
    case pageTooLarge
    case unsupportedSchemaVersion
}

/// Protocol-owned digest chain shared by artifact builders, transports, local
/// importers, and test fixtures. Keeping this in IMV2Core prevents two peers
/// from drifting while still compiling against structurally identical pages.
public enum V2SnapshotV3Digest {
    public static func initial(baseSequence: UInt64, capabilityProfile: String) -> String {
        sha256(Data("IM-SNAPSHOT-V3\u{0}\(V2SnapshotProjectionV3Codec.schemaVersion)\u{0}\(baseSequence)\u{0}\(capabilityProfile)".utf8))
    }

    public static func next(
        previous: String,
        pageIndex: UInt32,
        pageDigest: String,
        firstKey: V2SnapshotProjectionKey,
        lastKey: V2SnapshotProjectionKey,
        itemCount: UInt32
    ) -> String {
        sha256(Data([
            previous, String(pageIndex), pageDigest,
            firstKey.projectionKind, firstKey.entityKey,
            lastKey.projectionKind, lastKey.entityKey,
            String(itemCount),
        ].joined(separator: "\u{0}").utf8))
    }

    public static func page(_ payload: Data) -> String { sha256(payload) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
