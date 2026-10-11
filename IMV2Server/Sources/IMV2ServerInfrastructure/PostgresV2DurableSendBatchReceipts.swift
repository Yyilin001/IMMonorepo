import Foundation
import IMV2Core
import IMV2ServerContracts
import SQLKit

/// Caller holds the room execution boundary before consulting these
/// sets. This layer does not acquire connections, release locks, or grant room
/// authority; the owner kernel retains full activation and room fences.
struct V2DurableSendBatchReceiptInput: Sendable {
    let command: V2MessageSendOperationCommand
    var key: String { get throws { try DurableReceiptKey(command: command).key } }
}

struct V2DurableSendBatchPermanentReceipt: Sendable {
    let receipt: V2MessageSendOperationReceipt
    let domainFingerprint: V2SendMessageFingerprint
}

struct V2DurableSendBatchCompletion: Sendable {
    let eventID: UUID
    let messageID: UUID?
    let roomSequence: Int64?
    let fingerprint: Data
    let fingerprintVersion: Int16
    let recipientID: UUID?
}

struct V2DurableSendBatchReceiptSnapshot: Sendable {
    let existing: [String: V2MessageSendOperationRecoveryResult]
    let completions: [String: V2DurableSendBatchCompletion]
}

struct PostgresV2DurableSendBatchReceipts: Sendable {
    /// Success and domain completion facts share one READ COMMITTED statement.
    func snapshot(_ inputs: [V2DurableSendBatchReceiptInput], sql: any SQLDatabase) async throws -> V2DurableSendBatchReceiptSnapshot {
        let read = try snapshotRead(inputs)
        V2RoomSQLContinuationObservation.current?.willDispatch()
        return try read.decode(try await sql.raw(read.query).all())
    }

    func snapshotRead(_ inputs: [V2DurableSendBatchReceiptInput]) throws -> V2DurableSendBatchSnapshotRead {
        let keys = try uniqueKeys(inputs)
        guard !keys.isEmpty else {
            return .init(query: "SELECT NULL::text AS kind WHERE false", decode: { _ in .init(existing: [:], completions: [:]) })
        }
        let input = try json(keys)
        let query: SQLQueryString = """
            /* imv2_durable_receipt_snapshot */
            WITH input AS MATERIALIZED (
              SELECT * FROM jsonb_to_recordset(\(bind: input)::jsonb)
                AS input(ordinal integer, room_id uuid, sender_id uuid, operation_id uuid)
              LIMIT \(literal: keys.count)
            )
            SELECT 'envelope' AS kind,
                   input.ordinal AS ordinal,
                   result.request_fingerprint AS domain_fingerprint,
                   NULL::uuid AS event_id,
                   result.message_id AS message_id,
                   result.room_sequence AS room_sequence,
                   NULL::bytea AS request_fingerprint,
                   result.fingerprint_version AS fingerprint_version,
                   NULL::uuid AS recipient_id,
                   result.operation_fingerprint AS operation_fingerprint,
                   result.operation_resolved_at_ms AS operation_resolved_at_ms
            FROM input JOIN im_v2.message_send_completions result
              ON result.room_id=input.room_id AND result.sender_user_id=input.sender_id
             AND result.client_message_id=input.operation_id
            UNION ALL
            SELECT 'completion' AS kind,
                   input.ordinal AS ordinal,
                   NULL::bytea AS domain_fingerprint,
                   result.event_id AS event_id,
                   result.message_id AS message_id,
                   result.room_sequence AS room_sequence,
                   result.request_fingerprint AS request_fingerprint,
                   result.fingerprint_version AS fingerprint_version,
                   result.direct_recipient_user_id AS recipient_id,
                   NULL::bytea AS operation_fingerprint,
                   NULL::bigint AS operation_resolved_at_ms
            FROM input JOIN im_v2.message_send_completions result ON result.room_id=input.room_id AND result.sender_user_id=input.sender_id
             AND result.client_message_id=input.operation_id
            """
        return .init(query: query, decode: { rows in
            var envelopes: [DurableEnvelopeRow] = [], completions: [DurableCompletionRow] = []
            for row in rows {
                switch try row.decode(column: "kind", as: String.self) {
                case "envelope": envelopes.append(try row.decode(model: DurableEnvelopeRow.self))
                case "completion": completions.append(try row.decode(model: DurableCompletionRow.self))
                default: throw V2MessageOperationValidationError.invalidReceipt
                }
            }
            return .init(existing: try decodeExisting(envelopes, keys: keys, inputs: inputs),
                completions: try decodeCompletions(completions, keys: keys))
        })
    }

    func existing(_ inputs: [V2DurableSendBatchReceiptInput], sql: any SQLDatabase) async throws -> [String: V2MessageSendOperationRecoveryResult] {
        guard !inputs.isEmpty else { return [:] }
        let keys = try uniqueKeys(inputs)
        let input = try json(keys)
        let rows = try await sql.raw("""
            SELECT input.ordinal, receipt.message_id, receipt.room_sequence,
                   receipt.request_fingerprint AS domain_fingerprint, receipt.fingerprint_version,
                   receipt.operation_fingerprint, receipt.operation_resolved_at_ms
            FROM jsonb_to_recordset(\(bind: input)::jsonb)
              AS input(ordinal integer, room_id uuid, sender_id uuid, operation_id uuid)
            JOIN im_v2.message_send_completions receipt
              ON receipt.room_id=input.room_id AND receipt.sender_user_id=input.sender_id
             AND receipt.client_message_id=input.operation_id
            """).all(decoding: DurableEnvelopeRow.self)
        return try decodeExisting(rows, keys: keys, inputs: inputs)
    }

