import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    // One original command, one authoritative proof (common 64 KiB cap),
    // and bounded identity/claim/status columns. No command is duplicated.
    static let readReceiptControlOverheadBytes: Int64 = 65_536 + 2_048
    static let maximumControlRecoveryCount = 64
    static let maximumControlRecoveryBytes: Int64 = 1_048_576
    static let operationWorkSchemaSQL = """
        CREATE TABLE v2_operation_work (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            work_id TEXT NOT NULL UNIQUE,
            intent_id TEXT NOT NULL,
            account_id TEXT NOT NULL,
            identity_key TEXT NOT NULL UNIQUE,
            operation_kind TEXT NOT NULL,
            identity BLOB NOT NULL,
            fingerprint_version INTEGER NOT NULL,
            fingerprint BLOB NOT NULL CHECK(length(fingerprint)=32),
            ordering_key TEXT NOT NULL CHECK(length(ordering_key)>0),
            payload_bytes INTEGER NOT NULL CHECK(payload_bytes>=0),
            admission_class TEXT NOT NULL DEFAULT 'ordinary' CHECK(admission_class IN ('ordinary','readReceiptControl')),
            execution_state TEXT NOT NULL CHECK(execution_state IN
                ('prepared','submitting','processing','awaitingConfirmation','committed','rejected',
                 'conflicted','closed','cancelledLocally','expiredUnsubmitted')),
            scheduling_state TEXT NOT NULL CHECK(scheduling_state IN
                ('ready','claimed','waitingForDependency','waitingForAuthentication','waitingForNetwork',
                 'backingOff','needsAttention','suspended','finished')),
            submission_started INTEGER NOT NULL DEFAULT 0 CHECK(submission_started IN (0,1)),
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count>=0 AND attempt_count<=2147483647),
            submission_round_attempts INTEGER NOT NULL DEFAULT 0 CHECK(submission_round_attempts>=0),
            reconciliation_round_attempts INTEGER NOT NULL DEFAULT 0 CHECK(reconciliation_round_attempts>=0),
            submission_round_deadline REAL, reconciliation_round_deadline REAL,
            next_action_kind TEXT NOT NULL DEFAULT 'submit' CHECK(next_action_kind IN ('submit','reconcile')),
            next_action_at REAL NOT NULL,
            admission_deadline REAL,
            claim_id TEXT, claim_owner_id TEXT, claim_until REAL,
            work_revision INTEGER NOT NULL DEFAULT 1 CHECK(work_revision>0),
            last_error_code TEXT, terminal_receipt BLOB,
            created_at REAL NOT NULL, completed_at REAL,
            CHECK((claim_id IS NULL)=(claim_owner_id IS NULL)),
            CHECK((claim_id IS NULL)=(claim_until IS NULL)),
            CHECK((claim_id IS NOT NULL)=(scheduling_state='claimed')),
            CHECK((execution_state IN ('committed','rejected','conflicted','closed','cancelledLocally','expiredUnsubmitted'))=(scheduling_state='finished')),
            CHECK((execution_state IN ('committed','rejected','conflicted','closed'))=(terminal_receipt IS NOT NULL)),
            CHECK(execution_state NOT IN ('submitting','processing','awaitingConfirmation') OR submission_started=1),
            CHECK(execution_state NOT IN ('prepared','cancelledLocally','expiredUnsubmitted') OR submission_started=0),
            CHECK((scheduling_state='finished')=(completed_at IS NOT NULL)),
            CHECK(admission_class='ordinary' OR
                (operation_kind='readReceipt' AND submission_started=1 AND next_action_kind='reconcile'
                 AND admission_deadline IS NULL AND payload_bytes<=71680))
        );
        CREATE INDEX v2_operation_work_due ON v2_operation_work(next_action_at,local_sequence)
            WHERE scheduling_state IN ('ready','backingOff');
        CREATE INDEX v2_operation_work_order ON v2_operation_work(ordering_key,local_sequence)
            WHERE scheduling_state<>'finished';
        CREATE INDEX v2_operation_work_intent ON v2_operation_work(intent_id,local_sequence);
        CREATE INDEX v2_operation_work_active ON v2_operation_work(account_id,payload_bytes)
            WHERE scheduling_state<>'finished';
        CREATE INDEX v2_operation_work_retention ON v2_operation_work(completed_at,local_sequence)
            WHERE execution_state='committed' AND scheduling_state='finished';
        CREATE TABLE v2_operation_dependencies (
            child_work_id TEXT NOT NULL REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            parent_work_id TEXT NOT NULL REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            PRIMARY KEY(child_work_id,parent_work_id),
            CHECK(child_work_id<>parent_work_id)
        );
        CREATE INDEX v2_operation_dependency_parent ON v2_operation_dependencies(parent_work_id,child_work_id);
        """

    /// This internal transaction helper must be called beside the domain payload
    /// insert. No public API can enqueue a payload-less executable command.
    @discardableResult
    static func insertOperationWork(_ input: V2NewOperationWork, now: Date,
                                    limits: V2OperationWorkLimits = .init(), readReceiptControlRecovery: Bool = false, db: Database) throws -> V2OperationWork {
        let time = try commandRetryTimestamp(now)
        guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == input.identity.accountID.rawValue
        else { throw V2OperationWorkError.accountMismatch }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_operation_work WHERE identity_key=?", arguments: [input.identity.storageKey]) {
            let existing = try decodeOperationWork(row)
            let dependencies = try String.fetchAll(db, sql: "SELECT parent_work_id FROM v2_operation_dependencies WHERE child_work_id=?", arguments: [existing.id.uuidString])
            guard existing.id == input.id, existing.intentID == input.intentID, existing.identity == input.identity,
                  existing.fingerprint == input.fingerprint, existing.orderingKey == input.orderingKey,
                  existing.admissionDeadline == input.admissionDeadline,
                  row["payload_bytes"] as Int64 == input.payloadBytes,
                  row["admission_class"] as String == (readReceiptControlRecovery ? "readReceiptControl" : "ordinary"),
                  Set(dependencies) == Set(input.dependencyIDs.map(\.uuidString)) else {
                throw V2OperationWorkError.identityConflict
            }
            return existing
        }
        guard input.dependencyIDs.count <= limits.maximumDependencies else { throw V2OperationWorkError.capacityExceeded }
        if readReceiptControlRecovery {
            // Charge the sole encoded command plus the common 65,536-byte
            // authoritative receipt upper bound plus 2,048 bytes of fixed
            // identity/claim/status metadata. Both count and bytes
            // are independent of ordinary admission, and never borrow from it.
            // Only the verified archive transfer can request this classification.
            // The archive owns the sole frozen command until this transaction moves it.
            guard input.identity.kind == .readReceipt, input.id == input.intentID,
                  input.admissionDeadline == nil, input.dependencyIDs.isEmpty,
                  let archived = try Row.fetchOne(db, sql: "SELECT command FROM v2_read_receipt_archives WHERE work_id=?", arguments: [input.id.uuidString])
            else { throw V2OperationWorkError.invalidTransition }
            let bytes: Data = archived["command"]
            let command = try JSONDecoder().decode(V2RecordReadReceiptCommand.self, from: bytes)
            guard bytes.count <= 4_096, input.payloadBytes == Int64(bytes.count) + readReceiptControlOverheadBytes,
                  input.orderingKey == "readReceiptControl:" + command.roomID.rawValue + ":" + input.id.uuidString,
                  try command.identity == input.identity, try command.fingerprint == input.fingerprint
            else { throw V2OperationWorkError.identityConflict }
            let reservation = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n,COALESCE(SUM(payload_bytes),0) AS b FROM v2_operation_work WHERE admission_class='readReceiptControl' AND scheduling_state<>'finished'")!
            let count: Int = reservation["n"], total: Int64 = reservation["b"]
            guard count < maximumControlRecoveryCount, total >= 0, total <= maximumControlRecoveryBytes,
                  input.payloadBytes <= maximumControlRecoveryBytes - total else { throw V2OperationWorkError.capacityExceeded }
        } else {
            try requireOperationCapacity(adding: input.payloadBytes, excludingIntent: input.intentID, limits: limits, db: db)
        }
        // Parents must pre-exist and are immutable. Consequently insertion can
        // never create a dependency cycle, including across process restarts.
        for parent in input.dependencyIDs {
            guard let row = try Row.fetchOne(db, sql: "SELECT account_id FROM v2_operation_work WHERE work_id=?", arguments: [parent.uuidString]),
                  row["account_id"] as String == input.identity.accountID.rawValue else {
                throw V2OperationWorkError.dependencyUnavailable
            }
        }
        let deadline = try input.admissionDeadline.map(commandRetryTimestamp)
        try db.execute(sql: """
            INSERT INTO v2_operation_work(work_id,intent_id,account_id,identity_key,operation_kind,identity,fingerprint_version,fingerprint,
                ordering_key,payload_bytes,admission_class,execution_state,scheduling_state,submission_started,next_action_kind,next_action_at,admission_deadline,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?, 'ready',?,?, ?,?,?)
            """, arguments: [input.id.uuidString, input.intentID.uuidString, input.identity.accountID.rawValue,
                input.identity.storageKey, input.identity.kind.rawValue, try JSONEncoder().encode(input.identity), Int(input.fingerprint.version), input.fingerprint.digest,
                input.orderingKey, input.payloadBytes,
                readReceiptControlRecovery ? "readReceiptControl" : "ordinary",
                readReceiptControlRecovery ? "awaitingConfirmation" : "prepared",
                readReceiptControlRecovery ? 1 : 0, readReceiptControlRecovery ? "reconcile" : "submit",
                time, deadline, time])
        for parent in input.dependencyIDs {
            try db.execute(sql: "INSERT INTO v2_operation_dependencies(child_work_id,parent_work_id) VALUES(?,?)",
                           arguments: [input.id.uuidString, parent.uuidString])
        }
        return try requireOperationWork(input.id, db: db)
    }

    public func operationWork(id: UUID) throws -> V2OperationWork? {
        try databasePool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM v2_operation_work WHERE work_id=?", arguments: [id.uuidString]).map(Self.decodeOperationWork)
        }
    }

    /// A deferred head blocks its key even if a younger row is already due.
    /// The query returns bounded identities, never all payloads.
    public func dueOperationWork(now: Date, limit: Int = 32, kinds: Set<V2OperationKind>? = nil, firstAttemptSince: Date? = nil, excludingFirstAttemptsSince: Date? = nil) throws -> [V2OperationWork] {
        guard (1...32).contains(limit) else { throw V2OperationWorkError.invalidRecord }
        let time = try Self.commandRetryTimestamp(now)
        let preference = try Self.operationAdmissionPredicate(firstAttemptSince: firstAttemptSince, excludingFirstAttemptsSince: excludingFirstAttemptsSince)
        return try databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT work.* FROM v2_operation_work work
                WHERE work.scheduling_state IN ('ready','backingOff') AND work.next_action_at<=?
                  AND \(Self.operationKindPredicate(kinds))
                  AND \(preference)
                  AND \(Self.operationHeadPredicate)
                  AND \(Self.operationDependencyPredicate)
                ORDER BY work.next_action_at,work.local_sequence LIMIT ?
                """, arguments: [time, limit]).map(Self.decodeOperationWork)
        }
    }

    private static func operationAdmissionPredicate(firstAttemptSince: Date?, excludingFirstAttemptsSince: Date?) throws -> String {
        guard firstAttemptSince == nil || excludingFirstAttemptsSince == nil else { throw V2OperationWorkError.invalidRecord }
        if let date = firstAttemptSince {
            return "work.attempt_count=0 AND work.created_at>=\(try commandRetryTimestamp(date))"
        }
        if let date = excludingFirstAttemptsSince {
            return "NOT (work.attempt_count=0 AND work.created_at>=\(try commandRetryTimestamp(date)))"
        }
        return "1"
    }

    /// Used only when the dispatcher has reserved its last slot for fresh interaction.
    public func nextInteractiveOperationAttemptAt(kinds: Set<V2OperationKind>, since: Date) throws -> Date? {
        let preference = try Self.operationAdmissionPredicate(firstAttemptSince: since, excludingFirstAttemptsSince: nil)
        return try databasePool.read { db in
            try Double.fetchOne(db, sql: """
                SELECT MIN(work.next_action_at) FROM v2_operation_work work
                WHERE work.scheduling_state IN ('ready','backingOff') AND \(preference)
                  AND \(Self.operationKindPredicate(kinds))
                  AND \(Self.operationHeadPredicate) AND \(Self.operationDependencyPredicate)
                """).map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Write ahead of domain I/O. A bounded dispatcher slot owns this step;
    /// leaf network admission may still wait. The durable attempt is consumed
    /// even if the process dies before sending. Expiry/budget changes commit.
    public func claimOperationWork(id: UUID, ownerID: UUID, action: V2OperationWorkAction,
                                   now: Date, leaseDuration: TimeInterval = 30,
                                   maximumAutomaticAttempts: Int = 5,
                                   roundDuration: TimeInterval = 60) throws -> V2OperationWorkClaimResult {
        guard leaseDuration.isFinite, leaseDuration > 0, roundDuration.isFinite, roundDuration > 0, maximumAutomaticAttempts > 0,
              maximumAutomaticAttempts <= Int(Int32.max) else { throw V2OperationWorkError.invalidRecord }
        let time = try Self.commandRetryTimestamp(now)
        let until = try Self.commandRetryTimestamp(now.addingTimeInterval(leaseDuration))
        return try databasePool.write { db in
            let work = try Self.requireOperationWork(id, db: db)
            guard [.ready, .backingOff].contains(work.scheduling), work.nextActionAt.timeIntervalSince1970 <= time,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_operation_work work WHERE work.work_id=? AND \(Self.operationHeadPredicate) AND \(Self.operationDependencyPredicate))",
                                    arguments: [id.uuidString]) == true else { return .unavailable }
            if action == .submit,
               try String.fetchOne(db, sql: "SELECT admission_class FROM v2_operation_work WHERE work_id=?", arguments: [id.uuidString]) == "readReceiptControl" {
                return .unavailable
            }
            // A frozen sensitive admission expires into original-identity query/close,
            // never a new authorization or a fabricated server rejection. Its first
            // physical step is reconciliation and consumes that round's budget.
            // A frozen invitation without a command was explicitly handed off
            // for original-identity query/close, not for submission preparation.
            var invitationRecoveryOnly = false
            if [.groupInvite, .groupJoinRequest, .groupJoinDecision].contains(work.identity.kind) {
                invitationRecoveryOnly = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_invitation_operation_intents WHERE work_id=? AND command IS NULL AND preparation_state='frozen')", arguments: [id.uuidString]) == true
            }
            let closeSensitiveAdmission = !work.submissionStarted
                && [.moderation, .memberMute, .moderatedMemberRemoval, .membership, .groupRoom, .groupInvite, .groupJoinRequest, .groupJoinDecision, .relationship, .userBlock, .strangerMessagePreference, .userAddPreference, .readReceiptPreference, .liveActivityPreference, .pinnedMessage, .groupAnnouncement, .groupPermission, .groupRole].contains(work.identity.kind)
                && (work.admissionDeadline.map { $0 <= now } ?? false)
            let action: V2OperationWorkAction = closeSensitiveAdmission || invitationRecoveryOnly ? .reconcile : action
            if !work.submissionStarted, !closeSensitiveAdmission, !invitationRecoveryOnly, let deadline = work.admissionDeadline, deadline <= now {
                try Self.finishLocalOperation(id, state: .expiredUnsubmitted, now: time, db: db)
                return .expiredUnsubmitted
            }
            if action == .submit, work.submissionStarted, let deadline = work.admissionDeadline, deadline <= now {
                try db.execute(sql: "UPDATE v2_operation_work SET next_action_kind='reconcile',work_revision=work_revision+1 WHERE work_id=?", arguments: [id.uuidString])
                return .unavailable
            }
            let roundAttempts = action == .submit ? work.submissionRoundAttempts : work.reconciliationRoundAttempts
            let roundDeadline = action == .submit ? work.submissionRoundDeadline : work.reconciliationRoundDeadline
            guard work.attemptCount < Int(Int32.max), roundAttempts < maximumAutomaticAttempts,
                  roundDeadline.map({ $0 > now }) ?? true else {
                try db.execute(sql: "UPDATE v2_operation_work SET scheduling_state='needsAttention',work_revision=work_revision+1 WHERE work_id=?", arguments: [id.uuidString])
                return .needsAttention
            }
            switch action {
            case .submit:
                guard work.execution == .prepared || work.execution == .awaitingConfirmation else { return .unavailable }
            case .reconcile:
                guard work.submissionStarted || closeSensitiveAdmission || invitationRecoveryOnly else { return .unavailable }
            }
            let roundPrefix = action == .submit ? "submission" : "reconciliation"
            let deadline = try Self.commandRetryTimestamp(roundDeadline ?? now.addingTimeInterval(roundDuration))
            let claim = UUID()
            try db.execute(sql: """
                UPDATE v2_operation_work SET scheduling_state='claimed',claim_id=?,claim_owner_id=?,claim_until=?,
                    submission_started=1,execution_state=?,next_action_kind=?,attempt_count=attempt_count+1,work_revision=work_revision+1,
                    \(roundPrefix)_round_attempts=\(roundPrefix)_round_attempts+1,\(roundPrefix)_round_deadline=?
                WHERE work_id=?
                """, arguments: [claim.uuidString, ownerID.uuidString, until,
                    action == .submit ? V2OperationExecutionState.submitting.rawValue : (closeSensitiveAdmission || invitationRecoveryOnly ? V2OperationExecutionState.awaitingConfirmation.rawValue : work.execution.rawValue), action.rawValue, deadline, id.uuidString])
            return .claimed(.init(work: try Self.requireOperationWork(id, db: db), action: action, ownerID: ownerID, claimID: claim))
        }
    }

    /// Called only after the previous process/owner has been drained. A timer
    /// alone cannot prove its I/O stopped, so expired same-owner claims stay held.
    public func recoverOperationClaims(forNewOwner ownerID: UUID, now: Date) throws {
        let time = try Self.commandRetryTimestamp(now)
        try databasePool.write { db in
            try db.execute(sql: """
                UPDATE v2_operation_work SET execution_state=CASE WHEN execution_state='processing' THEN 'processing' ELSE 'awaitingConfirmation' END,
                    scheduling_state='ready',next_action_kind='reconcile',claim_id=NULL,claim_owner_id=NULL,claim_until=NULL,
                    next_action_at=?,work_revision=work_revision+1,last_error_code='PROCESS_INTERRUPTED'
                WHERE scheduling_state='claimed' AND claim_owner_id<>?
                """, arguments: [time, ownerID.uuidString])
        }
    }

    public func deferOperationWork(_ claim: V2OperationWorkClaim, until: Date, code: String,
                                  scheduling: V2OperationSchedulingState = .backingOff,
                                  processing: Bool = false, nextAction: V2OperationWorkAction = .reconcile) throws {
        guard [.backingOff, .waitingForAuthentication, .waitingForNetwork, .needsAttention, .suspended].contains(scheduling),
              !code.isEmpty, code.utf8.count <= 128 else { throw V2OperationWorkError.invalidTransition }
        let time = try Self.commandRetryTimestamp(until)
        try databasePool.write { db in
            let work = try Self.requireOperationWork(claim.work.id, db: db)
            if work.execution.isTerminal { return }
            try Self.requireOperationClaim(claim, db: db)
            if nextAction == .submit,
               try String.fetchOne(db, sql: "SELECT admission_class FROM v2_operation_work WHERE work_id=?", arguments: [claim.work.id.uuidString]) == "readReceiptControl" {
                throw V2OperationWorkError.invalidTransition
            }
            try db.execute(sql: """
                UPDATE v2_operation_work SET execution_state=?,scheduling_state=?,next_action_at=?,last_error_code=?,next_action_kind=?,
                    claim_id=NULL,claim_owner_id=NULL,claim_until=NULL,work_revision=work_revision+1 WHERE work_id=?
                """, arguments: [processing || work.execution == .processing ? "processing" : "awaitingConfirmation", scheduling.rawValue, time, code, nextAction.rawValue, claim.work.id.uuidString])
        }
    }

    /// A matched authoritative receipt can win after its old claim expired. A
    /// failure callback, in contrast, must match the current claim/revision.
    func completeOperationWork(_ outcome: V2VerifiedOperationOutcome, now: Date) throws {
        try databasePool.write { db in
            try Self.completeOperationWork(outcome, now: now, db: db)
        }
    }

    static func completeOperationWork(_ outcome: V2VerifiedOperationOutcome, now: Date, db: Database) throws {
        let time = try commandRetryTimestamp(now)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_operation_work WHERE identity_key=?", arguments: [outcome.identity.storageKey])
        else { throw V2OperationWorkError.invalidRecord }
        let work = try Self.decodeOperationWork(row)
        guard work.identity == outcome.identity, work.fingerprint == outcome.fingerprint else { throw V2OperationWorkError.identityConflict }
        if work.execution.isTerminal {
            guard work.execution == outcome.state, row["terminal_receipt"] as Data? == outcome.canonicalReceipt else {
                throw V2OperationWorkError.identityConflict
            }
            return
        }
        guard work.submissionStarted else { throw V2OperationWorkError.invalidTransition }
        try db.execute(sql: """
            UPDATE v2_operation_work SET execution_state=?,scheduling_state='finished',terminal_receipt=?,completed_at=?,
                claim_id=NULL,claim_owner_id=NULL,claim_until=NULL,work_revision=work_revision+1,last_error_code=NULL
            WHERE work_id=?
            """, arguments: [outcome.state.rawValue, outcome.canonicalReceipt, time, work.id.uuidString])
    }

    public func cancelUnsubmittedOperation(id: UUID, now: Date) throws {
        let time = try Self.commandRetryTimestamp(now)
        try databasePool.write { db in
            let work = try Self.requireOperationWork(id, db: db)
            if work.execution == .cancelledLocally { return }
            guard !work.submissionStarted, !work.execution.isTerminal else { throw V2OperationWorkError.invalidTransition }
            try Self.finishLocalOperation(id, state: .cancelledLocally, now: time, db: db)
        }
    }

    /// Event-driven wake retains persisted budgets. Only explicit user retry
    /// grants a fresh bounded round; it never resets the lifetime attempt count.
    public func resumeOperationWork(id: UUID, now: Date) throws {
        let time = try Self.commandRetryTimestamp(now)
        try databasePool.write { db in
            let work = try Self.requireOperationWork(id, db: db)
            guard !work.execution.isTerminal, work.scheduling != .claimed else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql: "UPDATE v2_operation_work SET scheduling_state='ready',next_action_at=MAX(next_action_at,?),work_revision=work_revision+1 WHERE work_id=?",
                           arguments: [time, id.uuidString])
        }
    }

    public func retryOperationWorkByUser(id: UUID, now: Date) throws {
        let time = try Self.commandRetryTimestamp(now)
        try databasePool.write { db in
            let work = try Self.requireOperationWork(id, db: db)
            guard !work.execution.isTerminal, work.scheduling != .claimed else { throw V2OperationWorkError.invalidTransition }
            try db.execute(sql: """
                UPDATE v2_operation_work SET scheduling_state='ready',next_action_at=MAX(next_action_at,?),work_revision=work_revision+1,
                    submission_round_attempts=0,reconciliation_round_attempts=0,
                    submission_round_deadline=NULL,reconciliation_round_deadline=NULL,
                    next_action_kind=CASE WHEN submission_started=1 THEN 'reconcile' ELSE 'submit' END WHERE work_id=?
                """, arguments: [time, id.uuidString])
        }
    }

    /// Observe only eligible heads of supported domains. A blocked younger row
    /// must not leave the wake timer permanently due while its parent is asleep.
    public nonisolated func operationWorkRetrySchedule(kinds: Set<V2OperationKind>) -> V2CommandRetrySchedule {
        let query = """
            SELECT MIN(work.next_action_at) FROM v2_operation_work work
            WHERE work.scheduling_state IN ('ready','backingOff')
                AND \(Self.operationKindPredicate(kinds))
                AND \(Self.operationHeadPredicate) AND \(Self.operationDependencyPredicate)
            """
        let pool = databasePool
        return .init(nextAttemptAt: {
            try await pool.read { db in
                try Double.fetchOne(db, sql: query).map(Date.init(timeIntervalSince1970:))
            }
        }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        // Equal MIN values can still hide a newly inserted eligible
                        // interactive head. Observe table mutations without MIN
                        // deduplication; the stream coalesces wakes to one item.
                        let observation = ValueObservation.tracking { db in
                            try Double.fetchOne(db, sql: query)
                        }
                        for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                            continuation.yield(())
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }

    private static func operationKindPredicate(_ kinds: Set<V2OperationKind>?) -> String {
        guard let kinds else { return "1" }
        guard !kinds.isEmpty else { return "0" }
        // Values originate exclusively from the closed enum, never from input.
        return "work.operation_kind IN (" + kinds.map { "'" + $0.rawValue + "'" }.sorted().joined(separator: ",") + ")"
    }

    static let operationHeadPredicate = """
        NOT EXISTS(SELECT 1 FROM v2_operation_work predecessor
            WHERE predecessor.ordering_key=work.ordering_key AND predecessor.local_sequence<work.local_sequence
              AND predecessor.scheduling_state<>'finished')
        """
    static let operationDependencyPredicate = """
        NOT EXISTS(SELECT 1 FROM v2_operation_dependencies dependency
            JOIN v2_operation_work parent ON parent.work_id=dependency.parent_work_id
            WHERE dependency.child_work_id=work.work_id AND parent.execution_state<>'committed')
        """

    static func requireOperationWork(_ id: UUID, db: Database) throws -> V2OperationWork {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_operation_work WHERE work_id=?", arguments: [id.uuidString])
        else { throw V2OperationWorkError.invalidRecord }
        return try decodeOperationWork(row)
    }

    static func requireOperationClaim(_ claim: V2OperationWorkClaim, db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_operation_work WHERE work_id=? AND claim_id=? AND claim_owner_id=? AND work_revision=? AND scheduling_state='claimed')",
            arguments: [claim.work.id.uuidString, claim.claimID.uuidString, claim.ownerID.uuidString, claim.work.revision]) == true
        else { throw V2OperationWorkError.staleClaim }
    }

    static func finishLocalOperation(_ id: UUID, state: V2OperationExecutionState, now: Double, db: Database) throws {
        guard state == .cancelledLocally || state == .expiredUnsubmitted else { throw V2OperationWorkError.invalidTransition }
        try db.execute(sql: """
            UPDATE v2_operation_work SET execution_state=?,scheduling_state='finished',completed_at=?,
                claim_id=NULL,claim_owner_id=NULL,claim_until=NULL,work_revision=work_revision+1 WHERE work_id=?
            """, arguments: [state.rawValue, now, id.uuidString])
    }

    static func decodeOperationWork(_ row: Row) throws -> V2OperationWork {
        guard let id = UUID(uuidString: row["work_id"]), let intent = UUID(uuidString: row["intent_id"]),
              let execution = V2OperationExecutionState(rawValue: row["execution_state"]),
              let scheduling = V2OperationSchedulingState(rawValue: row["scheduling_state"]),
              let nextAction = V2OperationWorkAction(rawValue: row["next_action_kind"]),
              let version = UInt16(exactly: row["fingerprint_version"] as Int64) else { throw V2OperationWorkError.invalidRecord }
        let identity = try JSONDecoder().decode(V2OperationIdentity.self, from: row["identity"])
        guard identity.kind.rawValue == row["operation_kind"] as String,
              identity.storageKey == row["identity_key"] as String,
              identity.accountID.rawValue == row["account_id"] as String else { throw V2OperationWorkError.accountMismatch }
        return .init(id: id, intentID: intent, identity: identity,
            fingerprint: try .init(version: version, digest: row["fingerprint"]), orderingKey: row["ordering_key"],
            localSequence: row["local_sequence"], execution: execution, scheduling: scheduling,
            submissionStarted: row["submission_started"], attemptCount: row["attempt_count"],
            submissionRoundAttempts: row["submission_round_attempts"], reconciliationRoundAttempts: row["reconciliation_round_attempts"],
            submissionRoundDeadline: (row["submission_round_deadline"] as Double?).map(Date.init(timeIntervalSince1970:)),
            reconciliationRoundDeadline: (row["reconciliation_round_deadline"] as Double?).map(Date.init(timeIntervalSince1970:)),
            nextAction: nextAction, nextActionAt: Date(timeIntervalSince1970: row["next_action_at"]),
            admissionDeadline: (row["admission_deadline"] as Double?).map(Date.init(timeIntervalSince1970:)),
            lastErrorCode: row["last_error_code"], revision: row["work_revision"])
    }
}
