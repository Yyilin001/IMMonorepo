import Foundation

/// Bounded, process-local classifier for the message-write execution path.
///
/// This cache is deliberately not an authorization, room-existence, or
/// delivery authority. It only separates direct, hybrid-group, and scalar
/// write graphs before a shared transaction is attempted. Every selected path
/// still validates the room and caller against PostgreSQL before accepting a
/// message. A stale entry can therefore only choose a slower path or cause an
/// atomic path to decline safely.
actor V2RoomWriteBatchRouteCache {
    enum Route: Sendable, Equatable {
        case direct
        case largeGroupHybrid
        case individual
    }

    struct Snapshot: Sendable, Equatable {
        let entries: Int
        let lookupHits: UInt64
        let lookupMisses: UInt64
        let insertions: UInt64
        let evictions: UInt64
    }

    private final class Node {
        let roomID: UUID
        var route: Route
        weak var previous: Node?
        var next: Node?

        init(roomID: UUID, route: Route) {
            self.roomID = roomID
            self.route = route
        }
    }

    private let capacity: Int
    private var entries: [UUID: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?
    private var lookupHits: UInt64 = 0
    private var lookupMisses: UInt64 = 0
    private var insertions: UInt64 = 0
    private var evictions: UInt64 = 0

    init(capacity: Int = 50_000) {
        self.capacity = max(1, capacity)
    }

    func values(for roomIDs: [UUID]) -> [Route?] {
        roomIDs.map { roomID in
            guard let node = entries[roomID] else {
                lookupMisses &+= 1
                return nil
            }
            lookupHits &+= 1
            moveToMostRecent(node)
            return node.route
        }
    }

    func insert(_ routes: [(roomID: UUID, route: Route)]) {
        for value in routes {
            if let node = entries[value.roomID] {
                node.route = value.route
                moveToMostRecent(node)
                continue
            }
            if entries.count >= capacity, let leastRecent {
                remove(leastRecent)
                evictions &+= 1
            }
            let node = Node(roomID: value.roomID, route: value.route)
            entries[value.roomID] = node
            attachAsMostRecent(node)
            insertions &+= 1
        }
    }

    func snapshot() -> Snapshot {
        .init(
            entries: entries.count,
            lookupHits: lookupHits,
            lookupMisses: lookupMisses,
            insertions: insertions,
            evictions: evictions
        )
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
        if leastRecent == nil {
            leastRecent = node
        }
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
