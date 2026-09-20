import Foundation
import IMV2Core

/// One broker interest per room, shared by independent gateway features.
/// Each scope maintains its own room-level demand, not one lease per device.
public actor V2SharedGroupEventWakeInterests {
    public enum Scope: Hashable, Sendable {
        case foreground, accountCoverage
        /// A shared online account lifecycle, independent of connection count.
        case account(UUID)
    }
    public enum Failure: Error, Equatable, Sendable { case closed }

    private final class Entry {
        var owners: [Scope: UUID] = [:]
        var revision = UUID()
        var operation: (id: UUID, task: Task<UUID, Error>)?
    }

    private let underlying: any V2GroupEventWakeInterestManaging
    private var entries: [RoomID: Entry] = [:]
    private var closed = false

    public init(underlying: any V2GroupEventWakeInterestManaging) {
        self.underlying = underlying
    }

    public nonisolated func manager(for scope: Scope) -> some V2GroupEventWakeInterestManaging {
        ScopedInterest(owner: self, scope: scope)
    }

    func interestedScopes(roomID: RoomID) -> Set<Scope> {
        Set(entries[roomID]?.owners.keys.map { $0 } ?? [])
    }

    private func activate(roomID: RoomID, scope: Scope) async throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        let entry = entries[roomID] ?? Entry()
        entries[roomID] = entry
        let token = UUID()
        entry.owners[scope] = token
        entry.revision = UUID()
        do {
            try await reconcile(roomID: roomID, entry: entry)
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
        } catch {
            // A late failure cannot release a newer activation by this scope.
            if entry.owners[scope] == token {
                entry.owners.removeValue(forKey: scope)
                entry.revision = UUID()
            }
            if !closed { try? await reconcile(roomID: roomID, entry: entry) }
            throw error
        }
    }

    private func deactivate(roomID: RoomID, scope: Scope) async {
        guard !closed, let entry = entries[roomID], entry.owners.removeValue(forKey: scope) != nil else { return }
        entry.revision = UUID()
        // A remaining scope's failed broker activation is still reported to
        // its activation caller; releasing our own demand does not own it.
        do { try await reconcile(roomID: roomID, entry: entry) }
        catch {
            // A failed in-flight activation can finish after the final scope
            // has been removed. Still release any partial broker state.
            if !closed, entry.owners.isEmpty { try? await reconcile(roomID: roomID, entry: entry) }
        }
    }

    private func reconcile(roomID: RoomID, entry: Entry) async throws {
        while entries[roomID] === entry {
            let operation: (id: UUID, task: Task<UUID, Error>)
            if let existing = entry.operation { operation = existing }
            else {
                operation = (UUID(), Task { try await self.drive(roomID: roomID, entry: entry) })
                entry.operation = operation
            }
            do {
                let settledRevision = try await operation.task.value
                if entry.operation?.id == operation.id { entry.operation = nil }
                // The task may already have completed before a newer caller
                // joined it. Recheck its returned revision, not just success.
                if settledRevision == entry.revision {
                    if entry.operation == nil, entry.owners.isEmpty, entries[roomID] === entry {
                        entries.removeValue(forKey: roomID)
                    }
                    return
                }
            } catch {
                if entry.operation?.id == operation.id { entry.operation = nil }
                throw error
            }
        }
    }

    private func drive(roomID: RoomID, entry: Entry) async throws -> UUID {
        while true {
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
            guard entries[roomID] === entry else { return entry.revision }
            let revision = entry.revision
            if entry.owners.isEmpty { await underlying.deactivate(roomID: roomID) }
            else { try await underlying.activate(roomID: roomID) }
            // Scope mutations during broker I/O must be reconciled before
            // any waiter can regard activation/deactivation as complete.
            if entry.revision == revision { return revision }
        }
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        let active = entries
        for entry in active.values { entry.operation?.task.cancel() }
        for entry in active.values { _ = try? await entry.operation?.task.value }
        for roomID in active.keys { await underlying.deactivate(roomID: roomID) }
        entries.removeAll()
    }

    private struct ScopedInterest: V2GroupEventWakeInterestManaging {
        let owner: V2SharedGroupEventWakeInterests
        let scope: Scope
        func activate(roomID: RoomID) async throws { try await owner.activate(roomID: roomID, scope: scope) }
        func deactivate(roomID: RoomID) async { await owner.deactivate(roomID: roomID, scope: scope) }
    }
}
