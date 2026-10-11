import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let resourceJournalSchemaSQL = """
        CREATE TABLE v2_resource_transfer_jobs (
            job_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE,
            media_id TEXT NOT NULL UNIQUE, request BLOB NOT NULL,
            local_file_token TEXT NOT NULL, session BLOB,
            stage TEXT NOT NULL CHECK(stage IN ('prepared','transferring','processing','ready','paused','cancelled','rejected','expired')),
            cancellation_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancellation_requested IN (0,1)),
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
            retry_at REAL NOT NULL DEFAULT 0, server_retry_not_before REAL NOT NULL DEFAULT 0, last_error TEXT,
            next_action TEXT NOT NULL DEFAULT 'create' CHECK(next_action IN ('create','status','upload','finalize','cancel','awaitingBackground')),
            action_attempts INTEGER NOT NULL DEFAULT 0 CHECK(action_attempts >= 0),
            total_attempts INTEGER NOT NULL DEFAULT 0 CHECK(total_attempts >= 0),
            background_attempts INTEGER NOT NULL DEFAULT 0 CHECK(background_attempts>=0),
            round_deadline REAL, poll_attempts INTEGER NOT NULL DEFAULT 0 CHECK(poll_attempts >= 0),
            needs_attention INTEGER NOT NULL DEFAULT 0 CHECK(needs_attention IN (0,1)),
            execution_owner TEXT,
            staging_released INTEGER NOT NULL DEFAULT 0 CHECK(staging_released IN (0,1)),
            staging_release_started INTEGER NOT NULL DEFAULT 0 CHECK(staging_release_started IN (0,1)),
            bindable_until REAL, created_at REAL NOT NULL
        );
        CREATE INDEX v2_resource_transfer_active_admission ON v2_resource_transfer_jobs(job_id)
            WHERE stage NOT IN ('ready','cancelled','rejected','expired');
        CREATE INDEX v2_resource_transfer_due ON v2_resource_transfer_jobs(retry_at, created_at, job_id)
            WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND execution_owner IS NULL AND next_action<>'awaitingBackground';
        CREATE INDEX v2_resource_staging_release_candidates ON v2_resource_transfer_jobs(job_id) WHERE stage='ready' AND staging_released=0;
        CREATE INDEX v2_resource_jobs_local_file ON v2_resource_transfer_jobs(local_file_token);
        CREATE TABLE v2_background_transfer_session(singleton INTEGER PRIMARY KEY CHECK(singleton=1),session_id TEXT NOT NULL UNIQUE);
        CREATE TABLE v2_background_transfer_tasks(
            mapping_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,job_id TEXT NOT NULL REFERENCES v2_resource_transfer_jobs(job_id),
            activation_id TEXT NOT NULL,task_identifier INTEGER NOT NULL,source_token TEXT NOT NULL,
            part_number INTEGER NOT NULL CHECK(part_number BETWEEN 1 AND 32),expected_bytes INTEGER NOT NULL CHECK(expected_bytes>0 AND expected_bytes<=8388608),
            expires_at REAL NOT NULL,origin_digest TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN ('active','completed')),
            created_at REAL NOT NULL,UNIQUE(session_id,task_identifier));
        CREATE UNIQUE INDEX v2_background_transfer_active_job ON v2_background_transfer_tasks(job_id) WHERE state='active';
        CREATE TABLE v2_send_intents (
            intent_id TEXT PRIMARY KEY, client_message_id TEXT NOT NULL UNIQUE,
            room_id TEXT NOT NULL, text TEXT NOT NULL,
            mentions TEXT NOT NULL, entities TEXT NOT NULL, reply_to TEXT,
            stage TEXT NOT NULL CHECK(stage IN ('preparing','handedOff','cancelled')),
            replacement_of TEXT REFERENCES v2_send_intents(intent_id),
            work_id TEXT REFERENCES v2_operation_work(work_id),
            payload_bytes INTEGER NOT NULL CHECK(typeof(payload_bytes)='integer' AND payload_bytes>=0),
            admission_deadline INTEGER NOT NULL CHECK(typeof(admission_deadline)='integer' AND admission_deadline>0),
            retry_at REAL NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
            created_at REAL NOT NULL
        );
        CREATE INDEX v2_send_intents_room_stage ON v2_send_intents(stage,room_id,created_at);
        CREATE UNIQUE INDEX v2_send_intent_replacement ON v2_send_intents(replacement_of) WHERE replacement_of IS NOT NULL;
        CREATE TABLE v2_send_intent_dependencies (
            intent_id TEXT NOT NULL REFERENCES v2_send_intents(intent_id),
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            job_id TEXT NOT NULL REFERENCES v2_resource_transfer_jobs(job_id),
            PRIMARY KEY(intent_id, ordinal), UNIQUE(intent_id, job_id)
        );
        CREATE INDEX v2_send_intent_file_consumers ON v2_send_intent_dependencies(job_id,intent_id);
        """

    static let resourceImportSchemaSQL = """
        CREATE TABLE v2_resource_import_jobs (
            job_id TEXT PRIMARY KEY, request BLOB NOT NULL, status BLOB,
            cancellation_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancellation_requested IN (0,1)),
            stage TEXT NOT NULL CHECK(stage IN ('pending','copying','processing','ready','cancelled','failed')),
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
            retry_at REAL NOT NULL DEFAULT 0, server_retry_not_before REAL NOT NULL DEFAULT 0, poll_attempts INTEGER NOT NULL DEFAULT 0 CHECK(poll_attempts>=0),
            round_deadline REAL, created_at REAL NOT NULL
        );
        CREATE INDEX v2_resource_import_active_admission ON v2_resource_import_jobs(job_id)
            WHERE stage NOT IN ('ready','cancelled','failed');
        CREATE INDEX v2_resource_import_due ON v2_resource_import_jobs(retry_at,created_at,job_id)
            WHERE stage NOT IN ('ready','cancelled','failed') AND attempts<5;
        CREATE TABLE v2_send_intent_import_dependencies (
            intent_id TEXT NOT NULL REFERENCES v2_send_intents(intent_id),
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            job_id TEXT NOT NULL REFERENCES v2_resource_import_jobs(job_id),
            PRIMARY KEY(intent_id,ordinal), UNIQUE(intent_id,job_id)
        );
        """

    public func freezeSendIntent(_ intent: V2SendIntent, resources: [V2ResourcePreparedUpload] = [], imports: [UUID: V2ResourceImportRequest] = [:], now: Date = Date()) throws {
        guard intent.stage == .preparing else { throw V2ResourceJournalError.conflict }
        guard resources.count + imports.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(imports.keys).isDisjoint(with: resources.map(\.id)),
              imports.allSatisfy({ intent.attachmentJobIDs.contains($0.key) && $0.value.targetUsage == .messageAttachment(intent.roomID) }),
              Set(resources.map(\.id)).count == resources.count,
              resources.allSatisfy({ intent.attachmentJobIDs.contains($0.id) && $0.request.usage == .messageAttachment(intent.roomID) }) else { throw V2ResourceJournalError.invalidRecord }
        try databasePool.write { db in
            for (id, request) in imports {
                try Self.prepareResourceImport(id: id, request: request, now: now, db: db)
            }
            for resource in resources {
                _ = try Self.prepareResourceTransfer(id: resource.id, request: resource.request, localFileToken: resource.localFileToken, now: now, db: db)
            }
            if let existing = try Self.readSendIntent(intent.id, db: db) {
                guard existing.roomID == intent.roomID, existing.clientMessageID == intent.clientMessageID,
                      existing.text == intent.text, existing.mentions == intent.mentions,
                      existing.entities == intent.entities, existing.replyTo == intent.replyTo,
                      existing.attachmentJobIDs == intent.attachmentJobIDs else { throw V2ResourceJournalError.conflict }
                return
            }
            let deadline=try Self.messageSendDeadline(now:now)
            let reservation=try Self.messageSendReservation(intent,deadline:deadline,db:db)
            try Self.requireMessageRoomCapacity(room:intent.roomID,db:db)
            try Self.requireOperationCapacity(adding:reservation,db:db)
            try db.execute(sql: """
                INSERT INTO v2_send_intents(intent_id,client_message_id,room_id,text,mentions,entities,reply_to,stage,created_at,payload_bytes,admission_deadline)
                VALUES(?,?,?,?,?,?,?,'preparing',?,?,?)
                """, arguments: [intent.id.uuidString, intent.clientMessageID.rawValue, intent.roomID.rawValue, intent.text,
                                  try Self.encodeMentions(intent.mentions), try Self.encodeEntities(intent.entities, text: intent.text),
                                  intent.replyTo?.messageID.rawValue, try Self.commandRetryTimestamp(now),reservation,Int64(deadline)])
            for (ordinal, job) in intent.attachmentJobIDs.enumerated() {
                let imported = try Self.readResourceImport(job, db: db) != nil
                if !imported {
                    guard try Bool.fetchOne(db, sql: "SELECT staging_released=0 AND staging_release_started=0 AND cancellation_requested=0 FROM v2_resource_transfer_jobs WHERE job_id=?",
                        arguments: [job.uuidString]) == true else { throw V2ResourceJournalError.conflict }
                }
                let table = imported ? "v2_send_intent_import_dependencies" : "v2_send_intent_dependencies"
                try db.execute(sql: "INSERT INTO \(table)(intent_id,ordinal,job_id) VALUES(?,?,?)", arguments: [intent.id.uuidString, ordinal, job.uuidString])
            }
        }
    }

    public func preparingSendIntents(in roomID: RoomID? = nil, limit: Int = 64) throws -> [V2SendIntent] {
        guard (1...256).contains(limit) else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.read { db in
            let query = roomID == nil
                ? "SELECT intent_id FROM v2_send_intents WHERE stage = 'preparing' ORDER BY created_at LIMIT ?"
                : "SELECT intent_id FROM v2_send_intents WHERE stage = 'preparing' AND room_id=? ORDER BY created_at LIMIT ?"
            let arguments: StatementArguments = roomID.map { [$0.rawValue, limit] } ?? [limit]
            return try String.fetchAll(db, sql: query, arguments: arguments).map {
                guard let id = UUID(uuidString: $0), let intent = try Self.readSendIntent(id, db: db) else { throw V2ResourceJournalError.invalidRecord }
                return intent
            }
        }
    }

    /// Exact lookup for page actions; room/account result windows must never decide intent stage.
    public func preparingSendIntent(id: UUID) throws -> V2SendIntent? {
        try databasePool.read { db in
            guard let intent = try Self.readSendIntent(id, db: db), intent.stage == .preparing else { return nil }
            return intent
        }
    }

    public func sendIntentNeedsAttention(id: UUID) throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT w.scheduling_state='needsAttention' FROM v2_send_intents i
                JOIN v2_operation_work w ON w.work_id=i.work_id
                WHERE i.intent_id=? AND i.stage='handedOff'
                """, arguments: [id.uuidString]) ?? false
        }
    }

    public func sendIntentRoom(_ id:UUID) throws -> RoomID {
        try databasePool.read { db in
            guard let intent=try Self.readSendIntent(id,db:db) else { throw V2ResourceJournalError.invalidRecord }
            return intent.roomID
        }
    }
    public func submittedSendIntents(in roomID:RoomID,limit:Int=64,offset:Int=0) throws -> [V2SubmittedSendIntent] {
        guard (1...256).contains(limit), offset >= 0, offset <= Int.max - limit else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.write { db in
            try Self.settleAcceptedSendPresentations(roomID: roomID.rawValue, db: db)
            return try Self.readSubmittedSendIntents(in: roomID, limit: limit, offset: offset, db: db)
        }
    }

    static func readSubmittedSendIntents(in roomID: RoomID, limit: Int, offset: Int, db: Database) throws -> [V2SubmittedSendIntent] {
        return try Row.fetchAll(db,sql:"""
            SELECT i.intent_id,i.text,w.execution_state,w.scheduling_state FROM v2_send_intents i
            JOIN v2_operation_work w ON w.work_id=i.work_id
            JOIN v2_message_send_operations m ON m.work_id=w.work_id
            WHERE i.stage='handedOff' AND i.room_id=? AND \(Self.submittedSendVisibilityPredicate)
            ORDER BY CASE WHEN w.scheduling_state='finished' AND NOT (w.execution_state='committed' AND m.accepted_projection_observed=0) THEN 1 ELSE 0 END,
                CASE WHEN w.scheduling_state='finished' AND NOT (w.execution_state='committed' AND m.accepted_projection_observed=0) THEN -i.created_at ELSE i.created_at END,
                i.intent_id LIMIT ? OFFSET ?
            """,arguments:[roomID.rawValue,limit,offset]).map { row in
                guard let id=UUID(uuidString:row["intent_id"]) else { throw V2ResourceJournalError.invalidRecord }
                let state:String=row["execution_state"],schedule:String=row["scheduling_state"]
                let status:V2SubmittedSendIntent.Status = state=="committed" ? .acceptedAwaitingProjection : schedule=="needsAttention" ? .needsAttention
                    : state=="closed" ? .closed : state=="expiredUnsubmitted" ? .expiredUnsubmitted
                    : state=="rejected" ? .rejected : state=="conflicted" ? .needsAttention
                    : state=="awaitingConfirmation" || state=="submitting" || state=="processing" ? .confirmingOutcome : .pending
                return .init(id:id,text:row["text"],status:status)
            }
    }

    /// The ready preflight and outbox insert share one transaction. Once handed off,
    /// no new media IDs may be substituted, including after a resource TTL expires.
    @discardableResult
    public func handOffSendIntent(_ id: UUID, now: Date = Date(), limits:V2OperationWorkLimits = .init()) throws -> ClientMessageID {
        try databasePool.write { db in
            guard let intent = try Self.readSendIntent(id, db: db) else { throw V2ResourceJournalError.invalidRecord }
            if intent.stage == .handedOff { return intent.clientMessageID }
            guard intent.stage == .preparing else { throw V2ResourceJournalError.conflict }
            var media: [V2MediaReference] = []
            for job in intent.attachmentJobIDs {
                if let imported = try Self.readResourceImport(job, db: db) {
                    guard !imported.cancellationRequested, imported.request.targetUsage == .messageAttachment(intent.roomID),
                          let status = imported.status, status.state == .ready else { throw V2ResourceJournalError.dependencyNotReady }
                    guard let until = status.bindableUntilUnixMilliseconds, Double(until) / 1_000 > now.timeIntervalSince1970 else { throw V2ResourceJournalError.bindingExpired }
                    media.append(.init(mediaID: status.mediaID))
                    continue
                }
                guard let transfer = try Self.readResourceTransfer(job, db: db), !transfer.cancellationRequested,
                      transfer.request.usage == .messageAttachment(intent.roomID), transfer.stage == .ready else { throw V2ResourceJournalError.dependencyNotReady }
                guard let deadline = transfer.session?.bindableUntil, deadline > now else { throw V2ResourceJournalError.bindingExpired }
                media.append(.init(mediaID: transfer.request.mediaID))
            }
            guard let deadline=try Int64.fetchOne(db,sql:"SELECT admission_deadline FROM v2_send_intents WHERE intent_id=?",arguments:[id.uuidString]),deadline>0 else { throw V2OperationWorkError.invalidRecord }
            let command=try Self.messageSendEnvelope(intent,media:media,deadline:UInt64(deadline),db:db)
            // Transfer the preparation reservation atomically, so a full queue still permits its own handoff.
            try db.execute(sql: "UPDATE v2_send_intents SET stage='handedOff' WHERE intent_id=?", arguments: [id.uuidString])
            let workID=try Self.insertMessageSendWork(command,intentID:id,now:now,limits:limits,db:db)
            try db.execute(sql:"UPDATE v2_send_intents SET work_id=? WHERE intent_id=?",arguments:[workID.uuidString,id.uuidString])
            return intent.clientMessageID
        }
    }

    public func cancelSendIntent(_ id: UUID) throws {
        try databasePool.write { db in
            guard let intent = try Self.readSendIntent(id, db: db) else { throw V2ResourceJournalError.invalidRecord }
            guard intent.stage != .handedOff else { throw V2ResourceJournalError.alreadyHandedOff }
            try db.execute(sql: "UPDATE v2_send_intents SET stage='cancelled' WHERE intent_id=?", arguments: [id.uuidString])
        }
    }

    /// Explicit user retry. Only the permanent negative receipt authorizes a
    /// replacement; repeated taps/crash recovery return the same replacement.
    public func replaceProvenUnsentSendIntent(_ id: UUID, now: Date = Date()) throws -> UUID {
        try databasePool.write { db in
            if let existing=try String.fetchOne(db,sql:"SELECT intent_id FROM v2_send_intents WHERE replacement_of=?",arguments:[id.uuidString]) {
                guard let result=UUID(uuidString:existing) else {throw V2ResourceJournalError.invalidRecord};return result
            }
            let original=try Self.requireProvenUnsentSendIntent(id,db:db)
            let replacementID=UUID(), clientID=UUID()
            let deadline=try Self.messageSendDeadline(now:now)
            try db.execute(sql:"""
                INSERT INTO v2_send_intents(intent_id,client_message_id,room_id,text,mentions,entities,reply_to,stage,created_at,replacement_of,payload_bytes,admission_deadline)
                VALUES(?,?,?,?,?,?,?,'preparing',?,?,0,?)
                """,arguments:[replacementID.uuidString,clientID.uuidString,original.roomID.rawValue,original.text,
                    try Self.encodeMentions(original.mentions),try Self.encodeEntities(original.entities,text:original.text),
                    original.replyTo?.messageID.rawValue,try Self.commandRetryTimestamp(now),id.uuidString,Int64(deadline)])
            for (ordinal,oldID) in original.attachmentJobIDs.enumerated() {
                let newID=UUID()
                if let old=try Self.readResourceTransfer(oldID,db:db) {
                    let request=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),
                        usage:old.request.usage,contentType:old.request.contentType,byteCount:old.request.byteCount,
                        checksum:old.request.checksum,clientModes:old.request.clientModes)
                    guard try Bool.fetchOne(db,sql:"SELECT staging_released=0 AND staging_release_started=0 FROM v2_resource_transfer_jobs WHERE job_id=?",arguments:[oldID.uuidString]) == true
                    else {throw V2ResourceJournalError.invalidRecord}
                    // Share the immutable local file; its release predicate includes every job using it.
                    _ = try Self.prepareResourceTransfer(id: newID, request: request, localFileToken: old.localFileToken, now: now, db: db)
                    try db.execute(sql:"INSERT INTO v2_send_intent_dependencies(intent_id,ordinal,job_id) VALUES(?,?,?)",arguments:[replacementID.uuidString,ordinal,newID.uuidString])
                } else if let old=try Self.readResourceImport(oldID,db:db) {
                    let request=try V2ResourceImportRequest(operationID:.init(uuid:UUID()),source:old.request.source,
                        targetUsage:old.request.targetUsage,targetMediaID:.init(uuid:UUID()))
                    try Self.prepareResourceImport(id: newID, request: request, now: now, db: db)
                    try db.execute(sql:"INSERT INTO v2_send_intent_import_dependencies(intent_id,ordinal,job_id) VALUES(?,?,?)",arguments:[replacementID.uuidString,ordinal,newID.uuidString])
                } else {throw V2ResourceJournalError.invalidRecord}
            }
            guard let replacement=try Self.readSendIntent(replacementID,db:db) else { throw V2ResourceJournalError.invalidRecord }
            let reservation=try Self.messageSendReservation(replacement,deadline:deadline,db:db)
            try Self.requireMessageRoomCapacity(room:original.roomID,excludingIntent:replacementID,db:db)
            try Self.requireOperationCapacity(adding:reservation,excludingIntent:replacementID,db:db)
            try db.execute(sql:"UPDATE v2_send_intents SET payload_bytes=? WHERE intent_id=?",arguments:[reservation,replacementID.uuidString])
            try db.execute(sql:"UPDATE v2_send_intents SET stage='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
            return replacementID
        }
    }

    public func abandonProvenUnsentSendIntent(_ id: UUID) throws {
        try databasePool.write { db in
            _ = try Self.requireProvenUnsentSendIntent(id,db:db)
            try db.execute(sql:"UPDATE v2_send_intents SET stage='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
        }
    }

    private static func requireProvenUnsentSendIntent(_ id:UUID,db:Database) throws -> V2SendIntent {
        guard let original=try readSendIntent(id,db:db),original.stage == .handedOff,
            let row=try Row.fetchOne(db,sql:"SELECT w.* FROM v2_send_intents i JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.intent_id=?",arguments:[id.uuidString]) else { throw V2ResourceJournalError.conflict }
        let work=try decodeOperationWork(row)
        // This is a local admission fact, not a fabricated remote rejection.
        // Once submission has started, only a bound permanent receipt suffices.
        if work.execution == .expiredUnsubmitted, !work.submissionStarted, work.scheduling == .finished {
            return original
        }
        guard let data=row["terminal_receipt"] as Data? else { throw V2ResourceJournalError.conflict }
        let receipt=try JSONDecoder().decode(V2MessageSendOperationReceipt.self,from:data)
        guard receipt.validates(identity:work.identity,fingerprint:work.fingerprint) else {
            throw V2ResourceJournalError.conflict
        }
        switch (work.execution, receipt.outcome) {
        case (.rejected, .rejected): break
        default: throw V2ResourceJournalError.conflict
        }
        return original
    }

    static func readSendIntent(_ id: UUID, db: Database) throws -> V2SendIntent? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_send_intents WHERE intent_id=?", arguments: [id.uuidString]) else { return nil }
        let jobs = try String.fetchAll(db, sql: "SELECT job_id,ordinal FROM v2_send_intent_dependencies WHERE intent_id=? UNION ALL SELECT job_id,ordinal FROM v2_send_intent_import_dependencies WHERE intent_id=? ORDER BY ordinal", arguments: [id.uuidString, id.uuidString]).map {
            guard let id = UUID(uuidString: $0) else { throw V2ResourceJournalError.invalidRecord }; return id
        }
        guard let stage = V2SendIntent.Stage(rawValue: row["stage"]) else { throw V2ResourceJournalError.invalidRecord }
        let reply: String? = row["reply_to"]
        return try .init(id: id, roomID: .init(row["room_id"]), clientMessageID: .init(row["client_message_id"]), text: row["text"], mentions: decodeMentions(row["mentions"]), entities: decodeEntities(row["entities"], text: row["text"]), replyTo: reply.map { try .init(messageID: .init($0)) }, attachmentJobIDs: jobs, stage: stage)
    }
}
