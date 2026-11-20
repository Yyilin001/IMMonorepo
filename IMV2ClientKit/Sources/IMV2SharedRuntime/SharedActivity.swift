import Foundation
import IMV2Core
import IMV2ClientRuntime

struct SharedActivityView: Encodable, Sendable {
    let roomID: String
    let isGroup: Bool
    let isOnline: Bool?
    let typingUserIDs: [String]
}

/// Owns one room's transient presence/typing subscription and the outgoing
/// typing lease. Snapshot replacement keeps TTL expiry authoritative.
actor SharedActivity {
    private let accountID: UserID
    private let transport: V2ClientLiveActivityTransport
    private let rooms: V2RoomSubscriptionCoordinator
    private var room: RoomID?
    private var group = false
    private var lease: V2RoomSubscriptionLease?
    private var observer: Task<Void, Never>?
    private var snapshot: V2RoomSubscriptionSnapshot?
    private var typingTask: Task<Void, Never>?

    init(accountID: UserID, transport: V2ClientLiveActivityTransport, rooms: V2RoomSubscriptionCoordinator) {
        self.accountID = accountID; self.transport = transport; self.rooms = rooms
    }

    func open(room: RoomID, isGroup: Bool) async throws {
        guard self.room != room || group != isGroup else { return }
        await close()
        let channels: Set<V2RoomSubscriptionChannel> = isGroup ? [.typing] : [.typing, .presence]
        let lease = try await rooms.acquire(roomID: room, channels: channels)
        self.room = room; group = isGroup; self.lease = lease
        observer = Task { [weak self] in
            for await value in lease.updates {
                guard let self else { return }
                await self.publish(value)
            }
        }
    }
    private func publish(_ value: V2RoomSubscriptionSnapshot) { snapshot = value }

    func close() async {
        typingTask?.cancel(); typingTask = nil
        let previous = lease
        lease = nil; observer?.cancel(); observer = nil; snapshot = nil
        if let previous { await rooms.release(roomID: previous.roomID, consumerID: previous.id) }
        room = nil
    }

    func setTyping(_ typing: Bool) async throws {
        guard let room else { return }
        try await transport.setTyping(roomID: room, isTyping: typing)
    }

    func view() -> SharedActivityView? {
        guard let room else { return nil }
        let now = Date()
        let typing = (snapshot?.typing ?? []).filter {
            $0.isTyping && $0.expiresAt > now && $0.userID != accountID
        }.map(\.userID.rawValue)
        let presence = snapshot?.presence.flatMap { $0.expiresAt > now ? $0.isOnline : nil }
        return SharedActivityView(roomID: room.rawValue, isGroup: group, isOnline: presence, typingUserIDs: typing)
    }
}
