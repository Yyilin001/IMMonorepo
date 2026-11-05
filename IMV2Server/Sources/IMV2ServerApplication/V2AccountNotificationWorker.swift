import Foundation
import IMV2ServerContracts

public struct V2AccountNotificationReport: Sendable {
    public var expired = 0
    public var claimed = 0
    public var completed = 0
    public var retried = 0
}

/// No provider means retention only. Unconfigured APNs never acknowledges work
/// as delivered, performs network calls, or creates an immediate retry loop.
public struct V2AccountNotificationWorker: Sendable {
    private let store: any V2AccountNotificationStoring
    private let delivery: (any V2AccountNotificationDelivering)?
    private let now: @Sendable () -> Date
    public init(store: any V2AccountNotificationStoring, delivery: (any V2AccountNotificationDelivering)? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.delivery = delivery; self.now = now
    }
    public func runOnce(limit: Int) async throws -> V2AccountNotificationReport {
        guard (1...128).contains(limit) else { throw V2RoomDispatchError.invalidInput }
        var result = V2AccountNotificationReport()
        result.expired = try await store.expire(now: now(), limit: limit)
        guard let delivery else { return result }
        // A small window avoids claiming more leases than a slow provider can serve.
        let leases = try await store.claim(now: now(), limit: min(limit, 8))
        result.claimed = leases.count
        for lease in leases {
            try Task.checkCancellation()
            guard now() < lease.expiresAt else { continue }
            let outcome: V2AccountNotificationOutcome
            do { outcome = try await delivery.deliver(lease.notification) }
            catch is CancellationError { throw CancellationError() }
            catch { outcome = .retry }
            try Task.checkCancellation()
            switch outcome {
            case .accepted, .suppressed:
                if try await store.complete(lease, now: now()) { result.completed += 1 }
            case .retry:
                try await store.retry(lease, now: now(), after: min(300, pow(2, Double(min(lease.attempt, 9)))))
                result.retried += 1
            }
        }
        return result
    }
}
