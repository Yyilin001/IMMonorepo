import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let readReceiptWorkSchemaSQL = """
        CREATE TABLE v2_read_receipt_intents (
            room_id TEXT PRIMARY KEY,
            desired_sequence INTEGER NOT NULL CHECK(typeof(desired_sequence)='integer' AND desired_sequence>0),
            payload_bytes INTEGER NOT NULL CHECK(typeof(payload_bytes)='integer' AND payload_bytes>0)
        );
        CREATE TABLE v2_read_receipt_operations (
            work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            room_id TEXT NOT NULL,
            requested_sequence INTEGER NOT NULL CHECK(typeof(requested_sequence)='integer' AND requested_sequence>0),
            command BLOB NOT NULL CHECK(length(command)<=65536)
        );
        CREATE INDEX v2_read_receipt_operations_room ON v2_read_receipt_operations(room_id);
        CREATE TABLE v2_read_receipt_archives (
            work_id TEXT PRIMARY KEY,
            room_id TEXT NOT NULL,
            requested_sequence INTEGER NOT NULL CHECK(typeof(requested_sequence)='integer' AND requested_sequence>0),
            command BLOB NOT NULL CHECK(length(command)<=4096),
            archived_at REAL NOT NULL
        );
        CREATE INDEX v2_read_receipt_archives_room ON v2_read_receipt_archives(room_id,archived_at,work_id);
        """

    /// One unfrozen successor per room. Frozen commands never change identity or payload.
    @discardableResult public func enqueueReadReceiptIntent(accountID: UserID, roomID: RoomID, readThrough: UInt64, limits: V2OperationWorkLimits = .init()) throws -> Bool {
        guard readThrough > 0, readThrough <= UInt64(Int64.max) else { throw V2ReadReceiptValidationError.invalidRoomSequence }
        return try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            let watermark = try Self.readReceiptLocalHighWater(roomID: roomID, db: db)
            guard readThrough > watermark else { return false }
            let reservation = try JSONEncoder().encode(V2RecordReadReceiptCommand(roomID:roomID,actorUserID:accountID,
                operationID:.init(uuid:UUID()),readThroughRoomSequence:readThrough)).count
            try Self.requireOperationCapacity(adding:Int64(reservation),excludingReadReceiptRoom:roomID.rawValue,limits:limits,db:db)
            try db.execute(sql: """
                INSERT INTO v2_read_receipt_intents(room_id,desired_sequence,payload_bytes) VALUES(?,?,?)
                ON CONFLICT(room_id) DO UPDATE SET desired_sequence=MAX(desired_sequence,excluded.desired_sequence),payload_bytes=MAX(payload_bytes,excluded.payload_bytes)
                """, arguments: [roomID.rawValue, Int64(readThrough),reservation])
            return true
        }
    }
    static func readReceiptLocalHighWater(roomID: RoomID, db: Database) throws -> UInt64 {
        let row = try Row.fetchOne(db, sql: """
            SELECT CASE WHEN COALESCE(MIN(CASE WHEN typeof(value)='integer' AND value>0 THEN 1 ELSE 0 END),1)=1
                THEN COALESCE(MAX(value),0) ELSE -1 END AS value FROM (
                SELECT read_through_room_sequence AS value FROM v2_room_read_watermarks WHERE room_id=?
                UNION ALL SELECT desired_sequence FROM v2_read_receipt_intents WHERE room_id=?
                UNION ALL SELECT requested_sequence FROM v2_read_receipt_archives WHERE room_id=?
                UNION ALL SELECT r.requested_sequence FROM v2_read_receipt_operations r JOIN v2_operation_work w ON w.work_id=r.work_id
                    WHERE r.room_id=? AND w.execution_state NOT IN ('rejected','closed','cancelledLocally','expiredUnsubmitted')
            )
            """, arguments: [roomID.rawValue, roomID.rawValue, roomID.rawValue, roomID.rawValue])!
        return try storageUnsigned(row, column: "value")
    }
    private static let nextReadReceiptIntentQuery = """
        SELECT i.room_id,i.desired_sequence FROM v2_read_receipt_intents i
        WHERE NOT EXISTS(SELECT 1 FROM v2_read_receipt_operations r JOIN v2_operation_work w ON w.work_id=r.work_id
            WHERE r.room_id=i.room_id AND w.scheduling_state<>'finished')
        ORDER BY i.room_id LIMIT 1
        """
    @discardableResult public func prepareNextReadReceiptIntent(accountID: UserID, now: Date = Date(), limits: V2OperationWorkLimits = .init()) throws -> Bool {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            guard let row = try Row.fetchOne(db, sql: Self.nextReadReceiptIntentQuery) else { return false }
            let room = try RoomID(row["room_id"] as String), sequence = try Self.storageUnsigned(row, column: "desired_sequence")
            let confirmed = try Row.fetchOne(db, sql: "SELECT read_through_room_sequence AS value FROM v2_room_read_watermarks WHERE room_id=?", arguments: [room.rawValue]).map { try Self.storageUnsigned($0,column: "value") } ?? 0
            if sequence <= confirmed { try db.execute(sql: "DELETE FROM v2_read_receipt_intents WHERE room_id=?", arguments:[room.rawValue]); return true }
            let id = UUID(), command = try V2RecordReadReceiptCommand(roomID: room, actorUserID: accountID, operationID: .init(uuid: id), readThroughRoomSequence: sequence)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(command)
            // Transfer the existing count/byte reservation inside this transaction.
            try db.execute(sql:"DELETE FROM v2_read_receipt_intents WHERE room_id=?",arguments:[room.rawValue])
            try Self.insertOperationWork(.init(id:id,intentID:id,identity:command.identity,fingerprint:command.fingerprint,
                orderingKey:"readReceipt:" + room.rawValue,payloadBytes:Int64(bytes.count),admissionDeadline:nil), now:now,limits:limits,db:db)
            try db.execute(sql: "INSERT INTO v2_read_receipt_operations(work_id,room_id,requested_sequence,command) VALUES(?,?,?,?)",arguments:[id.uuidString,room.rawValue,Int64(sequence),bytes])
            try db.execute(sql:"DELETE FROM v2_read_receipt_intents WHERE room_id=?",arguments:[room.rawValue])
            return true
        }
    }
    func readReceiptRecoveryNeedingAttention(roomID: RoomID) throws -> UUID? {
        try databasePool.read { db in
            try String.fetchOne(db,sql:"""
                SELECT w.work_id FROM v2_read_receipt_operations r JOIN v2_operation_work w ON w.work_id=r.work_id
                WHERE r.room_id=? AND w.scheduling_state='needsAttention'
                ORDER BY CASE WHEN w.admission_class='readReceiptControl' THEN 0 ELSE 1 END,w.local_sequence LIMIT 1
                """,arguments:[roomID.rawValue]).flatMap(UUID.init(uuidString:))
        }
    }
    func readReceiptCommand(workID: UUID) throws -> V2RecordReadReceiptCommand {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db,sql:"SELECT command,room_id,requested_sequence FROM v2_read_receipt_operations WHERE work_id=?",arguments:[workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let command = try JSONDecoder().decode(V2RecordReadReceiptCommand.self,from:row["command"])
            guard command.roomID.rawValue == row["room_id"] as String,
                command.readThroughRoomSequence == (try Self.storageUnsigned(row,column:"requested_sequence")) else { throw V2OperationWorkError.identityConflict }
            return command
        }
    }
    func completeReadReceiptWork(_ command: V2RecordReadReceiptCommand, result: V2ReadReceiptRecoveryResult, now: Date = Date()) throws {
        let receipt: V2ReadReceipt, state: V2OperationExecutionState
        switch result {
        case .originalReceipt(let value): guard value.validates(command) else { throw V2OperationWorkError.identityConflict }; receipt=value.receipt; state = .committed
        case .watermarkProof(let value): guard value.validates(command) else { throw V2OperationWorkError.identityConflict }; receipt=value.watermark; state = .committed
        default: throw V2OperationWorkError.invalidTransition
        }
        let outcome = try V2VerifiedOperationOutcome(identity:command.identity,fingerprint:command.fingerprint,state:state,
            receipt: V2ReadReceiptLocalOutcome(command:command,result:result))
        try databasePool.write { db in
            if let old = try Row.fetchOne(db,sql:"SELECT read_through_room_sequence AS value FROM v2_room_read_watermarks WHERE room_id=?",arguments:[command.roomID.rawValue]) {
                _ = try Self.storageUnsigned(old,column:"value")
            }
            try Self.completeOperationWork(outcome,now:now,db:db)
            do {
                try db.execute(sql:"""
                    INSERT INTO v2_room_read_watermarks(room_id,read_through_room_sequence,recorded_at) VALUES(?,?,?)
                    ON CONFLICT(room_id) DO UPDATE SET read_through_room_sequence=MAX(read_through_room_sequence,excluded.read_through_room_sequence),
                        recorded_at=CASE WHEN excluded.read_through_room_sequence>read_through_room_sequence THEN excluded.recorded_at ELSE recorded_at END
                    """,arguments:[command.roomID.rawValue,Int64(receipt.readThroughRoomSequence),receipt.recordedAt.timeIntervalSince1970])
            }
        }
    }
    public nonisolated func readReceiptWorkUpdates(roomID: RoomID) -> AsyncThrowingStream<V2ReadReceiptTrackingSnapshot, any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        let work = try Row.fetchOne(db,sql:"""
                            SELECT w.* FROM v2_read_receipt_operations r JOIN v2_operation_work w ON w.work_id=r.work_id
                            WHERE r.room_id=? AND w.scheduling_state<>'finished'
                            ORDER BY CASE WHEN w.admission_class='readReceiptControl' AND w.scheduling_state='needsAttention' THEN 0 ELSE 1 END,w.local_sequence LIMIT 1
                            """,arguments:[roomID.rawValue]).map(Self.decodeOperationWork)
                        return try V2ReadReceiptTrackingSnapshot(work: work, archives: Self.readReceiptArchives(roomID: roomID, db: db))
                    }.removeDuplicates()
                    for try await value in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
    public nonisolated func readReceiptPreparationUpdates() -> AsyncThrowingStream<Void, any Error> {
        let pool=databasePool
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let task=Task {
                do {
                    let observation=ValueObservation.tracking { db in try String.fetchOne(db,sql:"""
                        SELECT (SELECT room_id FROM (\(Self.nextReadReceiptIntentQuery))) || ':' || SUM(n) || ':' || SUM(b) FROM (
                            SELECT COUNT(*) n,COALESCE(SUM(payload_bytes),0) b FROM v2_operation_work WHERE scheduling_state<>'finished'
                            UNION ALL SELECT COUNT(*),COALESCE(SUM(w.payload_bytes),0)
                                FROM v2_operation_work w JOIN v2_message_send_operations m USING(work_id)
                                WHERE w.execution_state='committed' AND w.admission_class='ordinary'
                                    AND m.accepted_projection_observed=0
                            UNION ALL SELECT COUNT(*),COALESCE(SUM(length(payload)),0) FROM v2_profile_intents WHERE work_id IS NULL AND local_terminal IS NULL
                            UNION ALL SELECT COUNT(*),COALESCE(SUM(length(payload)),0) FROM v2_personal_preference_intents WHERE work_id IS NULL AND local_terminal IS NULL
                            UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_read_receipt_intents
                            UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_send_intents WHERE stage='preparing'
                            UNION ALL SELECT COUNT(*),COALESCE(SUM(payload_bytes),0) FROM v2_message_reaction_intents WHERE work_id IS NULL AND local_terminal IS NULL
                        )
                        """) }.removeDuplicates()
                    for try await _ in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) { continuation.yield(()) }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={ _ in task.cancel() }
        }
    }
}
private struct V2ReadReceiptLocalOutcome: Codable, Sendable {
    let command: V2RecordReadReceiptCommand
    let result: V2ReadReceiptRecoveryResult
}
