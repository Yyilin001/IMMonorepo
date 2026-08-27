import Foundation
import IMV2Core
import Synchronization

/// A bounded process-local acceleration cache for plain, canonical direct
/// room-log events. It is deliberately not an authorization cache: callers
/// must obtain a fresh membership fence from PostgreSQL before returning a
/// candidate page, and every uncertain range falls back to the durable log.
///
/// Room state is hash-sharded so unrelated conversations do not serialize on
/// one actor. Each shard owns an O(1) room LRU and an exact share of the global
/// entry/byte budgets; the aggregate can never exceed the configured limits.
public final class V2DirectRoomLogEventCache: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let maximumEvents: Int
        public let maximumBytes: Int
        public let maximumEventsPerRoom: Int
        public let shardCount: Int
        public let maximumPendingWrites: Int

        public init(
            maximumEvents: Int,
            maximumBytes: Int,
            maximumEventsPerRoom: Int,
            shardCount: Int = 16,
            maximumPendingWrites: Int = 4_096
        ) {
            precondition(maximumEvents > 0)
            precondition(maximumBytes > 0)
            precondition(maximumEventsPerRoom > 0)
            precondition(shardCount > 0)
            precondition(maximumPendingWrites > 0)
            self.maximumEvents = maximumEvents
            self.maximumBytes = maximumBytes
            self.maximumEventsPerRoom = maximumEventsPerRoom
            self.shardCount = shardCount
            self.maximumPendingWrites = maximumPendingWrites
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let cachedEvents: Int
        public let cachedRooms: Int
        public let cachedBytes: Int
        public let hits: UInt64
        public let misses: UInt64
        public let bypassedIneligibleEvents: UInt64
        public let pendingWrites: Int
        public let droppedWrites: UInt64

        public init(
            cachedEvents: Int,
            cachedRooms: Int,
            cachedBytes: Int,
            hits: UInt64,
            misses: UInt64,
            bypassedIneligibleEvents: UInt64,
            pendingWrites: Int = 0,
            droppedWrites: UInt64 = 0
        ) {
            self.cachedEvents = cachedEvents
            self.cachedRooms = cachedRooms
            self.cachedBytes = cachedBytes
            self.hits = hits
            self.misses = misses
            self.bypassedIneligibleEvents = bypassedIneligibleEvents
            self.pendingWrites = pendingWrites
            self.droppedWrites = droppedWrites
        }

        static let empty = Self(
            cachedEvents: 0,
            cachedRooms: 0,
            cachedBytes: 0,
            hits: 0,
            misses: 0,
            bypassedIneligibleEvents: 0,
            pendingWrites: 0,
            droppedWrites: 0
        )

        static func + (lhs: Self, rhs: Self) -> Self {
            .init(
                cachedEvents: lhs.cachedEvents + rhs.cachedEvents,
                cachedRooms: lhs.cachedRooms + rhs.cachedRooms,
                cachedBytes: lhs.cachedBytes + rhs.cachedBytes,
                hits: lhs.hits &+ rhs.hits,
                misses: lhs.misses &+ rhs.misses,
                bypassedIneligibleEvents:
                    lhs.bypassedIneligibleEvents &+ rhs.bypassedIneligibleEvents,
                pendingWrites: lhs.pendingWrites + rhs.pendingWrites,
                droppedWrites: lhs.droppedWrites &+ rhs.droppedWrites
            )
        }
    }

    /// Immutable cache coverage captured before the durable authorization
    /// read. It carries no identity and cannot authorize a response by itself.
    struct Candidate: Sendable {
        struct Event: Sendable {
            let entry: V2GroupEventLogEntry
            let membershipRevision: UInt64
        }

        let roomID: RoomID
        let afterRoomSequence: UInt64
        let pageSize: Int
        let events: [Event]

        func authorizedPage(
            actorJoinedRevision: UInt64,
            actorLeftRevision: UInt64?,
            currentHighWatermark: UInt64
        ) -> V2GroupEventLogPage? {
            guard afterRoomSequence <= currentHighWatermark else { return nil }
            if afterRoomSequence == currentHighWatermark {
                return .init(
                    roomID: roomID,
                    events: [],
                    nextRoomSequence: afterRoomSequence,
                    hasMore: false
                )
            }
            guard let first = events.first,
                  afterRoomSequence < UInt64.max,
                  first.entry.roomSequence == afterRoomSequence + 1,
                  let last = events.last,
                  last.entry.roomSequence <= currentHighWatermark
            else { return nil }
            for event in events {
                guard actorJoinedRevision <= event.membershipRevision,
                      actorLeftRevision == nil || actorLeftRevision! > event.membershipRevision
                else { return nil }
            }
            guard events.count == pageSize || last.entry.roomSequence == currentHighWatermark
            else { return nil }
            return .init(
                roomID: roomID,
                events: events.map(\.entry),
                nextRoomSequence: last.entry.roomSequence,
                hasMore: last.entry.roomSequence < currentHighWatermark
            )
        }
    }

    fileprivate struct PreparedEvent: Sendable {
        let roomID: RoomID
        let entry: V2GroupEventLogEntry
        let membershipRevision: UInt64
        let byteCost: Int
    }

    private struct Lane: Sendable {
        let cache: V2DirectRoomLogEventCacheShard
        let mailbox: V2DirectRoomLogEventCacheMailbox
    }

    private let lanes: [Lane]

    public init(configuration: Configuration) {
        // Every shard must be able to retain one room at the configured
        // per-room depth. Otherwise splitting a small test/development budget
        // could evict a room before it ever forms a contiguous page.
        let perRoomCapacity = min(
            configuration.maximumEvents,
            configuration.maximumEventsPerRoom
        )
        let maximumUsefulShards = max(1, configuration.maximumEvents / perRoomCapacity)
        let count = max(
            1,
            min(
                configuration.shardCount,
                maximumUsefulShards,
                configuration.maximumBytes,
                configuration.maximumPendingWrites
            )
        )
        lanes = (0..<count).map { index in
            .init(
                cache: V2DirectRoomLogEventCacheShard(configuration: .init(
                    maximumEvents: Self.partition(
                        configuration.maximumEvents,
                        among: count,
                        index: index
                    ),
                    maximumBytes: Self.partition(
                        configuration.maximumBytes,
                        among: count,
                        index: index
                    ),
                    maximumEventsPerRoom: configuration.maximumEventsPerRoom
                )),
                mailbox: V2DirectRoomLogEventCacheMailbox(maximumPending: Self.partition(
                    configuration.maximumPendingWrites,
                    among: count,
                    index: index
                ))
            )
        }
    }

    /// Records only an already-committed, plain direct-room message. Payload
    /// construction happens before entering the room shard, keeping JSON CPU
    /// out of the shard's isolation domain.
    public func recordCommittedPlainDirectMessage(_ message: V2AcceptedMessage) async {
        guard let prepared = Self.prepare(message) else {
            await lane(for: message.roomID).cache.recordBypass()
            return
        }
        await lane(for: message.roomID).cache.record(prepared)
    }

    /// Hot-path entry point used after a durable message commit. The accepted
    /// response waits only for one bounded shard-mailbox append; JSON creation,
    /// ordering and LRU mutation run in the runtime-owned writer task.
    public func enqueueCommittedPlainDirectMessage(_ message: V2AcceptedMessage) {
        guard Self.isEligible(message) else {
            lane(for: message.roomID).mailbox.recordBypass()
            return
        }
        lane(for: message.roomID).mailbox.enqueue(message)
    }

    /// Own this loop with one runtime task. Each lane is drained by one child,
    /// preserving room order without serializing unrelated room hashes.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for lane in lanes {
                group.addTask { await Self.run(lane: lane) }
            }
            await group.waitForAll()
        }
    }

    public func finish() async {
        for lane in lanes { lane.mailbox.finish() }
    }

    /// Captures contiguous local coverage without consulting or carrying
    /// authorization. A definite miss is recorded here so callers can skip the
    /// separate lightweight authorization query and execute the durable,
    /// authorization-bearing SQL directly.
    func candidate(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) async -> Candidate? {
        precondition(pageSize > 0)
        return await lane(for: roomID).cache.candidate(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        )
    }

    /// Applies a fresh durable membership fence to an immutable candidate.
    /// The candidate is never authority; this method only centralizes the
    /// visibility/continuity checks and hit/miss accounting.
    func page(
        candidate: Candidate,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64
    ) async -> V2GroupEventLogPage? {
        let page = candidate.authorizedPage(
            actorJoinedRevision: actorJoinedRevision,
            actorLeftRevision: actorLeftRevision,
            currentHighWatermark: currentHighWatermark
        )
        await lane(for: candidate.roomID).cache.recordLookup(hit: page != nil)
        return page
    }

    /// Compatibility/testing convenience for callers that already hold the
    /// durable fence.
    public func page(
        roomID: RoomID,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) async -> V2GroupEventLogPage? {
        guard let candidate = await candidate(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        ) else { return nil }
        return await page(
            candidate: candidate,
            actorJoinedRevision: actorJoinedRevision,
            actorLeftRevision: actorLeftRevision,
            currentHighWatermark: currentHighWatermark
        )
    }

    func recordMiss(roomID: RoomID) async {
        await lane(for: roomID).cache.recordLookup(hit: false)
    }

    public func snapshot() async -> Snapshot {
        await withTaskGroup(of: Snapshot.self, returning: Snapshot.self) { group in
            for lane in lanes {
                group.addTask {
                    let cache = await lane.cache.snapshot()
                    let mailbox = lane.mailbox.snapshot()
                    return cache + mailbox
                }
            }
            var aggregate = Snapshot.empty
            for await value in group { aggregate = aggregate + value }
            return aggregate
        }
    }

    private func lane(for roomID: RoomID) -> Lane {
        lanes[Self.shardIndex(for: roomID.rawValue, count: lanes.count)]
    }

    private static func run(lane: Lane) async {
        for await _ in lane.mailbox.signals {
            if Task.isCancelled { return }
            let messages = lane.mailbox.drain()
            for message in messages {
                if Task.isCancelled { return }
                guard let prepared = prepare(message) else {
                    await lane.cache.recordBypass()
                    continue
                }
                await lane.cache.record(prepared)
            }
        }
    }

    private static func isEligible(_ message: V2AcceptedMessage) -> Bool {
        message.usesRoomEventLog &&
            message.groupDeliveryMode == nil &&
            message.media.isEmpty &&
            message.mentions.isEmpty &&
            message.replyTo == nil &&
            message.sourceEventID != nil &&
            message.acceptedMembershipRevision != nil
    }

    private static func prepare(_ message: V2AcceptedMessage) -> PreparedEvent? {
        guard isEligible(message),
              let sourceEventID = message.sourceEventID,
              let membershipRevision = message.acceptedMembershipRevision,
              let payload = V2DirectRoomLogPayloadCodec.encode(message)
        else { return nil }
        return .init(
            roomID: message.roomID,
            entry: .init(
                sourceEventID: sourceEventID,
                roomSequence: message.roomSequence,
                projectionKind: "message",
                payload: payload
            ),
            membershipRevision: membershipRevision,
            byteCost: payload.count + 128
        )
    }

    private static func partition(_ total: Int, among count: Int, index: Int) -> Int {
        total / count + (index < total % count ? 1 : 0)
    }

    private static func shardIndex(for value: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

private final class V2DirectRoomLogEventCacheMailbox: Sendable {
    private struct State: Sendable {
        var pending: [V2AcceptedMessage]
        var dropped: UInt64 = 0
        var bypassed: UInt64 = 0
        var finished = false
    }

    let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let maximumPending: Int
    private let state: Mutex<State>

    init(maximumPending: Int) {
        precondition(maximumPending > 0)
        self.maximumPending = maximumPending
        var pending: [V2AcceptedMessage] = []
        pending.reserveCapacity(maximumPending)
        state = Mutex(.init(pending: pending))
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = stream.stream
        continuation = stream.continuation
    }

    func enqueue(_ message: V2AcceptedMessage) {
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            guard state.pending.count < maximumPending else {
                state.dropped &+= 1
                return false
            }
            state.pending.append(message)
            return true
        }
        if accepted { continuation.yield() }
    }

    func recordBypass() {
        state.withLock { $0.bypassed &+= 1 }
    }

    func drain() -> [V2AcceptedMessage] {
        state.withLock { state in
            guard !state.pending.isEmpty else { return [] }
            let batch = state.pending
            state.pending.removeAll(keepingCapacity: true)
            return batch
        }
    }

    func snapshot() -> V2DirectRoomLogEventCache.Snapshot {
        state.withLock {
            .init(
                cachedEvents: 0,
                cachedRooms: 0,
                cachedBytes: 0,
                hits: 0,
                misses: 0,
                bypassedIneligibleEvents: $0.bypassed,
                pendingWrites: $0.pending.count,
                droppedWrites: $0.dropped
            )
        }
    }

    func finish() {
        let shouldFinish = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            state.pending.removeAll(keepingCapacity: false)
            return true
        }
        if shouldFinish { continuation.finish() }
    }
}

