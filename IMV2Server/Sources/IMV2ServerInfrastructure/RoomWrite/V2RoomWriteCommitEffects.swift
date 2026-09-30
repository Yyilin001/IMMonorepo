import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// Process-local effects only. A borrowed operation transaction can decode its
/// provisional result, but cannot publish caches or consume committed credits.
struct V2RoomWriteCommitEffects: Sendable {
    let ownership: V2RoomWriteTransactionOwnership
    let directSendPolicyCache: V2DirectSendPolicyCache
    let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache
    let shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool?
    let roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool?
    let appendStageMetrics: V2DirectRoomLogAppendStageMetrics?

    func finalize(
        command: V2SendMessageCommand,
        cacheKey: V2DirectSendPolicyCache.Key,
        commit: RoomWriteCommit
    ) async throws -> V2SendMessageOutcome {
        let outcome = try roomWritePersistedAcceptanceOutcome(commit.outcome)
        // The bound operation still owns the surrounding transaction. Its receipt
        // insert can fail, so no process cache may observe this provisional write.
        if ownership.borrowsTransaction {
            return outcome
        }
        let cacheStartedAt = ContinuousClock.now
        if let entry = commit.directPolicyCacheUpdate {
            await directSendPolicyCache.insert(entry, for: cacheKey)
        }
        if let entry = commit.directRoomLogFastAppendCacheUpdate {
            await directRoomLogFastAppendCache.insert(entry, for: .init(
                roomID: cacheKey.roomID, senderID: cacheKey.senderID
            ))
        }
        if let update = commit.reciprocalDirectReplyCacheUpdate {
            await directSendPolicyCache.markRecipientsHaveReplied([.init(
                key: update.key,
                expectedDirectPairRevision: update.expectedDirectPairRevision
            )])
            await directRoomLogFastAppendCache.markRecipientsHaveReplied([.init(
                key: .init(roomID: update.key.roomID, senderID: update.key.senderID),
                expectedDirectPairRevision: update.expectedDirectPairRevision
            )])
        }
        if let shardCreditToken = commit.shardAdmissionCommandCredit,
           let shardAdmissionCommandCreditPool {
            await shardAdmissionCommandCreditPool.commit(shardCreditToken)
        }
        if let roomCreditToken = commit.roomAdmissionCommandCredit,
           let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.commit(roomCreditToken)
        }
        if let roomID = commit.roomAdmissionHeatObservation,
           let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.recordNormalAdmissionCommit(
                roomID: roomID,
                now: Date()
            )
        }
        appendStageMetrics?.record(
            .cacheFinalization,
            duration: cacheStartedAt.duration(to: .now)
        )
        return outcome
    }

    func finalize(
        requests: [V2RoomWriteRequest],
        committed: [OrderedRoomWriteCommit]
    ) async throws -> [V2SendMessageOutcome] {
        let outcomes = try orderedOutcomes(requests: requests, committed: committed)
        if ownership.borrowsTransaction {
            return outcomes
        }
        let cacheFinalizationStartedAt = ContinuousClock.now

        var policyUpdates: [V2DirectSendPolicyCache.Update] = []
        var fastAppendUpdates: [V2DirectRoomLogFastAppendCache.Update] = []
        var reciprocalPolicyUpdates: [V2DirectSendPolicyCache.RecipientReplyUpdate] = []
        var reciprocalFastAppendUpdates: [V2DirectRoomLogFastAppendCache.RecipientReplyUpdate] = []
        var shardTokens: [V2ShardAdmissionCommandCreditPool.Token] = []
        var roomTokens: [V2RoomAdmissionCommandCreditPool.Token] = []
        var heatObservations: [(UUID, Date)] = []
        policyUpdates.reserveCapacity(committed.count)
        fastAppendUpdates.reserveCapacity(committed.count)
        reciprocalPolicyUpdates.reserveCapacity(committed.count)
        reciprocalFastAppendUpdates.reserveCapacity(committed.count)
        shardTokens.reserveCapacity(committed.count)
        roomTokens.reserveCapacity(committed.count)
        heatObservations.reserveCapacity(committed.count)
        // 准入热度属于进程内运行时状态，因此必须像原先逐次提交的收尾逻辑一样
        // 使用运行时时钟。请求时间戳可能是确定生成或重放的，不能用于判断缓存新鲜度。
        let heatObservationNow = Date()

        for item in committed {
            guard requests.indices.contains(item.originalIndex) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if let entry = item.commit.directPolicyCacheUpdate {
                policyUpdates.append(.init(entry: entry, key: item.cacheKey))
            }
            if let entry = item.commit.directRoomLogFastAppendCacheUpdate {
                fastAppendUpdates.append(.init(
                    entry: entry,
                    key: .init(roomID: item.cacheKey.roomID, senderID: item.cacheKey.senderID)
                ))
            }
            if let update = item.commit.reciprocalDirectReplyCacheUpdate {
                reciprocalPolicyUpdates.append(.init(
                    key: update.key,
                    expectedDirectPairRevision: update.expectedDirectPairRevision
                ))
                reciprocalFastAppendUpdates.append(.init(
                    key: .init(roomID: update.key.roomID, senderID: update.key.senderID),
                    expectedDirectPairRevision: update.expectedDirectPairRevision
                ))
            }
            if let token = item.commit.shardAdmissionCommandCredit {
                shardTokens.append(token)
            }
            if let token = item.commit.roomAdmissionCommandCredit {
                roomTokens.append(token)
            }
            if let roomID = item.commit.roomAdmissionHeatObservation {
                heatObservations.append((roomID, heatObservationNow))
            }
        }

        // 这些修改只是 Actor 隔离的少量字典和计数器更新。
        // 每个 Actor 批量调用一次，比每个 PostgreSQL 微批次创建四个子任务
        // 成本更低且更可预测。
        await directSendPolicyCache.insert(policyUpdates)
        await directRoomLogFastAppendCache.insert(fastAppendUpdates)
        await directSendPolicyCache.markRecipientsHaveReplied(reciprocalPolicyUpdates)
        await directRoomLogFastAppendCache.markRecipientsHaveReplied(
            reciprocalFastAppendUpdates
        )
        if let shardAdmissionCommandCreditPool {
            await shardAdmissionCommandCreditPool.commit(shardTokens)
        }
        if let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.commit(roomTokens)
            await roomAdmissionCommandCreditPool.recordNormalAdmissionCommits(heatObservations)
        }
        appendStageMetrics?.record(
            .cacheFinalization,
            duration: cacheFinalizationStartedAt.duration(to: .now)
        )

        return outcomes
    }

    /// Hybrid batches have already consumed their durable shard reservation when
    /// SQL commits. Retire those tokens even if response conversion later fails;
    /// a malformed response must never make committed capacity reusable.
    func finalizeHybridBatch(
        requests: [V2RoomWriteRequest],
        committed: [OrderedRoomWriteCommit],
        shardTokens: [V2ShardAdmissionCommandCreditPool.Token]
    ) async throws -> [V2SendMessageOutcome] {
        guard !ownership.borrowsTransaction, let shardAdmissionCommandCreditPool else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        await shardAdmissionCommandCreditPool.commit(shardTokens)
        return try orderedOutcomes(requests: requests, committed: committed)
    }

    private func orderedOutcomes(requests: [V2RoomWriteRequest], committed: [OrderedRoomWriteCommit]) throws -> [V2SendMessageOutcome] {
        guard committed.count == requests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        var outcomes = Array<V2SendMessageOutcome?>(repeating: nil, count: requests.count)
        for item in committed {
            guard requests.indices.contains(item.originalIndex) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            outcomes[item.originalIndex] = try roomWritePersistedAcceptanceOutcome(item.commit.outcome)
        }
        guard outcomes.allSatisfy({ $0 != nil }) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return outcomes.compactMap { $0 }
    }

}
