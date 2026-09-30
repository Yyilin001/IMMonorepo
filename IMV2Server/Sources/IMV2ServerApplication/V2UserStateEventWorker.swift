import Foundation
import IMV2ServerContracts

/// 独立于消息扇出的用户状态派发器。失败只影响对应事件，不跳过持久恢复。
public struct V2UserStateEventWorker: Sendable {
    private let outbox: any V2UserStateEventOutbox
    private let projector: any V2UserStateEventProjecting
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date
    private let maxConcurrentUsers: Int

    public init(outbox: any V2UserStateEventOutbox, projector: any V2UserStateEventProjecting,
                retryPolicy: V2DurableRetryPolicy = .standard, maxConcurrentUsers: Int = 8,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.outbox = outbox
        self.projector = projector
        self.retryPolicy = retryPolicy
        self.maxConcurrentUsers = max(1, maxConcurrentUsers)
        self.now = now
    }

    /// 每轮只领取能够立即处理的行数，并在用户之间并发。来源确认成功后才计为完成。
    public func runOnce(limit: Int, leaseDuration: TimeInterval = 30) async throws -> Int {
        guard limit > 0, limit <= 1024 else { throw V2UserStateEventError.invalidEvent }
        try Task.checkCancellation()
        var claimed = 0
        var completed = 0
        while claimed < limit {
            try Task.checkCancellation()
            // The outbox returns at most one oldest outstanding event per user.
            // Claim only one processing window so no lease waits in a local queue.
            let claimedAt = now()
            let leases = try await outbox.claim(
                now: claimedAt, leaseDuration: leaseDuration,
                limit: min(maxConcurrentUsers, limit - claimed)
            )
            guard !leases.isEmpty else { break }
            claimed += leases.count
            let batch = try await withThrowingTaskGroup(
                of: V2UserStateEventProcessOutcome.self,
                returning: (completed: Int, leaseExpired: Bool).self
            ) { group in
                for lease in leases {
                    let leaseDeadline = claimedAt.addingTimeInterval(leaseDuration)
                    group.addTask { try await process(lease, leaseDeadline: leaseDeadline) }
                }
                var acknowledged = 0
                var leaseExpired = false
                while let outcome = try await group.next() {
                    try Task.checkCancellation()
                    switch outcome {
                    case .acknowledged: acknowledged += 1
                    case .notAcknowledged: break
                    case .leaseExpired: leaseExpired = true
                    }
                }
                return (acknowledged, leaseExpired)
            }
            completed += batch.completed
            // Do not immediately reclaim an expired row in this run and amplify
            // slow-target retries. The durable lease remains available to recovery.
            if batch.leaseExpired { break }
        }
        return completed
    }

    private func process(_ lease: V2UserStateEventLease, leaseDeadline: Date) async throws -> V2UserStateEventProcessOutcome {
        try Task.checkCancellation()
        guard now() < leaseDeadline else { return .leaseExpired }
        do {
            let sequence = try await projector.project(lease.event)
            try Task.checkCancellation()
            // The target write is idempotent, but a source acknowledgement after
            // lease expiry could hide a concurrent recovery attempt.
            guard now() < leaseDeadline else { return .leaseExpired }
            let acknowledged = try await outbox.acknowledge(lease, sequence: sequence, now: now())
            return acknowledged ? .acknowledged : .leaseExpired
        } catch is CancellationError {
            // Do not mutate source state; the durable lease remains recoverable on expiry.
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard now() < leaseDeadline else { return .leaseExpired }
            let kind: V2DurableWorkFailureKind = error is V2UserStateEventError
                ? .deterministic : v2DurableWorkFailureKind(for: error)
            try await outbox.retry(lease, disposition: retryPolicy.disposition(
                attempt: lease.attempt, claimToken: lease.token, now: now(), kind: kind
            ))
            return .notAcknowledged
        }
    }
}

private enum V2UserStateEventProcessOutcome: Sendable {
    case acknowledged
    case notAcknowledged
    case leaseExpired
}
