import Foundation
import IMV2Core

/// Ephemeral account membership is shared by its connections. This index is
/// only a routing candidate source; database authorization precedes enqueue.
// Non-Sendable: exclusively owned by V2AccountRoomChangeService.
final class V2AccountRoomCoverageIndex {
    struct Ticket: Equatable, Sendable {
        let userID: UserID
        let connectionID: UUID
        let epoch: UUID
    }

    struct Candidate: Equatable, Sendable {
        let userID: UserID
        let roomID: RoomID
        let accountEpoch: UUID
        let membershipRevision: UInt64
        let ownerEpoch: UInt64
    }

    private struct Membership: Sendable {
        let revision: UInt64
        let ownerEpoch: UInt64
    }

    // Never escapes its owning service. Reference storage avoids copying a large
    // membership dictionary for every bounded directory page or connection.
    private final class Account {
        let epoch = UUID()
        var connections: Set<UUID> = []
        var rooms: [RoomID: Membership] = [:]
        var revokedThrough: [RoomID: UInt64] = [:]
    }

    private struct Connection: Sendable {
        let ticket: Ticket
        var buffer: V2AccountRoomChangeBuffer
    }

    private let maximumPendingRooms: Int
    private var accounts: [UserID: Account] = [:]
    private var connections: [UUID: Connection] = [:]
    private var usersByRoom: [RoomID: Set<UserID>] = [:]

    init(maximumPendingRooms: Int = 4096) throws {
        guard maximumPendingRooms > 0 else { throw V2RoomRecoveryReadError.invalidRequest }
        self.maximumPendingRooms = maximumPendingRooms
    }

    func begin(userID: UserID, connectionID: UUID) throws -> Ticket {
        guard userID.uuidValue != nil, connections[connectionID] == nil else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        let ticket = Ticket(userID: userID, connectionID: connectionID, epoch: UUID())
        connections[connectionID] = try .init(ticket: ticket,
            buffer: .init(epoch: ticket.epoch, maximumPendingRooms: maximumPendingRooms))
        let account = accounts[userID] ?? Account()
        account.connections.insert(connectionID)
        accounts[userID] = account
        return ticket
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        connections[ticket.connectionID]?.ticket == ticket
    }

    /// Returns globally inactive rooms so the owner can release broker interest.
    func end(_ ticket: Ticket) -> Set<RoomID> {
        guard isCurrent(ticket) else { return [] }
        connections.removeValue(forKey: ticket.connectionID)
        accounts[ticket.userID]?.connections.remove(ticket.connectionID)
        guard accounts[ticket.userID]?.connections.isEmpty == true,
              let account = accounts.removeValue(forKey: ticket.userID) else { return [] }
        var inactive: Set<RoomID> = []
        for room in account.rooms.keys {
            usersByRoom[room]?.remove(ticket.userID)
            if usersByRoom[room]?.isEmpty == true {
                usersByRoom.removeValue(forKey: room)
                inactive.insert(room)
            }
        }
        return inactive
    }

    struct Entry: Sendable {
        let roomID: RoomID
        let viewerMembershipRevision: UInt64
        let ownerEpoch: UInt64
    }

    /// Install only owner-validated directory entries. The caller must await
    /// broker activation before returning the corresponding page to the client.
    func install(_ entries: [V2UserRoomDirectoryEntry], ticket: Ticket) throws -> Set<RoomID> {
        try install(entries.map { Entry(roomID: $0.roomID,
            viewerMembershipRevision: $0.viewerMembershipRevision, ownerEpoch: $0.ownerEpoch) }, ticket: ticket)
    }

    func install(_ entries: [Entry], ticket: Ticket) throws -> Set<RoomID> {
        guard entries.count <= 100, Set(entries.map(\.roomID)).count == entries.count else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        guard isCurrent(ticket), let account = accounts[ticket.userID] else { return [] }
        var activated: Set<RoomID> = []
        for entry in entries {
            guard entry.viewerMembershipRevision > account.revokedThrough[entry.roomID, default: 0] else { continue }
            if let existing = account.rooms[entry.roomID] {
                guard entry.viewerMembershipRevision >= existing.revision,
                      entry.ownerEpoch >= existing.ownerEpoch else { continue }
            }
            if usersByRoom[entry.roomID] == nil { activated.insert(entry.roomID) }
            usersByRoom[entry.roomID, default: []].insert(ticket.userID)
            account.rooms[entry.roomID] = .init(revision: entry.viewerMembershipRevision, ownerEpoch: entry.ownerEpoch)
        }
        return activated
    }

