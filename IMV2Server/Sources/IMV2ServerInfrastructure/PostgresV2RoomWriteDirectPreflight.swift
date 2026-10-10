import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

// 在 Store 借用的事务连接上执行权威私聊房间日志预检。
// 围栏检查与提交由 Store 负责。
enum PlainDirectRoomLogPreflight {
    /// 单聊房间日志预检的批量变体。
    ///
    /// 进程本地策略缓存刻意*不是*权威：
    /// 每次命中都只有在本次查询锁定并精确匹配持久配对与两条用户策略修订围栏之后才被接受。
    /// 未命中或不匹配时，会先从事 PostgreSQL 读取完整策略，命令才可能被接受。
    ///
    /// - Parameters:
    ///   - ordered: 已排序的房间写入请求。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 各请求对应的预检结果行。
    /// - Throws: 预检不匹配或查询失败时抛出。
    static func load(
        _ ordered: [OrderedRoomWriteRequest],
        leasedPolicies: [Int: V2DirectSendControlPolicy]? = nil,
        sql: any SQLDatabase
    ) async throws -> [PlainDirectRoomLogBatchPreflightRow] {
        let rows = try await sql.raw(query(ordered, leasedPolicies: leasedPolicies)).all()
            .map { try PlainDirectRoomLogBatchPreflightRow(row: $0) }
        guard rows.count == ordered.count,
              zip(rows, ordered).allSatisfy({ $0.0.ordinal == $0.1.preflightOrdinal })
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return rows
    }

