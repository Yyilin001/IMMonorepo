import Foundation
import IMV2Core

/// 账号的临时成员关系由其连接共享。此索引只提供路由候选项；
/// 入队前仍须完成数据库授权。
// 非 Sendable：仅由 V2AccountRoomChangeService 持有。
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

    // 绝不逃逸出所属服务。使用引用存储，避免每个有界目录页面
    // 或每条连接都复制大型成员关系字典。
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

    /// 返回全局已无活动连接的房间，供所有者释放消息代理订阅意向。
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

    /// 只安装经所有者校验的目录条目。调用方须等待消息代理激活，
    /// 再向客户端返回对应页面。
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

    /// 状态读取在同一所有者快照中绑定当前授权和日志头。
    /// 成员关系或所有者不匹配时须恢复，不能使用缓存。
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

    /// 成员资格不存在的事实会阻止迟到的目录与状态响应生效。
    func revoke(userID: UserID, roomID: RoomID, revision: UInt64) throws {
        guard revision > 0, revision <= UInt64(Int64.max) else { throw V2RoomRecoveryReadError.invalidRequest }
        guard let account = accounts[userID] else { return }
        if let existing = account.rooms[roomID], existing.revision > revision { return }
        account.revokedThrough[roomID] = max(account.revokedThrough[roomID, default: 0], revision)
        account.rooms.removeValue(forKey: roomID)
        usersByRoom[roomID]?.remove(userID)
        if usersByRoom[roomID]?.isEmpty == true { usersByRoom.removeValue(forKey: roomID) }
        // 持久化成员移除是已知事实，而非传输缺口。
        // 保留其他房间和当前纪元，避免消费其个人事件时
        // 触发重连与重放循环。
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
