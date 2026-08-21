import Foundation
import IMV2Core

/// A bounded process-local acceleration cache for plain, canonical direct
/// room-log events. It is deliberately not an authorization cache: callers
/// must obtain a fresh membership fence from PostgreSQL before asking for a
/// page, and every uncertain range falls back to the durable event log.
public actor V2DirectRoomLogEventCache {
    public struct Configuration: Equatable, Sendable {
        public let maximumEvents: Int
        public let maximumBytes: Int
        public let maximumEventsPerRoom: Int

        public init(
            maximumEvents: Int,
            maximumBytes: Int,
            maximumEventsPerRoom: Int
        ) {
            precondition(maximumEvents > 0)
            precondition(maximumBytes > 0)
            precondition(maximumEventsPerRoom > 0)
            self.maximumEvents = maximumEvents
            self.maximumBytes = maximumBytes
            self.maximumEventsPerRoom = maximumEventsPerRoom
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let cachedEvents: Int
        public let cachedRooms: Int
        public let cachedBytes: Int
        public let hits: UInt64
        public let misses: UInt64
        public let bypassedIneligibleEvents: UInt64

        public init(
            cachedEvents: Int,
            cachedRooms: Int,
            cachedBytes: Int,
            hits: UInt64,
            misses: UInt64,
            bypassedIneligibleEvents: UInt64
        ) {
            self.cachedEvents = cachedEvents
            self.cachedRooms = cachedRooms
            self.cachedBytes = cachedBytes
            self.hits = hits
            self.misses = misses
            self.bypassedIneligibleEvents = bypassedIneligibleEvents
        }
    }

    private struct CachedEvent: Sendable {
        let entry: V2GroupEventLogEntry
        let membershipRevision: UInt64
        let byteCost: Int
    }

    private struct RoomEntries: Sendable {
        var events: [CachedEvent]
        var lastAccess: UInt64
    }

    private let configuration: Configuration
    private var rooms: [String: RoomEntries] = [:]
    private var cachedEventCount = 0
    private var cachedByteCount = 0
    private var accessClock: UInt64 = 0
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0
    private var bypassedIneligibleEvents: UInt64 = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Records only an already-committed, plain direct-room message. Cache
    /// construction errors are intentionally a local miss rather than a
    /// message-send failure.
    public func recordCommittedPlainDirectMessage(_ message: V2AcceptedMessage) {
        guard message.usesRoomEventLog,
              message.groupDeliveryMode == nil,
              message.media.isEmpty,
              message.mentions.isEmpty,
              message.replyTo == nil,
              let sourceEventID = message.sourceEventID,
              let membershipRevision = message.acceptedMembershipRevision,
              let payload = Self.payload(for: message)
        else {
            bypassedIneligibleEvents &+= 1
            return
        }

        let event = CachedEvent(
            entry: .init(
                sourceEventID: sourceEventID,
                roomSequence: message.roomSequence,
                projectionKind: "message",
                payload: payload
            ),
            membershipRevision: membershipRevision,
            byteCost: payload.count + 128
        )
        guard event.byteCost <= configuration.maximumBytes else {
            bypassedIneligibleEvents &+= 1
            return
        }

        let roomKey = message.roomID.rawValue
        var entries = rooms[roomKey] ?? .init(events: [], lastAccess: nextAccess())
        if let existingIndex = entries.events.firstIndex(
            where: { $0.entry.roomSequence == event.entry.roomSequence }
        ) {
            let existing = entries.events[existingIndex]
            guard existing.entry.sourceEventID == event.entry.sourceEventID,
                  existing.membershipRevision == event.membershipRevision,
                  existing.entry.payload == event.entry.payload
            else {
                // A contradictory local observation must never be resolved
                // by guesswork. Drop the entire room and force durable reads.
                removeRoom(roomKey)
                bypassedIneligibleEvents &+= 1
                return
            }
            entries.lastAccess = nextAccess()
            rooms[roomKey] = entries
            return
        }

        entries.events.append(event)
        entries.events.sort { $0.entry.roomSequence < $1.entry.roomSequence }
        entries.lastAccess = nextAccess()
        rooms[roomKey] = entries
        cachedEventCount += 1
        cachedByteCount += event.byteCost

        while entries.events.count > configuration.maximumEventsPerRoom,
              let evicted = entries.events.first {
            entries.events.removeFirst()
            cachedEventCount -= 1
            cachedByteCount -= evicted.byteCost
        }
        rooms[roomKey] = entries
        evictIfNeeded()
    }

    /// Returns a page only when every sequence from the caller's cursor is
    /// locally known and visible under the freshly-read membership fence.
    /// A cache miss is semantically invisible: callers use the durable store.
    public func page(
        roomID: RoomID,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) -> V2GroupEventLogPage? {
        precondition(pageSize > 0)
        let roomKey = roomID.rawValue
        guard afterRoomSequence <= currentHighWatermark else {
            misses &+= 1
            return nil
        }
        if afterRoomSequence == currentHighWatermark {
            hits &+= 1
            return .init(
                roomID: roomID,
                events: [],
                nextRoomSequence: afterRoomSequence,
                hasMore: false
            )
        }
        guard var entries = rooms[roomKey] else {
            misses &+= 1
            return nil
        }
        guard afterRoomSequence < UInt64.max else {
            misses &+= 1
            return nil
        }

        var expectedSequence = afterRoomSequence + 1
        var page: [V2GroupEventLogEntry] = []
        page.reserveCapacity(pageSize)
        for event in entries.events where event.entry.roomSequence >= expectedSequence {
            guard event.entry.roomSequence == expectedSequence,
                  isVisible(
                      eventMembershipRevision: event.membershipRevision,
                      actorJoinedRevision: actorJoinedRevision,
                      actorLeftRevision: actorLeftRevision
                  )
            else {
                misses &+= 1
                return nil
            }
            page.append(event.entry)
            if page.count == pageSize { break }
            guard expectedSequence < UInt64.max else {
                misses &+= 1
                return nil
            }
            expectedSequence += 1
        }
        guard let last = page.last else {
            misses &+= 1
            return nil
        }
        if page.count < pageSize, last.roomSequence != currentHighWatermark {
            // A cached subset must not claim a complete page across an
            // unknown gap (for example an edit or a message from another
            // gateway that has not reached this process).
            misses &+= 1
            return nil
        }
        entries.lastAccess = nextAccess()
        rooms[roomKey] = entries
        hits &+= 1
        return .init(
            roomID: roomID,
            events: page,
            nextRoomSequence: last.roomSequence,
            hasMore: last.roomSequence < currentHighWatermark
        )
    }

    public func snapshot() -> Snapshot {
        .init(
            cachedEvents: cachedEventCount,
            cachedRooms: rooms.count,
            cachedBytes: cachedByteCount,
            hits: hits,
            misses: misses,
            bypassedIneligibleEvents: bypassedIneligibleEvents
        )
    }

    private func nextAccess() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func removeRoom(_ key: String) {
        guard let removed = rooms.removeValue(forKey: key) else { return }
        cachedEventCount -= removed.events.count
        cachedByteCount -= removed.events.reduce(into: 0) { $0 += $1.byteCost }
    }

    private func evictIfNeeded() {
        while (cachedEventCount > configuration.maximumEvents || cachedByteCount > configuration.maximumBytes),
              let leastRecentlyUsed = rooms.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            removeRoom(leastRecentlyUsed)
        }
    }

    private func isVisible(
        eventMembershipRevision: UInt64,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?
    ) -> Bool {
        actorJoinedRevision <= eventMembershipRevision
            && (actorLeftRevision == nil || actorLeftRevision! > eventMembershipRevision)
    }

    private static func payload(for message: V2AcceptedMessage) -> Data? {
        guard let entitiesData = try? JSONEncoder().encode(message.entities),
              let entities = try? JSONSerialization.jsonObject(with: entitiesData)
        else { return nil }
        let body: [String: Any] = [
            "event_type": "message.accepted",
            "message_id": message.messageID.rawValue,
            "room_id": message.roomID.rawValue,
            "room_sequence": message.roomSequence,
            "timeline_sequence": message.timelineSequence,
            "sender_user_id": message.senderUserID.rawValue,
            "text": message.text,
            "media_ids": [],
            "media_presentations": [],
            "mention_user_ids": [],
            "mentions_everyone": false,
            "entities": entities,
            "reply_to_message_id": NSNull(),
            "forwarded_from_message_id": NSNull(),
            "forwarded_from_user_id": NSNull(),
            "message_revision": 1,
            "server_created_at_ms": Int64(message.createdAt.timeIntervalSince1970 * 1_000),
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
