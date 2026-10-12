import FluentKit
import Foundation
import IMV2ActorContracts

/// Deployment observations nominate candidates only. They never mint proof;
/// recovery must still exclude the exact instance and settle its SQL sessions.
package protocol V2RoomHostFailureObserver: Sendable {
    func failedHosts(among hosts: Set<V2ActorHostIdentity>,
                     deadline: ContinuousClock.Instant) async throws -> Set<V2ActorHostIdentity>
}

package enum V2RoomHostFailureMonitorError: Error {
    case invalidConfiguration, conflictingIncarnations, unexpectedCandidate
}

/// Run in the deployment service's owned task. No detached worker, overlap,
/// or fire-and-forget shutdown: the service awaits run before closing resources.
package struct V2RoomHostFailureMonitor: Sendable {
    private let control: V2RoomHostControlSession
    private let configuration: V2RoomActorApplicationConfiguration
    private let journal: V2RoomHostRecoveryJournal
    private let backend: any V2RoomHostExclusionBackend
    private let observer: any V2RoomHostFailureObserver
    private let databases: [String: any Database]
    private let shardDatabaseTargets: [String: String]
    private let pollInterval: Duration
    private let roundBudget: Duration
    private let managedHostIDs: Set<V2ActorHostID>

    package init(configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                 journal: V2RoomHostRecoveryJournal,
                 backend: any V2RoomHostExclusionBackend, observer: any V2RoomHostFailureObserver,
                 databases: [String: any Database], shardDatabaseTargets: [String: String],
                 managedHostIDs: Set<V2ActorHostID>,
                 pollInterval: Duration = .seconds(1), roundBudget: Duration = .seconds(30)) throws {
        guard pollInterval >= .milliseconds(100), pollInterval <= .seconds(60),
              roundBudget >= .seconds(1), roundBudget <= .seconds(300),
              !databases.isEmpty, databases.keys.allSatisfy({ !$0.isEmpty }),
              Set(shardDatabaseTargets.values).isSubset(of: Set(databases.keys)) else {
            throw V2RoomHostFailureMonitorError.invalidConfiguration
        }
        let hosts = Set(configuration.discovery.peers.map(\.hostID))
        guard !managedHostIDs.isEmpty, managedHostIDs.isSubset(of: hosts) else {
            throw V2RoomHostFailureMonitorError.invalidConfiguration
        }
        try journal.requireScope(supervisorID: configuration.signer.serviceID, hostIDs: hosts)
        var shards = Set<String>()
        for hostID in managedHostIDs {
            shards.formUnion(try V2PlacementControlService.exclusionShards(configuration: configuration,
                host: .init(hostID: hostID, incarnationID: UUID())))
        }
        guard !hosts.isEmpty, Set(shardDatabaseTargets.keys) == shards else {
            throw V2RoomHostRecoveryError.incompleteDatabaseCoverage
        }
        self.control = control; self.configuration = configuration; self.journal = journal
        self.backend = backend; self.observer = observer; self.databases = databases
        self.shardDatabaseTargets = shardDatabaseTargets
        self.pollInterval = pollInterval; self.roundBudget = roundBudget
        self.managedHostIDs = managedHostIDs
    }

    package func run(afterRound: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = { _ in },
                     onFailure: @escaping @Sendable (any Error) async -> Void) async throws {
        try await Self.loop(pollInterval: pollInterval, roundBudget: roundBudget,
            round: {
                try await runRound(deadline: $0)
                try await afterRound($0)
            }, onFailure: onFailure)
    }

    private func runRound(deadline: ContinuousClock.Instant) async throws {
        // Retire every known failure before choosing any successor. Pending
        // takeover must not prevent observing another stopped Host.
        for host in try await journal.pendingHosts() {
            guard managedHostIDs.contains(host.hostID) else { throw V2RoomHostFailureMonitorError.unexpectedCandidate }
            try await retire(host, deadline: deadline)
        }
        let inspections = try await control.inspect(deadline: deadline)
        let hosts = try Self.currentHosts(inspections, managedHostIDs: managedHostIDs)
        let failed = try await observer.failedHosts(among: hosts, deadline: deadline)
        guard failed.isSubset(of: hosts) else { throw V2RoomHostFailureMonitorError.unexpectedCandidate }
        for host in failed.sorted(by: { $0.hostID.rawValue < $1.hostID.rawValue }) {
            try Task.checkCancellation()
            // Observation is not authority: re-read, persist, exclude and
            // settle every physical database before committing retirement.
            try await retire(host, deadline: deadline)
        }
        for host in try await journal.pendingHosts() {
            try await recover(host, deadline: deadline)
        }
    }

    private func retire(_ host: V2ActorHostIdentity, deadline: ContinuousClock.Instant) async throws {
        let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
        try await V2RoomHostRecoveryCoordinator.retireExcluded(configuration: configuration, control: control,
            host: host, journal: journal, backend: backend, databases: databases,
            shardDatabaseTargets: shardDatabaseTargets.filter { shards.contains($0.key) }, deadline: deadline)
    }

    private func recover(_ host: V2ActorHostIdentity, deadline: ContinuousClock.Instant) async throws {
        let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
        _ = try await V2RoomHostRecoveryCoordinator.recover(configuration: configuration, control: control,
            host: host, journal: journal, backend: backend, databases: databases,
            shardDatabaseTargets: shardDatabaseTargets.filter { shards.contains($0.key) }, deadline: deadline)
    }

    package static func currentHosts(_ inspections: [V2PlacementControlInspection],
                                     managedHostIDs: Set<V2ActorHostID>) throws -> Set<V2ActorHostIdentity> {
        var byID: [V2ActorHostID: UUID] = [:]
        for inspection in inspections {
            for registration in inspection.hosts where !registration.retired {
                let hostID = try V2ActorHostID(registration.identity.hostID)
                guard managedHostIDs.contains(hostID) else { continue }
                let incarnation = registration.identity.incarnationID
                if let prior = byID[hostID], prior != incarnation {
                    throw V2RoomHostFailureMonitorError.conflictingIncarnations
                }
                byID[hostID] = incarnation
            }
        }
        return Set(byID.map { .init(hostID: $0.key, incarnationID: $0.value) })
    }

    /// Small lifecycle seam: production's round always uses the concrete
    /// coordinator above. Retries wait even when a round immediately fails.
    package static func loop(pollInterval: Duration, roundBudget: Duration,
                             round: @Sendable (ContinuousClock.Instant) async throws -> Void,
                             onFailure: @Sendable (any Error) async -> Void) async throws {
        while true {
            try Task.checkCancellation()
            do { try await round(.now + roundBudget) }
            catch {
                try Task.checkCancellation()
                await onFailure(error)
            }
            try await ContinuousClock().sleep(for: pollInterval)
        }
    }
}
