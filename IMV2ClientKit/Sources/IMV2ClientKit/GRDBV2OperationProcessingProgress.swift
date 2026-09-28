import Foundation
import GRDB
import IMV2Core

/// A domain constructs this only after validating a bound server progress result against its frozen command.
/// Its full proof belongs in the domain journal, atomically with the shared scheduling update.
struct V2VerifiedOperationProgress:Sendable {
    let identity:V2OperationIdentity
    let fingerprint:V2OperationFingerprint
    let canonicalProof:Data
    init<Proof:Encodable & Sendable>(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,proof:Proof) throws {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(proof)
        guard !bytes.isEmpty,bytes.count<=1_048_576 else { throw V2OperationWorkError.invalidRecord }
        self.identity=identity;self.fingerprint=fingerprint;self.canonicalProof=bytes
    }
}
extension GRDBV2LocalSyncStore {
    /// Returns false when terminal authority already won; callers must then leave their old progress unchanged.
    @discardableResult static func recordProcessingProgress(_ progress:V2VerifiedOperationProgress,
        claim:V2OperationWorkClaim,until:Date,scheduling:V2OperationSchedulingState = .backingOff,db:Database) throws -> Bool {
        guard [.backingOff,.needsAttention].contains(scheduling),progress.identity==claim.work.identity,
            progress.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        let work=try requireOperationWork(claim.work.id,db:db)
        guard work.identity==progress.identity,work.fingerprint==progress.fingerprint else { throw V2OperationWorkError.identityConflict }
        if work.execution.isTerminal { return false }
        try requireOperationClaim(claim,db:db)
        guard work.submissionStarted else { throw V2OperationWorkError.invalidTransition }
        let time=try commandRetryTimestamp(until)
        try db.execute(sql:"""
            UPDATE v2_operation_work SET execution_state='processing',scheduling_state=?,next_action_kind='reconcile',
                next_action_at=MAX(next_action_at,?),claim_id=NULL,claim_owner_id=NULL,claim_until=NULL,
                work_revision=work_revision+1,last_error_code='PROCESSING_RESULT'
            WHERE work_id=?
            """,arguments:[scheduling.rawValue,time,work.id.uuidString])
        return true
    }
}
