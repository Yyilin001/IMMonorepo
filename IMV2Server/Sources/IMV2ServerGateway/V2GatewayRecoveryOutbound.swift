import Synchronization
import Foundation

private enum V2RecoveryOutboundWorkerContext {
    @TaskLocal static var ownerID: UUID?
}

/// Owns recovery handoffs for one physical connection. Retention is distinct
/// from the operation's actual socket admission result. No authority is granted
/// here: the operation must preserve its original write-time scope permits.
actor V2GatewayRecoveryOutbound {
    struct Snapshot: Sendable {
        let retained: Int
        let executing: Bool
        let revoked: Bool
        let acceptedHandoffs: UInt64
        let refusedHandoffs: UInt64
        let admittedOperations: UInt64
        let failedOperations: UInt64
    }

    private struct Entry: Sendable {
        let kind: Int
        let operation: @Sendable () async -> Bool
        let onSettled: @Sendable (Bool) async -> Void
    }

    private nonisolated let revoked = Mutex(false)
    private nonisolated let ownerID = UUID()
    private var entries: [Entry] = []
    private var retainedKinds: Set<Int> = []
    private var executing = false
    private var worker: Task<Void, Never>?
    private var acceptedHandoffs: UInt64 = 0
    private var refusedHandoffs: UInt64 = 0
    private var admittedOperations: UInt64 = 0
    private var failedOperations: UInt64 = 0

    /// The running operation also owns its slot. A slow writer cannot cause
    /// another scope of the same kind to accumulate behind it.
    func offer(kind: Int, operation: @escaping @Sendable () async -> Bool,
               onSettled: @escaping @Sendable (Bool) async -> Void) -> Bool {
        guard (1...5).contains(kind), !revoked.withLock({ $0 }),
              !retainedKinds.contains(kind), retainedKinds.count < 5 else {
            refusedHandoffs &+= 1
            return false
        }
        acceptedHandoffs &+= 1
        retainedKinds.insert(kind)
        entries.append(.init(kind: kind, operation: operation, onSettled: onSettled))
        if worker == nil {
            worker = Task {
                await V2RecoveryOutboundWorkerContext.$ownerID.withValue(ownerID) { await self.run() }
            }
        }
        return true
    }

    /// Revoke synchronously before any connection shutdown awaits. Pending
    /// entries are settled by the existing worker; revocation creates no task.
    nonisolated func revoke() { revoked.withLock { $0 = true } }

    nonisolated var isRevoked: Bool { revoked.withLock { $0 } }

    nonisolated var isCurrentWorker: Bool { V2RecoveryOutboundWorkerContext.ownerID == ownerID }

    func requestCancellation() {
        revoke()
        worker?.cancel()
    }

    /// The socket owner uses this synchronously around actual enqueue. A close
    /// that wins this lock prevents a previously selected write from slipping
    /// through while asynchronous Registry cleanup is still pending.
    nonisolated func enqueueIfActive(_ enqueue: () -> Bool) -> Bool {
        revoked.withLock { closed in
            guard !closed else { return false }
            return enqueue()
        }
    }

    func drain() async {
        requestCancellation()
        let actual = worker
        if !isCurrentWorker { await actual?.value }
    }

    func snapshot() -> Snapshot {
        .init(retained: retainedKinds.count, executing: executing, revoked: revoked.withLock { $0 },
              acceptedHandoffs: acceptedHandoffs, refusedHandoffs: refusedHandoffs,
              admittedOperations: admittedOperations, failedOperations: failedOperations)
    }

    private func run() async {
        defer { worker = nil }
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            executing = true
            let accepted: Bool
            if Task.isCancelled || revoked.withLock({ $0 }) { accepted = false }
            else { accepted = await entry.operation() }
            // Cancellation is not completion. Retain the slot until the actual
            // operation AND its one settlement callback have returned.
            let settled = accepted && !revoked.withLock({ $0 })
            if settled { admittedOperations &+= 1 } else { failedOperations &+= 1 }
            await entry.onSettled(settled)
            retainedKinds.remove(entry.kind)
            executing = false
        }
    }
}
