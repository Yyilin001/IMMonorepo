import FluentKit
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure

/// The coordinator persists operation identity before invoking deployment I/O.
/// Trusted backends exclude the exact incarnation irreversibly and prevent it reconnecting.
/// A failed health check, signal delivery, or temporary network cut cannot
/// satisfy this contract. Retrying the same operation must remain safe.
package protocol V2RoomHostExclusionBackend: Sendable {
    func exclude(host: V2ActorHostIdentity, operationID: UUID,
                 deadline: ContinuousClock.Instant) async throws
}

package enum V2RoomHostRecoveryError: Error, Equatable {
    case incompleteDatabaseCoverage
    case deadlineExceeded
}

/// The deployment backend and database map remain package-owned. Neither a
/// remote request nor an operator-supplied boolean can mint an exclusion proof.
package enum V2RoomHostRecoveryCoordinator {
    /// Resume before observing new failures. Each completed Host is recorded
    /// separately; a later failure leaves only unfinished intents for restart.
    /// The caller owns this loop and awaits it before closing SQL/journal resources.
    package static func resumePending(configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                              journal: V2RoomHostRecoveryJournal,
                              backend: any V2RoomHostExclusionBackend,
                              databases: [String: any Database], shardDatabaseTargets: [String: String],
                              deadline: ContinuousClock.Instant) async throws -> [V2ActorHostIdentity] {
        try check(deadline)
        try journal.requireScope(supervisorID: configuration.signer.serviceID,
            hostIDs: Set(configuration.discovery.peers.map(\.hostID)))
        var completed: [V2ActorHostIdentity] = []
        let pending = try await journal.pendingHosts()
        for host in pending {
            let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
            try await retireExcluded(configuration: configuration, control: control, host: host, journal: journal,
                backend: backend, databases: databases,
                shardDatabaseTargets: shardDatabaseTargets.filter { shards.contains($0.key) }, deadline: deadline)
        }
        for host in pending {
            let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
            _ = try await recover(configuration: configuration, control: control, host: host, journal: journal,
                backend: backend, databases: databases,
                shardDatabaseTargets: shardDatabaseTargets.filter { shards.contains($0.key) }, deadline: deadline)
            completed.append(host)
        }
        return completed
    }

    package static func recover(configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                        host: V2ActorHostIdentity, journal: V2RoomHostRecoveryJournal,
                        backend: any V2RoomHostExclusionBackend,
                        databases: [String: any Database], shardDatabaseTargets: [String: String],
                        deadline: ContinuousClock.Instant) async throws -> [V2PlacementControlInspection] {
        let operationID = try await prepareOperation(configuration: configuration, control: control, host: host, journal: journal,
            databases: databases, shardDatabaseTargets: shardDatabaseTargets, deadline: deadline)
        let recovered = try await recover(configuration: configuration, control: control, host: host, operationID: operationID,
            backend: backend, databases: databases, shardDatabaseTargets: shardDatabaseTargets, deadline: deadline)
        // No completion marker on partial retirement/takeover or shutdown error.
        try await journal.complete(host: host, operationID: operationID)
        return recovered
    }

    /// Settle and retire before selecting successors. Multiple failed Hosts
    /// must all retire first; one recovery must not wait for another dead Host
    /// to become a usable successor. A new generation may then register.
    /// Keep intent pending until registration/takeover removes old references.
    package static func retireExcluded(configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                        host: V2ActorHostIdentity, journal: V2RoomHostRecoveryJournal,
                        backend: any V2RoomHostExclusionBackend, databases: [String: any Database],
                        shardDatabaseTargets: [String: String], deadline: ContinuousClock.Instant) async throws {
        let operationID = try await prepareOperation(configuration: configuration, control: control, host: host, journal: journal,
            databases: databases, shardDatabaseTargets: shardDatabaseTargets, deadline: deadline)
        let proof = try await prepareDatabaseProof(configuration: configuration, control: control, host: host, operationID: operationID,
            backend: backend, databases: databases, shardDatabaseTargets: shardDatabaseTargets, deadline: deadline)
        _ = try await control.apply(proof, takeOver: false, deadline: deadline)
    }

    private static func prepareOperation(configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                        host: V2ActorHostIdentity, journal: V2RoomHostRecoveryJournal,
                        databases: [String: any Database], shardDatabaseTargets: [String: String],
                        deadline: ContinuousClock.Instant) async throws -> UUID {
        try check(deadline)
        let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
        try journal.requireScope(supervisorID: configuration.signer.serviceID,
            hostIDs: Set(configuration.discovery.peers.map(\.hostID)))
        guard Set(shardDatabaseTargets.keys) == shards,
              Set(shardDatabaseTargets.values).isSubset(of: Set(databases.keys)) else {
            throw V2RoomHostRecoveryError.incompleteDatabaseCoverage
        }
        // Do not roll the journal back to an old incarnation based on a cached
        // monitor observation. Already-retired exact registrations permit retry.
        let inspections = try await control.inspect(deadline: deadline)
        let existing = try await journal.existingOperation(for: host)
        for shard in shards {
            guard let snapshot = inspections.first(where: { $0.shardID == shard }),
                  let registration = snapshot.hosts.first(where: { $0.identity.hostID == host.hostID.rawValue }) else {
                throw V2ActorPlacementError.staleOwner
            }
            if registration.identity.incarnationID != host.incarnationID {
                // A crash during registration can leave untouched shards on
                // their retired bootstrap/previous identity. Those shards need
                // no retirement for this incarnation. An active replacement
                // is permitted only when resuming an already durable intent.
                guard permitsDifferentRegistration(existingOperation: existing != nil,
                    registrationRetired: registration.retired,
                    hasReferences: !snapshot.partitions.allSatisfy({
                    !($0.owner.hostID == host.hostID.rawValue && $0.owner.incarnationID == host.incarnationID)
                        && !($0.transfer?.successor.hostID == host.hostID.rawValue
                             && $0.transfer?.successor.incarnationID == host.incarnationID)
                })) else { throw V2ActorPlacementError.staleOwner }
            }
        }
        try check(deadline)
        let operationID: UUID
        if let existing { operationID = existing } else { operationID = try await journal.operation(for: host) }
        return operationID
    }

    static func permitsDifferentRegistration(existingOperation: Bool, registrationRetired: Bool,
                                             hasReferences: Bool) -> Bool {
        !hasReferences && (existingOperation || registrationRetired)
    }

    private static func recover(configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                        host: V2ActorHostIdentity, operationID: UUID,
                        backend: any V2RoomHostExclusionBackend,
                        databases: [String: any Database], shardDatabaseTargets: [String: String],
                        deadline: ContinuousClock.Instant) async throws -> [V2PlacementControlInspection] {
        let proof = try await prepareDatabaseProof(configuration: configuration, control: control, host: host, operationID: operationID,
            backend: backend, databases: databases, shardDatabaseTargets: shardDatabaseTargets, deadline: deadline)
        return try await control.apply(proof, takeOver: true, deadline: deadline)
    }

    private static func prepareDatabaseProof(configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                        host: V2ActorHostIdentity, operationID: UUID,
                        backend: any V2RoomHostExclusionBackend, databases: [String: any Database],
                        shardDatabaseTargets: [String: String], deadline: ContinuousClock.Instant) async throws -> V2RoomHostExclusionProof {
        let required = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
        return try await prepareProof(host: host, operationID: operationID,
            requiredShards: required, shardDatabaseTargets: shardDatabaseTargets,
            availableDatabaseTargets: Set(databases.keys), deadline: deadline,
            exclude: { try await backend.exclude(host: host, operationID: operationID, deadline: deadline) },
            settle: { target in
                // Coverage is checked before exclusion; each handle is supplied
                // by trusted deployment topology, never by a remote URL.
                guard let database = databases[target] else {
                    throw V2RoomHostRecoveryError.incompleteDatabaseCoverage
                }
                try await V2PostgresHostSessionSettlement.settle(host: host, database: database, deadline: deadline)
            })
    }

    /// Separated from I/O for checking fail-closed stage ordering. Production
    /// always uses the concrete PostgreSQL settlement implementation above.
    static func prepareProof(host: V2ActorHostIdentity, operationID: UUID,
                             requiredShards: Set<String>, shardDatabaseTargets: [String: String],
                             availableDatabaseTargets: Set<String>,
                             deadline: ContinuousClock.Instant,
                             exclude: @Sendable () async throws -> Void,
                             settle: @Sendable (String) async throws -> Void) async throws -> V2RoomHostExclusionProof {
        guard !requiredShards.isEmpty, Set(shardDatabaseTargets.keys) == requiredShards,
              !availableDatabaseTargets.isEmpty, availableDatabaseTargets.allSatisfy({ !$0.isEmpty }),
              Set(shardDatabaseTargets.values).isSubset(of: availableDatabaseTargets) else {
            throw V2RoomHostRecoveryError.incompleteDatabaseCoverage
        }
        try check(deadline)
        try await exclude()
        // Include control/policy databases from the deployment inventory too,
        // even when they do not own a room shard. Shared targets settle once.
        for target in availableDatabaseTargets.sorted() {
            try check(deadline)
            try await settle(target)
        }
        try check(deadline)
        return .init(host: host, operationID: operationID, settledShardIDs: requiredShards)
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomHostRecoveryError.deadlineExceeded }
    }
}