    static func query(
        _ ordered: [OrderedRoomWriteRequest],
        leasedPolicies: [Int: V2DirectSendControlPolicy]? = nil,
        priorOperation: SQLQueryString? = nil,
        validatesDirectMemberships: Bool = false,
        usesAcceptedRoomState: Bool = false
    ) throws -> SQLQueryString {
        let input = try ordered.map { item in
            PlainDirectRoomLogBatchPreflightInput(
                ordinal: item.preflightOrdinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try directPreflightUUID(item.request.command.clientMessageID),
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(item.request.now),
                cachedDirectPolicy: item.cachedDirectPolicy,
                usesRoomAdmissionCredits: item.usesRoomAdmissionCredits
            )
        }
        let inputJSON = try roomWriteJSON(input)
        let policyInput: SQLQueryString
        let senderActive: SQLQueryString
        let policyCTEs: SQLQueryString
        if let leasedPolicies {
            guard leasedPolicies.count == ordered.count,
                  ordered.allSatisfy({ leasedPolicies[$0.preflightOrdinal] != nil }) else {
                throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
            }
            let policies = try roomWriteJSON(ordered.map {
                LeasedDirectPreflightInput(ordinal: $0.preflightOrdinal, policy: leasedPolicies[$0.preflightOrdinal]!)
            })
            policyInput = """
                leased_policy AS MATERIALIZED (
                    SELECT (value->>'ordinal')::integer AS ordinal, value->'policy' AS policy
                    FROM jsonb_array_elements(\(bind: policies)::jsonb)
                    LIMIT \(literal: ordered.count)
                ),
                """
            senderActive = "(SELECT (policy->'sender'->>'is_active')::boolean FROM leased_policy WHERE ordinal=room.ordinal)"
            policyCTEs = """
                direct_policy AS MATERIALIZED (
                    SELECT pair.*, 0::bigint AS sender_policy_revision, 0::bigint AS recipient_policy_revision,
                           (lease.policy->'recipient'->>'is_active')::boolean AS recipient_is_active,
                           (lease.policy->>'blocked')::boolean AS blocked,
                           (lease.policy->>'isFriend')::boolean AS is_friend,
                           (lease.policy->>'allowsStrangers')::boolean AS allows_strangers,
                           lease.policy->'sender'->>'special_kind' AS sender_account_kind,
                           lease.policy->'sender'->>'special_status' AS sender_account_status,
                           (lease.policy->'sender'->>'allows_service_messages')::boolean AS sender_allows_service_messages,
                           lease.policy->'recipient'->>'special_kind' AS recipient_account_kind,
                           lease.policy->'recipient'->>'special_status' AS recipient_account_status,
                           (lease.policy->'recipient'->>'allows_customer_messages')::boolean AS recipient_allows_customer_messages
                    FROM direct_pair AS pair
                    JOIN fresh_room AS room ON room.ordinal=pair.ordinal
                    JOIN leased_policy AS lease ON lease.ordinal=pair.ordinal
                        AND pair.recipient_user_id=(lease.policy->'recipient'->>'user_id')::uuid
                        AND room.sender_id=(lease.policy->'sender'->>'user_id')::uuid
                )
                """
        } else {
            policyInput = ""
            senderActive = """
                EXISTS (
                    SELECT 1
                    FROM im_v2.public_user_profiles AS profile
                    WHERE profile.user_id = room.sender_id
                      AND profile.state = 'active'
                      AND NOT EXISTS (
                          SELECT 1 FROM im_v2.account_disables AS disabled
                          WHERE disabled.user_id = profile.user_id
                      )
                )
                """
            policyCTEs = """
                direct_policy_versions AS MATERIALIZED (
                    SELECT pair.*,
                           sender_version.revision AS sender_policy_revision,
                           recipient_version.revision AS recipient_policy_revision
                    FROM direct_pair AS pair
                    JOIN fresh_room AS room ON room.ordinal = pair.ordinal
                    JOIN im_v2.user_direct_send_policy_versions AS sender_version
                      ON sender_version.user_id = room.sender_id
                    JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                      ON recipient_version.user_id = pair.recipient_user_id
                    FOR KEY SHARE OF sender_version, recipient_version
                ), special AS MATERIALIZED (
                    SELECT pair.ordinal, account.account_user_id, account.account_kind,
                           account.status, account.allows_customer_messages,
                           account.allows_service_messages
                    FROM direct_policy_versions AS pair
                    JOIN fresh_room AS room ON room.ordinal = pair.ordinal
                    JOIN im_v2.special_accounts AS account
                      ON account.account_user_id = room.sender_id
                      OR account.account_user_id = pair.recipient_user_id
                    ORDER BY pair.ordinal, account.account_user_id
                    FOR KEY SHARE OF account
                ), direct_policy AS MATERIALIZED (
                    SELECT pair.ordinal, pair.recipient_user_id,
                           pair.direct_policy_revision, pair.sender_policy_revision,
                           pair.recipient_policy_revision,
                           pair.sender_profile_visible_to_recipient,
                           pair.sender_can_send, pair.sender_has_replied,
                           pair.recipient_has_replied,
                           CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                          AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                          AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                          AND pair.recipient_user_id = room.cached_recipient_id
                                THEN room.cached_recipient_is_active
                                ELSE EXISTS (
                               SELECT 1 FROM im_v2.public_user_profiles AS profile
                               WHERE profile.user_id = pair.recipient_user_id
                                 AND profile.state = 'active'
                                 AND NOT EXISTS (
                                     SELECT 1 FROM im_v2.account_disables AS disabled
                                     WHERE disabled.user_id = profile.user_id
                                 )
                           ) END AS recipient_is_active,
                           CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                          AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                          AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                          AND pair.recipient_user_id = room.cached_recipient_id
                                THEN room.cached_blocked
                                ELSE EXISTS (
                               SELECT 1 FROM im_v2.user_blocks AS block
                               WHERE (block.blocker_user_id = pair.lower_user_id
                                      AND block.blocked_user_id = pair.higher_user_id)
                                  OR (block.blocker_user_id = pair.higher_user_id
                                      AND block.blocked_user_id = pair.lower_user_id)
                           ) END AS blocked,
                           CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                          AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                          AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                          AND pair.recipient_user_id = room.cached_recipient_id
                                THEN room.cached_is_friend
                                ELSE EXISTS (
                               SELECT 1 FROM im_v2.user_relationships AS relationship
                               WHERE relationship.lower_user_id = pair.lower_user_id
                                 AND relationship.higher_user_id = pair.higher_user_id
                                 AND relationship.state = 'accepted'
                           ) END AS is_friend,
                           CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                          AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                          AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                          AND pair.recipient_user_id = room.cached_recipient_id
                                THEN room.cached_allows_strangers
                                ELSE COALESCE((
                               SELECT preference.allows_stranger_messages
                               FROM im_v2.user_stranger_message_preferences AS preference
                               WHERE preference.user_id = pair.recipient_user_id
                           ), TRUE) END AS allows_strangers,
                           (SELECT account_kind FROM special
                            WHERE ordinal = pair.ordinal
                              AND account_user_id = room.sender_id) AS sender_account_kind,
                           (SELECT status FROM special
                            WHERE ordinal = pair.ordinal
                              AND account_user_id = room.sender_id) AS sender_account_status,
                           (SELECT allows_service_messages FROM special
                            WHERE ordinal = pair.ordinal
                              AND account_user_id = room.sender_id) AS sender_allows_service_messages,
                           (SELECT account_kind FROM special
                            WHERE ordinal = pair.ordinal
                              AND account_user_id = pair.recipient_user_id) AS recipient_account_kind,
                           (SELECT status FROM special
                            WHERE ordinal = pair.ordinal
                              AND account_user_id = pair.recipient_user_id) AS recipient_account_status,
                           (SELECT allows_customer_messages FROM special
                            WHERE ordinal = pair.ordinal
                              AND account_user_id = pair.recipient_user_id) AS recipient_allows_customer_messages
                    FROM direct_policy_versions AS pair
                    JOIN fresh_room AS room ON room.ordinal = pair.ordinal
                )
                """
        }
        let priorOperationQuery: SQLQueryString = priorOperation ?? """
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.message_send_completions AS message
                  ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                 AND message.client_message_id = room.client_message_id
                UNION
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.direct_message_denials AS denial
                  ON denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                 AND denial.client_message_id = room.client_message_id
            """
        let membershipValidation: SQLQueryString = validatesDirectMemberships ? """
            room.room_kind <> 'direct' OR EXISTS (
                SELECT 1 FROM im_v2.direct_room_pairs pair WHERE pair.room_id=room.room_id
                  AND COALESCE((SELECT count(*)=2 AND bool_and(member.user_id IN (pair.lower_user_id,pair.higher_user_id))
                    FROM (SELECT user_id FROM im_v2.room_memberships
                          WHERE room_id=room.room_id AND joined_revision<=room.membership_revision
                            AND (left_revision IS NULL OR left_revision>room.membership_revision) LIMIT 3) member),false)
            )
            """ : "true"
        // A typed accepted send already checked membership/mute in the room
        // runtime. Do not read or lock those policy rows again during persistence.
        let actorQuery: SQLQueryString = usesAcceptedRoomState ? """
                SELECT room.ordinal, 'member'::text AS actor_role,
                       true AS sender_is_active, false AS muted
                FROM fresh_room room
            """ : """
                SELECT room.ordinal, membership.role AS actor_role,
                       \(senderActive) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = room.sender_id
                             AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                       ) AS muted
                FROM fresh_room AS room
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                FOR UPDATE OF membership
            """
        return """
            WITH \(policyInput) input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.client_message_id, input.now_postgres_microseconds,
                       input.cached_recipient_id,
                       input.cached_direct_pair_revision,
                       input.cached_sender_policy_revision,
                       input.cached_recipient_policy_revision,
                       input.cached_recipient_is_active,
                       input.cached_blocked, input.cached_is_friend,
                       input.cached_allows_strangers,
                       input.uses_room_admission_credits
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    now_postgres_microseconds bigint,
                    cached_recipient_id uuid,
                    cached_direct_pair_revision bigint,
                    cached_sender_policy_revision bigint,
                    cached_recipient_policy_revision bigint,
                    cached_recipient_is_active boolean,
                    cached_blocked boolean,
                    cached_is_friend boolean,
                    cached_allows_strangers boolean,
                    uses_room_admission_credits boolean
                )
                -- The JSON is generated from exactly input.count requests.
                -- Expose that bound to the planner instead of its SRF estimate
                -- of 100, which scans every room for a singleton turn.
                LIMIT \(literal: input.count)
            ), locked_room AS MATERIALIZED (
                SELECT input.ordinal, input.sender_id, input.client_message_id,
                       input.now_postgres_microseconds, input.cached_recipient_id,
                       input.cached_direct_pair_revision,
                       input.cached_sender_policy_revision,
                       input.cached_recipient_policy_revision,
                       input.cached_recipient_is_active,
                       input.cached_blocked, input.cached_is_friend,
                       input.cached_allows_strangers,
                       input.uses_room_admission_credits, room.room_kind,
                       room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.capacity_class,
                       room.frozen_at, room.room_id
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                -- Room identity is immutable. Keep writers serialized while
                -- allowing independent KEY SHARE credit reservations.
                FOR NO KEY UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                \(priorOperationQuery)
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1 FROM prior_operation AS prior
                    WHERE prior.ordinal = room.ordinal
                )
            ), locked_actor AS MATERIALIZED (
                \(actorQuery)
            ), direct_pair AS MATERIALIZED (
                SELECT room.ordinal, pair.lower_user_id, pair.higher_user_id,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_user_id,
                       pair.direct_policy_revision,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_profile_visible_to_higher
                            ELSE pair.higher_profile_visible_to_lower
                       END AS sender_profile_visible_to_recipient,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_can_send ELSE pair.higher_can_send
                       END AS sender_can_send,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_has_replied ELSE pair.higher_has_replied END AS sender_has_replied,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.higher_has_replied ELSE pair.lower_has_replied END AS recipient_has_replied
                FROM fresh_room AS room
                JOIN locked_actor AS actor ON actor.ordinal = room.ordinal
                JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
                WHERE room.room_kind = 'direct'
                  AND (pair.lower_user_id = room.sender_id
                       OR pair.higher_user_id = room.sender_id)
                FOR UPDATE OF pair
            ), \(policyCTEs)
            SELECT room.ordinal, room.room_kind, room.room_shard_id,
                   room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.capacity_profile_id,
                   room.capacity_class, room.frozen_at,
                   actor.actor_role, actor.sender_is_active, actor.muted,
                   policy.recipient_user_id,
                   policy.sender_profile_visible_to_recipient,
                   policy.direct_policy_revision,
                   policy.sender_policy_revision, policy.recipient_policy_revision,
                   policy.sender_can_send, policy.recipient_is_active,
                   policy.blocked, policy.is_friend, policy.sender_has_replied,
                   policy.recipient_has_replied, policy.allows_strangers,
                   policy.sender_account_kind, policy.sender_account_status,
                   policy.sender_allows_service_messages,
                   policy.recipient_account_kind, policy.recipient_account_status,
                   policy.recipient_allows_customer_messages,
                   \(membershipValidation) AS valid_direct_memberships
            FROM fresh_room AS room
            LEFT JOIN locked_actor AS actor ON actor.ordinal = room.ordinal
            LEFT JOIN direct_policy AS policy ON policy.ordinal = room.ordinal
            ORDER BY room.ordinal
            """
    }
}

