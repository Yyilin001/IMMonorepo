import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import PostgresNIO
import SQLKit

/// 永久完成回执与永久关闭墓碑共享发送的操作锁。恢复不依赖仍可保留的消息正文。
public struct PostgresV2MessageOperationRecoveryStore: Sendable {
    private let database: any Database
    public init(database: any Database) { self.database = database }

    public func recover(_ request: V2MessageOperationRecoveryRequest, actorUserID: UserID,
                        token: V2RoomActivationToken) async throws -> V2MessageOperationRecoveryResult {
        guard request.roomID == token.roomID, let room = request.roomID.uuidValue,
              let actor = actorUserID.uuidValue, let operation = request.clientMessageID.uuidValue
        else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        return try await v2WithRoomScopedTransaction(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            // Existing send paths use operation -> room -> activation order.
            try await sql.raw("""
                SELECT pg_advisory_xact_lock(hashtextextended(
                    'v2-message-operation:' || \(bind: room)::text || ':' || \(bind: actor)::text || ':' || \(bind: operation)::text, 0))
                """).run()
            try await v2RequireRoomActivation(token: token, sql: sql)
            if let accepted = try await sql.raw("""
                SELECT fingerprint_version, request_fingerprint, message_id, room_sequence
                FROM im_v2.message_send_completions
                WHERE room_id = \(bind: room) AND sender_user_id = \(bind: actor) AND client_message_id = \(bind: operation)
                """).first(decoding: V2MessageRecoveryAcceptedRow.self) {
                guard accepted.fingerprintVersion == Int16(request.fingerprint.version),
                      accepted.fingerprint == request.fingerprint.digest else { return .fingerprintConflict }
                guard accepted.roomSequence > 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return .accepted(try .init(messageID: .init(uuid: accepted.messageID), roomSequence: UInt64(accepted.roomSequence)))
            }
            if let closed = try await sql.raw("""
                SELECT fingerprint_version, request_fingerprint FROM im_v2.message_operation_closures
                WHERE room_id = \(bind: room) AND sender_user_id = \(bind: actor) AND client_message_id = \(bind: operation)
                """).first(decoding: V2MessageRecoveryFingerprintRow.self) {
                return closed.matches(request.fingerprint) ? .closed : .fingerprintConflict
            }
            // A prior policy denial can be retained for less time than this tombstone. Do not treat it as permanent closure.
            if let denied = try await sql.raw("""
                SELECT fingerprint_version, request_fingerprint FROM im_v2.direct_message_denials
                WHERE room_id = \(bind: room) AND sender_user_id = \(bind: actor) AND client_message_id = \(bind: operation)
                """).first(decoding: V2MessageRecoveryFingerprintRow.self), !denied.matches(request.fingerprint) {
                return .fingerprintConflict
            }
            guard request.action == .closeIfAbsent else { return .unresolved }
            try await sql.raw("""
                INSERT INTO im_v2.message_operation_closures(room_id,sender_user_id,client_message_id,
                    fingerprint_version,request_fingerprint,closed_at)
                VALUES (\(bind: room),\(bind: actor),\(bind: operation),\(bind: Int16(request.fingerprint.version)),
                    \(bind: request.fingerprint.digest),clock_timestamp())
                """).run()
            return .closed
        }
    }
}

/// Only the named completion trigger means the operation is permanently closed; arbitrary SQL failures stay infrastructure errors.
func v2IsMessageOperationClosed(_ error: any Error) -> Bool {
    let state: String?, constraint: String?
    if let error = error as? PSQLError {
        state = error.serverInfo?[.sqlState]; constraint = error.serverInfo?[.constraintName]
    } else if let error = error as? PostgresError, case .server(let message) = error {
        state = message.fields[.sqlState]; constraint = message.fields[.constraintName]
    } else { return false }
    return state == "23514" && constraint == "message_operation_permanently_closed"
}

private struct V2MessageRecoveryAcceptedRow: Decodable {
    let fingerprintVersion: Int16; let fingerprint: Data; let messageID: UUID; let roomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case fingerprintVersion = "fingerprint_version", fingerprint = "request_fingerprint"
        case messageID = "message_id", roomSequence = "room_sequence"
    }
}
private struct V2MessageRecoveryFingerprintRow: Decodable {
    let fingerprintVersion: Int16; let fingerprint: Data
    enum CodingKeys: String, CodingKey { case fingerprintVersion = "fingerprint_version", fingerprint = "request_fingerprint" }
    func matches(_ value: V2SendMessageFingerprint) -> Bool { fingerprintVersion == Int16(value.version) && fingerprint == value.digest }
}
