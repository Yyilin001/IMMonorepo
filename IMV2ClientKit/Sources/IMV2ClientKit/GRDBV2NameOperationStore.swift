import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let nameOperationSchemaSQL = """
        CREATE TABLE v2_name_operations (
            work_id TEXT PRIMARY KEY REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            ordering_key TEXT NOT NULL,
            command BLOB NOT NULL CHECK(length(command)<=65536),
            close_requested INTEGER NOT NULL DEFAULT 0 CHECK(close_requested IN (0,1))
        );
        CREATE INDEX v2_name_operations_order ON v2_name_operations(ordering_key);
        CREATE TABLE v2_name_confirmed (
            ordering_key TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision>=0),
            payload BLOB NOT NULL CHECK(length(payload)<=65536)
        );
        CREATE TABLE v2_contact_alias_invalidations (
            target_user_id TEXT PRIMARY KEY,
            revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0)
        );
        """
    public func enqueueNameOperation(accountID: UserID, target: V2NameTarget, name: String?, expectedRevision: V2ProfileRevision?, now: Date = Date()) throws -> UUID {
        let id = UUID()
        guard let window = V2CommandPolicy.registered(for: target.kind).firstSubmissionWindowMilliseconds else { throw V2OperationWorkError.invalidRecord }
        let deadline = now.addingTimeInterval(Double(V2ClientSubmissionWindow.milliseconds(maximum: window)) / 1000)
        let command = try V2FrozenNameOperation(accountID: accountID, target: target, name: name, revision: expectedRevision, id: id, deadline: deadline)
        let bytes = try JSONEncoder().encode(command)
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            try Self.insertOperationWork(.init(id: id, intentID: id, identity: command.identity, fingerprint: command.fingerprint,
                orderingKey: target.orderingKey, payloadBytes: Int64(bytes.count), admissionDeadline: deadline), now: now, db: db)
            try db.execute(sql: "INSERT INTO v2_name_operations(work_id,ordering_key,command) VALUES(?,?,?)", arguments: [id.uuidString, target.orderingKey, bytes])
        }
        return id
    }
    func nameCommand(workID: UUID) throws -> (V2FrozenNameOperation, Bool) {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT command,close_requested FROM v2_name_operations WHERE work_id=?", arguments: [workID.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            return (try JSONDecoder().decode(V2FrozenNameOperation.self, from: row["command"]), row["close_requested"])
        }
    }
    static func saveNameSnapshot(_ snapshot: V2NameSnapshot, db: Database) throws {
        let revision = snapshot.revision?.signedValue ?? 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        if let previous = try Row.fetchOne(db, sql: "SELECT revision,payload FROM v2_name_confirmed WHERE ordering_key=?", arguments: [snapshot.target.orderingKey]),
           previous["revision"] as Int64 == revision {
            guard try JSONDecoder().decode(V2NameSnapshot.self, from: previous["payload"]) == snapshot else { throw V2OperationWorkError.identityConflict }
        }
        try db.execute(sql: """
            INSERT INTO v2_name_confirmed(ordering_key,revision,payload) VALUES(?,?,?)
            ON CONFLICT(ordering_key) DO UPDATE SET revision=excluded.revision,payload=excluded.payload
            WHERE excluded.revision>v2_name_confirmed.revision
            """, arguments: [snapshot.target.orderingKey, revision, data])
    }
    func saveNameSnapshot(_ snapshot: V2NameSnapshot, accountID: UserID) throws {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            try Self.saveNameSnapshot(snapshot, db: db)
        }
    }
    public func nameSnapshot(target: V2NameTarget) throws -> V2NameSnapshot? {
        try databasePool.read { db in try Self.readNameSnapshot(target: target, db: db) }
    }
    private static func readNameSnapshot(target: V2NameTarget, db: Database) throws -> V2NameSnapshot? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM v2_name_confirmed WHERE ordering_key=?", arguments: [target.orderingKey]) else { return nil }
        let value = try JSONDecoder().decode(V2NameSnapshot.self, from: data)
        let floor: Int64
        switch target {
        case .contact(let user):
            floor = try Int64.fetchOne(db, sql: "SELECT revision FROM v2_contact_alias_invalidations WHERE target_user_id=?", arguments: [user.rawValue]) ?? 0
        case .group(let room):
            floor = try Int64.fetchOne(db, sql: """
                SELECT revision FROM v2_group_nickname_invalidations WHERE room_id=?
                    AND user_id=(SELECT user_id FROM v2_local_installation WHERE singleton=1)
                """, arguments: [room.rawValue]) ?? 0
        }
        return (value.revision?.signedValue ?? 0) >= floor ? value : nil
    }
    public nonisolated func nameSnapshotUpdates(target: V2NameTarget) -> AsyncThrowingStream<V2NameSnapshot?, any Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in try Self.readNameSnapshot(target: target, db: db) }.removeDuplicates()
                    for try await value in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func completeNameOperation(_ command: V2FrozenNameOperation, receipt: V2NameReceipt, now: Date = Date()) throws {
        try command.validate(receipt)
        let outcome = try V2VerifiedOperationOutcome(identity: receipt.identity, fingerprint: receipt.fingerprint, state: receipt.state, receipt: receipt)
        try databasePool.write { db in
            try Self.completeOperationWork(outcome, now: now, db: db)
            if let snapshot = receipt.snapshot { try Self.saveNameSnapshot(snapshot, db: db) }
        }
    }
    public func requestNameOperationClose(id: UUID, now: Date = Date()) throws {
        let (command, _) = try nameCommand(workID: id)
        guard let work = try operationWork(id: id), work.identity == command.identity else { throw V2OperationWorkError.invalidRecord }
        if work.execution.isTerminal { return }
        if !work.submissionStarted { try cancelUnsubmittedOperation(id: id, now: now); return }
        guard work.scheduling != .claimed else { throw V2OperationWorkError.invalidTransition }
        // Persist the decision before the wake. A crash cannot turn a close back into a submit.
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_name_operations SET close_requested=1 WHERE work_id=?", arguments: [id.uuidString])
        }
        try retryOperationWorkByUser(id: id, now: now)
    }
    private static func nameIntent(target: V2NameTarget, db: Database) throws -> V2NameIntentSnapshot? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT w.*,n.command FROM v2_name_operations n JOIN v2_operation_work w ON w.work_id=n.work_id
            WHERE n.ordering_key=? ORDER BY (w.scheduling_state='finished'),
                CASE WHEN w.scheduling_state<>'finished' THEN w.local_sequence END ASC,
                w.local_sequence DESC LIMIT 1
            """, arguments: [target.orderingKey]) else { return nil }
        let command = try JSONDecoder().decode(V2FrozenNameOperation.self, from: row["command"])
        let work = try decodeOperationWork(row)
        return .init(id: work.id, target: command.target, name: command.name, work: work)
    }
    public nonisolated func nameIntentUpdates(target: V2NameTarget) -> AsyncThrowingStream<V2NameIntentSnapshot?, any Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in try Self.nameIntent(target: target, db: db) }.removeDuplicates()
                    for try await value in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
