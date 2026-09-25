import FluentKit
import Foundation

public struct V2GroupJoinQuotaRecoveryReport: Equatable, Sendable {
    public var attempted = 0
    public var reconciled = 0
    public var deferred = 0
}

/// 有界恢复已预留的提交，并在终态释放其额度。
/// 传输失败时保留容量，并重试同一个不可变的所有者尝试。
public struct V2GroupJoinQuotaRecoveryWorker: Sendable {
    private let jobs: PostgresV2GroupJoinQuotaStore
    private let resume: @Sendable (V2GroupJoinQuotaIntent, Date) async throws -> Void
    private let now: @Sendable () -> Date

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
                // 响应丢失或结果不确定，并不意味着可以释放配额槽位。
                // 租约到期后，接替的工作器可以重放所有者回执。
                throw CancellationError()
            } catch {
                try await jobs.deferClaim(intent, now: now())
                report.deferred += 1
            }
        }
        return report
    }
}
