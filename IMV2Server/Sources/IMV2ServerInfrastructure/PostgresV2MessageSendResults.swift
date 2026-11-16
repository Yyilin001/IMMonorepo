import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Accepted sends and permanent rejections compete for the same primary key.
/// Callers own the transaction and must confirm its commit before returning a receipt.
enum PostgresV2MessageSendResults {
    struct Key {
        let identity: V2OperationIdentity
        let room: UUID
        let actor: UUID
        let operation: UUID

        init(_ identity: V2OperationIdentity) throws {
            guard identity.kind == .sendMessage, case .room(let room) = identity.scope,
                  let roomID = room.uuidValue, let actor = identity.accountID.uuidValue,
                  let operation = UUID(uuidString: identity.operation.rawOperationID) else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            self.identity = identity
            self.room = roomID
            self.actor = actor
            self.operation = operation
        }
    }

    static func read(key: Key, fingerprint: V2OperationFingerprint,
                     domain: V2SendMessageFingerprint, sql: any SQLDatabase) async throws -> V2MessageSendOperationRecoveryResult? {
        guard let row = try await sql.raw("""
            SELECT message_id, room_sequence, request_fingerprint AS domain_fingerprint,
                   fingerprint_version, operation_fingerprint, operation_resolved_at_ms, rejection_code
            FROM im_v2.message_send_completions
            WHERE room_id=\(bind: key.room) AND sender_user_id=\(bind: key.actor)
              AND client_message_id=\(bind: key.operation)
            """).first(decoding: V2SendResultRow.self) else { return nil }
        return try row.result(identity: key.identity, fingerprint: fingerprint, domain: domain)
    }

    static func reject(key: Key, fingerprint: V2OperationFingerprint,
                       domain: V2SendMessageFingerprint, reason: V2MessageSendOperationRejection,
                       now: Date, sql: any SQLDatabase) async throws -> V2MessageSendOperationRecoveryResult {
        let milliseconds = try v2PositiveMilliseconds(now, invalid: V2MessageOperationValidationError.invalidReceipt)
        try await sql.raw("""
            INSERT INTO im_v2.message_send_completions
                (room_id, sender_user_id, client_message_id, fingerprint_version, request_fingerprint,
                 created_at, operation_fingerprint, operation_resolved_at_ms, rejection_code)
            VALUES (\(bind: key.room), \(bind: key.actor), \(bind: key.operation), \(bind: Int16(domain.version)),
                    \(bind: domain.digest), \(bind: now), \(bind: fingerprint.digest), \(bind: Int64(milliseconds)), \(bind: reason.rawValue))
            ON CONFLICT (room_id, sender_user_id, client_message_id) DO NOTHING
            """).run()
        // A competing acceptance may have held the unique key until its COMMIT.
        // Read in a fresh READ COMMITTED statement, not the INSERT's old snapshot.
        guard let result = try await read(key: key, fingerprint: fingerprint, domain: domain, sql: sql) else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        return result
    }
}
