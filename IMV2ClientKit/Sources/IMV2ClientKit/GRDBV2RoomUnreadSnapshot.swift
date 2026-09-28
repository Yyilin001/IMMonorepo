import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// Reads authority and optimistic read receipts in one SQLite snapshot.
    /// Missing or locally revoked states stay absent, rather than becoming zero.
    public func roomUnreadSnapshot(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientConversationUnreadRow] {
        let identifiers = Array(Set(roomIDs.map(\.rawValue)))
        guard identifiers.count <= 1_000 else { throw V2RoomRecoveryPersistenceError.invalidWork }
        guard !identifiers.isEmpty else { return [:] }
        return try await databasePool.read { db in
            var result: [RoomID: V2ClientConversationUnreadRow] = [:]
            for start in stride(from: 0, to: identifiers.count, by: 100) {
                let ids = Array(identifiers[start..<min(start + 100, identifiers.count)])
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT state.*, member.membership_revision AS local_membership_revision, member.is_member AS local_is_member,
                        (SELECT CASE WHEN COALESCE(MIN(CASE WHEN typeof(value) = 'integer' AND value > 0
                            THEN 1 ELSE 0 END), 1) = 1 THEN MAX(value) ELSE -1 END FROM (
                            SELECT read_through_room_sequence AS value FROM v2_room_read_watermarks
                            WHERE room_id = state.room_id
                            UNION ALL
                            SELECT desired_sequence AS value FROM v2_read_receipt_intents WHERE room_id=state.room_id
                            UNION ALL
                            SELECT requested_sequence AS value FROM v2_read_receipt_archives WHERE room_id=state.room_id
                            UNION ALL
                            SELECT r.requested_sequence AS value FROM v2_read_receipt_operations r JOIN v2_operation_work w ON w.work_id=r.work_id
                            WHERE r.room_id=state.room_id AND w.execution_state NOT IN ('rejected','closed','cancelledLocally','expiredUnsubmitted')
                        )) AS local_read
                    FROM v2_room_sync_states AS state
                    JOIN v2_room_recovery_scan AS scan ON scan.singleton = 1
                    JOIN v2_local_installation AS account ON account.singleton = scan.singleton
                        AND account.binding = scan.installation_binding AND account.user_id = scan.user_id
                    LEFT JOIN v2_room_membership_states AS member ON member.room_id = state.room_id
                    WHERE state.room_id IN (\(placeholders))
                    """, arguments: StatementArguments(ids))
                for row in rows {
                    let room = try RoomID(row["room_id"] as String)
                    let state = try V2RoomSynchronizationState(roomID: room,
                        ownerEpoch: Self.storageUnsigned(row, column: "owner_epoch"),
                        viewerMembershipRevision: Self.storageUnsigned(row, column: "membership_revision"),
                        head: Self.storageUnsigned(row, column: "head"), trimmedThrough: Self.storageUnsigned(row, column: "trimmed_through"),
                        readThrough: Self.storageUnsigned(row, column: "read_through"),
                        latestOwnMessageSequence: Self.storageUnsigned(row, column: "latest_own_sequence"))
                    // Validate membership before filtering: SQL ordering can hide a corrupt revision.
                    let memberValue: DatabaseValue = row["local_membership_revision"]
                    if !memberValue.isNull {
                        let revision = try Self.storageUnsigned(row, column: "local_membership_revision")
                        guard revision > 0 else { throw V2ClientSyncError.storageRangeExceeded }
                        if revision > state.viewerMembershipRevision ||
                            (revision == state.viewerMembershipRevision && !(row["local_is_member"] as Bool)) { continue }
                    }
                    // NULL means no candidate; -1 is the aggregate's invalid-candidate sentinel.
                    let localValue: DatabaseValue = row["local_read"]
                    let local = try localValue.isNull ? nil : Self.storageUnsigned(row, column: "local_read")
                    result[room] = .init(roomID: room, head: state.head, serverUnreadCount: state.unreadCount,
                        localReadWatermark: local,
                        displayedUnread: V2ClientConversationUnread.displayedUnread(serverUnread: state.unreadCount,
                            head: state.head, localWatermark: local))
                }
            }
            return result
        }
    }
}
