import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// Prepares a locked direct-room append and writes policy, messages, then
/// projections on the connection borrowed from the Store transaction.
struct V2RoomWriteDirectBatchPath: Sendable {
    let policyContext: V2RoomWriteDirectPolicyContext
    let activationScope: V2RoomActivationWriteScope?
    let strangerMessagePolicy: V2StrangerMessagePolicy
    let roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool?
    let shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool?

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
        stageMetrics: V2DirectRoomLogAppendStageMetrics? = nil
    ) async throws -> [OrderedRoomWriteCommit] {
        guard !prepared.isEmpty else { return [] }
        let policyStartedAt = ContinuousClock.now
        do {
            try await persistPolicyMutations(prepared, sql: sql)
        } catch {
            stageMetrics?.record(.policyMutations, duration: policyStartedAt.duration(to: .now))
            throw error
        }
        stageMetrics?.record(.policyMutations, duration: policyStartedAt.duration(to: .now))

        let messageStartedAt = ContinuousClock.now
        do {
            try await Self.persistMessages(
                inputs: prepared.enumerated().map { ordinal, append in
                    append.input.withOrdinal(ordinal)
                },
                sql: sql
            )
        } catch {
            stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))
            throw error
        }
        stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))

        let projectionStartedAt = ContinuousClock.now
        let projectionChanges: [DirectPostAcceptanceProjectionChanges]
        do {
            projectionChanges = try await V2RoomWriteDirectProjectionPath.appendBatch(
                for: prepared,
                sql: sql
            )
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
        // 分片额度和可选的房间额度已在开启事务前预扣。
        // 持有这些房间锁期间，不会再次从池中获取额度或进行第二次预留。
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
                    directPolicyCacheUpdate: cacheEntry,
                    directRoomLogFastAppendCacheUpdate: fastAppendCacheUpdate,
                    reciprocalDirectReplyCacheUpdate: reciprocalReplyCacheUpdate,
                    shardAdmissionCommandCredit: append.commit.shardAdmissionCommandCredit,
                    roomAdmissionCommandCredit: append.commit.roomAdmissionCommandCredit,
                    roomAdmissionHeatObservation: append.commit.roomAdmissionHeatObservation
                )
            )
        }
    }

    func prepare(
        _ item: OrderedRoomWriteRequest,
        preflight: PlainDirectRoomLogBatchPreflightRow,
        sequenceOffset: Int64 = 0,
        shardCreditAcquisition: V2ShardAdmissionCommandCreditPool.Acquisition? = nil
    ) async throws -> DirectRoomLogBatchPreparation {
        let request = item.request
        let command = request.command
        let clientMessageID = try directBatchUUID(command.clientMessageID)
        guard preflight.ordinal == item.preflightOrdinal else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        let room = try preflight.room.advancingSequences(by: sequenceOffset)
        if let reason = directRoomLogAdmissionMismatchReason(
            room: room,
            request: request
        ) {
            throw V2AtomicRoomWriteBatchError(reason: reason)
        }
        let usesRoomAdmissionCredits = item.usesRoomAdmissionCredits
        // 与激活绑定的额度必须在此事务前预取。
        // 实时热路径在 fastPlainDirectRoomLogCommitsIfEligible 中完成预取；
        // 标准路径则传入 usesRoomAdmissionCredits = false。
        guard activationScope == nil || !usesRoomAdmissionCredits else {
            throw V2AtomicRoomWriteBatchError(reason: .roomCreditModeMismatch)
        }
        let shard: ShardRow
        let roomCommandWindowUsed: Int
        if usesRoomAdmissionCredits {
            shard = try preflight.shard()
            guard try policyContext.senderIsActive(preflight.senderIsActive, roomID: item.roomID, senderID: item.senderID),
                  let role = preflight.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  preflight.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
            roomCommandWindowUsed = 0
        } else {
            let admissionSnapshot = try preflight.admissionSnapshot()
            let admission = admissionSnapshot.room
            shard = admissionSnapshot.shard
            guard admission.shardLeaseID == shard.leaseID,
                  admission.shardLeaseGeneration == shard.generation,
                  try policyContext.senderIsActive(admissionSnapshot.senderIsActive, roomID: item.roomID, senderID: item.senderID),
                  let role = admissionSnapshot.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  admissionSnapshot.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
            roomCommandWindowUsed = admission.commandWindowUsed
        }
        let directContext = try policyContext.directMessageContext(from: preflight.directPolicySnapshot(), roomID: item.roomID, senderID: item.senderID)
        guard directContext.restriction == nil,
              directContext.supportAccountID == nil
        else {
            throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
        }

        let shardState = try shard.admissionState()
        let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
        if let roomAdmissionCommandCreditPool, usesRoomAdmissionCredits {
            switch try await roomAdmissionCommandCreditPool.acquire(
                roomID: item.roomID,
                shardState: shardState,
                now: request.now
            ) {
            case .granted(let token):
                roomCreditToken = token
            case .rateLimited:
                return .outcome(.init(
                    outcome: .rateLimited(retryAfterSeconds: request.capacityProfile.limits.retryAfterSeconds)
                ))
            case .unavailable(let reason):
                return .outcome(.init(outcome: .unavailable(reason)))
            }
        } else {
            roomCreditToken = nil
        }
        let shardStateForReduction: ShardAdmissionState
        let shardCreditToken: V2ShardAdmissionCommandCreditPool.Token?
        guard let shardPool = shardAdmissionCommandCreditPool else {
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        let acquisition: V2ShardAdmissionCommandCreditPool.Acquisition
        if let shardCreditAcquisition {
            acquisition = shardCreditAcquisition
        } else {
            acquisition = try await shardPool.acquire(
                roomShardID: room.roomShardID,
                capacityProfileID: room.capacityProfileID,
                shardState: shardState,
                now: request.now
            )
        }
        switch acquisition {
        case .granted(let token, let effectiveShardState):
            shardCreditToken = token
            shardStateForReduction = effectiveShardState
        case .rateLimited:
            if let roomCreditToken, let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
            }
            return .outcome(.init(
                outcome: .rateLimited(retryAfterSeconds: request.capacityProfile.limits.retryAfterSeconds)
            ))
        case .unavailable(let reason):
            if let roomCreditToken, let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
            }
            return .outcome(.init(outcome: .unavailable(reason)))
        }
        do {
            let writeSet: PlainDirectRoomLogWriteSet
            if usesRoomAdmissionCredits {
                switch try directRoomLogPrechargedCommandBatchReduction(
                    command: command,
                    nextRoomSequence: roomWriteNextSequence(room.roomSequence),
                    shardState: shardStateForReduction,
                    profile: request.capacityProfile.limits,
                    identifiers: request.identifiers,
                    now: request.now
                ) {
                case .accepted(let transaction):
                    writeSet = .init(
                        acceptedMessage: transaction.acceptedMessage,
                        eventID: transaction.eventID,
                        nextShardState: transaction.nextShardState,
                        roomCommandWindowUsed: roomCommandWindowUsed
                    )
                case .rateLimited(let retryAfterSeconds):
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    if let roomCreditToken, let roomAdmissionCommandCreditPool {
                        await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: .rateLimited(retryAfterSeconds: retryAfterSeconds)
                    ))
                case .unavailable(let reason):
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    if let roomCreditToken, let roomAdmissionCommandCreditPool {
                        await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: .unavailable(reason)
                    ))
                }
            } else {
                let admission = try preflight.admissionSnapshot().room
                let roomState = try room.commandState(roomID: command.roomID, admission: admission)
                let result = try roomLogReduction(
                    command: command,
                    roomState: roomState,
                    shardState: shardStateForReduction,
                    profile: request.capacityProfile.limits,
                    identifiers: request.identifiers,
                    now: request.now
                )
                guard case .accepted(let transaction) = result else {
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: result.outcome()
                    ))
                }
                writeSet = .init(
                    acceptedMessage: transaction.acceptedMessage,
                    eventID: transaction.eventID,
                    nextShardState: transaction.nextShardState,
                    roomCommandWindowUsed: roomCommandWindowUsed
                )
            }
            let timelineMessage = try roomWriteWithTimelineSequence(
                writeSet.acceptedMessage,
                timelineSequence: roomWriteNextSequence(room.timelineSequence)
            )
            let shardReservation = try roomWriteShardAdmissionReservation(
                from: shardStateForReduction,
                to: writeSet.nextShardState
            )
            guard shardReservation.commandDelta == 1
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let acceptedMessage = timelineMessage.materialized(
                mediaPresentations: [],

                sourceEventID: writeSet.eventID,
                acceptedMembershipRevision: try directBatchUnsigned(room.membershipRevision),
                directRecipientUserID: .init(uuid: directContext.recipientID)
            )
            let input = try plainRoomLogMessageInput(
                acceptedMessage: timelineMessage,
                fingerprint: request.command.fingerprint,
                eventID: writeSet.eventID,
                commandWindowUsed: writeSet.roomCommandWindowUsed,
                room: room,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: clientMessageID,
                persistsRoomAdmission: !usesRoomAdmissionCredits
            )
            return .append(.init(
                originalIndex: item.originalIndex,
                request: request,
                cacheKey: item.cacheKey,
                roomID: item.roomID,
                senderID: item.senderID,
                input: input,
                now: request.now,
                directContext: directContext,
                policyCacheEntry: try preflight.directPolicyCacheEntry(),
                advancesReplyMarker: !directContext.senderHasReplied,
                fastAppendRoomShardID: room.roomShardID,
                fastAppendCapacityProfileID: room.capacityProfileID,
                fastAppendShardState: writeSet.nextShardState,
                commit: .init(
                    outcome: .accepted(acceptedMessage),
                    directPolicyCacheUpdate: nil,
                    shardAdmissionCommandCredit: shardCreditToken,
                    roomAdmissionCommandCredit: roomCreditToken,
                    roomAdmissionHeatObservation: usesRoomAdmissionCredits ? nil : item.roomID
                )
            ))
        } catch {
            if let shardCreditToken, let shardAdmissionCommandCreditPool {
                await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
            }
            if let roomCreditToken, let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
            }
            throw error
        }
    }

    private func directRoomLogAdmissionMismatchReason(
        room: RoomRow,
        request: V2RoomWriteRequest
    ) -> V2AtomicRoomWriteBatchError.Reason? {
        guard room.kind == "direct" else { return .roomKindMismatch }
        guard room.capacityProfileID == request.capacityProfile.id else {
            return .capacityProfileMismatch
        }
        guard room.frozenAt == nil else { return .roomFrozen }
        return nil
    }

    /// 同房间批次只有在所有单聊配对生产者标记都已建立、
    /// 且房间准入已经由持久额度表示之后才是安全的。
    ///
    /// 这使「每房间一行」的集合追加免于触发陌生人配额、首次回复、
    /// 资料/能力或房间准入等尚未在此建模逐命令顺序的可变效果。
    ///
    /// 该批次仍会锁定权威配对、成员、策略版本与房间行。
    /// 这是一种收窄的有序追加优化，而不是基于缓存的授权捷径。
    ///
    /// - Parameter orderedRequests: 本批有序写入请求。
    /// - Throws: 不满足同房间批次安全前提时抛出。
    private func assertSameRoomBatchSafety(
        orderedRequests: [OrderedRoomWriteRequest],
        contexts: [PlainDirectRoomLogBatchPreflightRow]
    ) throws {
        guard orderedRequests.count == contexts.count else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        let indicesByRoom = Dictionary(grouping: orderedRequests.indices) {
            orderedRequests[$0].roomID
        }
        for indices in indicesByRoom.values where indices.count > 1 {
            guard indices.allSatisfy({ orderedRequests[$0].usesRoomAdmissionCredits }),
                  try indices.allSatisfy({
                      let policy = try contexts[$0].directPolicySnapshot()
                      return policy.senderHasReplied
                          && policy.senderProfileVisibleToRecipient
                          && policy.senderCanSend == true
                  })
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
        }
    }

    private func plainRoomLogMessageInput(
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
        sql: any SQLDatabase
    ) async throws {
        guard !inputs.isEmpty,
              Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count,
              inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await assertDirectMemberships(roomIDs: inputs.map(\.roomID), sql: sql)
        try await PlainDirectRoomLogBatchWritePath.persist(inputs: inputs, sql: sql)
    }

}

