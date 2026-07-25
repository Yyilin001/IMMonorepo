import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Coalesces disconnect storms so route cleanup does not create one Redis/actor workflow per channel.
final class IMTCPConnectionCloseBatcher: @unchecked Sendable {
    private struct Event: Sendable {
        let connectionID: UUID?
        let metrics: IMTCPChannelInactiveMetricEvent
    }

    private struct State {
        var pending: [Event] = []
        var isDraining = false
    }

    private static let maximumBatchSize = 2_048

    private let application: Application
    private let state = NIOLockedValueBox(State())

    init(application: Application) {
        self.application = application
    }

    func enqueue(
        connectionID: UUID?,
        closeReason: String?,
        state: String
    ) {
        let event = Event(
            connectionID: connectionID,
            metrics: IMTCPChannelInactiveMetricEvent(closeReason: closeReason, state: state)
        )
        let shouldStartDrain = self.state.withLockedValue { state in
            state.pending.append(event)
            guard !state.isDraining else {
                return false
            }
            state.isDraining = true
            return true
        }
        guard shouldStartDrain else {
            return
        }
        Task { [weak self] in
            // Give concurrent channelInactive callbacks one scheduler turn to join this batch.
            await Task.yield()
            await self?.drain()
        }
    }

    private func drain() async {
        while true {
            let batch = state.withLockedValue { state -> [Event] in
                guard !state.pending.isEmpty else {
                    state.isDraining = false
                    return []
                }
                let batchCount = min(state.pending.count, Self.maximumBatchSize)
                let batch = Array(state.pending.prefix(batchCount))
                state.pending.removeFirst(batchCount)
                return batch
            }
            guard !batch.isEmpty else {
                return
            }

            let connectionIDs = batch.compactMap(\.connectionID)
            if !connectionIDs.isEmpty {
                await application.connectionRoutingService.remove(connectionIDs: connectionIDs)
            }
            await application.routingMetrics.recordTCPChannelInactive(
                events: batch.map(\.metrics)
            )

            // Bound each cleanup slice so a disconnect storm cannot monopolize the cooperative executor.
            await Task.yield()
        }
    }
}
