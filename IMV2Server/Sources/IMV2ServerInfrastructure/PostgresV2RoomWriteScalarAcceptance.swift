import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

// 仅在 Store 借用的事务中运行。事务仍由 Store 开启；
// Store 负责完成授权回执，并严格在提交后更新缓存。
struct V2RoomWriteScalarAcceptancePath {
    let ownerGuard: V2RoomWriteSelectedOwnerGuard
    let policyContext: V2RoomWriteDirectPolicyContext
    let strangerMessagePolicy: V2StrangerMessagePolicy
    let contentReviewMode: V2ContentReviewMode

    func acceptInTransaction(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        roomID: UUID,
        senderID: UUID,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        importedForward: ForwardInboxAuthorization? = nil,
        fenceContext: V2ConfiguredRoomFenceContext? = nil,
        deferShardAdmission: Bool = false,
        priorShardAdmissionReservations: [ShardAdmissionReservation] = [],
        sql: any SQLDatabase
    ) async throws -> RoomWriteCommit {
            let clientMessageID = try scalarAcceptanceUUID(command.clientMessageID)
            try await ownerGuard.acquireMessageOperationLock(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                sql: sql
            )
            let forwardSourceRoomID: UUID?
            if importedForward == nil, let expectedSource = ownerGuard.forwardOwnerSourceRoomID {
                guard command.forwardedFrom != nil, let ownerRoutes = ownerGuard.ownerRoutes else { throw V2RoomOwnerFenceError.ownerChanged }
                try await v2RequireForwardOwners(ownerRoutes, sql: sql)
                try await ownerGuard.activationScope?.require([expectedSource, roomID], sql: sql)
                forwardSourceRoomID = expectedSource
            } else if importedForward == nil, let forwarded = command.forwardedFrom {
                forwardSourceRoomID = try await v2LockForwardRooms(
                    sourceMessageID: scalarAcceptanceUUID(forwarded.messageID), targetRoomID: roomID, sql: sql
                )
            } else {
                forwardSourceRoomID = nil
            }
            if ownerGuard.forwardOwnerSourceRoomID == nil || ownerGuard.authorizationGrants != nil {
                if let fenceContext, let activationScope = ownerGuard.activationScope,
                   command.forwardedFrom == nil, importedForward == nil,
                   ownerGuard.forwardOwnerSourceRoomID == nil, ownerGuard.authorizationGrants == nil {
                    try await fenceContext.requireSelectedOwnersAndActivations(
                        roomIDs: [roomID], expectedRoutes: ownerGuard.ownerRoutes,
                        expectedKinds: ownerGuard.controlScopeRoomKinds, scope: activationScope)
                } else {
                    try await ownerGuard.requireSelectedOwners([roomID], sql: sql)
                }
            }
            let prepared = try await V2RoomWriteScalarPath.prepare(.init(
                command: command, roomID: roomID, senderID: senderID,
                clientMessageID: clientMessageID, capacityProfileID: capacityProfile.id,
                now: now, cachedDirectPolicy: cachedDirectPolicy,
                importedForward: importedForward,
                controlScopeRoomKinds: ownerGuard.controlScopeRoomKinds,
                leasedPolicy: ownerGuard.controlResolution.policyExecution?.snapshot.policy,
                leasedAccount: ownerGuard.controlResolution.policyExecution?.snapshot.account), sql: sql)
            let fresh: V2ScalarAcceptancePreparation.Fresh
            switch prepared {
            case .replay(let commit): return commit
            case .fresh(let value): fresh = value
            }
            let loadedContext = fresh.loaded
            let room = fresh.room
            let authorized = try V2RoomWriteScalarPath.admission(fresh)
            let actorIsActive = try policyContext.senderIsActive(authorized.senderIsActive,
                roomID: roomID, senderID: senderID)
            try await V2RoomWriteScalarPath.authorizeContent(fresh,
                admission: authorized, roomID: roomID,
                actorIsActive: actorIsActive, sql: sql)
            let directContext: DirectMessageAcceptanceContext?
            if room.kind == "direct" {
                let context = try policyContext.directMessageContext(from: loadedContext.directPolicySnapshot(), roomID: roomID, senderID: senderID)
                directContext = context
                if let restriction = context.restriction {
                    if V2SendSuccessMetadata.current.contains(where: {
                        $0.room == roomID && $0.sender == senderID && $0.operation == clientMessageID
                    }) {
                        // The rejected operation has no durable result. Its
                        // sender-only room hint is a separate presentation fact.
                        try await persistDirectRestrictionHint(
                            roomUUID: roomID, senderID: senderID,
                            clientMessageID: clientMessageID,
                            nextTimelineSequence: try roomWriteNextSequence(room.timelineSequence),
                            createdAt: now, reason: restriction,
                            currentCanSend: context.senderCanSend, sql: sql)
                        throw V2SendOperationResponseError.directPolicyDenied
                    }
                    let denied = try await persistDirectMessageDenied(
                        fingerprint: command.fingerprint,
                        roomID: command.roomID,
                        roomUUID: roomID,
                        senderID: senderID,
                        clientMessageID: clientMessageID,
                        sourceEventID: try scalarAcceptanceUUID(identifiers.eventID),
                        nextTimelineSequence: try roomWriteNextSequence(room.timelineSequence),
                        createdAt: now,
                        reason: restriction,
                        currentCanSend: context.senderCanSend,
                        sql: sql
                    )
                    return .init(outcome: .denied(denied))
                }
            } else {
                directContext = nil
            }
            try await assertMentionsAuthorized(command.mentions, roomID: roomID, membershipRevision: room.membershipRevision, senderID: senderID, sql: sql)
            let mediaPresentations = try await RoomWriteMediaAcceptance.presentations(
                command: command,
                importedForward: importedForward,
                forwardSourceRoomID: forwardSourceRoomID,
                senderID: senderID,
                now: now,
                sql: sql
            )
            try await assertReplyTarget(command.replyTo, roomID: roomID, actorID: senderID, sql: sql)
            let roomState = try V2RoomCommandState(roomID: command.roomID,
                nextRoomSequence: try roomWriteNextSequence(room.roomSequence),
                admission: .init(eligibleMemberCount: 0, commandWindow: try .init(limit: 0)))
            let shardState = try ShardAdmissionState(lease: nil)
            let shardStateForReduction = shardState
            let result: V2SendMessageAcceptanceResult
            // 房间日志是权威副本：不预留任何逐用户投递成本，被 @ 的成员只收到通知。
            result = try roomLogReduction(
                command: command,
                roomState: roomState,
                shardState: shardStateForReduction,
                profile: capacityProfile.limits,
                identifiers: identifiers,
                now: now
            )
            guard case .accepted(let writeSet) = result else {
                return .init(
                    outcome: result.outcome(
                        mediaPresentations: mediaPresentations,
                        groupCapacityClass: room.kind == "group" ? room.capacityClass : nil
                    )
                )
            }
            // 只在通用准入归约器接受后执行。容量拒绝会从此事务正常返回；
            // 若提前消耗陌生人额度窗口，即使没有消息被接受也会悄然损失配额。
            if let directContext, directContext.requiresStrangerQuota {
                try await consumeDirectMessageQuota(
                    senderID: senderID,
                    recipientID: directContext.recipientID,
                    policy: strangerMessagePolicy,
                    now: now,
                    sql: sql
                )
            }
            let loadedDirectPolicyCacheEntry = loadedContext.directPolicyCacheEntry()
            var updatedDirectPolicyCacheEntry = loadedDirectPolicyCacheEntry
            // 回复标记单调变化。发送者已有接受的消息后，后续每次发送
            // 不再执行无效果的 UPDATE。实际值取自事务快照，绝不取自进程内缓存。
            var replyMarkerAdvanced = false
            if let directContext, !directContext.senderHasReplied {
                replyMarkerAdvanced = try await markDirectSenderHasReplied(
                    roomID: roomID,
                    senderID: senderID,
                    sql: sql
                )
                if replyMarkerAdvanced {
                    updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?.markingSenderHasReplied()
                }
            }

            let timelineWriteSet = try roomWriteWithTimelineSequence(writeSet, timelineSequence: roomWriteNextSequence(room.timelineSequence))
            let acceptedMessage = timelineWriteSet.acceptedMessage.materialized(
                mediaPresentations: mediaPresentations,
                groupCapacityClass: room.kind == "group" ? room.capacityClass : nil,

                sourceEventID: timelineWriteSet.eventID,
                acceptedMembershipRevision: try scalarAcceptanceUnsigned(room.membershipRevision),
                directRecipientUserID: directContext.map { .init(uuid: $0.recipientID) },
                projectionCreatedAtUnixMilliseconds: try roomWriteProjectionMilliseconds(timelineWriteSet.acceptedMessage.createdAt)
            )
            let acceptedState = try V2MessageProjectionState(
                accepted: acceptedMessage,
                forwardedFromMessageID: command.forwardedFrom?.messageID,
                forwardedFromUserID: command.forwardedFrom?.senderUserID
            )
            let messageStateEventID = try scalarAcceptanceUUID(timelineWriteSet.eventID)
            let storedMessageState = try V2StoredMessageProjectionState(
                state: acceptedState,
                originEventID: messageStateEventID,
                stateEventID: messageStateEventID,
                createdAt: acceptedMessage.createdAt
            )
            try await V2RoomWriteScalarPersistencePath.persist(
                timelineWriteSet,
                command: command,
                mediaPresentations: mediaPresentations,
                messageProjectionState: storedMessageState,
                contentReviewMode: contentReviewMode,
                room: room,
                sql: sql
            )
            if let directContext,
               (!directContext.senderProfileVisibleToRecipient || directContext.senderCanSend != true || directContext.supportAccountID != nil) {
                let recipientID = directContext.recipientID
                let projectionChanges = try await V2RoomWriteDirectProjectionPath.appendSingle(
                    roomID: roomID,
                    senderID: senderID,
                    recipientID: recipientID,
                    senderProfileVisibleToRecipient: directContext.senderProfileVisibleToRecipient,
                    senderCanSend: directContext.senderCanSend,
                    sourceEventID: messageStateEventID,
                    createdAt: timelineWriteSet.acceptedMessage.createdAt,
                    stateVersion: timelineWriteSet.acceptedMessage.timelineSequence,
                    sql: sql
                )
                updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?
                    .applyingPostAcceptanceProjection(
                        senderCapabilityInserted: projectionChanges.senderCapabilityInserted,
                        recipientProfileInserted: projectionChanges.recipientProfileInserted
                    )
                if let supportAccountID = directContext.supportAccountID {
                    try await openSupportSessionIfNeeded(
                        roomID: roomID,
                        senderID: senderID,
                        supportAccountID: supportAccountID,
                        createdAt: timelineWriteSet.acceptedMessage.createdAt,
                        sql: sql
                    )
                }
            }
            let reciprocalReplyCacheUpdate: DirectReplyCacheUpdate?
            if replyMarkerAdvanced,
               let directContext,
               let loadedDirectPolicyCacheEntry {
                reciprocalReplyCacheUpdate = .init(
                    key: .init(
                        roomID: roomID,
                        senderID: directContext.recipientID
                    ),
                    expectedDirectPairRevision: loadedDirectPolicyCacheEntry.directPairRevision
                )
            } else {
                reciprocalReplyCacheUpdate = nil
            }
            return .init(
                outcome: .accepted(acceptedMessage),
                directPolicyCacheUpdate: updatedDirectPolicyCacheEntry,
                reciprocalDirectReplyCacheUpdate: reciprocalReplyCacheUpdate,
                shardAdmissionReservation: nil

            )
    }
}