enum DirectRoomLogBatchPreparation {
    case append(PreparedDirectRoomLogAppend)
    case outcome(RoomWriteCommit)
}

/// 普通单聊房间日志快速路径使用的最小已接受事件材料。
///
/// 对预扣费房间，持久房间额度由独立的信用池维护；其余请求仍写入房间准入行。
private struct PlainDirectRoomLogWriteSet {
    let acceptedMessage: V2AcceptedMessageDraft
    let eventID: EventID
    let nextShardState: ShardAdmissionState
    let roomCommandWindowUsed: Int
}


private func directBatchUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func directBatchUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}

private func directBatchSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}

/// 单聊房间日志投递的受众固定为两人，且不会创建扇出计划或未完成工作预留。
///
/// 其命令预算已由分片额度池持久预扣；
/// 在选用旧版每房间策略时，也由房间额度池预扣。
/// 因此这次归并只推进批量规范消息插入所需的房间序号与分片快照。
///
/// 授权刻意留在此辅助函数之外，
/// 并在归并之前由 `PostgresV2RoomWriteStore.accept` 依据已锁定的房间、成员、
/// 单聊配对、策略版本与陌生人配额状态持续校验。
///
/// - Parameters:
///   - command: 发送消息命令。
///   - roomState: 房间命令状态。
///   - admission: 分片准入状态。
///   - now: 服务端统一授时时刻。
/// - Returns: 归并结果。
/// - Throws: 状态非法或序号溢出时抛出。
private func directRoomLogPrechargedCommandBatchReduction(
    command: V2SendMessageCommand,
    nextRoomSequence: UInt64,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    now: Date
) throws -> DirectRoomLogPrechargedCommandReductionResult {
    guard let lease = shardState.lease else { return .unavailable(.missingShardLease) }
    guard lease.isValid(at: now) else { return .unavailable(.expiredShardLease) }
    guard lease.commandWindow.canReserve(1) else {
        return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds)
    }

    let nextLease = try ShardAdmissionLease(
        id: lease.id,
        generation: lease.generation,
        validUntil: lease.validUntil,
        commandWindow: lease.commandWindow.reserving(1))
    let nextShard = try ShardAdmissionState(
        lease: nextLease)
    let accepted = V2AcceptedMessageDraft(
        messageID: identifiers.messageID,
        roomID: command.roomID,
        roomSequence: nextRoomSequence,
        senderUserID: command.senderUserID,
        clientMessageID: command.clientMessageID,
        text: command.text,
        media: command.media,
        mentions: command.mentions,
        entities: command.entities,
        replyTo: command.replyTo,
        createdAt: now
    )
    return .accepted(.init(
        acceptedMessage: accepted,
        eventID: identifiers.eventID,
        nextShardState: nextShard
    ))
}

/// 已预扣费的热路径由房间信用池持有准入计数，事务只需保留消息与分片结果。
private enum DirectRoomLogPrechargedCommandReductionResult {
    case accepted(DirectRoomLogPrechargedCommandWriteSet)
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2CommandAdmissionUnavailableReason)
}

private struct DirectRoomLogPrechargedCommandWriteSet {
    let acceptedMessage: V2AcceptedMessageDraft
    let eventID: EventID
    let nextShardState: ShardAdmissionState
}
