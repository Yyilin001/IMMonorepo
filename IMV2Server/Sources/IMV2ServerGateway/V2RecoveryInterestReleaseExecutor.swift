import Foundation

/// Owns exact interest releases after the lifecycle owner has revoked them.
/// The containing lifecycle closes admission before joining `finish()`.
actor V2RecoveryInterestReleaseExecutor {
    struct Snapshot: Sendable {
        let retained: Int
        let actual: Int
        let pendingAdmissions: Int
        let capacityWaiter: Bool
        let waitingActivations: Int
    }
    private let maximumRetained: Int
    private let maximumActual: Int
    private var tickets: [UUID: V2RecoveryInterestTicket] = [:]
    private var queue: [UUID] = []
    private var offset = 0
    private var eligible: Set<UUID> = []
    private var drainSignalID: UUID?
    private var drainSignal: Task<Void, Never>?
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private var capacitySignalID: UUID?
    private var capacitySignal: Task<Void, Never>?
    private var capacityContinuation: CheckedContinuation<Void, Never>?
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var actual: Set<UUID> = []

    init(maximumRetained: Int = 1024, maximumActual: Int = 4) {
        precondition(maximumRetained > 0 && maximumActual > 0 && maximumActual <= maximumRetained)
        self.maximumRetained = maximumRetained
        self.maximumActual = maximumActual
    }

    /// Revocation precedes the first suspension. Refusal leaves the original
    /// lifecycle owner responsible for the ticket; this executor owns no
    /// overflow queue or caller continuations containing cleanup capabilities.
    nonisolated func trySubmit(ticket: V2RecoveryInterestTicket) async -> Bool {
        ticket.revoke()
        return await retain(ticket)
    }

    private func retain(_ ticket: V2RecoveryInterestTicket) -> Bool {
        if tickets[ticket.ownerID] != nil { enqueueIfEligible(ticket); return true }
        guard tickets.count < maximumRetained else { return false }
        tickets[ticket.ownerID] = ticket
        enqueueIfEligible(ticket)
        return true
    }

    /// Called by the already-owned activation root after actual completion.
    /// Duplicate or late notifications cannot lend another owner's position.
    func activationSettled(ticket: V2RecoveryInterestTicket) {
        enqueueIfEligible(ticket)
    }

    func activationSettled(tickets: [V2RecoveryInterestTicket]) {
        for ticket in tickets { enqueueIfEligible(ticket) }
    }

    private func enqueueIfEligible(_ ticket: V2RecoveryInterestTicket) {
        guard tickets[ticket.ownerID] != nil, ticket.activationSettled,
              !actual.contains(ticket.ownerID), eligible.insert(ticket.ownerID).inserted else { return }
        queue.append(ticket.ownerID)
        startWorkers()
    }

    /// Only the coordinator's one owned cleanup-pump task waits here. The
    /// shared signal task has no ticket payload and is independent of callers.
    func waitForCapacity() async {
        guard tickets.count >= maximumRetained else { return }
        let signal: Task<Void, Never>
        if let existing = capacitySignal { signal = existing }
        else {
            let id = UUID()
            capacitySignalID = id
            let created = Task { await self.installCapacityWait(id) }
            capacitySignal = created
            signal = created
        }
        await signal.value
    }

    private func installCapacityWait(_ id: UUID) async {
        guard capacitySignalID == id, tickets.count >= maximumRetained else { return }
        await withCheckedContinuation { capacityContinuation = $0 }
    }

    private func startWorkers() {
        let available = queue.count - offset
        while workers.count < maximumActual && workers.count - actual.count < available {
            let id = UUID()
            workers[id] = Task { await self.run(id) }
        }
    }

    private func run(_ workerID: UUID) async {
        while offset < queue.count {
            let id = queue[offset]
            offset += 1
            guard let ticket = tickets[id] else { preconditionFailure("interest release ownership") }
            eligible.remove(id)
            actual.insert(id)
            await ticket.release()
            actual.remove(id)
            tickets.removeValue(forKey: id)
            if tickets.isEmpty {
                drainContinuation?.resume()
                drainContinuation = nil
                drainSignal = nil
                drainSignalID = nil
            }
            capacityContinuation?.resume()
            capacityContinuation = nil
            capacitySignal = nil
            capacitySignalID = nil
            if offset >= 1024 && offset * 2 >= queue.count {
                queue.removeFirst(offset)
                offset = 0
            }
        }
        workers.removeValue(forKey: workerID)
        if workers.isEmpty {
            queue.removeAll(keepingCapacity: true)
            offset = 0
            precondition(eligible.isEmpty && actual.isEmpty)
        }
    }

    func snapshot() -> Snapshot {
        .init(retained: tickets.count, actual: actual.count, pendingAdmissions: 0, capacityWaiter: capacitySignal != nil,
              waitingActivations: tickets.count - actual.count - eligible.count)
    }

    /// Cancellation cannot pretend the underlying release has settled.
    func finish() async {
        if !tickets.isEmpty {
            let signal: Task<Void, Never>
            if let existing = drainSignal { signal = existing }
            else {
                let id = UUID()
                drainSignalID = id
                let created = Task { await self.installDrainWait(id) }
                drainSignal = created
                signal = created
            }
            await signal.value
        }
        let owned = Array(workers.values)
        for worker in owned { await worker.value }
    }
    private func installDrainWait(_ id: UUID) async {
        guard drainSignalID == id, !tickets.isEmpty else { return }
        await withCheckedContinuation { drainContinuation = $0 }
    }

}
