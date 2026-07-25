import Foundation
import IMV2Core

public struct V2PushDispatchSeed: Sendable {
    public let wake: V2GenericPushWake
    public let campaignEnabled: Bool
    public let request: V2PushAdmissionRequest
    public let budget: V2PushDeviceBudget

    public init(wake: V2GenericPushWake, campaignEnabled: Bool, request: V2PushAdmissionRequest, budget: V2PushDeviceBudget) {
        self.wake = wake
        self.campaignEnabled = campaignEnabled
        self.request = request
        self.budget = budget
    }
}

public actor InMemoryV2PushWakeStore: V2PushWakeStore {
    private enum State: Sendable { case pending, claimed(V2PushWakeLease), sent, suppressed(V2PushSuppressionReason) }
    private struct Entry: Sendable { var seed: V2PushDispatchSeed; var state: State }
    private var entries: [UUID: Entry]

    public init(seeds: [V2PushDispatchSeed]) {
        entries = Dictionary(uniqueKeysWithValues: seeds.map { ($0.wake.dispatchID, Entry(seed: $0, state: .pending)) })
    }

    public func claimAdmitted(now _: Date, leaseDuration _: TimeInterval, limit: Int) throws -> [V2PushWakeLease] {
        guard limit > 0 else { return [] }
        var result: [V2PushWakeLease] = []
        for id in entries.keys.sorted(by: { $0.uuidString < $1.uuidString }) where result.count < limit {
            guard var entry = entries[id], case .pending = entry.state else { continue }
            let admission = try V2PushAdmissionEvaluator.evaluate(campaignEnabled: entry.seed.campaignEnabled, request: entry.seed.request, budget: entry.seed.budget)
            switch admission {
            case .suppressed(let reason):
                entry.state = .suppressed(reason)
            case .allowed(let nextBudget):
                let lease = V2PushWakeLease(wake: entry.seed.wake, claimToken: UUID())
                entry.seed = .init(wake: entry.seed.wake, campaignEnabled: entry.seed.campaignEnabled, request: entry.seed.request, budget: nextBudget)
                entry.state = .claimed(lease)
                result.append(lease)
            }
            entries[id] = entry
        }
        return result
    }

    public func markSent(_ lease: V2PushWakeLease, now _: Date) {
        guard var entry = entries[lease.wake.dispatchID], case .claimed(let active) = entry.state, active == lease else { return }
        entry.state = .sent
        entries[lease.wake.dispatchID] = entry
    }

    public func suppress(_ lease: V2PushWakeLease, reason: V2PushSuppressionReason) {
        guard var entry = entries[lease.wake.dispatchID], case .claimed(let active) = entry.state, active == lease else { return }
        entry.state = .suppressed(reason)
        entries[lease.wake.dispatchID] = entry
    }

    public func release(_ lease: V2PushWakeLease) {
        guard var entry = entries[lease.wake.dispatchID], case .claimed(let active) = entry.state, active == lease else { return }
        entry.state = .pending
        entries[lease.wake.dispatchID] = entry
    }

    public func suppressionReason(for dispatchID: UUID) -> V2PushSuppressionReason? {
        guard let entry = entries[dispatchID], case .suppressed(let reason) = entry.state else { return nil }
        return reason
    }
}
