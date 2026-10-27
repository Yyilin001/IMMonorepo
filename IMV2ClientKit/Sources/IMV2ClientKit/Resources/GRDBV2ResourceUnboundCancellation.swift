import Foundation
import GRDB
import IMV2Core

/// A reviewed task identity, scoped to one live account owner. The request is
/// retained for execution-time validation; no provider URL or file path escapes.
public struct V2ResourceUnboundCancellationPlan: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let transfer: V2ManagedResourceTransferID
    let incarnation: UUID
    let owner: UUID
    let identity: V2ResourceUnboundIdentity
}

enum V2ResourceUnboundIdentity: Equatable, Sendable {
    case upload(V2ResourceUploadRequest, V2LocalResourceAssetID)
    case serverImport(V2ResourceImportRequest)
}

extension GRDBV2LocalSyncStore {
    func unboundResourceIdentity(_ transfer: V2ManagedResourceTransferID) throws -> V2ResourceUnboundIdentity? {
        try databasePool.read { try Self.unboundResourceIdentity(transfer, db: $0) }
    }

    static func uploadHasLiveResourceConsumer(_ id: UUID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM v2_send_intent_dependencies d JOIN v2_send_intents i USING(intent_id)
                          WHERE d.job_id=? AND i.stage<>'cancelled')
                OR EXISTS(SELECT 1 FROM v2_profile_intents WHERE upload_job_id=? AND source_released=0)
                OR EXISTS(SELECT 1 FROM v2_group_avatar_intents WHERE upload_job_id=? AND
                    (stage NOT IN ('committed','cancelled','closed') OR (stage='closed' AND closed_disposition='awaitingDecision')))
            """, arguments: [id.uuidString,id.uuidString,id.uuidString]) ?? true
    }

    static func unboundResourceIdentity(_ transfer: V2ManagedResourceTransferID, db: Database) throws -> V2ResourceUnboundIdentity? {
        switch transfer {
        case .download: return nil
        case .upload(let id):
            guard let job = try readResourceTransfer(id, db: db), !job.cancellationRequested,
                  ![.ready,.cancelled,.rejected,.expired].contains(job.stage),
                  try !uploadHasLiveResourceConsumer(id, db: db) else { return nil }
            return .upload(job.request, job.localAssetID)
        case .serverImport(let id):
            guard let job = try readResourceImport(id, db: db), !job.cancellationRequested,
                  case .messageAttachment = job.request.targetUsage,
                  job.status.map({ ![.ready,.cancelled,.failed].contains($0.state) }) ?? true,
                  try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM v2_send_intent_import_dependencies d JOIN v2_send_intents i USING(intent_id)
                                  WHERE d.job_id=? AND i.stage<>'cancelled')
                    """, arguments: [id.uuidString]) == false else { return nil }
            return .serverImport(job.request)
        }
    }

    /// Consumer binding and this cancellation both use the same database writer,
    /// so a task acquired by another business flow cannot slip through review.
    func cancelUnboundResource(_ plan: V2ResourceUnboundCancellationPlan) throws -> UUID? {
        try databasePool.write { db in
            guard try Self.unboundResourceIdentity(plan.transfer, db: db) == plan.identity else {
                throw V2ResourceTransferManagementError.actionUnavailable
            }
            switch plan.transfer {
            case .upload(let id):
                try db.execute(sql: """
                    UPDATE v2_resource_transfer_jobs SET cancellation_requested=1,user_control='run',
                    next_action=CASE WHEN EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=v2_resource_transfer_jobs.job_id AND b.state='active') THEN 'awaitingBackground' ELSE 'cancel' END,
                    retry_at=server_retry_not_before,needs_attention=0,action_attempts=0,round_deadline=NULL WHERE job_id=?
                    """, arguments: [id.uuidString])
                return id
            case .serverImport(let id):
                try db.execute(sql: """
                    UPDATE v2_resource_import_jobs SET cancellation_requested=1,user_control='run',
                    retry_at=server_retry_not_before,attempts=0,round_deadline=NULL WHERE job_id=?
                    """, arguments: [id.uuidString])
                return nil
            case .download: throw V2ResourceTransferManagementError.actionUnavailable
            }
        }
    }
}
