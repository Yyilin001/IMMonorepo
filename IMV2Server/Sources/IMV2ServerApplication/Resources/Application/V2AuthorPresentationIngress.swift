import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization

/// Synchronous, bounded handoff from committed-message delivery to the optional
/// dispatcher. One owned consumer exists for this whole process, never one Task
/// per recipient. Call close before closing the dispatcher or its dependencies.
public final class V2AuthorPresentationIngress: Sendable {
    public struct Configuration: Sendable {
        public let maximumOffers, maximumKeys, maximumChargedBytes: Int
        public let lifetime: Duration
        public init(maximumOffers: Int = 256, maximumKeys: Int = 1_024,
                    maximumChargedBytes: Int = 256 * 1_024, lifetime: Duration = .milliseconds(500)) throws {
            guard (1...256).contains(maximumOffers), (1...1_024).contains(maximumKeys),
                  (192...262_144).contains(maximumChargedBytes), lifetime > .zero,
                  lifetime <= .milliseconds(500) else { throw V2ResourceProviderError.configurationInvalid }
            self.maximumOffers = maximumOffers; self.maximumKeys = maximumKeys
            self.maximumChargedBytes = maximumChargedBytes; self.lifetime = lifetime
        }
    }
    struct Offer: Sendable {
        let connectionID: UUID, viewID: UUID
        let roomID: RoomID
        var authors: [UserID]
        let deadline: ContinuousClock.Instant
        // Admission charge for fixed identities and bounded UUID author values;
        // object/allocator overhead is additionally bounded by offer/key counts.
        var charge: Int { 128 + authors.count * 64 }
        func matches(connectionID: UUID, roomID: RoomID, viewID: UUID) -> Bool {
            self.connectionID == connectionID && self.roomID == roomID && self.viewID == viewID
        }
    }
    public struct Statistics: Sendable {
        public let pendingOffers, retainedKeys, chargedBytes, activeConsumers: Int
        public let rejected, expired: Int
        public let closed: Bool
    }
    private struct State: Sendable {
        var queue: [Offer] = []
        var active = false, closed = false
        var keys = 0, bytes = 0, rejected = 0, expired = 0
    }
    private final class SharedState: Sendable { let value = Mutex(State()) }
    private let state: SharedState
    private let configuration: Configuration
    private let signal: AsyncStream<Void>.Continuation
    private let worker: Task<Void, Never>

    public convenience init(configuration: Configuration, dispatcher: V2AuthorPresentationDispatcher) {
        self.init(configuration: configuration) { offer in
            _ = await dispatcher.offer(connectionID: offer.connectionID, roomID: offer.roomID,
                viewID: offer.viewID, authors: offer.authors, deadline: offer.deadline)
        }
    }

