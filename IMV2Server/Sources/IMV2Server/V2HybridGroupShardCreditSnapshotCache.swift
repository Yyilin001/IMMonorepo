import Foundation
import IMV2Core

/// Bounded, short-lived shard-lease hints for hybrid-group command credits.
///
/// This cache is not an authorization or capacity authority. A cache hit is
/// useful only for asking `V2ShardAdmissionCommandCreditPool` to reserve a
/// durable command batch. The enclosing message transaction still compares
/// the room assignment and lease generation and locks every membership,
/// permission and mute row used by acceptance.
actor V2HybridGroupShardCreditSnapshotCache {
    struct Entry: Sendable {
        let roomShardID: String
        let capacityProfileID: String
        let kind: String
        let deliveryMode: V2GroupDeliveryMode
        let frozenAt: Date?
        let roomShardLeaseID: UUID
        let roomShardLeaseGeneration: Int64
        let shardState: ShardAdmissionState
    }

    struct Update: Sendable {
        let roomID: UUID
        let entry: Entry
    }

    private final class Node {
        let roomID: UUID
        var entry: Entry
        var expiresAt: ContinuousClock.Instant
        weak var previous: Node?
        var next: Node?

        init(roomID: UUID, entry: Entry, expiresAt: ContinuousClock.Instant) {
            self.roomID = roomID
            self.entry = entry
            self.expiresAt = expiresAt
        }
    }

    private let capacity: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [UUID: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?

    init(capacity: Int = 50_000, lifetime: Duration = .seconds(60)) {
        self.capacity = max(1, capacity)
        self.lifetime = max(.seconds(1), lifetime)
    }

    func values(for roomIDs: [UUID]) -> [Entry?] {
        let now = clock.now
        return roomIDs.map { roomID in
            guard let node = entries[roomID] else { return nil }
            guard node.expiresAt > now else {
                remove(node)
                return nil
            }
            moveToMostRecent(node)
            return node.entry
        }
    }

    func insert(_ updates: [Update]) {
        let now = clock.now
        for update in updates {
            if let node = entries[update.roomID] {
                node.entry = update.entry
                node.expiresAt = now + lifetime
                moveToMostRecent(node)
                continue
            }
            if entries.count >= capacity, let leastRecent {
                remove(leastRecent)
            }
            let node = Node(
                roomID: update.roomID,
                entry: update.entry,
                expiresAt: now + lifetime
            )
            entries[update.roomID] = node
            attachAsMostRecent(node)
        }
    }

    func invalidate(_ roomIDs: [UUID]) {
        for roomID in Set(roomIDs) {
            if let node = entries[roomID] { remove(node) }
        }
    }

    private func moveToMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        detach(node)
        attachAsMostRecent(node)
    }

    private func attachAsMostRecent(_ node: Node) {
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil { leastRecent = node }
    }

    private func detach(_ node: Node) {
        if let previous = node.previous {
            previous.next = node.next
        } else {
            mostRecent = node.next
        }
        if let next = node.next {
            next.previous = node.previous
        } else {
            leastRecent = node.previous
        }
        node.previous = nil
        node.next = nil
    }

    private func remove(_ node: Node) {
        detach(node)
        entries.removeValue(forKey: node.roomID)
    }
}
