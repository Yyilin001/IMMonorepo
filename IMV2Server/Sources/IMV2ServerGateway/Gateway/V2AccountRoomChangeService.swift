import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

public protocol V2AccountRoomChangesStarting: Sendable {
    func startAccountRoomChanges(connectionID: UUID, userID: UserID) async throws -> String
}

/// A fixed account recovery session. Durable room changes arrive through the
/// personal sync log; this service owns only the connection epoch/Ready barrier.
/// It has no directory reader, room routes, membership cache or Owner calls.
public actor V2AccountRoomChangeService {
    public enum Failure: Error, Equatable, Sendable { case closed, staleConnection }
    struct Ticket: Equatable, Sendable {
        let userID: UserID
        let connectionID: UUID
        let epoch: UUID
    }
    private final class Session {
        let ticket: Ticket
        let send: @Sendable (V2AccountRoomNotification) async -> Bool
        let close: @Sendable () async -> Void
        var ready = false
        var readyResponsePending = false
        var invalidated = false
        var drain: Task<Void, Never>?
        init(ticket: Ticket, send: @escaping @Sendable (V2AccountRoomNotification) async -> Bool,
             close: @escaping @Sendable () async -> Void) {
            self.ticket = ticket; self.send = send; self.close = close
        }
    }
    private var sessions: [UUID: Session] = [:]
    private var connectionsByUser: [UserID: Set<UUID>] = [:]
    private var closed = false
    private var completed: UInt64 = 0

    public init() {}

    func begin(userID: UserID, connectionID: UUID,
               send: @escaping @Sendable (V2AccountRoomNotification) async -> Bool,
               close: @escaping @Sendable () async -> Void) throws -> Ticket {
        guard !closed else { throw Failure.closed }
        guard userID.uuidValue != nil, sessions[connectionID] == nil else { throw Failure.staleConnection }
        let ticket = Ticket(userID: userID, connectionID: connectionID, epoch: UUID())
        sessions[connectionID] = Session(ticket: ticket, send: send, close: close)
        connectionsByUser[userID, default: []].insert(connectionID)
        if completed != .max { completed += 1 }
        return ticket
    }

    func reserveReadyResponse(_ ticket: Ticket) throws {
        guard !closed, let session = current(ticket), !session.invalidated else { throw Failure.staleConnection }
        session.readyResponsePending = true
    }

    /// If invalidation races an admitted Ready response, retain the resync
    /// boundary until this callback, so no notification can precede Ready.
    func resume(_ ticket: Ticket) {
        guard let session = current(ticket) else { return }
        session.ready = true; session.readyResponsePending = false
        kick(session)
    }

    public func invalidateCoverage() {
        for session in sessions.values { invalidate(session) }
    }
    public func invalidate(userID: UserID) {
        for id in connectionsByUser[userID] ?? [] {
            if let session = sessions[id] { invalidate(session) }
        }
    }
    private func invalidate(_ session: Session) {
        session.invalidated = true
        kick(session)
    }
    private func kick(_ session: Session) {
        guard !closed, current(session.ticket) === session, session.invalidated, session.drain == nil,
              session.ready || !session.readyResponsePending else { return }
        session.drain = Task { await drain(session) }
    }
    private func drain(_ session: Session) async {
        guard !Task.isCancelled, current(session.ticket) === session else { return }
        if session.ready {
            _ = await session.send(.resyncRequired(epoch: session.ticket.epoch))
            guard current(session.ticket) === session else { return }
        }
        detach(session)
        await session.close()
    }
    private func current(_ ticket: Ticket) -> Session? {
        guard let session = sessions[ticket.connectionID], session.ticket == ticket else { return nil }
        return session
    }
    private func detach(_ session: Session) {
        guard current(session.ticket) === session else { return }
        sessions.removeValue(forKey: session.ticket.connectionID)
        connectionsByUser[session.ticket.userID]?.remove(session.ticket.connectionID)
        if connectionsByUser[session.ticket.userID]?.isEmpty == true {
            connectionsByUser.removeValue(forKey: session.ticket.userID)
        }
    }
    func stop(_ ticket: Ticket) async {
        guard let session = current(ticket) else { return }
        detach(session)
        session.drain?.cancel()
        await session.drain?.value
    }
    public func initializationMetricsSnapshot() -> V2AccountInitializationMetricsSnapshot {
        let readyAccounts = connectionsByUser.values.filter { ids in
            ids.contains { sessions[$0]?.invalidated == false }
        }.count
        return .init(accounts: connectionsByUser.count, readyAccounts: readyAccounts,
            active: 0, queued: 0, deferred: 0, completed: completed, retries: 0, failures: 0)
    }
    public func shutdown() async {
        guard !closed else { return }
        closed = true
        let retiring = Array(sessions.values)
        sessions.removeAll(); connectionsByUser.removeAll()
        for session in retiring { session.drain?.cancel() }
        for session in retiring { await session.drain?.value }
    }
}
