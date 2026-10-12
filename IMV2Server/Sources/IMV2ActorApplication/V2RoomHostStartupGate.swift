import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerInfrastructure
import NIOPosix
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

package enum V2RoomHostStartupGateError: Error { case invalidHandshake, alreadyStarted }

/// One private per-container mount shared only with its trusted launcher.
/// This is a one-time startup barrier, not a renewable execution lease.
package actor V2RoomHostStartupGate {
    private enum State { case fresh, waiting, released, failed }
    private var state = State.fresh
    private let directory: URL
    private let hello: Data
    private let supervisorID: V2ActorServiceID
    private static let maximumBytes = 4096

    package init(directory: URL, host: V2ActorHostIdentity, serviceID: V2ActorServiceID,
                 supervisorID: V2ActorServiceID, launchToken: UUID) throws {
        self.directory = directory; self.supervisorID = supervisorID
        var message = Im_Actor_V1_RoomHostStartupHello()
        message.hostID = host.hostID.rawValue; message.incarnationID = V2HotPB.bytes(host.incarnationID)
        message.launchToken = V2HotPB.bytes(launchToken); message.supervisorID = supervisorID.rawValue
        message.serviceID = serviceID.rawValue; message.processID = Int64(ProcessInfo.processInfo.processIdentifier)
        hello = try message.serializedData()
    }

    package func wait(deadline: ContinuousClock.Instant) async throws {
        if state == .released { return }
        guard state == .fresh else { throw V2RoomHostStartupGateError.alreadyStarted }
        state = .waiting
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start()
        do {
            try Self.check(deadline)
            try await pool.runIfActive { [directory] in
                var info = stat()
                guard directory.isFileURL, directory.path.hasPrefix("/"),
                      lstat(directory.path, &info) == 0,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0 else {
                    throw V2RoomHostStartupGateError.invalidHandshake
                }
            }
            let published = try await V2ActorDurableFileStorage.provision(
                at: directory.appendingPathComponent("hello.pb"), initial: hello,
                maximumBytes: Self.maximumBytes, pool: pool, validate: { _ = try Self.decodeHello($0) })
            try await published.close()
            let digest = Data(SHA256.hash(data: hello))
            let release = directory.appendingPathComponent("release.pb")
            while true {
                try Self.check(deadline)
                let exists = try await pool.runIfActive {
                    var info = stat()
                    if lstat(release.path, &info) == 0 { return true }
                    guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    return false
                }
                if exists {
                    do {
                        _ = try await Self.read(release, pool: pool, validate: { [supervisorID] bytes in
                            try Self.validateRelease(bytes, digest: digest, supervisorID: supervisorID)
                        })
                        try Self.check(deadline)
                        break
                    } catch let error as POSIXError where error.code == .EWOULDBLOCK || error.code == .EAGAIN {
                        // The launcher may still be closing its durable writer.
                    }
                }
                try await ContinuousClock().sleep(for: .milliseconds(20))
            }
            try await pool.shutdownGracefully()
            state = .released
        } catch {
            state = .failed
            try await pool.shutdownGracefully()
            throw error
        }
    }

    package static func readHello(directory: URL, pool: NIOThreadPool) async throws -> Data {
        try await read(directory.appendingPathComponent("hello.pb"), pool: pool,
            validate: { _ = try decodeHello($0) })
    }

    package static func inspectHello(_ bytes: Data, hostID: V2ActorHostID, serviceID: V2ActorServiceID,
                                     supervisorID: V2ActorServiceID, launchToken: UUID) throws
        -> Im_Actor_V1_RoomHostStartupHello {
        let message = try decodeHello(bytes)
        guard message.hostID == hostID.rawValue, message.serviceID == serviceID.rawValue,
              message.supervisorID == supervisorID.rawValue,
              try V2HotPB.uuid(message.launchToken) == launchToken else {
            throw V2RoomHostStartupGateError.invalidHandshake
        }
        return message
    }

    /// Publishing release requires an already-durable matching inventory.
    /// A release retry confirms the exact existing reply instead of replacing it.
    package static func release(directory: URL, hello: Data, inventory: V2DockerRoomHostInventory,
                                pool: NIOThreadPool) async throws {
        try Task.checkCancellation()
        let message = try decodeHello(hello)
        let supervisor = try V2ActorServiceID(message.supervisorID)
        try inventory.requireSupervisor(supervisor)
        let identity = V2ActorHostIdentity(hostID: try V2ActorHostID(message.hostID),
            incarnationID: try V2HotPB.uuid(message.incarnationID))
        guard try await inventory.bindings().contains(where: { $0.host == identity }),
              try await readHello(directory: directory, pool: pool) == hello else {
            throw V2RoomHostStartupGateError.invalidHandshake
        }
        var reply = Im_Actor_V1_RoomHostStartupRelease()
        let digest = Data(SHA256.hash(data: hello))
        reply.helloSha256 = digest; reply.supervisorID = supervisor.rawValue
        let path = directory.appendingPathComponent("release.pb")
        let validate: @Sendable (Data) throws -> Void = { try validateRelease($0, digest: digest, supervisorID: supervisor) }
        let file: V2ActorDurableFileStorage
        do {
            file = try await V2ActorDurableFileStorage.provision(at: path, initial: reply.serializedData(),
                maximumBytes: maximumBytes, pool: pool, validate: validate)
        } catch let error as POSIXError where error.code == .EEXIST {
            file = try await V2ActorDurableFileStorage.open(at: path, maximumBytes: maximumBytes, pool: pool, validate: validate)
        }
        do {
            try await file.update { bytes in try validate(bytes); return (nil, ()) }
            try await file.close()
        } catch { try await file.close(); throw error }
    }

    private static func read(_ path: URL, pool: NIOThreadPool,
                             validate: @escaping @Sendable (Data) throws -> Void) async throws -> Data {
        // A reader probing before publication must not create/take the writer's
        // sidecar lock. Once published, normal exclusive reads remain bounded.
        try await pool.runIfActive {
            var info = stat()
            guard lstat(path.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        let file = try await V2ActorDurableFileStorage.open(at: path, maximumBytes: maximumBytes, pool: pool, validate: validate)
        do {
            let bytes = try await file.load(); try validate(bytes)
            try await file.close(); return bytes
        } catch { try await file.close(); throw error }
    }
    private static func decodeHello(_ bytes: Data) throws -> Im_Actor_V1_RoomHostStartupHello {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw V2RoomHostStartupGateError.invalidHandshake }
        let message = try Im_Actor_V1_RoomHostStartupHello(serializedBytes: bytes)
        try V2HotPB.check(message)
        _ = try V2ActorHostID(message.hostID); _ = try V2HotPB.uuid(message.incarnationID)
        _ = try V2HotPB.uuid(message.launchToken); _ = try V2ActorServiceID(message.supervisorID)
        _ = try V2ActorServiceID(message.serviceID)
        guard message.processID > 0 else { throw V2RoomHostStartupGateError.invalidHandshake }
        return message
    }
    private static func validateRelease(_ bytes: Data, digest: Data, supervisorID: V2ActorServiceID) throws {
        let message = try Im_Actor_V1_RoomHostStartupRelease(serializedBytes: bytes)
        try V2HotPB.check(message)
        guard message.helloSha256 == digest, message.supervisorID == supervisorID.rawValue else {
            throw V2RoomHostStartupGateError.invalidHandshake
        }
    }
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomHostRecoveryError.deadlineExceeded }
    }
}
