import FluentKit
import Foundation

public struct V2GroupJoinQuotaRecoveryReport: Equatable, Sendable {
    public var attempted = 0
    public var reconciled = 0
    public var deferred = 0
}

/// Bounded recovery of reserved submissions and their terminal quota release.
/// Transport failures retain capacity and retry the same immutable owner attempt.
public struct V2GroupJoinQuotaRecoveryWorker: Sendable {
    private let jobs: PostgresV2GroupJoinQuotaStore
    private let resume: @Sendable (V2GroupJoinQuotaIntent, Date) async throws -> Void
    private let now: @Sendable () -> Date

    public init(controlDatabase: any Database, invitations: V2RoutedGroupInvitationStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.jobs = .init(database: controlDatabase)
        self.resume = { intent, at in try await invitations.resumeSubmission(intent, now: at) }
        self.now = now
    }

    public init(controlDatabase: any Database, coordinator: V2ActorInvitationCoordinator,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.jobs = .init(database: controlDatabase)
        self.resume = { intent, _ in try await coordinator.resumeSubmission(intent, deadline: deadline()) }
        self.now = now
    }

    public func runOnce(limit: Int = 8) async throws -> V2GroupJoinQuotaRecoveryReport {
        guard (1...100).contains(limit) else { throw V2GroupInvitationServiceError.invalidRequest }
        var report = V2GroupJoinQuotaRecoveryReport()
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard let intent = try await jobs.claim(limit: 1, now: now(), lease: 60).first else { break }
            report.attempted += 1
            do {
                try Task.checkCancellation()
                try await resume(intent, now())
                report.reconciled += 1
            } catch is CancellationError {
                // A lost/uncertain response is not permission to free the slot.
                // Lease expiry lets a replacement worker replay the owner receipt.
                throw CancellationError()
            } catch {
                try await jobs.deferClaim(intent, now: now())
                report.deferred += 1
            }
        }
        return report
    }
}
