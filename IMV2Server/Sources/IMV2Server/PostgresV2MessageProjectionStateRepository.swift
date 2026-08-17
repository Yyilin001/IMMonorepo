import Foundation
import IMV2Core
import SQLKit

struct V2StoredMessageProjectionState: Equatable, Sendable {
    let stateID: UUID
    let messageID: UUID
    let roomID: UUID
    let messageRevision: Int64
    let variantKey: Int16
    let originEventID: UUID
    let stateEventID: UUID?
    let isWithdrawn: Bool
    let payloadSchemaVersion: Int16
    let payloadJSON: String
    let createdAt: Date

    init(
        stateID: UUID,
        messageID: UUID,
        roomID: UUID,
        messageRevision: Int64,
        variantKey: Int16,
        originEventID: UUID,
        stateEventID: UUID?,
        isWithdrawn: Bool,
        payloadSchemaVersion: Int16,
        payloadJSON: String,
        createdAt: Date
    ) {
        self.stateID = stateID
        self.messageID = messageID
        self.roomID = roomID
        self.messageRevision = messageRevision
        self.variantKey = variantKey
        self.originEventID = originEventID
        self.stateEventID = stateEventID
        self.isWithdrawn = isWithdrawn
        self.payloadSchemaVersion = payloadSchemaVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }

    init(
        state: V2MessageProjectionState,
        originEventID: UUID,
        stateEventID: UUID?,
        variantKey: Int16 = 0,
        createdAt: Date
    ) throws {
        guard let messageID = UUID(uuidString: state.messageID.rawValue),
              let roomID = UUID(uuidString: state.roomID.rawValue),
              state.messageRevision <= UInt64(Int64.max)
        else { throw V2MessageProjectionStatePersistenceError.corruptPersistence }
        let revision = Int64(state.messageRevision)
        self.stateID = try v2MessageProjectionStateID(
            messageID: messageID,
            messageRevision: revision,
            variantKey: variantKey
        )
        self.messageID = messageID
        self.roomID = roomID
        self.messageRevision = revision
        self.variantKey = variantKey
        self.originEventID = originEventID
        self.stateEventID = stateEventID
        self.isWithdrawn = state.isWithdrawn
        self.payloadSchemaVersion = V2MessageProjectionState.payloadSchemaVersion
        self.payloadJSON = try state.encodedPayloadJSON()
        self.createdAt = createdAt
    }

    var state: V2MessageProjectionState {
        get throws {
            let decoded = try V2MessageProjectionState(payloadJSON: payloadJSON)
            guard UUID(uuidString: decoded.messageID.rawValue) == messageID,
                  UUID(uuidString: decoded.roomID.rawValue) == roomID,
                  decoded.messageRevision == UInt64(messageRevision),
                  decoded.isWithdrawn == isWithdrawn,
                  payloadSchemaVersion == V2MessageProjectionState.payloadSchemaVersion,
                  try v2MessageProjectionStateID(
                    messageID: messageID,
                    messageRevision: messageRevision,
                    variantKey: variantKey
                  ) == stateID
            else { throw V2MessageProjectionStatePersistenceError.corruptPersistence }
            return decoded
        }
    }
}

/// SQL boundary for immutable message projection states. Every insert is an
/// idempotent create followed by an equality verification; a retry may reuse
/// an existing state, but can never overwrite conflicting canonical content.
struct PostgresV2MessageProjectionStateRepository: Sendable {
    let schema: String

    init(schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.schema = schema
    }

