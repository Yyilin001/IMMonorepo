import Foundation

/// Minimal durable-sync boundary used by the lifecycle runtime. The concrete
/// engine retains its serial pull/apply/ACK ownership; tests can inject a fake
/// without constructing a database or a framed transport.
public protocol V2SyncDriving: Sendable {
    func synchronizeUntilCaughtUp() async throws -> V2SyncCycleResult
    func completePendingReset() async throws
}

/// Application code owns the task that calls `run()`, so foreground/background
/// policy controls its lifecycle. Each coalesced live hint causes bounded pull
/// work; no hint is treated as a durable delivery signal.
public struct V2AvailabilityDrivenSyncRunner: Sendable {
    private let source: any V2SyncAvailabilityHintSource
    private let syncEngine: any V2SyncDriving
    private let afterSynchronization: @Sendable () async throws -> Void

    public init(
        source: any V2SyncAvailabilityHintSource,
        syncEngine: any V2SyncDriving,
        afterSynchronization: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.source = source
        self.syncEngine = syncEngine
        self.afterSynchronization = afterSynchronization
    }

    public func run() async throws {
        while !Task.isCancelled {
            _ = try await source.nextAvailabilityHint()
            _ = try await syncEngine.synchronizeUntilCaughtUp()
            try await afterSynchronization()
        }
    }
}
