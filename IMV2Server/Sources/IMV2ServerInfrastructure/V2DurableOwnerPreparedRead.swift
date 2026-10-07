import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import Foundation
import SQLKit

/// Final receipt lookup and room-local preflight share one READ COMMITTED
/// statement within the runtime-owned room write transaction.
/// Historical completions and closures remain visible to the receipt decoder.
struct V2DurableOwnerPreparedRead {
    let receipts: V2DurableSendBatchReceiptSnapshot
    let rooms: [Int: PlainDirectRoomLogBatchPreflightRow]

    static func load(inputs: [V2DurableSendBatchReceiptInput], ordered: [OrderedRoomWriteRequest],
        policies: [Int: V2DirectSendControlPolicy], insertFirst: Bool = false, sql: any SQLDatabase
    ) async throws -> Self {
        guard inputs.count == ordered.count, inputs.allSatisfy({ $0.attempt == nil }),
              Set(try inputs.map { try $0.key }).count == inputs.count else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        let read = try PostgresV2DurableSendBatchReceipts().snapshotRead(inputs, includeOwners: false)
        // Normal accepted sends insert first. PostgreSQL eliminates this
        // false branch; a uniqueness/closure collision rolls back the entire
        // write and uses the existing scalar recovery path.
        let receiptQuery: SQLQueryString = insertFirst
            ? "SELECT * FROM (\(read.query)) unused WHERE false" : read.query
        let prior: SQLQueryString = """
            SELECT map.preflight_ordinal AS ordinal FROM receipt_snapshot receipt
            JOIN receipt_ordinal_map map ON map.receipt_ordinal=receipt.ordinal
            WHERE receipt.kind IN ('envelope','completion','closure')
            """
        let preflight = try PlainDirectRoomLogPreflight.query(ordered, leasedPolicies: policies, priorOperation: prior, validatesDirectMemberships: !insertFirst, usesAcceptedRoomState: insertFirst)
        V2RoomSQLContinuationObservation.current?.willDispatch()
        let rows = try await sql.raw("""
            /* imv2_owner_combined_preflight */
            WITH receipt_ordinal_map AS MATERIALIZED (
                SELECT (ordinality-1)::integer AS receipt_ordinal, value AS preflight_ordinal
                FROM unnest(\(bind: ordered.map(\.preflightOrdinal))::integer[]) WITH ORDINALITY AS mapping(value,ordinality)
            ), receipt_snapshot AS MATERIALIZED (\(receiptQuery)),
                 room_preflight AS MATERIALIZED (\(preflight))
            SELECT r.*,
                p.ordinal AS preflight_ordinal,
                p.room_kind AS preflight_room_kind,
                p.room_shard_id AS preflight_room_shard_id,
                p.room_sequence AS preflight_room_sequence,
                p.timeline_sequence AS preflight_timeline_sequence,
                p.membership_revision AS preflight_membership_revision,
                p.capacity_profile_id AS preflight_capacity_profile_id,
                p.capacity_class AS preflight_capacity_class,
                p.frozen_at AS preflight_frozen_at,
                p.actor_role AS preflight_actor_role,
                p.sender_is_active AS preflight_sender_is_active,
                p.muted AS preflight_muted,
                p.recipient_user_id AS preflight_recipient_user_id,
                p.sender_profile_visible_to_recipient AS preflight_sender_profile_visible_to_recipient,
                p.direct_policy_revision AS preflight_direct_policy_revision,
                p.sender_policy_revision AS preflight_sender_policy_revision,
                p.recipient_policy_revision AS preflight_recipient_policy_revision,
                p.sender_can_send AS preflight_sender_can_send,
                p.recipient_is_active AS preflight_recipient_is_active,
                p.blocked AS preflight_blocked,
                p.is_friend AS preflight_is_friend,
                p.sender_has_replied AS preflight_sender_has_replied,
                p.recipient_has_replied AS preflight_recipient_has_replied,
                p.allows_strangers AS preflight_allows_strangers,
                p.sender_account_kind AS preflight_sender_account_kind,
                p.sender_account_status AS preflight_sender_account_status,
                p.sender_allows_service_messages AS preflight_sender_allows_service_messages,
                p.recipient_account_kind AS preflight_recipient_account_kind,
                p.recipient_account_status AS preflight_recipient_account_status,
                p.recipient_allows_customer_messages AS preflight_recipient_allows_customer_messages,
                p.valid_direct_memberships AS preflight_valid_direct_memberships
            FROM receipt_snapshot r FULL JOIN room_preflight p ON false
            """).all()
        var receiptRows: [any SQLRow] = [], rooms: [Int: PlainDirectRoomLogBatchPreflightRow] = [:]
        for row in rows {
            if try !row.decodeNil(column: "kind") { receiptRows.append(row) }
            if try !row.decodeNil(column: "preflight_ordinal") {
                guard try row.decode(column: "preflight_valid_direct_memberships", as: Bool.self) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let value = try PlainDirectRoomLogBatchPreflightRow(row: PrefixedSQLRow(row: row, prefix: "preflight_"))
                guard rooms.updateValue(value, forKey: value.ordinal) == nil else {
                    throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
                }
            }
        }
        return .init(receipts: try read.decode(receiptRows).snapshot, rooms: rooms)
    }
}

private struct PrefixedSQLRow: SQLRow {
    let row: any SQLRow
    let prefix: String
    var allColumns: [String] { row.allColumns.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
    func contains(column: String) -> Bool { row.contains(column: prefix + column) }
    func decodeNil(column: String) throws -> Bool { try row.decodeNil(column: prefix + column) }
    func decode<D: Decodable>(column: String, as: D.Type) throws -> D { try row.decode(column: prefix + column, as: D.self) }
}
