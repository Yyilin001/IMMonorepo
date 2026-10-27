import Foundation
import GRDB

public struct V2ResourcePreparationCancellationPlan: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let transfer: V2ManagedResourceTransferID
    public var messageCount: Int { intents.count }
    let incarnation: UUID
    let owner: UUID
    let intents: [UUID]
}

extension GRDBV2LocalSyncStore {
    func preparationCancellationParents(_ transfer: V2ManagedResourceTransferID) throws -> [UUID]? {
        try databasePool.read { try Self.preparationCancellationParents(transfer, db: $0) }
    }

    static func preparationCancellationParents(_ transfer: V2ManagedResourceTransferID, db: Database, includingReady: Bool = false) throws -> [UUID]? {
        let table: String
        switch transfer {
        case .download: return nil
        case .upload(let id):
            guard let job = try readResourceTransfer(id, db: db), !job.cancellationRequested,
                  case .messageAttachment = job.request.usage,
                  includingReady || job.stage != .ready,
                  try !preparationUploadHasAvatarConsumer(id, db: db) else { return nil }
            table = "v2_send_intent_dependencies"
        case .serverImport(let id):
            guard let job = try readResourceImport(id, db: db), !job.cancellationRequested,
                  includingReady || job.status?.state != .ready else { return nil }
            table = "v2_send_intent_import_dependencies"
        }
        let rows = try Row.fetchAll(db, sql: "SELECT i.intent_id,i.stage FROM \(table) d JOIN v2_send_intents i USING(intent_id) WHERE d.job_id=? AND i.stage<>'cancelled' ORDER BY i.intent_id LIMIT 65", arguments: [transfer.value.uuidString])
        guard !rows.isEmpty, rows.count <= 64, rows.allSatisfy({ $0["stage"] as String == "preparing" }) else { return nil }
        return try rows.map {
            guard let id = UUID(uuidString: $0["intent_id"]) else { throw V2ResourceJournalError.invalidRecord }
            return id
        }
    }

    /// One transaction freezes the reviewed scope and withdraws every parent
    /// before a handoff can race the resource cancellation commands.
    func cancelResourcePreparation(_ plan: V2ResourcePreparationCancellationPlan) throws -> [UUID] {
        try databasePool.write { db in
            let current = try Self.preparationCancellationParents(plan.transfer, db: db, includingReady: true)
            guard current == plan.intents, !plan.intents.isEmpty else { throw V2ResourceTransferManagementError.actionUnavailable }
            let placeholders = Array(repeating: "?", count: plan.intents.count).joined(separator: ",")
            let ids = StatementArguments(plan.intents.map(\.uuidString))
            let uploads = try String.fetchAll(db, sql: "SELECT DISTINCT job_id FROM v2_send_intent_dependencies WHERE intent_id IN (\(placeholders)) ORDER BY job_id", arguments: ids)
            let imports = try String.fetchAll(db, sql: "SELECT DISTINCT job_id FROM v2_send_intent_import_dependencies WHERE intent_id IN (\(placeholders)) ORDER BY job_id", arguments: ids)
            try db.execute(sql: "UPDATE v2_send_intents SET stage='cancelled' WHERE intent_id IN (\(placeholders)) AND stage='preparing'", arguments: ids)
            guard db.changesCount == plan.intents.count else { throw V2ResourceTransferManagementError.actionUnavailable }
            var cancelledUploads: [UUID] = []
            for raw in uploads {
                guard let id = UUID(uuidString: raw) else { throw V2ResourceJournalError.invalidRecord }
                guard try !Self.preparationHasLiveMessageConsumer(raw, imported: false, db: db),
                      try !Self.preparationUploadHasAvatarConsumer(id, db: db),
                      let job = try Self.readResourceTransfer(id, db: db),
                      ![.ready,.cancelled,.rejected,.expired].contains(job.stage) else { continue }
                try db.execute(sql: """
                    UPDATE v2_resource_transfer_jobs SET cancellation_requested=1,
                        next_action=CASE WHEN EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=v2_resource_transfer_jobs.job_id AND b.state='active') THEN 'awaitingBackground' ELSE 'cancel' END,
                        retry_at=server_retry_not_before,needs_attention=0,user_control='run',action_attempts=0,round_deadline=NULL
                    WHERE job_id=? AND cancellation_requested=0
                    """, arguments: [raw])
                cancelledUploads.append(id)
            }
            for raw in imports where try !Self.preparationHasLiveMessageConsumer(raw, imported: true, db: db) {
                try db.execute(sql: "UPDATE v2_resource_import_jobs SET cancellation_requested=1,user_control='run',retry_at=server_retry_not_before,attempts=0,round_deadline=NULL WHERE job_id=? AND cancellation_requested=0 AND stage NOT IN ('ready','cancelled','failed')", arguments: [raw])
            }
            return cancelledUploads
        }
    }

    private static func preparationHasLiveMessageConsumer(_ id: String, imported: Bool, db: Database) throws -> Bool {
        let table = imported ? "v2_send_intent_import_dependencies" : "v2_send_intent_dependencies"
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) d JOIN v2_send_intents i USING(intent_id) WHERE d.job_id=? AND i.stage<>'cancelled')", arguments: [id]) ?? true
    }
    private static func preparationUploadHasAvatarConsumer(_ id: UUID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM v2_profile_intents WHERE upload_job_id=? AND source_released=0)
                OR EXISTS(SELECT 1 FROM v2_group_avatar_intents WHERE upload_job_id=? AND
                    (stage NOT IN ('committed','cancelled','closed') OR (stage='closed' AND closed_disposition='awaitingDecision')))
            """, arguments: [id.uuidString,id.uuidString]) ?? true
    }
}
