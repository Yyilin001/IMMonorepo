import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let profileIntentSchemaSQL = """
        CREATE TABLE v2_profile_intents (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            intent_id TEXT NOT NULL UNIQUE,
            account_id TEXT NOT NULL,
            payload BLOB NOT NULL CHECK(length(payload)<=65536),
            payload_bytes INTEGER NOT NULL CHECK(payload_bytes>0 AND payload_bytes<=65536),
            work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            preparation_next_at REAL, preparation_error TEXT, preparation_attempts INTEGER NOT NULL DEFAULT 0,
            local_file_token TEXT, upload_job_id TEXT, source_released INTEGER NOT NULL DEFAULT 0 CHECK(source_released IN (0,1)),
            local_terminal TEXT CHECK(local_terminal IN ('expiredUnsubmitted','cancelledLocally')),
            CHECK(local_terminal IS NULL OR work_id IS NULL)
        );
        CREATE INDEX v2_profile_intents_order ON v2_profile_intents(account_id,local_sequence);
        CREATE INDEX v2_profile_intents_recoverable ON v2_profile_intents(account_id,local_sequence DESC) WHERE source_released=0;
        CREATE TABLE v2_own_profile_snapshot (
            account_id TEXT PRIMARY KEY,
            revision INTEGER NOT NULL CHECK(revision>0),
            payload BLOB NOT NULL CHECK(length(payload)<=65536)
        );
        """
    public func enqueueProfileIntent(accountID: UserID, expectedRevision: V2ProfileRevision, patch: V2ProfilePatch,
                                     avatarUpload: V2ProfileAvatarUpload?, now: Date = Date()) throws -> V2ProfileIntent {
        let deadline = now.addingTimeInterval(24 * 60 * 60)
        let id = UUID()
        let intent = V2ProfileIntent(id: id, accountID: accountID, operationID: .init(uuid: UUID()), expectedRevision: expectedRevision,
                                     patch: patch, avatarUpload: avatarUpload, deadline: deadline, workID: nil)
        let bytes = try JSONEncoder().encode(intent)
        // The final payload adds a work ID and, for an upload, its immutable
        // media reference. Reserve their bounded encoded form before admission.
        let reservedAvatar = try avatarUpload.map { _ in
            V2AvatarReference(mediaID: try MediaID(String(repeating: "x", count: MediaID.maximumUTF8Bytes)))
        }
        let reservedPatch = try V2ProfilePatch(displayName: patch.displayName,
            avatar: reservedAvatar.map(V2ProfileAvatarPatch.set) ?? patch.avatar)
        let reservedIntent = V2ProfileIntent(id: id, accountID: accountID, operationID: intent.operationID,
            expectedRevision: expectedRevision, patch: reservedPatch, avatarUpload: avatarUpload,
            deadline: deadline, workID: UUID())
        let reservation = max(bytes.count, try JSONEncoder().encode(reservedIntent).count)
        guard reservation <= 65_536 else { throw V2OperationWorkError.capacityExceeded }
        return try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            try Self.requireOperationCapacity(adding: Int64(reservation), db: db)
            if let avatarUpload {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_transfer_jobs WHERE local_file_token=? AND (staging_release_started=1 OR staging_released=1))", arguments: [avatarUpload.fileURL.lastPathComponent]) != true else { throw V2ResourceJournalError.conflict }
            }
            try db.execute(sql: "INSERT INTO v2_profile_intents(intent_id,account_id,payload,payload_bytes,preparation_next_at,local_file_token,upload_job_id) VALUES(?,?,?,?,?,?,?)", arguments: [id.uuidString, accountID.rawValue, bytes, reservation, now.timeIntervalSince1970, avatarUpload?.fileURL.lastPathComponent, avatarUpload?.id.uuidString])
            if avatarUpload == nil, try Self.firstUnfinishedProfileIntent(accountID: accountID, db: db)?.id == id {
                return try Self.freezeProfileIntent(intent, avatar: nil, now: now, db: db)
            }
            return intent
        }
    }
    public func latestRecoverableProfileIntent(accountID: UserID) throws -> V2ProfileIntent? {
        try databasePool.read { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            return try Data.fetchOne(db, sql: """
                SELECT i.payload FROM v2_profile_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id
                WHERE i.account_id=? AND i.source_released=0 AND COALESCE(i.local_terminal,'')<>'cancelledLocally'
                    AND COALESCE(w.execution_state,'') NOT IN ('committed','cancelledLocally')
                    AND NOT EXISTS(SELECT 1 FROM v2_profile_intents newer JOIN v2_operation_work completed ON completed.work_id=newer.work_id
                        WHERE newer.account_id=i.account_id AND newer.local_sequence>i.local_sequence AND completed.execution_state='committed')
                ORDER BY i.local_sequence DESC LIMIT 1
                """, arguments: [accountID.rawValue]).map { try JSONDecoder().decode(V2ProfileIntent.self, from: $0) }
        }
    }
    public func firstUnfinishedProfileIntent(accountID: UserID) throws -> V2ProfileIntent? {
        try databasePool.read { try Self.firstUnfinishedProfileIntent(accountID: accountID, db: $0) }
    }
    static func firstUnfinishedProfileIntent(accountID: UserID, db: Database) throws -> V2ProfileIntent? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT i.payload FROM v2_profile_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id
            WHERE i.account_id=? AND i.local_terminal IS NULL AND (i.work_id IS NULL OR w.scheduling_state<>'finished')
            ORDER BY i.local_sequence LIMIT 1
            """, arguments: [accountID.rawValue]) else { return nil }
        return try JSONDecoder().decode(V2ProfileIntent.self, from: row["payload"])
    }
    public func freezeProfileIntent(id: UUID, avatar: V2AvatarReference?, now: Date = Date()) throws -> V2ProfileIntent {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload FROM v2_profile_intents WHERE intent_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let intent = try JSONDecoder().decode(V2ProfileIntent.self, from: row["payload"])
            guard try Self.firstUnfinishedProfileIntent(accountID: intent.accountID, db: db)?.id == id else { throw V2OperationWorkError.invalidTransition }
            return try Self.freezeProfileIntent(intent, avatar: avatar, now: now, db: db)
        }
    }
    static func freezeProfileIntent(_ input: V2ProfileIntent, avatar: V2AvatarReference?, now: Date, db: Database) throws -> V2ProfileIntent {
        if input.workID != nil { return input }
        guard input.avatarUpload == nil || avatar != nil else { throw V2OperationWorkError.dependencyUnavailable }
        let patch = try V2ProfilePatch(displayName: input.patch.displayName, avatar: avatar.map(V2ProfileAvatarPatch.set) ?? input.patch.avatar)
        let command = try profileCommand(intent: input, patch: patch)
        let identity = try V2OperationIdentity(accountID: input.accountID, scope: .account(input.accountID), operation: .profileUpdate(input.operationID))
        let workID = UUID()
        let frozen = V2ProfileIntent(id: input.id, accountID: input.accountID, operationID: input.operationID, expectedRevision: input.expectedRevision,
                                     patch: command.patch, avatarUpload: input.avatarUpload, deadline: input.deadline, workID: workID)
        let bytes = try JSONEncoder().encode(frozen)
        _ = try insertOperationWork(.init(id: workID, intentID: input.id, identity: identity, fingerprint: command.fingerprint,
                                           orderingKey: "profile/\(input.accountID.rawValue)", payloadBytes: Int64(bytes.count), admissionDeadline: input.deadline), now: now, db: db)
        try db.execute(sql: "UPDATE v2_profile_intents SET payload=?,work_id=?,preparation_next_at=NULL,preparation_error=NULL WHERE intent_id=? AND work_id IS NULL", arguments: [bytes, workID.uuidString, input.id.uuidString])
        return frozen
    }
    static func profileCommand(intent: V2ProfileIntent, patch: V2ProfilePatch? = nil) throws -> V2ProfileUpdateCommand {
        let milliseconds = intent.deadline.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int64.max) else { throw V2OperationWorkError.invalidRecord }
        return try .init(actorUserID: intent.accountID, operationID: intent.operationID, expectedRevision: intent.expectedRevision,
                         patch: patch ?? intent.patch, firstSubmissionDeadlineMilliseconds: UInt64(milliseconds))
    }
    public func profileIntent(id: UUID) throws -> V2ProfileIntent? {
        try databasePool.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM v2_profile_intents WHERE intent_id=?", arguments: [id.uuidString]).map { try JSONDecoder().decode(V2ProfileIntent.self, from: $0) }
        }
    }
    public func profileIntent(forWorkID id: UUID) throws -> V2ProfileIntent? {
        try databasePool.read { db in
            try Row.fetchOne(db, sql: "SELECT payload FROM v2_profile_intents WHERE work_id=?", arguments: [id.uuidString]).map { try JSONDecoder().decode(V2ProfileIntent.self, from: $0["payload"]) }
        }
    }
    public func profileIntentProtectedFileTokens() throws -> Set<String> {
        try databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM v2_profile_intents WHERE source_released=0")
            return Set(try rows.compactMap { try JSONDecoder().decode(V2ProfileIntent.self, from: $0["payload"]).avatarUpload?.fileURL.lastPathComponent })
        }
    }
    public func saveOwnProfileSnapshot(_ profile: V2ProfileView) throws {
        try databasePool.write { try Self.persistOwnProfileSnapshot(profile, db: $0) }
    }
    static func persistOwnProfileSnapshot(_ profile: V2ProfileView, db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == profile.userID.rawValue,
              profile.revision.rawValue <= UInt64(Int64.max) else { throw V2OperationWorkError.invalidRecord }
        try db.execute(sql: """
            INSERT INTO v2_own_profile_snapshot(account_id,revision,payload) VALUES(?,?,?)
            ON CONFLICT(account_id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload WHERE excluded.revision>v2_own_profile_snapshot.revision
            """, arguments: [profile.userID.rawValue, Int64(profile.revision.rawValue), try JSONEncoder().encode(profile)])
    }
    public func ownProfileSnapshot(accountID: UserID) throws -> V2ProfileView? {
        try databasePool.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM v2_own_profile_snapshot WHERE account_id=?", arguments: [accountID.rawValue]).map { try JSONDecoder().decode(V2ProfileView.self, from: $0) }
        }
    }
    public func profileIntentUpdates(id: UUID) -> AsyncThrowingStream<V2ProfileIntentStatus, Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db -> V2ProfileIntentStatus in
                        guard let row = try Row.fetchOne(db, sql: "SELECT i.payload,i.local_terminal,i.preparation_error,w.execution_state,w.scheduling_state FROM v2_profile_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.intent_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
                        let intent = try JSONDecoder().decode(V2ProfileIntent.self, from: row["payload"])
                        let execution: String? = row["execution_state"]
                        let scheduling: String? = row["scheduling_state"]
                        let phase: V2ProfileIntentStatus.Phase
                        if row["local_terminal"] as String? != nil || row["preparation_error"] as String? != nil { phase = .needsAttention }
                        else if execution == "committed" { phase = .committed }
                        else if execution == "closed" || execution == "cancelledLocally" { phase = .closed }
                        else if scheduling == "needsAttention" || scheduling == "finished" { phase = .needsAttention }
                        else if execution == "awaitingConfirmation" || execution == "processing" { phase = .confirming }
                        else if intent.workID == nil && intent.avatarUpload != nil { phase = .uploading }
                        else { phase = .waitingToSubmit }
                        let snapshot = try Data.fetchOne(db, sql: "SELECT payload FROM v2_own_profile_snapshot WHERE account_id=?", arguments: [intent.accountID.rawValue]).map { try JSONDecoder().decode(V2ProfileView.self, from: $0) }
                        return .init(intent: intent, phase: phase, currentSnapshot: snapshot, canReplace: row["local_terminal"] as String? != nil || scheduling == "finished")
                    }.removeDuplicates()
                    for try await status in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(status) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
