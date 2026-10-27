import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// One bounded transaction across the canonical journals. Progress and
    /// retry updates never change the creation-time keyset ordering.
    func managedResourceTransfers(_ query: V2ResourceTransferQuery) throws -> V2ResourceTransferPage {
        try databasePool.read { db in
            var filter = "1=1", arguments = StatementArguments()
            if let group = query.group { filter += " AND group_kind=?"; arguments += [group.rawValue] }
            if let before = query.before {
                filter += " AND (created_at,kind,job_id)<(?,?,?)"
                arguments += [before.createdAt.timeIntervalSince1970,before.id.kind,before.id.value.uuidString]
            }
            arguments += [query.limit + 1]
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM (
                  SELECT 'upload' AS kind,job_id,created_at,
                    CASE WHEN stage IN ('ready','cancelled') AND execution_owner IS NULL AND NOT EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=v2_resource_transfer_jobs.job_id AND b.state='active') THEN 'finished'
                         WHEN stage IN ('rejected','expired') OR needs_attention=1 OR (user_control='pause' AND execution_owner IS NULL AND NOT EXISTS(SELECT 1 FROM v2_background_transfer_tasks b WHERE b.job_id=v2_resource_transfer_jobs.job_id AND b.state='active')) THEN 'attention' ELSE 'active' END AS group_kind
                    FROM v2_resource_transfer_jobs WHERE history_retired=0 OR stage NOT IN ('ready','cancelled')
                  UNION ALL
                  SELECT 'download',job_id,created_at,
                    CASE WHEN state IN ('completed','stopped') THEN 'finished' WHEN state='failed' OR (state='paused' AND resume_requested=0)
                        OR (transport='background' AND state='downloaded' AND issue IS NOT NULL AND resume_requested=0 AND execution_owner IS NULL) THEN 'attention' ELSE 'active' END
                    FROM v2_resource_download_jobs WHERE history_retired=0 OR state NOT IN ('completed','stopped')
                  UNION ALL
                  SELECT 'import',job_id,created_at,
                    CASE WHEN stage IN ('ready','cancelled') AND execution_owner IS NULL THEN 'finished'
                         WHEN stage='failed' OR ((attempts>=5 OR user_control='pause') AND execution_owner IS NULL) THEN 'attention' ELSE 'active' END
                    FROM v2_resource_import_jobs WHERE history_retired=0 OR stage NOT IN ('ready','cancelled')
                ) WHERE \(filter) ORDER BY created_at DESC,kind DESC,job_id DESC LIMIT ?
                """, arguments: arguments)
            let entries = try rows.prefix(query.limit).map { row -> V2ManagedResourceTransfer in
                guard let id = UUID(uuidString: row["job_id"]), let group = V2ResourceTransferGroup(rawValue: row["group_kind"]) else {
                    throw V2ResourceJournalError.invalidRecord
                }
                let stamp = Date(timeIntervalSince1970: row["created_at"])
                switch row["kind"] as String {
                case "upload": return try Self.managedUpload(id, createdAt: stamp, group: group, db: db)
                case "download": return try Self.managedDownload(id, createdAt: stamp, group: group, db: db)
                case "import": return try Self.managedImport(id, createdAt: stamp, group: group, db: db)
                default: throw V2ResourceJournalError.invalidRecord
                }
            }
            return .init(entries: entries, nextCursor: rows.count > query.limit ? entries.last.map { .init(createdAt: $0.createdAt, id: $0.id) } : nil)
        }
    }

    private static func managedUpload(_ id: UUID, createdAt: Date, group: V2ResourceTransferGroup, db: Database) throws -> V2ManagedResourceTransfer {
        guard let job = try readResourceTransfer(id, db: db) else { throw V2ResourceJournalError.invalidRecord }
        let owner = try String.fetchOne(db, sql: "SELECT execution_owner FROM v2_resource_transfer_jobs WHERE job_id=?", arguments: [id.uuidString])
        let nativeActive = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_background_transfer_tasks WHERE job_id=? AND state='active')", arguments: [id.uuidString]) ?? false
        let busy = owner != nil || nativeActive
        let cancellationStalled = job.cancellationRequested && job.stage == .paused && job.needsAttention && !busy
        let phase: V2ManagedResourceTransferPhase
        if busy, job.stage == .ready { phase = .verifying }
        else if busy, job.stage == .cancelled { phase = .cancelling }
        else if cancellationStalled { phase = .requiresAttention(.cancellationUnconfirmed) }
        else if job.cancellationRequested && ![.ready,.cancelled,.rejected,.expired].contains(job.stage) { phase = .cancelling }
        else if job.control == .pause && ![.ready,.cancelled,.rejected,.expired].contains(job.stage) { phase = busy ? .pausing : .paused }
        else {
            switch job.stage {
            case .ready: phase = .completed
            case .cancelled: phase = .cancelled
            case .rejected: phase = .failed(.rejected)
            case .expired: phase = .failed(.expired)
            case .paused: phase = job.needsAttention ? .requiresAttention(failure(job.lastError)) : (job.retryAt > Date() ? .waitingRetry(job.retryAt) : .queued)
            case .processing: phase = .processing
            case .prepared: phase = busy ? .preparing : (job.retryAt > Date() ? .waitingRetry(job.retryAt) : .queued)
            case .transferring:
                switch job.nextAction {
                case .status: phase = .confirming
                case .finalize: phase = .verifying
                case .cancel: phase = .cancelling
                default: phase = busy ? .transferring : (job.retryAt > Date() ? .waitingRetry(job.retryAt) : .queued)
                }
            }
        }
        var confirmed: Int64 = 0
        for part in job.session?.confirmedParts ?? [] {
            let (sum, overflow) = confirmed.addingReportingOverflow(part.byteCount)
            guard !overflow, sum <= job.request.byteCount else { throw V2ResourceJournalError.invalidRecord }
            confirmed = sum
        }
        let purpose: V2ResourceTransferPurpose
        switch job.request.usage { case .messageAttachment: purpose = .attachment; case .userAvatar: purpose = .personalAvatar; case .groupAvatar: purpose = .groupAvatar }
        let retryable = job.stage == .paused && job.needsAttention && job.control == .run && !job.cancellationRequested && !busy
        let pausable = job.control == .run && !job.cancellationRequested && !job.needsAttention && ![.ready,.cancelled,.rejected,.expired].contains(job.stage)
        let resumable = job.control == .pause && !job.cancellationRequested && !busy && ![.ready,.cancelled,.rejected,.expired].contains(job.stage)
        let cancellationCount = try preparationCancellationParents(.upload(id), db: db)?.count
        let unbound = try unboundResourceIdentity(.upload(id), db: db) != nil
        return .init(id: .upload(id), displayName: job.request.displayName, purpose: purpose, mediaID: job.request.mediaID, resource: nil,
            createdAt: createdAt, group: group, phase: phase, totalBytes: job.request.byteCount,
            confirmedBytes: job.stage == .ready ? job.request.byteCount : (confirmed > 0 ? confirmed : nil),
            actions: (retryable ? [.retry] : []) + (cancellationStalled ? [.retryCancellation] : [])
                + (pausable ? [.pause] : []) + (resumable ? [.resume] : [])
                + (unbound ? [.cancelUnbound] : [])
                + (cancellationCount != nil ? [.cancel] : []), cancellableMessageCount: cancellationCount,
            hasBusinessOwners: try !resourceBusinessOwners(.init(transfer: .upload(id), limit: 1), db: db).entries.isEmpty)
    }

    private static func managedDownload(_ id: UUID, createdAt: Date, group: V2ResourceTransferGroup, db: Database) throws -> V2ManagedResourceTransfer {
        guard let row = try Row.fetchOne(db, sql: "SELECT media_id,room_id,message_id,transport,execution_owner,resume_requested,control,state,byte_count,sha256,COALESCE(byte_count,expected_bytes) AS total_bytes,issue,retry_at_milliseconds FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) else { throw V2ResourceJournalError.invalidRecord }
        var phase: V2ManagedResourceTransferPhase
        let control: String = row["control"]
        if control == "cancel", row["state"] as String != "stopped" { phase = .cancelling }
        else if control == "pause" { phase = row["state"] as String == "pausing" || (row["execution_owner"] as String?) != nil ? .pausing : .paused }
        else {
        switch row["state"] as String {
        case "preparing":
            let retry: Int64 = row["retry_at_milliseconds"]
            phase = retry > Int64(Date().timeIntervalSince1970 * 1000) ? .waitingRetry(Date(timeIntervalSince1970: Double(retry) / 1000)) : ((row["execution_owner"] as String?) == nil ? .queued : .preparing)
        case "transferring": phase = .transferring
        case "downloaded":
            phase = row["transport"] as String == "background" && (row["issue"] as String?) != nil && !(row["resume_requested"] as Bool) && (row["execution_owner"] as String?) == nil
                ? .requiresAttention(downloadFailure(row["issue"])) : .verifying
        case "paused":
            if row["resume_requested"] as Bool {
                let retry: Int64 = row["retry_at_milliseconds"]
                phase = retry > Int64(Date().timeIntervalSince1970 * 1000) ? .waitingRetry(Date(timeIntervalSince1970: Double(retry) / 1000)) : ((row["execution_owner"] as String?) == nil ? .queued : .preparing)
            } else { phase = .requiresAttention(downloadFailure(row["issue"])) }
        case "cancelled": phase = .cancelling
        case "completed": phase = .completed
        case "stopped": phase = .cancelled
        case "failed": phase = .failed(downloadFailure(row["issue"]))
        default: throw V2ResourceJournalError.invalidRecord
        }
        }
        if (row["byte_count"] as Int64?) == nil, phase == .queued || phase == .preparing {
            phase = .resolvingMetadata
        }
        // A system task's metadata is not authority to reveal a revoked
        // message's filename or open the previous resource detail.
        let source = try Row.fetchOne(db, sql: "SELECT r.home_id,r.media_id,e.display_name FROM v2_resource_references r JOIN v2_resource_entries e USING(home_kind,home_id,media_id) WHERE r.home_kind='room' AND r.home_id=? AND r.context_id=? AND r.media_id=? AND " + visibleResourceMessageReferenceSQL + " LIMIT 1", arguments: [row["room_id"] as String?,row["message_id"] as String?,row["media_id"] as String])
        let resource: V2ResourceKey? = try source.map { .init(home: .room(try .init($0["home_id"])), mediaID: try .init($0["media_id"])) }
        let name: V2ResourceDisplayName? = try source.map { try .init($0["display_name"]) }
        let state: String = row["state"]
        let foreground = row["transport"] as String == "foreground"
        let mayCancel = foreground ? ((control != "cancel" && ["preparing","transferring","downloaded","paused"].contains(state)) || (control == "cancel" && state == "cancelled" && (row["execution_owner"] as String?) == nil)) : ["preparing","transferring","downloaded","pausing","paused","cancelled"].contains(state)
        let accessible: Bool
        if let room: String = row["room_id"], let message: String = row["message_id"] {
            accessible = try V2ResourceFileJournal.messageMayResolve(.init(roomID: .init(room), messageID: .init(message)), mediaID: .init(row["media_id"]), db: db)
        } else { accessible = false }
        let mayPause = mayCancel && control == "run" && accessible && (foreground
            ? (state != "paused" || row["resume_requested"] as Bool)
            : (["preparing","transferring"].contains(state) && (row["byte_count"] as Int64?) != nil))
        let retryableState = state == "paused" || (!foreground && state == "downloaded" && (row["issue"] as String?) != nil)
        let mayRetry = control == "run" && retryableState && (row["execution_owner"] as String?) == nil && !(row["resume_requested"] as Bool) && accessible && ((row["byte_count"] as Int64?) != nil || foreground)
        let mayResume = control == "pause" && state == "paused" && (row["execution_owner"] as String?) == nil && accessible
        return try .init(id: .download(id), displayName: name, purpose: .download, mediaID: .init(row["media_id"]), resource: resource,
            createdAt: createdAt, group: group, phase: phase, totalBytes: row["total_bytes"],
            confirmedBytes: state == "completed" ? row["total_bytes"] : nil,
            actions: (mayRetry ? [.retry] : []) + (mayPause ? [.pause] : []) + (mayResume ? [.resume] : []) + (mayCancel ? [.cancel] : []), cancellableMessageCount: nil, hasBusinessOwners: false)
    }

    private static func managedImport(_ id: UUID, createdAt: Date, group: V2ResourceTransferGroup, db: Database) throws -> V2ManagedResourceTransfer {
        guard let job = try readResourceImport(id, db: db) else { throw V2ResourceJournalError.invalidRecord }
        let owner = try String.fetchOne(db, sql: "SELECT execution_owner FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString])
        let phase: V2ManagedResourceTransferPhase
        let state = job.status?.state ?? .pending
        let cancellationStalled = job.cancellationRequested && job.attempts >= 5 && owner == nil && ![.ready,.cancelled,.failed].contains(state)
        if owner != nil, state == .ready { phase = .verifying }
        else if owner != nil, state == .cancelled { phase = .cancelling }
        else if cancellationStalled { phase = .requiresAttention(.cancellationUnconfirmed) }
        else if job.cancellationRequested && ![.ready,.cancelled,.failed].contains(state) { phase = .cancelling }
        else if job.control == .pause && ![.ready,.cancelled,.failed].contains(state) { phase = owner == nil ? .paused : .pausing }
        else if job.attempts >= 5 && owner == nil && ![.ready,.cancelled,.failed].contains(state) { phase = .requiresAttention(.needsAttention) }
        else {
            switch state {
            case .pending: phase = owner != nil ? .preparing : (job.retryAt > Date() ? .waitingRetry(job.retryAt) : .queued)
            case .copying: phase = .transferring
            case .processing: phase = .processing
            case .ready: phase = .completed
            case .cancelled: phase = .cancelled
            case .failed: phase = .failed(.rejected)
            }
        }
        let cancellationCount = try preparationCancellationParents(.serverImport(id), db: db)?.count
        let unbound = try unboundResourceIdentity(.serverImport(id), db: db) != nil
        let nonterminal = ![.ready,.cancelled,.failed].contains(state)
        let pausable = job.control == .run && !job.cancellationRequested && nonterminal && (job.attempts < 5 || owner != nil)
        let resumable = job.control == .pause && !job.cancellationRequested && nonterminal && owner == nil
        return .init(id: .serverImport(id), displayName: nil, purpose: .serverImport, mediaID: job.request.targetMediaID, resource: nil,
            createdAt: createdAt, group: group, phase: phase, totalBytes: nil, confirmedBytes: nil,
            actions: (job.attempts >= 5 && job.control == .run && owner == nil && !job.cancellationRequested && nonterminal ? [.retry] : [])
                + (cancellationStalled ? [.retryCancellation] : [])
                + (pausable ? [.pause] : []) + (resumable ? [.resume] : [])
                + (unbound ? [.cancelUnbound] : [])
                + (cancellationCount != nil ? [.cancel] : []), cancellableMessageCount: cancellationCount, hasBusinessOwners: !(try resourceBusinessOwners(.init(transfer: .serverImport(id), limit: 1), db: db).entries.isEmpty))
    }

    private static func failure(_ code: String?) -> V2ResourceTransferFailure {
        switch code { case "transport", "network": .network; case "fileUnavailable": .sourceUnavailable; case "rejected": .rejected; default: .needsAttention }
    }

    /// A new confirmation round for the original cancellation, never a retry
    /// of the original upload/import. Capability and mutation share a transaction.
    func retryManagedResourceCancellation(_ id: V2ManagedResourceTransferID) throws {
        try databasePool.write { db in
            switch id {
            case .upload(let key):
                guard try Self.readResourceTransfer(key, db: db) != nil,
                      try Self.managedUpload(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.retryCancellation)
                else { throw V2ResourceTransferManagementError.actionUnavailable }
                try db.execute(sql: """
                    UPDATE v2_resource_transfer_jobs SET action_attempts=0,poll_attempts=0,
                    round_deadline=NULL,needs_attention=0,retry_at=server_retry_not_before,
                    last_error=NULL,next_action='cancel' WHERE job_id=?
                    """, arguments: [key.uuidString])
            case .serverImport(let key):
                guard try Self.readResourceImport(key, db: db) != nil,
                      try Self.managedImport(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.retryCancellation)
                else { throw V2ResourceTransferManagementError.actionUnavailable }
                try db.execute(sql: """
                    UPDATE v2_resource_import_jobs SET attempts=0,poll_attempts=0,
                    round_deadline=NULL,retry_at=server_retry_not_before WHERE job_id=?
                    """, arguments: [key.uuidString])
            case .download: throw V2ResourceTransferManagementError.actionUnavailable
            }
        }
    }

    private static func downloadFailure(_ code: String?) -> V2ResourceTransferFailure {
        switch code { case "policy": .automaticDownloadRestricted; case "network": .network; case "integrity": .integrity; case "space": .space; case "unavailable": .sourceUnavailable; default: .needsAttention }
    }

    /// Revalidate the capability in the same write transaction. The account's
    /// existing recovery observation performs I/O; UI never starts another loop.
    func retryManagedResourceTransfer(_ id: V2ManagedResourceTransferID) throws {
        try databasePool.write { db in
            let available: Bool
            switch id {
            case .upload(let key):
                guard try Self.readResourceTransfer(key, db: db) != nil else { throw V2ResourceTransferManagementError.actionUnavailable }
                available = try Self.managedUpload(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.retry)
                guard available else { throw V2ResourceTransferManagementError.actionUnavailable }
                try Self.retryResourceTransfer(id: key, db: db)
            case .serverImport(let key):
                guard try Self.readResourceImport(key, db: db) != nil else { throw V2ResourceTransferManagementError.actionUnavailable }
                available = try Self.managedImport(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.retry)
                guard available else { throw V2ResourceTransferManagementError.actionUnavailable }
                try Self.retryResourceImport(id: key, db: db)
            case .download(let key):
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_download_jobs WHERE job_id=?)", arguments: [key.uuidString]) == true else { throw V2ResourceTransferManagementError.actionUnavailable }
                available = try Self.managedDownload(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.retry)
                guard available else { throw V2ResourceTransferManagementError.actionUnavailable }
                try db.execute(sql: "UPDATE v2_resource_download_jobs SET resume_requested=1,attempt_count=0,automatic_retry_allowed=0,retry_at_milliseconds=0,issue=NULL,work_priority=? WHERE job_id=?", arguments: [V2NetworkWorkPriority.interactive.rawValue,key.uuidString])
            }
        }
    }

    func requestManagedUploadPause(_ key: UUID) throws {
        try databasePool.write { db in
            guard try Self.readResourceTransfer(key, db: db) != nil,
                  try Self.managedUpload(key, createdAt: .distantPast, group: .active, db: db).actions.contains(.pause)
            else { throw V2ResourceTransferManagementError.actionUnavailable }
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET user_control='pause' WHERE job_id=?", arguments: [key.uuidString])
        }
    }

    /// This stops local polling/admission. It cannot suspend server-side copy.
    /// An already claimed request keeps its owner until it actually returns.
    func requestManagedImportPause(_ key: UUID) throws {
        try databasePool.write { db in
            guard try Self.readResourceImport(key, db: db) != nil,
                  try Self.managedImport(key, createdAt: .distantPast, group: .active, db: db).actions.contains(.pause)
            else { throw V2ResourceTransferManagementError.actionUnavailable }
            try db.execute(sql: "UPDATE v2_resource_import_jobs SET user_control='pause' WHERE job_id=?", arguments: [key.uuidString])
        }
    }

    func resumeManagedResourceTransfer(_ id: V2ManagedResourceTransferID) throws {
        try databasePool.write { db in
            if case .serverImport(let key) = id {
                guard try Self.readResourceImport(key, db: db) != nil,
                      try Self.managedImport(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.resume)
                else { throw V2ResourceTransferManagementError.actionUnavailable }
                try db.execute(sql: """
                    UPDATE v2_resource_import_jobs SET user_control='run',attempts=0,
                    poll_attempts=0,round_deadline=NULL,retry_at=server_retry_not_before WHERE job_id=?
                    """, arguments: [key.uuidString])
                return
            }
            if case .upload(let key) = id {
                guard try Self.readResourceTransfer(key, db: db) != nil,
                      try Self.managedUpload(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.resume)
                else { throw V2ResourceTransferManagementError.actionUnavailable }
                try db.execute(sql: """
                    UPDATE v2_resource_transfer_jobs SET user_control='run',needs_attention=0,
                    action_attempts=0,poll_attempts=0,round_deadline=NULL,last_error=NULL,
                    retry_at=server_retry_not_before,next_action=CASE WHEN session IS NULL THEN 'create' ELSE 'status' END
                    WHERE job_id=?
                    """, arguments: [key.uuidString])
                return
            }
            guard case .download(let key) = id else { throw V2ResourceTransferManagementError.actionUnavailable }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_download_jobs WHERE job_id=?)", arguments: [key.uuidString]) == true,
                  try Self.managedDownload(key, createdAt: .distantPast, group: .attention, db: db).actions.contains(.resume) else { throw V2ResourceTransferManagementError.actionUnavailable }
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET control='run',resume_requested=1,attempt_count=0,automatic_retry_allowed=0,retry_at_milliseconds=0,issue=NULL,work_priority=? WHERE job_id=?", arguments: [V2NetworkWorkPriority.interactive.rawValue,key.uuidString])
        }
    }
}
