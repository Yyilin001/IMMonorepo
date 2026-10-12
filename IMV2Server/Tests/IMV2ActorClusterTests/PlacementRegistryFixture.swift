// Test fixture only. Production room lifetime belongs to V2RoomActivationHost.
import Foundation
import Crypto
import IMV2ActorContracts
import IMV2Core
import Synchronization
@testable import IMV2ActorCluster

/// One room's admission and physical work lifetime. Draining closes admission
/// synchronously and waits for body completion, not merely task cancellation.
package final class V2RoomActorHandle<Value: Sendable>: Sendable {
    package let identity: V2RoomActorIdentity
    private let value: Value
    private let directory: V2ActorPlacementDirectory
    private struct State {
        var accepting = false
        var inFlight = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    package init(identity: V2RoomActorIdentity, value: Value, directory: V2ActorPlacementDirectory) {
        self.identity = identity; self.value = value; self.directory = directory
    }
    fileprivate func open() { state.withLock { $0.accepting = true } }
    fileprivate func closeAdmission() { state.withLock { $0.accepting = false } }

    package func invoke<Result: Sendable>(_ body: @Sendable (Value) async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        guard directory.admits(identity) else { throw V2ActorPlacementError.staleOwner }
        try state.withLock { value in
            guard value.accepting else { throw V2ActorPlacementError.retiring }
            value.inFlight += 1
        }
        defer { finish() }
        return try await body(value)
    }
    private func finish() {
        let waiters = state.withLock { value -> [CheckedContinuation<Void, Never>] in
            precondition(value.inFlight > 0)
            value.inFlight -= 1
            guard value.inFlight == 0 else { return [] }
            let waiters = value.waiters; value.waiters.removeAll(); return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    fileprivate func drain() async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { value in
                value.accepting = false
                guard value.inFlight > 0 else { return true }
                value.waiters.append(continuation); return false
            }
            if finished { continuation.resume() }
        }
    }
    fileprivate var instance: Value { value }
}

/// Sole local creator of room instances. Pending restore and retirement jobs
/// are owned by the entry, so cancellation of one caller cannot spawn a second
/// instance. Neither warm invocations nor SQL run on this registry actor.
package actor V2RoomActorRegistry<Value: Sendable> {
    private final class Entry {
        let identity: V2RoomActorIdentity
        let restore: Task<V2RoomActorHandle<Value>, any Error>
        var handle: V2RoomActorHandle<Value>?
        var retirement: Task<Void, Never>?
        init(identity: V2RoomActorIdentity, restore: Task<V2RoomActorHandle<Value>, any Error>) {
            self.identity = identity; self.restore = restore
        }
    }
    private let host: V2ActorHostIdentity
    private let directory: V2ActorPlacementDirectory
    private let maximumRooms: Int
    private let make: @Sendable (V2RoomActorIdentity) async throws -> Value
    private let close: @Sendable (Value) async -> Void
    private var entries: [RoomID: Entry] = [:]
    private var accepting = true

    package init(host: V2ActorHostIdentity, directory: V2ActorPlacementDirectory, maximumRooms: Int,
                 make: @escaping @Sendable (V2RoomActorIdentity) async throws -> Value,
                 close: @escaping @Sendable (Value) async -> Void) throws {
        guard maximumRooms > 0 else { throw V2ActorPlacementError.invalidConfiguration }
        self.host = host; self.directory = directory; self.maximumRooms = maximumRooms
        self.make = make; self.close = close
    }

    package func resolve(_ roomID: RoomID) async throws -> V2RoomActorHandle<Value> {
        try Task.checkCancellation()
        guard accepting else { throw V2ActorPlacementError.unavailable }
        let snapshot = directory.snapshot()
        let partition = snapshot.partition(for: roomID)
        let slot = snapshot.slots[partition]
        guard slot.owner.host == host, !slot.retired, slot.transfer == nil else { throw V2ActorPlacementError.staleOwner }
        let entry: Entry
        if let existing = entries[roomID] {
            guard existing.retirement == nil else { throw V2ActorPlacementError.retiring }
            guard existing.identity.owner == slot.owner else { throw V2ActorPlacementError.staleOwner }
            entry = existing
        } else {
            guard entries.count < maximumRooms else { throw V2ActorPlacementError.unavailable }
            let identity = V2RoomActorIdentity(roomID: roomID, clusterID: snapshot.clusterID,
                partition: partition, owner: slot.owner, activationID: UUID())
            let make = self.make, directory = self.directory
            let restore = Task {
                let value = try await make(identity)
                return V2RoomActorHandle(identity: identity, value: value, directory: directory)
            }
            entry = Entry(identity: identity, restore: restore)
            entries[roomID] = entry
        }
        let handle: V2RoomActorHandle<Value>
        do { handle = try await entry.restore.value }
        catch {
            if entries[roomID] === entry, entry.retirement == nil { entries.removeValue(forKey: roomID) }
            throw error
        }
        guard entries[roomID] === entry, entry.retirement == nil, accepting,
              directory.admits(entry.identity) else {
            await retire(entry.identity)
            throw V2ActorPlacementError.staleOwner
        }
        if entry.handle == nil { entry.handle = handle; handle.open() }
        try Task.checkCancellation()
        return handle
    }

    /// Exact-identity retirement prevents a late cleanup from closing a newly
    /// restored instance. No replacement is admitted until close returns.
    package func retire(_ identity: V2RoomActorIdentity) async {
        guard let entry = entries[identity.roomID], entry.identity == identity else { return }
        let job = beginRetirement(entry)
        await job.value
        if entries[identity.roomID] === entry { entries.removeValue(forKey: identity.roomID) }
    }

    private func beginRetirement(_ entry: Entry) -> Task<Void, Never> {
        entry.handle?.closeAdmission()
        if let existing = entry.retirement { return existing }
        let restore = entry.restore, close = self.close
        let job = Task {
            guard let handle = try? await restore.value else { return }
            await handle.drain()
            await close(handle.instance)
        }
        entry.retirement = job
        return job
    }

    package func drain(partition: Int, owner: V2ActorPlacementOwner) async {
        let identities = entries.values.map(\.identity).filter { $0.partition == partition && $0.owner == owner }
        // Mark ALL entries retiring before suspending, including pending restores.
        for identity in identities {
            if let entry = entries[identity.roomID] { _ = beginRetirement(entry) }
        }
        for identity in identities { await retire(identity) }
    }

    /// The old-owner endpoint invokes this with an authenticated committed
    /// withdrawal. Receipt creation is downstream of actual restore, work and
    /// close completion. An unfinished/cancelled drain never grants takeover.
    package func drainPlacement(_ withdrawn: V2ActorPlacementSnapshot,
                                partition: Int) async throws -> V2ActorPlacementDrainReceipt {
        guard withdrawn.slots.indices.contains(partition),
              let transfer = withdrawn.slots[partition].transfer,
              withdrawn.slots[partition].owner.host == host else {
            throw V2ActorPlacementError.staleOwner
        }
        try directory.installCommitted(withdrawn)
        let owner = withdrawn.slots[partition].owner
        await drain(partition: partition, owner: owner)
        let current = directory.snapshot()
        guard current.clusterID == withdrawn.clusterID,
              current.slots[partition] == withdrawn.slots[partition] else {
            throw V2ActorPlacementError.invalidTransition
        }
        return .init(clusterID: withdrawn.clusterID, partition: partition,
                     owner: owner, transferID: transfer.id)
    }

    package func stop() async {
        accepting = false
        let identities = entries.values.map(\.identity)
        for entry in entries.values { _ = beginRetirement(entry) }
        for identity in identities { await retire(identity) }
    }
    package func count() -> Int { entries.count }
}

package struct V2RoomActorIdentity: Equatable, Sendable {
    package let roomID: RoomID
    package let clusterID: UUID
    package let partition: Int
    package let owner: V2ActorPlacementOwner
    package let activationID: UUID
    fileprivate let partitionHash: UInt64

    package init(roomID: RoomID, clusterID: UUID, partition: Int,
                 owner: V2ActorPlacementOwner, activationID: UUID) {
        self.roomID = roomID; self.clusterID = clusterID; self.partition = partition
        self.owner = owner; self.activationID = activationID
        // Validate the room-to-partition binding without hashing on every
        // invocation or doing cryptographic work inside the directory lock.
        partitionHash = SHA256.hash(data: Array(roomID.rawValue.utf8)).prefix(8)
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

extension V2ActorPlacementDirectory {
    package func admits(_ identity: V2RoomActorIdentity) -> Bool {
        let current = snapshot()
        guard current.clusterID == identity.clusterID,
              Int(identity.partitionHash % UInt64(current.slots.count)) == identity.partition else { return false }
        let slot = current.slots[identity.partition]
        return !slot.retired && slot.transfer == nil && slot.owner == identity.owner
    }
}
