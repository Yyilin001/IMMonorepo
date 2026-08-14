import Foundation
import IMV2Core

public struct V2GenericPushWake: Equatable, Sendable {
    public let dispatchID: UUID
    public let deviceID: DeviceID
    public let campaignID: V2PushCampaignID

    public init(dispatchID: UUID, deviceID: DeviceID, campaignID: V2PushCampaignID) {
        self.dispatchID = dispatchID
        self.deviceID = deviceID
        self.campaignID = campaignID
    }
}

public struct V2PushWakeLease: Equatable, Sendable {
    public let wake: V2GenericPushWake
    public let claimToken: UUID

    public init(wake: V2GenericPushWake, claimToken: UUID) {
        self.wake = wake
        self.claimToken = claimToken
    }
}

/// The store performs campaign/budget admission before this provider is ever
/// invoked, so a provider adapter may safely resolve device-key material only
/// for an already-admitted generic wake.
public protocol V2PushWakeProvider: Sendable {
    func send(_ wake: V2GenericPushWake) async throws -> V2PushWakeProviderOutcome
}

/// A terminal suppression differs from a transient provider failure. The
/// worker records it without retrying, while a thrown error only releases the
/// Push lease. Neither path participates in durable user-sync correctness.
public enum V2PushWakeProviderOutcome: Equatable, Sendable {
    case sent
    case suppressed(V2PushSuppressionReason)
}

public protocol V2PushWakeStore: Sendable {
    func claimAdmitted(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2PushWakeLease]
    func markSent(_ lease: V2PushWakeLease, now: Date) async throws
    func suppress(_ lease: V2PushWakeLease, reason: V2PushSuppressionReason) async throws
    func release(_ lease: V2PushWakeLease) async throws
}

public struct V2PushWakeReport: Equatable, Sendable {
    public let admittedCount: Int
    public let sentCount: Int
    public let releasedCount: Int

    public init(admittedCount: Int, sentCount: Int, releasedCount: Int) {
        self.admittedCount = admittedCount
        self.sentCount = sentCount
        self.releasedCount = releasedCount
    }
}

/// Bounded worker; provider failure intentionally only releases the Push
/// dispatch for retry. It cannot roll back or delay the user sync projection.
public struct V2PushWakeWorker: Sendable {
    private let store: any V2PushWakeStore
    private let provider: any V2PushWakeProvider
    private let leaseDuration: TimeInterval
    private let sendTimeout: TimeInterval
    private let maximumConcurrency: Int
    private let now: @Sendable () -> Date

    public init(
        store: any V2PushWakeStore,
        provider: any V2PushWakeProvider,
        leaseDuration: TimeInterval = 30,
        sendTimeout: TimeInterval = 10,
        maximumConcurrency: Int = 8,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(
            leaseDuration.isFinite && sendTimeout.isFinite &&
            leaseDuration > sendTimeout && sendTimeout > 0 && maximumConcurrency > 0
        )
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.sendTimeout = sendTimeout
        self.maximumConcurrency = maximumConcurrency
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2PushWakeReport {
        precondition(limit > 0)
        let leases = try await store.claimAdmitted(now: now(), leaseDuration: leaseDuration, limit: limit)
        let counts = try await withThrowingTaskGroup(
            of: PushProcessingResult.self,
            returning: (sent: Int, released: Int).self
        ) { group in
            var nextIndex = 0
            let initialCount = min(maximumConcurrency, leases.count)
            for _ in 0..<initialCount {
                let lease = leases[nextIndex]
                nextIndex += 1
                group.addTask { try await process(lease) }
            }
            var sent = 0
            var released = 0
            while let result = try await group.next() {
                switch result {
                case .sent: sent += 1
                case .suppressed: break
                case .released: released += 1
                }
                if nextIndex < leases.count {
                    let lease = leases[nextIndex]
                    nextIndex += 1
                    group.addTask { try await process(lease) }
                }
            }
            return (sent, released)
        }
        return .init(admittedCount: leases.count, sentCount: counts.sent, releasedCount: counts.released)
    }

    private func process(_ lease: V2PushWakeLease) async throws -> PushProcessingResult {
        do {
            try Task.checkCancellation()
            let outcome = try await withThrowingTaskGroup(of: V2PushWakeProviderOutcome.self) { group in
                group.addTask { try await provider.send(lease.wake) }
                group.addTask {
                    try await Task.sleep(for: .seconds(sendTimeout))
                    throw V2PushWakeWorkerError.sendTimedOut
                }
                guard let result = try await group.next() else { throw V2PushWakeWorkerError.sendTimedOut }
                group.cancelAll()
                return result
            }
            switch outcome {
            case .sent:
                try await store.markSent(lease, now: now())
                return .sent
            case .suppressed(let reason):
                try await store.suppress(lease, reason: reason)
                return .suppressed
            }
        } catch is CancellationError {
            try? await store.release(lease)
            throw CancellationError()
        } catch {
            try await store.release(lease)
            return .released
        }
    }
}

private enum V2PushWakeWorkerError: Error, Sendable { case sendTimedOut }

private enum PushProcessingResult: Sendable {
    case sent
    case suppressed
    case released
}