private func directPreflightUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

/// 持久集合式单聊发送预检的输入。
///
/// 缓存字段只是「按修订不可变」的策略事实；
/// 只有全部匹配三条已锁定修订围栏与接收者之后，PostgreSQL 才会视其为可用。
private struct PlainDirectRoomLogBatchPreflightInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let nowPostgresMicroseconds: Int64
    let cachedRecipientID: UUID?
    let cachedDirectPairRevision: Int64?
    let cachedSenderPolicyRevision: Int64?
    let cachedRecipientPolicyRevision: Int64?
    let cachedRecipientIsActive: Bool?
    let cachedBlocked: Bool?
    let cachedIsFriend: Bool?
    let cachedAllowsStrangers: Bool?
    let usesRoomAdmissionCredits: Bool

    init(
        ordinal: Int,
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        nowPostgresMicroseconds: Int64,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        usesRoomAdmissionCredits: Bool
    ) {
        self.ordinal = ordinal
        self.roomID = roomID
        self.senderID = senderID
        self.clientMessageID = clientMessageID
        self.nowPostgresMicroseconds = nowPostgresMicroseconds
        cachedRecipientID = cachedDirectPolicy?.recipientID
        cachedDirectPairRevision = cachedDirectPolicy?.directPairRevision
        cachedSenderPolicyRevision = cachedDirectPolicy?.senderPolicyRevision
        cachedRecipientPolicyRevision = cachedDirectPolicy?.recipientPolicyRevision
        cachedRecipientIsActive = cachedDirectPolicy?.recipientIsActive
        cachedBlocked = cachedDirectPolicy?.blocked
        cachedIsFriend = cachedDirectPolicy?.isFriend
        cachedAllowsStrangers = cachedDirectPolicy?.allowsStrangers
        self.usesRoomAdmissionCredits = usesRoomAdmissionCredits
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
        case cachedRecipientID = "cached_recipient_id"
        case cachedDirectPairRevision = "cached_direct_pair_revision"
        case cachedSenderPolicyRevision = "cached_sender_policy_revision"
        case cachedRecipientPolicyRevision = "cached_recipient_policy_revision"
        case cachedRecipientIsActive = "cached_recipient_is_active"
        case cachedBlocked = "cached_blocked"
        case cachedIsFriend = "cached_is_friend"
        case cachedAllowsStrangers = "cached_allows_strangers"
        case usesRoomAdmissionCredits = "uses_room_admission_credits"
    }
}

