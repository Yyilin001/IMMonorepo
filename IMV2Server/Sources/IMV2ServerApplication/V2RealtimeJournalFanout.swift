import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts

/// An exact installed interest group; authority remains with the partition actor.
public struct V2RealtimeJournalRecipient: Equatable, Sendable {
    public let token: V2RealtimeShardToken
    public let session: V2RealtimeShardSession
    /// Trusted local coverage deadline; never reconstructed from publisher wire Date.
    public let deadline: ContinuousClock.Instant
    /// Wire interestGeneration binds the confirmed partition revision,
    /// not an individual topic generation. Exact topic generations are retained.
    public let interestGeneration: Int64
    public let interests: [V2RealtimeTopicKey: Int64]
    public var topics: Set<V2RealtimeTopicKey> { Set(interests.keys) }
    public init(token: V2RealtimeShardToken, session: V2RealtimeShardSession,
                interestGeneration: Int64, interests: [V2RealtimeTopicKey: Int64],
                deadline: ContinuousClock.Instant = .now + .seconds(30)) {
        self.token = token; self.session = session; self.deadline = deadline
        self.interestGeneration = interestGeneration; self.interests = interests
    }
}

/// Source ACK remains pending until every current recipient proves an actual
/// commit. Fast peers retain independent checkpoints while a slow peer retries.
/// No in-memory queue is treated as a durable responsibility handoff.
public actor V2RealtimeJournalFanout {
    public typealias Send = @Sendable (V2GatewayRealtimeDescriptor, V2RealtimeJournalProjectionBatch) async throws -> V2RealtimeJournalProjectionResult
    public typealias ColdSnapshot = @Sendable (V2RealtimeJournalRecipient, V2RealtimeJournalSource, V2RealtimeJournalProjectionFence, Int64) async throws -> V2RealtimeJournalProjectionApplied
    public typealias SourceIdentity = @Sendable (String) async throws -> V2RealtimeJournalSourceIdentity
    public typealias Recipients = @Sendable (Int) async -> [V2RealtimeJournalRecipient]
    public typealias IsCurrent = @Sendable (V2RealtimeJournalRecipient) async -> Bool
    private struct Key: Hashable {
        let source: V2RealtimeJournalSource
        let gateway: V2GatewayRealtimeIdentity
        let sessionID: UUID
        let revision: Int64
        let routingToken: UUID
        let sourceToken: UUID
        let sourceEpoch: Int64
    }
    private let send: Send
    private let coldSnapshot: ColdSnapshot
    private let sourceIdentity: SourceIdentity
    private let recipients: Recipients
    private let isCurrent: IsCurrent
    private let maximumItems: Int
    private let maximumBytes: Int
    private var checkpoints: [Key: Int64] = [:]
    private var flights: [Key: Task<Bool, Never>] = [:]
    private var peerCalls: [V2GatewayRealtimeIdentity: Int] = [:]
    private var closed = false
    private var operations = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(maximumItems: Int = 64, maximumPacketBytes: Int = 262_144,
                sourceIdentity: @escaping SourceIdentity, recipients: @escaping Recipients,
                isCurrent: @escaping IsCurrent, requestColdSnapshot: @escaping ColdSnapshot,
                send: @escaping Send) throws {
        guard (1...64).contains(maximumItems), maximumPacketBytes >= 16_384, maximumPacketBytes <= 262_144 else {
            throw V2RealtimeJournalError.invalidInput
        }
        self.maximumItems = maximumItems
        // Signed session/envelope metadata must also fit the actual packet cap.
        maximumBytes = maximumPacketBytes - 8_192
        self.sourceIdentity = sourceIdentity; self.recipients = recipients; self.isCurrent = isCurrent
        coldSnapshot = requestColdSnapshot; self.send = send
    }

    public func apply(sourceID: String, lease: V2RealtimePartitionLease,
                      batch: V2RealtimeJournalBatch) async throws -> V2RealtimeJournalApplyResult {
        guard !closed, (operations < 16), batch.partitionID == lease.partitionID else { throw V2RealtimeJournalError.authorityLost }
        operations += 1
        defer { operationFinished() }
        guard batch.entries.allSatisfy({ $0.topicKind == "roomEvents" || $0.topicKind == "userSync" }) else {
            throw V2RealtimeJournalError.invalidInput
        }
        let through = batch.requiresSnapshot ? batch.publishedThrough : (batch.entries.last?.sequence ?? batch.publishedThrough)
        let safe = try await fanout(sourceID: sourceID, lease: lease, control: batch, heads: nil, through: through)
        guard safe else { throw V2RealtimeJournalError.authorityLost }
        return .init(sourceID: sourceID, partitionID: lease.partitionID,
                     appliedThrough: through, snapshotInstalled: batch.requiresSnapshot)
    }

    public func applyHeads(sourceID: String, lease: V2RealtimePartitionLease,
                           heads: [V2RealtimeRoomHeadChange]) async throws -> Bool {
        guard !closed, (operations < 16), heads.count <= 128, heads.allSatisfy({ $0.partitionID == lease.partitionID }) else {
            throw V2RealtimeJournalError.invalidInput
        }
        operations += 1
        defer { operationFinished() }
        return try await fanout(sourceID: sourceID, lease: lease, control: nil, heads: heads, through: nil)
    }

    /// Best-effort online H delivery for one exact current Gateway binding.
    /// Success proves this RPC merged the heads, but never advances a journal,
    /// user ACK or source dirty-row revision. The caller owns latest-H retries.
    public func applyOnlineHeads(sourceID: String, lease: V2RealtimePartitionLease,
                                 recipient: V2RealtimeJournalRecipient,
                                 heads: [V2RealtimeRoomHeadChange]) async throws -> Bool {
        guard !closed, (operations < 16), heads.count <= 128,
              heads.allSatisfy({ $0.partitionID == lease.partitionID }), recipient.deadline > .now else {
            throw V2RealtimeJournalError.authorityLost
        }
        operations += 1
        defer { operationFinished() }
        let identity = try await sourceIdentity(sourceID)
        let source = V2RealtimeJournalSource(sourceID: sourceID, incarnationID: identity.databaseIncarnation,
                                            partitionID: lease.partitionID)
        return await deliver(source: source, lease: lease, recipient: recipient,
                             control: nil, heads: heads, through: nil)
    }

    /// Delivery-only entrypoint. The source responsibility already lives in SQL;
    /// this result may advance only this consumer's exact CAS checkpoint.
    public func applyConsumer(sourceID: String, lease: V2RealtimePartitionLease,
                              batch: V2RealtimeJournalConsumerBatch,
                              recipient: V2RealtimeJournalRecipient) async throws -> Int64 {
        guard !closed, (operations < 16), recipient.deadline > .now,
              batch.registration.key.gateway == recipient.session.gateway.identity,
              batch.registration.key.sessionID == recipient.session.sessionID,
              batch.registration.key.sessionRevision == recipient.interestGeneration,
              batch.registration.sessionGeneration == recipient.session.sessionGeneration,
              batch.registration.routingEpoch == recipient.token.epoch,
              batch.registration.routingToken == recipient.token.leaseToken,
              batch.registration.partitionID == recipient.token.partitionID,
              batch.journal.entries.allSatisfy({ $0.topicKind == "roomEvents" || $0.topicKind == "userSync" }) else {
            throw V2RealtimeJournalError.authorityLost
        }
        operations += 1
        defer { operationFinished() }
        let identity = try await sourceIdentity(sourceID)
        let source = V2RealtimeJournalSource(sourceID: sourceID, incarnationID: identity.databaseIncarnation, partitionID: lease.partitionID)
        let through = min(batch.offeredThrough,
            batch.journal.requiresSnapshot ? batch.journal.publishedThrough :
                (batch.journal.entries.last?.sequence ?? batch.journal.publishedThrough))
        let applied = await deliver(source: source, lease: lease, recipient: recipient,
            control: batch.journal, heads: batch.heads, through: through)
        guard applied else { throw V2RealtimeJournalError.authorityLost }
        let lane = key(source: source, lease: lease, recipient: recipient)
        return max(batch.controlCursor, checkpoints[lane] ?? through)
    }

    private func fanout(sourceID: String, lease: V2RealtimePartitionLease, control: V2RealtimeJournalBatch?,
                        heads: [V2RealtimeRoomHeadChange]?, through: Int64?) async throws -> Bool {
        try Task.checkCancellation()
        let identity = try await sourceIdentity(sourceID)
        let source = V2RealtimeJournalSource(sourceID: sourceID, incarnationID: identity.databaseIncarnation, partitionID: lease.partitionID)
        let selected = await recipients(lease.partitionID)
        guard !closed else { return false }
        let currentKeys = Set(selected.map { key(source: source, lease: lease, recipient: $0) })
        checkpoints = checkpoints.filter { $0.key.source != source || currentKeys.contains($0.key) || flights[$0.key] != nil }
        var allApplied = true
        await withTaskGroup(of: Bool.self) { group in
            var remaining = selected.makeIterator()
            func submit(_ recipient: V2RealtimeJournalRecipient) {
                group.addTask { await self.deliver(source: source, lease: lease, recipient: recipient,
                                                  control: control, heads: heads, through: through) }
            }
            for _ in 0..<min(16, selected.count) { if let next = remaining.next() { submit(next) } }
            while let applied = await group.next() {
                allApplied = allApplied && applied
                if let next = remaining.next() { submit(next) }
            }
        }
        // A newly installed session/revision cannot be hidden by the earlier
        // snapshot. Its cold cut must be proven on the next source replay.
        let after = await recipients(lease.partitionID)
        return !closed && allApplied && Set(after.map { key(source: source, lease: lease, recipient: $0) }).isSubset(of: currentKeys)
    }

    private func key(source: V2RealtimeJournalSource, lease: V2RealtimePartitionLease,
                     recipient: V2RealtimeJournalRecipient) -> Key {
        .init(source: source, gateway: recipient.session.gateway.identity, sessionID: recipient.session.sessionID,
              revision: recipient.interestGeneration, routingToken: recipient.token.leaseToken,
              sourceToken: lease.token, sourceEpoch: lease.epoch)
    }

    private func deliver(source: V2RealtimeJournalSource, lease: V2RealtimePartitionLease,
                         recipient: V2RealtimeJournalRecipient, control: V2RealtimeJournalBatch?,
                         heads: [V2RealtimeRoomHeadChange]?, through: Int64?) async -> Bool {
        guard recipient.deadline > .now, await isCurrent(recipient) else { return false } // retired interest no longer owns this ACK
        let lane = key(source: source, lease: lease, recipient: recipient)
        guard !closed, flights[lane] == nil, (flights.count < 16),
              (peerCalls[lane.gateway, default: 0] < 2),
              (checkpoints[lane] != nil || checkpoints.count < 4_096) else { return false }
        peerCalls[lane.gateway, default: 0] += 1
        let task = Task { await self.execute(lane: lane, source: source, lease: lease, recipient: recipient,
                                            control: control, heads: heads, through: through) }
        flights[lane] = task
        let success = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        flights.removeValue(forKey: lane)
        peerCalls[lane.gateway, default: 1] -= 1
        if peerCalls[lane.gateway] == 0 { peerCalls.removeValue(forKey: lane.gateway) }
        return success
    }

    private func execute(lane: Key, source: V2RealtimeJournalSource, lease: V2RealtimePartitionLease,
                         recipient: V2RealtimeJournalRecipient, control: V2RealtimeJournalBatch?,
                         heads: [V2RealtimeRoomHeadChange]?, through: Int64?) async -> Bool {
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: lease.identity.incarnationID,
            sourceLeaseEpoch: lease.epoch, sourceLeaseToken: lease.token,
            sourceLeaseExpiresAt: Date().addingTimeInterval(lease.remainingLeaseSeconds),
            routingPartitionEpoch: recipient.token.epoch, routingLeaseToken: recipient.token.leaseToken,
            sessionID: recipient.session.sessionID, interestGeneration: recipient.interestGeneration,
            gatewayIncarnationID: recipient.session.gateway.identity.incarnationID)
        do {
            try Task.checkCancellation()
            if let control, let through {
                let missingFloor = control.entries.first.map { $0.sequence - 1 } ?? through
                let opaque = control.entries.contains { entry in
                    if entry.topicKind == "userSync" { return entry.userControlVersion == nil }
                    return entry.ownerEpoch == nil || entry.roomControlVersion == nil
                }
                if control.requiresSnapshot || checkpoints[lane] == nil || checkpoints[lane]! < missingFloor || opaque {
                    try await establishCold(lane: lane, source: source, fence: fence, recipient: recipient, minimumCut: through)
                }
                if checkpoints[lane, default: 0] < through {
                    let entries = try control.entries.filter { $0.sequence > checkpoints[lane, default: 0] }.compactMap { entry -> V2RealtimeJournalProjectionEntry? in
                        let kind: V2RealtimeTopicKind = entry.topicKind == "userSync" ? .userSync : .roomEvents
                        guard recipient.topics.contains(.init(kind: kind, id: entry.topicID)) else { return nil }
                        guard let uuid = UUID(uuidString: entry.topicID) else { throw V2RealtimeJournalError.corruptPersistenceState }
                        if kind == .userSync {
                            guard let version = entry.userControlVersion, version > 0 else { throw V2RealtimeJournalError.corruptPersistenceState }
                            return .init(sequence: entry.sequence, change: .userControlInvalidation(userID: UserID(uuid: uuid),
                                controlVersion: UInt64(version), deviceID: entry.deviceID,
                                membershipRoomID: entry.membershipRoomID.map { RoomID(uuid: $0) }))
                        }
                        guard let epoch = entry.ownerEpoch, epoch >= 0,
                              let version = entry.roomControlVersion, version > 0 else { throw V2RealtimeJournalError.corruptPersistenceState }
                        return .init(sequence: entry.sequence, change: .controlInvalidation(roomID: RoomID(uuid: uuid),
                            ownerEpoch: UInt64(epoch), controlVersion: UInt64(version)))
                    }
                    try await sendControlRanges(entries, through: through, lane: lane, source: source, fence: fence, recipient: recipient)
                }
            }
            if let heads {
                if checkpoints[lane] == nil {
                    try await establishCold(lane: lane, source: source, fence: fence, recipient: recipient, minimumCut: 0)
                }
                let filtered = try heads.filter { recipient.topics.contains($0.topic) }.map { head -> V2RealtimeJournalRoomHead in
                    guard head.roomSequence >= 0, head.ownerEpoch >= 0, head.roomControlVersion >= 0 else { throw V2RealtimeJournalError.corruptPersistenceState }
                    return .init(roomID: RoomID(uuid: head.roomID), highWatermark: UInt64(head.roomSequence),
                                 ownerEpoch: UInt64(head.ownerEpoch), controlVersion: UInt64(head.roomControlVersion))
                }
                for chunk in try chunks(filtered) {
                    let batch = V2RealtimeJournalProjectionBatch(source: source, fence: fence, payload: .heads(chunk))
                    var result = try await send(recipient.session.gateway, batch)
                    if result == .snapshotRequired {
                        try await establishCold(lane: lane, source: source, fence: fence, recipient: recipient,
                                                minimumCut: checkpoints[lane, default: 0])
                        result = try await send(recipient.session.gateway, batch)
                    }
                    guard case .headsApplied(let applied) = result, applied.batchID == batch.batchID,
                          applied.source == source, applied.fence == fence else { return false }
                    try Task.checkCancellation()
                    guard !closed, recipient.deadline > .now, await isCurrent(recipient) else { return false }
                }
            }
            let stillCurrent = await isCurrent(recipient)
            return !closed && recipient.deadline > .now && !Task.isCancelled && stillCurrent
        } catch { return false }
    }

    private func establishCold(lane: Key, source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence,
                               recipient: V2RealtimeJournalRecipient, minimumCut: Int64) async throws {
        let result = try await coldSnapshot(recipient, source, fence, minimumCut)
        try Task.checkCancellation()
        guard !closed, recipient.deadline > .now, await isCurrent(recipient), result.source == source, result.fence == fence,
              result.snapshotInstalled, result.appliedThrough >= minimumCut else { throw V2RealtimeJournalError.authorityLost }
        checkpoints[lane] = result.appliedThrough
    }

    private func sendControlRanges(_ entries: [V2RealtimeJournalProjectionEntry], through: Int64, lane: Key,
                                   source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence,
                                   recipient: V2RealtimeJournalRecipient) async throws {
        let groups = try chunks(entries)
        let ranges = groups.isEmpty ? [[]] : groups
        for (index, chunk) in ranges.enumerated() {
            let end = index == ranges.count - 1 ? through : chunk.last!.sequence
            let batch = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
                payload: .changes(fromExclusive: checkpoints[lane, default: 0], throughInclusive: end, entries: chunk))
            let result = try await send(recipient.session.gateway, batch)
            if result == .snapshotRequired {
                try await establishCold(lane: lane, source: source, fence: fence, recipient: recipient, minimumCut: end)
                continue
            }
            guard case .applied(let applied) = result, applied.batchID == batch.batchID,
                  applied.source == source, applied.fence == fence, applied.appliedThrough == end,
                  !applied.snapshotInstalled else { throw V2RealtimeJournalError.authorityLost }
            try Task.checkCancellation()
            guard !closed, recipient.deadline > .now, await isCurrent(recipient) else { throw V2RealtimeJournalError.authorityLost }
            checkpoints[lane] = end
        }
    }

    private func chunks<T: Encodable>(_ items: [T]) throws -> [[T]] {
        var result: [[T]] = [], chunk: [T] = []
        for item in items {
            let candidate = chunk + [item]
            let encodedSize = V2ActorPayloadBudget.retainedBytes(of: candidate)
            if candidate.count > maximumItems || encodedSize > maximumBytes - 4_096 {
                guard !chunk.isEmpty else { throw V2RealtimeJournalError.invalidInput }
                result.append(chunk); chunk = [item]
                guard (V2ActorPayloadBudget.retainedBytes(of: chunk)) <= maximumBytes - 4_096 else { throw V2RealtimeJournalError.invalidInput }
            } else { chunk = candidate }
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    private func operationFinished() {
        operations -= 1
        if operations == 0 {
            let waiting = drainWaiters; drainWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }

    public func close() async {
        closed = true
        let active = Array(flights.values)
        for task in active { task.cancel() }
        for task in active { _ = await task.value }
        if operations > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
        checkpoints.removeAll()
    }
}
