import Foundation
import GRDB
import IMV2Core

public struct V2ResourceMessageSource: Hashable, Sendable {
    public let location: V2MediaMessageLocation
    public let ordinal: Int
    public let createdAt: Date?
}

public enum V2ResourceReadPreparation: Equatable, Sendable {
    /// Local bytes are only a cache observation, never an access grant.
    case local
    case queued(V2ManagedResourceTransferID)
}

public struct V2ResourceSourceCursor: Equatable, Sendable {
    public let messageID: MessageID
    public let ordinal: Int
}

public struct V2ResourceDetailSnapshot: Equatable, Sendable {
    public let descriptor: V2ResourceDescriptor
    public let sources: [V2ResourceMessageSource]
    public let nextSourceCursor: V2ResourceSourceCursor?
    public let variants: [V2ResourceVariantSnapshot]
}

struct V2ResourceDetailMetadata: Sendable {
    let descriptor: V2ResourceDescriptor
    let sources: [V2ResourceMessageSource]
    let nextSourceCursor: V2ResourceSourceCursor?
}

extension GRDBV2LocalSyncStore {
    func resourceMessageSource(_ key: V2ResourceKey, location: V2MediaMessageLocation) throws -> V2ResourceMessageSource? {
        guard key.home == .room(location.roomID) else { throw V2ResourceStorageError.invalidRecord }
        return try databasePool.read { db in
            guard let ordinal = try Int.fetchOne(db, sql: "SELECT r.ordinal FROM v2_resource_references r WHERE r.home_kind='room' AND r.home_id=? AND r.media_id=? AND r.context_id=? AND " + Self.visibleResourceMessageReferenceSQL + " ORDER BY r.ordinal LIMIT 1",
                arguments: [location.roomID.rawValue,key.mediaID.rawValue,location.messageID.rawValue]) else {
                let known = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_references WHERE context_kind='message' AND home_kind='room' AND home_id=? AND media_id=? AND context_id=?)",
                    arguments: [location.roomID.rawValue,key.mediaID.rawValue,location.messageID.rawValue]) ?? false
                if known { throw V2ResourceStorageError.unavailable }
                return nil
            }
            return .init(location: location, ordinal: ordinal, createdAt: nil)
        }
    }
    func resourceContainsSource(_ key: V2ResourceKey, source: V2ResourceMessageSource) throws -> Bool {
        let home = Self.resourceHomeColumns(key.home)
        guard key.home == .room(source.location.roomID) else { return false }
        return try databasePool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_references r WHERE r.home_kind=? AND r.home_id=? AND r.media_id=? AND r.context_id=? AND r.ordinal=? AND " + Self.visibleResourceMessageReferenceSQL + ")",
                arguments: [home.kind,home.id,key.mediaID.rawValue,source.location.messageID.rawValue,source.ordinal]) ?? false
        }
    }

    /// Names and source identities follow exactly the directory's authority
    /// predicate, including snapshot fences. No object URLs leave this read.
    func resourceDetailMetadata(_ key: V2ResourceKey, before: V2ResourceSourceCursor?, limit: Int = 50) throws -> V2ResourceDetailMetadata? {
        guard (1...100).contains(limit), before.map({ (0..<V2MessageCommandLimits.maxMediaAttachments).contains($0.ordinal) }) ?? true else { throw V2ResourceStorageError.invalidRecord }
        let home = Self.resourceHomeColumns(key.home)
        return try databasePool.read { db in
            let predicate = "r.home_kind=? AND r.home_id=? AND r.media_id=? AND " + Self.visibleResourceMessageReferenceSQL
            let base: StatementArguments = [home.kind,home.id,key.mediaID.rawValue]
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_references r WHERE " + predicate + ")", arguments: base) == true,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_entries WHERE home_kind=? AND home_id=? AND media_id=?", arguments: base) else { return nil }
            var arguments = base
            let cursor: String
            if let before {
                cursor = " AND (r.context_id,r.ordinal)<(?,?)"
                arguments += [before.messageID.rawValue,before.ordinal]
            } else { cursor = "" }
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: "SELECT r.context_id,r.ordinal,(SELECT server_created_at FROM v2_message_projections m WHERE m.message_id=r.context_id AND m.room_id=r.home_id) AS created_at FROM v2_resource_references r WHERE " + predicate + cursor + " ORDER BY r.context_id DESC,r.ordinal DESC LIMIT ?", arguments: arguments)
            let sources = try rows.prefix(limit).map { row -> V2ResourceMessageSource in
                guard case .room(let roomID) = key.home else { throw V2ResourceStorageError.invalidRecord }
                return .init(location: .init(roomID: roomID, messageID: try .init(row["context_id"])), ordinal: row["ordinal"], createdAt: (row["created_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
            }
            return .init(descriptor: try Self.decodeResourceDescriptor(row), sources: sources,
                nextSourceCursor: rows.count > limit ? sources.last.map { .init(messageID: $0.location.messageID, ordinal: $0.ordinal) } : nil)
        }
    }
}
