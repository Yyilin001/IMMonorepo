import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// Process-local effects only. A borrowed operation transaction can decode its
/// provisional result, but cannot publish caches.
struct V2RoomWriteCommitEffects: Sendable {
    let ownership: V2RoomWriteTransactionOwnership
    let directSendPolicyCache: V2DirectSendPolicyCache
    let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache
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
        policyUpdates.reserveCapacity(committed.count)
        fastAppendUpdates.reserveCapacity(committed.count)
        reciprocalPolicyUpdates.reserveCapacity(committed.count)
        reciprocalFastAppendUpdates.reserveCapacity(committed.count)
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
        appendStageMetrics?.record(
            .cacheFinalization,
            duration: cacheFinalizationStartedAt.duration(to: .now)
        )

        return outcomes
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
