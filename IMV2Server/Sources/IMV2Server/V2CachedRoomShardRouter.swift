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
        let state = Mutex(BucketState())
    }

    private let source: any V2DirectRoomShardRouting
    private let buckets: [Bucket]
    private let capacityPerBucket: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()

    public init(
        source: any V2DirectRoomShardRouting,
        capacity: Int = 250_000,
        lifetime: Duration = .seconds(300),
        bucketCount: Int = 64
    ) {
        let count = max(1, bucketCount)
        self.source = source
        buckets = (0 ..< count).map { _ in Bucket() }
        capacityPerBucket = max(1, (max(1, capacity) + count - 1) / count)
        self.lifetime = max(.seconds(1), lifetime)
    }

    public func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        if let cached = cachedRoute(for: roomID) { return cached }
        let route = try await source.route(for: roomID)
        insert(route, for: roomID)
        return route
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
            guard fetched.count == misses.count else {
                throw V2RoomShardRouteError.roomNotFound
            }
            for (roomID, route) in fetched {
                insert(route, for: roomID)
                result[roomID] = route
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
        try await source.withDirectPairRoute(
            actorUserID: actorUserID,
            targetUserID: targetUserID,
            proposedShardID: proposedShardID
        ) { [self] route in
            let completion = try await operation(route)
            if let roomID = completion.roomID {
                insert(route, for: roomID)
            }
            return completion
        }
    }

    private func cachedRoute(for roomID: RoomID) -> V2RoomShardRoute? {
        let now = clock.now
        let bucket = bucket(for: roomID)
        return bucket.state.withLock { state in
            guard let entry = state.entries[roomID] else { return nil }
            guard entry.expiresAt > now else {
                state.entries.removeValue(forKey: roomID)
                return nil
            }
            return entry.route
        }
    }

    private func insert(_ route: V2RoomShardRoute, for roomID: RoomID) {
        let expiresAt = clock.now + lifetime
        let bucket = bucket(for: roomID)
        bucket.state.withLock { state in
            if state.entries[roomID] == nil,
               state.entries.count >= capacityPerBucket {
                // Routes are uniformly distributed IDs and every bucket is
                // bounded. Arbitrary replacement avoids a serialized global
                // LRU mutation on this very high-frequency lookup path.
                state.entries.remove(at: state.entries.startIndex)
            }
            state.entries[roomID] = .init(
                route: route, expiresAt: expiresAt
            )
        }
    }

    private func bucket(for roomID: RoomID) -> Bucket {
        var hasher = Hasher()
        hasher.combine(roomID)
        let hash = hasher.finalize()
        return buckets[Int(UInt(bitPattern: hash) % UInt(buckets.count))]
    }
}