struct PlainDirectRoomLogBatchPreflightRow {
    var usesRuntimeState = false
    let ordinal: Int
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    let frozenAt: Date?
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let recipientUserID: UUID?
    let senderProfileVisibleToRecipient: Bool?
    let directPolicyRevision: Int64?
    let senderPolicyRevision: Int64?
    let recipientPolicyRevision: Int64?
    let senderCanSend: Bool?
    let recipientIsActive: Bool?
    let blocked: Bool?
    let isFriend: Bool?
    let senderHasReplied: Bool?
    let recipientHasReplied: Bool?
    let allowsStrangers: Bool?
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    /// 这是单聊消息准入中最热、最宽的行。直接按列解码可避免为每条消息
    /// 构造通用键控 Codable 容器、分配 49 个编码键并反复查找它们，
    /// 同时保留完全相同的 PostgreSQL 类型校验。
    ///
    /// - Parameter row: 待解码的数据库行。
    /// - Throws: 类型校验失败或列缺失时抛出。
    init(row: any SQLRow) throws {
        ordinal = try row.decode(column: "ordinal")
        kind = try row.decode(column: "room_kind")
        roomShardID = try row.decode(column: "room_shard_id")
        roomSequence = try row.decode(column: "room_sequence")
        timelineSequence = try row.decode(column: "timeline_sequence")
        membershipRevision = try row.decode(column: "membership_revision")
        capacityProfileID = try row.decode(column: "capacity_profile_id")
        capacityClass = try row.decode(column: "capacity_class")
        frozenAt = try row.decode(column: "frozen_at", as: Date?.self)

        actorRole = try row.decode(column: "actor_role", as: String?.self)
        senderIsActive = try row.decode(column: "sender_is_active", as: Bool?.self)
        muted = try row.decode(column: "muted", as: Bool?.self)
        recipientUserID = try row.decode(column: "recipient_user_id", as: UUID?.self)
        senderProfileVisibleToRecipient = try row.decode(column: "sender_profile_visible_to_recipient", as: Bool?.self)
        directPolicyRevision = try row.decode(column: "direct_policy_revision", as: Int64?.self)
        senderPolicyRevision = try row.decode(column: "sender_policy_revision", as: Int64?.self)
        recipientPolicyRevision = try row.decode(column: "recipient_policy_revision", as: Int64?.self)
        senderCanSend = try row.decode(column: "sender_can_send", as: Bool?.self)
        recipientIsActive = try row.decode(column: "recipient_is_active", as: Bool?.self)
        blocked = try row.decode(column: "blocked", as: Bool?.self)
        isFriend = try row.decode(column: "is_friend", as: Bool?.self)
        senderHasReplied = try row.decode(column: "sender_has_replied", as: Bool?.self)
        recipientHasReplied = try row.decode(column: "recipient_has_replied", as: Bool?.self)
        allowsStrangers = try row.decode(column: "allows_strangers", as: Bool?.self)
        senderAccountKind = try row.decode(column: "sender_account_kind", as: String?.self)
        senderAccountStatus = try row.decode(column: "sender_account_status", as: String?.self)
        senderAllowsServiceMessages = try row.decode(column: "sender_allows_service_messages", as: Bool?.self)
        recipientAccountKind = try row.decode(column: "recipient_account_kind", as: String?.self)
        recipientAccountStatus = try row.decode(column: "recipient_account_status", as: String?.self)
        recipientAllowsCustomerMessages = try row.decode(column: "recipient_allows_customer_messages", as: Bool?.self)
    }

