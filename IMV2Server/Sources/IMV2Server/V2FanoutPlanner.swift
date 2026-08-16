import Foundation
import IMV2Core

public struct V2FanoutPlanningResult: Equatable, Sendable {
    public let createdCompletionUnits: Int
    public let createdDeliveries: Int
    public let wasAlreadyPlanned: Bool

    public init(createdCompletionUnits: Int, createdDeliveries: Int, wasAlreadyPlanned: Bool) {
        self.createdCompletionUnits = createdCompletionUnits
        self.createdDeliveries = createdDeliveries
        self.wasAlreadyPlanned = wasAlreadyPlanned
    }
}

public protocol V2FanoutPlanStore: Sendable {
    func plan(_ trigger: V2FanoutPlanTrigger, pageSize: Int, now: Date) async throws -> V2FanoutPlanningResult
    func planBatch(_ triggers: [V2FanoutPlanTrigger], pageSize: Int, now: Date) async throws -> [V2FanoutPlanningResult]
}

public extension V2FanoutPlanStore {
    /// Stores without a native set-based implementation retain the exact
    /// single-plan semantics. PostgreSQL overrides this requirement so a
    /// relay claim costs one round trip per audience page rather than one
    /// transaction per source event.
    func planBatch(
        _ triggers: [V2FanoutPlanTrigger],
        pageSize: Int,
        now: Date
    ) async throws -> [V2FanoutPlanningResult] {
        var results: [V2FanoutPlanningResult] = []
        results.reserveCapacity(triggers.count)
        for trigger in triggers {
            results.append(try await plan(trigger, pageSize: pageSize, now: now))
        }
        return results
    }
}

/// The planner owns immutable membership-revision enumeration. Delivery work
/// is split into bounded completion units, so source-room capacity is released
/// by completed units rather than one callback per recipient.
public struct V2FanoutPlanner: Sendable {
    private let store: any V2FanoutPlanStore
    private let pageSize: Int
    private let now: @Sendable () -> Date

    public init(
        store: any V2FanoutPlanStore,
        pageSize: Int,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(pageSize > 0)
        self.store = store
        self.pageSize = pageSize
        self.now = now
    }

    public func plan(_ trigger: V2FanoutPlanTrigger) async throws -> V2FanoutPlanningResult {
        try await store.plan(trigger, pageSize: pageSize, now: now())
    }

    public func planBatch(_ triggers: [V2FanoutPlanTrigger]) async throws -> [V2FanoutPlanningResult] {
        guard !triggers.isEmpty else { return [] }
        return try await store.planBatch(triggers, pageSize: pageSize, now: now())
    }
}
