import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// Account connections share membership routing candidates.
/// Message authorization and watermarks belong to the room Owner authority.
// 非 Sendable：仅由 V2AccountRoomChangeService 持有。
final class V2AccountRoomCoverageIndex {
    enum Failure: Error, Equatable, Sendable { case revocationHistoryFull }
    private let maximumRevokedRoomsPerAccount: Int

    init(maximumRevokedRoomsPerAccount: Int = 4096) {
        precondition(maximumRevokedRoomsPerAccount > 0)
        self.maximumRevokedRoomsPerAccount = maximumRevokedRoomsPerAccount
    }

    struct Ticket: Equatable, Sendable {
        let userID: UserID
        let connectionID: UUID
        let epoch: UUID
    }

    struct Candidate: Equatable, Sendable {
        let userID: UserID
        let membershipRevision: UInt64
        let ownerEpoch: UInt64
    }

    private struct Membership: Sendable {
        let revision: UInt64
        let ownerEpoch: UInt64
    }

    // 绝不逃逸出所属服务。使用引用存储，避免每个有界目录页面
    // 或每条连接都复制大型成员关系字典。
    private final class Account {
        var connections: Set<UUID> = []
        var rooms: [RoomID: Membership] = [:]
        var revokedThrough: [RoomID: UInt64] = [:]
    }

    private struct Connection: Sendable {
        let ticket: Ticket
        enum Recovery: Sendable { case active, pending, delivered }
        var recovery: Recovery = .active
    }

    private var accounts: [UserID: Account] = [:]
    private var connections: [UUID: Connection] = [:]
    private var usersByRoom: [RoomID: Set<UserID>] = [:]

    func begin(userID: UserID, connectionID: UUID) throws -> Ticket {
        guard userID.uuidValue != nil, connections[connectionID] == nil else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        let ticket = Ticket(userID: userID, connectionID: connectionID, epoch: UUID())
        connections[connectionID] = .init(ticket: ticket)
        let account = accounts[userID] ?? Account()
        account.connections.insert(connectionID)
        accounts[userID] = account
        return ticket
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        connections[ticket.connectionID]?.ticket == ticket
    }

    /// Retire only this ticket; Owner route references are service-owned.
    func end(_ ticket: Ticket) {
        guard isCurrent(ticket) else { return }
        connections.removeValue(forKey: ticket.connectionID)
        accounts[ticket.userID]?.connections.remove(ticket.connectionID)
        guard accounts[ticket.userID]?.connections.isEmpty == true,
              let account = accounts.removeValue(forKey: ticket.userID) else { return }
        for room in account.rooms.keys {
            usersByRoom[room]?.remove(ticket.userID)
            if usersByRoom[room]?.isEmpty == true {
                usersByRoom.removeValue(forKey: room)
            }
        }
    }

    struct Entry: Sendable {
        let roomID: RoomID
        let viewerMembershipRevision: UInt64
        let ownerEpoch: UInt64
    }

    /// Install membership candidates; route activation belongs to the service.
    func install(_ entries: [V2UserRoomDirectoryEntry], ticket: Ticket) throws {
        try install(entries.map { Entry(roomID: $0.roomID,
            viewerMembershipRevision: $0.viewerMembershipRevision, ownerEpoch: $0.ownerEpoch) }, ticket: ticket)
    }

    func install(_ entries: [Entry], ticket: Ticket) throws {
        guard entries.count <= 100, Set(entries.map(\.roomID)).count == entries.count else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        guard isCurrent(ticket), let account = accounts[ticket.userID] else { return }
        for entry in entries {
            if let revoked = account.revokedThrough[entry.roomID], entry.viewerMembershipRevision <= revoked { continue }
            if let existing = account.rooms[entry.roomID] {
                guard entry.viewerMembershipRevision >= existing.revision,
                      entry.ownerEpoch >= existing.ownerEpoch else { continue }
            }
            usersByRoom[entry.roomID, default: []].insert(ticket.userID)
            account.rooms[entry.roomID] = .init(revision: entry.viewerMembershipRevision, ownerEpoch: entry.ownerEpoch)
            // The installed newer revision now rejects late directory results.
            // A separate revoked floor is needed only while membership is absent.
            account.revokedThrough.removeValue(forKey: entry.roomID)
        }
    }

    func contains(_ entry: Entry, userID: UserID) -> Bool {
        guard let membership = accounts[userID]?.rooms[entry.roomID] else { return false }
        return membership.revision == entry.viewerMembershipRevision && membership.ownerEpoch == entry.ownerEpoch
    }

    func candidate(roomID: RoomID, userID: UserID) -> Candidate? {
        guard let membership = accounts[userID]?.rooms[roomID] else { return nil }
        return .init(userID: userID, membershipRevision: membership.revision, ownerEpoch: membership.ownerEpoch)
    }

    func candidates(roomID: RoomID) -> [Candidate] {
        (usersByRoom[roomID] ?? []).compactMap { candidate(roomID: roomID, userID: $0) }
    }

    /// 成员资格不存在的事实会阻止迟到的目录与状态响应生效。
    func revoke(userID: UserID, roomID: RoomID, revision: UInt64) throws {
        guard revision <= UInt64(Int64.max) else { throw V2RoomRecoveryReadError.invalidRequest }
        guard let account = accounts[userID] else { return }
        if let existing = account.rooms[roomID], existing.revision > revision { return }
        // Never evict a floor while old responses can still use this epoch.
        // The service catches this failure and retires account coverage.
        guard account.revokedThrough[roomID] != nil || account.revokedThrough.count < maximumRevokedRoomsPerAccount else {
            throw Failure.revocationHistoryFull
        }
        account.revokedThrough[roomID] = max(account.revokedThrough[roomID, default: 0], revision)
        account.rooms.removeValue(forKey: roomID)
        usersByRoom[roomID]?.remove(userID)
        if usersByRoom[roomID]?.isEmpty == true { usersByRoom.removeValue(forKey: roomID) }
        // 持久化成员移除是已知事实，而非传输缺口。
        // 保留其他房间和当前纪元，避免消费其个人事件时
        // 触发重连与重放循环。
    }

    func invalidate(userID: UserID) {
        for id in accounts[userID]?.connections ?? [] where connections[id]?.recovery == .active {
            connections[id]?.recovery = .pending
        }
    }

    func next(ticket: Ticket) -> V2AccountRoomNotification? {
        guard isCurrent(ticket), connections[ticket.connectionID]?.recovery == .pending else { return nil }
        connections[ticket.connectionID]?.recovery = .delivered
        return .resyncRequired(epoch: ticket.epoch)
    }

    func hasPending(ticket: Ticket) -> Bool {
        isCurrent(ticket) && connections[ticket.connectionID]?.recovery == .pending
    }

    func metrics() -> (accounts: Int, connections: Int, memberships: Int) {
        (accounts.count, connections.count, accounts.values.reduce(0) { $0 + $1.rooms.count })
    }
}
