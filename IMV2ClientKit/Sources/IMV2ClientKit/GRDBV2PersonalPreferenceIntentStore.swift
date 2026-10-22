import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let personalPreferenceIntentSchemaSQL = """
        CREATE TABLE v2_personal_preference_intents (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            intent_id TEXT NOT NULL UNIQUE, account_id TEXT NOT NULL,
            ordering_key TEXT NOT NULL, payload BLOB NOT NULL CHECK(length(payload)<=65536),
            payload_bytes INTEGER NOT NULL CHECK(payload_bytes>0 AND payload_bytes<=65536),
            deadline REAL NOT NULL,
            work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            command BLOB CHECK(length(command)<=65536),
            local_terminal TEXT CHECK(local_terminal IN ('expiredUnsubmitted','cancelledLocally')),
            CHECK((work_id IS NULL)=(command IS NULL)),
            CHECK(local_terminal IS NULL OR work_id IS NULL)
        );
        CREATE INDEX v2_personal_preference_intents_order ON v2_personal_preference_intents(ordering_key,local_sequence);
        CREATE TABLE v2_personal_preference_confirmed (
            ordering_key TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision>0),
            payload BLOB NOT NULL CHECK(length(payload)<=65536)
        );
        """

    /// All domain admission reservations share the account's count and byte quota.
    static func requireOperationCapacity(adding bytes: Int64, excludingIntent: UUID? = nil, excludingReadReceiptRoom: String? = nil, limits: V2OperationWorkLimits = .init(), db: Database) throws {
        let (count, total) = try operationAdmissionUsage(excludingIntent: excludingIntent, excludingReadReceiptRoom: excludingReadReceiptRoom, db: db)
        guard bytes >= 0, count < limits.maximumActiveCount, total <= limits.maximumPayloadBytes,
              bytes <= limits.maximumPayloadBytes - total else { throw V2OperationWorkError.capacityExceeded }
    }

    /// Shared admission accounting for both enforcement and on-demand diagnostics.
    /// Accepted sends retain their existing payload reservation until their local
    /// display converges; the completed work is never made executable again.
    static func operationAdmissionUsage(excludingIntent: UUID? = nil, excludingReadReceiptRoom: String? = nil, db: Database) throws -> (count: Int, bytes: Int64) {
        let excluded = excludingIntent?.uuidString ?? ""
        let row = try Row.fetchOne(db, sql: """
            SELECT SUM(n) AS n, SUM(b) AS b FROM (
                SELECT COUNT(*) AS n, COALESCE(SUM(payload_bytes),0) AS b FROM v2_operation_work WHERE scheduling_state<>'finished' AND admission_class='ordinary'
                UNION ALL SELECT COUNT(*),COALESCE(SUM(w.payload_bytes),0)
                    FROM v2_operation_work w JOIN v2_message_send_operations m USING(work_id)
                    WHERE w.execution_state='committed' AND w.admission_class='ordinary'
                        AND m.accepted_projection_observed=0
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_profile_intents WHERE work_id IS NULL AND local_terminal IS NULL AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_personal_preference_intents WHERE work_id IS NULL AND local_terminal IS NULL AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_read_receipt_intents WHERE room_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_send_intents WHERE stage='preparing' AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_message_reaction_intents WHERE work_id IS NULL AND local_terminal IS NULL AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_member_administration_intents WHERE work_id IS NULL AND preparation_state<>'cancelled' AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_membership_intents WHERE work_id IS NULL AND preparation_state<>'cancelled' AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_group_capability_intents WHERE work_id IS NULL AND preparation_state<>'cancelled' AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_account_preference_intents WHERE work_id IS NULL AND state<>'cancelled' AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_social_operation_proposals WHERE state='pending' AND intent_id<>?
                UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_invitation_operation_intents WHERE work_id IS NULL AND preparation_state<>'cancelled' AND intent_id<>?
            )
            """, arguments: [excluded, excluded, excludingReadReceiptRoom ?? "",excluded,excluded,excluded,excluded,excluded,excluded,excluded,excluded])!
        return (row["n"], row["b"])
    }

    public func enqueuePersonalPreference(accountID: UserID, target: V2PersonalPreferenceTarget, now: Date = Date()) throws -> UUID {
        try databasePool.write { db in
            try Self.enqueuePersonalPreference(accountID: accountID, target: target, now: now, db: db)
        }
    }

    static func enqueuePersonalPreference(accountID: UserID, target: V2PersonalPreferenceTarget, now: Date, db: Database) throws -> UUID {
        guard let window = V2CommandPolicy.registered(for: target.kind).firstSubmissionWindowMilliseconds else {
            throw V2OperationWorkError.invalidRecord
        }
        guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
        let existing = try Row.fetchOne(db, sql: """
            SELECT intent_id,deadline FROM v2_personal_preference_intents
            WHERE account_id=? AND ordering_key=? AND work_id IS NULL AND local_terminal IS NULL AND deadline>?
            ORDER BY local_sequence DESC LIMIT 1
            """, arguments: [accountID.rawValue, target.orderingKey, now.timeIntervalSince1970])
        let id: UUID
        let deadline: Date
        if let existing {
            guard let originalID = UUID(uuidString: existing["intent_id"]) else { throw V2OperationWorkError.invalidRecord }
            id = originalID
            deadline = Date(timeIntervalSince1970: existing["deadline"])
        } else {
            id = UUID()
            deadline = now.addingTimeInterval(Double(V2ClientSubmissionWindow.milliseconds(maximum: window)) / 1000)
        }
        let encoder = JSONEncoder()
        let bytes = try encoder.encode(target)
        // Draft coalescing preserves its original identity and first deadline.
        // Already frozen or unknown work is never rewritten.
        let maximumRevision = V2PersonalPreferenceRevision(rawValue: UInt64(Int64.max) - 1)!
        let frozenBytes = try encoder.encode(target.freeze(id: id, revision: maximumRevision, deadline: deadline))
        let reservation = max(bytes.count, frozenBytes.count)
        guard reservation <= 65_536 else { throw V2OperationWorkError.capacityExceeded }
        try Self.requireOperationCapacity(adding: Int64(reservation), excludingIntent: existing == nil ? nil : id, db: db)
        if existing != nil {
            try db.execute(sql: "UPDATE v2_personal_preference_intents SET payload=?,payload_bytes=? WHERE intent_id=?",
                arguments: [bytes, reservation, id.uuidString])
        } else {
            try db.execute(sql: "INSERT INTO v2_personal_preference_intents(intent_id,account_id,ordering_key,payload,payload_bytes,deadline) VALUES(?,?,?,?,?,?)",
                arguments: [id.uuidString, accountID.rawValue, target.orderingKey, bytes, reservation, try Self.commandRetryTimestamp(deadline)])
        }
        return id
    }
    static let personalPreferenceHeadPredicate = """
        i.work_id IS NULL AND i.local_terminal IS NULL AND NOT EXISTS(
            SELECT 1 FROM v2_personal_preference_intents p LEFT JOIN v2_operation_work w ON w.work_id=p.work_id
            WHERE p.ordering_key=i.ordering_key AND p.local_sequence<i.local_sequence
                AND p.local_terminal IS NULL AND (p.work_id IS NULL OR w.scheduling_state<>'finished'))
        """
    @discardableResult
    public func preparePersonalPreferences(accountID: UserID, now: Date = Date()) throws -> Int {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            let rows = try Row.fetchAll(db, sql: "SELECT i.* FROM v2_personal_preference_intents i WHERE \(Self.personalPreferenceHeadPredicate) ORDER BY i.local_sequence LIMIT 32")
            for row in rows {
                guard let id = UUID(uuidString: row["intent_id"]) else { throw V2OperationWorkError.invalidRecord }
                let deadline = Date(timeIntervalSince1970: row["deadline"])
                if deadline <= now {
                    try db.execute(sql: "UPDATE v2_personal_preference_intents SET local_terminal='expiredUnsubmitted' WHERE intent_id=?", arguments: [id.uuidString]); continue
                }
                let target = try JSONDecoder().decode(V2PersonalPreferenceTarget.self, from: row["payload"])
                let prior = try Int64.fetchOne(db, sql: "SELECT revision FROM v2_personal_preference_confirmed WHERE ordering_key=?", arguments: [target.orderingKey]) ?? 0
                // The synchronized projection may be newer than our last local receipt.
                let observed: Int64
                switch target {
                case .conversation(let room, _, _, _): observed = try Int64.fetchOne(db, sql: "SELECT revision FROM v2_conversation_states WHERE room_id=?", arguments: [room.rawValue]) ?? 0
                case .favorite(_, let message, _): observed = try Int64.fetchOne(db, sql: "SELECT revision FROM v2_message_favorites WHERE message_id=?", arguments: [message.rawValue]) ?? 0
                }
                guard let revision = V2PersonalPreferenceRevision(rawValue: UInt64(max(prior, observed))) else { throw V2OperationWorkError.invalidRecord }
                let command = try target.freeze(id: id, revision: revision, deadline: deadline)
                let bytes = try JSONEncoder().encode(command), workID = UUID()
                try Self.insertOperationWork(.init(id: workID, intentID: id, identity: command.identity(accountID: accountID),
                    fingerprint: command.fingerprint(accountID: accountID), orderingKey: target.orderingKey,
                    payloadBytes: Int64(bytes.count), admissionDeadline: deadline), now: now, db: db)
                try db.execute(sql: "UPDATE v2_personal_preference_intents SET command=?,work_id=? WHERE intent_id=?", arguments: [bytes, workID.uuidString, id.uuidString])
            }
            return rows.count
        }
    }
    func personalPreferenceCommand(workID: UUID) throws -> V2FrozenPersonalPreference {
        try databasePool.read { db in
            guard let bytes = try Data.fetchOne(db, sql: "SELECT command FROM v2_personal_preference_intents WHERE work_id=?", arguments: [workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            return try JSONDecoder().decode(V2FrozenPersonalPreference.self, from: bytes)
        }
    }
    func completePersonalPreference(command: V2FrozenPersonalPreference, receipt: V2PersonalPreferenceReceipt, accountID: UserID, now: Date = Date()) throws {
        try command.validate(receipt, accountID: accountID)
        let state: V2OperationExecutionState
        switch receipt.outcome {
        case .committed: state = .committed
        case .rejected(.revisionConflict): state = .conflicted
        case .rejected: state = .rejected
        case .closed: state = .closed
        }
        let outcome = try V2VerifiedOperationOutcome(identity: receipt.identity, fingerprint: receipt.fingerprint, state: state, receipt: receipt)
        try databasePool.write { db in
            try Self.completeOperationWork(outcome, now: now, db: db)
            if case .committed(let value) = receipt.outcome {
                let key: String, revision: V2PersonalPreferenceRevision
                switch value {
                case .conversationState(let state): key = V2PersonalPreferenceTarget.conversation(roomID: state.roomID, isPinned: state.isPinned, isArchived: state.isArchived, muteUntil: state.muteUntil).orderingKey; revision = state.revision
                case .messageFavorite(let state): key = V2PersonalPreferenceTarget.favorite(roomID: state.roomID, messageID: state.messageID, isFavorited: state.isFavorited).orderingKey; revision = state.revision
                }
                try db.execute(sql: """
                    INSERT INTO v2_personal_preference_confirmed(ordering_key,revision,payload) VALUES(?,?,?)
                    ON CONFLICT(ordering_key) DO UPDATE SET revision=excluded.revision,payload=excluded.payload
                    WHERE excluded.revision>v2_personal_preference_confirmed.revision
                    """, arguments: [key, revision.signedValue, try JSONEncoder().encode(value)])
            }
        }
    }
    public nonisolated func personalPreferencePreparationSchedule() -> V2CommandRetrySchedule {
        let query = "SELECT MIN(i.local_sequence) FROM v2_personal_preference_intents i WHERE \(Self.personalPreferenceHeadPredicate)"
        let pool = databasePool
        return .init(nextAttemptAt: { try await pool.read { db in try Int64.fetchOne(db, sql: query).map { _ in Date.distantPast } } }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        let observation = ValueObservation.tracking { db in try Int64.fetchOne(db, sql: query) }.removeDuplicates()
                        for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
}
