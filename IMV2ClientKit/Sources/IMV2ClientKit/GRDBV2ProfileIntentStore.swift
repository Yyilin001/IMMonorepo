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
            local_asset_id TEXT REFERENCES v2_resource_local_assets(asset_id), upload_job_id TEXT, import_job_id TEXT REFERENCES v2_resource_import_jobs(job_id), source_released INTEGER NOT NULL DEFAULT 0 CHECK(source_released IN (0,1)),
            local_terminal TEXT CHECK(local_terminal IN ('expiredUnsubmitted','cancelledLocally','preparationFailed')),
            created_at REAL NOT NULL DEFAULT (unixepoch('subsec')),
            CHECK(local_terminal IS NULL OR work_id IS NULL),
            CHECK(upload_job_id IS NULL OR import_job_id IS NULL),
            CHECK(import_job_id IS NULL OR local_asset_id IS NULL)
        );
        CREATE INDEX v2_profile_intents_order ON v2_profile_intents(account_id,local_sequence);
        CREATE INDEX v2_profile_intent_import ON v2_profile_intents(import_job_id) WHERE import_job_id IS NOT NULL;
        CREATE INDEX v2_profile_intent_upload ON v2_profile_intents(upload_job_id) WHERE upload_job_id IS NOT NULL;
        CREATE INDEX v2_profile_intents_recoverable ON v2_profile_intents(account_id,local_sequence DESC) WHERE source_released=0;
        CREATE TABLE v2_own_profile_snapshot (
            account_id TEXT PRIMARY KEY,
            revision INTEGER NOT NULL CHECK(revision>0),
            payload BLOB NOT NULL CHECK(length(payload)<=65536)
        );
        """
    public func enqueueProfileIntent(accountID: UserID, expectedRevision: V2ProfileRevision, patch: V2ProfilePatch,
                                     avatarUpload: V2ProfileAvatarUpload?, adoptingFromIntentID: UUID? = nil, now: Date = Date()) throws -> V2ProfileIntent {
        try enqueueProfileIntent(accountID: accountID, expectedRevision: expectedRevision, patch: patch,
            avatarPreparation: avatarUpload.map(V2ProfileAvatarPreparation.upload), adoptingFromIntentID: adoptingFromIntentID, now: now)
    }
    public func enqueueProfileImportIntent(accountID: UserID, expectedRevision: V2ProfileRevision, patch: V2ProfilePatch,
                                           source: V2ProfileAvatarImport, now: Date = Date()) throws -> V2ProfileIntent {
        try enqueueProfileIntent(accountID: accountID, expectedRevision: expectedRevision, patch: patch,
            avatarPreparation: .serverImport(source), adoptingFromIntentID: nil, now: now)
    }
    private func enqueueProfileIntent(accountID: UserID, expectedRevision: V2ProfileRevision, patch: V2ProfilePatch,
                                      avatarPreparation: V2ProfileAvatarPreparation?, adoptingFromIntentID: UUID?, now: Date) throws -> V2ProfileIntent {
        let avatarUpload: V2ProfileAvatarUpload? = if case .upload(let value) = avatarPreparation { value } else { nil }
        let avatarImport: V2ProfileAvatarImport? = if case .serverImport(let value) = avatarPreparation { value } else { nil }
        let deadline = now.addingTimeInterval(24 * 60 * 60)
        let id = UUID()
        let intent = V2ProfileIntent(id: id, accountID: accountID, operationID: .init(uuid: UUID()), expectedRevision: expectedRevision,
                                     patch: patch, avatarPreparation: avatarPreparation, deadline: deadline, workID: nil)
        let bytes = try JSONEncoder().encode(intent)
        // The final payload adds a work ID and, for an upload, its immutable
        // media reference. Reserve their bounded encoded form before admission.
        let reservedAvatar = try avatarPreparation.map { _ in
            V2AvatarReference(mediaID: try MediaID(String(repeating: "x", count: MediaID.maximumUTF8Bytes)))
        }
        let reservedPatch = try V2ProfilePatch(displayName: patch.displayName,
            avatar: reservedAvatar.map(V2ProfileAvatarPatch.set) ?? patch.avatar)
        let reservedIntent = V2ProfileIntent(id: id, accountID: accountID, operationID: intent.operationID,
            expectedRevision: expectedRevision, patch: reservedPatch, avatarPreparation: avatarPreparation,
            deadline: deadline, workID: UUID())
        let reservation = max(bytes.count, try JSONEncoder().encode(reservedIntent).count)
        guard reservation <= 65_536 else { throw V2OperationWorkError.capacityExceeded }
        return try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            try Self.requireOperationCapacity(adding: Int64(reservation), db: db)
            if let avatarUpload {
                guard let asset = try V2ResourceFileJournal.readAsset(avatarUpload.localAssetID, db: db), asset.availability == .local,
                      asset.purpose == .personalAvatar, asset.contentType.value == avatarUpload.contentType,
                      asset.displayName.value == avatarUpload.displayName, asset.byteCount == avatarUpload.byteCount else { throw V2ResourceJournalError.conflict }
                if let origin = adoptingFromIntentID {
                    guard try Bool.fetchOne(db, sql: """
                        SELECT i.local_asset_id=? AND i.source_released=0 AND (i.local_terminal IS NOT NULL OR w.scheduling_state='finished')
                        FROM v2_profile_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id
                        WHERE i.intent_id=? AND i.account_id=?
                        """, arguments: [avatarUpload.localAssetID.value.uuidString,origin.uuidString,accountID.rawValue]) == true else { throw V2ResourceJournalError.conflict }
                }
            }
            if let avatarImport {
                try Self.prepareResourceImport(id: avatarImport.id, request: avatarImport.request, now: now, db: db)
                guard let job = try Self.readResourceImport(avatarImport.id, db: db), !job.cancellationRequested,
                      job.status.map({ ![.cancelled,.failed].contains($0.state) }) ?? true else { throw V2ResourceJournalError.conflict }
            }
            try db.execute(sql: "INSERT INTO v2_profile_intents(intent_id,account_id,payload,payload_bytes,preparation_next_at,local_asset_id,upload_job_id,import_job_id,created_at) VALUES(?,?,?,?,?,?,?,?,?)", arguments: [id.uuidString, accountID.rawValue, bytes, reservation, now.timeIntervalSince1970, avatarUpload?.localAssetID.value.uuidString, avatarUpload?.id.uuidString,avatarImport?.id.uuidString,try Self.commandRetryTimestamp(now)])
            if let avatarUpload {
                _ = try Self.bindLocalResourceAsset(avatarUpload.localAssetID, consumer: .profileIntent(id),
                    adoptingFrom: adoptingFromIntentID.map(V2LocalResourceOriginalConsumer.profileIntent), relinquishSelection: true, db: db)
            }
            if avatarPreparation == nil, try Self.firstUnfinishedProfileIntent(accountID: accountID, db: db)?.id == id {
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
        guard input.avatarPreparation == nil || avatar != nil else { throw V2OperationWorkError.dependencyUnavailable }
        if let source = input.avatarUpload {
            guard let job = try Self.readResourceTransfer(source.id, db: db),
                  job.localAssetID == source.localAssetID, job.request.usage == .userAvatar,
                  job.request.mediaID == MediaID(uuid: source.id), avatar?.mediaID == job.request.mediaID,
                  job.stage == .ready, !job.cancellationRequested,
                  let session = job.session, session.resourceState == .ready, session.state == .completed else {
                throw V2OperationWorkError.dependencyUnavailable
            }
            guard let until = session.bindableUntil, until > now else { throw V2ResourceJournalError.bindingExpired }
        }
        if let source = input.avatarImport {
            guard let job = try Self.readResourceImport(source.id, db: db), job.request == source.request,
                  job.status?.state == .ready, !job.cancellationRequested,
                  avatar?.mediaID == source.request.targetMediaID else { throw V2OperationWorkError.dependencyUnavailable }
            guard let until = job.status?.bindableUntilUnixMilliseconds,
                  Double(until) / 1000 > now.timeIntervalSince1970 else { throw V2ResourceJournalError.bindingExpired }
        }
        let patch = try V2ProfilePatch(displayName: input.patch.displayName, avatar: avatar.map(V2ProfileAvatarPatch.set) ?? input.patch.avatar)
        let command = try profileCommand(intent: input, patch: patch)
        let identity = try V2OperationIdentity(accountID: input.accountID, scope: .account(input.accountID), operation: .profileUpdate(input.operationID))
        let workID = UUID()
        let frozen = V2ProfileIntent(id: input.id, accountID: input.accountID, operationID: input.operationID, expectedRevision: input.expectedRevision,
                                     patch: command.patch, avatarPreparation: input.avatarPreparation, deadline: input.deadline, workID: workID)
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
                        guard let row = try Row.fetchOne(db, sql: "SELECT i.payload,i.source_released,i.local_terminal,i.preparation_error,w.execution_state,w.scheduling_state FROM v2_profile_intents i LEFT JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.intent_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
                        let intent = try JSONDecoder().decode(V2ProfileIntent.self, from: row["payload"])
                        let execution: String? = row["execution_state"]
                        let scheduling: String? = row["scheduling_state"]
                        let phase: V2ProfileIntentStatus.Phase
                        let preparationIssue: String? = row["preparation_error"]
                        if row["local_terminal"] as String? != nil || (preparationIssue != nil && preparationIssue != "PROFILE_AVATAR_PENDING") { phase = .needsAttention }
                        else if execution == "committed" { phase = .committed }
                        else if execution == "closed" || execution == "cancelledLocally" { phase = .closed }
                        else if scheduling == "needsAttention" || scheduling == "finished" { phase = .needsAttention }
                        else if execution == "awaitingConfirmation" || execution == "processing" { phase = .confirming }
                        else if intent.workID == nil && intent.avatarPreparation != nil { phase = .preparingAvatar }
                        else { phase = .waitingToSubmit }
                        let snapshot = try Data.fetchOne(db, sql: "SELECT payload FROM v2_own_profile_snapshot WHERE account_id=?", arguments: [intent.accountID.rawValue]).map { try JSONDecoder().decode(V2ProfileView.self, from: $0) }
                        return .init(intent: intent, phase: phase, currentSnapshot: snapshot, sourceRetained: !(row["source_released"] as Bool), canReplace: row["local_terminal"] as String? != nil || scheduling == "finished")
                    }.removeDuplicates()
                    for try await status in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(status) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
