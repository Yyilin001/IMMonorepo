import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    private static let resourceBusinessOwnerRows = """
        SELECT 'profile' kind,intent_id token,created_at,NULL room_id FROM v2_profile_intents
        WHERE upload_job_id=? AND source_released=0 AND account_id=(SELECT user_id FROM v2_local_installation WHERE singleton=1)
        UNION ALL
        SELECT 'group',operation_id,created_at,room_id FROM v2_group_avatar_intents
        WHERE upload_job_id=? AND actor_user_id=(SELECT user_id FROM v2_local_installation WHERE singleton=1)
          AND (stage NOT IN ('committed','cancelled','closed') OR (stage='closed' AND closed_disposition='awaitingDecision'))
        """
    private static func businessOwnerSelection(_ transfer: V2ManagedResourceTransferID) -> (sql: String, arguments: StatementArguments)? {
        switch transfer {
        case .upload(let id): return (resourceBusinessOwnerRows, [id.uuidString,id.uuidString])
        case .serverImport(let id): return ("""
            SELECT 'profile' kind,intent_id token,created_at,NULL room_id FROM v2_profile_intents
            WHERE import_job_id=? AND source_released=0 AND account_id=(SELECT user_id FROM v2_local_installation WHERE singleton=1)
            UNION ALL
            SELECT 'group' kind,operation_id token,created_at,room_id FROM v2_group_avatar_intents
            WHERE import_job_id=? AND actor_user_id=(SELECT user_id FROM v2_local_installation WHERE singleton=1)
              AND (stage NOT IN ('committed','cancelled','closed') OR (stage='closed' AND closed_disposition='awaitingDecision'))
            """, [id.uuidString,id.uuidString])
        case .download: return nil
        }
    }
    func resourceBusinessOwners(_ query: V2ResourceBusinessOwnerQuery) throws -> V2ResourceBusinessOwnerPage {
        try databasePool.read { try Self.resourceBusinessOwners(query, db: $0) }
    }
    static func resourceBusinessOwners(_ query: V2ResourceBusinessOwnerQuery, db: Database) throws -> V2ResourceBusinessOwnerPage {
        guard let selection = businessOwnerSelection(query.transfer) else { return .init(entries: [], nextCursor: nil) }
        var args = selection.arguments
        var predicate = "1=1"
        if let cursor = query.before {
            predicate = "(created_at,kind,token)<(?,?,?)"
            args += [cursor.createdAt.timeIntervalSince1970,cursor.kind,cursor.token]
        }
        args += [query.limit + 1]
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM (\(selection.sql)) WHERE \(predicate) ORDER BY created_at DESC,kind DESC,token DESC LIMIT ?", arguments: args)
        let entries = try rows.prefix(query.limit).map { row -> V2ResourceBusinessOwnerEntry in
            let owner: V2ResourceBusinessOwner
            switch row["kind"] as String {
            case "profile":
                guard let id = UUID(uuidString: row["token"]) else { throw V2ResourceJournalError.invalidRecord }
                owner = .profileIntent(id)
            case "group": owner = .groupAvatar(try RoomID(row["room_id"]), try GroupAvatarOperationID(row["token"]))
            default: throw V2ResourceJournalError.invalidRecord
            }
            return .init(owner: owner, createdAt: Date(timeIntervalSince1970: row["created_at"]))
        }
        let cursor = rows.count > query.limit ? entries.last.map { V2ResourceBusinessOwnerCursor(transfer: query.transfer, createdAt: $0.createdAt, kind: $0.owner.kind, token: $0.owner.token) } : nil
        return .init(entries: entries, nextCursor: cursor)
    }
    func resourceHasBusinessOwner(_ owner: V2ResourceBusinessOwner, transfer: V2ManagedResourceTransferID) throws -> Bool {
        try databasePool.read { try Self.resourceHasBusinessOwner(owner, transfer: transfer, db: $0) }
    }
    static func resourceHasBusinessOwner(_ owner: V2ResourceBusinessOwner, transfer: V2ManagedResourceTransferID, db: Database) throws -> Bool {
        guard let selection = businessOwnerSelection(transfer) else { return false }
        let room: String? = if case .groupAvatar(let room, _) = owner { room.rawValue } else { nil }
        var arguments = selection.arguments
        arguments += [owner.kind,owner.token,room]
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM (\(selection.sql)) WHERE kind=? AND token=? AND (room_id IS ?))", arguments: arguments) ?? false
    }
    func profileResourceDisposition(transfer: V2ManagedResourceTransferID, intentID: UUID) throws -> V2ProfileIntent {
        try databasePool.read { try Self.profileResourceDisposition(transfer: transfer, intentID: intentID, db: $0) }
    }
    private static func profileResourceDisposition(transfer: V2ManagedResourceTransferID, intentID: UUID, db: Database) throws -> V2ProfileIntent {
        guard try resourceHasBusinessOwner(.profileIntent(intentID), transfer: transfer, db: db),
              let row = try Row.fetchOne(db, sql: """
                SELECT i.payload,i.account_id,i.work_id,w.scheduling_state FROM v2_profile_intents i
                LEFT JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.intent_id=?
                """, arguments: [intentID.uuidString]),
              (row["work_id"] as String?) == nil || (row["scheduling_state"] as String?) == "finished" else { throw V2ResourceTransferManagementError.actionUnavailable }
        let intent = try JSONDecoder().decode(V2ProfileIntent.self, from: row["payload"])
        guard intent.id == intentID, intent.avatarPreparation?.transferID == transfer,
              intent.accountID.rawValue == (row["account_id"] as String) else { throw V2ResourceJournalError.invalidRecord }
        return intent
    }
    func commitResourceProfileDisposition(_ plan: V2ResourceProfileDispositionPlan) throws -> UUID? {
        try databasePool.write { db in
            guard try Self.profileResourceDisposition(transfer: plan.transfer, intentID: plan.intent.id, db: db) == plan.intent else {
                throw V2ResourceTransferManagementError.actionUnavailable
            }
            try Self.discardProfileIntentSource(id: plan.intent.id, db: db)
            guard case .upload(let id) = plan.transfer, try Self.readResourceTransfer(id, db: db)?.cancellationRequested == true else { return nil }
            return id
        }
    }
}
