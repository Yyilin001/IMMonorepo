import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

// 在 Store 借用的事务连接上加载逐条接受快照。
// 所有者围栏、最终预留和提交仍由 Store 负责。
enum ScalarMessagePreflight {
    /// 一次事务范围内的读取，同时加载房间、幂等结果、房间准入、发送者成员关系与单聊策略。
    ///
    /// 操作围栏已经建立了新快照；CTE 加锁图保持
    /// 房间 -> 房间准入 -> 发送者成员 -> 单聊配对的顺序。
    /// 共享分片行仍只作为最后一步的窄范围预留。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 消息接受上下文。
    /// - Throws: 查询失败时抛出。
    static func load(
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        now: Date,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        leasedPolicy: V2DirectSendControlPolicy? = nil,
        leasedAccount: V2PolicyAccountFacts? = nil,
        sql: any SQLDatabase
    ) async throws -> MessageAcceptanceContextRow {
        // 缓存的发送方回复标记只是性能提示。旧授权路径锁定策略版本到提交；
        // 新许可路径由调用方持有许可围栏，下面只锁定房间配对事实。
        // `senderHasReplied` 单调变化；缓存命中让稳定状态的发送
        // 使用兼容的共享锁，而非首次写入回复标记所需的独占锁。
        let directPairLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF pair"
            : "FOR UPDATE OF pair"
        let directPolicyVersionLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF sender_version, recipient_version"
            : "FOR KEY SHARE OF sender_version, recipient_version"
        // A leased execution has already held the durable room fence. Only
        // room-owned membership, reply markers and admission are read here;
        // account/pair facts come from its registered immutable snapshot.
        let senderActive: SQLQueryString
        let policyCTEs: SQLQueryString
        guard leasedAccount == nil || leasedPolicy == nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
        if let account = leasedAccount {
            guard account.userID == senderID else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
            senderActive = "\(bind: account.isActive)"
            policyCTEs = """
                direct_policy AS MATERIALIZED (
                    SELECT NULL::uuid AS recipient_user_id, NULL::bigint AS direct_policy_revision,
                           NULL::bigint AS sender_policy_revision, NULL::bigint AS recipient_policy_revision,
                           NULL::boolean AS sender_profile_visible_to_recipient, NULL::boolean AS sender_can_send,
                           NULL::boolean AS sender_has_replied, NULL::boolean AS recipient_has_replied,
                           NULL::boolean AS recipient_is_active, NULL::boolean AS blocked,
                           NULL::boolean AS is_friend, NULL::boolean AS allows_strangers,
                           NULL::text AS sender_account_kind, NULL::text AS sender_account_status,
                           NULL::boolean AS sender_allows_service_messages,
                           NULL::text AS recipient_account_kind, NULL::text AS recipient_account_status,
                           NULL::boolean AS recipient_allows_customer_messages
                    WHERE FALSE
                )
                """
        } else if let policy = leasedPolicy {
            senderActive = "\(bind: policy.sender.isActive)"
            policyCTEs = """
                direct_policy AS MATERIALIZED (
                    SELECT pair.recipient_user_id, pair.direct_policy_revision,
                           NULL::bigint AS sender_policy_revision,
                           NULL::bigint AS recipient_policy_revision,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.lower_profile_visible_to_higher ELSE pair.higher_profile_visible_to_lower
                           END AS sender_profile_visible_to_recipient,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.lower_can_send ELSE pair.higher_can_send
                           END AS sender_can_send,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.lower_has_replied ELSE pair.higher_has_replied
                           END AS sender_has_replied,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.higher_has_replied ELSE pair.lower_has_replied
                           END AS recipient_has_replied,
                           \(bind: policy.recipient.isActive)::boolean AS recipient_is_active,
                           \(bind: policy.blocked)::boolean AS blocked,
                           \(bind: policy.isFriend)::boolean AS is_friend,
                           \(bind: policy.allowsStrangers)::boolean AS allows_strangers,
                           \(bind: policy.sender.specialKind)::text AS sender_account_kind,
                           \(bind: policy.sender.specialStatus)::text AS sender_account_status,
                           \(bind: policy.sender.allowsServiceMessages)::boolean AS sender_allows_service_messages,
                           \(bind: policy.recipient.specialKind)::text AS recipient_account_kind,
                           \(bind: policy.recipient.specialStatus)::text AS recipient_account_status,
                           \(bind: policy.recipient.allowsCustomerMessages)::boolean AS recipient_allows_customer_messages
                    FROM direct_pair AS pair
                )
                """
        } else {
            senderActive = """
                EXISTS (
                    SELECT 1
                    FROM im_v2.public_user_profiles AS profile
                    WHERE profile.user_id = \(bind: senderID)
                      AND profile.state = 'active'
                      AND NOT EXISTS (
                          SELECT 1 FROM im_v2.account_disables AS disabled
                          WHERE disabled.user_id = profile.user_id
                      )
                )
                """
            policyCTEs = """
                direct_policy_versions AS MATERIALIZED (
                    SELECT pair.*, sender_version.revision AS sender_policy_revision,
                           recipient_version.revision AS recipient_policy_revision
                    FROM direct_pair AS pair
                    JOIN im_v2.user_direct_send_policy_versions AS sender_version
                      ON sender_version.user_id = \(bind: senderID)
                    JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                      ON recipient_version.user_id = pair.recipient_user_id
                    \(unsafeRaw: directPolicyVersionLockClause)
                ), special AS MATERIALIZED (
                    SELECT account.account_user_id, account.account_kind, account.status,
                           account.allows_customer_messages, account.allows_service_messages
                    FROM im_v2.special_accounts AS account
                    JOIN direct_policy_versions AS pair
                      ON account.account_user_id = \(bind: senderID)
                      OR account.account_user_id = pair.recipient_user_id
                    ORDER BY account.account_user_id
                    FOR KEY SHARE OF account
                ), direct_policy AS MATERIALIZED (
                    SELECT pair.recipient_user_id, pair.direct_policy_revision,
                           pair.sender_policy_revision, pair.recipient_policy_revision,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.lower_profile_visible_to_higher
                                ELSE pair.higher_profile_visible_to_lower
                           END AS sender_profile_visible_to_recipient,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.lower_can_send
                                ELSE pair.higher_can_send
                           END AS sender_can_send,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.lower_has_replied
                                ELSE pair.higher_has_replied
                           END AS sender_has_replied,
                           CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                          AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                          AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                          AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                                THEN \(bind: cachedDirectPolicy?.recipientIsActive)
                                ELSE EXISTS (
                               SELECT 1 FROM im_v2.public_user_profiles AS profile
                               WHERE profile.user_id = pair.recipient_user_id
                                 AND profile.state = 'active'
                                 AND NOT EXISTS (
                                     SELECT 1 FROM im_v2.account_disables AS disabled
                                     WHERE disabled.user_id = profile.user_id
                                 )
                           ) END AS recipient_is_active,
                           CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                          AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                          AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                          AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                                THEN \(bind: cachedDirectPolicy?.blocked)
                                ELSE EXISTS (
                               SELECT 1 FROM im_v2.user_blocks AS block
                               WHERE (block.blocker_user_id = pair.lower_user_id AND block.blocked_user_id = pair.higher_user_id)
                                  OR (block.blocker_user_id = pair.higher_user_id AND block.blocked_user_id = pair.lower_user_id)
                           ) END AS blocked,
                           CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                          AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                          AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                          AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                                THEN \(bind: cachedDirectPolicy?.isFriend)
                                ELSE EXISTS (
                               SELECT 1 FROM im_v2.user_relationships AS relationship
                               WHERE relationship.lower_user_id = pair.lower_user_id
                                 AND relationship.higher_user_id = pair.higher_user_id
                                 AND relationship.state = 'accepted'
                           ) END AS is_friend,
                           CASE WHEN pair.lower_user_id = \(bind: senderID)
                                THEN pair.higher_has_replied
                                ELSE pair.lower_has_replied
                           END AS recipient_has_replied,
                           CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                          AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                          AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                          AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                                THEN \(bind: cachedDirectPolicy?.allowsStrangers)
                                ELSE COALESCE((
                               SELECT preference.allows_stranger_messages
                               FROM im_v2.user_stranger_message_preferences AS preference
                               WHERE preference.user_id = pair.recipient_user_id
                           ), TRUE) END AS allows_strangers,
                           (SELECT account_kind FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_kind,
                           (SELECT status FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_status,
                           (SELECT allows_service_messages FROM special WHERE account_user_id = \(bind: senderID)) AS sender_allows_service_messages,
                           (SELECT account_kind FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_kind,
                           (SELECT status FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_status,
                           (SELECT allows_customer_messages FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_allows_customer_messages
                    FROM direct_policy_versions AS pair
                )
                """
        }
        let rows = try await sql.raw("""
            WITH locked_room AS MATERIALIZED (
                SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.capacity_class,
                       room.frozen_at,
                       room.room_id
                FROM im_v2.rooms AS room
                WHERE room.room_id = \(bind: roomID)
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT message.message_id AS prior_message_id,
                       message.room_id AS prior_room_id,
                       message.room_sequence AS prior_room_sequence,
                       message.timeline_sequence AS prior_timeline_sequence,
                       message.sender_user_id AS prior_sender_user_id,
                       message.client_message_id AS prior_client_message_id,
                       message.fingerprint_version AS prior_fingerprint_version,
                       message.request_fingerprint AS prior_request_fingerprint,
                       message.created_at AS prior_created_at,
                       message.event_id AS prior_source_event_id,
                       message.accepted_membership_revision AS prior_accepted_membership_revision,
                       message.direct_recipient_user_id AS prior_direct_recipient_user_id,
                       message.group_capacity_class AS prior_group_capacity_class
                FROM locked_room
                JOIN im_v2.message_send_completions AS message ON message.room_id = locked_room.room_id
                WHERE message.sender_user_id = \(bind: senderID)
                  AND message.client_message_id = \(bind: clientMessageID)
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (SELECT 1 FROM prior_operation)
            ), locked_actor AS MATERIALIZED (
                SELECT membership.role AS actor_role,
                       \(senderActive) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = \(bind: senderID)
                             AND mute.mute_until > \(bind: now)
                       ) AS muted
                FROM fresh_room AS room
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = \(bind: senderID)
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                FOR UPDATE OF membership
            ), direct_pair AS MATERIALIZED (
                SELECT pair.room_id, pair.lower_user_id, pair.higher_user_id,
                       pair.lower_profile_visible_to_higher,
                       pair.higher_profile_visible_to_lower,
                       pair.lower_can_send, pair.higher_can_send,
                       pair.lower_has_replied, pair.higher_has_replied,
                       pair.direct_policy_revision,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_user_id
                FROM fresh_room AS room
                CROSS JOIN locked_actor
                JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
                WHERE room.room_kind = 'direct'
                  AND (pair.lower_user_id = \(bind: senderID)
                       OR pair.higher_user_id = \(bind: senderID))
                \(unsafeRaw: directPairLockClause)
            ), \(policyCTEs)
            SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.capacity_profile_id, room.capacity_class, room.frozen_at,
                   prior.prior_message_id,
                   prior.prior_room_id, prior.prior_room_sequence,
                   prior.prior_timeline_sequence, prior.prior_sender_user_id,
                   prior.prior_client_message_id, prior.prior_fingerprint_version,
                   prior.prior_request_fingerprint,
                   prior.prior_created_at, prior.prior_source_event_id,
                   prior.prior_accepted_membership_revision,
                   prior.prior_direct_recipient_user_id,
                   prior.prior_group_capacity_class,
                   actor.actor_role, actor.sender_is_active, actor.muted,
                   policy.recipient_user_id, policy.sender_profile_visible_to_recipient,
                   policy.direct_policy_revision, policy.sender_policy_revision,
                   policy.recipient_policy_revision,
                   policy.sender_can_send, policy.recipient_is_active, policy.blocked,
                   policy.is_friend, policy.sender_has_replied,
                   policy.recipient_has_replied, policy.allows_strangers,
                   policy.sender_account_kind, policy.sender_account_status,
                   policy.sender_allows_service_messages, policy.recipient_account_kind,
                   policy.recipient_account_status, policy.recipient_allows_customer_messages
            FROM locked_room AS room
            LEFT JOIN prior_operation AS prior ON TRUE
            LEFT JOIN locked_actor AS actor ON TRUE
            LEFT JOIN direct_policy AS policy ON TRUE
            """).all(decoding: MessageAcceptanceContextRow.self)
        guard rows.count == 1, let row = rows.first else {
            throw rows.isEmpty ? V2RoomWriteStoreError.roomNotFound : V2RoomWriteStoreError.corruptPersistenceState
        }
        return row
    }
}

