import Foundation
import IMV2Core

/// Multiplexes the durable Hybrid-room wake outbox across independent room
/// owner databases. A Gateway may run this store on every replica: each
/// underlying PostgreSQL store still owns the lease fence for its rows, while
/// this actor remembers which physical owner issued an in-flight lease so the
/// completion never performs a control-plane route lookup.
///
/// The mapping is intentionally process-local. After a process restart the
/// PostgreSQL lease expires and a later claim recreates the mapping; no wake
/// correctness depends on this actor surviving a crash.
public actor V2RoutedGroupEventWakeStore: V2GroupEventWakeStore {
    private struct Owner: Sendable {
        let store: any V2GroupEventWakeStore
    }

    private struct LeaseKey: Hashable, Sendable {
        let roomID: RoomID
        let revision: UInt64
        let claimToken: UUID

        init(_ lease: V2GroupEventWakeLease) {
            roomID = lease.wake.roomID
            revision = lease.revision
            claimToken = lease.claimToken
        }
    }

    private struct LeaseOwner: Sendable {
        let ownerIndex: Int
        let expiresAt: Date
    }

    private enum ClaimResult: Sendable {
        case success(ownerIndex: Int, leases: [V2GroupEventWakeLease])
        case failure(any Error)
    }

    private let owners: [Owner]
    private var nextOwnerIndex = 0
    private var leaseOwners: [LeaseKey: LeaseOwner] = [:]

    /// `ownerStores` must contain one entry per physical PostgreSQL location,
    /// not one entry per logical shard. The key exists only for deterministic
    /// startup ordering and diagnostics; it never enters a client or broker
    /// payload.
    public init(ownerStores: [String: any V2GroupEventWakeStore]) throws {
        guard !ownerStores.isEmpty,
              ownerStores.keys.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        owners = ownerStores.keys.sorted().map { key in
            Owner(store: ownerStores[key]!)
        }
    }

    public func claimPending(
        now: Date,
        leaseDuration: TimeInterval,
        limit: Int
    ) async throws -> [V2GroupEventWakeLease] {
        guard leaseDuration > 0, limit > 0 else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        leaseOwners = leaseOwners.filter { $0.value.expiresAt > now }

        let startIndex = nextOwnerIndex
        nextOwnerIndex = (nextOwnerIndex + 1) % owners.count
        let baseQuota = limit / owners.count
        let remainder = limit % owners.count
        var work: [(ownerIndex: Int, quota: Int)] = []
        work.reserveCapacity(min(limit, owners.count))
        for offset in owners.indices {
            let quota = baseQuota + (offset < remainder ? 1 : 0)
            guard quota > 0 else { continue }
            work.append(((startIndex + offset) % owners.count, quota))
        }

        let results = await withTaskGroup(
            of: ClaimResult.self,
            returning: [ClaimResult].self
        ) { group in
            for item in work {
                let store = owners[item.ownerIndex].store
                group.addTask {
                    do {
                        return .success(
                            ownerIndex: item.ownerIndex,
                            leases: try await store.claimPending(
                                now: now,
                                leaseDuration: leaseDuration,
                                limit: item.quota
                            )
                        )
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [ClaimResult] = []
            collected.reserveCapacity(work.count)
            for await result in group { collected.append(result) }
            return collected
        }

        let expiry = now.addingTimeInterval(leaseDuration)
        var leases: [V2GroupEventWakeLease] = []
        leases.reserveCapacity(limit)
        var firstError: (any Error)?
        var successfulOwnerCount = 0
        for result in results {
            switch result {
            case .success(let ownerIndex, let claimed):
                successfulOwnerCount += 1
                for lease in claimed {
                    leaseOwners[LeaseKey(lease)] = .init(
                        ownerIndex: ownerIndex,
                        expiresAt: expiry
                    )
                    leases.append(lease)
                }
            case .failure(let error):
                if firstError == nil { firstError = error }
            }
        }
        // A partial owner outage must not strand leases already acquired from
        // healthy owners. Return those leases now; the round-robin start moves
        // on the next pass and the failed owner remains independently durable.
        if successfulOwnerCount == 0, let firstError { throw firstError }
        guard leases.count <= limit else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        return leases
    }

    public func markPublished(_ lease: V2GroupEventWakeLease) async throws {
        let key = LeaseKey(lease)
        guard let owner = leaseOwners[key] else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        try await owners[owner.ownerIndex].store.markPublished(lease)
        leaseOwners.removeValue(forKey: key)
    }

    public func scheduleRetry(
        _ lease: V2GroupEventWakeLease,
        nextAttemptAt: Date
    ) async throws {
        let key = LeaseKey(lease)
        guard let owner = leaseOwners[key] else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        try await owners[owner.ownerIndex].store.scheduleRetry(
            lease,
            nextAttemptAt: nextAttemptAt
        )
        leaseOwners.removeValue(forKey: key)
    }
}
