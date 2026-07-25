import Foundation
import Vapor

actor RealtimeDeliveryAsyncDispatcher {
    typealias RelayHandler = @Sendable ([ConversationRealtimeConsumer.DomainEventPayloadBatch], UUID?) async -> Void
    typealias ReliableRelayHandler = @Sendable ([ConversationRealtimeConsumer.DomainEventPayloadBatch], UUID?) async throws -> Void

    enum CoalescingScope: Hashable, Sendable {
        case defaultScope
        case activeCompactHint

        var keepsLatestPayloadPerRecipient: Bool {
            switch self {
            case .activeCompactHint:
                return true
            case .defaultScope:
                return false
            }
        }
    }

    private struct CoalescingKey: Hashable, Sendable {
        let id: UUID
        let scope: CoalescingScope
    }

    private struct CoalescedDispatch: Sendable {
        var payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch]
        var requestID: UUID?
        var scheduled: Bool
    }

    private struct SlotStats: Sendable {
        let waitMilliseconds: Int
        let inFlight: Int
        let queuedWaiters: Int
    }

    private struct RecipientLatestMergeResult: Sendable {
        var payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch]
        var droppedPayloadBatchCount: Int
        var droppedRecipientDeliveryCount: Int
    }

    private struct RecipientLatestAssignment: Sendable {
        let payload: IMTCPChatDomainEventPayload
        let fanoutIntent: IMGatewayDomainEventFanoutIntent
        let sourceIndex: Int
    }

    private let app: Application
    private let maxInFlight: Int
    private let maxQueued: Int
    private let relayHandler: RelayHandler
    private let reliableRelayHandler: ReliableRelayHandler
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var coalescedDispatches: [CoalescingKey: CoalescedDispatch] = [:]

    init(
        app: Application,
        maxInFlight: Int,
        maxQueued: Int = 1024,
        relayHandler: RelayHandler? = nil,
        reliableRelayHandler: ReliableRelayHandler? = nil
    ) {
        self.app = app
        self.maxInFlight = max(1, maxInFlight)
        self.maxQueued = max(0, maxQueued)
        self.relayHandler = relayHandler ?? { batches, requestID in
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                batches.map { payloadBatch in
                    IMGatewayDomainEventPayloadBatch(
                        payload: payloadBatch.payload,
                        recipientUserIDs: payloadBatch.recipientUserIDs,
                        fanoutIntent: payloadBatch.fanoutIntent
                    )
                },
                requestID: requestID
            )
        }
        self.reliableRelayHandler = reliableRelayHandler ?? { batches, requestID in
            try await app.gatewaySessionService.sendDomainEventPayloadBatchesReliably(
                batches.map { payloadBatch in
                    IMGatewayDomainEventPayloadBatch(
                        payload: payloadBatch.payload,
                        recipientUserIDs: payloadBatch.recipientUserIDs,
                        fanoutIntent: payloadBatch.fanoutIntent
                    )
                },
                requestID: requestID
            )
        }
    }

    func dispatch(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?,
        coalescingKey: UUID? = nil,
        coalescingScope: CoalescingScope = .defaultScope,
        coalescingWindowMilliseconds: Int = 0
    ) async {
        let payloadBatches = deliveries.map { delivery in
            ConversationRealtimeConsumer.DomainEventPayloadBatch(
                payload: delivery.payload,
                recipientUserIDs: [delivery.ownerUserID]
            )
        }
        await dispatchPayloadBatches(
            payloadBatches,
            requestID: requestID,
            coalescingKey: coalescingKey,
            coalescingScope: coalescingScope,
            coalescingWindowMilliseconds: coalescingWindowMilliseconds
        )
    }

    func dispatchPayloadBatches(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?,
        coalescingKey: UUID? = nil,
        coalescingScope: CoalescingScope = .defaultScope,
        coalescingWindowMilliseconds: Int = 0
    ) async {
        guard !payloadBatches.isEmpty else { return }
        if let coalescingKey, coalescingWindowMilliseconds > 0 {
            await coalesce(
                payloadBatches,
                requestID: requestID,
                key: CoalescingKey(id: coalescingKey, scope: coalescingScope),
                windowMilliseconds: coalescingWindowMilliseconds
            )
            return
        }

        await dispatchNow(payloadBatches, requestID: requestID)
    }

    /// Delivers non-coalesced realtime payloads from a durable source stream.
    /// A failure means the gateway handoff was not persisted and lets the
    /// caller retain its Kafka offset for retry.
    func dispatchPayloadBatchesReliably(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?
    ) async throws {
        guard !payloadBatches.isEmpty else { return }
        try await dispatchNowReliably(payloadBatches, requestID: requestID)
    }

    private func coalesce(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?,
        key: CoalescingKey,
        windowMilliseconds: Int
    ) async {
        let wasScheduled: Bool
        if var pending = coalescedDispatches[key] {
            wasScheduled = pending.scheduled
            if key.scope.keepsLatestPayloadPerRecipient {
                let mergeResult = mergeLatestPayloadPerRecipient(
                    pending: pending.payloadBatches,
                    replacement: payloadBatches
                )
                pending.payloadBatches = mergeResult.payloadBatches
                pending.requestID = requestID
                pending.scheduled = true
                coalescedDispatches[key] = pending
                if mergeResult.droppedPayloadBatchCount > 0 || mergeResult.droppedRecipientDeliveryCount > 0 {
                    await app.routingMetrics.recordRealtimeCoalescedDispatchReplacement(
                        droppedPayloadBatchCount: mergeResult.droppedPayloadBatchCount,
                        droppedRecipientDeliveryCount: mergeResult.droppedRecipientDeliveryCount
                    )
                }
            } else {
                let droppedPayloadBatchCount = pending.payloadBatches.count
                let droppedRecipientDeliveryCount = pending.payloadBatches.reduce(0) {
                    $0 + $1.recipientUserIDs.count
                }
                pending.payloadBatches = payloadBatches
                pending.requestID = requestID
                pending.scheduled = true
                coalescedDispatches[key] = pending
                await app.routingMetrics.recordRealtimeCoalescedDispatchReplacement(
                    droppedPayloadBatchCount: droppedPayloadBatchCount,
                    droppedRecipientDeliveryCount: droppedRecipientDeliveryCount
                )
            }
        } else {
            wasScheduled = false
            let initialPayloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch]
            if key.scope.keepsLatestPayloadPerRecipient {
                // A Kafka run can already contain dozens of message-created
                // events. Coalesce the first run before scheduling it too.
                initialPayloadBatches = mergeLatestPayloadPerRecipient(
                    pending: [],
                    replacement: payloadBatches
                ).payloadBatches
            } else {
                initialPayloadBatches = payloadBatches
            }
            coalescedDispatches[key] = CoalescedDispatch(
                payloadBatches: initialPayloadBatches,
                requestID: requestID,
                scheduled: true
            )
        }

        guard !wasScheduled else {
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(windowMilliseconds) * 1_000_000)
            await self.flushCoalescedDispatch(for: key)
        }
    }

    private func mergeLatestPayloadPerRecipient(
        pending: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        replacement: [ConversationRealtimeConsumer.DomainEventPayloadBatch]
    ) -> RecipientLatestMergeResult {
        var assignments: [UUID: RecipientLatestAssignment] = [:]
        var pendingBatchRecipientCounts: [Int: Int] = [:]
        var nextSourceIndex = 0

        for batch in pending {
            let sourceIndex = nextSourceIndex
            nextSourceIndex += 1
            var uniqueRecipientCount = 0
            var seenPendingRecipients = Set<UUID>()
            for recipientUserID in batch.recipientUserIDs where seenPendingRecipients.insert(recipientUserID).inserted {
                if let previous = assignments[recipientUserID],
                   let remaining = pendingBatchRecipientCounts[previous.sourceIndex] {
                    pendingBatchRecipientCounts[previous.sourceIndex] = max(0, remaining - 1)
                }
                uniqueRecipientCount += 1
                assignments[recipientUserID] = RecipientLatestAssignment(
                    payload: batch.payload,
                    fanoutIntent: batch.fanoutIntent,
                    sourceIndex: sourceIndex
                )
            }
            pendingBatchRecipientCounts[sourceIndex] = uniqueRecipientCount
        }

        var droppedRecipientDeliveryCount = 0
        for batch in replacement {
            let sourceIndex = nextSourceIndex
            nextSourceIndex += 1
            var seenReplacementRecipients = Set<UUID>()
            for recipientUserID in batch.recipientUserIDs where seenReplacementRecipients.insert(recipientUserID).inserted {
                if let previous = assignments[recipientUserID] {
                    droppedRecipientDeliveryCount += 1
                    if let remaining = pendingBatchRecipientCounts[previous.sourceIndex] {
                        pendingBatchRecipientCounts[previous.sourceIndex] = max(0, remaining - 1)
                    }
                }
                assignments[recipientUserID] = RecipientLatestAssignment(
                    payload: batch.payload,
                    fanoutIntent: batch.fanoutIntent,
                    sourceIndex: sourceIndex
                )
            }
        }

        var recipientsBySourceIndex: [Int: [UUID]] = [:]
        for (recipientUserID, assignment) in assignments {
            recipientsBySourceIndex[assignment.sourceIndex, default: []].append(recipientUserID)
        }

        var payloadBySourceIndex: [Int: IMTCPChatDomainEventPayload] = [:]
        var fanoutIntentBySourceIndex: [Int: IMGatewayDomainEventFanoutIntent] = [:]
        for assignment in assignments.values {
            payloadBySourceIndex[assignment.sourceIndex] = assignment.payload
            fanoutIntentBySourceIndex[assignment.sourceIndex] = assignment.fanoutIntent
        }

        let payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch] = recipientsBySourceIndex.keys.sorted().compactMap { sourceIndex in
            guard let payload = payloadBySourceIndex[sourceIndex],
                  let fanoutIntent = fanoutIntentBySourceIndex[sourceIndex]
            else {
                return nil
            }
            return ConversationRealtimeConsumer.DomainEventPayloadBatch(
                payload: payload,
                recipientUserIDs: (recipientsBySourceIndex[sourceIndex] ?? []).sorted { $0.uuidString < $1.uuidString },
                fanoutIntent: fanoutIntent
            )
        }
        let droppedPayloadBatchCount = pendingBatchRecipientCounts.values.filter { $0 == 0 }.count
        return RecipientLatestMergeResult(
            payloadBatches: payloadBatches,
            droppedPayloadBatchCount: droppedPayloadBatchCount,
            droppedRecipientDeliveryCount: droppedRecipientDeliveryCount
        )
    }

    private func flushCoalescedDispatch(for key: CoalescingKey) async {
        guard let pending = coalescedDispatches.removeValue(forKey: key) else {
            return
        }
        await dispatchNow(pending.payloadBatches, requestID: pending.requestID)
    }

    private func dispatchNow(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        guard !payloadBatches.isEmpty else {
            return
        }

        let recipientCount = payloadBatches.reduce(0) { $0 + $1.recipientUserIDs.count }
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        let slotRequestedAt = Date()
        let slotStats = await acquireSlot(requestedAt: slotRequestedAt)
        if IMRealtimeDeliveryDiagnostics.shouldLog(
            durationMilliseconds: slotStats.waitMilliseconds,
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Realtime async dispatcher waited for relay slot.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "delivery_count": .stringConvertible(recipientCount),
                "payload_batch_count": .stringConvertible(payloadBatches.count),
                "slot_wait_ms": .stringConvertible(slotStats.waitMilliseconds),
                "in_flight": .stringConvertible(slotStats.inFlight),
                "queued_waiters": .stringConvertible(slotStats.queuedWaiters),
                "max_in_flight": .stringConvertible(maxInFlight),
                "max_queued": .stringConvertible(maxQueued)
            ])
        }

        let relayStartedAt = Date()
        await app.routingMetrics.recordRealtimeAsyncRelayTaskStarted(
            taskStartLagMilliseconds: 0,
            inFlight: slotStats.inFlight
        )
        await relayHandler(payloadBatches, requestID)
        let relayMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: relayStartedAt)
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [relayMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Realtime async dispatcher slow relay task.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "delivery_count": .stringConvertible(recipientCount),
                "payload_batch_count": .stringConvertible(payloadBatches.count),
                "relay_ms": .stringConvertible(relayMilliseconds),
                "slot_wait_ms": .stringConvertible(slotStats.waitMilliseconds),
                "max_in_flight": .stringConvertible(maxInFlight),
                "max_queued": .stringConvertible(maxQueued)
            ])
        }
        let currentInFlight = await releaseSlot()
        await app.routingMetrics.recordRealtimeAsyncRelayTaskCompleted(
            relayMilliseconds: relayMilliseconds,
            inFlight: currentInFlight
        )
    }

    private func dispatchNowReliably(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?
    ) async throws {
        let recipientCount = payloadBatches.reduce(0) { $0 + $1.recipientUserIDs.count }
        let slotStats = await acquireSlot(requestedAt: Date())
        await app.routingMetrics.recordRealtimeAsyncRelayTaskStarted(
            taskStartLagMilliseconds: 0,
            inFlight: slotStats.inFlight
        )
        let relayStartedAt = Date()
        do {
            try await reliableRelayHandler(payloadBatches, requestID)
        } catch {
            let currentInFlight = await releaseSlot()
            await app.routingMetrics.recordRealtimeAsyncRelayTaskCompleted(
                relayMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: relayStartedAt),
                inFlight: currentInFlight
            )
            app.logger.warning("Reliable realtime relay failed; source event will retry.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "delivery_count": .stringConvertible(recipientCount),
                "payload_batch_count": .stringConvertible(payloadBatches.count),
                "error": .string(String(describing: error))
            ])
            throw error
        }
        let currentInFlight = await releaseSlot()
        await app.routingMetrics.recordRealtimeAsyncRelayTaskCompleted(
            relayMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: relayStartedAt),
            inFlight: currentInFlight
        )
    }

    private func acquireSlot(requestedAt: Date) async -> SlotStats {
        if inFlight < maxInFlight {
            inFlight += 1
            return SlotStats(
                waitMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: requestedAt),
                inFlight: inFlight,
                queuedWaiters: waiters.count
            )
        }

        if waiters.count >= maxQueued {
            await app.routingMetrics.recordRealtimeAsyncRelayQueueSaturated()
        }

        let metrics = app.routingMetrics
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let queuedWaiterCount = waiters.count
            Task {
                await metrics.recordRealtimeAsyncRelayQueuedWaiters(queuedWaiterCount)
            }
        }
        return SlotStats(
            waitMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: requestedAt),
            inFlight: inFlight,
            queuedWaiters: waiters.count
        )
    }

    private func releaseSlot() async -> Int {
        if waiters.isEmpty {
            inFlight -= 1
            await app.routingMetrics.recordRealtimeAsyncRelayQueuedWaiters(0)
            return inFlight
        } else {
            let continuation = waiters.removeFirst()
            await app.routingMetrics.recordRealtimeAsyncRelayQueuedWaiters(waiters.count)
            continuation.resume()
            return inFlight
        }
    }
}

private struct RealtimeDeliveryAsyncDispatcherStorageKey: StorageKey {
    typealias Value = RealtimeDeliveryAsyncDispatcher
}

extension Application {
    var realtimeDeliveryAsyncDispatcher: RealtimeDeliveryAsyncDispatcher {
        if let dispatcher = storage[RealtimeDeliveryAsyncDispatcherStorageKey.self] {
            return dispatcher
        }

        let dispatcher = RealtimeDeliveryAsyncDispatcher(
            app: self,
            maxInFlight: streamConsumerConfiguration.realtimeDeliveryAsyncMaxInFlight,
            maxQueued: streamConsumerConfiguration.realtimeDeliveryAsyncMaxQueued
        )
        storage[RealtimeDeliveryAsyncDispatcherStorageKey.self] = dispatcher
        return dispatcher
    }
}
