import Foundation
import GRDB
import IMV2Core

/// Local tracking history, never evidence that the server executed or rejected a read.
public struct V2ReadReceiptArchive: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let requestedSequence: UInt64
    public let archivedAt: Date
}

public struct V2ReadReceiptTrackingSnapshot: Equatable, Sendable {
    public let work: V2OperationWork?
    public let archives: [V2ReadReceiptArchive]
}

extension GRDBV2LocalSyncStore {
    /// Moves only a paused, submitted operation out of active admission. No network
    /// request is in flight under its claim; dependencies must not lose their parent.
    public func archiveReadReceiptWork(id: UUID, accountID: UserID, now: Date = Date()) throws {
        let timestamp = try Self.commandRetryTimestamp(now)
        try databasePool.write { db in
            let work = try Self.requireOperationWork(id, db: db)
            guard work.identity.accountID == accountID else { throw V2OperationWorkError.accountMismatch }
            let admissionClass = try String.fetchOne(db, sql: "SELECT admission_class FROM v2_operation_work WHERE work_id=?", arguments: [id.uuidString])
            let canArchive = work.lastErrorCode == "READ_RECEIPT_CURRENT_UNAVAILABLE" ||
                (work.lastErrorCode == "READ_RECEIPT_CONTROL_CAPACITY_REQUIRED" && admissionClass == "readReceiptControl")
            guard work.identity.kind == .readReceipt, work.scheduling == .needsAttention,
                  work.submissionStarted,
                  canArchive,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_operation_dependencies WHERE parent_work_id=? OR child_work_id=?)", arguments: [id.uuidString, id.uuidString]) == false
            else { throw V2OperationWorkError.invalidTransition }
            guard let row = try Row.fetchOne(db, sql: "SELECT command,room_id,requested_sequence FROM v2_read_receipt_operations WHERE work_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let bytes: Data = row["command"]
            let command = try JSONDecoder().decode(V2RecordReadReceiptCommand.self, from: bytes)
            guard try command.identity == work.identity, try command.fingerprint == work.fingerprint,
                  command.roomID.rawValue == row["room_id"] as String,
                  command.readThroughRoomSequence == (try Self.storageUnsigned(row, column: "requested_sequence"))
            else { throw V2OperationWorkError.identityConflict }
            // Separate bounded history budget: no unknown identity is evicted for space.
            guard bytes.count <= 4096,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_read_receipt_archives")! < 256,
                  try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(command)),0) FROM v2_read_receipt_archives")! + bytes.count <= 1_048_576
            else { throw V2OperationWorkError.capacityExceeded }
            try db.execute(sql: "INSERT INTO v2_read_receipt_archives(work_id,room_id,requested_sequence,command,archived_at) VALUES(?,?,?,?,?)", arguments: [id.uuidString, command.roomID.rawValue, Int64(command.readThroughRoomSequence), bytes, timestamp])
            try db.execute(sql: "DELETE FROM v2_read_receipt_operations WHERE work_id=?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM v2_operation_work WHERE work_id=?", arguments: [id.uuidString])
        }
    }

    static func readReceiptArchives(roomID: RoomID, db: Database) throws -> [V2ReadReceiptArchive] {
        try Row.fetchAll(db, sql: "SELECT work_id,requested_sequence,archived_at FROM v2_read_receipt_archives WHERE room_id=? ORDER BY archived_at,work_id LIMIT 256", arguments: [roomID.rawValue]).map { row in
            guard let id = UUID(uuidString: row["work_id"]) else { throw V2OperationWorkError.invalidRecord }
            return try .init(id: id, requestedSequence: Self.storageUnsigned(row, column: "requested_sequence"), archivedAt: Date(timeIntervalSince1970: row["archived_at"]))
        }
    }

    /// An unresolved original query may resume submission only after its exact
    /// same work acquires ordinary capacity. The transfer and claim release are
    /// one transaction, so neither pool can observe an uncharged runnable write.
    func resumeReadReceiptSubmissionFromControl(_ claim: V2OperationWorkClaim, until: Date) throws {
        let timestamp = try Self.commandRetryTimestamp(until)
        try databasePool.write { db in
            try Self.requireOperationClaim(claim, db: db)
            guard claim.action == .reconcile,
                  try String.fetchOne(db, sql: "SELECT admission_class FROM v2_operation_work WHERE work_id=?", arguments: [claim.work.id.uuidString]) == "readReceiptControl",
                  let row = try Row.fetchOne(db, sql: "SELECT command FROM v2_read_receipt_operations WHERE work_id=?", arguments: [claim.work.id.uuidString])
            else { throw V2OperationWorkError.invalidTransition }
            let bytes: Data = row["command"]
            let command = try JSONDecoder().decode(V2RecordReadReceiptCommand.self, from: bytes)
            guard bytes.count <= 4_096, try command.identity == claim.work.identity,
                  try command.fingerprint == claim.work.fingerprint else { throw V2OperationWorkError.identityConflict }
            var admitted = false
            do {
                try Self.requireOperationCapacity(adding: Int64(bytes.count), db: db)
                admitted = true
            } catch V2OperationWorkError.capacityExceeded {
                // Keep the existing control reservation and original identity.
            }
            try db.execute(sql: """
                UPDATE v2_operation_work SET admission_class=?,payload_bytes=?,ordering_key=?,
                    execution_state='awaitingConfirmation',scheduling_state=?,next_action_kind=?,next_action_at=?,
                    last_error_code=?,claim_id=NULL,claim_owner_id=NULL,claim_until=NULL,work_revision=work_revision+1
                WHERE work_id=?
                """, arguments: [admitted ? "ordinary" : "readReceiptControl",
                    admitted ? Int64(bytes.count) : Int64(bytes.count) + Self.readReceiptControlOverheadBytes,
                    admitted ? "readReceipt:" + command.roomID.rawValue : "readReceiptControl:" + command.roomID.rawValue + ":" + claim.work.id.uuidString,
                    admitted ? "backingOff" : "needsAttention", admitted ? "submit" : "reconcile", timestamp,
                    admitted ? "READ_RECEIPT_UNRESOLVED" : "READ_RECEIPT_CONTROL_CAPACITY_REQUIRED", claim.work.id.uuidString])
        }
    }

    func readReceiptUsesControlAdmission(workID: UUID) throws -> Bool {
        try databasePool.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT admission_class FROM v2_operation_work WHERE work_id=? AND operation_kind='readReceipt'", arguments: [workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            return value == "readReceiptControl"
        }
    }

    /// Explicit recovery restores exactly the archived command, starting with query.
    /// Admission failure rolls back and leaves the archive intact.
    public func restoreReadReceiptArchive(id: UUID, accountID: UserID, now: Date = Date()) throws {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT command,room_id,requested_sequence FROM v2_read_receipt_archives WHERE work_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            let bytes: Data = row["command"]
            let command = try JSONDecoder().decode(V2RecordReadReceiptCommand.self, from: bytes)
            guard command.actorUserID == accountID else { throw V2OperationWorkError.accountMismatch }
            let expected = try V2RecordReadReceiptCommand(roomID: command.roomID, actorUserID: accountID, operationID: .init(uuid: id), readThroughRoomSequence: command.readThroughRoomSequence)
            guard try command.identity == expected.identity, try command.fingerprint == expected.fingerprint,
                  command.roomID.rawValue == row["room_id"] as String,
                  command.readThroughRoomSequence == (try Self.storageUnsigned(row, column: "requested_sequence"))
            else { throw V2OperationWorkError.identityConflict }
            try Self.insertOperationWork(.init(id: id, intentID: id, identity: command.identity, fingerprint: command.fingerprint, orderingKey: "readReceiptControl:" + command.roomID.rawValue + ":" + id.uuidString, payloadBytes: Int64(bytes.count) + Self.readReceiptControlOverheadBytes, admissionDeadline: nil), now: now, readReceiptControlRecovery: true, db: db)
            try db.execute(sql: "INSERT INTO v2_read_receipt_operations(work_id,room_id,requested_sequence,command) VALUES(?,?,?,?)", arguments: [id.uuidString, command.roomID.rawValue, Int64(command.readThroughRoomSequence), bytes])
            try db.execute(sql: "UPDATE v2_operation_work SET execution_state='awaitingConfirmation',submission_started=1,next_action_kind='reconcile' WHERE work_id=?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM v2_read_receipt_archives WHERE work_id=?", arguments: [id.uuidString])
        }
    }
}
