import Foundation
import GRDB
import IMV2Core

public protocol V2MessageSendOperationClient:Sendable {
    func submit(_ command:V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult
    func recover(_ request:V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult
}
extension GRDBV2LocalSyncStore {
    static func messageSendDeadline(now:Date) throws -> UInt64 {
        let value=try commandRetryTimestamp(now)*1_000
        guard value>0,value<Double(Int64.max),let window=V2CommandPolicy.registered(for:.sendMessage).firstSubmissionWindowMilliseconds,
            UInt64(value)<=UInt64(Int64.max)-window else { throw V2OperationWorkError.invalidRecord }
        return UInt64(value)+V2ClientSubmissionWindow.milliseconds(maximum:window)
    }
    static func messageSendEnvelope(_ intent:V2SendIntent,media:[V2MediaReference],deadline:UInt64,db:Database) throws -> V2MessageSendOperationCommand {
        guard let raw=try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1") else { throw V2OperationWorkError.accountMismatch }
        let command=try V2SendMessageCommand(roomID:intent.roomID,senderUserID:.init(raw),clientMessageID:intent.clientMessageID,text:intent.text,
            media:media,mentions:intent.mentions,entities:intent.entities,replyTo:intent.replyTo,limits:.init(maxUTF8Bytes:65_536))
        return try .init(command:command,firstSubmissionDeadlineMilliseconds:deadline)
    }
    /// Count the exact future envelope even while resource dependencies have not reached Ready.
    // Bounded derived acceptance ID/sequence and snapshot presentation evidence.
    // This reservation survives acceptance until real projection convergence.
    static func messageSendReservation(_ intent:V2SendIntent,deadline:UInt64,db:Database) throws -> Int64 {
        let media=try intent.attachmentJobIDs.map { id -> V2MediaReference in
            if let upload=try readResourceTransfer(id,db:db) { return .init(mediaID:upload.request.mediaID) }
            if let imported=try readResourceImport(id,db:db) { return .init(mediaID:imported.request.targetMediaID) }
            throw V2ResourceJournalError.dependencyNotReady
        }
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return Int64(try encoder.encode(messageSendEnvelope(intent,media:media,deadline:deadline,db:db)).count) + 256
    }
    static func requireMessageRoomCapacity(room:RoomID,excludingIntent:UUID?=nil,db:Database) throws {
        let count=try Int.fetchOne(db,sql:"""
            SELECT SUM(n) FROM (
                SELECT COUNT(*) n FROM v2_send_intents WHERE room_id=? AND stage='preparing' AND intent_id<>?
                UNION ALL SELECT COUNT(*) FROM v2_message_send_operations m JOIN v2_operation_work w USING(work_id)
                    WHERE m.room_id=? AND (w.scheduling_state<>'finished' OR (w.execution_state='committed' AND m.accepted_projection_observed=0)))
            """,arguments:[room.rawValue,excludingIntent?.uuidString ?? "",room.rawValue]) ?? 0
        guard count<200 else { throw V2OperationWorkError.capacityExceeded }
    }
    static let messageSendWorkSchemaSQL="""
        CREATE TABLE v2_message_send_operations(
            work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            client_message_id TEXT NOT NULL UNIQUE,room_id TEXT NOT NULL,
            command BLOB NOT NULL CHECK(length(command)>0 AND length(command)<=1048576),
            accepted_message_id TEXT,accepted_room_sequence INTEGER CHECK(accepted_room_sequence>0),
            accepted_projection_observed INTEGER NOT NULL DEFAULT 0 CHECK(accepted_projection_observed IN (0,1)),
            projection_observed_snapshot_id TEXT,
            CHECK((accepted_message_id IS NULL)=(accepted_room_sequence IS NULL)));
        CREATE INDEX v2_message_send_waiting_projection ON v2_message_send_operations(room_id,work_id)
            WHERE accepted_message_id IS NOT NULL AND accepted_projection_observed=0;
        CREATE INDEX v2_message_send_snapshot_evidence ON v2_message_send_operations(projection_observed_snapshot_id)
            WHERE projection_observed_snapshot_id IS NOT NULL;
        CREATE INDEX v2_message_send_operations_room ON v2_message_send_operations(room_id);
        """
    static func insertMessageSendWork(_ command:V2MessageSendOperationCommand,intentID:UUID,now:Date,limits:V2OperationWorkLimits = .init(),db:Database) throws -> UUID {
        guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1") == command.command.senderUserID.rawValue else {
            throw V2OperationWorkError.accountMismatch
        }
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let bytes=try encoder.encode(command)
        guard bytes.count<=1_048_576 else { throw V2OperationWorkError.invalidRecord }
        let id=UUID()
        try Self.insertOperationWork(.init(id:id,intentID:intentID,identity:command.identity,fingerprint:command.fingerprint,
            orderingKey:"send:"+command.command.roomID.rawValue,payloadBytes:Int64(bytes.count) + 256,
            admissionDeadline:Date(timeIntervalSince1970:Double(command.firstSubmissionDeadlineMilliseconds)/1_000)),now:now,limits:limits,db:db)
        try db.execute(sql:"INSERT INTO v2_message_send_operations(work_id,client_message_id,room_id,command) VALUES(?,?,?,?)",
            arguments:[id.uuidString,command.command.clientMessageID.rawValue,command.command.roomID.rawValue,bytes])
        return id
    }
    func messageSendCommand(workID:UUID) throws -> V2MessageSendOperationCommand {
        try databasePool.read { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT command,client_message_id,room_id FROM v2_message_send_operations WHERE work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let command=try JSONDecoder().decode(V2MessageSendOperationCommand.self,from:row["command"])
            guard command.command.clientMessageID.rawValue == row["client_message_id"] as String,
                command.command.roomID.rawValue == row["room_id"] as String else { throw V2OperationWorkError.identityConflict }
            return command
        }
    }
    static let submittedSendVisibilityPredicate = """
        (w.execution_state<>'committed' OR (m.accepted_message_id IS NOT NULL AND m.accepted_projection_observed=0
            AND NOT EXISTS(SELECT 1 FROM v2_room_membership_states a WHERE a.room_id=m.room_id AND a.is_member=0)
            AND NOT EXISTS(SELECT 1 FROM v2_room_event_authorizations a WHERE a.room_id=m.room_id AND a.is_authorized=0)))
        """

    /// A one-way presentation marker; it never changes execution or delivery state.
    static func settleAcceptedSendPresentations(roomID: String, db: Database) throws {
        try db.execute(sql: """
            UPDATE v2_message_send_operations AS m SET accepted_projection_observed=1,projection_observed_snapshot_id=NULL
            WHERE m.room_id=? AND m.accepted_message_id IS NOT NULL AND m.accepted_projection_observed=0
              AND (EXISTS(SELECT 1 FROM v2_message_projections p WHERE p.message_id=m.accepted_message_id
                    AND p.room_id=m.room_id AND p.room_sequence=m.accepted_room_sequence)
                OR EXISTS(SELECT 1 FROM v2_message_tombstones t WHERE t.message_id=m.accepted_message_id AND t.room_id=m.room_id)
                )
            """, arguments: [roomID])
    }

    static func prepareAcceptedSendSnapshotEvidence(snapshotID: String, workID: String? = nil, db: Database) throws {
        let messages = ProjectionTableTarget.snapshotShadow.table("v2_message_projections")
        let tombstones = ProjectionTableTarget.snapshotShadow.table("v2_message_tombstones")
        try db.execute(sql: """
            UPDATE v2_message_send_operations AS m SET projection_observed_snapshot_id=?
            WHERE (? IS NULL OR m.work_id=?) AND m.accepted_message_id IS NOT NULL AND m.accepted_projection_observed=0
              AND (EXISTS(SELECT 1 FROM \(messages) p WHERE p.message_id=m.accepted_message_id
                    AND p.room_id=m.room_id AND p.room_sequence=m.accepted_room_sequence)
                OR EXISTS(SELECT 1 FROM \(tombstones) t WHERE t.message_id=m.accepted_message_id AND t.room_id=m.room_id)
                )
            """, arguments: [snapshotID,workID,workID])
    }

    func completeMessageSend(_ command:V2MessageSendOperationCommand,receipt:V2MessageSendOperationReceipt,now:Date=Date()) throws {
        let identity=try command.identity,fingerprint=try command.fingerprint
        guard receipt.validates(identity:identity,fingerprint:fingerprint) else { throw V2OperationWorkError.identityConflict }
        let state:V2OperationExecutionState
        switch receipt.outcome { case .accepted: state = .committed
        case .rejected: state = .rejected }
        try databasePool.write { db in
            try Self.completeOperationWork(.init(identity:identity,fingerprint:fingerprint,state:state,receipt:receipt),now:now,db:db)
            if case .accepted(let acceptance) = receipt.outcome {
                guard let sequence = Int64(exactly: acceptance.roomSequence), sequence > 0 else { throw V2OperationWorkError.invalidRecord }
                try db.execute(sql: "UPDATE v2_message_send_operations SET accepted_message_id=?,accepted_room_sequence=? WHERE work_id=(SELECT work_id FROM v2_operation_work WHERE identity_key=?)",
                    arguments: [acceptance.messageID.rawValue,sequence,identity.storageKey])
                // A projection may have arrived before the send receipt.
                try Self.settleAcceptedSendPresentations(roomID: command.command.roomID.rawValue, db: db)
                // Receipt installation may race the interval between shadow
                // preparation and ACK activation. Attach this one receipt to
                // the already prepared snapshot evidence in the same write.
                if let snapshotID = try String.fetchOne(db, sql: "SELECT snapshot_id FROM v2_snapshot_import WHERE activation_prepared=1"),
                   let workID = try String.fetchOne(db, sql: "SELECT work_id FROM v2_operation_work WHERE identity_key=?", arguments: [identity.storageKey]) {
                    try Self.prepareAcceptedSendSnapshotEvidence(snapshotID: snapshotID, workID: workID, db: db)
                }
            }
        }
        // Accepted means the server accepted this identity, never moderation approval or delivery.
    }
}
public actor V2MessageSendOperationService {
    private let accountID:UserID
    private let store:GRDBV2LocalSyncStore
    private let client:any V2MessageSendOperationClient
    public init(accountID:UserID,store:GRDBV2LocalSyncStore,client:any V2MessageSendOperationClient) {
        self.accountID=accountID;self.store=store;self.client=client
    }
    @discardableResult public func enqueueMessage(roomID:RoomID,text:String,mentions:[V2MentionTarget]=[],entities:[V2MessageEntity]=[],replyTo:V2MessageReplyReference?=nil) async throws -> UUID {
        try Task.checkCancellation()
        let intent=try V2SendIntent(id:UUID(),roomID:roomID,clientMessageID:.init(UUID().uuidString),text:text,mentions:mentions,entities:entities,replyTo:replyTo,attachmentJobIDs:[])
        try await store.freezeSendIntent(intent)
        return intent.id
    }
    public func resumeConfirmation(intentID:UUID) async throws {
        let workID=try await store.databasePool.read { db in
            try String.fetchOne(db,sql:"SELECT work_id FROM v2_send_intents WHERE intent_id=?",arguments:[intentID.uuidString]).flatMap(UUID.init(uuidString:))
        }
        guard let workID,let work=try await store.operationWork(id:workID),work.identity.accountID==accountID,work.identity.kind == .sendMessage else { throw V2OperationWorkError.accountMismatch }
        try await store.retryOperationWorkByUser(id:workID,now:Date())
    }
    public func execute(_ claim:V2OperationWorkClaim) async throws {
        guard claim.work.identity.accountID==accountID,claim.work.identity.kind == .sendMessage else { throw V2OperationWorkError.accountMismatch }
        let command=try await store.messageSendCommand(workID:claim.work.id)
        guard try command.identity==claim.work.identity,try command.fingerprint==claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
        do {
            let result:V2MessageSendOperationRecoveryResult
            if claim.action == .submit { result=try await client.submit(command) }
            else {
                result=try await client.recover(.init(identity:claim.work.identity,fingerprint:claim.work.fingerprint,
                    domainFingerprint:command.command.fingerprint))
            }
            switch result {
            case .receipt(let receipt):try await store.completeMessageSend(command,receipt:receipt)
            case .fingerprintConflict:try await store.deferOperationWork(claim,until:Date(),code:"MESSAGE_SEND_FINGERPRINT_CONFLICT",scheduling:.needsAttention)
            case .deferred(let hint):
                guard hint.validates(identity:claim.work.identity,fingerprint:claim.work.fingerprint) else { throw V2OperationWorkError.identityConflict }
                let now=Date(),policy=V2NetworkWorkPolicy.commandRecovery
                let floor=now.addingTimeInterval(Double(hint.retryAfterMilliseconds ?? 0)/1_000)
                let deadline=(claim.action == .submit ? claim.work.submissionRoundDeadline : claim.work.reconciliationRoundDeadline) ?? now.addingTimeInterval(policy.totalBudget)
                let attempts=claim.action == .submit ? claim.work.submissionRoundAttempts : claim.work.reconciliationRoundAttempts
                let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:attempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:floor)
                try await store.deferOperationWork(claim,until:max(retry ?? now,floor),code:hint.reason == .rateLimited ? "RATE_LIMITED" : "ADMISSION_UNAVAILABLE",scheduling:retry == nil ? .needsAttention : .backingOff,nextAction:claim.action)
            case .unresolved:
                let now = Date()
                let canResubmit = now.timeIntervalSince1970 * 1_000 < Double(command.firstSubmissionDeadlineMilliseconds)
                try await store.deferOperationWork(claim,
                    until: now.addingTimeInterval(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt: claim.work.reconciliationRoundAttempts)),
                    code: "MESSAGE_SEND_UNRESOLVED",
                    scheduling: canResubmit ? .backingOff : .needsAttention,
                    nextAction: canResubmit ? .submit : .reconcile)
            }
        } catch is CancellationError {
            try await store.deferOperationWork(claim,until:Date(),code:"MESSAGE_SEND_INTERRUPTED")
            throw CancellationError()
        } catch {
            let now=Date(),transportFailure=error as? V2MessageSendTransportError,policy=V2NetworkWorkPolicy.commandRecovery
            let nextAction: V2OperationWorkAction
            switch transportFailure {
            case .unavailableBeforeSubmission, .authenticationRequired, .busyBeforeSubmission:
                nextAction = claim.action
            default:
                nextAction = .reconcile
            }
            // Outcome recovery owns a separate durable round. Exhausting the
            // submission round must not prevent its first original-ID query.
            let deadline=(nextAction == .submit ? claim.work.submissionRoundDeadline : claim.work.reconciliationRoundDeadline) ?? now.addingTimeInterval(policy.totalBudget)
            let retryAfter: Date?
            switch transportFailure {
            case .retryAfter(let date), .busyBeforeSubmission(let date): retryAfter = date
            default: retryAfter = nil
            }
            let attempts = nextAction == .submit ? claim.work.submissionRoundAttempts : claim.work.reconciliationRoundAttempts
            let retry=policy.nextAttempt(now:now,startedAt:deadline.addingTimeInterval(-policy.totalBudget),attemptsCompleted:attempts,randomUnit:Double.random(in:0...1),serverRetryNotBefore:retryAfter)
            let malformed=error is V2OperationWorkError || error is V2MessageOperationValidationError ||
                transportFailure == .invalidResponse || transportFailure == .unsupportedCapability
            let scheduling: V2OperationSchedulingState
            let code: String
            switch transportFailure {
            case .unavailableBeforeSubmission:
                scheduling = .waitingForNetwork
                code = "MESSAGE_SEND_TRANSPORT_UNAVAILABLE"
            case .authenticationRequired:
                scheduling = .waitingForAuthentication
                code = "MESSAGE_SEND_AUTHENTICATION_REQUIRED"
            case .busyBeforeSubmission:
                scheduling = retry == nil ? .needsAttention : .backingOff
                code = "MESSAGE_SEND_CAPACITY_UNAVAILABLE"
            case .outcomeUnknown:
                scheduling = retry == nil ? .needsAttention : .backingOff
                code = "MESSAGE_SEND_OUTCOME_UNKNOWN"
            default:
                scheduling = malformed || retry == nil ? .needsAttention : .backingOff
                code = "MESSAGE_SEND_CONFIRMATION_REQUIRED"
            }
            try await store.deferOperationWork(claim,until:max(retry ?? now,retryAfter ?? now),code:code,scheduling:scheduling,nextAction:nextAction)
            if error is DatabaseError { throw error }
        }
    }
}

extension V2MessageSendOperationService {
    /// Observes exactly the send clicked by this page, including a lost ACK recovered later.
    public func confirmationUpdates(intentID: UUID) -> AsyncThrowingStream<V2OperationExecutionState?, any Error> {
        let pool = store.databasePool
        let account = accountID
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observer = Task {
                do {
                    let observation = ValueObservation.tracking { db -> V2OperationExecutionState? in
                        guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == account.rawValue else { throw V2OperationWorkError.accountMismatch }
                        guard let row = try Row.fetchOne(db, sql: "SELECT w.* FROM v2_send_intents i JOIN v2_operation_work w ON w.work_id=i.work_id WHERE i.intent_id=?", arguments: [intentID.uuidString]) else { return nil }
                        return try GRDBV2LocalSyncStore.decodeOperationWork(row).execution
                    }.removeDuplicates()
                    for try await state in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                        continuation.yield(state)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
    }
}
