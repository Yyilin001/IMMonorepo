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
    private let now: @Sendable () -> Date

    public init(store: any V2PushWakeStore, provider: any V2PushWakeProvider, leaseDuration: TimeInterval = 30, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(leaseDuration > 0)
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2PushWakeReport {
        precondition(limit > 0)
        let leases = try await store.claimAdmitted(now: now(), leaseDuration: leaseDuration, limit: limit)
        var sent = 0
        var released = 0
        for lease in leases {
            do {
                switch try await provider.send(lease.wake) {
                case .sent:
                    try await store.markSent(lease, now: now())
                    sent += 1
                case .suppressed(let reason):
                    try await store.suppress(lease, reason: reason)
                }
            } catch {
                try await store.release(lease)
                released += 1
            }
        }
        return .init(admittedCount: leases.count, sentCount: sent, releasedCount: released)
    }
}
