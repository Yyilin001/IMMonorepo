import Foundation
import GRDB
import IMV2Core

public struct V2ClientGroupDirectoryItem: Equatable, Sendable, Identifiable {
    public let roomID: RoomID
    public let title: String
    public let isArchived: Bool
    public var id: RoomID { roomID }
    public init(roomID: RoomID, title: String, isArchived: Bool) {
        self.roomID = roomID; self.title = title; self.isArchived = isArchived
    }
}

public struct V2ClientGroupDirectoryCursor: Equatable, Sendable {
    public let title: String
    public let roomID: RoomID
    public init(title: String, roomID: RoomID) { self.title = title; self.roomID = roomID }
}

public struct V2ClientGroupDirectoryPage: Sendable {
    public let items: [V2ClientGroupDirectoryItem]
    public let nextCursor: V2ClientGroupDirectoryCursor?
    public init(items: [V2ClientGroupDirectoryItem], nextCursor: V2ClientGroupDirectoryCursor?) {
        self.items = items; self.nextCursor = nextCursor
    }
}

extension GRDBV2LocalSyncStore {
    /// Account-local group directory, independent of inbox pagination and archive state.
    /// Explicit membership and authorization denials always override cached room profiles.
    public func groupDirectoryPage(matching query: String = "", after cursor: V2ClientGroupDirectoryCursor? = nil,
                                   limit: Int = 50) throws -> V2ClientGroupDirectoryPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(limit), query.utf8.count <= 400 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try databasePool.read { db in
            var predicates = ["profile.is_group_event_authorized = 1",
                "NOT EXISTS (SELECT 1 FROM v2_room_membership_states WHERE room_id = profile.room_id AND is_member = 0)",
                "NOT EXISTS (SELECT 1 FROM v2_room_event_authorizations WHERE room_id = profile.room_id AND is_authorized = 0)"]
            var arguments: StatementArguments = []
            if !query.isEmpty {
                predicates.append("instr(lower(profile.title), lower(?)) > 0")
                arguments += [query]
            }
            if let cursor {
                predicates.append("(profile.title COLLATE NOCASE > ? OR (profile.title COLLATE NOCASE = ? AND profile.room_id > ?))")
                arguments += [cursor.title, cursor.title, cursor.roomID.rawValue]
            }
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: """
                SELECT profile.room_id, profile.title, COALESCE(state.is_archived, 0) AS is_archived
                FROM v2_room_profile_projections AS profile
                LEFT JOIN v2_conversation_states AS state ON state.room_id = profile.room_id
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY profile.title COLLATE NOCASE, profile.room_id
                LIMIT ?
                """, arguments: arguments)
            let items = try rows.prefix(limit).map {
                try V2ClientGroupDirectoryItem(roomID: .init($0["room_id"] as String), title: $0["title"], isArchived: $0["is_archived"])
            }
            let next = rows.count > limit ? items.last.map { V2ClientGroupDirectoryCursor(title: $0.title, roomID: $0.roomID) } : nil
            return .init(items: items, nextCursor: next)
        }
    }
}
