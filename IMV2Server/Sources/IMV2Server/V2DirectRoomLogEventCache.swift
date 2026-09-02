import Foundation
import IMV2Core
import Synchronization

/// A bounded process-local acceleration cache for plain, canonical direct and
/// hybrid-group room-log events. It is deliberately not an authorization cache: callers
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
            // The durable high-watermark can advance after this immutable
            // cache candidate was captured. A shorter contiguous page is
            // still complete for the returned cursor range; advertise
            // `hasMore` and let the client continue instead of rebuilding the
            // same events through the substantially heavier durable query.
            // An empty candidate while the room has advanced is still
            // rejected above because it cannot move the caller's cursor.
            return .init(
                roomID: roomID,
                events: events.map(\.entry),
                nextRoomSequence: last.entry.roomSequence,
                hasMore: last.entry.roomSequence < currentHighWatermark
            )
        }
    }

    enum PreparedPageResult: Sendable {
        case prepared(V2PreparedGroupEventPageResponse)
        case eventTooLarge
        case miss
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

    /// Records only an already-committed, plain room-log message. Payload
    /// construction happens before entering the room shard, keeping JSON CPU
    /// out of the shard's isolation domain.
    public func recordCommittedPlainDirectMessage(_ message: V2AcceptedMessage) async {
        guard let prepared = Self.prepare(message) else {
            await lane(for: message.roomID).cache.recordBypass()
            return
        }
        await lane(for: message.roomID).cache.record(prepared)
    }

    /// Records an already-materialized post-commit payload before its
    /// availability hint is published. This establishes cache-before-hint
    /// ordering without re-encoding JSON or involving PostgreSQL.
    func recordCommittedPlainDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        guard let prepared = Self.prepare(event) else {
            await lane(for: event.roomID).cache.recordBypass()
            return
        }
        await lane(for: prepared.roomID).cache.record(prepared)
    }

    /// Hot-path entry point used after a durable message commit. The accepted
    /// response waits only for one bounded shard-mailbox append; JSON creation,
    /// ordering and LRU mutation run in the runtime-owned writer task.
    public func enqueueCommittedPlainDirectMessage(_ message: V2AcceptedMessage) {
        guard let prepared = Self.prepare(message) else {
            lane(for: message.roomID).mailbox.recordBypass()
            return
        }
        lane(for: prepared.roomID).mailbox.enqueue(prepared)
    }

    /// Preferred production entry point. The foreground live event and this
    /// cache share one immutable encoded payload, so post-commit acceleration
    /// no longer performs two JSON encodes or retains two full message values.
    func enqueueCommittedPlainDirectEvent(_ event: V2DirectRoomLiveEvent) {
        guard let prepared = Self.prepare(event) else {
            lane(for: event.roomID).mailbox.recordBypass()
            return
        }
        lane(for: prepared.roomID).mailbox.enqueue(prepared)
    }

    /// Batch counterpart used by the cross-Gateway relay. A decoded NATS
    /// microbatch normally belongs to one room/lane; retain that batching
    /// through the mailbox and shard actor instead of turning it back into one
    /// mutex acquisition, stream signal and actor hop per event.
    ///
    /// Grouping by lane also keeps the method correct for compatibility input
    /// containing multiple rooms. Relative order within every lane is exactly
    /// the input order, and the shard's sequence fence remains authoritative
    /// for duplicates or rare reordering.
    func enqueueCommittedPlainDirectEvents(_ events: [V2DirectRoomLiveEvent]) {
        guard !events.isEmpty else { return }
        var preparedByLane: [Int: [PreparedEvent]] = [:]
        preparedByLane.reserveCapacity(min(events.count, lanes.count))
        for event in events {
            guard let prepared = Self.prepare(event) else {
                lane(for: event.roomID).mailbox.recordBypass()
                continue
            }
            let index = laneIndex(for: prepared.roomID)
            preparedByLane[index, default: []].append(prepared)
        }
        for (index, batch) in preparedByLane {
            lanes[index].mailbox.enqueue(batch)
        }
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
        let lane = lane(for: roomID)
        // A post-commit hint can reach a foreground client before the owned
        // cache runner has consumed its mailbox signal. Materialize the
        // already-committed bounded batch before declaring a coverage miss;
        // otherwise the pull unnecessarily executes the much heavier durable
        // event reconstruction query. Authorization is deliberately still
        // performed by the caller after this identity-free candidate exists.
        await Self.materializePending(lane)
        return await lane.cache.candidate(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        )
    }

    /// Cheap identity-free coverage probe used before deciding whether the
    /// request should spend one small authorization query or go directly to
    /// the complete durable page query. It performs no event-array copy.
    func hasPreparedPageCoverage(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) async -> Bool {
        precondition(pageSize > 0)
        let lane = lane(for: roomID)
        await Self.materializePending(lane)
        return await lane.cache.hasCoverage(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        )
    }

    /// Applies the fresh durable membership fence, derives an encoded-page
    /// fingerprint inside the room shard, and consults the shared payload
    /// cache before any Candidate/domain/protobuf event array is built.
    func preparedPage(
        roomID: RoomID,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> PreparedPageResult {
        let result = try await lane(for: roomID).cache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: actorJoinedRevision,
            actorLeftRevision: actorLeftRevision,
            currentHighWatermark: currentHighWatermark,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        )
        switch result {
        case .prepared, .eventTooLarge:
            await lane(for: roomID).cache.recordLookup(hit: true)
        case .miss:
            await lane(for: roomID).cache.recordLookup(hit: false)
        }
        return result
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
        lanes[laneIndex(for: roomID)]
    }

    private func laneIndex(for roomID: RoomID) -> Int {
        Self.shardIndex(for: roomID.rawValue, count: lanes.count)
    }

    private static func run(lane: Lane) async {
        for await _ in lane.mailbox.signals {
            if Task.isCancelled { return }
            await materializePending(lane)
        }
    }

    private static func materializePending(_ lane: Lane) async {
        let events = lane.mailbox.drain()
        guard !events.isEmpty else { return }
        await lane.cache.record(events)
    }

    private static func isEligible(_ message: V2AcceptedMessage) -> Bool {
        message.usesRoomEventLog &&
            message.groupDeliveryMode != .standardFanout &&
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

    private static func prepare(_ event: V2DirectRoomLiveEvent) -> PreparedEvent? {
        guard event.projectionKind == "message",
              let membershipRevision = event.acceptedMembershipRevision
        else { return nil }
        return .init(
            roomID: event.roomID,
            entry: .init(
                sourceEventID: event.sourceEventID,
                roomSequence: event.roomSequence,
                projectionKind: event.projectionKind,
                payload: event.payload
            ),
            membershipRevision: membershipRevision,
            byteCost: event.payload.count + 128
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
        var pending: [V2DirectRoomLogEventCache.PreparedEvent]
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
        var pending: [V2DirectRoomLogEventCache.PreparedEvent] = []
        pending.reserveCapacity(maximumPending)
        state = Mutex(.init(pending: pending))
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = stream.stream
        continuation = stream.continuation
    }

    func enqueue(_ event: V2DirectRoomLogEventCache.PreparedEvent) {
        enqueue([event])
    }

    func enqueue(_ events: [V2DirectRoomLogEventCache.PreparedEvent]) {
        guard !events.isEmpty else { return }
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            let available = maximumPending - state.pending.count
            guard available > 0 else {
                state.dropped &+= UInt64(events.count)
                return false
            }
            let acceptedCount = min(available, events.count)
            state.pending.append(contentsOf: events.prefix(acceptedCount))
            state.dropped &+= UInt64(events.count - acceptedCount)
            return true
        }
        if accepted { continuation.yield() }
    }

    func recordBypass() {
        state.withLock { $0.bypassed &+= 1 }
    }

    func drain() -> [V2DirectRoomLogEventCache.PreparedEvent] {
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

    /// Actor-confined reference storage is intentional. Keeping this as a
    /// value type made `rooms[roomKey]` and the local mutation share the same
    /// Array buffer, so every append to a saturated room triggered a full
    /// Copy-on-Write clone of the retained window. The instance never crosses
    /// the shard actor boundary.
    private final class RoomEntries {
        var events: [CachedEvent]
        /// Logical head of the retained window. Removing the oldest event by
        /// `Array.removeFirst()` shifted every retained payload on every new
        /// message once a hot room reached capacity. Advancing this cursor is
        /// O(1); occasional compaction amortizes the storage reclamation.
        var firstEventIndex: Int
        var previousRoom: String?
        var nextRoom: String?

        init(
            events: [CachedEvent],
            firstEventIndex: Int,
            previousRoom: String?,
            nextRoom: String?
        ) {
            self.events = events
            self.firstEventIndex = firstEventIndex
            self.previousRoom = previousRoom
            self.nextRoom = nextRoom
        }

        var eventCount: Int { events.count - firstEventIndex }

        func removeFirstEvent() -> CachedEvent {
            precondition(firstEventIndex < events.count)
            let event = events[firstEventIndex]
            firstEventIndex += 1
            if firstEventIndex >= 1_024 && firstEventIndex * 2 >= events.count {
                events.removeFirst(firstEventIndex)
                firstEventIndex = 0
            }
            return event
        }

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
        let room = rooms[roomKey] ?? .init(
            events: [],
            firstEventIndex: 0,
            previousRoom: nil,
            nextRoom: nil
        )
        if room.firstEventIndex < room.events.count,
           prepared.entry.roomSequence < room.events[room.firstEventIndex].entry.roomSequence {
            // A retry older than the retained sliding window cannot improve
            // any future cursor page. The durable log still covers it.
            touch(roomKey)
            return
        }
        // Committed room sequences are monotonic in the common path. Append
        // that case without scanning or sorting the retained room window.
        // Retries and rare cross-task reordering use a logarithmic lookup and
        // preserve the same duplicate-consistency fence as before.
        var lowerBound = room.firstEventIndex
        var upperBound = room.events.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if room.events[middle].entry.roomSequence < prepared.entry.roomSequence {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        if lowerBound < room.events.count,
           room.events[lowerBound].entry.roomSequence == prepared.entry.roomSequence {
            let existingIndex = lowerBound
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

        let cached = CachedEvent(
            entry: prepared.entry,
            membershipRevision: prepared.membershipRevision,
            byteCost: prepared.byteCost
        )
        if lowerBound == room.events.endIndex {
            room.events.append(cached)
        } else {
            room.events.insert(cached, at: lowerBound)
        }
        cachedEventCount += 1
        cachedByteCount += prepared.byteCost
        while room.eventCount > configuration.maximumEventsPerRoom {
            let evicted = room.removeFirstEvent()
            cachedEventCount -= 1
            cachedByteCount -= evicted.byteCost
        }
        rooms[roomKey] = room
        touch(roomKey)
        evictIfNeeded()
    }

    /// Preserve a relay microbatch across the actor boundary. `record(_:)`
    /// still applies the identical duplicate, ordering and budget rules to
    /// every entry; this method only removes per-event executor scheduling.
    func record(_ prepared: [V2DirectRoomLogEventCache.PreparedEvent]) {
        for event in prepared {
            record(event)
        }
    }

    func recordBypass() {
        bypassedIneligibleEvents &+= 1
    }

    func hasCoverage(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) -> Bool {
        guard let room = rooms[roomID.rawValue],
              coverageRange(
                  room: room,
                  afterRoomSequence: afterRoomSequence,
                  pageSize: pageSize
              ) != nil
        else { return false }
        touch(roomID.rawValue)
        return true
    }

    func preparedPage(
        roomID: RoomID,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) throws -> V2DirectRoomLogEventCache.PreparedPageResult {
        let roomKey = roomID.rawValue
        guard afterRoomSequence <= currentHighWatermark,
              let room = rooms[roomKey],
              let candidateRange = coverageRange(
                  room: room,
                  afterRoomSequence: afterRoomSequence,
                  pageSize: pageSize
              )
        else { return .miss }

        if afterRoomSequence == currentHighWatermark {
            let key = V2PreparedGroupEventPageCache.PageKey(
                protocolVersion: context.frameVersion,
                roomID: roomKey,
                firstEventID: "",
                lastEventID: "",
                firstRoomSequence: 0,
                lastRoomSequence: 0,
                eventCount: 0,
                nextRoomSequence: afterRoomSequence,
                hasMore: false
            )
            let frame = try context.cache.frame(
                for: key,
                requestID: context.requestID,
                compression: context.compression,
                maximumUncompressedPayloadBytes: context.maximumUncompressedPayloadBytes,
                compressionThresholdBytes: context.compressionThresholdBytes,
                maximumExpansionRatio: context.maximumExpansionRatio
            ) {
                var envelope = IMV2Envelope()
                envelope.requestID = context.requestID
                envelope.protocolVersion = UInt32(context.frameVersion)
                envelope.groupEventPage = .init()
                envelope.groupEventPage.roomID = roomKey
                envelope.groupEventPage.nextRoomSequence = afterRoomSequence
                return envelope
            }
            touch(roomKey)
            return .prepared(.init(
                frame: frame,
                roomID: roomID,
                nextRoomSequence: afterRoomSequence,
                hasMore: false
            ))
        }

        guard !candidateRange.isEmpty,
              let firstCandidate = room.events[candidateRange].first,
              let lastCandidate = room.events[candidateRange].last,
              firstCandidate.entry.roomSequence == afterRoomSequence + 1,
              lastCandidate.entry.roomSequence <= currentHighWatermark
        else { return .miss }
        for index in candidateRange {
            let event = room.events[index]
            guard actorJoinedRevision <= event.membershipRevision,
                  actorLeftRevision == nil || actorLeftRevision! > event.membershipRevision
            else { return .miss }
        }

        let candidateHasMore =
            lastCandidate.entry.roomSequence < currentHighWatermark
        var eventFieldBytes = 0
        var includedCount = 0
        var finalHasMore = candidateHasMore
        for (offset, index) in candidateRange.enumerated() {
            let event = room.events[index]
            let candidateEventFieldBytes = eventFieldBytes
                + v2PreparedGroupEventRepeatedFieldBytes(event.entry)
            let hasMore = candidateHasMore || offset < candidateRange.count - 1
            guard v2PreparedGroupEventPageEnvelopeBytes(
                roomID: roomKey,
                eventFieldBytes: candidateEventFieldBytes,
                nextRoomSequence: event.entry.roomSequence,
                hasMore: hasMore
            ) <= context.maximumGroupEventPagePayloadBytes else {
                break
            }
            includedCount += 1
            eventFieldBytes = candidateEventFieldBytes
            finalHasMore = hasMore
        }
        guard includedCount > 0 else {
            touch(roomKey)
            return .eventTooLarge
        }

        let includedRange = candidateRange.lowerBound
            ..< (candidateRange.lowerBound + includedCount)
        let first = room.events[includedRange.lowerBound].entry
        let last = room.events[includedRange.index(before: includedRange.endIndex)].entry
        let key = V2PreparedGroupEventPageCache.PageKey(
            protocolVersion: context.frameVersion,
            roomID: roomKey,
            firstEventID: first.sourceEventID.rawValue,
            lastEventID: last.sourceEventID.rawValue,
            firstRoomSequence: first.roomSequence,
            lastRoomSequence: last.roomSequence,
            eventCount: includedCount,
            nextRoomSequence: last.roomSequence,
            hasMore: finalHasMore
        )
        let frame = try context.cache.frame(
            for: key,
            requestID: context.requestID,
            compression: context.compression,
            maximumUncompressedPayloadBytes: context.maximumUncompressedPayloadBytes,
            compressionThresholdBytes: context.compressionThresholdBytes,
            maximumExpansionRatio: context.maximumExpansionRatio
        ) {
            var envelope = IMV2Envelope()
            envelope.requestID = context.requestID
            envelope.protocolVersion = UInt32(context.frameVersion)
            envelope.groupEventPage = .init()
            envelope.groupEventPage.roomID = roomKey
            var events: [IMV2GroupEvent] = []
            events.reserveCapacity(includedCount)
            for index in includedRange {
                let entry = room.events[index].entry
                var event = IMV2GroupEvent()
                event.sourceEventID = entry.sourceEventID.rawValue
                event.roomSequence = entry.roomSequence
                event.projectionKind = entry.projectionKind
                event.payload = entry.payload
                events.append(event)
            }
            envelope.groupEventPage.events = events
            envelope.groupEventPage.nextRoomSequence = last.roomSequence
            envelope.groupEventPage.hasMore_p = finalHasMore
            return envelope
        }
        touch(roomKey)
        return .prepared(.init(
            frame: frame,
            roomID: roomID,
            nextRoomSequence: last.roomSequence,
            hasMore: finalHasMore
        ))
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
        result.reserveCapacity(min(pageSize, room.eventCount))
        for event in room.events[room.firstEventIndex...] where event.entry.roomSequence >= expectedFirst {
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

    private func coverageRange(
        room: RoomEntries,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) -> Range<Int>? {
        guard afterRoomSequence < UInt64.max else { return nil }
        let expectedFirst = afterRoomSequence + 1
        var lowerBound = room.firstEventIndex
        var upperBound = room.events.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if room.events[middle].entry.roomSequence < expectedFirst {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let start = lowerBound
        var expected = expectedFirst
        var index = start
        while index < room.events.count, index - start < pageSize {
            let sequence = room.events[index].entry.roomSequence
            guard sequence == expected else { return nil }
            index += 1
            guard expected < UInt64.max else { break }
            expected += 1
        }
        return start..<index
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
        guard mostRecentlyUsedRoom != roomKey, let room = rooms[roomKey] else { return }
        unlink(roomKey, room: room)
        room.previousRoom = mostRecentlyUsedRoom
        room.nextRoom = nil
        if let mostRecentlyUsedRoom, let previous = rooms[mostRecentlyUsedRoom] {
            previous.nextRoom = roomKey
        } else {
            leastRecentlyUsedRoom = roomKey
        }
        mostRecentlyUsedRoom = roomKey
    }

    private func unlink(_ roomKey: String, room: RoomEntries) {
        if let previousRoom = room.previousRoom, let previous = rooms[previousRoom] {
            previous.nextRoom = room.nextRoom
        } else if leastRecentlyUsedRoom == roomKey {
            leastRecentlyUsedRoom = room.nextRoom
        }
        if let nextRoom = room.nextRoom, let next = rooms[nextRoom] {
            next.previousRoom = room.previousRoom
        } else if mostRecentlyUsedRoom == roomKey {
            mostRecentlyUsedRoom = room.previousRoom
        }
    }

    private func removeRoom(_ roomKey: String) {
        guard let room = rooms.removeValue(forKey: roomKey) else { return }
        unlink(roomKey, room: room)
        cachedEventCount -= room.eventCount
        cachedByteCount -= room.events[room.firstEventIndex...].reduce(into: 0) {
            $0 += $1.byteCost
        }
    }

    private func evictIfNeeded() {
        while cachedEventCount > configuration.maximumEvents ||
                cachedByteCount > configuration.maximumBytes {
            guard let leastRecentlyUsedRoom else { return }
            removeRoom(leastRecentlyUsedRoom)
        }
    }

}

private func v2PreparedGroupEventPageEnvelopeBytes(
    roomID: String,
    eventFieldBytes: Int,
    nextRoomSequence: UInt64,
    hasMore: Bool
) -> Int {
    let pageBytes =
        v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 1,
            payloadBytes: roomID.utf8.count
        )
        + eventFieldBytes
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 3,
            value: nextRoomSequence
        )
        + (hasMore
            ? v2PreparedProtobufVarintFieldBytes(fieldNumber: 4, value: 1)
            : 0)

    return v2PreparedProtobufVarintFieldBytes(fieldNumber: 1, value: .max)
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 2,
            value: UInt64(IMV2ProtocolVersion.current)
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 62,
            payloadBytes: pageBytes
        )
}

private func v2PreparedGroupEventRepeatedFieldBytes(
    _ entry: V2GroupEventLogEntry
) -> Int {
    let eventBytes =
        v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 1,
            payloadBytes: entry.sourceEventID.rawValue.utf8.count
        )
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 2,
            value: entry.roomSequence
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 3,
            payloadBytes: entry.projectionKind.utf8.count
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 4,
            payloadBytes: entry.payload.count
        )
    return v2PreparedProtobufLengthDelimitedFieldBytes(
        fieldNumber: 2,
        payloadBytes: eventBytes
    )
}

private func v2PreparedProtobufLengthDelimitedFieldBytes(
    fieldNumber: Int,
    payloadBytes: Int
) -> Int {
    v2PreparedProtobufTagBytes(fieldNumber: fieldNumber, wireType: 2)
        + v2PreparedProtobufVarintByteCount(UInt64(payloadBytes))
        + payloadBytes
}

private func v2PreparedProtobufVarintFieldBytes(
    fieldNumber: Int,
    value: UInt64
) -> Int {
    guard value != 0 else { return 0 }
    return v2PreparedProtobufTagBytes(fieldNumber: fieldNumber, wireType: 0)
        + v2PreparedProtobufVarintByteCount(value)
}

private func v2PreparedProtobufTagBytes(
    fieldNumber: Int,
    wireType: UInt64
) -> Int {
    v2PreparedProtobufVarintByteCount((UInt64(fieldNumber) << 3) | wireType)
}

private func v2PreparedProtobufVarintByteCount(_ value: UInt64) -> Int {
    var remaining = value
    var count = 1
    while remaining >= 0x80 {
        remaining >>= 7
        count += 1
    }
    return count
}
