import Foundation
import IMV2Core

/// Execution-local metadata is appended to the original immutable completion
/// INSERT. It is not a second result write and carries no authorization.
enum V2SendSuccessMetadata {
    /// Immutable command material, prepared before a connection is borrowed.
    struct Prepared: Sendable {
        let room: UUID, sender: UUID, operation: UUID
        let fingerprint: Data
        let fingerprintHex: String
        init(_ command: V2MessageSendOperationCommand) throws {
            guard let room = command.command.roomID.uuidValue,
                  let sender = command.command.senderUserID.uuidValue,
                  let operation = command.command.clientMessageID.uuidValue else {
                throw V2MessageOperationValidationError.invalidReceipt
            }
            self.room = room; self.sender = sender; self.operation = operation
            fingerprint = try command.fingerprint.digest
            fingerprintHex = fingerprint.map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Entry: Sendable {
        let room: UUID, sender: UUID, operation: UUID
        let fingerprint: Data
        let fingerprintHex: String
        let resolvedAt: UInt64
        init(_ command: V2MessageSendOperationCommand, now: Date) throws {
            try self.init(Prepared(command), now: now)
        }
        init(_ prepared: Prepared, now: Date) throws {
            room = prepared.room; sender = prepared.sender; operation = prepared.operation
            fingerprint = prepared.fingerprint; fingerprintHex = prepared.fingerprintHex
            let milliseconds = now.timeIntervalSince1970 * 1000
            guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int64.max) else {
                throw V2MessageOperationValidationError.invalidReceipt
            }
            resolvedAt = UInt64(milliseconds)
        }
    }
    @TaskLocal static var current: [Entry] = []
    static var cte: String {
        let values: String
        if current.isEmpty {
            values = "SELECT NULL::uuid,NULL::uuid,NULL::uuid,NULL::bytea,NULL::bigint WHERE false"
        } else {
            var seen = Set<String>()
            let entries = current.filter { seen.insert("\($0.room):\($0.sender):\($0.operation)").inserted }
            values = "VALUES " + entries.map { entry in
                let hex = entry.fingerprintHex
                return "('\(entry.room)'::uuid,'\(entry.sender)'::uuid,'\(entry.operation)'::uuid,decode('\(hex)','hex'),\(entry.resolvedAt)::bigint)"
            }.joined(separator: ",")
        }
        // UUIDs, fixed-length digests and validated integers only; never SQL
        // derived from client text. One indexed/hash join replaces per-row CASEs.
        return ", send_operation_metadata(room_id,sender_id,client_message_id,operation_fingerprint,operation_resolved_at_ms) AS (\(values))"
    }
    static let join = "LEFT JOIN send_operation_metadata metadata ON metadata.room_id=message.room_id AND metadata.sender_id=message.sender_user_id AND metadata.client_message_id=message.client_message_id"

}

enum V2SendOperationResponseError: Error { case directPolicyDenied }

/// Minimal durable success facts, decoded as columns without response JSON.
struct V2SendSuccessRow: Decodable, Sendable {
    let messageID: UUID
    let roomSequence: Int64
    let domainFingerprint: Data
    let fingerprintVersion: Int16
    let operationFingerprint: Data?
    let resolvedAt: Int64?
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", roomSequence = "room_sequence"
        case domainFingerprint = "domain_fingerprint", fingerprintVersion = "fingerprint_version"
        case operationFingerprint = "operation_fingerprint", resolvedAt = "operation_resolved_at_ms"
        case createdAt = "created_at"
    }
    static func decodeIfPresent(from decoder: any Decoder) throws -> Self? {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decodeIfPresent(UUID.self, forKey: .messageID) != nil else { return nil }
        return try Self(from: decoder)
    }
    func result(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
                domain: V2SendMessageFingerprint) throws -> V2MessageSendOperationRecoveryResult {
        guard fingerprintVersion == Int16(domain.version), domainFingerprint == domain.digest else {
            return .fingerprintConflict
        }
        guard (operationFingerprint == nil) == (resolvedAt == nil) else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        if let operationFingerprint {
            guard operationFingerprint == fingerprint.digest else { return .fingerprintConflict }
        }
        let milliseconds: Int64
        if let resolvedAt { milliseconds = resolvedAt }
        else {
            let value = createdAt.timeIntervalSince1970 * 1000
            guard value.isFinite, value > 0, value < Double(Int64.max) else {
                throw V2MessageOperationValidationError.invalidReceipt
            }
            milliseconds = Int64(value)
        }
        guard roomSequence > 0, milliseconds > 0 else { throw V2MessageOperationValidationError.invalidReceipt }
        return .receipt(try .init(identity: identity, fingerprint: fingerprint,
            outcome: .accepted(.init(messageID: .init(uuid: messageID), roomSequence: UInt64(roomSequence))),
            resolvedAtMilliseconds: UInt64(milliseconds)))
    }
}
