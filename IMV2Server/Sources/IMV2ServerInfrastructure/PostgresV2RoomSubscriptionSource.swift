import Foundation
import FluentKit
import SQLKit
import IMV2Core
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2ServerContracts
import IMV2ServerApplication

/// Reads committed room order, never a preallocated outbox/identity high-water.
/// Membership controls rebuild historical state at their committed revisions;
/// ordinary bodies rely on the already-consumed control stream. Only edits,
/// withdrawals and reactions query original-message visibility. Compact bodies
/// become pull heads. Every cut retains the actual activation through its native lifetime capability.
public struct PostgresV2RoomSubscriptionSource: V2RoomSubscriptionSource {
    private let database: any Database
    private let admission: V2DatabaseWorkAdmissionController?
    private let schema: String
    private let activation: V2RoomActivationToken
    private let lifetime: V2RoomActivationLifetime
    private let maximumTrackedUsers: Int
    private let maximumOnlineBodyBytes: Int
    public init(database: any Database, activation: V2RoomActivationToken, lifetime: V2RoomActivationLifetime, schema: String = "im_v2", maximumTrackedUsers: Int = V2GroupCapacityPolicy.largeMaximumMembers,
                maximumOnlineBodyBytes: Int = 262_144, databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
              maximumTrackedUsers > 0, (1...262_144).contains(maximumOnlineBodyBytes) else {
            throw V2RoomSubscriptionSourceError.invalidInput
        }
        guard lifetime.token == activation else { throw V2RoomSubscriptionSourceError.wrongOwner }
        self.lifetime = lifetime
        self.admission = databaseWorkAdmission; self.database = database; self.schema = schema; self.activation = activation; self.maximumTrackedUsers = maximumTrackedUsers
        self.maximumOnlineBodyBytes = maximumOnlineBodyBytes
    }

