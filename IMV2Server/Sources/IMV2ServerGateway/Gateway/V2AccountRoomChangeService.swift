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
        var membershipRefreshRetryAt: ContinuousClock.Instant?
        var bootstrapWork: V2BoundedInitialization.Ticket?
        var bootstrapID: UUID?
        var bootstrapCursor: String?
        var bootstrapTopology: String?
        var bootstrapPage: V2UserRoomDirectoryPage?
        var bootstrapFailures = 0
        var bootstrapped = false
        var bootstrapStartedAt: ContinuousClock.Instant?
        var bootstrapLastReportAt: ContinuousClock.Instant?
        var bootstrapStage = "directory"
        var bootstrapOwnerRetries = 0
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
    private let initialization: V2BoundedInitialization
    private var accounts: [UserID: Account] = [:]
    private var sessions: [UUID: Session] = [:]
    private struct Cleanup {
        let ticket: Ticket
        let task: Task<Void, Never>
    }
    private var cleanups: [UUID: Cleanup] = [:]
    private var closed = false
    private var readyAccounts = 0
    private var completedInitializations: UInt64 = 0
    private var initializationRetries: UInt64 = 0
    private var initializationFailures: UInt64 = 0
    private let logger = Logger(label: "imv2.gateway.account_coverage")

    public init(states: any V2RoomStateReading,
                directoryPage: (@Sendable (UserID, String?) async throws -> V2UserRoomDirectoryPage)? = nil,
                maximumRevokedRoomsPerAccount: Int = 4096,
                maximumConcurrentInitializations: Int = 32,
                maximumInitializationJobs: Int = 65_536,
                onlineDelivery: OnlineDelivery) throws {
        self.index = .init(maximumRevokedRoomsPerAccount: maximumRevokedRoomsPerAccount)
        self.states = states
        self.directoryPage = directoryPage
        self.onlineDelivery = onlineDelivery
        self.initialization = V2BoundedInitialization(maximumConcurrent: maximumConcurrentInitializations,
            maximumJobs: maximumInitializationJobs + maximumConcurrentInitializations)
    }

    /// Establish account coverage from server membership state before Ready.
    /// Public directory pulls are not prerequisites for online routing.
    func bootstrap(_ ticket: Ticket, waitForCompletion: Bool = true) async throws {
        guard current(ticket) != nil, let account = accounts[ticket.userID], !account.recovering else {
            throw Failure.staleConnection
        }
        if !account.bootstrapped {
            if account.bootstrapWork == nil {
                let id = account.bootstrapID ?? UUID()
                account.bootstrapID = id
                if account.bootstrapStartedAt == nil { account.bootstrapStartedAt = .now }
                do {
                    let work = try await initialization.submit(id: id) {
                        try await self.accountWorkStep(userID: ticket.userID, id: id)
                    }
                    guard accounts[ticket.userID] === account, !closed else {
                        await work.cancelAndDrain(); throw Failure.staleConnection
                    }
                    account.bootstrapWork = work
                } catch V2BoundedInitialization.Failure.overloaded {
                    account.bootstrapID = nil
                    throw V2RealtimePublicationBackpressure.receiverQueue
                }
            }
            if !waitForCompletion { return }
            guard let work = account.bootstrapWork else { throw V2RealtimePublicationBackpressure.receiverQueue }
            try await work.wait()
        }
        try Task.checkCancellation()
        guard current(ticket) != nil, accounts[ticket.userID] === account, !account.recovering else {
            throw Failure.staleConnection
        }
    }

    /// One authoritative page per scheduled step. Only executing jobs own tasks;
    /// retries release their slot and retain the last completed directory cursor.
    private func bootstrapStep(userID: UserID, id: UUID) async throws -> V2BoundedInitialization.Step {
        try Task.checkCancellation()
        guard !closed, let account = accounts[userID], account.bootstrapID == id, !account.recovering,
              let ticket = account.connections.compactMap({ sessions[$0]?.ticket }).first else { throw Failure.staleConnection }
        do {
            if account.bootstrapped { return .finished }
            guard let directoryPage else { completeBootstrap(account); return .finished }
            account.bootstrapStage = "directory"
            let cursor = account.bootstrapCursor
            let page: V2UserRoomDirectoryPage
            if let pending = account.bootstrapPage { page = pending }
            else { page = try await directoryPage(userID, cursor) }
            guard accounts[userID] === account, current(ticket) != nil, !account.recovering else { throw Failure.staleConnection }
            if let previous = account.bootstrapTopology, previous != page.topologyGeneration {
                // Restart the authoritative scan on topology change. Existing
                // grants remain governed by Owner controls, never by this cursor.
                throw V2RoomRecoveryReadError.topologyChanged
            }
            guard page.nextCursor == nil || page.nextCursor != cursor else { throw V2RoomRecoveryReadError.corruptPersistence }
            account.bootstrapPage = page
            try await install(page.rooms, ticket: ticket)
            try Task.checkCancellation()
            guard accounts[userID] === account, current(ticket) != nil, !account.recovering else { throw Failure.staleConnection }
            account.bootstrapTopology = page.topologyGeneration; account.bootstrapCursor = page.nextCursor
            account.bootstrapPage = nil
            if page.nextCursor != nil { return .again(at: .now) }
            account.bootstrapFailures = 0
            completeBootstrap(account)
            return account.membershipRefreshPending || !account.membershipRefreshRooms.isEmpty ? .again(at: .now) : .finished
        } catch {
            guard accounts[userID] === account, !closed, !account.recovering else { throw Failure.staleConnection }
            if current(ticket) == nil { return .again(at: .now) }
            if Self.retryableInitialization(error) {
                if initializationRetries != .max { initializationRetries += 1 }
                if case V2RoomRecoveryReadError.topologyChanged = error {
                    account.bootstrapCursor = nil; account.bootstrapTopology = nil; account.bootstrapPage = nil
                }
                account.bootstrapFailures += 1
                account.bootstrapOwnerRetries += 1
                account.bootstrapStage = "retry_wait"
                // Shared delayed queue, not one sleeping task per account.
                let delay = Self.retryDelayMilliseconds(error, failures: account.bootstrapFailures, id: id)
                if account.bootstrapFailures == 1 {
                    logger.warning("Account initialization temporarily deferred", metadata: [
                        "stage": "account_bootstrap", "error_type": .string(String(reflecting: type(of: error)))])
                }
                return .again(at: .now + .milliseconds(delay))
            }
            logger.warning("Account coverage bootstrap failed", metadata: [
                "stage": "account_bootstrap", "error_type": .string(String(reflecting: type(of: error)))])
            if initializationFailures != .max { initializationFailures += 1 }
            invalidate(userID: userID)
            throw error
        }
    }
    private func completeBootstrap(_ account: Account) {
        guard !account.bootstrapped else { return }
        account.bootstrapped = true; readyAccounts += 1
        if completedInitializations != .max { completedInitializations += 1 }
    }
    public func initializationMetricsSnapshot() async -> V2AccountInitializationMetricsSnapshot {
        let work = await initialization.snapshot
        return .init(accounts: accounts.count, readyAccounts: readyAccounts, active: work.active,
            queued: work.ready, deferred: work.delayed, completed: completedInitializations,
            retries: initializationRetries, failures: initializationFailures)
    }
    private static func retryableInitialization(_ error: any Error) -> Bool {
        if let safe = error as? any V2SafeOperationalErrorCodeProviding {
            switch safe.safeOperationalErrorCode {
            case .databaseLoanQueueFull, .databaseLoanTimedOut: return true
            default: break
            }
        }
        switch error {
        case V2GatewayRoomSubscriptionCoordinationError.overloaded,
             V2GatewayRoomSubscriptionCoordinationError.deadlineExpired,
             V2GatewayRoomSubscriptionCoordinationError.refused(.overloaded),
             V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable): return true
        case V2RoomCallFailure.notAccepted(let reason), V2RoomCallFailure.rolledBack(let reason):
            return reason == .overloaded || reason == .roomCapacityExhausted || reason == .unavailable || reason == .notReady || reason == .deadlineExceeded
        case V2RoomRecoveryReadError.topologyChanged: return true
        default: return false
        }
    }
    package static func retryDelayMilliseconds(_ error: any Error, failures: Int, id: UUID) -> Int {
        if case V2RoomCallFailure.notAccepted(.roomCapacityExhausted) = error {
            // A full Host needs retirement or a capacity change, not rapid RPC retries.
            let jitter = (Int(id.uuid.0) * 256 + Int(id.uuid.1)) % 5_001
            return 30_000 + jitter
        }
        return min(10_000, 100 << min(7, max(0, failures - 1))) + Int(id.uuid.0)
    }

    /// The listener RPC observes account-owned installation; it must not own
    /// the potentially long directory scan or Owner admission retry lifetime.
    func requireBootstrapReady(_ ticket: Ticket) throws {
        guard current(ticket) != nil, let account = accounts[ticket.userID], !account.recovering else {
            throw Failure.staleConnection
        }
        guard account.bootstrapped else {
            reportBootstrapWait(account)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
    }

    /// Listener retries reveal which owned installation is still pending,
    /// without logging account/room identifiers or creating another timer.
    private func reportBootstrapWait(_ account: Account) {
        let instant = ContinuousClock.now
        guard let started = account.bootstrapStartedAt, instant - started >= .seconds(5),
              account.bootstrapLastReportAt.map({ instant - $0 >= .seconds(30) }) ?? true else { return }
        account.bootstrapLastReportAt = instant
        logger.warning("Account coverage installation still pending", metadata: [
            "stage": "account_bootstrap", "waiting_on": .string(account.bootstrapStage),
            "owner_retries": .string(String(account.bootstrapOwnerRetries)),
            "elapsed_seconds": .string(String((instant - started).components.seconds))])
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
            accounts[ticket.userID]?.bootstrapStage = "directory"
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
    public func requestServerMembershipRefresh(userID: UserID, rooms: Set<RoomID>? = nil) async {
        guard !closed, directoryPage != nil, let account = accounts[userID], !account.recovering else { return }
        if let rooms { account.membershipRefreshRooms.formUnion(rooms) }
        else { account.membershipRefreshPending = true }
        if account.membershipRefreshRooms.count > 4096 {
            account.membershipRefreshRooms.removeAll(); account.membershipRefreshPending = true
        }
        // Bootstrap owns first discovery. Its final step sees these dirty flags.
        guard account.bootstrapped else { return }
        let id = account.bootstrapID ?? UUID(); account.bootstrapID = id
        do {
            let work = try await initialization.submit(id: id, repeatExisting: true) {
                try await self.accountWorkStep(userID: userID, id: id)
            }
            guard accounts[userID] === account, !closed else { await work.cancelAndDrain(); return }
            account.bootstrapWork = work
        } catch {
            if !closed { invalidate(userID: userID) }
        }
    }
    private func accountWorkStep(userID: UserID, id: UUID) async throws -> V2BoundedInitialization.Step {
        guard !closed, let account = accounts[userID], account.bootstrapID == id, !account.recovering else { throw Failure.staleConnection }
        if !account.bootstrapped { return try await bootstrapStep(userID: userID, id: id) }
        guard account.membershipRefreshPending || !account.membershipRefreshRooms.isEmpty else { return .finished }
        if let at = account.membershipRefreshRetryAt, at > .now { return .again(at: at) }
        account.membershipRefreshRetryAt = nil
        let full = account.membershipRefreshPending, rooms = account.membershipRefreshRooms
        account.membershipRefreshPending = false; account.membershipRefreshRooms.removeAll()
        if full { await refreshMembershipDirectory(userID: userID) }
        else { await refreshServerMemberships(userID: userID, rooms: rooms) }
        try Task.checkCancellation()
        guard accounts[userID] === account, !account.recovering else { throw Failure.staleConnection }
        if let at = account.membershipRefreshRetryAt { return .again(at: at) }
        account.bootstrapFailures = 0
        return account.membershipRefreshPending || !account.membershipRefreshRooms.isEmpty ? .again(at: .now) : .finished
    }
    public func refreshServerMemberships(userID: UserID) async {
        await requestServerMembershipRefresh(userID: userID)
        if let work = accounts[userID]?.bootstrapWork { _ = try? await work.waitCurrent() }
    }

    /// Only membership-discovery control changes trigger this reconciliation.
    /// Ordinary room messages consume existing grants without directory reads.
    private func refreshMembershipDirectory(userID: UserID) async {
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
                account.bootstrapStage = "owner_installation"
                let reference = request.scope
                guard account.routes[request.roomID] == request.scope else { continue }
                do {
                    try Task.checkCancellation()
                    try await onlineDelivery.activate(ticket.userID, request.roomID, reference)
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
            // Transient resource failures are owned by the bounded bootstrap
            // scheduler. They must not retire the account's installed progress.
            if current(ticket) != nil, accounts[ticket.userID] === account,
               !Self.retryableInitialization(error) { invalidate(userID: ticket.userID) }
            throw error
        }
    }

    private func failMembershipRefresh(userID: UserID, account: Account, generation: UUID, error: any Error) {
        guard accounts[userID] === account, account.membershipRefresh == generation else { return }
        if Self.retryableInitialization(error) {
            account.membershipRefreshPending = true
            account.bootstrapFailures += 1
            account.membershipRefreshRetryAt = .now + .milliseconds(Self.retryDelayMilliseconds(error,
                failures: account.bootstrapFailures, id: account.membershipRefresh))
            if initializationRetries != .max { initializationRetries += 1 }
            return
        }
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
        if let account = accounts[userID], account.bootstrapped && !account.recovering { readyAccounts -= 1 }
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
        if last {
            if let account, account.bootstrapped && !account.recovering { readyAccounts -= 1 }
            accounts.removeValue(forKey: user)
        }
        index.end(session.ticket)
        if last, let account {
            let bootstrap = account.bootstrapWork
            let scopes = account.routes
            let onlineDelivery = self.onlineDelivery
            let task = Task {
                await bootstrap?.cancelAndDrain()
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
        await initialization.shutdown()
        for session in Array(sessions.values) {
            let drain = session.drain
            await remove(session)
            await drain?.value
        }
        for cleanup in Array(cleanups.values) { await cleanup.task.value }
    }
}
