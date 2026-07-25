import Foundation
import IMV2Core

public actor InMemoryV2OutboxStore: V2RoomOutboxStore {
    private struct Entry: Sendable {
        let trigger: V2FanoutPlanTrigger
        var published = false
        var lease: V2OutboxLease?
    }

    private var entries: [EventID: Entry]

    public init(triggers: [V2FanoutPlanTrigger]) {
        self.entries = Dictionary(uniqueKeysWithValues: triggers.map { ($0.sourceEventID, Entry(trigger: $0)) })
    }

    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) -> [V2OutboxLease] {
        guard limit > 0 else { return [] }
        let available = entries.values
            .filter { !$0.published && ($0.lease == nil) }
            .prefix(limit)
        var claimed: [V2OutboxLease] = []
        for entry in available {
            let lease = V2OutboxLease(trigger: entry.trigger, claimToken: UUID())
            entries[entry.trigger.sourceEventID]?.lease = lease
            claimed.append(lease)
        }
        return claimed
    }

    public func markPublished(_ lease: V2OutboxLease) {
        guard var entry = entries[lease.trigger.sourceEventID], entry.lease == lease else { return }
        entry.published = true
        entry.lease = nil
        entries[lease.trigger.sourceEventID] = entry
    }

    public func release(_ lease: V2OutboxLease) {
        guard var entry = entries[lease.trigger.sourceEventID], entry.lease == lease else { return }
        entry.lease = nil
        entries[lease.trigger.sourceEventID] = entry
    }

    public func publishedTriggers() -> [V2FanoutPlanTrigger] {
        entries.values.filter(\.published).map(\.trigger).sorted { $0.sourceEventID < $1.sourceEventID }
    }
}
