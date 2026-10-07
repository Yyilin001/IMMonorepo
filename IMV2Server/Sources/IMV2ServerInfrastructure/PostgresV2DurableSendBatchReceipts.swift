import Foundation
import IMV2Core
import IMV2ServerContracts
import SQLKit

/// Caller holds all legacy message-operation locks before consulting these
/// sets. This layer does not acquire connections, release locks, or grant room
/// authority; the owner kernel retains full activation and room fences.
struct V2DurableSendBatchReceiptInput: Sendable {
    let command: V2MessageSendOperationCommand
    let attempt: V2DirectAuthorizationAttempt?
    var key: String { get throws { try DurableReceiptKey(command: command).key } }
}

struct V2DurableSendBatchPermanentReceipt: Sendable {
    let receipt: V2MessageSendOperationReceipt
    let domainFingerprint: V2SendMessageFingerprint
}

enum V2DurableSendBatchAttemptCheck: Sendable {
    case ready
    case terminal(V2DirectAuthorizationReceipt)
    case identityConflict
}

struct V2DurableSendBatchCompletion: Sendable {
    let disposition: V2DirectAuthorizationDisposition
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
    let closedKeys: Set<String>
    let checks: [String: V2DurableSendBatchAttemptCheck]
}

struct PostgresV2DurableSendBatchReceipts: Sendable {
    /// One READ COMMITTED statement after all operation locks have settled.
    /// Independent typed branches preserve duplicate/corruption detection.
    func snapshot(_ inputs: [V2DurableSendBatchReceiptInput], sql: any SQLDatabase) async throws -> V2DurableSendBatchReceiptSnapshot {
        try await readSnapshot(inputs, includeOwners: false, sql: sql).snapshot
    }

    private func readSnapshot(_ inputs: [V2DurableSendBatchReceiptInput], includeOwners: Bool,
        sql: any SQLDatabase
    ) async throws -> (snapshot: V2DurableSendBatchReceiptSnapshot, owners: [DurableProofOwnerRow]) {
        guard !inputs.isEmpty else { return (.init(existing: [:], completions: [:], closedKeys: [], checks: [:]), []) }
        let read = try snapshotRead(inputs, includeOwners: includeOwners)
        V2RoomSQLContinuationObservation.current?.willDispatch()
        return try read.decode(try await sql.raw(read.query).all())
    }