    init(ordinal: Int, room: RoomRow,
        context: DirectMessageAcceptanceContext, policy: V2DirectSendControlPolicy, directPolicyRevision: Int64, recipientHasReplied: Bool) {
        self.ordinal = ordinal
        usesRuntimeState = true
        kind = room.kind; roomShardID = room.roomShardID
        roomSequence = room.roomSequence; timelineSequence = room.timelineSequence
        membershipRevision = room.membershipRevision; capacityProfileID = room.capacityProfileID
        capacityClass = room.capacityClass; frozenAt = room.frozenAt

        actorRole = "member"; senderIsActive = true; muted = false
        recipientUserID = context.recipientID; senderProfileVisibleToRecipient = context.senderProfileVisibleToRecipient
        self.directPolicyRevision = directPolicyRevision; senderPolicyRevision = 0; recipientPolicyRevision = 0
        senderCanSend = context.senderCanSend; recipientIsActive = policy.recipient.isActive
        blocked = policy.blocked; isFriend = policy.isFriend; senderHasReplied = context.senderHasReplied
        self.recipientHasReplied = recipientHasReplied; allowsStrangers = policy.allowsStrangers
        senderAccountKind = nil; senderAccountStatus = nil; senderAllowsServiceMessages = nil
        recipientAccountKind = nil; recipientAccountStatus = nil; recipientAllowsCustomerMessages = nil
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            capacityClass: capacityClass,

            frozenAt: frozenAt
        )
    }

    func directPolicySnapshot() throws -> DirectMessagePolicySnapshotRow {
        guard let recipientUserID, let senderProfileVisibleToRecipient,
              let recipientIsActive, let blocked, let isFriend,
              let senderHasReplied, let recipientHasReplied,
              let allowsStrangers
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    func directPolicyCacheEntry() throws -> V2DirectSendPolicyCache.Entry {
        guard let directPolicyRevision, let senderPolicyRevision, let recipientPolicyRevision
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return try directPolicySnapshot().cacheEntry(directPairRevision: directPolicyRevision,
            senderPolicyRevision: senderPolicyRevision, recipientPolicyRevision: recipientPolicyRevision,
            senderIsActive: senderIsActive == true)
    }

}

/// Generated only from opaque runtime executions, never client input.
private struct LeasedDirectPreflightInput: Encodable {
    let ordinal: Int
    let policy: V2DirectSendControlPolicy
}
