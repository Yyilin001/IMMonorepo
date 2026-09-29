import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// Prepares the direct fast path without opening a transaction. Its returned
/// credits are settled by the Store after the owner transaction completes.
struct V2RoomWriteFastDirectPath: Sendable {
    let contentReviewMode: V2ContentReviewMode
    let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache
    let shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool?
    let roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool?
    let activationScope: V2RoomActivationWriteScope?
    let controlPolicyScope: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]?
    let controlScopeRoomKinds: [UUID: String]?
    let strangerMessagePolicy: V2StrangerMessagePolicy

    struct Prepared {
        let ordered: [FastPlainDirectRoomLogAppend]
        let lockRequests: [OrderedRoomWriteRequest]
        let cachedSnapshots: [V2DirectRoomLogFastAppendCache.Entry]
    }

    func prepare(
        requests: [V2RoomWriteRequest],
        knownIDs: [(roomID: UUID, senderID: UUID, cacheKey: V2DirectSendPolicyCache.Key)]
    ) async throws -> Prepared? {
        guard !requests.isEmpty,
              requests.count == knownIDs.count,
              !contentReviewMode.enqueuesJobs,
              let shardAdmissionCommandCreditPool
        else { return nil }

        // 此语句每个房间只推进一次游标。必须在获取任何进程内房间额度之前，
        // 拒绝包含同一房间多条请求的微批次；否则推测性获取可能覆盖预留记录，
        // 而同一房间的另一条请求仍持有执行中的令牌。既有顺序批处理路径会
        // 保留此场景的 FIFO 语义。
        guard Set(knownIDs.map(\.roomID)).count == knownIDs.count else {
            return nil
        }

        // 在预留任何进程内准入额度前，先判定全部缓存和请求形态条件。
        // 缓存命中与未命中混合的批次整体回退；若边遍历边获取额度，
        // 后续输入未命中时会泄漏此前已获取的令牌。
        var candidates: [FastPlainDirectRoomLogCandidate] = []
        candidates.reserveCapacity(requests.count)
        let cacheKeys = knownIDs.map {
            V2DirectRoomLogFastAppendCache.Key(
                roomID: $0.roomID,
                senderID: $0.senderID
            )
        }
        guard let cachedSnapshots = await directRoomLogFastAppendCache.valuesIfAllPresent(
            for: cacheKeys
        ) else {
            return nil
        }
        let roomCreditHints: [Bool]
        if let roomAdmissionCommandCreditPool {
            roomCreditHints = await roomAdmissionCommandCreditPool.shouldUseCredits(
                roomIDs: knownIDs.map(\.roomID),
                now: Date()
            )
        } else {
            roomCreditHints = Array(repeating: false, count: requests.count)
        }
        guard roomCreditHints.count == requests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        for (originalIndex, request) in requests.enumerated() {
            let identity = knownIDs[originalIndex]
            let cached = cachedSnapshots[originalIndex]
            let policy = try controlPolicy(roomID: identity.roomID, senderID: identity.senderID,
                recipientID: cached.policy.recipientID)
            let snapshot = V2DirectRoomLogFastAppendCache.Entry(
                policy: policy.map { cached.policy.applyingControlPolicy($0) } ?? cached.policy,
                roomShardID: cached.roomShardID, capacityProfileID: cached.capacityProfileID,
                membershipRevision: cached.membershipRevision, shardState: cached.shardState)
            guard V2RoomWriteFastDirectEligibility.acceptsBatchShape(request),
                  snapshot.capacityProfileID == request.capacityProfile.id,
                  V2RoomWriteFastDirectEligibility.acceptsSnapshot(snapshot.policy),
                  let lease = snapshot.shardState.lease,
                  lease.validUntil > request.now
            else {
                return nil
            }

            let usesRoomAdmissionCredits = roomCreditHints[originalIndex]
            candidates.append(.init(
                originalIndex: originalIndex,
                request: request,
                roomID: identity.roomID,
                senderID: identity.senderID,
                cacheKey: identity.cacheKey,
                snapshot: snapshot,
                requiresStrangerQuota: Self.requiresStrangerQuota(
                    snapshot.policy
                ),
                usesRoomAdmissionCredits: usesRoomAdmissionCredits
            ))
        }

        // 每层进程内准入只进入 Actor 一次。保持先房间、后分片的既有顺序，
        // 同时避免常见的热批次为每条消息创建两个串行执行器任务。
        var roomAcquisitions = Array<V2RoomAdmissionCommandCreditPool.Acquisition?>(
            repeating: nil,
            count: candidates.count
        )
        let roomCreditIndices = candidates.indices.filter {
            candidates[$0].usesRoomAdmissionCredits
        }
        if let roomAdmissionCommandCreditPool, !roomCreditIndices.isEmpty {
            let acquisitions = try await roomAdmissionCommandCreditPool.acquire(
                roomCreditIndices.map {
                    let candidate = candidates[$0]
                    return .init(
                        roomID: candidate.roomID,
                        shardState: candidate.snapshot.shardState,
                        now: candidate.request.now,
                        activation: try activationScope?.token(for: candidate.roomID)
                    )
                }
            )
            guard acquisitions.count == roomCreditIndices.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            for (index, acquisition) in zip(roomCreditIndices, acquisitions) {
                roomAcquisitions[index] = acquisition
            }
            guard acquisitions.allSatisfy({
                if case .granted = $0 { return true }
                return false
            }) else {
                let granted = zip(roomCreditIndices, acquisitions).compactMap {
                    index, acquisition -> (token: V2RoomAdmissionCommandCreditPool.Token, now: Date)? in
                    guard case .granted(let token) = acquisition else { return nil }
                    return (token, candidates[index].request.now)
                }
                await roomAdmissionCommandCreditPool.release(granted)
                return nil
            }
        }

        let shardAcquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition]
        do {
            shardAcquisitions = try await shardAdmissionCommandCreditPool.acquire(
                candidates.map { candidate in
                    .init(
                        roomShardID: candidate.snapshot.roomShardID,
                        capacityProfileID: candidate.snapshot.capacityProfileID,
                        shardState: candidate.snapshot.shardState,
                        now: candidate.request.now
                    )
                }
            )
        } catch {
            await releaseRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            throw error
        }
        guard shardAcquisitions.count == candidates.count else {
            await releaseRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard shardAcquisitions.allSatisfy({
            if case .granted = $0 { return true }
            return false
        }) else {
            let granted: [V2ShardAdmissionCommandCreditPool.Token] =
                shardAcquisitions.compactMap { acquisition in
                guard case .granted(let token, _) = acquisition else { return nil }
                return token
            }
            await shardAdmissionCommandCreditPool.release(granted, now: Date())
            await releaseRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            return nil
        }

        var prepared: [FastPlainDirectRoomLogAppend] = []
        prepared.reserveCapacity(candidates.count)
        for index in candidates.indices {
            let candidate = candidates[index]
            let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
            if case .granted(let token)? = roomAcquisitions[index] {
                roomCreditToken = token
            } else {
                roomCreditToken = nil
            }
            guard case .granted(let shardCreditToken, _) = shardAcquisitions[index] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            prepared.append(.init(
                originalIndex: candidate.originalIndex,
                request: candidate.request,
                roomID: candidate.roomID,
                senderID: candidate.senderID,
                cacheKey: candidate.cacheKey,
                snapshot: candidate.snapshot,
                requiresStrangerQuota: candidate.requiresStrangerQuota,
                usesRoomAdmissionCredits: candidate.usesRoomAdmissionCredits,
                roomCreditToken: roomCreditToken,
                shardCreditToken: shardCreditToken
            ))
        }

        let ordered = prepared.sorted { $0.roomID < $1.roomID }
        let lockRequests = ordered.enumerated().map { ordinal, append in
            OrderedRoomWriteRequest(
                originalIndex: append.originalIndex,
                request: append.request,
                roomID: append.roomID,
                senderID: append.senderID,
                cacheKey: append.cacheKey,
                cachedDirectPolicy: append.snapshot.policy,
                usesRoomAdmissionCredits: append.usesRoomAdmissionCredits,
                preflightOrdinal: ordinal
            )
        }

        return .init(ordered: ordered, lockRequests: lockRequests,
                     cachedSnapshots: cachedSnapshots)
    }

    /// Executes only after the Store acquired operation and owner locks on
    /// this borrowed SQL connection. It cannot commit or publish caches.
    func persist(_ prepared: Prepared, sql: any SQLDatabase) async throws -> [OrderedRoomWriteCommit] {
        let ordered = prepared.ordered
        let cachedSnapshots = prepared.cachedSnapshots
        let allocations = try await persistMessages(ordered, sql: sql)
        guard allocations.count == ordered.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try zip(ordered, allocations).enumerated().map {
            offset, pair in
            let (append, allocation) = pair
            guard allocation.ordinal == offset else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let draft = V2AcceptedMessageDraft(
                messageID: append.request.identifiers.messageID,
                roomID: append.request.command.roomID,
                roomSequence: try fastDirectUnsigned(allocation.roomSequence),
                timelineSequence: try fastDirectUnsigned(allocation.timelineSequence),
                senderUserID: append.request.command.senderUserID,
                clientMessageID: append.request.command.clientMessageID,
                text: append.request.command.text,
                entities: append.request.command.entities,

                createdAt: append.request.now
            )
            let accepted = draft.materialized(
                mediaPresentations: [],

                sourceEventID: append.request.identifiers.eventID,
                acceptedMembershipRevision: try fastDirectUnsigned(
                    append.snapshot.membershipRevision
                ),
                directRecipientUserID: try .init(
                    append.snapshot.policy.recipientID.uuidString
                )
            )
            return OrderedRoomWriteCommit(
                originalIndex: append.originalIndex,
                cacheKey: append.cacheKey,
                commit: .init(
                    outcome: .accepted(accepted),
                    // 映射得到的控制侧事实随外层事务失效。
                    // 共享缓存只保留原始的所有者快照。
                    directPolicyCacheUpdate: cachedSnapshots[append.originalIndex].policy,
                    directRoomLogFastAppendCacheUpdate: cachedSnapshots[append.originalIndex],
                    shardAdmissionCommandCredit: append.shardCreditToken,
                    roomAdmissionCommandCredit: append.roomCreditToken,
                    roomAdmissionHeatObservation: append.roomCreditToken == nil
                        && roomAdmissionCommandCreditPool != nil
                        ? append.roomID : nil
                )
            )
        }
    }

    func releaseCredits(
        _ appends: [FastPlainDirectRoomLogAppend],
        outcomeUnknown: Bool = false
    ) async {
        for append in appends {
            if outcomeUnknown {
                await shardAdmissionCommandCreditPool?.discard(append.shardCreditToken)
                if let token = append.roomCreditToken {
                    await roomAdmissionCommandCreditPool?.discard(token)
                }
                continue
            }
            if let shardAdmissionCommandCreditPool {
                await shardAdmissionCommandCreditPool.release(
                    append.shardCreditToken, now: append.request.now
                )
            }
            if let roomCreditToken = append.roomCreditToken,
               let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: append.request.now)
            }
        }
    }

    private func releaseRoomCredits(
        candidates: [FastPlainDirectRoomLogCandidate],
        acquisitions: [V2RoomAdmissionCommandCreditPool.Acquisition?]
    ) async {
        guard let roomAdmissionCommandCreditPool else { return }
        let granted = zip(candidates, acquisitions).compactMap {
            candidate, acquisition -> (token: V2RoomAdmissionCommandCreditPool.Token, now: Date)? in
            guard case .granted(let token)? = acquisition else { return nil }
            return (token, candidate.request.now)
        }
        await roomAdmissionCommandCreditPool.release(granted)
    }

    private func persistMessages(
        _ appends: [FastPlainDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws -> [FastPlainDirectRoomLogAllocationRow] {
        guard !appends.isEmpty,
              Set(appends.map(\.roomID)).count == appends.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        let inputs = try appends.map { append in
            try FastPlainDirectRoomLogAppendInput(append: append, strangerWindow: strangerMessagePolicy.window)
        }
        return try await FastPlainDirectRoomLogWritePath.persist(
            inputs: inputs,
            maximumStrangerMessages: strangerMessagePolicy.maximumMessagesPerWindow,
            sql: sql
        )
    }

    private func controlPolicy(roomID: UUID, senderID: UUID, recipientID: UUID? = nil) throws -> V2DirectSendControlPolicy? {
        guard let scope = controlPolicyScope else { return nil }
        if controlScopeRoomKinds?[roomID] == "group" { return nil }
        guard let policy = scope[.init(roomID: roomID, senderID: senderID)],
              policy.sender.userID == senderID,
              recipientID == nil || recipientID == policy.recipient.userID
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return policy
    }

    private static func requiresStrangerQuota(_ policy: V2DirectSendPolicyCache.Entry) -> Bool {
        !policy.isFriend && !policy.recipientHasReplied
    }
}

private func fastDirectUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