    func snapshotRead(_ inputs: [V2DurableSendBatchReceiptInput], includeOwners: Bool) throws -> V2DurableSendBatchSnapshotRead {
        let keys = try uniqueKeys(inputs)
        // Proof finishing originally validates attempts before consulting facts.
        // Initial preflight validates them only after envelopes/domain/closures.
        let proofAttempts: [DurableAttemptInput]
        if includeOwners { proofAttempts = try attemptKeys(inputs) }
        else { proofAttempts = [] }
        guard !keys.isEmpty else {
            return .init(query: "SELECT NULL::text AS kind WHERE false", decode: { _ in (.init(existing: [:], completions: [:], closedKeys: [], checks: [:]), []) })
        }
        // Read-only lookup is always scoped by the command's full key. The
        // optional generation is typed JSON data, not authority or SQL text.
        let input = try json(keys.map {
            DurableSnapshotInput(key: $0, generation: inputs[$0.sourceOrdinal].attempt?.generation)
        })
        let attemptQuery: SQLQueryString = inputs.contains(where: { $0.attempt != nil }) ? """
            UNION ALL
            SELECT 'attempt' AS kind,
                   input.ordinal AS ordinal,
                   NULL::text AS receipt,
                   NULL::bytea AS domain_fingerprint,
                   result.disposition AS disposition,
                   result.event_id AS event_id,
                   NULL::uuid AS message_id,
                   NULL::bigint AS room_sequence,
                   result.request_fingerprint AS request_fingerprint,
                   NULL::smallint AS fingerprint_version,
                   NULL::uuid AS recipient_id,
                   result.generation AS generation,
                   result.recipient_user_id AS recipient_user_id,
                   result.owner_shard_id AS owner_shard_id,
                   result.owner_epoch AS owner_epoch,
                   NULL::text AS room_shard_id,
                   NULL::text AS room_kind,
                   NULL::uuid AS lower_user_id,
                   NULL::uuid AS higher_user_id,
                   NULL::bytea AS operation_fingerprint,
                   NULL::bigint AS operation_resolved_at_ms, NULL::timestamptz AS created_at
            FROM input
            LEFT JOIN LATERAL (
              WITH exact AS MATERIALIZED (
                SELECT * FROM im_v2.direct_authorization_receipts
                WHERE room_id=input.room_id AND sender_user_id=input.sender_id
                  AND client_message_id=input.operation_id AND generation=input.generation
              ), prior AS (
                SELECT * FROM im_v2.direct_authorization_receipts
                WHERE room_id=input.room_id AND sender_user_id=input.sender_id
                  AND client_message_id=input.operation_id AND NOT EXISTS (SELECT 1 FROM exact)
                ORDER BY generation DESC LIMIT 1
              ) SELECT * FROM exact UNION ALL SELECT * FROM prior
            ) result ON true
            WHERE input.generation IS NOT NULL
            """ : ""
        let ownerQuery: SQLQueryString = includeOwners ? """
            UNION ALL
            SELECT 'owner' AS kind,
                   input.ordinal AS ordinal,
                   NULL::text AS receipt,
                   NULL::bytea AS domain_fingerprint,
                   NULL::text AS disposition,
                   NULL::uuid AS event_id,
                   NULL::uuid AS message_id,
                   NULL::bigint AS room_sequence,
                   NULL::bytea AS request_fingerprint,
                   NULL::smallint AS fingerprint_version,
                   NULL::uuid AS recipient_id,
                   NULL::bigint AS generation,
                   NULL::uuid AS recipient_user_id,
                   NULL::text AS owner_shard_id,
                   room.owner_epoch AS owner_epoch,
                   room.room_shard_id AS room_shard_id,
                   room.room_kind AS room_kind,
                   pair.lower_user_id AS lower_user_id,
                   pair.higher_user_id AS higher_user_id,
                   NULL::bytea AS operation_fingerprint,
                   NULL::bigint AS operation_resolved_at_ms, NULL::timestamptz AS created_at
            FROM input
            LEFT JOIN im_v2.rooms room ON room.room_id=input.room_id
            LEFT JOIN im_v2.direct_room_pairs pair ON pair.room_id=input.room_id
            WHERE \(bind: includeOwners) AND input.generation IS NOT NULL
            """ : ""
        let query: SQLQueryString = """
            /* imv2_durable_receipt_snapshot */
            WITH input AS MATERIALIZED (
              SELECT * FROM jsonb_to_recordset(\(bind: input)::jsonb)
                AS input(ordinal integer, room_id uuid, sender_id uuid, operation_id uuid, generation bigint)
              LIMIT \(literal: keys.count)
            )
            SELECT 'envelope' AS kind,
                   input.ordinal AS ordinal,
                   NULL::text AS receipt,
                   result.request_fingerprint AS domain_fingerprint,
                   NULL::text AS disposition,
                   NULL::uuid AS event_id,
                   result.message_id AS message_id,
                   result.room_sequence AS room_sequence,
                   NULL::bytea AS request_fingerprint,
                   result.fingerprint_version AS fingerprint_version,
                   NULL::uuid AS recipient_id,
                   NULL::bigint AS generation,
                   NULL::uuid AS recipient_user_id,
                   NULL::text AS owner_shard_id,
                   NULL::bigint AS owner_epoch,
                   NULL::text AS room_shard_id,
                   NULL::text AS room_kind,
                   NULL::uuid AS lower_user_id,
                   NULL::uuid AS higher_user_id,
                   result.operation_fingerprint AS operation_fingerprint,
                   result.operation_resolved_at_ms AS operation_resolved_at_ms, result.created_at AS created_at
            FROM input JOIN im_v2.message_send_completions result
              ON result.room_id=input.room_id AND result.sender_user_id=input.sender_id
             AND result.client_message_id=input.operation_id
            WHERE \(bind: !includeOwners)
            UNION ALL
            SELECT 'completion' AS kind,
                   input.ordinal AS ordinal,
                   NULL::text AS receipt,
                   NULL::bytea AS domain_fingerprint,
                   'accepted' AS disposition,
                   result.event_id AS event_id,
                   result.message_id AS message_id,
                   result.room_sequence AS room_sequence,
                   result.request_fingerprint AS request_fingerprint,
                   result.fingerprint_version AS fingerprint_version,
                   result.direct_recipient_user_id AS recipient_id,
                   NULL::bigint AS generation,
                   NULL::uuid AS recipient_user_id,
                   NULL::text AS owner_shard_id,
                   NULL::bigint AS owner_epoch,
                   NULL::text AS room_shard_id,
                   NULL::text AS room_kind,
                   NULL::uuid AS lower_user_id,
                   NULL::uuid AS higher_user_id,
                   NULL::bytea AS operation_fingerprint,
                   NULL::bigint AS operation_resolved_at_ms, NULL::timestamptz AS created_at
            FROM input JOIN im_v2.message_send_completions result ON result.room_id=input.room_id AND result.sender_user_id=input.sender_id
             AND result.client_message_id=input.operation_id
            UNION ALL
            SELECT 'completion' AS kind,
                   input.ordinal AS ordinal,
                   NULL::text AS receipt,
                   NULL::bytea AS domain_fingerprint,
                   'denied' AS disposition,
                   result.source_event_id AS event_id,
                   NULL::uuid AS message_id,
                   NULL::bigint AS room_sequence,
                   result.request_fingerprint AS request_fingerprint,
                   result.fingerprint_version AS fingerprint_version,
                   NULL::uuid AS recipient_id,
                   NULL::bigint AS generation,
                   NULL::uuid AS recipient_user_id,
                   NULL::text AS owner_shard_id,
                   NULL::bigint AS owner_epoch,
                   NULL::text AS room_shard_id,
                   NULL::text AS room_kind,
                   NULL::uuid AS lower_user_id,
                   NULL::uuid AS higher_user_id,
                   NULL::bytea AS operation_fingerprint,
                   NULL::bigint AS operation_resolved_at_ms, NULL::timestamptz AS created_at
            FROM input JOIN im_v2.direct_message_denials result ON result.room_id=input.room_id AND result.sender_user_id=input.sender_id
             AND result.client_message_id=input.operation_id
            UNION ALL
            SELECT 'closure' AS kind,
                   input.ordinal AS ordinal,
                   NULL::text AS receipt,
                   NULL::bytea AS domain_fingerprint,
                   NULL::text AS disposition,
                   NULL::uuid AS event_id,
                   NULL::uuid AS message_id,
                   NULL::bigint AS room_sequence,
                   NULL::bytea AS request_fingerprint,
                   NULL::smallint AS fingerprint_version,
                   NULL::uuid AS recipient_id,
                   NULL::bigint AS generation,
                   NULL::uuid AS recipient_user_id,
                   NULL::text AS owner_shard_id,
                   NULL::bigint AS owner_epoch,
                   NULL::text AS room_shard_id,
                   NULL::text AS room_kind,
                   NULL::uuid AS lower_user_id,
                   NULL::uuid AS higher_user_id,
                   NULL::bytea AS operation_fingerprint,
                   NULL::bigint AS operation_resolved_at_ms, NULL::timestamptz AS created_at
            FROM input JOIN im_v2.message_operation_closures result ON result.room_id=input.room_id AND result.sender_user_id=input.sender_id
             AND result.client_message_id=input.operation_id
            WHERE \(bind: !includeOwners)
            \(attemptQuery)
            \(ownerQuery)
            """
        return .init(query: query, decode: { rows in
            // Partition raw rows only. Typed/semantic failures are evaluated in
            // the same phase order as the previous independent reads.
            var byKind: [String: [any SQLRow]] = [:]
            for row in rows {
                let kind = try row.decode(column: "kind", as: String.self)
                switch kind {
                case "envelope", "closure":
                    guard !includeOwners else { throw V2MessageOperationValidationError.invalidReceipt }
                case "owner":
                    guard includeOwners else { throw V2DirectAuthorizationReceiptError.ownerChanged }
                case "completion", "attempt": break
                default: throw V2MessageOperationValidationError.invalidReceipt
                }
                byKind[kind, default: []].append(row)
            }
            if includeOwners {
                let attemptByKey = Dictionary(uniqueKeysWithValues: proofAttempts.map { ($0.key, $0) })
                let attemptRows = try snapshotAttempts(byKind["attempt"] ?? [], keys: keys, attemptByKey: attemptByKey)
                let checks = try decodeAttempts(attemptRows, attempts: proofAttempts, inputs: inputs)
                let domainRows = try (byKind["completion"] ?? []).map { try $0.decode(model: DurableCompletionRow.self) }
                let domain = try decodeCompletions(domainRows, keys: keys)
                let owners = try snapshotOwners(byKind["owner"] ?? [], keys: keys, attemptByKey: attemptByKey)
                return (.init(existing: [:], completions: domain, closedKeys: [], checks: checks), owners)
            }
            let envelopeRows = try (byKind["envelope"] ?? []).map { try $0.decode(model: DurableEnvelopeRow.self) }
            let existing = try decodeExisting(envelopeRows, keys: keys, inputs: inputs)
            let domainRows = try (byKind["completion"] ?? []).map { try $0.decode(model: DurableCompletionRow.self) }
            let domain = try decodeCompletions(domainRows, keys: keys)
            let closureRows = try (byKind["closure"] ?? []).map { try $0.decode(model: DurableClosedKeyRow.self) }
            let closures = try decodeClosedKeys(closureRows, keys: keys)
            let attempts = try attemptKeys(inputs)
            let attemptByKey = Dictionary(uniqueKeysWithValues: attempts.map { ($0.key, $0) })
            let attemptRows = try snapshotAttempts(byKind["attempt"] ?? [], keys: keys, attemptByKey: attemptByKey)
            let checks = try decodeAttempts(attemptRows, attempts: attempts, inputs: inputs)
            return (.init(existing: existing, completions: domain, closedKeys: closures, checks: checks), [])
        })
    }

