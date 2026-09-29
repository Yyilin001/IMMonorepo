import Foundation
import IMV2ServerContracts

/// 独立于消息扇出的用户状态派发器。失败只影响对应事件，不跳过持久恢复。
public struct V2UserStateEventWorker: Sendable {
    private let outbox: any V2UserStateEventOutbox
    private let projector: any V2UserStateEventProjecting
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    public init(outbox: any V2UserStateEventOutbox, projector: any V2UserStateEventProjecting,
                retryPolicy: V2DurableRetryPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.outbox = outbox
        self.projector = projector
        self.retryPolicy = retryPolicy
        self.now = now
    }

    /// 返回已被来源库确认的事件数；目标完成但租约失效不计为本轮完成。
    public func runOnce(limit: Int, leaseDuration: TimeInterval = 30) async throws -> Int {
        let leases = try await outbox.claim(now: now(), leaseDuration: leaseDuration, limit: limit)
        var completed = 0
        for lease in leases {
            try Task.checkCancellation()
            do {
                let sequence = try await projector.project(lease.event)
                try Task.checkCancellation()
                if try await outbox.acknowledge(lease, sequence: sequence, now: now()) { completed += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let kind: V2DurableWorkFailureKind = error is V2UserStateEventError
                    ? .deterministic : v2DurableWorkFailureKind(for: error)
                try await outbox.retry(lease, disposition: retryPolicy.disposition(
                    attempt: lease.attempt, claimToken: lease.token, now: now(), kind: kind
                ))
            }
        }
        return completed
    }
}