/// 发送预检 CTE 的单行结果。
///
/// `locked_room` 始终存在；
/// 其他分组都是可选的，因为在其持久结果已经存在之后，
/// 幂等重放不得再获取全新发送的锁或做出策略决定。
struct MessageAcceptanceContextRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    let frozenAt: Date?
    let priorMessageID: UUID?
    let priorRoomID: UUID?
    let priorRoomSequence: Int64?
    let priorTimelineSequence: Int64?
    let priorSenderUserID: UUID?
    let priorClientMessageID: UUID?
    let priorFingerprintVersion: Int16?
    let priorRequestFingerprint: Data?
    let priorCreatedAt: Date?
    let priorSourceEventID: UUID?
    let priorAcceptedMembershipRevision: Int64?
    let priorDirectRecipientUserID: UUID?
    let priorGroupCapacityClass: V2GroupCapacityClass?
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let recipientUserID: UUID?
    let directPolicyRevision: Int64?
    let senderPolicyRevision: Int64?
    let recipientPolicyRevision: Int64?
    let senderProfileVisibleToRecipient: Bool?
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

    enum CodingKeys: String, CodingKey {
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case capacityProfileID = "capacity_profile_id"
        case capacityClass = "capacity_class"
        case frozenAt = "frozen_at"
        case priorMessageID = "prior_message_id"
        case priorRoomID = "prior_room_id"
        case priorRoomSequence = "prior_room_sequence"
        case priorTimelineSequence = "prior_timeline_sequence"
        case priorSenderUserID = "prior_sender_user_id"
        case priorClientMessageID = "prior_client_message_id"
        case priorFingerprintVersion = "prior_fingerprint_version"
        case priorRequestFingerprint = "prior_request_fingerprint"
        case priorCreatedAt = "prior_created_at"
        case priorSourceEventID = "prior_source_event_id"
        case priorAcceptedMembershipRevision = "prior_accepted_membership_revision"
        case priorDirectRecipientUserID = "prior_direct_recipient_user_id"
        case priorGroupCapacityClass = "prior_group_capacity_class"

        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
        case recipientUserID = "recipient_user_id"
        case directPolicyRevision = "direct_policy_revision"
        case senderPolicyRevision = "sender_policy_revision"
        case recipientPolicyRevision = "recipient_policy_revision"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
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

    func existingOperation() throws -> ExistingMessageOperation? {
        guard let priorMessageID else {
            guard priorRoomID == nil,
                  priorRoomSequence == nil, priorTimelineSequence == nil,
                  priorSenderUserID == nil, priorClientMessageID == nil,
                  priorFingerprintVersion == nil, priorRequestFingerprint == nil,
                  priorCreatedAt == nil,
                  priorSourceEventID == nil, priorAcceptedMembershipRevision == nil,
                  priorDirectRecipientUserID == nil,
                  priorGroupCapacityClass == nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return nil
        }
        guard let priorRoomID, let priorTimelineSequence, let priorSenderUserID,
              let priorClientMessageID, let priorCreatedAt
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try MessageOperationReplayRow(
            messageID: priorMessageID,
            roomID: priorRoomID,
            roomSequence: priorRoomSequence,
            timelineSequence: priorTimelineSequence,
            senderUserID: priorSenderUserID,
            clientMessageID: priorClientMessageID,
            fingerprintVersion: priorFingerprintVersion,
            requestFingerprint: priorRequestFingerprint,
            createdAt: priorCreatedAt,
            sourceEventID: priorSourceEventID,
            acceptedMembershipRevision: priorAcceptedMembershipRevision,
            directRecipientUserID: priorDirectRecipientUserID,
            groupCapacityClass: priorGroupCapacityClass
        ).operation()
    }

    func directPolicySnapshot() throws -> DirectMessagePolicySnapshotRow {
        guard let recipientUserID, let senderProfileVisibleToRecipient,
              let recipientIsActive, let blocked, let isFriend,
              let senderHasReplied, let recipientHasReplied, let allowsStrangers
        else { throw V2RoomWriteStoreError.actorNotEligible }
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

    func directPolicyCacheEntry() -> V2DirectSendPolicyCache.Entry? {
        guard kind == "direct", let directPolicyRevision, let senderPolicyRevision,
              let recipientPolicyRevision, let senderIsActive,
              let policy = try? directPolicySnapshot() else { return nil }
        return policy.cacheEntry(directPairRevision: directPolicyRevision,
            senderPolicyRevision: senderPolicyRevision, recipientPolicyRevision: recipientPolicyRevision,
            senderIsActive: senderIsActive)
    }

}

enum ExistingMessageOperation {
    case accepted(V2MessageAcceptanceReceipt, V2SendMessageFingerprint)
}

struct MessageOperationReplayRow: Decodable {
    let messageID: UUID?
    let roomID: UUID
    let roomSequence: Int64?
    let timelineSequence: Int64
    let senderUserID: UUID
    let clientMessageID: UUID
    let fingerprintVersion: Int16?
    let requestFingerprint: Data?
    let createdAt: Date
    let sourceEventID: UUID?
    let acceptedMembershipRevision: Int64?
    let directRecipientUserID: UUID?
    let groupCapacityClass: V2GroupCapacityClass?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", roomID = "room_id"
        case roomSequence = "room_sequence", timelineSequence = "timeline_sequence"
        case senderUserID = "sender_user_id", clientMessageID = "client_message_id"
        case fingerprintVersion = "fingerprint_version", requestFingerprint = "request_fingerprint"
        case createdAt = "created_at", sourceEventID = "source_event_id"
        case acceptedMembershipRevision = "accepted_membership_revision"
        case directRecipientUserID = "direct_recipient_user_id"
        case groupCapacityClass = "group_capacity_class"
    }

    func operation() throws -> ExistingMessageOperation {
        guard let fingerprintVersion, let version = UInt16(exactly: fingerprintVersion),
              let requestFingerprint, let sourceEventID, timelineSequence > 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let fingerprint = try V2SendMessageFingerprint(version: version, digest: requestFingerprint)
        guard let messageID, let roomSequence, roomSequence > 0,
              let acceptedMembershipRevision, acceptedMembershipRevision >= 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .accepted(try .init(
            messageID: .init(uuid: messageID), roomID: .init(uuid: roomID),
            roomSequence: v2PersistenceUnsigned(roomSequence, invalid: V2RoomWriteStoreError.corruptPersistenceState), timelineSequence: v2PersistenceUnsigned(timelineSequence, invalid: V2RoomWriteStoreError.corruptPersistenceState),
            senderUserID: .init(uuid: senderUserID), clientMessageID: .init(uuid: clientMessageID),
            groupCapacityClass: groupCapacityClass,
            sourceEventID: .init(uuid: sourceEventID), acceptedMembershipRevision: v2PersistenceUnsigned(acceptedMembershipRevision, invalid: V2RoomWriteStoreError.corruptPersistenceState),
            directRecipientUserID: directRecipientUserID.map { .init(uuid: $0) }, createdAt: createdAt
        ), fingerprint)
    }
}
