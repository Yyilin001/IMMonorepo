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
            retry_at REAL NOT NULL DEFAULT 0, last_error TEXT,
            staging_released INTEGER NOT NULL DEFAULT 0 CHECK(staging_released IN (0,1)),
            staging_release_started INTEGER NOT NULL DEFAULT 0 CHECK(staging_release_started IN (0,1)),
            bindable_until REAL, created_at REAL NOT NULL
        );
        CREATE INDEX v2_resource_transfer_due ON v2_resource_transfer_jobs(retry_at, job_id)
            WHERE stage IN ('prepared','transferring','processing');
        CREATE INDEX v2_resource_staging_release_candidates ON v2_resource_transfer_jobs(job_id) WHERE stage='ready' AND staging_released=0;
        CREATE INDEX v2_resource_jobs_local_file ON v2_resource_transfer_jobs(local_file_token);
        CREATE TABLE v2_send_intents (
            intent_id TEXT PRIMARY KEY, client_message_id TEXT NOT NULL UNIQUE,
            room_id TEXT NOT NULL, text TEXT NOT NULL,
            mentions TEXT NOT NULL, entities TEXT NOT NULL, reply_to TEXT,
            stage TEXT NOT NULL CHECK(stage IN ('preparing','handedOff','cancelled')),
            replacement_of TEXT REFERENCES v2_send_intents(intent_id),
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
            retry_at REAL NOT NULL DEFAULT 0, created_at REAL NOT NULL
        );
        CREATE TABLE v2_send_intent_import_dependencies (
            intent_id TEXT NOT NULL REFERENCES v2_send_intents(intent_id),
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            job_id TEXT NOT NULL REFERENCES v2_resource_import_jobs(job_id),
            PRIMARY KEY(intent_id,ordinal), UNIQUE(intent_id,job_id)
        );
        """

    public func freezeSendIntent(_ intent: V2SendIntent, now: Date = Date()) throws {
        guard intent.stage == .preparing else { throw V2ResourceJournalError.conflict }
        try databasePool.write { db in
            if let existing = try Self.readSendIntent(intent.id, db: db) {
                guard existing.roomID == intent.roomID, existing.clientMessageID == intent.clientMessageID,
                      existing.text == intent.text, existing.mentions == intent.mentions,
                      existing.entities == intent.entities, existing.replyTo == intent.replyTo,
                      existing.attachmentJobIDs == intent.attachmentJobIDs else { throw V2ResourceJournalError.conflict }
                return
            }
            try db.execute(sql: """
                INSERT INTO v2_send_intents(intent_id,client_message_id,room_id,text,mentions,entities,reply_to,stage,created_at)
                VALUES(?,?,?,?,?,?,?,'preparing',?)
                """, arguments: [intent.id.uuidString, intent.clientMessageID.rawValue, intent.roomID.rawValue, intent.text,
                                  try Self.encodeMentions(intent.mentions), try Self.encodeEntities(intent.entities, text: intent.text),
                                  intent.replyTo?.messageID.rawValue, try Self.commandRetryTimestamp(now)])
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

    public func submittedSendIntents(in roomID: RoomID, limit: Int = 64) throws -> [V2SubmittedSendIntent] {
        guard (1...256).contains(limit) else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT i.intent_id,i.text,c.state,c.terminal_code,r.client_message_id AS recovering
                FROM v2_send_intents i JOIN v2_pending_message_commands c USING(client_message_id)
                LEFT JOIN v2_message_operation_recoveries r USING(client_message_id)
                WHERE i.stage='handedOff' AND i.room_id=? AND c.state<>'accepted'
                ORDER BY i.created_at,i.intent_id LIMIT ?
                """, arguments: [roomID.rawValue,limit]).map { row in
                guard let id=UUID(uuidString:row["intent_id"]) else {throw V2ResourceJournalError.invalidRecord}
                let recovery:String?=row["recovering"], state:String=row["state"], code:String?=row["terminal_code"]
                let status:V2SubmittedSendIntent.Status = recovery != nil ? .confirmingOutcome
                    : state == "pending" ? .pending : code == "MESSAGE_OPERATION_CLOSED" ? .closed : .rejected
                return .init(id:id,text:row["text"],status:status)
            }
        }
    }

    /// The ready preflight and outbox insert share one transaction. Once handed off,
    /// no new media IDs may be substituted, including after a resource TTL expires.
    @discardableResult
    public func handOffSendIntent(_ id: UUID, now: Date = Date()) throws -> ClientMessageID {
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
            let command = V2PendingMessageCommand(roomID: intent.roomID, clientMessageID: intent.clientMessageID, text: intent.text, media: media, mentions: intent.mentions, entities: intent.entities, replyTo: intent.replyTo, state: .pending, attemptCount: 0, nextAttemptAt: now, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
            try Self.enqueueMessage(command, db: db)
            try db.execute(sql: "UPDATE v2_send_intents SET stage='handedOff' WHERE intent_id=?", arguments: [id.uuidString])
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
    public func replacePermanentlyClosedSendIntent(_ id: UUID, now: Date = Date()) throws -> UUID {
        try databasePool.write { db in
            if let existing=try String.fetchOne(db,sql:"SELECT intent_id FROM v2_send_intents WHERE replacement_of=?",arguments:[id.uuidString]) {
                guard let result=UUID(uuidString:existing) else {throw V2ResourceJournalError.invalidRecord};return result
            }
            let original=try Self.requireClosedSendIntent(id,db:db)
            let replacementID=UUID(), clientID=UUID()
            try db.execute(sql:"""
                INSERT INTO v2_send_intents(intent_id,client_message_id,room_id,text,mentions,entities,reply_to,stage,created_at,replacement_of)
                VALUES(?,?,?,?,?,?,?,'preparing',?,?)
                """,arguments:[replacementID.uuidString,clientID.uuidString,original.roomID.rawValue,original.text,
                    try Self.encodeMentions(original.mentions),try Self.encodeEntities(original.entities,text:original.text),
                    original.replyTo?.messageID.rawValue,try Self.commandRetryTimestamp(now),id.uuidString])
            for (ordinal,oldID) in original.attachmentJobIDs.enumerated() {
                let newID=UUID()
                if let old=try Self.readResourceTransfer(oldID,db:db) {
                    let request=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),
                        usage:old.request.usage,contentType:old.request.contentType,byteCount:old.request.byteCount,
                        checksum:old.request.checksum,clientModes:old.request.clientModes)
                    guard try Bool.fetchOne(db,sql:"SELECT staging_released=0 AND staging_release_started=0 FROM v2_resource_transfer_jobs WHERE job_id=?",arguments:[oldID.uuidString]) == true
                    else {throw V2ResourceJournalError.invalidRecord}
                    // Share the immutable local file; its release predicate includes every job using it.
                    try db.execute(sql:"""
                        INSERT INTO v2_resource_transfer_jobs(job_id,operation_id,media_id,request,local_file_token,stage,created_at)
                        VALUES(?,?,?,?,?,'prepared',?)
                        """,arguments:[newID.uuidString,request.operationID.rawValue,request.mediaID.rawValue,
                            try JSONEncoder().encode(request),old.localFileToken,try Self.commandRetryTimestamp(now)])
                    try db.execute(sql:"INSERT INTO v2_send_intent_dependencies(intent_id,ordinal,job_id) VALUES(?,?,?)",arguments:[replacementID.uuidString,ordinal,newID.uuidString])
                } else if let old=try Self.readResourceImport(oldID,db:db) {
                    let request=try V2ResourceImportRequest(operationID:.init(uuid:UUID()),source:old.request.source,
                        targetUsage:old.request.targetUsage,targetMediaID:.init(uuid:UUID()))
                    try db.execute(sql:"INSERT INTO v2_resource_import_jobs(job_id,request,stage,created_at) VALUES(?,?,'pending',?)",
                        arguments:[newID.uuidString,try JSONEncoder().encode(request),try Self.commandRetryTimestamp(now)])
                    try db.execute(sql:"INSERT INTO v2_send_intent_import_dependencies(intent_id,ordinal,job_id) VALUES(?,?,?)",arguments:[replacementID.uuidString,ordinal,newID.uuidString])
                } else {throw V2ResourceJournalError.invalidRecord}
            }
            try db.execute(sql:"UPDATE v2_send_intents SET stage='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
            return replacementID
        }
    }

    public func abandonPermanentlyClosedSendIntent(_ id: UUID) throws {
        try databasePool.write { db in
            _ = try Self.requireClosedSendIntent(id,db:db)
            try db.execute(sql:"UPDATE v2_send_intents SET stage='cancelled' WHERE intent_id=?",arguments:[id.uuidString])
        }
    }

    private static func requireClosedSendIntent(_ id: UUID,db:Database) throws -> V2SendIntent {
        guard let original=try readSendIntent(id,db:db),original.stage == .handedOff,
              try Bool.fetchOne(db,sql:"""
                SELECT EXISTS(SELECT 1 FROM v2_pending_message_commands c
                    WHERE c.client_message_id=? AND c.state='rejected' AND c.terminal_code='MESSAGE_OPERATION_CLOSED'
                    AND NOT EXISTS(SELECT 1 FROM v2_message_operation_recoveries r WHERE r.client_message_id=c.client_message_id))
                """,arguments:[original.clientMessageID.rawValue]) == true
        else {throw V2ResourceJournalError.conflict}
        return original
    }

    private static func readSendIntent(_ id: UUID, db: Database) throws -> V2SendIntent? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_send_intents WHERE intent_id=?", arguments: [id.uuidString]) else { return nil }
        let jobs = try String.fetchAll(db, sql: "SELECT job_id,ordinal FROM v2_send_intent_dependencies WHERE intent_id=? UNION ALL SELECT job_id,ordinal FROM v2_send_intent_import_dependencies WHERE intent_id=? ORDER BY ordinal", arguments: [id.uuidString, id.uuidString]).map {
            guard let id = UUID(uuidString: $0) else { throw V2ResourceJournalError.invalidRecord }; return id
        }
        guard let stage = V2SendIntent.Stage(rawValue: row["stage"]) else { throw V2ResourceJournalError.invalidRecord }
        let reply: String? = row["reply_to"]
        return try .init(id: id, roomID: .init(row["room_id"]), clientMessageID: .init(row["client_message_id"]), text: row["text"], mentions: decodeMentions(row["mentions"]), entities: decodeEntities(row["entities"], text: row["text"]), replyTo: reply.map { try .init(messageID: .init($0)) }, attachmentJobIDs: jobs, stage: stage)
    }
}