    /// Validates the generated ACK against the same reduced messages. No
    /// envelope is serialized or written: completion_insert is the result.
    func validateAcknowledgments(_ receipts: [V2DurableSendBatchPermanentReceipt],
        messages: [PlainRoomLogMessageInput]) throws {
        let rows = try receipts.map(DurableAcceptedReceipt.init)
        guard rows.count == messages.count, Set(rows.map(\.key)).count == rows.count else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        for message in messages {
            let key = [message.roomID, message.senderID, message.clientMessageID].map { $0.uuidString.lowercased() }.joined(separator: ":")
            guard let row = byKey[key], row.domainFingerprint == message.fingerprint.digest,
                  case .accepted(let result) = row.receipt.outcome,
                  result.messageID.uuidValue == message.messageID,
                  result.roomSequence == UInt64(exactly: message.roomSequence) else {
                throw V2MessageOperationValidationError.invalidReceipt
            }
        }
    }

    private func decodeExisting(_ rows: [DurableEnvelopeRow], keys: [DurableReceiptKey], inputs: [V2DurableSendBatchReceiptInput]) throws -> [String: V2MessageSendOperationRecoveryResult] {
        var result: [String: V2MessageSendOperationRecoveryResult] = [:]
        for row in rows {
            guard keys.indices.contains(row.ordinal) else { throw V2MessageOperationValidationError.invalidReceipt }
            let key = keys[row.ordinal], command = inputs[key.sourceOrdinal].command
            guard result[key.key] == nil else { throw V2MessageOperationValidationError.invalidReceipt }
            result[key.key] = try row.receipt.result(identity: command.identity,
                fingerprint: command.fingerprint, domain: command.command.fingerprint)
        }
        return result
    }

    private func decodeCompletions(_ rows: [DurableCompletionRow], keys: [DurableReceiptKey]) throws -> [String: V2DurableSendBatchCompletion] {
        var result: [String: V2DurableSendBatchCompletion] = [:]
        for row in rows {
            guard keys.indices.contains(row.ordinal) else { throw V2MessageOperationValidationError.invalidReceipt }
            let key = keys[row.ordinal].key
            guard result[key] == nil else { throw V2MessageOperationValidationError.invalidReceipt }
            result[key] = .init(eventID: row.eventID, messageID: row.messageID,
                roomSequence: row.roomSequence, fingerprint: row.fingerprint,
                fingerprintVersion: row.fingerprintVersion, recipientID: row.recipientID)
        }
        return result
    }

    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func uniqueKeys(_ inputs: [V2DurableSendBatchReceiptInput]) throws -> [DurableReceiptKey] {
        guard inputs.count <= 256 else { throw V2MessageOperationValidationError.invalidReceipt }
        var seen = Set<String>(), result: [DurableReceiptKey] = []
        for (index, input) in inputs.enumerated() {
            var key = try DurableReceiptKey(command: input.command)
            if seen.insert(key.key).inserted { key.ordinal = result.count; key.sourceOrdinal = index; result.append(key) }
        }
        return result
    }
}

private struct DurableReceiptKey: Encodable {
    var ordinal = 0
    var sourceOrdinal = 0
    let roomID: UUID, senderID: UUID, operationID: UUID
    var key: String { [roomID,senderID,operationID].map { $0.uuidString.lowercased() }.joined(separator: ":") }
    init(command: V2MessageSendOperationCommand) throws {
        guard let room = command.command.roomID.uuidValue, let sender = command.command.senderUserID.uuidValue,
              let operation = command.command.clientMessageID.uuidValue else { throw V2MessageOperationValidationError.invalidReceipt }
        roomID=room; senderID=sender; operationID=operation
    }
    enum CodingKeys: String, CodingKey { case ordinal,roomID="room_id",senderID="sender_id",operationID="operation_id" }
}
private struct DurableEnvelopeRow: Decodable {
    let ordinal: Int
    let receipt: V2SendSuccessRow
    enum CodingKeys: String, CodingKey { case ordinal }
    init(from decoder: any Decoder) throws {
        ordinal = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .ordinal)
        receipt = try V2SendSuccessRow(from: decoder)
    }
}
private struct DurableCompletionRow: Decodable {
    let ordinal: Int, eventID: UUID, messageID: UUID?, roomSequence: Int64?
    let fingerprint: Data, fingerprintVersion: Int16, recipientID: UUID?
    enum CodingKeys: String,CodingKey { case ordinal,eventID="event_id",messageID="message_id",roomSequence="room_sequence",fingerprint="request_fingerprint",fingerprintVersion="fingerprint_version",recipientID="recipient_id" }
}
private struct DurableAcceptedReceipt {
    let roomID: UUID, senderID: UUID, operationID: UUID, domainFingerprint: Data
    let receipt: V2MessageSendOperationReceipt
    var key: String { [roomID,senderID,operationID].map { $0.uuidString.lowercased() }.joined(separator: ":") }
    init(_ value: V2DurableSendBatchPermanentReceipt) throws {
        guard case .room(let room) = value.receipt.identity.scope, value.receipt.identity.kind == .sendMessage,
              let roomID=room.uuidValue, let sender=value.receipt.identity.accountID.uuidValue,
              let operation=UUID(uuidString:value.receipt.identity.operation.rawOperationID),
              value.domainFingerprint.version == 3, case .accepted = value.receipt.outcome else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        self.roomID=roomID;senderID=sender;operationID=operation
        domainFingerprint=value.domainFingerprint.digest;receipt=value.receipt
    }
}


struct V2DurableSendBatchSnapshotRead: Sendable {
    let query: SQLQueryString
    let decode: @Sendable ([any SQLRow]) throws -> V2DurableSendBatchReceiptSnapshot
}
