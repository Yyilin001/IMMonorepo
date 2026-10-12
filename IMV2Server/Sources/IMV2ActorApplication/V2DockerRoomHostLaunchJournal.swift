import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix

package enum V2DockerRoomHostLaunchError: Error { case invalidIntent, conflictingInstance }

/// One durable intent per owned container generation. The Docker API body is
/// opaque boundary data kept in the PB record, never regenerated on retries.
/// No API call may create/start a container before this intent is durable.
package final class V2DockerRoomHostLaunchJournal: Sendable {
    package struct Scope: Sendable, Equatable {
        package let supervisorID: V2ActorServiceID
        package let daemonID: String
        package let socketPath: String
        package let hostID: V2ActorHostID
        package let serviceID: V2ActorServiceID
        package let gateDirectory: String
        package init(supervisorID: V2ActorServiceID, daemonID: String, socketPath: String,
                     hostID: V2ActorHostID, serviceID: V2ActorServiceID, gateDirectory: String) {
            self.supervisorID = supervisorID; self.daemonID = daemonID; self.socketPath = socketPath
            self.hostID = hostID; self.serviceID = serviceID; self.gateDirectory = gateDirectory
        }
    }
    package struct Intent: Sendable {
        package let token: UUID
        package let createRequest: Data
        package let containerID: String?
        package let binding: V2DockerRoomHostBinding?
        package let released: Bool
        package var containerName: String { "imv2-host-launch-" + token.uuidString.lowercased() }
    }
    private let file: V2ActorDurableFileStorage
    private let scope: Scope
    private static let maximumBytes = 256 * 1024
    private init(file: V2ActorDurableFileStorage, scope: Scope) { self.file = file; self.scope = scope }

    package static func provision(at path: URL, scope: Scope, pool: NIOThreadPool,
                                  createRequest: @Sendable (UUID) throws -> Data) async throws -> V2DockerRoomHostLaunchJournal {
        let token = UUID()
        var record = Im_Actor_V1_DockerRoomHostLaunch()
        record.version = 1; record.supervisorID = scope.supervisorID.rawValue
        record.daemonID = scope.daemonID; record.socketPath = scope.socketPath
        record.hostID = scope.hostID.rawValue; record.serviceID = scope.serviceID.rawValue
        record.gateDirectory = scope.gateDirectory; record.launchToken = V2HotPB.bytes(token)
        record.createRequest = try createRequest(token)
        let file = try await V2ActorDurableFileStorage.provision(at: path, initial: encode(record),
            maximumBytes: maximumBytes, pool: pool, validate: { _ = try decode($0, scope: scope) })
        return .init(file: file, scope: scope)
    }
    package static func open(at path: URL, scope: Scope, pool: NIOThreadPool) async throws -> V2DockerRoomHostLaunchJournal {
        let file = try await V2ActorDurableFileStorage.open(at: path, maximumBytes: maximumBytes,
            pool: pool, validate: { _ = try decode($0, scope: scope) })
        return .init(file: file, scope: scope)
    }
    package func intent() async throws -> Intent {
        try Self.intent(Self.decode(await file.load(), scope: scope))
    }
    package func recordCreated(containerID: String) async throws {
        try await file.update { [scope] bytes in
            var record = try Self.decode(bytes, scope: scope)
            guard Self.validContainerID(containerID) else { throw V2DockerRoomHostLaunchError.invalidIntent }
            if !record.containerID.isEmpty {
                guard record.containerID == containerID else { throw V2DockerRoomHostLaunchError.conflictingInstance }
                return (nil, ())
            }
            record.containerID = containerID
            return (try Self.encode(record), ())
        }
    }
    package func recordBound(_ binding: V2DockerRoomHostBinding) async throws {
        try await file.update { [scope] bytes in
            var record = try Self.decode(bytes, scope: scope)
            _ = try V2DockerRoomHostExclusionBackend.validateBindings(daemonID: scope.daemonID, bindings: [binding])
            guard binding.host.hostID == scope.hostID, record.containerID == binding.containerID else {
                throw V2DockerRoomHostLaunchError.conflictingInstance
            }
            if !record.incarnationID.isEmpty {
                guard record.incarnationID == V2HotPB.bytes(binding.host.incarnationID), record.startedAt == binding.startedAt else {
                    throw V2DockerRoomHostLaunchError.conflictingInstance
                }
                return (nil, ())
            }
            record.incarnationID = V2HotPB.bytes(binding.host.incarnationID); record.startedAt = binding.startedAt
            return (try Self.encode(record), ())
        }
    }
    /// Called after durable inventory and actual startup release, not on signal
    /// delivery. A crash before this marker retries the same exact release.
    package func recordReleased(_ binding: V2DockerRoomHostBinding) async throws {
        try await file.update { [scope] bytes in
            var record = try Self.decode(bytes, scope: scope)
            guard let current = try Self.intent(record).binding, current.host == binding.host,
                  current.containerID == binding.containerID, current.startedAt == binding.startedAt else {
                throw V2DockerRoomHostLaunchError.conflictingInstance
            }
            if record.released { return (nil, ()) }
            record.released = true; return (try Self.encode(record), ())
        }
    }
    package func close() async throws { try await file.close() }
    package func requireScope(_ candidate: Scope) throws {
        guard candidate == scope else { throw V2DockerRoomHostLaunchError.invalidIntent }
    }

    private static func validContainerID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func intent(_ record: Im_Actor_V1_DockerRoomHostLaunch) throws -> Intent {
        let token = try V2HotPB.uuid(record.launchToken)
        let binding: V2DockerRoomHostBinding?
        if record.incarnationID.isEmpty { binding = nil }
        else {
            binding = try .init(host: .init(hostID: V2ActorHostID(record.hostID),
                incarnationID: V2HotPB.uuid(record.incarnationID)),
                containerID: record.containerID, startedAt: record.startedAt)
        }
        return .init(token: token, createRequest: record.createRequest,
            containerID: record.containerID.isEmpty ? nil : record.containerID, binding: binding, released: record.released)
    }
    private static func encode(_ record: Im_Actor_V1_DockerRoomHostLaunch) throws -> Data {
        let bytes = try record.serializedData()
        var envelope = Im_Actor_V1_DockerRoomHostLaunchFile()
        envelope.launch = bytes; envelope.sha256 = Data(SHA256.hash(data: bytes))
        let result = try envelope.serializedData()
        guard result.count <= maximumBytes else { throw V2DockerRoomHostLaunchError.invalidIntent }
        return result
    }
    private static func decode(_ bytes: Data, scope: Scope) throws -> Im_Actor_V1_DockerRoomHostLaunch {
        guard !bytes.isEmpty, bytes.count <= maximumBytes, !scope.daemonID.isEmpty,
              scope.socketPath.hasPrefix("/"), !scope.socketPath.contains("\0"),
              scope.gateDirectory.hasPrefix("/"), !scope.gateDirectory.contains("\0") else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
        let envelope = try Im_Actor_V1_DockerRoomHostLaunchFile(serializedBytes: bytes)
        try V2HotPB.check(envelope)
        guard !envelope.launch.isEmpty, envelope.sha256.count == 32,
              envelope.sha256 == Data(SHA256.hash(data: envelope.launch)) else { throw V2DockerRoomHostLaunchError.invalidIntent }
        let record = try Im_Actor_V1_DockerRoomHostLaunch(serializedBytes: envelope.launch)
        try V2HotPB.check(record)
        guard record.version == 1, record.supervisorID == scope.supervisorID.rawValue,
              record.daemonID == scope.daemonID, record.socketPath == scope.socketPath,
              record.hostID == scope.hostID.rawValue, record.serviceID == scope.serviceID.rawValue,
              record.gateDirectory == scope.gateDirectory, !record.createRequest.isEmpty,
              record.createRequest.count <= 128 * 1024,
              record.containerID.isEmpty || validContainerID(record.containerID),
              record.incarnationID.isEmpty == record.startedAt.isEmpty,
              !record.released || !record.incarnationID.isEmpty else { throw V2DockerRoomHostLaunchError.invalidIntent }
        let token = try V2HotPB.uuid(record.launchToken)
        try validateRequest(record.createRequest, scope: scope, token: token)
        if !record.incarnationID.isEmpty {
            let binding = V2DockerRoomHostBinding(host: .init(hostID: scope.hostID,
                incarnationID: try V2HotPB.uuid(record.incarnationID)), containerID: record.containerID, startedAt: record.startedAt)
            _ = try V2DockerRoomHostExclusionBackend.validateBindings(daemonID: scope.daemonID, bindings: [binding])
        }
        return record
    }
    private struct Request: Decodable {
        let Image: String; let Env: [String]; let Labels: [String: String]; let HostConfig: Host
        struct Host: Decodable {
            let RestartPolicy: Restart; let Privileged: Bool; let PidMode: String; let AutoRemove: Bool; let Mounts: [Mount]
        }
        struct Restart: Decodable { let Name: String }
        struct Mount: Decodable {
            let kind: String; let Source: String; let Target: String; let ReadOnly: Bool
            enum CodingKeys: String, CodingKey { case kind = "Type", Source, Target, ReadOnly }
        }
    }
    private static func validateRequest(_ bytes: Data, scope: Scope, token: UUID) throws {
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        let image = request.Image.components(separatedBy: "@sha256:")
        guard image.count == 2, !image[0].isEmpty, validContainerID(image[1]),
              request.HostConfig.RestartPolicy.Name == "no", !request.HostConfig.Privileged,
              request.HostConfig.PidMode != "host", !request.HostConfig.AutoRemove,
              request.Labels["com.imv2.actor.host-id"] == scope.hostID.rawValue,
              request.Labels["com.imv2.actor.launch-token"] == token.uuidString.lowercased() else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
        var environment: [String: String] = [:]
        for entry in request.Env {
            guard let equal = entry.firstIndex(of: "="), equal != entry.startIndex else { throw V2DockerRoomHostLaunchError.invalidIntent }
            let key = String(entry[..<equal]), value = String(entry[entry.index(after: equal)...])
            guard environment.updateValue(value, forKey: key) == nil else { throw V2DockerRoomHostLaunchError.invalidIntent }
        }
        guard environment["IMV2_ROOM_ACTOR_STARTUP_GATE_DIRECTORY"] == "/imv2-startup",
              environment["IMV2_ROOM_ACTOR_STARTUP_GATE_TOKEN"] == token.uuidString.lowercased(),
              environment["IMV2_ROOM_ACTOR_STARTUP_SUPERVISOR_ID"] == scope.supervisorID.rawValue,
              request.HostConfig.Mounts.filter({ $0.Target == "/imv2-startup" }).count == 1,
              request.HostConfig.Mounts.contains(where: { $0.kind == "bind" && $0.Source == scope.gateDirectory
                  && $0.Target == "/imv2-startup" && !$0.ReadOnly }) else {
            throw V2DockerRoomHostLaunchError.invalidIntent
        }
    }
}
