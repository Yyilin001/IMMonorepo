import Foundation
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts

/// One pool-local dispatcher owns room fairness, physical connection capacity,
/// cancellation and drain. Room execution remains occupied through finalization.
public final class V2DurableSendOperationOwnerBatcher: V2SendOperationOwnerMetricsReading, Sendable {
    private let dispatcher: V2PhysicalSendDispatcher

    // Fixed roots may retain the dispatcher while parked, but must not retain
    // its owner forever. Explicit shutdown remains the awaited drain boundary.
    deinit { dispatcher.requestShutdown() }

    public convenience init(store: PostgresV2MessageSendOperationStore, capacityProfile: V2CapacityProfile,
                identifiers: V2AcceptanceIDFactory = .init(), now: @escaping @Sendable () -> Date,
                configuration: V2SendOperationSchedulingConfiguration,
                maximumRetainedBytes: Int) throws {
        guard let capacity = store.scheduledSendConnectionCapacity, capacity > 0 else {
            throw V2ActorContractError.invalidConfiguration("message send requires physical connection capacity")
        }
        self.init(store: store, configuration: configuration,
            maximumRetainedBytes: maximumRetainedBytes,
            resourceDemandLimit: capacity,
            scheduledConnection: { deadline, body in
                try await store.withMessageWriteConnection(deadline: deadline, pipelineDepth: configuration.pipelineDepth, body)
            }, scheduledExecute: { executor, prepared in
                try await executor.execute(prepared, capacityProfile, identifiers, now)
            })
    }

    /// Tests inject the same connection and execution boundaries used in production.
    package init(store: PostgresV2MessageSendOperationStore,
        configuration: V2SendOperationSchedulingConfiguration,
        maximumRetainedBytes: Int, resourceDemandLimit: Int,
        scheduledConnection: @escaping V2ScheduledSendConnection,
        scheduledExecute: @escaping V2ScheduledSendExecution) {
        dispatcher = V2PhysicalSendDispatcher(store: store, configuration: configuration,
            maximumRetainedBytes: maximumRetainedBytes, capacity: resourceDemandLimit,
            borrow: scheduledConnection, execute: scheduledExecute)
    }

    public func execute(_ prepared: V2PreparedMessageSendBatch) async throws -> [V2RoomMessagingResult] {
        try await dispatcher.execute(prepared)
    }

    public func sendOperationOwnerMetricsSnapshot() async -> V2SendOperationOwnerMetricsSnapshot {
        dispatcher.metrics()
    }

    package func pressureSnapshot() -> (retainedItems: Int, retainedBytes: Int, queuedTurns: Int,
        inFlightBatches: Int, occupiedRooms: Int, closed: Bool, drainingWaiters: Int) {
        dispatcher.pressureSnapshot()
    }

    public func shutdown() async { await dispatcher.shutdown() }
}