    func existing(_ inputs: [V2DurableSendBatchReceiptInput], sql: any SQLDatabase) async throws -> [String: V2MessageSendOperationRecoveryResult] {
        guard !inputs.isEmpty else { return [:] }
        let keys = try uniqueKeys(inputs)
        let input = try json(keys)
        let rows = try await sql.raw("""
            SELECT input.ordinal, receipt.message_id, receipt.room_sequence,
                   receipt.request_fingerprint AS domain_fingerprint, receipt.fingerprint_version,
                   receipt.operation_fingerprint, receipt.operation_resolved_at_ms, receipt.created_at
            FROM jsonb_to_recordset(\(bind: input)::jsonb)
              AS input(ordinal integer, room_id uuid, sender_id uuid, operation_id uuid)
            JOIN im_v2.message_send_completions receipt
              ON receipt.room_id=input.room_id AND receipt.sender_user_id=input.sender_id
             AND receipt.client_message_id=input.operation_id
            """).all(decoding: DurableEnvelopeRow.self)
        return try decodeExisting(rows, keys: keys, inputs: inputs)
    }

    /// Caller keeps room/pair locks and the fresh-clock full-token fence from
    /// preflight through this statement. Only actual immutable domain facts
    /// produce proofs, never the supplied callback result.
    func prepareProofs(_ inputs: [V2DurableSendBatchReceiptInput], now: Date, sql: any SQLDatabase) async throws -> ValidatedProofWrites {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DirectAuthorizationReceiptError.invalidAttempt }
        let attempts = try attemptKeys(inputs)
        guard !attempts.isEmpty else { return try validatedProofWrites(inputs, proofs: [], receipts: [:], now: now) }
        // Domain writes have already settled; this new statement sees those
        // actual facts and reads attempts/completions/owners coherently.
        let facts = try await readSnapshot(inputs, includeOwners: true, sql: sql)
        let checks = facts.snapshot.checks, completions = facts.snapshot.completions
        let owners = facts.owners
        guard owners.count == attempts.count else { throw V2DirectAuthorizationReceiptError.ownerChanged }
        var ownerByOrdinal: [Int: DurableProofOwnerRow] = [:]
        for owner in owners {
            guard attempts.indices.contains(owner.ordinal), ownerByOrdinal.updateValue(owner, forKey: owner.ordinal) == nil else {
                throw V2DirectAuthorizationReceiptError.ownerChanged
            }
        }
        var proofs: [DurableProofInsert] = [], result: [String: V2DirectAuthorizationReceipt] = [:]
        for indexed in attempts {
            guard let attempt = inputs[indexed.sourceOrdinal].attempt, let check = checks[indexed.key] else {
                throw V2DirectAuthorizationReceiptError.invalidAttempt
            }
            switch check {
            case .identityConflict: throw V2DirectAuthorizationReceiptError.identityConflict
            case .terminal(let receipt):
                guard receipt.disposition != .aborted else { throw V2DirectAuthorizationReceiptError.attemptAborted }
                result[indexed.key] = receipt
                continue
            case .ready: break
            }
            guard let owner = ownerByOrdinal[indexed.ordinal], owner.shardID == attempt.ownerShardID,
                  owner.epoch == attempt.ownerEpoch, owner.kind == "direct" else { throw V2DirectAuthorizationReceiptError.ownerChanged }
            guard let lower = owner.lower, let higher = owner.higher,
                  Set([lower, higher]) == Set([attempt.senderID, attempt.recipientID]) else {
                throw V2DirectAuthorizationReceiptError.identityConflict
            }
            guard let completion = completions[indexed.key] else { continue }
            guard completion.fingerprintVersion == 3, completion.fingerprint == attempt.fingerprint,
                  completion.disposition == .denied || completion.recipientID == attempt.recipientID else {
                throw V2DirectAuthorizationReceiptError.identityConflict
            }
            let receipt = V2DirectAuthorizationReceipt(disposition: completion.disposition, eventID: completion.eventID)
            proofs.append(.init(index: indexed, attempt: attempt, receipt: receipt))
            result[indexed.key] = receipt
        }
        return try validatedProofWrites(inputs, proofs: proofs, receipts: result, now: now)
    }

    struct ValidatedProofWrites: Sendable {
        fileprivate let payload: String
        fileprivate let count: Int
        fileprivate let fingerprints: [String: Data]
        fileprivate let requiredProofKeys: Set<String>
        fileprivate let recordedAt: Date
        fileprivate let receipts: [String: V2DirectAuthorizationReceipt]
        fileprivate init(payload: String, count: Int, fingerprints: [String: Data], requiredProofKeys: Set<String>, recordedAt: Date,
                         receipts: [String: V2DirectAuthorizationReceipt]) {
            self.payload = payload; self.count = count; self.fingerprints = fingerprints
            self.requiredProofKeys = requiredProofKeys
            self.recordedAt = recordedAt; self.receipts = receipts
        }
    }

    private func validatedProofWrites(_ inputs: [V2DurableSendBatchReceiptInput], proofs: [DurableProofInsert],
        receipts: [String: V2DirectAuthorizationReceipt], now: Date
    ) throws -> ValidatedProofWrites {
        let keys = try uniqueKeys(inputs)
        return .init(payload: try json(proofs), count: proofs.count,
            fingerprints: Dictionary(uniqueKeysWithValues: keys.map {
                ($0.key, inputs[$0.sourceOrdinal].command.command.fingerprint.digest)
            }), requiredProofKeys: Set(try attemptKeys(inputs).map { $0.key }), recordedAt: now, receipts: receipts)
    }

    // Scalar/negative callers retain their original independent strict insert.
    func finishProofs(_ inputs: [V2DurableSendBatchReceiptInput], now: Date, sql: any SQLDatabase) async throws -> [String: V2DirectAuthorizationReceipt] {
        let prepared = try await prepareProofs(inputs, now: now, sql: sql)
        if prepared.count > 0 {
            try await sql.raw("""
                INSERT INTO im_v2.direct_authorization_receipts
                  (room_id,sender_user_id,client_message_id,generation,recipient_user_id,
                   owner_shard_id,owner_epoch,request_fingerprint,disposition,event_id,recorded_at)
                SELECT room_id,sender_id,operation_id,generation,recipient_id,owner_shard_id,owner_epoch,
                       decode(fingerprint,'base64'),disposition,event_id,\(bind: now)
                FROM jsonb_to_recordset(\(bind: prepared.payload)::jsonb)
                  AS input(room_id uuid,sender_id uuid,operation_id uuid,generation bigint,recipient_id uuid,
                           owner_shard_id text,owner_epoch bigint,fingerprint text,disposition text,event_id uuid)
                """).run()
        }
        return prepared.receipts
    }

    /// Accepted-cohort only. The witness is constructed after reading actual
    /// domain facts and complete attempt/owner validation in this transaction.
    /// Any write/count/decode failure escapes to the enclosing rollback; never
    /// retry the separate inserts after this statement has been dispatched.
    func persistAccepted(_ receipts: [V2DurableSendBatchPermanentReceipt], proofs: ValidatedProofWrites,
        sql: any SQLDatabase) async throws {
        let rows = try receipts.map(DurableEnvelopeInsert.init)
        guard Set(rows.map(\.key)).count == rows.count,
              Set(rows.map(\.key)) == Set(proofs.fingerprints.keys),
              rows.allSatisfy({ !$0.closes && proofs.fingerprints[$0.key] == $0.domainFingerprint }),
              Set(proofs.receipts.keys) == proofs.requiredProofKeys,
              proofs.receipts.values.allSatisfy({ $0.disposition == .accepted }) else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        // Success metadata already lives in the original completion INSERT.
        // Only legacy authorization proof obligations need another write.
        if proofs.count > 0 {
            try await sql.raw("""
                INSERT INTO im_v2.direct_authorization_receipts
                  (room_id,sender_user_id,client_message_id,generation,recipient_user_id,
                   owner_shard_id,owner_epoch,request_fingerprint,disposition,event_id,recorded_at)
                SELECT room_id,sender_id,operation_id,generation,recipient_id,owner_shard_id,owner_epoch,
                       decode(fingerprint,'base64'),disposition,event_id,\(bind: proofs.recordedAt)
                FROM jsonb_to_recordset(\(bind: proofs.payload)::jsonb)
                  AS input(room_id uuid,sender_id uuid,operation_id uuid,generation bigint,recipient_id uuid,
                           owner_shard_id text,owner_epoch bigint,fingerprint text,disposition text,event_id uuid)
                """).run()
        }
    }

    /// Validates the generated ACK against the same reduced messages. No
    /// envelope is serialized or written: completion_insert is the result.
    func validateAcknowledgments(_ receipts: [V2DurableSendBatchPermanentReceipt],
        messages: [PlainRoomLogMessageInput]) throws {
        let rows = try receipts.map(DurableEnvelopeInsert.init)
        guard rows.count == messages.count, Set(rows.map(\.key)).count == rows.count else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        for message in messages {
            let key = [message.roomID, message.senderID, message.clientMessageID].map { $0.uuidString.lowercased() }.joined(separator: ":")
            guard let row = byKey[key], !row.closes, row.domainFingerprint == message.fingerprint.digest,
                  case .accepted(let result) = row.receipt.outcome,
                  result.messageID.uuidValue == message.messageID,
                  result.roomSequence == UInt64(exactly: message.roomSequence) else {
                throw V2MessageOperationValidationError.invalidReceipt
            }
        }
    }

    private func snapshotAttempts(_ rows: [any SQLRow], keys: [DurableReceiptKey],
        attemptByKey: [String: DurableAttemptInput]
    ) throws -> [DurableAttemptRow] {
        try rows.map { row in
            let value = try row.decode(model: DurableAttemptRow.self)
            guard keys.indices.contains(value.ordinal), let indexed = attemptByKey[keys[value.ordinal].key] else {
                throw V2DirectAuthorizationReceiptError.invalidAttempt
            }
            return .init(ordinal: indexed.ordinal, generation: value.generation, recipientID: value.recipientID,
                ownerShardID: value.ownerShardID, ownerEpoch: value.ownerEpoch, fingerprint: value.fingerprint,
                disposition: value.disposition, eventID: value.eventID)
        }
    }

    private func snapshotOwners(_ rows: [any SQLRow], keys: [DurableReceiptKey],
        attemptByKey: [String: DurableAttemptInput]
    ) throws -> [DurableProofOwnerRow] {
        try rows.map { row in
            let value = try row.decode(model: DurableProofOwnerRow.self)
            guard keys.indices.contains(value.ordinal), let indexed = attemptByKey[keys[value.ordinal].key] else {
                throw V2DirectAuthorizationReceiptError.ownerChanged
            }
            return .init(ordinal: indexed.ordinal, shardID: value.shardID, epoch: value.epoch,
                kind: value.kind, lower: value.lower, higher: value.higher)
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

    private func decodeClosedKeys(_ rows: [DurableClosedKeyRow], keys: [DurableReceiptKey]) throws -> Set<String> {
        var result = Set<String>()
        for row in rows {
            guard keys.indices.contains(row.ordinal), result.insert(keys[row.ordinal].key).inserted else {
                throw V2MessageOperationValidationError.invalidReceipt
            }
        }
        return result
    }

    private func decodeCompletions(_ rows: [DurableCompletionRow], keys: [DurableReceiptKey]) throws -> [String: V2DurableSendBatchCompletion] {
        var result: [String: V2DurableSendBatchCompletion] = [:]
        for row in rows {
            guard keys.indices.contains(row.ordinal) else { throw V2MessageOperationValidationError.invalidReceipt }
            let key = keys[row.ordinal].key
            guard result[key] == nil else { throw V2DirectAuthorizationReceiptError.identityConflict }
            result[key] = .init(disposition: row.disposition, eventID: row.eventID, messageID: row.messageID,
                roomSequence: row.roomSequence, fingerprint: row.fingerprint,
                fingerprintVersion: row.fingerprintVersion, recipientID: row.recipientID)
        }
        return result
    }

    private func decodeAttempts(_ rows: [DurableAttemptRow], attempts: [DurableAttemptInput], inputs: [V2DurableSendBatchReceiptInput]) throws -> [String: V2DurableSendBatchAttemptCheck] {
        guard rows.count == attempts.count else { throw V2DirectAuthorizationReceiptError.invalidAttempt }
        var result: [String: V2DurableSendBatchAttemptCheck] = [:]
        for row in rows {
            guard attempts.indices.contains(row.ordinal), let attempt = inputs[attempts[row.ordinal].sourceOrdinal].attempt else {
                throw V2DirectAuthorizationReceiptError.invalidAttempt
            }
            let key = attempts[row.ordinal].key
            guard result[key] == nil else { throw V2DirectAuthorizationReceiptError.invalidAttempt }
            guard let generation = row.generation else { result[key] = .ready; continue }
            if generation == attempt.generation {
                guard row.recipientID == attempt.recipientID, row.ownerShardID == attempt.ownerShardID,
                      row.ownerEpoch == attempt.ownerEpoch, row.fingerprint == attempt.fingerprint,
                      let disposition = row.disposition else { result[key] = .identityConflict; continue }
                result[key] = .terminal(.init(disposition: disposition, eventID: row.eventID))
            } else {
                result[key] = generation < attempt.generation && row.recipientID == attempt.recipientID
                    && row.fingerprint == attempt.fingerprint ? .ready : .identityConflict
            }
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
    private func attemptKeys(_ inputs: [V2DurableSendBatchReceiptInput]) throws -> [DurableAttemptInput] {
        var result: [DurableAttemptInput] = []
        for key in try uniqueKeys(inputs) {
            if let attempt = inputs[key.sourceOrdinal].attempt {
                try attempt.validate()
                guard attempt.roomID == key.roomID, attempt.senderID == key.senderID, attempt.clientMessageID == key.operationID,
                      attempt.fingerprint == inputs[key.sourceOrdinal].command.command.fingerprint.digest else {
                    throw V2DirectAuthorizationReceiptError.identityConflict
                }
                result.append(.init(ordinal: result.count, sourceOrdinal: key.sourceOrdinal, key: key.key, roomID: key.roomID,
                    senderID: key.senderID, operationID: key.operationID, generation: attempt.generation))
            }
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
private struct DurableSnapshotInput: Encodable {
    let ordinal: Int
    let roomID: UUID, senderID: UUID, operationID: UUID
    let generation: Int64?
    init(key: DurableReceiptKey, generation: Int64?) {
        ordinal = key.ordinal; roomID = key.roomID; senderID = key.senderID
        operationID = key.operationID; self.generation = generation
    }
    enum CodingKeys: String, CodingKey { case ordinal, roomID="room_id", senderID="sender_id", operationID="operation_id", generation }
}
private struct DurableAttemptInput: Encodable {
    let ordinal: Int, sourceOrdinal: Int
    let key: String
    let roomID: UUID, senderID: UUID, operationID: UUID
    let generation: Int64
    enum CodingKeys: String, CodingKey { case ordinal,roomID="room_id",senderID="sender_id",operationID="operation_id",generation }
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
    let ordinal: Int, disposition: V2DirectAuthorizationDisposition, eventID: UUID, messageID: UUID?, roomSequence: Int64?
    let fingerprint: Data, fingerprintVersion: Int16, recipientID: UUID?
    enum CodingKeys: String,CodingKey { case ordinal,disposition,eventID="event_id",messageID="message_id",roomSequence="room_sequence",fingerprint="request_fingerprint",fingerprintVersion="fingerprint_version",recipientID="recipient_id" }
}
private struct DurableAttemptRow: Decodable {
    let ordinal: Int, generation: Int64?, recipientID: UUID?, ownerShardID: String?, ownerEpoch: Int64?
    let fingerprint: Data?, disposition: V2DirectAuthorizationDisposition?, eventID: UUID?
    enum CodingKeys: String,CodingKey { case ordinal,generation,recipientID="recipient_user_id",ownerShardID="owner_shard_id",ownerEpoch="owner_epoch",fingerprint="request_fingerprint",disposition,eventID="event_id" }
}
struct DurableProofOwnerRow: Decodable, Sendable {
    let ordinal: Int, shardID: String?, epoch: Int64?, kind: String?, lower: UUID?, higher: UUID?
    enum CodingKeys: String,CodingKey { case ordinal,shardID="room_shard_id",epoch="owner_epoch",kind="room_kind",lower="lower_user_id",higher="higher_user_id" }
}
private struct DurableProofInsert: Encodable {
    let roomID: UUID, senderID: UUID, operationID: UUID, generation: Int64, recipientID: UUID
    let ownerShardID: String, ownerEpoch: Int64, fingerprint: Data, disposition: String, eventID: UUID?
    init(index: DurableAttemptInput, attempt: V2DirectAuthorizationAttempt, receipt: V2DirectAuthorizationReceipt) {
        roomID=index.roomID;senderID=index.senderID;operationID=index.operationID;generation=attempt.generation
        recipientID=attempt.recipientID;ownerShardID=attempt.ownerShardID;ownerEpoch=attempt.ownerEpoch
        fingerprint=attempt.fingerprint;disposition=receipt.disposition.rawValue;eventID=receipt.eventID
    }
    enum CodingKeys: String,CodingKey { case roomID="room_id",senderID="sender_id",operationID="operation_id",generation,recipientID="recipient_id",ownerShardID="owner_shard_id",ownerEpoch="owner_epoch",fingerprint,disposition,eventID="event_id" }
}
private struct DurableEnvelopeInsert {
    let roomID: UUID, senderID: UUID, operationID: UUID, fingerprint: Data, domainFingerprint: Data
    let receipt: V2MessageSendOperationReceipt, resolvedAtMilliseconds: UInt64, closes: Bool
    var key: String { [roomID,senderID,operationID].map { $0.uuidString.lowercased() }.joined(separator: ":") }
    init(_ value: V2DurableSendBatchPermanentReceipt) throws {
        guard case .room(let room) = value.receipt.identity.scope, value.receipt.identity.kind == .sendMessage,
              let roomID=room.uuidValue, let sender=value.receipt.identity.accountID.uuidValue,
              let operation=UUID(uuidString:value.receipt.identity.operation.rawOperationID), value.domainFingerprint.version == 3 else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        self.roomID=roomID;senderID=sender;operationID=operation;fingerprint=value.receipt.fingerprint.digest
        domainFingerprint=value.domainFingerprint.digest;receipt=value.receipt;resolvedAtMilliseconds=receipt.resolvedAtMilliseconds
        if case .accepted = receipt.outcome { closes=false } else { closes=true }
    }
    enum CodingKeys: String,CodingKey { case roomID="room_id",senderID="sender_id",operationID="operation_id",fingerprint,domainFingerprint="domain_fingerprint",receipt,resolvedAtMilliseconds="resolved_at_ms",closes }
}

private struct DurableClosedKeyRow: Decodable { let ordinal: Int }

struct V2DurableSendBatchSnapshotRead: Sendable {
    let query: SQLQueryString
    let decode: @Sendable ([any SQLRow]) throws -> (snapshot: V2DurableSendBatchReceiptSnapshot, owners: [DurableProofOwnerRow])
}
