import Foundation
import Vapor

actor RealtimeDeliveryAsyncDispatcher {
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

    private let app: Application
    private let maxInFlight: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var coalescedDispatches: [UUID: CoalescedDispatch] = [:]

    init(app: Application, maxInFlight: Int) {
        self.app = app
        self.maxInFlight = max(1, maxInFlight)
    }

    func dispatch(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?,
        coalescingKey: UUID? = nil,
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
            coalescingWindowMilliseconds: coalescingWindowMilliseconds
        )
    }

    func dispatchPayloadBatches(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?,
        coalescingKey: UUID? = nil,
        coalescingWindowMilliseconds: Int = 0
    ) async {
        guard !payloadBatches.isEmpty else { return }
        if let coalescingKey, coalescingWindowMilliseconds > 0 {
            coalesce(
                payloadBatches,
                requestID: requestID,
                key: coalescingKey,
                windowMilliseconds: coalescingWindowMilliseconds
            )
            return
        }

        await dispatchNow(payloadBatches, requestID: requestID)
    }

    private func coalesce(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        requestID: UUID?,
        key: UUID,
        windowMilliseconds: Int
    ) {
        let wasScheduled = coalescedDispatches[key]?.scheduled == true
        coalescedDispatches[key] = CoalescedDispatch(
            payloadBatches: payloadBatches,
            requestID: requestID,
            scheduled: true
        )

        guard !wasScheduled else {
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(windowMilliseconds) * 1_000_000)
            await self.flushCoalescedDispatch(for: key)
        }
    }

    private func flushCoalescedDispatch(for key: UUID) async {
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
                "max_in_flight": .stringConvertible(maxInFlight)
            ])
        }

        let taskQueuedAt = Date()
        let maxInFlightValue = maxInFlight
        Task {
            let relayStartedAt = Date()
            for payloadBatch in payloadBatches {
                await app.gatewaySessionService.sendDomainEventPayload(
                    payloadBatch.payload,
                    toUserIDs: payloadBatch.recipientUserIDs,
                    requestID: requestID
                )
            }
            let relayMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: relayStartedAt)
            let taskStartLagMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(from: taskQueuedAt, to: relayStartedAt)
            if IMRealtimeDeliveryDiagnostics.shouldLogAny(
                [taskStartLagMilliseconds, relayMilliseconds],
                thresholdMilliseconds: slowLogMilliseconds
            ) {
                app.logger.info("Realtime async dispatcher slow relay task.", metadata: [
                    "request_id": .string(requestID?.uuidString ?? ""),
                    "delivery_count": .stringConvertible(recipientCount),
                    "payload_batch_count": .stringConvertible(payloadBatches.count),
                    "task_start_lag_ms": .stringConvertible(taskStartLagMilliseconds),
                    "relay_ms": .stringConvertible(relayMilliseconds),
                    "slot_wait_ms": .stringConvertible(slotStats.waitMilliseconds),
                    "max_in_flight": .stringConvertible(maxInFlightValue)
                ])
            }
            await self.releaseSlot()
        }
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

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return SlotStats(
            waitMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: requestedAt),
            inFlight: inFlight,
            queuedWaiters: waiters.count
        )
    }

    private func releaseSlot() async {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
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
            maxInFlight: streamConsumerConfiguration.realtimeDeliveryAsyncMaxInFlight
        )
        storage[RealtimeDeliveryAsyncDispatcherStorageKey.self] = dispatcher
        return dispatcher
    }
}
