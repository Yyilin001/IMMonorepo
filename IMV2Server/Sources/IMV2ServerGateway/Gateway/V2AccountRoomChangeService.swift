import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ActorContracts
import Logging

public protocol V2AccountRoomChangesStarting: Sendable {
    func startAccountRoomChanges(connectionID: UUID, userID: UserID) async throws -> String
}

/// 负责成员关系覆盖、Owner 路由引用及每条连接的单一写者。
/// 房间通知只是提示；持久化内容仍保存在房间日志中。
public actor V2AccountRoomChangeService {
    public struct OnlineDelivery: Sendable {
        public let activate: @Sendable (UserID, RoomID, UUID) async throws -> Void
        public let deactivate: @Sendable (UUID) async -> Void
        public init(activate: @escaping @Sendable (UserID, RoomID, UUID) async throws -> Void,
                    deactivate: @escaping @Sendable (UUID) async -> Void) {
            self.activate = activate; self.deactivate = deactivate
        }
    }
    public enum Failure: Error, Equatable, Sendable { case closed, staleConnection }
    typealias Ticket = V2AccountRoomCoverageIndex.Ticket

    private final class Account {
        var connections: Set<UUID> = []
        var routes: [RoomID: UUID] = [:]
        var recovering = false
        var membershipRefresh = UUID()
        var membershipRefreshPending = false
        var membershipRefreshRooms: Set<RoomID> = []
        var membershipRefreshTask: Task<Void, Never>?
        var bootstrapTask: Task<Void, Error>?
        var bootstrapped = false
    }
    private final class Session {
        let ticket: Ticket
        let send: @Sendable (V2AccountRoomNotification) async -> Bool
        let close: @Sendable () async -> Void
        var ready = false
        var readyResponsePending = false
        var drain: Task<Void, Never>?
        init(ticket: Ticket, send: @escaping @Sendable (V2AccountRoomNotification) async -> Bool,
             close: @escaping @Sendable () async -> Void) {
            self.ticket = ticket; self.send = send; self.close = close
        }
    }

    private let index: V2AccountRoomCoverageIndex
    private let states: any V2RoomStateReading
    private let directoryPage: (@Sendable (UserID, String?) async throws -> V2UserRoomDirectoryPage)?
    private let onlineDelivery: OnlineDelivery
    private var accounts: [UserID: Account] = [:]
    private var sessions: [UUID: Session] = [:]
    private struct Cleanup {
        let ticket: Ticket
        let task: Task<Void, Never>
    }
    private var cleanups: [UUID: Cleanup] = [:]
    private var closed = false
    private let logger = Logger(label: "imv2.gateway.account_coverage")

    public init(states: any V2RoomStateReading,
                directoryPage: (@Sendable (UserID, String?) async throws -> V2UserRoomDirectoryPage)? = nil,
                maximumRevokedRoomsPerAccount: Int = 4096,
                onlineDelivery: OnlineDelivery) throws {
        self.index = .init(maximumRevokedRoomsPerAccount: maximumRevokedRoomsPerAccount)
        self.states = states
        self.directoryPage = directoryPage
        self.onlineDelivery = onlineDelivery
    }

    /// Establish account coverage from server membership state before Ready.
    /// Public directory pulls are not prerequisites for online routing.
    func bootstrap(_ ticket: Ticket, waitForCompletion: Bool = true) async throws {
        guard current(ticket) != nil, let account = accounts[ticket.userID], !account.recovering else {
            throw Failure.staleConnection
        }
        if !account.bootstrapped {
            if account.bootstrapTask == nil {
                account.bootstrapTask = Task {
                    while self.accounts[ticket.userID] === account, !account.recovering {
                        try Task.checkCancellation()
                        guard let active = account.connections.compactMap({ self.sessions[$0]?.ticket }).first else {
                            throw Failure.staleConnection
                        }
                        do {
                            _ = try await self.loadServerMemberships(active, collectingRooms: false)
                            guard self.accounts[ticket.userID] === account, !account.recovering else {
                                throw Failure.staleConnection
                            }
                            account.bootstrapped = true
                            return
                        } catch Failure.staleConnection {
                            // The scan's device may leave while a sibling still owns coverage.
                            guard self.accounts[ticket.userID] === account, !account.recovering,
                                  self.current(active) == nil else { throw Failure.staleConnection }
                        } catch {
                            // A departing device's late failure cannot invalidate
                            // coverage now owned by another authenticated device.
                            if self.accounts[ticket.userID] === account, !account.recovering,
                               self.current(active) == nil { continue }
                            var reason = "other"
                            if let value = error as? V2RoomRecoveryReadError { reason = String(describing: value) }
                            if let value = error as? V2GatewayRoomSubscriptionCoordinationError {
                                switch value {
                                case .refused(let code): reason = "owner_" + String(describing: code)
                                case .superseded: reason = "superseded"
                                case .closed: reason = "closed"
                                case .overloaded: reason = "overloaded"
                                case .invalidGrant: reason = "invalid_grant"
                                case .deadlineExpired: reason = "deadline_expired"
                                }
                            }
                            self.logger.warning("Account coverage bootstrap failed", metadata: [
                                "stage": "account_bootstrap", "reason": .string(reason),
                                "error_type": .string(String(reflecting: type(of: error)))])
                            if self.accounts[ticket.userID] === account { self.invalidate(userID: ticket.userID) }
                            throw error
                        }
                    }
                    throw Failure.staleConnection
                }
            }
            if !waitForCompletion { return }
            let task = account.bootstrapTask!
            do { try await task.value }
            catch {
                if accounts[ticket.userID] === account { invalidate(userID: ticket.userID) }
                throw error
            }
        }
        try Task.checkCancellation()
        guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else {
            throw Failure.staleConnection
        }
    }

    /// The listener RPC observes account-owned installation; it must not own
    /// the potentially long directory scan or Owner admission retry lifetime.
    func requireBootstrapReady(_ ticket: Ticket) throws {
        guard current(ticket) != nil, let account = accounts[ticket.userID], !account.recovering else {
            throw Failure.staleConnection
        }
        guard account.bootstrapped else { throw V2RealtimePublicationBackpressure.receiverQueue }
    }

    /// Reserve only after all listener admission checks have succeeded.
    func reserveReadyResponse(_ ticket: Ticket) throws {
        try requireBootstrapReady(ticket)
        current(ticket)?.readyResponsePending = true
    }

    private func loadServerMemberships(_ ticket: Ticket, collectingRooms: Bool = true) async throws -> Set<RoomID> {
        guard let directoryPage else { return [] }
        var cursor: String?
        var topology: String?
        var seen: Set<RoomID> = []
        repeat {
            try Task.checkCancellation()
            guard current(ticket) != nil else { throw Failure.staleConnection }
            let page = try await directoryPage(ticket.userID, cursor)
            guard current(ticket) != nil else { throw Failure.staleConnection }
            if let topology, topology != page.topologyGeneration {
                throw V2RoomRecoveryReadError.topologyChanged
            }
            topology = page.topologyGeneration
            guard page.nextCursor == nil || page.nextCursor != cursor else {
                throw V2RoomRecoveryReadError.corruptPersistence
            }
            try await install(page.rooms, ticket: ticket)
            // Only reconciliation needs the full set to detect removed rooms.
            // Bootstrap installs each page without retaining a second directory.
            if collectingRooms { seen.formUnion(page.rooms.map(\.roomID)) }
            cursor = page.nextCursor
        } while cursor != nil
        return seen
    }

    /// Control consumption must not wait for a complete membership directory.
    /// Each account owns one refresh; changes during a scan request another pass.
    public func requestServerMembershipRefresh(userID: UserID, rooms: Set<RoomID>? = nil) {
        guard !closed, directoryPage != nil, let account = accounts[userID], !account.recovering else { return }
        if let rooms { account.membershipRefreshRooms.formUnion(rooms) }
        else { account.membershipRefreshPending = true }
        if account.membershipRefreshRooms.count > 4096 {
            account.membershipRefreshRooms.removeAll(); account.membershipRefreshPending = true
        }
        guard account.membershipRefreshTask == nil else { return }
        account.membershipRefreshTask = Task {
            defer { account.membershipRefreshTask = nil }
            // Initial discovery owns route installation until its barrier completes.
            // Keep dirty rooms queued instead of acquiring the same reference twice.
            if !account.bootstrapped, let bootstrap = account.bootstrapTask {
                do { try await bootstrap.value }
                catch { return }
            }
            while !Task.isCancelled, self.accounts[userID] === account,
                  !account.recovering, account.membershipRefreshPending || !account.membershipRefreshRooms.isEmpty {
                let full = account.membershipRefreshPending
                let rooms = account.membershipRefreshRooms
                account.membershipRefreshPending = false
                account.membershipRefreshRooms.removeAll()
                if full { await self.refreshServerMemberships(userID: userID) }
                else { await self.refreshServerMemberships(userID: userID, rooms: rooms) }
            }
        }
    }

    /// Only membership-discovery control changes trigger this reconciliation.
    /// Ordinary room messages consume existing grants without directory reads.
    public func refreshServerMemberships(userID: UserID) async {
        guard directoryPage != nil, let account = accounts[userID], !account.recovering,
              let ticket = account.connections.compactMap({ sessions[$0]?.ticket }).first else { return }
        let generation = UUID()
        account.membershipRefresh = generation
        let prior = account.routes.compactMap { room, scope -> (RoomID, UUID, V2AccountRoomCoverageIndex.Candidate)? in
            guard let candidate = index.candidate(roomID: room, userID: userID) else { return nil }
            return (room, scope, candidate)
        }
        do {
            let seen = try await loadServerMemberships(ticket)
            guard accounts[userID] === account, account.membershipRefresh == generation, !account.recovering else { return }
            for (room, scope, before) in prior where !seen.contains(room) {
                guard accounts[userID] === account, account.membershipRefresh == generation,
                      account.routes[room] == scope,
                      let current = index.candidate(roomID: room, userID: userID),
                      current.membershipRevision == before.membershipRevision, current.ownerEpoch == before.ownerEpoch else { continue }
                try index.revoke(userID: userID, roomID: room, revision: current.membershipRevision)
                account.routes.removeValue(forKey: room)
                await onlineDelivery.deactivate(scope)
            }
        } catch {
            failMembershipRefresh(userID: userID, account: account, generation: generation, error: error)
        }
    }

    private func refreshServerMemberships(userID: UserID, rooms: Set<RoomID>) async {
        guard let account = accounts[userID], !account.recovering,
              let ticket = account.connections.compactMap({ sessions[$0]?.ticket }).first else { return }
        let generation = UUID()
        account.membershipRefresh = generation
        do {
            let ordered = rooms.sorted { $0.rawValue < $1.rawValue }
            for offset in stride(from: 0, to: ordered.count, by: 100) {
                let batch = Array(ordered[offset..<min(offset + 100, ordered.count)])
                let prior = Dictionary(uniqueKeysWithValues: batch.compactMap { room -> (RoomID, V2AccountRoomCoverageIndex.Candidate)? in
                    guard let candidate = index.candidate(roomID: room, userID: userID) else { return nil }
                    return (room, candidate)
                })
                let priorScopes = Dictionary(uniqueKeysWithValues: batch.compactMap { room -> (RoomID, UUID)? in
                    guard let scope = account.routes[room] else { return nil }
                    return (room, scope)
                })
                let results = try await states.states(roomIDs: batch, actorUserID: userID)
                guard accounts[userID] === account, account.membershipRefresh == generation,
                      current(ticket) != nil, !account.recovering else { throw Failure.staleConnection }
                for room in batch {
                    guard accounts[userID] === account, account.membershipRefresh == generation,
                          current(ticket) != nil, !account.recovering else { throw Failure.staleConnection }
                    guard let result = results[room] else { throw V2RoomRecoveryReadError.corruptPersistence }
                    switch result {
                    case .state(let state):
                        guard state.roomID == room else { throw V2RoomRecoveryReadError.corruptPersistence }
                        try await install([.init(roomID: room, viewerMembershipRevision: state.viewerMembershipRevision,
                            ownerEpoch: state.ownerEpoch)], ticket: ticket)
                    case .unavailable:
                        if let before = prior[room],
                           let latest = index.candidate(roomID: room, userID: userID),
                           latest.membershipRevision == before.membershipRevision, latest.ownerEpoch == before.ownerEpoch,
                           account.routes[room] == priorScopes[room],
                           let scope = account.routes[room] {
                            try index.revoke(userID: userID, roomID: room, revision: before.membershipRevision)
                            account.routes.removeValue(forKey: room)
                            await onlineDelivery.deactivate(scope)
                        }
                    case .retry: throw V2RoomRecoveryReadError.topologyChanged
                    }
                    guard accounts[userID] === account, account.membershipRefresh == generation,
                          current(ticket) != nil, !account.recovering else { throw Failure.staleConnection }
                }
            }
        } catch {
            failMembershipRefresh(userID: userID, account: account, generation: generation, error: error)
        }
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
        session.readyResponsePending = false
        kick(session)
    }

    func install(_ entries: [V2UserRoomDirectoryEntry], ticket: Ticket) async throws {
        try await install(entries.map { V2AccountRoomCoverageIndex.Entry(roomID: $0.roomID,
            viewerMembershipRevision: $0.viewerMembershipRevision, ownerEpoch: $0.ownerEpoch) }, ticket: ticket)
    }

    private func install(_ entries: [V2AccountRoomCoverageIndex.Entry], ticket: Ticket) async throws {
        guard current(ticket) != nil, let account = accounts[ticket.userID], !account.recovering else { throw Failure.staleConnection }
        guard entries.count <= 128, Set(entries.map(\.roomID)).count == entries.count else { throw V2RoomRecoveryReadError.invalidRequest }
        // The local coverage index retains its public-page limit of 100.
        // Install the internal batch without suspension, then activate its
        // account routes through the configured delivery owner.
        for offset in stride(from: 0, to: entries.count, by: 100) {
            try index.install(Array(entries[offset..<min(offset + 100, entries.count)]), ticket: ticket)
        }
        guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else { throw Failure.staleConnection }
        do {
            var requests: [(roomID: RoomID, scope: UUID)] = []
            for entry in entries {
                guard current(ticket) != nil, !account.recovering else { throw Failure.staleConnection }
                guard index.contains(entry, userID: ticket.userID) else { continue }
                let scope = account.routes[entry.roomID] ?? UUID()
                account.routes[entry.roomID] = scope
                requests.append((roomID: entry.roomID, scope: scope))
            }
            for request in requests {
                let reference = request.scope
                guard account.routes[request.roomID] == request.scope else { continue }
                do {
                    while true {
                        try Task.checkCancellation()
                        do {
                            try await onlineDelivery.activate(ticket.userID, request.roomID, reference)
                            break
                        } catch V2GatewayRoomSubscriptionCoordinationError.refused(let reason) where reason == .overloaded || reason == .unavailable {
                            guard current(ticket) != nil, accounts[ticket.userID] === account,
                                  !account.recovering, account.routes[request.roomID] == request.scope else {
                                throw Failure.staleConnection
                            }
                            // Owner admission and route recovery can be temporarily
                            // unavailable. Retry this reference in the owned task.
                            try await Task.sleep(for: reason == .unavailable ? .milliseconds(100) : .milliseconds(50))
                        }
                    }
                }
                catch {
                    guard account.routes[request.roomID] != request.scope else { throw error }
                    await onlineDelivery.deactivate(reference)
                    continue
                }
                if account.routes[request.roomID] != request.scope {
                    await onlineDelivery.deactivate(reference)
                    continue
                }
                guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else {
                    // A sibling device still owns this account's reference.
                    if accounts[ticket.userID] !== account {
                        await onlineDelivery.deactivate(reference)
                    }
                    throw Failure.staleConnection
                }
            }

        } catch {
            if current(ticket) != nil, accounts[ticket.userID] === account { invalidate(userID: ticket.userID) }
            throw error
        }
    }

    private func failMembershipRefresh(userID: UserID, account: Account, generation: UUID, error: any Error) {
        guard accounts[userID] === account, account.membershipRefresh == generation else { return }
        if case V2AccountRoomCoverageIndex.Failure.revocationHistoryFull = error {
            logger.warning("Account membership history reached its capacity; retiring coverage", metadata: [
                "stage": "membership_refresh", "reason": "revocation_history_full"])
        }
        invalidate(userID: userID)
    }

    /// Owner-specific routing failure affects only accounts covering its topics.
    public func connections(covering rooms: Set<RoomID>) -> Set<UUID> {
        var connections: Set<UUID> = []
        for room in rooms {
            for candidate in index.candidates(roomID: room) {
                connections.formUnion(accounts[candidate.userID]?.connections ?? [])
            }
        }
        return connections
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

    private func kick(_ session: Session) {
        guard !closed, session.drain == nil, current(session.ticket) === session else { return }
        guard session.ready else {
            // An approved Ready may already be visible on the socket while its
            // write callback is pending. Retain the resync boundary until resume
            // confirms that response, rather than silently retiring its epoch.
            guard !session.readyResponsePending else { return }
            // A failed automatic coverage installation cannot wait for a directory
            // consumer that may never start. Close this epoch without sending a
            // notification before its Ready barrier.
            guard accounts[session.ticket.userID]?.recovering == true else { return }
            session.drain = Task {
                await self.remove(session)
                await session.close()
            }
            return
        }
        session.drain = Task { await self.drain(session) }
    }


    private func drain(_ session: Session) async {
        guard !Task.isCancelled, current(session.ticket) === session,
              let notification = index.next(ticket: session.ticket) else {
            session.drain = nil
            return
        }
        let sent = await session.send(notification)
        guard current(session.ticket) === session else { return }
        logger.warning("Account coverage notification retired its epoch", metadata: [
            "stage": "account_delivery", "reason": .string(sent ? "resync_boundary" : "enqueue_rejected"),
            "ready": .string(String(session.ready)),
            "account_recovering": .string(String(accounts[session.ticket.userID]?.recovering ?? false))])
        // The one recovery boundary retires this exact account ticket.
        await remove(session)
        await session.close()
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
        index.end(session.ticket)
        if last, let account {
            let bootstrap = account.bootstrapTask
            bootstrap?.cancel()
            let refresh = account.membershipRefreshTask
            refresh?.cancel()
            let scopes = account.routes
            let onlineDelivery = self.onlineDelivery
            let task = Task {
                _ = try? await bootstrap?.value
                await refresh?.value
                for reference in scopes.values { await onlineDelivery.deactivate(reference) }
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
        for session in Array(sessions.values) {
            let drain = session.drain
            await remove(session)
            await drain?.value
        }
        for cleanup in Array(cleanups.values) { await cleanup.task.value }
    }
}
