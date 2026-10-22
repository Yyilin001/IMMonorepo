import Foundation
import GRDB
import IMV2Core

/// A local send waiting for a real, server-assigned room. Never used as a room ID.
public struct V2LocalDirectMessage: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let workID: UUID
    public let text: String
    public let createdAt: Date
}

extension GRDBV2LocalSyncStore {
    static let localDirectMessagesSchemaSQL = """
    CREATE TABLE v2_local_direct_messages (
      intent_id TEXT PRIMARY KEY,
      work_id TEXT NOT NULL REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
      text TEXT NOT NULL CHECK(length(text)>0 AND length(CAST(text AS BLOB))<=65536),
      created_at REAL NOT NULL
    );
    CREATE INDEX v2_local_direct_messages_work ON v2_local_direct_messages(work_id,created_at,intent_id);
    """

    func saveLocalDirectMessage(workID: UUID, accountID: UserID, text: String, now: Date) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 65_536 else { throw V2OperationWorkError.invalidRecord }
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT w.* FROM v2_operation_work w JOIN v2_direct_room_operations s USING(work_id) WHERE w.work_id=?", arguments: [workID.uuidString]),
                  try Self.decodeOperationWork(row).identity.accountID == accountID,
                  try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else {
                throw V2OperationWorkError.accountMismatch
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_local_direct_messages")! < 500 else { throw V2ResourceJournalError.capacityExceeded }
            try db.execute(sql: "INSERT INTO v2_local_direct_messages(intent_id,work_id,text,created_at) VALUES(?,?,?,?)",
                arguments: [UUID().uuidString, workID.uuidString, text, now.timeIntervalSince1970])
        }
    }

    func localDirectMessages(workID: UUID? = nil) throws -> [V2LocalDirectMessage] {
        try databasePool.read { db in
            try Self.readLocalDirectMessages(workID: workID, db: db)
        }
    }

    private static func readLocalDirectMessages(workID: UUID?, db: Database) throws -> [V2LocalDirectMessage] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM v2_local_direct_messages" + (workID == nil ? "" : " WHERE work_id=?") + " ORDER BY created_at,intent_id",
            arguments: workID.map { StatementArguments([$0.uuidString]) } ?? StatementArguments())
        return try rows.map { row in
            guard let id = UUID(uuidString: row["intent_id"]), let work = UUID(uuidString: row["work_id"]) else { throw V2OperationWorkError.invalidRecord }
            return .init(id: id, workID: work, text: row["text"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
        }
    }

    func removeLocalDirectMessage(id: UUID) throws {
        try databasePool.write { db in try db.execute(sql: "DELETE FROM v2_local_direct_messages WHERE intent_id=?", arguments: [id.uuidString]) }
    }

    nonisolated func localDirectMessageUpdates() -> AsyncThrowingStream<[V2LocalDirectMessage], any Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in
                        // Observe room completions as well as local composer writes.
                        _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_operation_work WHERE execution_state='committed'")
                        return try Self.readLocalDirectMessages(workID: nil, db: db)
                    }
                    for try await messages in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                        try Task.checkCancellation()
                        continuation.yield(messages)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension V2DirectRoomOperationService {
    public func existingLocalRoom(with userID: UserID) async throws -> RoomID? {
        let rooms = try await store.databasePool.read { db in
            try String.fetchAll(db, sql: """
                SELECT room_id FROM v2_direct_room_identities WHERE target_user_id=?
                UNION SELECT room_id FROM v2_direct_room_profile_projections WHERE target_user_id=?
                """, arguments: [userID.rawValue, userID.rawValue]).map(RoomID.init)
        }
        for room in rooms where try await store.roomAllowsLocalRead(roomID: room) { return room }
        return nil
    }
    public func enqueueLocalMessage(text: String, workID: UUID) async throws {
        try await store.saveLocalDirectMessage(workID: workID, accountID: accountID, text: text, now: Date())
    }
    public func localMessages(workID: UUID) async throws -> [V2LocalDirectMessage] {
        let command = try await store.directRoomCommand(workID: workID)
        guard command.actorUserID == accountID else { throw V2OperationWorkError.accountMismatch }
        return try await store.localDirectMessages(workID: workID)
    }
    public func messageUpdates() async -> AsyncThrowingStream<[V2LocalDirectMessage], any Error> { store.localDirectMessageUpdates() }

    /// Crash-safe handoff: the send intent keeps the local message UUID. A crash
    /// between freezing and deletion repeats the same intent, never a new send.
    public func prepareLocalMessages() async throws {
        for message in try await store.localDirectMessages() {
            try Task.checkCancellation()
            guard let receipt = try await receipt(id: message.workID), case .opened(let room, _) = receipt.outcome else { continue }
            let intent = try V2SendIntent(id: message.id, roomID: room, clientMessageID: .init(message.id.uuidString), text: message.text, attachmentJobIDs: [])
            try await store.freezeSendIntent(intent, originalCreatedAt: message.createdAt)
            try await store.removeLocalDirectMessage(id: message.id)
        }
    }
    public func runLocalMessagePreparation() async throws {
        for try await _ in store.localDirectMessageUpdates() {
            try Task.checkCancellation()
            try await prepareLocalMessages()
        }
    }
}