    public func snapshot(roomID: RoomID, owner: V2RoomDataOwner,
                         trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot {
        let (value, remaining) = try await withOwnedCut { sql in
            try await self.snapshotSQL(roomID: roomID, owner: owner, trackedUserIDs: trackedUserIDs, sql: sql, remaining: 0)
        }
        return .init(roomID: value.roomID, owner: value.owner, highWatermark: value.highWatermark,
            membershipRevision: value.membershipRevision, roomControlVersion: value.roomControlVersion, remainingLeaseMilliseconds: remaining, members: value.members)
    }

    private func snapshotSQL(roomID: RoomID, owner: V2RoomDataOwner, trackedUserIDs: Set<UserID>,
                             sql: any SQLDatabase, remaining: Int64) async throws -> V2RoomSubscriptionSourceSnapshot {
        let (room, users) = try inputs(roomID, owner, trackedUserIDs)
        let states = membershipStates(users: users, room: room, revision: "r.membership_revision")
        guard let row = try await sql.raw("""
            SELECT r.room_shard_id, r.owner_epoch, r.room_sequence, r.membership_revision,
                   coalesce((SELECT version FROM \(unsafeRaw: schema).realtime_control_versions
                       WHERE topic_kind='roomEvents' AND topic_id=r.room_id::text),0) AS room_control_version,
                   (\(states))::text AS members_json
            FROM \(unsafeRaw: schema).rooms r WHERE r.room_id = \(bind: room)
            """).first(decoding: SnapshotRow.self) else { throw V2RoomSubscriptionSourceError.roomNotFound }
        try validateOwner(shard: row.room_shard_id, epoch: row.owner_epoch, sequence: row.room_sequence, owner: owner)
        guard row.membership_revision >= 0, row.room_control_version >= 0 else { throw V2RoomSubscriptionSourceError.corruptPersistence }
        let members = try decodeMembers(row.members_json, requested: trackedUserIDs)
        return .init(roomID: roomID, owner: owner, highWatermark: UInt64(row.room_sequence), membershipRevision: UInt64(row.membership_revision), roomControlVersion: row.room_control_version, remainingLeaseMilliseconds: remaining, members: members)
    }

    public func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
                     trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage {
        let (value, remaining) = try await withOwnedCut { sql in
            try await self.readSQL(roomID: roomID, owner: owner, afterRoomSequence: afterRoomSequence,
                trackedUserIDs: trackedUserIDs, limit: limit, sql: sql, remaining: 0)
        }
        return .init(roomID: value.roomID, owner: value.owner, afterRoomSequence: value.afterRoomSequence,
            highWatermark: value.highWatermark, records: value.records, remainingLeaseMilliseconds: remaining)
    }

    private func readSQL(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
                         trackedUserIDs: Set<UserID>, limit: Int, sql: any SQLDatabase,
                         remaining: Int64) async throws -> V2RoomSubscriptionSourcePage {
        guard afterRoomSequence <= UInt64(Int64.max), (1...64).contains(limit) else {
            throw V2RoomSubscriptionSourceError.invalidInput
        }
        let (room, users) = try inputs(roomID, owner, trackedUserIDs)
        let rows = try await sql.raw(readQuery(room: room, users: users, after: Int64(afterRoomSequence), limit: limit)).all(decoding: EventRow.self)
        guard let first = rows.first else { throw V2RoomSubscriptionSourceError.roomNotFound }
        try validateOwner(shard: first.room_shard_id, epoch: first.owner_epoch, sequence: first.high_watermark, owner: owner)
        guard first.trimmed_through >= 0, afterRoomSequence >= UInt64(first.trimmed_through),
              afterRoomSequence <= UInt64(first.high_watermark) else { throw V2RoomSubscriptionSourceError.snapshotRequired }
        var expected = afterRoomSequence + 1
        var records: [V2RoomSubscriptionSourceRecord] = []
        for row in rows where row.event_id != nil {
            guard let id = row.event_id, let sequence = row.room_sequence, sequence >= 0,
                  UInt64(sequence) == expected, sequence <= first.high_watermark,
                  let type = row.event_type, Self.knownTypes.contains(type),
                  let revision = row.committed_membership_revision, revision >= 0,
                  let effectiveRevision = row.effective_revision, effectiveRevision >= revision else {
                throw V2RoomSubscriptionSourceError.corruptPersistence
            }
            if ["message.edited", "message.withdrawn", "message.reaction_changed"].contains(type) {
                guard let accepted = row.accepted_membership_revision, accepted >= 0, accepted <= revision,
                      row.eligible_json != nil else {
                    throw V2RoomSubscriptionSourceError.corruptPersistence
                }
            }
            let control: V2RoomSubscriptionSourceRecord.MembershipControl?
            if ["room.created", "membership_changed", "group.member_role_changed"].contains(type) {
                guard effectiveRevision > 0, let membersJSON = row.members_json,
                      type != "group.member_role_changed" || effectiveRevision == revision + 1 else {
                    throw V2RoomSubscriptionSourceError.corruptPersistence
                }
                control = .init(revisionBefore: UInt64(effectiveRevision - 1), revisionAfter: UInt64(effectiveRevision),
                    members: try decodeMembers(membersJSON, requested: trackedUserIDs))
            } else {
                guard row.members_json == nil else { throw V2RoomSubscriptionSourceError.corruptPersistence }
                control = nil
            }
            let policy: V2RoomSubscriptionSourceRecord.RecipientPolicy
            if let eligibleJSON = row.eligible_json {
                let eligible = Set(try JSONDecoder().decode([UUID].self, from: Data(eligibleJSON.utf8)).map { UserID(uuid: $0) })
                guard eligible.isSubset(of: trackedUserIDs) else { throw V2RoomSubscriptionSourceError.corruptPersistence }
                policy = .explicit(eligible)
            } else { policy = .currentAuthorized }
            let event = V2RealtimeRoomEvent(roomID: roomID, highWatermark: UInt64(first.high_watermark),
                sourceEventID: EventID(uuid: id), roomSequence: UInt64(sequence),
                projectionKind: groupEventProjectionKind(for: type), payload: Data((row.payload_json ?? "").utf8),
                recipientUserIDs: [], groupMembershipRevision: UInt64(revision),
                acceptedMembershipRevision: row.accepted_membership_revision.map(UInt64.init))
            records.append(.init(event: event, hasOnlineBody: row.payload_json != nil,
                membershipControl: control, recipientPolicy: policy))
            expected += 1
        }
        if records.count < limit, expected <= UInt64(first.high_watermark) {
            throw V2RoomSubscriptionSourceError.snapshotRequired
        }
        return .init(roomID: roomID, owner: owner, afterRoomSequence: afterRoomSequence,
                     highWatermark: UInt64(first.high_watermark), records: records, remainingLeaseMilliseconds: remaining)
    }

    package func readQuery(room: UUID, users: [UUID], after: Int64, limit: Int) -> SQLQueryString {
        let states = membershipStates(users: users, room: room, revision: "event.effective_revision")
        return """
            WITH r AS MATERIALIZED (
                SELECT room_shard_id, owner_epoch, room_sequence, log_trimmed_through_room_sequence
                FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room)
            ), candidates AS MATERIALIZED (
                (SELECT e.event_id, e.room_sequence, e.event_type, e.payload,
                        e.committed_membership_revision
                 FROM \(unsafeRaw: schema).room_events e
                 WHERE e.room_id = \(bind: room) AND e.room_sequence > \(bind: after)
                 ORDER BY e.room_sequence LIMIT \(bind: limit))
                UNION ALL
                (SELECT m.accepted_event_id, m.room_sequence, 'message.accepted', NULL::jsonb,
                        m.accepted_membership_revision
                 FROM \(unsafeRaw: schema).messages m
                 WHERE m.room_id = \(bind: room) AND m.accepted_event_storage = 'message_row'
                   AND m.room_sequence > \(bind: after)
                 ORDER BY m.room_sequence LIMIT \(bind: limit))
            ), event AS MATERIALIZED (
                SELECT *, CASE WHEN event_type IN ('membership_changed', 'group.member_role_changed')
                               THEN (payload->>'membership_revision')::bigint
                               ELSE committed_membership_revision END AS effective_revision
                FROM candidates ORDER BY room_sequence LIMIT \(bind: limit)
            )
            SELECT r.room_shard_id, r.owner_epoch, r.room_sequence AS high_watermark,
                   r.log_trimmed_through_room_sequence AS trimmed_through,
                   event.event_id, event.room_sequence, event.event_type, event.committed_membership_revision,
                   event.effective_revision, acceptance.accepted_membership_revision,
                   CASE WHEN event.payload->>'payload_storage' = 'message_reference_v1'
                             OR octet_length(event.payload::text) > \(bind: maximumOnlineBodyBytes)
                        THEN NULL ELSE event.payload::text END AS payload_json,
                   CASE WHEN event.event_type IN ('room.created','membership_changed','group.member_role_changed')
                        THEN (\(states))::text ELSE NULL END AS members_json,
                   CASE WHEN event.event_type IN ('message.edited','message.withdrawn','message.reaction_changed') THEN (
                       SELECT coalesce(jsonb_agg(u.user_id::text ORDER BY u.user_id), '[]'::jsonb)
                       FROM unnest(\(bind: users)::uuid[]) u(user_id)
                       WHERE EXISTS (
                           SELECT 1 FROM \(unsafeRaw: schema).room_memberships m
                           WHERE m.room_id = \(bind: room) AND m.user_id = u.user_id
                             AND m.joined_revision <= event.effective_revision
                             AND (m.left_revision IS NULL OR m.left_revision > event.effective_revision)
                       ) AND (event.event_type NOT IN ('message.edited','message.withdrawn','message.reaction_changed')
                           OR EXISTS (
                               SELECT 1 FROM \(unsafeRaw: schema).room_memberships original
                               WHERE original.room_id = \(bind: room) AND original.user_id = u.user_id
                                 AND original.joined_revision <= acceptance.accepted_membership_revision
                                 AND (original.left_revision IS NULL OR original.left_revision > acceptance.accepted_membership_revision)
                           ))
                   )::text ELSE NULL END AS eligible_json
            FROM r LEFT JOIN event ON TRUE
            LEFT JOIN LATERAL (
                SELECT completion.accepted_membership_revision
                FROM \(unsafeRaw: schema).messages message
                JOIN \(unsafeRaw: schema).message_send_completions completion
                  ON completion.room_id = message.room_id AND completion.sender_user_id = message.sender_user_id
                 AND completion.client_message_id = message.client_message_id
                WHERE event.event_type IN ('message.edited','message.withdrawn','message.reaction_changed')
                  AND message.room_id = \(bind: room) AND message.message_id = (event.payload->>'message_id')::uuid
                  AND completion.message_id = message.message_id AND completion.room_sequence = message.room_sequence
            ) acceptance ON TRUE
            ORDER BY event.room_sequence NULLS LAST
            """
    }

    package func withOwnedCut<Value: Sendable>(
        _ operation: @escaping @Sendable (any SQLDatabase) async throws -> Value
    ) async throws -> (Value, Int64) {
        let deadline = V2RoomSQLDeadline.boundedTransactionDeadline()
        return try await lifetime.withPin(deadline: deadline) { validUntil in
            let value = try await v2WithAdmittedRoomDatabaseWork(admission, workClass: .interactiveRead,
                callerDeadline: validUntil) {
                try await v2WithRoomActivationTransaction(database: database, deadline: validUntil,
                    readOnlyRepeatableRead: true) { transaction in
                    guard let sql = transaction as? any SQLDatabase else {
                        throw V2RoomSubscriptionSourceError.invalidInput
                    }
                    guard let row = try await sql.raw("""
                        SELECT room_shard_id, owner_epoch FROM \(unsafeRaw: schema).rooms
                        WHERE room_id=\(bind: activation.roomID.uuidValue!)
                        """).first(decoding: ReadOwnerRow.self) else {
                        throw V2RoomActorStateError.roomNotFound
                    }
                    guard row.room_shard_id == activation.owner.shardID,
                          row.owner_epoch == activation.owner.epoch else {
                        throw V2RoomActorStateError.ownerChanged
                    }
                    return try await operation(sql)
                }
            }
            let duration = ContinuousClock.now.duration(to: validUntil).components
            let remaining = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
            guard remaining > 0 else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            return (value, remaining)
        }
    }

    private struct ReadOwnerRow: Decodable {
        let room_shard_id: String
        let owner_epoch: Int64
    }

    private func inputs(_ roomID: RoomID, _ owner: V2RoomDataOwner, _ users: Set<UserID>) throws -> (UUID, [UUID]) {
        guard roomID == activation.roomID, owner == activation.owner else { throw V2RoomSubscriptionSourceError.wrongOwner }
        guard let room = roomID.uuidValue,
              users.count <= maximumTrackedUsers, users.allSatisfy({ $0.uuidValue != nil }) else {
            throw V2RoomSubscriptionSourceError.invalidInput
        }
        return (room, users.sorted().compactMap(\.uuidValue))
    }
    private func membershipStates(users: [UUID], room: UUID, revision: SQLQueryString) -> SQLQueryString {
        """
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'userID', u.user_id::text,
            'memberRevision', CASE WHEN m.left_revision <= \(revision) THEN m.left_revision ELSE coalesce(m.joined_revision,0) END,
            'authorized', m.user_id IS NOT NULL AND (m.left_revision IS NULL OR m.left_revision > \(revision))
        ) ORDER BY u.user_id), '[]'::jsonb)
        FROM unnest(\(bind: users)::uuid[]) u(user_id)
        LEFT JOIN LATERAL (
            SELECT user_id, joined_revision, left_revision FROM \(unsafeRaw: schema).room_memberships
            WHERE room_id = \(bind: room) AND user_id = u.user_id AND joined_revision <= \(revision)
            ORDER BY joined_revision DESC LIMIT 1
        ) m ON TRUE
        """
    }
    private func decodeMembers(_ json: String, requested: Set<UserID>) throws -> [V2RoomSubscriptionSourceMember] {
        let rows = try JSONDecoder().decode([MemberRow].self, from: Data(json.utf8))
        let members = rows.map { V2RoomSubscriptionSourceMember(userID: UserID(uuid: $0.userID),
            memberRevision: $0.memberRevision, authorized: $0.authorized) }
        guard Set(members.map(\.userID)) == requested, members.count == requested.count,
              members.allSatisfy({ $0.memberRevision <= UInt64(Int64.max) }) else {
            throw V2RoomSubscriptionSourceError.corruptPersistence
        }
        return members
    }
    private func validateOwner(shard: String, epoch: Int64, sequence: Int64, owner: V2RoomDataOwner) throws {
        guard shard == owner.shardID, epoch == owner.epoch else { throw V2RoomSubscriptionSourceError.wrongOwner }
        guard sequence >= 0 else { throw V2RoomSubscriptionSourceError.corruptPersistence }
    }
    private static let knownTypes: Set<String> = [
        "room.created", "membership_changed", "group.member_role_changed", "member.muted", "room.frozen", "room.unfrozen",
        "message.accepted", "message.edited", "message.withdrawn", "message.redacted", "message.reaction_changed",
        "message.pinned_changed", "group.announcement_changed", "group.role_permissions_changed", "group.avatar_changed", "group.nickname_changed"
    ]
    private struct SnapshotRow: Decodable {
        let room_shard_id: String; let owner_epoch: Int64; let room_sequence: Int64; let membership_revision: Int64; let room_control_version: Int64; let members_json: String
    }
    private struct MemberRow: Decodable {
        let userID: UUID; let memberRevision: UInt64; let authorized: Bool
    }
    private struct EventRow: Decodable {
        let room_shard_id: String; let owner_epoch: Int64; let high_watermark: Int64; let trimmed_through: Int64
        let event_id: UUID?; let room_sequence: Int64?; let event_type: String?
        let committed_membership_revision: Int64?; let effective_revision: Int64?; let accepted_membership_revision: Int64?
        let payload_json: String?; let members_json: String?; let eligible_json: String?
    }
}
