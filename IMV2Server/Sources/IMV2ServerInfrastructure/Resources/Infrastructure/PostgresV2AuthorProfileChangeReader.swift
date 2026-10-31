import Foundation
import FluentKit
import SQLKit
import IMV2Core
import IMV2ServerApplication

/// Every gateway has an independent cursor over the same committed outbox.
/// No claim/lease steals events from another gateway. Cleanup gaps reset the
/// visible set; a sequence is never allocated outside the source transaction.
public struct PostgresV2AuthorProfileChangeReader: V2AuthorProfileChangeReading {
    private let database: any Database
    public init(database: any Database) { self.database = database }

    public func readChanges(after cursor: UInt64?) async throws -> V2AuthorProfileChangeBatch {
        guard cursor.map({ $0 <= UInt64(Int64.max) }) ?? true,
              let sql = database as? any SQLDatabase else { throw V2ProfileControlBatchError.corruptResult }
        let rows = try await sql.raw("""
            SELECT h.sequence AS head, e.publication_sequence AS sequence, e.kind, e.owner_user_id, e.target_user_id, e.revision
            FROM im_v2.author_presentation_change_head h
            LEFT JOIN LATERAL (
                SELECT * FROM (
                    SELECT publication_sequence, 'public_profile'::text AS kind,
                        NULL::uuid AS owner_user_id, source_user_id AS target_user_id, revision
                    FROM im_v2.public_profile_update_outbox
                    WHERE \(bind: cursor != nil) AND publication_sequence > \(bind: Int64(cursor ?? 0))
                    UNION ALL
                    SELECT publication_sequence, kind, owner_user_id, target_user_id, revision
                    FROM im_v2.author_presentation_control_changes
                    WHERE \(bind: cursor != nil) AND publication_sequence > \(bind: Int64(cursor ?? 0))
                ) events
                ORDER BY publication_sequence LIMIT 128
            ) e ON true WHERE h.singleton
            ORDER BY e.publication_sequence
            """).all(decoding: Row.self)
        guard let first = rows.first, first.head >= 0, rows.allSatisfy({ $0.head == first.head }) else {
            throw V2ProfileControlBatchError.corruptResult
        }
        let head = UInt64(first.head)
        let changes = try rows.compactMap { row -> V2AuthorProfileChange? in
            guard let sequence = row.sequence else {
                guard row.target == nil, row.owner == nil, row.kind == nil, row.revision == nil else { throw V2ProfileControlBatchError.corruptResult }
                return nil
            }
            guard sequence > 0, let target = row.target, let revision = row.revision, revision > 0 else {
                throw V2ProfileControlBatchError.corruptResult
            }
            let scope: V2AuthorProfileChange.Scope
            if row.kind == "public_profile", row.owner == nil { scope = .publicProfile(.init(uuid: target)) }
            else if let owner = row.owner {
                switch row.kind {
                case "contact_alias": scope = .contactAlias(owner: .init(uuid: owner), target: .init(uuid: target))
                case "relationship": scope = .relationship(.init(uuid: owner), .init(uuid: target))
                case "user_block": scope = .userBlock(actor: .init(uuid: owner), target: .init(uuid: target))
                default: throw V2ProfileControlBatchError.corruptResult
                }
            } else { throw V2ProfileControlBatchError.corruptResult }
            return try .init(sequence: UInt64(sequence), scope: scope, revision: UInt64(revision))
        }
        guard let cursor, cursor <= head else { return try .init(head: head, resetRequired: true, changes: []) }
        var expected = cursor
        for change in changes {
            guard change.sequence == expected + 1 else { return try .init(head: head, resetRequired: true, changes: []) }
            expected = change.sequence
        }
        if changes.isEmpty && cursor < head { return try .init(head: head, resetRequired: true, changes: []) }
        return try .init(head: head, resetRequired: false, changes: changes)
    }

    private struct Row: Decodable {
        let head: Int64; let sequence: Int64?; let kind: String?; let owner: UUID?; let target: UUID?; let revision: Int64?
        enum CodingKeys: String, CodingKey { case head, sequence, kind, owner = "owner_user_id", target = "target_user_id", revision }
    }
}
