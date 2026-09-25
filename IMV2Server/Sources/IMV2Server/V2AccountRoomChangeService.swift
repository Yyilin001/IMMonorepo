import Foundation
import IMV2Core

public protocol V2AccountRoomChangesStarting: Sendable {
    func startAccountRoomChanges(connectionID: UUID, userID: UserID) async throws -> String
}

/// 本地唤醒直接通过连接注册表投递。
public struct V2LocalRoomChangeInterest: V2GroupEventWakeInterestManaging {
    public init() {}
    public func activate(roomID: RoomID) async throws { try Task.checkCancellation() }
    public func deactivate(roomID: RoomID) async {}
}

/// 负责实时账号覆盖、有界唤醒处理及每条连接的单一写者。
/// 房间通知只是提示；持久化内容仍保存在房间日志中。
public actor V2AccountRoomChangeService {
    public enum Failure: Error, Equatable, Sendable { case closed, staleConnection }
    typealias Ticket = V2AccountRoomCoverageIndex.Ticket

    private final class Account {
        var connections: Set<UUID> = []
        var interests: [RoomID: any V2GroupEventWakeInterestManaging] = [:]
        var recovering = false
    }
    private final class Session {
        let ticket: Ticket
        let send: @Sendable (V2AccountRoomNotification) async -> Bool
        let close: @Sendable () async -> Void
        var ready = false
        var drain: Task<Void, Never>?
        init(ticket: Ticket, send: @escaping @Sendable (V2AccountRoomNotification) async -> Bool,
             close: @escaping @Sendable () async -> Void) {
            self.ticket = ticket; self.send = send; self.close = close
        }
    }

    private let index: V2AccountRoomCoverageIndex
    private let states: any V2RoomStateReading
    private let interests: V2SharedGroupEventWakeInterests
    private let maximumPendingWakeRooms: Int
    private var accounts: [UserID: Account] = [:]
    private var sessions: [UUID: Session] = [:]
    private struct Cleanup {
        let ticket: Ticket
        let task: Task<Void, Never>
    }
    private var cleanups: [UUID: Cleanup] = [:]
    private var pendingRooms: Set<RoomID> = []
    private var wakeOrder: [RoomID] = []
    private var wakeOffset = 0
    private var wakeTask: Task<Void, Never>?
    private var closed = false

    public init(states: any V2RoomStateReading, interests: V2SharedGroupEventWakeInterests,
                maximumPendingRooms: Int = 4096, maximumPendingWakeRooms: Int = 4096) throws {
        guard maximumPendingWakeRooms > 0 else { throw V2RoomRecoveryReadError.invalidRequest }
        self.index = try .init(maximumPendingRooms: maximumPendingRooms)
        self.states = states; self.interests = interests
        self.maximumPendingWakeRooms = maximumPendingWakeRooms
    }

    func begin(userID: UserID, connectionID: UUID,
               send: @escaping @Sendable (V2AccountRoomNotification) async -> Bool,
               close: @escaping @Sendable () async -> Void) async throws -> Ticket {
        guard !closed else { throw Failure.closed }
        guard sessions[connectionID] == nil, cleanups[connectionID] == nil else { throw Failure.staleConnection }
        guard accounts[userID]?.recovering != true else { throw Failure.staleConnection }
        let ticket = try index.begin(userID: userID, connectionID: connectionID)
        let account = accounts[userID] ?? Account()
        account.connections.insert(connectionID)
        accounts[userID] = account
        sessions[connectionID] = Session(ticket: ticket, send: send, close: close)
        return ticket
    }

    /// 仅在 Ready 响应写入连接后调用。
    func resume(_ ticket: Ticket) {
        guard let session = current(ticket) else { return }
        session.ready = true
        kick(session)
    }

    func install(_ entries: [V2UserRoomDirectoryEntry], ticket: Ticket) async throws {
        try await install(entries.map { V2AccountRoomCoverageIndex.Entry(roomID: $0.roomID,
            viewerMembershipRevision: $0.viewerMembershipRevision, ownerEpoch: $0.ownerEpoch) }, ticket: ticket)
    }

    private func install(_ entries: [V2AccountRoomCoverageIndex.Entry], ticket: Ticket) async throws {
        guard current(ticket) != nil, let account = accounts[ticket.userID], !account.recovering else { throw Failure.staleConnection }
        _ = try index.install(entries, ticket: ticket)
        guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else { throw Failure.staleConnection }
        do {
            for entry in entries {
                try Task.checkCancellation()
                guard current(ticket) != nil, !account.recovering else { throw Failure.staleConnection }
                guard index.contains(entry, userID: ticket.userID) else { continue }
                let interest = account.interests[entry.roomID] ?? interests.manager(for: .account(UUID()))
                account.interests[entry.roomID] = interest
                // 房间移除后重新加入时会获得新的作用域。
                // 旧的清理操作不能跨越 await 取消替代的订阅需求。
                try await interest.activate(roomID: entry.roomID)
                guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else {
                    if accounts[ticket.userID] !== account {
                        await interest.deactivate(roomID: entry.roomID)
                    }
                    throw Failure.staleConnection
                }
            }
        } catch {
            if current(ticket) != nil, accounts[ticket.userID] === account { invalidate(userID: ticket.userID) }
            throw error
        }
    }

    /// 个人发现事件可能提及目录游标之后的房间。
    /// 重新读取当前授权，然后在安排日志头读取前安装订阅。
    func refreshMemberships(_ changes: [V2AccountRoomMembershipChange], ticket: Ticket) async throws {
        guard let account = accounts[ticket.userID], current(ticket) != nil, !account.recovering else {
            throw Failure.staleConnection
        }
        let roomIDs = Array(Set(changes.map(\.roomID)))
        guard roomIDs.count <= 100 else { throw V2RoomRecoveryReadError.invalidRequest }
        if roomIDs.isEmpty { return }
        let prior = Dictionary(uniqueKeysWithValues: roomIDs.compactMap { room in
            index.candidates(roomID: room).first(where: { $0.userID == ticket.userID }).map { (room, $0) }
        })
        let results = try await states.states(roomIDs: roomIDs, actorUserID: ticket.userID)
        guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else {
            throw Failure.staleConnection
        }
        var entries: [V2AccountRoomCoverageIndex.Entry] = []
        for room in roomIDs {
            switch results[room] {
            case .state(let state):
                guard state.roomID == room else { throw V2RoomRecoveryReadError.corruptPersistence }
                entries.append(.init(roomID: room, viewerMembershipRevision: state.viewerMembershipRevision, ownerEpoch: state.ownerEpoch))
            case .unavailable:
                let removedRevision = changes.filter { $0.roomID == room }.compactMap(\.removedThrough).max() ?? 0
                let revision = max(removedRevision, prior[room]?.membershipRevision ?? 0)
                if revision > 0 {
                    try index.revoke(userID: ticket.userID, roomID: room, revision: revision)
                }
                // 状态读取等待期间，较新的安装操作可能已先完成。
                if !index.candidates(roomID: room).contains(where: { $0.userID == ticket.userID }),
                   let interest = account.interests.removeValue(forKey: room) {
                    await interest.deactivate(roomID: room)
                    guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else {
                        throw Failure.staleConnection
                    }
                }
            case .retry, nil:
                throw V2RoomRecoveryReadError.topologyChanged
            }
        }
        try await install(entries, ticket: ticket)
        for entry in entries { notify(roomID: entry.roomID) }
    }

    /// 不为每次唤醒创建任务；重复房间在授权读取前合并。
    public func notify(roomID: RoomID) {
        guard !closed else { return }
        guard !pendingRooms.contains(roomID) else { return }
        guard pendingRooms.count < maximumPendingWakeRooms else {
            pendingRooms.removeAll(); wakeOrder.removeAll(); wakeOffset = 0
            for user in Array(accounts.keys) { invalidate(userID: user) }
            return
        }
        pendingRooms.insert(roomID)
        wakeOrder.append(roomID)
        if wakeTask == nil { wakeTask = Task { await self.processWakes() } }
    }

    /// Core 消息代理重连无法重放故障期间丢失的唤醒。
    public func invalidateCoverage() {
        for user in Array(accounts.keys) { invalidate(userID: user) }
    }

    public func invalidate(userID: UserID) {
        accounts[userID]?.recovering = true
        index.invalidate(userID: userID)
        for id in accounts[userID]?.connections ?? [] { if let session = sessions[id] { kick(session) } }
    }

    func stop(_ ticket: Ticket) async {
        if let session = current(ticket) {
            let drain = session.drain
            await remove(session)
            await drain?.value
        }
        // 写者释放订阅意向时可能已经分离会话。
        // 注销流程仍须等待该精确生命周期结束。
        if let cleanup = cleanups[ticket.connectionID], cleanup.ticket == ticket {
            await cleanup.task.value
        }
    }

    private func current(_ ticket: Ticket) -> Session? {
        guard let session = sessions[ticket.connectionID], session.ticket == ticket else { return nil }
        return session
    }

    private func processWakes() async {
        while !Task.isCancelled, !closed, wakeOffset < wakeOrder.count {
            let room = wakeOrder[wakeOffset]
            wakeOffset += 1
            pendingRooms.remove(room)
            if wakeOffset >= wakeOrder.count / 2 { wakeOrder.removeFirst(wakeOffset); wakeOffset = 0 }
            for candidate in index.candidates(roomID: room) {
                guard !Task.isCancelled, !closed else { break }
                do {
                    let result = try await states.states(roomIDs: [room], actorUserID: candidate.userID)
                    guard !Task.isCancelled, !closed else { break }
                    if case .state(let state)? = result[room],
                       state.viewerMembershipRevision == candidate.membershipRevision,
                       state.ownerEpoch == candidate.ownerEpoch {
                        try index.enqueueAuthorized(state, candidate: candidate)
                        for id in accounts[candidate.userID]?.connections ?? [] {
                            if let session = sessions[id] { kick(session) }
                        }
                    } else { invalidate(candidate: candidate) }
                } catch {
                    if Task.isCancelled { break }
                    invalidate(candidate: candidate)
                }
            }
        }
        wakeTask = nil
    }

    private func kick(_ session: Session) {
        guard !closed, session.ready, session.drain == nil, current(session.ticket) === session else { return }
        session.drain = Task { await self.drain(session) }
    }

    private func invalidate(candidate: V2AccountRoomCoverageIndex.Candidate) {
        guard index.invalidate(candidate: candidate) else { return }
        accounts[candidate.userID]?.recovering = true
        for id in accounts[candidate.userID]?.connections ?? [] {
            if let session = sessions[id] { kick(session) }
        }
    }

    private func drain(_ session: Session) async {
        while !Task.isCancelled, current(session.ticket) === session {
            guard let notification = index.next(ticket: session.ticket) else { break }
            guard !Task.isCancelled, current(session.ticket) === session else { break }
            let sent = await session.send(notification)
            guard current(session.ticket) === session else { break }
            if !sent || notification.isResyncBoundary {
                // 重新同步边界也会关闭此纪元，
                // 在下次恢复前释放过期授权和消息代理订阅意向。
                await remove(session)
                await session.close()
                return
            }
        }
        session.drain = nil
        // 此排空任务尚在运行时，入队可能与空读取竞速。
        // 清除任务后再次检查，防止丢失唤醒。
        if !Task.isCancelled, index.hasPending(ticket: session.ticket) { kick(session) }
    }

    private func remove(_ session: Session) async {
        guard current(session.ticket) === session else { return }
        sessions.removeValue(forKey: session.ticket.connectionID)
        session.drain?.cancel()
        let user = session.ticket.userID
        let account = accounts[user]
        account?.connections.remove(session.ticket.connectionID)
        let last = account?.connections.isEmpty == true
        if last { accounts.removeValue(forKey: user) }
        _ = index.end(session.ticket)
        if last, let account {
            let interests = account.interests
            let task = Task {
                for (room, interest) in interests { await interest.deactivate(roomID: room) }
            }
            cleanups[session.ticket.connectionID] = .init(ticket: session.ticket, task: task)
            await task.value
            if cleanups[session.ticket.connectionID]?.ticket == session.ticket {
                cleanups.removeValue(forKey: session.ticket.connectionID)
            }
        }
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        let wake = wakeTask
        wake?.cancel()
        for session in Array(sessions.values) {
            let drain = session.drain
            await remove(session)
            await drain?.value
        }
        for cleanup in Array(cleanups.values) { await cleanup.task.value }
        await wake?.value
        pendingRooms.removeAll(); wakeOrder.removeAll(); wakeOffset = 0
    }
}

private extension V2AccountRoomNotification {
    var isResyncBoundary: Bool {
        if case .resyncRequired = self { return true }
        return false
    }
}
