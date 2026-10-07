import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// Prepares a locked direct-room append and writes policy, messages, then
/// projections on the connection borrowed from the Store transaction.
struct V2RoomWriteDirectBatchPath: Sendable {
    let strangerMessagePolicy: V2StrangerMessagePolicy

    /// 在所有受影响的房间、成员、单聊配对与策略行都已完成预检加锁之后，
    /// 完成权威持久追加。
    ///
    /// 让真正的微批与热房间单条路径共享它，
    /// 可以避免授权、投影或令牌收尾逻辑出现行为漂移。
    ///
    /// - Parameters:
    ///   - prepared: 已准备的单聊房间日志追加。
    ///   - sql: 参与当前事务的数据库连接。
    ///   - stageMetrics: 可选的阶段耗时记录器。
    /// - Returns: 各请求对应的有序提交结果。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    func complete(
        _ prepared: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase,
        stageMetrics: V2DirectRoomLogAppendStageMetrics? = nil,
        sendOperationMetrics: V2SendOperationBatchMetrics? = nil,
        combinedWrite: V2DurableOwnerCombinedWrite? = nil,
        prevalidatedDirectMemberships: Bool = false
    ) async throws -> [OrderedRoomWriteCommit] {
        guard !prepared.isEmpty else { return [] }
        let usesRuntimeState = prepared.allSatisfy { $0.input.runtimeGuard != nil }
        if !usesRuntimeState {
            let startedAt = ContinuousClock.now
            do {
                try await v2MeasureSendOperationStage(.ownerPolicy, metrics: sendOperationMetrics) {
                    try await persistPolicyMutations(prepared, sql: sql)
                }
            } catch {
                stageMetrics?.record(.policyMutations, duration: startedAt.duration(to: .now))
                throw error
            }
            stageMetrics?.record(.policyMutations, duration: startedAt.duration(to: .now))
        }

        let messageStartedAt = ContinuousClock.now
        do {
            try await v2MeasureSendOperationStage(.ownerMessagePersistence, metrics: sendOperationMetrics) {
                try await Self.persistMessages(
                    inputs: prepared.enumerated().map { ordinal, append in
                        append.input.withOrdinal(ordinal)
                    },
                    sql: sql, operationReceipts: try combinedWrite?.receipts(for: prepared),
                    prevalidatedDirectMemberships: prevalidatedDirectMemberships
                )
            }
        } catch {
            stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))
            throw error
        }
        stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))

        // Acquire room/admission write locks before pair mutations, matching the
        // legacy room->pair order. A failure still rolls back the entire append.
        if usesRuntimeState {
            let startedAt = ContinuousClock.now
            do {
                try await v2MeasureSendOperationStage(.ownerPolicy, metrics: sendOperationMetrics) {
                    try await persistPolicyMutations(prepared, sql: sql)
                }
            } catch {
                stageMetrics?.record(.policyMutations, duration: startedAt.duration(to: .now))
                throw error
            }
            stageMetrics?.record(.policyMutations, duration: startedAt.duration(to: .now))
        }

        let projectionStartedAt = ContinuousClock.now
        let projectionChanges: [DirectPostAcceptanceProjectionChanges]
        do {
            projectionChanges = try await v2MeasureSendOperationStage(.ownerProjection, metrics: sendOperationMetrics) {
                try await V2RoomWriteDirectProjectionPath.appendBatch(
                    for: prepared,
                    sql: sql
                )
            }
        } catch {
            stageMetrics?.record(
                .projectionPersistence,
                duration: projectionStartedAt.duration(to: .now)
            )
            throw error
        }
        stageMetrics?.record(
            .projectionPersistence,
            duration: projectionStartedAt.duration(to: .now)
        )
        guard projectionChanges.count == prepared.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return zip(prepared, projectionChanges).map { append, changes in
            let reciprocalReplyCacheUpdate = append.advancesReplyMarker
                ? DirectReplyCacheUpdate(
                    key: .init(
                        roomID: append.roomID,
                        senderID: append.directContext.recipientID
                    ),
                    expectedDirectPairRevision: append.policyCacheEntry.directPairRevision
                )
                : nil
            var cacheEntry = append.policyCacheEntry
            if append.advancesReplyMarker {
                cacheEntry = cacheEntry.markingSenderHasReplied()
            }
            cacheEntry = cacheEntry.applyingPostAcceptanceProjection(
                senderCapabilityInserted: changes.senderCapabilityInserted,
                recipientProfileInserted: changes.recipientProfileInserted
            )
            let fastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
            if V2RoomWriteFastDirectEligibility.isCacheCandidate(cacheEntry),
               let shardState = append.fastAppendShardState {
                fastAppendCacheUpdate = .init(
                    policy: cacheEntry,
                    roomShardID: append.fastAppendRoomShardID,
                    capacityProfileID: append.fastAppendCapacityProfileID,
                    membershipRevision: append.input.membershipRevision,
                    shardState: shardState
                )
            } else {
                fastAppendCacheUpdate = nil
            }
            return .init(
                originalIndex: append.originalIndex,
                cacheKey: append.cacheKey,
                commit: .init(
                    outcome: append.commit.outcome,
                    directPolicyCacheUpdate: append.publishesPolicyHints ? cacheEntry : nil,
                    directRoomLogFastAppendCacheUpdate: append.publishesPolicyHints ? fastAppendCacheUpdate : nil,
                    reciprocalDirectReplyCacheUpdate: append.publishesPolicyHints ? reciprocalReplyCacheUpdate : nil
                )
            )
        }
    }

    func plainRoomLogMessageInput(
        acceptedMessage: V2AcceptedMessageDraft,
        fingerprint: V2SendMessageFingerprint,
        eventID: EventID,
        commandWindowUsed: Int,
        room: RoomRow,
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        persistsRoomAdmission: Bool
    ) throws -> PlainRoomLogMessageInput {
        return try .init(
            ordinal: 0,
            roomID: roomID,
            messageID: try directBatchUUID(acceptedMessage.messageID),
            eventID: try directBatchUUID(eventID),
            senderID: senderID,
            clientMessageID: clientMessageID,
            persistsRoomAdmission: persistsRoomAdmission,
            roomSequence: try directBatchSigned(acceptedMessage.roomSequence),
            timelineSequence: try directBatchSigned(acceptedMessage.timelineSequence),
            commandWindowUsed: commandWindowUsed,
            text: acceptedMessage.text,
            entities: acceptedMessage.entities,
            replyToMessageID: nil,
            forwardedFromMessageID: nil,
            forwardedFromUserID: nil,
            membershipRevision: room.membershipRevision,
            fingerprint: fingerprint,
            createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(acceptedMessage.createdAt)
        )
    }

    /// 各准入路径已持有房间锁。独立于用户级投递工作检查固定的私聊关系。
    static func assertDirectMemberships(roomIDs: [UUID], sql: any SQLDatabase) async throws {
        let roomsJSON = try roomWriteJSON(Array(Set(roomIDs)).map { $0.uuidString })
        guard try await sql.raw("""
            SELECT 1 FROM im_v2.rooms AS room
            LEFT JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
            WHERE room.room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: roomsJSON)::jsonb))
              AND room.room_kind = 'direct'
              AND (pair.room_id IS NULL OR NOT COALESCE((
                  SELECT count(*) = 2 AND bool_and(member.user_id IN (pair.lower_user_id, pair.higher_user_id))
                  FROM (
                      SELECT user_id FROM im_v2.room_memberships
                      WHERE room_id = room.room_id AND joined_revision <= room.membership_revision
                        AND (left_revision IS NULL OR left_revision > room.membership_revision)
                      LIMIT 3
                  ) AS member
              ), FALSE))
            LIMIT 1
            """).first() == nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
    }

    /// 为一个房间、成员、配对与用户策略行均已由权威预检锁定的批次，
    /// 应用仅限单聊的可变策略效果。
    ///
    /// 每次变更都是集合式的，调用方会把部分影响行数视为不受支持的形态，
    /// 于是外层事务回滚，改由既有的逐命令路径在不丢配额的前提下决定各结果。
    ///
    /// - Parameters:
    ///   - appends: 已准备的单聊房间日志追加。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    private func persistPolicyMutations(
        _ appends: [PreparedDirectRoomLogAppend], sql: any SQLDatabase
    ) async throws {
        let inputs = appends.map { append in
            V2RoomWriteDirectBatchPolicy.Input(roomID: append.roomID, senderID: append.senderID,
                recipientID: append.directContext.recipientID, now: append.now,
                requiresStrangerQuota: append.directContext.requiresStrangerQuota,
                advancesReplyMarker: append.advancesReplyMarker)
        }
        try await V2RoomWriteDirectBatchPolicy(strangerMessagePolicy: strangerMessagePolicy).persist(inputs, sql: sql)
    }

    /// 用单条 PostgreSQL 语句持久化普通房间日志消息。
    ///
    /// 输入已按房间与到达序号排序。因此一个房间可能出现多次：
    /// 消息行会保留每个输入，
    /// 而房间/准入状态只根据该房间的最终输入更新一次。
    ///
    /// - Parameters:
    ///   - inputs: 本批普通房间日志消息输入。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    static func persistMessages(
        inputs: [PlainRoomLogMessageInput],
        sql: any SQLDatabase,
        operationReceipts: [V2DurableSendBatchPermanentReceipt]? = nil,
        prevalidatedDirectMemberships: Bool = false
    ) async throws {
        guard !inputs.isEmpty,
              Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count,
              inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        if !prevalidatedDirectMemberships {
            try await assertDirectMemberships(roomIDs: inputs.map(\.roomID), sql: sql)
        }
        try await PlainDirectRoomLogBatchWritePath.persist(inputs: inputs, sql: sql, operationReceipts: operationReceipts)
    }

}

private func directBatchUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}



private func directBatchSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}
