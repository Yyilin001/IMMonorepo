import AsyncHTTPClient
import FluentPostgresDriver
import Foundation
import IMV2ActorApplication
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
import Logging
import NIOPosix
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum IMV2RoomHostSupervisorApp {
    private typealias Document = V2RoomHostSupervisorDocument
    private typealias Launch = Document.Launch
    private struct Environment: V2RuntimeEnvironment {
        let actorConfigurationFile: String
        func value(for key: String) -> String? {
            key == "IMV2_ROOM_ACTOR_CONFIGURATION_FILE" ? actorConfigurationFile : ProcessInfo.processInfo.environment[key]
        }
    }
    private struct Opened: Sendable {
        let launch: Launch
        let scope: V2DockerRoomHostLaunchJournal.Scope
        let journal: V2DockerRoomHostLaunchJournal
    }
    private enum Event: Sendable { case stopped, unexpectedReturn }

    static func main() async {
        V2ProcessTerminationSignal.install()
        LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
        do { try await execute() }
        catch {
            // Configuration/templates may contain database credentials. Never
            // render raw errors or Docker response bodies from this boundary.
            FileHandle.standardError.write(Data("Host supervisor failed [\(failureCategory(error))]; persisted launch and recovery intents retained.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    private static func execute() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || arguments == ["--provision"] || arguments == ["--provision-launches"],
              let path = ProcessInfo.processInfo.environment["IMV2_HOST_SUPERVISOR_CONFIGURATION_FILE"] else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
        let document = try JSONDecoder().decode(Document.self, from: read(path))
        try document.validatePaths(configurationPath: path)
        guard !document.launches.isEmpty, document.launches.count <= 256, !document.shardIDs.isEmpty,
              Set(document.shardIDs).count == document.shardIDs.count,
              !document.databases.isEmpty, !document.daemonID.isEmpty, document.socketPath.hasPrefix("/") else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
        let configuration = try V2RoomActorApplicationConfiguration(
            environment: Environment(actorConfigurationFile: document.actorConfigurationFile), hostsRooms: false,
            configuredShardIDs: Set(document.shardIDs))
        let hostIDs = Set(configuration.discovery.peers.map(\.hostID))
        var scopes: [V2DockerRoomHostLaunchJournal.Scope] = []
        var journalPaths = Set<String>(), inventoryPaths = Set<String>(), gatePaths = Set<String>()
        for launch in document.launches {
            let host = try V2ActorHostID(launch.hostID), service = try V2ActorServiceID(launch.serviceID)
            _ = try V2PlacementControlService.exclusionShards(configuration: configuration,
                host: .init(hostID: host, incarnationID: UUID()))
            guard configuration.discovery.peers.contains(where: { $0.hostID == host && $0.serviceID == service }),
                  launch.journalPath.hasPrefix("/"), launch.inventoryPath.hasPrefix("/"), launch.gateDirectory.hasPrefix("/"),
                  journalPaths.insert(launch.journalPath).inserted, inventoryPaths.insert(launch.inventoryPath).inserted,
                  gatePaths.insert(launch.gateDirectory).inserted else { throw V2DockerRoomHostLaunchError.invalidIntent }
            scopes.append(.init(supervisorID: configuration.signer.serviceID, daemonID: document.daemonID,
                socketPath: document.socketPath, hostID: host, serviceID: service, gateDirectory: launch.gateDirectory))
        }
        let managed = Set(scopes.map(\.hostID))
        let requiredShards = try managed.reduce(into: Set<String>()) {
            $0.formUnion(try V2PlacementControlService.exclusionShards(configuration: configuration,
                host: .init(hostID: $1, incarnationID: UUID())))
        }
        guard Set(document.shardDatabaseTargets.keys) == requiredShards,
              Set(document.shardDatabaseTargets.values).isSubset(of: Set(document.databases.keys)),
              !journalPaths.contains(document.recoveryJournalPath), !inventoryPaths.contains(document.recoveryJournalPath),
              journalPaths.isDisjoint(with: inventoryPaths) else { throw V2RoomHostRecoveryError.incompleteDatabaseCoverage }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = V2DatabaseResources(eventLoopGroup: group, logger: Logger(label: "imv2.host-supervisor"), ownsEventLoopGroup: true)
        let pool = NIOThreadPool(numberOfThreads: 2); pool.start()
        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
        var recovery: V2RoomHostRecoveryJournal?, opened: [Opened] = []
        var descriptor: V2RoomHostSupervisorDocumentStore?
        do {
            let store = try await V2RoomHostSupervisorDocumentStore.open(at: path, pool: pool)
            descriptor = store
            guard try await store.load() == document else { throw V2DockerRoomHostLaunchError.invalidIntent }
            if !arguments.isEmpty {
                guard document.retiredLaunches.isEmpty else { throw V2DockerRoomHostLaunchError.invalidIntent }
                let append = arguments == ["--provision-launches"]
                if append {
                    recovery = try await .open(at: URL(fileURLWithPath: document.recoveryJournalPath),
                        supervisorID: configuration.signer.serviceID, hostIDs: hostIDs, pool: pool)
                } else {
                    recovery = try await .provision(at: URL(fileURLWithPath: document.recoveryJournalPath),
                        supervisorID: configuration.signer.serviceID, hostIDs: hostIDs, pool: pool)
                }
                for (launch, scope) in zip(document.launches, scopes) {
                    if append && FileManager.default.fileExists(atPath: launch.journalPath) {
                        opened.append(.init(launch: launch, scope: scope, journal: try await .open(
                            at: URL(fileURLWithPath: launch.journalPath), scope: scope, pool: pool)))
                        continue
                    }
                    guard let templatePath = launch.createTemplatePath else { throw V2DockerRoomHostLaunchError.invalidIntent }
                    let template = try read(templatePath)
                    try FileManager.default.createDirectory(atPath: scope.gateDirectory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    let journal = try await V2DockerRoomHostLaunchJournal.provision(
                        at: URL(fileURLWithPath: launch.journalPath), scope: scope, pool: pool,
                        createRequest: { token in try createRequest(template: template, scope: scope, token: token) })
                    opened.append(.init(launch: launch, scope: scope, journal: journal))
                }
            } else {
                let journal = try await V2RoomHostRecoveryJournal.open(at: URL(fileURLWithPath: document.recoveryJournalPath),
                    supervisorID: configuration.signer.serviceID, hostIDs: hostIDs, pool: pool); recovery = journal
                for (launch, scope) in zip(document.launches, scopes) {
                    opened.append(.init(launch: launch, scope: scope, journal: try await .open(
                        at: URL(fileURLWithPath: launch.journalPath), scope: scope, pool: pool)))
                }
                var databases: [String: any Database] = [:]
                for target in document.databases.keys.sorted() {
                    let id = DatabaseID(string: "supervisor-" + target)
                    resources.databases.use(try .postgres(url: document.databases[target]!, maxConnectionsPerEventLoop: 1), as: id)
                    databases[target] = resources.database(id)
                }
                try await run(configuration: configuration, document: document, opened: opened,
                    recovery: journal, managed: managed, databases: databases, pool: pool, client: client, descriptor: store)
            }
            for launch in opened { try await launch.journal.close() }; opened.removeAll()
            try await recovery?.close(); recovery = nil
            try await descriptor?.close(); descriptor = nil
            try await client.shutdown(); try await pool.shutdownGracefully(); try await resources.shutdown()
        } catch {
            for launch in opened { try? await launch.journal.close() }
            try? await recovery?.close(); try? await descriptor?.close(); try? await client.shutdown()
            try? await pool.shutdownGracefully(); try? await resources.shutdown()
            throw error
        }
    }
    private static func run(configuration: V2RoomActorApplicationConfiguration, document: Document,
                            opened: [Opened], recovery: V2RoomHostRecoveryJournal, managed: Set<V2ActorHostID>,
                            databases: [String: any Database], pool: NIOThreadPool, client: HTTPClient,
                            descriptor: V2RoomHostSupervisorDocumentStore) async throws {
        try await withThrowingTaskGroup(of: Event.self) { tasks in
            tasks.addTask {
                let control = try V2RoomHostControlSession(configuration: configuration)
                var inventories: [V2DockerRoomHostInventory] = []
                do {
                    let resumedRetention = V2RoomHostGenerationRetention(entries: [], store: descriptor,
                        configuration: configuration, control: control, recovery: recovery, databases: databases, pool: pool, client: client)
                    try await resumedRetention.resume(deadline: .now + .seconds(120))
                    var bindings: [V2DockerRoomHostBinding] = []
                    var intents: [(Opened, V2DockerRoomHostLaunchJournal.Intent)] = []
                    for launch in opened { intents.append((launch, try await launch.journal.intent())) }
                    // Descriptor order is generation order per Host. Keep all
                    // generations referenced by recovery, with at most one
                    // unfinished newest launch per Host.
                    var unfinished = Set<V2ActorHostID>()
                    var previous: [V2ActorHostID: V2DockerRoomHostBinding] = [:]
                    var replacements: [V2ActorHostID: V2DockerRoomHostBinding] = [:]
                    for (launch, intent) in intents {
                        let hostID = launch.scope.hostID
                        guard !unfinished.contains(hostID) else { throw V2DockerRoomHostLaunchError.invalidIntent }
                        if intent.released {
                            guard let binding = intent.binding else { throw V2DockerRoomHostLaunchError.invalidIntent }
                            previous[hostID] = binding
                        } else {
                            unfinished.insert(hostID)
                            replacements[hostID] = previous[hostID]
                        }
                    }
                    let pending = try await recovery.pendingHosts()
                    if !pending.isEmpty || !replacements.isEmpty {
                        let recorded = intents.compactMap { $0.1.binding }
                        let backend = try V2DockerRoomHostDeploymentBackend(socketPath: document.socketPath,
                            daemonID: document.daemonID, bindings: recorded, managedHostIDs: managed, client: client)
                        for host in pending {
                            if let replacement = replacements[host.hostID] {
                                guard replacement.host == host else { throw V2DockerRoomHostLaunchError.conflictingInstance }
                                continue
                            }
                            guard managed.contains(host.hostID) else { throw V2DockerRoomHostLaunchError.invalidIntent }
                            let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
                            try await retryStartup {
                                try await V2RoomHostRecoveryCoordinator.retireExcluded(configuration: configuration, control: control,
                                    host: host, journal: recovery, backend: backend, databases: databases,
                                    shardDatabaseTargets: document.shardDatabaseTargets.filter { shards.contains($0.key) },
                                    deadline: $0)
                            }
                        }
                        for hostID in replacements.keys.sorted() {
                            let host = replacements[hostID]!.host
                            let shards = try V2PlacementControlService.exclusionShards(configuration: configuration, host: host)
                            try await retryStartup {
                                try await V2RoomHostRecoveryCoordinator.retireExcluded(configuration: configuration, control: control,
                                    host: host, journal: recovery, backend: backend, databases: databases,
                                    shardDatabaseTargets: document.shardDatabaseTargets.filter { shards.contains($0.key) },
                                    deadline: $0)
                            }
                        }
                    }
                    for launch in opened {
                        let launcher = try V2DockerRoomHostLauncher(scope: launch.scope, journal: launch.journal, pool: pool, client: client)
                        let result = try await launcher.launch(inventoryPath: URL(fileURLWithPath: launch.launch.inventoryPath),
                            deadline: .now + .seconds(120))
                        inventories.append(result.inventory); bindings.append(result.binding)
                    }
                    let backend = try V2DockerRoomHostDeploymentBackend(socketPath: document.socketPath,
                        daemonID: document.daemonID, bindings: bindings, managedHostIDs: managed, client: client)
                    let monitor = try V2RoomHostFailureMonitor(configuration: configuration, control: control, journal: recovery,
                        backend: backend, observer: backend, databases: databases, shardDatabaseTargets: document.shardDatabaseTargets,
                        managedHostIDs: managed)
                    let retention = V2RoomHostGenerationRetention(entries: zip(opened, inventories).map {
                        .init(launch: $0.0.launch, journal: $0.0.journal, inventory: $0.1)
                    }, store: descriptor, configuration: configuration, control: control, recovery: recovery,
                       databases: databases, pool: pool, client: client)
                    FileHandle.standardOutput.write(Data("Host supervisor monitor active.\n".utf8))
                    try await monitor.run(afterRound: { try await retention.collect(deadline: $0) }, onFailure: { error in
                        FileHandle.standardError.write(Data("Host recovery round failed [\(failureCategory(error))]; durable intent retained for retry.\n".utf8))
                    })
                    try await control.close()
                    for inventory in inventories { try await inventory.close() }
                    return .unexpectedReturn
                } catch {
                    let failure = error
                    var shutdownFailure: (any Error)?
                    do { try await control.close() } catch { shutdownFailure = error }
                    for inventory in inventories {
                        do { try await inventory.close() } catch { shutdownFailure = shutdownFailure ?? error }
                    }
                    throw shutdownFailure ?? failure
                }
            }
            tasks.addTask { await V2ProcessTerminationSignal.wait(); return .stopped }
            guard try await tasks.next() == .stopped else { throw V2RoomActorApplicationError.incompleteShutdown }
            tasks.cancelAll()
            while true {
                do { guard try await tasks.next() != nil else { break } }
                catch is CancellationError { continue }
            }
        }
    }
    /// Startup reconciliation has the same retry lifecycle as monitoring. Each
    /// attempt finishes before the next starts; cancellation drains the attempt
    /// before the owner closes SQL, HTTP and durable files.
    private static func retryStartup(_ work: @Sendable (ContinuousClock.Instant) async throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            do { try await work(.now + .seconds(120)); return }
            catch {
                try Task.checkCancellation()
                let retry: Bool
                switch error {
                case V2ActorPlacementError.unavailable, V2ActorPlacementError.requestExpired, V2RoomHostRecoveryError.deadlineExceeded,
                     V2DockerRoomHostExclusionError.unavailable: retry = true
                default: retry = false
                }
                guard retry else { throw error }
                FileHandle.standardError.write(Data("Host startup recovery retry [\(failureCategory(error))]; durable intent retained.\n".utf8))
                try await ContinuousClock().sleep(for: .seconds(1))
            }
        }
    }
    /// Known local enums contain no response bodies or deployment credentials.
    /// Unknown errors expose only their type, never their textual payload.
    private static func failureCategory(_ error: any Error) -> String {
        switch error {
        case let value as V2DockerRoomHostExclusionError: "exclusion." + String(describing: value)
        case let value as V2DockerRoomHostLaunchError: "launch." + String(describing: value)
        case let value as V2DockerRoomHostLauncherError: "launcher." + String(describing: value)
        case let value as V2RoomActorApplicationError: "actor." + String(describing: value)
        case let value as V2ActorPlacementError: "placement." + String(describing: value)
        case let value as V2RoomHostRecoveryError: "recovery." + String(describing: value)
        case let value as POSIXError: "file.errno." + String(value.code.rawValue)
        default: String(reflecting: type(of: error))
        }
    }
    private static func read(_ path: String) throws -> Data {
        guard path.hasPrefix("/") else { throw V2DockerRoomHostLaunchError.invalidIntent }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !bytes.isEmpty, bytes.count <= 1_048_576 else { throw V2DockerRoomHostLaunchError.invalidIntent }
        return bytes
    }
    /// JSON belongs to the external Engine API. Only reserved launch fields
    /// are supplied here; the durable journal validates the resulting request.
    private static func createRequest(template: Data, scope: V2DockerRoomHostLaunchJournal.Scope, token: UUID) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: template) as? [String: Any],
              var environment = object["Env"] as? [String], var labels = object["Labels"] as? [String: String] else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
        let keys = ["IMV2_ROOM_ACTOR_STARTUP_GATE_DIRECTORY", "IMV2_ROOM_ACTOR_STARTUP_GATE_TOKEN", "IMV2_ROOM_ACTOR_STARTUP_SUPERVISOR_ID"]
        guard !environment.contains(where: { entry in keys.contains(where: { entry.hasPrefix($0 + "=") }) }) else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
        environment += [keys[0] + "=/imv2-startup", keys[1] + "=" + token.uuidString.lowercased(), keys[2] + "=" + scope.supervisorID.rawValue]
        labels["com.imv2.actor.host-id"] = scope.hostID.rawValue
        labels["com.imv2.actor.launch-token"] = token.uuidString.lowercased()
        object["Env"] = environment; object["Labels"] = labels
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