private actor V2DirectRoomLogEventCacheShard {
    struct Configuration: Sendable {
        let maximumEvents: Int
        let maximumBytes: Int
        let maximumEventsPerRoom: Int
    }

    private struct CachedEvent: Sendable {
        let entry: V2GroupEventLogEntry
        let membershipRevision: UInt64
        let byteCost: Int
    }

    private struct RoomEntries: Sendable {
        var events: [CachedEvent]
        var previousRoom: String?
        var nextRoom: String?
    }

    private let configuration: Configuration
    private var rooms: [String: RoomEntries] = [:]
    private var leastRecentlyUsedRoom: String?
    private var mostRecentlyUsedRoom: String?
    private var cachedEventCount = 0
    private var cachedByteCount = 0
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0
    private var bypassedIneligibleEvents: UInt64 = 0

    init(configuration: Configuration) {
        precondition(configuration.maximumEvents > 0 && configuration.maximumBytes > 0)
        self.configuration = configuration
    }

    func record(_ prepared: V2DirectRoomLogEventCache.PreparedEvent) {
        guard prepared.byteCost <= configuration.maximumBytes else {
            recordBypass()
            return
        }
        let roomKey = prepared.roomID.rawValue
        var room = rooms[roomKey] ?? .init(
            events: [],
            previousRoom: nil,
            nextRoom: nil
        )
        if let existingIndex = room.events.firstIndex(
            where: { $0.entry.roomSequence == prepared.entry.roomSequence }
        ) {
            let existing = room.events[existingIndex]
            guard existing.entry.sourceEventID == prepared.entry.sourceEventID,
                  existing.membershipRevision == prepared.membershipRevision,
                  existing.entry.payload == prepared.entry.payload
            else {
                removeRoom(roomKey)
                recordBypass()
                return
            }
            rooms[roomKey] = room
            touch(roomKey)
            return
        }

        room.events.append(.init(
            entry: prepared.entry,
            membershipRevision: prepared.membershipRevision,
            byteCost: prepared.byteCost
        ))
        room.events.sort { $0.entry.roomSequence < $1.entry.roomSequence }
        cachedEventCount += 1
        cachedByteCount += prepared.byteCost
        while room.events.count > configuration.maximumEventsPerRoom {
            let evicted = room.events.removeFirst()
            cachedEventCount -= 1
            cachedByteCount -= evicted.byteCost
        }
        rooms[roomKey] = room
        touch(roomKey)
        evictIfNeeded()
    }

    func recordBypass() {
        bypassedIneligibleEvents &+= 1
    }

    func candidate(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) -> V2DirectRoomLogEventCache.Candidate? {
        let roomKey = roomID.rawValue
        guard let room = rooms[roomKey], afterRoomSequence < UInt64.max else {
            misses &+= 1
            return nil
        }
        let expectedFirst = afterRoomSequence + 1
        var expected = expectedFirst
        var result: [V2DirectRoomLogEventCache.Candidate.Event] = []
        result.reserveCapacity(min(pageSize, room.events.count))
        for event in room.events where event.entry.roomSequence >= expectedFirst {
            if result.count == pageSize { break }
            guard event.entry.roomSequence == expected else {
                misses &+= 1
                return nil
            }
            result.append(.init(
                entry: event.entry,
                membershipRevision: event.membershipRevision
            ))
            guard expected < UInt64.max else { break }
            expected += 1
        }
        touch(roomKey)
        return .init(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            events: result
        )
    }

    func recordLookup(hit: Bool) {
        if hit { hits &+= 1 } else { misses &+= 1 }
    }

    func snapshot() -> V2DirectRoomLogEventCache.Snapshot {
        .init(
            cachedEvents: cachedEventCount,
            cachedRooms: rooms.count,
            cachedBytes: cachedByteCount,
            hits: hits,
            misses: misses,
            bypassedIneligibleEvents: bypassedIneligibleEvents
        )
    }

    private func touch(_ roomKey: String) {
        guard mostRecentlyUsedRoom != roomKey, var room = rooms[roomKey] else { return }
        unlink(roomKey, room: room)
        room.previousRoom = mostRecentlyUsedRoom
        room.nextRoom = nil
        if let mostRecentlyUsedRoom, var previous = rooms[mostRecentlyUsedRoom] {
            previous.nextRoom = roomKey
            rooms[mostRecentlyUsedRoom] = previous
        } else {
            leastRecentlyUsedRoom = roomKey
        }
        mostRecentlyUsedRoom = roomKey
        rooms[roomKey] = room
    }

    private func unlink(_ roomKey: String, room: RoomEntries) {
        if let previousRoom = room.previousRoom, var previous = rooms[previousRoom] {
            previous.nextRoom = room.nextRoom
            rooms[previousRoom] = previous
        } else if leastRecentlyUsedRoom == roomKey {
            leastRecentlyUsedRoom = room.nextRoom
        }
        if let nextRoom = room.nextRoom, var next = rooms[nextRoom] {
            next.previousRoom = room.previousRoom
            rooms[nextRoom] = next
        } else if mostRecentlyUsedRoom == roomKey {
            mostRecentlyUsedRoom = room.previousRoom
        }
    }

    private func removeRoom(_ roomKey: String) {
        guard let room = rooms.removeValue(forKey: roomKey) else { return }
        unlink(roomKey, room: room)
        cachedEventCount -= room.events.count
        cachedByteCount -= room.events.reduce(into: 0) { $0 += $1.byteCost }
    }

    private func evictIfNeeded() {
        while cachedEventCount > configuration.maximumEvents ||
                cachedByteCount > configuration.maximumBytes {
            guard let leastRecentlyUsedRoom else { return }
            removeRoom(leastRecentlyUsedRoom)
        }
    }
}