    func contains(_ entry: Entry, userID: UserID) -> Bool {
        guard let membership = accounts[userID]?.rooms[entry.roomID] else { return false }
        return membership.revision == entry.viewerMembershipRevision && membership.ownerEpoch == entry.ownerEpoch
    }

    func candidates(roomID: RoomID) -> [Candidate] {
        (usersByRoom[roomID] ?? []).compactMap { user in
            guard let membership = accounts[user]?.rooms[roomID] else { return nil }
            return .init(userID: user, roomID: roomID, accountEpoch: accounts[user]!.epoch,
                         membershipRevision: membership.revision, ownerEpoch: membership.ownerEpoch)
        }
    }

    /// A state read binds current authorization and head in one owner snapshot.
    /// A membership/owner mismatch requires recovery rather than using the cache.
    func enqueueAuthorized(_ state: V2RoomSynchronizationState, candidate: Candidate) throws {
        guard state.roomID == candidate.roomID else { throw V2RoomRecoveryReadError.corruptPersistence }
        guard let account = accounts[candidate.userID], account.epoch == candidate.accountEpoch,
              let membership = account.rooms[state.roomID],
              membership.revision == candidate.membershipRevision,
              membership.ownerEpoch == candidate.ownerEpoch else { return }
        guard membership.revision == state.viewerMembershipRevision, membership.ownerEpoch == state.ownerEpoch else {
            invalidate(userID: candidate.userID)
            return
        }
        for id in account.connections {
            try connections[id]?.buffer.offer(roomID: state.roomID, highWatermark: state.head)
        }
    }

    /// Negative membership facts fence late directory and state responses.
    func revoke(userID: UserID, roomID: RoomID, revision: UInt64) throws {
        guard revision > 0, revision <= UInt64(Int64.max) else { throw V2RoomRecoveryReadError.invalidRequest }
        guard let account = accounts[userID] else { return }
        if let existing = account.rooms[roomID], existing.revision > revision { return }
        account.revokedThrough[roomID] = max(account.revokedThrough[roomID, default: 0], revision)
        account.rooms.removeValue(forKey: roomID)
        usersByRoom[roomID]?.remove(userID)
        if usersByRoom[roomID]?.isEmpty == true { usersByRoom.removeValue(forKey: roomID) }
        // A durable membership removal is a known fact, not a transport gap.
        // Preserve other rooms and the epoch so consuming its personal event
        // does not create a reconnect/replay loop.
        for id in account.connections { connections[id]?.buffer.revoke(roomID: roomID) }
    }

    func invalidate(userID: UserID) {
        for id in accounts[userID]?.connections ?? [] { connections[id]?.buffer.invalidate() }
    }

    @discardableResult
    func invalidate(candidate: Candidate) -> Bool {
        guard let account = accounts[candidate.userID], account.epoch == candidate.accountEpoch,
              let membership = account.rooms[candidate.roomID],
              membership.revision == candidate.membershipRevision,
              membership.ownerEpoch == candidate.ownerEpoch else { return false }
        invalidate(userID: candidate.userID)
        return true
    }

    func next(ticket: Ticket) -> V2AccountRoomNotification? {
        guard isCurrent(ticket) else { return nil }
        return connections[ticket.connectionID]?.buffer.next()
    }

    func hasPending(ticket: Ticket) -> Bool {
        isCurrent(ticket) && connections[ticket.connectionID]?.buffer.hasOutput == true
    }

    func metrics() -> (accounts: Int, connections: Int, memberships: Int) {
        (accounts.count, connections.count, accounts.values.reduce(0) { $0 + $1.rooms.count })
    }
}