extension V2RoomWriteScalarAcceptancePath {
    func consumeDirectMessageQuota(senderID: UUID, recipientID: UUID, policy: V2StrangerMessagePolicy, now: Date, sql: any SQLDatabase) async throws {
        let windowStart = try roomWriteStrangerWindowStart(now: now, interval: policy.window)
        let consumed = try await sql.raw("""
            INSERT INTO im_v2.stranger_message_windows (sender_user_id, recipient_user_id, window_started_at, message_count)
            VALUES (\(bind: senderID), \(bind: recipientID), \(bind: now), 1)
            ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
            SET window_started_at = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN EXCLUDED.window_started_at ELSE im_v2.stranger_message_windows.window_started_at END,
                message_count = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN 1 ELSE im_v2.stranger_message_windows.message_count + 1 END
            WHERE im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart)
               OR im_v2.stranger_message_windows.message_count < \(bind: policy.maximumMessagesPerWindow)
            RETURNING message_count
            """).first(decoding: DirectMessageWindowRow.self)
        guard consumed != nil else { throw V2RoomWriteStoreError.strangerMessageLimitReached }
    }

    /// 陌生人消息策略只需要知道对端是否曾经回复过。
    ///
    /// 把这个单调事实保存在已加锁的单聊配对上，
    /// 可以省去每次发送时的一次 `messages` 存在性扫描，同时不改变回复变得可见的时点：
    /// 该更新与已接受消息原子提交。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - senderID: 发送者标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 是否发生了首次回复状态迁移。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    @discardableResult
    func markDirectSenderHasReplied(
        roomID: UUID,
        senderID: UUID,
        sql: any SQLDatabase
    ) async throws -> Bool {
        let updated = try await sql.raw("""
            UPDATE im_v2.direct_room_pairs AS pair
            SET lower_has_replied = CASE
                    WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.lower_has_replied
                END,
                higher_has_replied = CASE
                    WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.higher_has_replied
                END,
                direct_policy_revision = pair.direct_policy_revision + 1
            WHERE pair.room_id = \(bind: roomID)
              AND pair.direct_policy_revision < \(bind: Int64.max)
              AND (pair.lower_user_id = \(bind: senderID)
                   OR pair.higher_user_id = \(bind: senderID))
              AND ((pair.lower_user_id = \(bind: senderID) AND NOT pair.lower_has_replied)
                   OR (pair.higher_user_id = \(bind: senderID) AND NOT pair.higher_has_replied))
            RETURNING pair.room_id
            """).first(decoding: DirectReplyMarkerMutationRow.self)
        // 加锁预检要求完成首次回复状态转换。若更新缺失，不能让已接受的消息
        // 带着过期的回复标记或策略修订号继续存在。
        guard updated != nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return true
    }

