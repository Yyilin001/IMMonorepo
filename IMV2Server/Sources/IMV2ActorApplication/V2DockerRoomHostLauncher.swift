import AsyncHTTPClient
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import NIOPosix

package enum V2DockerRoomHostLauncherError: Error { case missingInstance, instanceStopped, unexpectedResponse }

/// Runs one already-durable launch intent. Creation/start unknown outcomes are
/// reconciled by the same name/full ID; an exited container is never restarted.
package struct V2DockerRoomHostLauncher: Sendable {
    package struct Result: Sendable {
        package let binding: V2DockerRoomHostBinding
        /// Caller retains/closes this handle after monitor lifecycle completion.
        package let inventory: V2DockerRoomHostInventory
    }
    private let scope: V2DockerRoomHostLaunchJournal.Scope
    private let journal: V2DockerRoomHostLaunchJournal
    private let pool: NIOThreadPool
    private let request: @Sendable (String, String, Data?, ContinuousClock.Instant) async throws -> V2DockerRoomHostExclusionBackend.Response

    package init(scope: V2DockerRoomHostLaunchJournal.Scope, journal: V2DockerRoomHostLaunchJournal,
                 pool: NIOThreadPool, client: HTTPClient) throws {
        let engine = try V2DockerEngineConnection(socketPath: scope.socketPath, client: client)
        try self.init(scope: scope, journal: journal, pool: pool,
            request: { method, path, body, deadline in try await engine.request(method, path, body: body, deadline: deadline) })
    }
    package init(scope: V2DockerRoomHostLaunchJournal.Scope, journal: V2DockerRoomHostLaunchJournal,
                 pool: NIOThreadPool,
                 request: @escaping @Sendable (String, String, Data?, ContinuousClock.Instant) async throws -> V2DockerRoomHostExclusionBackend.Response) throws {
        try journal.requireScope(scope)
        self.scope = scope; self.journal = journal; self.pool = pool; self.request = request
    }

    package func launch(inventoryPath: URL, deadline: ContinuousClock.Instant) async throws -> Result {
        try await checkDaemon(deadline)
        var intent = try await journal.intent()
        let inventoryScope = V2DockerRoomHostInventory.Scope(supervisorID: scope.supervisorID, daemonID: scope.daemonID,
            socketPath: scope.socketPath, hostIDs: [scope.hostID])
        if intent.released {
            guard let binding = intent.binding else { throw V2DockerRoomHostLaunchError.invalidIntent }
            let inventory = try await V2DockerRoomHostInventory.open(at: inventoryPath, scope: inventoryScope, pool: pool)
            do {
                try await requireBinding(binding, inventory: inventory)
                return .init(binding: binding, inventory: inventory)
            } catch { try await inventory.close(); throw error }
        }
        if intent.containerID == nil {
            // Adopt only the same owned intent after an uncertain create reply.
            if let prior = try await inspect(intent.containerName, intent: intent, deadline: deadline) {
                try await journal.recordCreated(containerID: prior.Id)
            } else {
                let created = try await send("POST", "/containers/create?name=" + intent.containerName,
                    body: intent.createRequest, deadline: deadline)
                if created.status == 201 {
                    struct Created: Decodable { let Id: String }
                    let id = try JSONDecoder().decode(Created.self, from: created.body).Id
                    try await journal.recordCreated(containerID: id)
                } else if created.status == 409 {
                    guard let prior = try await inspect(intent.containerName, intent: intent, deadline: deadline) else {
                        throw V2DockerRoomHostLauncherError.unexpectedResponse
                    }
                    try await journal.recordCreated(containerID: prior.Id)
                } else { throw V2DockerRoomHostLauncherError.unexpectedResponse }
            }
            intent = try await journal.intent()
        }
        guard let id = intent.containerID,
              var container = try await inspect(id, intent: intent, deadline: deadline) else {
            throw V2DockerRoomHostLauncherError.missingInstance
        }
        if container.State.StartedAt.hasPrefix("0001-") {
            guard container.State.Status == "created", !container.State.Running, intent.binding == nil else {
                throw V2DockerRoomHostLauncherError.instanceStopped
            }
            let started = try await send("POST", "/containers/" + id + "/start", deadline: deadline)
            guard started.status == 204 || started.status == 304,
                  let after = try await inspect(id, intent: intent, deadline: deadline) else {
                throw V2DockerRoomHostLauncherError.unexpectedResponse
            }
            container = after
        }
        // No second start after a nonzero StartedAt, including manual restarts.
        guard !container.State.StartedAt.hasPrefix("0001-") else { throw V2DockerRoomHostLauncherError.instanceStopped }
        if let binding = intent.binding, binding.startedAt != container.State.StartedAt {
            throw V2DockerRoomHostExclusionError.instanceChanged
        }
        let directory = URL(fileURLWithPath: scope.gateDirectory, isDirectory: true)
        let hello = try await waitForHello(directory: directory, id: id, startedAt: container.State.StartedAt,
            intent: intent, deadline: deadline)
        let observed = try V2RoomHostStartupGate.inspectHello(hello, hostID: scope.hostID, serviceID: scope.serviceID,
            supervisorID: scope.supervisorID, launchToken: intent.token)
        let binding = V2DockerRoomHostBinding(host: .init(hostID: scope.hostID,
            incarnationID: try V2HotPB.uuid(observed.incarnationID)), containerID: id, startedAt: container.State.StartedAt)
        guard let final = try await inspect(id, intent: intent, deadline: deadline), final.State.StartedAt == binding.startedAt else {
            throw V2DockerRoomHostExclusionError.instanceChanged
        }
        try await checkDaemon(deadline)
        try await journal.recordBound(binding)
        let inventory: V2DockerRoomHostInventory
        do {
            inventory = try await V2DockerRoomHostInventory.provision(at: inventoryPath,
                scope: inventoryScope, bindings: [binding], pool: pool)
        } catch let error as POSIXError where error.code == .EEXIST {
            inventory = try await V2DockerRoomHostInventory.open(at: inventoryPath, scope: inventoryScope, pool: pool)
        }
        do {
            try await requireBinding(binding, inventory: inventory)
            try Self.check(deadline)
            try await V2RoomHostStartupGate.release(directory: directory, hello: hello, inventory: inventory, pool: pool)
            try await journal.recordReleased(binding)
            return .init(binding: binding, inventory: inventory)
        } catch { try await inventory.close(); throw error }
    }

    private func waitForHello(directory: URL, id: String, startedAt: String,
                              intent: V2DockerRoomHostLaunchJournal.Intent,
                              deadline: ContinuousClock.Instant) async throws -> Data {
        var nextInspection = ContinuousClock.now
        while true {
            try Self.check(deadline)
            do { return try await V2RoomHostStartupGate.readHello(directory: directory, pool: pool) }
            catch let error as POSIXError where error.code == .ENOENT || error.code == .EWOULDBLOCK || error.code == .EAGAIN {
                if ContinuousClock.now >= nextInspection {
                    guard let current = try await inspect(id, intent: intent, deadline: deadline),
                          current.State.StartedAt == startedAt, current.State.Running else {
                        throw V2DockerRoomHostLauncherError.instanceStopped
                    }
                    nextInspection = .now + .milliseconds(250)
                }
                try await ContinuousClock().sleep(for: .milliseconds(20))
            }
        }
    }
    private func requireBinding(_ binding: V2DockerRoomHostBinding, inventory: V2DockerRoomHostInventory) async throws {
        let stored = try await inventory.bindings()
        guard stored.count == 1, stored[0].host == binding.host, stored[0].containerID == binding.containerID,
              stored[0].startedAt == binding.startedAt else { throw V2DockerRoomHostLaunchError.conflictingInstance }
    }
    private struct Container: Decodable {
        let Id: String; let Name: String; let RestartCount: Int; let State: StateValue; let Config: Configuration; let HostConfig: Host
        struct StateValue: Decodable { let Running: Bool; let Restarting: Bool; let StartedAt: String; let Status: String }
        struct Configuration: Decodable { let Labels: [String: String] }
        struct Host: Decodable { let RestartPolicy: Restart; let Privileged: Bool; let PidMode: String; let AutoRemove: Bool }
        struct Restart: Decodable { let Name: String }
    }
    private func inspect(_ reference: String, intent: V2DockerRoomHostLaunchJournal.Intent,
                         deadline: ContinuousClock.Instant) async throws -> Container? {
        let response = try await send("GET", "/containers/" + reference + "/json", deadline: deadline)
        if response.status == 404 { return nil }
        guard response.status == 200 else { throw V2DockerRoomHostLauncherError.unexpectedResponse }
        let container = try JSONDecoder().decode(Container.self, from: response.body)
        guard container.Id.utf8.count == 64,
              container.Id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              intent.containerID == nil || intent.containerID == container.Id,
              container.Name == "/" + intent.containerName, container.RestartCount == 0, !container.State.Restarting,
              container.HostConfig.RestartPolicy.Name == "no", !container.HostConfig.Privileged,
              container.HostConfig.PidMode != "host", !container.HostConfig.AutoRemove,
              container.Config.Labels["com.imv2.actor.host-id"] == scope.hostID.rawValue,
              container.Config.Labels["com.imv2.actor.launch-token"] == intent.token.uuidString.lowercased() else {
            throw V2DockerRoomHostExclusionError.instanceChanged
        }
        return container
    }
    private func send(_ method: String, _ path: String, body: Data? = nil,
                      deadline: ContinuousClock.Instant) async throws -> V2DockerRoomHostExclusionBackend.Response {
        try Self.check(deadline)
        let response = try await request(method, path, body, deadline)
        try Self.check(deadline)
        return response
    }
    private func checkDaemon(_ deadline: ContinuousClock.Instant) async throws {
        struct Daemon: Decodable { let ID: String }
        let response = try await send("GET", "/info", deadline: deadline)
        guard response.status == 200 else { throw V2DockerRoomHostExclusionError.unavailable }
        guard try JSONDecoder().decode(Daemon.self, from: response.body).ID == scope.daemonID else {
            throw V2DockerRoomHostExclusionError.daemonChanged
        }
    }
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomHostRecoveryError.deadlineExceeded }
    }
}