    func persist(
        _ value: V2StoredMessageProjectionState,
        sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table("message_projection_states"))
                (state_id, message_id, room_id, message_revision, variant_key,
                 origin_event_id, state_event_id, is_withdrawn,
                 payload_schema_version, payload, created_at)
            VALUES
                (\(bind: value.stateID), \(bind: value.messageID), \(bind: value.roomID),
                 \(bind: value.messageRevision), \(bind: value.variantKey),
                 \(bind: value.originEventID), \(bind: value.stateEventID),
                 \(bind: value.isWithdrawn), \(bind: value.payloadSchemaVersion),
                 \(bind: value.payloadJSON)::jsonb, \(bind: value.createdAt))
            ON CONFLICT DO NOTHING
            """).run()
        guard let verified = try await sql.raw("""
            SELECT 1 AS value
            FROM \(unsafeRaw: table("message_projection_states"))
            WHERE state_id = \(bind: value.stateID)
              AND message_id = \(bind: value.messageID)
              AND room_id = \(bind: value.roomID)
              AND message_revision = \(bind: value.messageRevision)
              AND variant_key = \(bind: value.variantKey)
              AND origin_event_id = \(bind: value.originEventID)
              AND state_event_id IS NOT DISTINCT FROM \(bind: value.stateEventID)
              AND is_withdrawn = \(bind: value.isWithdrawn)
              AND payload_schema_version = \(bind: value.payloadSchemaVersion)
              AND payload = \(bind: value.payloadJSON)::jsonb
            """).first(decoding: MessageProjectionStateExistsRow.self),
              verified.value == 1
        else { throw V2MessageProjectionStatePersistenceError.conflictingState }
    }

    func load(
        messageID: UUID,
        revision: Int64,
        variantKey: Int16 = 0,
        sql: any SQLDatabase
    ) async throws -> V2StoredMessageProjectionState? {
        guard revision > 0, variantKey >= 0 else {
            throw V2MessageProjectionStatePersistenceError.corruptPersistence
        }
        return try await sql.raw("""
            SELECT state_id, message_id, room_id, message_revision, variant_key,
                   origin_event_id, state_event_id, is_withdrawn,
                   payload_schema_version, payload::text AS payload_json, created_at
            FROM \(unsafeRaw: table("message_projection_states"))
            WHERE message_id = \(bind: messageID)
              AND message_revision = \(bind: revision)
              AND variant_key = \(bind: variantKey)
            """).first(decoding: MessageProjectionStateRow.self)?.value
    }

    func load(
        stateID: UUID,
        sql: any SQLDatabase
    ) async throws -> V2StoredMessageProjectionState? {
        try await sql.raw("""
            SELECT state_id, message_id, room_id, message_revision, variant_key,
                   origin_event_id, state_event_id, is_withdrawn,
                   payload_schema_version, payload::text AS payload_json, created_at
            FROM \(unsafeRaw: table("message_projection_states"))
            WHERE state_id = \(bind: stateID)
            """).first(decoding: MessageProjectionStateRow.self)?.value
    }

    /// Transitional self-healing path for a message mutation that arrives
    /// before the bounded historical backfill reaches this message. It reads
    /// only control-store authority and persists one immutable current state;
    /// normal post-migration writes always hit `load` above.
    func loadCurrentOrMaterialize(
        messageID: UUID,
        revision: Int64,
        sql: any SQLDatabase
    ) async throws -> V2StoredMessageProjectionState {
        if let existing = try await load(messageID: messageID, revision: revision, sql: sql) {
            _ = try existing.state
            return existing
        }
        guard let source = try await sql.raw("""
            SELECT message.text_body,
                   message.rich_entities::text AS entities_json,
                   message.withdrawn_at,
                   accepted.event_id AS origin_event_id,
                   accepted.payload::text AS accepted_payload_json,
                   accepted.created_at
            FROM \(unsafeRaw: table("messages")) AS message
            JOIN \(unsafeRaw: table("room_events")) AS accepted
              ON accepted.room_id = message.room_id
             AND accepted.room_sequence = message.room_sequence
             AND accepted.event_type = 'message.accepted'
            WHERE message.message_id = \(bind: messageID)
              AND message.content_revision = \(bind: revision)
            """).first(decoding: MessageProjectionStateMaterializationRow.self),
              source.withdrawnAt == nil,
              let entityData = source.entitiesJSON.data(using: .utf8)
        else { throw V2MessageProjectionStatePersistenceError.corruptPersistence }
        let entities: [V2MessageEntity]
        do {
            entities = try JSONDecoder().decode([V2MessageEntity].self, from: entityData)
        } catch {
            throw V2MessageProjectionStatePersistenceError.corruptPersistence
        }
        let accepted = try V2MessageProjectionState(payloadJSON: source.acceptedPayloadJSON)
        let restored: V2MessageProjectionState
        do {
            restored = try accepted.restoringActiveRevision(
                UInt64(revision),
                text: source.text,
                entities: entities
            )
        } catch {
            throw V2MessageProjectionStatePersistenceError.corruptPersistence
        }
        let value = try V2StoredMessageProjectionState(
            state: restored,
            originEventID: source.originEventID,
            stateEventID: revision == 1 ? source.originEventID : nil,
            createdAt: source.createdAt
        )
        try await persist(value, sql: sql)
        return value
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

enum V2MessageProjectionStatePersistenceError: Error, Equatable, Sendable {
    case conflictingState
    case corruptPersistence
}

private struct MessageProjectionStateExistsRow: Decodable { let value: Int }

private struct MessageProjectionStateRow: Decodable {
    let stateID: UUID
    let messageID: UUID
    let roomID: UUID
    let messageRevision: Int64
    let variantKey: Int16
    let originEventID: UUID
    let stateEventID: UUID?
    let isWithdrawn: Bool
    let payloadSchemaVersion: Int16
    let payloadJSON: String
    let createdAt: Date

    var value: V2StoredMessageProjectionState {
        .init(
            stateID: stateID,
            messageID: messageID,
            roomID: roomID,
            messageRevision: messageRevision,
            variantKey: variantKey,
            originEventID: originEventID,
            stateEventID: stateEventID,
            isWithdrawn: isWithdrawn,
            payloadSchemaVersion: payloadSchemaVersion,
            payloadJSON: payloadJSON,
            createdAt: createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case stateID = "state_id"
        case messageID = "message_id"
        case roomID = "room_id"
        case messageRevision = "message_revision"
        case variantKey = "variant_key"
        case originEventID = "origin_event_id"
        case stateEventID = "state_event_id"
        case isWithdrawn = "is_withdrawn"
        case payloadSchemaVersion = "payload_schema_version"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}

private struct MessageProjectionStateMaterializationRow: Decodable {
    let text: String
    let entitiesJSON: String
    let withdrawnAt: Date?
    let originEventID: UUID
    let acceptedPayloadJSON: String
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case text = "text_body"
        case entitiesJSON = "entities_json"
        case withdrawnAt = "withdrawn_at"
        case originEventID = "origin_event_id"
        case acceptedPayloadJSON = "accepted_payload_json"
        case createdAt = "created_at"
    }
}