    /// Retain a sender-only restriction presentation without a durable rejected
    /// operation. The room's serialized transaction owns the capability change.
    func persistDirectRestrictionHint(
        roomUUID: UUID, senderID: UUID, clientMessageID: UUID,
        nextTimelineSequence: UInt64, createdAt: Date,
        reason: V2DirectMessageDenied.Reason, currentCanSend: Bool?,
        sql: any SQLDatabase
    ) async throws {
        let activityType = directMessageTimelineActivityType(for: reason)
        // Stable presentation identity deduplicates retries without freezing a
        // rejected operation's result. Separate attempted messages keep their
        // own hints, including messages submitted while the App is backgrounded.
        var bytes = Array(SHA256.hash(data: Data("v2-direct-restriction:v1:\(roomUUID.uuidString):\(senderID.uuidString):\(clientMessageID.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let sourceEventID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        if try await sql.raw("SELECT source_event_id FROM im_v2.room_timeline_activities WHERE source_event_id = \(bind: sourceEventID) AND room_id = \(bind: roomUUID) AND recipient_user_id = \(bind: senderID) LIMIT 1").first() != nil {
            return
        }
        let timelineSequence = try scalarAcceptanceSigned(nextTimelineSequence)
        let milliseconds = try v2GatewayMilliseconds(roomWritePersistedDate(createdAt))
        try await sql.raw("UPDATE im_v2.rooms SET timeline_sequence = \(bind: timelineSequence) WHERE room_id = \(bind: roomUUID)").run()
        try await sql.raw("INSERT INTO im_v2.room_timeline_activities (source_event_id, room_id, timeline_sequence, activity_type, recipient_user_id, created_at) VALUES (\(bind: sourceEventID), \(bind: roomUUID), \(bind: timelineSequence), \(bind: activityType), \(bind: senderID), \(bind: createdAt))").run()
        let payload = try JSONSerialization.data(withJSONObject: ["event_type": activityType, "room_id": roomUUID.uuidString, "timeline_sequence": timelineSequence, "server_created_at_ms": milliseconds])
        try await enqueuePrivateStateEvent(sourceRoomID: roomUUID, userID: senderID, sourceEventID: sourceEventID, projectionKind: "timeline_activity", payload: payload, createdAt: createdAt, sql: sql)
        try await appendDirectSendingCapabilityIfChanged(roomID: roomUUID,
            recipientID: senderID, sourceEventID: sourceEventID, canSend: false,
            currentCanSend: currentCanSend, createdAt: createdAt,
            createdAtMilliseconds: milliseconds, timelineSequence: timelineSequence, sql: sql)
    }

    /// Legacy scalar sends retain their original per-command denial identity.
    func persistDirectMessageDenied(
        fingerprint: V2SendMessageFingerprint,
        roomID: RoomID,
        roomUUID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        sourceEventID: UUID,
        nextTimelineSequence: UInt64,
        createdAt: Date,
        reason: V2DirectMessageDenied.Reason,
        currentCanSend: Bool?,
        sql: any SQLDatabase
    ) async throws -> V2DirectMessageDenied {
        // 保留下方原生 Date 绑定，但对外返回未来重放时会解码出的确切时间。
        // 重新绑定已解码的 Date 可能再次损失一微秒，因此响应规范化不能改动持久化值。
        let persistedCreatedAt = try roomWritePersistedDate(createdAt)
        let createdAtMilliseconds = try v2GatewayMilliseconds(persistedCreatedAt)
        let timelineSequence = try scalarAcceptanceSigned(nextTimelineSequence)
        let activityType = directMessageTimelineActivityType(for: reason)
        try await sql.raw("UPDATE im_v2.rooms SET timeline_sequence = \(bind: timelineSequence) WHERE room_id = \(bind: roomUUID)").run()
        // 拒绝记录引用其私有时间线活动。先插入被引用的事实；
        // 两条记录仍在外围消息事务中原子提交。
        try await sql.raw("INSERT INTO im_v2.room_timeline_activities (source_event_id, room_id, timeline_sequence, activity_type, recipient_user_id, created_at) VALUES (\(bind: sourceEventID), \(bind: roomUUID), \(bind: timelineSequence), \(bind: activityType), \(bind: senderID), \(bind: createdAt))").run()
        try await sql.raw("INSERT INTO im_v2.direct_message_denials (sender_user_id, client_message_id, room_id, source_event_id, timeline_sequence, created_at, reason, fingerprint_version, request_fingerprint) VALUES (\(bind: senderID), \(bind: clientMessageID), \(bind: roomUUID), \(bind: sourceEventID), \(bind: timelineSequence), \(bind: createdAt), \(bind: reason.rawValue), \(bind: Int16(fingerprint.version)), \(bind: fingerprint.digest))").run()
        let activityPayload = try JSONSerialization.data(withJSONObject: ["event_type": activityType, "room_id": roomUUID.uuidString, "timeline_sequence": timelineSequence, "server_created_at_ms": createdAtMilliseconds])
        try await enqueuePrivateStateEvent(sourceRoomID: roomUUID, userID: senderID, sourceEventID: sourceEventID, projectionKind: "timeline_activity", payload: activityPayload, createdAt: createdAt, sql: sql)
        try await appendDirectSendingCapabilityIfChanged(
            roomID: roomUUID,
            recipientID: senderID,
            sourceEventID: sourceEventID,
            canSend: false,
            currentCanSend: currentCanSend,
            createdAt: createdAt,
            createdAtMilliseconds: createdAtMilliseconds,
            timelineSequence: timelineSequence,
            sql: sql
        )
        return .init(roomID: roomID, sourceEventID: .init(uuid: sourceEventID), timelineSequence: nextTimelineSequence, createdAt: persistedCreatedAt, reason: reason)
    }

    /// 公开的拒绝原因刻意隐藏了究竟是拉黑、陌生人偏好还是失活的特殊账号导致了拒绝。
    ///
    /// 私有时间线仍使用 SQLite 消费、PostgreSQL 约束的稳定投影词汇表。
    ///
    /// - Parameter reason: 私有拒绝原因。
    /// - Returns: 稳定的时间线活动类型字符串。
    private func directMessageTimelineActivityType(for reason: V2DirectMessageDenied.Reason) -> String {
        switch reason {
        case .generic:
            "direct_message_restricted"
        case .systemAccountReadOnly:
            "system_account_read_only"
        }
    }

    private func appendDirectSendingCapabilityIfChanged(
        roomID: UUID,
        recipientID: UUID,
        sourceEventID: UUID,
        canSend: Bool,
        currentCanSend: Bool?,
        createdAt: Date,
        createdAtMilliseconds: Int64,
        timelineSequence: Int64,
        sql: any SQLDatabase
    ) async throws {
        guard currentCanSend != canSend else { return }
        guard let mutation = try await sql.raw("""
            WITH event_insert AS (
                INSERT INTO im_v2.user_state_event_outbox
                    (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
                VALUES (\(bind: recipientID), \(bind: sourceEventID), 'direct_sending_capability',
                        jsonb_build_object('room_id', \(bind: roomID.uuidString),
                                           'can_send', \(bind: canSend),
                                           'state_version', \(bind: timelineSequence),
                                           'updated_at_ms', \(bind: createdAtMilliseconds)),
                        \(bind: createdAt), \(bind: createdAt), \(bind: roomID))
                RETURNING user_id
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND EXISTS (SELECT 1 FROM event_insert)
                RETURNING pair.room_id
            )
            SELECT (SELECT count(*) FROM event_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectCapabilityMutationRow.self),
              mutation.insertedCount == 1,
              mutation.pairCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// 客户的首条已接受消息会在与消息相同的事务中创建服务会话。
    ///
    /// 重试消息会复用该房间行；
    /// 而已关闭的会话刻意不会被一次过期的重复操作重新打开。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - senderID: 客户用户标识。
    ///   - supportAccountID: 客服账号标识。
    ///   - createdAt: 会话创建时间。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 写入失败时抛出。
    func openSupportSessionIfNeeded(roomID: UUID, senderID: UUID, supportAccountID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("INSERT INTO im_v2.support_conversation_sessions (room_id, support_account_user_id, customer_user_id, state, opened_at, last_activity_at, closed_at) VALUES (\(bind: roomID), \(bind: supportAccountID), \(bind: senderID), 'open', \(bind: createdAt), \(bind: createdAt), NULL) ON CONFLICT (room_id) DO UPDATE SET last_activity_at = EXCLUDED.last_activity_at, state = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN 'open' ELSE im_v2.support_conversation_sessions.state END, closed_at = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN NULL ELSE im_v2.support_conversation_sessions.closed_at END").run()
    }

    private func enqueuePrivateStateEvent(sourceRoomID: UUID, userID: UUID, sourceEventID: UUID, projectionKind: String, payload: Data, createdAt: Date, sql: any SQLDatabase) async throws {
        guard let kind = V2UserStateEventKind(rawValue: projectionKind) else {
            throw V2UserStateEventError.invalidEvent
        }
        let event = try V2UserStateEvent(sourceEventID: .init(uuid: sourceEventID),
            userID: .init(uuid: userID), kind: kind, payload: payload, createdAt: createdAt)
        guard let transaction = sql as? any Database else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await PostgresV2UserStateEventOutbox(database: transaction).enqueue(event, sourceRoomID: .init(uuid: sourceRoomID), in: sql)
    }

    func assertMentionsAuthorized(_ mentions: [V2MentionTarget], roomID: UUID, membershipRevision: Int64, senderID: UUID, sql: any SQLDatabase) async throws {
        guard !mentions.isEmpty else { return }
        guard mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2MentionValidationError.invalidTargetSet }
        guard let sender = try await sql.raw("""
            SELECT role
            FROM im_v2.room_memberships
            WHERE room_id = \(bind: roomID) AND user_id = \(bind: senderID)
              AND joined_revision <= \(bind: membershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: membershipRevision))
            FOR UPDATE
            """).first(decoding: MentionSenderMembershipRow.self),
              let role = V2RoomMembershipRole(rawValue: sender.role)
        else { throw V2RoomWriteStoreError.actorNotEligible }

        var mentionedUserIDs: [UUID] = []
        for target in mentions {
            guard case .user(let userID) = target else { continue }
            mentionedUserIDs.append(try scalarAcceptanceUUID(userID))
        }
        let rows: [MentionMembershipRow]
        if mentionedUserIDs.isEmpty {
            rows = []
        } else {
            let targetJSON = try mentionTargetJSON(mentionedUserIDs)
            rows = try await sql.raw("""
                WITH targets AS (
                    SELECT value::uuid AS user_id
                    FROM jsonb_array_elements_text(\(bind: targetJSON)::jsonb) AS value
                )
                SELECT membership.user_id,
                       NOT EXISTS (
                         SELECT 1 FROM im_v2.user_blocks AS blocks
                         WHERE (blocks.blocker_user_id = \(bind: senderID) AND blocks.blocked_user_id = membership.user_id)
                            OR (blocks.blocker_user_id = membership.user_id AND blocks.blocked_user_id = \(bind: senderID))
                       ) AS mentionable
                FROM targets
                JOIN im_v2.room_memberships AS membership
                  ON membership.user_id = targets.user_id
                WHERE membership.room_id = \(bind: roomID)
                  AND membership.joined_revision <= \(bind: membershipRevision)
                  AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: membershipRevision))
                FOR UPDATE OF membership
                """).all(decoding: MentionMembershipRow.self)
        }
        let visibility = V2MentionVisibility(
            senderRole: role,
            visibleActiveUsers: Set(try rows.map { try UserID($0.userID.uuidString) }),
            mentionableUsers: Set(try rows.filter(\.mentionable).map { try UserID($0.userID.uuidString) })
        )
        try V2MentionAuthorization.authorize(mentions, visibility: visibility, limits: .init(maximumTargets: V2MessageCommandLimits.maxMentions))
    }

    func assertReplyTarget(_ replyTo: V2MessageReplyReference?, roomID: UUID, actorID: UUID, sql: any SQLDatabase) async throws {
        guard let replyTo else { return }
        guard let targetID = UUID(uuidString: replyTo.messageID.rawValue),
              (try await sql.raw("""
                  SELECT EXISTS (
                      SELECT 1 FROM im_v2.messages AS message
                      JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                      WHERE message.message_id = \(bind: targetID)
                        AND message.room_id = \(bind: roomID)
                        AND message.withdrawn_at IS NULL
                        AND (\(v2ForwardSourceVisibility(actorID: actorID)))
                  ) AS authorized
                  """).first(decoding: AuthorizationRow.self)?.authorized ?? false)
        else { throw V2RoomWriteStoreError.replyTargetNotFound }
    }
}

struct V2RoomWriteSelectedOwnerGuard {
    let ownerSelection: V2RoomWriteOwnerSelection
    let controlResolution: V2RoomWriteControlResolution

    var ownerRoutes: [UUID: V2RoomShardRoute]? { ownerSelection.routes }
    var activationScope: V2RoomActivationWriteScope? { ownerSelection.activation }
    var forwardOwnerSourceRoomID: UUID? { ownerSelection.forwardSource }
    var authorizationGrants: [String: V2DirectAuthorizationGrant]? { controlResolution.authorization?.grants }
    var controlScopeRoomKinds: [UUID: String]? { controlResolution.roomKinds }

    func acquireMessageOperationLock(roomID: UUID, senderID: UUID, clientMessageID: UUID,
                                     sql: any SQLDatabase) async throws {
        if activationScope?.reliesOnRuntimeLifecycle != true {
            try await v2AcquireMessageOperationLock(roomID: roomID, senderID: senderID,
                clientMessageID: clientMessageID, sql: sql)
        }
        try await prepareAuthorization(roomID: roomID, senderID: senderID,
            clientMessageID: clientMessageID, sql: sql)
    }

    func prepareAuthorization(roomID: UUID, senderID: UUID, clientMessageID: UUID, sql: any SQLDatabase) async throws {
        if let execution = controlResolution.policyExecution {
            guard let activationScope, try activationScope.token(for: roomID) == execution.activation else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            try await execution.requireActive(roomID: roomID, senderID: senderID, clientMessageID: clientMessageID, sql: sql)
            return
        }
        guard let grants = authorizationGrants else { return }
        if controlScopeRoomKinds?[roomID] == "group" { return }
        let key = scalarAuthorizationOperationKey(roomID: roomID, senderID: senderID, clientMessageID: clientMessageID)
        guard let grant = grants[key], let transaction = sql as? any Database else {
            throw V2DirectAuthorizationIntentError.identityConflict
        }
        let prior = try await PostgresV2DirectAuthorizationReceiptStore().checkAttempt(grant.attempt, transaction: transaction)
        guard prior?.disposition != .aborted else { throw V2DirectAuthorizationReceiptError.attemptAborted }
    }

    /// 校验给定房间的归属路由均已选定。
    ///
    /// 操作锁必须先于本查询取得。`NO KEY UPDATE` 在围栏任期/分片更新的同时，
    /// 保持与既有追加/外键锁兼容。加锁后读取当前归属，拒绝过期路由。
    ///
    /// - Parameters:
    ///   - roomIDs: 待校验归属的房间标识。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 存在未选定归属的房间时抛出。
    func requireSelectedOwners(_ roomIDs: [UUID], sql: any SQLDatabase) async throws {
        if let scope = activationScope, scope.reliesOnRuntimeLifecycle {
            for room in Set(roomIDs) { _ = try scope.token(for: room) }
            return
        }
        let rooms = Set(roomIDs)
        if let ownerRoutes, !rooms.allSatisfy({ ownerRoutes[$0] != nil }) {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let requested = try roomWriteJSON(rooms.map(\.uuidString))
        let rows = try await sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_kind FROM im_v2.rooms
            WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: requested)::jsonb))
            ORDER BY room_id FOR NO KEY UPDATE
            """).all(decoding: SelectedRoomOwnerRow.self)
        if let kinds = controlScopeRoomKinds {
            guard rows.allSatisfy({ kinds[$0.roomID] == nil || kinds[$0.roomID] == $0.kind }) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }
        if let ownerRoutes {
            guard rows.count == rooms.count, rows.allSatisfy({ row in
                guard let expected = ownerRoutes[row.roomID] else { return false }
                return expected.shardID == row.shardID && expected.epoch == row.epoch
            }) else { throw V2RoomOwnerFenceError.ownerChanged }
        }
        try await activationScope?.require(roomIDs, sql: sql)
        if let execution = controlResolution.policyExecution {
            let target = execution.activation.roomID.uuidValue!
            var permitted = Set([target])
            if let source = forwardOwnerSourceRoomID { permitted.insert(source) }
            guard rooms.isSubset(of: permitted), rooms.contains(target), let activationScope,
                  try activationScope.token(for: execution.activation.roomID.uuidValue!) == execution.activation,
                  rows.contains(where: { $0.roomID == target && $0.epoch == execution.activation.owner.epoch
                      && $0.shardID == execution.activation.owner.shardID }) else {
                throw V2RoomOwnerFenceError.ownerChanged
            }
        }
        if let grants = authorizationGrants {
            guard let transaction = sql as? any Database else { throw V2DirectAuthorizationIntentError.corruptPersistence }
            for key in grants.keys.sorted() {
                guard let grant = grants[key], rooms.contains(grant.attempt.roomID) else { continue }
                let prior = try await PostgresV2DirectAuthorizationReceiptStore().prepare(grant.attempt, transaction: transaction)
                guard prior?.disposition != .aborted else { throw V2DirectAuthorizationReceiptError.attemptAborted }
            }
        }
        // 没有选定路由时，缺失房间沿用接受路径的普通领域错误。
    }

}

private func scalarAuthorizationOperationKey(roomID: UUID, senderID: UUID, clientMessageID: UUID) -> String {
    [roomID, senderID, clientMessageID].map { $0.uuidString.lowercased() }.joined(separator: ":")
}

private func scalarAcceptanceSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}

private func scalarAcceptanceUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func scalarAcceptanceUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
