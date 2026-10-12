import AsyncHTTPClient
import FluentKit
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix

/// Serial maintenance in the supervisor's owned monitor task, never a detached
/// cleanup worker. The current generation and an unfinished successor stay live.
package actor V2RoomHostGenerationRetention {
    package struct Entry: Sendable {
        let launch: V2RoomHostSupervisorDocument.Launch
        let journal: V2DockerRoomHostLaunchJournal
        let inventory: V2DockerRoomHostInventory
        package init(launch: V2RoomHostSupervisorDocument.Launch, journal: V2DockerRoomHostLaunchJournal,
                     inventory: V2DockerRoomHostInventory) {
            self.launch = launch; self.journal = journal; self.inventory = inventory
        }
    }
    private var entries: [Entry]
    private let store: V2RoomHostSupervisorDocumentStore
    private let configuration: V2RoomActorApplicationConfiguration
    private let control: V2RoomHostControlSession
    private let recovery: V2RoomHostRecoveryJournal
    private let databases: [String: any Database]
    private let pool: NIOThreadPool
    private let client: HTTPClient

    package init(entries: [Entry], store: V2RoomHostSupervisorDocumentStore,
                 configuration: V2RoomActorApplicationConfiguration, control: V2RoomHostControlSession,
                 recovery: V2RoomHostRecoveryJournal, databases: [String: any Database],
                 pool: NIOThreadPool, client: HTTPClient) {
        self.entries = entries; self.store = store; self.configuration = configuration; self.control = control
        self.recovery = recovery; self.databases = databases; self.pool = pool; self.client = client
    }

    /// Also used before launching at startup. Retired metadata may already be
    /// partly absent, so recovery uses the immutable binding in the descriptor.
    package func resume(deadline: ContinuousClock.Instant) async throws {
        let document = try await store.load()
        for retired in document.retiredLaunches {
            try await confirm(retired, document: document, deadline: deadline)
            if let index = entries.firstIndex(where: { $0.launch == retired.launch }) {
                try await entries[index].journal.close()
                try await entries[index].inventory.close()
                entries.remove(at: index)
            }
            try await V2ActorDurableFileStorage.removeGeneration(
                journal: URL(fileURLWithPath: retired.launch.journalPath),
                inventory: URL(fileURLWithPath: retired.launch.inventoryPath),
                gate: URL(fileURLWithPath: retired.launch.gateDirectory), pool: pool)
            try await store.finish(operationID: retired.operationID)
        }
    }

    package func collect(deadline: ContinuousClock.Instant) async throws {
        // A failed deletion resumes before another intent can be admitted.
        try await resume(deadline: deadline)
        let document = try await store.load()
        // No extra quorum/SQL work on the common one-generation deployment.
        guard Set(entries.map { $0.launch.hostID }).count < entries.count else { return }
        for entry in entries {
            let later = entries.drop(while: { $0.launch != entry.launch }).dropFirst()
                .filter { $0.launch.hostID == entry.launch.hostID }
            guard !later.isEmpty else { continue }
            let latest = try await later.last!.journal.intent()
            guard latest.released else { continue }
            let intent = try await entry.journal.intent()
            guard intent.released, let binding = intent.binding,
                  try await entry.inventory.bindings().contains(where: {
                      $0.host == binding.host && $0.containerID == binding.containerID && $0.startedAt == binding.startedAt
                  }) else { throw V2DockerRoomHostLaunchError.conflictingInstance }
            let host = binding.host
            if try await recovery.pendingHosts().contains(host) { continue }
            let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
            guard Self.unreferenced(host, shards: shards, inspections: try await control.inspect(deadline: deadline)) else { continue }
            let retired = try V2RoomHostSupervisorDocument.Retired(launch: entry.launch, binding: binding)
            try await confirm(retired, document: document, deadline: deadline)
            // Persist both removal from live launches and deletion intent first.
            try await store.enqueue(retired)
            try await resume(deadline: deadline)
            FileHandle.standardOutput.write(Data("Host supervisor retired generation records reclaimed.\n".utf8))
        }
    }

    private func confirm(_ retired: V2RoomHostSupervisorDocument.Retired,
                         document: V2RoomHostSupervisorDocument, deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let binding = try retired.binding, host = binding.host
        let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
        guard !databases.isEmpty, Set(document.shardDatabaseTargets.keys).isSuperset(of: shards),
              Set(document.shardDatabaseTargets.values).isSubset(of: Set(databases.keys)),
              !(try await recovery.pendingHosts()).contains(host),
              Self.unreferenced(host, shards: shards, inspections: try await control.inspect(deadline: deadline)) else {
            throw V2ActorPlacementError.staleOwner
        }
        let backend = try V2DockerRoomHostExclusionBackend(socketPath: document.socketPath,
            daemonID: document.daemonID, bindings: [binding], client: client)
        try await backend.exclude(host: host, operationID: retired.operationID, deadline: deadline)
        for target in databases.keys.sorted() {
            try await V2PostgresHostSessionSettlement.settle(host: host, database: databases[target]!, deadline: deadline)
        }
        guard Self.unreferenced(host, shards: shards, inspections: try await control.inspect(deadline: deadline)),
              !(try await recovery.pendingHosts()).contains(host) else { throw V2ActorPlacementError.staleOwner }
    }

    /// Missing shards/registration are not evidence that a generation is gone.
    /// Even a retired exact registration remains a recovery reference until a
    /// newer incarnation has replaced it; epochs cannot revive an old identity.
    static func unreferenced(_ host: V2ActorHostIdentity, shards: Set<String>,
                             inspections: [V2PlacementControlInspection]) -> Bool {
        !shards.isEmpty && shards.allSatisfy { shard in
            guard let inspection = inspections.first(where: { $0.shardID == shard }),
                  let registration = inspection.hosts.first(where: { $0.identity.hostID == host.hostID.rawValue }),
                  registration.identity.incarnationID != host.incarnationID else { return false }
            return inspection.partitions.allSatisfy {
                !($0.owner.hostID == host.hostID.rawValue && $0.owner.incarnationID == host.incarnationID)
                    && !($0.transfer?.successor.hostID == host.hostID.rawValue
                         && $0.transfer?.successor.incarnationID == host.incarnationID)
            }
        }
    }
}