    init(configuration: Configuration, consume: @escaping @Sendable (Offer) async -> Void) {
        self.configuration = configuration
        let state = SharedState(); self.state = state
        let (stream, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.signal = signal
        // Capture state, not self; the owner explicitly cancels and drains this
        // task. The wake stream retains at most one empty signal.
        worker = Task {
            for await _ in stream {
                while !Task.isCancelled {
                    let next = state.value.withLock { state -> Offer? in
                        guard !state.closed, !state.queue.isEmpty else { return nil }
                        let next = state.queue.removeFirst()
                        state.active = true
                        return next
                    }
                    guard let next else { break }
                    if next.deadline > .now { await consume(next) }
                    else { state.value.withLock { $0.expired += 1 } }
                    // Actual consumption, including non-cooperative suspension,
                    // owns its charged capacity until it really returns.
                    state.value.withLock {
                        $0.active = false; $0.keys -= next.authors.count; $0.bytes -= next.charge
                    }
                }
            }
        }
    }

    /// Input is derived only from already authorized body delivery. There is no
    /// authorization cache here; the dispatcher reader must authorize anew.
    @discardableResult
    package func submit(connectionID: UUID, roomID: RoomID, viewID: UUID, authors: [UserID]) -> Bool {
        guard roomID.uuidValue != nil, (1...128).contains(authors.count),
              authors.allSatisfy({ $0.uuidValue != nil }) else { return false }
        let authors = Array(Set(authors)).sorted { $0.rawValue < $1.rawValue }
        let accepted = state.value.withLock { state -> Bool in
            guard !state.closed else { state.rejected += 1; return false }
            if let index = state.queue.firstIndex(where: { $0.matches(connectionID: connectionID, roomID: roomID, viewID: viewID) }) {
                let old = state.queue[index]
                let merged = Array(Set(old.authors + authors)).sorted { $0.rawValue < $1.rawValue }
                let added = merged.count - old.authors.count
                guard merged.count <= 128, state.keys + added <= configuration.maximumKeys,
                      state.bytes + added * 64 <= configuration.maximumChargedBytes else {
                    state.rejected += 1; return false
                }
                state.queue[index].authors = merged
                state.keys += added; state.bytes += added * 64
                return true // Keep the original deadline; merging never renews it.
            }
            let offer = Offer(connectionID: connectionID, viewID: viewID, roomID: roomID,
                authors: authors, deadline: .now + configuration.lifetime)
            guard state.queue.count + (state.active ? 1 : 0) < configuration.maximumOffers,
                  state.keys + authors.count <= configuration.maximumKeys,
                  state.bytes + offer.charge <= configuration.maximumChargedBytes else {
                state.rejected += 1; return false
            }
            state.queue.append(offer); state.keys += authors.count; state.bytes += offer.charge
            return true
        }
        if accepted { signal.yield(()) }
        return accepted
    }

    public func statistics() -> Statistics {
        state.value.withLock { .init(pendingOffers: $0.queue.count, retainedKeys: $0.keys, chargedBytes: $0.bytes,
            activeConsumers: $0.active ? 1 : 0, rejected: $0.rejected, expired: $0.expired, closed: $0.closed) }
    }

    public func close() async {
        state.value.withLock {
            $0.closed = true
            for offer in $0.queue { $0.keys -= offer.authors.count; $0.bytes -= offer.charge }
            $0.queue.removeAll()
        }
        signal.finish(); worker.cancel()
        await worker.value
    }
}

/// Decode once per authorized body event/batch, and only when the ingress is
/// installed. The hint contains no display fields, token or cached permission.
package struct V2AuthorPresentationHints: Sendable {
    package let roomID: RoomID
    package let authors: [UserID]
    private struct Payload: Decodable {
        let event_type, room_id, sender_user_id: String
        let room_sequence: UInt64
    }
    package init?(events: [V2DirectRoomLiveEvent]) {
        guard events.first?.groupMembershipRevision != nil else { return nil }
        self.init(validatedEvents: events)
    }

    package init?(directEvent: V2DirectRoomLiveEvent) {
        guard directEvent.groupMembershipRevision == nil, !directEvent.recipientUserIDs.isEmpty else { return nil }
        self.init(validatedEvents: [directEvent])
    }

    private init?(validatedEvents events: [V2DirectRoomLiveEvent]) {
        guard let first = events.first else { return nil }
        let decoder = JSONDecoder()
        var authors = Set<UserID>(), examinedBytes = 0
        for event in events.prefix(128) {
            guard event.roomID == first.roomID, event.groupMembershipRevision == first.groupMembershipRevision else { return nil }
            guard event.projectionKind == "message" else { continue }
            guard event.payload.count <= 65_536 - examinedBytes else { break }
            examinedBytes += event.payload.count
            guard let payload = try? decoder.decode(Payload.self, from: event.payload),
                  payload.event_type == "message.accepted", payload.room_sequence == event.roomSequence,
                  (try? RoomID(payload.room_id)) == first.roomID,
                  let user = UUID(uuidString: payload.sender_user_id) else { continue }
            authors.insert(UserID(uuid: user))
        }
        guard !authors.isEmpty else { return nil }
        roomID = first.roomID; self.authors = authors.sorted { $0.rawValue < $1.rawValue }
    }

    /// Only invoked after the authorized page has crossed its response writer.
    /// Keep a small first-page sample; the server does not know visible rows.
    package init?(page: V2AuthorPresentationPageSample) {
        let decoder = JSONDecoder()
        var authors = Set<UserID>(), ordered: [UserID] = []
        for entry in page.events {
            guard let payload = try? decoder.decode(Payload.self, from: entry.payload),
                  payload.event_type == "message.accepted", payload.room_sequence == entry.roomSequence,
                  (try? RoomID(payload.room_id)) == page.roomID,
                  let id = UUID(uuidString: payload.sender_user_id) else { continue }
            let user = UserID(uuid: id)
            if authors.insert(user).inserted { ordered.append(user) }
            if ordered.count == V2AuthorPresentationPageSample.maximumAuthors { break }
        }
        guard !ordered.isEmpty else { return nil }
        roomID = page.roomID; self.authors = ordered
    }
}
