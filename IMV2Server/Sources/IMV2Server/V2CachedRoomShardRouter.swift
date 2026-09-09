import Foundation
import IMV2Core
import Synchronization

/// Bounded process-local acceleration for the durable room-owner directory.
/// It caches only a physical routing hint, never authorization or room state.
/// PostgreSQL remains authoritative on every miss and owner stores still
/// validate the room before accepting a command.
public final class V2CachedRoomShardRouter: V2DirectRoomShardRouting, Sendable {
    private struct Entry: Sendable {
        let route: V2RoomShardRoute
        let expiresAt: ContinuousClock.Instant
    }

    private struct BucketState: Sendable {
        var entries: [RoomID: Entry] = [:]
    }

    private final class Bucket: Sendable {
        let capacity: Int
        let state = Mutex(BucketState())

        init(capacity: Int) { self.capacity = capacity }
    }

    private let source: any V2DirectRoomShardRouting
    private let buckets: [Bucket]
    private let lifetime: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(
        source: any V2DirectRoomShardRouting,
        capacity: Int = 250_000,
        lifetime: Duration = .seconds(300),
        bucketCount: Int = 64,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        let capacity = max(1, capacity)
        let count = min(max(1, bucketCount), capacity)
        let base = capacity / count
        let remainder = capacity % count
        self.source = source
        // Partition the configured budget exactly, without a ceiling-division
        // addition that can overflow or allocate extra entries in every bucket.
        buckets = (0 ..< count).map { Bucket(capacity: base + ($0 < remainder ? 1 : 0)) }
        self.lifetime = max(.seconds(1), lifetime)
        self.now = now
    }

    public func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        if let cached = cachedRoute(for: roomID) { return cached }
        let route = try await source.route(for: roomID)
        return insert(route, for: roomID)
    }

    public func routes(
        for roomIDs: [RoomID]
    ) async throws -> [RoomID: V2RoomShardRoute] {
        guard !roomIDs.isEmpty else { return [:] }
        let unique = Array(Set(roomIDs))
        var result: [RoomID: V2RoomShardRoute] = [:]
        var misses: [RoomID] = []
        result.reserveCapacity(unique.count)
        misses.reserveCapacity(unique.count)
        for roomID in unique {
            if let cached = cachedRoute(for: roomID) {
                result[roomID] = cached
            } else {
                misses.append(roomID)
            }
        }
        if !misses.isEmpty {
            let fetched = try await source.routes(for: misses)
            guard fetched.count == misses.count, misses.allSatisfy({ fetched[$0] != nil }) else {
                throw V2RoomShardRouteError.roomNotFound
            }
            for (roomID, route) in fetched {
                result[roomID] = insert(route, for: roomID)
            }
        }
        guard result.count == unique.count else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return result
    }

    public func withDirectPairRoute<Result: Sendable>(
        actorUserID: UserID,
        targetUserID: UserID,
        proposedShardID: String,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (
            result: Result, roomID: RoomID?
        )
    ) async throws -> Result {
        let committed = try await source.withDirectPairRoute(
            actorUserID: actorUserID,
            targetUserID: targetUserID,
            proposedShardID: proposedShardID
        ) { route in
            let completion = try await operation(route)
            return (result: (value: completion.result, roomID: completion.roomID, route: route), roomID: completion.roomID)
        }
        // The owner callback can succeed before the control directory fails.
        // Publish a route only after that outer transaction also commits.
        if let roomID = committed.roomID {
            insert(committed.route, for: roomID)
        }
        return committed.value
    }

    private func cachedRoute(for roomID: RoomID) -> V2RoomShardRoute? {
        let now = now()
        let bucket = bucket(for: roomID)
        return bucket.state.withLock { state in
            guard let entry = state.entries[roomID] else { return nil }
            guard entry.expiresAt > now else {
                // Keep its epoch while a refresh is in flight. The entry is
                // still subject to the same bucket capacity and eviction.
                return nil
            }
            return entry.route
        }
    }

    @discardableResult
    private func insert(_ route: V2RoomShardRoute, for roomID: RoomID) -> V2RoomShardRoute {
        let observedAt = now()
        let expiresAt = observedAt + lifetime
        let bucket = bucket(for: roomID)
        return bucket.state.withLock { state in
            // Directory reads can finish out of order. An older result must
            // neither replace a newer hint nor extend its expiration, even
            // when that hint has expired while this read was in flight.
            if let existing = state.entries[roomID], existing.route.epoch > route.epoch {
                return existing.route
            }
            if state.entries[roomID] == nil,
               state.entries.count >= bucket.capacity {
                // Routes are uniformly distributed IDs and every bucket is
                // bounded. Arbitrary replacement avoids a serialized global
                // LRU mutation on this very high-frequency lookup path.
                state.entries.remove(at: state.entries.startIndex)
            }
            state.entries[roomID] = .init(
                route: route, expiresAt: expiresAt
            )
            return route
        }
    }

    private func bucket(for roomID: RoomID) -> Bucket {
        var hasher = Hasher()
        hasher.combine(roomID)
        let hash = hasher.finalize()
        return buckets[Int(UInt(bitPattern: hash) % UInt(buckets.count))]
    }
}
