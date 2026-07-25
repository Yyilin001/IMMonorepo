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
}
